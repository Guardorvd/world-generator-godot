extends SceneTree
## Один стенд без генерации. Низкое солнце, дерево, камень, столб и земля.
## --before <старый day_cycle.gd> --out <каталог> снимает тот же ракурс до/после.
var fails := 0
var sun: DirectionalLight3D
var environment: Environment
var day: DayCycle
var previous: RefCounted
var camera: Camera3D
var output := "res://.godot/shadow_contact"
var frames := 0
var stage := 0

func check(ok: bool, label: String) -> void:
	print(("OK " if ok else "FAIL ") + label)
	fails += int(not ok)

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 90)
	setup.call_deferred()

func setup() -> void:
	var args := OS.get_cmdline_user_args()
	if args.has("--out"): output = args[args.find("--out") + 1]
	DirAccess.make_dir_recursive_absolute(output)
	RenderingServer.directional_shadow_atlas_set_size(1024, false)
	var world_env := WorldEnvironment.new()
	environment = Environment.new()
	world_env.environment = environment
	root.add_child(world_env)
	sun = DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.shadow_bias = 0.04
	sun.shadow_blur = 1.2
	sun.directional_shadow_blend_splits = true
	sun.directional_shadow_max_distance = 220
	root.add_child(sun)
	day = DayCycle.new(environment, sun)
	if args.has("--before"):
		var source := GDScript.new()
		source.source_code = FileAccess.get_file_as_string(args[args.find("--before") + 1]).replace("class_name DayCycle", "")
		check(source.reload() == OK, "загрузка прежних настроек света")
		previous = source.new(environment, sun)
	var ground := PlaneMesh.new()
	ground.size = Vector2(130, 65)
	# Размер квадрата близок к игровой сетке TILE, а не две гигантские грани.
	ground.subdivide_width = 32
	ground.subdivide_depth = 16
	add_mesh(ground, Vector3(40, 0, 0), Color("c3c7b1"))
	var box := BoxMesh.new()
	box.size = Vector3(2, 3, 2)
	add_mesh(box, Vector3(0, 1.5, 0), Color("bd815f"))
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.15
	trunk.bottom_radius = 0.22
	trunk.height = 4
	add_mesh(trunk, Vector3(0, 2, -10), Color("765c3b"))
	var crown := SphereMesh.new()
	crown.radius = 1.6
	crown.height = 3.2
	add_mesh(crown, Vector3(0, 4, -10), Color("426539"))
	var stone := SphereMesh.new()
	stone.radius = 0.9
	stone.height = 1.2
	add_mesh(stone, Vector3(0, 0.5, 10), Color("8b8d88"))
	camera = Camera3D.new()
	root.add_child(camera)
	# Игровая перспективная камера: каскады теней зависят от её пирамиды видимости.
	camera.fov = 70
	camera.look_at_from_position(Vector3(-12, 8, 20), Vector3(20, 0, 0))
	camera.make_current()
	day.apply(12, 0)
	check(is_equal_approx(sun.shadow_normal_bias, 1.2), "дневное смещение теней сохранено")
	day.apply(17.65, 0)
	check(sun.shadow_normal_bias <= DayCycle.SHADOW_NORMAL_LOW + 0.001, "у горизонта тень не отодвигается большим normal bias")
	check(sun.basis.z.is_equal_approx(DayCycle.sun_direction(17.65)), "свет направлен от настоящего положения солнца")
	var first := DayCycle.sun_direction(17)
	var last := DayCycle.sun_direction(17.65)
	check(Vector2(last.x, last.z).length() / last.y > Vector2(first.x, first.z).length() / first.y,
		"при закате геометрическая длина тени увеличивается")
	apply_light(previous if previous != null else day)
	stage = 1

func add_mesh(mesh: Mesh, at: Vector3, color: Color) -> void:
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.position = at
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 1
	node.material_override = material
	root.add_child(node)

func apply_light(cycle: RefCounted) -> void:
	cycle.apply(17.65, 0)
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("8297aa")
	environment.fog_enabled = false
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_energy = 0.35
	environment.ambient_light_color = Color.WHITE

func _process(_delta: float) -> bool:
	if stage == 0: return false
	frames += 1
	if frames < 8: return false
	var path := output.path_join("before.png" if stage == 1 and previous != null else "after.png")
	var image := root.get_texture().get_image()
	check(image.save_png(path) == OK, "снимок " + path)
	if stage == 2 or previous == null:
		# Свободная полоса плоской земли ниже объектов не должна давать полосы самозатенения.
		var low := 1.0
		var high := 0.0
		for x in range(image.get_width() / 2, image.get_width() - 80):
			var color := image.get_pixel(x, int(image.get_height() * 0.82))
			low = minf(low, color.r)
			high = maxf(high, color.r)
		check(high - low < 0.04, "на земле нет полос самозатенения: " + str(high - low))
	if stage == 1 and previous != null:
		apply_light(day)
		stage = 2
		frames = 0
	else:
		print("SHADOW_CONTACT failures=", fails)
		quit(1 if fails else 0)
	return false
