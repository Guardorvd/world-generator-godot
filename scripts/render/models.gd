class_name Models
extends RefCounted
## Общая библиотека растительности; деревья (кроме кактуса) строит ForestModels.
## Модели вида: trunk — ствол (цвет bark), crown — крона (цвет из leaves по варианту объекта).
## Новый вид объекта: константа в Biomes.T_* и запись здесь.


static func _cyl(rt: float, rb: float, h: float, seg: int = 8) -> Array:
	var m := CylinderMesh.new()
	m.top_radius = rt
	m.bottom_radius = rb
	m.height = h
	m.radial_segments = seg
	m.rings = 0
	return [m, Transform3D(Basis(), Vector3(0, h / 2.0, 0))]


static func _ico(r: float, y: float, sx: float = 1.0, sy: float = 1.0, sz: float = 1.0) -> Array:
	var m := SphereMesh.new()
	m.radius = r
	m.height = r * 2.0
	m.radial_segments = 10
	m.rings = 5
	return [m, Transform3D(Basis().scaled(Vector3(sx, sy, sz)), Vector3(0, y, 0))]


static func _cone(r: float, h: float, y: float, seg: int = 10) -> Array:
	return _moved(_cyl(0.0, r, h, seg), Vector3(0, y, 0))


## Сдвинуть часть модели
static func _moved(part: Array, offset: Vector3) -> Array:
	var t: Transform3D = part[1]
	return [part[0], Transform3D(t.basis, t.origin + offset)]


## Повернуть часть модели вокруг оси Z (после её собственного сдвига), затем сдвинуть
static func _rotz(part: Array, angle: float, offset: Vector3) -> Array:
	var t: Transform3D = part[1]
	return [part[0], Transform3D(Basis(Vector3.BACK, angle), offset) * t]


## Объединение частей в один меш
static func merge(parts: Array) -> ArrayMesh:
	var st := SurfaceTool.new()
	for p in parts:
		st.append_from(p[0], 0, p[1])
	st.index()
	var source := st.commit()
	var importer := ImporterMesh.new()
	importer.add_surface(Mesh.PRIMITIVE_TRIANGLES, source.surface_get_arrays(0))
	importer.generate_lods(25.0, 60.0, [])
	return importer.get_mesh()


static func _c(r: int, g: int, b: int) -> Color:
	return Color8(r, g, b)


static func tree_defs() -> Dictionary:
	var rock := SphereMesh.new()
	rock.radius = 1.1
	rock.height = 2.2
	rock.radial_segments = 5
	rock.rings = 2
	var defs := {
		Biomes.T_BUSH: {crown = merge([_ico(0.8, 0.55), _moved(_ico(0.6, 0.45), Vector3(0.6, 0, 0.2))]), leaves = [_c(78, 120, 52), _c(96, 130, 56), _c(70, 104, 60)]},
		Biomes.T_CACTUS: {trunk = merge([_cyl(0.28, 0.32, 2.6, 7), _moved(_cyl(0.18, 0.18, 0.9, 6), Vector3(0.5, 1.0, 0)), _moved(_cyl(0.18, 0.18, 0.8, 6), Vector3(-0.5, 1.3, 0))]), bark = _c(79, 138, 60)},
		Biomes.T_ROCK: {crown = merge([[rock, Transform3D(Basis().scaled(Vector3(1.3, 0.75, 1)), Vector3(0, 0.35, 0))]]), leaves = [_c(128, 124, 118), _c(112, 108, 104), _c(140, 132, 120)]},
		Biomes.T_REED: {crown = merge([_cone(0.08, 1.5, 0, 4), _moved(_cone(0.08, 1.2, 0, 4), Vector3(0.3, 0, 0.1)), _moved(_cone(0.08, 1.35, 0, 4), Vector3(-0.2, 0, 0.25))]), leaves = [_c(111, 143, 58), _c(93, 125, 52), _c(120, 140, 70)]},
	}
	for kind in [Biomes.T_OAK, Biomes.T_BIRCH, Biomes.T_PINE, Biomes.T_SNOWPINE, Biomes.T_PALM, Biomes.T_JUNGLE, Biomes.T_ACACIA, Biomes.T_DEAD]:
		for variant in ForestModels.VARIANTS:
			defs[kind + variant * ForestModels.MODEL_STRIDE] = ForestModels.definition(kind, variant)
	return defs


## Пучок травы: пять травинок веером, нормали вверх, чтобы трава освещалась как земля под ней
static func grass_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_normal(Vector3.UP)
	for k in 5:
		var a := (k / 5.0) * PI
		var cx := cos(a) * 0.05
		var cz := sin(a) * 0.05
		var ox := cos(a * 3.1) * 0.16
		var oz := sin(a * 2.3) * 0.16
		var h := 0.32 + (k % 3) * 0.08
		var tx := ox + cos(a + 1.0) * 0.1
		var tz := oz + sin(a + 1.0) * 0.1
		for v: Vector3 in [Vector3(ox - cx, 0, oz - cz), Vector3(ox + cx, 0, oz + cz), Vector3(tx, h, tz)]:
			st.add_vertex(v)
	return st.commit()
