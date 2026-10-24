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

import fcntl
import json
import os
import random
import re
import subprocess
import threading
import time
from contextlib import contextmanager
from pathlib import Path

import vpn
from request_log import log_request

# Not a bare "429": that also matches video ids and timings in stderr.
BLOCK_RE = re.compile(r"HTTP Error 429|too many requests|not a bot|confirm you.re not", re.I)
COOKIE_ERROR_RE = re.compile(r"cookie", re.I)
VPN_403_RE = re.compile(r"HTTP Error 403|403: Forbidden", re.I)
# After the VPN rescued a blocked home IP, go straight to the VPN this long.
VPN_HOLD_SECONDS = 3600
# Optional work never waits longer than this for its slot.
MAX_OPTIONAL_WAIT = 5.0
OPTIONAL_KINDS = {"prefetch"}
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
        tmp = path.with_name(f"{path.name}.{os.getpid()}.{threading.get_ident()}.tmp")
        tmp.write_text(json.dumps(state), encoding="utf-8")
        os.replace(tmp, path)
    except OSError:
        pass


@contextmanager
def _transaction():
    """Read-modify-write gate.json under a thread lock and a cross-process
    flock, so the backend, Hazel and the self-test never undo each other."""
    path = _state_path()
    with _lock:
        handle = None
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            handle = open(path.with_suffix(".lock"), "a")
            fcntl.flock(handle, fcntl.LOCK_EX)
        except OSError:
            pass
        try:
            state = _load()
            yield state
            _save(state)
        finally:
            if handle is not None:
                fcntl.flock(handle, fcntl.LOCK_UN)
                handle.close()


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
    def key(p: Path) -> tuple:
        try:
            mtime = p.stat().st_mtime
        except OSError:
            mtime = 0
        return ("default-release" not in p.name, -mtime)
    found.sort(key=key)
    return str(found[0]) if found else ""


def _with_cookies(command: list[str], profile: str) -> list[str]:
    if "--cookies-from-browser" in command or "--cookies" in command:
        return command
    return [command[0], "--cookies-from-browser", f"firefox:{profile}", *command[1:]]


def _blocked_text(result: subprocess.CompletedProcess, vpn_path: bool = False) -> bool:
    """A block signal. Through the VPN a 403 also counts: the server's shared
    IP is refused, which rotating fixes."""
    if result.returncode == 0:
        return False
    text = result.stderr or ""
    return bool(BLOCK_RE.search(text) or (vpn_path and VPN_403_RE.search(text)))


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


def _reserve_slot(max_wait: float | None = None) -> float | None:
    """Pick the earliest start time at least a random gap after the last one.
    Returns the wait, or None when it would exceed max_wait (nothing reserved)."""
    with _transaction() as state:
        now = _now()
        start = max(now, state.get("last_start", 0) + random.uniform(*MIN_GAP))
        if max_wait is not None and start - now > max_wait:
            return None
        state["last_start"] = start
        recent = [t for t in state.get("recent", []) if now - t < 3600]
        recent.append(start)
        state["recent"] = recent
        return start - now


def count(kind: str) -> None:
    """Count a light request (InnerTube search) against the hourly budget
    without spacing it; typing in the search box must stay instant."""
    with _transaction() as state:
        now = _now()
        recent = [t for t in state.get("recent", []) if now - t < 3600]
        recent.append(now)
        state["recent"] = recent


def note_external(kind: str, video_id: str = "") -> None:
    """Count and space a YouTube request made outside run() (mpv's ytdl_hook)."""
    wait = _reserve_slot()
    if wait:
        _sleep(wait)
    log_request(kind, video_id, True, 0, "external")


def routes_via_vpn() -> bool:
    """True when YouTube requests should go straight to the VPN rung: mode
    "always", or "fallback" while the home IP is known to be blocked."""
    vmode = vpn.mode()
    if vmode == "always":
        return True
    return vmode == "fallback" and _load().get("vpn_until", 0) > _now()


def _proxied(command: list[str]) -> list[str]:
    return [command[0], "--proxy", vpn.PROXY_URL, *command[1:]]


def run(command: list[str], timeout: int, kind: str = "request",
        video_id: str = "") -> subprocess.CompletedProcess:
    """Run a yt-dlp command through the gate. Raises Blocked, or
    subprocess.TimeoutExpired exactly as subprocess.run would.

    Ladder: direct -> Firefox cookies -> VPN (at most 2 servers) -> breaker.
    A result that came through the VPN carries `.vpn = (server, generation)`,
    because its stream URLs only play through that same tunnel."""
    state = _load()
    now = _now()
    if state.get("blocked_until", 0) > now:
        raise Blocked(_message(state["blocked_until"] - now))
    recent = [t for t in state.get("recent", []) if now - t < 3600]
    if len(recent) >= HOURLY_CAP:
        raise Blocked(_message(recent[0] + 3600 - now, budget=True))

    vmode = vpn.mode()
    base = list(command)
    profile = firefox_profile()

    def attempt(cmd: list[str]) -> subprocess.CompletedProcess:
        wait = _reserve_slot(MAX_OPTIONAL_WAIT if kind in OPTIONAL_KINDS else None)
        if wait is None:
            raise Blocked("Busy; skipped optional request.")
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
        result.vpn = None
        return result

    def via_vpn() -> subprocess.CompletedProcess | None:
        """Up to two servers. None means the VPN rung gave up."""
        try:
            tag = vpn.ensure_up()
        except vpn.VpnError as exc:
            log_request("vpn", video_id, False, 0, str(exc))
            if vmode == "always":
                raise Blocked(str(exc)) from exc
            return None
        for tries in range(2):
            result = attempt(_proxied(base))
            if not _blocked_text(result, vpn_path=True):
                vpn.touch()
                result.vpn = tag
                return result
            if tries == 1:
                break
            try:
                tag = vpn.rotate((result.stderr or "").strip().splitlines()[-1]
                                 if (result.stderr or "").strip() else "blocked")
            except vpn.VpnError as exc:
                log_request("vpn", video_id, False, 0, str(exc))
                break
            log_request("vpn_rotate", video_id, True, 0, tag[0])
        # Both servers blocked: the next request starts on a fresh head.
        try:
            vpn.rotate("blocked")
        except vpn.VpnError:
            pass
        return None

    if vmode == "always" or (vmode == "fallback" and state.get("vpn_until", 0) > now):
        result = via_vpn()
        if result is not None:
            return result
        if vmode == "always":
            return _open_breaker(video_id, "VPN servers are blocked too")
        # "fallback" whose tunnel failed: try the home connection after all.

    use_cookies = bool(profile) and state.get("cookies_until", 0) > now
    command = _with_cookies(base, profile) if use_cookies else base

    result = attempt(command)
    if (use_cookies and result.returncode != 0 and not _blocked_text(result)
            and COOKIE_ERROR_RE.search(result.stderr or "")):
        # Cookies themselves broke (profile locked, decrypt failure): stop
        # using them and try once more the plain way.
        with _transaction() as state:
            state["cookies_until"] = 0
        use_cookies = False
        command = base
        result = attempt(command)
    if not _blocked_text(result):
        if result.returncode == 0:
            with _transaction() as state:
                if state.get("strikes"):
                    state["strikes"] = 0
        return result

    if profile and not use_cookies:
        retry = attempt(_with_cookies(base, profile))
        if retry.returncode == 0:
            with _transaction() as state:
                state["cookies_until"] = _now() + COOKIE_HOLD_SECONDS
            log_request("cookie_rescue", video_id, True, 0)
            return retry

    if vmode == "fallback":
        result = via_vpn()
        if result is not None:
            # The home IP is blocked: keep using the VPN for a while instead
            # of knocking on the blocked door before every request.
            with _transaction() as state:
                state["vpn_until"] = _now() + VPN_HOLD_SECONDS
            log_request("vpn_rescue", video_id, result.returncode == 0, 0, result.vpn[0])
            return result

    return _open_breaker(video_id)


def _open_breaker(video_id: str, why: str = "") -> subprocess.CompletedProcess:
    with _transaction() as state:
        now = _now()
        if state.get("blocked_until", 0) > now:
            # Another request already opened the breaker for this same block;
            # one block event is one strike.
            delay = state["blocked_until"] - now
        else:
            strikes = int(state.get("strikes", 0))
            delay = BACKOFF_SECONDS[min(strikes, len(BACKOFF_SECONDS) - 1)]
            state["strikes"] = strikes + 1
            state["blocked_until"] = now + delay
        state["cookies_until"] = 0
        state["vpn_until"] = 0
    log_request("breaker_open", video_id, False, 0, f"{int(delay) // 60} min {why}".strip())
    raise Blocked(_message(delay))
