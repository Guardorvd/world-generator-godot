extends RefCounted
## Общий стенд для снимков модели велосипеда и седока (bike_model_look, rider_look): свет игры без мира.
## Окружение — resources/game_environment.tres, солнце и небо — DayCycle в заданный час, качество света и стиль
## кадра — как в игре по умолчанию (Lighting.apply, VisualStyle). Земля — ровная плоскость тона сухого грунта.
## Ключи: --hour <ч> (по умолчанию 10.5), --flat — прежний плоский стенд (серый фон, белый заполняющий свет).
const Lighting := preload("res://scripts/render/lighting_quality.gd")
const GAME_ENVIRONMENT := "res://resources/game_environment.tres"
const DT := 1.0 / 60.0


static func arg(name: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var at := args.find(name)
	return args[at + 1] if at >= 0 and at + 1 < args.size() else fallback


static func setup(root: Window) -> DayCycle:
	var sun := DirectionalLight3D.new()
	root.add_child(sun)
	var env_node := WorldEnvironment.new()
	root.add_child(env_node)
	var cycle: DayCycle = null
	if OS.get_cmdline_user_args().has("--flat"):
		var e := Environment.new()
		e.background_mode = Environment.BG_COLOR
		e.background_color = Color("a6bbc5")
		e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		e.ambient_light_color = Color.WHITE
		e.ambient_light_energy = 0.6
		env_node.environment = e
		sun.rotation_degrees = Vector3(-45.0, -35.0, 0.0)
		sun.shadow_enabled = true
	else:
		var env: Environment = (load(GAME_ENVIRONMENT) as Environment).duplicate()
		env_node.environment = env
		cycle = DayCycle.new(env, sun)
		cycle.world_seed = 7
		cycle.cloud_cover_override = 0.25
		Lighting.apply(env, sun, 2, true)
		sun.directional_shadow_max_distance = 40.0
		VisualStyle.configure(VisualStyle.DEFAULT_ON, VisualStyle.DEFAULT_AMOUNT)
		VisualStyle.bind(env)
		cycle.apply(float(arg("--hour", "10.5")), 0.0)
	var ground := MeshInstance3D.new()
	ground.name = "Ground"
	var plane := PlaneMesh.new()
	plane.size = Vector2(60, 60)
	ground.mesh = plane
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_color = Color(0.43, 0.39, 0.31)
	ground_mat.roughness = 0.95
	ground.material_override = ground_mat
	root.add_child(ground)
	return cycle


## Цена модели: отрисовки (поверхности видимых мешей), из них в тень, треугольники, разные материалы.
static func cost(bike: Node3D) -> String:
	var draws := 0
	var shadow := 0
	var tris := 0
	var mats := {}
	for item: Node in bike.find_children("*", "GeometryInstance3D", true, false):
		var mi := item as MeshInstance3D
		if mi == null or mi.mesh == null or not mi.is_visible_in_tree():
			continue
		var shadows_only := mi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		for s in mi.mesh.get_surface_count():
			var arrays := mi.mesh.surface_get_arrays(s)
			var index: Variant = arrays[Mesh.ARRAY_INDEX]
			if not shadows_only:
				tris += (index.size() if index != null and index.size() > 0 else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
				draws += 1
			if mi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
				shadow += 1
			mats[mi.material_override if mi.material_override else mi.get_active_material(s)] = true
	return "draws=%d shadow_draws=%d tris=%d materials=%d" % [draws, shadow, tris, mats.size()]


## Время отрисовки кадра на процессоре и видеокарте с моделью и без неё (игровая камера уже стоит).
static func measure(tree: SceneTree, bike: Node3D) -> String:
	var vp := tree.root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	var sums := {"model": Vector2.ZERO, "empty": Vector2.ZERO}
	for i in 60:
		await tree.process_frame
	for rep in 4:
		for mode: String in sums:
			bike.visible = mode == "model"
			for i in 10:
				await tree.process_frame
			for i in 60:
				await tree.process_frame
				sums[mode] += Vector2(RenderingServer.viewport_get_measured_render_time_cpu(vp), RenderingServer.viewport_get_measured_render_time_gpu(vp))
	bike.visible = true
	var m: Vector2 = sums.model / 240.0
	var e: Vector2 = sums.empty / 240.0
	return "render CPU %.3f ms (+%.3f model), GPU %.3f ms (+%.3f model), %s" % [m.x, m.x - e.x, m.y, m.y - e.y, RenderingServer.get_current_rendering_method()]
