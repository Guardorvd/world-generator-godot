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
var status := Label.new()
var editor := EditorPanel.new()
var lane := 0
var element_index := 0
var overview := false
var terrain := MeshInstance3D.new()
var markers := Node3D.new()
var last_land_impact := 0.0
var last_bottom_out := 0.0
var _sources: Array[TrailDefinition] = []

func _ready() -> void:
	if routes.is_empty(): routes = Fixture.definitions()
	_sources.assign(routes)
	add_child(terrain)
	add_child(markers)
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
	telemetry.position = Vector2(18, 18)
	status.position = Vector2(18, 235)
	status.custom_minimum_size.x = 850
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	for label in [telemetry, status]:
		label.add_theme_color_override("font_shadow_color", Color.BLACK)
		label.add_theme_constant_override("shadow_outline_size", 5)
		canvas.add_child(label)
	canvas.add_child(editor)
	editor.visible = false
	editor.course_selected.connect(func(index: int, kind: String) -> void:
		if rebuild(Fixture.course(index, kind)):
			overview = true)
	editor.route_selected.connect(select_route)
	editor.element_selected.connect(func(index: int) -> void:
		element_index = index
		editor.present(routes, lane, element_index))
	editor.apply_requested.connect(apply_edit)
	editor.launch_requested.connect(launch_element)
	editor.reload_requested.connect(reload_sources)
	get_viewport().size_changed.connect(_place_editor)
	_place_editor()
	rebuild(_copy_routes(routes))

func _place_editor() -> void:
	var viewport_size := get_viewport().get_visible_rect().size
	editor.size = Vector2(390, maxf(100.0, viewport_size.y - 36))
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
	var prepared := Fixture.prepare(candidate)
	if not prepared.errors.is_empty():
		show_message("Правка отклонена: " + "; ".join(prepared.errors))
		return false
	var next_heights: Heightfield = prepared.heights
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, TerrainBuilder.build_arrays(next_heights.world, next_heights))
	crash.abort()
	heights = next_heights
	routes = candidate
	terrain.mesh = mesh
	lane = clampi(lane, 0, routes.size() - 1)
	element_index = clampi(element_index, 0, maxi(0, routes[lane].elements.size() - 1))
	for child in markers.get_children(): child.free()
	for d in routes:
		_label(d.title, d.points[0], 3.0)
		for e in d.elements:
			_label("%s · %.1f м / %.1f м" % [TrailElement.Profile.keys()[e.profile], e.height, e.length], d.point_at(e.station), 1.8)
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
	if not d.elements.is_empty():
		var e := d.elements[element_index]
		e.profile = int(values.profile) as TrailElement.Profile
		for key in ["station", "length", "height", "bank"]: e.set(key, values[key])
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
	heights.obstacles.update(player.x, player.z, PackedFloat32Array(), 0, true)
	view.snap(bike)

func launch_element() -> void:
	if heights == null: return
	var station := 0.0
	if not routes[lane].elements.is_empty():
		var e := routes[lane].elements[element_index]
		station = maxf(0.0, e.station - e.length * 0.5 - 12.0)
	reset_ride(station, editor.numbers.speed.value / 3.6)
	editor.hide()
	get_viewport().gui_release_focus()
	show_message("Заезд с %.0f км/ч · R — старт трассы" % editor.numbers.speed.value)

func show_message(text: String) -> void:
	status.text = text

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
		editor.visible = not editor.visible
		get_viewport().gui_release_focus()
	if key == KEY_F5: reload_sources()
	if heights == null or editor.visible: return
	if key >= KEY_1 and key < KEY_1 + mini(routes.size(), 9): select_route(key - KEY_1)
	if key == KEY_R: reset_ride()
	if key == KEY_G: launch_element()
	if key == KEY_V: overview = not overview

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
	heights.obstacles.update(player.x, player.z, PackedFloat32Array(), 0)
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
	if bike.land_impact > 0.0: last_land_impact = bike.land_impact
	if bike.bottom_out > 0.0: last_bottom_out = bike.bottom_out
	# These are one-tick events. Leaving them latched repeats the rider's landing animation.
	bike.land_impact = 0.0
	bike.bottom_out = 0.0

func _process(_dt: float) -> void:
	if heights == null: return
	if crash.active(): crash.draw()
	else: view.draw(Engine.get_physics_interpolation_fraction())
	var target := Vector3(player.x, player.feet + 1.0, player.z)
	if overview:
		camera.position = Vector3(128, 240, 245)
		camera.look_at(Vector3(128, 12, 128))
	else:
		camera.position = target + Vector3(sin(bike.heading) * 7, 3.5, cos(bike.heading) * 7)
		camera.look_at(target)
	var contact := RideSurface.sample(heights.world, heights, bike.x, bike.z)
	var name := "вне трассы" if contact.surface == 0 else str(RoadSurface.LIST[contact.surface].name)
	var escape_hint := "выход" if exit_requested.get_connections().is_empty() else "в меню"
	telemetry.text = "TRAIL LAB | %s\n1–%d: трасса | R: старт | G: заезд | V: обзор | %s: посадка/сход\nF2: трассы и земляные работы | F5: перечитать файлы | Esc: %s\nW/S: педали/тормоз | A/D: руль | Space: прыжок | Shift: усилие\n%.1f км/ч | %s (%.0f%%) | уклон %.1f%%\nснос %.1f° | расход сцепления %.0f%% | подвеска %.3f / %.3f м\n%s | выносливость %.0f%% | последний удар %.1f м/с" % [routes[lane].title, mini(routes.size(), 9), services.controls.label("interact"), escape_hint, absf(bike.speed) * 3.6, name, contact.weight * 100, bike.grade(heights) * 100, rad_to_deg(bike.slip), bike.grip_usage * 100, bike.squash_f, bike.squash_r, "ПАДЕНИЕ" if crash.active() else ("ПОЛЁТ" if bike.airborne else "ЗЕМЛЯ"), controller.stamina.value * 100, last_land_impact]
