extends SceneTree
## Снимок-эталон дорожных вычислений (16.11.2026): хеши результата RoadBed и RoadRefinement без генерации мира (секунды).
## Нужен, чтобы переносить дорожный код и перестраивать его, не меняя результат: любая правка, после которой хеши
## расходятся, меняет мир. Эталон пишется один раз на проверенном коде; пересъёмка — только осознанно (поведение изменили),
## в том же коммите, с объяснением (docs/ROADS_CSHARP.md).
##   godot --headless --path . --script res://tools/road_golden.gd -- [--save] [--reference]
## Без ключа сверяет с tools/control/golden/roads.txt и печатает «ROAD GOLDEN RESULT n failures»; код 1 при расхождении.
## Случаи (префикс ключа): whole/part — стенд road_relief_fixture, полная и частичная сборка; switchback — тесный серпантин;
## slope — косой склон (дорога, тропа, горная тропа, трасса без земляных работ и с ними, дубль и параллельная линия);
## shelf — полка горной тропы; prepared — подготовленные трассы; fork — развилки 14° и меньше; section — сечения по ширине,
## мост, брод, скала; edge — пути до всех краёв карты; width — переменная ширина; settle — горная тропа у поселения;
## overlap — параллельные полотна дороги и тропы; lab — стенд Trail Lab (вода, сооружения, сдвиг начала, виды и покрытия вперемешку,
## частичные сборки, полотно RoadBed поверх готовых патчей: все, один путь, заморозка).
## --reference — те же случаи на исходном GDScript (пока он есть): расходится только .corridor у путей с земляными работами —
## C# хранит для них нулевые строки в общем массиве, GDScript не хранит (доступ по corridor_routes, на результат не влияет). Лимит 120 с.
const Fixture := preload("res://tools/road_relief_fixture.gd")
const LabFixture := preload("res://scripts/lab/trail_lab_fixture.gd")
const Topology := preload("res://scripts/world/road_topology.gd")
const Section := preload("res://scripts/world/road_section.gd")
const FILE := "res://tools/control/golden/roads.txt"
var lines := {}


class SectionGround extends Heightfield:
	func ground_at(x: float, z: float, _raw := false) -> float:
		return 20.0 + 0.42 * (z - 162.0) if x >= 136.0 and x <= 180.0 and absf(z - 162.0) < 5.0 else 20.0

	func depth_at(x: float, z: float, _feet := -INF) -> float:
		return 0.18 if absf(z - 242.0) < 3.0 and absf(x - 154.0) < 1.0 else 0.0


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	run.call_deferred()


func run() -> void:
	var args := OS.get_cmdline_user_args()
	var save := "--save" in args
	if "--reference" in args:
		# исходный GDScript вместо C# (сверка эталона с прежней реализацией, пока она есть)
		RoadBed.allow_fast = false
		RoadRefinement.allow_fast_index = false
		RoadRefinement.allow_fast_patches = false
		RoadRefinement.allow_fast_nearest = false
		RoadRefinement.allow_fast_vertices = false
		RoadRefinement.restrict_local_index = false
	if Grid.fast_grid() == null:
		print("ROAD GOLDEN: нужен C# (dotnet build), без него эталон не снять и не сверить")
		quit(1)
		return
	_stand()
	_slope()
	_switchback()
	_shelf()
	_prepared()
	_fork()
	_section()
	_audit_cases()
	_lab()
	_finish(FILE, save)


func _finish(file: String, save: bool) -> void:
	if save:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(file.get_base_dir()))
		var out := FileAccess.open(file, FileAccess.WRITE)
		for key: String in _sorted(lines.keys()):
			out.store_line("%s %s" % [key, lines[key]])
		out.close()
		print("ROAD GOLDEN: записано %d хешей в %s" % [lines.size(), file])
		quit(0)
		return
	var saved := {}
	if FileAccess.file_exists(file):
		for row in FileAccess.get_file_as_string(file).split("\n", false):
			var pair := row.split(" ")
			if pair.size() == 2: saved[pair[0]] = pair[1]
	var failures := 0
	if saved.is_empty():
		print("FAIL эталона нет: %s (снять: -- --save)" % file)
		failures += 1
	for key: String in _sorted(lines.keys()):
		var same: bool = saved.get(key, "") == lines[key]
		print("PASS " if same else "FAIL ", key)
		failures += int(not same)
	for key: String in saved:
		if not lines.has(key):
			print("FAIL в эталоне лишний ключ ", key)
			failures += 1
	print("ROAD GOLDEN RESULT %d failures" % failures)
	quit(1 if failures else 0)


# ── сборки ────────────────────────────────────────────────────────────────────────────────────────────────

## Полотно RoadBed (если bed), сооружения и метровая сетка на мире; возвращает рельеф для частичных сборок.
## prepare(h) — правка рельефа до полотна (косой склон, перепад).
func _full(label: String, w: WorldData, bed := true, fit := true, prepare := Callable()) -> Heightfield:
	var h := Heightfield.new(w, false)
	h.road_refinement = null
	if prepare.is_valid(): prepare.call(h)
	if bed:
		RoadBed.refine(h)
		lines[label + ".bed_hv"] = _hash(h.hv)
	h.build_structures()
	_refinement(label, RoadRefinement.build(h, fit))
	return h


## Частичная сборка путей only на готовом рельефе
func _only(label: String, h: Heightfield, only: Dictionary) -> void:
	_refinement(label, RoadRefinement.build(h, true, only))


func _stand() -> void:
	var w := Fixture.world()
	var h := Heightfield.new(w, false)
	h.road_refinement = null
	RoadBed.refine(h)
	h.build_structures()
	lines["whole.bed_hv"] = _hash(h.hv)
	var whole := RoadRefinement.build(h)
	_refinement("whole", whole)
	h.road_refinement = whole
	# Частичная пересборка нового пути на готовой сетке: полотно и сетка только вокруг пути 0
	var part := Heightfield.new(w, false)
	RoadBed.refine(part)
	part.build_structures()
	part.road_refinement = whole
	var frozen := PackedByteArray()
	frozen.resize(w.N)
	for i in w.N:
		frozen[i] = 1 if i % 97 < 9 else 0
	RoadBed.refine(part, {0: true}, frozen)
	lines["part.bed_hv"] = _hash(part.hv)
	_refinement("part", RoadRefinement.build(part, true, {0: true}))
	# Та же сетка без подгонки профиля (fit_road = false)
	_refinement("whole_nofit", RoadRefinement.build(h, false))


## Косой склон: дорога, тропа и горная тропа с полкой и формами; трасса без земляных работ и с ними; дубль и параллельная линия
func _slope() -> void:
	var w := Fixture.world()
	for z in w.H:
		for x in w.W: w.h[z * w.W + x] += (z + 0.5) * GameConfig.TILE * 0.12 / GameConfig.HS
	var slope_h := _full("slope.lanes", w)
	_only("slope.lanes_local", slope_h, {1: true})
	_only("slope.lanes_local2", slope_h, {0: true, 2: true})
	# одна горная тропа без подгонки профиля, без RoadBed (как стенд формы коридора)
	var m := Fixture.world()
	m.trails = [m.trails[2]]
	m.trails[0].kind = "mountain"
	for z in m.H:
		for x in m.W: m.h[z * m.W + x] += (z + 0.5) * GameConfig.TILE * 0.12 / GameConfig.HS
	var h := _full("slope.mountain", m, false)
	m.trails[0].trail_id = "natural"
	m.trails[0].formation = Vector3.ZERO
	_refinement("slope.natural", RoadRefinement.build(h))
	_only("slope.natural_local", h, {0: true})
	m.trails[0].formation = Vector3(1.0, 0.0, 0.0)
	_only("slope.authored_local", h, {0: true})
	_refinement("slope.authored", RoadRefinement.build(h))
	m.trails[0].erase("trail_id")
	m.trails[0].erase("formation")
	# дубль в обратную сторону (сеть его не публикует, но запись остаётся допустимой) и параллельная линия на 6 м
	var duplicate: Dictionary = m.trails[0].duplicate(true)
	duplicate.pts.reverse()
	duplicate.surf.reverse()
	m.trails.append(duplicate)
	_refinement("slope.duplicate", RoadRefinement.build(h))
	var parallel: Dictionary = m.trails[0].duplicate(true)
	for point: Dictionary in parallel.pts: point.y += 1.5
	m.trails[1] = parallel
	_refinement("slope.parallel", RoadRefinement.build(h))
	_only("slope.parallel_local", h, {1: true})


func _switchback() -> void:
	var w := Fixture.world()
	var pts := StageTrails._road_stations([
		{x = 15.5, y = 30.5, w = 0.75}, {x = 55.5, y = 30.5, w = 0.75},
		{x = 55.5, y = 31.5, w = 0.75}, {x = 15.5, y = 31.5, w = 0.75}])
	var surf := PackedByteArray()
	surf.resize(pts.size())
	surf.fill(RoadSurface.GRAVEL)
	w.trails = [{kind = "road", pts = pts, surf = surf}]
	_full("switchback.raw", w, false)
	_full("switchback.bed", w)
	# серпантин из трёх колен горной тропой и тропой
	for kind: String in ["trail", "mountain"]:
		w.trails[0].kind = kind
		_full("switchback." + kind, w)


func _shelf() -> void:
	var w := Fixture.world()
	w.trails = [w.trails[2]]
	w.trails[0].kind = "mountain"
	for z in w.H:
		for x in w.W: w.h[z * w.W + x] += (z + 0.5) * GameConfig.TILE * 0.6 / GameConfig.HS
	_full("shelf.raw", w, false)
	_full("shelf.bed", w)


## Подготовленные трассы: с земляными работами (рельеф пути ведёт TrailShaping, форм нет), без них (слабее, без продавленных мест)
func _prepared() -> void:
	var w := Fixture.world()
	for route: Dictionary in w.trails:
		route.trail_id = "prepared"
		route.formation = Vector3(1.0, 0.0, 0.0)
	var h := _full("prepared.shaped", w)
	_only("prepared.shaped_local", h, {0: true})
	for route: Dictionary in w.trails: route.formation = Vector3.ZERO
	h = _full("prepared.natural", w)
	_only("prepared.natural_local", h, {0: true})
	_only("prepared.natural_local2", h, {1: true, 2: true})


## Развилка: тропа отходит от дороги под малым углом (старая маска защищала только углы больше 26°)
func _fork() -> void:
	for dz in [5.0, 20.0, 60.0]:
		var w := Fixture.world()
		w.trails = [w.trails[1]]
		w.trails.append({kind = "trail", pts = [{x = 40.0, y = 48.5, w = 0.55}, {x = 60.0, y = 48.5 + dz, w = 0.55}], surf = PackedByteArray([RoadSurface.FOREST, RoadSurface.FOREST])})
		var h := _full("fork.%d" % int(dz), w)
		_only("fork.%d_local" % int(dz), h, {1: true})


## Сечения по ширине: сужение у моста и брода, полка в склоне, скала, путь с авторской шириной; сужающийся участок
func _section() -> void:
	var w := Fixture.world()
	var trail := _section_line("trail", 6, 20, 40.5)
	var road := _section_line("road", 20, 76, 40.5)
	var through_fork := Topology.section("trail",
		[{x = 40.5, y = 40.5, w = 0.55}, {x = 40.5, y = 44.5, w = 0.55}], Vector2i.ZERO)
	var ford := _section_line("trail", 22, 60, 60.5)
	var authored := _section_line("trail", 22, 60, 70.5)
	authored.trail_id = "authored-width"
	authored.pts[0].w = 0.36
	w.trails = [trail, road, through_fork, ford, authored]
	w.bridges = [BridgeData.new(40 * w.W + 56, 40 * w.W + 64)]
	for x in range(46, 50): w.biome[60 * w.W + x] = Biomes.ROCK
	StageTrails._fit_sections(w, SectionGround.new(w, false))
	lines["section.widths"] = _hash(w.trails)
	# покрытие по станциям: дорога — гравий, тропа — лес, брод — грунтовка, с переходом посередине
	for route: Dictionary in w.trails:
		var covering := PackedByteArray()
		var size: int = route.pts.size()
		for n in size:
			covering.append(RoadSurface.GRAVEL if route.kind == "road" else (RoadSurface.FOREST if n < size / 2 else RoadSurface.DIRT))
		route.surf = covering
	var h := _full("section.bridge", w)
	_only("section.bridge_local", h, {1: true})
	_only("section.bridge_local2", h, {3: true, 4: true})
	# туннель на том же стенде
	w.bridges = []
	w.tunnels = [TunnelData.new(40 * w.W + 56, 40 * w.W + 64)]
	_full("section.tunnel", w)
	w.tunnels = []
	var varying := {kind = "road", pts = [{x = 10.5, y = 16.72, w = 1.2}, {x = 58.5, y = 16.72, w = 0.48}],
		surf = PackedByteArray([RoadSurface.GRAVEL, RoadSurface.GRAVEL])}
	var v := Fixture.world()
	v.trails = [varying]
	_full("section.varying", v)


func _section_line(kind: String, x0: int, x1: int, z: float) -> Dictionary:
	var points: Array = []
	for x in range(x0, x1 + 1):
		points.append({x = x + 0.5, y = z, w = Section.WIDTHS[kind]})
	return Topology.section(kind, points, Vector2i.ZERO)


# ── стенды road_surface_audit_test ───────────────────────────────────────────────────────────────────────

func _audit_world() -> WorldData:
	var w := WorldData.new()
	w.W = 64
	w.H = 64
	w.N = w.W * w.H
	w.seed_num = 44
	for key: String in ["h", "filled", "slope", "dist_water", "temp", "moist", "elev"]:
		var a := PackedFloat32Array()
		a.resize(w.N)
		w.set(key, a)
	w.dist_water.fill(100.0)
	for key: String in ["ocean", "lake", "river", "path_mask", "biome"]:
		var a := PackedByteArray()
		a.resize(w.N)
		w.set(key, a)
	w.biome.fill(Biomes.GRASS)
	for y in w.H:
		for x in w.W: w.h[y * w.W + x] = (40.0 + y * 0.8 + sin(x * 0.5) * 1.5) / GameConfig.HS
	return w


func _route(a: Vector2, b: Vector2, kind := "road", width_a := 0.9, width_b := 0.9) -> Dictionary:
	return {kind = kind, pts = [{x = a.x, y = a.y, w = width_a}, {x = b.x, y = b.y, w = width_b}], surf = PackedByteArray([1, 1])}


func _audit_cases() -> void:
	# пути доходят до всех четырёх краёв карты
	var w := _audit_world()
	w.trails = [_route(Vector2(0.5, 32.5), Vector2(63.5, 32.5)), _route(Vector2(32.5, 0.5), Vector2(32.5, 63.5))]
	_full("edge.cross", w, false)
	_full("edge.cross_bed", w)
	# переменная ширина при равномерном поперечном уклоне: срез зависит только от ширины станции
	w = _audit_world()
	w.trails = [_route(Vector2(8.5, 32.5), Vector2(55.5, 32.5), "road", 0.2, 2.5)]
	_full("width.bed", w)
	_full("width.slope", w, false, true, func(h: Heightfield) -> void:
		for y in w.H:
			for x in w.W: h.hv[y * w.W + x] = 40.0 + y * 3.2)
	# горная тропа у поселения: основа не меняется в защищённой зоне
	w = _audit_world()
	w.trails = [_route(Vector2(8.5, 32.5), Vector2(55.5, 32.5), "mountain", 0.42, 0.42)]
	w.settlements.append(SettlementData.from_dict({x = 32.5, y = 32.5, i = 32 * w.W + 32, huts = []}))
	_full("settle.mountain", w, false)
	# параллельные полотна дороги и тропы разной ширины на разном расстоянии (смена ближайшего пути)
	for gap in [2.0, 4.0, 8.0]:
		w = _audit_world()
		w.trails = [_route(Vector2(8.5, 31.5), Vector2(55.5, 31.5), "road", 0.9, 0.9),
			_route(Vector2(8.5, 31.5 + gap / 4.0), Vector2(55.5, 31.5 + gap / 4.0), "trail", 0.55, 0.55)]
		_full("overlap.%d" % int(gap), w, false)


# ── стенд Trail Lab (road_native_test) ─────────────────────────────────────────────────────────────────

func _lab() -> void:
	var prepared := LabFixture.prepare(LabFixture.definitions())
	if not prepared.errors.is_empty():
		push_error("road_golden: стенд Trail Lab не собрался: " + str(prepared.errors))
		lines["lab.error"] = _hash(str(prepared.errors))
		return
	var h: Heightfield = prepared.heights
	for i in h.world.N:
		h.hv[i] = 40.0 + (i % h.world.W) * 0.4 + sin(i * 0.03) * 2
		if i % 43 == 0: h.water_level[i] = h.hv[i] - 1
	h.world.world_origin = Vector2i(-71, 123)
	h.structures = [{ax = 40.0, az = 70.0, bx = 120.0, bz = 150.0}]
	for k in h.world.trails.size():
		var route: Dictionary = h.world.trails[k]
		route.kind = ["road", "trail", "mountain"][k % 3]
		for j in route.surf.size(): route.surf[j] = j % 7 + 1
	_refinement("lab.fit", RoadRefinement.build(h, true))
	_refinement("lab.nofit", RoadRefinement.build(h, false))
	_only("lab.local", h, {0: true})
	_only("lab.local12", h, {1: true, 2: true})
	var frozen := PackedByteArray()
	frozen.resize(h.world.N)
	for i in h.world.N:
		frozen[i] = 1 if (i % 97) < 9 else 0
	var cases := [["all", {}, PackedByteArray()], ["one", {0: true}, PackedByteArray()],
		["two_frozen", {1: true, 2: true}, frozen], ["all_frozen", {}, frozen]]
	for c: Array in cases:
		var copy := h.copy()
		copy.road_refinement = h.road_refinement
		var changed := RoadBed.refine(copy, c[1], c[2])
		lines["lab.bed_%s.hv" % c[0]] = _hash(copy.hv)
		lines["lab.bed_%s.changed" % c[0]] = _hash(changed)
	var bare := h.copy()
	RoadBed.refine(bare)
	lines["lab.bed_bare.hv"] = _hash(bare.hv)


# ── хеши ──────────────────────────────────────────────────────────────────────────────────────────────

## Профиль подгонки, формы коридора и метровые патчи — по отдельному хешу: видно, что именно разошлось
func _refinement(label: String, r: RoadRefinement) -> void:
	var fit := HashingContext.new()
	fit.start(HashingContext.HASH_SHA256)
	for route: int in _sorted(r.fit_routes.keys()):
		var f: Dictionary = r.fit_routes[route]
		for field: String in ["points", "profile", "strength", "limit"]:
			fit.update(var_to_bytes(f[field]))
		fit.update(var_to_bytes(route))
	lines[label + ".fit"] = fit.finish().hex_encode()
	var corridor := HashingContext.new()
	corridor.start(HashingContext.HASH_SHA256)
	corridor.update(var_to_bytes(r.corridor))
	for route: int in _sorted(r.corridor_routes.keys()):
		corridor.update(var_to_bytes([route, r.corridor_routes[route]]))
	lines[label + ".corridor"] = corridor.finish().hex_encode()
	var patches := HashingContext.new()
	patches.start(HashingContext.HASH_SHA256)
	for key: int in _sorted(r.patches.keys()):
		patches.update(var_to_bytes(key))
		var patch: Dictionary = r.patches[key]
		for field: String in _sorted(patch.keys()):
			patches.update(var_to_bytes(patch[field]))
	lines[label + ".patches"] = patches.finish().hex_encode()
	lines[label + ".patch_count"] = str(r.patches.size())


func _hash(value: Variant) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(var_to_bytes(value))
	return ctx.finish().hex_encode()


func _sorted(values: Array) -> Array:
	var copy := values.duplicate()
	copy.sort()
	return copy
