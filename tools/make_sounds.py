"""Organic Tactile Audio synthesizer & Foley asset generator (44100 Hz, 16-bit PCM WAV).

Run from project root:
  python tools/make_sounds.py

Generates structured audio assets under resources/sounds/:
  - Core loops & ambience (roll, grit, freewheel, chain, water, surf, fire, wind)
  - bike/      (tire_rush, brake_pad, skid_loose, skid_firm, air_wind, susp_stroke_*, hop_prep_*, takeoff_*, gear_shift_*, bike_mount_*, bike_dismount_*, stop_foot_*)
  - surfaces/  (tex_* loops for 11 real world surfaces + plank_* + grain_*)
  - impacts/   (land_soft_*, land_med_*, land_hard_*, bump_hit_*, rim_knock_*, fork_bottom_*, crash_*)
  - foley/     (steps/step_<surface>_*, cloth_*, brush_*, water_entry_*)
  - UI & event chimes (ui_*, lamp_switch, discovery_chime, quest_complete, glass_clink)

All synthesis is deterministic (fixed seeds) and uses zero third-party recordings
(100% original procedural DSP + modal physical modeling, commercially unrestricted).
"""

import math
import os
import struct
import numpy as np

RATE = 44100
TAU = 2.0 * math.pi
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "resources", "sounds")


# ---------- Core DSP & Physical Modeling Toolkit ----------

def fft_noise(n, slope_db_per_oct, rng, f_lo=24.0, f_hi=18000.0):
    """Exact circularly-seamless colored noise via FFT spectral shaping."""
    x = rng.standard_normal(n)
    spec = np.fft.rfft(x)
    freqs = np.fft.rfftfreq(n, 1.0 / RATE)
    mag = np.ones_like(freqs)
    mag[0] = 0.0
    nz = freqs > 0.0
    exp = slope_db_per_oct / 6.0205999
    mag[nz] = np.power(np.maximum(freqs[nz], 20.0) / 1000.0, exp)
    # Smooth Butterworth-like rolloffs at f_lo and f_hi
    if f_lo > 0.0:
        r_lo = freqs[nz] / f_lo
        mag[nz] *= (r_lo ** 2) / np.sqrt(1.0 + r_lo ** 4)
    if f_hi < RATE * 0.49:
        r_hi = freqs[nz] / f_hi
        mag[nz] /= np.sqrt(1.0 + r_hi ** 6)
    y = np.fft.irfft(spec * mag, n=n)
    std = np.std(y)
    return y / std if std > 1e-9 else y


def pink(n, rng, f_lo=28.0, f_hi=14000.0):
    return fft_noise(n, -3.0, rng, f_lo, f_hi)


def brown(n, rng, f_lo=25.0, f_hi=6000.0):
    return fft_noise(n, -6.0, rng, f_lo, f_hi)


def white(n, rng, f_lo=30.0, f_hi=18000.0):
    return fft_noise(n, 0.0, rng, f_lo, f_hi)


def fft_bandpass(x, f_lo, f_hi, order=2):
    """Smooth zero-phase FFT bandpass (circular for loops, pad caller for one-shots)."""
    n = len(x)
    spec = np.fft.rfft(x)
    freqs = np.fft.rfftfreq(n, 1.0 / RATE)
    mag = np.zeros_like(freqs)
    nz = freqs > 0.0
    hp = 1.0 / np.sqrt(1.0 + (f_lo / freqs[nz]) ** (2 * order)) if f_lo > 0.0 else 1.0
    lp = 1.0 / np.sqrt(1.0 + (freqs[nz] / f_hi) ** (2 * order)) if f_hi < RATE * 0.49 else 1.0
    mag[nz] = hp * lp
    return np.fft.irfft(spec * mag, n=n)


def fft_eq(x, center_hz, gain_db, q=1.0):
    """Smooth peaking EQ in frequency domain."""
    n = len(x)
    spec = np.fft.rfft(x)
    freqs = np.fft.rfftfreq(n, 1.0 / RATE)
    mag = np.ones_like(freqs)
    nz = freqs > 0.0
    ratio = np.log2(np.maximum(freqs[nz], 1.0) / center_hz)
    bw = 1.0 / max(q, 0.25)
    bell = np.exp(-0.5 * (ratio / (bw * 0.6)) ** 2)
    mag[nz] = 10.0 ** ((gain_db * bell) / 20.0)
    return np.fft.irfft(spec * mag, n=n)


def lowpass_1pole(x, cutoff):
    """Vectorized or time-varying 1-pole lowpass."""
    n = len(x)
    if np.isscalar(cutoff):
        pad = min(n, int(RATE * 0.1))
        xp = np.concatenate([x, x[:pad]]) if pad > 0 else x
        a = 1.0 - math.exp(-TAU * cutoff / RATE)
        out = np.empty(len(xp), dtype=np.float64)
        y = 0.0
        for i in range(len(xp)):
            y += a * (xp[i] - y)
            out[i] = y
        return out[:n]
    out = np.empty(n, dtype=np.float64)
    y = 0.0
    k = -TAU / RATE
    for i in range(n):
        a = 1.0 - math.exp(k * cutoff[i])
        y += a * (x[i] - y)
        out[i] = y
    return out


def biquad_bp(x, freq, q):
    """Causal RBJ bandpass biquad (handles scalar or array freq)."""
    n = len(x)
    out = np.empty(n, dtype=np.float64)
    x1 = x2 = y1 = y2 = 0.0
    scalar = np.isscalar(freq)
    if scalar:
        w0 = TAU * min(freq, RATE * 0.45) / RATE
        al = math.sin(w0) / (2.0 * q)
        a0 = 1.0 + al
        b0 = al / a0
        b2 = -al / a0
        a1 = -2.0 * math.cos(w0) / a0
        a2 = (1.0 - al) / a0
    for i in range(n):
        if not scalar:
            w0 = TAU * min(freq[i], RATE * 0.45) / RATE
            al = math.sin(w0) / (2.0 * q)
            a0 = 1.0 + al
            b0 = al / a0
            b2 = -al / a0
            a1 = -2.0 * math.cos(w0) / a0
            a2 = (1.0 - al) / a0
        v = x[i]
        y = b0 * v + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1 = x1, v
        y2, y1 = y1, y
        out[i] = y
    return out


def smooth_mod(n, rate_hz, rng):
    """Circularly seamless smooth modulation curve in [0, 1]."""
    x = fft_bandpass(rng.standard_normal(n), 0.0, rate_hz, order=3)
    lo, hi = np.min(x), np.max(x)
    return (x - lo) / (hi - lo + 1e-9)


def circular_mix(dst, src, at):
    """Add src into dst wrapping seamlessly modulo len(dst)."""
    n = len(dst)
    m = len(src)
    idx = (np.arange(m) + int(at)) % n
    np.add.at(dst, idx, src)


def mix_at(dst, src, at=0, gain=1.0):
    at = int(at)
    n = len(dst)
    m = len(src)
    if at >= n or at + m <= 0:
        return
    s0 = max(0, -at)
    d0 = max(0, at)
    cnt = min(m - s0, n - d0)
    dst[d0:d0 + cnt] += src[s0:s0 + cnt] * gain


def fade(x, ms_in=2.0, ms_out=25.0):
    out = x.copy()
    n_in = min(len(out), int(RATE * ms_in / 1000.0))
    n_out = min(len(out), int(RATE * ms_out / 1000.0))
    if n_in > 0:
        t = np.linspace(0.0, 0.5 * math.pi, n_in)
        out[:n_in] *= np.sin(t) ** 2
    if n_out > 0:
        t = np.linspace(0.0, 0.5 * math.pi, n_out)
        out[-n_out:] *= np.cos(t) ** 2
    return out


def modal_hit(seconds, modes, rng, exc_ms=4.0, exc_bw=(180.0, 1600.0)):
    """Physical damped modal body excited by a soft shaped contact impulse."""
    n = int(RATE * seconds)
    t = np.arange(n, dtype=np.float64) / RATE
    out = np.zeros(n, dtype=np.float64)
    # Soft damped excitation transient (rubber/wood/soil contact)
    ne = min(n, max(8, int(RATE * exc_ms / 1000.0)))
    exc = rng.standard_normal(ne)
    env_e = np.sin(np.linspace(0.0, math.pi, ne)) ** 1.5
    exc_pad = np.zeros(n, dtype=np.float64)
    exc_pad[:ne] = exc * env_e
    out += fft_bandpass(exc_pad, exc_bw[0], exc_bw[1], order=2) * 0.45
    # Damped resonant modes
    atk = np.minimum(1.0, t / 0.0025)
    for freq, decay_ms, amp in modes:
        ph = rng.uniform(0.0, 0.35)
        tau = max(0.002, decay_ms / 1000.0)
        out += amp * atk * np.exp(-t / tau) * np.sin(TAU * freq * t + ph)
    return out


def grain(ms, f_lo, f_hi, rng, attack_ms=0.8, decay_ms=None):
    """Single natural micro-grain (pebble, sand, twig, snow crystal)."""
    n = max(16, int(RATE * ms / 1000.0))
    if decay_ms is None:
        decay_ms = ms * 0.32
    t_ms = np.arange(n, dtype=np.float64) * 1000.0 / RATE
    atk = np.minimum(1.0, t_ms / max(0.2, attack_ms))
    env = (atk ** 1.5) * np.exp(-t_ms / max(0.3, decay_ms))
    env *= np.sin(np.linspace(0.0, math.pi, n)) ** 0.5
    x = rng.standard_normal(n) * env
    return fft_bandpass(x, f_lo, f_hi, order=2)


def pitch_thump(seconds, f0, f1, decay_ms, attack_ms=2.5, harm2=0.12):
    """Warm sub/low body thump with smooth pitch drop."""
    n = int(RATE * seconds)
    t = np.arange(n, dtype=np.float64) / RATE
    decay = decay_ms / 1000.0
    freq = f1 + (f0 - f1) * np.exp(-t / max(0.008, decay * 0.45))
    ph = np.cumsum(TAU * freq / RATE)
    atk = np.minimum(1.0, t / max(0.0008, attack_ms / 1000.0))
    env = (atk ** 1.4) * np.exp(-t / decay)
    return env * (np.sin(ph) + harm2 * np.sin(2.0 * ph))


def tone_sweep(seconds, f0, f1, harm=0.06, vib=0.0, vib_hz=0.0):
    """Smooth Hann-windowed tonal sweep (birds, UI chimes, water droplets)."""
    n = max(8, int(RATE * seconds))
    t = np.linspace(0.0, 1.0, n)
    f = f0 + (f1 - f0) * (0.5 - 0.5 * np.cos(math.pi * t))
    if vib > 0.0 and vib_hz > 0.0:
        f *= 1.0 + vib * np.sin(TAU * vib_hz * np.arange(n) / RATE)
    ph = np.cumsum(TAU * f / RATE)
    env = np.sin(math.pi * t) ** 2
    return env * (np.sin(ph) + harm * np.sin(2.0 * ph))


def soft_saturate(x, drive=1.15):
    return np.tanh(x * drive) / math.tanh(drive)


def prepare_audio(x, peak=0.60, target_rms=None):
    x = np.asarray(x, dtype=np.float64)
    x = x - np.mean(x)
    x = np.nan_to_num(x, nan=0.0, posinf=0.0, neginf=0.0)
    if target_rms is not None:
        rms = float(np.sqrt(np.mean(x * x)))
        if rms > 1e-9:
            x = x * (target_rms / rms)
        cur_peak = float(np.max(np.abs(x)))
        if cur_peak > peak:
            x = soft_saturate(x * (peak / cur_peak) * 1.15, 1.2)
            cur_peak = float(np.max(np.abs(x)))
            if cur_peak > peak:
                x *= peak / cur_peak
    else:
        cur_peak = float(np.max(np.abs(x)))
        if cur_peak > 1e-9:
            x = x * (peak / cur_peak)
    return np.clip(x, -0.95, 0.95)


# С 27.11.2026 петли езды (качение, цепь, свободный ход, покрытия, зёрна грунта и снега) делает
# tools/make_ride_sounds.gd (Godot, без numpy): прежние петли гудели (низы 75–420 Гц, опущенные по высоте).
# Ветер езды (bike/air_wind) и шипение шины (bike/tire_rush) убраны из игры.
# Их генераторы здесь по-прежнему вызываются, чтобы общий rng шёл как раньше и остальные звуки
# (приземления, шаги, окружение) при перезапуске получались байт в байт прежними; файлы не пишутся.
SKIP_FILES = {
    "roll.wav", "freewheel.wav", "chain.wav", "bike/tire_rush.wav", "bike/air_wind.wav",
} | {f"surfaces/tex_{s}.wav" for s in (
    "packed", "dirt", "forest", "gravel", "grass", "sand", "stone", "wet", "wood", "snow", "water")}


def write_wav(rel_path, x, looped=False, peak=0.60, target_rms=None):
    if rel_path in SKIP_FILES:
        return
    x = prepare_audio(x, peak=peak, target_rms=target_rms)
    pcm = np.round(x * 32767.0).astype("<i2").tobytes()
    fmt = struct.pack("<HHIIHH", 1, 1, RATE, RATE * 2, 2, 16)
    chunks = b"fmt " + struct.pack("<I", len(fmt)) + fmt
    chunks += b"data" + struct.pack("<I", len(pcm)) + pcm
    if looped:
        smpl = struct.pack("<9I", 0, 0, int(1e9 / RATE), 60, 0, 0, 0, 1, 0)
        smpl += struct.pack("<6I", 0, 0, 0, len(x) - 1, 0, 0)
        chunks += b"smpl" + struct.pack("<I", len(smpl)) + smpl
    full_path = os.path.join(ROOT, rel_path)
    os.makedirs(os.path.dirname(full_path), exist_ok=True)
    with open(full_path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 4 + len(chunks)) + b"WAVE" + chunks)


# ---------- 1. Core Bike Loops & Drivetrain ----------

def make_roll(rng):
    """Warm pneumatic rubber tire casing contact + subtle frame resonance (no wind/mic boom)."""
    n = RATE * 8
    casing = fft_bandpass(pink(n, rng, 55.0, 520.0), 75.0, 420.0, order=2)
    casing = fft_eq(casing, 130.0, -3.5, q=0.9)
    casing = fft_eq(casing, 240.0, 2.5, q=1.1)
    tread_hum = fft_bandpass(pink(n, rng, 180.0, 950.0), 220.0, 720.0, order=2)
    breath = 0.88 + 0.12 * smooth_mod(n, 0.45, rng)
    # Subtle micro tire-knob undulation (~14 Hz) so it feels tactile, not static pink noise
    knob = 0.94 + 0.06 * smooth_mod(n, 16.0, rng)
    return (casing * 0.85 + tread_hum * 0.28) * breath * knob


def make_tire_rush(rng):
    """Silky high-speed tire air-shearing & knob rush (500-2400 Hz)."""
    n = RATE * 6
    hiss = fft_bandpass(pink(n, rng, 350.0, 3200.0), 520.0, 2200.0, order=2)
    hiss = fft_eq(hiss, 1100.0, 2.0, q=0.8)
    breath = 0.84 + 0.16 * smooth_mod(n, 0.8, rng)
    return hiss * breath


def make_freewheel(rng, seconds=2.0, rate=24):
    """Precision 24T freehub ratchet inside damped aluminum shell — warm, zero piercing sines."""
    n = int(RATE * seconds)
    out = np.zeros(n, dtype=np.float64)
    clicks = int(seconds * rate)
    step = n / clicks
    for k in range(clicks):
        at = int(round(k * step + rng.uniform(-0.00025, 0.00025) * RATE)) % n
        g = rng.uniform(0.86, 1.04)
        # Damped hub shell modes + crisp non-harsh pawl strike
        m1 = rng.uniform(1180.0, 1260.0)
        m2 = rng.uniform(2100.0, 2240.0)
        m3 = rng.uniform(3100.0, 3350.0)
        click = modal_hit(
            0.016,
            [(m1, 3.2, 0.55), (m2, 2.4, 0.40), (m3, 1.5, 0.18)],
            rng,
            exc_ms=1.6,
            exc_bw=(1400.0, 3800.0),
        )
        click = fade(click, ms_in=0.2, ms_out=4.0) * g
        circular_mix(out, click, at)
    # Very gentle hub bearing roll underneath
    bearing = fft_bandpass(pink(n, rng, 180.0, 900.0), 220.0, 750.0, order=2) * 0.05
    return fft_bandpass(out + bearing, 300.0, 5200.0, order=2)


def make_chain(rng):
    """Silky lubricated drivetrain: warm crank hum + soft oiled roller meshing."""
    n = RATE * 4
    hum = fft_bandpass(pink(n, rng, 110.0, 480.0), 140.0, 380.0, order=2) * 0.55
    mesh = fft_bandpass(pink(n, rng, 650.0, 2600.0), 800.0, 2100.0, order=2) * 0.35
    out = hum + mesh
    # Soft lubricated chain roller links (~38 links/s)
    t = 0
    while t < n:
        t += int(RATE / rng.uniform(34.0, 44.0))
        link = grain(rng.uniform(4.0, 7.0), 950.0, 2400.0, rng, attack_ms=0.6, decay_ms=1.8)
        circular_mix(out, link * rng.uniform(0.12, 0.24), t)
    return fft_bandpass(out, 100.0, 3200.0, order=2)


def make_brake_pad(rng):
    """Velvety rotor-pad mechanical bite — zero metallic squeal."""
    n = RATE * 4
    bed = fft_bandpass(pink(n, rng, 320.0, 1750.0), 420.0, 1450.0, order=2)
    bed = fft_eq(bed, 780.0, 2.5, q=0.9)
    pulse = 0.82 + 0.18 * smooth_mod(n, 14.0, rng)
    sub = fft_bandpass(brown(n, rng, 90.0, 320.0), 110.0, 260.0, order=2) * 0.35
    return bed * pulse + sub


def make_skid_loose(rng):
    """Tire shearing loose gravel/soil — rich displaced stones + earth body."""
    n = RATE * 4
    earth = fft_bandpass(pink(n, rng, 130.0, 1400.0), 160.0, 1100.0, order=2) * 0.65
    shear = fft_bandpass(pink(n, rng, 600.0, 3200.0), 750.0, 2600.0, order=2) * 0.45
    out = earth + shear
    t = 0
    while t < n:
        t += int(RATE * rng.exponential(1.0 / 130.0)) + 4
        g = grain(rng.uniform(5.0, 13.0), rng.uniform(700.0, 1400.0), rng.uniform(1900.0, 3400.0), rng, 0.5, rng.uniform(1.6, 4.0))
        circular_mix(out, g * rng.uniform(0.35, 0.95), t)
    return fft_bandpass(out, 110.0, 3800.0, order=2)


def make_skid_firm(rng):
    """Controlled rubber tire scrub on firm packed dirt/stone/wood — zero screech."""
    n = RATE * 4
    scrub = fft_bandpass(pink(n, rng, 200.0, 1650.0), 260.0, 1350.0, order=2)
    scrub = fft_eq(scrub, 520.0, 3.0, q=0.8)
    flutter = 0.78 + 0.22 * smooth_mod(n, 22.0, rng)
    grit_bed = fft_bandpass(pink(n, rng, 900.0, 2800.0), 1000.0, 2400.0, order=2) * 0.22
    return scrub * flutter + grit_bed


def make_air_wind(rng):
    """Soft, non-fatiguing aerodynamic rush for speed & airborne flight."""
    n = RATE * 8
    low = fft_bandpass(brown(n, rng, 70.0, 380.0), 90.0, 320.0, order=2) * 0.65
    mid = fft_bandpass(pink(n, rng, 180.0, 950.0), 220.0, 780.0, order=2) * 0.55
    gust = 0.72 + 0.28 * smooth_mod(n, 0.35, rng)
    return (low + mid) * gust


# ---------- 2. Surface Texture Loops (11 Real Surfaces) ----------

def make_tex_packed(rng):
    """Packed earth near settlements: firm, warm, subtle fine dust."""
    n = RATE * 5
    body = fft_bandpass(pink(n, rng, 180.0, 1500.0), 220.0, 1200.0, order=2) * 0.7
    dust = fft_bandpass(white(n, rng, 1400.0, 3600.0), 1600.0, 3200.0, order=2) * 0.18
    mod = 0.86 + 0.14 * smooth_mod(n, 1.5, rng)
    return (body + dust) * mod


def make_tex_dirt(rng):
    """Dry dirt road: warm earthy roll + sparse soft clods/grit."""
    n = RATE * 5
    out = fft_bandpass(pink(n, rng, 160.0, 1600.0), 200.0, 1300.0, order=2) * 0.6
    t = 0
    while t < n:
        t += int(RATE * rng.exponential(1.0 / 55.0)) + 8
        g = grain(rng.uniform(4.0, 10.0), rng.uniform(550.0, 1100.0), rng.uniform(1500.0, 2600.0), rng, 0.6, rng.uniform(1.2, 3.0))
        circular_mix(out, g * rng.uniform(0.20, 0.55), t)
    return fft_bandpass(out, 140.0, 3200.0, order=2)


def make_tex_forest(rng):
    """Forest trail: cushioned pine needles/loam + delicate organic twig/leaf crinkles."""
    n = RATE * 6
    loam = fft_bandpass(brown(n, rng, 90.0, 650.0), 110.0, 520.0, order=2) * 0.65
    needles = fft_bandpass(pink(n, rng, 700.0, 2600.0), 850.0, 2200.0, order=2) * 0.25
    out = loam + needles
    t = 0
    while t < n:
        t += int(RATE * rng.exponential(1.0 / 32.0)) + 16
        crinkle = grain(rng.uniform(7.0, 18.0), rng.uniform(900.0, 1600.0), rng.uniform(2200.0, 3800.0), rng, 1.0, rng.uniform(2.5, 6.0))
        circular_mix(out, crinkle * rng.uniform(0.25, 0.65), t)
    return fft_bandpass(out, 90.0, 4200.0, order=2)


def make_tex_gravel(rng):
    """Gravel road: voluminous rolling pebbles across low/mid/crisp bands (fatigue-free)."""
    n = RATE * 5
    bed = fft_bandpass(pink(n, rng, 140.0, 1100.0), 170.0, 900.0, order=2) * 0.42
    out = bed
    # Medium tumbling pebbles
    t = 0
    while t < n:
        t += int(RATE * rng.exponential(1.0 / 110.0)) + 4
        f_c = rng.uniform(650.0, 1650.0)
        g = grain(rng.uniform(5.0, 12.0), f_c * 0.7, f_c * 1.45, rng, 0.5, rng.uniform(1.4, 3.4))
        circular_mix(out, g * rng.uniform(0.35, 0.90), t)
    # Finer top pebbles (rolled off gently above 3.6 kHz)
    t = 0
    while t < n:
        t += int(RATE * rng.exponential(1.0 / 140.0)) + 3
        f_c = rng.uniform(1700.0, 2900.0)
        g = grain(rng.uniform(3.0, 6.5), f_c * 0.75, f_c * 1.35, rng, 0.35, rng.uniform(0.8, 1.8))
        circular_mix(out, g * rng.uniform(0.22, 0.55), t)
    return fft_bandpass(out, 120.0, 4000.0, order=2)


def make_tex_grass(rng):
    """Meadow/grass track: muffled earth + soft swishing grass blades."""
    n = RATE * 5
    cushion = fft_bandpass(brown(n, rng, 80.0, 450.0), 100.0, 380.0, order=2) * 0.55
    swish = fft_bandpass(pink(n, rng, 650.0, 3200.0), 800.0, 2600.0, order=2) * 0.45
    swish *= 0.65 + 0.35 * smooth_mod(n, 3.2, rng)
    out = cushion + swish
    t = 0
    while t < n:
        t += int(RATE * rng.exponential(1.0 / 28.0)) + 16
        blade = grain(rng.uniform(12.0, 26.0), 1200.0, 3200.0, rng, 3.5, rng.uniform(5.0, 10.0))
        circular_mix(out, blade * rng.uniform(0.15, 0.35), t)
    return fft_bandpass(out, 85.0, 3800.0, order=2)


def make_tex_sand(rng):
    """Sand: fine-grained, loose sifting friction with damped sink."""
    n = RATE * 5
    sink = fft_bandpass(brown(n, rng, 95.0, 420.0), 110.0, 360.0, order=2) * 0.55
    sift = fft_bandpass(white(n, rng, 900.0, 3800.0), 1100.0, 3300.0, order=2) * 0.48
    sift = fft_eq(sift, 2100.0, 2.5, q=0.7)
    sift *= 0.78 + 0.22 * smooth_mod(n, 2.4, rng)
    return fft_bandpass(sink + sift, 90.0, 4200.0, order=2)


def make_tex_stone(rng):
    """Rocky surface: dense, short, non-harsh rubber-knob contacts on rock."""
    n = RATE * 5
    out = fft_bandpass(pink(n, rng, 140.0, 950.0), 160.0, 800.0, order=2) * 0.50
    t = 0
    while t < n:
        t += int(RATE * rng.exponential(1.0 / 48.0)) + 8
        tap = modal_hit(0.025, [(rng.uniform(220.0, 340.0), 7.0, 0.7), (rng.uniform(550.0, 820.0), 4.0, 0.3)], rng, 2.5, (200.0, 1300.0))
        circular_mix(out, fade(tap, 0.4, 8.0) * rng.uniform(0.25, 0.65), t)
    return fft_bandpass(out, 110.0, 2600.0, order=2)


def make_tex_wet(rng):
    """Wet soil/swamp: soft, dense damp compression + tiny gentle moisture squelches."""
    n = RATE * 5
    damp = fft_bandpass(brown(n, rng, 95.0, 620.0), 115.0, 520.0, order=2) * 0.70
    sheen = fft_bandpass(pink(n, rng, 550.0, 2200.0), 650.0, 1800.0, order=2) * 0.32
    out = damp + sheen
    t = 0
    while t < n:
        t += int(RATE * rng.exponential(1.0 / 26.0)) + 20
        f0 = rng.uniform(280.0, 620.0)
        pop = tone_sweep(rng.uniform(0.02, 0.045), f0, f0 * rng.uniform(1.3, 1.8), harm=0.0)
        circular_mix(out, pop * rng.uniform(0.08, 0.22), t)
        sq = grain(rng.uniform(10.0, 22.0), 450.0, 1400.0, rng, 2.5, rng.uniform(4.0, 8.0))
        circular_mix(out, sq * rng.uniform(0.20, 0.45), t)
    return fft_bandpass(out, 90.0, 2800.0, order=2)


def make_tex_wood(rng):
    """Wooden deck: warm hollow timber resonance underneath plank seams."""
    n = RATE * 5
    hollow = fft_bandpass(brown(n, rng, 85.0, 380.0), 100.0, 320.0, order=2) * 0.80
    grain_bed = fft_bandpass(pink(n, rng, 320.0, 1100.0), 380.0, 920.0, order=2) * 0.30
    return hollow + grain_bed


def make_tex_snow(rng):
    """Snow: muffled delicate crystalline compression crunch."""
    n = RATE * 5
    pack = fft_bandpass(brown(n, rng, 80.0, 360.0), 95.0, 300.0, order=2) * 0.50
    out = pack
    t = 0
    while t < n:
        t += int(RATE * rng.exponential(1.0 / 95.0)) + 5
        cr = grain(rng.uniform(5.0, 14.0), rng.uniform(950.0, 1500.0), rng.uniform(2200.0, 3600.0), rng, 1.2, rng.uniform(2.0, 5.0))
        circular_mix(out, cr * rng.uniform(0.28, 0.68), t)
    return fft_bandpass(out, 80.0, 3800.0, order=2)


def make_tex_water(rng):
    """Shallow water wading / wheel spray: continuous splash + bubbling droplets."""
    n = RATE * 5
    spray = fft_bandpass(pink(n, rng, 320.0, 3200.0), 420.0, 2600.0, order=2)
    spray *= 0.55 + 0.45 * smooth_mod(n, 6.5, rng)
    out = spray * 0.70
    t = 0
    while t < n:
        t += int(RATE * rng.exponential(1.0 / 35.0)) + 15
        f0 = rng.uniform(380.0, 950.0)
        drop = tone_sweep(rng.uniform(0.025, 0.06), f0, f0 * rng.uniform(1.4, 2.2), harm=0.0)
        circular_mix(out, drop * rng.uniform(0.10, 0.26), t)
    return fft_bandpass(out, 180.0, 4200.0, order=2)


def make_plank(rng):
    """Warm hollow wooden bridge plank thump when tire crosses a seam."""
    f1 = rng.uniform(98.0, 124.0)
    f2 = f1 * rng.uniform(1.75, 1.98)
    f3 = f1 * rng.uniform(2.8, 3.2)
    body = modal_hit(0.14, [(f1, 34.0, 1.0), (f2, 22.0, 0.45), (f3, 12.0, 0.16)], rng, 3.5, (140.0, 720.0))
    return fade(fft_bandpass(body, 65.0, 1600.0, order=2), 1.0, 35.0)


def make_surface_grain(kind, rng):
    """Individual sparse micro-detail grain for forest/gravel/stone/wet."""
    if kind == "forest":
        x = grain(rng.uniform(18.0, 32.0), 700.0, 2800.0, rng, 1.5, 7.0)
        mix_at(x, modal_hit(0.03, [(rng.uniform(420.0, 680.0), 8.0, 0.3)], rng, 2.0, (400.0, 1600.0)), 0, 0.4)
        return fade(x, 0.8, 8.0)
    if kind == "gravel":
        f = rng.uniform(900.0, 2100.0)
        x = modal_hit(0.028, [(f, 5.0, 0.5), (f * 1.4, 3.0, 0.25)], rng, 1.5, (700.0, 2800.0))
        return fade(x, 0.4, 8.0)
    if kind == "stone":
        x = modal_hit(0.032, [(rng.uniform(240.0, 380.0), 9.0, 0.8), (rng.uniform(620.0, 920.0), 5.0, 0.3)], rng, 2.0, (200.0, 1200.0))
        return fade(x, 0.5, 10.0)
    # wet
    f0 = rng.uniform(320.0, 560.0)
    x = tone_sweep(0.045, f0, f0 * 1.65, harm=0.0) * 0.45
    mix_at(x, grain(35.0, 320.0, 1200.0, rng, 4.0, 10.0), 0, 0.7)
    return fade(x, 1.5, 12.0)


# ---------- 3. Jumps, Landings, Suspension, Impacts & Bike Mechanics ----------

def make_hop_prep(rng):
    """Soft suspension preload & rider weight drop before jump."""
    n = int(RATE * 0.14)
    whoosh = fft_bandpass(pink(n, rng, 180.0, 1400.0), 220.0, 1100.0, order=2)
    env = np.sin(np.linspace(0.0, math.pi, n)) ** 1.4
    thud = pitch_thump(0.14, 95.0, 65.0, 28.0, attack_ms=8.0, harm2=0.05) * 0.45
    return fade(whoosh * env * 0.75 + thud, 4.0, 30.0)


def make_takeoff(is_hop, rng):
    """Takeoff: crisp fork top-out rebound + tire release (hop) or smooth crest unweight."""
    n = int(RATE * (0.18 if is_hop else 0.16))
    out = np.zeros(n, dtype=np.float64)
    rebound = fft_bandpass(pink(n, rng, 350.0, 2200.0), 450.0, 1800.0, order=2)
    env = np.sin(np.linspace(0.0, math.pi, n)) ** 1.2 * np.exp(-np.linspace(0.0, 2.8 if is_hop else 3.5, n))
    out += rebound * env * (0.85 if is_hop else 0.55)
    if is_hop:
        # Subtle top-out rubber stopper + tire snap off surface
        mix_at(out, pitch_thump(0.11, 145.0, 95.0, 22.0, attack_ms=2.0, harm2=0.08), 0, 0.65)
        mix_at(out, modal_hit(0.07, [(420.0, 10.0, 0.35), (780.0, 7.0, 0.18)], rng, 2.0, (350.0, 1500.0)), int(RATE * 0.015), 0.30)
    else:
        mix_at(out, pitch_thump(0.10, 110.0, 75.0, 25.0, attack_ms=4.0, harm2=0.04), 0, 0.40)
    return fade(out, 1.5, 40.0)


def make_landing(tier, rng):
    """Multi-layered tactile landing: soft / med / hard. Punchy, organic, never explosive."""
    dur = 0.28 if tier == "soft" else (0.36 if tier == "med" else 0.46)
    n = int(RATE * dur)
    out = np.zeros(n, dtype=np.float64)
    if tier == "soft":
        mix_at(out, pitch_thump(0.22, 82.0, 48.0, 46.0, attack_ms=3.5, harm2=0.10), 0, 0.85)
        air = fft_bandpass(pink(n, rng, 220.0, 1100.0), 260.0, 900.0, order=2)
        air *= np.exp(-np.arange(n) / (RATE * 0.055)) * np.minimum(1.0, np.arange(n) / (RATE * 0.006))
        out += air * 0.45
    elif tier == "med":
        mix_at(out, pitch_thump(0.28, 92.0, 44.0, 56.0, attack_ms=2.5, harm2=0.14), 0, 1.0)
        # Rear wheel follows front slightly or simultaneously
        mix_at(out, pitch_thump(0.24, 78.0, 42.0, 52.0, attack_ms=3.0, harm2=0.10), int(RATE * rng.uniform(0.012, 0.026)), 0.70)
        air = fft_bandpass(pink(n, rng, 260.0, 1450.0), 320.0, 1200.0, order=2)
        air *= np.exp(-np.arange(n) / (RATE * 0.065)) * np.minimum(1.0, np.arange(n) / (RATE * 0.004))
        out += air * 0.62
        # Frame/fork damped settle
        mix_at(out, modal_hit(0.14, [(165.0, 24.0, 0.38), (310.0, 14.0, 0.16)], rng, 3.0, (180.0, 900.0)), 0, 0.42)
    else:  # hard
        mix_at(out, pitch_thump(0.34, 105.0, 40.0, 68.0, attack_ms=2.0, harm2=0.18), 0, 1.0)
        mix_at(out, pitch_thump(0.28, 86.0, 38.0, 60.0, attack_ms=2.5, harm2=0.14), int(RATE * rng.uniform(0.014, 0.030)), 0.78)
        air = fft_bandpass(pink(n, rng, 280.0, 1800.0), 350.0, 1450.0, order=2)
        air *= np.exp(-np.arange(n) / (RATE * 0.075)) * np.minimum(1.0, np.arange(n) / (RATE * 0.003))
        out += air * 0.75
        # Subtle lubricated chain slap & frame thud (warm, never harsh metallic clang)
        mix_at(out, modal_hit(0.18, [(150.0, 28.0, 0.45), (285.0, 18.0, 0.25), (540.0, 10.0, 0.10)], rng, 3.0, (160.0, 1100.0)), 0, 0.50)
        slap = grain(24.0, 900.0, 2400.0, rng, 1.0, 6.0)
        mix_at(out, slap * 0.25, int(RATE * 0.025))
        mix_at(out, slap * 0.16, int(RATE * 0.068))
    return fade(fft_bandpass(out, 36.0, 3600.0, order=2), 1.0, 65.0)


def make_bump_hit(rng):
    """Organic damped rubber-tire + rim bump over a root or stone."""
    f1 = rng.uniform(115.0, 148.0)
    f2 = rng.uniform(230.0, 290.0)
    body = modal_hit(0.13, [(f1, 24.0, 0.90), (f2, 14.0, 0.40)], rng, 2.5, (140.0, 1100.0))
    thud = pitch_thump(0.13, 130.0, 75.0, 22.0, attack_ms=1.5, harm2=0.10)
    return fade(fft_bandpass(body * 0.7 + thud * 0.65, 55.0, 2200.0, order=2), 0.8, 30.0)


def make_rim_knock(rng):
    """Heavier obstacle edge strike: firm tire compression + damped alloy rim knock."""
    f1 = rng.uniform(155.0, 185.0)
    f2 = rng.uniform(340.0, 410.0)
    f3 = rng.uniform(680.0, 780.0)
    body = modal_hit(0.16, [(f1, 22.0, 0.85), (f2, 14.0, 0.45), (f3, 8.0, 0.18)], rng, 2.0, (200.0, 1700.0))
    thud = pitch_thump(0.16, 165.0, 88.0, 24.0, attack_ms=1.0, harm2=0.12)
    return fade(fft_bandpass(body * 0.75 + thud * 0.7, 65.0, 2600.0, order=2), 0.6, 35.0)


def make_fork_bottom(rng):
    """Fork bottom-out: dense rubber bump-stop thud + damped stanchion stop."""
    thud = pitch_thump(0.20, 125.0, 68.0, 36.0, attack_ms=1.2, harm2=0.14)
    stop = modal_hit(0.20, [(190.0, 26.0, 0.75), (410.0, 15.0, 0.35), (860.0, 9.0, 0.14)], rng, 2.0, (180.0, 1500.0))
    whoosh = fft_bandpass(pink(int(RATE * 0.16), rng, 280.0, 1400.0), 320.0, 1100.0, order=2)
    whoosh *= np.exp(-np.arange(len(whoosh)) / (RATE * 0.032))
    out = thud * 0.85 + stop * 0.60
    mix_at(out, whoosh * 0.35, 0)
    return fade(fft_bandpass(out, 48.0, 2400.0, order=2), 0.6, 45.0)


def make_susp_stroke(rng):
    """Soft air/oil fork damper breathing over bumps & rollers."""
    n = int(RATE * rng.uniform(0.13, 0.18))
    hiss = fft_bandpass(pink(n, rng, 280.0, 1500.0), 360.0, 1200.0, order=2)
    env = np.sin(np.linspace(0.0, math.pi, n)) ** 1.6
    low = fft_bandpass(brown(n, rng, 80.0, 300.0), 95.0, 250.0, order=2) * 0.4
    return fade((hiss * 0.7 + low) * env, 4.0, 28.0)


def make_gear_shift(rng):
    """Crisp mechanical derailleur click + brief chain settle."""
    n = int(RATE * 0.11)
    out = np.zeros(n, dtype=np.float64)
    c1 = modal_hit(0.04, [(rng.uniform(1150.0, 1320.0), 4.0, 0.55), (rng.uniform(2100.0, 2350.0), 2.8, 0.25)], rng, 1.2, (800.0, 3200.0))
    c2 = modal_hit(0.05, [(rng.uniform(860.0, 980.0), 5.0, 0.45), (rng.uniform(1650.0, 1850.0), 3.0, 0.22)], rng, 1.5, (600.0, 2500.0))
    mix_at(out, fade(c1, 0.2, 8.0), 0, 0.85)
    mix_at(out, fade(c2, 0.2, 10.0), int(RATE * rng.uniform(0.022, 0.036)), 0.70)
    return fade(fft_bandpass(out, 250.0, 4200.0, order=2), 0.4, 25.0)


def make_bike_mount(rng):
    """Warm frame/saddle settle + soft cleat/pedal engagement."""
    n = int(RATE * 0.24)
    out = np.zeros(n, dtype=np.float64)
    settle = pitch_thump(0.16, 98.0, 62.0, 38.0, attack_ms=4.0, harm2=0.08) * 0.7
    cloth = fft_bandpass(pink(n, rng, 350.0, 1800.0), 420.0, 1450.0, order=2) * np.sin(np.linspace(0.0, math.pi, n)) ** 1.5 * 0.35
    click = modal_hit(0.045, [(920.0, 5.0, 0.45), (1680.0, 3.0, 0.20)], rng, 1.5, (700.0, 2600.0))
    mix_at(out, settle, 0)
    out += cloth
    mix_at(out, fade(click, 0.3, 8.0), int(RATE * 0.085), 0.55)
    return fade(out, 2.0, 45.0)


def make_bike_dismount(rng):
    """Gentle frame unload + shoe sole touch."""
    n = int(RATE * 0.24)
    out = np.zeros(n, dtype=np.float64)
    unload = fft_bandpass(pink(n, rng, 250.0, 1400.0), 300.0, 1100.0, order=2) * np.sin(np.linspace(0.0, math.pi, n)) ** 1.6 * 0.45
    sole = pitch_thump(0.14, 105.0, 68.0, 30.0, attack_ms=3.0, harm2=0.06) * 0.7
    out += unload
    mix_at(out, sole, int(RATE * 0.055))
    return fade(out, 2.0, 45.0)


def make_stop_foot(rng):
    """Soft shoe sole plant + gentle brake lever settle."""
    n = int(RATE * 0.16)
    out = np.zeros(n, dtype=np.float64)
    sole = pitch_thump(0.12, 95.0, 64.0, 24.0, attack_ms=3.0, harm2=0.05) * 0.75
    scuff = grain(35.0, 400.0, 1600.0, rng, 4.0, 10.0) * 0.45
    mix_at(out, sole, 0)
    mix_at(out, scuff, 0)
    return fade(out, 1.5, 35.0)


def make_crash_impact(rng):
    """Natural tumble: body/frame thud on earth + damped frame knock + dirt slide."""
    n = int(RATE * 0.95)
    out = np.zeros(n, dtype=np.float64)
    mix_at(out, pitch_thump(0.32, 92.0, 42.0, 80.0, attack_ms=2.0, harm2=0.15), 0, 1.0)
    mix_at(out, modal_hit(0.24, [(210.0, 32.0, 0.45), (460.0, 18.0, 0.22)], rng, 2.5, (180.0, 1200.0)), int(RATE * 0.012), 0.45)
    m = int(RATE * 0.78)
    scrape = fft_bandpass(pink(m, rng, 250.0, 2200.0), 350.0, 1750.0, order=2)
    t = np.linspace(0.0, 1.0, m)
    env = (np.sin(0.5 * math.pi * np.minimum(1.0, t * 7.0)) ** 2) * ((1.0 - t) ** 1.6)
    env *= 0.65 + 0.35 * smooth_mod(m, 14.0, rng)
    mix_at(out, scrape * env * 0.85, int(RATE * 0.05))
    return fade(fft_bandpass(out, 40.0, 3200.0, order=2), 1.5, 130.0)


# ---------- 4. Footsteps & On-Foot / World Foley ----------

def make_step(kind, rng):
    """Natural human footstep with sole roll, material interaction, and warm body."""
    n = int(RATE * 0.26)
    out = np.zeros(n, dtype=np.float64)
    heel = pitch_thump(0.11, 96.0, 58.0, 22.0, attack_ms=3.5, harm2=0.06)
    toe = pitch_thump(0.09, 82.0, 54.0, 18.0, attack_ms=5.0, harm2=0.04)
    toe_at = int(RATE * rng.uniform(0.038, 0.055))
    if kind in ("packed", "soft"):
        mix_at(out, heel, 0, 0.72)
        mix_at(out, toe, toe_at, 0.42)
        mix_at(out, grain(75.0, 280.0, 1450.0, rng, 6.0, 22.0), 0, 0.55)
    elif kind == "dirt":
        mix_at(out, heel, 0, 0.68)
        mix_at(out, toe, toe_at, 0.42)
        mix_at(out, grain(95.0, 380.0, 2200.0, rng, 5.0, 28.0), 0, 0.65)
        for _ in range(rng.integers(3, 6)):
            mix_at(out, grain(9.0, 900.0, 2600.0, rng, 0.6, 2.5), int(RATE * rng.uniform(0.01, 0.09)), 0.22)
    elif kind == "forest":
        mix_at(out, heel, 0, 0.62)
        mix_at(out, grain(110.0, 320.0, 2400.0, rng, 8.0, 34.0), 0, 0.58)
        for _ in range(rng.integers(4, 8)):
            mix_at(out, grain(rng.uniform(8.0, 18.0), 1000.0, 3400.0, rng, 1.2, 4.5), int(RATE * rng.uniform(0.0, 0.11)), rng.uniform(0.18, 0.42))
    elif kind == "gravel":
        mix_at(out, heel, 0, 0.55)
        mix_at(out, toe, toe_at, 0.35)
        mix_at(out, grain(85.0, 260.0, 1200.0, rng, 4.0, 24.0), 0, 0.48)
        for _ in range(rng.integers(14, 21)):
            at = int(RATE * 0.12 * (rng.random() ** 1.35))
            f_c = rng.uniform(850.0, 2300.0)
            mix_at(out, grain(rng.uniform(4.0, 9.0), f_c * 0.7, f_c * 1.4, rng, 0.4, 2.0), at, rng.uniform(0.22, 0.65))
    elif kind == "grass":
        mix_at(out, heel, 0, 0.50)
        mix_at(out, grain(140.0, 750.0, 3100.0, rng, 14.0, 42.0), int(RATE * 0.006), 0.55)
    elif kind == "sand":
        mix_at(out, heel, 0, 0.45)
        mix_at(out, grain(145.0, 700.0, 3400.0, rng, 12.0, 44.0), 0, 0.75)
        mix_at(out, grain(90.0, 220.0, 900.0, rng, 8.0, 30.0), 0, 0.45)
    elif kind == "stone":
        mix_at(out, heel, 0, 0.75)
        mix_at(out, toe, toe_at, 0.48)
        tap = modal_hit(0.05, [(rng.uniform(240.0, 340.0), 12.0, 0.55), (rng.uniform(520.0, 720.0), 6.0, 0.20)], rng, 2.5, (220.0, 1400.0))
        mix_at(out, fade(tap, 0.5, 14.0), 0, 0.55)
    elif kind == "wet":
        mix_at(out, heel, 0, 0.62)
        mix_at(out, grain(120.0, 280.0, 1600.0, rng, 8.0, 34.0), 0, 0.68)
        f0 = rng.uniform(340.0, 620.0)
        mix_at(out, tone_sweep(0.04, f0, f0 * 1.6, harm=0.0), int(RATE * 0.03), 0.18)
    elif kind == "wood":
        f1 = rng.uniform(102.0, 128.0)
        plank = modal_hit(0.16, [(f1, 36.0, 0.85), (f1 * 1.85, 22.0, 0.38), (f1 * 2.9, 11.0, 0.12)], rng, 4.0, (140.0, 900.0))
        mix_at(out, plank, 0, 0.85)
        mix_at(out, heel, 0, 0.45)
    elif kind == "snow":
        mix_at(out, heel, 0, 0.50)
        for _ in range(rng.integers(10, 16)):
            at = int(RATE * 0.11 * (rng.random() ** 1.1))
            mix_at(out, grain(rng.uniform(7.0, 16.0), 850.0, 3100.0, rng, 1.5, 5.0), at, rng.uniform(0.20, 0.52))
    else:  # water / splash
        mix_at(out, grain(210.0, 380.0, 2400.0, rng, 10.0, 58.0), 0, 0.80)
        for _ in range(4):
            f0 = rng.uniform(380.0, 820.0)
            mix_at(out, tone_sweep(rng.uniform(0.025, 0.055), f0, f0 * 1.8, harm=0.0), int(RATE * rng.uniform(0.02, 0.15)), 0.22)
    return fade(fft_bandpass(out, 45.0, 4200.0, order=2), 1.5, 45.0)


def make_cloth(rng):
    """Soft jacket / backpack fabric rustle."""
    n = int(RATE * rng.uniform(0.14, 0.20))
    x = fft_bandpass(pink(n, rng, 450.0, 2600.0), 550.0, 2100.0, order=2)
    env = np.sin(np.linspace(0.0, math.pi, n)) ** 1.6
    return fade(x * env, 4.0, 35.0)


def make_brush(rng):
    """Soft grass / foliage brushing past tires and legs."""
    n = int(RATE * rng.uniform(0.18, 0.26))
    x = fft_bandpass(pink(n, rng, 700.0, 3600.0), 850.0, 2900.0, order=2)
    env = np.sin(np.linspace(0.0, math.pi, n)) ** 1.4 * (0.7 + 0.3 * smooth_mod(n, 16.0, rng))
    return fade(x * env, 6.0, 45.0)


def make_water_entry(rng):
    """Organic water entry splash for tire or foot."""
    n = int(RATE * 0.34)
    out = grain(280.0, 320.0, 2600.0, rng, 8.0, 72.0) * 0.85
    mix_at(out, pitch_thump(0.14, 120.0, 68.0, 32.0, attack_ms=3.0, harm2=0.05), 0, 0.45)
    for _ in range(5):
        f0 = rng.uniform(360.0, 920.0)
        mix_at(out, tone_sweep(rng.uniform(0.03, 0.065), f0, f0 * rng.uniform(1.4, 2.1), harm=0.0), int(RATE * rng.uniform(0.02, 0.22)), 0.24)
    return fade(fft_bandpass(out, 60.0, 4200.0, order=2), 1.5, 70.0)


# ---------- 5. Ambience & Legacy Compatibility ----------

def make_wind(rng):
    n = RATE * 10
    gust = smooth_mod(n, 0.25, rng)
    body = biquad_bp(pink(n, rng, 120.0, 1200.0), 230.0 + 360.0 * gust, 0.9)
    low = lowpass_1pole(pink(n, rng, 50.0, 400.0), 170.0)
    return body * (0.45 + 0.55 * gust) + low * 0.55


def make_water(rng):
    n = RATE * 6
    hiss = fft_bandpass(pink(n, rng, 400.0, 2400.0), 550.0, 2000.0, order=2)
    ripple = smooth_mod(n, 8.5, rng)
    out = hiss * (0.40 + 0.60 * ripple)
    for _ in range(42):
        f0 = rng.uniform(320.0, 700.0)
        b = tone_sweep(rng.uniform(0.03, 0.07), f0, f0 * rng.uniform(1.4, 2.2), harm=0.0)
        circular_mix(out, b * rng.uniform(0.04, 0.11), rng.integers(0, n))
    return fft_bandpass(out, 180.0, 2400.0, order=2)


def make_surf(rng):
    n = RATE * 12
    noise = pink(n, rng, 60.0, 2600.0)
    period = n / 2.0
    t = (np.arange(n, dtype=np.float64) % period) / period
    env = np.where(t < 0.175, np.sin(math.pi * t / 0.35), np.exp(-(t - 0.175) * 4.0))
    env = np.maximum(0.0, env)
    hiss = lowpass_1pole(noise, 280.0 + 860.0 * env)
    rumble = fft_bandpass(brown(n, rng, 45.0, 180.0), 50.0, 140.0, order=2)
    return hiss * (0.16 + 0.84 * env) + rumble * 0.25


def make_fire(rng):
    n = RATE * 6
    out = fft_bandpass(brown(n, rng, 55.0, 260.0), 65.0, 220.0, order=2) * 0.55
    t = 0
    while t < n:
        t += int(RATE * rng.exponential(1.0 / 13.0)) + 12
        c = grain(rng.uniform(3.5, 9.5), rng.uniform(800.0, 1500.0), rng.uniform(1800.0, 3200.0), rng, 0.3, rng.uniform(1.5, 4.0))
        circular_mix(out, c * rng.exponential(0.35), t)
    return out


def make_bird(kind, rng):
    out = np.zeros(int(RATE * 2.2), dtype=np.float64)
    at = int(RATE * 0.05)
    if kind == 0:
        for _ in range(int(rng.integers(3, 5))):
            f = rng.uniform(3300.0, 3800.0)
            mix_at(out, tone_sweep(0.11, f, f * 0.72, vib=0.01, vib_hz=30.0), at)
            at += int(RATE * rng.uniform(0.17, 0.22))
    elif kind == 1:
        f = rng.uniform(2700.0, 3100.0)
        for k in range(9):
            mix_at(out, tone_sweep(0.045, f * (1.12 if k % 2 else 1.0), f * (1.05 if k % 2 else 0.95)), at, 0.8)
            at += int(RATE * 0.06)
    else:
        f = rng.uniform(2800.0, 3200.0)
        mix_at(out, tone_sweep(0.26, f, f * 1.02, vib=0.004, vib_hz=7.0), at)
        at += int(RATE * 0.34)
        mix_at(out, tone_sweep(0.30, f * 0.82, f * 0.78, vib=0.004, vib_hz=7.0), at)
    return fade(out[:at + int(RATE * 0.35)], 5.0, 60.0)


def make_pump_suspension(rng):
    n = int(RATE * 0.18)
    air = fft_bandpass(pink(n, rng, 240.0, 1200.0), 320.0, 960.0, order=2)
    env = np.sin(np.linspace(0.0, math.pi, n)) ** 1.5
    low = pitch_thump(0.18, 88.0, 62.0, 34.0, attack_ms=10.0, harm2=0.04) * 0.45
    return fade(air * env * 0.85 + low, 6.0, 36.0)


# ---------- 5b. Atmospheric Ecology & Environment (v1.1) ----------

def make_river_rapids(rng):
    n = RATE * 6
    surge = 0.55 + 0.45 * smooth_mod(n, 0.34, rng)
    body = fft_bandpass(pink(n, rng, 140.0, 1100.0), 170.0, 820.0, order=2)
    froth = fft_bandpass(pink(n, rng, 550.0, 3400.0), 650.0, 2600.0, order=2)
    ripple = smooth_mod(n, 4.2, rng)
    out = body * (0.48 + 0.52 * surge) + froth * (0.28 + 0.42 * ripple) * surge
    for _ in range(95):
        f0 = rng.uniform(360.0, 950.0)
        dur = rng.uniform(0.025, 0.065)
        b = tone_sweep(dur, f0, f0 * rng.uniform(1.3, 2.0), harm=0.0)
        circular_mix(out, b * rng.uniform(0.03, 0.085), rng.integers(0, n))
    for _ in range(60):
        c = grain(rng.uniform(10.0, 26.0), 600.0, 2200.0, rng, 2.0, rng.uniform(6.0, 14.0))
        circular_mix(out, c * rng.uniform(0.06, 0.16), rng.integers(0, n))
    return lowpass_1pole(fft_bandpass(out, 110.0, 4000.0, order=2), 3400.0)


def make_wind_forest(rng):
    n = RATE * 7
    gust_a = smooth_mod(n, 0.16, rng)
    gust_b = smooth_mod(n, 0.31, rng)
    woody = fft_bandpass(pink(n, rng, 180.0, 950.0), 220.0, 760.0, order=2)
    leaves = fft_bandpass(pink(n, rng, 850.0, 3200.0), 950.0, 2700.0, order=2)
    low = lowpass_1pole(brown(n, rng, 45.0, 320.0), 180.0)
    out = low * 0.40 + woody * (0.38 + 0.62 * gust_a) + leaves * (0.16 + 0.54 * gust_b)
    return lowpass_1pole(fft_bandpass(out, 65.0, 3200.0, order=2), 2600.0)


def make_wind_alpine(rng):
    n = RATE * 7
    gust = smooth_mod(n, 0.20, rng)
    rumble = fft_bandpass(brown(n, rng, 55.0, 340.0), 75.0, 290.0, order=2)
    air = fft_bandpass(pink(n, rng, 340.0, 1900.0), 400.0, 1550.0, order=2)
    out = rumble * (0.55 + 0.45 * gust) + air * (0.28 + 0.62 * gust) * 0.72
    return lowpass_1pole(out, 1950.0)


def make_wind_valley_mist(rng):
    n = RATE * 7
    drift = smooth_mod(n, 0.14, rng)
    cushion = fft_bandpass(brown(n, rng, 65.0, 480.0), 85.0, 420.0, order=2)
    silk = fft_bandpass(pink(n, rng, 480.0, 1750.0), 540.0, 1500.0, order=2)
    out = cushion * (0.60 + 0.40 * drift) + silk * (0.22 + 0.35 * drift) * 0.52
    return lowpass_1pole(fft_bandpass(out, 60.0, 2000.0, order=2), 1650.0)


def make_meadow_breeze(rng):
    n = RATE * 6
    sway = smooth_mod(n, 0.28, rng)
    bed = fft_bandpass(pink(n, rng, 130.0, 520.0), 150.0, 440.0, order=2)
    grass = fft_bandpass(pink(n, rng, 700.0, 2800.0), 820.0, 2400.0, order=2)
    out = bed * 0.50 + grass * (0.25 + 0.75 * sway) * 0.68
    return lowpass_1pole(out, 2500.0)


def make_night_crickets(rng):
    n = RATE * 6
    air = lowpass_1pole(brown(n, rng, 60.0, 340.0), 190.0) * 0.20
    out = air.copy()
    # Two soft distant cricket timbres around 3.0-3.55 kHz (warm, well below harsh 6+ kHz)
    voices = [
        (3080.0, 0.55, 0.11, 0.90),
        (3380.0, 0.42, 0.08, 1.35),
        (2920.0, 0.30, 0.07, 1.75),
    ]
    for f_base, amp, pulse_gap, phrase_gap in voices:
        t_s = rng.uniform(0.1, 0.6)
        while t_s < 5.3:
            pulses = int(rng.integers(3, 6))
            for k in range(pulses):
                dur = 0.024
                m = int(RATE * dur)
                tt = np.arange(m, dtype=np.float64) / RATE
                freq = f_base * (1.0 + rng.uniform(-0.008, 0.008))
                sig = np.sin(2.0 * math.pi * freq * tt) * 0.85 + np.sin(2.0 * math.pi * freq * 1.5 * tt) * 0.06
                env = np.sin(math.pi * tt / dur) ** 1.6
                circular_mix(out, sig * env * amp, int(t_s * RATE) + k * int(pulse_gap * 0.42 * RATE))
            t_s += phrase_gap * rng.uniform(0.75, 1.30)
    return lowpass_1pole(out, 4200.0)


def make_tunnel_hum(rng):
    n = RATE * 5
    hum = fft_bandpass(brown(n, rng, 52.0, 260.0), 62.0, 210.0, order=2)
    drift = 0.78 + 0.22 * smooth_mod(n, 0.22, rng)
    return lowpass_1pole(hum * drift, 320.0)


def make_bird_v11(kind, rng):
    out = np.zeros(int(RATE * 2.0), dtype=np.float64)
    at = int(RATE * 0.05)
    if kind == 4:
        # Gentle forest thrush two-note flute glide
        f = rng.uniform(1850.0, 2250.0)
        mix_at(out, tone_sweep(0.24, f, f * 1.24, harm=0.04, vib=0.006, vib_hz=9.0), at, 0.90)
        at += int(RATE * 0.34)
        mix_at(out, tone_sweep(0.28, f * 1.18, f * 0.94, harm=0.04, vib=0.007, vib_hz=8.0), at, 0.80)
        at += int(RATE * 0.32)
    elif kind == 5:
        # Distant forest woodpecker soft woody taps
        taps = int(rng.integers(5, 8))
        base_f = rng.uniform(980.0, 1320.0)
        for _ in range(taps):
            hit = modal_hit(0.055, [(base_f, 1.0, 11.0), (base_f * 1.48, 0.42, 7.5)], rng, exc_ms=1.8, exc_bw=(450.0, 1800.0))
            mix_at(out, lowpass_1pole(hit, 2600.0), at, rng.uniform(0.55, 0.90))
            at += int(RATE * rng.uniform(0.048, 0.062))
        at += int(RATE * 0.25)
    else:
        # Calm woodland cuckoo / dove two-tone call
        f = rng.uniform(520.0, 610.0)
        mix_at(out, tone_sweep(0.22, f * 0.97, f, harm=0.03), at, 0.95)
        at += int(RATE * 0.34)
        mix_at(out, tone_sweep(0.29, f * 0.78, f * 0.76, harm=0.03), at, 0.85)
        at += int(RATE * 0.35)
    return fade(out[:max(at + int(RATE * 0.2), 4000)], 6.0, 65.0)


def make_owl(kind, rng):
    out = np.zeros(int(RATE * 2.1), dtype=np.float64)
    at = int(RATE * 0.08)
    f = rng.uniform(350.0, 415.0) if kind == 0 else rng.uniform(325.0, 380.0)
    mix_at(out, tone_sweep(0.32, f * 0.96, f, harm=0.03, vib=0.004, vib_hz=5.5), at, 0.82)
    at += int(RATE * 0.56)
    mix_at(out, tone_sweep(0.14, f * 0.99, f * 1.02, harm=0.02), at, 0.58)
    at += int(RATE * 0.24)
    mix_at(out, tone_sweep(0.46, f * 0.95, f * 0.87, harm=0.03, vib=0.005, vib_hz=5.0), at, 0.95)
    at += int(RATE * 0.54)
    return fade(out[:at], 15.0, 95.0)


def make_canopy_gust(rng):
    dur = 3.2
    n = int(RATE * dur)
    t = np.linspace(0.0, 1.0, n)
    swell = (np.sin(math.pi * t) ** 1.7) * (0.65 + 0.35 * smooth_mod(n, 0.9, rng))
    body = fft_bandpass(pink(n, rng, 200.0, 900.0), 240.0, 780.0, order=2)
    leaf = fft_bandpass(pink(n, rng, 900.0, 2900.0), 1000.0, 2500.0, order=2)
    return fade(lowpass_1pole((body * 0.65 + leaf * 0.55) * swell, 2700.0), 40.0, 180.0)


# ---------- 6. UI & Event Sounds (Warm 44.1 kHz Polish) ----------

def make_ui_hover(rng):
    n = int(RATE * 0.022)
    out = np.zeros(n, dtype=np.float64)
    mix_at(out, grain(18.0, 550.0, 1400.0, rng, 1.5, 5.0), 0, 0.35)
    mix_at(out, tone_sweep(0.018, 740.0, 660.0, harm=0.04), 0, 0.45)
    return fade(out, 2.0, 10.0)


def make_ui_click(rng):
    n = int(RATE * 0.042)
    out = np.zeros(n, dtype=np.float64)
    mix_at(out, grain(20.0, 900.0, 2100.0, rng, 0.8, 6.0), 0, 0.45)
    mix_at(out, pitch_thump(0.036, 480.0, 310.0, 10.0, attack_ms=1.0, harm2=0.05), 0, 0.85)
    return fade(out, 1.0, 16.0)


def make_ui_carousel_step(rng):
    n = int(RATE * 0.046)
    out = np.zeros(n, dtype=np.float64)
    mix_at(out, grain(22.0, 1100.0, 2500.0, rng, 0.6, 5.5), 0, 0.55)
    mix_at(out, tone_sweep(0.032, 900.0, 640.0, harm=0.05), 0, 0.75)
    return fade(out, 1.0, 18.0)


def make_ui_panel_open(rng):
    n = int(RATE * 0.13)
    noise = pink(n, rng, 180.0, 2400.0)
    freq = np.linspace(420.0, 900.0, n)
    swell = biquad_bp(noise, freq, 1.3) * np.sin(np.linspace(0.0, math.pi, n)) * 0.55
    mix_at(swell, tone_sweep(0.11, 310.0, 420.0, harm=0.05), int(RATE * 0.01), 0.55)
    return fade(swell, 8.0, 45.0)


def make_ui_panel_close(rng):
    n = int(RATE * 0.10)
    noise = pink(n, rng, 180.0, 2400.0)
    freq = np.linspace(750.0, 360.0, n)
    swell = biquad_bp(noise, freq, 1.3) * np.sin(np.linspace(0.0, math.pi, n)) * 0.50
    mix_at(swell, tone_sweep(0.085, 360.0, 260.0, harm=0.04), int(RATE * 0.005), 0.50)
    return fade(swell, 5.0, 40.0)


def make_ui_confirm(rng):
    n = int(RATE * 0.16)
    out = np.zeros(n, dtype=np.float64)
    mix_at(out, grain(20.0, 750.0, 1800.0, rng, 1.0, 6.0), 0, 0.25)
    mix_at(out, tone_sweep(0.085, 440.0, 445.0, harm=0.06), 0, 0.65)
    mix_at(out, tone_sweep(0.115, 660.0, 665.0, harm=0.06), int(RATE * 0.04), 0.75)
    return fade(out, 2.0, 55.0)


def make_ui_error_deny(rng):
    n = int(RATE * 0.12)
    out = np.zeros(n, dtype=np.float64)
    mix_at(out, pitch_thump(0.048, 210.0, 165.0, 16.0, attack_ms=1.5, harm2=0.06), 0, 0.90)
    mix_at(out, grain(18.0, 320.0, 820.0, rng, 1.0, 6.0), 0, 0.25)
    mix_at(out, pitch_thump(0.054, 165.0, 130.0, 18.0, attack_ms=1.5, harm2=0.06), int(RATE * 0.048), 0.85)
    return fade(out, 2.0, 35.0)


def make_ui_volume_tick():
    return fade(tone_sweep(0.075, 440.0, 440.0, harm=0.06), 4.0, 24.0)


def make_lamp_switch(rng):
    n = int(RATE * 0.06)
    out = np.zeros(n, dtype=np.float64)
    mix_at(out, grain(10.0, 1800.0, 3800.0, rng, 0.3, 2.5), 0, 0.8)
    mix_at(out, grain(12.0, 1400.0, 3000.0, rng, 0.3, 3.0), int(RATE * 0.018), 0.6)
    return fade(out, 0.5, 15.0)


def ring_tone(seconds, f, decay_ms, attack_ms=5.0, partials=((1.0, 1.0),)):
    n = int(RATE * seconds)
    t = np.arange(n, dtype=np.float64) / RATE
    a = max(1e-4, attack_ms / 1000.0)
    env = np.where(t < a, np.sin(0.5 * math.pi * t / a) ** 2, 1.0) * np.exp(-t * 1000.0 / decay_ms)
    sig = sum(g * np.sin(TAU * f * m * t) for m, g in partials)
    return env * sig


PLUCK = ((1.0, 1.0), (2.0, 0.16), (3.0, 0.04))


def make_discovery_chime():
    n = int(RATE * 1.4)
    out = np.zeros(n, dtype=np.float64)
    mix_at(out, ring_tone(1.0, 523.25, 380.0, 6.0, PLUCK), 0, 0.60)
    mix_at(out, ring_tone(1.25, 698.46, 520.0, 6.0, PLUCK), int(RATE * 0.14), 0.55)
    return fade(out, 2.0, 250.0)


def make_quest_complete():
    n = int(RATE * 1.8)
    out = np.zeros(n, dtype=np.float64)
    for k, f in enumerate((392.0, 493.88, 587.33)):
        mix_at(out, ring_tone(1.5 - k * 0.15, f, 600.0 - k * 60.0, 8.0, PLUCK), int(RATE * 0.12 * k), 0.50)
    mix_at(out, ring_tone(1.4, 196.0, 700.0, 20.0, ((1.0, 1.0), (2.0, 0.10))), 0, 0.25)
    return fade(out, 2.0, 350.0)


def make_glass_clink(rng):
    n = int(RATE * 0.45)
    out = np.zeros(n, dtype=np.float64)
    at = 0
    for k, (f, g) in enumerate(((2450.0, 0.8), (2940.0, 0.55), (2220.0, 0.35))):
        mix_at(out, ring_tone(0.3, f, 70.0 - k * 12.0, 0.5, ((1.0, 0.7), (2.76, 0.22))), at, g)
        mix_at(out, grain(8.0, f * 0.9, f * 1.5, rng, 0.2, 2.0), at, g * 0.35)
        at += int(RATE * rng.uniform(0.045, 0.085))
    return fade(fft_bandpass(out, 180.0, 4800.0, order=2), 0.5, 80.0)


def main():
    os.makedirs(ROOT, exist_ok=True)
    rng = np.random.default_rng(27042)

    # Core bike & ambience loops (exact legacy paths preserved + upgraded to 44.1 kHz)
    write_wav("wind.wav", make_wind(rng), looped=True, target_rms=0.14)
    write_wav("water.wav", make_water(rng), looped=True, target_rms=0.14)
    write_wav("surf.wav", make_surf(rng), looped=True, target_rms=0.14)
    write_wav("fire.wav", make_fire(rng), looped=True, target_rms=0.14)
    write_wav("roll.wav", make_roll(rng), looped=True, target_rms=0.18)
    write_wav("grit.wav", make_tex_gravel(rng), looped=True, target_rms=0.16)
    write_wav("freewheel.wav", make_freewheel(rng), looped=True, peak=0.55)
    write_wav("chain.wav", make_chain(rng), looped=True, target_rms=0.14)

    # Bike specialized loops & foley
    write_wav("bike/tire_rush.wav", make_tire_rush(rng), looped=True, target_rms=0.14)
    write_wav("bike/brake_pad.wav", make_brake_pad(rng), looped=True, target_rms=0.14)
    write_wav("bike/skid_loose.wav", make_skid_loose(rng), looped=True, target_rms=0.17)
    write_wav("bike/skid_firm.wav", make_skid_firm(rng), looped=True, target_rms=0.16)
    write_wav("bike/air_wind.wav", make_air_wind(rng), looped=True, target_rms=0.15)

    for k in range(2):
        write_wav(f"bike/hop_prep_{k + 1}.wav", make_hop_prep(rng), peak=0.55)
        write_wav(f"bike/takeoff_crest_{k + 1}.wav", make_takeoff(False, rng), peak=0.58)
        write_wav(f"bike/bike_mount_{k + 1}.wav", make_bike_mount(rng), peak=0.58)
        write_wav(f"bike/bike_dismount_{k + 1}.wav", make_bike_dismount(rng), peak=0.58)
        write_wav(f"bike/stop_foot_{k + 1}.wav", make_stop_foot(rng), peak=0.55)
    for k in range(3):
        write_wav(f"bike/takeoff_hop_{k + 1}.wav", make_takeoff(True, rng), peak=0.62)
        write_wav(f"bike/gear_shift_{k + 1}.wav", make_gear_shift(rng), peak=0.55)
    for k in range(4):
        write_wav(f"bike/susp_stroke_{k + 1}.wav", make_susp_stroke(rng), peak=0.50)

    # 11 surface texture loops
    tex_makers = {
        "packed": make_tex_packed,
        "dirt": make_tex_dirt,
        "forest": make_tex_forest,
        "gravel": make_tex_gravel,
        "grass": make_tex_grass,
        "sand": make_tex_sand,
        "stone": make_tex_stone,
        "wet": make_tex_wet,
        "wood": make_tex_wood,
        "snow": make_tex_snow,
        "water": make_tex_water,
    }
    for surf_name, fn in tex_makers.items():
        write_wav(f"surfaces/tex_{surf_name}.wav", fn(rng), looped=True, target_rms=0.16)
    for k in range(4):
        write_wav(f"surfaces/plank_{k + 1}.wav", make_plank(rng), peak=0.62)
    for kind in ("forest", "gravel", "stone", "wet"):
        for k in range(4):
            write_wav(f"surfaces/grain_{kind}_{k + 1}.wav", make_surface_grain(kind, rng), peak=0.55)

    # Impacts & landings
    for k in range(3):
        write_wav(f"impacts/land_soft_{k + 1}.wav", make_landing("soft", rng), peak=0.62)
        write_wav(f"impacts/land_med_{k + 1}.wav", make_landing("med", rng), peak=0.65)
        write_wav(f"impacts/land_hard_{k + 1}.wav", make_landing("hard", rng), peak=0.68)
        write_wav(f"impacts/rim_knock_{k + 1}.wav", make_rim_knock(rng), peak=0.62)
        write_wav(f"impacts/fork_bottom_{k + 1}.wav", make_fork_bottom(rng), peak=0.64)
    for k in range(4):
        write_wav(f"impacts/bump_hit_{k + 1}.wav", make_bump_hit(rng), peak=0.60)
    for k in range(2):
        write_wav(f"impacts/crash_{k + 1}.wav", make_crash_impact(rng), peak=0.66)

    # Footsteps across all 11 surfaces + cloth, brush, water entry
    for surf_name in tex_makers.keys():
        for k in range(4):
            write_wav(f"foley/steps/step_{surf_name}_{k + 1}.wav", make_step(surf_name, rng), peak=0.60)
    for k in range(4):
        write_wav(f"foley/cloth_{k + 1}.wav", make_cloth(rng), peak=0.52)
        write_wav(f"foley/brush_{k + 1}.wav", make_brush(rng), peak=0.52)
    for k in range(3):
        write_wav(f"foley/water_entry_{k + 1}.wav", make_water_entry(rng), peak=0.62)

    # Birds, nocturnal owls, atmospheric & environmental v1.1 layers
    for k in range(3):
        write_wav(f"bird_{k + 1}.wav", make_bird(k, rng), peak=0.55)
        write_wav(f"ambience/bird_{k + 4}.wav", make_bird_v11(k + 4, rng), peak=0.55)
        write_wav(f"ambience/gust_trees_{k + 1}.wav", make_canopy_gust(rng), peak=0.52)
    for k in range(2):
        write_wav(f"ambience/owl_{k + 1}.wav", make_owl(k, rng), peak=0.52)
    write_wav("ambience/river_rapids.wav", make_river_rapids(rng), looped=True, target_rms=0.15)
    write_wav("ambience/wind_forest.wav", make_wind_forest(rng), looped=True, target_rms=0.13)
    write_wav("ambience/wind_alpine.wav", make_wind_alpine(rng), looped=True, target_rms=0.13)
    write_wav("ambience/wind_valley_mist.wav", make_wind_valley_mist(rng), looped=True, target_rms=0.13)
    write_wav("ambience/meadow_breeze.wav", make_meadow_breeze(rng), looped=True, target_rms=0.13)
    write_wav("ambience/night_crickets.wav", make_night_crickets(rng), looped=True, target_rms=0.10)
    write_wav("ambience/tunnel_hum.wav", make_tunnel_hum(rng), looped=True, target_rms=0.09)
    for k in range(4):
        write_wav(f"step_soft_{k + 1}.wav", make_step("soft", rng), peak=0.58)
        write_wav(f"step_gravel_{k + 1}.wav", make_step("gravel", rng), peak=0.58)
    for k in range(3):
        write_wav(f"step_wood_{k + 1}.wav", make_step("wood", rng), peak=0.58)
        write_wav(f"step_splash_{k + 1}.wav", make_step("water", rng), peak=0.58)

    write_wav("land.wav", make_landing("med", rng), peak=0.65)
    write_wav("fork_bottom.wav", make_fork_bottom(rng), peak=0.64)
    write_wav("rim_knock.wav", make_rim_knock(rng), peak=0.62)
    write_wav("crash_impact.wav", make_crash_impact(rng), peak=0.66)
    write_wav("pump_suspension.wav", make_pump_suspension(rng), peak=0.56)

    # UI & event feedback
    ui_rng = np.random.default_rng(2026)
    write_wav("ui_hover.wav", make_ui_hover(ui_rng), peak=0.50)
    write_wav("ui_click.wav", make_ui_click(ui_rng), peak=0.55)
    write_wav("ui_carousel_step.wav", make_ui_carousel_step(ui_rng), peak=0.55)
    write_wav("ui_panel_open.wav", make_ui_panel_open(ui_rng), peak=0.55)
    write_wav("ui_panel_close.wav", make_ui_panel_close(ui_rng), peak=0.55)
    write_wav("ui_confirm.wav", make_ui_confirm(ui_rng), peak=0.58)
    write_wav("ui_error_deny.wav", make_ui_error_deny(ui_rng), peak=0.58)
    write_wav("ui_volume_tick.wav", make_ui_volume_tick(), peak=0.55)
    write_wav("lamp_switch.wav", make_lamp_switch(ui_rng), peak=0.55)
    write_wav("discovery_chime.wav", make_discovery_chime(), peak=0.55)
    write_wav("quest_complete.wav", make_quest_complete(), peak=0.55)
    write_wav("glass_clink.wav", make_glass_clink(ui_rng), peak=0.55)
    print("Generated all Organic Tactile Audio WAV assets at 44100 Hz.")


if __name__ == "__main__":
    main()
