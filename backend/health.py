"""Readiness and a silent self-test for YouTube playback.

The self-test resolves one short fixed video through the request gate and has
mpv decode two seconds of it with --ao=null, so it is never audible. Results go
to ~/.local/state/ytwidget/health.jsonl; `summary()` turns them into a pass
rate. A systemd user timer runs it twice a day.

VPN state is only observed (does the proton0 interface exist); nothing here
connects or disconnects anything.

    python3 health.py selftest    run one self-test, print the entry
    python3 health.py summary     pass rate over the last 7 days
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

import vpn
import yt_gate

SELFTEST_VIDEO = "jNQXAC9IVRw"  # "Me at the zoo", 19 s, stable since 2005
DECODE_SECONDS = 2
_cache: tuple[float, dict] = (0.0, {})


def log_path() -> Path:
    state = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state"))
    return state / "ytwidget" / "health.jsonl"


def vpn_info(check_ips: bool = False) -> dict:
    """The YouTube-only VPN: mode, active server, unit, proxy, queue order.
    check_ips adds two non-YouTube requests (exit IP vs home IP)."""
    try:
        return vpn.status(check_ips=check_ips)
    except Exception as exc:  # noqa: BLE001 - health must never raise
        return {"error": str(exc)[:200]}


def _append(entry: dict) -> None:
    try:
        path = log_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(entry) + "\n")
    except OSError:
        pass


def _resolve(video_id: str) -> str:
    binary = shutil.which("yt-dlp")
    if not binary:
        raise RuntimeError("yt-dlp is not installed")
    result = yt_gate.run(
        [binary, "-f", "bestaudio/best", "-g", "--no-playlist", "--no-warnings",
         "--no-progress", f"https://www.youtube.com/watch?v={video_id}"],
        90, "selftest", video_id)
    lines = (result.stdout or "").strip().splitlines()
    if result.returncode != 0 or not lines:
        detail = (result.stderr or "").strip().splitlines()
        raise RuntimeError(detail[-1][:200] if detail else "no stream URL")
    return lines[-1]


def _decode(url: str) -> bool:
    """Decode a couple of seconds with no audio device at all."""
    mpv = shutil.which("mpv")
    if not mpv:
        return False
    try:
        result = subprocess.run(
            [mpv, "--no-config", "--ao=null", "--vo=null", "--no-video",
             "--ytdl=no", "--really-quiet", f"--length={DECODE_SECONDS}", url],
            capture_output=True, timeout=45, check=False)
    except subprocess.TimeoutExpired:
        return False
    return result.returncode == 0


def selftest(video_id: str = SELFTEST_VIDEO) -> dict:
    info = vpn_info()
    entry: dict = {"ts": round(time.time(), 3), "vpn_mode": info.get("mode"),
                   "vpn_active": info.get("active")}
    gate = yt_gate.status()
    entry["using_cookies"] = gate["using_cookies"]
    if gate["blocked"]:
        entry.update(ok=False, skipped=True, error="breaker open")
        _append(entry)
        return entry
    started = time.time()
    try:
        url = _resolve(video_id)
        entry["resolve_ms"] = int((time.time() - started) * 1000)
        entry["decode_ok"] = _decode(url)
        entry["ok"] = entry["decode_ok"]
        if not entry["ok"]:
            entry["error"] = "decode failed"
    except yt_gate.Blocked as exc:
        entry.update(ok=False, blocked=True, error=str(exc)[:200])
    except Exception as exc:  # noqa: BLE001 - every failure is a data point
        entry.update(ok=False, error=str(exc)[:200])
    entry["using_cookies"] = yt_gate.status()["using_cookies"]
    _append(entry)
    return entry


def _entries(days: float) -> list[dict]:
    cutoff = time.time() - days * 86400
    out: list[dict] = []
    try:
        for line in log_path().read_text(encoding="utf-8").splitlines():
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if not isinstance(entry, dict) or not isinstance(entry.get("ts"), (int, float)):
                continue
            if entry["ts"] >= cutoff:
                out.append(entry)
    except OSError:
        pass
    return out


def summary(days: float = 7) -> dict:
    entries = [e for e in _entries(days) if not e.get("skipped")]
    passed = [e for e in entries if e.get("ok")]
    times = sorted(e["resolve_ms"] for e in passed if "resolve_ms" in e)
    p95 = times[min(len(times) - 1, int(len(times) * 0.95))] if times else None
    rate = round(len(passed) / len(entries), 3) if entries else None
    return {
        "days": days,
        "runs": len(entries),
        "passed": len(passed),
        "pass_rate": rate,
        "p95_resolve_ms": p95,
        # "Proven working": at least a week of runs, >=95% pass, p95 under 5 s.
        "proven": bool(rate is not None and len(entries) >= 10 and rate >= 0.95
                       and p95 is not None and p95 < 5000),
    }


def readiness() -> dict:
    """Cheap snapshot for the state broadcast; cached for a few seconds."""
    global _cache
    now = time.time()
    if now - _cache[0] < 5:
        return _cache[1]
    gate = yt_gate.status()
    last = _entries(30)[-1:] or [{}]
    if gate["blocked"]:
        minutes = max(1, gate["seconds_left"] // 60 + 1)
        reason = f"YouTube is blocking requests; retrying in {minutes} minutes. Saved songs still play."
    elif gate["requests_last_hour"] >= yt_gate.HOURLY_CAP:
        reason = "Hourly YouTube budget is used up. Saved songs still play."
    else:
        reason = ""
    info = {
        "ready": not reason,
        "reason": reason,
        "blocked": gate["blocked"],
        "using_cookies": gate["using_cookies"],
        "requests_last_hour": gate["requests_last_hour"],
        "vpn": vpn_info(),
        "last_selftest_ok": last[0].get("ok"),
        "last_selftest_ts": last[0].get("ts"),
    }
    _cache = (now, info)
    return info


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else "summary"
    if command == "selftest":
        result = selftest()
        print(json.dumps(result))
        sys.exit(0 if result.get("ok") or result.get("skipped") else 1)
    print(json.dumps(summary(float(sys.argv[2]) if len(sys.argv) > 2 else 7)))
