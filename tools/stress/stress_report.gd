extends RefCounted
## Числа и отчёты стресс-теста (tools/stress/stress.gd): статистика кадров, выводы, сводка Markdown, сравнение
## двух отчётов. Только чистые функции: сцены и окна здесь нет, сравнение работает и без окна.

const NOISE_FPS := 15.0    # % — как в docs/CONTROL.md: меньше считается шумом
const NOISE_COUNT := 10.0  # % — вызовы отрисовки и память


static func _r(v: float, step := 0.01) -> float:
	return snappedf(v, step)


static func _mean(a: PackedFloat32Array) -> float:
	var s := 0.0
	for v in a:
		s += v
	return s / maxf(1.0, a.size())


static func _at(sorted: PackedFloat32Array, share: float) -> float:
	return sorted[mini(sorted.size() - 1, int(sorted.size() * share))] if sorted.size() > 0 else 0.0


## Статистика одного замера. ms — время кадров по часам; gpu/cpu — время отрисовки вьюпорта; work — время
## своей работы шага (подгрузка), мс. 0,1 % худших считается только при 1000+ кадров: иначе это один кадр.
static func stats(ms: PackedFloat32Array, gpu: PackedFloat32Array, cpu: PackedFloat32Array,
		work: PackedFloat32Array, calls: float, prims: float) -> Dictionary:
	var n := ms.size()
	if n == 0:
		return {frames = 0, fps = 0.0}
	var s := ms.duplicate()
	s.sort()
	var median := _at(s, 0.5)
	var worst := maxi(1, n / 100)
	var hitches := 0 # рывки: кадр вдвое длиннее обычного и дольше 8 мс
	var over := [0, 0, 0]
	for v in ms:
		hitches += int(v > maxf(8.0, median * 2.0))
		over[0] += int(v > 16.7)
		over[1] += int(v > 33.3)
		over[2] += int(v > 100.0)
	var g := gpu.duplicate()
	g.sort()
	var c := cpu.duplicate()
	c.sort()
	var out := {
		frames = n,
		fps = _r(1000.0 / maxf(_mean(ms), 0.001), 0.1),
		low1_fps = _r(1000.0 / maxf(_mean(s.slice(n - worst)), 0.001), 0.1),
		ms = {min = _r(s[0]), avg = _r(_mean(ms)), p50 = _r(median), p95 = _r(_at(s, 0.95)), p99 = _r(_at(s, 0.99)), max = _r(s[n - 1])},
		hitches = hitches, over_16_7 = over[0], over_33_3 = over[1], over_100 = over[2],
		gpu_ms = _r(_at(g, 0.5)), render_cpu_ms = _r(_at(c, 0.5)),
		draw_calls = roundi(calls / n), primitives = roundi(prims / n),
	}
	if n >= 1000:
		out.low01_fps = _r(1000.0 / maxf(_mean(s.slice(n - maxi(1, n / 1000))), 0.001), 0.1)
	if not work.is_empty():
		var w := work.duplicate()
		w.sort()
		out.work_ms = {p50 = _r(_at(w, 0.5)), p99 = _r(_at(w, 0.99)), max = _r(w[w.size() - 1])}
	# во что упирается кадр: GPU, если отрисовка занимает большую часть кадра
	out.bound = "GPU" if out.gpu_ms > 0.65 * median else "CPU"
	return out


static func _case(report: Dictionary, name: String) -> Dictionary:
	for c: Dictionary in report.get("cases", []):
		if c.name == name:
			return c
	return {}


## Выводы словами: самое медленное, худшие рывки, что сколько стоит, во что упирается кадр, память.
static func findings(report: Dictionary) -> Array:
	var out: Array = []
	var cases: Array = report.get("cases", []).filter(func(c: Dictionary) -> bool: return c.get("frames", 0) > 0)
	if cases.is_empty():
		return ["Замеров нет."]
	cases = cases.filter(func(c: Dictionary) -> bool: return not c.name.contains("off_")) # отключения — в своей таблице
	var slow := cases.duplicate()
	slow.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.fps < b.fps)
	var names := []
	for c: Dictionary in slow.slice(0, 3):
		names.append("%s — %.0f FPS (1%% худших %.0f)" % [c.title, c.fps, c.low1_fps])
	out.append("Самые медленные: " + "; ".join(names) + ".")
	var spiky := cases.duplicate()
	spiky.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.ms.max > b.ms.max)
	names = []
	for c: Dictionary in spiky.slice(0, 3):
		if c.ms.max > maxf(16.7, c.ms.p50 * 2.0):
			var why: Array = c.get("worst", [])
			names.append("%s — кадр %.0f мс при обычном %.1f мс, рывков %d%s" % [c.title, c.ms.max, c.ms.p50, c.hitches,
				" (%s)" % why[0].cause if not why.is_empty() else ""])
	out.append("Самые большие пики: " + "; ".join(names) + "." if not names.is_empty() else "Пиков вдвое длиннее обычного кадра и дольше 16,7 мс нет.")
	for key: String in report.get("ablation", {}):
		var ab: Dictionary = report.ablation[key]
		var items: Array = ab.items.duplicate()
		items.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.gain_ms > b.gain_ms)
		names = []
		for it: Dictionary in items.slice(0, 4):
			if it.gain_ms > 0.05 * ab.base_ms:
				names.append("%s −%.1f мс (%.0f %%)" % [it.title, it.gain_ms, 100.0 * it.gain_ms / ab.base_ms])
		out.append("Что стоит дороже всего (%s, кадр %.1f мс): %s." % [ab.title, ab.base_ms,
			", ".join(names) if not names.is_empty() else "ни одно отключение не дало больше 5 % кадра"])
		for it: Dictionary in items:
			if it.name == "half_res":
				out.append("%s упирается в %s: половинное разрешение даёт %.0f %% кадра." % [ab.title,
					"пиксели (разрешение, заполнение экрана)" if it.gain_ms > 0.25 * ab.base_ms else ("геометрию на GPU (треугольники, вызовы, тени), а не в пиксели"
					if _case(report, ab.base).get("bound", "") == "GPU" else "CPU, а не в видеокарту"), 100.0 * it.gain_ms / ab.base_ms])
	var a := _case(report, "forest.still")
	var b := _case(report, "forest.dense_still")
	if not a.is_empty() and not b.is_empty():
		out.append("Лес вдвое гуще по заявке (%d → %d объектов): %.0f → %.0f FPS." % [a.get("objects", 0), b.get("objects", 0), a.fps, b.fps])
	for pair: Array in [["world.road_still", "world.ride"], ["forest.still", "forest.ride"]]:
		a = _case(report, pair[0])
		b = _case(report, pair[1])
		if not a.is_empty() and not b.is_empty():
			out.append("Подгрузка в движении (%s): 1 %% худших %.0f FPS против %.0f на месте, худший кадр %.0f мс." % [b.title, b.low1_fps, a.low1_fps, b.ms.max])
	a = _case(report, "forest.still")
	b = _case(report, "forest.back")
	if not a.is_empty() and not b.is_empty() and a.draw_calls > 0:
		out.append("Тот же вид леса после переездов: вызовов %d → %d (%+.0f %%), треугольников %+.0f %%, кадр %.1f → %.1f мс%s." % [
			a.draw_calls, b.draw_calls, _delta(a.draw_calls, b.draw_calls), _delta(maxf(a.primitives, 1.0), b.primitives), a.ms.p50, b.ms.p50,
			" — лес не вернулся к прежней раскладке" if absf(_delta(a.draw_calls, b.draw_calls)) > 5.0 else ""])
	a = _case(report, "base.empty")
	b = _case(report, "base.calib_end")
	if not a.is_empty() and not b.is_empty():
		var drift := absf(_delta(a.ms.p50, b.ms.p50))
		out.append("Шум машины: пустая сцена в начале и в конце %.2f и %.2f мс на кадр (%.0f %%)%s." % [a.ms.p50, b.ms.p50, drift,
			" — машина была занята, числам доверять осторожно" if drift > NOISE_FPS else ""])
	for c: Dictionary in cases:
		if c.has("tick_parts_ms"):
			var parts: Dictionary = c.tick_parts_ms
			var keys: Array = parts.keys()
			keys.sort_custom(func(a: String, b: String) -> bool: return parts[a] > parts[b])
			var top: Array = []
			for k: String in keys.slice(0, 3):
				top.append("%s %.2f" % [k, parts[k]])
			out.append("%s: CPU игры %.1f мс на кадр (%s мс; физика %.0f Гц), кадр %.1f мс, GPU %.1f мс." % [c.title, c.get("game_cpu_ms", 0.0),
				", ".join(top), c.get("physics_hz", 0.0), c.ms.p50, c.gpu_ms])
	var tr := _case(report, "world.after_travel")
	if not tr.is_empty():
		out.append("Быстрое перемещение: переход %.1f с, худший кадр в нём %.0f мс; после прибытия прогрев до %.0f мс, дальше %.0f FPS (1 %% худших %.0f)." % [
			tr.get("travel_s", 0.0), tr.get("travel_worst_ms", 0.0), tr.get("cold_max_ms", 0.0), tr.fps, tr.low1_fps])
	var mem: Dictionary = report.get("memory", {})
	if mem.has("after_free") and mem.has("after_free2"):
		var grow: float = mem.after_free2.rss_mb - mem.after_free.rss_mb
		out.append("Второй цикл загрузки и выгрузки: процесс %+.0f МБ, видеопамять %+.0f МБ, узлов %+d к первому%s." % [grow,
			mem.after_free2.video_mb - mem.after_free.video_mb, mem.after_free2.nodes - mem.after_free.nodes,
			" — растёт от цикла к циклу, похоже на утечку" if grow > 50.0 else " — не растёт, остаток после первой выгрузки — кэши"])
	if mem.has("menu") and mem.has("after_free"):
		out.append("Память после выгрузки мира против меню до загрузки: процесс %+.0f МБ, видеопамять %+.0f МБ, узлов %+d (часть — кэши игры, а не утечка; смотреть на рост от версии к версии)." % [
			mem.after_free.rss_mb - mem.menu.rss_mb, mem.after_free.video_mb - mem.menu.video_mb, mem.after_free.nodes - mem.menu.nodes])
	return out


static func _delta(base: float, now: float) -> float:
	return 100.0 * (now - base) / base if absf(base) > 0.0001 else 0.0


## Сравнение двух отчётов по именам замеров. Возвращает {rows, warnings, text}: ⚠ — хуже шума.
static func compare(base: Dictionary, now: Dictionary) -> Dictionary:
	var rows: Array = []
	var warnings: Array = []
	if base.get("machine", {}).get("gpu", "") != now.get("machine", {}).get("gpu", "") \
			or base.get("machine", {}).get("renderer", "") != now.get("machine", {}).get("renderer", ""):
		warnings.append("Другая машина или рендерер: числа сравнивать нельзя (%s / %s)." % [base.get("machine", {}).get("gpu", "?"), now.get("machine", {}).get("gpu", "?")])
	var lines := ["| Замер | FPS было | FPS стало | Δ FPS | Δ p99 | Δ худший кадр | Δ вызовы | Δ видеопамять |", "|---|---:|---:|---:|---:|---:|---:|---:|"]
	for c: Dictionary in now.get("cases", []):
		var b := _case(base, c.name)
		if b.is_empty() or b.get("frames", 0) == 0 or c.get("frames", 0) == 0:
			continue
		var row := {name = c.name, fps = _r(_delta(b.fps, c.fps), 0.1), p99 = _r(_delta(b.ms.p99, c.ms.p99), 0.1),
			max = _r(_delta(b.ms.max, c.ms.max), 0.1), draw_calls = _r(_delta(b.draw_calls, c.draw_calls), 0.1),
			video = _r(_delta(b.get("video_mb", 0.0), c.get("video_mb", 0.0)), 0.1)}
		# на сотнях FPS проценты ничего не значат: кадр должен стать хуже ещё и на 0,5 мс, p99 — на 1 мс
		row.low1 = _r(_delta(b.low1_fps, c.low1_fps), 0.1)
		row.hitches = int(c.get("hitches", 0)) - int(b.get("hitches", 0))
		# 1 % худших и рывки: хуже шума и заметно в мс (1 % худших — на 2 мс), рывков — хотя бы на 3 больше и вдвое
		var low_worse: bool = row.low1 < -NOISE_FPS and 1000.0 / maxf(c.low1_fps, 0.1) - 1000.0 / maxf(b.low1_fps, 0.1) > 2.0
		var hitch_worse: bool = row.hitches >= 3 and c.get("hitches", 0) >= 2 * maxi(1, b.get("hitches", 0))
		row.worse = low_worse or hitch_worse or (row.fps < -NOISE_FPS and c.ms.avg - b.ms.avg > 0.5) or (row.p99 > NOISE_FPS and c.ms.p99 - b.ms.p99 > 1.0) 			or row.draw_calls > NOISE_COUNT or row.video > NOISE_COUNT
		row.better = row.fps > NOISE_FPS
		rows.append(row)
		if row.worse:
			warnings.append("%s: FPS %+.0f %%, 1 %% худших %+.0f %%, p99 %+.0f %%, рывков %+d, вызовы %+.0f %%, видеопамять %+.0f %%." % [c.title, row.fps,
				row.low1, row.p99, row.hitches, row.draw_calls, row.video])
		lines.append("| %s%s | %.0f | %.0f | %+.0f %% | %+.0f %% | %+.0f %% | %+.0f %% | %+.0f %% |" % ["⚠ " if row.worse else "", c.title,
			b.fps, c.fps, row.fps, row.p99, row.max, row.draw_calls, row.video])
	# не замеры кадров: память, загрузка, выборки высоты
	var bm: Dictionary = base.get("memory", {})
	var nm: Dictionary = now.get("memory", {})
	if bm.has("menu") and bm.has("after_free") and nm.has("menu") and nm.has("after_free"):
		var b_left: float = bm.after_free.rss_mb - bm.menu.rss_mb
		var n_left: float = nm.after_free.rss_mb - nm.menu.rss_mb
		if n_left - b_left > maxf(50.0, absf(b_left) * NOISE_COUNT / 100.0):
			warnings.append("Память после выгрузки мира: остаток %+.0f МБ против %+.0f МБ в базе." % [n_left, b_left])
	for key: String in ["peak_rss_mb"]:
		if bm.has("played") and nm.has("played") and nm.played.get(key, 0.0) > bm.played.get(key, 0.0) * (1.0 + NOISE_COUNT / 100.0) + 50.0:
			warnings.append("Пик памяти процесса: %.0f МБ против %.0f МБ в базе." % [nm.played[key], bm.played[key]])
	var bl: float = base.get("load", {}).get("load_s", 0.0)
	var nl: float = now.get("load", {}).get("load_s", 0.0)
	if bl > 0.0 and nl > 0.0 and _delta(bl, nl) > NOISE_FPS and nl - bl > 1.0:
		warnings.append("Загрузка мира: %.1f с против %.1f с в базе." % [nl, bl])
	var bmi: Dictionary = base.get("micro", {})
	var nmi: Dictionary = now.get("micro", {})
	for key: String in nmi:
		if bmi.has(key) and _delta(bmi[key], nmi[key]) > NOISE_FPS and nmi[key] - bmi[key] > 0.5:
			warnings.append("Выборка %s: %.2f мкс против %.2f мкс в базе." % [key.trim_suffix("_us"), nmi[key], bmi[key]])
	var head := "База: версия %s, коммит %s, %s. Шум: FPS и p99 до %d %% (и не меньше 0,5 и 1 мс), вызовы и память до %d %%. Худший кадр — для сведения, он шумный. Строку с ⚠ перед выводом повторить один раз: --only <имя>.\n\n" % [
		base.get("version", "?"), base.get("commit", "?"), base.get("date", "?"), int(NOISE_FPS), int(NOISE_COUNT)]
	return {rows = rows, warnings = warnings, text = head + "\n".join(lines) + "\n"}


static func markdown(report: Dictionary, comparison: Dictionary = {}) -> String:
	var m: Dictionary = report.get("machine", {})
	var t := "# Стресс-тест производительности\n\n"
	t += "Версия %s, коммит %s%s, %s. %s, %s, %s, окно %s, %s.\nГруппы: %s. Время прогона %.0f с.%s\n\n" % [
		report.get("version", "?"), report.get("commit", "?"), " (есть правки)" if report.get("dirty", false) else "", report.get("date", ""),
		m.get("gpu", "?"), m.get("cpu", "?"), m.get("renderer", "?"), m.get("window", "?"), "отладочная сборка" if m.get("debug", true) else "релизная сборка",
		", ".join(report.get("groups", [])), report.get("duration_s", 0.0),
		" **Прогон не завершён: " + "; ".join(report.get("failed", [])) + ".**" if not report.get("failed", []).is_empty() else ""]
	t += "## Выводы\n\n"
	for f: String in report.get("findings", []):
		t += "- %s\n" % f
	if not comparison.is_empty():
		t += "\n## Сравнение с базой\n\n"
		for w: String in comparison.warnings:
			t += "- ⚠ %s\n" % w
		if comparison.warnings.is_empty():
			t += "Хуже шума ничего нет.\n"
		t += "\n" + comparison.text
	t += "\n## Замеры\n\n| Замер | FPS | 1 % худших | p50, мс | p99, мс | худший, мс | рывки | прогрев, худший мс | GPU, мс | CPU работы, мс | вызовы | треуг., тыс. | упор |\n|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|\n"
	for c: Dictionary in report.get("cases", []):
		if c.get("frames", 0) == 0:
			continue
		t += "| %s | %.0f | %.0f | %.1f | %.1f | %.0f | %d | %.0f | %.1f | %.1f | %d | %.0f | %s |\n" % [c.title, c.fps, c.low1_fps, c.ms.p50, c.ms.p99,
			c.ms.max, c.hitches, c.get("cold_max_ms", 0.0), c.gpu_ms, c.get("game_cpu_ms", c.get("work_ms", {}).get("p50", 0.0)), c.draw_calls, c.primitives / 1000.0, c.bound]
	for key: String in report.get("ablation", {}):
		var ab: Dictionary = report.ablation[key]
		t += "\n## Что сколько стоит: %s (кадр %.1f мс, GPU %.1f мс)\n\n| Отключено | кадр, мс | выигрыш, мс | %% кадра | выигрыш GPU, мс | само переключение, мс |\n|---|---:|---:|---:|---:|---:|\n" % [ab.title, ab.base_ms, ab.base_gpu_ms]
		var items: Array = ab.items.duplicate()
		items.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.gain_ms > b.gain_ms)
		for it: Dictionary in items:
			t += "| %s | %.1f | %+.1f | %.0f | %+.1f | %.0f |\n" % [it.title, it.frame_ms, it.gain_ms, 100.0 * it.gain_ms / maxf(ab.base_ms, 0.001), it.gpu_gain_ms, it.get("apply_ms", 0.0)]
		t += "\nВыигрыши не складываются: кадр упирается либо в GPU, либо в CPU, и отключение видно только на той стороне, которая держит кадр.\n"
	var worst := ""
	for c: Dictionary in report.get("cases", []):
		for w: Dictionary in c.get("worst", []):
			worst += "| %s | %.1f | %.0f | %.1f | %.1f / %.1f | %s |\n" % [c.title, w.t, w.ms, w.work_ms, w.get("gpu_ms", 0.0), w.get("cpu_ms", 0.0), w.cause]
	if worst != "":
		t += "\n## Длинные кадры (дольше 16,7 мс, до пяти на замер)\n\n| Замер | секунда | кадр, мс | работа подгрузки, мс | GPU / CPU отрисовки, мс | самое дорогое в этом кадре |\n|---|---:|---:|---:|---:|---|\n" + worst
	if report.has("micro"):
		t += "\nВыборки у дороги, мкс на вызов: ground_at %.2f, surface_at %.2f, depth_at %.2f, проверка габарита %.2f.\n" % [report.micro.ground_at_us,
			report.micro.surface_at_us, report.micro.get("depth_at_us", 0.0), report.micro.get("passable_us", 0.0)]
	var mem: Dictionary = report.get("memory", {})
	if not mem.is_empty():
		t += "\n## Память, МБ\n\n| Точка | процесс | пик процесса | видеопамять | объекты | узлы |\n|---|---:|---:|---:|---:|---:|\n"
		for key: String in mem:
			t += "| %s | %.0f | %.0f | %.0f | %d | %d |\n" % [mem[key].title, mem[key].rss_mb, mem[key].peak_rss_mb, mem[key].video_mb, mem[key].objects, mem[key].nodes]
	if report.has("load"):
		t += "\nЗагрузка мира «%s»: %.1f с (%s).\n" % [report.load.seed, report.load.load_s, "из кэша стресс-теста" if report.load.cached else "с генерацией, дальше будет из кэша"]
	return t
