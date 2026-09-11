"""List and switch the audio output device for our own mpv stream only.

Scoped to this app's own PipeWire/Pulse stream (found by client name
"ytwidget", set via mpv's --audio-client-name) rather than the system
default sink, so switching output here doesn't affect anything else
playing on the machine.
"""

from __future__ import annotations

import json
import shutil
import subprocess


class AudioOutputError(RuntimeError):
    pass


def _pactl(args: list[str], timeout: float = 3.0) -> str:
    binary = shutil.which("pactl")
    if not binary:
        raise AudioOutputError("pactl is not installed")
    result = subprocess.run(
        [binary] + args, capture_output=True, text=True, timeout=timeout, check=False,
    )
    if result.returncode != 0:
        raise AudioOutputError((result.stderr or "pactl command failed").strip())
    return result.stdout


def list_outputs() -> list[dict]:
    raw = _pactl(["-f", "json", "list", "sinks"])
    try:
        sinks = json.loads(raw)
    except json.JSONDecodeError:
        return []
    default_raw = _pactl(["get-default-sink"]).strip()
    outputs = []
    for sink in sinks:
        name = str(sink.get("name") or "")
        if not name:
            continue
        outputs.append({
            "name": name,
            "description": str(sink.get("description") or name),
            "isDefault": name == default_raw,
        })
    return outputs


def _our_sink_input_index() -> int | None:
    raw = _pactl(["-f", "json", "list", "sink-inputs"])
    try:
        inputs = json.loads(raw)
    except json.JSONDecodeError:
        return None
    for item in inputs:
        props = item.get("properties") or {}
        if str(props.get("application.name") or "") == "ytwidget":
            try:
                return int(item.get("index"))
            except (TypeError, ValueError):
                return None
    return None


def set_output(sink_name: str) -> bool:
    sink_name = str(sink_name or "").strip()
    if not sink_name:
        raise AudioOutputError("Missing sink name")
    index = _our_sink_input_index()
    if index is None:
        # Nothing playing right now to move — not an error, just a no-op;
        # the next track will still play on whatever the system default is.
        return False
    _pactl(["move-sink-input", str(index), sink_name])
    return True
