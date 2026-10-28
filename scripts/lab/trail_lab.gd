extends Node3D
## Developer composition root: production terrain, controller, view and crash lifecycle.
const Fixture = preload("res://tools/trail_lab_fixture.gd")
const EditorPanel = preload("res://scripts/lab/trail_lab_editor.gd")
signal exit_requested
@export var routes: Array[TrailDefinition] = []
var heights: Heightfield
var services := ServiceScope.new()
var player := PlayerState.new()
var bike := BikeRide.new()
var controller := BikeController.new()
var view: BikeView
var crash := BikeCrash.new()
var camera := Camera3D.new()
var telemetry := Label.new()
var speed_label := Label.new()
var surface_label := Label.new()
var stamina_label := Label.new()
var stamina_bar := ProgressBar.new()
var route_hint := Label.new()
var camera_control := Button.new()
var details_control := Button.new()
var status := Label.new()
var diagnostics := Label.new()
var hud_panel := PanelContainer.new()
var diagnostics_visible := false
var status_time := 0.0
var editor := EditorPanel.new()
var lane := 0
var element_index := 0
var overview := false
var terrain := MeshInstance3D.new()
var markers := Node3D.new()
var props := Node3D.new()
var technical := {collide = PackedFloat32Array(), bumps = PackedFloat32Array(), props = [], lines = {}, decks = []}
var last_land_impact := 0.0
var last_bottom_out := 0.0
var metrics := TrailLabMetrics.new()
var _cam_from := Vector4() # x, feet, z, heading on the previous physics tick
var _cam_to := Vector4()
var _cam_feet := 0.0
var _sources: Array[TrailDefinition] = []
## Test ground of the current session (Fixture.GROUNDS): the lab's gentle slope or a window of world relief.
var ground_kind := "flat"

func _ready() -> void:
	if routes.is_empty(): routes = Fixture.definitions()
	_sources.assign(routes)
	add_child(terrain)
	add_child(markers)
	add_child(props)
	var image := Image.create(64, 64, false, Image.FORMAT_RGB8)
	image.fill(Color(0.32, 0.42, 0.23))
	terrain.material_override = services.terrain.material(image)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, -30, 0)
	sun.shadow_enabled = true
	add_child(sun)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.47, 0.65, 0.8)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color(0.7, 0.8, 1.0)
	environment.environment.ambient_light_energy = 0.65
	add_child(environment)
	view = preload("res://scenes/bike.tscn").instantiate() as BikeView
	add_child(view)
	add_child(crash)
	add_child(camera)
	camera.current = true
	camera.far = 800.0
	var canvas := CanvasLayer.new()
	add_child(canvas)
	hud_panel.position = Vector2(18, 18)
	hud_panel.theme_type_variation = "HudPanel"
	canvas.add_child(hud_panel)
	var hud_margin := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]: hud_margin.add_theme_constant_override("margin_" + side, 10)
	hud_panel.add_child(hud_margin)
	var hud_box := VBoxContainer.new()
	hud_box.add_theme_constant_override("separation", 6)
	hud_margin.add_child(hud_box)
	telemetry.theme_type_variation = "AccentLabel"
	telemetry.add_theme_font_size_override("font_size", 14)
	telemetry.custom_minimum_size.x = 220
	telemetry.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	speed_label.add_theme_font_size_override("font_size", 26)
	surface_label.theme_type_variation = "HintLabel"
	stamina_label.theme_type_variation = "HintLabel"
	stamina_label.add_theme_font_size_override("font_size", 12)
	stamina_bar.show_percentage = false
	stamina_bar.custom_minimum_size.y = 7
	diagnostics.add_theme_font_size_override("font_size", 13)
	diagnostics.visible = false
	hud_box.add_child(telemetry)
	route_hint.theme_type_variation = "HintLabel"
	route_hint.add_theme_font_size_override("font_size", 12)
	hud_box.add_child(route_hint)
	var ride_row := HBoxContainer.new()
	hud_box.add_child(ride_row)
	ride_row.add_child(speed_label)
	var ride_info := VBoxContainer.new()
	ride_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ride_row.add_child(ride_info)
	ride_info.add_child(surface_label)
	ride_info.add_child(stamina_label)
	ride_info.add_child(stamina_bar)
	var hud_actions := HBoxContainer.new()
	hud_box.add_child(hud_actions)
	var settings_control := Button.new()
	settings_control.text = "F2  Настройки"
	settings_control.add_theme_font_size_override("font_size", 12)
	settings_control.tooltip_text = "Открыть настройки трассы"
	settings_control.pressed.connect(func() -> void: set_editor_visible(not editor.visible))
	hud_actions.add_child(settings_control)
	camera_control.pressed.connect(func() -> void: set_overview(not overview))
	camera_control.add_theme_font_size_override("font_size", 12)
	hud_actions.add_child(camera_control)
	var more_actions := HBoxContainer.new()
	hud_box.add_child(more_actions)
	details_control.text = "F3  Подробности"
	details_control.add_theme_font_size_override("font_size", 12)
	details_control.pressed.connect(func() -> void: set_diagnostics_visible(not diagnostics_visible))
	more_actions.add_child(details_control)
	hud_box.add_child(diagnostics)
	status.position = Vector2(18, 110)
	status.custom_minimum_size.x = 220
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	for label in [telemetry, diagnostics, status]:
		label.add_theme_color_override("font_shadow_color", Color.BLACK)
		label.add_theme_constant_override("shadow_outline_size", 5)
	canvas.add_child(status)
	canvas.add_child(editor)
	editor.visible = false
	editor.course_selected.connect(func(index: int, kind: String, style: String, ground: String) -> void:
		var previous := ground_kind
		ground_kind = ground
		if rebuild(Fixture.course(index, kind, style, ground)):
			set_overview(true)
		else:
			ground_kind = previous)
	editor.camera_toggle_requested.connect(func() -> void: set_overview(not overview))
	editor.close_requested.connect(func() -> void: set_editor_visible(false))
	editor.route_selected.connect(select_route)
	editor.element_selected.connect(func(index: int) -> void:
		element_index = index
		editor.present(routes, lane, element_index))
	editor.apply_requested.connect(apply_edit)
	editor.launch_requested.connect(launch_element)
	editor.reload_requested.connect(reload_sources)
	set_overview(false)
	get_viewport().size_changed.connect(_place_editor)
	_place_editor()
	rebuild(_copy_routes(routes))

func _place_editor() -> void:
	var viewport_size := get_viewport().get_visible_rect().size
	editor.size = Vector2(360, maxf(100.0, viewport_size.y - 36))
	editor.position = Vector2(maxf(18.0, viewport_size.x - editor.size.x - 18), 18)

func _copy_routes(source: Array[TrailDefinition]) -> Array[TrailDefinition]:
	var copies: Array[TrailDefinition] = []
	for d in source: copies.append(d.duplicate(true) as TrailDefinition if d != null else null)
	return copies

## Transactional edit: prepare data and mesh first, then replace the live session.
func rebuild(candidate: Array[TrailDefinition]) -> bool:
	if candidate.is_empty():
		show_message("Нужна хотя бы одна трасса")
		return false
	var prepared := Fixture.prepare(candidate, true, ground_kind)
	if not prepared.errors.is_empty():
		show_message("Правка отклонена: " + "; ".join(prepared.errors))
		return false
	var next_heights: Heightfield = prepared.heights
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, TerrainBuilder.build_arrays(next_heights.world, next_heights))
	var next_technical := TrailTechnical.build(next_heights, candidate)
	crash.abort()
	heights = next_heights
	routes = candidate
	technical = next_technical
	heights.obstacles.set_bumps(technical.bumps, 1)
	for child in props.get_children(): child.free()
	TrailLabProps.populate(props, technical.props)
	terrain.mesh = mesh
	lane = clampi(lane, 0, routes.size() - 1)
	element_index = clampi(element_index, 0, maxi(0, routes[lane].elements.size() - 1))
	for child in markers.get_children(): child.free()
	for d in routes:
		_label(d.title, d.points[0], 3.0)
		for s: Dictionary in d.sections:
			_label("Участок · %s · сложность %.2f" % [TrailComposer.MOODS[s.mood].title, s.difficulty], d.point_at(s.from), 4.2)
		for e in d.elements:
			_label("%s · %.1f м / %.1f м" % [TrailElementLibrary.title(e.profile), e.height, e.length], d.point_at(e.station), 1.8)
	editor.present(routes, lane, element_index)
	reset_ride()
	show_message("Готово · правки действуют в текущем запуске")
	return true

func _label(text: String, at: Vector2, lift: float) -> void:
	var label := Label3D.new()
	label.text = text
	label.position = Vector3(at.x, heights.ground_at(at.x, at.y) + lift, at.y)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	markers.add_child(label)

func select_route(index: int) -> void:
	if heights == null: return
	lane = clampi(index, 0, routes.size() - 1)
	element_index = 0
	editor.present(routes, lane, element_index)
	reset_ride()

func apply_edit(values: Dictionary) -> bool:
	if heights == null: return false
	var candidate := _copy_routes(routes)
	var d := candidate[lane]
	d.width = values.width
	d.surface = values.surface
	for key in ["earthwork", "elevation_offset", "auto_bank"]:
		if values.has(key): d.set(key, values[key])
	if values.has("grade_limit"):
		var shape := d.shape()
		shape.grade_limit = values.grade_limit / 100.0
		shape.side_follow = values.side_follow
		shape.bank_max = values.bank_max / 100.0
		shape.batter = values.batter
		d.shaping = shape
	if not d.elements.is_empty():
		var e := d.elements[element_index]
		e.profile = int(values.profile) as TrailElement.Profile
		for key: String in TrailElement.KEYS:
			if values.has(key): e.set(key, int(values[key]) if key in TrailElement.INTEGER_KEYS else values[key])
	if not rebuild(candidate): return false
	launch_element()
	return true

func reload_sources() -> bool:
	var candidate: Array[TrailDefinition] = []
	for source in _sources:
		if source == null:
			show_message("Невозможно загрузить пустой ресурс трассы")
			return false
		var loaded := source
		if not source.resource_path.is_empty():
			loaded = ResourceLoader.load(source.resource_path, "", ResourceLoader.CACHE_MODE_IGNORE) as TrailDefinition
		if loaded == null:
			show_message("Не удалось перечитать " + source.resource_path)
			return false
		candidate.append(loaded.duplicate(true) as TrailDefinition)
	return rebuild(candidate)

func reset_ride(station := 0.0, speed := 0.0) -> void:
	if heights == null: return
	crash.abort()
	controller = BikeController.new()
	controller.message.connect(show_message)
	player = PlayerState.new()
	bike = BikeRide.new()
	var d := routes[lane]
	var at := d.point_at(station)
	player.x = at.x
	player.z = at.y
	player.feet = heights.surface_at(at.x, at.y, -INF)
	player.on_ground = true
	bike.x = player.x
	bike.z = player.z
	bike.y = player.feet
	bike.heading = d.heading_at(station)
	bike.mount(player)
	bike.speed = speed
	last_land_impact = 0.0
	last_bottom_out = 0.0
	heights.obstacles.update(player.x, player.z, technical.collide, 1, true)
	view.snap(bike)
	metrics.reset(bike)
	_cam_to = Vector4(player.x, player.feet, player.z, bike.heading)
	_cam_from = _cam_to
	_cam_feet = player.feet

func launch_element() -> void:
	if heights == null: return
	var station := 0.0
	if not routes[lane].elements.is_empty():
		var e := routes[lane].elements[element_index]
		station = maxf(0.0, e.station - e.length * 0.5 - 12.0)
	reset_ride(station, editor.numbers.speed.value / 3.6)
	set_overview(false)
	editor.hide()
	get_viewport().gui_release_focus()
	show_message("Заезд с %.0f км/ч · R — старт трассы" % editor.numbers.speed.value)

func show_message(text: String) -> void:
	status.text = text
	status.visible = true
	status_time = 4.0

func set_overview(enabled: bool) -> void:
	overview = enabled
	editor.set_camera_overview(enabled)
	camera_control.text = "V  Сверху" if enabled else "V  Камера"
	camera_control.tooltip_text = "Сейчас: обзор сверху. Переключить на вид за велосипедистом" if enabled else "Сейчас: вид за велосипедистом. Переключить на обзор сверху"

func set_editor_visible(enabled: bool) -> void:
	editor.visible = enabled
	get_viewport().gui_release_focus()

func set_diagnostics_visible(enabled: bool) -> void:
	diagnostics_visible = enabled
	diagnostics.visible = enabled
	details_control.text = "F3  Скрыть" if enabled else "F3  Подробности"
	hud_panel.reset_size()
	get_viewport().gui_release_focus()

## Release ragdoll bodies before the owning menu removes the scene.
func shutdown() -> void:
	set_process(false)
	set_physics_process(false)
	crash.abort()
	get_viewport().gui_release_focus()

func _request_exit() -> void:
	if exit_requested.get_connections().is_empty():
		shutdown()
		get_tree().quit()
	else:
		exit_requested.emit()

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo: return
	var key: int = event.physical_keycode if event.physical_keycode != 0 else event.keycode
	if key == KEY_F2:
		set_editor_visible(not editor.visible)
	if key == KEY_F5: reload_sources()
	if key == KEY_F3:
		set_diagnostics_visible(not diagnostics_visible)
		get_viewport().set_input_as_handled()
		return
	if key == KEY_V:
		set_overview(not overview)
		get_viewport().set_input_as_handled()
		return
	if heights == null or editor.visible: return
	if key >= KEY_1 and key < KEY_1 + mini(routes.size(), 9): select_route(key - KEY_1)
	if key == KEY_R: reset_ride()
	if key == KEY_G: launch_element()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause") or event.is_action_pressed("ui_cancel"):
		if editor.visible:
			editor.hide()
			get_viewport().gui_release_focus()
		else:
			_request_exit()
		get_viewport().set_input_as_handled()
		return
	if heights != null and not editor.visible and event.is_action_pressed("interact") and not crash.active():
		controller.toggle_mount(player, bike, heights.world, heights)
		view.snap(bike)

func _physics_process(dt: float) -> void:
	if heights == null: return
	var input_allowed := not editor.visible
	var throttle := Input.get_axis("move_back", "move_forward") if input_allowed else 0.0
	var turn := Input.get_axis("move_left", "move_right") if input_allowed else 0.0
	var jump := input_allowed and Input.is_action_just_pressed("jump")
	var run := input_allowed and Input.is_action_pressed("run")
	step_simulation(dt, throttle, turn, run, jump)

## Same controller/foot lifecycle as GameWorld; callable by the isolated scene regression.
func step_simulation(dt: float, throttle: float, turn: float, run: bool, jump: bool) -> void:
	var w := heights.world
	_cam_from = _cam_to
	heights.obstacles.update(player.x, player.z, technical.collide, 1)
	if crash.active():
		controller.recover(dt, player, bike, crash, w, heights)
	elif bike.riding:
		throttle = controller.ride(dt, player, bike, w, heights, throttle, turn, run, jump, false)
		if bike.crashed:
			view.tick(bike, dt, throttle)
			view.draw(1.0)
			controller.begin_crash(view, bike, crash, heights)
	else:
		var moving := player.step(throttle, turn, run, jump, bike.heading, dt, w, heights)
		controller.stamina.tick_foot(dt, run and moving)
		player.land_impact = 0.0
	if not crash.active():
		view.tick(bike, dt, throttle, bike.riding and controller.stamina.can_boost(run, throttle))
	_cam_to = Vector4(player.x, player.feet, player.z, bike.heading)
	if bike.riding and not crash.active(): metrics.tick(dt, bike, routes[lane])
	if bike.land_impact > 0.0: last_land_impact = bike.land_impact
	if bike.bottom_out > 0.0: last_bottom_out = bike.bottom_out
	# These are one-tick events. Leaving them latched repeats the rider's landing animation.
	bike.land_impact = 0.0
	bike.bottom_out = 0.0

func _shaping_report() -> String:
	var stats: Dictionary = heights.road_refinement.trail_shaping.get(routes[lane].id, {})
	if stats.is_empty(): return "Рельеф: без земляных работ"
	return "Рельеф: выемка %.0f м³ (до %.2f м) · насыпь %.0f м³ (до %.2f м)
Уклон %.0f%% → %.0f%% · вираж до %.0f%%" % [stats.cut_m3, stats.max_cut, stats.fill_m3, stats.max_fill, stats.grade_natural * 100.0, stats.grade_designed * 100.0, stats.bank_peak * 100.0]

func _process(dt: float) -> void:
	if heights == null: return
	if status_time > 0.0:
		status_time -= dt
		if status_time <= 0.0: status.hide()
	var alpha := Engine.get_physics_interpolation_fraction()
	if crash.active(): crash.draw()
	else: view.draw(alpha)
	# Same interpolation as the bike model: the camera must not step at the physics rate.
	var at := _cam_from.lerp(_cam_to, alpha)
	var heading := lerp_angle(_cam_from.w, _cam_to.w, alpha)
	# Terrain bumps move the feet by whole centimetres per tick; follow them softly.
	_cam_feet = lerpf(_cam_feet, at.y, 1.0 - exp(-dt * 10.0)) if absf(at.y - _cam_feet) < 3.0 else at.y
	var target := Vector3(at.x, _cam_feet + 1.0, at.z)
	if overview:
		camera.position = Vector3(128, 240, 245)
		camera.look_at(Vector3(128, 12, 128))
	else:
		camera.position = target + Vector3(sin(heading) * 7, 3.5, cos(heading) * 7)
		camera.look_at(target)
	var contact := RideSurface.sample(heights.world, heights, bike.x, bike.z)
	var name := "вне трассы" if contact.surface == 0 else str(RoadSurface.LIST[contact.surface].name)
	telemetry.text = "TRAIL LAB  /  " + routes[lane].title
	route_hint.text = "Трасса %d / %d  ·  клавиши 1–%d" % [lane + 1, routes.size(), mini(routes.size(), 9)]
	speed_label.text = "%.0f\nкм/ч" % (absf(bike.speed) * 3.6)
	surface_label.text = name + ("  ·  ПАДЕНИЕ" if crash.active() else ("  ·  ПОЛЁТ" if bike.airborne else ""))
	stamina_label.text = "Выносливость  %.0f%%" % (controller.stamina.value * 100)
	stamina_bar.value = controller.stamina.value * 100
	if diagnostics_visible:
		diagnostics.text = "R старт  ·  G заезд  ·  %s посадка/сход\nW/S педали и тормоз  ·  A/D руль\nSpace прыжок  ·  Shift усилие\nF5 перечитать  ·  Esc назад\nПокрытие %.0f%%  ·  уклон %.1f%%\nСнос %.1f°  ·  сцепление %.0f%%\nПодвеска %.3f / %.3f м\n%s  ·  удар %.1f м/с
%s" % [services.controls.label("interact"), contact.weight * 100, bike.grade(heights) * 100, rad_to_deg(bike.slip), bike.grip_usage * 100, bike.squash_f, bike.squash_r, "ПАДЕНИЕ" if crash.active() else ("ПОЛЁТ" if bike.airborne else "ЗЕМЛЯ"), last_land_impact, metrics.report(routes[lane]) + "
" + _shaping_report()]
	status.position.y = hud_panel.position.y + hud_panel.size.y + 10
