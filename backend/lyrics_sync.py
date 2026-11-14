"""Check timed lyrics against the audio that is actually playing.

Every lyric line should start where a voice comes in, so the loudness of the
voice range (roughly 250 Hz to 4 kHz) jumps up near each line's timestamp.
While a song plays we record that loudness against the song position, turn
it into an "onset" curve (how much it rose over the last 300 ms), and slide
the line timestamps back and forth by up to three seconds to find the shift
where lines land on onsets best.

  clear best shift, close to the current one   -> "ok"
  clear best shift, far from it                -> apply it, "adjusted"
  no shift lines up after plenty of lines      -> "doubtful" (probably the
                                                  wrong song or version)

It never overrides a timing the user set by hand.
"""

from __future__ import annotations

import math
import threading
import time
from typing import Any, Callable

# Voice range, in Hz, against the spectrum's band edges.
VOICE_LOW = 250.0
VOICE_HIGH = 4000.0

BIN_MS = 50
SEARCH_MS = 3000
BASELINE_BINS = 6          # 300 ms of history for the onset
WINDOW_BEFORE_MS = 100     # a line may light a moment before the voice
WINDOW_AFTER_MS = 150

ANALYSE_EVERY_S = 5.0
MIN_LINES = 10             # lines heard before any verdict
DOUBT_LINES = 24           # lines heard before calling it doubtful
GIVE_UP_S = 240.0          # stop listening after this much audio
APPLY_IF_OFF_BY_MS = 250

CLEAR_Z = 3.5
CLEAR_RATIO = 1.15
DOUBT_Z = 1.3
CLEAR_HITS = 0.7          # share of lines that land on a strong rise
DOUBT_HITS = 0.35


def onset_curve(frames: list[tuple[float, float]]) -> tuple[float, list[float]]:
    """Frames of (song_ms, energy) -> (start_ms, onset per 50 ms bin)."""
    if not frames:
        return 0.0, []
    start = min(f[0] for f in frames)
    end = max(f[0] for f in frames)
    count = int((end - start) / BIN_MS) + 1
    sums = [0.0] * count
    hits = [0] * count
    for ms, energy in frames:
        i = int((ms - start) / BIN_MS)
        if 0 <= i < count:
            sums[i] += energy
            hits[i] += 1
    env: list[float | None] = [sums[i] / hits[i] if hits[i] else None for i in range(count)]
    # Fill short holes so a dropped frame does not read as an onset.
    last = None
    for i in range(count):
        if env[i] is None:
            env[i] = last
        else:
            last = env[i]
    onsets = [0.0] * count
    for i in range(count):
        cur = env[i]
        if cur is None:
            continue
        # Rise over the last 100 ms against the quietest of the 300 ms
        # before: sharp at the moment a voice comes in, flat while it holds.
        prev = [v for v in env[max(0, i - BASELINE_BINS):max(0, i - 1)] if v is not None]
        if not prev:
            continue
        onsets[i] = max(0.0, cur - min(prev))
        if i >= 2 and env[i - 2] is not None:
            onsets[i] = min(onsets[i], max(0.0, cur - env[i - 2]))
    return start, onsets


def score_shifts(starts: list[float], curve_start: float, onsets: list[float]) -> tuple[dict[int, float], int]:
    """Mean onset peak at each line start, for every shift. Returns the
    scores and how many lines fell inside the heard audio."""
    if not onsets:
        return {}, 0
    curve_end = curve_start + len(onsets) * BIN_MS
    usable = [s for s in starts
              if s - SEARCH_MS - WINDOW_BEFORE_MS >= curve_start
              and s + SEARCH_MS + WINDOW_AFTER_MS <= curve_end]
    if not usable:
        return {}, 0
    # A "hit" is a line landing on a clearly strong onset (top fifth of
    # all the rises heard). The score is the mean onset at the line starts;
    # the hit rate is kept per shift for the verdict.
    rising = sorted(v for v in onsets if v > 0)
    strong = rising[int(len(rising) * 0.8)] if rising else 0.0
    scores: dict[int, float] = {}
    hits: dict[int, float] = {}
    for d in range(-SEARCH_MS, SEARCH_MS + 1, BIN_MS):
        total = 0.0
        hit = 0
        for s in usable:
            lo = int((s + d - WINDOW_BEFORE_MS - curve_start) / BIN_MS)
            hi = int((s + d + WINDOW_AFTER_MS - curve_start) / BIN_MS)
            peak = max(onsets[max(0, lo):max(0, hi) + 1] or [0.0])
            total += peak
            if strong > 0 and peak >= strong:
                hit += 1
        scores[d] = total / len(usable)
        hits[d] = hit / len(usable)
    score_shifts.hits = hits
    return scores, len(usable)


def verdict(scores: dict[int, float], lines: int, hits: dict[int, float] | None = None) -> dict[str, Any]:
    """Best shift and how sure we are of it."""
    if not scores or lines < MIN_LINES:
        return {"status": "checking"}
    values = sorted(scores.values())
    median = values[len(values) // 2]
    mean = sum(values) / len(values)
    std = math.sqrt(sum((v - mean) ** 2 for v in values) / len(values)) or 1e-9
    best = max(scores.values())
    # The middle of the plateau of near-best shifts, not its first edge.
    near = [d for d, v in scores.items() if v >= best * 0.97]
    peak = max(scores, key=lambda d: scores[d])
    near = [d for d in near if abs(d - peak) <= 400]
    best_d = int(round(sum(near) / len(near) / BIN_MS)) * BIN_MS
    others = [v for d, v in scores.items() if abs(d - best_d) > 400]
    second = max(others) if others else 0.0
    z = (best - median) / std
    ratio = best / second if second > 0 else float("inf")
    hit = (hits or {}).get(best_d, 0.0)
    if z >= CLEAR_Z and ratio >= CLEAR_RATIO and hit >= CLEAR_HITS:
        return {"status": "clear", "shift": best_d, "z": round(z, 2), "hits": round(hit, 2)}
    # Doubtful only when both say so: nothing stands out and few lines land.
    if lines >= DOUBT_LINES and z < DOUBT_Z and hit < DOUBT_HITS:
        return {"status": "doubtful", "z": round(z, 2), "hits": round(hit, 2)}
    return {"status": "checking", "z": round(z, 2), "hits": round(hit, 2)}


class LyricsSync:
    """Fed raw spectrum frames from the audio thread; decides in the
    background. `position()` gives (video_id, song_ms, playing);
    `lyrics()` the lyrics snapshot; `report(sync)` publishes the result and
    `apply(offset_ms)` sets an automatic offset."""

    def __init__(self, band_edges: tuple[float, ...],
                 position: Callable[[], tuple[str, float, bool]],
                 lyrics: Callable[[], dict[str, Any]],
                 report: Callable[[dict[str, Any]], None],
                 apply: Callable[[int], None]) -> None:
        self._voice = [i for i in range(len(band_edges) - 1)
                       if band_edges[i] >= VOICE_LOW and band_edges[i + 1] <= VOICE_HIGH]
        self._position = position
        self._lyrics = lyrics
        self._report = report
        self._apply = apply
        self._lock = threading.Lock()
        self._video = ""
        self._key = ""
        self._frames: list[tuple[float, float]] = []
        self._heard_s = 0.0
        self._last_frame = 0.0
        self._next_analysis = 0.0
        self._done = False
        self._busy = False

    def feed(self, raw_bands: list[float]) -> None:
        video, song_ms, playing = self._position()
        now = time.monotonic()
        with self._lock:
            if video != self._video:
                self._reset(video)
            if not video or not playing or self._done:
                self._last_frame = now
                return
            energy = math.log1p(sum(raw_bands[i] for i in self._voice if i < len(raw_bands)))
            self._frames.append((song_ms, energy))
            if 0 < now - self._last_frame < 0.5:
                self._heard_s += now - self._last_frame
            self._last_frame = now
            due = now >= self._next_analysis and not self._busy
            if due:
                self._next_analysis = now + ANALYSE_EVERY_S
                self._busy = True
        if due:
            threading.Thread(target=self._analyse, daemon=True).start()

    def lyrics_changed(self) -> None:
        """A different match or a hand-set offset: judge again from the audio
        already heard."""
        with self._lock:
            self._done = False
            self._next_analysis = 0.0

    def _reset(self, video: str) -> None:
        self._video = video
        self._key = ""
        self._frames = []
        self._heard_s = 0.0
        self._done = False
        self._next_analysis = time.monotonic() + ANALYSE_EVERY_S

    def _analyse(self) -> None:
        try:
            snap = self._lyrics() or {}
            with self._lock:
                frames = list(self._frames)
                video = self._video
                heard = self._heard_s
            if snap.get("videoId") != video or snap.get("status") not in ("synced", "captions"):
                return
            starts = [float(l.get("ms", 0)) for l in snap.get("lines") or []
                      if str(l.get("text") or "").strip() and float(l.get("ms", -1)) >= 0]
            curve_start, onsets = onset_curve(frames)
            scores, lines = score_shifts(starts, curve_start, onsets)
            v = verdict(scores, lines, getattr(score_shifts, "hits", None))
            current = int(snap.get("offsetMs") or 0)
            user_set = snap.get("offsetBy") == "user"
            sync: dict[str, Any] = {"status": "checking", "lines": lines}
            if v["status"] == "clear":
                shift = int(v["shift"])
                if not user_set and abs(shift - current) > APPLY_IF_OFF_BY_MS:
                    self._apply(shift)
                    sync = {"status": "adjusted", "offsetMs": shift, "lines": lines, "z": v["z"]}
                else:
                    sync = {"status": "ok", "offsetMs": shift, "lines": lines, "z": v["z"]}
                with self._lock:
                    self._done = True
            elif v["status"] == "doubtful":
                sync = {"status": "doubtful", "lines": lines, "z": v["z"]}
                with self._lock:
                    self._done = True
            elif heard >= GIVE_UP_S:
                sync = {"status": "unknown", "lines": lines}
                with self._lock:
                    self._done = True
            self._report(sync)
        finally:
            with self._lock:
                self._busy = False
