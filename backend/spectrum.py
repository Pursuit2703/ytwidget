"""Realtime spectrum for the bar visualiser, taken from this plugin's own
audio stream. Band layout and smoothing follow cava."""

from __future__ import annotations

import math
import shutil
import struct
import subprocess
import threading
import time
from typing import Callable

# The two mpv instances this plugin starts, identified by the
# --audio-client-name each is launched with (see player.py and video.py).
# The visualiser follows these and nothing else.
OWN_CLIENT_NAMES = ("ytwidget", "ytwidget-video")

# How often to re-check that the stream we are recording is still the one we
# want, while it is producing audio.
STREAM_POLL_SECONDS = 1.5

# Band layout and smoothing follow cava (github.com/karlstav/cava), the
# reference implementation for this kind of bar display.
#
# The old layout was ten fixed edges reaching to 20kHz, and it was the root of
# the "left side dances, right side is dead" problem: YouTube's Opus/AAC
# lowpass removes everything above roughly 13kHz, so the top bands were not
# quiet, they were exactly zero on every frame ever measured. Stopping at
# 12kHz means every band carries signal, and spreading the edges
# logarithmically (as cava does) gives the low end -- where music actually
# lives -- the resolution it deserves instead of lumping 20-100Hz into one bar.
NUM_BANDS = 16
LOWER_CUT_OFF = 50.0
UPPER_CUT_OFF = 12000.0


def _log_band_edges(bands: int, low: float, high: float) -> tuple[float, ...]:
    """cava's logarithmic bar distribution (cavacore.c)."""
    constant = math.log10(low / high) / (1.0 / (bands + 1) - 1.0)
    edges = []
    for n in range(bands + 1):
        coefficient = -constant + ((n + 1) / (bands + 1)) * constant
        edges.append(high * (10.0 ** coefficient))
    return tuple(edges)


BAND_EDGES = _log_band_edges(NUM_BANDS, LOWER_CUT_OFF, UPPER_CUT_OFF)
SAMPLE_RATE = 44100
WINDOW = 2048
# Slide the analysis window forward by half a window each frame. Reading a
# full WINDOW per frame meant waiting 46ms for every update (~21Hz); a half
# window hop halves that to ~23ms (~43Hz) while keeping the 2048-point FFT's
# frequency resolution, since consecutive windows overlap by 50%.
HOP = WINDOW // 2


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


def analyze_raw(samples: list[float], sample_rate: int = SAMPLE_RATE) -> list[float]:
    """Raw per-band magnitude sums. No smoothing and no normalising — that is
    BandSmoother's job, and keeping the two apart is what lets the smoothing
    be stateful across frames."""
    if not samples:
        return [0.0] * NUM_BANDS

    windowed = list(samples[:WINDOW])
    if len(windowed) < WINDOW:
        windowed.extend([0.0] * (WINDOW - len(windowed)))
    windowed = [windowed[i] * HANN[i] for i in range(WINDOW)]
    spectrum = fft_magnitudes(windowed)
    if not spectrum:
        return [0.0] * NUM_BANDS

    bin_hz = float(sample_rate) / float(WINDOW)
    half_len = len(spectrum)
    bands: list[float] = []
    for b in range(NUM_BANDS):
        lo_idx = max(1, int(BAND_EDGES[b] / bin_hz))
        hi_idx = min(half_len - 1, int(BAND_EDGES[b + 1] / bin_hz))
        # The lowest bands are narrower than one FFT bin at this window size,
        # so without this they would collapse to nothing.
        if hi_idx < lo_idx:
            hi_idx = lo_idx
        total = 0.0
        for i in range(lo_idx, hi_idx + 1):
            total += spectrum[i]
        bands.append(total)
    return bands


class BandSmoother:
    """cava's smoothing chain (cavacore.c), which is what makes a row of bars
    look like music rather than like a noisy meter.

    Three parts, none of which is a timer — every bit of movement here comes
    from the audio:

      falloff   A bar jumps to a new peak instantly, then falls away from that
                peak under acceleration (fall grows by a fixed step each frame
                and the drop goes as its square). Instant attack with a heavy
                decay is the whole character of the thing.
      integral  A leaky integrator on top, so the raw FFT's frame-to-frame
                noise does not make the bars buzz.
      autosens  A single gain that creeps up while nothing is clipping and
                drops quickly the moment anything overshoots. This is the part
                worth having: it means the display fits whatever the track and
                the volume slider happen to be doing, instead of needing a gain
                constant tuned for one song.
    """

    def __init__(self, bands: int = NUM_BANDS, framerate: float = SAMPLE_RATE / HOP,
                 noise_reduction: float = 0.77, autosens: float = 1.0):
        self.bands = bands
        self.noise_reduction = noise_reduction
        self.autosens = autosens
        self.sens = 1.0
        self.sens_init = True
        self.peak = [0.0] * bands
        self.fall = [0.0] * bands
        self.mem = [0.0] * bands
        self.prev = [0.0] * bands
        framerate_mod = 66.0 / float(framerate)
        self.framerate_mod = framerate_mod
        self.gravity_mod = (framerate_mod ** 2.5) * 2.0 / noise_reduction
        self.integral_mod = framerate_mod ** 0.1

    def reset(self) -> None:
        """Clear the per-band state but keep the learned sensitivity: the
        stream dropping out between tracks is not a reason to relearn the
        gain from scratch and flicker while it settles."""
        self.peak = [0.0] * self.bands
        self.fall = [0.0] * self.bands
        self.mem = [0.0] * self.bands
        self.prev = [0.0] * self.bands

    def process(self, raw: list[float], silent: bool = False) -> list[float]:
        out = [value * self.sens for value in raw]
        overshoot = False
        for n in range(self.bands):
            if out[n] < self.prev[n] and self.noise_reduction > 0.1:
                out[n] = self.peak[n] * (1.0 - (self.fall[n] * self.fall[n] * self.gravity_mod))
                if out[n] < 0.0:
                    out[n] = 0.0
                self.fall[n] += 0.028
            else:
                self.peak[n] = out[n]
                self.fall[n] = 0.0
            self.prev[n] = out[n]

            out[n] = self.mem[n] * self.noise_reduction / self.integral_mod + out[n]
            self.mem[n] = out[n]

            if out[n] > 1.0:
                overshoot = True
                out[n] = 1.0

        if overshoot:
            self.sens *= 1.0 - (0.02 * self.framerate_mod)
            self.sens_init = False
        elif not silent:
            self.sens *= 1.0 + (0.001 * self.framerate_mod * self.autosens)
            if self.sens_init:
                # Converge fast on the first few seconds instead of crawling
                # up from 1.0 while the widget sits flat.
                self.sens *= 1.0 + (0.1 * self.framerate_mod)
        return out


def _pactl(*args: str) -> str:
    pactl = shutil.which("pactl")
    if not pactl:
        return ""
    try:
        return subprocess.check_output([pactl, *args], text=True, timeout=1.5)
    except (subprocess.SubprocessError, OSError):
        return ""


def _sink_monitors() -> dict[str, str]:
    """Sink index -> the name of that sink's monitor source."""
    monitors: dict[str, str] = {}
    for line in _pactl("list", "short", "sinks").splitlines():
        parts = line.split()
        if len(parts) >= 2:
            monitors[parts[0]] = parts[1] + ".monitor"
    return monitors


def find_own_stream() -> tuple[str, str] | None:
    """(sink input index, monitor source) for this plugin's own playback.

    Recording a sink's monitor captures everything on the machine, so the bar
    visualiser used to dance to whatever browser tab happened to be making
    noise — and kept dancing when the plugin itself was silent. parec's
    --monitor-stream narrows the capture to one sink input, so we find ours by
    the --audio-client-name mpv was launched with.

    Returns None when the plugin is not producing audio at all, which is a
    normal state, not an error: mpv closes its audio output between tracks and
    while idle, and the sink input disappears with it.
    """
    listing = _pactl("list", "sink-inputs")
    if not listing:
        return None
    monitors = _sink_monitors()
    index = ""
    sink = ""
    name = ""
    # The trailing sentinel flushes the final block, which has no header after
    # it to trigger the check.
    for raw in listing.splitlines() + ["Sink Input #"]:
        line = raw.strip()
        if line.startswith("Sink Input #"):
            if index and name in OWN_CLIENT_NAMES:
                monitor = monitors.get(sink, "")
                if monitor:
                    return index, monitor
            index = line[len("Sink Input #"):].strip()
            sink = ""
            name = ""
        elif line.startswith("Sink:"):
            sink = line.split(":", 1)[1].strip()
        elif line.startswith("application.name"):
            name = line.split("=", 1)[1].strip().strip('"')
    return None


class SpectrumTap:
    def __init__(self, on_levels: Callable[[list[float]], None] | None = None):
        self.on_levels = on_levels or (lambda _bands: None)
        self.levels = [0.0] * NUM_BANDS
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._proc: subprocess.Popen[bytes] | None = None
        self._smoother = BandSmoother()

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

    def _silence(self) -> None:
        """Report a flat spectrum. Used whenever the plugin is not the one
        making sound, so the widget rests instead of holding its last shape."""
        with self._lock:
            self._smoother.reset()
            if not any(self.levels):
                return
            self.levels = [0.0] * NUM_BANDS
        self.on_levels(self.snapshot())

    def _spawn(self) -> tuple[subprocess.Popen[bytes], str] | None:
        stream = find_own_stream()
        if stream is None:
            return None
        index, monitor = stream
        parec = shutil.which("parec")
        if not parec:
            return None
        try:
            proc = subprocess.Popen(
                [parec, "--format=float32le", f"--rate={SAMPLE_RATE}",
                 "--channels=1", "--latency-msec=20",
                 "-d", monitor, f"--monitor-stream={index}"],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
            )
        except OSError:
            return None
        return proc, index

    def _loop(self) -> None:
        chunk = HOP * 4
        while not self._stop.is_set():
            spawned = self._spawn()
            if spawned is None:
                # Not playing anything of our own right now. Wait for our sink
                # input to appear rather than falling back to the whole
                # desktop, which is what made this follow other applications.
                self._silence()
                self._stop.wait(0.5)
                continue
            proc, index = spawned
            self._proc = proc
            window = [0.0] * WINDOW
            next_check = time.monotonic() + STREAM_POLL_SECONDS
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
                    raw = analyze_raw(window)
                    with self._lock:
                        self.levels = self._smoother.process(raw, silent=max(raw) <= 0.0)
                    self.on_levels(self.snapshot())
                    # mpv tears down and rebuilds its audio output between
                    # tracks, so the sink input we are recording gets a new
                    # index. Re-resolve periodically and respawn onto the new
                    # one instead of recording a stream that is no longer ours.
                    now = time.monotonic()
                    if now >= next_check:
                        next_check = now + STREAM_POLL_SECONDS
                        current = find_own_stream()
                        if current is None or current[0] != index:
                            break
            finally:
                try:
                    proc.kill()
                except OSError:
                    pass
                self._proc = None
            self._silence()
            self._stop.wait(0.3)
