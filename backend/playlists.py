"""Local named playlists (not synced to any account)."""

from __future__ import annotations

import json
import re
import time
from pathlib import Path
from typing import Any

import store
from play_history import video_id

MAX_PLAYLISTS = 100
MAX_ITEMS_PER_PLAYLIST = 500


class PlaylistError(RuntimeError):
    pass


def playlists_path() -> Path:
    return store.config_dir() / "playlists.json"


def _slugify(name: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", name.strip().lower()).strip("-")
    return slug or f"playlist-{int(time.time())}"


def _load_all(path: Path | None = None) -> dict[str, Any]:
    target = path or playlists_path()
    try:
        raw = json.loads(target.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, TypeError):
        return {}
    return raw if isinstance(raw, dict) else {}


def _save_all(data: dict[str, Any], path: Path | None = None) -> None:
    target = path or playlists_path()
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    try:
        target.chmod(0o600)
    except OSError:
        pass


def list_playlists(path: Path | None = None) -> list[dict[str, Any]]:
    data = _load_all(path)
    out = []
    for playlist_id, entry in data.items():
        if not isinstance(entry, dict):
            continue
        items = [row for row in entry.get("items", []) if isinstance(row, dict)]
        out.append({
            "id": playlist_id,
            "name": entry.get("name", playlist_id),
            "count": len(items),
            "createdAt": entry.get("createdAt", 0),
        })
    out.sort(key=lambda row: row.get("createdAt", 0), reverse=True)
    return out


def get_playlist(playlist_id: str, path: Path | None = None) -> dict[str, Any]:
    data = _load_all(path)
    entry = data.get(playlist_id)
    if not isinstance(entry, dict):
        raise PlaylistError("Playlist not found")
    return {
        "id": playlist_id,
        "name": entry.get("name", playlist_id),
        "items": [row for row in entry.get("items", []) if isinstance(row, dict)],
    }


def create_playlist(name: str, items: list[dict[str, Any]] | None = None,
                     path: Path | None = None) -> dict[str, Any]:
    name = str(name or "").strip()
    if not name:
        raise PlaylistError("Playlist name is required")
    data = _load_all(path)
    if len(data) >= MAX_PLAYLISTS:
        raise PlaylistError("Too many playlists")
    playlist_id = _slugify(name)
    suffix = 2
    base_id = playlist_id
    while playlist_id in data:
        playlist_id = f"{base_id}-{suffix}"
        suffix += 1
    tracks = [row for row in (items or []) if isinstance(row, dict) and video_id(row)]
    data[playlist_id] = {
        "name": name,
        "items": tracks[:MAX_ITEMS_PER_PLAYLIST],
        "createdAt": time.time(),
    }
    _save_all(data, path)
    return {"id": playlist_id, "name": name, "count": len(tracks)}


def delete_playlist(playlist_id: str, path: Path | None = None) -> None:
    data = _load_all(path)
    data.pop(playlist_id, None)
    _save_all(data, path)


def add_to_playlist(playlist_id: str, item: dict[str, Any], path: Path | None = None) -> dict[str, Any]:
    data = _load_all(path)
    entry = data.get(playlist_id)
    if not isinstance(entry, dict):
        raise PlaylistError("Playlist not found")
    if not video_id(item):
        raise PlaylistError("Item has no video id")
    items = [row for row in entry.get("items", []) if isinstance(row, dict)]
    if not any(video_id(row) == video_id(item) for row in items):
        items.append(item)
    entry["items"] = items[:MAX_ITEMS_PER_PLAYLIST]
    data[playlist_id] = entry
    _save_all(data, path)
    return {"id": playlist_id, "count": len(entry["items"])}


def remove_from_playlist(playlist_id: str, target_video_id: str,
                          path: Path | None = None) -> dict[str, Any]:
    data = _load_all(path)
    entry = data.get(playlist_id)
    if not isinstance(entry, dict):
        raise PlaylistError("Playlist not found")
    items = [row for row in entry.get("items", [])
             if isinstance(row, dict) and video_id(row) != target_video_id]
    entry["items"] = items
    data[playlist_id] = entry
    _save_all(data, path)
    return {"id": playlist_id, "count": len(items)}
