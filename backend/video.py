"""A real mpv video window for the track that is playing.

This deliberately does NOT reuse the audio deck's pre-resolved stream URL.
The audio deck asks yt-dlp for `bestaudio` and drives a windowless mpv with
scripts disabled; a watchable video needs muxed video+audio, subtitle tracks,
chapters and the on-screen controller. All of that is exactly what mpv's own
built-in ytdl_hook produces when you hand it a watch URL, so that is what we
do here — one mpv invocation, no second resolver of our own.

Audio hand-off: the caller pauses the audio deck before opening this window
and resumes it at `position_ms` when the window closes, so there is never
more than one stream making sound and the two never drift apart.
"""

from __future__ import annotations

import json
import os
import select
import shutil
import socket
import subprocess
import threading
import time
from pathlib import Path
from typing import Any, Callable

DEFAULT_SUB_LANG = "en"
DEFAULT_MAX_HEIGHT = 1080
# Stable Wayland app-id so compositor rules can target this window. mpv's
# default is plain "mpv", which would match every other mpv on the system.
APP_ID = "ytwidget-video"
DEFAULT_AUTOFIT_PERCENT = 70
# What YouTube's own speed menu offers.
SPEEDS = (0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0)
# YouTube stream URLs stay valid around six hours; expire well before that so
# a prewarmed entry is never handed to mpv just as it goes stale.
RESOLVE_TTL_SECONDS = 3 * 60 * 60
# Poll cadence for the window's own time-pos. Only used to know where to put
# the audio deck when the window closes, so it does not need to be tight.
WATCH_INTERVAL = 0.25


class VideoError(RuntimeError):
    pass


_gpu_cache: dict[str, str] = {}
_gpu_lock = threading.Lock()


def integrated_gpu_name() -> str:
    """Name of the integrated Vulkan device, or "" if there isn't one.

    libplacebo prefers the discrete GPU when a machine has both. For video
    playback that is the wrong default on a laptop: the iGPU decodes the same
    codecs in hardware, starts up measurably faster and more consistently
    (mpv itself logs "creating vulkan device (slow!)" on the dGPU), and it
    avoids spinning up a card that is otherwise powered down.
    """
    with _gpu_lock:
        if "name" in _gpu_cache:
            return _gpu_cache["name"]
    name = ""
    binary = shutil.which("vulkaninfo")
    if binary:
        try:
            out = subprocess.run([binary, "--summary"], capture_output=True,
                                 text=True, timeout=10, check=False).stdout
            pending_type = ""
            for line in out.splitlines():
                stripped = line.strip()
                if stripped.startswith("deviceType"):
                    pending_type = stripped.split("=", 1)[-1].strip()
                elif stripped.startswith("deviceName"):
                    if "INTEGRATED" in pending_type:
                        name = stripped.split("=", 1)[-1].strip()
                        break
                    pending_type = ""
        except Exception:
            name = ""
    with _gpu_lock:
        _gpu_cache["name"] = name
    return name


def watch_url(video_id: str) -> str:
    return f"https://www.youtube.com/watch?v={video_id}"


def ytdl_format(max_height: int) -> str:
    height = max(240, min(2160, int(max_height or DEFAULT_MAX_HEIGHT)))
    # Prefer a capped-height muxed pair, but never fail outright: the trailing
    # /best keeps oddball or low-res uploads playable.
    return (
        f"bestvideo[height<=?{height}]+bestaudio/"
        f"best[height<=?{height}]/best"
    )


def mpv_escape(value: str) -> str:
    """Wrap a value for mpv's key=value option lists.

    Those lists are comma-separated, so a value that itself contains a comma
    (two subtitle languages, say) makes mpv reject the whole option with
    "Error parsing option ytdl-raw-options" and exit — the window never opens.
    mpv's own escape for this is a %<bytelength>% prefix.
    """
    text = str(value or "")
    if "," not in text and ":" not in text:
        return text
    return f"%{len(text.encode('utf-8'))}%{text}"


def subtitle_options(lang: str) -> list[str]:
    """Ask yt-dlp for real and auto-generated captions and preselect one.

    mpv only ever sees the subtitle tracks yt-dlp reports, and yt-dlp only
    reports them when explicitly asked — without write-subs/write-auto-subs
    the video arrives with no subtitle tracks at all.
    """
    code = (str(lang or "").strip() or DEFAULT_SUB_LANG).replace(",", "")
    wanted = [code] if code == DEFAULT_SUB_LANG else [code, DEFAULT_SUB_LANG]
    langs = ",".join(f"{item}.*" for item in wanted)
    return [
        "--ytdl-raw-options=write-subs=,write-auto-subs=,"
        f"sub-langs={mpv_escape(langs)}",
        f"--slang={','.join(wanted)}",
        "--sid=auto",
    ]


def base_options(binary: str, ipc_path: Path, *, title: str, volume: int,
                 speed: float, autofit_percent: int,
                 gpu: str = "integrated") -> list[str]:
    fit = max(20, min(100, int(autofit_percent or DEFAULT_AUTOFIT_PERCENT)))
    extra: list[str] = []
    if str(gpu or "").lower() == "integrated":
        device = integrated_gpu_name()
        if device:
            extra.append(f"--vulkan-device={device}")
    # argv[0] must stay the binary; options follow it.
    return [binary] + extra + [
        "--no-config",
        "--force-window=immediate",
        "--hwdec=auto-safe",
        "--osc=yes",
        "--input-default-bindings=yes",
        "--input-vo-keyboard=yes",
        "--keep-open=no",
        "--cache=yes",
        f"--volume={max(0, min(100, int(volume)))}",
        f"--speed={max(0.25, min(4.0, float(speed or 1.0)))}",
        # Shrink to fit the screen but never blow a small video up.
        f"--autofit-larger={fit}%x{fit}%",
        f"--title={title or 'YT Widget'}",
        f"--wayland-app-id={APP_ID}",
        "--audio-client-name=ytwidget-video",
        f"--input-ipc-server={ipc_path}",
        "--msg-level=cplayer=info,ffmpeg=error",
    ]


def direct_command_line(binary: str, resolved: dict, height: int, ipc_path: Path,
                        *, title: str, start_ms: int, volume: int, speed: float,
                        sub_lang: str, autofit_percent: int,
                        gpu: str = "integrated") -> list[str]:
    """Launch straight from prewarmed URLs, skipping mpv's ytdl_hook entirely.

    This is the fast path: the ~3s extraction has already happened in the
    background while the audio deck was playing.
    """
    stream = (resolved.get("streams") or {}).get(height) or {}
    video_url = stream.get("video")
    if not video_url:
        raise VideoError("That quality is not available")
    command = base_options(binary, ipc_path, title=title, volume=volume,
                           speed=speed, autofit_percent=autofit_percent, gpu=gpu)
    command.append("--ytdl=no")
    if stream.get("audio"):
        command.append(f"--audio-file={stream['audio']}")
    # Subtitles are deliberately NOT passed here. --sub-file makes mpv fetch
    # and parse the caption file before it will start playing, which measured
    # at ~1.3s of pure dead time on every open. They are attached over IPC
    # once playback is running instead (see _attach_subtitles).
    # Without ytdl there is no metadata, so name the window ourselves.
    command.append(f"--force-media-title={title or 'YT Widget'}")
    start_seconds = max(0, int(start_ms or 0)) / 1000.0
    if start_seconds > 0:
        command.append(f"--start={start_seconds:.3f}")
    command.append(video_url)
    return command


def command_line(binary: str, url: str, ipc_path: Path, *, title: str,
                 start_ms: int, volume: int, sub_lang: str,
                 max_height: int, speed: float = 1.0,
                 autofit_percent: int = DEFAULT_AUTOFIT_PERCENT,
                 gpu: str = "integrated") -> list[str]:
    start_seconds = max(0, int(start_ms or 0)) / 1000.0
    prefix: list[str] = []
    if str(gpu or "").lower() == "integrated":
        device = integrated_gpu_name()
        if device:
            prefix.append(f"--vulkan-device={device}")
    command = [
        binary,
        "--no-config",
        # Show the window immediately rather than after the network round
        # trip, so clicking the button feels like it did something.
        "--force-window=immediate",
        "--ytdl=yes",
        f"--ytdl-format={ytdl_format(max_height)}",
        # Hardware decoding matters here in a way it never did for the audio
        # deck: software-decoding 1080p is the difference between idle and a
        # pegged core. auto-safe falls back to software if the driver balks.
        "--hwdec=auto-safe",
        "--osc=yes",
        "--input-default-bindings=yes",
        "--input-vo-keyboard=yes",
        "--keep-open=no",
        "--cache=yes",
        f"--volume={max(0, min(100, int(volume)))}",
        f"--title={title or 'YT Widget'}",
        f"--wayland-app-id={APP_ID}",
        f"--speed={max(0.25, min(4.0, float(speed or 1.0)))}",
        f"--autofit-larger={max(20, min(100, int(autofit_percent)))}%"
        f"x{max(20, min(100, int(autofit_percent)))}%",
        "--audio-client-name=ytwidget-video",
        f"--input-ipc-server={ipc_path}",
        "--msg-level=cplayer=info,ffmpeg=error",
    ]
    if start_seconds > 0:
        command.append(f"--start={start_seconds:.3f}")
    command.extend(subtitle_options(sub_lang))
    command.append(url)
    # mpv takes options before the URL; the device pin has to lead.
    return [command[0]] + prefix + command[1:]


class VideoResolver:
    """Resolve one video into a per-quality URL ladder, once.

    A single `yt-dlp -J` returns the URL of *every* format, so one call is
    enough to both start playback immediately and switch quality afterwards
    without going back to the network. Prewarming this while the audio deck
    plays is what makes the video button feel instant instead of costing the
    ~3s extraction at click time.
    """

    def __init__(self, sub_lang: str = DEFAULT_SUB_LANG):
        self.sub_lang = sub_lang
        self._cache: dict[str, tuple[float, dict[str, Any]]] = {}
        self._lock = threading.Lock()
        self._inflight: set[str] = set()

    def set_sub_lang(self, lang: str) -> None:
        lang = str(lang or "").strip() or DEFAULT_SUB_LANG
        if lang == self.sub_lang:
            return
        self.sub_lang = lang
        # Cached entries carry subtitle URLs for the old language only.
        with self._lock:
            self._cache.clear()

    def cached(self, video_id: str) -> dict[str, Any] | None:
        with self._lock:
            entry = self._cache.get(str(video_id or ""))
            if entry and entry[0] > time.time():
                return entry[1]
            return None

    def resolve(self, video_id: str) -> dict[str, Any]:
        video_id = str(video_id or "").strip()
        if not video_id:
            raise VideoError("Missing video id")
        hit = self.cached(video_id)
        if hit:
            return hit
        resolved = self._extract(video_id)
        with self._lock:
            self._cache[video_id] = (time.time() + RESOLVE_TTL_SECONDS, resolved)
        return resolved

    def prefetch(self, video_id: str) -> None:
        video_id = str(video_id or "").strip()
        if not video_id or self.cached(video_id):
            return
        with self._lock:
            if video_id in self._inflight:
                return
            self._inflight.add(video_id)

        def worker() -> None:
            try:
                self.resolve(video_id)
            except Exception:
                pass
            finally:
                with self._lock:
                    self._inflight.discard(video_id)

        threading.Thread(target=worker, daemon=True).start()

    def _extract(self, video_id: str) -> dict[str, Any]:
        binary = shutil.which("yt-dlp")
        if not binary:
            raise VideoError("yt-dlp is not installed")
        # No player_client override: the android client exposes a single 360p
        # muxed format and no audio-only stream, which would silently cap the
        # video at 360p. The default clients return the full ladder.
        command = [
            binary, "--no-warnings", "--no-progress", "-J", "--no-playlist",
            "--write-subs", "--write-auto-subs",
            "--sub-langs", f"{self.sub_lang}.*,{DEFAULT_SUB_LANG}.*",
            "--", watch_url(video_id),
        ]
        try:
            result = subprocess.run(command, capture_output=True, text=True,
                                    timeout=90, check=False)
        except subprocess.TimeoutExpired as exc:
            raise VideoError("YouTube took too long to answer") from exc
        if result.returncode != 0 or not result.stdout.strip():
            detail = (result.stderr or "").strip().splitlines()
            message = detail[-1] if detail else "Could not load that video"
            if message.lower().startswith("error:"):
                message = message[6:].strip()
            raise VideoError(message[:200] or "Could not load that video")
        try:
            info = json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            raise VideoError("Could not read that video's details") from exc
        return self._build(video_id, info)

    @staticmethod
    def _build(video_id: str, info: dict[str, Any]) -> dict[str, Any]:
        formats = [f for f in (info.get("formats") or []) if isinstance(f, dict)]

        audio_only = [f for f in formats
                      if f.get("vcodec") in (None, "none") and f.get("url")
                      and f.get("acodec") not in (None, "none")]
        audio_url = ""
        if audio_only:
            # Big channels now ship AI-dubbed audio tracks alongside the real
            # one, all at the same bitrate. Sorting on bitrate alone picks
            # whichever dub happens to come first — which is how a Marques
            # Brownlee video ended up narrated in Japanese. yt-dlp flags the
            # original track with language_preference 10 against -1 for dubs.
            original = str(info.get("language") or "").lower()

            def audio_rank(fmt: dict[str, Any]) -> tuple:
                lang = str(fmt.get("language") or "").lower()
                return (
                    int(fmt.get("language_preference") or 0),
                    1 if (original and lang == original) else 0,
                    float(fmt.get("abr") or 0),
                )

            audio_url = str(max(audio_only, key=audio_rank)["url"])

        streams: dict[int, dict[str, Any]] = {}
        for fmt in formats:
            raw_height = fmt.get("height")
            url = fmt.get("url")
            if not url or not raw_height or fmt.get("vcodec") in (None, "none"):
                continue
            # Quality is named after the short side, the way YouTube labels it.
            # Keying on raw height would call a 1080x1920 vertical video "1920p"
            # and pick the wrong rung whenever the user asks for 1080p.
            width = fmt.get("width")
            height = int(min(int(width), int(raw_height))) if width else int(raw_height)
            if height < 144:
                continue
            muxed = fmt.get("acodec") not in (None, "none")
            rank = codec_rank(str(fmt.get("vcodec") or ""))
            rate = float(fmt.get("tbr") or 0)
            current = streams.get(height)
            # Rank first, bitrate only to break ties within a codec. Picking
            # by bitrate alone selects the *least* efficient encode: at 1080p
            # that is avc1 at ~4700kbps instead of av01 at ~1270kbps for the
            # same picture — nearly 4x the bytes, and a visibly slower start.
            if current is None or (rank, -rate) < (current["_rank"], -current["_tbr"]):
                streams[height] = {
                    "video": str(url),
                    # A muxed rendition already carries its own audio; pairing
                    # it with a separate track would play both at once.
                    "audio": "" if muxed else audio_url,
                    "_rank": rank,
                    "_tbr": rate,
                }
        for entry in streams.values():
            entry.pop("_rank", None)
            entry.pop("_tbr", None)

        subs: dict[str, str] = {}
        for lang, tracks in (info.get("requested_subtitles") or {}).items():
            if isinstance(tracks, dict) and tracks.get("url"):
                subs[str(lang)] = str(tracks["url"])

        duration = info.get("duration")
        return {
            "videoId": video_id,
            "title": str(info.get("title") or ""),
            "heights": sorted(streams.keys(), reverse=True),
            "streams": streams,
            "subs": subs,
            "durationMs": int(float(duration) * 1000) if duration else 0,
        }


# yt-dlp's own default ordering prefers the more efficient codec at a given
# resolution. Mirror it so the prewarmed path and mpv's ytdl_hook path choose
# the same rendition — otherwise playback quality and bandwidth would depend
# on whether the cache happened to be warm.
CODEC_PREFERENCE = ("av01", "vp9", "vp09", "avc1", "h264")


def codec_rank(vcodec: str) -> int:
    name = str(vcodec or "").lower()
    for index, prefix in enumerate(CODEC_PREFERENCE):
        if name.startswith(prefix):
            return index
    return len(CODEC_PREFERENCE)


def pick_subtitle(subs: dict, sub_lang: str) -> str:
    if not subs:
        return ""
    return (subs.get(sub_lang) or subs.get(DEFAULT_SUB_LANG)
            or next(iter(subs.values())) or "")


def pick_height(heights: list[int], wanted: int) -> int:
    """Closest available height at or below `wanted`, else the smallest."""
    if not heights:
        return 0
    below = [h for h in heights if h <= wanted]
    return max(below) if below else min(heights)


class VideoWindow:
    """Owns at most one mpv video window and reports where it stopped."""

    def __init__(self, runtime_dir: Path,
                 on_closed: Callable[[str, int], None] | None = None,
                 on_ready: Callable[[str], None] | None = None,
                 on_pause_changed: Callable[[], None] | None = None):
        self.ipc_path = Path(runtime_dir) / "mpv-video.sock"
        self.on_closed = on_closed or (lambda _video_id, _position_ms: None)
        # Fires when the window actually has playback running, which is
        # several seconds after launch: opening two network streams and
        # spinning up the decoder dominates, not the metadata lookup.
        self.on_ready = on_ready or (lambda _video_id: None)
        # Fires whenever mpv's own pause state flips, whether from our
        # commands or the user hitting space/clicking inside the window
        # directly — that's the only way this ever finds out about the
        # latter, since mpv owns its own play/pause state once open.
        self.on_pause_changed = on_pause_changed or (lambda: None)
        self.process: subprocess.Popen | None = None
        self.video_id = ""
        self.position_ms = 0
        self.paused = False
        self.speed = 1.0
        self.height = 0
        self.heights: list[int] = []
        self.title = ""
        self.sub_lang = DEFAULT_SUB_LANG
        self.autofit_percent = DEFAULT_AUTOFIT_PERCENT
        self.gpu = "integrated"
        self._resolved: dict[str, Any] | None = None
        self._lock = threading.Lock()
        self._sock_lock = threading.Lock()
        self._sock: socket.socket | None = None
        self._next_request = 1
        self._announced_ready = False
        self._sub_attached = True
        self._watcher: threading.Thread | None = None

    @property
    def active(self) -> bool:
        return self.process is not None and self.process.poll() is None

    def open(self, video_id: str, *, title: str = "", start_ms: int = 0,
             volume: int = 80, sub_lang: str = DEFAULT_SUB_LANG,
             max_height: int = DEFAULT_MAX_HEIGHT, speed: float = 1.0,
             autofit_percent: int = DEFAULT_AUTOFIT_PERCENT,
             resolved: dict[str, Any] | None = None,
             gpu: str = "integrated") -> None:
        video_id = str(video_id or "").strip()
        if not video_id:
            raise VideoError("No video to show")
        binary = shutil.which("mpv")
        if not binary:
            raise VideoError("mpv is not installed")
        self.sub_lang = sub_lang or DEFAULT_SUB_LANG
        self.autofit_percent = autofit_percent
        self.gpu = gpu or "integrated"
        self.speed = float(speed or 1.0)
        self._resolved = resolved
        self.heights = list((resolved or {}).get("heights") or [])
        self.height = pick_height(self.heights, max_height) if self.heights else 0
        with self._lock:
            if self.active:
                self._terminate_locked()
            self.ipc_path.parent.mkdir(parents=True, exist_ok=True)
            if self.ipc_path.exists():
                try:
                    self.ipc_path.unlink()
                except OSError:
                    pass
            self.title = title or "YT Widget"
            if resolved and self.height:
                # Prewarmed: mpv gets final URLs and never spawns yt-dlp.
                command = direct_command_line(
                    binary, resolved, self.height, self.ipc_path,
                    title=self.title, start_ms=start_ms, volume=volume,
                    speed=self.speed, sub_lang=self.sub_lang,
                    autofit_percent=autofit_percent, gpu=self.gpu,
                )
            else:
                # Cold: fall back to mpv's own ytdl_hook, which costs the
                # extraction up front but always works.
                command = command_line(
                    binary, watch_url(video_id), self.ipc_path,
                    title=self.title, start_ms=start_ms,
                    volume=volume, sub_lang=self.sub_lang,
                    max_height=max_height, speed=self.speed,
                    autofit_percent=autofit_percent, gpu=self.gpu,
                )
            log_path = self.ipc_path.parent / "mpv-video.log"
            stderr = log_path.open("ab")
            try:
                # The audio deck's mpv_env() strips WAYLAND_DISPLAY on purpose
                # so that deck can never open a window. This one must, so it
                # inherits the session environment untouched.
                self.process = subprocess.Popen(
                    command,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=stderr,
                    env=dict(os.environ),
                    start_new_session=True,
                )
            except OSError as exc:
                raise VideoError(f"Could not start the video window: {exc}") from exc
            finally:
                stderr.close()
            self.video_id = video_id
            self.position_ms = max(0, int(start_ms or 0))
            self.paused = False
            self._announced_ready = False
            self._sub_attached = not bool(
                pick_subtitle((resolved or {}).get("subs") or {}, self.sub_lang))
            self._watcher = threading.Thread(target=self._watch, daemon=True)
            self._watcher.start()

    def close(self) -> None:
        with self._lock:
            self._terminate_locked()

    def _terminate_locked(self) -> None:
        process = self.process
        if process is None:
            return
        try:
            process.terminate()
            process.wait(timeout=3)
        except Exception:
            try:
                process.kill()
            except Exception:
                pass

    def shutdown(self) -> None:
        self.close()

    # ------------------------------------------------------------ commands

    def command(self, args: list[Any]) -> bool:
        """Send one command to the running window over its IPC socket."""
        with self._sock_lock:
            sock = self._sock
            if sock is None:
                return False
            payload = json.dumps({"command": args, "request_id": self._next_request})
            self._next_request += 1
            try:
                sock.sendall((payload + "\n").encode("utf-8"))
                return True
            except OSError:
                return False

    def _attach_subtitles(self) -> None:
        """Add the caption track after playback has started.

        Handing mpv a --sub-file up front delays the first frame by the time
        it takes to fetch that file; doing it here costs nothing visible
        beyond captions appearing a moment after the picture.
        """
        if self._sub_attached or not self._resolved:
            return
        url = pick_subtitle(self._resolved.get("subs") or {}, self.sub_lang)
        if not url:
            self._sub_attached = True
            return
        if self.command(["sub-add", url, "select"]):
            self._sub_attached = True

    def seek(self, position_ms: int) -> bool:
        return self.command(
            ["seek", max(0, int(position_ms or 0)) / 1000.0, "absolute"])

    def play(self) -> bool:
        return self.command(["set_property", "pause", False])

    def pause(self) -> bool:
        return self.command(["set_property", "pause", True])

    def toggle(self) -> bool:
        return self.command(["cycle", "pause"])

    def set_speed(self, speed: float) -> float:
        """Playback rate. Applies live — no reload, no re-resolve."""
        value = max(0.25, min(4.0, float(speed or 1.0)))
        self.speed = value
        if self.active:
            self.command(["set_property", "speed", value])
        return value

    def set_quality(self, height: int) -> int:
        """Switch rendition. Reloads in place at the current position, which
        is cheap because every quality's URL came from the same resolve."""
        if not self.active:
            raise VideoError("No video window is open")
        if not self._resolved or not self.heights:
            raise VideoError("Quality switching needs a prepared video")
        target = pick_height(self.heights, int(height or 0))
        stream = (self._resolved.get("streams") or {}).get(target) or {}
        video_url = stream.get("video")
        if not video_url:
            raise VideoError("That quality is not available")
        options: dict[str, Any] = {
            "start": max(0, int(self.position_ms)) / 1000.0,
            "force-media-title": self.title,
        }
        if stream.get("audio"):
            options["audio-file"] = stream["audio"]
        if not self.command(["loadfile", video_url, "replace", -1, options]):
            raise VideoError("Could not reach the video window")
        self.height = target
        # The reload drops the external caption track with the old file, so
        # re-arm it; the watcher re-attaches on the next position update.
        self._sub_attached = not bool(
            pick_subtitle(self._resolved.get("subs") or {}, self.sub_lang))
        # speed is a player property, not a per-file one, but re-assert it so
        # a reload can never silently drop back to 1x.
        self.command(["set_property", "speed", self.speed])
        return target

    # ------------------------------------------------------------- watching

    def _connect(self, timeout: float = 6.0) -> socket.socket | None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if not self.active:
                return None
            if self.ipc_path.exists():
                try:
                    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    sock.settimeout(2.0)
                    sock.connect(str(self.ipc_path))
                    sock.setblocking(False)
                    return sock
                except OSError:
                    pass
            time.sleep(0.05)
        return None

    def _watch(self) -> None:
        process = self.process
        video_id = self.video_id
        sock = self._connect()
        if sock is not None:
            try:
                sock.sendall(
                    (json.dumps({"command": ["observe_property", 1, "time-pos"],
                                 "request_id": 1}) + "\n").encode("utf-8"))
                sock.sendall(
                    (json.dumps({"command": ["observe_property", 2, "pause"],
                                 "request_id": 2}) + "\n").encode("utf-8"))
            except OSError:
                sock.close()
                sock = None
        with self._sock_lock:
            self._sock = sock
        buffer = ""
        while process is not None and process.poll() is None:
            if sock is None:
                time.sleep(WATCH_INTERVAL)
                continue
            try:
                ready, _, _ = select.select([sock], [], [], WATCH_INTERVAL)
            except (OSError, ValueError):
                break
            if not ready:
                continue
            try:
                data = sock.recv(65536)
            except BlockingIOError:
                continue
            except OSError:
                break
            if not data:
                break
            buffer += data.decode("utf-8", "replace")
            lines = buffer.split("\n")
            buffer = lines.pop()
            for line in lines:
                line = line.strip()
                if not line:
                    continue
                try:
                    message: Any = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(message, dict):
                    continue
                if message.get("event") == "property-change" \
                        and message.get("name") == "time-pos":
                    value = message.get("data")
                    if isinstance(value, (int, float)) and value >= 0:
                        self.position_ms = int(value * 1000)
                        if not self._sub_attached:
                            self._attach_subtitles()
                        if not self._announced_ready:
                            self._announced_ready = True
                            try:
                                self.on_ready(video_id)
                            except Exception:
                                pass
                elif message.get("event") == "property-change" \
                        and message.get("name") == "pause":
                    value = message.get("data")
                    if isinstance(value, bool) and value != self.paused:
                        self.paused = value
                        try:
                            self.on_pause_changed()
                        except Exception:
                            pass
        with self._sock_lock:
            self._sock = None
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass
        if process is not None:
            try:
                process.wait(timeout=2)
            except Exception:
                pass
        with self._lock:
            if self.process is process:
                self.process = None
        try:
            self.on_closed(video_id, self.position_ms)
        except Exception:
            pass
