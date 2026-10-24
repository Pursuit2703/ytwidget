"""Single door for every yt-dlp call: spacing, an hourly budget, and a breaker.

YouTube blocks an IP that asks too often, and retrying while blocked makes the
block last longer. So this module
  * spaces requests a second or two apart,
  * refuses to exceed an hourly budget,
  * on a block signal ("429", "not a bot") retries once with Firefox cookies,
    and keeps using them for an hour if that works,
  * otherwise opens a breaker (45 min, then 90, 180, 240) and refuses every
    request until it ends, so saved songs still play and nothing hammers the IP.

State survives restarts in ~/.local/state/ytwidget/gate.json. Cookies are read
from the Firefox profile's cookies.sqlite by yt-dlp; no browser is started.
"""

from __future__ import annotations

import json
import os
import random
import re
import subprocess
import threading
import time
from pathlib import Path

from request_log import log_request

BLOCK_RE = re.compile(r"429|too many requests|not a bot|confirm you.re not", re.I)
MIN_GAP = (1.5, 3.0)
HOURLY_CAP = 90
COOKIE_HOLD_SECONDS = 3600
BACKOFF_SECONDS = (2700, 5400, 10800, 14400)

_lock = threading.Lock()
# Replaced by tests.
_now = time.time
_sleep = time.sleep
_run = subprocess.run


class Blocked(RuntimeError):
    """YouTube is blocking us, or the hourly budget is spent."""


def _state_path() -> Path:
    state = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state"))
    return state / "ytwidget" / "gate.json"


def _load() -> dict:
    try:
        data = json.loads(_state_path().read_text(encoding="utf-8"))
        if isinstance(data, dict):
            return data
    except (OSError, ValueError):
        pass
    return {}


def _save(state: dict) -> None:
    path = _state_path()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(state), encoding="utf-8")
        os.replace(tmp, path)
    except OSError:
        pass


def firefox_profile() -> str:
    """Path of the Firefox profile holding cookies.sqlite, or ''."""
    override = os.environ.get("YTWIDGET_COOKIE_PROFILE")
    if override:
        return override if Path(override, "cookies.sqlite").is_file() else ""
    roots = [Path.home() / ".config" / "mozilla" / "firefox",
             Path.home() / ".mozilla" / "firefox"]
    found: list[Path] = []
    for root in roots:
        try:
            found += [p.parent for p in root.glob("*/cookies.sqlite")]
        except OSError:
            continue
    found.sort(key=lambda p: ("default-release" not in p.name, -p.stat().st_mtime))
    return str(found[0]) if found else ""


def _with_cookies(command: list[str], profile: str) -> list[str]:
    if "--cookies-from-browser" in command or "--cookies" in command:
        return command
    return [command[0], "--cookies-from-browser", f"firefox:{profile}", *command[1:]]


def _blocked_text(result: subprocess.CompletedProcess) -> bool:
    return result.returncode != 0 and bool(BLOCK_RE.search(result.stderr or ""))


def _message(seconds_left: float, budget: bool = False) -> str:
    minutes = max(1, int(seconds_left // 60) + 1)
    if budget:
        return (f"YouTube request budget used up for this hour. "
                f"Saved songs still play. Try again in {minutes} minutes.")
    return (f"YouTube is blocking requests from this connection. "
            f"Saved songs still play. Trying again in {minutes} minutes.")


def status() -> dict:
    state = _load()
    now = _now()
    recent = [t for t in state.get("recent", []) if now - t < 3600]
    return {
        "blocked": state.get("blocked_until", 0) > now,
        "seconds_left": max(0, int(state.get("blocked_until", 0) - now)),
        "using_cookies": state.get("cookies_until", 0) > now,
        "requests_last_hour": len(recent),
        "strikes": state.get("strikes", 0),
    }


def healthy() -> bool:
    """True when optional work (prefetch) is allowed: no block, budget under half."""
    info = status()
    return not info["blocked"] and info["requests_last_hour"] < HOURLY_CAP // 2


def _reserve_slot() -> float:
    """Pick the earliest start time at least a random gap after the last one."""
    with _lock:
        state = _load()
        now = _now()
        start = max(now, state.get("last_start", 0) + random.uniform(*MIN_GAP))
        state["last_start"] = start
        recent = [t for t in state.get("recent", []) if now - t < 3600]
        recent.append(start)
        state["recent"] = recent
        _save(state)
        return start - now


def note_external(kind: str, video_id: str = "") -> None:
    """Count a YouTube request made outside run() (mpv's own ytdl_hook)."""
    _reserve_slot()
    log_request(kind, video_id, True, 0, "external")


def run(command: list[str], timeout: int, kind: str = "request",
        video_id: str = "") -> subprocess.CompletedProcess:
    """Run a yt-dlp command through the gate. Raises Blocked, or
    subprocess.TimeoutExpired exactly as subprocess.run would."""
    state = _load()
    now = _now()
    if state.get("blocked_until", 0) > now:
        raise Blocked(_message(state["blocked_until"] - now))
    recent = [t for t in state.get("recent", []) if now - t < 3600]
    if len(recent) >= HOURLY_CAP:
        raise Blocked(_message(recent[0] + 3600 - now, budget=True))

    profile = firefox_profile()
    use_cookies = bool(profile) and state.get("cookies_until", 0) > now
    command = _with_cookies(command, profile) if use_cookies else command

    def attempt(cmd: list[str]) -> subprocess.CompletedProcess:
        wait = _reserve_slot()
        if wait > 0:
            _sleep(wait)
        started = _now()
        try:
            result = _run(cmd, capture_output=True, text=True, timeout=timeout, check=False)
        except subprocess.TimeoutExpired:
            log_request(kind, video_id, False, int((_now() - started) * 1000), "timeout")
            raise
        log_request(kind, video_id, result.returncode == 0,
                    int((_now() - started) * 1000),
                    (result.stderr or "").strip().splitlines()[-1][:100]
                    if result.returncode != 0 and (result.stderr or "").strip() else "")
        return result

    result = attempt(command)
    if not _blocked_text(result):
        if result.returncode == 0:
            state = _load()
            if state.get("strikes"):
                state["strikes"] = 0
                _save(state)
        return result

    if profile and not use_cookies:
        retry = attempt(_with_cookies(command, profile))
        if not _blocked_text(retry):
            state = _load()
            state["cookies_until"] = _now() + COOKIE_HOLD_SECONDS
            _save(state)
            log_request("cookie_rescue", video_id, retry.returncode == 0, 0)
            return retry

    state = _load()
    strikes = int(state.get("strikes", 0))
    delay = BACKOFF_SECONDS[min(strikes, len(BACKOFF_SECONDS) - 1)]
    state["strikes"] = strikes + 1
    state["blocked_until"] = _now() + delay
    state["cookies_until"] = 0
    _save(state)
    log_request("breaker_open", video_id, False, 0, f"{delay // 60} min")
    raise Blocked(_message(delay))
