extends SceneTree
## Стенд детальной геометрии «Речной экспедиции» на сохранённом плане.
## --save-fixture создаёт два плана. --seeds <a,b> выбирает фикстуры; --tag задаёт папку прогона.
## --fine off|on|both выбирает поверхность, both пишет общий лист. --measure включает замер кадра при 1080p,
## --fine smooth оставляет только восстановление. --fine compare_forms добавляет к нему малые формы.
## --fine small оставляет только малые формы без плавных уровней.
## --fine compare_lod сравнивает старые и новые LOD на одном поле. --fine legacy_lod пригоден для исходного заезда.
## --ride ведёт камеру по оси тропы 60 с со скоростью 22 м/с, --parity сверяет физику с мешем.
## Лист: верхний ряд — свет стенда, нижний — свет «для формы» (серая глина, низкое солнце сбоку).
## Виды: пять ближних из фикстуры и дальние Fixture.FAR_VIEW_NAMES (план части 2, этап 0).

const Fixture := preload("res://tools/relief_fine_fixture.gd")
const Metrics := preload("res://tools/relief_fine_metrics.gd")
const Dev := preload("res://tools/control/control.gd")
const Frames := preload("res://scripts/core/frame_statistics.gd")
const Source := preload("res://scripts/render/chunk_source.gd")
const FrameBudget := preload("res://scripts/render/stream_frame_budget.gd")
const FarForest := preload("res://scripts/render/distant_forest.gd")
const RIDE_SPEED := 22.0
const RIDE_SECONDS := 60.0
const SHOT_SIZE := Vector2i(640, 360)
const MEASURE_FRAMES := 45
const MEASURE_WINDOW_US := 600_000
## Свет «для формы»: высота солнца над горизонтом, оно светит сбоку от взгляда; тени до дальних видов.
const FORM_SUN_ELEVATION_DEG := 20.0
const FORM_SHADOW_M := 600.0
const FORM_AMBIENT_ENERGY := 0.22
## Глина: ровный серый цвет вместо материалов, без затенения впадин (cavity_tex), микротеней и рисунка нормалей.
## Остаётся только геометрия: по такому кадру отвечаем на контрольный вопрос плана части 2.
const FORM_ALBEDO := 0.4
const CLAY_LINES := {
	"ALBEDO = depth_tone(col * (1.0 + v), length(VERTEX));": "ALBEDO = vec3(%s);",
	"AO = sky * (use_vertex_color ? 1.0 : texture(cavity_tex, UV).r);": "AO = 1.0;",
	"BACKLIGHT = vec3(mix(micro_shadow, road_shade, road), gloss_v, 0.0);": "BACKLIGHT = vec3(1.0, 0.0, 0.0);",
	"NORMAL_MAP = detail_n;": "NORMAL_MAP = vec3(0.5, 0.5, 1.0);",
}

var _scene: Node3D
var _camera: Camera3D
var _sun: DirectionalLight3D
var _terrain: PlanTerrain
var _source: RefCounted
var _heights: Heightfield
var _provider := FrameBudget.new()
var _failures := 0
var _env: Environment
var _clay_shaders := {}
var _clay_materials := {}


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 240 if "--save-fixture" in OS.get_cmdline_user_args() else (90 if "--ride" in OS.get_cmdline_user_args() else 150))
	_run.call_deferred()


func _expect(ok: bool, description: String) -> void:
	if not ok:
		_failures += 1
		printerr("RELIEF_FAIL ", description)


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var save := args.has("--save-fixture")
	var fine := Dev.arg("fine", "off")
	var seeds := Dev.arg("seeds", ",".join(Fixture.SEEDS) if save else Fixture.SEEDS[0]).split(",", false)
	if seeds.is_empty() or (args.has("--ride") and seeds.size() != 1):
		printerr("RELIEF_FAIL укажите один сид для заезда")
		quit(1)
		return
	if save:
		for seed: String in seeds:
			var started := Time.get_ticks_msec()
			var result := Fixture.save(seed)
			_expect(result == OK, "фикстура %s: %s" % [seed, error_string(result)])
			print("RELIEF_FIXTURE ", seed, " ms=", Time.get_ticks_msec() - started, " result=", error_string(result))
		quit(int(_failures > 0))
		return
	var comparison_modes: Array = {
		"both": ["off", "on"], "compare_forms": ["smooth", "small"],
		"compare_lod": ["legacy_lod", "on"],
	}.get(fine, [])
	if DisplayServer.get_name() == "headless" or (comparison_modes.is_empty() and fine not in ["off", "on", "smooth", "small", "legacy_lod"]) or (not comparison_modes.is_empty() and args.has("--ride")):
		printerr("RELIEF_FAIL для съёмки нужен экран; --fine off|on|both|smooth|small|legacy_lod|compare_forms|compare_lod (заезд с одним вариантом)")
		quit(1)
		return
	var measure := args.has("--measure")
	var parity := args.has("--parity")
	root.size = Vector2i(1920, 1080) if measure else Vector2i(960, 540)
	var settings := GameSettings.new()
	var settings_path := Dev.arg("settings", "")
	if not settings_path.is_empty():
		settings.settings_path = settings_path
		settings.load_settings()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var viewport := root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(viewport, measure)
	FarForest.active = false
	var probe := await _probe_vertex_inputs()
	_expect(probe, "CUSTOM0 и instance uniform должны изменить вершины двух экземпляров")
	var renderer := RenderingServer.get_current_rendering_method()
	var adapter := RenderingServer.get_video_adapter_name()
	print("RELIEF_RENDERER ", renderer, " / ", adapter, " CUSTOM0_AND_INSTANCE=", probe)
	var runs := []
	for seed: String in seeds:
		for mode: String in (comparison_modes if not comparison_modes.is_empty() else [fine]):
			runs.append([seed, mode])
	for run: Array in runs:
		var seed: String = run[0]
		var mode: String = run[1]
		var started := Time.get_ticks_msec()
		var fixture := Fixture.restore(seed)
		if fixture.is_empty():
			_expect(false, "фикстура %s отсутствует или повреждена" % seed)
			continue
		var folder := Fixture.DIR.path_join(Dev.arg("tag", "baseline")).path_join(seed)
		var mkdir := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
		if mkdir != OK:
			_expect(false, "папка прогона %s: %s" % [folder, error_string(mkdir)])
			continue
		var prepare_ms := 0.0
		if mode != "off":
			var prepare_started := Time.get_ticks_usec()
			fixture.heights.prepare_fine_relief(mode != "smooth", mode == "on")
			prepare_ms = (Time.get_ticks_usec() - prepare_started) / 1000.0
			if fixture.heights.fine_relief == null:
				_expect(false, "точное поле не готово на " + seed)
				continue
		_build_scene(fixture.world, fixture.heights)
		var rows: Array = []
		var names := Fixture.view_names()
		var capture_views: Array = [] if args.has("--ride") else fixture.views + fixture.far_views
		if not args.has("--ride"):
			_expect(capture_views.size() == names.size(), "дальние виды не найдены: " + seed)
		var sheet := Image.create_empty(SHOT_SIZE.x * names.size(), SHOT_SIZE.y * 2, false, Image.FORMAT_RGB8)
		for i in mini(capture_views.size(), names.size()):
			var view: Dictionary = capture_views[i]
			var eye: Vector3 = view.eye
			var target: Vector3 = view.target
			var focus: Vector2 = view.focus
			var uploads := _place_camera(eye, target)
			var shot := await _grab()
			shot.convert(Image.FORMAT_RGB8)
			var repeated := true
			if i == 0:
				var second := await _grab()
				second.convert(Image.FORMAT_RGB8)
				repeated = shot.get_data() == second.get_data()
				_expect(repeated, "повторная съёмка дала другой кадр: " + seed)
			var pieces := []
			for key: Vector2i in _terrain.nodes:
				if not Metrics.near_view(key, Vector2(eye.x, eye.z), focus):
					continue
				var detail := _terrain.relief_detail
				var nodes: Array = detail.entries[key].parts if detail != null and detail.active(key) else [_terrain.nodes[key]]
				for node: MeshInstance3D in nodes:
					pieces.append(node.mesh.surface_get_arrays(0))
			var row := Metrics.mesh_stats(pieces, _heights, eye, focus, parity)
			row.name = names[i]
			row.eye = eye
			row.target = target
			row.energy_pct = Metrics.spectrum(_heights, focus)
			row.triangles = _visible_triangles()
			row.settle_uploads = uploads
			if _terrain.relief_detail != null:
				row.detail = _terrain.relief_detail.stats.duplicate()
			if i == 0:
				row.repeat_identical = repeated
			if measure:
				root.msaa_3d = settings.msaa as Viewport.MSAA
				_sun.shadow_enabled = settings.shadows
				row.merge(await _measure(viewport))
				_sun.shadow_enabled = false
				root.msaa_3d = Viewport.MSAA_DISABLED
			if parity:
				_expect(row.parity_samples > 0 and row.parity_failed == 0, "паритет %s %s: %d / %d, max %.4f мм" %
					[seed, row.name, row.parity_failed, row.parity_samples, row.max_error_mm])
			_expect(row.shared_edge_m > 0.0 and row.triangles > 0, "нет геометрии: %s %s" % [seed, row.name])
			_expect(shot.save_png(folder.path_join("%02d_%s.png" % [i + 1, mode])) == OK, "запись снимка: " + str(i))
			shot.resize(SHOT_SIZE.x, SHOT_SIZE.y, Image.INTERPOLATE_LANCZOS)
			sheet.blit_rect(shot, Rect2i(Vector2i.ZERO, SHOT_SIZE), Vector2i(i * SHOT_SIZE.x, 0))
			var form := await _grab_form(eye, target)
			_expect(form.save_png(folder.path_join("%02d_%s_form.png" % [i + 1, mode])) == OK, "запись снимка формы: " + str(i))
			form.resize(SHOT_SIZE.x, SHOT_SIZE.y, Image.INTERPOLATE_LANCZOS)
			sheet.blit_rect(form, Rect2i(Vector2i.ZERO, SHOT_SIZE), Vector2i(i * SHOT_SIZE.x, SHOT_SIZE.y))
			rows.append(row)
			print("RELIEF_VIEW ", seed, " ", mode, " ", JSON.stringify(row))
		var setup_ms := Time.get_ticks_msec() - started
		if not rows.is_empty():
			if not comparison_modes.is_empty():
				var baseline_path := folder.path_join("relief_fine_sheet_%s.png" % comparison_modes[0])
				if mode == comparison_modes[0]:
					_expect(sheet.save_png(baseline_path) == OK, "запись исходного листа " + seed)
				else:
					var baseline := Image.load_from_file(baseline_path)
					if baseline != null:
						var rect := Rect2i(Vector2i.ZERO, sheet.get_size())
						var comparison := Image.create_empty(rect.size.x, rect.size.y * 2, false, Image.FORMAT_RGB8)
						comparison.blit_rect(baseline, rect, Vector2i.ZERO)
						comparison.blit_rect(sheet, rect, Vector2i(0, rect.size.y))
						_expect(comparison.save_png(folder.path_join("relief_fine_sheet.png")) == OK, "запись листа " + seed)
					else:
						_expect(false, "чтение исходного листа " + seed)
			else:
				_expect(sheet.save_png(folder.path_join("relief_fine_sheet.png")) == OK, "запись листа " + seed)
		var ride := {}
		if args.has("--ride"):
			root.msaa_3d = settings.msaa as Viewport.MSAA if measure else Viewport.MSAA_DISABLED
			_sun.shadow_enabled = settings.shadows
			ride = await _ride(fixture.route)
			_expect(not ride.is_empty(), "нет 1320 м непрерывной тропы для заезда")
			if _terrain.morph_lod != null:
				_expect(_terrain.morph_lod.stats.switches > 0, "заезд не пересёк пороги уровней 4/8/16 м")
			print("RELIEF_RIDE ", seed, " ", JSON.stringify(ride))
		var report := "relief_fine_ride_" if args.has("--ride") else "relief_fine_"
		var file := FileAccess.open(folder.path_join(report + mode + ".json"), FileAccess.WRITE)
		_expect(file != null, "запись метрик " + seed)
		if file != null:
			file.store_string(JSON.stringify({seed = seed, renderer = renderer, gpu = adapter, resolution = [root.size.x, root.size.y],
				msaa = settings.msaa if measure else Viewport.MSAA_DISABLED, shadows = settings.shadows,
				custom0_and_instance_uniform = probe, fixture_and_views_ms = setup_ms, prepare_ms = prepare_ms, views = rows, ride = ride}, "\t"))
		_source.close()
		_scene.free()
	print("RELIEF_RESULT failures=", _failures)
	quit(int(_failures > 0))


func _build_scene(w: WorldData, h: Heightfield) -> void:
	_heights = h
	root.msaa_3d = Viewport.MSAA_DISABLED
	_scene = Node3D.new()
	root.add_child(_scene)
	_clay_shaders.clear()
	_clay_materials.clear()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("b3c4d4")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("e0e9f0")
	env.ambient_light_energy = 0.38
	var weather := WorldEnvironment.new()
	weather.environment = env
	_env = env
	_scene.add_child(weather)
	_sun = DirectionalLight3D.new()
	_sun.rotation_degrees = Vector3(-33.0, -56.0, 0.0)
	# Мягкие динамические тени включаются в замере, снимкам нужен фиксированный свет.
	_sun.directional_shadow_max_distance = 180.0
	_scene.add_child(_sun)
	RenderingServer.global_shader_parameter_set("sun_dir", _sun.basis.z)
	var chunks := TerrainBuilder.build_chunks(w, h)
	_source = Source.new()
	_source.setup(WorldCache.new(), w, h, w.W, [chunks, {}, {}], null)
	_terrain = PlanTerrain.new()
	_scene.add_child(_terrain)
	_terrain.frame_budget = _provider
	var builder := TerrainBuilder.new()
	var mat := builder.material(MapBaker.bake(w, WorldLoader.px_for(maxi(w.W, w.H)), true), null, w.template_id)
	_terrain.setup(chunks, mat, null, w, h, _source)
	_terrain.far_material = builder.far_material(mat)
	# Вода остаётся на том же меше; останавливаем только движение бликов для повторяемой съёмки.
	var water_shader := Shader.new()
	water_shader.code = WaterBuilder.SHADER.code.replace("TIME * speed", "0.0 * speed")
	for node: MeshInstance3D in WaterBuilder.build(w, WaterBuilder.prepare(w, h)):
		if node.name == "Ocean":
			node.free()
			continue
		var water_mat := node.mesh.surface_get_material(0).duplicate() as ShaderMaterial
		water_mat.shader = water_shader
		node.material_override = water_mat
		_scene.add_child(node)
	_camera = Camera3D.new()
	_camera.far = PlanTerrain.RADIUS
	_camera.fov = 68.0
	_scene.add_child(_camera)
	_camera.make_current()


func _place_camera(eye: Vector3, target: Vector3, near := PlanTerrain.RADIUS) -> Dictionary:
	_camera.position = eye
	_camera.look_at(target)
	var p := Vector2(eye.x, eye.z)
	_source.prewarm([p], near)
	var detail_prewarm_ms := 0.0
	if _terrain.relief_detail != null:
		var started := Time.get_ticks_usec()
		_source.prewarm_detail(PackedVector2Array([p]), _terrain.relief_detail.enter_m)
		detail_prewarm_ms = (Time.get_ticks_usec() - started) / 1000.0
	_terrain.update(p.x, p.y, true, _heights.fine_relief != null, near)
	_source.finish_startup()
	# Статичный вид снимается после подмены всех уровней. В заезде работает обычный бюджет кадра.
	if near == PlanTerrain.RADIUS:
		while _terrain._step_lod(p):
			pass
		_expect(_terrain.arrival_ready(p, near), "не все чанки готовы к съёмке")
	var snapshot: Dictionary = _source.snapshot()
	snapshot.detail_prewarm_ms = detail_prewarm_ms
	return snapshot


## Кадр «для формы»: глина на всех частях рельефа, низкое солнце слева от взгляда, длинные тени.
func _grab_form(eye: Vector3, target: Vector3) -> Image:
	var flat := Vector3(target.x - eye.x, 0.0, target.z - eye.z).normalized()
	var right := flat.cross(Vector3.UP)
	var elevation := deg_to_rad(FORM_SUN_ELEVATION_DEG)
	var sun_basis := _sun.basis
	var shadow_on := _sun.shadow_enabled
	var shadow_m := _sun.directional_shadow_max_distance
	var ambient := _env.ambient_light_energy
	_sun.basis = Basis.looking_at(right * cos(elevation) + Vector3.DOWN * sin(elevation))
	_sun.shadow_enabled = not OS.get_cmdline_user_args().has("--form-no-shadow")
	_sun.directional_shadow_max_distance = FORM_SHADOW_M
	_env.ambient_light_energy = FORM_AMBIENT_ENERGY
	RenderingServer.global_shader_parameter_set("sun_dir", _sun.basis.z)
	var swapped := {}
	for node: GeometryInstance3D in _terrain.find_children("*", "GeometryInstance3D", true, false):
		if node.material_override is ShaderMaterial:
			swapped[node] = node.material_override
			node.material_override = _clay(node.material_override)
	var image := await _grab()
	image.convert(Image.FORMAT_RGB8)
	for node: GeometryInstance3D in swapped:
		node.material_override = swapped[node]
	_sun.basis = sun_basis
	_sun.shadow_enabled = shadow_on
	_sun.directional_shadow_max_distance = shadow_m
	_env.ambient_light_energy = ambient
	RenderingServer.global_shader_parameter_set("sun_dir", _sun.basis.z)
	return image


func _clay(source: ShaderMaterial) -> ShaderMaterial:
	if _clay_materials.has(source):
		return _clay_materials[source]
	if not _clay_shaders.has(source.shader):
		var code := source.shader.code
		for line: String in CLAY_LINES:
			_expect(code.count(line) == 1, "строка глины не найдена в шейдере рельефа: " + line)
			code = code.replace(line, CLAY_LINES[line] % str(FORM_ALBEDO) if "%s" in CLAY_LINES[line] else CLAY_LINES[line])
		var shader := Shader.new()
		shader.code = code
		_clay_shaders[source.shader] = shader
	var clay := source.duplicate() as ShaderMaterial
	clay.shader = _clay_shaders[source.shader]
	_clay_materials[source] = clay
	return clay


func _grab() -> Image:
	for frame in 4:
		await process_frame
		await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


func _visible_triangles() -> int:
	return root.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME)


func _measure(viewport: RID) -> Dictionary:
	var gpu := PackedFloat32Array()
	var cpu := PackedFloat32Array()
	for warmup in 3:
		await process_frame
		await RenderingServer.frame_post_draw
	var stop := Time.get_ticks_usec() + MEASURE_WINDOW_US
	for i in MEASURE_FRAMES:
		await process_frame
		await RenderingServer.frame_post_draw
		gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(viewport))
		cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(viewport))
		if Time.get_ticks_usec() >= stop:
			break
	gpu.sort()
	cpu.sort()
	var gpu_median := Frames.percentile(gpu, 0.5)
	var cpu_median := Frames.percentile(cpu, 0.5)
	return {measured_frames = gpu.size(), gpu_ms = gpu_median if gpu_median > 0.0 else null,
		render_cpu_ms = cpu_median if cpu_median > 0.0 else null, measured_triangles = _visible_triangles()}


func _ride(route: PackedVector2Array) -> Dictionary:
	var length := PackedFloat64Array([0.0])
	for i in range(1, route.size()):
		length.append(length[-1] + route[i].distance_to(route[i - 1]))
	if length[-1] < RIDE_SPEED * RIDE_SECONDS + 12.0:
		return {}
	var start := route[0]
	var forward := start.direction_to(route[1])
	_place_camera(_at(start, 1.85), _at(start + forward * 12.0, 1.0), PlanTerrain.SIDE)
	await _grab()
	var started := Time.get_ticks_usec()
	var previous := started
	var frames := PackedFloat32Array()
	var segment := 1
	var lod_changes := 0
	var stream_frames := 0
	var visible_peak := 0
	var visible_total := 0
	var lods: Dictionary = _terrain._node_lod.duplicate()
	var upload_before: Dictionary = _source.snapshot()
	var stream := preload("res://scripts/render/world_stream_coordinator.gd").new()
	var prior := {distance_m = 0.0, terrain_ms = 0.0, uploaded = false, detail_piece = false}
	var previous_pipelines := Frames.pipeline_counts()
	var worst := {}
	while true:
		await process_frame
		var now := Time.get_ticks_usec()
		var elapsed := (now - started) / 1000000.0
		var frame_ms := (now - previous) / 1000.0
		frames.append(frame_ms)
		var pipelines := Frames.pipeline_counts()
		if frame_ms > float(worst.get("ms", 0.0)):
			var delta := pipelines - previous_pipelines
			worst = prior.duplicate()
			worst.ms = frame_ms
			worst.pipeline_compilations = delta.x + delta.y + delta.z + delta.w
		previous_pipelines = pipelines
		previous = now
		if elapsed >= RIDE_SECONDS:
			break
		var distance := elapsed * RIDE_SPEED
		while length[segment] <= distance:
			segment += 1
		var p := route[segment - 1].lerp(route[segment], inverse_lerp(length[segment - 1], length[segment], distance))
		var ahead := segment
		while length[ahead] < distance + 12.0:
			ahead += 1
		_camera.position = _at(p, 1.85)
		_camera.look_at(_at(route[ahead], 1.0))
		var detail := _terrain.relief_detail
		var before: int = detail.stats.uploads if detail != null else 0
		var terrain_started := Time.get_ticks_usec()
		_provider.deadline_usec = terrain_started + stream.publication_budget_us
		var uploaded := _terrain.update(p.x, p.y)
		stream_frames += int(uploaded)
		prior.distance_m = distance
		prior.terrain_ms = (Time.get_ticks_usec() - terrain_started) / 1000.0
		prior.uploaded = uploaded
		prior.detail_piece = detail != null and detail.stats.uploads != before
		for key: Vector2i in _terrain._node_lod:
			var lod: int = _terrain._node_lod[key]
			lod_changes += int(lods.has(key) and lods[key] != lod)
		lods = _terrain._node_lod.duplicate()
		var triangles := _visible_triangles()
		visible_peak = maxi(visible_peak, triangles)
		visible_total += triangles
	frames.sort()
	var upload_after: Dictionary = _source.snapshot()
	_provider.deadline_usec = 0
	var result := {seconds = RIDE_SECONDS, speed_mps = RIDE_SPEED, frames = frames.size(), max_ms = frames[-1],
		p99_ms = Frames.percentile(frames, 0.99), lod_changes = lod_changes, stream_frames = stream_frames,
		peak_triangles = visible_peak, mean_triangles = float(visible_total) / maxi(1, frames.size() - 1),
		full_upload_bytes = upload_after.upload_bytes - upload_before.upload_bytes,
		full_upload_ms = upload_after.upload_ms - upload_before.upload_ms, worst_frame = worst}
	if _terrain.relief_detail != null:
		result.detail = _terrain.relief_detail.stats
		result.tile_bytes = _heights.fine_relief.Bytes()
		result.mesh_cache_bytes = _source._fine_cpu.bytes
	if _terrain.morph_lod != null:
		result.coarse_lod = _terrain.morph_lod.stats
	return result


func _at(p: Vector2, offset: float) -> Vector3:
	return Vector3(p.x, _heights.ground_at(p.x, p.y) + offset, p.y)


func _probe_vertex_inputs() -> bool:
	var view := SubViewport.new()
	view.size = Vector2i(128, 128)
	view.own_world_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(view)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 4.0
	view.add_child(cam)
	cam.position = Vector3(0, 0, 5)
	cam.make_current()
	var shader := Shader.new()
	shader.code = """shader_type spatial;
render_mode unshaded, cull_disabled;
instance uniform float blend_height = 0.0;
varying float sample_value;
void vertex() {
	VERTEX.y += CUSTOM0.x * blend_height;
	sample_value = CUSTOM0.x;
}
void fragment() {
	ALBEDO = vec3(0.0, sample_value, 0.0);
}
"""
	var material := ShaderMaterial.new()
	material.shader = shader
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(-0.45, -0.4, 0), Vector3(0.45, -0.4, 0), Vector3(0, 0.45, 0)])
	arrays[Mesh.ARRAY_CUSTOM0] = PackedFloat32Array([1.0, 1.0, 1.0])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, Mesh.ARRAY_CUSTOM_R_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
	for i in 2:
		var node := MeshInstance3D.new()
		node.mesh = mesh
		node.material_override = material
		view.add_child(node)
		node.position = Vector3(-1.0 if i == 0 else 1.0, 0, 0)
		node.set_instance_shader_parameter("blend_height", float(i))
	for frame in 4:
		await process_frame
		await RenderingServer.frame_post_draw
	var image := view.get_texture().get_image()
	var low := image.get_pixelv(Vector2i(cam.unproject_position(Vector3(-1, 0, 0))))
	var high := image.get_pixelv(Vector2i(cam.unproject_position(Vector3(1, 1, 0))))
	var vacated := image.get_pixelv(Vector2i(cam.unproject_position(Vector3(1, 0, 0))))
	view.free()
	return low.g > 0.8 and high.g > 0.8 and vacated.g < 0.8
