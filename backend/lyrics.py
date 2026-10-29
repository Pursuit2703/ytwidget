"""Lyrics for the track that is playing.

Order of preference, all matched against the exact video that is playing:

1. Timed lyrics from LRCLIB (lrclib.net, free, no key). A result only counts
   when its length is within MATCH_TOLERANCE_S of the video, so a piano cover
   or a live version never borrows the studio track's timing.
2. The video's own captions (uploader's first, then YouTube's automatic
   ones). They are timed against this very video, so they always line up.
   Tracks that are only "[Music]" / "♪" are thrown away.
3. Untimed lyrics from LRCLIB (same length rule), shown as plain text.
4. Nothing. LRCLIB also says outright when a recording is instrumental.

Results are cached per video under ~/.cache/ytwidget/lyrics, with the timing
offset the user set, so replays are instant and work offline.
"""

from __future__ import annotations

import json
import os
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable

LRCLIB = "https://lrclib.net/api"
USER_AGENT = "ytwidget (Omarchy plugin; https://github.com/omarchy)"
MATCH_TOLERANCE_S = 3.0
HTTP_TIMEOUT_S = 8
# A "none" answer is retried after this long, in case lyrics were added.
NONE_TTL_S = 7 * 86400
# Offline answers are retried on the next play.
CACHE_VERSION = 1

# Words in brackets that describe the upload, not the song.
_NOISE = (
    r"official|video|audio|lyrics?|lyric video|mv|m/v|hd|hq|4k|8k|remaster(ed)?|"
    r"visuali[sz]er|explicit|clean|color coded|full version|full|topic|"
    r"piano|cover|instrumental|karaoke|sped up|slowed|reverb|nightcore|"
    r"tv size|tv ver\.?|ost|op|ed|opening|ending|amv"
)
_BRACKETS = re.compile(r"[\[\(【「（][^\]\)】」）]*[\]\)】」）]")
_MUSIC_ONLY = re.compile(r"^[\s\[\(]*(music|musique|música|musik|音楽|applause|laughter|silence|instrumental)?[\s\]\)]*$", re.I)


def cache_dir() -> Path:
    base = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache")
    path = base / "ytwidget" / "lyrics"
    path.mkdir(parents=True, exist_ok=True)
    return path


# ---------------------------------------------------------------- names

def clean_title(name: str) -> str:
    text = str(name or "")
    # Drop bracketed tags that are about the upload: "(Official Video)",
    # "[Piano]", "【MV】". Keep ones that are part of the song name.
    def strip(match: re.Match) -> str:
        inner = match.group(0)[1:-1].strip().lower()
        return " " if re.search(_NOISE, inner) else match.group(0)
    text = _BRACKETS.sub(strip, text)
    text = re.sub(r"\s*\|.*$", "", text)            # "Song | Channel extras"
    text = re.sub(r"\s+(ft\.?|feat\.?)\s+.*$", "", text, flags=re.I)
    text = re.sub(r"\s{2,}", " ", text).strip(" -–—·/")
    return text.strip()


def clean_artist(channel: str) -> str:
    text = str(channel or "")
    text = re.sub(r"\s*-\s*Topic$", "", text)
    text = re.sub(r"(VEVO|Official|Music)$", "", text).strip()
    return text


def name_pairs(name: str, channel: str) -> list[tuple[str, str]]:
    """(title, artist) guesses, best first."""
    title = clean_title(name)
    artist = clean_artist(channel)
    pairs: list[tuple[str, str]] = []
    parts = re.split(r"\s+[-–—]\s+", title, maxsplit=1)
    if len(parts) == 2 and parts[0] and parts[1]:
        left, right = parts[0].strip(), parts[1].strip()
        pairs.append((right, left))      # "Artist - Song"
        pairs.append((left, right))      # "Song - Artist / Show"
        pairs.append((left, artist))
    pairs.append((title, artist))
    seen: set[tuple[str, str]] = set()
    out = []
    for t, a in pairs:
        key = (t.lower(), a.lower())
        if t and key not in seen:
            seen.add(key)
            out.append((t, a))
    return out


# ---------------------------------------------------------------- parsing

_LRC_TIME = re.compile(r"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]")


def parse_lrc(text: str) -> list[dict[str, Any]]:
    """LRC text to [{ms, text}], sorted. Lines with several stamps repeat."""
    lines: list[dict[str, Any]] = []
    for raw in str(text or "").splitlines():
        stamps = list(_LRC_TIME.finditer(raw))
        if not stamps:
            continue
        words = _LRC_TIME.sub("", raw).strip()
        # Word-level (enhanced) LRC tags: <00:12.34>
        words = re.sub(r"<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>", "", words).strip()
        for m in stamps:
            frac = m.group(3) or "0"
            ms = int(m.group(1)) * 60000 + int(m.group(2)) * 1000 + int(frac.ljust(3, "0")[:3])
            lines.append({"ms": ms, "text": words})
    lines.sort(key=lambda line: line["ms"])
    return lines


def parse_json3(data: dict[str, Any]) -> list[dict[str, Any]]:
    """YouTube timedtext json3 to [{ms, text}]. Automatic captions arrive as
    a window of words per event; each event with words becomes one line."""
    lines: list[dict[str, Any]] = []
    for ev in (data or {}).get("events") or []:
        segs = ev.get("segs")
        if not segs:
            continue
        text = "".join(str(s.get("utf8") or "") for s in segs)
        text = re.sub(r"\s+", " ", text.replace("\n", " ")).strip()
        if not text:
            continue
        ms = int(ev.get("tStartMs") or 0)
        if lines and lines[-1]["text"] == text:
            continue
        lines.append({"ms": ms, "text": text})
    return lines


def is_music_only(lines: list[dict[str, Any]]) -> bool:
    real = 0
    for line in lines:
        text = re.sub(r"[♪♫♬🎵🎶]", "", line.get("text") or "").strip()
        if text and not _MUSIC_ONLY.match(text):
            real += 1
    return real < 4


def plain_lines(text: str) -> list[dict[str, Any]]:
    return [{"ms": -1, "text": line.strip()} for line in str(text or "").splitlines()]


# ---------------------------------------------------------------- network

class Offline(Exception):
    pass


def http_json(url: str, attempts: int = 3) -> Any:
    """GET json. 404 is "nothing here" (None). LRCLIB answers 503 "busy" now
    and then, so busy/rate-limit replies are retried with a short backoff."""
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_S) as resp:
                return json.loads(resp.read().decode("utf-8", "replace"))
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return None
            if exc.code in (429, 500, 502, 503, 504) and attempt + 1 < attempts:
                time.sleep(1.0 + attempt * 1.5)
                continue
            raise Offline(str(exc)) from exc
        except (urllib.error.URLError, TimeoutError, OSError, ValueError) as exc:
            raise Offline(str(exc)) from exc
    raise Offline("no answer")


def lrclib_candidates(name: str, channel: str, duration_s: float,
                      fetch: Callable[[str], Any] = http_json) -> list[dict[str, Any]]:
    """Every LRCLIB record that could be this recording, closest length first.
    Each: {id, title, artist, duration, synced, plain, instrumental, diff}."""
    found: dict[Any, dict[str, Any]] = {}
    answered = 0
    failed = 0

    def ask(url: str) -> Any:
        nonlocal answered, failed
        try:
            data = fetch(url)
            answered += 1
            return data
        except Offline:
            failed += 1
            return None

    def take(rec: Any) -> None:
        if not isinstance(rec, dict):
            return
        dur = float(rec.get("duration") or 0)
        key = rec.get("id") or (rec.get("trackName"), rec.get("artistName"), dur)
        found[key] = {
            "id": rec.get("id"),
            "title": str(rec.get("trackName") or ""),
            "artist": str(rec.get("artistName") or ""),
            "duration": dur,
            "synced": str(rec.get("syncedLyrics") or ""),
            "plain": str(rec.get("plainLyrics") or ""),
            "instrumental": bool(rec.get("instrumental")),
            "diff": abs(dur - duration_s) if duration_s and dur else 999.0,
        }

    pairs = name_pairs(name, channel)
    for title, artist in pairs[:3]:
        if not artist or not duration_s:
            continue
        q = urllib.parse.urlencode({"track_name": title, "artist_name": artist,
                                    "duration": int(round(duration_s))})
        take(ask(f"{LRCLIB}/get?{q}"))
        if any(c["diff"] <= MATCH_TOLERANCE_S for c in found.values()):
            break
    if not any(c["diff"] <= MATCH_TOLERANCE_S for c in found.values()):
        for title, artist in pairs[:2]:
            params = {"track_name": title}
            if artist:
                params["artist_name"] = artist
            for rec in (ask(f"{LRCLIB}/search?{urllib.parse.urlencode(params)}") or [])[:20]:
                take(rec)
        if pairs:
            for rec in (ask(f"{LRCLIB}/search?{urllib.parse.urlencode({'q': pairs[0][0]})}") or [])[:20]:
                take(rec)
    if failed and not answered:
        raise Offline("lyrics site unreachable")
    return sorted(found.values(), key=lambda c: (c["diff"], not c["synced"]))


def caption_lines(subs: dict[str, str], kinds: dict[str, str], prefer_lang: str,
                  fetch: Callable[[str], Any] = http_json) -> tuple[list[dict[str, Any]], str]:
    """Best usable captions: uploader's in the preferred language, then any
    uploader's, then automatic ones. Returns (lines, "manual"|"auto")."""
    if not subs:
        return [], ""
    base = (prefer_lang or "en").split("-")[0].lower()

    def rank(lang: str) -> tuple:
        manual = kinds.get(lang) != "auto"
        return (0 if manual else 1, 0 if lang.lower().startswith(base) else 1,
                0 if lang.lower().startswith("en") else 1)

    for lang in sorted(subs, key=rank):
        url = subs[lang]
        url = re.sub(r"([?&])fmt=[^&]*", r"\1fmt=json3", url) if "fmt=" in url else url + "&fmt=json3"
        try:
            data = fetch(url)
        except Offline:
            continue
        lines = parse_json3(data or {})
        if lines and not is_music_only(lines):
            return lines, ("auto" if kinds.get(lang) == "auto" else "manual")
    return [], ""


# ---------------------------------------------------------------- service

class LyricsService:
    """Looks lyrics up off the UI thread, one track at a time, and keeps the
    answer for the track that is playing.

    `resolve_video(video_id)` returns the widget's resolved video record
    (with `subs`, `subKinds`, `durationMs`); it may block for a few seconds.
    """

    def __init__(self, on_change: Callable[[], None],
                 resolve_video: Callable[[str], dict[str, Any] | None],
                 fetch: Callable[[str], Any] = http_json,
                 directory: Path | None = None) -> None:
        self._on_change = on_change
        self._resolve_video = resolve_video
        self._fetch = fetch
        self._dir = directory
        self._lock = threading.Lock()
        self._wake = threading.Event()
        self.enabled = True
        self.source = "auto"            # auto | lrclib | captions
        self.sub_lang = "en"
        self._want: dict[str, Any] | None = None
        self._result: dict[str, Any] = self._empty("")
        self._candidates: dict[str, list[dict[str, Any]]] = {}
        threading.Thread(target=self._worker, daemon=True).start()

    # -- public

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            return dict(self._result)

    def track_changed(self, item: dict[str, Any] | None, duration_ms: int = 0) -> None:
        video_id = str((item or {}).get("videoId") or "")
        with self._lock:
            if video_id and video_id == self._result.get("videoId"):
                return
            if not video_id:
                self._result = self._empty("")
                self._want = None
                return
            self._want = {"item": dict(item or {}), "duration_ms": int(duration_ms or 0), "other": 0}
            self._result = self._empty(video_id, "loading" if self.enabled else "off")
        self._on_change()
        if self.enabled:
            self._wake.set()

    def try_other(self) -> None:
        with self._lock:
            vid = self._result.get("videoId")
            if not vid or not self._want_item_for(vid):
                return
            self._want = {"item": self._want_item_for(vid), "duration_ms": self._result.get("durationMs", 0),
                          # Offline: ask again for the same thing.
                          "other": int(self._result.get("choice", 0))
                          + (0 if self._result.get("status") == "offline" else 1)}
            self._result = dict(self._result, status="loading")
        self._on_change()
        self._wake.set()

    def set_offset(self, offset_ms: int) -> None:
        with self._lock:
            self._result = dict(self._result, offsetMs=int(offset_ms))
            result = dict(self._result)
        if result.get("videoId") and result["status"] not in ("loading", "offline", "off"):
            self._save(result)
        self._on_change()

    def configure(self, enabled: bool | None = None, source: str | None = None,
                  sub_lang: str | None = None) -> None:
        changed = False
        with self._lock:
            if enabled is not None and bool(enabled) != self.enabled:
                self.enabled = bool(enabled)
                changed = True
            if source in ("auto", "lrclib", "captions") and source != self.source:
                self.source = source
                changed = True
            if sub_lang:
                self.sub_lang = sub_lang
            item = self._last_item
        if changed and item:
            with self._lock:
                self._result = self._empty("")
            self.track_changed(item.get("item"), item.get("duration_ms", 0))

    # -- internals

    _last_item: dict[str, Any] | None = None

    def _want_item_for(self, video_id: str) -> dict[str, Any] | None:
        last = self._last_item
        if last and str(last["item"].get("videoId")) == video_id:
            return last["item"]
        return None

    @staticmethod
    def _empty(video_id: str, status: str = "none") -> dict[str, Any]:
        return {"videoId": video_id, "status": status, "source": "", "lines": [],
                "offsetMs": 0, "title": "", "artist": "", "choice": 0, "durationMs": 0}

    def _path(self, video_id: str) -> Path:
        safe = re.sub(r"[^A-Za-z0-9_-]", "_", video_id)
        return (self._dir or cache_dir()) / f"{safe}.json"

    def _load(self, video_id: str) -> dict[str, Any] | None:
        try:
            data = json.loads(self._path(video_id).read_text())
        except (OSError, ValueError):
            return None
        if data.get("v") != CACHE_VERSION:
            return None
        if data.get("status") == "none" and time.time() - float(data.get("at") or 0) > NONE_TTL_S:
            return None
        if data.get("sourcePref", "auto") != self.source:
            return None
        return data.get("result")

    def _save(self, result: dict[str, Any]) -> None:
        try:
            path = self._path(result["videoId"])
            tmp = path.with_suffix(".tmp")
            tmp.write_text(json.dumps({"v": CACHE_VERSION, "at": time.time(), "status": result["status"],
                                       "sourcePref": self.source, "result": result}))
            tmp.replace(path)
        except OSError:
            pass

    def _worker(self) -> None:
        while True:
            self._wake.wait()
            self._wake.clear()
            with self._lock:
                want, self._want = self._want, None
                enabled = self.enabled
            if not want or not enabled:
                continue
            self._last_item = want
            video_id = str(want["item"].get("videoId") or "")
            try:
                result = self._lookup(want)
            except Exception:
                result = self._empty(video_id, "offline")
            with self._lock:
                # A newer track may have started while we were looking.
                if self._result.get("videoId") != video_id or self._want:
                    continue
                self._result = result
            if result["status"] != "offline":
                self._save(result)
            self._on_change()

    def _lookup(self, want: dict[str, Any]) -> dict[str, Any]:
        item = want["item"]
        video_id = str(item.get("videoId") or "")
        other = int(want.get("other") or 0)
        if other == 0:
            cached = self._load(video_id)
            if cached:
                return cached

        duration_ms = int(item.get("durationMs") or want.get("duration_ms") or 0)
        video: dict[str, Any] | None = None

        def resolved() -> dict[str, Any]:
            nonlocal video, duration_ms
            if video is None:
                try:
                    video = self._resolve_video(video_id) or {}
                except Exception:
                    video = {}
                if video.get("durationMs"):
                    duration_ms = int(video["durationMs"])
            return video

        if not duration_ms:
            resolved()
        duration_s = duration_ms / 1000.0
        base = self._empty(video_id)
        base["durationMs"] = duration_ms

        # Every option, best first; "try another match" walks down the list.
        options: list[dict[str, Any]] = []
        offline = False
        cands: list[dict[str, Any]] = []
        if self.source in ("auto", "lrclib"):
            if video_id in self._candidates:
                cands = self._candidates[video_id]
            else:
                try:
                    cands = lrclib_candidates(str(item.get("name") or ""), str(item.get("subtitle") or ""),
                                              duration_s, self._fetch)
                    self._candidates[video_id] = cands
                except Offline:
                    offline = True
            close = [c for c in cands if c["diff"] <= MATCH_TOLERANCE_S]
            if close and close[0]["instrumental"] and other == 0:
                return dict(base, status="none", source="instrumental")
            for c in close:
                if c["synced"]:
                    options.append({"kind": "synced", "cand": c})
        if self.source in ("auto", "captions"):
            options.append({"kind": "captions"})
        if self.source in ("auto", "lrclib"):
            close = [c for c in cands if c["diff"] <= MATCH_TOLERANCE_S]
            for c in close:
                if c["plain"] and not c["synced"]:
                    options.append({"kind": "plain", "cand": c})
            # Asked for another match: loosen the length rule.
            if other:
                for c in cands:
                    if c["diff"] > MATCH_TOLERANCE_S and (c["synced"] or c["plain"]):
                        options.append({"kind": "synced" if c["synced"] else "plain", "cand": c})

        tried = 0
        for index, opt in enumerate(options):
            if index < other:
                continue
            tried += 1
            if opt["kind"] == "captions":
                v = resolved()
                try:
                    lines, kind = caption_lines(v.get("subs") or {}, v.get("subKinds") or {},
                                                self.sub_lang, self._fetch)
                except Offline:
                    offline = True
                    continue
                if lines:
                    return dict(base, status="captions", source=kind, lines=lines, choice=index)
                continue
            c = opt["cand"]
            if opt["kind"] == "synced":
                lines = [line for line in parse_lrc(c["synced"])]
                if lines:
                    return dict(base, status="synced", source="lrclib", lines=lines,
                                title=c["title"], artist=c["artist"], choice=index)
            else:
                return dict(base, status="plain", source="lrclib", lines=plain_lines(c["plain"]),
                            title=c["title"], artist=c["artist"], choice=index)
        if offline:
            return dict(base, status="offline")
        return dict(base, status="none", choice=max(0, len(options) - 1) if other else 0)
