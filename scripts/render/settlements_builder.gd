class_name SettlementsBuilder
extends RefCounted
## Поселения и вершины в 3D: дома, костры, туры с флажками, подписи. Копия js/render3d/settlements.js.

const TILE := GameConfig.TILE
const PEAK_LABEL_CLEAR := 24.0 # м: ближе к поселению подпись вершины не ставится
const HUT_CORNERS := [Vector2(-1.6, -1.6), Vector2(1.6, -1.6), Vector2(-1.6, 1.6), Vector2(1.6, 1.6)]
const PEAK_STONES := [Vector2(0.9, 0.5), Vector2(0.65, 1.3), Vector2(0.45, 1.95)] # радиус, высота центра


static func _mat(c: Color, unshaded: bool = false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 1.0
	if unshaded:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
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
	var win_m := _mat(Color8(0xf2, 0xd2, 0x7a), true)
	var wall_mesh := _box_mesh(Vector3(3.2, 2.6, 3.2))
	var roof_mesh := _cone_mesh(2.8, 2.2, 4)
	var door_mesh := _box_mesh(Vector3(0.9, 1.7, 0.1))
	var win_mesh := _box_mesh(Vector3(0.6, 0.5, 0.1))
	var log_mesh := CylinderMesh.new()
	log_mesh.top_radius = 0.1
	log_mesh.bottom_radius = 0.1
	log_mesh.height = 1.2
	log_mesh.radial_segments = 5
	var flame_mesh := _cone_mesh(0.4, 1.1, 6)
	var core_mesh := _cone_mesh(0.22, 0.7, 6)
	var flame_m := _mat(Color8(0xff, 0x8a, 0x2a), true)
	var core_m := _mat(Color8(0xff, 0xd3, 0x6b), true)
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
			# дом стоит на самом низком из углов, чтобы не висел над склоном
			var y := INF
			for c: Vector2 in HUT_CORNERS:
				y = minf(y, heights.ground_at(x + c.x, z + c.y))
			# дверью к костру
			var at := Transform3D(Basis(Vector3.UP, atan2(s.x * TILE - x, s.y * TILE - z)), Vector3(x, y, z))
			batch.add(wall_mesh, at.translated_local(Vector3(0, 1.3, 0)), walls[hut.v])
			batch.add(roof_mesh, at * Transform3D(Basis(Vector3.UP, PI / 4.0), Vector3(0, 2.6 + 1.1, 0)), roofs[hut.v])
			batch.add(door_mesh, at.translated_local(Vector3(0, 0.85, 1.62)), door_m)
			batch.add(win_mesh, at.translated_local(Vector3(0.95, 1.6, 1.62)), win_m)
		# костёр
		var fx: float = s.x * TILE
		var fz: float = s.y * TILE
		var fy := heights.ground_at(fx, fz)
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
	for pk in w.peaks:
		var x: float = pk.x * TILE
		var z: float = pk.y * TILE
		var y := heights.ground_at(x, z)
		var at := Transform3D(Basis(), Vector3(x, y, z))
		for rh: Vector2 in PEAK_STONES:
			var sm := SphereMesh.new()
			sm.radius = rh.x
			sm.height = rh.x * 2.0
			sm.radial_segments = 5
			sm.rings = 2
			batch.add(sm, at.translated_local(Vector3(0, rh.y, 0)), stone)
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
	var mi := batch.build("Buildings")
	if mi != null:
		parent.add_child(mi)
	return {fires = fires, labels = labels}


## Покачивание пламени костров; time — секунды игры
static func animate_fires(fires: Array, time: float) -> void:
	for f: Dictionary in fires:
		var t: float = time * 9.0 + f.phase
		var s := 0.85 + sin(t) * 0.1 + sin(t * 1.7) * 0.08
		f.flame.scale = Vector3(1, s, 1)
		f.core.scale = Vector3(1, s * 1.1, 1)
