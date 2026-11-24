extends SceneTree
## Изолированная линейка возрастных форм деревьев (11.11.2026), без генерации мира: модели строятся напрямую
## (ForestModels.baking = true). По породе ряд: прежние силуэты (было), молодые, взрослые, старые; у каждой формы
## фигура 1,8 м. Снимки сбоку и с высоты глаз велосипедиста 1,6 м снизу вверх — в .godot/tree_age.
## Было — прежняя версия ForestModels, подставленная файлом (--before, по умолчанию .godot/tree_age/forest_models_before.gd,
## в нём убрана строка class_name). Нужно окно. Печатает высоту, радиус кроны и ствола каждой формы.
##   godot --path . --script tools/tree_age_look.gd [-- --only <вид> --before <файл>]
##   --expedition: формы экспедиции рядом с аналогом, включая LOD1/2.
##   --phase82 --baseline-catalog res://...res: породы фазы 8.2 и парные снимки по старому каталогу.

const OUT := "res://.godot/tree_age"
const EXPEDITION_NAMES := {Biomes.T_SPRUCE: "spruce", Biomes.T_LARCH: "larch", Biomes.T_ALDER: "alder",
	Biomes.T_WESTERN_REDCEDAR: "western_redcedar", Biomes.T_SIBERIAN_CEDAR: "siberian_cedar", Biomes.T_MAPLE: "maple",
	Biomes.T_HEMLOCK: "hemlock", Biomes.T_DOUGLAS_FIR: "douglas_fir"}
const PHASE82 := [Biomes.T_HEMLOCK, Biomes.T_DOUGLAS_FIR, Biomes.T_SPRUCE, Biomes.T_WESTERN_REDCEDAR, Biomes.T_SIBERIAN_CEDAR]
const NAMES := {Biomes.T_PINE: "pine", Biomes.T_BIRCH: "birch", Biomes.T_OAK: "oak", Biomes.T_SNOWPINE: "snowpine", Biomes.T_ROWAN: "rowan", Biomes.T_MUGO: "mugo"}
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
	if args.has("--phase82-composition"):
		await _composition(soil, sun, env.environment)
		ForestModels.baking = false
		quit()
		return
	var phase82 := args.has("--phase82")
	var expedition := phase82 or args.has("--expedition")
	var kinds := PHASE82 if phase82 else (Biomes.EXPEDITION_TREES if expedition else NAMES.keys())
	var baseline: Resource
	var baseline_arg := args.find("--baseline-catalog")
	if baseline_arg >= 0 and baseline_arg + 1 < args.size():
		baseline = load(args[baseline_arg + 1])
	var names := EXPEDITION_NAMES if expedition else NAMES
	for kind: int in kinds:
		if only != "" and names[kind] != only:
			continue
		_clear()
		# [определение, подпись]
		var row: Array = []
		if kind == Biomes.T_MAPLE:
			row.append([ForestModels.definition(Biomes.T_OAK, 0), "дуб", Biomes.T_OAK])
			row.append([ForestModels.definition(Biomes.T_WESTERN_REDCEDAR, 0), "западный кедр", Biomes.T_WESTERN_REDCEDAR])
		elif expedition:
			var analog := Biomes.T_ROWAN if kind == Biomes.T_ALDER else Biomes.T_PINE
			var analog_label := "рябина" if kind == Biomes.T_ALDER else "сосна"
			if kind == Biomes.T_HEMLOCK or kind == Biomes.T_DOUGLAS_FIR:
				analog = Biomes.T_SPRUCE if kind == Biomes.T_HEMLOCK else Biomes.T_WESTERN_REDCEDAR
				analog_label = "горная ель" if kind == Biomes.T_HEMLOCK else "западный кедр"
			row.append([ForestModels.definition(analog, 0), analog_label, analog])
		elif before != null:
			for v in [0, 2]:
				row.append([before.definition(kind, v), "было %d" % v])
		var lead := row.size()
		for v: int in ([4, 5, 0, 1, 2, 3, 6, 7] if ForestModels.has_ages(kind) else [0, 1, 2, 3]):
			var age := ForestModels.age_of(v) if ForestModels.has_ages(kind) else 0
			var label: String = ["взрослая", "молодая", "старая"][age] + " %d" % v
			var def := ForestModels.definition(kind, v)
			var scale := 1.0
			if phase82 and kind in [Biomes.T_HEMLOCK, Biomes.T_SPRUCE] and age == ForestModels.YOUNG_AGE:
				scale = (0.075 if v == ForestModels.YOUNG else 0.14) / def.ref
			row.append([def, label, kind, scale])
		var x := 0.0
		var prev_r := 0.0
		var spots: Array[float] = []
		var top := 0.0
		for item: Array in row:
			var item_kind: int = item[2] if item.size() > 2 else kind
			var def: Dictionary = item[0]
			var stats := _stats(def)
			var scale: float = item[3] if item.size() > 3 else 1.0
			var r: float = stats.crown_r * scale
			x += prev_r + r + 1.5 if not spots.is_empty() else 0.0
			spots.append(x)
			prev_r = r
			top = maxf(top, stats.height * scale)
			_place(def, item_kind, x, item[1], 0, scale)
			var table_s: float = def.get("ref", 1.0) if not str(item[1]).begins_with("было") else 1.0
			print("%s %-12s высота %5.1f м  ref %.2f  крона R %.2f м (таблица×s %.2f)  ствол %.2f м (таблица×s %.2f)  треугольников %d" % [
				names[kind], item[1], stats.height, def.get("ref", 1.0), r, Biomes.CROWN_RADIUS[item_kind] * GameConfig.TILE * table_s,
				stats.trunk_r, StageVegetation.TRUNK[item_kind] * table_s, stats.triangles])
		var width := spots[-1] - spots[0] + 12.0
		var center := (spots[0] + spots[-1]) * 0.5
		camera.fov = 34.0
		var aspect := 1600.0 / 900.0
		var dist := maxf(width * 0.5 / (tan(deg_to_rad(camera.fov * 0.5)) * aspect), (top + 4.0) * 0.5 / tan(deg_to_rad(camera.fov * 0.5))) * 1.05
		camera.look_at_from_position(Vector3(center, top * 0.42, dist), Vector3(center, top * 0.42, 0))
		await _shot("%s_side" % names[kind])
		# С седла: 1,6 м, в нескольких метрах перед взрослой формой и прежней, взгляд вверх.
		var adult_at := spots[lead + (1 if ForestModels.has_ages(kind) else 0) + (AGE_FORMS_OFFSET if ForestModels.has_ages(kind) else 0)]
		camera.fov = 75.0
		camera.look_at_from_position(Vector3(adult_at - 3.0, 1.6, 7.0), Vector3(adult_at, minf(8.0, top * 0.72), -1.0))
		await _shot("%s_eye" % names[kind])
		if kind == Biomes.T_MAPLE:
			var old_at := spots[-1]
			camera.fov = 65.0
			camera.look_at_from_position(Vector3(old_at - 2.0, 2.3, 6.5), Vector3(old_at + 1.2, 4.3, 0))
			await _shot("maple_bark")
			camera.fov = 55.0
			camera.look_at_from_position(Vector3(adult_at - 4.0, 10.0, 10.0), Vector3(adult_at, 12.7, 0))
			await _shot("maple_leaves")
		if expedition:
			camera.fov = 49.0
			camera.look_at_from_position(Vector3(center - dist * 0.42, top * 0.62, dist * 0.74), Vector3(center, top * 0.45, 0))
			await _shot("%s_angle" % names[kind])
			if not phase82:
				sun.rotation_degrees = Vector3(-11, -61, 0)
			else:
				await _shot("%s_low_lod0" % names[kind])
			if kind == Biomes.T_MAPLE:
				await _shot("maple_low_lod0")
			for level in [1, 2]:
				_clear()
				for idx in row.size():
					var item: Array = row[idx]
					_place(item[0], item[2] if item.size() > 2 else kind, spots[idx], item[1], level, item[3] if item.size() > 3 else 1.0)
				await _shot("%s_low_lod%d" % [names[kind], level])
			sun.rotation_degrees = Vector3(-48, -30, 0)
			if baseline != null and baseline.trees.has(kind):
				await _compare(kind, names[kind], baseline)
		elif before != null:
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


func _compare(kind: int, name: String, baseline: Resource) -> void:
	camera.fov = 43.0
	var old := Biomes.T_WESTERN_REDCEDAR == kind or Biomes.T_SIBERIAN_CEDAR == kind
	var variants := [0, 6] if old else [0, 4]
	var height: float = ForestModels.NOMINAL[kind]
	camera.look_at_from_position(Vector3(0, height * 0.54, height * 1.82), Vector3(0, height * 0.54, 0))
	for pass_name in ["before", "after"]:
		_clear()
		for i in variants.size():
			var v: int = variants[i]
			var definition: Dictionary = baseline.trees[kind + v * ForestModels.MODEL_STRIDE] if pass_name == "before" else ForestModels.definition(kind, v)
			_place(definition, kind, (-0.32 if i == 0 else 0.32) * height, "форма %d" % v)
		await _shot("%s_%s" % [name, pass_name])


func _composition(soil: StandardMaterial3D, sun: DirectionalLight3D, env: Environment) -> void:
	var plants := preload("res://scripts/render/understory_models.gd")
	var floor_models := preload("res://scripts/render/forest_floor.gd")
	soil.albedo_color = Color("62513b")
	env.background_color = Color("b5c8c5")
	env.ambient_light_energy = 0.52
	sun.rotation_degrees = Vector3(-38, -126, 0)
	sun.light_energy = 0.70
	for item: Array in [
		[Biomes.T_WESTERN_REDCEDAR, 6, -5.8, 0.5, 1.0], [Biomes.T_DOUGLAS_FIR, 6, 7.4, -2.9, 0.89],
		[Biomes.T_HEMLOCK, 2, -7.8, -12.0, 0.88], [Biomes.T_HEMLOCK, 0, 4.1, -14.0, 0.75],
		[Biomes.T_SPRUCE, 0, 9.1, -18.0, 0.82], [Biomes.T_SIBERIAN_CEDAR, 6, -4.3, -21.5, 0.94],
		[Biomes.T_HEMLOCK, 4, -3.5, -6.3, 0.33], [Biomes.T_SPRUCE, 4, 3.0, -7.8, 0.37],
		[Biomes.T_HEMLOCK, 5, 6.2, 0.1, 0.27], [Biomes.T_SPRUCE, 4, -6.3, -18.7, 0.39],
		[Biomes.T_MAPLE, 0, 3.2, -25.0, 0.80], [Biomes.T_HEMLOCK, 3, -7.2, -30.0, 0.80],
	]:
		_place(ForestModels.definition(item[0], item[1]), item[0], item[2], "", 0, item[4], item[3])
	for i in 15:
		var species: int = [Biomes.T_HEMLOCK, Biomes.T_WESTERN_REDCEDAR, Biomes.T_SPRUCE][i % 3]
		var x := (i % 7 - 3) * 5.5 + sin(i * 2.1) * 2.5
		var z := -32.0 - i * 2.0 + cos(i * 1.9) * 1.5
		_place(ForestModels.definition(species, i % 4), species, x, "", 1, 0.72 + 0.22 * cos(i * 2.1) ** 2.0, z)
	var catalog := preload("res://scripts/render/asset_catalog.gd").get_catalog()
	for item: Array in [
		[floor_models.NURSE_LOG_HOLLOW, Vector3(-5.8, -0.04, -4.0), -0.45],
		[floor_models.NURSE_LOG_LONG, Vector3(7.0, -0.08, -9.4), 0.53],
		[floor_models.ROOT_PLATE, Vector3(-4.2, -0.01, -11.4), -0.8],
		[floor_models.MOSS_BOULDER, Vector3(3.05, -0.02, -1.45), 0.3],
	]:
		_detail(catalog.floor_meshes[item[0]], item[1], item[2], 1.0)
	var shrubs := [plants.SALAL, plants.SALAL_TALL, plants.SWORD_FERN, plants.SWORD_FERN_TALL, plants.DEVILS_CLUB_TALL, plants.BERRY_SHRUB_TALL]
	for i in 38:
		var side := -1.0 if i % 2 == 0 else 1.0
		var x := side * (2.5 + WGRandom.hash2(i, 28, 109) * 6.0)
		var z := 5.3 - i * 0.68 + sin(i * 3.8) * 1.8
		_detail(catalog.understory[shrubs[i % shrubs.size()]], Vector3(x, 0, z), i * 2.399, 0.68 + 0.30 * cos(i * 2.6) ** 2.0)
	var low := [Models.CARPET_MOSS, Models.CARPET_WOODLAND_LEAVES, Models.CARPET_BERRY, Models.CARPET_SEDGE]
	for iz in range(-24, 7):
		for ix in range(-10, 11):
			if absf(ix - sin(iz * 0.30) * 0.55) < 1.4 or WGRandom.hash2(ix, iz, 607) < 0.27:
				continue
			var kind: int = low[int(WGRandom.hash2(floori(ix * 0.43), floori(iz * 0.43), 661) * low.size())]
			var x := ix * 0.82 + (WGRandom.hash2(ix, iz, 677) - 0.5) * 0.52
			var z := iz * 0.95 + (WGRandom.hash2(ix, iz, 683) - 0.5) * 0.65
			_detail(Models.build_carpet_mesh(kind, false), Vector3(x, 0.01, z), iz * 2.399 + ix, 1.02, Color("627744"))
	camera.fov = 69.0
	camera.look_at_from_position(Vector3(0.04, 1.65, 6.85), Vector3(-0.5, 2.5, -12.0))
	await _shot("phase82_all_layers")


func _detail(mesh: Mesh, pos: Vector3, angle: float, model_scale: float, tint := Color.WHITE) -> void:
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.position = pos
	node.rotation.y = angle
	node.scale = Vector3.ONE * model_scale
	var mat := VegetationLayer._wind_mat(VegetationLayer.SHADER, VegetationLayer.CALM, true)
	mat.set_shader_parameter("albedo_color", tint)
	mat.set_shader_parameter("height", maxf(0.2, mesh.get_aabb().end.y))
	node.material_override = mat
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED if mesh.get_aabb().end.y > 0.4 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	stand.add_child(node)


func _place(def: Dictionary, kind: int, x: float, label: String, level := 0, model_scale := 1.0, z := 0.0) -> void:
	var height := 0.3
	for part: String in ["trunk", "crown"]:
		if def.has(part):
			height = maxf(height, (def[part] as Mesh).get_aabb().end.y)
	for part: String in ["trunk", "crown"]:
		if not def.has(part):
			continue
		var node := MeshInstance3D.new()
		node.mesh = ForestModels.lod_meshes(def[part])[level]
		node.position = Vector3(x, 0, z)
		node.scale = Vector3.ONE * model_scale
		var shader := VegetationLayer.CUTOUT_SHADER if part == "crown" else VegetationLayer.TRUNK_SHADER
		var mat := VegetationLayer._wind_mat(shader, VegetationLayer.WIND.get(kind, VegetationLayer.CALM), part == "crown")
		mat.set_shader_parameter("albedo_tex", def.get(part + "_texture"))
		mat.set_shader_parameter("albedo_color", def.leaves[0] if part == "crown" else def.bark)
		mat.set_shader_parameter("use_vertex_color", def.get("colored_bark", false))
		mat.set_shader_parameter("height", height)
		mat.set_shader_parameter("bark_detail", VegetationLayer.bark_detail(kind))
		mat.set_shader_parameter("lod_level", -1)
		if part == "crown":
			node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
		node.material_override = mat
		stand.add_child(node)
	if label.is_empty():
		return
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
