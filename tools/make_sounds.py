"""Звуки игры (с 2.7): синтез из шума и синусов, без чужих записей.

Запуск из папки проекта:  python tools/make_sounds.py
Пишет resources/sounds/*.wav (22050 Гц, моно, 16 бит). Петли (ветер, вода, прибой, костёр, шины, покрытие, трещотка, цепь)
сшиты плавным переходом конца в начало и помечены точками петли (блок smpl), поэтому Godot
повторяет их сам. Случайность с постоянным зерном: повторный запуск даёт те же файлы.
Громкость каждого звука в игре задаёт scripts/render/world_audio.gd, здесь все нормированы одинаково.
"""

import math
import os
import random
import struct

RATE = 22050
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "resources", "sounds")
TAU = 2.0 * math.pi


# ---------- фильтры и шумы ----------

def white(n, rng):
    return [rng.uniform(-1.0, 1.0) for _ in range(n)]


def pink(n, rng):
    """Розовый шум (фильтр Пола Келлета): мягче белого, как ветер и вода"""
    b0 = b1 = b2 = b3 = b4 = b5 = b6 = 0.0
    out = []
    for _ in range(n):
        w = rng.uniform(-1.0, 1.0)
        b0 = 0.99886 * b0 + w * 0.0555179
        b1 = 0.99332 * b1 + w * 0.0750759
        b2 = 0.96900 * b2 + w * 0.1538520
        b3 = 0.86650 * b3 + w * 0.3104856
        b4 = 0.55000 * b4 + w * 0.5329522
        b5 = -0.7616 * b5 - w * 0.0168980
        out.append((b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362) * 0.11)
        b6 = w * 0.115926
    return out


def lowpass(x, cutoff):
    """Однополюсный фильтр нижних частот; cutoff — число или список частот на каждый отсчёт"""
    out = []
    y = 0.0
    for i, v in enumerate(x):
        c = cutoff[i] if isinstance(cutoff, list) else cutoff
        a = 1.0 - math.exp(-TAU * c / RATE)
        y += a * (v - y)
        out.append(y)
    return out


def bandpass(x, freq, q):
    """Полосовой биквад (RBJ); freq — число или список частот на каждый отсчёт"""
    out = []
    x1 = x2 = y1 = y2 = 0.0
    for i, v in enumerate(x):
        f = freq[i] if isinstance(freq, list) else freq
        if i == 0 or isinstance(freq, list):
            w0 = TAU * f / RATE
            al = math.sin(w0) / (2.0 * q)
            a0 = 1.0 + al
            b0 = al / a0
            b2 = -al / a0
            a1 = -2.0 * math.cos(w0) / a0
            a2 = (1.0 - al) / a0
        y = b0 * v + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1 = x1, v
        y2, y1 = y1, y
        out.append(y)
    return out


def smooth_noise(n, rate_hz, rng):
    """Медленно меняющийся случайный множитель 0..1 (белый шум через два фильтра, нормирован)"""
    x = lowpass(lowpass(white(n, rng), rate_hz), rate_hz)
    lo, hi = min(x), max(x)
    return [(v - lo) / (hi - lo + 1e-9) for v in x]


def normalize(x, peak=0.5):
    m = max(abs(v) for v in x) or 1.0
    return [v * peak / m for v in x]


def mix(dst, src, at=0, gain=1.0):
    for i, v in enumerate(src):
        j = at + i
        if 0 <= j < len(dst):
            dst[j] += v * gain


def fade(x, ms_in, ms_out):
    """Мягкое начало и конец одиночного звука, чтобы не щёлкало"""
    n_in = int(RATE * ms_in / 1000)
    n_out = int(RATE * ms_out / 1000)
    for i in range(min(n_in, len(x))):
        x[i] *= math.sin(0.5 * math.pi * i / n_in) ** 2
    for i in range(min(n_out, len(x))):
        x[-1 - i] *= math.sin(0.5 * math.pi * i / n_out) ** 2
    return x


def loop(make, seconds, cross=0.6):
    """Петля: make(n) даёт n отсчётов, хвост длиной cross секунд плавно переходит в начало"""
    n = int(RATE * seconds)
    f = int(RATE * cross)
    x = make(n + f)
    out = x[:n]
    for i in range(f):
        t = i / f
        out[i] = x[i] * math.sin(0.5 * math.pi * t) + x[n + i] * math.cos(0.5 * math.pi * t)
    return out


def tone(seconds, f0, f1, harm=0.08, vib=0.0, vib_hz=0.0):
    """Синус с плавным скольжением частоты f0 -> f1 и огибающей Ханна (голос птицы, бульк)"""
    n = int(RATE * seconds)
    out = []
    ph = 0.0
    for i in range(n):
        t = i / max(1, n - 1)
        f = f0 + (f1 - f0) * (0.5 - 0.5 * math.cos(math.pi * t))
        f *= 1.0 + vib * math.sin(TAU * vib_hz * i / RATE)
        ph += TAU * f / RATE
        env = math.sin(math.pi * t) ** 2
        out.append(env * (math.sin(ph) + harm * math.sin(2.0 * ph)))
    return out


def burst(ms, decay_ms, rng, attack_ms=2.0):
    """Короткий шумовой удар: быстрый подъём и спад"""
    n = int(RATE * ms / 1000)
    a = max(1, int(RATE * attack_ms / 1000))
    out = []
    for i in range(n):
        env = (i / a if i < a else 1.0) * math.exp(-(i / RATE) * 1000.0 / decay_ms)
        out.append(rng.uniform(-1.0, 1.0) * env)
    return out


def thump(ms, f0, f1, decay_ms):
    """Глухой удар: низкий синус, частота опускается f0 -> f1"""
    n = int(RATE * ms / 1000)
    out = []
    ph = 0.0
    for i in range(n):
        t = i / n
        f = f0 + (f1 - f0) * t
        ph += TAU * f / RATE
        env = min(1.0, i / (RATE * 0.003)) * math.exp(-(i / RATE) * 1000.0 / decay_ms)
        out.append(math.sin(ph) * env)
    return out


# ---------- звуки ----------

def wind(n, rng):
    """Ветер: розовый шум в полосе 250–700 Гц, порывы — медленные волны громкости и высоты"""
    base = pink(n, rng)
    gust = smooth_noise(n, 0.25, rng)
    freq = [260.0 + 420.0 * g for g in gust]
    body = bandpass(base, freq, 0.9)
    low = lowpass(pink(n, rng), 180.0)
    return [b * (0.45 + 0.55 * g) + l * 0.6 for b, l, g in zip(body, low, gust)]


def water(n, rng):
    """Ручей: журчание в полосе около 1,2 кГц с быстрой рябью громкости и тихими бульками"""
    hiss = bandpass(pink(n, rng), 1200.0, 0.6)
    ripple = smooth_noise(n, 9.0, rng)
    out = [h * (0.35 + 0.65 * r) for h, r in zip(hiss, ripple)]
    for _ in range(int(n / RATE * 7)):
        f0 = rng.uniform(320.0, 700.0)
        b = tone(rng.uniform(0.03, 0.07), f0, f0 * rng.uniform(1.4, 2.2), harm=0.0)
        mix(out, b, rng.randrange(n), rng.uniform(0.04, 0.12))
    return lowpass(out, 2200.0)


def surf(n, rng):
    """Прибой: волна набегает за пару секунд и долго шуршит, отходя; две волны за петлю"""
    noise = pink(n, rng)
    period = n / 2.0
    env = []
    for i in range(n):
        t = (i % period) / period
        e = math.sin(math.pi * t / 0.35) if t < 0.35 * 0.5 else math.exp(-(t - 0.175) * 4.0)
        env.append(max(0.0, e))
    hiss = lowpass(noise, [300.0 + 900.0 * e for e in env])
    rumble = lowpass(pink(n, rng), 120.0)
    return [h * (0.15 + 0.85 * e) + r * 0.15 for h, r, e in zip(hiss, rumble, env)]


def fire(n, rng):
    """Костёр: тихий низкий гул и редкие мягкие потрескивания"""
    out = [v * 0.5 for v in lowpass(pink(n, rng), 220.0)]
    t = 0
    while t < n:
        t += int(RATE * rng.expovariate(14.0))
        c = bandpass(burst(rng.uniform(3, 9), rng.uniform(1.5, 4.0), rng, 0.3), rng.uniform(900, 2600), 1.2)
        mix(out, c, t, rng.expovariate(1.0) * 0.5)
    return out


def roll(n, rng):
    """Шины по грунту: мягкий низкий шорох. С 10.3 без частой волны громкости (она «ухала» 4 раза в
    секунду), только медленное неровное дыхание; высоту и громкость в игре задаёт скорость"""
    body = lowpass(pink(n, rng), 380.0)
    # Убираем постоянный басовый гул, который воспринимался как ветер в микрофоне.
    sub = lowpass(body, 100.0)
    body = [b - s for b, s in zip(body, sub)]
    hum = bandpass(pink(n, rng), 140.0, 1.2)
    breath = smooth_noise(n, 0.3, rng)
    return [(b + h * 0.15) * (0.85 + 0.15 * w) for b, h, w in zip(body, hum, breath)]


def grit(n, rng):
    """Покрытие под шиной (10.3): россыпь мелких мягких песчинок на тихой подложке. Плотность
    случайная, без ритма, поэтому не звучит как очередь щелчков"""
    out = [v * 0.25 for v in lowpass(pink(n, rng), 700.0)]
    t = 0
    while t < n:
        t += int(RATE * rng.expovariate(90.0)) + 1
        g = bandpass(burst(rng.uniform(1.5, 3.5), rng.uniform(0.5, 1.2), rng, 0.3), rng.uniform(1300, 2800), 1.3)
        mix(out, g, t, rng.expovariate(1.0) * 0.35)
    return lowpass(out, 3500.0)


def freewheel(rng, seconds=2.0, rate=20):
    """Трещотка втулки накатом (10.3): ровные тихие щелчки собачек, rate в секунду. В игре высота
    (а с ней и частота щелчков) идёт за скоростью колеса. Целое число щелчков — петля без шва"""
    n = int(RATE * seconds)
    out = [0.0] * n
    step = n / int(seconds * rate)
    for k in range(int(seconds * rate)):
        at = int(k * step + rng.uniform(-0.0004, 0.0004) * RATE) % n
        g = rng.uniform(0.85, 1.0)
        mix(out, bandpass(burst(4, 0.7, rng, 0.15), 3000.0, 2.5), at, g)
        mix(out, tone(0.008, 5200.0, 5100.0, harm=0.0), at, g * 0.12)
    return out


def chain(n, rng):
    """Цепь под нагрузкой (10.3): мягкое жужжание звёздочек и едва слышный стрекот звеньев"""
    out = [v * 0.7 for v in bandpass(pink(n, rng), 650.0, 1.8)]
    mix(out, [v * 0.5 for v in lowpass(pink(n, rng), 160.0)])
    t = 0
    while t < n:
        t += int(RATE / 55.0 * rng.uniform(0.9, 1.1))
        mix(out, bandpass(burst(3, 0.6, rng, 0.2), 2200.0, 2.0), t, rng.uniform(0.08, 0.15))
    return out


def bird(kind, rng):
    """Голоса птиц: короткие свисты с плавным скольжением частоты, без резких призвуков"""
    out = [0.0] * int(RATE * 2.2)
    at = int(RATE * 0.05)
    if kind == 0:     # «тиу-тиу-тиу»: три-четыре нисходящих свиста
        for _ in range(rng.randint(3, 4)):
            f = rng.uniform(3600, 4000)
            mix(out, tone(0.11, f, f * 0.7, vib=0.01, vib_hz=30), at)
            at += int(RATE * rng.uniform(0.17, 0.22))
    elif kind == 1:   # короткая трель
        f = rng.uniform(2900, 3200)
        for k in range(9):
            mix(out, tone(0.045, f * (1.12 if k % 2 else 1.0), f * (1.05 if k % 2 else 0.95)), at, 0.8)
            at += int(RATE * 0.06)
    else:             # «фи-бю»: два долгих мягких свиста, как у синицы
        f = rng.uniform(3000, 3300)
        mix(out, tone(0.26, f, f * 1.02, vib=0.004, vib_hz=7), at)
        at += int(RATE * 0.34)
        mix(out, tone(0.3, f * 0.82, f * 0.78, vib=0.004, vib_hz=7), at)
    return fade(out[:at + int(RATE * 0.35)], 5, 60)


def step(kind, rng):
    """Шаг: мягкий (трава, земля), хрусткий (гравий, камень, песок), по доскам, по воде"""
    n = int(RATE * 0.32)
    out = [0.0] * n
    if kind == "soft":
        mix(out, lowpass(burst(110, 32, rng, 6), 900.0), 0, 1.0)
        mix(out, bandpass(burst(150, 45, rng, 15), rng.uniform(2400, 3400), 0.8), int(RATE * 0.01), 0.35)
        mix(out, thump(60, 90, 60, 18), 0, 0.5)
    elif kind == "gravel":
        for _ in range(rng.randint(18, 26)):   # с 10.3 реже и ниже: меньше колючего «треска»
            g = bandpass(burst(rng.uniform(1.5, 4), rng.uniform(0.6, 1.5), rng, 0.2), rng.uniform(1200, 3000), 1.5)
            mix(out, g, int(RATE * 0.11 * rng.random() ** 1.6), rng.uniform(0.3, 1.0))
        mix(out, lowpass(burst(70, 20, rng, 4), 600.0), 0, 0.6)
        mix(out, thump(50, 95, 65, 14), 0, 0.4)
    elif kind == "wood":
        for f, d, g in ((rng.uniform(150, 175), 70, 1.0), (rng.uniform(290, 320), 45, 0.5), (rng.uniform(520, 580), 25, 0.25)):
            mix(out, thump(160, f, f * 0.97, d), 0, g)
        mix(out, lowpass(burst(30, 6, rng, 1), 1500.0), 0, 0.5)
    else:             # вода
        mix(out, bandpass(burst(300, 70, rng, 12), rng.uniform(1100, 1600), 0.7), 0, 1.0)
        for _ in range(4):
            f0 = rng.uniform(400, 800)
            mix(out, tone(rng.uniform(0.03, 0.06), f0, f0 * 1.8, harm=0.0), int(RATE * rng.uniform(0.03, 0.2)), 0.25)
    return fade(out, 1, 60)


def land(rng):
    """Приземление: глухой мягкий удар с шорохом"""
    n = int(RATE * 0.4)
    out = [0.0] * n
    mix(out, thump(300, 70, 42, 70), 0, 1.0)
    mix(out, lowpass(burst(200, 45, rng, 5), 700.0), 0, 0.7)
    return fade(out, 1, 80)


# ---------- запись WAV ----------

def write_wav(name, x, looped=False):
    x = normalize(x)
    data = b"".join(struct.pack("<h", int(max(-1.0, min(1.0, v)) * 32767)) for v in x)
    fmt = struct.pack("<HHIIHH", 1, 1, RATE, RATE * 2, 2, 16)
    chunks = b"fmt " + struct.pack("<I", len(fmt)) + fmt
    chunks += b"data" + struct.pack("<I", len(data)) + data
    if looped:
        # блок smpl: одна петля вперёд на весь звук, Godot читает её при импорте
        smpl = struct.pack("<9I", 0, 0, int(1e9 / RATE), 60, 0, 0, 0, 1, 0)
        smpl += struct.pack("<6I", 0, 0, 0, len(x) - 1, 0, 0)
        chunks += b"smpl" + struct.pack("<I", len(smpl)) + smpl
    with open(os.path.join(OUT, name + ".wav"), "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 4 + len(chunks)) + b"WAVE" + chunks)


def main():
    os.makedirs(OUT, exist_ok=True)
    rng = random.Random(27)
    write_wav("wind", loop(lambda n: wind(n, rng), 10.0, 1.5), True)
    write_wav("water", loop(lambda n: water(n, rng), 6.0, 0.8), True)
    write_wav("surf", loop(lambda n: surf(n, rng), 12.0, 1.0), True)
    write_wav("fire", loop(lambda n: fire(n, rng), 6.0, 0.6), True)
    write_wav("roll", loop(lambda n: roll(n, rng), 8.0, 0.8), True)
    write_wav("grit", loop(lambda n: grit(n, rng), 5.0, 0.4), True)
    write_wav("freewheel", freewheel(rng), True)
    write_wav("chain", loop(lambda n: chain(n, rng), 4.0, 0.4), True)
    for k in range(3):
        write_wav("bird_%d" % (k + 1), bird(k, rng))
    for kind, count in (("soft", 4), ("gravel", 4), ("wood", 3), ("splash", 3)):
        for k in range(count):
            write_wav("step_%s_%d" % (kind, k + 1), step(kind, rng))
    write_wav("land", land(rng))

    # Звуки UI (используют отдельный генератор, чтобы не менять ни байта в звуках мира)
    ui_rng = random.Random(2026)
    write_wav("ui_hover", ui_hover(ui_rng))
    write_wav("ui_click", ui_click(ui_rng))
    write_wav("ui_carousel_step", ui_carousel_step(ui_rng))
    write_wav("ui_panel_open", ui_panel_open(ui_rng))
    write_wav("ui_panel_close", ui_panel_close(ui_rng))
    write_wav("ui_confirm", ui_confirm(ui_rng))
    write_wav("ui_error_deny", ui_error_deny(ui_rng))
    write_wav("ui_volume_tick", ui_volume_tick(ui_rng))

    # 20.11: удары велосипеда и тихие отклики событий (свой генератор: прежние файлы не меняются ни на байт)
    hit_rng = random.Random(2011)
    write_wav("fork_bottom", fork_bottom(hit_rng))
    write_wav("rim_knock", rim_knock(hit_rng))
    write_wav("crash_impact", crash_impact(hit_rng))
    write_wav("lamp_switch", lamp_switch(hit_rng))
    write_wav("discovery_chime", discovery_chime(hit_rng))
    write_wav("quest_complete", quest_complete(hit_rng))
    write_wav("glass_clink", glass_clink(random.Random(2012)))  # 20.11: хрупкий груз звякнул
    write_wav("pump_suspension", pump_suspension(random.Random(2027)))


def ui_hover(rng):
    """Тихий деревянный отклик при наведении или смене фокуса"""
    n = int(RATE * 0.022)
    out = [0.0] * n
    mix(out, bandpass(burst(18, 5.0, rng, 1.5), 950.0, 1.4), 0, 0.35)
    mix(out, tone(0.018, 760.0, 680.0, harm=0.05), 0, 0.45)
    return fade(out, 2, 10)


def ui_click(rng):
    """Мягкий тактильный щелчок нажатия кнопки"""
    n = int(RATE * 0.042)
    out = [0.0] * n
    mix(out, bandpass(burst(22, 6.0, rng, 0.8), 1450.0, 1.5), 0, 0.45)
    mix(out, thump(36, 520.0, 340.0, 10.0), 0, 0.85)
    return fade(out, 1, 16)


def ui_carousel_step(rng):
    """Чёткий короткий щелчок переключения карточки карусели или вкладки"""
    n = int(RATE * 0.046)
    out = [0.0] * n
    mix(out, bandpass(burst(24, 5.5, rng, 0.6), 1850.0, 1.8), 0, 0.55)
    mix(out, tone(0.032, 940.0, 660.0, harm=0.06), 0, 0.75)
    return fade(out, 1, 18)


def ui_panel_open(rng):
    """Мягкое раскрытие панели (лёгкий вздох вверх + тёплый тон)"""
    n = int(RATE * 0.13)
    noise = pink(n, rng)
    freq = [420.0 + 480.0 * (i / max(1, n - 1)) for i in range(n)]
    swell = bandpass(noise, freq, 1.3)
    out = [swell[i] * math.sin(math.pi * i / max(1, n - 1)) * 0.55 for i in range(n)]
    mix(out, tone(0.11, 310.0, 420.0, harm=0.06), int(RATE * 0.01), 0.55)
    return fade(out, 8, 45)


def ui_panel_close(rng):
    """Мягкое закрытие панели (спад вниз)"""
    n = int(RATE * 0.10)
    noise = pink(n, rng)
    freq = [750.0 - 390.0 * (i / max(1, n - 1)) for i in range(n)]
    swell = bandpass(noise, freq, 1.3)
    out = [swell[i] * math.sin(math.pi * i / max(1, n - 1)) * 0.5 for i in range(n)]
    mix(out, tone(0.085, 360.0, 260.0, harm=0.05), int(RATE * 0.005), 0.5)
    return fade(out, 5, 40)


def ui_confirm(rng):
    """Тёплый двухнотный отклик подтверждения запуска мира"""
    n = int(RATE * 0.16)
    out = [0.0] * n
    mix(out, bandpass(burst(20, 6.0, rng, 1.0), 1200.0, 1.2), 0, 0.25)
    mix(out, tone(0.085, 440.0, 445.0, harm=0.08), 0, 0.65)
    mix(out, tone(0.115, 660.0, 665.0, harm=0.08), int(RATE * 0.04), 0.75)
    return fade(out, 2, 55)


def ui_error_deny(rng):
    """Приглушённый двойной низкий отказ"""
    n = int(RATE * 0.12)
    out = [0.0] * n
    mix(out, thump(48, 220.0, 175.0, 16.0), 0, 0.9)
    mix(out, bandpass(burst(18, 6.0, rng, 1.0), 520.0, 1.2), 0, 0.25)
    mix(out, thump(54, 175.0, 135.0, 18.0), int(RATE * 0.048), 0.85)
    return fade(out, 2, 35)


def ui_volume_tick(_rng):
    """Нейтральный чистый тон проверки громкости"""
    out = tone(0.075, 440.0, 440.0, harm=0.08)
    return fade(out, 4, 24)



# ---------- 20.11: удары велосипеда и отклики событий ----------

def ring(seconds, f, decay_ms, attack_ms=4.0, partials=((1.0, 1.0),)):
    """Затухающий звон: сумма синусов (множитель частоты, громкость) с мягкой атакой и спадом"""
    n = int(RATE * seconds)
    a = max(1, int(RATE * attack_ms / 1000))
    out = []
    for i in range(n):
        t = i / RATE
        env = (math.sin(0.5 * math.pi * i / a) ** 2 if i < a else 1.0) * math.exp(-t * 1000.0 / decay_ms)
        out.append(env * sum(g * math.sin(TAU * f * m * t) for m, g in partials))
    return out


def fork_bottom(rng):
    """Пробой вилки: глухой удар резинового отбойника и короткий металлический отзвук ног вилки"""
    n = int(RATE * 0.3)
    out = [0.0] * n
    mix(out, thump(160, 130, 85, 38), 0, 1.0)
    mix(out, lowpass(burst(60, 14, rng, 1.0), 1400.0), 0, 0.45)
    # металл: негармоничные призвуки, быстро гаснут, тише удара
    mix(out, ring(0.18, 1130.0, 45, 1.0, ((1.0, 0.5), (1.47, 0.35), (2.31, 0.2))), int(RATE * 0.004), 0.32)
    return fade(out, 1, 60)


def pump_suspension(rng):
    """Тихий шелест подвески под нагрузкой, без стука отбойника."""
    out = [0.0] * int(RATE * 0.18)
    mix(out, bandpass(burst(155, 48, rng, 18), 680.0, 0.85), 0, 1.0)
    mix(out, lowpass(burst(115, 28, rng, 15), 320.0), 0, 0.5)
    return fade(out, 6, 34)


def rim_knock(rng):
    """Удар колеса о кромку: сухой щелчок обода и короткий тупой отзвук шины"""
    n = int(RATE * 0.14)
    out = [0.0] * n
    mix(out, bandpass(burst(30, 7, rng, 0.5), 1900.0, 2.2), 0, 0.7)
    mix(out, thump(90, 210, 140, 22), 0, 0.9)
    mix(out, ring(0.08, 820.0, 18, 0.5, ((1.0, 0.6), (2.6, 0.25))), 0, 0.25)
    return fade(out, 1, 40)


def crash_impact(rng):
    """Падение: тяжёлый удар тела и рамы, звяк рамы и шорох скольжения по земле"""
    n = int(RATE * 0.95)
    out = [0.0] * n
    mix(out, thump(320, 95, 45, 90), 0, 1.0)
    mix(out, lowpass(burst(160, 40, rng, 2.0), 900.0), 0, 0.8)
    mix(out, ring(0.25, 690.0, 60, 1.0, ((1.0, 0.5), (1.63, 0.3), (2.71, 0.18))), int(RATE * 0.012), 0.25)
    # скольжение: шорох в полосе 900 Гц, медленно стихает
    m = int(RATE * 0.75)
    scrape = bandpass(pink(m, rng), 900.0, 0.9)
    env = smooth_noise(m, 18.0, rng)
    for i in range(m):
        t = i / m
        scrape[i] *= (0.5 + 0.5 * env[i]) * (math.sin(0.5 * math.pi * min(1.0, t * 8.0)) ** 2) * (1.0 - t) ** 1.5
    mix(out, scrape, int(RATE * 0.06), 2.2)
    return fade(out, 1, 120)


def lamp_switch(rng):
    """Тумблер фары: два сухих коротких щелчка (нажатие и фиксация)"""
    n = int(RATE * 0.06)
    out = [0.0] * n
    mix(out, bandpass(burst(10, 2.5, rng, 0.3), 3200.0, 2.5), 0, 0.8)
    mix(out, bandpass(burst(12, 3.0, rng, 0.3), 2400.0, 2.5), int(RATE * 0.018), 0.6)
    return fade(out, 0.5, 15)


# мягкий щипок: основной тон и немного октавы и дуодецимы, как у калимбы
PLUCK = ((1.0, 1.0), (2.0, 0.18), (3.0, 0.05))


def discovery_chime(_rng):
    """Открытие места: тихая чистая кварта вверх, второй тон вступает позже и звучит дольше"""
    n = int(RATE * 1.4)
    out = [0.0] * n
    mix(out, ring(1.0, 523.25, 380, 6.0, PLUCK), 0, 0.6)
    mix(out, ring(1.25, 698.46, 520, 6.0, PLUCK), int(RATE * 0.14), 0.55)
    return fade(out, 2, 250)


def quest_complete(_rng):
    """Задание выполнено: неспешное мажорное трезвучие снизу вверх, без звонкой верхушки"""
    n = int(RATE * 1.8)
    out = [0.0] * n
    for k, f in enumerate((392.0, 493.88, 587.33)):
        mix(out, ring(1.5 - k * 0.15, f, 600 - k * 60, 8.0, PLUCK), int(RATE * 0.12 * k), 0.5)
    mix(out, ring(1.4, 196.0, 700, 20.0, ((1.0, 1.0), (2.0, 0.1))), 0, 0.25)
    return fade(out, 2, 350)



def glass_clink(rng):
    """Хрупкий груз в сумке: два-три тонких звяка стекла о стекло, глухо, через ткань"""
    n = int(RATE * 0.45)
    out = [0.0] * n
    at = 0
    for k, (f, g) in enumerate(((2650.0, 0.8), (3180.0, 0.55), (2420.0, 0.35))):
        mix(out, ring(0.3, f, 70 - k * 12, 0.4, ((1.0, 0.7), (2.76, 0.25), (5.4, 0.08))), at, g)
        mix(out, bandpass(burst(8, 2.0, rng, 0.2), f * 1.4, 3.0), at, g * 0.4)
        at += int(RATE * rng.uniform(0.045, 0.085))
    return fade(lowpass(out, 5200.0), 0.5, 80)


if __name__ == "__main__":
    main()
