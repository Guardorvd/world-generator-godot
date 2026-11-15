extends SceneTree
## 11.3: изолированная сцена полотна дорог без генерации мира. Ровный участок 64 × 64 м с метровой сеткой,
## извилистая дорога одного покрытия; цвет вершин и UV2 считаются так же, как RoadRefinement._vertex
## (маска кромки, поперечная координата, номер покрытия). Материал — GameContext.scope.terrain.material.
## Снимки: вид с велосипеда и сверху-сбоку для каждого покрытия. Нужно окно (не headless).
##   godot --path . --script res://tools/road_look.gd -- [--out <папка>] [--surfaces 1,2,6,7] [--shader <файл>]
## --shader — другой код шейдера рельефа (например, прошлая версия) для сравнения «было | стало».
## --obstacles — 11.6: на полотне ветка, камни, бревно поперёк и валун у края (модели подстилки, цвет вершин).
## --shift x,z — 12.3: сдвиг участка в мире (м): поля RoadBump (разбитые участки, колеи, ямы) — в мировых координатах.
## --style <сила> — 13.11: глобальный параметр «Планы» визуального стиля (resources/depth_tone.gdshaderinc), читаемость полотна с ним и без.
## --wet <0..1> — 15.11: влажность почвы участка (сырое полотно: потемнение, блеск впадин).
## --relief — 15.11: участок с формами коридора (корыто полотна, валик и канава обочин, продольные волны) вместо плоскости.
## --grade <уклон> — 15.11 (4): продольный уклон участка вдоль z (промоины грунта появляются с ~3 %).
## --sun <градусы> — высота солнца (по умолчанию 55); ниже 50 включаются тени: объём виден при низком свете.
## --stones — 15.11: россыпь камней и комьев у полотна (GroundCarpet.road_stone, та же раскладка, что в игре; материал простой).
## --detail <качество>,<дальность> — 15.11: уровни настройки графики (0 — простое, 0.5 — среднее, 1 — высокое; дальность 0.6 / 1 / 1.6).
## --diagonal — прямая дорога наискосок к метровой сетке (~24°): кромка без ступенек сетки (15.11).
## --measure — 120 кадров на ракурс после прогрева, timings.json: CPU/GPU/кадр. Изолированный стенд, не игровой FPS.

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
var measure := false
var relief := false
var grade := 0.0
var diagonal := false
var stones_node: MultiMeshInstance3D
var frame_times := PackedFloat32Array()
var gpu_times := PackedFloat32Array()
var cpu_times := PackedFloat32Array()
var timings := []


func _arg(name: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--" + name)
	return args[at + 1] if at >= 0 and at + 1 < args.size() else fallback


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	out = _arg("out", OS.get_user_data_dir().path_join("road_look"))
	DirAccess.make_dir_recursive_absolute(out)
	shader_path = _arg("shader", "")
	# 13.11: --style <сила 0..1> — «Планы» визуального стиля (тон по расстоянию в шейдере рельефа) на этом участке
	var style_strength := float(_arg("style", "0"))
	if style_strength > 0.0:
		RenderingServer.global_shader_parameter_set("style_depth", Vector4(style_strength, style_strength, style_strength, 1.0))
	# 15.11: --detail <качество 0..1>,<множитель дальности> — настройка «Дороги: детализация и дальность» (road_detail)
	var detail := _arg("detail", "1,1").split(",")
	RenderingServer.global_shader_parameter_set("road_quality", Vector2(float(detail[0]), float(detail[1]) if detail.size() > 1 else 1.0))
	measure = "--measure" in OS.get_cmdline_user_args()
	if measure:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0
		RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
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
	var sun_height := float(_arg("sun", "55"))
	sun.rotation_degrees = Vector3(-sun_height, 35.0, 0.0)
	sun.shadow_enabled = sun_height < 50.0
	sun.directional_shadow_max_distance = 60.0
	relief = "--relief" in OS.get_cmdline_user_args()
	grade = float(_arg("grade", "0"))
	diagonal = "--diagonal" in OS.get_cmdline_user_args()
	# направление на светило для шейдера рельефа (в игре его ставит DayCycle)
	RenderingServer.global_shader_parameter_set("sun_dir", sun.global_transform.basis.z if sun.is_inside_tree() else sun.transform.basis.z)
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
	# 15.0: корни через тропу (растянуты на ширину полотна, наискосок), бревно у кромки наискосок, утоплено
	for item: Array in [[Floor.BRANCH, 10.0, 0.4, 1.0], [Floor.STONES, 14.0, -0.5, 1.0], [Floor.LOG, 19.0, 0.0, 0.85], [Floor.BOULDER, 25.0, 1.0, 0.85],
			[Floor.ROOT_SPAN, 8.0, 0.0, 1.1], [Floor.ROOT_SPAN, 8.7, 0.2, 0.8], [Floor.LOG, 30.0, 1.6, 0.8]]:
		var z: float = item[1]
		var tangent := Vector2(_axis(z + 0.05) - _axis(z), 0.05).normalized()
		var side := Vector2(-tangent.y, tangent.x)
		var at := Vector2(_axis(z), z) + side * float(item[2])
		var node := MeshInstance3D.new()
		node.mesh = meshes[item[0]]
		node.material_override = mat
		var rot := atan2(-side.y, side.x) + (0.3 if item[0] == Floor.LOG else (0.5 if item[0] == Floor.ROOT_SPAN else 1.1))
		if item[1] > 28.0: rot += 1.1 # бревно у кромки наискосок
		var xf := Transform3D(Basis(Vector3.UP, rot).scaled(Vector3.ONE * float(item[3])), Vector3(at.x, -0.015 - (0.04 if item[0] == Floor.LOG else 0.0), at.y))
		if item[0] == Floor.ROOT_SPAN: xf.basis.x *= 4.4 / float(item[3]) # длина корня 4,4 м
		node.transform = xf
		root.add_child.call_deferred(node)


## Ось дороги: x по z, плавный изгиб
func _axis(z: float) -> float:
	if diagonal:
		return SIZE * 0.5 + 0.45 * (z - SIZE * 0.5)
	return SIZE * 0.5 + 6.0 * sin(z / 11.0)


## 15.11: высота участка с формами коридора: продольные волны, корыто полотна, обочины как RoadRefinement._vertex
## (вал > 0 у кромки, канава < 0 дальше, по сторонам и вдоль пути то одно, то другое; величины — таблица CORRIDOR дорог)
func _height(x: float, z: float, d: float, half: float, side := 1.0) -> float:
	if not relief:
		return grade * z
	var y := grade * z + 0.35 * sin(z / 9.0) + 0.12 * sin(x / 13.0 + 1.0)
	y -= 0.07 * (1.0 - smoothstep(half * 0.5, half + 0.4, d))
	var e := d - half
	var v := side * (0.6 * sin(z / 7.0) + 0.4 * sin(z / 3.1 + 1.0))
	v = v * 0.10 if v > 0.0 else v * 0.28
	y += v * RoadRefinement._bell((e - 0.35) / 0.8) if v > 0.0 else v * RoadRefinement._bell((e - 0.85) / 0.65)
	return y


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
	var road_kind := surface != RoadSurface.FOREST and surface != RoadSurface.MEADOW and surface != RoadSurface.STONE
	var n := SIZE + 1
	var pos := PackedVector3Array()
	var nor := PackedVector3Array()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var colors := PackedColorArray()
	for z in n:
		for x in n:
			var near := _nearest(x, z)
			pos.append(Vector3(x, _height(x, z, near.x, half, near.y), z))
			nor.append(Vector3.UP)
			uv.append(Vector2(x / float(SIZE), z / float(SIZE)))
			var d := near.x
			if d > half + RoadRefinement.REACH:
				colors.append(Color(0, 0, 0, 0))
				uv2.append(Vector2.ZERO)
				continue
			# Как RoadRefinement._vertex: несимметричные края и обочина, примесь подстилки
			var slow := noise.get_noise_2d(x * 0.13, z * 0.13)
			var organic: float = data.organic
			var color := Color8(data.color[0], data.color[1], data.color[2]).srgb_to_linear()
			var road := road_kind
			color.a = RoadRefinement.tread_mask(half, d, slow, organic, road)
			colors.append(color)
			uv2.append(Vector2(near.y * d / half, float(surface) + (0.0 if road else 0.25)))
	if relief or grade != 0.0:
		for z in n:
			for x in n:
				var a := pos[z * n + maxi(x - 1, 0)].y - pos[z * n + mini(x + 1, SIZE)].y
				var b := pos[maxi(z - 1, 0) * n + x].y - pos[mini(z + 1, SIZE) * n + x].y
				nor[z * n + x] = Vector3(a, 2.0, b).normalized()
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
	var mat: ShaderMaterial = GameContext.scope.terrain.material(base)
	# 15.11: --wet <0..1> — влажность почвы на участке (канал B текстуры леса), по умолчанию как раньше 0,45
	var wet := float(_arg("wet", "-1"))
	if wet >= 0.0:
		var damp := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		damp.set_pixel(0, 0, Color(0.0, 0.0, wet, 0.0))
		mat.set_shader_parameter("forest_tex", ImageTexture.create_from_image(damp))
		mat.set_shader_parameter("forest_enabled", true)
	if shader_path != "":
		var code := FileAccess.get_file_as_string(shader_path)
		var sh := Shader.new()
		sh.code = code
		mat.shader = sh
	mesh.surface_set_material(0, mat)
	mesh_node.mesh = mesh
	if "--stones" in OS.get_cmdline_user_args():
		_stones(surface, half, road_kind)


## Россыпь у полотна: те же правила и модель, что у GroundCarpet._road_stones
func _stones(surface: int, half: float, road: bool) -> void:
	if stones_node == null:
		stones_node = MultiMeshInstance3D.new()
		var mat := StandardMaterial3D.new()
		mat.vertex_color_use_as_albedo = true
		mat.vertex_color_is_srgb = true
		mat.roughness = 1.0
		stones_node.material_override = mat
		stones_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mesh_node.add_child(stones_node)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = Models.build_carpet_mesh(Models.CARPET_STONES, false)
	var data: Array = []
	var step := 4.0 / GroundCarpet.STONE_SUB
	var cells := int(SIZE / step)
	var organic: float = RoadSurface.LIST[surface].organic
	for gz in cells:
		for gx in cells:
			var x := (gx + WGRandom.hash2(gx, gz, 311)) * step
			var z := (gz + WGRandom.hash2(gx, gz, 313)) * step
			var near := _nearest(x, z)
			if near.x > half + RoadRefinement.REACH:
				continue
			var weight := RoadRefinement.tread_mask(half, near.x, noise.get_noise_2d(x * 0.13, z * 0.13), organic, road)
			var h := WGRandom.hash2(gx, gz, 317)
			var size := GroundCarpet.road_stone(weight, near.x / half, surface, road, h, GroundCarpet.stone_clump(x, z))
			if size <= 0.0:
				continue
			data.append([Transform3D(Basis(Vector3.UP, h * TAU * 7.0).scaled_local(Vector3.ONE * size), Vector3(x, _height(x, z, near.x, half, near.y), z)),
				GroundCarpet.road_stone_tint(surface, WGRandom.hash2(gx, gz, 331))])
	mm.instance_count = data.size()
	for n in data.size():
		mm.set_instance_transform(n, data[n][0])
		mm.set_instance_color(n, data[n][1])
	stones_node.multimesh = mm
	print("россыпь: ", data.size(), " на покрытии ", surface)


func _process(delta: float) -> bool:
	if shot < 0:
		DisplayServer.window_set_size(WINDOW)
		shot = 0
		_place()
		return false
	wait += 1
	if wait < SETTLE:
		return false
	if measure and frame_times.size() < 120:
		frame_times.append(delta * 1000.0)
		gpu_times.append(RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid()))
		cpu_times.append(RenderingServer.viewport_get_measured_render_time_cpu(root.get_viewport_rid()))
		return false
	var s: Dictionary = shots[shot]
	if measure:
		frame_times.sort(); gpu_times.sort(); cpu_times.sort()
		var row := {surface = s.surface, view = s.name, frame_ms = frame_times[60], gpu_ms = gpu_times[60], cpu_ms = cpu_times[60], p99_ms = frame_times[118]}
		timings.append(row)
		print("TIMING ", JSON.stringify(row))
		frame_times.clear(); gpu_times.clear(); cpu_times.clear()
	var path := out.path_join("road_%d_%s.jpg" % [s.surface, s.name])
	root.get_texture().get_image().save_jpg(path, 0.92)
	print("Снимок: ", path)
	shot += 1
	wait = 0
	if shot >= shots.size():
		if measure: FileAccess.open(out.path_join("timings.json"), FileAccess.WRITE).store_string(JSON.stringify(timings, "\t"))
		quit(0)
		return true
	_place()
	return false


func _place() -> void:
	var s: Dictionary = shots[shot]
	if shot == 0 or shots[shot - 1].surface != s.surface:
		_build(s.surface)
	var lift := Vector3(0.0, _height(s.pos.x, s.pos.z, 0.0, 1.0) + (0.07 if relief else 0.0), 0.0)
	camera.look_at_from_position(s.pos + shift + lift, s.target + shift + lift, Vector3.UP)
