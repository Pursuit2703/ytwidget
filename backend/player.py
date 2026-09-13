"""mpv-backed local playback with an owned queue.

Adapted from wizwam/omamusic (MIT): same mpv-control/EQ/resolver design,
with the YouTube Music radio auto-fill and catalog coupling removed since
this backend only ever deals in plain YouTube video ids.
"""

from __future__ import annotations

import json
import os
import select
import shutil
import signal
import socket
import subprocess
import threading
import time
from pathlib import Path
from typing import Any, Callable

from play_history import video_id as item_video_id
from spectrum import SpectrumTap


class PlayerError(RuntimeError):
    pass


# yt-dlp has to fetch and solve YouTube's player JS challenge the first time it
# sees a new player build, which is far slower than a normal resolve. Failing
# that inside the warm budget is what makes the very first play after an install
# report "Playback failed", so a cold cache gets a much larger budget.
RESOLVE_TIMEOUT_WARM = 40
RESOLVE_TIMEOUT_COLD = 150
YT_DLP_SIGFUNC_CACHE = (
    Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
    / "yt-dlp" / "youtube-sigfuncs"
)


def yt_dlp_cache_warm(path: Path | None = None) -> bool:
    """True when yt-dlp has already solved a player JS challenge."""
    target = Path(path) if path is not None else YT_DLP_SIGFUNC_CACHE
    try:
        return target.is_dir() and any(target.iterdir())
    except OSError:
        return False


def resolve_timeout(warm: bool) -> int:
    return RESOLVE_TIMEOUT_WARM if warm else RESOLVE_TIMEOUT_COLD


def playback_error_message(detail: str) -> str:
    text = str(detail or "").strip()
    lower = text.lower()
    # Checked before the "sign in" case below: yt-dlp's own last-line message
    # for this is literally "Sign in to confirm you're not a bot..." — which
    # would otherwise match that generic check and blame the account/video,
    # when the real, verified (via -v) underlying cause is an HTTP 429 from
    # YouTube rate-limiting the request volume, not anything sign-in related.
    if "429" in lower or "too many requests" in lower or "not a bot" in lower:
        return "YouTube is rate-limiting requests right now. Try again in a bit."
    if "403" in lower or "forbidden" in lower:
        return "YouTube refused that stream. Try it again."
    if "401" in lower or "unauthorized" in lower or "sign in" in lower:
        return "That video needs sign-in and cannot be played here."
    if "private video" in lower:
        return "That video is private."
    if "video unavailable" in lower:
        return "That video is unavailable."
    if not text:
        return "Could not resolve audio stream"
    line = text.splitlines()[-1].strip()
    if line.lower().startswith("error:"):
        line = line[6:].strip()
    return (line or "Could not resolve audio stream")[:200]


# Crossfade is a volume dip, not two overlapping decks: this backend drives a
# single mpv instance. The fade-out is started *before* the track ends (see
# _maybe_tail_fade) so a natural transition fades down into the next track
# rather than adding silence after it has already finished.
DEFAULT_CROSSFADE_MS = 500
MAX_CROSSFADE_MS = 3000
# ~25 volume writes/second. Fine enough to be inaudible as steps, coarse
# enough not to flood the mpv IPC socket.
FADE_STEP_MS = 40
# Grace period after a ramp during which observed `volume` changes are still
# treated as our own echo rather than a user action.
FADE_SETTLE_MS = 250


def quality_format(kbps: int) -> str:
    rate = 96 if kbps <= 96 else (160 if kbps <= 160 else 320)
    return f"bestaudio[abr<={rate}]/bestaudio/best"


# Ten-band EQ matching cliamp center frequencies (Hz).
EQ_FREQS = (70, 180, 320, 600, 1000, 3000, 6000, 12000, 14000, 16000)
EQ_LABELS = ("70", "180", "320", "600", "1k", "3k", "6k", "12k", "14k", "16k")
EQ_PRESETS: dict[str, tuple[float, ...]] = {
    "Flat": (0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
    "Rock": (5, 4, 2, -1, -2, 2, 4, 5, 5, 5),
    "Pop": (-1, 2, 4, 5, 4, 1, -1, -1, 1, 2),
    "Jazz": (3, 4, 2, 1, -1, -1, 1, 2, 3, 4),
    "Classical": (3, 2, 1, 0, -1, -1, 0, 2, 3, 4),
    "Bass Boost": (8, 6, 4, 2, 0, 0, 0, 0, 0, 0),
    "Treble Boost": (0, 0, 0, 0, 0, 1, 3, 5, 6, 7),
    "Vocal": (-2, -1, 1, 4, 5, 4, 2, 0, -1, -2),
    "Electronic": (6, 4, 1, -1, -2, 1, 3, 4, 5, 6),
    "Acoustic": (3, 3, 2, 0, 1, 2, 3, 3, 2, 1),
}


def eq_filter_chain(bands: list[float]) -> str:
    """Stable 10-band lavfi graph. Always emit every band so mpv does not
    rebuild a different filter topology (that restarts the stream)."""
    parts: list[str] = []
    values = list(bands) + [0.0] * 10
    for freq, gain in zip(EQ_FREQS, values):
        clamped = max(-12.0, min(12.0, float(gain)))
        parts.append(f"equalizer=f={freq}:t=o:w=1:g={clamped:.1f}")
    return "lavfi=[" + ",".join(parts) + "]"


def media_title(item: dict | None) -> str:
    source = item or {}
    title = str(source.get("name") or source.get("title") or "").strip()
    if title:
        return title[:200]
    return "YouTube"


def media_artist(item: dict | None) -> str:
    source = item or {}
    return str(source.get("subtitle") or "").strip()[:200]


def mpris_title(item: dict | None = None) -> str:
    title = media_title(item)
    artist = media_artist(item)
    if artist and artist.lower() not in title.lower():
        return f"{artist} - {title}"[:220]
    return title


def loadfile_command(url: str, item: dict | None = None) -> list:
    options = {"force-media-title": mpris_title(item)}
    return ["loadfile", url, "replace", -1, options]


def looks_like_stream_title(text: str) -> bool:
    value = str(text or "")
    lower = value.lower()
    return (
        "googlevideo.com" in lower
        or "videoplayback" in lower
        or "mime=audio" in lower
        or value.startswith("webm&")
        or "&ns=" in value
        or "&sig=" in value
    )


def mpv_command_line(binary: str, ipc_path: Path, mpris: str = "") -> list[str]:
    command = [
        binary,
        "--no-config",
        "--idle=yes",
        "--no-video",
        "--vo=null",
        "--force-window=no",
        "--no-terminal",
        "--audio-display=no",
        "--osc=no",
        "--load-scripts=no",
        "--keep-open=no",
        "--ytdl=no",
        "--ao=pipewire,pulse",
        "--clipboard-backends-clr",
        "--no-input-default-bindings",
        "--volume=80",
        "--title=YT Widget",
        "--audio-client-name=ytwidget",
        f"--input-ipc-server={ipc_path}",
        "--msg-level=cplayer=info,ao=info,ffmpeg=warn",
    ]
    if mpris:
        command.append(f"--script={mpris}")
    return command


def mpv_env(source: dict[str, str] | None = None) -> dict[str, str]:
    env = dict(source if source is not None else os.environ)
    for key in (
        "WAYLAND_DISPLAY",
        "DISPLAY",
        "HYPRLAND_INSTANCE_SIGNATURE",
        "SWAYSOCK",
        "WAYLAND_SOCKET",
    ):
        env.pop(key, None)
    return env


class Mpv:
    def __init__(self, ipc_path: Path):
        self.ipc_path = ipc_path
        self.process: subprocess.Popen | None = None
        self.sock: socket.socket | None = None
        self._next_id = 1
        self._lock = threading.Lock()

    @property
    def running(self) -> bool:
        return self.process is not None and self.process.poll() is None

    def start(self) -> None:
        if self.running:
            return
        mpv = shutil.which("mpv")
        if not mpv:
            raise PlayerError("mpv is not installed")
        self.ipc_path.parent.mkdir(parents=True, exist_ok=True)
        if self.ipc_path.exists():
            try:
                self.ipc_path.unlink()
            except OSError:
                pass
        log_path = self.ipc_path.parent / "mpv.log"
        command = mpv_command_line(mpv, self.ipc_path, _mpris_script())
        stderr = log_path.open("ab")
        try:
            self.process = subprocess.Popen(
                command,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=stderr,
                env=mpv_env(),
                start_new_session=True,
            )
        finally:
            stderr.close()
        self._wait_for_socket()
        self._connect()
        self.command(["observe_property", 1, "pause"])
        self.command(["observe_property", 2, "eof-reached"])
        self.command(["observe_property", 3, "idle-active"])
        self.command(["observe_property", 4, "time-pos"])
        self.command(["observe_property", 5, "duration"])
        self.command(["observe_property", 6, "volume"])
        self.command(["observe_property", 7, "media-title"])

    def _wait_for_socket(self, timeout: float = 4.0) -> None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.ipc_path.exists():
                return
            if self.process and self.process.poll() is not None:
                raise PlayerError("mpv exited before the control socket appeared")
            time.sleep(0.05)
        raise PlayerError("mpv control socket did not appear")

    def _connect(self) -> None:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(2.0)
        sock.connect(str(self.ipc_path))
        sock.setblocking(False)
        self.sock = sock

    def stop(self) -> None:
        if self.sock:
            try:
                self.command(["quit"])
            except Exception:
                pass
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None
        if self.process:
            try:
                self.process.terminate()
                self.process.wait(timeout=3)
            except Exception:
                try:
                    self.process.kill()
                except Exception:
                    pass
            self.process = None
        if self.ipc_path.exists():
            try:
                self.ipc_path.unlink()
            except OSError:
                pass

    def command(self, args: list[Any]) -> int:
        if not self.sock:
            raise PlayerError("mpv is not connected")
        with self._lock:
            request_id = self._next_id
            self._next_id += 1
            payload = json.dumps({"command": args, "request_id": request_id}) + "\n"
            self.sock.sendall(payload.encode("utf-8"))
            return request_id

    def poll_events(self, timeout: float = 0.2) -> list[dict]:
        if not self.sock:
            return []
        ready, _, _ = select.select([self.sock], [], [], timeout)
        if not ready:
            return []
        chunks = []
        while True:
            try:
                data = self.sock.recv(65536)
            except BlockingIOError:
                break
            if not data:
                break
            chunks.append(data)
        if not chunks:
            return []
        text = b"".join(chunks).decode("utf-8", errors="replace")
        events = []
        for line in text.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(message, dict):
                events.append(message)
        return events


def stale_mpv_pids(ipc_path: Path) -> list[int]:
    ours = str(ipc_path)
    pids: list[int] = []
    try:
        entries = Path("/proc").iterdir()
    except OSError:
        return []
    for proc in entries:
        if not proc.name.isdigit():
            continue
        try:
            raw = (proc / "cmdline").read_bytes()
        except OSError:
            continue
        cmd = raw.replace(b"\0", b" ").decode("utf-8", "replace")
        if "audio-client-name=ytwidget" not in cmd:
            continue
        if f"--input-ipc-server={ours}" in cmd:
            continue
        if "mpv" not in cmd:
            continue
        pids.append(int(proc.name))
    return pids


def reap_stale_mpv(ipc_path: Path) -> int:
    killed = 0
    for pid in stale_mpv_pids(ipc_path):
        try:
            os.kill(pid, signal.SIGTERM)
            killed += 1
        except OSError:
            pass
    return killed


def _mpris_script() -> str:
    candidates = [
        "/usr/lib/mpv-mpris/mpris.so",
        "/usr/lib/mpv/scripts/mpris.so",
        "/usr/lib64/mpv-mpris/mpris.so",
    ]
    for path in candidates:
        if os.path.isfile(path):
            return path
    return ""


class StreamResolver:
    def __init__(self, kbps: int = 320):
        self.kbps = kbps
        self._cache: dict[str, tuple[float, str]] = {}
        self._lock = threading.Lock()
        # video_id -> the event the in-flight resolve for it will set when
        # done, and (if it failed) the error text to hand to anyone waiting.
        self._inflight: dict[str, threading.Event] = {}
        self._inflight_error: dict[str, str] = {}

    def set_quality(self, kbps: int) -> None:
        self.kbps = kbps
        with self._lock:
            self._cache.clear()

    def resolve(self, video_id: str) -> str:
        video_id = str(video_id or "").strip()
        if not video_id:
            raise PlayerError("Missing video id")
        while True:
            now = time.time()
            with self._lock:
                cached = self._cache.get(video_id)
                if cached and cached[0] > now:
                    return cached[1]
                event = self._inflight.get(video_id)
                if event is None:
                    # Nobody is resolving this video right now — claim it so
                    # a concurrent caller (the foreground load racing a
                    # background prefetch, most often) waits on us instead
                    # of launching its own redundant yt-dlp process.
                    event = threading.Event()
                    self._inflight[video_id] = event
                    owner = True
                else:
                    owner = False
            if owner:
                try:
                    url = self._yt_dlp(video_id)
                except Exception as exc:
                    with self._lock:
                        self._inflight_error[video_id] = str(exc)
                        self._inflight.pop(video_id, None)
                    event.set()
                    raise
                with self._lock:
                    self._cache[video_id] = (time.time() + 4 * 60 * 60, url)
                    self._inflight_error.pop(video_id, None)
                    self._inflight.pop(video_id, None)
                event.set()
                return url
            # Someone else is already resolving this exact video. Wait for
            # their outcome (bounded by the same worst-case timeout their own
            # yt-dlp call is bounded by) rather than starting a second one —
            # only retry ourselves, as a fresh attempt, once theirs is done
            # and it turns out to have failed.
            event.wait(RESOLVE_TIMEOUT_COLD)
            with self._lock:
                cached = self._cache.get(video_id)
                if cached and cached[0] > now:
                    return cached[1]
                self._inflight_error.pop(video_id, None)
            # Either they failed (nothing cached), or we timed out still
            # waiting on them, or a stale error was left with no owner left
            # to have caused it — in every case, loop back: it either makes
            # us the new owner for a fresh attempt, or waits again on a
            # still-running one. Never launches a second yt-dlp in parallel.

    def prefetch(self, video_id: str) -> None:
        def worker() -> None:
            try:
                self.resolve(video_id)
            except Exception:
                pass
        threading.Thread(target=worker, daemon=True).start()

    def _yt_dlp(self, video_id: str) -> str:
        binary = shutil.which("yt-dlp")
        if not binary:
            raise PlayerError("yt-dlp is not installed")
        url = f"https://www.youtube.com/watch?v={video_id}"
        command = [
            binary,
            # No player_client override here. The android client exposes no
            # audio-only format at all, so `bestaudio` matched nothing and this
            # fell through to `best` — format 18, a 360p H.264 muxed stream
            # pulled down in full just to play its audio track. The default
            # clients return format 251 (opus ~130k, audio only) instead.
            "-f", quality_format(self.kbps),
            "-g",
            "--no-playlist",
            "--no-warnings",
            "--no-progress",
            url,
        ]
        warm = yt_dlp_cache_warm()
        try:
            result = subprocess.run(
                command,
                capture_output=True,
                text=True,
                timeout=resolve_timeout(warm),
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            if warm:
                raise PlayerError(
                    "YouTube took too long to answer. Try that video again."
                ) from exc
            raise PlayerError(
                "Preparing playback took too long the first time. "
                "Try that video again; the next one is much faster."
            ) from exc
        stream = (result.stdout or "").strip().splitlines()
        if result.returncode != 0 or not stream:
            detail = (result.stderr or "").strip().splitlines()
            raise PlayerError(playback_error_message(
                detail[-1] if detail else "Could not resolve audio stream"))
        return stream[-1]


class QueuePlayer:
    def __init__(
        self,
        runtime_dir: Path,
        on_change: Callable[[], None] | None = None,
        on_played: Callable[[dict], None] | None = None,
    ):
        self.mpv = Mpv(runtime_dir / "mpv.sock")
        self.resolver = StreamResolver()
        self.on_change = on_change or (lambda: None)
        self.on_played = on_played or (lambda _item: None)
        self.queue: list[dict] = []
        self.index = -1
        self.shuffle = False
        self.repeat = "off"
        self.playing = False
        self.volume = 80
        self.muted = False
        self.volume_before_mute = 80
        self.position_ms = 0
        self.duration_ms = 0
        self.error = ""
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._generation = 0
        self._sleep_deadline = 0.0
        self._sleep_after = ""
        self._display_title = ""
        self.resolving = False
        self.last_activity = time.time()
        self.eq_bands: list[float] = list(EQ_PRESETS["Flat"])
        self.eq_preset = "Flat"
        self._eq_timer: threading.Timer | None = None
        self._eq_guard_until = 0.0
        self._eq_last_chain = ""
        self.spectrum = SpectrumTap()
        self._loaded_video_id = ""
        # mpv reports idle-active while a loadfile is still settling, so a
        # stall is only believed once a load has had time to take effect.
        self._load_guard_until = 0.0
        # Whether mpv currently has nothing loaded, straight from its
        # idle-active property. play() consults this instead of trusting that
        # a matching _loaded_video_id means the file is still up.
        self._mpv_idle = True
        self._resume_position_ms = 0
        self.crossfade_ms = DEFAULT_CROSSFADE_MS
        # A fade only ever moves mpv's output volume. self.volume stays the
        # user's setting throughout, and the observed `volume` property is
        # ignored while a fade is in flight so the slider never gets rewritten.
        self._fade_lock = threading.Lock()
        self._fade_generation = 0
        self._fading = False
        self._faded_out = False
        self._tail_fade_for = ""

    @property
    def current(self) -> dict | None:
        if 0 <= self.index < len(self.queue):
            return self.queue[self.index]
        return None

    def snapshot_track(self) -> dict | None:
        item = self.current
        return dict(item) if item else None

    def ensure_started(self) -> None:
        if not self.mpv.running:
            reap_stale_mpv(self.mpv.ipc_path)
            self.mpv.start()
            self._stop.clear()
            if not self._thread or not self._thread.is_alive():
                self._thread = threading.Thread(target=self._loop, daemon=True)
                self._thread.start()
            self.mpv.command(["set_property", "volume", self.volume])
            self.apply_eq(immediate=True)
            self.spectrum.start()

    def shutdown(self) -> None:
        self._stop.set()
        self.spectrum.shutdown()
        self.mpv.stop()
        self.playing = False
        self._loaded_video_id = ""

    def load(self, items: list[dict], index: int = 0, play: bool = True) -> None:
        tracks = [item for item in items if isinstance(item, dict) and item.get("videoId")]
        if not tracks:
            raise PlayerError("Nothing playable in that selection")
        self.queue = tracks
        self.index = max(0, min(int(index or 0), len(tracks) - 1))
        self.note_activity()
        self.ensure_started()
        self._play_current(start=play)

    def add_to_queue(self, item: dict) -> None:
        if not item or not item.get("videoId"):
            raise PlayerError("That item cannot be queued")
        self.queue.append(item)
        # Queueing never interrupts what's already playing. But if the queue
        # was empty there was no current track at all, so point at the one we
        # just added — selected and ready, still paused until play is pressed.
        if self.index < 0:
            self.index = 0
            try:
                self.duration_ms = max(0, int(item.get("durationMs") or 0))
            except (TypeError, ValueError):
                self.duration_ms = 0
        self.note_activity()
        if self.current and self.current.get("videoId"):
            nxt = self._upcoming_video_id()
            if nxt:
                self.resolver.prefetch(nxt)
        self.on_change()

    def add_many_to_queue(self, items: list[dict]) -> int:
        tracks = [item for item in items if isinstance(item, dict) and item.get("videoId")]
        if not tracks:
            raise PlayerError("Nothing playable in that selection")
        was_empty = self.index < 0
        self.queue.extend(tracks)
        # Same "point at what we just added" rule as add_to_queue, for the
        # same reason: an empty queue has no current track to preserve.
        if was_empty:
            self.index = 0
            try:
                self.duration_ms = max(0, int(tracks[0].get("durationMs") or 0))
            except (TypeError, ValueError):
                self.duration_ms = 0
        self.note_activity()
        if self.current and self.current.get("videoId"):
            nxt = self._upcoming_video_id()
            if nxt:
                self.resolver.prefetch(nxt)
        self.on_change()
        return len(tracks)

    def remove_from_queue(self, index: int) -> None:
        if not (0 <= index < len(self.queue)):
            return
        with self._lock:
            self.queue.pop(index)
            if index < self.index:
                self.index -= 1
            elif index == self.index:
                self.index = min(self.index, len(self.queue) - 1)
        self.note_activity()
        self.on_change()

    def reorder_queue(self, source_index: int, destination_index: int) -> None:
        if not self.queue:
            return
        source = max(0, min(int(source_index), len(self.queue) - 1))
        destination = max(0, min(int(destination_index), len(self.queue) - 1))
        if source == destination:
            return
        with self._lock:
            current = self.index
            item = self.queue.pop(source)
            self.queue.insert(destination, item)
            if current == source:
                self.index = destination
            elif source < destination and source < current <= destination:
                self.index -= 1
            elif destination < source and destination <= current < source:
                self.index += 1
        self.note_activity()
        self.on_change()

    def eq_snapshot(self) -> dict[str, Any]:
        return {
            "bands": [float(value) for value in self.eq_bands],
            "preset": self.eq_preset,
            "labels": list(EQ_LABELS),
            "presets": list(EQ_PRESETS.keys()),
        }

    def apply_eq(self, immediate: bool = False) -> None:
        if not self.mpv.running:
            return
        with self._lock:
            if self._eq_timer:
                self._eq_timer.cancel()
                self._eq_timer = None
            if immediate:
                self._flush_eq_locked()
                return
            timer = threading.Timer(0.08, self._flush_eq)
            timer.daemon = True
            self._eq_timer = timer
            timer.start()

    def _flush_eq(self) -> None:
        with self._lock:
            self._eq_timer = None
            self._flush_eq_locked()

    def _flush_eq_locked(self) -> None:
        if not self.mpv.running:
            return
        chain = eq_filter_chain(self.eq_bands)
        if chain == self._eq_last_chain:
            return
        self._eq_last_chain = chain
        self._eq_guard_until = time.time() + 1.5
        try:
            self.mpv.command(["set_property", "af", chain])
        except PlayerError:
            pass

    def set_eq_band(self, index: int, gain: float) -> None:
        band = max(0, min(int(index), len(self.eq_bands) - 1))
        self.eq_bands[band] = max(-12.0, min(12.0, float(gain)))
        self.eq_preset = "Custom"
        self.apply_eq()
        self.on_change()

    def set_eq_preset(self, name: str) -> None:
        preset = EQ_PRESETS.get(str(name or "").strip())
        if not preset:
            raise PlayerError("Unknown EQ preset")
        self.eq_bands = list(preset)
        self.eq_preset = str(name)
        self.apply_eq()
        self.on_change()

    def restore_queue(self, items: list[dict] | None, index: int = 0,
                      shuffle: bool = False, repeat: str = "off",
                      position_ms: int = 0) -> bool:
        tracks = [item for item in (items or [])
                  if isinstance(item, dict) and item.get("videoId")]
        if not tracks:
            return False
        self.queue = tracks
        self.index = max(0, min(int(index or 0), len(tracks) - 1))
        self.shuffle = bool(shuffle)
        mode = str(repeat or "off")
        self.repeat = mode if mode in ("off", "context", "track") else "off"
        self.playing = False
        self._loaded_video_id = ""
        try:
            resume_at = max(0, int(position_ms or 0))
        except (TypeError, ValueError):
            resume_at = 0
        self.position_ms = resume_at
        self._resume_position_ms = resume_at
        current = self.current or {}
        try:
            self.duration_ms = max(0, int(current.get("durationMs") or 0))
        except (TypeError, ValueError):
            self.duration_ms = 0
        return True

    def restore_eq(self, preset: str, bands: list | None = None) -> None:
        name = str(preset or "").strip() or "Flat"
        if name == "Custom":
            values = list(bands or [])
            cleaned: list[float] = []
            for index in range(10):
                try:
                    gain = float(values[index]) if index < len(values) else 0.0
                except (TypeError, ValueError):
                    gain = 0.0
                cleaned.append(max(-12.0, min(12.0, round(gain * 2) / 2)))
            self.eq_bands = cleaned
            self.eq_preset = "Custom"
            self.apply_eq(immediate=True)
            self.on_change()
            return
        if name not in EQ_PRESETS:
            name = "Flat"
        preset = EQ_PRESETS[name]
        self.eq_bands = list(preset)
        self.eq_preset = name
        self.apply_eq(immediate=True)
        self.on_change()

    def cycle_eq_preset(self) -> str:
        names = list(EQ_PRESETS.keys())
        if self.eq_preset in names:
            nxt = (names.index(self.eq_preset) + 1) % len(names)
        else:
            nxt = 0
        self.set_eq_preset(names[nxt])
        return names[nxt]

    def play(self) -> None:
        if not self.current:
            raise PlayerError("Nothing is queued")
        video_id = str(self.current.get("videoId") or "")
        # _mpv_idle is the part that is easy to leave out: several paths stop
        # playback without clearing _loaded_video_id — the end of the queue
        # most of all — and then this fast path unpauses an mpv that has no
        # file open, which looks exactly like the play button doing nothing.
        if not self.mpv.running or self._loaded_video_id != video_id or self._mpv_idle:
            # This path reloads from scratch, which always starts at 0 — fine
            # for a genuinely different track, but if mpv only went idle
            # because a paused stream's signed URL went stale, we were still
            # on this same track and shouldn't lose the position it was
            # paused at.
            if self._loaded_video_id == video_id and self.position_ms > 0:
                self.set_resume_position(self.position_ms)
            self._play_current(start=True)
            self._apply_resume_position()
            return
        self.ensure_started()
        self._restore_volume()
        self.mpv.command(["set_property", "pause", False])
        self.playing = True
        self.note_activity()
        self._apply_resume_position()
        self.on_change()

    def set_resume_position(self, position_ms: int) -> None:
        """Where the next play() should pick up from. Used to hand the
        playhead back after the video window has been driving it.

        Also moves the reported position straight away: nothing is playing at
        this point, so no time-pos events are arriving to correct it, and the
        UI would otherwise show the pre-video timestamp until you hit play.
        """
        self._resume_position_ms = max(0, int(position_ms or 0))
        if not self.playing:
            self.position_ms = self._resume_position_ms

    def _apply_resume_position(self) -> None:
        resume_at = int(self._resume_position_ms or 0)
        self._resume_position_ms = 0
        if resume_at <= 0:
            return
        try:
            self.seek(resume_at)
        except Exception:
            self.position_ms = resume_at

    def pause(self) -> None:
        if not self.mpv.running:
            return
        self.mpv.command(["set_property", "pause", True])
        # Pausing during a tail fade would otherwise resume at near-silence.
        self._restore_volume()
        self.playing = False
        self.note_activity()
        self.on_change()

    def toggle(self) -> None:
        if self.playing:
            self.pause()
        else:
            self.play()

    def stop(self) -> None:
        if self.mpv.running:
            try:
                self.mpv.command(["stop"])
            except Exception:
                pass
        self.playing = False
        self.position_ms = 0
        self._loaded_video_id = ""
        self._restore_volume()
        self.note_activity()
        self.on_change()

    def next(self) -> None:
        self.note_activity()
        if self._advance():
            self._play_current(start=True)
        else:
            self.playing = False
            self.on_change()

    def previous(self) -> None:
        self.note_activity()
        if self.position_ms > 3000 and self.current:
            self.seek(0)
            return
        if self.index > 0:
            self.index -= 1
            self._play_current(start=True)
        elif self.repeat == "context" and self.queue:
            self.index = len(self.queue) - 1
            self._play_current(start=True)
        else:
            self.seek(0)

    def seek(self, position_ms: int) -> None:
        if not self.mpv.running:
            return
        seconds = max(0, int(position_ms or 0)) / 1000.0
        self.mpv.command(["seek", seconds, "absolute"])
        self.position_ms = int(seconds * 1000)
        # Seeking back out of the tail window has to re-arm the tail fade and
        # undo a fade that already ran.
        self._restore_volume()
        self.note_activity()
        self.on_change()

    def set_volume(self, volume: int) -> None:
        volume = max(0, min(100, int(volume)))
        self.volume = volume
        self.muted = volume <= 0
        if volume > 0:
            self.volume_before_mute = volume
        # An explicit volume change wins over an in-flight fade.
        self._next_fade_generation()
        self._fading = False
        self._faded_out = False
        if self.mpv.running:
            self.mpv.command(["set_property", "volume", volume])
        self.note_activity()
        self.on_change()

    def set_shuffle(self, value: bool) -> None:
        self.shuffle = bool(value)
        self.note_activity()
        self.on_change()

    def set_repeat(self, mode: str) -> None:
        if mode not in ("off", "context", "track"):
            mode = "off"
        self.repeat = mode
        self.note_activity()
        self.on_change()

    def cycle_repeat(self) -> str:
        nxt = {"off": "context", "context": "track", "track": "off"}[self.repeat]
        self.set_repeat(nxt)
        return nxt

    def note_activity(self) -> None:
        self.last_activity = time.time()

    def _upcoming_video_id(self) -> str:
        nxt = self.index + 1
        if 0 <= nxt < len(self.queue):
            return str(self.queue[nxt].get("videoId") or "")
        return ""

    # ------------------------------------------------------------ fading

    def set_crossfade_ms(self, value: int) -> None:
        self.crossfade_ms = max(0, min(MAX_CROSSFADE_MS, int(value or 0)))
        if self.crossfade_ms == 0:
            self._restore_volume()

    def _fade_generation_now(self) -> int:
        with self._fade_lock:
            return self._fade_generation

    def _next_fade_generation(self) -> int:
        """Invalidate any in-flight ramp and claim the next generation."""
        with self._fade_lock:
            self._fade_generation += 1
            return self._fade_generation

    def _target_volume(self) -> float:
        if self.muted:
            return 0.0
        return float(max(0, min(100, self.volume)))

    def _set_output_volume(self, level: float) -> bool:
        if not self.mpv.running:
            return False
        try:
            self.mpv.command(
                ["set_property", "volume", round(max(0.0, min(100.0, level)), 1)])
            return True
        except Exception:
            return False

    def _ramp_volume(self, start: float, end: float | None,
                     duration_ms: int, generation: int) -> None:
        """Slide mpv's volume from `start` to `end` over `duration_ms`.

        `end=None` tracks the user's current volume each step, so moving the
        slider mid fade-in lands on the new value instead of the old one.
        """
        steps = max(1, int(max(0, int(duration_ms)) / FADE_STEP_MS))
        for step in range(1, steps + 1):
            if self._stop.is_set() or self._fade_generation_now() != generation:
                return
            target = self._target_volume() if end is None else float(end)
            level = float(start) + (target - float(start)) * (step / steps)
            if not self._set_output_volume(level):
                return
            if step < steps:
                time.sleep(FADE_STEP_MS / 1000.0)

    def _run_ramp(self, start: float, end: float | None,
                  duration_ms: int, generation: int) -> None:
        self._fading = True
        try:
            self._ramp_volume(start, end, duration_ms, generation)
        finally:
            # mpv reports our own writes back asynchronously, so the last few
            # `volume` events land after the ramp has finished. Hold the guard
            # across that tail or the observer adopts a fade level as the
            # user's volume setting.
            time.sleep(FADE_SETTLE_MS / 1000.0)
            if self._fade_generation_now() == generation:
                self._fading = False

    def _begin_fade_out(self) -> threading.Thread | None:
        """Fade down on a worker thread so the caller can resolve the next
        stream URL while the fade runs, instead of paying for both in series."""
        if self._faded_out or self.crossfade_ms <= 0:
            return None
        if not self.mpv.running or self.muted or self.volume <= 0:
            return None
        generation = self._next_fade_generation()
        start = self._target_volume()
        # Raise the guard here, not inside the worker: the observer must never
        # see one of our own volume writes while it is still free to believe it.
        self._fading = True

        def work() -> None:
            self._run_ramp(start, 0.0, self.crossfade_ms, generation)
            if self._fade_generation_now() == generation:
                self._faded_out = True

        thread = threading.Thread(target=work, daemon=True)
        thread.start()
        return thread

    def _fade_in(self) -> None:
        if self.crossfade_ms <= 0 or not self.mpv.running:
            self._restore_volume()
            return
        generation = self._next_fade_generation()
        # Order matters: the guard has to be up before the drop to silence.
        # Clearing _faded_out first and writing 0 second left a window where
        # the observer adopted 0 as the user's volume, and the fade-in then
        # ramped to that new "target" — silence, permanently.
        self._fading = True
        self._faded_out = False
        self._set_output_volume(0.0)
        threading.Thread(
            target=self._run_ramp,
            args=(0.0, None, self.crossfade_ms, generation),
            daemon=True,
        ).start()

    def repair_volume_setting(self) -> None:
        """Undo a volume setting that collapsed to zero without the user ever
        asking for it — fall back to the pre-mute level rather than leaving
        the player permanently silent."""
        if self.volume <= 0 and not self.muted:
            self.volume = max(1, int(self.volume_before_mute or 80))

    def _restore_volume(self) -> None:
        """Cancel any fade and put mpv back at the user's volume. Every path
        that leaves playback stopped, paused or seeked has to call this, or
        the output stays stuck wherever the fade left it."""
        self._next_fade_generation()
        self._fading = False
        self._faded_out = False
        self._tail_fade_for = ""
        self.repair_volume_setting()
        self._set_output_volume(self._target_volume())

    def _maybe_tail_fade(self) -> None:
        """Start the fade-out while the track is still playing its last
        `crossfade_ms`, so the dip is hidden inside the outgoing track."""
        if self.crossfade_ms <= 0 or not self.playing or self._faded_out:
            return
        video_id = self._loaded_video_id
        if not video_id or self._tail_fade_for == video_id:
            return
        if self.duration_ms <= self.crossfade_ms:
            return
        if self.duration_ms - self.position_ms > self.crossfade_ms:
            return
        self._tail_fade_for = video_id
        self._begin_fade_out()

    def _publish_title(self, item: dict | None = None) -> None:
        title = mpris_title(item if item is not None else self.current)
        self._display_title = title
        if not self.mpv.running:
            return
        try:
            self.mpv.command(["set_property", "force-media-title", title])
        except Exception:
            pass

    def _play_current(self, start: bool = True) -> None:
        item = self.current
        if not item:
            raise PlayerError("Nothing is queued")
        video_id = str(item.get("videoId") or "")
        self.error = ""
        self.ensure_started()
        self._publish_title(item)
        self.resolving = True
        self.on_change()
        # Only a track *change* fades — the very first load has nothing to
        # fade out of. The tail fade may already have taken the volume down,
        # in which case _begin_fade_out is a no-op and this returns None.
        fader = (self._begin_fade_out()
                 if (start and self.playing and self._loaded_video_id) else None)
        try:
            url = self.resolver.resolve(video_id)
            if fader is not None:
                fader.join(timeout=(self.crossfade_ms / 1000.0) + 1.0)
            self._publish_title(item)
            if start and self.crossfade_ms > 0:
                # Load at silence so the new track cannot burst in at full
                # volume in the gap before the fade-in thread gets scheduled.
                self._set_output_volume(0.0)
            self.mpv.command(loadfile_command(url, item))
            self.mpv.command(["set_property", "pause", not start])
            self.playing = start
            self.position_ms = 0
            self.duration_ms = int(item.get("durationMs") or 0)
            self._loaded_video_id = video_id
            self._load_guard_until = time.time() + 2.0
            self._mpv_idle = False
            self._tail_fade_for = ""
            if start:
                self._fade_in()
            else:
                self._restore_volume()
        except Exception as exc:
            self._restore_volume()
            self.error = playback_error_message(str(exc))
            self.playing = False
            self.resolving = False
            self.on_change()
            raise PlayerError(self.error) from exc
        finally:
            self.resolving = False
        nxt = self._upcoming_video_id()
        if nxt:
            self.resolver.prefetch(nxt)
        self._generation += 1
        try:
            self.on_played(item)
        except Exception:
            pass
        self.on_change()

    def _advance(self) -> bool:
        if self._sleep_after == "track":
            self._sleep_after = ""
            return False
        if self.repeat == "track" and self.current:
            return True
        if self.shuffle and len(self.queue) > 1:
            import random
            choices = [i for i in range(len(self.queue)) if i != self.index]
            if not choices:
                return False
            self.index = random.choice(choices)
            return True
        if self.index + 1 < len(self.queue):
            self.index += 1
            return True
        if self.repeat == "context" and self.queue:
            self.index = 0
            return True
        return False

    def _loop(self) -> None:
        while not self._stop.is_set():
            try:
                events = self.mpv.poll_events(0.25)
            except Exception:
                time.sleep(0.2)
                continue
            changed = False
            eof = False
            idle = False
            for event in events:
                name = event.get("event")
                if name == "property-change":
                    prop = event.get("name")
                    value = event.get("data")
                    if prop == "pause":
                        self.playing = value is False
                        changed = True
                    elif prop == "time-pos" and isinstance(value, (int, float)):
                        self.position_ms = int(max(0, value) * 1000)
                        self._maybe_tail_fade()
                    elif prop == "duration" and isinstance(value, (int, float)) and value > 0:
                        self.duration_ms = int(value * 1000)
                        changed = True
                    elif prop == "volume" and isinstance(value, (int, float)):
                        # Our own fade writes drive this property. Adopting
                        # them would drag the user's volume setting to zero.
                        if not (self._fading or self._faded_out):
                            self.volume = int(max(0, min(100, value)))
                    elif prop == "eof-reached" and value is True:
                        eof = True
                    elif prop == "idle-active":
                        # Acted on after the loop: an end-of-track idle must
                        # not pre-empt the auto-advance below.
                        idle = value is True
                        self._mpv_idle = idle
                    elif prop == "media-title":
                        shown = str(value or "")
                        if self._display_title and (
                            looks_like_stream_title(shown) or shown != self._display_title
                        ):
                            self._publish_title()
                elif name in ("file-loaded", "playback-restart"):
                    self._publish_title()
                    # playback-restart fires whenever mpv re-inits playback —
                    # including when the audio filter chain is rebuilt (an EQ
                    # change) and when a file is loaded paused. It does NOT mean
                    # audio started, so don't infer `playing` from it or the
                    # play/pause label flips with nothing behind it. The observed
                    # `pause` property above is the authoritative source.
                    if name == "playback-restart":
                        self.error = ""
                        changed = True
                elif name == "end-file":
                    reason = str(event.get("reason") or "")
                    if reason in ("eof", "0"):
                        eof = True
                    elif reason == "error":
                        if time.time() < self._eq_guard_until:
                            continue
                        self.playing = False
                        self.error = self.error or "Playback failed"
                        changed = True
            if eof and self.playing:
                if self._advance():
                    try:
                        self._play_current(start=True)
                    except Exception:
                        self._restore_volume()
                        self.playing = False
                        changed = True
                else:
                    # End of queue after a tail fade — put the volume back or
                    # the next manual play starts silent.
                    self._restore_volume()
                    self.playing = False
                    changed = True
            elif idle and self.playing and time.time() >= self._load_guard_until:
                # mpv fell back to idle without an end-file this loop acts on
                # — a "stop" reason, or a load that never produced a file.
                # Nothing is loaded any more, so continuing to report
                # `playing` leaves the UI showing a pause button, a timer
                # frozen at 0:00 and a waveform dancing over silence.
                #
                # Clearing the loaded id matters just as much: play() skips
                # straight to unpausing when the requested track is already
                # loaded, so a stale id meant every press of play unpaused an
                # idle mpv and did nothing at all. Forgetting it sends the
                # next play() down the reload path instead.
                self._restore_volume()
                self._loaded_video_id = ""
                self.playing = False
                self.position_ms = 0
                changed = True
            if changed:
                self.on_change()
