extends SceneTree
## Сравнение прогона с базой (сравнивается то, что есть в новом прогоне): снимки (доля изменившихся пикселей и картинка «было | стало | разница»),
## сводки миров (stats_*.json) и замеры (perf.json). Пишет <новая папка>/compare/report.md и картинки рядом.
## По умолчанию база — самая свежая версия в tools/control/baseline, новая папка — tools/control/runs/<версия>.
## Запуск из папки проекта:
##   godot --headless --path . --script res://tools/control/compare.gd -- [--base <папка>] [--new <папка>]

const Dev := preload("res://tools/control/control.gd")
const PIXEL_DIFF := 32        # пиксель изменился, если хоть один канал отличается больше чем на столько
const IMAGE_CHANGED := 0.5    # снимок изменился, если изменилось больше стольких процентов пикселей
const LOAD_WORSE := 15.0      # загрузка дольше на столько процентов — заметно
const FPS_WORSE := 15.0       # FPS ниже на столько процентов — заметно
const MEMORY_WORSE := 10.0    # памяти больше на столько процентов — заметно

var lines: PackedStringArray = []
var notes: PackedStringArray = []   # что заметно изменилось: короткий итог в начале отчёта


func _init() -> void:
	var base := Dev.arg("base", Dev.latest_baseline())
	var fresh := Dev.arg("new", Dev.RUNS.path_join(Dev.version()))
	base = Dev.abs_dir(base)
	fresh = Dev.abs_dir(fresh)
	if base == "" or not DirAccess.dir_exists_absolute(base) or not DirAccess.dir_exists_absolute(fresh):
		printerr("Нет папки базы (%s) или прогона (%s)" % [base, fresh])
		quit(1)
		return
	var out := fresh.path_join("compare")
	DirAccess.make_dir_recursive_absolute(out)
	lines.append("# Сравнение: %s → %s" % [base.get_file(), fresh.get_file()])
	lines.append("")
	_compare_stats(base, fresh)
	_compare_images(base, fresh, out)
	_compare_perf(base, fresh)
	var head: PackedStringArray = ["", "## Итог", ""]
	if notes.is_empty():
		head.append("Заметных отличий нет.")
	for n in notes:
		head.append("- " + n)
	head.append("")
	var report := "\n".join(lines.slice(0, 2) + head + lines.slice(2)) + "\n"
	var f := FileAccess.open(out.path_join("report.md"), FileAccess.WRITE)
	f.store_string(report)
	print(report)
	print("Отчёт: ", out.path_join("report.md"))
	quit()


static func _files(dir: String, prefix: String, ext: PackedStringArray) -> PackedStringArray:
	var r: PackedStringArray = []
	for f in DirAccess.get_files_at(dir):
		if f.begins_with(prefix) and f.get_extension() in ext:
			r.append(f)
	r.sort()
	return r


static func _pct(a: float, b: float) -> float:
	return 0.0 if a == 0.0 else 100.0 * (b - a) / a


# --- Сводки миров ---

static func _flat(d: Dictionary, prefix: String, out: Dictionary) -> void:
	for k in d:
		if d[k] is Dictionary:
			_flat(d[k], prefix + str(k) + ".", out)
		else:
			out[prefix + str(k)] = d[k]


func _compare_stats(base: String, fresh: String) -> void:
	lines.append("## Миры")
	lines.append("")
	# сравнивается то, что снято в новом прогоне: быстрая проверка снимает один мир, а база может быть полной
	for f in _files(fresh, "stats_", ["json"]):
		var a := {}
		var b := {}
		var na: Variant = Dev.load_json(base.path_join(f))
		var name := f.trim_prefix("stats_").trim_suffix(".json")
		if na == null:
			lines.append("- %s: в базе этого мира нет" % name)
			continue
		_flat(na, "", a)
		_flat(Dev.load_json(fresh.path_join(f)), "", b)
		var diff: PackedStringArray = []
		var keys := a.keys()
		for k in b:
			if not a.has(k):
				keys.append(k)
		for k in keys:
			if str(a.get(k, "—")) != str(b.get(k, "—")):
				diff.append("%s %s → %s" % [k, str(a.get(k, "—")), str(b.get(k, "—"))])
		if diff.is_empty():
			lines.append("- %s: мир тот же" % name)
		else:
			lines.append("- %s: %s" % [name, ", ".join(diff)])
			notes.append("%s: мир изменился (%d показателей)" % [name, diff.size()])
	lines.append("")


# --- Снимки ---

func _compare_images(base: String, fresh: String, out: String) -> void:
	lines.append("## Снимки")
	lines.append("")
	lines.append("Изменившиеся пиксели (канал отличается больше чем на %d), %%. Картинки «было | стало | разница» — в папке compare." % PIXEL_DIFF)
	lines.append("")
	lines.append("| Снимок | Изменилось, % | |")
	lines.append("|---|---:|---|")
	for f in _files(fresh, "", ["png", "jpg"]):
		var name := f.get_basename()
		if not FileAccess.file_exists(base.path_join(f)):
			lines.append("| %s | — | нет в базе |" % name)
			continue
		var a := Image.load_from_file(base.path_join(f))
		var b := Image.load_from_file(fresh.path_join(f))
		if a.get_size() != b.get_size():
			b.resize(a.get_width(), a.get_height(), Image.INTERPOLATE_BILINEAR)
		var r := _diff(a, b)
		var share: float = r[0]
		var flag := "изменился" if share > IMAGE_CHANGED else ""
		if share > IMAGE_CHANGED:
			notes.append("%s: изменилось %.1f %% пикселей" % [name, share])
		lines.append("| %s | %.2f | %s |" % [name, share, flag])
		_triptych(a, b, r[1]).save_jpg(out.path_join(name + ".jpg"), 0.85)
	lines.append("")


## [доля изменившихся пикселей в процентах, картинка разницы: новый снимок блёкло, изменения красным]
static func _diff(a: Image, b: Image) -> Array:
	a.convert(Image.FORMAT_RGB8)
	b.convert(Image.FORMAT_RGB8)
	var da := a.get_data()
	var db := b.get_data()
	var dd := PackedByteArray()
	dd.resize(da.size())
	var changed := 0
	var i := 0
	while i < da.size():
		var d := maxi(absi(da[i] - db[i]), maxi(absi(da[i + 1] - db[i + 1]), absi(da[i + 2] - db[i + 2])))
		if d > PIXEL_DIFF:
			changed += 1
			dd[i] = 255
			dd[i + 1] = 40
			dd[i + 2] = 40
		else:
			var g := (db[i] + db[i + 1] + db[i + 2]) / 9 + 40
			dd[i] = g
			dd[i + 1] = g
			dd[i + 2] = g
		i += 3
	var img := Image.create_from_data(a.get_width(), a.get_height(), false, Image.FORMAT_RGB8, dd)
	return [100.0 * changed / maxi(1, da.size() / 3), img]


## Три картинки в ряд, каждая в половину размера (не шире 640)
static func _triptych(a: Image, b: Image, d: Image) -> Image:
	var w := mini(640, a.get_width() / 2)
	var h := roundi(a.get_height() * float(w) / a.get_width())
	var out := Image.create(w * 3 + 8, h, false, Image.FORMAT_RGB8)
	out.fill(Color.WHITE)
	var x := 0
	for img in [a, b, d]:
		var s: Image = img.duplicate()
		s.resize(w, h, Image.INTERPOLATE_BILINEAR)
		out.blit_rect(s, Rect2i(0, 0, w, h), Vector2i(x, 0))
		x += w + 4
	return out


# --- Замеры ---

func _compare_perf(base: String, fresh: String) -> void:
	var a: Variant = Dev.load_json(base.path_join("perf.json"))
	var b: Variant = Dev.load_json(fresh.path_join("perf.json"))
	lines.append("## Производительность")
	lines.append("")
	if a == null or b == null:
		lines.append("Нет perf.json в %s." % ("базе" if a == null else "новом прогоне"))
		lines.append("")
		return
	lines.append("База: %s, %s. Новый прогон: %s, %s." % [a.version, a.get("machine", {}).get("gpu", "?"), b.version, b.get("machine", {}).get("gpu", "?")])
	if a.get("machine", {}).get("gpu") != b.get("machine", {}).get("gpu") or a.get("machine", {}).get("cpu") != b.get("machine", {}).get("cpu"):
		lines.append("**Замеры сняты на разных машинах: сравнивать их нельзя.**")
	lines.append("")
	lines.append("| Размер | Показатель | Было | Стало | Разница |")
	lines.append("|---|---|---:|---:|---:|")
	for s in b.sizes:
		if not a.sizes.has(s):
			lines.append("| %s | нет в базе | | | |" % s)
			continue
		var ra: Dictionary = a.sizes[s]
		var rb: Dictionary = b.sizes[s]
		_perf_row(s, "Загрузка, с", ra.load_s, rb.load_s, LOAD_WORSE, true)
		_perf_row(s, "FPS, осмотр", ra.look.fps, rb.look.fps, FPS_WORSE, false)
		_perf_row(s, "FPS 1% худших, осмотр", ra.look.low1, rb.look.low1, FPS_WORSE, false)
		_perf_row(s, "FPS, дорога", ra.road.fps, rb.road.fps, FPS_WORSE, false)
		_perf_row(s, "FPS 1% худших, дорога", ra.road.low1, rb.road.low1, FPS_WORSE, false)
		_perf_row(s, "Память процесса, МБ", ra.memory.rss_mb, rb.memory.rss_mb, MEMORY_WORSE, true)
		_perf_row(s, "Видеопамять, МБ", ra.memory.video_mb, rb.memory.video_mb, MEMORY_WORSE, true)
		_perf_row(s, "Вызовов отрисовки", ra.draw_calls, rb.draw_calls, MEMORY_WORSE, true)
	lines.append("")
	lines.append("Загрузка и FPS от прогона к прогону гуляют на 5–10 %%: заметным считается хуже на %d %% (загрузка), %d %% (FPS), %d %% (память)." % [LOAD_WORSE, FPS_WORSE, MEMORY_WORSE])
	lines.append("")


## Строка таблицы; higher_worse — рост показателя плохо (время, память), иначе плохо падение (FPS)
func _perf_row(size: String, label: String, a: float, b: float, limit: float, higher_worse: bool) -> void:
	var d := _pct(a, b)
	var worse := d > limit if higher_worse else d < -limit
	var mark := " ⚠" if worse else ""
	if worse:
		notes.append("%s: %s %s → %s (%+.0f %%)" % [size, label, _num(a), _num(b), d])
	lines.append("| %s | %s | %s | %s | %+.1f %%%s |" % [size, label, _num(a), _num(b), d, mark])


static func _num(v: float) -> String:
	return str(roundi(v)) if absf(v) >= 100.0 else "%.1f" % v
