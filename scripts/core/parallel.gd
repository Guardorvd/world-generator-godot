class_name Parallel
extends RefCounted
## Параллельный расчёт по строкам карты на пуле потоков Godot.
## Каждая полоса строк получает свои копии шумов: общие объекты между потоками сильно замедляют GDScript
## (счётчики ссылок), а результат от этого не меняется. По той же причине в горячих циклах, которые
## идут в потоках, нет вызовов статических функций других классов: они развёрнуты на месте.

const BAND := 16


## job(y0, y1) -> результат полосы; возвращает результаты полос по порядку
static func bands(h: int, job: Callable, band: int = BAND) -> Array:
	var out: Array = []
	out.resize(ceili(float(h) / band))
	var lock := Mutex.new()
	var task := func(b: int) -> void:
		var r: Variant = job.call(b * band, mini(h, (b + 1) * band))
		lock.lock()
		out[b] = r
		lock.unlock()
	var id := WorkerThreadPool.add_group_task(task, out.size(), -1, true)
	WorkerThreadPool.wait_for_group_task_completion(id)
	return out


## Поле fbm(x / d + ox, y / d + oy, oct) по всем клеткам, в двойной точности (как в JS).
## В сборке Godot .NET считается на C# (FastGrid.FbmField), результат тот же.
static func fbm_field(w: WorldData, noise: Simplex, d: float, oct: int, ox: float = 0.0, oy: float = 0.0) -> PackedFloat64Array:
	var W := w.W
	var fast := Grid.fast_grid()
	if fast != null:
		return fast.FbmField(noise.perm, W, w.H, d, oct, ox, oy)
	var parts := bands(w.H, func(y0: int, y1: int) -> PackedFloat64Array:
		var n := noise.clone()
		var r := PackedFloat64Array()
		r.resize((y1 - y0) * W)
		var o := 0
		for y in range(y0, y1):
			for x in W:
				r[o] = n.fbm(x / d + ox, y / d + oy, oct)
				o += 1
		return r)
	var out := PackedFloat64Array()
	for p in parts:
		out.append_array(p)
	return out
