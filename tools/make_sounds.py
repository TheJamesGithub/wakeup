#!/usr/bin/env python3
"""Generates the bundled alarm sounds.

Every alarm is ~28 s (AlarmKit's limit is 30 s), mono 44.1 kHz 16-bit .caf,
built from harsh waveforms in the 0.8-4 kHz range where phone speakers are
loudest, then pushed through a soft limiter so it's as loud as a file can be.
"""
import os
import subprocess
import sys
import tempfile
import wave

import numpy as np

SR = 44100
LEN = 28.0
rng = np.random.default_rng(7)


def t_axis(sec):
    return np.arange(int(sec * SR)) / SR


def square(f, t, duty=0.5):
    ph = (np.cumsum(np.broadcast_to(f, t.shape)) / SR) % 1.0
    return np.where(ph < duty, 1.0, -1.0)


def saw(f, t):
    ph = (np.cumsum(np.broadcast_to(f, t.shape)) / SR) % 1.0
    return 2 * ph - 1


def sine(f, t):
    return np.sin(2 * np.pi * np.cumsum(np.broadcast_to(f, t.shape)) / SR)


def gate(t, period, on):
    return ((t % period) < on).astype(float)


def fade_edges(x, ms=4):
    n = int(SR * ms / 1000)
    env = np.ones_like(x)
    env[:n] = np.linspace(0, 1, n)
    env[-n:] = np.linspace(1, 0, n)
    return x * env


def smooth_gate(g, ms=3):
    n = max(1, int(SR * ms / 1000))
    k = np.ones(n) / n
    return np.convolve(g, k, mode="same")


def tile(pattern, total=LEN):
    reps = int(np.ceil(total * SR / len(pattern)))
    return np.tile(pattern, reps)[: int(total * SR)]


def loudest(x, drive=3.0):
    x = x / (np.max(np.abs(x)) + 1e-9)
    x = np.tanh(drive * x) / np.tanh(drive)
    return 0.97 * x / (np.max(np.abs(x)) + 1e-9)


# ---------- alarm designs ----------

def classic_beep():
    t = t_axis(1.0)
    g = smooth_gate(gate(t, 0.12, 0.07) * (t < 0.48))
    return tile(square(2400, t) * g)


def siren_wail():
    t = t_axis(LEN)
    f = 1100 + 550 * np.sin(2 * np.pi * t / 1.6)
    return saw(f, t) + 0.5 * square(f * 1.5, t)


def siren_yelp():
    t = t_axis(LEN)
    f = 900 + 1200 * ((t * 4) % 1.0)
    return saw(f, t) + 0.4 * square(f * 2, t)


def klaxon():
    t = t_axis(LEN)
    f = np.where((t % 1.0) < 0.5, 960, 770)
    return square(f, t) + 0.6 * saw(f * 2.01, t)


def digital_chirp():
    t1 = t_axis(0.09)
    chirp = sine(np.linspace(1000, 4000, len(t1)), t1)
    seg = np.concatenate([chirp, np.zeros(int(0.03 * SR))])
    block = np.concatenate([np.tile(seg, 5), np.zeros(int(0.35 * SR))])
    return tile(block)


def buzzer():
    t = t_axis(LEN)
    g = smooth_gate(gate(t, 0.8, 0.45))
    return (saw(220, t) * 0.7 + square(2000, t) * (0.5 + 0.5 * square(30, t))) * g


def arp_scream():
    notes = [1046.5, 1318.5, 1568.0, 2093.0, 1568.0, 1318.5]
    t = t_axis(0.075)
    seg = np.concatenate([square(n, t) for n in notes])
    return tile(np.concatenate([seg, seg, np.zeros(int(0.15 * SR))]))


def morse_panic():
    unit = 0.06
    pattern = "1010101110111011101010100000"  # SOS-ish
    out = []
    t = t_axis(unit)
    tone = square(3000, t)
    for c in pattern:
        out.append(tone if c == "1" else np.zeros_like(tone))
    return tile(np.concatenate(out))


def bell_ringer():
    t = t_axis(LEN)
    partials = [(1200, 1.0), (2810, 0.6), (3520, 0.4), (5300, 0.2)]
    tone = sum(a * sine(f, t) for f, a in partials)
    trem = 0.55 + 0.45 * square(14, t)
    return tone * trem


def phone_trill():
    t = t_axis(LEN)
    tone = sine(1300, t) + sine(1500, t)
    am = 0.5 + 0.5 * square(20, t)
    cadence = gate(t, 2.0, 1.2)
    return tone * am * smooth_gate(cadence) + 0.4 * square(1400, t) * am * cadence


def glitch():
    out = []
    total = 0
    while total < LEN * SR:
        kind = rng.integers(0, 3)
        dur = rng.uniform(0.03, 0.18)
        t = t_axis(dur)
        if kind == 0:
            seg = rng.uniform(-1, 1, len(t))
        elif kind == 1:
            seg = square(rng.uniform(800, 3500), t)
        else:
            seg = sine(np.linspace(rng.uniform(500, 4000), rng.uniform(500, 4000), len(t)), t)
        seg = fade_edges(seg, 2)
        out.append(seg)
        total += len(seg)
        if rng.random() < 0.3:
            pause = np.zeros(int(rng.uniform(0.02, 0.1) * SR))
            out.append(pause)
            total += len(pause)
    x = np.concatenate(out)
    return x[: int(LEN * SR)]


def rising_steps():
    t = t_axis(0.11)
    steps = np.concatenate([square(f, t) for f in np.geomspace(700, 3200, 10)])
    return tile(np.concatenate([steps, np.zeros(int(0.2 * SR))]))


def dive_bomb():
    t = t_axis(0.7)
    f = np.geomspace(4000, 500, len(t))
    return tile(np.concatenate([saw(f, t) + 0.5 * square(f, t), np.zeros(int(0.1 * SR))]))


def smoke_alarm():
    t = t_axis(LEN)
    # T3 temporal pattern: 3 x 0.5s on / 0.5s off, then 1.5s off
    p = t % 4.5
    on = ((p < 0.5) | ((p >= 1.0) & (p < 1.5)) | ((p >= 2.0) & (p < 2.5))).astype(float)
    return (square(3100, t) + 0.3 * rng.uniform(-1, 1, len(t))) * smooth_gate(on)


def random_melody():
    out = []
    scale = [880, 987.8, 1108.7, 1318.5, 1480, 1760, 1975.5, 2217.5, 2637]
    while sum(len(s) for s in out) < LEN * SR:
        t = t_axis(rng.choice([0.08, 0.12, 0.16]))
        out.append(fade_edges(square(rng.choice(scale), t) + 0.5 * saw(rng.choice(scale) * 2, t), 2))
    return np.concatenate(out)[: int(LEN * SR)]


def wobble():
    t = t_axis(LEN)
    lfo = 0.5 + 0.5 * np.sin(2 * np.pi * 6 * t)
    f = 500 + 900 * lfo
    return square(f, t) * (0.6 + 0.4 * square(3, t)) + 0.5 * saw(f * 2.5, t)


def truck_reverse():
    t = t_axis(LEN)
    g = smooth_gate(gate(t, 1.0, 0.5))
    return (square(1250, t) + 0.6 * square(2500, t)) * g


ALARMS = {
    "alarm_classic_beep": classic_beep,
    "alarm_siren_wail": siren_wail,
    "alarm_siren_yelp": siren_yelp,
    "alarm_klaxon": klaxon,
    "alarm_digital_chirp": digital_chirp,
    "alarm_buzzer": buzzer,
    "alarm_arp_scream": arp_scream,
    "alarm_morse_panic": morse_panic,
    "alarm_bell_ringer": bell_ringer,
    "alarm_phone_trill": phone_trill,
    "alarm_glitch": glitch,
    "alarm_rising_steps": rising_steps,
    "alarm_dive_bomb": dive_bomb,
    "alarm_smoke": smoke_alarm,
    "alarm_random_melody": random_melody,
    "alarm_wobble": wobble,
    "alarm_truck_reverse": truck_reverse,
}


# ---------- wake-check "bing bing" sounds (short on purpose) ----------

def ding(f, dur=0.45):
    t = t_axis(dur)
    env = np.exp(-t * 7)
    return (sine(f, t) + 0.35 * sine(f * 2.76, t) + 0.15 * sine(f * 5.4, t)) * env


def check_bingbing():
    gap = np.zeros(int(0.08 * SR))
    return np.concatenate([ding(1760), gap, ding(1760), np.zeros(int(0.3 * SR))])


def check_dingdong():
    return np.concatenate([ding(1568, 0.5), ding(1245, 0.7), np.zeros(int(0.3 * SR))])


def check_triple():
    gap = np.zeros(int(0.06 * SR))
    return np.concatenate([ding(2093, 0.3), gap, ding(2093, 0.3), gap, ding(2637, 0.5), np.zeros(int(0.3 * SR))])


CHECKS = {
    "check_bingbing": check_bingbing,
    "check_dingdong": check_dingdong,
    "check_triple": check_triple,
}


def write_caf(name, x, outdir, drive):
    x = loudest(fade_edges(x), drive)
    pcm = (x * 32767).astype("<i2")
    with tempfile.TemporaryDirectory() as td:
        wav_path = os.path.join(td, "x.wav")
        with wave.open(wav_path, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(SR)
            w.writeframes(pcm.tobytes())
        out = os.path.join(outdir, name + ".caf")
        subprocess.run(
            ["ffmpeg", "-y", "-loglevel", "error", "-i", wav_path, "-c:a", "pcm_s16le", "-f", "caf", out],
            check=True,
        )
    return out


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else "Sounds"
    os.makedirs(outdir, exist_ok=True)
    for name, fn in ALARMS.items():
        x = fn()
        assert len(x) / SR < 30, name
        print(write_caf(name, x, outdir, drive=3.0), f"{len(x)/SR:.1f}s")
    for name, fn in CHECKS.items():
        print(write_caf(name, fn(), outdir, drive=1.5))


if __name__ == "__main__":
    main()
