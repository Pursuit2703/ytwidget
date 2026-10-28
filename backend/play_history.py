"""Local play history for the YT Widget backend.

Adapted from wizwam/omamusic (MIT) — same shape, generic video items
instead of YouTube Music tracks.
"""

from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

import store
from search import watch_url

MAX_ITEMS = 100


def history_path() -> Path:
    return store.config_dir() / "play-history.json"


def video_id(item: dict | None) -> str:
    source = item or {}
    return str(source.get("videoId") or source.get("id") or "").strip()


def load(path: Path | None = None) -> list[dict[str, Any]]:
    target = path or history_path()
    try:
        raw = json.loads(target.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, TypeError):
        return []
    if not isinstance(raw, list):
        return []
    return [row for row in raw if isinstance(row, dict) and video_id(row)][:MAX_ITEMS]


def save(rows: list[dict[str, Any]], path: Path | None = None) -> None:
    target = path or history_path()
    target.parent.mkdir(parents=True, exist_ok=True)
    payload = [row for row in rows if isinstance(row, dict) and video_id(row)][:MAX_ITEMS]
    target.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    try:
        target.chmod(0o600)
    except OSError:
        pass


def remember(item: dict | None, existing: list[dict[str, Any]] | None = None,
             path: Path | None = None, now: float | None = None) -> list[dict[str, Any]]:
    """Put a track at the top of the history.

    Each entry carries `playedAt` (epoch seconds of the latest play) and
    `plays` (how many times it was started). Replaying a track moves it to the
    top and keeps its count, so "most played" can be ranked from this file.
    """
    track = dict(item or {})
    vid = video_id(track)
    if not vid:
        return list(existing) if existing is not None else load(path)
    previous = 0
    rows = []
    for row in (existing if existing is not None else load(path)):
        if video_id(row) == vid:
            try:
                previous = max(previous, int(row.get("plays") or 1))
            except (TypeError, ValueError):
                previous = max(previous, 1)
        else:
            rows.append(row)
    track["videoId"] = vid
    track["plays"] = previous + 1
    track["playedAt"] = int(time.time() if now is None else now)
    if not str(track.get("externalUrl") or "").strip():
        track["externalUrl"] = watch_url(vid)
    rows.insert(0, track)
    rows = rows[:MAX_ITEMS]
    save(rows, path)
    return rows


def clear(path: Path | None = None) -> list[dict[str, Any]]:
    """Forget every play. Returns the (empty) history."""
    save([], path)
    return []
