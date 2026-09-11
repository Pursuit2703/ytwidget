"""Persist the in-memory play queue across backend restarts.

Adapted from wizwam/omamusic (MIT).
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import store
from play_history import video_id

MAX_ITEMS = 200
REPEAT_MODES = ("off", "context", "track")


def queue_path() -> Path:
    return store.config_dir() / "play-queue.json"


def load(path: Path | None = None) -> dict[str, Any] | None:
    target = path or queue_path()
    try:
        raw = json.loads(target.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, TypeError):
        return None
    if not isinstance(raw, dict):
        return None
    items = [row for row in (raw.get("items") or [])
             if isinstance(row, dict) and video_id(row)]
    try:
        index = int(raw.get("index") or 0)
    except (TypeError, ValueError):
        index = 0
    try:
        position_ms = max(0, int(raw.get("position_ms") or 0))
    except (TypeError, ValueError):
        position_ms = 0
    repeat = str(raw.get("repeat") or "off")
    if repeat not in REPEAT_MODES:
        repeat = "off"
    return _clip({
        "items": items,
        "index": index,
        "shuffle": bool(raw.get("shuffle")),
        "repeat": repeat,
        "position_ms": position_ms,
        "playing": bool(raw.get("playing")),
    })


def save(payload: dict[str, Any] | None, path: Path | None = None) -> dict[str, Any]:
    target = path or queue_path()
    target.parent.mkdir(parents=True, exist_ok=True)
    session = _clip(payload or {})
    target.write_text(json.dumps(session, ensure_ascii=False, indent=2) + "\n",
                      encoding="utf-8")
    try:
        target.chmod(0o600)
    except OSError:
        pass
    return session


def _clip(payload: dict[str, Any]) -> dict[str, Any]:
    items = [row for row in (payload.get("items") or [])
             if isinstance(row, dict) and video_id(row)]
    try:
        index = int(payload.get("index") or 0)
    except (TypeError, ValueError):
        index = 0
    if items:
        index = max(0, min(index, len(items) - 1))
        if len(items) > MAX_ITEMS:
            start = min(index, max(0, len(items) - MAX_ITEMS))
            start = max(0, min(start, index))
            end = min(len(items), start + MAX_ITEMS)
            start = max(0, end - MAX_ITEMS)
            items = items[start:end]
            index = index - start
    else:
        index = -1
    try:
        position_ms = max(0, int(payload.get("position_ms") or 0))
    except (TypeError, ValueError):
        position_ms = 0
    repeat = str(payload.get("repeat") or "off")
    if repeat not in REPEAT_MODES:
        repeat = "off"
    return {
        "items": items,
        "index": index,
        "shuffle": bool(payload.get("shuffle")),
        "repeat": repeat,
        "position_ms": position_ms,
        "playing": bool(payload.get("playing")),
    }
