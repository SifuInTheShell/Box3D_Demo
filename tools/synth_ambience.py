#!/usr/bin/env python3
"""Synthesize placeholder ambience audio for lib/ambient/audio/.

So the ambience layer works with no downloads at all, it ships PROCEDURAL
placeholders — authored here, seeded, CC0 by construction — under the exact
filenames ambience_audio.gd loads. The fetch round
(tools/fetch_ambient_assets.py) replaces any of these with recorded CC0 takes
by overwriting the file; no code changes needed.

Voices with no credible synthesis (dog, chatter, rooster) are deliberately
skipped — the scheduler tolerates missing files, and a goofy fake reads
worse than silence.

Usage:  python3 tools/synth_ambience.py            # writes game/lib/ambient/audio/
Needs:  numpy, ffmpeg (wav -> ogg)
"""

import math
import shutil
import subprocess
import tempfile
import wave
from pathlib import Path

import numpy as np

SR = 44100
OUT_DIR = Path(__file__).resolve().parent.parent / "game" / "lib" / "ambient" / "audio"


def _write(name: str, samples: np.ndarray, peak: float = 0.9) -> None:
    """Normalize, encode 16-bit WAV, transcode to .ogg via ffmpeg."""
    samples = samples.astype(np.float64)
    m = np.max(np.abs(samples))
    if m > 0:
        samples = samples / m * peak
    pcm = (samples * 32767).astype(np.int16)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        wav_path = tmp.name
    with wave.open(wav_path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    out = OUT_DIR / f"{name}.ogg"
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-i", wav_path,
         "-c:a", "libvorbis", "-q:a", "3", str(out)],
        check=True)
    Path(wav_path).unlink()
    print(f"  {out.name}  {out.stat().st_size / 1024:.0f} KiB")


def _loopify(x: np.ndarray, fade_s: float = 1.5) -> np.ndarray:
    """Crossfade the tail into the head so the bed loops seamlessly."""
    n = int(fade_s * SR)
    fade = np.linspace(0.0, 1.0, n)
    head = x[:n] * fade + x[-n:] * (1.0 - fade)
    return np.concatenate([head, x[n:-n]])


def _pink(rng: np.random.Generator, n: int, alpha: float = 1.0) -> np.ndarray:
    """1/f^alpha noise via FFT shaping."""
    white = rng.standard_normal(n)
    spec = np.fft.rfft(white)
    freqs = np.fft.rfftfreq(n, 1.0 / SR)
    freqs[0] = freqs[1]
    spec = spec / np.power(freqs, alpha / 2.0)
    return np.fft.irfft(spec, n)


def _lfo(n: int, hz: float, phase: float = 0.0) -> np.ndarray:
    t = np.arange(n) / SR
    return np.sin(2.0 * math.pi * hz * t + phase)


def street_bed(seconds: float = 26.0) -> np.ndarray:
    """Distant city hum: deep rumble + mid murmur, slowly breathing."""
    rng = np.random.default_rng(0x57EE7)
    n = int(seconds * SR)
    rumble = _pink(rng, n, 1.6)
    murmur = _pink(rng, n, 1.0) * 0.35
    breathe = 1.0 + 0.18 * _lfo(n, 0.05) + 0.09 * _lfo(n, 0.013, 1.7)
    return _loopify((rumble + murmur) * breathe)


def rural_bed(seconds: float = 26.0) -> np.ndarray:
    """Wind through leaves: airy pink noise, gusting gently."""
    rng = np.random.default_rng(0x2A7A1)
    n = int(seconds * SR)
    air = _pink(rng, n, 0.8)
    gusts = 1.0 + 0.35 * _lfo(n, 0.07) + 0.2 * _lfo(n, 0.19, 0.8)
    hiss = _pink(rng, n, 0.4) * 0.15 * (1.0 + 0.5 * _lfo(n, 0.11, 2.1))
    return _loopify(air * gusts + hiss)


def birdsong(seed: int, phrase_count: int = 3) -> np.ndarray:
    """A short songbird phrase: FM chirps with vibrato, silence between."""
    rng = np.random.default_rng(seed)
    parts = [np.zeros(int(0.15 * SR))]
    for _ in range(phrase_count):
        notes = rng.integers(2, 5)
        for _ in range(notes):
            dur = rng.uniform(0.06, 0.18)
            n = int(dur * SR)
            t = np.arange(n) / SR
            f0 = rng.uniform(2200.0, 4600.0)
            sweep = rng.uniform(-1400.0, 600.0)
            vib = rng.uniform(20.0, 60.0)
            freq = f0 + sweep * (t / dur) + vib * 8.0 * np.sin(2 * math.pi * vib * t)
            phase = 2.0 * math.pi * np.cumsum(freq) / SR
            env = np.hanning(n)
            parts.append(np.sin(phase) * env)
            parts.append(np.zeros(int(rng.uniform(0.04, 0.16) * SR)))
        parts.append(np.zeros(int(rng.uniform(0.3, 0.7) * SR)))
    return np.concatenate(parts)


def wind_gust(seed: int, seconds: float = 3.5) -> np.ndarray:
    """One gust: airy noise swelling and dying."""
    rng = np.random.default_rng(seed)
    n = int(seconds * SR)
    x = _pink(rng, n, 0.7)
    t = np.linspace(0.0, 1.0, n)
    env = np.power(np.sin(math.pi * np.clip(t, 0.0, 1.0)), 1.6)
    return x * env


def car_pass(seed: int, seconds: float = 4.5) -> np.ndarray:
    """A car going by: band-ish noise swelling with a pitch dip (doppler)."""
    rng = np.random.default_rng(seed)
    n = int(seconds * SR)
    t = np.linspace(0.0, 1.0, n)
    body = _pink(rng, n, 1.2)
    tire = _pink(rng, n, 0.5) * 0.4
    env = np.power(np.sin(math.pi * t), 2.2)
    # Doppler-ish: modulate with a tone that slides down mid-pass.
    f = 90.0 - 25.0 * (t > 0.5)
    hum = 0.4 * np.sin(2.0 * math.pi * np.cumsum(f) / SR)
    return (body + tire + hum * env) * env


def main() -> None:
    if shutil.which("ffmpeg") is None:
        raise SystemExit("ffmpeg not found on PATH -- needed for wav -> ogg")
    print(f"writing {OUT_DIR}")
    _write("street", street_bed(), peak=0.5)
    _write("rural", rural_bed(), peak=0.5)
    for i, seed in enumerate([0xB1AD1, 0xB1AD2, 0xB1AD3]):
        _write(f"birdsong_{i + 1}", birdsong(seed), peak=0.55)
    for i, seed in enumerate([0x9057, 0x9058]):
        _write(f"wind_gust_{i + 1}", wind_gust(seed), peak=0.6)
    for i, seed in enumerate([0xCA7, 0xCA8]):
        _write(f"car_pass_{i + 1}", car_pass(seed), peak=0.55)
    print("done — placeholders in place; the CC0 fetch round overwrites them 1:1.")


if __name__ == "__main__":
    main()
