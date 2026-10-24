"""ProtonVPN for YouTube traffic only, through a userspace WireGuard proxy.

wireproxy runs as the user unit ytwidget-vpn.service and serves an HTTP proxy
on 127.0.0.1:25345. Nothing else on the machine is routed through it; system
routing and the `protonvpn` CLI are never touched.

Servers are the Proton WireGuard configs in ~/.config/ytwidget/vpn/*.conf
(read only). They form a queue in ~/.local/state/ytwidget/vpn_queue.json; the
head is the active server, reached through the symlink active.conf that the
wireproxy config points at. Switching repoints the symlink and restarts the
unit (one tunnel at a time, ~1 s). A blocked server goes to the end of the
queue; there are no cooldowns.

Mode lives in ~/.config/ytwidget/vpn.json: "off", "fallback" (default) or
"always".
"""

from __future__ import annotations

import fcntl
import json
import os
import socket
import subprocess
import threading
import time
import urllib.request
from contextlib import contextmanager
from pathlib import Path

PROXY_HOST = "127.0.0.1"
PROXY_PORT = 25345
PROXY_URL = f"http://{PROXY_HOST}:{PROXY_PORT}"
UNIT = "ytwidget-vpn.service"
IP_CHECK_URL = "https://api.ipify.org"
IDLE_STOP_SECONDS = 30 * 60
MODES = ("off", "fallback", "always")
DEFAULT_MODE = "fallback"

_lock = threading.Lock()
# Replaced by tests.
_now = time.time
def _systemctl_real(*args):
    try:
        return subprocess.run(["systemctl", "--user", *args], capture_output=True,
                              text=True, timeout=20, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        return subprocess.CompletedProcess(args, 1, "", str(exc))


_systemctl = _systemctl_real


class VpnError(RuntimeError):
    """A sentence safe to show or speak."""


def config_dir() -> Path:
    return Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "ytwidget"


def server_dir() -> Path:
    return config_dir() / "vpn"


def active_link() -> Path:
    return server_dir() / "active.conf"


def _state_path() -> Path:
    state = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state"))
    return state / "ytwidget" / "vpn_queue.json"


# ----------------------------------------------------------------- mode

def mode() -> str:
    try:
        value = json.loads((config_dir() / "vpn.json").read_text(encoding="utf-8")).get("mode")
    except (OSError, ValueError, AttributeError):
        value = None
    return value if value in MODES else DEFAULT_MODE


def set_mode(value: str) -> str:
    if value not in MODES:
        raise ValueError(f"vpn mode must be one of {', '.join(MODES)}")
    path = config_dir() / "vpn.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f"vpn.json.{os.getpid()}.tmp")
    tmp.write_text(json.dumps({"mode": value}), encoding="utf-8")
    os.replace(tmp, path)
    if value == "off":
        stop()
    return value


# ----------------------------------------------------------------- queue state

_switch_lock = threading.Lock()


@contextmanager
def _switching():
    """Only one thread/process switches the tunnel at a time. Held across the
    slow restart + ipify check, but never together with the state lock, so
    readers (generation, current, status) never wait on a switch."""
    path = _state_path().with_name("vpn_switch.lock")
    with _switch_lock:
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "a") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(handle, fcntl.LOCK_UN)


def _read() -> dict:
    """Lock-free snapshot; writers replace the file atomically."""
    try:
        state = json.loads(_state_path().read_text(encoding="utf-8"))
        return state if isinstance(state, dict) else {}
    except (OSError, ValueError):
        return {}

@contextmanager
def _transaction():
    """Read-modify-write the queue under a thread lock and a cross-process flock."""
    path = _state_path()
    with _lock:
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path.with_suffix(".lock"), "a") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            try:
                try:
                    state = json.loads(path.read_text(encoding="utf-8"))
                    if not isinstance(state, dict):
                        state = {}
                except (OSError, ValueError):
                    state = {}
                yield state
                tmp = path.with_name(f"{path.name}.{os.getpid()}.{threading.get_ident()}.tmp")
                tmp.write_text(json.dumps(state), encoding="utf-8")
                os.replace(tmp, path)
            finally:
                fcntl.flock(handle, fcntl.LOCK_UN)


def available() -> list[str]:
    try:
        return sorted(p.name for p in server_dir().glob("*.conf")
                      if p.name != active_link().name and p.is_file())
    except OSError:
        return []


def _synced(state: dict) -> list[str]:
    """Queue order kept; vanished configs drop out, new ones join at the end."""
    present = available()
    queue = [name for name in state.get("queue", []) if name in present]
    queue += [name for name in present if name not in queue]
    state["queue"] = queue
    return queue


def queue() -> list[str]:
    with _transaction() as state:
        return list(_synced(state))


# ----------------------------------------------------------------- tunnel

def unit_active() -> bool:
    try:
        return _systemctl("is-active", "--quiet", UNIT).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def proxy_listening(timeout: float = 0.5) -> bool:
    try:
        with socket.create_connection((PROXY_HOST, PROXY_PORT), timeout=timeout):
            return True
    except OSError:
        return False


def exit_ip(via_proxy: bool = True, timeout: float = 8.0) -> str:
    """One non-YouTube request to learn the public IP. '' on failure."""
    handlers = [urllib.request.ProxyHandler(
        {"http": PROXY_URL, "https": PROXY_URL} if via_proxy else {})]
    opener = urllib.request.build_opener(*handlers)
    try:
        with opener.open(IP_CHECK_URL, timeout=timeout) as response:
            return response.read(64).decode("ascii", "replace").strip()
    except Exception:  # noqa: BLE001 - any failure means "tunnel not usable"
        return ""


def _point_at(name: str) -> None:
    link = active_link()
    tmp = link.with_name(f".active.{os.getpid()}.tmp")
    tmp.unlink(missing_ok=True)
    tmp.symlink_to(name)
    os.replace(tmp, link)


def _start_on(name: str) -> bool:
    """Point the tunnel at one server and prove it with one ipify request."""
    _point_at(name)
    _systemctl("restart", UNIT)
    deadline = _now() + 6
    while _now() < deadline and not proxy_listening():
        time.sleep(0.1)
    return bool(exit_ip())


def _link_points_at(name: str) -> bool:
    return os.path.realpath(active_link()) == os.path.realpath(server_dir() / name)


def ensure_up() -> tuple[str, int]:
    """Make sure the tunnel runs on the queue head. Returns (server, generation);
    the generation changes on every switch so stream URLs can be re-resolved.
    Raises VpnError only."""
    try:
        with _switching():
            return _ensure_up()
    except VpnError:
        raise
    except (OSError, subprocess.SubprocessError, ValueError) as exc:
        raise VpnError(f"The YouTube VPN failed: {exc}") from exc


def _ensure_up() -> tuple[str, int]:
    with _transaction() as state:
        order = list(_synced(state))
        active = state.get("active")
        gen = int(state.get("generation", 0))
    if not order:
        raise VpnError("No VPN servers are set up for YouTube. Add Proton configs to "
                       f"{server_dir()}.")
    if active == order[0] and proxy_listening() and _link_points_at(active) and unit_active():
        touch()
        return active, gen
    dead: list[str] = []
    chosen = None
    for name in order:
        if _start_on(name):
            chosen = name
            break
        dead.append(name)  # dead tunnel: to the back, try the next
    with _transaction() as state:
        queue_now = _synced(state)
        for name in dead:
            if name in queue_now:
                queue_now.remove(name)
                queue_now.append(name)
        if chosen is None:
            state["active"] = None
        else:
            if chosen in queue_now:
                queue_now.remove(chosen)
                queue_now.insert(0, chosen)
            state["active"] = chosen
            state["generation"] = gen = int(state.get("generation", 0)) + 1
            state["last_used"] = _now()
    if chosen is None:
        _systemctl("stop", UNIT)
        raise VpnError("None of the VPN servers answered.")
    return chosen, gen


def rotate(reason: str = "", tag: tuple[str, int] | None = None) -> tuple[str, int]:
    """The server in `tag` is blocked: send it to the back and switch. If
    another request already rotated away from it, just use the new head."""
    try:
        with _switching():
            with _transaction() as state:
                order = _synced(state)
                stale = tag is not None and (state.get("active") != tag[0]
                                             or int(state.get("generation", 0)) != tag[1])
                if not stale:
                    blocked = tag[0] if tag else (order[0] if order else None)
                    if blocked in order:
                        order.remove(blocked)
                        order.append(blocked)
                    state["active"] = None
                    state["last_rotation"] = {"ts": _now(), "server": blocked,
                                              "reason": reason[:120]}
    except (OSError, ValueError) as exc:
        raise VpnError(f"The YouTube VPN failed: {exc}") from exc
    return ensure_up()


def generation() -> int:
    state = _read()
    return int(state.get("generation", 0)) if state.get("active") else -1


def current(tag: tuple[str, int] | None) -> bool:
    """Is a URL resolved through `tag` (None = home connection) still usable?"""
    if not tag:
        return mode() != "always"  # never replay a home-IP URL in "always" mode
    return generation() == tag[1] and proxy_listening()


def route_ok(tag: tuple[str, int] | None) -> bool:
    try:
        return current(tag)
    except Exception:  # noqa: BLE001 - a broken check means "resolve again"
        return False


def touch() -> None:
    with _transaction() as state:
        state["last_used"] = _now()


def stop() -> None:
    _systemctl("stop", UNIT)
    with _transaction() as state:
        state["active"] = None


def stop_if_idle() -> bool:
    with _switching():  # an ensure_up cannot slip in between check and stop
        state = _read()
        idle = bool(state.get("active")) and _now() - state.get("last_used", 0) > IDLE_STOP_SECONDS
        if idle or (not state.get("active") and unit_active()):
            stop()
            return True
    return False


def status(check_ips: bool = False) -> dict:
    with _transaction() as state:
        order = _synced(state)
        info = {
            "mode": mode(),
            "active": state.get("active"),
            "queue": order,
            "unit_active": unit_active(),
            "proxy_listening": proxy_listening(),
            "last_rotation": state.get("last_rotation"),
        }
    if check_ips and info["proxy_listening"]:
        info["exit_ip"] = exit_ip()
        info["direct_ip"] = exit_ip(via_proxy=False)
        info["ip_differs"] = bool(info["exit_ip"]) and info["exit_ip"] != info["direct_ip"]
    return info


if __name__ == "__main__":
    # Used by ytwidget-vpn-idle.timer, so a tunnel started by Hazel or the
    # self-test (no backend running) still stops after 30 minutes unused.
    import sys
    if sys.argv[1:] == ["stop-if-idle"]:
        print("stopped" if stop_if_idle() else "kept")
    else:
        print(json.dumps(status(check_ips="--ips" in sys.argv), indent=2))
