extends SceneTree
## 11.3: изолированная сцена полотна дорог без генерации мира. Ровный участок 64 × 64 м с метровой сеткой,
## извилистая дорога одного покрытия; цвет вершин и UV2 считаются так же, как RoadRefinement._vertex
## (маска кромки, поперечная координата, номер покрытия). Материал — TerrainBuilder.material.
## Снимки: вид с велосипеда и сверху-сбоку для каждого покрытия. Нужно окно (не headless).
##   godot --path . --script res://tools/road_look.gd -- [--out <папка>] [--surfaces 1,2,6,7] [--shader <файл>]
## --shader — другой код шейдера рельефа (например, прошлая версия) для сравнения «было | стало».
## --obstacles — 11.6: на полотне ветка, камни, бревно поперёк и валун у края (модели подстилки, цвет вершин).
## --shift x,z — 12.3: сдвиг участка в мире (м): поля RoadBump (разбитые участки, колеи, ямы) — в мировых координатах.

const TerrainBuilderScript := preload("res://scripts/render/terrain_builder.gd")
const Floor := preload("res://scripts/render/forest_floor.gd")
const SIZE := 64        # м, сторона участка
const SETTLE := 8       # кадров до снимка
const WINDOW := Vector2i(1280, 720)

var out := ""
var surfaces: Array[int] = [1, 2, 3, 4, 5, 6, 7]
var shader_path := ""
var shift := Vector3.ZERO
var mesh_node: MeshInstance3D
var camera: Camera3D
var shots: Array[Dictionary] = []
var shot := -1
var wait := 0
var noise := FastNoiseLite.new()


func _arg(name: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--" + name)
	return args[at + 1] if at >= 0 and at + 1 < args.size() else fallback


func _initialize() -> void:
	out = _arg("out", OS.get_user_data_dir().path_join("road_look"))
	DirAccess.make_dir_recursive_absolute(out)
	shader_path = _arg("shader", "")
	var moved := _arg("shift", "0,0").split(",")
	shift = Vector3(float(moved[0]), 0.0, float(moved[1]))
	var list := _arg("surfaces", "")
	if list != "":
		surfaces.clear()
		for s in list.split(","):
			surfaces.append(int(s))
	noise.seed = 1234
	noise.frequency = 1.0
	noise.fractal_octaves = 2
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.environment.background_mode = Environment.BG_SKY
	env.environment.sky = sky
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55.0, 35.0, 0.0)
	sun.shadow_enabled = false
	root.add_child(sun)
	mesh_node = MeshInstance3D.new()
	mesh_node.position = shift
	root.add_child(mesh_node)
	camera = Camera3D.new()
	camera.fov = 70.0
	camera.far = 400.0
	root.add_child(camera)
	camera.make_current()
	if "--obstacles" in OS.get_cmdline_user_args():
		_obstacles()
	for s in surfaces:
		shots.append({surface = s, name = "low", pos = Vector3(_axis(6.0) , 1.45, 6.0), target = Vector3(_axis(20.0), 0.6, 20.0)})
		shots.append({surface = s, name = "high", pos = Vector3(_axis(10.0) + 5.0, 4.5, 8.0), target = Vector3(_axis(16.0), 0.0, 16.0)})


## Препятствия RoadObstacles на оси дороги: ветка, камни, бревно поперёк (с перекосом) и валун у края
func _obstacles() -> void:
	var meshes := Floor.meshes()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.9
	for item: Array in [[Floor.BRANCH, 10.0, 0.4, 1.0], [Floor.STONES, 14.0, -0.5, 1.0], [Floor.LOG, 19.0, 0.0, 0.85], [Floor.BOULDER, 25.0, 1.0, 0.85]]:
		var z: float = item[1]
		var tangent := Vector2(_axis(z + 0.05) - _axis(z), 0.05).normalized()
		var side := Vector2(-tangent.y, tangent.x)
		var at := Vector2(_axis(z), z) + side * float(item[2])
		var node := MeshInstance3D.new()
		node.mesh = meshes[item[0]]
		node.material_override = mat
		var rot := atan2(-side.y, side.x) + (0.3 if item[0] == Floor.LOG else 1.1)
		node.transform = Transform3D(Basis(Vector3.UP, rot).scaled(Vector3.ONE * float(item[3])), Vector3(at.x, -0.015, at.y))
		root.add_child.call_deferred(node)


## Ось дороги: x по z, плавный изгиб
func _axis(z: float) -> float:
	return SIZE * 0.5 + 6.0 * sin(z / 11.0)


func _half(surface: int) -> float:
	return 1.0 if surface == RoadSurface.FOREST or surface == RoadSurface.MEADOW else 1.7


## Ближайшая точка оси (перебор по 5 см) — расстояние и знак стороны
func _nearest(x: float, z: float) -> Vector2:
	var best := INF
	var side := 0.0
	var zz := z - 8.0
	while zz <= z + 8.0:
		var a := Vector2(_axis(zz), zz)
		var d := Vector2(x, z).distance_to(a)
		if d < best:
			best = d
			var tangent := Vector2(_axis(zz + 0.05) - a.x, 0.05).normalized()
			side = signf((Vector2(x, z) - a).cross(tangent))
		zz += 0.05
	return Vector2(best, side)


func _build(surface: int) -> void:
	var data: Dictionary = RoadSurface.LIST[surface]
	var half := _half(surface)
	var n := SIZE + 1
	var pos := PackedVector3Array()
	var nor := PackedVector3Array()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var colors := PackedColorArray()
	for z in n:
		for x in n:
			pos.append(Vector3(x, 0.0, z))
			nor.append(Vector3.UP)
			uv.append(Vector2(x / float(SIZE), z / float(SIZE)))
			var near := _nearest(x, z)
			var d := near.x
			if d > half + RoadRefinement.REACH:
				colors.append(Color(0, 0, 0, 0))
				uv2.append(Vector2.ZERO)
				continue
			# Как RoadRefinement._vertex: несимметричные края и обочина, примесь подстилки
			var slow := noise.get_noise_2d(x * 0.13, z * 0.13)
			var grain := noise.get_noise_2d(x * 0.8 + 71.0, z * 0.8)
			var edge := half + slow * 0.24 + grain * 0.10
			var shoulder := 0.7 + (slow + 1.0) * 0.3
			var organic: float = data.organic
			var color := Color8(data.color[0], data.color[1], data.color[2]).srgb_to_linear()
			var visual_edge := edge * (1.0 - organic * 0.12)
			var visual_shoulder := shoulder * (1.0 + organic * 0.5)
			color.a = (1.0 - smoothstep(visual_edge * 0.55, visual_edge + visual_shoulder, d)) * (1.0 - organic * 0.35)
			if surface == RoadSurface.MEADOW:
				color.a *= 0.65
			colors.append(color)
			uv2.append(Vector2(near.y * d / half, float(surface)))
	var idx := PackedInt32Array()
	for z in SIZE:
		for x in SIZE:
			var a := z * n + x
			idx.append_array([a, a + 1, a + n, a + 1, a + n + 1, a + n])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = nor
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	# Карта биомов: трава с лёгкими пятнами, 2 пикселя на метр
	var base := Image.create(SIZE * 2, SIZE * 2, false, Image.FORMAT_RGB8)
	for y in base.get_height():
		for x in base.get_width():
			var v := noise.get_noise_2d(x * 0.05, y * 0.05) * 0.06
			base.set_pixel(x, y, Color(0.34 + v, 0.52 + v, 0.20 + v * 0.5))
	var mat: ShaderMaterial = TerrainBuilderScript.material(base)
	if shader_path != "":
		var code := FileAccess.get_file_as_string(shader_path)
		var sh := Shader.new()
		sh.code = code
		mat.shader = sh
	mesh.surface_set_material(0, mat)
	mesh_node.mesh = mesh


func _process(_delta: float) -> bool:
	if shot < 0:
		DisplayServer.window_set_size(WINDOW)
		shot = 0
		_place()
		return false
	wait += 1
	if wait < SETTLE:
		return false
	var s: Dictionary = shots[shot]
	var path := out.path_join("road_%d_%s.jpg" % [s.surface, s.name])
	root.get_texture().get_image().save_jpg(path, 0.92)
	print("Снимок: ", path)
	shot += 1
	wait = 0
	if shot >= shots.size():
		quit(0)
		return true
	_place()
	return false


func _place() -> void:
	var s: Dictionary = shots[shot]
	if shot == 0 or shots[shot - 1].surface != s.surface:
		_build(s.surface)
	camera.look_at_from_position(s.pos + shift, s.target + shift, Vector3.UP)
