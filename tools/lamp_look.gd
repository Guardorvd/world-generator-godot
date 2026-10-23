extends SceneTree
## 12.4: изолированная сцена фары велосипеда (bike_lamp.gd) без генерации мира. Ночь, ровная земля с
## дорогой, стволы и камни по сторонам. Снимки: от глаз седока (lamp_rider.png) и сбоку (lamp_side.png).
## «Было» — прошлая версия фары тем же запуском: --lamp <файл .gd>. Нужно окно.
##   godot --path . --script res://tools/lamp_look.gd -- [--out <папка>] [--lamp <файл>] [--tag <суффикс>]

const LAMP_AT := Vector3(0.0, 1.05, 0.0) # фара на руле: высота над землёй

var out := ""
var tag := ""
var camera: Camera3D


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	out = _arg(args, "--out", OS.get_user_data_dir().path_join("lamp_look"))
	tag = _arg(args, "--tag", "")
	DirAccess.make_dir_recursive_absolute(out)
	root.size = Vector2i(1280, 720)
	_build(_arg(args, "--lamp", "res://scripts/render/bike_lamp.gd"))
	_run()


static func _arg(args: PackedStringArray, key: String, def: String) -> String:
	var at := args.find(key)
	return args[at + 1] if at >= 0 and at + 1 < args.size() else def


func _build(lamp_path: String) -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.015, 0.02, 0.035)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.25, 0.3, 0.45)
	e.ambient_light_energy = 0.08
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.fog_enabled = true
	e.fog_light_color = Color(0.02, 0.025, 0.04)
	e.fog_density = 0.01
	env.environment = e
	root.add_child(env)
	var moon := DirectionalLight3D.new()
	moon.light_color = Color(0.6, 0.7, 1.0)
	moon.light_energy = 0.04
	moon.rotation_degrees = Vector3(-40.0, 140.0, 0.0)
	root.add_child(moon)
	var plane := PlaneMesh.new()
	plane.size = Vector2(200, 200)
	_mesh(plane, Vector3.ZERO, Color(0.3, 0.38, 0.22))
	var road := PlaneMesh.new()
	road.size = Vector2(3.0, 200)
	_mesh(road, Vector3(0.0, 0.01, 0.0), Color(0.42, 0.37, 0.3))
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 40:
		var side := -1.0 if i % 2 == 0 else 1.0
		var at := Vector3(side * rng.randf_range(2.8, 14.0), 0.0, -rng.randf_range(2.0, 45.0))
		if i % 5 == 4:
			var rock := SphereMesh.new()
			rock.radius = rng.randf_range(0.3, 0.7)
			rock.height = rock.radius * 1.4
			_mesh(rock, at, Color(0.45, 0.44, 0.42))
		else:
			var trunk := CylinderMesh.new()
			trunk.top_radius = 0.15
			trunk.bottom_radius = 0.22
			trunk.height = 6.0
			_mesh(trunk, at + Vector3(0.0, 3.0, 0.0), Color(0.35, 0.27, 0.2))
	var lamp: Node3D = load(lamp_path).new()
	lamp.position = LAMP_AT
	root.add_child(lamp)
	lamp.set_enabled(true)
	camera = Camera3D.new()
	camera.fov = 75.0
	root.add_child(camera)


func _mesh(mesh: Mesh, at: Vector3, color: Color) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.9
	var m := MeshInstance3D.new()
	m.mesh = mesh
	m.material_override = mat
	m.position = at
	root.add_child(m)


func _shot(name: String, from: Vector3, target: Vector3) -> void:
	camera.look_at_from_position(from, target)
	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out.path_join(name + tag + ".png"))


func _run() -> void:
	await _shot("lamp_rider", Vector3(0.0, 1.75, 0.55), Vector3(0.0, 0.6, -10.0))
	await _shot("lamp_side", Vector3(-7.0, 2.4, 2.0), Vector3(0.0, 0.6, -6.0))
	print("lamp_look: снимки в ", out)
	quit(0)
