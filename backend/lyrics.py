"""Lyrics for the track that is playing.

Order of preference, all matched against the exact video that is playing:

1. Timed lyrics from LRCLIB (lrclib.net, free, no key). A record has to share
   the song's title and artist (fancy Unicode fonts and "~" separators in the
   upload's title are cleaned first), and its length has to be within
   MATCH_TOLERANCE_S of the video, or its words have to line up with the
   video's own captions. Lining up also fixes the timing: a slowed upload, a
   live take or a cover gets the studio lyrics stretched and shifted to the
   video. Slowed / sped-up uploads without captions are stretched by length.
2. The uploader's captions, in the song's own language first.
3. Untimed lyrics from LRCLIB, shown as plain text.
4. YouTube's automatic captions. Speech recognition on singing is often
   wrong ("bfp a bunch of purle flows"), so they come last. Tracks that are
   only "[Music]" / "♪" are thrown away.
5. Nothing. LRCLIB also says outright when a recording is instrumental.

Every option is listed in the result (`choices`) so the player can switch
source; "try another match" walks the same list. The song's language is
detected and the original is shown; another language can be picked, and the
lines are then translated, keeping their timing.

Results are cached per video under ~/.cache/ytwidget/lyrics, with the timing
offset the user set, so replays are instant and work offline. Translations
are cached next to them.
"""

from __future__ import annotations

import difflib
import hashlib
import html
import json
import os
import re
import statistics
import threading
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable

LRCLIB = "https://lrclib.net/api"
GTX = "https://translate.googleapis.com/translate_a/single"
MYMEMORY = "https://api.mymemory.translated.net/get"
USER_AGENT = "ytwidget (Omarchy plugin; https://github.com/omarchy)"
MATCH_TOLERANCE_S = 3.0
HTTP_TIMEOUT_S = 8
# How much a record's title and artist must agree with the upload (0..1).
NAME_OK = 0.6
NAME_STRONG = 0.8
# Below this share of words found in the video's captions, a record with
# enough caption words to judge by is a different song.
MIN_WORD_MATCH = 0.1
# A "none" answer is retried after this long, in case lyrics were added.
NONE_TTL_S = 7 * 86400
# Offline answers are retried on the next play.
CACHE_VERSION = 2

# Words in brackets that describe the upload, not the song.
_NOISE = (
    r"official|video|audio|lyrics?|lyric video|mv|m/v|hd|hq|4k|8k|remaster(ed)?|"
    r"visuali[sz]er|explicit|clean|color coded|full version|full|topic|"
    r"piano|cover|instrumental|karaoke|sped up|slowed|reverb|nightcore|"
    r"tv size|tv ver\.?|ost|op|ed|opening|ending|amv"
)
_BRACKETS = re.compile(r"[\[\(【「（〔][^\]\)】」）〕]*[\]\)】」）〕]")
# The same tags written without brackets at the end: "Song slowed + reverb".
_TRAILING = re.compile(
    r"(\s*[-–—~|+&,/]?\s*\b(slowed(\s*(down|\+|&|and)?\s*reverb)?|reverb|sped[\s-]*up|speed[\s-]*up|"
    r"nightcore|daycore|8d audio|lyrics?|lyric video|official (music )?video|official audio)\b\.?)+\s*$",
    re.I)
_SEPARATOR = re.compile(r"\s+[-–—~]\s+|\s*//\s*")
_SPEED = re.compile(r"slowed|sped[\s-]*up|speed[\s-]*up|nightcore|daycore", re.I)
_MUSIC_ONLY = re.compile(r"^[\s\[\(]*(music|musique|música|musik|音楽|applause|laughter|silence|instrumental)?[\s\]\)]*$", re.I)
_CJK = re.compile(r"[぀-ヿ㐀-鿿가-힯]")


def cache_dir() -> Path:
    base = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache")
    path = base / "ytwidget" / "lyrics"
    path.mkdir(parents=True, exist_ok=True)
    return path


# ---------------------------------------------------------------- names

def normalize(text: str) -> str:
    # NFKC folds "𝙰𝚛𝚖𝚢 𝙳𝚛𝚎𝚊𝚖𝚎𝚛𝚜" and fullwidth letters to plain ones.
    return unicodedata.normalize("NFKC", str(text or ""))


def words_of(text: str) -> list[str]:
    """Lower-case words, apostrophes dropped. Chinese, Japanese and Korean
    have no spaces between words, so each of their characters counts."""
    text = re.sub(r"['’`]", "", normalize(text).lower())
    out: list[str] = []
    for word in re.findall(r"[^\W_]+", text):
        if _CJK.search(word):
            out.extend(word)
        else:
            out.append(word)
    return out


def clean_title(name: str) -> str:
    text = normalize(name)
    # Drop bracketed tags that are about the upload: "(Official Video)",
    # "[Piano]", "【MV】". Keep ones that are part of the song name.
    def strip(match: re.Match) -> str:
        inner = match.group(0)[1:-1].strip().lower()
        return " " if re.search(_NOISE, inner) else match.group(0)
    text = _BRACKETS.sub(strip, text)
    text = re.sub(r"\s*\|.*$", "", text)            # "Song | Channel extras"
    text = re.sub(r"\s+(ft\.?|feat\.?)\s+.*$", "", text, flags=re.I)
    text = _TRAILING.sub("", text)
    text = re.sub(r"\s{2,}", " ", text).strip(" -–—~·/")
    return text.strip()


def clean_artist(channel: str) -> str:
    text = normalize(channel)
    text = re.sub(r"\s*-\s*Topic$", "", text)
    text = re.sub(r"(VEVO|Official|Music)$", "", text).strip()
    return text


def speed_hint(name: str) -> bool:
    """The upload says it is slowed down or sped up."""
    return bool(_SPEED.search(normalize(name)))


def name_pairs(name: str, channel: str) -> list[tuple[str, str]]:
    """(title, artist) guesses, best first."""
    title = clean_title(name)
    artist = clean_artist(channel)
    pairs: list[tuple[str, str]] = []
    # 'Show - Opening FULL "AIZO" by King Gnu': the quoted part is the song.
    raw = normalize(name)
    quoted = re.search(r'["“『「]([^"”』」]{1,80})["”』」]', raw)
    if quoted:
        by = re.search(r"\bby\s+(.+?)\s*(?:[\[\(【|].*)?$", raw[quoted.end():], re.I)
        pairs.append((quoted.group(1).strip(), by.group(1).strip() if by else artist))
    parts = _SEPARATOR.split(title, maxsplit=1)
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


def name_score(title: str, artist: str, name: str, channel: str) -> float:
    """How well an LRCLIB record's title and artist agree with the upload,
    0..1. The record's words must appear in the upload's title or channel,
    and the song part of the upload's title must be in the record's title
    (so "Love" is not taken for "Love Story")."""
    upload = set(words_of(clean_title(name) + " " + clean_artist(channel)))
    rec_title = words_of(_BRACKETS.sub(" ", normalize(title))) or words_of(title)
    if not rec_title or not upload:
        return 0.0
    title_in = sum(w in upload for w in rec_title) / len(rec_title)
    rec_set = set(rec_title)
    covered = 0.0
    for guess, _ in name_pairs(name, channel):
        words = words_of(guess)
        if words:
            covered = max(covered, sum(w in rec_set for w in words) / len(words))
            # "Fairytale" for "Fairytale Norway 🇳🇴 Eurovision Winner 2009":
            # the song name leads, upload words trail.
            if words[:len(rec_title)] == rec_title:
                covered = max(covered, 0.8)
    artist_in = 0.5
    parts = [words_of(p) for p in re.split(r",|&|/|\bfeat\.?|\bft\.?|\bx\b", normalize(artist), flags=re.I)]
    parts = [p for p in parts if p]
    if parts:
        artist_in = max(sum(w in upload for w in p) / len(p) for p in parts)
    score = 0.6 * (title_in + covered) / 2 + 0.4 * artist_in
    # A record titled "Artist - Song" is a sloppy copy; prefer the clean one.
    if parts and len(rec_title) > len(parts[0]) and set(parts[0]) <= rec_set:
        score -= 0.1
    return round(max(0.0, score), 3)


# ---------------------------------------------------------------- languages

LANG_NAMES = {
    "en": "English", "es": "Spanish", "fr": "French", "de": "German", "pt": "Portuguese",
    "it": "Italian", "nl": "Dutch", "tr": "Turkish", "pl": "Polish", "id": "Indonesian",
    "sv": "Swedish", "ru": "Russian", "uk": "Ukrainian", "ja": "Japanese", "ko": "Korean",
    "zh": "Chinese", "ar": "Arabic", "he": "Hebrew", "el": "Greek", "hi": "Hindi", "th": "Thai",
    "kk": "Kazakh", "uz": "Uzbek", "fa": "Persian", "vi": "Vietnamese",
}

_SCRIPTS = (
    ("ko", re.compile(r"[가-힯ᄀ-ᇿ]")),
    ("ja", re.compile(r"[぀-ヿ]")),
    ("zh", re.compile(r"[㐀-鿿]")),
    ("ru", re.compile(r"[Ѐ-ӿ]")),
    ("ar", re.compile(r"[؀-ۿ]")),
    ("he", re.compile(r"[֐-׿]")),
    ("el", re.compile(r"[Ͱ-Ͽ]")),
    ("hi", re.compile(r"[ऀ-ॿ]")),
    ("th", re.compile(r"[฀-๿]")),
)
_LATIN = re.compile(r"[A-Za-zÀ-ɏ]")
_STOPWORDS = {
    "en": "the and you i to a of in is it my me that your on for be all love dont im its this with what",
    "es": "el la que de y en no me mi tu es un una lo por con te se yo los las del pero como",
    "fr": "le la les de et je tu que pas un une est dans pour moi toi ne qui des au mon sur",
    "de": "der die das und ich du nicht ist ein eine mich dich mit es zu wir auf mir dir",
    "pt": "o a que de e não eu você meu minha é um uma do da com os em se te",
    "it": "il la che di e non io tu mi sei un una per con è ti lo le del",
    "nl": "de het een en ik je niet is van dat mijn op te zijn we",
    "tr": "bir ve bu ben sen ne de da mi çok gibi için ama beni seni",
    "pl": "i nie się w na to że jest mnie ja ty co jak mi",
    "id": "aku kau dan yang di ini itu tak tidak kamu cinta ku dia",
    "sv": "och jag du det att en är inte på som med för mig dig",
}
_STOPSETS = {lang: set(words.split()) for lang, words in _STOPWORDS.items()}


def detect_lang(texts: list[str]) -> str:
    """The language of some lyrics, by script and then by common words.
    "" when it cannot tell."""
    text = " ".join(str(t or "") for t in texts)
    counts = {code: len(rx.findall(text)) for code, rx in _SCRIPTS}
    latin = len(_LATIN.findall(text))
    code, best = max(counts.items(), key=lambda kv: kv[1])
    if best and best > latin * 0.5:
        if code == "zh" and counts["ja"] > best * 0.05:
            return "ja"
        if code == "ru" and len(re.findall(r"[їєґі]", text.lower())) > best * 0.02:
            return "uk"
        return code
    if counts["ja"] and counts["ja"] > latin * 0.2:
        return "ja"
    if not latin:
        return ""
    words = words_of(text)
    scores = sorted(((sum(w in stops for w in words), lang) for lang, stops in _STOPSETS.items()), reverse=True)
    (top, lang), (second, _) = scores[0], scores[1]
    if top >= 3 and top > second * 1.2:
        return lang
    return ""


def lang_name(code: str) -> str:
    return LANG_NAMES.get(str(code or "").split("-")[0].lower(), str(code or "").upper())


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


def json3_words(data: dict[str, Any]) -> list[tuple[str, int]]:
    """Every caption word with the moment it is said. Automatic captions
    time each word; the uploader's time a whole line."""
    out: list[tuple[str, int]] = []
    for ev in (data or {}).get("events") or []:
        start = int(ev.get("tStartMs") or 0)
        for seg in ev.get("segs") or []:
            text = re.sub(r"\[[^\]]*\]|\([^)]*\)", " ", str(seg.get("utf8") or ""))
            ms = start + int(seg.get("tOffsetMs") or 0)
            out.extend((w, ms) for w in words_of(text))
    return out


def is_music_only(lines: list[dict[str, Any]]) -> bool:
    real = 0
    for line in lines:
        text = re.sub(r"[♪♫♬🎵🎶]", "", line.get("text") or "").strip()
        if text and not _MUSIC_ONLY.match(text):
            real += 1
    return real < 4


def plain_lines(text: str) -> list[dict[str, Any]]:
    return [{"ms": -1, "text": line.strip()} for line in str(text or "").splitlines()]


def text_key(texts: list[str]) -> str:
    return hashlib.sha1("\n".join(texts).encode("utf-8")).hexdigest()[:12]


# ---------------------------------------------------------------- lining up

def match_words(lines: list[dict[str, Any]], caption: list[tuple[str, int]]) -> tuple[float, list[tuple[int, int]]]:
    """Compare lyrics with the video's caption words. Returns the share of
    lyric words found in the captions, in order, and (lyric ms, video ms)
    pairs for lines whose first words were found."""
    lyric: list[tuple[str, int, bool]] = []
    for i, line in enumerate(lines):
        if int(line.get("ms", -1)) < 0:
            continue
        for k, word in enumerate(words_of(line.get("text") or "")):
            lyric.append((word, i, k == 0))
    if not lyric or not caption:
        return 0.0, []
    sm = difflib.SequenceMatcher(None, [w for w, _, _ in lyric], [w for w, _ in caption], autojunk=False)
    matched = 0
    anchors: list[tuple[int, int]] = []
    for a, b, size in sm.get_matching_blocks():
        # Single words match by chance; runs of two or more do not.
        if size < 2:
            continue
        matched += size
        for t in range(size):
            _, i, first = lyric[a + t]
            if first:
                anchors.append((int(lines[i]["ms"]), int(caption[b + t][1])))
    return matched / len(lyric), anchors


def fit_timing(anchors: list[tuple[int, int]], default_scale: float = 1.0) -> dict[str, float] | None:
    """video_ms = scale * lyric_ms + shift, fitted to the anchors with
    outliers (a chorus matched to the wrong repeat) thrown out. None when
    the anchors do not agree on one line."""
    pts = sorted(set(anchors))
    if len(pts) < 4:
        return None
    slopes = [(y2 - y1) / (x2 - x1) for i, (x1, y1) in enumerate(pts)
              for x2, y2 in pts[i + 1:] if x2 - x1 > 2000]
    a = statistics.median(slopes) if slopes else default_scale
    b = statistics.median(y - a * x for x, y in pts)
    keep = pts
    for _ in range(3):
        keep = [(x, y) for x, y in pts if abs(y - (a * x + b)) <= 2500]
        if len(keep) < 4:
            return None
        xs = [x for x, _ in keep]
        if max(xs) - min(xs) < 30000:
            # Too short a stretch to tell the speed from: only shift.
            a = default_scale
            b = statistics.median(y - a * x for x, y in keep)
            continue
        n = len(keep)
        sx, sy = sum(xs), sum(y for _, y in keep)
        sxx, sxy = sum(x * x for x in xs), sum(x * y for x, y in keep)
        den = n * sxx - sx * sx
        if not den:
            return None
        a = (n * sxy - sx * sy) / den
        b = (sy - a * sx) / n
    res = statistics.median(abs(y - (a * x + b)) for x, y in keep)
    if not 0.6 <= a <= 1.6 or res > 1500:
        return None
    return {"scale": a, "shift": b, "residual": res, "anchors": len(keep)}


def retime(lines: list[dict[str, Any]], scale: float, shift: float) -> list[dict[str, Any]]:
    return [dict(line, ms=max(0, int(round(scale * line["ms"] + shift)))) if line["ms"] >= 0 else dict(line)
            for line in lines]


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
                      fetch: Callable[[str], Any] = http_json,
                      report: dict[str, Any] | None = None) -> list[dict[str, Any]]:
    """Every LRCLIB record that could be this recording, closest length first.
    Each: {id, title, artist, duration, synced, plain, instrumental, diff, score}.
    `report["failed"]` counts questions LRCLIB did not answer (it is busy
    now and then), so a thin answer is not taken as final."""
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
        title = str(rec.get("trackName") or "")
        artist = str(rec.get("artistName") or "")
        found[key] = {
            "id": rec.get("id"),
            "title": title,
            "artist": artist,
            "duration": dur,
            "synced": str(rec.get("syncedLyrics") or ""),
            "plain": str(rec.get("plainLyrics") or ""),
            "instrumental": bool(rec.get("instrumental")),
            "diff": abs(dur - duration_s) if duration_s and dur else 999.0,
            "score": name_score(title, artist, name, channel),
        }

    def matched() -> bool:
        return any(c["diff"] <= MATCH_TOLERANCE_S and c["score"] >= NAME_STRONG for c in found.values())

    pairs = name_pairs(name, channel)
    for title, artist in pairs[:3]:
        if not artist or not duration_s:
            continue
        q = urllib.parse.urlencode({"track_name": title, "artist_name": artist,
                                    "duration": int(round(duration_s))})
        take(ask(f"{LRCLIB}/get?{q}"))
        if matched():
            break
    # A slowed or sped-up upload is never the record's length, so look
    # around even after an exact hit: its other records are the studio ones.
    searches: list[dict[str, str]] = []
    for title, artist in pairs[:2]:
        searches.append({"track_name": title, "artist_name": artist} if artist else {"track_name": title})
    if pairs:
        searches.append({"q": _SEPARATOR.sub(" ", clean_title(name))})
        # "Artist - Song Norway 🇳🇴 Eurovision Winner 2009": the song is the
        # first word or two after the artist.
        song, artist = next((p for p in pairs if p[1] and p[1] != clean_artist(channel)), pairs[0])
        words = song.split()
        if len(pairs) > 1 and artist:
            for k in (2, 1):
                if len(words) > k:
                    searches.append({"q": f"{artist} {' '.join(words[:k])}"})
    speed = speed_hint(name)
    for i, params in enumerate(searches):
        if matched() and (not speed or i >= 2):
            break
        for rec in (ask(f"{LRCLIB}/search?{urllib.parse.urlencode(params)}") or [])[:20]:
            take(rec)
    if report is not None:
        report["failed"] = failed
    if failed and not answered:
        raise Offline("lyrics site unreachable")
    return sorted(found.values(), key=lambda c: (c["diff"], -c["score"], not c["synced"]))


def caption_tracks(video: dict[str, Any]) -> list[dict[str, str]]:
    """[{lang, kind, url}] for a resolved video: `captionTracks` when the
    resolver lists them, else the older `subs` / `subKinds` pair."""
    tracks = [t for t in video.get("captionTracks") or [] if isinstance(t, dict) and t.get("url")]
    if tracks:
        return tracks
    kinds = video.get("subKinds") or {}
    return [{"lang": str(lang), "kind": "auto" if kinds.get(lang) == "auto" else "manual", "url": str(url)}
            for lang, url in (video.get("subs") or {}).items()]


def fetch_captions(video: dict[str, Any], prefer_lang: str,
                   fetch: Callable[[str], Any] = http_json) -> dict[str, Any]:
    """The best usable caption track of each kind: {"manual": track,
    "auto": track, "offline": bool}, a track being {lang, lines, words}.
    Captions in the song's own language come first: on a music video the
    uploader's English subtitles under a Japanese song are a translation."""
    song_lang = str(video.get("language") or "").split("-")[0].lower()
    base = (prefer_lang or "en").split("-")[0].lower()
    out: dict[str, Any] = {"manual": None, "auto": None, "offline": False}
    tracks = caption_tracks(video)

    def rank(track: dict[str, str]) -> tuple:
        lang = str(track.get("lang") or "").lower()
        code = lang.split("-")[0]
        return (0 if lang.endswith("-orig") else 1, 0 if song_lang and code == song_lang else 1,
                0 if code == base else 1, 0 if code == "en" else 1)

    for kind, tries in (("manual", 3), ("auto", 2)):
        for track in sorted((t for t in tracks if t.get("kind") == kind), key=rank)[:tries]:
            url = str(track["url"])
            url = re.sub(r"([?&])fmt=[^&]*", r"\1fmt=json3", url) if "fmt=" in url else url + "&fmt=json3"
            try:
                data = fetch(url)
            except Offline:
                out["offline"] = True
                continue
            lines = parse_json3(data or {})
            if lines and not is_music_only(lines):
                out[kind] = {"lang": str(track.get("lang") or "").split("-")[0], "lines": lines,
                             "words": json3_words(data or {})}
                break
    return out


# ---------------------------------------------------------------- translation

def _post_json(url: str, form: dict[str, str]) -> Any:
    data = urllib.parse.urlencode(form).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_S) as resp:
            return json.loads(resp.read().decode("utf-8", "replace"))
    except (urllib.error.URLError, TimeoutError, OSError, ValueError) as exc:
        raise Offline(str(exc)) from exc


def _chunks(texts: list[str], limit: int) -> list[list[str]]:
    out: list[list[str]] = [[]]
    size = 0
    for text in texts:
        n = len(text.encode("utf-8")) + 1
        if out[-1] and size + n > limit:
            out.append([])
            size = 0
        out[-1].append(text)
        size += n
    return [c for c in out if c]


def _gtx(texts: list[str], target: str) -> list[str]:
    out: list[str] = []
    for chunk in _chunks(texts, 4000):
        data = _post_json(f"{GTX}?client=gtx&sl=auto&tl={urllib.parse.quote(target)}&dt=t",
                          {"q": "\n".join(chunk)})
        joined = "".join(str(seg[0] or "") for seg in (data or [[]])[0] or [] if seg)
        got = [s.strip() for s in joined.split("\n")]
        if len(got) != len(chunk):
            raise Offline("translation lost lines")
        out.extend(got)
    return out


def _mymemory(texts: list[str], target: str, source: str) -> list[str]:
    pair = f"{source or 'autodetect'}|{target}"

    def ask(q: str) -> str:
        data = http_json(f"{MYMEMORY}?{urllib.parse.urlencode({'q': q, 'langpair': pair})}", attempts=1)
        if not isinstance(data, dict) or data.get("quotaFinished") or int(data.get("responseStatus") or 0) != 200:
            raise Offline("translation quota used up")
        return html.unescape(str((data.get("responseData") or {}).get("translatedText") or ""))

    out: list[str] = []
    # Free tier: 500 bytes a request.
    for chunk in _chunks(texts, 480):
        got = [s.strip() for s in ask("\n".join(chunk)).split("\n")]
        if len(got) != len(chunk):
            got = [ask(text).strip() for text in chunk]
        out.extend(got)
    return out


def translate_texts(texts: list[str], target: str, source: str = "") -> list[str]:
    """Translate lyric lines, one answer per line. Repeated lines (the
    chorus) are sent once. Google's free endpoint first, MyMemory if Google
    turns us away. Raises Offline when neither answers."""
    unique = list(dict.fromkeys(t.strip() for t in texts if t.strip()))
    if not unique:
        return list(texts)
    try:
        done = _gtx(unique, target)
    except Offline:
        done = _mymemory(unique, target, source)
    mapping = dict(zip(unique, done))
    return [mapping.get(t.strip(), t) if t.strip() else t for t in texts]


# ---------------------------------------------------------------- service

def _mmss(seconds: float) -> str:
    s = int(round(seconds or 0))
    return f"{s // 60}:{s % 60:02d}"


class LyricsService:
    """Looks lyrics up off the UI thread, one track at a time, and keeps the
    answer for the track that is playing.

    `resolve_video(video_id)` returns the widget's resolved video record
    (with `captionTracks` or `subs`/`subKinds`, `language`, `durationMs`);
    it may block for a few seconds.
    """

    def __init__(self, on_change: Callable[[], None],
                 resolve_video: Callable[[str], dict[str, Any] | None],
                 fetch: Callable[[str], Any] = http_json,
                 directory: Path | None = None,
                 translate: Callable[[list[str], str, str], list[str]] = translate_texts,
                 settings_path: Path | None = None) -> None:
        self._on_change = on_change
        self._resolve_video = resolve_video
        self._fetch = fetch
        self._translate = translate
        self._dir = directory
        self._settings_path = settings_path
        self._lock = threading.Lock()
        self._wake = threading.Event()
        self.enabled = True
        self.source = "auto"            # auto | lrclib | captions
        self.sub_lang = "en"
        # Language to show lyrics in; "" is the song's own.
        self.translate_to = self._read_settings().get("translateTo", "")
        self._want: dict[str, Any] | None = None
        self._want_tr: dict[str, Any] | None = None
        self._base: dict[str, Any] = self._empty("")
        self._tr: dict[str, Any] = {}
        self._result: dict[str, Any] = self._compose()
        self._candidates: dict[str, list[dict[str, Any]]] = {}
        self._captions: dict[str, dict[str, Any]] = {}
        threading.Thread(target=self._worker, daemon=True).start()

    # -- public

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            return dict(self._result)

    def track_changed(self, item: dict[str, Any] | None, duration_ms: int = 0) -> None:
        video_id = str((item or {}).get("videoId") or "")
        with self._lock:
            if video_id and video_id == self._base.get("videoId"):
                return
            self._tr = {}
            if not video_id:
                self._base = self._empty("")
                self._want = None
                self._result = self._compose()
                return
            self._want = {"item": dict(item or {}), "duration_ms": int(duration_ms or 0), "choice": None}
            self._base = self._empty(video_id, "loading" if self.enabled else "off")
            self._result = self._compose()
        self._on_change()
        if self.enabled:
            self._wake.set()

    def try_other(self) -> None:
        """The next entry in `choices`, wrapping round, so the button can
        never strand you on "No lyrics". Offline: ask again."""
        with self._lock:
            base = self._base
            if base.get("status") == "offline":
                choice = base.get("choice") or None
            else:
                ids = [c["id"] for c in base.get("choices") or []]
                if not ids:
                    choice = None
                else:
                    cur = base.get("choice")
                    choice = ids[(ids.index(cur) + 1) % len(ids)] if cur in ids else ids[0]
        self.select(choice, _any=True)

    def select(self, choice: str | None, _any: bool = False) -> None:
        with self._lock:
            vid = self._base.get("videoId")
            item = self._want_item_for(vid) if vid else None
            if not item or (not choice and not _any):
                return
            # Asked by hand: never the cached answer, which is what was wrong.
            self._want = {"item": item, "duration_ms": self._base.get("durationMs", 0), "choice": choice or None,
                          "fresh": True}
            self._base = dict(self._base, status="loading")
            self._tr = {}
            self._result = self._compose()
        self._on_change()
        self._wake.set()

    def set_offset(self, offset_ms: int) -> None:
        with self._lock:
            self._base = dict(self._base, offsetMs=int(offset_ms))
            base = dict(self._base)
            self._result = self._compose()
        if base.get("videoId") and base["status"] not in ("loading", "offline", "off"):
            self._save(base)
        self._on_change()

    def set_language(self, code: str) -> None:
        """Show the lyrics in `code`, or in the song's own language for "".
        Sticks for the next songs."""
        code = re.sub(r"[^a-z-]", "", str(code or "").lower())[:8]
        with self._lock:
            self.translate_to = code
            self._tr = {}
        self._write_settings({"translateTo": code})
        self._queue_translation()

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
                self._base = self._empty("")
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
                "offsetMs": 0, "title": "", "artist": "", "choice": "", "choices": [],
                "durationMs": 0, "lang": "", "langName": "", "fit": ""}

    def _compose(self) -> dict[str, Any]:
        """What the player shows: the lyrics found, in the language picked.
        Call with the lock held."""
        r = dict(self._base)
        tr = self._tr
        r.update(translateTo=self.translate_to, translatedTo="", translating=tr.get("busy", ""),
                 translateError=tr.get("error", ""))
        if tr.get("lines") is not None:
            r["lines"] = tr["lines"]
            r["translatedTo"] = tr["lang"]
            r["translatedName"] = lang_name(tr["lang"])
        return r

    def _read_settings(self) -> dict[str, Any]:
        if not self._settings_path:
            return {}
        try:
            data = json.loads(self._settings_path.read_text())
            return data if isinstance(data, dict) else {}
        except (OSError, ValueError):
            return {}

    def _write_settings(self, data: dict[str, Any]) -> None:
        if not self._settings_path:
            return
        try:
            tmp = self._settings_path.with_suffix(".tmp")
            tmp.write_text(json.dumps(data))
            tmp.replace(self._settings_path)
        except OSError:
            pass

    def _path(self, video_id: str, suffix: str = "") -> Path:
        safe = re.sub(r"[^A-Za-z0-9_-]", "_", video_id)
        return (self._dir or cache_dir()) / f"{safe}{suffix}.json"

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

    def _queue_translation(self) -> None:
        """Translate the lyrics on show if another language is picked; a
        song already in that language stays as it is."""
        with self._lock:
            base = self._base
            texts = [str(line.get("text") or "") for line in base.get("lines") or []]
            target = self.translate_to
            self._tr = {}
            if (not target or base.get("status") not in ("synced", "plain", "captions")
                    or not any(t.strip() for t in texts) or target == base.get("lang")):
                self._result = self._compose()
                job = None
            else:
                key = text_key(texts)
                cached = self._load_translation(base["videoId"], target, key)
                if cached is not None:
                    self._tr = {"lang": target, "lines": cached}
                    job = None
                else:
                    self._tr = {"busy": target}
                    job = {"videoId": base["videoId"], "lang": target, "key": key, "texts": texts,
                           "source": base.get("lang") or ""}
                self._want_tr = job
                self._result = self._compose()
        self._on_change()
        if job:
            self._wake.set()

    def _load_translation(self, video_id: str, lang: str, key: str) -> list[dict[str, Any]] | None:
        try:
            data = json.loads(self._path(video_id, f".{lang}").read_text())
        except (OSError, ValueError):
            return None
        if data.get("key") != key:
            return None
        return self._apply_translation(data.get("texts") or [])

    def _apply_translation(self, texts: list[str]) -> list[dict[str, Any]] | None:
        lines = self._base.get("lines") or []
        if len(texts) != len(lines):
            return None
        return [dict(line, text=text) for line, text in zip(lines, texts)]

    def _translate_job(self, job: dict[str, Any]) -> None:
        try:
            texts = self._translate(job["texts"], job["lang"], job["source"])
            error = ""
        except Exception:
            texts, error = None, "Couldn’t translate right now"
        with self._lock:
            base = self._base
            still = (base.get("videoId") == job["videoId"] and self.translate_to == job["lang"]
                     and text_key([str(l.get("text") or "") for l in base.get("lines") or []]) == job["key"])
            if not still:
                return
            lines = self._apply_translation(texts) if texts else None
            self._tr = {"lang": job["lang"], "lines": lines} if lines else {"error": error or "Couldn’t translate right now"}
            self._result = self._compose()
        if lines:
            try:
                path = self._path(job["videoId"], f".{job['lang']}")
                path.write_text(json.dumps({"key": job["key"], "texts": texts}))
            except OSError:
                pass
        self._on_change()

    def _worker(self) -> None:
        while True:
            self._wake.wait()
            self._wake.clear()
            with self._lock:
                want, self._want = self._want, None
                enabled = self.enabled
                job = None if want else self._want_tr
                if job:
                    self._want_tr = None
            if want and enabled:
                self._last_item = want
                video_id = str(want["item"].get("videoId") or "")
                try:
                    result = self._lookup(want)
                except Exception:
                    result = self._empty(video_id, "offline")
                with self._lock:
                    # A newer track may have started while we were looking.
                    if self._base.get("videoId") != video_id or self._want:
                        self._wake.set()
                        continue
                    self._base = result
                if result["status"] != "offline" and not result.get("partial"):
                    self._save(result)
                self._queue_translation()
                continue
            if job:
                self._translate_job(job)

    # -- finding the lyrics

    def _lookup(self, want: dict[str, Any]) -> dict[str, Any]:
        item = want["item"]
        video_id = str(item.get("videoId") or "")
        choice = want.get("choice")
        if want.get("fresh"):
            self._candidates.pop(video_id, None) if choice is None else None
        elif choice is None:
            cached = self._load(video_id)
            if cached:
                return cached

        name = str(item.get("name") or "")
        channel = str(item.get("subtitle") or "")
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
        use_lrc = self.source in ("auto", "lrclib")
        use_yt = self.source in ("auto", "captions")

        offline = False
        cands: list[dict[str, Any]] = []
        if use_lrc:
            if video_id in self._candidates:
                cands = self._candidates[video_id]
            else:
                report: dict[str, Any] = {}
                try:
                    cands = lrclib_candidates(name, channel, duration_s, self._fetch, report)
                    if report.get("failed"):
                        # Some questions went unanswered: use what came back,
                        # but ask again next time instead of keeping it.
                        offline = True
                    else:
                        self._candidates[video_id] = cands
                except Offline:
                    offline = True
        named = [c for c in cands if c["score"] >= NAME_OK]
        close = [c for c in named if c["diff"] <= MATCH_TOLERANCE_S]
        if close and close[0]["instrumental"] and choice is None:
            return dict(base, status="none", source="instrumental")
        speed = speed_hint(name)

        # A clean match (right name, right length) needs nothing from YouTube.
        exact = [c for c in close if c["synced"] and c["score"] >= NAME_STRONG]
        if exact and not speed and video_id not in self._captions and (choice is None or choice.startswith("lrc:")):
            options = self._lrc_options(exact, None, duration_s, False)
            if use_yt:
                options.append({"id": "yt", "kind": "lookup", "label": "YouTube captions", "detail": "look up"})
            hit = self._pick(options, choice)
            if hit and hit["kind"] != "lookup":
                return self._build(base, hit, options)

        caps: dict[str, Any] = self._captions.get(video_id) or {}
        if not caps and (use_yt or named):
            caps = fetch_captions(resolved(), self.sub_lang, self._fetch)
            if caps.get("offline") and not (caps.get("manual") or caps.get("auto")):
                offline = True
            else:
                self._captions[video_id] = caps
        ref = caps.get("manual") or caps.get("auto")
        options = self._lrc_options(named, ref, duration_s, speed) if use_lrc else []
        if use_yt and caps.get("manual"):
            t = caps["manual"]
            options.append({"id": "yt:manual", "kind": "manual", "track": t, "label": "YouTube captions",
                            "detail": f"uploader’s · {lang_name(t['lang'])}"})
        if use_lrc:
            timed = {o["cand"]["id"] for o in options if o.get("cand")}
            options += self._plain_options([c for c in named if c["id"] not in timed], ref,
                                           has_synced=bool(options))
        if use_yt and caps.get("auto"):
            options.append({"id": "yt:auto", "kind": "auto", "track": caps["auto"],
                            "label": "YouTube auto captions", "detail": "may be wrong"})

        if choice == "yt":
            # No usable captions: stay on the best lyrics; the list now
            # shows there is nothing from YouTube.
            hit = next((o for o in options if o["id"].startswith("yt:")), None) or self._pick(options, None)
        else:
            hit = self._pick(options, choice)
        if hit:
            return dict(self._build(base, hit, options), partial=offline and hit["kind"] != "synced")
        if offline:
            return dict(base, status="offline")
        return dict(base, status="none", choices=self._choices(options))

    @staticmethod
    def _pick(options: list[dict[str, Any]], choice: str | None) -> dict[str, Any] | None:
        if not options:
            return None
        return next((o for o in options if o["id"] == choice), options[0])

    @staticmethod
    def _choices(options: list[dict[str, Any]]) -> list[dict[str, str]]:
        return [{"id": o["id"], "label": o["label"], "detail": o["detail"]} for o in options]

    @staticmethod
    def _lrc_options(named: list[dict[str, Any]], ref: dict[str, Any] | None,
                     duration_s: float, speed: bool) -> list[dict[str, Any]]:
        """Timed LRCLIB options, best first. With the video's captions to
        compare against, each record is lined up with the video (and dropped
        when its words are not there at all)."""
        judged = bool(ref and len(ref["words"]) >= 30)
        found: list[tuple[tuple, dict[str, Any]]] = []
        # When records disagree on which side is the artist, most are right.
        votes: dict[tuple[str, str], int] = {}
        for c in named:
            key = (c["title"].lower(), c["artist"].lower())
            votes[key] = votes.get(key, 0) + 1
        for c in named:
            popular = -votes.get((c["title"].lower(), c["artist"].lower()), 0)
            if votes.get((c["artist"].lower(), c["title"].lower()), 0) > -popular:
                # Filed with artist and title swapped: show it the right way round.
                c = dict(c, title=c["artist"], artist=c["title"])
            if not c["synced"]:
                continue
            lines = parse_lrc(c["synced"])
            if not lines:
                continue
            close = c["diff"] <= MATCH_TOLERANCE_S
            ratio = duration_s / c["duration"] if duration_s and c["duration"] else 1.0
            timing = ""
            rank: tuple = ()
            if ref:
                coverage, anchors = match_words(lines, ref["words"])
                if judged and coverage < MIN_WORD_MATCH:
                    continue
                fit = fit_timing(anchors, ratio if speed else 1.0)
                if fit and coverage >= 0.2:
                    if abs(fit["scale"] - 1) > 0.01 or abs(fit["shift"]) > 400:
                        lines = retime(lines, fit["scale"], fit["shift"])
                    timing = "fit"
                    rank = (0, -round(coverage * (1 - min(1.0, fit["residual"] / 2000)), 2), popular)
            if not timing and speed and 0.6 <= ratio <= 1.6 and c["score"] >= NAME_STRONG:
                if abs(ratio - 1) > 0.01:
                    lines = retime(lines, ratio, 0)
                timing = "stretch"
                rank = (2, -c["score"], popular, c["diff"])
            if not timing and close:
                timing = "exact"
                rank = (1, -c["score"], popular, c["diff"])
            if not timing:
                continue
            detail = {"fit": f"{_mmss(c['duration'])} record, lined up with the video",
                      "stretch": f"{_mmss(c['duration'])} record, stretched to the video",
                      "exact": f"{_mmss(c['duration'])}, same length"}[timing]
            found.append((rank, {"id": f"lrc:{c['id']}", "kind": "synced", "cand": c, "lines": lines,
                                 "timing": timing, "label": f"Synced · {c['artist']} – {c['title']}",
                                 "detail": f"LRCLIB · {detail}"}))
        found.sort(key=lambda f: f[0])
        out: list[dict[str, Any]] = []
        seen: set[str] = set()
        for _, opt in found:
            # LRCLIB often holds the same lyrics several times over.
            key = " ".join(words_of(" ".join(l["text"] for l in opt["lines"])))[:400]
            if key in seen:
                continue
            seen.add(key)
            out.append(opt)
        return out[:3]

    @staticmethod
    def _plain_options(named: list[dict[str, Any]], ref: dict[str, Any] | None,
                       has_synced: bool) -> list[dict[str, Any]]:
        judged = bool(ref and len(ref["words"]) >= 30)
        out: list[dict[str, Any]] = []
        seen: set[str] = set()
        for c in sorted(named, key=lambda c: (-c["score"], c["diff"])):
            if c["diff"] > MATCH_TOLERANCE_S and c["score"] < NAME_STRONG:
                continue
            text = c["plain"] or "\n".join(l["text"] for l in parse_lrc(c["synced"]))
            if not text.strip():
                continue
            lines = plain_lines(text)
            if judged:
                coverage, _ = match_words([dict(l, ms=0) for l in lines], ref["words"])
                if coverage < MIN_WORD_MATCH:
                    continue
            key = " ".join(words_of(text))[:400]
            if key in seen:
                continue
            seen.add(key)
            out.append({"id": f"lrc:{c['id']}:plain", "kind": "plain", "cand": c, "lines": lines,
                        "label": f"Not timed · {c['artist']} – {c['title']}", "detail": "LRCLIB"})
            if len(out) >= (1 if has_synced else 2):
                break
        return out

    def _build(self, base: dict[str, Any], opt: dict[str, Any], options: list[dict[str, Any]]) -> dict[str, Any]:
        r = dict(base, choices=self._choices(options), choice=opt["id"])
        kind = opt["kind"]
        if kind in ("synced", "plain"):
            c = opt["cand"]
            r.update(status=kind, source="lrclib", lines=opt["lines"], title=c["title"], artist=c["artist"],
                     fit=opt.get("timing", ""))
            lang = detect_lang([l["text"] for l in opt["lines"]])
        else:
            t = opt["track"]
            r.update(status="captions", source=kind, lines=t["lines"])
            lang = t["lang"] or detect_lang([l["text"] for l in t["lines"]])
        r["lang"] = lang
        r["langName"] = lang_name(lang) if lang else ""
        return r
