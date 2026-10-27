extends SceneTree
## Витрина подлеска и подстилки с настоящими игровыми материалами, без генерации мира.
const Plants := preload("res://scripts/render/understory_models.gd")
const Floor := preload("res://scripts/render/forest_floor.gd")
var camera: Camera3D
var stand: Node3D
var title: Label
var out := "res://.godot/understory_review"

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("Нужен оконный рендерер")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(out)
	root.size = Vector2i(1280, 720)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color("b6cbd0")
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color("e6e5dc")
	env.environment.ambient_light_energy = 0.65
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, -30, 0)
	sun.shadow_enabled = true
	root.add_child(sun)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(100, 100)
	ground.mesh = plane
	var soil := StandardMaterial3D.new()
	soil.albedo_color = Color("777454")
	ground.material_override = soil
	root.add_child(ground)
	stand = Node3D.new()
	root.add_child(stand)
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	root.add_child(camera)
	camera.current = true
	var ui := CanvasLayer.new()
	root.add_child(ui)
	title = Label.new()
	title.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 25)
	title.add_theme_color_override("font_color", Color("263b35"))
	ui.add_child(title)
	var plants := Plants.meshes()
	var floor_meshes := Floor.meshes()
	var low := [Plants.FERN, Plants.HERB, Plants.FLOWERS, Plants.MUSHROOM, Plants.MOSS]
	for i in low.size():
		add(plants[low[i]], low[i], (i - 2) * 1.2)
	view(Vector3(0, 2.3, -5), Vector3(0, 0.2, 0), 3.5)
	title.text = "Папоротники · разнотравье · цветы · грибы · мох"
	await shot("low")
	clear()
	var shrubs := [Plants.BUSH, Plants.SAPLING, Plants.PINE, Plants.YOUNG, Plants.YOUNG_PINE]
	for i in shrubs.size():
		add(plants[shrubs[i]], shrubs[i], (i - 2) * 2.3)
	view(Vector3(0, 4.5, -10), Vector3(0, 1.4, 0), 6.5)
	title.text = "Кусты и молодняк — ближний вид"
	await shot("shrubs_near")
	RenderingServer.global_shader_parameter_set("veg_center", Vector2(180, 0))
	title.text = "Кусты и молодняк — детали на дальней дистанции"
	await shot("shrubs_far")
	RenderingServer.global_shader_parameter_set("veg_center", Vector2.ZERO)
	clear()
	add(Models.grass_mesh(), -1, -2.8, 6, Color("83a44f"))
	add(plants[Plants.GRASS], Plants.GRASS, -0.95, 4)
	add(plants[Plants.HIGH_GRASS], Plants.HIGH_GRASS, 0.95, 4)
	add(Models.reeds(81), -2, 2.8, 3, Color("a1ad74"))
	view(Vector3(0, 2.5, -7), Vector3(0, 0.65, 0), 4.6)
	title.text = "Низкая и высокая трава · камыш"
	await shot("grasses")
	clear()
	var details := [Floor.LOG, Floor.MOSS_LOG, Floor.STUMP, Floor.BRANCH, Floor.STONES]
	for i in details.size():
		add(floor_meshes[details[i]], Plants.COUNT + details[i], (i - 2) * 4.8)
	view(Vector3(0, 7, -11), Vector3(0, 0.15, 0), 12)
	title.text = "Валежник · мох · пень · ветки · камни"
	await shot("floor")
	print("understory_look: снимки в ", out)
	quit()

func view(from: Vector3, target: Vector3, size: float) -> void:
	camera.size = size
	camera.look_at_from_position(from, target)

func add(mesh: Mesh, kind: int, x: float, count := 1, tint := Color.WHITE) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = count
	for i in count:
		var pos := Vector3(x + (i % 3 - 1) * 0.28 if count > 1 else x, 0, (i / 3) * 0.3)
		mm.set_instance_transform(i, Transform3D(Basis(Vector3.UP, i * 2.4).scaled(Vector3.ONE * (0.9 + i * 0.035)), pos))
		mm.set_instance_color(i, tint)
		mm.set_instance_custom_data(i, Color(0, fposmod(i * 0.618, 1), fposmod(i * 0.337, 1), 0))
	var node := MultiMeshInstance3D.new()
	node.multimesh = mm
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
	var still := kind >= Plants.COUNT or kind in [Plants.MOSS, Plants.MUSHROOM]
	var wind: Array = VegetationLayer.GRASS_WIND if kind == -1 else (VegetationLayer.CALM if still else VegetationLayer._plant_wind(kind))
	var mat := VegetationLayer._wind_mat(VegetationLayer.SHADER, wind, true)
	mat.set_shader_parameter("height", maxf(mesh.get_aabb().end.y, 0.2))
	mat.set_shader_parameter("grass_variation", kind in [-1, Plants.GRASS, Plants.HIGH_GRASS])
	if not still:
		mat.set_shader_parameter("detail_full", 35.0)
		mat.set_shader_parameter("detail_far", 120.0)
		mat.set_shader_parameter("detail_keep", 0.5)
	node.material_override = mat
	stand.add_child(node)

func clear() -> void:
	for node in stand.get_children():
		stand.remove_child(node)
		node.queue_free()

func shot(name: String) -> void:
	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var err := root.get_texture().get_image().save_png(out.path_join(name + ".png"))
	if err != OK:
		printerr(error_string(err))
