class_name SettlementsBuilder
extends RefCounted
## Поселения и вершины в 3D: дома, костры, туры с флажками, подписи. Копия js/render3d/settlements.js.

const TILE := GameConfig.TILE
const HS := GameConfig.HS
const PEAK_LABEL_CLEAR := 24.0 # м: ближе к поселению подпись вершины не ставится
const HUT_CORNERS := [Vector2(-1.6, -1.6), Vector2(1.6, -1.6), Vector2(-1.6, 1.6), Vector2(1.6, 1.6)]
const PEAK_STONES := [Vector2(0.9, 0.5), Vector2(0.65, 1.3), Vector2(0.45, 1.95)] # радиус, высота центра


## glow > 0 — светится сам (огонь, окна): цвет идёт в излучение с этой силой, яркое пятно подхватывает
## свечение окружения (glow). До 2.6 такие материалы были без освещения (unshaded)
static func _mat(c: Color, glow: float = 0.0) -> StandardMaterial3D:
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


## Узел с мешем и материалом (для костров); дома и туры собираются в один меш через MeshBatch
static func _part(mesh: Mesh, offset: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = offset
	mi.material_override = mat
	# костёр мелкий, а пламя светится: тени от них не нужны
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


static func _label(text: String, color: Color, pos: Vector3) -> Label3D:
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
	return l


## Добавляет постройки в parent. Возвращает {fires: [{flame, core, phase}], labels: [Label3D]}
## для анимации огня и скрытия подписей по расстоянию.
static func build(parent: Node3D, w: WorldData, heights: Heightfield) -> Dictionary:
	var walls := [0xa7825a, 0xb89470, 0x8f6e4c, 0xc2a27a].map(func(c: int) -> Material: return _mat(Color.hex((c << 8) | 0xff)))
	var roofs := [0x7b3f2a, 0x5c4632, 0x8a5a2b, 0x6d3b3b].map(func(c: int) -> Material: return _mat(Color.hex((c << 8) | 0xff)))
	var door_m := _mat(Color8(0x3a, 0x2a, 0x1c))
	var win_m := _mat(Color8(0xf2, 0xd2, 0x7a), 1.1)
	var wall_mesh := _box_mesh(Vector3(3.2, 2.6, 3.2))
	var roof_mesh := _cone_mesh(2.8, 2.2, 4)
	var door_mesh := _box_mesh(Vector3(0.9, 1.7, 0.1))
	var win_mesh := _box_mesh(Vector3(0.6, 0.5, 0.1))
	var stone_m := _mat(Color.html("#736d60"))
	var timber_m := _mat(Color.html("#755337"))
	var foundation_mesh := _box_mesh(Vector3(3.3, 1.0, 3.3))
	var step_mesh := _box_mesh(Vector3(1.1, 0.18, 0.65))
	var chimney_mesh := _box_mesh(Vector3(0.45, 1.1, 0.45))
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
	var flame_m := _mat(Color8(0xff, 0x8a, 0x2a), 2.2)
	var core_m := _mat(Color8(0xff, 0xd3, 0x6b), 3.0)
	var fires: Array = []
	var labels: Array = []
	var settle_pos := PackedVector2Array() # центры поселений, чтобы подписи вершин не ложились на их названия
	var rng := WGRandom.new(w.seed_num ^ 0x1234)
	# дома и туры неподвижны: они собираются в один меш (MeshBatch), костры с огнём — отдельные узлы
	var batch := MeshBatch.new()
	for s in w.settlements:
		for hut in s.huts:
			var x: float = hut.x * TILE
			var z: float = hut.y * TILE
			var facing := Basis(Vector3.UP, atan2(s.x * TILE - x, s.y * TILE - z))
			# Пол выше верхнего угла; каменный цоколь закрывает перепад до нижнего.
			var low := INF
			var y := -INF
			for c: Vector2 in HUT_CORNERS:
				var corner := facing * Vector3(c.x, 0, c.y)
				var h := heights.ground_at(x + corner.x, z + corner.z)
				low = minf(low, h)
				y = maxf(y, h)
			# дверью к костру
			var at := Transform3D(facing, Vector3(x, y, z))
			var base := at.translated_local(Vector3(0, -(y - low + 0.15) * 0.5, 0))
			base.basis = base.basis.scaled(Vector3(1, y - low + 0.15, 1))
			batch.add(foundation_mesh, base, stone_m)
			batch.add(wall_mesh, at.translated_local(Vector3(0, 1.3, 0)), walls[hut.v])
			batch.add(roof_mesh, at * Transform3D(Basis(Vector3.UP, PI / 4.0), Vector3(0, 2.6 + 1.1, 0)), roofs[hut.v])
			batch.add(door_mesh, at.translated_local(Vector3(0, 0.85, 1.62)), door_m)
			batch.add(win_mesh, at.translated_local(Vector3(0.95, 1.6, 1.62)), win_m)
			batch.add(win_mesh, at * Transform3D(Basis(Vector3.UP, PI / 2.0), Vector3(1.62, 1.6, 0)), win_m)
			batch.add(step_mesh, at.translated_local(Vector3(0, 0.02, 1.8)), stone_m)
			if hut.v % 2 == 0:
				batch.add(chimney_mesh, at.translated_local(Vector3(0.85, 3.6, 0.45)), stone_m)
		# костёр
		var fx: float = s.x * TILE
		var fz: float = s.y * TILE
		var fy := heights.ground_at(fx, fz)
		# Небольшое общее место: скамьи и указатель стоят внутри кольца домов.
		for side: float in [-1.0, 1.0]:
			var bx := fx + side * 3.0
			var by := heights.ground_at(bx, fz)
			var bench := Transform3D(Basis(Vector3.UP, PI / 2.0), Vector3(bx, by, fz))
			batch.add(bench_seat, bench.translated_local(Vector3(0, 0.5, 0)), timber_m)
			for leg: float in [-0.65, 0.65]:
				batch.add(bench_leg, bench.translated_local(Vector3(leg, 0.23, 0)), timber_m)
		var board_pos := Vector3(fx + 3.0, 0.0, fz - 3.0)
		board_pos.y = heights.ground_at(board_pos.x, board_pos.z)
		var board := Transform3D(Basis(Vector3.UP, -PI / 4.0), board_pos)
		for side: float in [-0.7, 0.7]:
			batch.add(board_post, board.translated_local(Vector3(side, 0.9, 0)), timber_m)
		batch.add(board_mesh, board.translated_local(Vector3(0, 1.35, 0)), door_m)
		var board_text := Label3D.new()
		board_text.text = "МАРШРУТЫ\n[E]"
		board_text.font_size = 24
		board_text.pixel_size = 0.005
		board_text.no_depth_test = false
		board_text.visibility_range_end = 35.0
		board_text.transform = board.translated_local(Vector3(0, 1.35, 0.08))
		parent.add_child(board_text)
		var fire := Node3D.new()
		for k in 3:
			var log_node := _part(log_mesh, Vector3(0, 0.1, 0), door_m)
			log_node.rotation = Vector3(0, k * PI / 3.0, PI / 2.0)
			fire.add_child(log_node)
		# пламя растёт от земли: узлы-основания масштабируются, конусы сдвинуты вверх
		var flame := Node3D.new()
		flame.add_child(_part(flame_mesh, Vector3(0, 0.55, 0), flame_m))
		var core := Node3D.new()
		core.add_child(_part(core_mesh, Vector3(0, 0.35, 0), core_m))
		fire.add_child(flame)
		fire.add_child(core)
		fire.position = Vector3(fx, fy, fz)
		parent.add_child(fire)
		fires.append({flame = flame, core = core, phase = rng.next_float() * 10.0})
		var label := _label(s.name, Color.html("#fff6d8"), Vector3(fx, fy + 9.0, fz))
		parent.add_child(label)
		labels.append(label)
		settle_pos.append(Vector2(fx, fz))
	# Туры на вершинах
	var stone := _mat(Color8(0x8f, 0x88, 0x80))
	var flag_m := _mat(Color8(0xc0, 0x39, 0x2b))
	flag_m.cull_mode = BaseMaterial3D.CULL_DISABLED
	var pole_m := _mat(Color8(0x5a, 0x3d, 0x24))
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.04
	pole_mesh.bottom_radius = 0.04
	pole_mesh.height = 2.2
	pole_mesh.radial_segments = 4
	var flag_mesh := QuadMesh.new()
	flag_mesh.size = Vector2(1.0, 0.6)
	var stone_meshes: Array[SphereMesh] = []
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
		for k in PEAK_STONES.size():
			batch.add(stone_meshes[k], at.translated_local(Vector3(0, PEAK_STONES[k].y, 0)), stone)
		batch.add(pole_mesh, at.translated_local(Vector3(0, 3.2, 0)), pole_m)
		batch.add(flag_mesh, at.translated_local(Vector3(0.5, 3.9, 0)), flag_m)
		# подпись вершины рядом с поселением закрыла бы его название: такую не ставим
		var near := false
		for sp: Vector2 in settle_pos:
			if sp.distance_to(Vector2(x, z)) < PEAK_LABEL_CLEAR:
				near = true
				break
		if near:
			continue
		var label := _label("▲ " + pk.name, Color.html("#e8f0ff"), Vector3(x, y + 8.0, z))
		parent.add_child(label)
		labels.append(label)
	_build_sites(parent, w, heights, batch, labels, {walls = walls, roofs = roofs, door = door_m, win = win_m,
		stone = stone_m, timber = timber_m, wall = wall_mesh, roof = roof_mesh, door_mesh = door_mesh, win_mesh = win_mesh})
	# названия озёр над серединой воды (с 2.9)
	for lk in w.lakes:
		var at := Vector2(lk.x * TILE, lk.y * TILE)
		var near := false
		for sp: Vector2 in settle_pos:
			if sp.distance_to(at) < PEAK_LABEL_CLEAR:
				near = true
				break
		if near:
			continue
		var label := _label(lk.name, Color.html("#cfeaff"), Vector3(at.x, maxf(0.0, lk.level) * HS + 6.0, at.y))
		parent.add_child(label)
		labels.append(label)
	var mi := batch.build("Buildings")
	if mi != null:
		parent.add_child(mi)
	return {fires = fires, labels = labels}


## Места вне поселений (с 9.3): постройки из тех же простых мешей в общий MeshBatch. Вид постройки — u.t,
## поворот — u.a (тот же, что у столкновений PlayerState.SITE_HALF). Подписи — у значимых мест.
static func _build_sites(parent: Node3D, w: WorldData, heights: Heightfield, batch: MeshBatch, labels: Array, m: Dictionary) -> void:
	var unit := _box_mesh(Vector3.ONE)
	var old_stone := _mat(Color.html("#6b6a5c"))
	var pale_stone := _mat(Color.html("#9a958a"))
	var straw := _mat(Color.html("#c2a35a"))
	var dark_roof := _mat(Color.html("#4a3f36"))
	var leg := _box_mesh(Vector3(0.25, 7.0, 0.25))
	var deck := _box_mesh(Vector3(2.8, 0.2, 2.8))
	var rail := _box_mesh(Vector3(2.8, 0.1, 0.08))
	var tower_roof := _cone_mesh(2.2, 1.6, 4)
	var tip := _cone_mesh(0.5, 0.7, 4)
	var hay := CylinderMesh.new()
	hay.top_radius = 0.75
	hay.bottom_radius = 0.9
	hay.height = 1.3
	hay.radial_segments = 8
	var hay_top := _cone_mesh(0.75, 0.7, 8)
	var keep := CylinderMesh.new()
	keep.top_radius = 1.5
	keep.bottom_radius = 1.6
	keep.height = 1.0
	keep.radial_segments = 8
	for s: Dictionary in w.sites:
		var top := -INF
		for u: Dictionary in s.huts:
			var x: float = u.x * TILE
			var z: float = u.y * TILE
			var low := INF
			var high := -INF
			for c: Vector2 in HUT_CORNERS:
				var corner := Basis(Vector3.UP, u.a) * Vector3(c.x, 0, c.y)
				var h := heights.ground_at(x + corner.x, z + corner.z)
				low = minf(low, h)
				high = maxf(high, h)
			var v: int = u.v
			# Жилые постройки стоят на цоколе по верхнему углу, камни и руины уходят в землю.
			var at := Transform3D(Basis(Vector3.UP, u.a), Vector3(x, high if u.t in ["house", "barn", "shelter"] else low, z))
			top = maxf(top, at.origin.y)
			match u.t:
				"house":
					var base := at.translated_local(Vector3(0, -(high - low + 0.15) * 0.5, 0))
					base.basis = base.basis.scaled(Vector3(1, high - low + 0.15, 1))
					batch.add(unit, base * Transform3D(Basis.from_scale(Vector3(3.3, 1, 3.3)), Vector3.ZERO), m.stone)
					batch.add(m.wall, at.translated_local(Vector3(0, 1.3, 0)), m.walls[v])
					batch.add(m.roof, at * Transform3D(Basis(Vector3.UP, PI / 4.0), Vector3(0, 3.7, 0)), m.roofs[v])
					batch.add(m.door_mesh, at.translated_local(Vector3(0, 0.85, 1.62)), m.door)
					batch.add(m.win_mesh, at.translated_local(Vector3(0.95, 1.6, 1.62)), m.win)
				"barn":
					var base := at.translated_local(Vector3(0, -(high - low + 0.15) * 0.5, 0))
					base.basis = base.basis.scaled(Vector3(4.1, high - low + 0.15, 3.1))
					batch.add(unit, base, m.stone)
					batch.add(unit, at * Transform3D(Basis.from_scale(Vector3(4.0, 2.8, 3.0)), Vector3(0, 1.4, 0)), m.timber)
					batch.add(m.roof, at * Transform3D(Basis(Vector3.UP, PI / 4.0).scaled(Vector3(1.05, 0.9, 1.05)), Vector3(0, 3.6, 0)), dark_roof)
					batch.add(unit, at * Transform3D(Basis.from_scale(Vector3(1.6, 2.0, 0.1)), Vector3(0, 1.0, 1.52)), m.door)
				"shelter":
					var base := at.translated_local(Vector3(0, -(high - low + 0.15) * 0.5, 0))
					base.basis = base.basis.scaled(Vector3(3.1, high - low + 0.15, 3.1))
					batch.add(unit, base, old_stone)
					batch.add(unit, at * Transform3D(Basis.from_scale(Vector3(3.0, 2.0, 3.0)), Vector3(0, 1.0, 0)), old_stone)
					batch.add(m.roof, at * Transform3D(Basis(Vector3.UP, PI / 4.0).scaled(Vector3(0.95, 0.6, 0.95)), Vector3(0, 2.65, 0)), dark_roof)
					batch.add(m.door_mesh, at.translated_local(Vector3(0, 0.85, 1.52)), m.door)
				"tower":
					for cx: float in [-1.0, 1.0]:
						for cz: float in [-1.0, 1.0]:
							batch.add(leg, at.translated_local(Vector3(cx, 3.2, cz)), m.timber)
					batch.add(deck, at.translated_local(Vector3(0, 6.4, 0)), m.timber)
					for k in 4:
						batch.add(rail, at * Transform3D(Basis(Vector3.UP, k * PI / 2.0)) * Transform3D(Basis(), Vector3(0, 7.2, 1.36)), m.timber)
					batch.add(tower_roof, at * Transform3D(Basis(Vector3.UP, PI / 4.0), Vector3(0, 8.5, 0)), m.roofs[v])
				"obelisk":
					batch.add(unit, at * Transform3D(Basis.from_scale(Vector3(1.5, 0.8, 1.5)), Vector3(0, 0.2, 0)), old_stone)
					batch.add(unit, at * Transform3D(Basis.from_scale(Vector3(0.7, 4.6, 0.7)), Vector3(0, 2.9, 0)), pale_stone)
					batch.add(tip, at * Transform3D(Basis(Vector3.UP, PI / 4.0), Vector3(0, 5.55, 0)), pale_stone)
				"stone":
					var tilt := Basis(Vector3.UP, u.a).rotated(Vector3.RIGHT, (v - 1.5) * 0.06)
					batch.add(unit, Transform3D(tilt.scaled(Vector3(0.65, 1.7 + v * 0.3, 0.45)), at.origin + Vector3(0, 0.6, 0)), pale_stone)
				"hay":
					batch.add(hay, at.translated_local(Vector3(0, 0.55, 0)), straw)
					batch.add(hay_top, at.translated_local(Vector3(0, 1.5, 0)), straw)
				"ruin":
					# Три стены комнаты разной высоты, четвёртой нет; рядом выпавший камень.
					var hs := [2.4, 1.3, 0.7]
					for k in 3:
						var h: float = hs[(k + v) % 3]
						var wall: Vector3 = [Vector3(3.4, h, 0.45), Vector3(0.45, h, 3.4), Vector3(0.45, h, 1.8)][k]
						var pos: Vector3 = [Vector3(0, h * 0.5 - 0.2, -1.5), Vector3(-1.5, h * 0.5 - 0.2, 0), Vector3(1.5, h * 0.5 - 0.2, -0.8)][k]
						batch.add(unit, at * Transform3D(Basis.from_scale(wall), pos), old_stone)
					batch.add(unit, at * Transform3D(Basis(Vector3.UP, 0.4).scaled(Vector3(0.7, 0.45, 0.9)), Vector3(1.2, 0.1, 1.4)), old_stone)
				"keep":
					var h := 5.0 + v * 1.5
					batch.add(keep, at * Transform3D(Basis.from_scale(Vector3(1, h, 1)), Vector3(0, h * 0.5 - 0.3, 0)), old_stone)
		if s.rank < 2 or s.huts.is_empty():
			continue
		var label := _label(s.name, Color.html("#efe2c0"), Vector3(s.x * TILE, top + (11.0 if s.type == "tower" else 7.0), s.y * TILE))
		# Мелкие подписи не висят над всей округой
		label.visibility_range_end = 900.0 if s.rank >= 3 else 350.0
		parent.add_child(label)
		labels.append(label)


## Покачивание пламени костров; time — секунды игры
static func animate_fires(fires: Array, time: float) -> void:
	for f: Dictionary in fires:
		var t: float = time * 9.0 + f.phase
		var s := 0.85 + sin(t) * 0.1 + sin(t * 1.7) * 0.08
		f.flame.scale = Vector3(1, s, 1)
		f.core.scale = Vector3(1, s * 1.1, 1)
