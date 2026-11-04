extends RefCounted
## Trail Lab, генератор местности, v2 (01.11). Окно 512 × 512 м рельефа того же генератора, что игра (StageRelief:
## шумы, нормализация, микрорельеф; без рек, дорог и поселений), из мира с сидом «Trail Lab #<seed>», и поверх —
## простые формы характера. Детерминирован по (seed, kind).
## v2 по заездам 01.11 (v1 давала похожие склоны: всегда лучшее окно по перепаду, одна ориентация):
##  1. окно — случайное (по сиду) среди подходящих по перепаду и без воды, не лучшее; поворот на 0/90/180/270° и
##     отражение — тоже по сиду;
##  2. многоуровневость — уступы (TERRACE): высоты сводятся к полкам шага step с короткими крутыми подъёмами между
##     ними, доля strength; у «плато» — всегда, у прочих — иногда и слабее;
##  3. овраги и гребни (GULLY) — по ребристому шуму: V-образные ложбины глубиной depth; у «хребтов» — всегда;
##  4. сила форм, шаг уступов и глубина — случайные в пределах характера: два сида одного характера разные.
## v3 (01.11): мир размером с игровой план (WorldGenerator.PLAN_SIZE × PLAN_SIZE клеток по 4 м, ~3 км) той же природной
## географией, что игра (WorldGenerator.geography: рельеф, море, реки, климат; без поселений и дорог) — generate_world.
## Поисковик (TrailLabScout) ищет на нём места под трассы; лаборатория строит окно CELLS × CELLS вокруг выбранного
## места (use_window). В окне генератор трасс может врезать в землю небольшие овражки и выемки (apply_cuts) — под гэпы,
## мостки и нижний проход петли.

const CELLS := 128                      ## клеток на сторону (как у главного полигона): 512 м
const SIZE := CELLS * GameConfig.TILE   ## м
## Характеры: перепад окна (м); terrace — вероятность уступов и их сила; gully — вероятность оврагов и их глубина, м.
const KINDS := {
	hills = {title = "Холмы", fall = Vector2(25.0, 60.0), terrace = Vector3(0.3, 0.3, 0.6), gully = Vector3(0.4, 2.0, 5.0)},
	mountain = {title = "Гора", fall = Vector2(70.0, 140.0), terrace = Vector3(0.35, 0.3, 0.6), gully = Vector3(0.4, 3.0, 7.0)},
	steep = {title = "Крутая гора", fall = Vector2(130.0, 230.0), terrace = Vector3(0.25, 0.2, 0.45), gully = Vector3(0.3, 4.0, 9.0)},
	plateau = {title = "Плато с уступами", fall = Vector2(50.0, 120.0), terrace = Vector3(1.0, 0.65, 0.9), gully = Vector3(0.25, 2.0, 5.0)},
	ridges = {title = "Хребты и овраги", fall = Vector2(50.0, 130.0), terrace = Vector3(0.15, 0.3, 0.5), gully = Vector3(1.0, 6.0, 12.0)},
}
const ORDER := ["hills", "mountain", "steep", "plateau", "ridges"]
## Сетка окон-кандидатов (шаг в клетках) и выборка по каждому для оценки.
const PROBE := 8
const STEP := 64
const GRID := 14
const BASE := 12.0 # высота нижней точки окна, м (как у прочих земель лаборатории)

static var seed := 1
static var kind := "mountain"
static var cells := PackedFloat32Array()
static var info := {}  ## {fall, window, title, forms}: что выбрано
static var _key := ""
## v3: мир и окно. world_h — высота клеток мира, м; world_wet — море и озёра с отступом в клетку (русла рек — нет).
static var world_input: Resource
static var window_input: Resource
static var world_seed := 0
static var world_size := 0
static var world_h := PackedFloat32Array()
static var world_wet := PackedByteArray()
static var world_rivers := PackedByteArray()
static var world_info := {}
static var origin := Vector2i.ZERO ## угол окна в клетках мира (v3)
static var window_mode := false
static var _base_cells := PackedFloat32Array() ## окно до врезок
static var _wet_cells := PackedByteArray()
static var _river_cells := PackedByteArray()
static var cuts: Array = [] ## врезки окна: {points, depth (по точкам), half — полудно, wall — заложение стенок}


## Сгенерировать местность для (seed_value, kind_name); повторный вызов с теми же значениями — из памяти.
static func generate(seed_value: int, kind_name: String) -> void:
	var key := "%d|%s" % [seed_value, kind_name]
	if key == _key and not cells.is_empty(): return
	window_mode = false
	cuts = []
	var started := Time.get_ticks_usec()
	seed = seed_value
	kind = kind_name if KINDS.has(kind_name) else "mountain"
	var spec: Dictionary = KINDS[kind]
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("trail_lab_terrain|%d|%s" % [seed, kind])
	var w := WorldData.new()
	w.W = 16
	w.H = 16
	w.N = w.W * w.H
	w.seed_text = "Trail Lab #%d" % seed
	w.seed_num = WGRandom.hash_string(w.seed_text)
	for name: String in WorldGenerator.NOISE_SLOTS: w.noise[name] = Simplex.new(WorldGenerator.noise_rng(w.seed_num, name))
	StageRelief.run(w) # горы мира и сдвиг стартовой области, как в игре
	var want: Vector2 = spec.fall
	var n := w.noise
	# окна-кандидаты: годные (перепад характера с запасом, без воды) — и случайное из них; иначе ближайшее по перепаду
	var good: Array[Vector2i] = []
	var best := Vector2i.ZERO
	var best_score := INF
	for cy in GRID:
		for cx in GRID:
			var x0 := (cx - GRID / 2) * STEP
			var y0 := (cy - GRID / 2) * STEP
			var lo := INF
			var hi := -INF
			for sj in PROBE:
				for si in PROBE:
					var sx := x0 + (si + 0.5) * CELLS / float(PROBE)
					var sy := y0 + (sj + 0.5) * CELLS / float(PROBE)
					var raw := StageRelief.raw_at(n.warpX, n.warpY, n.cont, n.mask, n.ridge, n.hill, sx, sy, w.macro_x, w.macro_y, w.mountain_scale, w.mountain_bias, w.mountain_height, w.foothill_spread)
					var m := StageRelief.normalize(raw) * GameConfig.HS
					lo = minf(lo, m)
					hi = maxf(hi, m)
			var fall := hi - lo
			if lo < 3.0: continue # вода
			if fall >= want.x * 0.85 and fall <= want.y * 1.15: good.append(Vector2i(x0, y0))
			var score := absf(fall - (want.x + want.y) * 0.5)
			if score < best_score:
				best_score = score
				best = Vector2i(x0, y0)
	if not good.is_empty(): best = good[rng.randi() % good.size()]
	var raw_cells := StageRelief.raw_rect(w, best.x, best.y, CELLS, CELLS, true)
	var micro := Parallel.fbm_rect(n.micro, best.x, best.y, CELLS, CELLS, 9.0, 2)
	var base := PackedFloat32Array()
	base.resize(CELLS * CELLS)
	for i in base.size(): base[i] = StageRelief.add_micro(StageRelief.normalize(raw_cells[i]), micro[i]) * GameConfig.HS
	# поворот и отражение
	var turns := rng.randi() % 4
	var mirror := rng.randf() < 0.5
	var out := PackedFloat32Array()
	out.resize(base.size())
	for z in CELLS:
		for x in CELLS:
			var sx := CELLS - 1 - x if mirror else x
			var sz := z
			for t in turns:
				var k := sx
				sx = CELLS - 1 - sz
				sz = k
			out[z * CELLS + x] = base[sz * CELLS + sx]
	var low := INF
	var high := -INF
	for v in out:
		low = minf(low, v)
		high = maxf(high, v)
	for i in out.size(): out[i] -= low
	var forms := PackedStringArray()
	# овраги: ребристый шум |n| < ширины — V-образная ложбина
	var g: Vector3 = spec.gully
	if rng.randf() < g.x:
		var depth := rng.randf_range(g.y, g.z)
		var scale := rng.randf_range(90.0, 170.0) # м между оврагами
		var noise := Simplex.new(WorldGenerator.noise_rng(w.seed_num + 77, "ridge"))
		for z in CELLS:
			for x in CELLS:
				var v := absf(noise.noise(x * GameConfig.TILE / scale, z * GameConfig.TILE / scale))
				out[z * CELLS + x] -= depth * pow(1.0 - smoothstep(0.0, 0.16, v), 1.5)
		forms.append("овраги до %.0f м" % depth)
	# уступы: полки шага step, подъём между ними на доле RISER высоты шага; strength — сколько от полки
	var tr: Vector3 = spec.terrace
	if rng.randf() < tr.x:
		var span := high - low
		var step := clampf(span / rng.randf_range(4.0, 8.0), 6.0, 30.0)
		var strength := rng.randf_range(tr.y, tr.z)
		for i in out.size():
			var h := out[i] / step
			var shelf := (floorf(h) + smoothstep(1.0 - RISER, 1.0, h - floorf(h))) * step
			out[i] = lerpf(out[i], shelf, strength)
		forms.append("уступы через %.0f м (%.0f %%)" % [step, strength * 100.0])
	low = INF
	high = -INF
	for v in out:
		low = minf(low, v)
		high = maxf(high, v)
	for i in out.size(): out[i] = out[i] - low + BASE
	cells = out
	_base_cells = out.duplicate()
	_key = key
	info = {fall = snappedf(high - low, 0.1), window = best, title = spec.title, forms = forms, turns = turns, mirror = mirror,
		candidates = good.size(), ms = (Time.get_ticks_usec() - started) / 1000.0}

## Доля шага уступа, на которой поднимается его стенка (остальное — полка).
const RISER := 0.35

## v3: мир размером с план игры по сиду (долго: география игры целиком; можно в потоке — пишет только свои поля).
static func generate_world(seed_value: int) -> void:
	if seed_value == world_seed and not world_h.is_empty(): return
	publish_world(prepare_world(seed_value))

## Worker-safe: returns owned data and never publishes into the active lab session.
static func prepare_world(seed_value: int, existing := {}) -> Dictionary:
	var started := Time.get_ticks_usec()
	if existing.get("seed", -1) == seed_value and not existing.get("heights", PackedFloat32Array()).is_empty(): return existing.duplicate(true)
	var cached := _read_world(seed_value)
	if not cached.is_empty():
		cached.info = {ms = (Time.get_ticks_usec() - started) / 1000.0, cached = true}
		return cached
	var w := WorldGenerator.geography("Trail Lab #%d" % seed_value)
	var h := PackedFloat32Array()
	h.resize(w.N)
	var wet := PackedByteArray()
	wet.resize(w.N)
	var ocean := w.ocean
	var lake := w.lake
	var source := w.h
	for i in w.N:
		h[i] = source[i] * GameConfig.HS
		# море и озёра; русла рек — врезанные в рельеф ложбины (в лаборатории вода не рисуется), их трасса пересекает
		if ocean[i] != 0 or lake[i] != 0 or source[i] <= 0.0: wet[i] = 1
	# отступ в клетку от воды
	var grown := wet.duplicate()
	for z in range(1, w.H - 1):
		for x in range(1, w.W - 1):
			var i := z * w.W + x
			if wet[i] == 0 and (wet[i - 1] != 0 or wet[i + 1] != 0 or wet[i - w.W] != 0 or wet[i + w.W] != 0): grown[i] = 1
	return {heights = h, water = grown, rivers = w.river_cells().duplicate(), size = w.W, seed = seed_value,
		info = {ms = (Time.get_ticks_usec() - started) / 1000.0, stages = w.generation_profile.get("stages_ms", {})}}

static func world_snapshot() -> Dictionary:
	return {input = world_input, heights = world_h.duplicate(), water = world_wet.duplicate(), rivers = world_rivers.duplicate(), size = world_size, seed = world_seed, info = world_info.duplicate(true)}

static func publish_world(data: Dictionary) -> void:
	world_input = data.get("input")
	world_h = data.heights.duplicate()
	world_wet = data.water.duplicate()
	world_rivers = data.get("rivers", PackedByteArray()).duplicate()
	world_rivers.resize(world_h.size())
	world_size = data.size
	world_seed = data.seed
	world_info = data.get("info", {}).duplicate(true)
	if world_input == null and not world_info.get("cached", false): _save_world()

## Кэш мира на диске по сиду: высоты и вода (повторный выбор того же мира — без географии). Версия формата — в имени.
const CACHE := "user://trail_lab_worlds/v3_%d.bin" # v2 did not retain rivers; never import it as game water data
static func _save_world() -> void:
	DirAccess.make_dir_recursive_absolute("user://trail_lab_worlds")
	var f := FileAccess.open(CACHE % world_seed, FileAccess.WRITE)
	if f == null: return
	f.store_32(world_size)
	f.store_buffer(world_h.to_byte_array())
	f.store_buffer(world_wet)
	f.store_buffer(world_rivers)
	f.close()

static func _read_world(seed_value: int) -> Dictionary:
	if not FileAccess.file_exists(CACHE % seed_value): return {}
	var f := FileAccess.open(CACHE % seed_value, FileAccess.READ)
	if f == null: return {}
	var n := f.get_32()
	if n != WorldGenerator.PLAN_SIZE:
		f.close()
		return {}
	var h := f.get_buffer(n * n * 4).to_float32_array()
	var wet := f.get_buffer(n * n)
	var rivers := f.get_buffer(n * n)
	f.close()
	if h.size() != n * n or wet.size() != n * n or rivers.size() != n * n: return {}
	return {heights = h, water = wet, rivers = rivers, size = n, seed = seed_value, info = {cached = true}}

## v3: окно CELLS × CELLS с углом at (клетки мира) — земля лаборатории. Врезки сбрасываются.
static func use_window(at: Vector2i) -> void:
	origin = Vector2i(clampi(at.x, 0, world_size - CELLS), clampi(at.y, 0, world_size - CELLS))
	var out := PackedFloat32Array()
	out.resize(CELLS * CELLS)
	var wet := PackedByteArray()
	wet.resize(CELLS * CELLS)
	var rivers := PackedByteArray()
	rivers.resize(CELLS * CELLS)
	var low := INF
	var high := -INF
	for z in CELLS:
		for x in CELLS:
			var i := (origin.y + z) * world_size + origin.x + x
			out[z * CELLS + x] = world_h[i]
			wet[z * CELLS + x] = world_wet[i]
			if world_rivers.size() == world_h.size(): rivers[z * CELLS + x] = world_rivers[i]
			low = minf(low, world_h[i])
			high = maxf(high, world_h[i])
	window_input = null
	if world_input != null:
		window_input = preload("res://scripts/lab/trail_lab_game_source.gd").window(world_input, origin, CELLS)
	else:
		for i in out.size(): out[i] = out[i] - low + BASE
	_base_cells = out
	_wet_cells = wet
	_river_cells = rivers
	cells = out.duplicate()
	cuts = []
	window_mode = true
	seed = world_seed
	_key = "window|%d|%d|%d" % [world_seed, origin.x, origin.y]
	info = {fall = snappedf(high - low, 0.1), title = "Мир", forms = PackedStringArray(["окно %d, %d" % [origin.x, origin.y]])}

## Вода в окне (v3): точка у воды — сюда трасса не идёт (в лаборатории вода не рисуется).
static func wet_at(at: Vector2) -> bool:
	if not window_mode: return false
	var x := clampi(floori(at.x / GameConfig.TILE), 0, CELLS - 1)
	var z := clampi(floori(at.y / GameConfig.TILE), 0, CELLS - 1)
	return _wet_cells[z * CELLS + x] != 0

## Врезки в землю окна (v3): каждая — ось points (м окна), глубина у каждой точки depth, полудно half, заложение стенок
## wall (м по горизонтали на метр глубины). Земля опускается до дна у оси и стенками к краям; врезки не складываются —
## берётся самая глубокая. Применяются к окну заново (прежние врезки снимаются).
static func apply_cuts(list: Array) -> void:
	cuts = list
	var out := _base_cells.duplicate() if not _base_cells.is_empty() else cells.duplicate()
	if out.is_empty(): return
	var dig := PackedFloat32Array()
	dig.resize(out.size())
	for c: Dictionary in list:
		var pts: PackedVector2Array = c.points
		var depths: PackedFloat32Array = c.depth
		var deepest := 0.0
		for v in depths: deepest = maxf(deepest, v)
		var far := float(c.half) + deepest * float(c.wall) + GameConfig.TILE
		var lo := Vector2(INF, INF)
		var hi := -lo
		for q in pts:
			lo = lo.min(q)
			hi = hi.max(q)
		var x0 := clampi(floori((lo.x - far) / GameConfig.TILE), 0, CELLS - 1)
		var x1 := clampi(ceili((hi.x + far) / GameConfig.TILE), 0, CELLS - 1)
		var z0 := clampi(floori((lo.y - far) / GameConfig.TILE), 0, CELLS - 1)
		var z1 := clampi(ceili((hi.y + far) / GameConfig.TILE), 0, CELLS - 1)
		for z in range(z0, z1 + 1):
			for x in range(x0, x1 + 1):
				var at := Vector2(x + 0.5, z + 0.5) * GameConfig.TILE
				for k in range(1, pts.size()):
					var a := pts[k - 1]
					var ab := pts[k] - a
					var t := clampf((at - a).dot(ab) / maxf(ab.length_squared(), 0.0001), 0.0, 1.0)
					var depth := lerpf(depths[k - 1], depths[k], t)
					if depth <= 0.0: continue
					var dist := at.distance_to(a + ab * t)
					var reach := float(c.half) + depth * float(c.wall) + GameConfig.TILE * 0.5
					if dist >= reach: continue
					var i := z * CELLS + x
					dig[i] = maxf(dig[i], depth * (1.0 - smoothstep(float(c.half), reach, dist)))
	for i in out.size(): out[i] -= dig[i]
	cells = out

## Высота земли, м (билинейно по центрам клеток, как прочие земли Fixture).
static func ground(at: Vector2) -> float:
	if cells.is_empty(): generate(seed, kind)
	var fx := clampf(at.x / GameConfig.TILE - 0.5, 0.0, CELLS - 1.0)
	var fz := clampf(at.y / GameConfig.TILE - 0.5, 0.0, CELLS - 1.0)
	var ix := mini(floori(fx), CELLS - 2)
	var iz := mini(floori(fz), CELLS - 2)
	var a := lerpf(cells[iz * CELLS + ix], cells[iz * CELLS + ix + 1], fx - ix)
	var b := lerpf(cells[(iz + 1) * CELLS + ix], cells[(iz + 1) * CELLS + ix + 1], fx - ix)
	return lerpf(a, b, fz - iz)

## Строка для подписи: характер, сид, перепад.
static func label() -> String:
	if info.is_empty(): return ""
	var forms: PackedStringArray = info.get("forms", PackedStringArray())
	return "%s · сид %d · перепад %.0f м%s" % [info.title, seed, info.fall, (" · " + ", ".join(forms)) if not forms.is_empty() else ""]
