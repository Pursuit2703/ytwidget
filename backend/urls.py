"""Recognise pasted YouTube links and expand them into playable items.

The search field doubles as a URL box: anything that parses as a YouTube
link here is expanded instead of being sent to search. A link that carries a
playlist id expands to the whole playlist and replaces the queue, matching
what youtube.com itself does when you open a watch URL from a playlist.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
from typing import Any
from urllib.parse import parse_qs, urlparse

from search import _ytdlp_normalize, thumbnail_url, watch_url

# A queue this long already covers any sane playlist, and the state broadcast
# carries the whole queue in one NDJSON frame (protocol.MAX_LINE_BYTES is
# 256KB) — an unbounded playlist would get silently stripped to an empty queue
# by the oversize fallback, which looks like a bug to the user.
MAX_PLAYLIST_ITEMS = 200

VIDEO_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")
PLAYLIST_ID_RE = re.compile(r"^[A-Za-z0-9_-]{2,64}$")

YOUTUBE_HOSTS = {
    "youtube.com", "www.youtube.com", "m.youtube.com",
    "music.youtube.com", "gaming.youtube.com",
    "youtu.be", "www.youtu.be",
}

# /shorts/<id>, /live/<id>, /embed/<id>, /v/<id> all address a single video.
PATH_VIDEO_PREFIXES = ("/shorts/", "/live/", "/embed/", "/v/")


class UrlError(RuntimeError):
    pass


def looks_like_url(text: str) -> bool:
    value = str(text or "").strip()
    if not value or " " in value:
        return False
    return bool(re.match(r"^(https?://|//)?(www\.|m\.|music\.)?(youtube\.com|youtu\.be)/", value, re.I))


def parse(text: str) -> dict[str, str] | None:
    """Return {'videoId': ..., 'playlistId': ...} for a YouTube link, else None.

    Either key may be empty: a bare playlist link has no video, a plain watch
    link has no playlist, and a watch link opened from a playlist has both.
    """
    value = str(text or "").strip()
    if not value or " " in value:
        return None
    if not re.match(r"^[a-z]+://", value, re.I):
        # Accept "youtu.be/xyz" and "//youtu.be/xyz" the way a browser bar would.
        value = "https://" + value.lstrip("/")
    try:
        parsed = urlparse(value)
    except ValueError:
        return None
    host = (parsed.hostname or "").lower()
    if host not in YOUTUBE_HOSTS:
        return None

    path = parsed.path or ""
    query = parse_qs(parsed.query or "")

    def first(key: str) -> str:
        values = query.get(key) or []
        return str(values[0]).strip() if values else ""

    video_id = ""
    if host.endswith("youtu.be"):
        candidate = path.lstrip("/").split("/")[0]
        if VIDEO_ID_RE.match(candidate):
            video_id = candidate
    else:
        candidate = first("v")
        if VIDEO_ID_RE.match(candidate):
            video_id = candidate
        else:
            for prefix in PATH_VIDEO_PREFIXES:
                if path.startswith(prefix):
                    tail = path[len(prefix):].split("/")[0]
                    if VIDEO_ID_RE.match(tail):
                        video_id = tail
                    break

    playlist_id = first("list")
    if playlist_id and not PLAYLIST_ID_RE.match(playlist_id):
        playlist_id = ""

    if not video_id and not playlist_id:
        return None
    return {"videoId": video_id, "playlistId": playlist_id}


def _run_ytdlp(args: list[str], timeout: int) -> str:
    binary = shutil.which("yt-dlp")
    if not binary:
        raise UrlError("yt-dlp is not installed")
    try:
        result = subprocess.run(
            [binary] + args, capture_output=True, text=True,
            timeout=timeout, check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise UrlError("YouTube took too long to answer that link") from exc
    if result.returncode != 0 and not result.stdout.strip():
        detail = (result.stderr or "").strip().splitlines()
        message = detail[-1] if detail else "Could not open that link"
        if message.lower().startswith("error:"):
            message = message[6:].strip()
        raise UrlError(message[:200] or "Could not open that link")
    return result.stdout


def _parse_json_lines(raw: str) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(entry, dict):
            continue
        normalized = _ytdlp_normalize(entry)
        if normalized:
            items.append(normalized)
    return items


def _fetch_playlist_raw(playlist_id: str, limit: int) -> str:
    limit = max(1, min(int(limit or MAX_PLAYLIST_ITEMS), MAX_PLAYLIST_ITEMS))
    # --flat-playlist keeps this to a single index fetch instead of one full
    # extraction per entry; the per-video stream URL is resolved lazily at play
    # time by StreamResolver, exactly as search results are.
    return _run_ytdlp([
        "--flat-playlist",
        "--dump-json",
        "--no-warnings",
        "--no-progress",
        "--playlist-items", f"1-{limit}",
        f"https://www.youtube.com/playlist?list={playlist_id}",
    ], timeout=60)


def expand_playlist(playlist_id: str, limit: int = MAX_PLAYLIST_ITEMS) -> list[dict[str, Any]]:
    return _parse_json_lines(_fetch_playlist_raw(playlist_id, limit))


def _playlist_title_from_raw(raw: str) -> str:
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(entry, dict):
            return str(entry.get("playlist_title") or "").strip()
    return ""


def import_playlist(text: str, limit: int = MAX_PLAYLIST_ITEMS) -> dict[str, Any]:
    """Expand a pasted playlist link into {items, title} for saving locally.

    Reuses the same yt-dlp fetch and item parsing as expand_playlist/
    resolve_link — this just also reads the playlist_title already present
    in each flat-playlist entry, to suggest a name for the saved playlist.
    """
    info = parse(text)
    playlist_id = (info or {}).get("playlistId") or ""
    if not playlist_id:
        raise UrlError("That does not look like a YouTube playlist link")
    raw = _fetch_playlist_raw(playlist_id, limit)
    items = _parse_json_lines(raw)
    if not items:
        raise UrlError("That playlist is empty or private")
    return {"items": items, "title": _playlist_title_from_raw(raw)}


def fetch_video(video_id: str) -> dict[str, Any]:
    raw = _run_ytdlp([
        "--dump-json",
        "--no-playlist",
        "--skip-download",
        "--no-warnings",
        "--no-progress",
        watch_url(video_id),
    ], timeout=45)
    items = _parse_json_lines(raw)
    if items:
        return items[0]
    # Metadata lookup failed but the id itself is well-formed, so still hand
    # back something playable — the stream resolver only needs the video id.
    return {
        "type": "track",
        "videoId": video_id,
        "name": "YouTube video",
        "subtitle": "",
        "durationMs": 0,
        "live": False,
        "thumbnail": thumbnail_url(video_id),
        "externalUrl": watch_url(video_id),
        "viewCount": None,
    }


def resolve_link(text: str, limit: int = MAX_PLAYLIST_ITEMS) -> dict[str, Any]:
    """Expand a pasted link into {items, index, kind, playlistId}.

    A link carrying both a video and a playlist expands to the playlist and
    starts at that video, so "share from the middle of a playlist" behaves the
    way it does on youtube.com.
    """
    info = parse(text)
    if not info:
        raise UrlError("That does not look like a YouTube link")
    playlist_id = info.get("playlistId") or ""
    video_id = info.get("videoId") or ""

    if playlist_id:
        try:
            items = expand_playlist(playlist_id, limit)
        except UrlError:
            if not video_id:
                raise
            items = []
        if items:
            index = 0
            if video_id:
                for position, item in enumerate(items):
                    if str(item.get("videoId") or "") == video_id:
                        index = position
                        break
            return {
                "items": items,
                "index": index,
                "kind": "playlist",
                "playlistId": playlist_id,
            }
        if not video_id:
            raise UrlError("That playlist is empty or private")

    item = fetch_video(video_id)
    return {"items": [item], "index": 0, "kind": "video", "playlistId": ""}
