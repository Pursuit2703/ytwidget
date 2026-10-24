"""On-disk audio cache keyed by YouTube video id.

A hit means mpv plays a local file and nothing is asked of YouTube. A miss is
filled in the background, one download at a time, from the stream URL the
resolver already obtained, so the cache costs no extra resolve request.
"""

from __future__ import annotations

import os
import re
import threading
import urllib.parse
import urllib.request
from pathlib import Path

from request_log import log_request

VIDEO_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")
MAX_TRACK_BYTES = 60 * 1024 * 1024
DEFAULT_CAP_BYTES = 2 * 1024 ** 3
CHUNK_BYTES = 1024 * 1024
_EXTENSIONS = {"audio/webm": ".webm", "audio/mp4": ".m4a"}


def cache_dir() -> Path:
    # ~/.local/share, not ~/.cache: cleaners and users treat .cache as disposable.
    base = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share"))
    return base / "ytwidget" / "audio"


def lookup(video_id: str, directory: Path | None = None) -> Path | None:
    """Return the saved file for this id, or None. Touches mtime for LRU."""
    if not VIDEO_ID_RE.match(video_id or ""):
        return None
    root = directory or cache_dir()
    try:
        for path in root.glob(f"{video_id}.*"):
            if path.suffix != ".part" and path.stat().st_size > 0:
                os.utime(path)
                return path
    except OSError:
        return None
    return None


def stream_info(url: str) -> tuple[int, str] | None:
    """(content length, extension) from a googlevideo URL, or None if the URL
    is not a plain finite audio stream (live, no length, wrong type)."""
    query = urllib.parse.parse_qs(urllib.parse.urlsplit(url).query)
    try:
        size = int(query.get("clen", [""])[0])
    except ValueError:
        return None
    mime = urllib.parse.unquote(query.get("mime", [""])[0])
    if mime not in _EXTENSIONS or size <= 0 or size > MAX_TRACK_BYTES:
        return None
    return size, _EXTENSIONS[mime]


def evict(directory: Path, cap_bytes: int) -> None:
    """Delete least recently used files until the folder fits the cap."""
    try:
        files = [p for p in directory.iterdir() if p.is_file() and p.suffix != ".part"]
        total = sum(p.stat().st_size for p in files)
        for path in sorted(files, key=lambda p: p.stat().st_mtime):
            if total <= cap_bytes:
                break
            total -= path.stat().st_size
            path.unlink(missing_ok=True)
    except OSError:
        pass


def _download(video_id: str, url: str, size: int, ext: str, directory: Path,
              cap_bytes: int) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    final = directory / f"{video_id}{ext}"
    part = directory / f"{video_id}{ext}.part"
    try:
        with part.open("wb") as handle:
            offset = 0
            while offset < size:
                end = min(offset + CHUNK_BYTES, size) - 1
                request = urllib.request.Request(
                    url, headers={"Range": f"bytes={offset}-{end}"})
                with urllib.request.urlopen(request, timeout=20) as response:
                    data = response.read()
                if not data:
                    raise OSError("empty chunk")
                handle.write(data)
                offset += len(data)
        if part.stat().st_size != size:
            raise OSError("size mismatch")
        os.replace(part, final)
        log_request("cache_fill", video_id, True, 0)
        evict(directory, cap_bytes)
    except Exception as exc:  # noqa: BLE001 - a failed fill must never break playback
        log_request("cache_fill", video_id, False, 0, str(exc))
        part.unlink(missing_ok=True)


class Filler:
    """Serialised background downloader; one fill at a time, none duplicated."""

    def __init__(self, directory: Path | None = None, cap_bytes: int = DEFAULT_CAP_BYTES):
        self.directory = directory or cache_dir()
        self.cap_bytes = cap_bytes
        self._lock = threading.Lock()
        self._busy: set[str] = set()
        self._worker = threading.Lock()

    def schedule(self, video_id: str, url: str) -> bool:
        if not VIDEO_ID_RE.match(video_id or "") or lookup(video_id, self.directory):
            return False
        info = stream_info(url)
        if info is None:
            return False
        with self._lock:
            if video_id in self._busy:
                return False
            self._busy.add(video_id)

        def run() -> None:
            try:
                with self._worker:
                    _download(video_id, url, info[0], info[1], self.directory,
                              self.cap_bytes)
            finally:
                with self._lock:
                    self._busy.discard(video_id)

        threading.Thread(target=run, daemon=True).start()
        return True
