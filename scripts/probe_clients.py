#!/usr/bin/env python3
"""Compare yt-dlp YouTube player clients on this connection, slowly.

Each probe resolves a bestaudio stream URL (no download, no audio output) and
then reads the first 64 KB of the stream to prove it is fetchable. Probes are
spread out (one a minute, rounds every 30 minutes) so the probe itself never
looks like a burst. It stops at the first block signal or if the request gate
breaker is open, so it never prolongs a block.

    probe_clients.py [rounds] [round_gap_seconds]

Results: ~/.local/state/ytwidget/client_probe.jsonl
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path.home() / ".local" / "lib" / "ytwidget"))
import yt_gate  # noqa: E402

VIDEOS = ["dQw4w9WgXcQ", "kJQP7kiw5Fk", "9bZkp7q19f0", "JGwWNGJdvx8",
          "fJ9rUzIMcZQ", "hTWKbfoikeg", "YQHsXMglC9A", "RgKAFK5djSk"]
VARIANTS = {
    "default": [],
    "android": ["--extractor-args", "youtube:player_client=android"],
    "web_embedded": ["--extractor-args", "youtube:player_client=web_embedded"],
    "android_vr": ["--extractor-args", "youtube:player_client=android_vr"],
    "tv": ["--extractor-args", "youtube:player_client=tv"],
    "default+cookies": ["--cookies-from-browser", f"firefox:{yt_gate.firefox_profile()}"],
}
BLOCK_RE = re.compile(r"429|too many requests|not a bot|confirm you.re not", re.I)
PROBE_GAP = 60


def out_path() -> Path:
    state = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state"))
    return state / "ytwidget" / "client_probe.jsonl"


def probe(variant: str, args: list[str], video_id: str) -> dict:
    entry = {"ts": round(time.time(), 3), "variant": variant, "id": video_id,
             "vpn": Path("/sys/class/net/proton0").exists()}
    started = time.time()
    result = subprocess.run(
        [shutil.which("yt-dlp") or "yt-dlp", *args, "-f", "bestaudio", "-g",
         "--no-playlist", "--no-warnings", f"https://www.youtube.com/watch?v={video_id}"],
        capture_output=True, text=True, timeout=120, check=False)
    entry["resolve_ms"] = int((time.time() - started) * 1000)
    lines = (result.stdout or "").strip().splitlines()
    if result.returncode != 0 or not lines:
        err = (result.stderr or "").strip().splitlines()
        entry.update(ok=False, error=(err[-1] if err else "no url")[:200],
                     blocked=bool(BLOCK_RE.search(result.stderr or "")))
        return entry
    url = lines[-1]
    entry["itag"] = (re.search(r"[?&]itag=(\d+)", url) or [None, None])[1]
    try:
        request = urllib.request.Request(url, headers={"Range": "bytes=0-65535"})
        with urllib.request.urlopen(request, timeout=20) as response:
            entry["fetch_status"] = response.status
            entry["ok"] = len(response.read()) > 0
    except Exception as exc:  # noqa: BLE001
        entry.update(ok=False, error=f"fetch: {exc}"[:200],
                     blocked="429" in str(exc))
    return entry


def main() -> None:
    rounds = int(sys.argv[1]) if len(sys.argv) > 1 else 8
    round_gap = int(sys.argv[2]) if len(sys.argv) > 2 else 1800
    path = out_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    for round_index in range(rounds):
        video_id = VIDEOS[round_index % len(VIDEOS)]
        for variant, args in VARIANTS.items():
            if yt_gate.status()["blocked"]:
                print("gate breaker open; stopping", flush=True)
                return
            if variant.endswith("cookies") and not yt_gate.firefox_profile():
                continue
            entry = probe(variant, args, video_id)
            entry["round"] = round_index
            with path.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(entry) + "\n")
            print(json.dumps(entry), flush=True)
            if entry.get("blocked"):
                print("block signal seen; stopping", flush=True)
                return
            time.sleep(PROBE_GAP)
        if round_index < rounds - 1:
            time.sleep(round_gap)


if __name__ == "__main__":
    main()
