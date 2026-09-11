"""Plain YouTube search: fast InnerTube path, yt-dlp as the safety net.

No API key, no browser, no login either way.

The fast path POSTs to YouTube's own InnerTube search endpoint over a
kept-alive, gzipped HTTPS connection (~0.9s). The fallback shells out to
the yt-dlp CLI (~2.2s), which is what this used to do exclusively.

Measured on this machine: yt-dlp spawn is only ~0.17s, so the old path was
not slow because of the subprocess — it was slow because YouTube returns
~1.9MB of JSON per search and the request asked for it uncompressed, then
paid DNS+TLS again every time. gzip cuts the wire payload ~16x and keeping
the connection warm removes another ~400ms.

Stability note: YouTube reshuffles the *containers* around search results
far more often than the result objects themselves, so we recursively hunt
for `videoRenderer` nodes rather than following a fixed path. If anything
about that breaks — parse yields nothing, HTTP error, or YouTube starts
gating the endpoint the way it already gates the ANDROID client — we fall
straight through to yt-dlp, so a breakage costs speed, not search itself.
"""

from __future__ import annotations

import gzip
import http.client
import json
import shutil
import ssl
import subprocess
import sys
import threading
import time
from typing import Any

WATCH_BASE = "https://www.youtube.com/watch?v="

INNERTUBE_HOST = "www.youtube.com"
INNERTUBE_PATH = "/youtubei/v1/search"
INNERTUBE_TIMEOUT = 6.0
INNERTUBE_CLIENT = {
    "clientName": "WEB",
    "clientVersion": "2.20240101.01.00",
    "hl": "en",
    "gl": "US",
}
USER_AGENT = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
              "(KHTML, like Gecko) Chrome/120.0 Safari/537.36")


class SearchError(RuntimeError):
    pass


def watch_url(video_id: str) -> str:
    return WATCH_BASE + str(video_id or "")


def thumbnail_url(video_id: str) -> str:
    return f"https://i.ytimg.com/vi/{video_id}/mqdefault.jpg"


# ---------------------------------------------------------------- fast path

_conn_lock = threading.Lock()
_conn: http.client.HTTPSConnection | None = None

# Circuit breaker. A failing fast path costs a wasted round-trip *before*
# the fallback even starts, so if YouTube gates us the naive retry-every-time
# behaviour would make every search permanently slower than not having the
# fast path at all. After a few consecutive failures, stop trying for a
# while; the timer expiring re-probes, so it heals itself when YouTube does.
_FAIL_THRESHOLD = 3
_COOLDOWN_SECONDS = 300.0
_fail_count = 0
_skip_until = 0.0


def _note_fast_failure() -> None:
    global _fail_count, _skip_until
    _fail_count += 1
    if _fail_count >= _FAIL_THRESHOLD:
        _skip_until = time.time() + _COOLDOWN_SECONDS


def _note_fast_success() -> None:
    global _fail_count, _skip_until
    _fail_count = 0
    _skip_until = 0.0


def _fast_path_suspended() -> bool:
    return time.time() < _skip_until


def _drop_connection() -> None:
    global _conn
    if _conn is not None:
        try:
            _conn.close()
        except OSError:
            pass
    _conn = None


def _innertube_post(query: str) -> dict[str, Any]:
    """POST one search, reusing the open connection. Retries once if the
    server closed an idle connection out from under us."""
    global _conn
    body = json.dumps({"context": {"client": dict(INNERTUBE_CLIENT)}, "query": query})
    headers = {
        "Content-Type": "application/json",
        "Accept-Encoding": "gzip",
        "User-Agent": USER_AGENT,
    }
    for attempt in (1, 2):
        try:
            if _conn is None:
                _conn = http.client.HTTPSConnection(
                    INNERTUBE_HOST, 443,
                    context=ssl.create_default_context(),
                    timeout=INNERTUBE_TIMEOUT,
                )
                _conn.connect()
            _conn.request("POST", INNERTUBE_PATH, body=body, headers=headers)
            response = _conn.getresponse()
            raw = response.read()
            if response.status != 200:
                raise SearchError(f"InnerTube HTTP {response.status}")
            if response.getheader("Content-Encoding") == "gzip":
                raw = gzip.decompress(raw)
            return json.loads(raw)
        except SearchError:
            _drop_connection()
            raise
        except Exception as exc:
            _drop_connection()
            if attempt == 2:
                raise SearchError(f"InnerTube request failed: {exc}") from exc
    raise SearchError("InnerTube request failed")


def _collect_renderers(node: Any, out: list[dict]) -> None:
    if isinstance(node, dict):
        renderer = node.get("videoRenderer")
        if isinstance(renderer, dict):
            out.append(renderer)
        for value in node.values():
            _collect_renderers(value, out)
    elif isinstance(node, list):
        for value in node:
            _collect_renderers(value, out)


def _text(node: Any) -> str:
    if not isinstance(node, dict):
        return ""
    runs = node.get("runs")
    if isinstance(runs, list):
        return "".join(str(r.get("text", "")) for r in runs if isinstance(r, dict))
    return str(node.get("simpleText") or "")


def _duration_ms(label: str) -> int:
    """'3:48' / '1:03:10' -> milliseconds. 0 when absent (live streams)."""
    parts = [p for p in str(label or "").strip().split(":") if p != ""]
    if not parts:
        return 0
    total = 0
    for part in parts:
        if not part.isdigit():
            return 0
        total = total * 60 + int(part)
    return total * 1000


def _view_count(label: str) -> int | None:
    digits = "".join(ch for ch in str(label or "") if ch.isdigit())
    return int(digits) if digits else None


def _is_live(renderer: dict, duration_label: str) -> bool:
    for badge in renderer.get("badges") or []:
        if not isinstance(badge, dict):
            continue
        style = badge.get("metadataBadgeRenderer", {}).get("style", "")
        if style == "BADGE_STYLE_TYPE_LIVE_NOW":
            return True
    return not duration_label


def _from_renderer(renderer: dict) -> dict[str, Any] | None:
    video_id = str(renderer.get("videoId") or "").strip()
    title = _text(renderer.get("title")).strip()
    if not video_id or not title:
        return None
    channel = (_text(renderer.get("ownerText"))
               or _text(renderer.get("longBylineText"))
               or _text(renderer.get("shortBylineText"))).strip()
    duration_label = _text(renderer.get("lengthText")).strip()
    return {
        "type": "track",
        "videoId": video_id,
        "name": title,
        "subtitle": channel,
        "durationMs": _duration_ms(duration_label),
        "live": _is_live(renderer, duration_label),
        "thumbnail": thumbnail_url(video_id),
        "externalUrl": watch_url(video_id),
        "viewCount": _view_count(_text(renderer.get("viewCountText"))),
    }


def innertube_search(query: str, limit: int = 20) -> list[dict[str, Any]]:
    with _conn_lock:
        payload = _innertube_post(query)
    renderers: list[dict] = []
    _collect_renderers(payload, renderers)
    items: list[dict[str, Any]] = []
    seen: set[str] = set()
    for renderer in renderers:
        item = _from_renderer(renderer)
        if not item or item["videoId"] in seen:
            continue
        seen.add(item["videoId"])
        items.append(item)
        if len(items) >= limit:
            break
    return items


# ------------------------------------------------------------ fallback path

def _ytdlp_normalize(entry: dict[str, Any]) -> dict[str, Any] | None:
    video_id = str(entry.get("id") or "").strip()
    if not video_id:
        return None
    duration = entry.get("duration")
    try:
        duration_ms = int(float(duration) * 1000) if duration is not None else 0
    except (TypeError, ValueError):
        duration_ms = 0
    title = str(entry.get("title") or "Untitled").strip()
    channel = str(entry.get("uploader") or entry.get("channel") or "").strip()
    return {
        "type": "track",
        "videoId": video_id,
        "name": title,
        "subtitle": channel,
        "durationMs": duration_ms,
        "live": duration is None,
        "thumbnail": thumbnail_url(video_id),
        "externalUrl": watch_url(video_id),
        "viewCount": entry.get("view_count"),
    }


def ytdlp_search(query: str, limit: int = 20) -> list[dict[str, Any]]:
    binary = shutil.which("yt-dlp")
    if not binary:
        raise SearchError("yt-dlp is not installed")
    command = [
        binary,
        "--dump-json",
        "--flat-playlist",
        "--no-warnings",
        "--no-playlist",
        "--playlist-items", f"1-{limit}",
        f"ytsearch{limit}:{query}",
    ]
    try:
        result = subprocess.run(
            command, capture_output=True, text=True, timeout=25, check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise SearchError("YouTube search took too long") from exc
    if result.returncode != 0 and not result.stdout.strip():
        detail = (result.stderr or "").strip().splitlines()
        raise SearchError(detail[-1] if detail else "Search failed")
    items: list[dict[str, Any]] = []
    for line in result.stdout.splitlines():
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


# ----------------------------------------------------------------- dispatch

def search(query: str, limit: int = 20) -> list[dict[str, Any]]:
    query = str(query or "").strip()
    if not query:
        return []
    limit = max(1, min(int(limit or 20), 50))

    if _fast_path_suspended():
        return ytdlp_search(query, limit)

    try:
        items = innertube_search(query, limit)
        if items:
            _note_fast_success()
            return items
        reason = "no results parsed"
    except Exception as exc:  # noqa: BLE001 - any failure just means fall back
        reason = str(exc)

    # Either YouTube changed something under us or it refused the request.
    # yt-dlp tracks those changes upstream, so the slow path still works.
    _note_fast_failure()
    suffix = ("; pausing fast path for %d min" % (_COOLDOWN_SECONDS / 60)
              if _fast_path_suspended() else "")
    print(f"ytwidget: InnerTube search unavailable ({reason}); using yt-dlp{suffix}",
          file=sys.stderr, flush=True)
    return ytdlp_search(query, limit)
