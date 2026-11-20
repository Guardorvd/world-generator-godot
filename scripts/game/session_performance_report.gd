extends RefCounted
## Текстовая сводка и взвешенные по времени кадра сравнения условий игры.

const LABELS := {
	"gameplay": "Игра", "opening": "Вступление", "pause": "Пауза", "settings": "Настройки",
	"map": "Карта", "map_path": "Планшет · Поездки", "map_album": "Планшет · Альбом", "map_shop": "Планшет · Магазин", "journal": "Журнал", "plaque": "Табличка", "settlement": "Доска поселения",
	"photo": "Фоторежим", "travel": "Быстрое перемещение", "background": "Свёрнутое окно",
	"walking": "Пешком", "riding": "На велосипеде",
	"dawn": "Рассвет", "day": "День", "dusk": "Закат", "night": "Ночь",
	"near": "У поселения", "approach": "Окрестности поселения", "far": "Вдали от поселений",
	"vista": "Вид с высоты", "other": "Обычный вид", "": "Не определён",
	"menu": "Выход в меню", "exit": "Выход из игры", "switch_world": "Смена мира или загрузка сохранения",
}

const WORK_LABELS := {
	"frame_stream": "Подгрузка мира", "frame_travel_apply": "Подгрузка при перемещении",
	"stream/vegetation": "Подгрузка растительности", "stream/terrain": "Подгрузка рельефа",
	"stream/water": "Подгрузка воды", "stream/outer": "Дальний рельеф", "stream/regions": "Подгрузка областей",
	"vegetation/tree_upload": "Передача мешей деревьев", "vegetation/carpet": "Ковёр травы",
	"vegetation/tree_poll": "Приём готовых деревьев", "frame_day": "Небо и смена света",
	"frame_ambient": "Частицы окружения", "frame_lights_mist": "Местный свет и туман",
	"frame_route": "Навигация", "frame_paused_preview": "Обновление графики на паузе",
	"world_save_auto": "Сохранение мира", "world_save_manual": "Ручное сохранение", "autosave_snapshot": "Подготовка автосохранения",
	"gpu": "GPU", "render_cpu": "CPU отрисовки", "chunk_upload": "Передача чанков",
	"pipeline_compilation": "Компиляции конвейеров", "dotnet_gc": "Пауза GC .NET",
	"process_unmarked": "Неразмеченная работа _process", "gpu_next": "GPU следующего кадра",
	"event_discovery": "Открыто место", "event_look_around": "Обзор с вышки или вершины", "event_crash": "Падение",
	"event_photo": "Снимок",
}


static func groups(timeline: Array[Dictionary]) -> Dictionary:
	var out := {}
	for row: Dictionary in timeline:
		_accumulate(out, "mode", row.mode, row)
		if row.mode not in ["gameplay", "opening", "photo"]:
			continue
		for key: String in ["biome", "light", "settlement_zone", "view", "movement"]:
			_accumulate(out, key, str(row.context.get(key, "")), row)
		if row.context.settlement != "":
			_accumulate(out, "settlement", str(row.context.settlement), row)
	for group: Dictionary in out.values():
		for entry: Dictionary in group.values():
			entry.fps = 1000.0 * entry.frames / entry.frame_ms_total
	return out


static func _accumulate(out: Dictionary, dimension: String, label: String, row: Dictionary) -> void:
	if not out.has(dimension):
		out[dimension] = {}
	var group: Dictionary = out[dimension]
	if not group.has(label):
		group[label] = {frames = 0, frame_ms_total = 0.0, worst_ms = 0.0, hitches = 0, over_33_3_ms = 0}
	var entry: Dictionary = group[label]
	entry.frames += row.frames
	entry.frame_ms_total += row.frame_ms_total
	entry.worst_ms = maxf(entry.worst_ms, row.worst_ms)
	entry.hitches += row.hitches
	entry.over_33_3_ms += row.over_33_3_ms


static func markdown(report: Dictionary) -> String:
	var s: Dictionary = report.summary
	var lines := PackedStringArray([
		"# Производительность игровой сессии", "",
		"Мир «%s» · версия %s · %s" % [report.seed, report.machine.version, report.started_at],
		"%s · %s · %s" % [report.machine.cpu, report.machine.gpu if report.machine.gpu != null else "GPU недоступен", report.machine.renderer],
		"В мире %.1f с · %s · запись мира %.1f мс" % [report.duration_s, _label(report.ended_by), report.world_save_ms],
	])
	if not report.world_load.is_empty():
		lines.append("Загрузка мира %.1f с. Подробности этапов записаны в JSON." % (report.world_load.duration_ms / 1000.0))
	lines.append_array(["", "## Кадры за всю сессию", ""])
	if s.frames == 0:
		lines.append("Сессия завершилась до первого замера кадра.")
		return "\n".join(lines) + "\n"
	lines.append("**Средний FPS %.1f · минимум %.1f · максимум %.1f**" % [s.fps, s.min_fps, s.max_fps])
	lines.append("")
	lines.append("Кадров %d · 1 %% худших %.1f FPS · 0,1 %% худших %s FPS" % [s.frames, s.low1_fps, _number(s.low01_fps)])
	lines.append("Время кадра p50 / p95 / p99 — %.2f / %.2f / %.2f мс. Худший кадр %.1f мс." % [s.ms.p50, s.ms.p95, s.ms.p99, s.ms.max])
	lines.append("Рывков %d. Кадров дольше 16,7 / 33,3 / 100 мс — %d / %d / %d." % [s.hitches, s.over_16_7_ms, s.over_33_3_ms, s.over_100_ms])
	# 20.11: при частоте экрана 60 Гц кадры около 16,7 мс колеблются вокруг порога — «пропуск» считается от полутора кадров экрана
	lines.append("Пропущенных обновлений экрана (кадр дольше %.1f мс при %.0f Гц) — %d (%.1f %%)." % [
		1.5 * 1000.0 / report.machine.refresh_hz, report.machine.refresh_hz, s.missed_refresh, 100.0 * s.missed_refresh / s.frames])
	lines.append("Пики GPU / CPU отрисовки — %s / %s мс. Пики вызовов отрисовки / примитивов — %s / %s. Пик видеопамяти %s МБ." % [
		_number(report.peaks.get("gpu_ms")), _number(report.peaks.get("render_cpu_ms")),
		_number(report.peaks.get("draw_calls"), 0), _number(report.peaks.get("primitives"), 0), _number(report.peaks.get("video_mb"))])
	lines.append("Компиляции конвейеров mesh / surface / draw / canvas — %d / %d / %d / %d." % [
		report.pipelines.mesh, report.pipelines.surface, report.pipelines.draw, report.pipelines.canvas])
	if report.dotnet_gc != null:
		var gc: Dictionary = report.dotnet_gc
		lines.append("Сборки мусора .NET по поколениям 0 / 1 / 2 — %d / %d / %d. Сумма пауз %d мс." % [gc.gen0, gc.gen1, gc.gen2, gc.pause_ms])
	lines.append("Замеры заняли в среднем %.3f мс на кадр, максимум %.2f мс." % [report.sampling.avg_ms, report.sampling.peak_ms])
	lines.append("")
	lines.append("Минимум и максимум FPS рассчитаны по отдельным кадрам. Рывок фиксируется при времени кадра свыше 8 мс и вдвое выше сглаженного времени кадра в текущем режиме.")
	lines.append_array(["", "## Сравнение условий", "",
		"| Условие | Секунды | FPS | Худший кадр, мс | Рывки | Кадры > 33,3 мс |",
		"|---|---:|---:|---:|---:|---:|"])
	var dimensions := {"mode": "Режим", "biome": "Биом", "light": "Свет", "settlement_zone": "Поселения",
		"settlement": "Поселение", "view": "Камера", "movement": "Движение"}
	for dimension: String in dimensions:
		var group: Dictionary = report.context_groups.get(dimension, {})
		var values := group.keys()
		values.sort_custom(func(a: String, b: String) -> bool: return group[a].frame_ms_total > group[b].frame_ms_total)
		for value: String in values:
			var entry: Dictionary = group[value]
			lines.append("| %s · %s | %.1f | %.1f | %.1f | %d | %d |" % [dimensions[dimension], _cell(_label(value)),
				entry.frame_ms_total / 1000.0, entry.fps, entry.worst_ms, entry.hitches, entry.over_33_3_ms])
	if not report.worst_frames.is_empty():
		lines.append_array(["", "## Самые длинные кадры", "",
			"| Секунда | Кадр, мс | Режим | Место и условия | Нагрузка рядом с кадром |",
			"|---:|---:|---|---|---|"])
		for row: Dictionary in report.worst_frames:
			lines.append("| %.3f | %.1f | %s | %s | %s |" % [row.t_s, row.ms, _label(row.mode), _location(row.context), _evidence(row.evidence)])
	var slow_windows: Array = report.timeline.filter(func(row: Dictionary) -> bool:
		return row.frame_ms_total >= 850.0 and row.mode in ["gameplay", "opening", "photo"])
	if not slow_windows.is_empty():
		lines.append_array(["", "## Интервалы игры с самым низким FPS", "",
			"| Секунда | FPS | Место и условия | GPU / CPU отрисовки, мс | Вызовы отрисовки |",
			"|---:|---:|---|---:|---:|"])
		slow_windows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.fps < b.fps)
		for row: Dictionary in slow_windows.slice(0, 10):
			lines.append("| %.2f | %.1f | %s | %s / %s | %s |" % [row.from_s, row.fps, _location(row.context),
				_number(row.render_avg.gpu_ms), _number(row.render_avg.render_cpu_ms), _number(row.render_avg.draw_calls, 0)])
	lines.append_array(["", "## Работа подсистем на CPU", "",
		"| Подсистема | Среднее на кадр, мс | Пик на кадр, мс |", "|---|---:|---:|"])
	var parts: Array = report.work.keys()
	parts.sort_custom(func(a: String, b: String) -> bool: return report.work[a].avg_ms > report.work[b].avg_ms)
	for part: String in parts:
		lines.append("| %s | %.3f | %.2f |" % [WORK_LABELS.get(part, part), report.work[part].avg_ms, report.work[part].peak_ms])
	lines.append("")
	lines.append("Вложенные замеры стриминга и фаз растительности пересекаются с замерами игрового цикла. GPU и CPU могут работать параллельно, а результаты таймеров рендера могут приходить с задержкой. Связь условий с просадкой оценивается по совпадению во времени.")
	lines.append("")
	lines.append("В парном JSON находятся секундная шкала до выхода, события мира и настроек, все рывки и кадры длиннее 100 мс. В сравнении условий используется снимок окружения интервала. «Вид с высоты» оценивается по наклону камеры и перепаду рельефа по направлению взгляда.")
	return "\n".join(lines) + "\n"


static func _location(context: Dictionary) -> String:
	var where := "%s · %s · %s" % [_label(context.biome), _label(context.light), _label(context.view)]
	if context.settlement != "":
		where += " · %s, %.0f м" % [context.settlement, context.settlement_m]
	return _cell(where)


static func _evidence(items: Array) -> String:
	var parts := PackedStringArray()
	for item: Dictionary in items:
		var label: String = WORK_LABELS.get(item.part, item.part)
		if item.part == "after_mode":
			parts.append("после «%s» (%.1f с)" % [_label(item.from), item.held_s])
		elif not item.has("ms") and not item.has("count"):
			parts.append(label)
		elif item.has("ms"):
			parts.append("%s %.1f мс" % [label, item.ms])
		else:
			parts.append("%s ×%d" % [label, item.count])
	return ", ".join(parts) if not parts.is_empty() else "—"


static func _label(value: String) -> String:
	return LABELS.get(value, value)


static func _number(value: Variant, digits := 1) -> String:
	return String.num(value, digits) if value != null else "—"


static func _cell(value: String) -> String:
	return value.replace("|", "\\|").replace("\n", " ")
