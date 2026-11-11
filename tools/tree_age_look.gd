extends SceneTree
## Изолированная линейка возрастных форм деревьев (11.11.2026), без генерации мира: модели строятся напрямую
## (ForestModels.baking = true). По породе ряд: прежние силуэты (было), молодые, взрослые, старые; у каждой формы
## фигура 1,8 м. Снимки сбоку и с высоты глаз велосипедиста 1,6 м снизу вверх — в .godot/tree_age.
## Было — прежняя версия ForestModels, подставленная файлом (--before, по умолчанию .godot/tree_age/forest_models_before.gd,
## в нём убрана строка class_name). Нужно окно. Печатает высоту, радиус кроны и ствола каждой формы.
##   godot --path . --script tools/tree_age_look.gd [-- --only <вид> --before <файл>]

const OUT := "res://.godot/tree_age"
const NEW_CROWN := {Biomes.T_PINE: 0.65, Biomes.T_BIRCH: 0.55, Biomes.T_OAK: 1.05, Biomes.T_SNOWPINE: 0.60}
const NEW_TRUNK := {Biomes.T_PINE: 0.29, Biomes.T_BIRCH: 0.20, Biomes.T_OAK: 0.50, Biomes.T_SNOWPINE: 0.29}
const NAMES := {Biomes.T_PINE: "pine", Biomes.T_BIRCH: "birch", Biomes.T_OAK: "oak", Biomes.T_SNOWPINE: "snowpine"}
var camera: Camera3D
var stand: Node3D
var before: GDScript
var labels := 0


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 150)
	call_deferred("run")


func run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("Для линейки нужен графический рендерер")
		quit(1)
		return
	var args := OS.get_cmdline_user_args()
	var before_path := "res://.godot/tree_age/forest_models_before.gd"
	if args.find("--before") >= 0:
		before_path = args[args.find("--before") + 1]
	if FileAccess.file_exists(before_path):
		before = load(before_path)
	var only := args[args.find("--only") + 1] if args.find("--only") >= 0 else ""
	DirAccess.make_dir_recursive_absolute(OUT)
	ForestModels.baking = true
	RenderingServer.global_shader_parameter_set("veg_center", Vector2.ZERO)
	DisplayServer.window_set_size(Vector2i(1600, 900))
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color("b9ced2")
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color("e5e6d7")
	env.environment.ambient_light_energy = 0.8
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, -30, 0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 260.0
	root.add_child(sun)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(400, 400)
	ground.mesh = plane
	var soil := StandardMaterial3D.new()
	soil.albedo_color = Color("738357")
	ground.material_override = soil
	root.add_child(ground)
	stand = Node3D.new()
	root.add_child(stand)
	camera = Camera3D.new()
	root.add_child(camera)
	camera.current = true
	for kind: int in [Biomes.T_PINE, Biomes.T_BIRCH, Biomes.T_OAK, Biomes.T_SNOWPINE]:
		if only != "" and NAMES[kind] != only:
			continue
		_clear()
		# [определение, подпись]
		var row: Array = []
		if before != null:
			for v in [0, 2]:
				row.append([before.definition(kind, v), "было %d" % v])
		for v: int in ([4, 5, 0, 1, 2, 3, 6, 7] if ForestModels.has_ages(kind) else [0, 1, 2, 3]):
			var age := ForestModels.age_of(v) if ForestModels.has_ages(kind) else 0
			row.append([ForestModels.definition(kind, v), ["взрослая", "молодая", "старая"][age] + " %d" % v])
		var x := 0.0
		var prev_r := 0.0
		var spots: Array[float] = []
		var top := 0.0
		for item: Array in row:
			var def: Dictionary = item[0]
			var stats := _stats(def)
			var r: float = stats.crown_r
			x += prev_r + r + 1.5 if not spots.is_empty() else 0.0
			spots.append(x)
			prev_r = r
			top = maxf(top, stats.height)
			_place(def, kind, x, item[1])
			var table_s: float = def.get("ref", 1.0) if not str(item[1]).begins_with("было") else 1.0
			print("%s %-12s высота %5.1f м  ref %.2f  крона R %.2f м (таблица×s %.2f)  ствол %.2f м (таблица×s %.2f)  треугольников %d" % [
				NAMES[kind], item[1], stats.height, def.get("ref", 1.0), r, NEW_CROWN[kind] * GameConfig.TILE * table_s,
				stats.trunk_r, NEW_TRUNK[kind] * table_s, stats.triangles])
		var width := spots[-1] - spots[0] + 12.0
		var center := (spots[0] + spots[-1]) * 0.5
		camera.fov = 34.0
		var aspect := 1600.0 / 900.0
		var dist := maxf(width * 0.5 / (tan(deg_to_rad(camera.fov * 0.5)) * aspect), (top + 4.0) * 0.5 / tan(deg_to_rad(camera.fov * 0.5))) * 1.05
		camera.look_at_from_position(Vector3(center, top * 0.42, dist), Vector3(center, top * 0.42, 0))
		await _shot("%s_side" % NAMES[kind])
		# С седла: 1,6 м, в нескольких метрах перед взрослой формой и прежней, взгляд вверх.
		var adult_at := spots[(2 if before != null else 0) + (1 if ForestModels.has_ages(kind) else 0) + (AGE_FORMS_OFFSET if ForestModels.has_ages(kind) else 0)]
		camera.fov = 75.0
		camera.look_at_from_position(Vector3(adult_at - 3.0, 1.6, 7.0), Vector3(adult_at, 8.0, -1.0))
		await _shot("%s_eye" % NAMES[kind])
		if before != null:
			camera.look_at_from_position(Vector3(spots[0] - 3.0, 1.6, 7.0), Vector3(spots[0], 8.0, -1.0))
			await _shot("%s_eye_before" % NAMES[kind])
	ForestModels.baking = false
	quit()


## Взрослые формы стоят после двух молодых.
const AGE_FORMS_OFFSET := 2


func _stats(def: Dictionary) -> Dictionary:
	var height := 0.0
	var crown_r := 0.0
	var trunk_r := 0.0
	var triangles := 0
	for part: String in ["trunk", "crown"]:
		if not def.has(part):
			continue
		var mesh: ArrayMesh = def[part]
		var arrays := mesh.surface_get_arrays(0)
		triangles += arrays[Mesh.ARRAY_INDEX].size() / 3
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for p in vertices:
			height = maxf(height, p.y)
			if part == "crown":
				crown_r = maxf(crown_r, Vector2(p.x, p.z).length())
			elif p.y > 1.2 and p.y < 1.4:
				trunk_r = maxf(trunk_r, Vector2(p.x, p.z).length())
	return {height = height, crown_r = crown_r, trunk_r = trunk_r, triangles = triangles}


func _place(def: Dictionary, kind: int, x: float, label: String) -> void:
	var height := 0.3
	for part: String in ["trunk", "crown"]:
		if def.has(part):
			height = maxf(height, (def[part] as Mesh).get_aabb().end.y)
	for part: String in ["trunk", "crown"]:
		if not def.has(part):
			continue
		var node := MeshInstance3D.new()
		node.mesh = def[part]
		node.position.x = x
		var shader := VegetationLayer.CUTOUT_SHADER if part == "crown" else VegetationLayer.TRUNK_SHADER
		var mat := VegetationLayer._wind_mat(shader, VegetationLayer.WIND.get(kind, VegetationLayer.CALM), part == "crown")
		mat.set_shader_parameter("albedo_tex", def.get(part + "_texture"))
		mat.set_shader_parameter("albedo_color", def.leaves[0] if part == "crown" else def.bark)
		mat.set_shader_parameter("use_vertex_color", def.get("colored_bark", false))
		mat.set_shader_parameter("height", height)
		mat.set_shader_parameter("lod_level", -1)
		if part == "crown":
			node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
		node.material_override = mat
		stand.add_child(node)
	# Фигура 1,8 м перед деревом
	var figure := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.25
	capsule.height = 1.8
	figure.mesh = capsule
	figure.position = Vector3(x + 0.9, 0.9, 1.4)
	var red := StandardMaterial3D.new()
	red.albedo_color = Color("d8572a")
	figure.material_override = red
	stand.add_child(figure)
	var text := Label3D.new()
	text.text = label
	text.pixel_size = 0.022
	text.font_size = 64
	text.outline_size = 12
	text.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	labels += 1
	text.position = Vector3(x, 0.6 + 1.6 * (labels % 2), 2.6)
	stand.add_child(text)


func _clear() -> void:
	for child in stand.get_children():
		stand.remove_child(child)
		child.queue_free()


func _shot(name: String) -> void:
	for i in 8:
		await process_frame
	await RenderingServer.frame_post_draw
	var err := root.get_texture().get_image().save_png(OUT.path_join(name + ".png"))
	if err != OK:
		printerr("Не удалось записать снимок: ", err)
