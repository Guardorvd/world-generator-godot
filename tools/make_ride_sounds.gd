extends SceneTree
## Ride sound generator (27.11.2026): surface loops and dirt/snow grains. Other sounds come from tools/make_sounds.py.
## Roll, chain and freewheel loops were removed the same day at the user's request (did not sound good);
## until new recordings exist, rolling is carried by the surface loops and pedaling is silent.
## Всё детерминировано (свои сиды), петли бесшовные: фильтры прогоняются по кругу дважды.
##
## Принципы этой версии:
## - ни одна петля езды не несёт гула: всё ниже ~150–200 Гц срезано, тело грунта — в средней полосе;
## - характер покрытия — в зерне и полосе, а не в низах; скорость меняет плотность зёрен (дистанция в игре).
##
## Запуск (из папки проекта):
##   godot --headless --path . --script res://tools/make_ride_sounds.gd            — создать файлы и отчёт
##   godot --headless --path . --script res://tools/make_ride_sounds.gd -- --report — только отчёт по текущим файлам
## Отчёт: RMS, пик, доля энергии ниже 150 и 250 Гц (гул), скачок на шве петли относительно среднего шага.

const RATE := 44100
const ROOT := "res://resources/sounds/"

const LOOPS := [
	"surfaces/tex_packed.wav", "surfaces/tex_dirt.wav", "surfaces/tex_forest.wav", "surfaces/tex_gravel.wav",
	"surfaces/tex_grass.wav", "surfaces/tex_sand.wav", "surfaces/tex_stone.wav", "surfaces/tex_wet.wav",
	"surfaces/tex_wood.wav", "surfaces/tex_snow.wav", "surfaces/tex_water.wav",
]

var rng := RandomNumberGenerator.new()


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 420)
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.has("--report"):
		_report_existing()
		quit(0)
		return
	var t0 := Time.get_ticks_msec()
	_make("surfaces/tex_packed.wav", 21, func() -> PackedFloat32Array: return _tex_packed(4.0), 0.13)
	_make("surfaces/tex_dirt.wav", 22, func() -> PackedFloat32Array: return _tex_dirt(4.0), 0.13)
	_make("surfaces/tex_forest.wav", 23, func() -> PackedFloat32Array: return _tex_forest(5.0), 0.12)
	_make("surfaces/tex_gravel.wav", 24, func() -> PackedFloat32Array: return _tex_gravel(4.0), 0.14)
	_make("surfaces/tex_grass.wav", 25, func() -> PackedFloat32Array: return _tex_grass(4.0), 0.12)
	_make("surfaces/tex_sand.wav", 26, func() -> PackedFloat32Array: return _tex_sand(4.0), 0.12)
	_make("surfaces/tex_stone.wav", 27, func() -> PackedFloat32Array: return _tex_stone(4.0), 0.13)
	_make("surfaces/tex_wet.wav", 28, func() -> PackedFloat32Array: return _tex_wet(4.0), 0.12)
	_make("surfaces/tex_wood.wav", 29, func() -> PackedFloat32Array: return _tex_wood(4.0), 0.12)
	_make("surfaces/tex_snow.wav", 30, func() -> PackedFloat32Array: return _tex_snow(4.0), 0.12)
	_make("surfaces/tex_water.wav", 31, func() -> PackedFloat32Array: return _tex_water(4.0), 0.13)
	for i in 4:
		rng.seed = 400 + i
		_write("surfaces/grain_dirt_%d.wav" % (i + 1), _grain_dirt(), false, 0.0, 0.55)
		rng.seed = 500 + i
		_write("surfaces/grain_snow_%d.wav" % (i + 1), _grain_snow(), false, 0.0, 0.55)
	print("RIDE_SOUNDS готово за %.1f с" % ((Time.get_ticks_msec() - t0) / 1000.0))
	quit(0)


func _make(rel: String, seed_v: int, gen: Callable, target_rms: float) -> void:
	rng.seed = seed_v
	var x: PackedFloat32Array = gen.call()
	x = _write(rel, x, true, target_rms, 0.6)
	print(_stats_line(rel, x))


# ---------- Покрытия: характер в полосе и зерне, без низов ----------

## Асфальт и плотная земля: ровное мягкое шуршание, тонкая пыль.
func _tex_packed(sec: float) -> PackedFloat32Array:
	var n := int(sec * RATE)
	var x := _band(_pink(n), 260.0, 2400.0)
	x = _peak(x, 900.0, 0.8, 1.5)
	var mod := _mod(n, 1.4)
	for i in n:
		x[i] *= 0.88 + 0.12 * mod[i]
	var dust := _scatter(n, 90.0, func() -> PackedFloat32Array:
		return _grain(rng.randf_range(2.0, 4.0), 1800.0, 3600.0, 0.3, 0.8), 0.15, 0.4)
	_add(x, dust, 0.25 * _rms(x) / maxf(_rms(dust), 1e-6))
	return _band(x, 220.0, 4000.0)


## Сухой грунт: тёплое зернистое качение, мягкие комочки.
func _tex_dirt(sec: float) -> PackedFloat32Array:
	var n := int(sec * RATE)
	var x := _band(_pink(n), 230.0, 1900.0)
	x = _peak(x, 650.0, 0.9, 2.5)
	var clods := _scatter(n, 60.0, func() -> PackedFloat32Array:
		return _grain(rng.randf_range(4.0, 9.0), rng.randf_range(500.0, 800.0), rng.randf_range(1500.0, 2300.0), 0.6, rng.randf_range(1.2, 2.6)), 0.2, 0.6)
	_add(x, clods, 0.6 * _rms(x) / maxf(_rms(clods), 1e-6))
	return _band(x, 200.0, 3400.0)


## Лесная тропа: мягкое качение по хвое и лиственному слою, редкие веточки и шорох листьев.
func _tex_forest(sec: float) -> PackedFloat32Array:
	var n := int(sec * RATE)
	var x := _band(_pink(n), 220.0, 1300.0)
	var needles := _band(_pink(n), 1100.0, 3000.0)
	var leaf := _mod(n, 2.2)
	for i in n:
		needles[i] *= 0.4 + 0.6 * leaf[i] * leaf[i]
	_add(x, needles, 0.45 * _rms(x) / maxf(_rms(needles), 1e-6))
	var crinkle := _scatter(n, 24.0, func() -> PackedFloat32Array:
		return _grain(rng.randf_range(8.0, 18.0), rng.randf_range(900.0, 1400.0), rng.randf_range(2400.0, 3600.0), 1.2, rng.randf_range(2.5, 5.0)), 0.25, 0.7)
	_add(x, crinkle, 0.5 * _rms(x) / maxf(_rms(crinkle), 1e-6))
	var twigs := _scatter(n, 1.6, func() -> PackedFloat32Array:
		return _modal(0.03, [[rng.randf_range(700.0, 1100.0), 6.0, 0.5], [rng.randf_range(1700.0, 2300.0), 3.0, 0.25]], 1.5, 600.0, 2800.0), 0.6, 1.0)
	_add(x, twigs, 0.35 * _rms(x) / maxf(_rms(twigs), 1e-6))
	return _band(x, 190.0, 4000.0)


## Гравий: объёмное перекатывание камешков в двух слоях, без резкого верха.
func _tex_gravel(sec: float) -> PackedFloat32Array:
	var n := int(sec * RATE)
	var x := _band(_pink(n), 300.0, 1300.0)
	var mid := _scatter(n, 120.0, func() -> PackedFloat32Array:
		var fc := rng.randf_range(650.0, 1500.0)
		return _grain(rng.randf_range(5.0, 11.0), fc * 0.7, fc * 1.5, 0.5, rng.randf_range(1.3, 3.0)), 0.3, 0.9)
	var fine := _scatter(n, 150.0, func() -> PackedFloat32Array:
		var fc := rng.randf_range(1600.0, 2700.0)
		return _grain(rng.randf_range(3.0, 6.0), fc * 0.75, fc * 1.35, 0.35, rng.randf_range(0.8, 1.6)), 0.2, 0.55)
	var out := PackedFloat32Array()
	out.resize(n)
	_add(out, x, 0.35)
	_add(out, mid, 1.0 * _rms(x) / maxf(_rms(mid), 1e-6))
	_add(out, fine, 0.55 * _rms(x) / maxf(_rms(fine), 1e-6))
	return _band(out, 260.0, 3800.0)


## Трава: приглушённый шелест стеблей по спицам и покрышке.
func _tex_grass(sec: float) -> PackedFloat32Array:
	var n := int(sec * RATE)
	var swish := _band(_pink(n), 700.0, 3000.0)
	var sway := _mod(n, 3.0)
	for i in n:
		swish[i] *= 0.45 + 0.55 * sway[i]
	var body := _band(_pink(n), 230.0, 800.0)
	var out := PackedFloat32Array()
	out.resize(n)
	_add(out, swish, 1.0)
	_add(out, body, 0.35)
	var blades := _scatter(n, 26.0, func() -> PackedFloat32Array:
		return _grain(rng.randf_range(12.0, 24.0), 1200.0, 3200.0, 3.5, rng.randf_range(5.0, 9.0)), 0.2, 0.45)
	_add(out, blades, 0.45 * _rms(out) / maxf(_rms(blades), 1e-6))
	return _band(out, 220.0, 3600.0)


## Песок: мелкозернистое рассыпчатое трение.
func _tex_sand(sec: float) -> PackedFloat32Array:
	var n := int(sec * RATE)
	var sift := _band(_white(n), 1100.0, 3600.0)
	var mod := _mod(n, 2.6)
	for i in n:
		sift[i] *= 0.7 + 0.3 * mod[i]
	var body := _band(_pink(n), 260.0, 900.0)
	var out := PackedFloat32Array()
	out.resize(n)
	_add(out, sift, 0.8)
	_add(out, body, 0.45)
	var sparkle := _scatter(n, 260.0, func() -> PackedFloat32Array:
		return _grain(rng.randf_range(1.5, 3.0), 1600.0, 3600.0, 0.25, 0.6), 0.1, 0.35)
	_add(out, sparkle, 0.5 * _rms(out) / maxf(_rms(sparkle), 1e-6))
	return _band(out, 240.0, 3800.0)


## Камень: плотные короткие нерезкие касания выступов протектора.
func _tex_stone(sec: float) -> PackedFloat32Array:
	var n := int(sec * RATE)
	var x := _band(_pink(n), 300.0, 1400.0)
	var taps := _scatter(n, 42.0, func() -> PackedFloat32Array:
		return _modal(0.024, [[rng.randf_range(420.0, 620.0), 5.0, 0.7], [rng.randf_range(900.0, 1300.0), 3.0, 0.3]], 1.6, 300.0, 1800.0), 0.3, 0.8)
	var out := PackedFloat32Array()
	out.resize(n)
	_add(out, x, 0.6)
	_add(out, taps, 1.1 * _rms(x) / maxf(_rms(taps), 1e-6))
	return _band(out, 260.0, 3000.0)


## Влажный грунт: мягкий плотный липкий шорох, редкие тихие чмоканья.
func _tex_wet(sec: float) -> PackedFloat32Array:
	var n := int(sec * RATE)
	var x := _band(_pink(n), 240.0, 1300.0)
	x = _peak(x, 480.0, 1.0, 2.0)
	var squelch := _scatter(n, 22.0, func() -> PackedFloat32Array:
		var g := _grain(rng.randf_range(10.0, 20.0), 380.0, 1300.0, 2.5, rng.randf_range(4.0, 7.0))
		var f0 := rng.randf_range(320.0, 560.0)
		_add(g, _sweep(minf(0.03, g.size() / float(RATE)), f0, f0 * 1.5), 0.25)
		return g, 0.25, 0.6)
	_add(x, squelch, 0.6 * _rms(x) / maxf(_rms(squelch), 1e-6))
	return _band(x, 220.0, 2800.0)


## Деревянный настил: тёплый полый древесный тон (резонансы досок 380/640 Гц), толчки швов — отдельно (plank_*).
func _tex_wood(sec: float) -> PackedFloat32Array:
	var n := int(sec * RATE)
	var x := _band(_pink(n), 250.0, 1600.0)
	x = _peak(x, 380.0, 3.0, 5.0)
	x = _peak(x, 640.0, 3.0, 3.5)
	var creak := _mod(n, 1.1)
	for i in n:
		x[i] *= 0.85 + 0.15 * creak[i]
	var fibres := _scatter(n, 40.0, func() -> PackedFloat32Array:
		return _grain(rng.randf_range(3.0, 6.0), 900.0, 2400.0, 0.4, 1.2), 0.2, 0.5)
	_add(x, fibres, 0.3 * _rms(x) / maxf(_rms(fibres), 1e-6))
	return _band(x, 220.0, 3200.0)


## Снег: приглушённый деликатный хруст.
func _tex_snow(sec: float) -> PackedFloat32Array:
	var n := int(sec * RATE)
	var x := _band(_pink(n), 260.0, 900.0)
	var crunch := _scatter(n, 85.0, func() -> PackedFloat32Array:
		return _grain(rng.randf_range(5.0, 12.0), rng.randf_range(900.0, 1300.0), rng.randf_range(2200.0, 3200.0), 1.2, rng.randf_range(2.0, 4.0)), 0.25, 0.65)
	var out := PackedFloat32Array()
	out.resize(n)
	_add(out, x, 0.5)
	_add(out, crunch, 1.0 * _rms(x) / maxf(_rms(crunch), 1e-6))
	return _band(_lp(out, 2600.0, 0.7), 230.0, 3600.0)


## Мелкая вода: брызги из-под колеса и мелкие капли.
func _tex_water(sec: float) -> PackedFloat32Array:
	var n := int(sec * RATE)
	var spray := _band(_pink(n), 450.0, 2800.0)
	var mod := _mod(n, 6.0)
	for i in n:
		spray[i] *= 0.5 + 0.5 * mod[i]
	var drops := _scatter(n, 30.0, func() -> PackedFloat32Array:
		var f0 := rng.randf_range(420.0, 900.0)
		return _sweep(rng.randf_range(0.025, 0.05), f0, f0 * rng.randf_range(1.4, 2.0)), 0.15, 0.35)
	_add(spray, drops, 0.5 * _rms(spray) / maxf(_rms(drops), 1e-6))
	return _band(spray, 250.0, 4000.0)


## Отдельные комочки сухого грунта (в игре — по пройденному пути, плотнее на скорости).
func _grain_dirt() -> PackedFloat32Array:
	var x := _grain(rng.randf_range(14.0, 22.0), 450.0, 1800.0, 1.2, rng.randf_range(4.0, 6.0))
	var tail := _grain(10.0, 900.0, 2400.0, 0.6, 2.0)
	_add_at(x, tail, int(rng.randf_range(0.003, 0.007) * RATE), 0.45)
	return _fade(_hp(x, 220.0, 0.7, false), 0.6, 8.0)


## Отдельный хруст снежного наста.
func _grain_snow() -> PackedFloat32Array:
	var n := int(0.05 * RATE)
	var x := PackedFloat32Array()
	x.resize(n)
	var at := 0
	for k in rng.randi_range(3, 5):
		_add_at(x, _grain(rng.randf_range(4.0, 8.0), 1000.0, 3000.0, 0.8, 1.8), at, rng.randf_range(0.5, 1.0))
		at += int(rng.randf_range(0.004, 0.009) * RATE)
	return _fade(_hp(x, 300.0, 0.7, false), 0.5, 10.0)


# ---------- Инструменты DSP ----------

func _white(n: int) -> PackedFloat32Array:
	var x := PackedFloat32Array()
	x.resize(n)
	for i in n:
		x[i] = rng.randfn(0.0, 1.0)
	return x


## Розовый шум (фильтр Келлета), бесшовный: состояние фильтра прогрето прошлым кругом.
func _pink(n: int) -> PackedFloat32Array:
	var w := _white(n)
	var x := PackedFloat32Array()
	x.resize(n)
	var b0 := 0.0
	var b1 := 0.0
	var b2 := 0.0
	for pass_i in 2:
		for i in n:
			var v := w[i]
			b0 = 0.99765 * b0 + v * 0.0990460
			b1 = 0.96300 * b1 + v * 0.2965164
			b2 = 0.57000 * b2 + v * 1.0526913
			if pass_i == 1:
				x[i] = (b0 + b1 + b2 + v * 0.1848) * 0.2
	return x


func _band(x: PackedFloat32Array, lo: float, hi: float) -> PackedFloat32Array:
	return _lp(_hp(x, lo, 0.7071), hi, 0.7071)


func _hp(x: PackedFloat32Array, f: float, q: float, circular := true) -> PackedFloat32Array:
	return _biquad(x, "hp", f, q, 0.0, circular)


func _lp(x: PackedFloat32Array, f: float, q: float, circular := true) -> PackedFloat32Array:
	return _biquad(x, "lp", f, q, 0.0, circular)


func _peak(x: PackedFloat32Array, f: float, q: float, gain_db: float) -> PackedFloat32Array:
	return _biquad(x, "peak", f, q, gain_db, true)


## Биквад RBJ. circular — первый круг только прогревает состояние, так что конец петли гладко переходит в начало.
func _biquad(x: PackedFloat32Array, kind: String, f: float, q: float, gain_db: float, circular: bool) -> PackedFloat32Array:
	var w0 := TAU * minf(f, RATE * 0.45) / RATE
	var cw := cos(w0)
	var al := sin(w0) / (2.0 * q)
	var b0 := 0.0
	var b1 := 0.0
	var b2 := 0.0
	var a0 := 1.0
	var a1 := 0.0
	var a2 := 0.0
	match kind:
		"lp":
			b0 = (1.0 - cw) * 0.5
			b1 = 1.0 - cw
			b2 = b0
			a0 = 1.0 + al
			a1 = -2.0 * cw
			a2 = 1.0 - al
		"hp":
			b0 = (1.0 + cw) * 0.5
			b1 = -(1.0 + cw)
			b2 = b0
			a0 = 1.0 + al
			a1 = -2.0 * cw
			a2 = 1.0 - al
		"peak":
			var a := pow(10.0, gain_db / 40.0)
			b0 = 1.0 + al * a
			b1 = -2.0 * cw
			b2 = 1.0 - al * a
			a0 = 1.0 + al / a
			a1 = -2.0 * cw
			a2 = 1.0 - al / a
	b0 /= a0
	b1 /= a0
	b2 /= a0
	a1 /= a0
	a2 /= a0
	var n := x.size()
	var out := PackedFloat32Array()
	out.resize(n)
	var x1 := 0.0
	var x2 := 0.0
	var y1 := 0.0
	var y2 := 0.0
	var passes := 2 if circular else 1
	for pass_i in passes:
		var store := pass_i == passes - 1
		for i in n:
			var v := x[i]
			var y := b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
			x2 = x1
			x1 = v
			y2 = y1
			y1 = y
			if store:
				out[i] = y
	return out


## Плавная бесшовная огибающая 0..1 (косинусная интерполяция случайных точек по кругу).
func _mod(n: int, rate_hz: float) -> PackedFloat32Array:
	var k := maxi(2, int(round(float(n) / RATE * rate_hz)))
	var pts := PackedFloat32Array()
	pts.resize(k)
	for i in k:
		pts[i] = rng.randf()
	var out := PackedFloat32Array()
	out.resize(n)
	var seg := float(n) / k
	for i in n:
		var p := i / seg
		var j := int(p)
		var fr := p - j
		var s := 0.5 - 0.5 * cos(PI * fr)
		out[i] = lerpf(pts[j % k], pts[(j + 1) % k], s)
	return out


## Одиночное зерно: шумовой импульс с огибающей, полосовой фильтр без хвоста на шве.
func _grain(ms: float, lo: float, hi: float, attack_ms: float, decay_ms: float) -> PackedFloat32Array:
	var n := maxi(16, int(RATE * ms / 1000.0))
	var x := PackedFloat32Array()
	x.resize(n)
	for i in n:
		var t_ms := i * 1000.0 / RATE
		var atk := minf(1.0, t_ms / maxf(0.15, attack_ms))
		var env := pow(atk, 1.5) * exp(-t_ms / maxf(0.3, decay_ms)) * sqrt(sin(PI * float(i) / n))
		x[i] = rng.randfn(0.0, 1.0) * env
	return _lp(_hp(x, lo, 0.7071, false), hi, 0.7071, false)


## Затухающие моды (тело камня, дерева, корпуса втулки) с мягким шумовым возбуждением.
func _modal(sec: float, modes: Array, exc_ms: float, exc_lo: float, exc_hi: float) -> PackedFloat32Array:
	var n := int(RATE * sec)
	var x := _grain(exc_ms, exc_lo, exc_hi, 0.2, exc_ms * 0.4)
	x.resize(n)
	var exc_rms := maxf(_rms(x), 1e-6)
	for i in range(int(RATE * exc_ms / 1000.0), n):
		x[i] = 0.0
	var out := PackedFloat32Array()
	out.resize(n)
	_add(out, x, 0.45 / exc_rms * 0.3)
	for m: Array in modes:
		var f: float = m[0]
		var tau: float = maxf(0.0003, float(m[1]) / 1000.0)
		var amp: float = m[2]
		var ph := rng.randf_range(0.0, 0.35)
		for i in n:
			var t := float(i) / RATE
			out[i] += amp * minf(1.0, t / 0.0006) * exp(-t / tau) * sin(TAU * f * t + ph)
	return _fade(out, 0.1, 3.0)


func _sweep(sec: float, f0: float, f1: float) -> PackedFloat32Array:
	var n := maxi(8, int(RATE * sec))
	var out := PackedFloat32Array()
	out.resize(n)
	var ph := 0.0
	for i in n:
		var t := float(i) / (n - 1)
		var f := f0 + (f1 - f0) * (0.5 - 0.5 * cos(PI * t))
		ph += TAU * f / RATE
		out[i] = pow(sin(PI * t), 2.0) * sin(ph)
	return out


## Случайная россыпь событий по кругу (пуассоновский поток rate в секунду).
func _scatter(n: int, rate: float, make_one: Callable, g_lo: float, g_hi: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(n)
	var t := 0.0
	var mean := RATE / rate
	while true:
		t += -log(maxf(rng.randf(), 1e-6)) * mean + 3.0
		if t >= n:
			break
		var g: PackedFloat32Array = make_one.call()
		_add_circular(out, g, int(t), rng.randf_range(g_lo, g_hi))
	return out


func _fade(x: PackedFloat32Array, ms_in: float, ms_out: float) -> PackedFloat32Array:
	var n := x.size()
	var ni := mini(n, int(RATE * ms_in / 1000.0))
	var no := mini(n, int(RATE * ms_out / 1000.0))
	for i in ni:
		x[i] *= pow(sin(0.5 * PI * float(i) / ni), 2.0)
	for i in no:
		x[n - 1 - i] *= pow(sin(0.5 * PI * float(i) / no), 2.0)
	return x


func _add(dst: PackedFloat32Array, src: PackedFloat32Array, gain: float) -> void:
	for i in mini(dst.size(), src.size()):
		dst[i] += src[i] * gain


func _add_at(dst: PackedFloat32Array, src: PackedFloat32Array, at: int, gain: float) -> void:
	for i in src.size():
		var j := at + i
		if j >= dst.size():
			break
		dst[j] += src[i] * gain


func _add_circular(dst: PackedFloat32Array, src: PackedFloat32Array, at: int, gain: float) -> void:
	var n := dst.size()
	for i in src.size():
		dst[posmod(at + i, n)] += src[i] * gain


func _rms(x: PackedFloat32Array) -> float:
	var s := 0.0
	for v in x:
		s += v * v
	return sqrt(s / maxf(1.0, x.size()))


# ---------- Запись и отчёт ----------

func _write(rel: String, x: PackedFloat32Array, looped: bool, target_rms: float, peak: float) -> PackedFloat32Array:
	var n := x.size()
	var mean := 0.0
	for v in x:
		mean += v
	mean /= maxf(1.0, n)
	for i in n:
		x[i] -= mean
	var pk := 0.0
	if target_rms > 0.0:
		var k := target_rms / maxf(_rms(x), 1e-9)
		for i in n:
			x[i] *= k
		for v in x:
			pk = maxf(pk, absf(v))
		if pk > peak:
			# мягкое ограничение редких пиков вместо жёсткого среза: тихие места не меняются, пики не выше peak
			for i in n:
				x[i] = peak * tanh(x[i] / peak)
	else:
		for v in x:
			pk = maxf(pk, absf(v))
		var k2 := peak / maxf(pk, 1e-9)
		for i in n:
			x[i] *= k2
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	for i in n:
		bytes.encode_s16(i * 2, clampi(roundi(clampf(x[i], -0.95, 0.95) * 32767.0), -32768, 32767))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.stereo = false
	wav.data = bytes
	if looped:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = n
	var path := ProjectSettings.globalize_path(ROOT + rel)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var err := wav.save_to_wav(path)
	if err != OK:
		push_error("не записан %s: %d" % [rel, err])
	return x


func _report_existing() -> void:
	print("Отчёт по текущим петлям езды (файлы на диске):")
	for rel: String in LOOPS:
		var path := ProjectSettings.globalize_path(ROOT + rel)
		if not FileAccess.file_exists(path):
			print("  %-28s нет файла" % rel)
			continue
		var wav := AudioStreamWAV.load_from_file(path)
		print(_stats_line(rel, _samples(wav)))


func _samples(wav: AudioStreamWAV) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if wav == null or wav.format != AudioStreamWAV.FORMAT_16_BITS:
		return out
	var d := wav.data
	var ch := 2 if wav.stereo else 1
	var n := d.size() / (2 * ch)
	out.resize(n)
	for i in n:
		out[i] = d.decode_s16(i * 2 * ch) / 32768.0
	return out


## Доля энергии ниже 150 и 250 Гц (гул), RMS, пик, скачок на шве петли.
func _stats_line(rel: String, x: PackedFloat32Array) -> String:
	if x.is_empty():
		return "  %-28s пусто" % rel
	var total := maxf(_rms(x), 1e-9)
	var lo150 := _rms(_lp(_lp(x, 150.0, 0.7071), 150.0, 0.7071)) / total
	var lo250 := _rms(_lp(_lp(x, 250.0, 0.7071), 250.0, 0.7071)) / total
	var pk := 0.0
	var dsum := 0.0
	for i in x.size():
		pk = maxf(pk, absf(x[i]))
		if i > 0:
			dsum += absf(x[i] - x[i - 1])
	var mean_step := dsum / maxf(1.0, x.size() - 1)
	var seam := absf(x[0] - x[x.size() - 1]) / maxf(mean_step, 1e-9)
	return "  %-28s %.1f с  RMS %.3f  пик %.2f  энергия <150 Гц %4.1f %%  <250 Гц %4.1f %%  шов %.1f шага" % [
		rel, x.size() / float(RATE), total, pk, lo150 * lo150 * 100.0, lo250 * lo250 * 100.0, seam]
