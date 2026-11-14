extends SceneTree
## Изолированный стенд для визуальной и производительной проверки парковых гирлянд
## (днём, в сумерки и ночью, спереди и крупным планом, для Forward+ и Compatibility).

class FlatHeightfield extends Heightfield:
	func _init() -> void:
		pass

	func _cell_list(_x: float, _z: float) -> Variant:
		return null

	func ground_at(_x: float, _z: float, _raw: bool = false) -> float:
		return 0.0

	func surface_at(_x: float, _z: float, _feet: float) -> float:
		return -INF

	func depth_at(_x: float, _z: float, _feet: float = -INF) -> float:
		return 0.0


var _failed := 0


func check(cond: bool, msg: String) -> void:
	if not cond:
		_failed += 1
		push_error("FAIL: " + msg)
		print("FAIL: " + msg)


func _init() -> void:
	preload("res://tools/watchdog.gd").arm(self, 90)
	call_deferred("_run")


func _arg_out() -> String:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--out" and i + 1 < args.size():
			return args[i + 1]
	return "C:/Users/Luisa/.gemini/antigravity/brain/44eb5250-7780-43db-ba32-300f67c40327/scratch/garland_look"


func _run() -> void:
	var out_dir := _arg_out()
	var headless := DisplayServer.get_name() == "headless"
	var method := RenderingServer.get_current_rendering_method()
	var tag := "gl" if method != "forward_plus" else "fp"
	print("garland_look: renderer=%s headless=%s" % [method, str(headless)])

	var scene := Node3D.new()
	root.add_child(scene)

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.fog_enabled = true
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	var we := WorldEnvironment.new()
	we.environment = env
	scene.add_child(we)

	var sun := DirectionalLight3D.new()
	scene.add_child(sun)

	var day := DayCycle.new(env, sun)
	preload("res://scripts/render/lighting_quality.gd").apply(env, sun, 2, true, 2)
	VisualStyle.bind(env)
	VisualStyle.configure(VisualStyle.DEFAULT_ON, VisualStyle.DEFAULT_AMOUNT)

	# Плоская лесная поляна и грунтовая дорога шириной ~4.6 м с мягким изгибом по X.
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(180.0, 180.0)
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.18, 0.23, 0.14)
	gmat.roughness = 0.96
	ground.mesh = plane
	ground.material_override = gmat
	scene.add_child(ground)

	var road_pts := PackedVector2Array()
	var road_widths := PackedFloat32Array()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var steps := 24
	for i in steps:
		var z := lerpf(-34.0, 34.0, float(i) / float(steps - 1))
		var x := sin(z * 0.055) * 2.1
		road_pts.append(Vector2(x, z))
		road_widths.append(2.3)
	for i in range(road_pts.size() - 1):
		var a := road_pts[i]
		var b := road_pts[i + 1]
		var tangent := (b - a).normalized()
		var n := Vector2(-tangent.y, tangent.x) * 2.3
		var v0 := Vector3(a.x - n.x, 0.015, a.y - n.y)
		var v1 := Vector3(a.x + n.x, 0.015, a.y + n.y)
		var v2 := Vector3(b.x - n.x, 0.015, b.y - n.y)
		var v3 := Vector3(b.x + n.x, 0.015, b.y + n.y)
		for tri: Vector3 in [v0, v2, v1, v1, v2, v3]:
			st.set_normal(Vector3.UP)
			st.add_vertex(tri)
	var road := MeshInstance3D.new()
	road.mesh = st.commit()
	var rmat := StandardMaterial3D.new()
	rmat.albedo_color = Color(0.28, 0.24, 0.19)
	rmat.roughness = 0.92
	road.material_override = rmat
	scene.add_child(road)

	# 14 взрослых и старых деревьев (сосны, берёзы, дубы) вдоль обеих обочин дороги.
	# В items.v возраст задаётся индексом v/3 (0..2 = ADULT, 6..8 = OLD).
	var tree_specs := [
		[-26.0, -5.2, Biomes.T_PINE, 0, 1.15],
		[-23.5, 5.1, Biomes.T_BIRCH, 1, 1.15],
		[-17.8, -5.4, Biomes.T_OAK, 2, 1.22],
		[-14.5, 4.9, Biomes.T_PINE, 6, 1.12],
		[-9.0, -4.8, Biomes.T_BIRCH, 0, 1.18],
		[-5.6, 5.2, Biomes.T_PINE, 1, 1.16],
		[0.4, -4.9, Biomes.T_PINE, 2, 1.20],
		[3.8, 4.8, Biomes.T_OAK, 7, 1.15],
		[9.5, -5.3, Biomes.T_BIRCH, 2, 1.15],
		[13.2, 5.0, Biomes.T_PINE, 0, 1.18],
		[18.8, -5.0, Biomes.T_OAK, 1, 1.20],
		[22.4, 5.3, Biomes.T_BIRCH, 6, 1.15],
		[27.8, -5.1, Biomes.T_PINE, 1, 1.18],
		[31.0, 5.0, Biomes.T_PINE, 2, 1.16],
	]
	var trees_override: Array = []
	for spec: Array in tree_specs:
		var z: float = spec[0]
		var lat: float = spec[1]
		var kind: int = spec[2]
		var v: int = spec[3]
		var s: float = spec[4]
		var cx := sin(z * 0.055) * 2.1
		var wx := cx + lat
		var wz := z
		var stretch_y := lerpf(0.92, 1.12, WGRandom.hash2(floori(wx / GameConfig.TILE * 71.0), floori(wz / GameConfig.TILE * 67.0), 23))
		trees_override.append({x = wx, z = wz, kind = kind, v = v, s = s, ground = 0.0})
		_spawn_tree(scene, wx, wz, kind, v, s, stretch_y)

	var heights := FlatHeightfield.new()
	var garlands := TreeGarlandsLayer.new()
	scene.add_child(garlands)
	var ok := garlands.setup_override(trees_override, road_pts, road_widths, heights, Vector2.ZERO, TreeGarlandsLayout.Archetype.ALLEY_ZIGZAG, 777)
	check(ok, "garlands.setup_override должен собрать аллейный кластер")
	check(garlands.loaded_count() == 1, "Должен быть смонтирован 1 кластер (loaded=%d)" % garlands.loaded_count())
	check(garlands.total_bulb_count() >= 14, "Должно быть >= 14 лампочек (bulbs=%d)" % garlands.total_bulb_count())

	var cam := Camera3D.new()
	cam.fov = 62.0
	cam.far = 600.0
	scene.add_child(cam)
	cam.current = true

	var wide_pos := Vector3(0.0, 2.2, 24.5)
	var wide_target := Vector3(0.0, 3.8, -4.0)

	# 1) День (14:00): без ночных ореолов и локального пула света.
	var night := _set_time(day, env, 14.0, 1.0)
	cam.position = wide_pos
	cam.look_at(wide_target)
	garlands.update(wide_pos, cam.position, Vector3.ZERO, false, night, 2, 2, 0.1)
	await _wait_frames(3)
	check(garlands.active_light_count() == 0, "Днём активных пуловых огней должно быть 0")
	for entry: Dictionary in garlands.loaded_entries().values():
		check(not entry.halos.visible, "Днём ореолы должны быть скрыты")
	if not headless:
		_save_shot(out_dir, "01_day_wide_" + tag)

	# 2) Сумерки (18.85): частичный прогрессивный розжиг нитей.
	night = _set_time(day, env, 18.85, 2.5)
	cam.position = wide_pos
	cam.look_at(wide_target)
	for _i in 6:
		garlands.update(wide_pos, cam.position, Vector3.ZERO, false, night, 2, 2, 0.1)
	await _wait_frames(3)
	if not headless:
		_save_shot(out_dir, "02_twilight_wide_" + tag)

	# 3) Ночь (22.8): полный розжиг, ореолы и пул OmniLight3D.
	night = _set_time(day, env, 22.8, 4.0)
	var night_pos := Vector3(0.0, 2.1, 18.0)
	cam.position = night_pos
	cam.look_at(Vector3(0.0, 3.4, -6.0))
	var t0 := Time.get_ticks_usec()
	for _i in 12:
		garlands.update(night_pos, cam.position, Vector3.ZERO, false, night, 2, 2, 0.1)
	var avg_us := float(Time.get_ticks_usec() - t0) / 12.0
	await _wait_frames(4)
	var light_cap := 3 if method == "forward_plus" else 2
	var active := garlands.active_light_count()
	check(active >= 1 and active <= light_cap, "Ночью число огней %d в пределах 1..%d" % [active, light_cap])
	for entry: Dictionary in garlands.loaded_entries().values():
		check(entry.halos.visible, "Ночью ореолы должны быть включены")
	if not headless:
		_save_shot(out_dir, "03_night_wide_" + tag)

	# 4) Ночь крупным планом около середины первого пролёта и хомута на стволе.
	var close_pos := Vector3(-1.4, 3.3, 6.2)
	cam.position = close_pos
	cam.look_at(Vector3(-0.2, 4.15, 0.5))
	for _i in 8:
		garlands.update(close_pos, cam.position, Vector3.ZERO, false, night, 2, 2, 0.1)
	await _wait_frames(3)
	if not headless:
		_save_shot(out_dir, "04_night_closeup_" + tag)

	var mounted_bulbs := garlands.total_bulb_count()
	# 5) Проверка живого выключения/включения.
	garlands.set_enabled(false)
	check(not garlands.visible and garlands.loaded_count() == 0 and garlands.active_light_count() == 0, "После выключения слой пуст и огни погашены")
	garlands.set_enabled(true)
	check(garlands.visible, "После повторного включения слой видим")

	print("garland_look OK: bulbs=%d active_lights=%d update=%.1f us" % [mounted_bulbs, active, avg_us])
	garlands.finish()
	VisualStyle.release()
	scene.queue_free()
	await process_frame
	quit(0 if _failed == 0 else 1)


func _spawn_tree(parent: Node3D, wx: float, wz: float, kind: int, v: int, s: float, stretch_y: float) -> void:
	var age := v / 3 if ForestModels.has_ages(kind) else ForestModels.ADULT_AGE
	var model_v := v % 3 if age == ForestModels.ADULT_AGE else (ForestModels.OLD + (v % ForestModels.AGE_FORMS))
	var def: Dictionary = ForestModels.definition(kind, model_v)
	var ref_scale: float = s / float(def.get("ref", 1.0))
	var root_n := Node3D.new()
	root_n.position = Vector3(wx, -0.1, wz)
	root_n.scale = Vector3(ref_scale, ref_scale * stretch_y, ref_scale)
	if def.has("trunk"):
		var tm := MeshInstance3D.new()
		tm.mesh = def.trunk
		var mat := StandardMaterial3D.new()
		mat.vertex_color_use_as_albedo = true
		mat.albedo_texture = def.get("trunk_texture")
		mat.roughness = 0.92
		tm.material_override = mat
		root_n.add_child(tm)
	if def.has("crown"):
		var cm := MeshInstance3D.new()
		cm.mesh = def.crown
		var cmat := StandardMaterial3D.new()
		cmat.vertex_color_use_as_albedo = true
		cmat.albedo_texture = def.get("crown_texture")
		cmat.alpha_scissor_threshold = 0.45
		cmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		cmat.cull_mode = BaseMaterial3D.CULL_DISABLED
		cm.material_override = cmat
		root_n.add_child(cm)
	parent.add_child(root_n)


func _set_time(day: DayCycle, env: Environment, hour: float, clock: float) -> float:
	day.apply(hour, clock)
	VisualStyle.apply_day(env, 1.0, 1.0)
	RenderingServer.global_shader_parameter_set("vegetation_clock", clock)
	var s: Array = DayCycle.state(hour)
	return smoothstep(0.25, 0.85, float(s[9]))


func _wait_frames(n: int) -> void:
	for _i in n:
		await process_frame


func _save_shot(out_dir: String, file_stem: String) -> void:
	DirAccess.make_dir_recursive_absolute(out_dir)
	var img := root.get_texture().get_image()
	var path := out_dir.path_join(file_stem + ".png")
	check(img.save_png(path) == OK, "Снимок " + path)
