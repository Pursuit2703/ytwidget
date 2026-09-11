"""Realtime 10-band spectrum from the desktop audio monitor (cliamp-style)."""

from __future__ import annotations

import math
import shutil
import struct
import subprocess
import threading
from typing import Callable

# Match cliamp/ui/visualizer.go band edges and smoothing.
BAND_EDGES = (20.0, 100.0, 200.0, 400.0, 800.0, 1600.0, 3200.0, 6400.0, 12800.0, 16000.0, 20000.0)
BAND_CENTERS = (70, 180, 320, 600, 1000, 3000, 6000, 12000, 14000, 16000)
SAMPLE_RATE = 44100
WINDOW = 2048
# Slide the analysis window forward by half a window each frame. Reading a
# full WINDOW per frame meant waiting 46ms for every update (~21Hz); a half
# window hop halves that to ~23ms (~43Hz) while keeping the 2048-point FFT's
# frequency resolution, since consecutive windows overlap by 50%.
HOP = WINDOW // 2
NUM_BANDS = 10


def hann_window(size: int) -> list[float]:
    if size <= 1:
        return [1.0] * size
    return [0.5 * (1.0 - math.cos(2.0 * math.pi * i / (size - 1))) for i in range(size)]


HANN = hann_window(WINDOW)


def fft_magnitudes(samples: list[float]) -> list[float]:
    """Radix-2 real FFT magnitudes for the first n/2 bins."""
    n = len(samples)
    if n == 0 or n & (n - 1):
        return []
    real = list(samples)
    imag = [0.0] * n
    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j ^= bit
        if i < j:
            real[i], real[j] = real[j], real[i]
            imag[i], imag[j] = imag[j], imag[i]
    length = 2
    while length <= n:
        angle = -2.0 * math.pi / length
        wlen_r = math.cos(angle)
        wlen_i = math.sin(angle)
        half = length // 2
        for start in range(0, n, length):
            wr = 1.0
            wi = 0.0
            for k in range(half):
                even = start + k
                odd = even + half
                vr = real[odd] * wr - imag[odd] * wi
                vi = real[odd] * wi + imag[odd] * wr
                real[odd] = real[even] - vr
                imag[odd] = imag[even] - vi
                real[even] += vr
                imag[even] += vi
                nwr = wr * wlen_r - wi * wlen_i
                wi = wr * wlen_i + wi * wlen_r
                wr = nwr
        length <<= 1
    return [math.hypot(real[i], imag[i]) for i in range(n // 2)]


def analyze(samples: list[float], prev: list[float] | None = None,
            sample_rate: int = SAMPLE_RATE) -> list[float]:
    """Return 10 levels in 0..1 with cliamp-like attack/decay smoothing."""
    previous = list(prev or [0.0] * NUM_BANDS)
    if len(previous) != NUM_BANDS:
        previous = [0.0] * NUM_BANDS
    if not samples:
        return [level * 0.8 for level in previous]

    windowed = list(samples[:WINDOW])
    if len(windowed) < WINDOW:
        windowed.extend([0.0] * (WINDOW - len(windowed)))
    windowed = [windowed[i] * HANN[i] for i in range(WINDOW)]
    spectrum = fft_magnitudes(windowed)
    if not spectrum:
        return [level * 0.8 for level in previous]

    bin_hz = float(sample_rate) / float(WINDOW)
    half_len = len(spectrum)
    bands: list[float] = []
    for b in range(NUM_BANDS):
        lo_idx = int(BAND_EDGES[b] / bin_hz)
        hi_idx = int(BAND_EDGES[b + 1] / bin_hz)
        if lo_idx < 1:
            lo_idx = 1
        if hi_idx >= half_len:
            hi_idx = half_len - 1
        total = 0.0
        count = 0
        if hi_idx >= lo_idx:
            for i in range(lo_idx, hi_idx + 1):
                total += spectrum[i]
                count += 1
        average = total / count if count else 0.0
        level = 0.0
        if average > 0:
            level = (20.0 * math.log10(average) + 10.0) / 50.0
        level = max(0.0, min(1.0, level))
        last = previous[b]
        if level > last:
            level = level * 0.8 + last * 0.2
        else:
            level = level * 0.55 + last * 0.45
        bands.append(level)
    return bands


def default_monitor_source() -> str:
    pactl = shutil.which("pactl")
    if not pactl:
        return ""
    try:
        sink = subprocess.check_output(
            [pactl, "get-default-sink"], text=True, timeout=1.5
        ).strip()
    except (subprocess.SubprocessError, OSError):
        sink = ""
    if sink:
        return sink + ".monitor"
    try:
        listing = subprocess.check_output(
            [pactl, "list", "short", "sources"], text=True, timeout=1.5
        )
    except (subprocess.SubprocessError, OSError):
        return ""
    for line in listing.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[1].endswith(".monitor"):
            return parts[1]
    return ""


class SpectrumTap:
    def __init__(self, on_levels: Callable[[list[float]], None] | None = None):
        self.on_levels = on_levels or (lambda _bands: None)
        self.levels = [0.0] * NUM_BANDS
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._proc: subprocess.Popen[bytes] | None = None

    def snapshot(self) -> list[float]:
        with self._lock:
            return list(self.levels)

    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        proc = self._proc
        if proc and proc.poll() is None:
            try:
                proc.terminate()
            except OSError:
                pass
        self._proc = None

    def shutdown(self) -> None:
        self.stop()
        thread = self._thread
        if thread and thread.is_alive():
            thread.join(timeout=0.6)

    def _spawn(self) -> subprocess.Popen[bytes] | None:
        monitor = default_monitor_source()
        parec = shutil.which("parec")
        if parec and monitor:
            try:
                return subprocess.Popen(
                    [parec, "--format=float32le", f"--rate={SAMPLE_RATE}",
                     "--channels=1", "--latency-msec=20", "-d", monitor],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                )
            except OSError:
                pass
        return None

    def _loop(self) -> None:
        chunk = HOP * 4
        while not self._stop.is_set():
            proc = self._spawn()
            self._proc = proc
            if proc is None or proc.stdout is None:
                with self._lock:
                    self.levels = [level * 0.8 for level in self.levels]
                self._stop.wait(0.8)
                continue
            window = [0.0] * WINDOW
            try:
                while not self._stop.is_set():
                    raw = proc.stdout.read(chunk)
                    if not raw:
                        break
                    count = len(raw) // 4
                    if count <= 0:
                        continue
                    samples = list(struct.unpack("<" + "f" * count, raw[:count * 4]))
                    # Shift the window forward by however much arrived, keeping
                    # it exactly WINDOW long so the FFT stays radix-2.
                    window = (window + samples)[-WINDOW:]
                    with self._lock:
                        self.levels = analyze(window, self.levels)
                    self.on_levels(self.snapshot())
            finally:
                try:
                    proc.kill()
                except OSError:
                    pass
                self._proc = None
            self._stop.wait(0.4)
