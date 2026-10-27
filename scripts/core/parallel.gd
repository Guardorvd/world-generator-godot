class_name Parallel
extends RefCounted
## Параллельный расчёт по строкам карты на пуле потоков Godot.
## Каждая полоса строк получает свои копии шумов: общие объекты между потоками сильно замедляют GDScript
## (счётчики ссылок), а результат от этого не меняется. По той же причине в горячих циклах, которые
## идут в потоках, нет вызовов статических функций других классов: они развёрнуты на месте.

const BAND := 16


## job(y0, y1) -> результат полосы; возвращает результаты полос по порядку.
## Полосы по band строк, последняя может быть короче. Строк нет — пустой массив, без задач в пуле.
static func bands(h: int, job: Callable, band: int = BAND) -> Array:
	if h <= 0:
		return []
	band = maxi(1, band)
	var out: Array = []
	out.resize(ceili(float(h) / band))
	var lock := Mutex.new()
	var task := func(b: int) -> void:
		var r: Variant = job.call(b * band, mini(h, (b + 1) * band))
		lock.lock()
		out[b] = r
		lock.unlock()
	# полос может быть меньше, чем потоков, — пул просто займёт не все
	var id := WorkerThreadPool.add_group_task(task, out.size(), -1, true)
	WorkerThreadPool.wait_for_group_task_completion(id)
	return out


## Поле fbm(x / d + ox, y / d + oy, oct) по всем клеткам карты W × H, в двойной точности (как в JS).
## В сборке Godot .NET считается на C# (FastGrid.FbmField), результат тот же.
static func fbm_field(W: int, H: int, noise: Simplex, d: float, oct: int, ox: float = 0.0, oy: float = 0.0) -> PackedFloat64Array:
	var fast := Grid.fast_grid()
	if fast != null:
		return fast.FbmField(noise.perm, W, H, d, oct, ox, oy)
	var parts := bands(H, func(y0: int, y1: int) -> PackedFloat64Array:
		var n := noise.clone()
		var r := PackedFloat64Array()
		r.resize((y1 - y0) * W)
		var o := 0
		for y: int in range(y0, y1):
			for x: int in W:
				r[o] = n.fbm(x / d + ox, y / d + oy, oct)
				o += 1
		return r)
	var out := PackedFloat64Array()
	for p: PackedFloat64Array in parts:
		out.append_array(p)
	return out


## То же поле по прямоугольнику клеток cw × ch с углом (x0, y0), в том числе за краем карты.
## parallel_rows включать только для полей полного плана; чанки уже считаются параллельно снаружи.
static func fbm_rect(noise: Simplex, x0: int, y0: int, cw: int, ch: int, d: float, oct: int, ox: float = 0.0, oy: float = 0.0, parallel_rows := false) -> PackedFloat64Array:
	var fast := Grid.fast_grid()
	if fast != null:
		return fast.FbmRect(noise.perm, x0, y0, cw, ch, d, oct, ox, oy, parallel_rows)
	if parallel_rows:
		var out := PackedFloat64Array()
		for part: PackedFloat64Array in bands(ch, func(a: int, b: int) -> PackedFloat64Array:
			return fbm_rect(noise, x0, y0 + a, cw, b - a, d, oct, ox, oy)):
			out.append_array(part)
		return out
	var n := noise.clone()
	var r := PackedFloat64Array()
	r.resize(cw * ch)
	var o := 0
	for j: int in ch:
		for i: int in cw:
			r[o] = n.fbm((x0 + i) / d + ox, (y0 + j) / d + oy, oct)
			o += 1
	return r
