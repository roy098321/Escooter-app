#!/usr/bin/env python3
"""Offline renderer for the app's own synthesized sounds (F-19, P6-3).

Re-creates the Web Audio recipes used in the approved sound review (bell, mallet,
pad, air, thump, ping, small generated room reverb, stereo pan) with numpy only
and writes 44.1 kHz 16-bit stereo WAV files into App/Resources/Sounds/.
No outside sound files are used. Run:  python Tools/render_sounds.py
"""
import math
import os
import sys
import wave

import numpy as np

SR = 44100
N = dict(C3=130.81, E3=164.81, G3=196, A3=220, C4=261.63, D4=293.66, E4=329.63, F4=349.23,
         G4=392, A4=440, B4=493.88, C5=523.25, D5=587.33, E5=659.25, G5=783.99, A5=880,
         B5=987.77, C6=1046.5, E6=1318.5, G6=1568)
RNG = np.random.default_rng(20261019)


def exp_ramp(v0, v1, n):
    return v0 * (v1 / v0) ** (np.arange(n) / max(1, n - 1))


def env(n_total, t0, a, peak, dec):
    """exp attack from .0001 to peak over a, exp decay back to .0001 over dec (Web Audio env())."""
    g = np.full(n_total, 0.0001)
    i0 = int(t0 * SR)
    na, nd = max(1, int(a * SR)), max(1, int(dec * SR))
    if i0 >= n_total:
        return g
    seg = np.concatenate([exp_ramp(0.0001, peak, na), exp_ramp(peak, 0.0001, nd)])
    seg = seg[: n_total - i0]
    g[i0:i0 + len(seg)] = seg
    return g


def biquad(x, kind, f, q, gain_db=0.0):
    w0 = 2 * math.pi * f / SR
    al = math.sin(w0) / (2 * q)
    cw = math.cos(w0)
    A = 10 ** (gain_db / 40)
    if kind == "bandpass":
        b0, b1, b2, a0, a1, a2 = al, 0, -al, 1 + al, -2 * cw, 1 - al
    elif kind == "peaking":
        b0, b1, b2 = 1 + al * A, -2 * cw, 1 - al * A
        a0, a1, a2 = 1 + al / A, -2 * cw, 1 - al / A
    else:
        raise ValueError(kind)
    b0, b1, b2, a1, a2 = b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0
    y = np.zeros_like(x)
    x1 = x2 = y1 = y2 = 0.0
    for i in range(len(x)):
        xi = x[i]
        yi = b0 * xi + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        y[i] = yi
        x2, x1, y2, y1 = x1, xi, y1, yi
    return y


def svf(x, kind, fc, q):
    """Time-varying state-variable filter (fc is an array, Hz)."""
    y = np.zeros_like(x)
    low = band = 0.0
    damp = 1.0 / q
    ff = 2 * np.sin(np.pi * np.minimum(fc, 7000) / SR)
    for i in range(len(x)):
        low += ff[i] * band
        high = x[i] - low - damp * band
        band += ff[i] * high
        y[i] = low if kind == "lowpass" else band * damp
    return y


class Mix:
    def __init__(self, sec):
        self.n = int(sec * SR)
        self.dry = np.zeros((2, self.n))
        self.rev = np.zeros((2, self.n))

    def route(self, sig, t0, pan=0.0, rev=0.6):
        """sig: mono array starting at t0 seconds; pan scalar or array in [-1,1]."""
        i0 = int(t0 * SR)
        sig = sig[: max(0, self.n - i0)]
        if len(sig) == 0:
            return
        if np.ndim(pan) == 0:
            p = (float(pan) + 1) * math.pi / 4
        else:
            p = (np.asarray(pan)[: len(sig)] + 1) * math.pi / 4
        sl, sr = sig * np.cos(p), sig * np.sin(p)
        self.dry[0, i0:i0 + len(sig)] += sl
        self.dry[1, i0:i0 + len(sig)] += sr
        self.rev[0, i0:i0 + len(sig)] += sl * rev
        self.rev[1, i0:i0 + len(sig)] += sr * rev

    def render(self, limit=0.89):
        out = self.dry * 0.9
        if np.any(self.rev):
            ln = int(SR * 1.6)
            decay = (1 - np.arange(ln) / ln) ** 3.2
            wet = []
            m = 1
            while m < self.n + ln:
                m *= 2
            for ch in range(2):
                ir = (RNG.random(ln) * 2 - 1) * decay
                c = np.fft.irfft(np.fft.rfft(self.rev[ch], m) * np.fft.rfft(ir, m), m)[: self.n]
                wet.append(c * 0.32)
            out = out + np.array(wet)
        pk = np.max(np.abs(out))
        if pk > limit:
            out = out * (limit / pk)
        return out


def noise(sec):
    return RNG.random(int(sec * SR)) * 2 - 1


def bell(m, f, t0, vol, dec, pan):
    n = int((dec + 0.1) * SR)
    t = np.arange(n) / SR
    mg = f * 2.2 * (f * 0.05 / (f * 2.2)) ** np.minimum(t / dec, 1)
    inst = f + mg * np.sin(2 * math.pi * f * 3.5 * t)
    car = np.sin(2 * math.pi * np.cumsum(inst) / SR)
    s = car * env(n, 0, 0.006, vol, dec)
    up = np.sin(2 * math.pi * f * 2.01 * t) * env(n, 0, 0.004, vol * 0.25, dec * 0.45)
    m.route(s, t0, pan)
    m.route(up, t0, pan)


def mallet(m, f, t0, vol, dec, pan, rv=1.0):
    n = int((dec + 0.1) * SR)
    t = np.arange(n) / SR
    s = np.sin(2 * math.pi * f * t) * env(n, 0, 0.004, vol, dec)
    s4 = np.sin(2 * math.pi * f * 4 * t) * env(n, 0, 0.002, vol * 0.35, dec * 0.18)
    nz = biquad(noise(0.03), "bandpass", min(f * 6, 18000), 2.0)
    nz = nz * env(len(nz), 0, 0.001, vol * 0.25, 0.03)
    m.route(s, t0, pan, 0.5 * rv)
    m.route(s4, t0, pan, 0.3 * rv)
    m.route(nz, t0, pan, 0.2 * rv)


def pad(m, freqs, t0, vol, dur, f0, f1):
    n = int((dur + 0.1) * SR)
    t = np.arange(n) / SR
    x = np.zeros(n)
    for i, f in enumerate(freqs):
        for cents in (-6, 6):
            ff = f * 2 ** ((cents + i) / 1200)
            x += 2 * ((t * ff) % 1.0) - 1
    fc = f0 * (f1 / f0) ** np.minimum(t / dur, 1)
    x = svf(x, "lowpass", fc, 0.7)
    g = np.full(n, 0.0001)
    na = int(dur * 0.35 * SR)
    nb = int(dur * SR) - na
    g[:na] = exp_ramp(0.0001, vol, na)
    g[na:na + nb] = exp_ramp(vol, 0.0001, nb)
    m.route(x * g, t0, 0, 0.9)


def air(m, t0, dur, f_from, f_to, vol, pan_from, pan_to):
    n = int((dur + 0.1) * SR)
    ramp = np.minimum(np.arange(n) / SR / dur, 1)
    fc = f_from * (f_to / f_from) ** ramp
    x = svf(noise(dur + 0.1), "bandpass", fc, 1.4)
    g = np.full(n, 0.0001)
    na = int(dur * 0.55 * SR)
    nb = int(dur * SR) - na
    g[:na] = exp_ramp(0.0001, vol, na)
    g[na:na + nb] = exp_ramp(vol, 0.0001, nb)
    m.route(x * g, t0, pan_from + (pan_to - pan_from) * ramp, 0.4)


def thump(m, t0, vol):
    n = int(0.4 * SR)
    t = np.arange(n) / SR
    fr = 120 * (48 / 120) ** np.minimum(t / 0.25, 1)
    s = np.sin(2 * math.pi * np.cumsum(fr) / SR) * env(n, 0, 0.005, vol, 0.3)
    m.route(s, t0, 0, 0.15)


def ping(m, f, t0, vol, dec, pan):
    n = int((dec + 0.05) * SR)
    t = np.arange(n) / SR
    x = np.zeros(n)
    for mult, amp, kind in ((1, 1, "tri"), (2, .55, "sin"), (3, .3, "sin"), (4.2, .12, "sin")):
        ph = 2 * math.pi * f * mult * t
        x += amp * (2 / math.pi * np.arcsin(np.sin(ph)) if kind == "tri" else np.sin(ph))
    x = biquad(x, "peaking", 2600, 0.9, 6.0)
    m.route(x * env(n, 0, 0.002, vol, dec), t0, pan, 0.12)


# ---- sounds -------------------------------------------------------------------------------

def s1():
    m = Mix(2.4)
    pad(m, [N["E3"], N["B4"] / 2, N["E4"]], 0, .035, 1.1, 500, 1400)
    bell(m, N["E5"], .02, .16, 1.1, -.25)
    bell(m, N["B5"], .16, .14, 1.4, .25)
    return m.render()


def kick_sync(T):
    """Start sound synced to the A3 transition: audible at t = 0, silent by t = T."""
    m = Mix(T + 0.05)
    thump(m, 0, .14)
    mallet(m, N["G4"], 0, .16, .16, -.2, 0)
    n = int((T + 0.05) * SR)
    t = np.arange(n) / SR
    fc = 700 * (4500 / 700) ** np.minimum(t / T, 1)
    x = svf(noise(T + 0.05), "bandpass", fc, 1.2)
    g = np.full(n, 0.0001)
    a, b, c = int(.02 * SR), int(T * .8 * SR), int(T * SR)
    g[:a] = exp_ramp(0.0001, .06, a)
    g[a:b] = exp_ramp(.06, .11, b - a)
    g[b:c] = exp_ramp(.11, 0.0001, c - b)
    g[c:] = 0
    m.route(x * g, 0, -.5 + np.minimum(t / T, 1), 0.0)
    mallet(m, N["D5"], T * .55, .18, T * .45 - .02, .2, 0)
    out = m.render()
    cut = int(T * SR)
    out = out[:, :cut]
    fade = int(0.04 * SR)
    out[:, -fade:] *= np.linspace(1, 0, fade)
    return out


def ride_end():
    m = Mix(2.4)
    mallet(m, N["D5"], 0, .18, .5, .2)
    mallet(m, N["G4"], .14, .2, .9, -.2)
    air(m, 0, .5, 3500, 500, .06, .5, -.5)
    thump(m, .14, .16)
    return m.render()


def battery_ping():
    m = Mix(1.4)
    for o in (0, .5):
        ping(m, 1318.5, o, .3, .16, -.1)
        ping(m, 987.77, o + .15, .3, .22, .1)
    return m.render()


def arrival():
    m = Mix(3.6)
    pad(m, [N["C4"], N["E4"], N["G4"]], 0, .03, 1.8, 600, 1800)
    bell(m, N["C5"], 0, .12, 1.2, -.35)
    bell(m, N["E5"], .14, .12, 1.2, 0)
    bell(m, N["G5"], .28, .12, 1.6, .35)
    bell(m, N["C6"], .42, .06, 2, 0)
    bell(m, N["G6"], .5, .025, 1.6, .2)
    return m.render()


def destination_ping():
    m = Mix(0.8)
    for i, p in enumerate((-.1, 0, .1)):
        ping(m, 1568, i * .11, .3, .12, p)
    return m.render()


def trim(x, thresh=0.0008):
    idx = np.where(np.max(np.abs(x), axis=0) > thresh)[0]
    return x[:, : (idx[-1] + int(0.02 * SR))] if len(idx) else x


def write(path, x):
    pcm = (np.clip(x, -1, 1).T * 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    print(f"{os.path.basename(path)}: {x.shape[1] / SR:.2f} s")


def main():
    default = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "App", "Resources", "Sounds")
    out = sys.argv[1] if len(sys.argv) > 1 else default
    os.makedirs(out, exist_ok=True)
    bp = battery_ping()
    files = {
        "connect": s1(),
        "ride_start": kick_sync(0.66),
        "ride_start_short": kick_sync(0.2),   # Reduce Motion: T = 0.2 s
        "ride_end": ride_end(),
        "battery_ping": bp,
        "motor_ping": bp,
        "arrival": arrival(),
        "destination_ping": destination_ping(),
    }
    for name, x in files.items():
        write(os.path.join(out, name + ".wav"), x if name.startswith("ride_start") else trim(x))


if __name__ == "__main__":
    main()
