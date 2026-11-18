class_name SettlementsBuilder
extends RefCounted
## Поселения и вершины в 3D: дома из каталога (.glb с 3 LOD и общим атласом), мелкие детали в MultiMesh,
## костры, туры с флажками, подписи. Старые процедурные дома сохранены под флагом use_legacy (для стенда «было»).

const TILE := GameConfig.TILE
const HS := GameConfig.HS
const FIRE_SEEN := 300.0  # м: дальше костры не рисуются и не анимируются
const HOMES := ["house", "house_timber", "chalet", "tall"]
## Облик жилых домов для запасного режима use_legacy (этап 1, «было» в village_look).
const HOUSE_FORM := {
	house = {floors = [[2.5, "plaster"]], gable = "timber", pitch = 0.62, eave = 0.55},
	house_timber = {floors = [[1.2, "stone"], [1.4, "timber"]], gable = "timber", pitch = 0.72, eave = 0.5},
	chalet = {floors = [[2.1, "stone"], [2.2, "timber"]], gable = "timber", pitch = 0.45, eave = 0.9, balcony = true},
	tall = {floors = [[2.4, "plaster"], [2.3, "plaster"]], gable = "plaster", pitch = 0.72, eave = 0.5},
}
const PEAK_STONES := [Vector2(0.9, 0.5), Vector2(0.65, 1.3), Vector2(0.45, 1.95)] # радиус, высота центра
const Catalog := preload("res://scripts/render/asset_catalog.gd")
const Courtyard := preload("res://scripts/render/settlement_courtyard.gd")

## false — модели каталога (glb, 3 LOD, общий атлас, MultiMesh деталей); true — прежние дома (только «было» на стенде).
static var use_legacy := false
static var shared_opaque_mat: StandardMaterial3D


## glow > 0 — светится сам (огонь, окна в режиме legacy)
static func mat(c: Color, glow: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 1.0
	if glow > 0.0:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = c * glow
	return m


static func _box_mesh(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b


static func _cone_mesh(r: float, h: float, seg: int) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = 0.0
	c.bottom_radius = r
	c.height = h
	c.radial_segments = seg
	c.rings = 0
	return c


## Узел с мешем и материалом (для костров); дома и туры собираются в общие меши через MeshBatch
static func _part(mesh: Mesh, offset: Vector3, material: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = offset
	mi.material_override = material
	# костёр мелкий, а пламя светится: тени от них не нужны
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visibility_range_end = FIRE_SEEN
	return mi


static func _label(text: String, color: Color, pos: Vector3, place_id: String = "") -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.modulate = color
	l.outline_modulate = Color(0, 0, 0, 0.7)
	l.font_size = 40
	l.outline_size = 10
	l.pixel_size = 0.0006
	l.fixed_size = true
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.position = pos
	l.set_meta("place_id", place_id)
	# Плавную дальность и перекрытия регулирует PlaceNames; движок отсекает всё за 450 м.
	l.visibility_range_end = 450.0
	return l


## Возвращает также фактические трансформы досок для наведения и доставки.
static func build(parent: Node3D, w: WorldData, heights: Heightfield, regional_paths: Array = []) -> Dictionary:
	var courtyards := Courtyard.new(w, heights, regional_paths)
	if use_legacy:
		return _build_legacy(parent, w, heights, courtyards)
	var catalog := Catalog.get_catalog()
	var mats := SettlementModels.make_materials(catalog.settlement_textures)
	var opaque_mat: StandardMaterial3D = mats.opaque
	shared_opaque_mat = opaque_mat
	var cutout_mat: StandardMaterial3D = mats.cutout
	var mat_pair := [opaque_mat, cutout_mat]
	var settlements_lib: Dictionary = catalog.settlements
	var details_lib: Dictionary = catalog.settlement_details
	var board_post := _uv_box(Vector3(0.12, 1.8, 0.12), SettlementModels.CELL_TIMBER)
	var board_panel := _uv_box(Vector3(1.8, 0.95, 0.13), SettlementModels.CELL_DARK_WOOD)
	var shelter_lantern := _uv_box(Vector3(0.24, 0.35, 0.20), SettlementModels.CELL_WINDOW)
	var extra_plinths := {}

	var flame_mesh := _cone_mesh(0.4, 1.1, 6)
	var core_mesh := _cone_mesh(0.22, 0.7, 6)
	var flame_m := mat(Color8(0xff, 0x8a, 0x2a), 2.2)
	var core_m := mat(Color8(0xff, 0xd3, 0x6b), 3.0)
	var fires: Array = []
	var boards: Array = []
	var rng := WGRandom.new(w.seed_num ^ 0x1234)
	var batch := MeshBatch.new()

	for s in w.settlements:
		var style: int = EntityCodec.value(s, "style", 0)
		var set_kind := SettlementSets.kind_of(w, s)
		for hut in s.huts:
			var kind: String = EntityCodec.value(hut, "t", "house")
			var model_id := kind if settlements_lib.has(kind) else "house"
			var entry: Dictionary = settlements_lib[model_id]
			var half: Vector2 = entry.get("half", SettlementSets.half_of(model_id))
			var at := Transform3D(Basis(Vector3.UP, PlayerState.hut_angle(s, hut)), Vector3(hut.x * TILE, 0, hut.y * TILE))
			var foot := footing(heights, at, half)
			at.origin.y = foot.y
			var drop := foot.y - foot.x
			var outbuilding: bool = entry.get("category", "home") != "home"
			var tints := SettlementModels.cell_tints(style, hut.v, outbuilding)
			var lods: Array = entry.lods
			for level in lods.size():
				batch.add_lod(lods[level], at, mat_pair, level, tints, true)
			_add_extra_plinth(batch, extra_plinths, model_id, half, at, drop, opaque_mat, tints, lods.size())
			_add_flower_details(batch, at, model_id, half, hut.v, details_lib, cutout_mat)
		var yard := courtyards.choose(s)
		_add_courtyard_details(batch, heights.world, heights, s, set_kind, details_lib, opaque_mat, rng)
		_add_settlement_label(parent, s, heights, yard)
		if yard.is_empty():
			continue
		if details_lib.has("lantern_post") and not s.huts.is_empty():
			_add_courtyard_lights(batch, heights, s, yard, courtyards, set_kind, details_lib.lantern_post, opaque_mat)
		for bench: Transform3D in yard.benches:
			batch.add_detail(details_lib.bench, bench, Color.html("#755337"), opaque_mat)
		var board: Transform3D = yard.board
		var face := _add_board_label(parent, board)
		boards.append({at = face, place = s})
		var board_tint := SettlementModels.cell_tints(style, 0, false)
		for side: float in [-0.7, 0.7]:
			batch.add_lod(board_post, board.translated_local(Vector3(side, 0.9, 0)), [opaque_mat], 0, board_tint, false)
			batch.add_lod(board_post, board.translated_local(Vector3(side, 0.9, 0)), [opaque_mat], 1, board_tint, false)
		batch.add_lod(board_panel, face, [opaque_mat], 0, board_tint, false)
		batch.add_lod(board_panel, face, [opaque_mat], 1, board_tint, false)

		if yard.fire.is_finite():
			batch.add_detail(details_lib.fire_logs, Transform3D(Basis.IDENTITY, yard.fire), Color8(0x3a, 0x2a, 0x1c), opaque_mat)
			fires.append(_add_fire(parent, yard.fire, s, rng.next_float() * 10.0, flame_mesh, flame_m, core_mesh, core_m))

	var site_lods: Dictionary = catalog.site_lods
	var legacy_m := {} if not site_lods.is_empty() else _legacy_site_materials(mat(Color8(0x3a, 0x2a, 0x1c)), opaque_mat)
	_build_peaks(parent, w, heights, batch, legacy_m, site_lods, opaque_mat)
	_build_sites(parent, w, heights, batch, legacy_m, {
		settlements = settlements_lib,
		details = details_lib,
		site_lods = site_lods,
		mat_pair = mat_pair,
		opaque = opaque_mat,
		cutout = cutout_mat,
		lantern = shelter_lantern,
		extra_plinths = extra_plinths,
	})
	for lk in w.lakes:
		var at := Vector2(lk.x * TILE, lk.y * TILE)
		parent.add_child(_label(lk.name, Color.html("#cfeaff"), Vector3(at.x, maxf(0.0, lk.level) * HS + 6.0, at.y), WorldData.place_id("lake", lk.x, lk.y)))
	_add_road_landmarks(batch, w, heights, details_lib, opaque_mat)
	var mi := batch.build("Buildings")
	if mi != null:
		parent.add_child(mi)
	return {fires = fires, windows = opaque_mat, boards = boards}


static func _add_settlement_label(parent: Node3D, s: SettlementData, heights: Heightfield, yard: Dictionary) -> void:
	var pos: Vector3
	if not yard.is_empty() and yard.fire.is_finite():
		pos = yard.fire
	elif not yard.is_empty():
		pos = yard.board.origin
	else:
		var at := Vector2(s.x, s.y) * TILE
		pos = Vector3(at.x, heights.ground_at(at.x, at.y), at.y)
	parent.add_child(_label(s.name, Color.html("#fff6d8"), pos + Vector3.UP * 9.0, WorldData.place_id("settlement", s.x, s.y)))


static func _add_board_label(parent: Node3D, board: Transform3D) -> Transform3D:
	var face := board.translated_local(Vector3.UP * Courtyard.BOARD_HEIGHT)
	var label := Label3D.new()
	label.text = "МАРШРУТЫ"
	label.font_size = 24
	label.pixel_size = 0.005
	label.visibility_range_end = 35.0
	label.transform = face.translated_local(Vector3(0, 0, 0.08))
	parent.add_child(label)
	return face


static func _add_fire(parent: Node3D, pos: Vector3, s: SettlementData, phase: float,
		flame_mesh: Mesh, flame_mat: Material, core_mesh: Mesh, core_mat: Material) -> Dictionary:
	var fire := Node3D.new()
	var flame := Node3D.new()
	flame.add_child(_part(flame_mesh, Vector3(0, 0.55, 0), flame_mat))
	var core := Node3D.new()
	core.add_child(_part(core_mesh, Vector3(0, 0.35, 0), core_mat))
	fire.add_child(flame)
	fire.add_child(core)
	fire.position = pos
	parent.add_child(fire)
	return {flame = flame, core = core, phase = phase, pos = pos, place = s}


static func _add_flower_details(batch: MeshBatch, at: Transform3D, model_id: String, half: Vector2, v: int, details_lib: Dictionary, cutout_mat: Material) -> void:
	var flower_mesh: Mesh = details_lib.flower_box if v % 2 == 0 else details_lib.flower_box_b
	match model_id:
		"house":
			for wx: float in [-half.x * 0.62, half.x * 0.62]:
				batch.add_detail(flower_mesh, at.translated_local(Vector3(wx, 0.90, half.y + 0.11)), Color.WHITE, cutout_mat)
		"house_wing":
			batch.add_detail(flower_mesh, at.translated_local(Vector3(half.x * 0.56, 0.87, half.y + 0.11)), Color.WHITE, cutout_mat)
			batch.add_detail(flower_mesh, at.translated_local(Vector3(half.x + 0.42, 0.75, 1.09)), Color.WHITE, cutout_mat)
		"house_steep":
			batch.add_detail(flower_mesh, at.translated_local(Vector3(0.68, 0.70, half.y + 0.11)), Color.WHITE, cutout_mat)
		"house_timber":
			batch.add_detail(flower_mesh, at.translated_local(Vector3(half.x * 0.56, 1.07, half.y + 0.11)), Color.WHITE, cutout_mat)
		"cabin_long":
			batch.add_detail(flower_mesh, at.translated_local(Vector3(0.65, 0.97, 0.95)), Color.WHITE, cutout_mat)
		"cabin_porch":
			batch.add_detail(flower_mesh, at.translated_local(Vector3(half.x * 0.58, 1.35, half.y + 0.11)), Color.WHITE, cutout_mat)
		"chalet":
			batch.add_detail(flower_mesh, at.translated_local(Vector3(half.x * 0.50, 0.83, half.y + 0.11)), Color.WHITE, cutout_mat)
			for bx: float in [-1.4, 0.0, 1.4]:
				batch.add_detail(flower_mesh, at.translated_local(Vector3(bx, 2.90, half.y + 0.98)), Color.WHITE, cutout_mat)
		"chalet_terrace":
			batch.add_detail(flower_mesh, at.translated_local(Vector3(half.x * 0.50, 0.83, half.y + 0.11)), Color.WHITE, cutout_mat)
			for wx: float in [-half.x * 0.48, half.x * 0.48]:
				batch.add_detail(flower_mesh, at.translated_local(Vector3(wx, 2.68, half.y + 0.11)), Color.WHITE, cutout_mat)
		"chalet_stone":
			for wx: float in [-half.x * 0.62, half.x * 0.62]:
				batch.add_detail(flower_mesh, at.translated_local(Vector3(wx, 0.80, half.y + 0.11)), Color.WHITE, cutout_mat)
			for bx: float in [-0.95, 0.95]:
				batch.add_detail(flower_mesh, at.translated_local(Vector3(bx, 2.92, half.y + 0.86)), Color.WHITE, cutout_mat)
		"tall":
			batch.add_detail(flower_mesh, at.translated_local(Vector3(half.x * 0.48, 0.90, half.y + 0.11)), Color.WHITE, cutout_mat)
			for wx: float in [-half.x * 0.48, half.x * 0.48]:
				batch.add_detail(flower_mesh, at.translated_local(Vector3(wx, 3.12, half.y + 0.11)), Color.WHITE, cutout_mat)
		"tall_mansard":
			for wx: float in [-half.x * 0.58, half.x * 0.58]:
				batch.add_detail(flower_mesh, at.translated_local(Vector3(wx, 0.85, half.y + 0.11)), Color.WHITE, cutout_mat)
			for wx: float in [-half.x * 0.48, half.x * 0.48]:
				batch.add_detail(flower_mesh, at.translated_local(Vector3(wx, 2.75, half.y + 0.11)), Color.WHITE, cutout_mat)
		"tall_hall":
			for wx: float in [-half.x * 0.65, 0.0, half.x * 0.65]:
				batch.add_detail(flower_mesh, at.translated_local(Vector3(wx, 2.89, half.y + 0.11)), Color.WHITE, cutout_mat)


static func _add_courtyard_lights(batch: MeshBatch, heights: Heightfield, s: SettlementData, yard: Dictionary,
		courtyards: Courtyard, set_kind: String, mesh: Mesh, material: Material) -> void:
	var board: Transform3D = yard.board
	var lamp := board.translated_local(Vector3(-1.45, 0.0, 0.0))
	lamp.origin.y = heights.ground_at(lamp.origin.x, lamp.origin.z)
	if heights.depth_at(lamp.origin.x, lamp.origin.z) <= 0.0:
		batch.add_detail(mesh, lamp, Color.WHITE, material)
	if not yard.fire.is_finite():
		return
	var center := Vector2(yard.fire.x, yard.fire.z)
	var remaining := 2 if set_kind == "center" else (1 if set_kind != "remote" and s.homes > 0 else 0)
	for k in 8:
		if remaining == 0:
			break
		var facing := Vector2.RIGHT.rotated(TAU * k / 8.0 + 0.35)
		var at := center - facing * 5.2
		if not heights.known(at.x, at.y) or not courtyards.road_clear(at, 0.4) or heights.depth_at(at.x, at.y) > 0.0:
			continue
		if _too_close_to_huts(at, s.huts, 2.0):
			continue
		var y := heights.ground_at(at.x, at.y)
		var pose := Transform3D(Basis(Vector3.UP, atan2(facing.x, facing.y)), Vector3(at.x, y, at.y))
		batch.add_detail(mesh, pose, Color.WHITE, material)
		remaining -= 1


static func _add_courtyard_details(batch: MeshBatch, w: WorldData, heights: Heightfield, s: SettlementData,
		set_kind: String, details_lib: Dictionary, opaque_mat: Material, rng: WGRandom) -> void:
	if details_lib.has("fence_section") and s.homes > 0 and set_kind in ["center", "ordinary", "foothill"]:
		var fence_col := Color.html("#7c5738")
		for hut: HutData in s.huts:
			var kind: String = EntityCodec.value(hut, "t", "house")
			if not SettlementSets.is_home(kind):
				continue
			if rng.next_float() > (0.55 if set_kind == "center" else 0.40):
				continue
			var half := SettlementSets.half_of(kind)
			var side: float = -1.0 if rng.next_float() < 0.5 else 1.0
			var at := Transform3D(Basis(Vector3.UP, PlayerState.hut_angle(s, hut)), Vector3(hut.x * TILE, 0, hut.y * TILE))
			var world_p := at * Vector3(side * (half.x + 1.15), 0.0, half.y * 0.35)
			var tile := w.tile_info(world_p.x / TILE, world_p.z / TILE)
			if tile.is_empty() or tile.path >= 2 or heights.depth_at(world_p.x, world_p.z) > 0.0:
				continue
			if _too_close_to_huts(Vector2(world_p.x, world_p.z), s.huts, 2.1):
				continue
			var hy := heights.ground_at(hut.x * TILE, hut.y * TILE)
			var fy := heights.ground_at(world_p.x, world_p.z)
			if absf(fy - hy) > 0.7:
				continue
			var fence_at := Transform3D(Basis(Vector3.UP, PlayerState.hut_angle(s, hut) + side * PI * 0.5), Vector3(world_p.x, fy, world_p.z))
			batch.add_detail(details_lib.fence_section, fence_at, fence_col, opaque_mat)

	if details_lib.has("wooden_jetty") and set_kind == "coastal" and s.homes > 0:
		var best_d2 := INF
		var water_cell := Vector2.ZERO
		var sx := floori(s.x)
		var sy := floori(s.y)
		for wy in range(maxi(0, sy - 12), mini(w.H, sy + 13)):
			for wx in range(maxi(0, sx - 12), mini(w.W, sx + 13)):
				var j := wy * w.W + wx
				if w.ocean[j] == 0 and w.lake[j] == 0:
					continue
				var d2 := Vector2(wx + 0.5 - s.x, wy + 0.5 - s.y).length_squared()
				if d2 < best_d2:
					best_d2 = d2
					water_cell = Vector2(wx + 0.5, wy + 0.5)
		if best_d2 < INF:
			var out_v := water_cell - Vector2(s.x, s.y)
			var dir := out_v.normalized() if out_v.length() > 0.1 else Vector2(0.0, 1.0)
			# Ставим мостки на кромке берега с заходом в воду (1,2 м глубже первой водной клетки)
			var jp := water_cell * TILE - dir * 1.2
			var dry_y := heights.ground_at(jp.x - dir.x * 3.0, jp.y - dir.y * 3.0)
			var g_y := heights.ground_at(jp.x, jp.y)
			var w_y := g_y + heights.depth_at(jp.x, jp.y)
			var deck_y := maxf(dry_y - 0.15, w_y - 0.10)
			batch.add_detail(details_lib.wooden_jetty, Transform3D(Basis(Vector3.UP, atan2(dir.x, dir.y)), Vector3(jp.x, deck_y, jp.y)), Color.html("#6e5138"), opaque_mat)


## Размещает дорожные указатели (signpost) на развилках, верстовые камни (milestone) вдоль дорог
## и перевальные туры (pass_cairn) на перевалах — всё через MultiMesh на общем атласе. Места — road_landmarks.
static func _add_road_landmarks(batch: MeshBatch, w: WorldData, heights: Heightfield,
		details_lib: Dictionary, opaque_mat: Material) -> void:
	var meshes := {sign = details_lib.get("signpost"), mile = details_lib.get("milestone"), cairn = details_lib.get("pass_cairn")}
	for mark: Dictionary in road_landmarks(w, heights):
		var mesh: Mesh = meshes[mark.kind]
		if mesh != null:
			batch.add_detail(mesh, mark.xform, Color.WHITE, opaque_mat)


const MILE_STEP := 200.0   # м между верстовыми камнями (по прямой, по всей сети дорог)
const MILE_PROBE := 20.0   # м между пробами места вдоль участка
const MILE_END := 20.0     # м: у конца участка (узла) камня нет — там указатель
const CREST_RISE := 8.0    # м: тур — на гребне, выше обоих концов участка хотя бы на столько
const CAIRN_ELEV := 0.36   # и выше этой отметки (w.elev) — высокогорье


## 17.11.2026: места ориентиров [{kind: sign | mile | cairn, xform}] без отрисовки (стенд road_plan_test -- --landmarks).
## Указатель — у конца участка, где сходится другой путь (развилка), на обочине, не ближе 90 м к другому. Верстовые
## камни — по всей сети дорог не ближе MILE_STEP друг к другу (прежде — через каждые 48 точек линии участка: на коротких
## участках между узлами их не было, на изогнутых шли чаще). Тур — на гребне участка тропы (выше обоих концов на CREST_RISE: перевал или
## седловина), а у конца участка на вершине (_summit) — у этого конца; прежде ставился в самой высокой точке любого участка,
## то есть посреди подъёма у узла.
static func road_landmarks(w: WorldData, heights: Heightfield) -> Array:
	var out: Array = []
	if w.trails.is_empty() or w.W <= 0 or w.H <= 0:
		return out
	# Пространственная хеш-таблица всех трасс для быстрого поиска развилок.
	var buckets := {}
	for tr_idx in w.trails.size():
		var tr: Dictionary = w.trails[tr_idx]
		if str(tr.get("kind", "")) == "animal":
			continue
		var pts: Array = tr.get("pts", [])
		for k in pts.size():
			if k != 0 and k != pts.size() - 1 and k % 5 != 0:
				continue
			var p: Dictionary = pts[k]
			var b := Vector2i(roundi(float(p.x) / 2.5), roundi(float(p.y) / 2.5))
			if not buckets.has(b):
				buckets[b] = [tr_idx]
			elif not (tr_idx in buckets[b]):
				buckets[b].append(tr_idx)

	var signs_placed: Array[Vector2] = []
	var miles_placed: Array[Vector2] = []
	var cairns_placed: Array[Vector2] = []

	for tr_idx in w.trails.size():
		var tr: Dictionary = w.trails[tr_idx]
		var kind: String = str(tr.get("kind", ""))
		if kind == "animal":
			continue
		var pts: Array = tr.get("pts", [])
		if pts.size() < 4:
			continue
		var junction := [_junction(buckets, tr_idx, pts[0]), _junction(buckets, tr_idx, pts[-1])]

		# 1. Указатели на развилках в начале/конце участка, где сходится другая трасса.
		for end in 2:
			if not junction[end]:
				continue
			var st_i := clampi(4 if end == 0 else pts.size() - 5, 1, pts.size() - 2)
			var xf := _road_shoulder(w, heights, pts, st_i, 1.45)
			if not xf.is_empty():
				var p2 := Vector2(xf.origin.x, xf.origin.z)
				if _far_from(signs_placed, p2, 90.0):
					signs_placed.append(p2)
					out.append({kind = "sign", xform = xf.xform})

		# 2. Каменные верстовые столбы вдоль главных дорог — по всей сети дорог через MILE_STEP: точка участка, от которой
		# до любого камня не меньше MILE_STEP (участки между узлами короткие — счёт по участку их пропускал)
		var along := PackedFloat32Array()
		along.resize(pts.size())
		for k in range(1, pts.size()):
			along[k] = along[k - 1] + Vector2(float(pts[k].x - pts[k - 1].x), float(pts[k].y - pts[k - 1].y)).length() * TILE
		var total := along[-1]
		if kind == "road":
			var last := -INF
			for k in range(1, pts.size() - 1):
				if along[k] < MILE_END or total - along[k] < MILE_END or along[k] - last < MILE_PROBE:
					continue
				last = along[k]
				var c := Vector2(float(pts[k].x) * TILE, float(pts[k].y) * TILE)
				if not _far_from(miles_placed, c, MILE_STEP):
					continue
				var xf := _road_shoulder(w, heights, pts, k, 1.25)
				if not xf.is_empty():
					var p2 := Vector2(xf.origin.x, xf.origin.z)
					if _far_from(signs_placed, p2, 28.0):
						miles_placed.append(c)
						out.append({kind = "mile", xform = xf.xform})

		# 3. Перевальные туры на гребнях горных и пешеходных троп; в тупике — у вершины.
		if kind in ["mountain", "trail"] and pts.size() >= 18:
			var elev := PackedFloat32Array()
			var hm := PackedFloat32Array()
			elev.resize(pts.size())
			hm.resize(pts.size())
			for k in pts.size():
				var cx := clampi(floori(float(pts[k].x)), 0, w.W - 1)
				var cy := clampi(floori(float(pts[k].y)), 0, w.H - 1)
				elev[k] = w.elev[cy * w.W + cx]
				hm[k] = heights.ground_at(float(pts[k].x) * TILE, float(pts[k].y) * TILE)
			var best_i := -1
			var best_h := -INF
			for k in range(8, pts.size() - 8, 2):
				if elev[k] > CAIRN_ELEV and hm[k] > best_h:
					best_h = hm[k]
					best_i = k
			var crest := best_i >= 0 and best_h - maxf(hm[0], hm[-1]) >= CREST_RISE
			var top := -INF
			for v: float in hm: top = maxf(top, v)
			if not crest:
				best_i = -1
				# конец участка на вершине (высший на участке и выше земли вокруг, _summit) — тур чуть ниже конца;
				# узел посреди подъёма (рядом земля выше) — не вершина
				for end in 2:
					var k_end := 0 if end == 0 else pts.size() - 1
					var k_in := clampi(6 if end == 0 else pts.size() - 7, 1, pts.size() - 2)
					if elev[k_end] > CAIRN_ELEV and hm[k_end] >= top - 0.5 and _summit(heights, float(pts[k_end].x) * TILE, float(pts[k_end].y) * TILE, hm[k_end]):
						best_i = k_in
			if best_i >= 0:
				var xf := _road_shoulder(w, heights, pts, best_i, 1.55)
				if not xf.is_empty():
					var p2 := Vector2(xf.origin.x, xf.origin.z)
					if _far_from(cairns_placed, p2, 120.0) and _far_from(signs_placed, p2, 24.0):
						cairns_placed.append(p2)
						out.append({kind = "cairn", xform = xf.xform})
	return out


## Точка на вершине или гребне: из восьми направлений на 20 м земля ниже на 1,5 м хотя бы в шести
static func _summit(heights: Heightfield, x: float, z: float, y: float) -> bool:
	var lower := 0
	for k in 8:
		var a := TAU * k / 8.0
		if heights.ground_at(x + cos(a) * 20.0, z + sin(a) * 20.0) < y - 1.5: lower += 1
	return lower >= 6


## Конец участка ep — развилка: рядом (±1 ячейка хеша, ~15 м) есть точка другого пути
static func _junction(buckets: Dictionary, tr_idx: int, ep: Dictionary) -> bool:
	var b := Vector2i(roundi(float(ep.x) / 2.5), roundi(float(ep.y) / 2.5))
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			for other: int in buckets.get(b + Vector2i(dx, dy), []):
				if other != tr_idx:
					return true
	return false


static func _road_shoulder(w: WorldData, heights: Heightfield, pts: Array, idx: int, extra_m: float) -> Dictionary:
	var p: Dictionary = pts[idx]
	var center := Vector2(float(p.x) * TILE, float(p.y) * TILE)
	if _landmark_blocked(w, heights, center):
		return {}
	var p_prev: Dictionary = pts[maxi(0, idx - 2)]
	var p_next: Dictionary = pts[mini(pts.size() - 1, idx + 2)]
	var tan := Vector2(float(p_next.x - p_prev.x), float(p_next.y - p_prev.y))
	if tan.length_squared() < 1e-6:
		return {}
	tan = tan.normalized()
	var perp := Vector2(-tan.y, tan.x)
	var offset := clampf(float(p.w) * TILE * 0.5, 0.8, 3.0) + extra_m
	var road_y := heights.ground_at(center.x, center.y)
	for side: float in [1.0, -1.0]:
		var pos := center + perp * (side * offset)
		var cx := floori(pos.x / TILE)
		var cy := floori(pos.y / TILE)
		if cx < 2 or cy < 2 or cx >= w.W - 2 or cy >= w.H - 2:
			continue
		var j := cy * w.W + cx
		if w.path_mask[j] >= 2 or w.ocean[j] != 0 or w.lake[j] != 0 or w.river[j] != 0:
			continue
		if heights.depth_at(pos.x, pos.y) > 0.0:
			continue
		var y := heights.ground_at(pos.x, pos.y)
		if absf(y - road_y) > 1.2:
			continue
		var to_road := (center - pos).normalized()
		var xform := Transform3D(Basis(Vector3.UP, atan2(to_road.x, to_road.y)), Vector3(pos.x, y, pos.y))
		return {xform = xform, origin = xform.origin}
	return {}


static func _landmark_blocked(w: WorldData, heights: Heightfield, pos_m: Vector2) -> bool:
	var min_settle2 := pow((StageLandmarks.LAYOUT_R + 2.5) * TILE, 2.0)
	for s in w.settlements:
		if Vector2(s.x * TILE, s.y * TILE).distance_squared_to(pos_m) < min_settle2:
			return true
	for site: SiteData in w.sites:
		if Vector2(site.x * TILE, site.y * TILE).distance_squared_to(pos_m) < 196.0:
			return true
	for st: Dictionary in heights.structures:
		var t := clampf((pos_m.x - float(st.ax)) * float(st.ux) + (pos_m.y - float(st.az)) * float(st.uz), -4.0, float(st.len) + 4.0)
		var near := Vector2(float(st.ax) + float(st.ux) * t, float(st.az) + float(st.uz) * t)
		if near.distance_to(pos_m) < float(st.half) + 5.0:
			return true
	return false


static func _far_from(placed: Array[Vector2], pos: Vector2, min_dist: float) -> bool:
	var d2 := min_dist * min_dist
	for prev in placed:
		if prev.distance_squared_to(pos) < d2:
			return false
	return true


static func _too_close_to_huts(pos_m: Vector2, huts: Array, gap_m: float) -> bool:
	var g2 := gap_m * gap_m
	for hut: HutData in huts:
		var hp := Vector2(hut.x * TILE, hut.y * TILE)
		if hp.distance_squared_to(pos_m) < g2:
			return true
	return false


## Прямоугольный блок с UV внутри выбранной ячейки общего атласа (для доски маршрутов и фонаря).
static func _uv_box(size: Vector3, cell: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	SettlementModels._box(st, size, Vector3.ZERO, Basis.IDENTITY, cell)
	st.index()
	return st.commit()


static func _legacy_site_materials(door_m: Material, win_m: Material) -> Dictionary:
	var tint := func(c: int) -> Material: return mat(Color.hex((c << 8) | 0xff))
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.04
	pole_mesh.bottom_radius = 0.04
	pole_mesh.height = 2.2
	pole_mesh.radial_segments = 4
	var flag_m := mat(Color8(0xc0, 0x39, 0x2b))
	flag_m.cull_mode = BaseMaterial3D.CULL_DISABLED
	var flag_mesh := QuadMesh.new()
	flag_mesh.size = Vector2(1.0, 0.6)
	var hay := CylinderMesh.new()
	hay.top_radius = 0.75
	hay.bottom_radius = 0.9
	hay.height = 1.3
	hay.radial_segments = 8
	return {
		plasters = [0xece2cc, 0xf3eee4, 0xdcc08a, 0xe6cbb8, 0xd3d6c6].map(tint),
		timbers = [0x7a4b2b, 0x5f3b23, 0x8d5e36].map(tint),
		roofs = [0x4a3a30, 0x464b54, 0x94452f, 0x67503e].map(tint),
		shutters = [0x3f6e3c, 0x9a3a2e, 0x4c6283, 0x2f2a24].map(tint),
		flowers = [0xd23a3f, 0xe0709a].map(tint),
		leaf = mat(Color.html("#4f6e2f")),
		rail = mat(Color.html("#a57446")),
		logs = mat(Color.html("#b48d5c")),
		water = mat(Color.html("#5d8ea6")),
		dark_roof = mat(Color.html("#4a3f36")),
		straw = mat(Color.html("#c2a35a")),
		hay = hay,
		hay_top = _cone_mesh(0.75, 0.7, 8),
		door = door_m,
		win = win_m,
		stone = mat(Color.html("#736d60")),
		timber = mat(Color.html("#755337")),
		unit = _box_mesh(Vector3.ONE),
		prism = PrismMesh.new(),
		roof = _cone_mesh(2.8, 2.2, 4),
		door_mesh = _box_mesh(Vector3(0.9, 1.7, 0.1)),
		win_mesh = _box_mesh(Vector3(0.6, 0.5, 0.1)),
		step = _box_mesh(Vector3(1.1, 0.18, 0.65)),
		pole = pole_mesh,
		pole_m = mat(Color8(0x5a, 0x3d, 0x24)),
		flag = flag_mesh,
		flag_m = flag_m,
	}


static func _add_extra_plinth(batch: MeshBatch, extra_plinths: Dictionary, model_id: String, half: Vector2,
		at: Transform3D, drop: float, opaque_mat: Material, tints: Dictionary, lod_count: int) -> void:
	if drop <= 0.35:
		return
	var qdrop := ceili((drop + 0.15) * 10.0) / 10.0
	var pkey := "%s|%.1f" % [model_id, qdrop]
	if not extra_plinths.has(pkey):
		extra_plinths[pkey] = SettlementModels.build_extra_plinth(half, -0.45, -qdrop)
	var plinth_mesh: Mesh = extra_plinths[pkey]
	for level in lod_count:
		batch.add_lod(plinth_mesh, at, [opaque_mat], level, tints, false)


static func _build_peaks(parent: Node3D, w: WorldData, heights: Heightfield, batch: MeshBatch, m: Dictionary,
		site_lods: Dictionary = {}, opaque_mat: Material = null) -> void:
	var use_atlas := opaque_mat != null and site_lods.has("peak_cairn")
	var peak_tints := SettlementModels.site_tints("peak_cairn", 0) if use_atlas else {}
	var stone: Material = null if use_atlas else mat(Color8(0x8f, 0x88, 0x80))
	var stone_meshes: Array[SphereMesh] = []
	if not use_atlas:
		for rh: Vector2 in PEAK_STONES:
			var sm := SphereMesh.new()
			sm.radius = rh.x
			sm.height = rh.x * 2.0
			sm.radial_segments = 5
			sm.rings = 2
			stone_meshes.append(sm)
	for pk in w.peaks:
		var x: float = pk.x * TILE
		var z: float = pk.y * TILE
		var y := heights.ground_at(x, z)
		var at := Transform3D(Basis(), Vector3(x, y, z))
		if use_atlas:
			var lods: Array = site_lods.peak_cairn
			for level in lods.size():
				batch.add_lod(lods[level], at, [opaque_mat], level, peak_tints, level <= 1)
		else:
			for k in PEAK_STONES.size():
				batch.add(stone_meshes[k], at.translated_local(Vector3(0, PEAK_STONES[k].y, 0)), stone)
			batch.add(m.pole, at.translated_local(Vector3(0, 3.2, 0)), m.pole_m)
			batch.add(m.flag, at.translated_local(Vector3(0.5, 3.9, 0)), m.flag_m)
		parent.add_child(_label("▲ " + pk.name, Color.html("#e8f0ff"), Vector3(x, y + 8.0, z), WorldData.place_id("peak", pk.x, pk.y)))


## Прежний процедурный сборщик домов (используется только при use_legacy = true как база «было»).
static func _build_legacy(parent: Node3D, w: WorldData, heights: Heightfield, courtyards: Courtyard) -> Dictionary:
	var door_m := mat(Color8(0x3a, 0x2a, 0x1c))
	var win_m := mat(Color8(0xf2, 0xd2, 0x7a), 1.1)
	var house := _legacy_site_materials(door_m, win_m)
	var bench_seat := _box_mesh(Vector3(1.8, 0.16, 0.48))
	var bench_leg := _box_mesh(Vector3(0.15, 0.45, 0.4))
	var board_post := _box_mesh(Vector3(0.12, 1.8, 0.12))
	var board_mesh := _box_mesh(Vector3(1.8, 0.95, 0.13))
	var log_mesh := CylinderMesh.new()
	log_mesh.top_radius = 0.1
	log_mesh.bottom_radius = 0.1
	log_mesh.height = 1.2
	log_mesh.radial_segments = 5
	var flame_mesh := _cone_mesh(0.4, 1.1, 6)
	var core_mesh := _cone_mesh(0.22, 0.7, 6)
	var flame_m := mat(Color8(0xff, 0x8a, 0x2a), 2.2)
	var core_m := mat(Color8(0xff, 0xd3, 0x6b), 3.0)
	var fires: Array = []
	var boards: Array = []
	var rng := WGRandom.new(w.seed_num ^ 0x1234)
	var batch := MeshBatch.new()
	for s in w.settlements:
		for hut in s.huts:
			var kind: String = EntityCodec.value(hut, "t", "house")
			var at := Transform3D(Basis(Vector3.UP, PlayerState.hut_angle(s, hut)), Vector3(hut.x * TILE, 0, hut.y * TILE))
			var foot := footing(heights, at, SettlementSets.half_of(kind))
			at.origin.y = foot.y
			if SettlementSets.is_home(kind) or HOUSE_FORM.has(kind):
				_house(batch, at, foot.y - foot.x, hut.v, house, kind, EntityCodec.value(s, "style", hut.v))
			else:
				_outbuilding(batch, at, foot.y - foot.x, kind, house)
		var yard := courtyards.choose(s)
		_add_settlement_label(parent, s, heights, yard)
		if yard.is_empty():
			continue
		for bench: Transform3D in yard.benches:
			batch.add(bench_seat, bench.translated_local(Vector3(0, 0.5, 0)), house.timber)
			for leg: float in [-0.65, 0.65]:
				batch.add(bench_leg, bench.translated_local(Vector3(leg, 0.23, 0)), house.timber)
		var board: Transform3D = yard.board
		var face := _add_board_label(parent, board)
		boards.append({at = face, place = s})
		for side: float in [-0.7, 0.7]:
			batch.add(board_post, board.translated_local(Vector3(side, 0.9, 0)), house.timber)
		batch.add(board_mesh, face, door_m)
		if yard.fire.is_finite():
			for k in 3:
				batch.add(log_mesh, Transform3D(Basis.from_euler(Vector3(0, k * PI / 3.0, PI / 2.0)), yard.fire + Vector3.UP * 0.1), door_m)
			fires.append(_add_fire(parent, yard.fire, s, rng.next_float() * 10.0, flame_mesh, flame_m, core_mesh, core_m))
	_build_peaks(parent, w, heights, batch, house)
	_build_sites(parent, w, heights, batch, house, {})
	for lk in w.lakes:
		var at := Vector2(lk.x * TILE, lk.y * TILE)
		parent.add_child(_label(lk.name, Color.html("#cfeaff"), Vector3(at.x, maxf(0.0, lk.level) * HS + 6.0, at.y), WorldData.place_id("lake", lk.x, lk.y)))
	var mi := batch.build("Buildings")
	if mi != null:
		parent.add_child(mi)
	return {fires = fires, windows = win_m, boards = boards}


## Жилой дом вида kind (HOUSE_FORM) для режима use_legacy.
static func _house(batch: MeshBatch, at: Transform3D, drop: float, v: int, m: Dictionary, kind := "house", style := -1) -> void:
	if style < 0:
		style = v
	var half := SettlementSets.half_of(kind)
	var form: Dictionary = HOUSE_FORM.get(kind, HOUSE_FORM.house)
	var wall := {stone = m.stone, plaster = m.plasters[(style * 2 + v) % 5], timber = m.timbers[(style + v / 2) % 3]}
	var roof: Material = m.roofs[(style + (1 if v == 3 else 0)) % 4]
	var trim := {shutter = m.shutters[(style + (1 if v == 2 else 0)) % 4], flower = m.flowers[v % 2]}
	var floors: Array = form.floors
	if kind == "house" and v % 2 == 1:
		floors = [[1.2, "stone"], [1.4, "timber"]]
	_plinth(batch, m.unit, at, drop, half * 2.0 + Vector2(0.1, 0.1), m.stone)
	var y := 0.0
	for f in floors.size():
		var h: float = floors[f][0]
		batch.add(m.unit, at * Transform3D(Basis.from_scale(Vector3(half.x * 2.0, h, half.y * 2.0)), Vector3(0, y + h * 0.5, 0)), wall[floors[f][1]])
		if h >= 1.5:
			var wy := maxf(y + h * 0.55, 1.45)
			var front: Array = [-half.x * 0.5, half.x * 0.5] if y > 0.5 or half.x < 1.8 else [half.x * 0.5]
			for wx: float in front:
				var spread := 1.15 if y < 0.5 and half.x < 1.8 else 1.0
				_window(batch, at, 0.0, Vector3(wx * spread, wy, half.y), m, trim, true)
			var sides: Array = [0.0] if half.y < 1.7 else [-half.y * 0.45, half.y * 0.45]
			for sz: float in sides:
				_window(batch, at, PI / 2.0, Vector3(-sz, wy, half.x), m, trim, false)
				_window(batch, at, -PI / 2.0, Vector3(sz, wy, half.x), m, trim, false)
			if y > 0.5:
				_window(batch, at, PI, Vector3(0, wy, half.y), m, trim, false)
		y += h
	var gable := half.x * tan(form.pitch)
	batch.add(m.prism, at * Transform3D(Basis.from_scale(Vector3(half.x * 2.0, gable, half.y * 2.0)), Vector3(0, y + gable * 0.5, 0)), wall[form.gable])
	batch.add(m.unit, at * Transform3D(Basis.from_scale(Vector3(0.42, 0.42, 0.06)), Vector3(0, y + gable * 0.35, half.y + 0.02)), m.win)
	_gable_roof(batch, at, half, y, form.pitch, form.eave, roof, m)
	var door_x := -half.x * 0.45 if half.x >= 1.8 else 0.0
	batch.add(m.unit, at * Transform3D(Basis.from_scale(Vector3(0.95, 1.85, 0.1)), Vector3(door_x, 0.93, half.y + 0.03)), m.door)
	batch.add(m.step, at.translated_local(Vector3(door_x, 0.02, half.y + 0.2)), m.stone)
	if form.get("balcony", false):
		var by: float = floors[0][0]
		var bw := half.x * 2.0 + 0.3
		batch.add(m.unit, at * Transform3D(Basis.from_scale(Vector3(bw, 0.12, 0.95)), Vector3(0, by, half.y + 0.47)), m.timber)
		batch.add(m.unit, at * Transform3D(Basis.from_scale(Vector3(bw, 0.8, 0.07)), Vector3(0, by + 0.46, half.y + 0.92)), m.rail)
		for sx: float in [-1.0, 1.0]:
			batch.add(m.unit, at * Transform3D(Basis.from_scale(Vector3(0.07, 0.8, 0.95)), Vector3(sx * bw * 0.5, by + 0.46, half.y + 0.47)), m.rail)
		batch.add(m.unit, at * Transform3D(Basis.from_scale(Vector3(bw - 0.2, 0.16, 0.22)), Vector3(0, by + 0.94, half.y + 0.98)), m.leaf)
		batch.add(m.unit, at * Transform3D(Basis.from_scale(Vector3(bw - 0.3, 0.14, 0.2)), Vector3(0, by + 1.07, half.y + 0.98)), trim.flower)
	if v % 2 == 0:
		var cx := half.x * 0.45
		batch.add(m.unit, at * Transform3D(Basis.from_scale(Vector3(0.5, 1.6, 0.5)), Vector3(cx, y + gable * (1.0 - 0.45) + 0.45, -half.y * 0.35)), m.stone)


## Двускатная крыша над стенами half (конёк вдоль z) высотой top: два ската со свесом eave и конёк
static func _gable_roof(batch: MeshBatch, at: Transform3D, half: Vector2, top: float, pitch: float, eave: float, roof: Material, m: Dictionary) -> void:
	var gable := half.x * tan(pitch)
	var run := half.x + eave
	var thick := 0.22
	var depth := half.y * 2.0 + eave * 2.0
	for side: float in [-1.0, 1.0]:
		var mid := Vector3(side * run * 0.5, top + gable - run * tan(pitch) * 0.5, 0)
		mid += Vector3(side * sin(pitch), cos(pitch), 0) * thick * 0.5
		var b := Basis(Vector3.BACK, -side * pitch) * Basis.from_scale(Vector3(run / cos(pitch), thick, depth))
		batch.add(m.unit, at * Transform3D(b, mid), roof)
	var ridge := Basis(Vector3.BACK, PI / 4.0) * Basis.from_scale(Vector3(0.3, 0.3, depth))
	batch.add(m.unit, at * Transform3D(ridge, Vector3(0, top + gable + thick * 0.8, 0)), roof)


static func _window(batch: MeshBatch, at: Transform3D, angle: float, pos: Vector3, m: Dictionary, trim: Dictionary, flowers: bool) -> void:
	var b := Basis(Vector3.UP, angle)
	var f := at * Transform3D(b, b * pos)
	batch.add(m.unit, f * Transform3D(Basis.from_scale(Vector3(0.62, 0.78, 0.08)), Vector3.ZERO), m.win)
	for sx: float in [-0.48, 0.48]:
		batch.add(m.unit, f * Transform3D(Basis.from_scale(Vector3(0.3, 0.84, 0.05)), Vector3(sx, 0, 0.04)), trim.shutter)
	if flowers:
		batch.add(m.unit, f * Transform3D(Basis.from_scale(Vector3(0.78, 0.16, 0.22)), Vector3(0, -0.48, 0.11)), m.leaf)
		batch.add(m.unit, f * Transform3D(Basis.from_scale(Vector3(0.7, 0.13, 0.18)), Vector3(0, -0.36, 0.11)), trim.flower)


static func _outbuilding(batch: MeshBatch, at: Transform3D, drop: float, kind: String, m: Dictionary) -> void:
	var half := SettlementSets.half_of(kind)
	match kind:
		"barn":
			_plinth(batch, m.unit, at, drop, half * 2.0 + Vector2(0.1, 0.1), m.stone)
			batch.add(m.unit, at * Transform3D(Basis.from_scale(Vector3(half.x * 2.0, 0.8, half.y * 2.0)), Vector3(0, 0.4, 0)), m.stone)
			batch.add(m.unit, at * Transform3D(Basis.from_scale(Vector3(half.x * 2.0, 2.0, half.y * 2.0)), Vector3(0, 1.8, 0)), m.timber)
			var gable := half.x * tan(0.5)
			batch.add(m.prism, at * Transform3D(Basis.from_scale(Vector3(half.x * 2.0, gable, half.y * 2.0)), Vector3(0, 2.8 + gable * 0.5, 0)), m.timber)
			_gable_roof(batch, at, half, 2.8, 0.5, 0.6, m.dark_roof, m)
			batch.add(m.unit, at * Transform3D(Basis.from_scale(Vector3(1.6, 2.0, 0.1)), Vector3(0, 1.0, half.y + 0.02)), m.door)
			batch.add(m.unit, at * Transform3D(Basis.from_scale(Vector3(0.9, 0.6, 0.08)), Vector3(0, 3.1, half.y + 0.02)), m.door)
		"hay":
			batch.add(m.hay, at.translated_local(Vector3(0, 0.55, 0)), m.straw)
			batch.add(m.hay_top, at.translated_local(Vector3(0, 1.5, 0)), m.straw)
		"shed":
			_plinth(batch, m.unit, at, drop, half * 2.0, m.stone)
			batch.add(m.unit, at * Transform3D(Basis.from_scale(Vector3(half.x * 2.0, 1.9, 0.15)), Vector3(0, 0.95, -half.y + 0.08)), m.timber)
			for sx: float in [-1.0, 1.0]:
				batch.add(m.unit, at * Transform3D(Basis.from_scale(Vector3(0.12, 1.7, half.y * 2.0)), Vector3(sx * (half.x - 0.06), 0.85, 0)), m.timber)
			batch.add(m.unit, at * Transform3D(Basis.from_scale(Vector3(half.x * 2.0 - 0.3, 1.25, half.y * 1.6)), Vector3(0, 0.63, 0.05)), m.logs)
			var lean := Basis(Vector3.RIGHT, 0.28) * Basis.from_scale(Vector3(half.x * 2.0 + 0.5, 0.14, half.y * 2.0 + 0.6))
			batch.add(m.unit, at * Transform3D(lean, Vector3(0, 1.95, 0.05)), m.dark_roof)
		"fountain":
			batch.add(m.unit, at * Transform3D(Basis.from_scale(Vector3(half.x * 2.0, 0.7, half.y * 2.0)), Vector3(0, 0.3, 0)), m.stone)
			batch.add(m.unit, at * Transform3D(Basis.from_scale(Vector3(half.x * 2.0 - 0.2, 0.05, half.y * 2.0 - 0.2)), Vector3(0, 0.66, 0)), m.water)
			batch.add(m.unit, at * Transform3D(Basis.from_scale(Vector3(0.3, 1.5, 0.3)), Vector3(-half.x + 0.15, 0.75, 0)), m.timber)
			batch.add(m.unit, at * Transform3D(Basis.from_scale(Vector3(0.35, 0.06, 0.06)), Vector3(-half.x + 0.45, 1.25, 0)), m.stone)


## Нижний и верхний угол земли под постройкой half (м), повёрнутой как at: Vector2(низ, верх)
static func footing(heights: Heightfield, at: Transform3D, half: Vector2) -> Vector2:
	var low := INF
	var high := -INF
	for c: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
		var corner := at.basis * Vector3(c.x * half.x, 0, c.y * half.y)
		var h := heights.ground_at(at.origin.x + corner.x, at.origin.z + corner.z)
		low = minf(low, h)
		high = maxf(high, h)
	return Vector2(low, high)


## Места вне поселений: дома/сараи/сеновалы и памятники (при не use_legacy) на общем атласе и с 3 LOD.
static func _build_sites(parent: Node3D, w: WorldData, heights: Heightfield, batch: MeshBatch, m: Dictionary, cat: Dictionary) -> void:
	var use_catalog := not cat.is_empty()
	var site_lods: Dictionary = cat.get("site_lods", {}) if use_catalog else {}
	var legacy_shapes := m if site_lods.is_empty() else {}
	var unit: Mesh = _box_mesh(Vector3.ONE) if site_lods.is_empty() else null
	var old_stone: Material = mat(Color.html("#6b6a5c")) if site_lods.is_empty() else null
	var weathered := [old_stone, mat(Color.html("#585749")), mat(Color.html("#5d6b48"))] if site_lods.is_empty() else []
	var pale_stone: Material = mat(Color.html("#9a958a")) if site_lods.is_empty() else null
	var dark_roof: Material = legacy_shapes.get("dark_roof", null)
	var leg: Mesh = _box_mesh(Vector3(0.25, 7.0, 0.25)) if site_lods.is_empty() else null
	var deck: Mesh = _box_mesh(Vector3(2.8, 0.2, 2.8)) if site_lods.is_empty() else null
	var rail: Mesh = _box_mesh(Vector3(2.8, 0.1, 0.08)) if site_lods.is_empty() else null
	var tower_roof: Mesh = _cone_mesh(2.2, 1.6, 4) if site_lods.is_empty() else null
	var tip: Mesh = _cone_mesh(0.5, 0.7, 4) if site_lods.is_empty() else null
	var keep: CylinderMesh = null
	if site_lods.is_empty():
		keep = CylinderMesh.new()
		keep.top_radius = 1.5
		keep.bottom_radius = 1.6
		keep.height = 1.0
		keep.radial_segments = 8
	for s: SiteData in w.sites:
		var top := -INF
		for u: HutData in s.huts:
			var v: int = u.v
			var at := Transform3D(Basis(Vector3.UP, u.a), Vector3(u.x * TILE, 0, u.y * TILE))
			var half := SettlementSets.half_of(u.t)
			var foot := footing(heights, at, half)
			var low := foot.x
			var high := foot.y
			at.origin.y = high if (SettlementSets.is_home(u.t) or u.t in ["barn", "barn_loft", "boat_shed", "shelter"]) else low
			if u.t == "tower":
				at.origin.y = TowerLayout.base_height(heights, at.origin.x, at.origin.z, u.a) # та же отметка, что у настилов лестницы
			top = maxf(top, at.origin.y)
			if use_catalog and cat.settlements.has(u.t):
				var entry: Dictionary = cat.settlements[u.t]
				var outbuilding: bool = entry.get("category", "home") != "home"
				var tints := SettlementModels.cell_tints(v, v, outbuilding)
				var lods: Array = entry.lods
				for level in lods.size():
					batch.add_lod(lods[level], at, cat.mat_pair, level, tints, true)
				_add_extra_plinth(batch, cat.extra_plinths, u.t, half, at, high - low, cat.opaque, tints, lods.size())
				_add_flower_details(batch, at, u.t, half, v, cat.details, cat.cutout)
				continue
			if not site_lods.is_empty() and site_lods.has(u.t):
				var xf := at
				if u.t == "keep":
					xf.basis = xf.basis.scaled(Vector3(1.0, (5.0 + float(v) * 1.5) / 6.4, 1.0))
				elif u.t == "stone":
					xf.basis = Basis(Vector3.UP, u.a).rotated(Vector3.RIGHT, (v - 1.5) * 0.06).scaled(Vector3(1.0, (1.7 + float(v) * 0.3) / 2.2, 1.0))
				var stints := SettlementModels.site_tints(u.t, v)
				var slods: Array = site_lods[u.t]
				for level in slods.size():
					batch.add_lod(slods[level], xf, [cat.opaque], level, stints, level <= 1)
				if u.t == "shelter":
					_add_extra_plinth(batch, cat.extra_plinths, u.t, half, at, high - low, cat.opaque, stints, slods.size())
				continue
			match u.t:
				"house":
					_house(batch, at, high - low, v, m)
				"barn", "hay":
					_outbuilding(batch, at, high - low, u.t, m)
				"shelter":
					_plinth(batch, unit, at, high - low, Vector2(3.1, 3.1), old_stone)
					batch.add(unit, at * Transform3D(Basis.from_scale(Vector3(3.0, 2.0, 3.0)), Vector3(0, 1.0, 0)), old_stone)
					batch.add(m.roof, at * Transform3D(Basis(Vector3.UP, PI / 4.0).scaled(Vector3(0.95, 0.6, 0.95)), Vector3(0, 2.65, 0)), dark_roof)
					batch.add(m.door_mesh, at.translated_local(Vector3(0, 0.85, 1.52)), m.door)
					if use_catalog:
						for level in 3:
							batch.add_lod(cat.lantern, at.translated_local(Vector3(0.85, 1.55, 1.52)), [cat.opaque], level, {}, false)
					else:
						batch.add(m.win_mesh, at * Transform3D(Basis.from_scale(Vector3(0.4, 0.7, 2.0)), Vector3(0.85, 1.55, 1.52)), m.win)
				"tower":
					for cx: float in [-1.0, 1.0]:
						for cz: float in [-1.0, 1.0]:
							batch.add(leg, at.translated_local(Vector3(cx, 3.2, cz)), m.timber)
					batch.add(deck, at.translated_local(Vector3(0, 6.4, 0)), m.timber)
					for k in 4:
						batch.add(rail, at * Transform3D(Basis(Vector3.UP, k * PI / 2.0)) * Transform3D(Basis(), Vector3(0, 7.2, 1.36)), m.timber)
					batch.add(tower_roof, at * Transform3D(Basis(Vector3.UP, PI / 4.0), Vector3(0, 8.5, 0)), m.roofs[v])
					batch.add(m.pole, at.translated_local(Vector3(0, 9.9, 0)), m.pole_m)
					batch.add(m.flag, at.translated_local(Vector3(0.5, 10.6, 0)), m.flag_m)
				"obelisk":
					batch.add(unit, at * Transform3D(Basis.from_scale(Vector3(1.5, 0.8, 1.5)), Vector3(0, 0.2, 0)), old_stone)
					batch.add(unit, at * Transform3D(Basis.from_scale(Vector3(0.7, 4.6, 0.7)), Vector3(0, 2.9, 0)), pale_stone)
					batch.add(tip, at * Transform3D(Basis(Vector3.UP, PI / 4.0), Vector3(0, 5.55, 0)), pale_stone)
				"stone":
					var tilt := Basis(Vector3.UP, u.a).rotated(Vector3.RIGHT, (v - 1.5) * 0.06)
					batch.add(unit, Transform3D(tilt.scaled(Vector3(0.65, 1.7 + v * 0.3, 0.45)), at.origin + Vector3(0, 0.6, 0)), pale_stone)
				"ruin":
					var hs := [2.4, 1.3, 0.7]
					for k in 3:
						var h: float = hs[(k + v) % 3]
						var wall: Vector3 = [Vector3(3.4, h, 0.45), Vector3(0.45, h, 3.4), Vector3(0.45, h, 1.8)][k]
						var pos: Vector3 = [Vector3(0, h * 0.5 - 0.2, -1.5), Vector3(-1.5, h * 0.5 - 0.2, 0), Vector3(1.5, h * 0.5 - 0.2, -0.8)][k]
						batch.add(unit, at * Transform3D(Basis.from_scale(wall), pos), weathered[(k + v) % 3])
					batch.add(unit, at * Transform3D(Basis(Vector3.UP, 0.4).scaled(Vector3(0.7, 0.45, 0.9)), Vector3(1.2, 0.1, 1.4)), weathered[2])
				"keep":
					var h := 5.0 + v * 1.5
					batch.add(keep, at * Transform3D(Basis.from_scale(Vector3(1, h, 1)), Vector3(0, h * 0.5 - 0.3, 0)), old_stone)
		var label := _label(s.name, Color.html("#efe2c0"), Vector3(s.x * TILE, top + (TowerLayout.HEIGHT + 2.0 if s.type == "tower" else 7.0), s.y * TILE), WorldData.place_id("site", s.x, s.y))
		parent.add_child(label)


## Каменный цоколь под постройкой size (м по x и z): от пола at на drop м вниз до нижнего угла
static func _plinth(batch: MeshBatch, unit: Mesh, at: Transform3D, drop: float, size: Vector2, material: Material) -> void:
	var base := at.translated_local(Vector3(0, -(drop + 0.15) * 0.5, 0))
	base.basis = base.basis.scaled(Vector3(size.x, drop + 0.15, size.y))
	batch.add(unit, base, material)


## Окна и фонари: для общего атласа управляет силой свечения, для режима legacy — цветом без освещения.
## night — 0 днём, 1 ночью
static func set_night(windows: StandardMaterial3D, night: float) -> void:
	var lit := smoothstep(0.25, 0.85, night)
	if windows != null:
		if windows.emission_enabled:
			windows.emission_energy_multiplier = lit * 2.6
		else:
			windows.albedo_color = Color(0.16, 0.18, 0.2).lerp(Color8(0xf2, 0xd2, 0x7a) * 2.6, lit)
	if shared_opaque_mat != null and shared_opaque_mat != windows and shared_opaque_mat.emission_enabled:
		shared_opaque_mat.emission_energy_multiplier = lit * 2.6


## Покачивание пламени костров; time — секунды игры. Дальше FIRE_SEEN от at пламя не видно (_part) и не качается
static func animate_fires(fires: Array, time: float, at: Vector3) -> void:
	for f: Dictionary in fires:
		if at.distance_squared_to(f.pos) > FIRE_SEEN * FIRE_SEEN:
			continue
		var t: float = time * 9.0 + f.phase
		var s := 0.85 + sin(t) * 0.1 + sin(t * 1.7) * 0.08
		f.flame.scale = Vector3(1, s, 1)
		f.core.scale = Vector3(1, s * 1.1, 1)
