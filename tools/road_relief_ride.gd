extends SceneTree
## godot --path . --script res://tools/road_relief_ride.gd
## Production BikeRide/BikeController and the actual terrain mesh. Tab: A/B, 1..3: lanes, R: restart.
const Fixture := preload("res://tools/road_relief_fixture.gd")
var w: WorldData
var h: Heightfield
var mesh_node := MeshInstance3D.new()
var camera := Camera3D.new()
var label := Label.new()
var bike := BikeRide.new()
var player := PlayerState.new()
var controller := BikeController.new()
var view: BikeView
var lane := 1
var enabled := true
var capture := false
var real_seed := ""
var review := {}
var baseline_patches := {}

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 90 if "--capture" in OS.get_cmdline_user_args() else 1800)
	run.call_deferred()

func run() -> void:
	root.size = Vector2i(1280, 720)
	root.window_input.connect(_input)
	var args := OS.get_cmdline_user_args()
	if "--real" in args: real_seed = args[args.find("--real") + 1]
	if real_seed.is_empty():
		w = Fixture.world()
		h = Heightfield.new(w, false)
	else:
		var dir := "res://tools/control/runs/road_relief/"
		var saved: Dictionary = FileAccess.open(dir + real_seed + ".fixture.bin", FileAccess.READ).get_var()
		w = WorldCache.new()._restore(saved.world, true)
		h = preload("res://scripts/game/surface_snapshot.gd").restore(w, saved.base, "base")
		baseline_patches = FileAccess.open(dir + real_seed + "_before_patches.bin", FileAccess.READ).get_var()
		var rows: Array = JSON.parse_string(FileAccess.get_file_as_string(dir + "profiles.json"))
		for row: Dictionary in rows:
			if row.label == real_seed and row.kind == "road": review = row
	RoadBed.refine(h); h.build_structures()
	root.add_child(mesh_node)
	var material := ShaderMaterial.new()
	var shader := Shader.new()
	# Show the actual triangles with soft oblique lighting. No visual displacement.
	shader.code = "shader_type spatial; render_mode cull_disabled; void fragment(){ float road=COLOR.a; ALBEDO=mix(vec3(0.19,0.27,0.12),COLOR.rgb,road); ROUGHNESS=1.0; }"
	material.shader = shader
	mesh_node.material_override = material
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.55, 0.70, 0.85)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color.WHITE
	env.environment.ambient_light_energy = 0.4
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-18, -45, 0)
	sun.shadow_enabled = true
	root.add_child(sun)
	root.add_child(camera)
	camera.far = 1000
	camera.current = true
	label.position = Vector2(20, 20)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_shadow_color", Color.BLACK)
	label.add_theme_constant_override("shadow_outline_size", 4)
	root.add_child(label)
	view = load("res://scenes/bike.tscn").instantiate() as BikeView
	root.add_child(view)
	capture = "--capture" in OS.get_cmdline_user_args()
	rebuild()
	if capture:
		for state in [false, true]:
			enabled = state
			rebuild()
			var focus := Vector2(135, 194)
			var tangent := Vector2.RIGHT
			if not review.is_empty():
				var at := 10
				for j in range(10, review.samples.size() - 10):
					if absf(review.samples[j][4] - review.samples[j][3]) > absf(review.samples[at][4] - review.samples[at][3]): at = j
				focus = Vector2(review.samples[at][1], review.samples[at][2])
				tangent = (Vector2(review.samples[at + 5][1], review.samples[at + 5][2]) - focus).normalized()
			var side := Vector2(-tangent.y, tangent.x)
			var from := focus - tangent * 15 + side * 4
			camera.position = Vector3(from.x, h.ground_at(from.x, from.y) + 1.5, from.y)
			camera.look_at(Vector3(focus.x, h.ground_at(focus.x, focus.y) + 0.15, focus.y))
			view.visible = false
			for i in 8: await process_frame
			await RenderingServer.frame_post_draw
			var path := "res://tools/control/runs/road_relief/%s_%s.png" % ["stand" if real_seed.is_empty() else real_seed, "after" if state else "before"]
			DirAccess.make_dir_recursive_absolute(path.get_base_dir())
			root.get_texture().get_image().save_png(path)
		quit()

func rebuild() -> void:
	RoadRefinement.natural_relief = enabled
	h.road_refinement = RoadRefinement.build(h) if enabled or baseline_patches.is_empty() else RoadRefinement.from_patches(baseline_patches, w.H)
	var arrays := TerrainBuilder.build_arrays(w, h)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh_node.mesh = mesh
	reset()

func reset() -> void:
	bike = BikeRide.new(); player = PlayerState.new(); controller = BikeController.new()
	bike.x = 50; bike.z = (16.5 + lane * 32) * 4; bike.heading = -PI * 0.5
	if not review.is_empty():
		var sample: Array = review.samples[mini(30, review.samples.size() - 2)]
		var next: Array = review.samples[mini(35, review.samples.size() - 1)]
		bike.x = sample[1]; bike.z = sample[2]
		bike.heading = atan2(-(next[1] - sample[1]), -(next[2] - sample[2]))
	bike.y = h.ground_at(bike.x, bike.z)
	bike.mount(player)
	view.tick(bike, 0.0, 0.0); view.draw(1.0)

func _input(event: InputEvent) -> void:
	if capture or not event is InputEventKey or not event.pressed or event.echo: return
	var key: int = event.physical_keycode if event.physical_keycode != 0 else event.keycode
	match key:
		KEY_TAB: enabled = not enabled; rebuild()
		KEY_R: reset()
		KEY_1, KEY_2, KEY_3: lane = key - KEY_1; reset()
		KEY_ESCAPE: quit()

func _physics_process(dt: float) -> bool:
	if h == null or capture: return false
	var throttle := Input.get_axis("move_back", "move_forward")
	var steer := Input.get_axis("move_left", "move_right")
	controller.ride(dt, player, bike, w, h, throttle, steer, Input.is_action_pressed("run"), Input.is_action_just_pressed("jump"), false)
	view.tick(bike, dt, throttle)
	if real_seed.is_empty() and (bike.x > 345 or bike.x < 30): reset()
	return false

func _process(_dt: float) -> bool:
	if h == null: return false
	var surface_name: String = ["гравий", "грунтовка", "лесная тропа"][lane] if real_seed.is_empty() else "%s / дорога %d" % [real_seed, review.get("route", -1)]
	label.text = "Средние формы: %s | %s | %.1f км/ч\nW/S — педали/тормоз, A/D — руль, Space — прыжок\nTab — сравнить, 1/2/3 — гравий/грунт/лесная тропа, R — старт\nПодвеска: %.1f / %.1f см%s" % ["ВКЛ" if enabled else "ВЫКЛ", surface_name, bike.speed * 3.6, bike.squash_f * 100, bike.squash_r * 100, " | падение: R" if bike.crashed else ""]
	if capture: return false
	view.draw(Engine.get_physics_interpolation_fraction())
	var forward := Vector3(-sin(bike.heading), 0, -cos(bike.heading))
	var target := Vector3(bike.x, bike.y + 0.9, bike.z)
	camera.position = target - forward * 4.5 + Vector3.UP * 1.8
	camera.look_at(target + forward * 2)
	return false
