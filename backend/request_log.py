"""Append-only log of every request this backend makes to YouTube.

One JSON object per line in ~/.local/state/ytwidget/requests.jsonl, so the
real number of requests per play can be counted with jq. Never raises.
"""

from __future__ import annotations

import json
import os
import time
from pathlib import Path


def log_path() -> Path:
    state = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state"))
    return state / "ytwidget" / "requests.jsonl"


def log_request(kind: str, video_id: str = "", ok: bool = True,
                ms: int = 0, detail: str = "") -> None:
    entry = {
        "ts": round(time.time(), 3),
        "kind": kind,
        "id": video_id,
        "ok": bool(ok),
        "ms": int(ms),
    }
    if detail:
        entry["detail"] = detail[:120]
    try:
        path = log_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(entry) + "\n")
    except OSError:
        pass
