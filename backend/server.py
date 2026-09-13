#!/usr/bin/env python3
"""Owner-only Unix socket backend for the YT Widget plugin.

Plain YouTube (not YouTube Music): search via yt-dlp, playback via mpv.
No browser, no login, no account cookies anywhere in this process.

Wire protocol and mpv-control design adapted from wizwam/omamusic (MIT).
"""

from __future__ import annotations

import argparse
import os
import signal
import socket
import sys
import threading
import time
import traceback
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import audio_output
import play_history
import playlists
import queue_session
import search as search_mod
import store
import urls as urls_mod
import video as video_mod
from audio_output import AudioOutputError
from player import PlayerError, QueuePlayer
from protocol import (
    BACKEND_VERSION,
    ERROR_INVALID_REQUEST,
    ERROR_PLAYBACK,
    ERROR_SEARCH,
    ERROR_UNSUPPORTED_VERSION,
    MAX_LINE_BYTES,
    PROTOCOL_VERSION,
    encode_line,
    event,
    parse_line,
    response,
    spectrum_event,
    write_locked,
)
from search import SearchError
from urls import UrlError
from video import VideoError, VideoWindow


def runtime_dir() -> Path:
    root = Path(os.environ.get("XDG_RUNTIME_DIR") or f"/tmp/ytwidget-{os.getuid()}")
    path = root / "ytwidget"
    path.mkdir(parents=True, exist_ok=True)
    try:
        path.chmod(0o700)
    except OSError:
        pass
    return path


def socket_path() -> Path:
    return runtime_dir() / "backend.sock"


def idle_should_exit(*, idle_minutes: int, playing: bool, client_count: int,
                     last_activity: float, now: float,
                     video_active: bool = False) -> bool:
    # An open video window counts as busy even though the audio deck is
    # paused behind it — shutting the daemon down here would close the window
    # the user is watching.
    if idle_minutes <= 0 or playing or video_active or client_count > 0:
        return False
    return (now - last_activity) >= idle_minutes * 60


class Backend:
    def __init__(self) -> None:
        self.lifecycle = "ready"
        self.error = ""
        self.idle_minutes = 15
        self.quality_kbps = 320
        self.generation = 0
        self._clients: list[socket.socket] = []
        self._clients_lock = threading.Lock()
        self._send_lock = threading.Lock()
        self._stop = threading.Event()
        self.player = QueuePlayer(
            runtime_dir(),
            on_change=self._on_player_change,
            on_played=self._on_track_played,
        )
        self.sub_lang = video_mod.DEFAULT_SUB_LANG
        self.video_max_height = video_mod.DEFAULT_MAX_HEIGHT
        self._video_resume_playing = False
        self._video_was_current = False
        self.video_speed = 1.0
        self.video_autofit = video_mod.DEFAULT_AUTOFIT_PERCENT
        self.video_gpu = "integrated"
        self.video_resolver = video_mod.VideoResolver(self.sub_lang)
        self.video = VideoWindow(runtime_dir(), on_closed=self._on_video_closed,
                                 on_ready=self._on_video_ready,
                                 on_pause_changed=self._on_video_pause_changed)
        self.local_history = play_history.load()
        self._last_broadcast = 0.0
        self._last_queue_save = 0.0
        self._resume_playing = False
        self._queue_save_timer: threading.Timer | None = None
        self._queue_path = queue_session.queue_path()
        self._restore_queue_session()

    def state(self) -> dict[str, Any]:
        track = self.player.snapshot_track()
        return {
            "lifecycle": self.lifecycle,
            "backend_version": BACKEND_VERSION,
            "protocol_version": PROTOCOL_VERSION,
            "playing": self.player.playing,
            "resolving": self.player.resolving,
            "shuffle": self.player.shuffle,
            "repeat": self.player.repeat,
            "volume": self.player.volume,
            "muted": self.player.muted,
            "position_ms": self.player.position_ms,
            "duration_ms": self.player.duration_ms,
            "track": track,
            "queue": list(self.player.queue),
            "queue_index": self.player.index,
            "idle_minutes": self.idle_minutes,
            "crossfade_ms": self.player.crossfade_ms,
            "video_active": self.video.active,
            "video_playing": self.video.active and not self.video.paused,
            "video_id": self.video.video_id if self.video.active else "",
            "video_speed": self.video.speed,
            "video_height": self.video.height,
            "video_heights": list(self.video.heights),
            "video_speeds": list(video_mod.SPEEDS),
            "video_default_height": self.video_max_height,
            "video_window_percent": self.video_autofit,
            "video_gpu": self.video_gpu,
            "video_ready": bool(self.video_resolver.cached(
                str((self.player.current or {}).get("videoId") or ""))),
            "sub_lang": self.sub_lang,
            "quality_kbps": self.quality_kbps,
            "eq": self.player.eq_snapshot(),
            "generation": self.generation,
            "error": self.error or self.player.error,
            "play_history": list(self.local_history),
            "playlists": playlists.list_playlists(),
        }

    def _send(self, client: socket.socket, data: bytes) -> None:
        write_locked(self._send_lock, client, data)

    def broadcast(self) -> None:
        self.generation += 1
        data = encode_line(event("state_changed", self.state()))
        with self._clients_lock:
            living = []
            for client in self._clients:
                try:
                    self._send(client, data)
                    living.append(client)
                except OSError:
                    try:
                        client.close()
                    except OSError:
                        pass
            self._clients[:] = living
        self._last_broadcast = time.time()

    def broadcast_spectrum(self, bands: list[float] | None = None) -> None:
        values = list(bands) if bands is not None else self.player.spectrum.snapshot()
        data = encode_line(spectrum_event(values))
        with self._clients_lock:
            living = []
            for client in self._clients:
                try:
                    self._send(client, data)
                    living.append(client)
                except OSError:
                    try:
                        client.close()
                    except OSError:
                        pass
            self._clients[:] = living

    def _on_player_change(self) -> None:
        now = time.time()
        if now - self._last_broadcast < 0.05:
            self._schedule_remember_queue()
            return
        self.broadcast()
        self._schedule_remember_queue()

    def _on_video_ready(self, video_id: str) -> None:
        """The video window has a picture — now hand the sound over.

        Pausing the deck at click time instead left several seconds of dead
        silence while mpv opened its streams and started its decoder. Keeping
        the music running until this point means the only thing the user
        notices is the window appearing.
        """
        try:
            if not self._video_was_current:
                if self.player.playing:
                    self.player.pause()
                return
            if self.player.playing:
                # The deck kept playing through the load, so it has moved on.
                # Line the video up with where the audio actually got to.
                self.video.seek(int(self.player.position_ms))
                self.player.pause()
        except Exception:
            pass
        finally:
            self.broadcast()

    def _on_video_pause_changed(self) -> None:
        """mpv's pause state flipped — either from our own command or the
        user hitting space/clicking inside the window directly. Either way
        the UI's play/pause indicator needs to catch up."""
        self.broadcast()

    def _on_video_closed(self, video_id: str, position_ms: int) -> None:
        """The video window is gone — give the audio deck the playhead back.

        Only when the window was showing the track the deck actually has
        loaded; watching some other video from search must not seek the
        queue to that video's timestamp.
        """
        try:
            if self._video_was_current and position_ms > 0:
                self.player.set_resume_position(int(position_ms))
            if self._video_resume_playing:
                self.player.play()
        except Exception:
            pass
        finally:
            self._video_resume_playing = False
            self._video_was_current = False
            self.broadcast()

    def _prewarm_video(self, item: dict) -> None:
        """Resolve this track's video ladder in the background while its audio
        plays, so pressing the video button costs no extraction at all."""
        video_id = str((item or {}).get("videoId") or "")
        if video_id:
            self.video_resolver.prefetch(video_id)

    def _on_track_played(self, item: dict) -> None:
        self._remember_play(item)
        self._prewarm_video(item)

    def _remember_play(self, item: dict) -> None:
        self.local_history = play_history.remember(item, self.local_history)

    def _remember_queue(self) -> None:
        try:
            queue_session.save({
                "items": list(self.player.queue),
                "index": self.player.index,
                "shuffle": self.player.shuffle,
                "repeat": self.player.repeat,
                "position_ms": self.player.position_ms,
                "playing": bool(self.player.playing),
            }, self._queue_path)
        except OSError:
            return
        self._last_queue_save = time.time()

    def _schedule_remember_queue(self) -> None:
        if self._queue_save_timer:
            self._queue_save_timer.cancel()
        timer = threading.Timer(0.4, self._remember_queue)
        timer.daemon = True
        self._queue_save_timer = timer
        timer.start()

    def _restore_queue_session(self) -> None:
        session = queue_session.load(self._queue_path)
        items = list((session or {}).get("items") or [])
        if items:
            self.player.restore_queue(
                items,
                index=int(session.get("index") or 0),
                shuffle=bool(session.get("shuffle")),
                repeat=str(session.get("repeat") or "off"),
                position_ms=int(session.get("position_ms") or 0),
            )
            # Never auto-resume audio on restore — always come back paused,
            # so nothing plays without an explicit action from the user.
            self._resume_playing = False
            return
        if session is not None:
            return
        if self.local_history:
            self.player.restore_queue(self.local_history[:1], index=0)

    def _resume_queue_session(self) -> None:
        # Warm the restored track's video ladder even when it comes back
        # paused. Prewarm otherwise only happens when a track *starts*, so
        # straight after a daemon restart the video button would fall back to
        # the slow path on the very track most likely to be clicked.
        current = self.player.current
        if current:
            self._prewarm_video(current)
        if not self._resume_playing or not current:
            return
        self._resume_playing = False
        try:
            self.player.play()
        except Exception:
            pass

    def handle(self, message: dict[str, Any]) -> dict[str, Any]:
        version = message.get("v", PROTOCOL_VERSION)
        request_id = message.get("id")
        if version != PROTOCOL_VERSION:
            return response(request_id, False, code=ERROR_UNSUPPORTED_VERSION,
                            message="This plugin backend speaks protocol 1")
        command = str(message.get("command") or "").strip()
        try:
            result = self.dispatch(command, message)
            return response(request_id, True, result)
        except PlayerError as exc:
            return response(request_id, False, code=ERROR_PLAYBACK, message=str(exc))
        except SearchError as exc:
            return response(request_id, False, code=ERROR_SEARCH, message=str(exc))
        except UrlError as exc:
            return response(request_id, False, code=ERROR_SEARCH, message=str(exc))
        except VideoError as exc:
            return response(request_id, False, code=ERROR_PLAYBACK, message=str(exc))
        except AudioOutputError as exc:
            return response(request_id, False, code=ERROR_INVALID_REQUEST, message=str(exc))
        except (playlists.PlaylistError, ValueError) as exc:
            return response(request_id, False, code=ERROR_INVALID_REQUEST, message=str(exc))
        except Exception as exc:
            traceback.print_exc()
            return response(request_id, False, code=ERROR_INVALID_REQUEST, message=str(exc))

    def dispatch(self, command: str, message: dict[str, Any]) -> dict[str, Any]:
        self.player.note_activity()
        if command in ("hello", "ping", "get_state"):
            return self.state()
        if command == "set_idle_minutes":
            self.idle_minutes = max(0, min(1440, int(message.get("minutes") or 0)))
            return self.state()
        if command == "set_crossfade_ms":
            self.player.set_crossfade_ms(int(message.get("ms") or 0))
            return self.state()
        if command == "show_video":
            requested = str(message.get("video_id") or "").strip()
            current = self.player.current or {}
            current_id = str(current.get("videoId") or "")
            video_id = requested or current_id
            if not video_id:
                raise VideoError("Nothing is playing to show")
            is_current = bool(current_id) and video_id == current_id
            # The window plays its own sound, so the deck must stop before
            # the two overlap — but not yet; see _on_video_ready.
            self._video_resume_playing = bool(self.player.playing) and is_current
            self._video_was_current = is_current
            start_ms = int(self.player.position_ms) if is_current else 0
            # A track parked at (or within a breath of) its end would hand mpv
            # a --start past EOF, and mpv exits instantly with "End of file" —
            # the window flashes and vanishes. Start over instead.
            duration_ms = int(self.player.duration_ms or 0)
            if duration_ms > 0 and start_ms >= duration_ms - 3000:
                start_ms = 0
            title = str((current if is_current else {}).get("name") or "") or "YT Widget"
            # Deliberately NOT pausing the deck here — _on_video_ready does it
            # once the window actually has a picture, so the music covers the
            # load instead of the user sitting in silence.
            # Use the prewarmed ladder when we have one; otherwise let mpv's
            # ytdl_hook do the work rather than making the user wait twice.
            resolved = self.video_resolver.cached(video_id)
            self.video.open(
                video_id,
                title=title,
                start_ms=start_ms,
                volume=int(self.player.volume),
                sub_lang=self.sub_lang,
                max_height=self.video_max_height,
                speed=self.video_speed,
                autofit_percent=self.video_autofit,
                resolved=resolved,
                gpu=self.video_gpu,
            )
            return self.state()
        if command == "set_video_speed":
            self.video_speed = self.video.set_speed(
                float(message.get("speed") or 1.0))
            return self.state()
        if command == "set_video_quality":
            height = int(message.get("height") or 0)
            self.video_max_height = max(144, min(2160, height or self.video_max_height))
            self.video.set_quality(self.video_max_height)
            return self.state()
        if command == "set_video_defaults":
            height = int(message.get("height") or 0)
            if height:
                self.video_max_height = max(144, min(2160, height))
            percent = int(message.get("window_percent") or 0)
            if percent:
                self.video_autofit = max(20, min(100, percent))
            gpu = str(message.get("gpu") or "").strip().lower()
            if gpu in ("integrated", "default"):
                self.video_gpu = gpu
            return self.state()
        if command == "prepare_video":
            target = str(message.get("video_id") or "") or \
                str((self.player.current or {}).get("videoId") or "")
            if target:
                self.video_resolver.prefetch(target)
            return self.state()
        if command == "hide_video":
            self.video.close()
            return self.state()
        if command == "set_subtitle_lang":
            self.sub_lang = str(message.get("lang") or video_mod.DEFAULT_SUB_LANG).strip() \
                or video_mod.DEFAULT_SUB_LANG
            self.video_resolver.set_sub_lang(self.sub_lang)
            return self.state()
        if command == "set_quality":
            kbps = int(message.get("kbps") or 320)
            self.quality_kbps = 96 if kbps <= 96 else (160 if kbps <= 160 else 320)
            self.player.resolver.set_quality(self.quality_kbps)
            return self.state()
        if command == "search":
            query = str(message.get("query") or "")
            limit = int(message.get("limit") or 20)
            # A pasted link typed into the search box would otherwise be sent
            # to YouTube as a literal search string, which finds nothing. Show
            # what the link points at instead; `open_link` is what plays it.
            if urls_mod.looks_like_url(query) and urls_mod.parse(query):
                expanded = urls_mod.resolve_link(query)
                return {
                    "items": expanded.get("items") or [],
                    "link": True,
                    "kind": expanded.get("kind") or "",
                    "index": int(expanded.get("index") or 0),
                }
            return {"items": search_mod.search(query, limit)}
        if command == "open_link":
            expanded = urls_mod.resolve_link(str(message.get("url") or ""))
            items = expanded.get("items") or []
            if not items:
                raise UrlError("That link has nothing playable in it")
            # A playlist link replaces the queue outright — that is the whole
            # point of pasting one, and it matches what youtube.com does.
            self.player.load(
                items,
                index=int(expanded.get("index") or 0),
                play=bool(message.get("play", True)),
            )
            return self.state() | {
                "kind": expanded.get("kind") or "",
                "loaded": len(items),
            }
        if command == "play":
            self.video.play() if self.video.active else self.player.play()
            return self.state()
        if command == "pause":
            self.video.pause() if self.video.active else self.player.pause()
            return self.state()
        if command == "toggle":
            self.video.toggle() if self.video.active else self.player.toggle()
            return self.state()
        if command == "stop":
            self.player.stop()
            return self.state()
        if command == "next":
            self.player.next()
            return self.state()
        if command == "previous":
            self.player.previous()
            return self.state()
        if command == "seek":
            self.player.seek(int(message.get("position_ms") or 0))
            return self.state()
        if command == "set_volume":
            volume = message.get("volume")
            if volume is None:
                volume = message.get("value")
            self.player.set_volume(int(volume if volume is not None else 80))
            return self.state()
        if command == "set_shuffle":
            self.player.set_shuffle(bool(message.get("shuffle")))
            return self.state()
        if command == "set_repeat":
            self.player.set_repeat(str(message.get("mode") or "off"))
            return self.state()
        if command == "cycle_repeat":
            mode = self.player.cycle_repeat()
            return self.state() | {"repeat": mode}
        if command == "load":
            items = message.get("items")
            item = message.get("item")
            play_flag = bool(message.get("play", True))
            if isinstance(items, list):
                self.player.load(items, index=int(message.get("index") or 0), play=play_flag)
            elif isinstance(item, dict):
                self.player.load([item], index=0, play=play_flag)
            else:
                raise ValueError("item or items is required")
            return self.state()
        if command == "add_to_queue":
            item = message.get("item") or {}
            if not isinstance(item, dict):
                raise ValueError("item is required")
            self.player.add_to_queue(item)
            return {"queue": list(self.player.queue)}
        if command == "remove_from_queue":
            # `or -1` would turn a perfectly valid index 0 into -1, making the
            # first row of the queue impossible to remove.
            raw_index = message.get("index")
            self.player.remove_from_queue(int(raw_index) if raw_index is not None else -1)
            return {"queue": list(self.player.queue), "index": self.player.index}
        if command == "reorder_queue":
            self.player.reorder_queue(
                int(message.get("source_index") or 0),
                int(message.get("destination_index") or 0),
            )
            return {"queue": list(self.player.queue), "index": self.player.index}
        if command == "set_eq_band":
            self.player.set_eq_band(
                int(message.get("index") or 0),
                float(message.get("gain") or 0),
            )
            return self.player.eq_snapshot()
        if command == "set_eq_preset":
            self.player.set_eq_preset(str(message.get("name") or ""))
            return self.player.eq_snapshot()
        if command == "cycle_eq_preset":
            name = self.player.cycle_eq_preset()
            return self.player.eq_snapshot() | {"preset": name}
        if command == "get_queue":
            return {"items": list(self.player.queue), "index": self.player.index}
        if command == "list_audio_outputs":
            return {"outputs": audio_output.list_outputs()}
        if command == "set_audio_output":
            moved = audio_output.set_output(str(message.get("sink_name") or ""))
            return {"moved": moved}
        if command == "list_playlists":
            return {"playlists": playlists.list_playlists()}
        if command == "get_playlist":
            return playlists.get_playlist(str(message.get("playlist_id") or ""))
        if command == "create_playlist":
            source = message.get("items")
            items = source if isinstance(source, list) else list(self.player.queue)
            return playlists.create_playlist(str(message.get("name") or ""), items)
        if command == "import_playlist":
            imported = urls_mod.import_playlist(str(message.get("url") or ""))
            name = str(message.get("name") or "").strip() or imported.get("title") or "Imported playlist"
            return playlists.create_playlist(name, imported.get("items"))
        if command == "delete_playlist":
            playlists.delete_playlist(str(message.get("playlist_id") or ""))
            return {}
        if command == "add_to_playlist":
            item = message.get("item") or self.player.snapshot_track() or {}
            return playlists.add_to_playlist(str(message.get("playlist_id") or ""), item)
        if command == "remove_from_playlist":
            return playlists.remove_from_playlist(
                str(message.get("playlist_id") or ""),
                str(message.get("video_id") or ""),
            )
        if not command:
            raise ValueError("missing command")
        raise ValueError(f"Unknown command: {command}")

    def serve(self, path: Path) -> None:
        if path.exists():
            try:
                path.unlink()
            except OSError:
                pass
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(str(path))
        os.chmod(path, 0o600)
        server.listen(8)
        server.settimeout(0.5)
        print(f"ytwidget-backend listening on {path}", file=sys.stderr)
        threading.Thread(target=self._idle_watch, daemon=True).start()
        threading.Thread(target=self._position_watch, daemon=True).start()
        threading.Thread(target=self._spectrum_watch, daemon=True).start()
        self._resume_queue_session()
        try:
            while not self._stop.is_set():
                try:
                    client, _ = server.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break
                thread = threading.Thread(target=self._client_loop, args=(client,), daemon=True)
                thread.start()
        finally:
            self._stop.set()
            try:
                self._remember_queue()
            except Exception:
                pass
            self.video.shutdown()
            self.player.shutdown()
            try:
                server.close()
            except OSError:
                pass
            if path.exists():
                try:
                    path.unlink()
                except OSError:
                    pass

    def _client_loop(self, client: socket.socket) -> None:
        client.settimeout(1.0)
        self.player.note_activity()
        with self._clients_lock:
            self._clients.append(client)
        try:
            self._send(client, encode_line(event("state_changed", self.state())))
        except OSError:
            self._drop(client)
            return
        buffer = b""
        while not self._stop.is_set():
            try:
                chunk = client.recv(65536)
            except socket.timeout:
                continue
            except OSError:
                break
            if not chunk:
                break
            buffer += chunk
            if len(buffer) > MAX_LINE_BYTES and b"\n" not in buffer:
                break
            while b"\n" in buffer:
                raw, buffer = buffer.split(b"\n", 1)
                if len(raw) > MAX_LINE_BYTES:
                    self._drop(client)
                    return
                message = parse_line(raw.decode("utf-8", errors="replace"))
                if not message:
                    continue
                reply = self.handle(message)
                try:
                    self._send(client, encode_line(reply))
                except OSError:
                    self._drop(client)
                    return
        self._drop(client)

    def _drop(self, client: socket.socket) -> None:
        with self._clients_lock:
            self._clients = [item for item in self._clients if item is not client]
        try:
            client.close()
        except OSError:
            pass

    def _idle_watch(self) -> None:
        while not self._stop.is_set():
            time.sleep(15)
            with self._clients_lock:
                clients = len(self._clients)
            if idle_should_exit(
                idle_minutes=self.idle_minutes,
                playing=self.player.playing,
                video_active=self.video.active,
                client_count=clients,
                last_activity=self.player.last_activity,
                now=time.time(),
            ):
                print("ytwidget-backend idle shutdown", file=sys.stderr)
                try:
                    self._remember_queue()
                except Exception:
                    pass
                self._stop.set()
                return

    def _position_watch(self) -> None:
        while not self._stop.is_set():
            time.sleep(1.0)
            if self.player.playing:
                self.broadcast()
                if time.time() - self._last_queue_save >= 5:
                    self._remember_queue()

    def _spectrum_watch(self) -> None:
        last: list[float] = []
        while not self._stop.is_set():
            # Poll faster than the ~43Hz capture rate so no frame waits around.
            time.sleep(0.015)
            if not self.player.playing and not last:
                continue
            if self.player.playing:
                bands = self.player.spectrum.snapshot()
            else:
                bands = [value * 0.72 for value in last]
            if last and max(abs(a - b) for a, b in zip(bands, last)) < 0.008:
                last = bands
                continue
            last = bands
            if max(bands) < 0.02 and not self.player.playing:
                last = []
            self.broadcast_spectrum(bands)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="YT Widget backend")
    parser.add_argument("--socket", default="", help="Unix socket path")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)

    if args.self_test:
        probe = encode_line(event("state_changed", {"lifecycle": "ready"}))
        assert probe.endswith(b"\n")
        assert b"lifecycle" in probe
        spectrum = encode_line(spectrum_event([0.0] * 10))
        assert spectrum.endswith(b"\n")
        assert b"spectrum" in spectrum
        results = search_mod.search("test", 1)
        assert isinstance(results, list)
        print("ok")
        return 0

    backend = Backend()

    def handle_stop(signum, frame):
        backend._stop.set()

    signal.signal(signal.SIGTERM, handle_stop)
    signal.signal(signal.SIGINT, handle_stop)
    path = Path(args.socket) if args.socket else socket_path()
    backend.serve(path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
