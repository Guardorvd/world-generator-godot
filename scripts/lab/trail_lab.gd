extends Node3D
const TrailLabTerrain := preload("res://scripts/lab/trail_lab_terrain.gd")
const TrailLabBuilder := preload("res://scripts/lab/trail_lab_builder.gd")
const Sites := preload("res://scripts/lab/trail_lab_sites.gd")
const TrailLabScout := preload("res://scripts/lab/trail_lab_scout.gd")
const Project := preload("res://scripts/lab/trail_lab_project.gd")
const ProjectPanel := preload("res://scripts/lab/trail_lab_project_panel.gd")
const Trial := preload("res://scripts/lab/trail_lab_trial.gd")
const TrialHud := preload("res://scripts/lab/trail_lab_trial_hud.gd")
var trial: RefCounted
var trial_hud := TrialHud.new()
var trial_visuals := Node3D.new()
const GAME_EXAMPLE := "res://resources/trails/lab/game_example_111_44101.tres"
var project_panel := ProjectPanel.new()
var draft_project: Project
var active_project: Project
var variants := {}
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
## разгрузка переднего колеса от сценария, а не от клавиши Q (замеры)
var body_back := false
var body_back_forced := false
var contact_model := bike.contact_model # общая игровая модель; F6 — сравнить с прежней
var view: BikeView
var brake_effects := BrakeEffects.new()
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
var save_control := Button.new() # «Сохранить запись»: сессия тестов попадает в ride_logs/ только по нажатию
var status := Label.new()
var diagnostics := Label.new()
var diagnostics_scroll := ScrollContainer.new()
var hud_panel := PanelContainer.new()
var diagnostics_visible := false
var status_time := 0.0
var editor := EditorPanel.new()
## Готовые трассы (TrailLabCatalog): плитки внизу экрана, PageUp/PageDown — соседняя
var preset := 0
var preset_panel := PanelContainer.new()
var preset_label := Label.new()
var preset_select := OptionButton.new()
var generator_label := Label.new() # сиды и итог генераторов, когда выбрана сгенерированная трасса
var site_row := HBoxContainer.new()  # v3: места большого мира
var site_select := OptionButton.new()
var _world_thread: Thread
var _world_job: RefCounted
var _world_request := 0
var _world_started := 0
var lane := 0
var element_index := 0
var overview := false
var terrain := MeshInstance3D.new()
var markers := Node3D.new()
## Problem intervals of the finished surface (red — over the grade requirement, orange — not measured).
var survey_markers := Node3D.new()
var props := Node3D.new()
## Finished-surface surveys of the current routes by id, and the explicit grade requirement they are judged by, m/m.
var surveys := {}
var grade_requirement := 0.2
## Stage times of the last successful build, ms; -1 — the stage did not run.
var build_timings := {}
var technical := {collide = PackedFloat32Array(), bumps = PackedFloat32Array(), props = [], lines = {}, decks = []}
var last_land_impact := 0.0
var last_bottom_out := 0.0
var metrics := TrailLabMetrics.new()
var _cam_from := Vector4() # x, feet, z, heading on the previous physics tick
var _cam_to := Vector4()
var _cam_feet := 0.0
## Свободный угол обзора; расстояние и FOV мягко передают ускорение и торможение.
var _cam_surge := 0.0
var _cam_brake := 0.0
var _cam_yaw := 0.0
var _cam_pitch := -0.464
var _cam_fov := -1.0
var _sources: Array[TrailDefinition] = []
## Test ground of the current session (Fixture.GROUNDS): the lab's gentle slope, a window of world relief or a saved site.
var ground_kind := "flat"
## Water of a saved site (WaterBuilder, as in the game) and the ground whose look (texture, world offset) is applied.
var water := Node3D.new()
## Bridges and tunnels of a saved site (StructuresBuilder over the same Heightfield.structures the wheels ride).
## Lab decks of elements are drawn by TrailLabProps and are not part of this list.
var structures := Node3D.new()
var _look := ""
## Last run of the line builder (TrailRouter), successful or refused; shown in F3 while its line is on the site.
var line_result: TrailRouter
## Last automatic choice of the place (TrailPicker); null after a manual line.
var pick_result: TrailPicker
## Elements on the found line (TrailFlow) of the last «Найти трассу» in the flow mode; null otherwise.
var flow_result: TrailFlow
## Лес вокруг трассы (главный полигон): тот же VegetationLayer, что в игре, над объектами мира лаборатории; null — леса нет.
var vegetation: VegetationLayer
## Автопилот (P — по кругу: выкл, осторожно, flow, на пределе): ведёт велосипед тем же вводом, что игрок.
const Autopilot = preload("res://scripts/lab/trail_autopilot.gd")
var autopilot: RefCounted
## Запись заезда в ride_logs/<дата>/ (всё из F3, ввод, положение, события): scripts/lab/trail_lab_recorder.gd
const Recorder = preload("res://scripts/lab/trail_lab_recorder.gd")
var recorder := Recorder.new()

func _ready() -> void:
	if routes.is_empty(): routes = Fixture.definitions()
	_sources.assign(routes)
	add_child(terrain)
	add_child(markers)
	add_child(survey_markers)
	add_child(props)
	add_child(water)
	add_child(structures)
	add_child(trial_visuals)
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
	add_child(brake_effects)
	add_child(crash)
	add_child(camera)
	camera.current = true
	camera.far = 800.0
	var canvas := CanvasLayer.new()
	add_child(canvas)
	canvas.add_child(trial_hud)
	trial_hud.hide()
	trial_hud.retry_requested.connect(func() -> void: reset_ride())
	trial_hud.exit_requested.connect(close_game_example)
	hud_panel.position = Vector2(12, 12)
	hud_panel.theme_type_variation = "HudPanel"
	canvas.add_child(hud_panel)
	var hud_margin := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]: hud_margin.add_theme_constant_override("margin_" + side, 8)
	hud_panel.add_child(hud_margin)
	var hud_box := VBoxContainer.new()
	hud_box.add_theme_constant_override("separation", 3)
	hud_margin.add_child(hud_box)
	telemetry.theme_type_variation = "AccentLabel"
	telemetry.add_theme_font_size_override("font_size", 14)
	telemetry.custom_minimum_size.x = 240
	telemetry.clip_text = true
	speed_label.add_theme_font_size_override("font_size", 21)
	surface_label.theme_type_variation = "HintLabel"
	stamina_label.theme_type_variation = "HintLabel"
	stamina_label.add_theme_font_size_override("font_size", 12)
	stamina_bar.show_percentage = false
	stamina_bar.custom_minimum_size.y = 7
	diagnostics.add_theme_font_size_override("font_size", 13)
	diagnostics.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	diagnostics.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	diagnostics.visible = false
	diagnostics_scroll.custom_minimum_size = Vector2(280, 220)
	diagnostics_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	diagnostics_scroll.visible = false
	hud_box.add_child(telemetry)
	route_hint.theme_type_variation = "HintLabel"
	route_hint.add_theme_font_size_override("font_size", 11)
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
	settings_control.text = "F2  Трасса"
	settings_control.add_theme_font_size_override("font_size", 12)
	settings_control.tooltip_text = "Открыть настройки трассы"
	settings_control.pressed.connect(func() -> void: set_editor_visible(not editor.visible))
	hud_actions.add_child(settings_control)
	camera_control.pressed.connect(func() -> void: set_overview(not overview))
	camera_control.add_theme_font_size_override("font_size", 12)
	hud_actions.add_child(camera_control)
	details_control.text = "F3  Инфо"
	details_control.add_theme_font_size_override("font_size", 12)
	details_control.pressed.connect(func() -> void: set_diagnostics_visible(not diagnostics_visible))
	hud_actions.add_child(details_control)
	save_control.add_theme_font_size_override("font_size", 12)
	save_control.focus_mode = Control.FOCUS_NONE # пробел (прыжок) не нажимает кнопку
	save_control.pressed.connect(save_ride_log)
	hud_box.add_child(save_control)
	hud_box.add_child(diagnostics_scroll)
	diagnostics_scroll.add_child(diagnostics)
	status.position = Vector2(18, 110)
	status.custom_minimum_size.x = 220
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	for label in [telemetry, diagnostics, status]:
		label.add_theme_color_override("font_shadow_color", Color.BLACK)
		label.add_theme_constant_override("shadow_outline_size", 5)
	canvas.add_child(status)
	_build_presets(canvas)
	add_child(project_panel)
	project_panel.preview_requested.connect(preview_site)
	project_panel.build_requested.connect(build_draft_project)
	project_panel.save_requested.connect(save_project_slot)
	project_panel.restore_requested.connect(restore_project_slot)
	project_panel.world_requested.connect(open_game_world)
	canvas.add_child(editor)
	editor.visible = false
	editor.course_selected.connect(func(index: int, kind: String, style: String, ground: String) -> void:
		var previous := ground_kind
		ground_kind = ground
		var course := Fixture.course(index, kind, style, ground)
		if course.is_empty() and ground == "site":
			show_message("Площадка не открыта: " + Fixture.site_error)
			ground_kind = previous
			return
		if rebuild(course, Fixture.compose_ms):
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
	editor.generator_requested.connect(configure_generator)
	editor.launch_requested.connect(launch_element)
	editor.reload_requested.connect(reload_sources)
	editor.requirement_changed.connect(func(grade: float) -> void: set_grade_requirement(grade / 100.0))
	editor.line_requested.connect(build_line)
	editor.find_requested.connect(find_trail)
	editor.numbers.required_grade.value = grade_requirement * 100.0
	set_overview(false)
	get_viewport().size_changed.connect(_place_editor)
	_place_editor()
	rebuild(_copy_routes(routes))

## Компактный выбор трассы; PageUp/PageDown работают также во время заезда.
func _build_presets(canvas: CanvasLayer) -> void:
	preset_panel.theme_type_variation = "HudPanel"
	preset_panel.resized.connect(_place_presets)
	canvas.add_child(preset_panel)
	var margin := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]: margin.add_theme_constant_override("margin_" + side, 8)
	preset_panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	margin.add_child(box)
	preset_label.theme_type_variation = "HintLabel"
	preset_label.add_theme_font_size_override("font_size", 12)
	box.add_child(preset_label)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	box.add_child(row)
	var previous := Button.new()
	previous.text = "‹"
	previous.tooltip_text = "Предыдущая трасса · PageUp"
	previous.pressed.connect(func() -> void: select_preset(preset - 1))
	row.add_child(previous)
	preset_select.fit_to_longest_item = false
	preset_select.clip_text = true
	preset_select.custom_minimum_size.x = 220
	preset_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preset_select.add_theme_font_size_override("font_size", 12)
	preset_select.tooltip_text = "Выбрать трассу · F2 или V для курсора"
	for i in TrailLabCatalog.LIST.size():
		preset_select.add_item("%d · %s" % [i + 1, TrailLabCatalog.LIST[i].title], i)
	preset_select.item_selected.connect(func(index: int) -> void: select_preset(index))
	row.add_child(preset_select)
	var next := Button.new()
	next.text = "›"
	next.tooltip_text = "Следующая трасса · PageDown"
	next.pressed.connect(func() -> void: select_preset(preset + 1))
	row.add_child(next)
	# 01.11: генераторы — случайная местность и трасса по ней (кубик, F7) и новая трасса на той же местности (F8)
	var gen_row := HBoxContainer.new()
	gen_row.add_theme_constant_override("separation", 4)
	box.add_child(gen_row)
	var dice := Button.new()
	dice.icon = _dice_icon()
	dice.text = "Новый мир"
	dice.add_theme_font_size_override("font_size", 12)
	dice.focus_mode = Control.FOCUS_NONE
	dice.tooltip_text = "Новый мир размером с карту игры, поиск мест под трассы и трассы на них · F7\nРазмеры элементов — по расчётным стандартам под скорость в каждом месте"
	dice.pressed.connect(func() -> void: generate_random(true))
	gen_row.add_child(dice)
	var again := Button.new()
	again.icon = _again_icon()
	again.text = "Другая линия"
	again.add_theme_font_size_override("font_size", 12)
	again.focus_mode = Control.FOCUS_NONE
	again.tooltip_text = "Другая трасса на этом месте · F8"
	again.pressed.connect(func() -> void: generate_random(false))
	gen_row.add_child(again)
	var examples := MenuButton.new()
	examples.text = "Ещё ▾"
	examples.add_theme_font_size_override("font_size", 12)
	examples.focus_mode = Control.FOCUS_NONE
	examples.tooltip_text = "Карта мест, варианты А/Б и игровые примеры"
	examples.get_popup().add_item("Карта мест · А/Б", 0)
	examples.get_popup().add_separator()
	examples.get_popup().add_item("Игровой пример: мир 111 · F10", 1)
	examples.get_popup().add_item("Игровой пример: мир 7", 2)
	examples.get_popup().id_pressed.connect(func(id: int) -> void:
		if id == 0: show_projects()
		elif id == 1: open_game_example()
		elif id == 2: open_game_example("res://resources/trails/lab/game_example_7_9066.tres"))
	gen_row.add_child(examples)
	# v3: места большого мира — список с переключением (‹ › или [ ]): выбор строит окно места и ставит на старт
	site_row.add_theme_constant_override("separation", 4)
	site_row.visible = false
	box.add_child(site_row)
	var site_prev := Button.new()
	site_prev.text = "‹"
	site_prev.focus_mode = Control.FOCUS_NONE
	site_prev.tooltip_text = "Предыдущее место · ["
	site_prev.pressed.connect(func() -> void: select_site(Sites.current - 1))
	site_row.add_child(site_prev)
	site_select.fit_to_longest_item = false
	site_select.clip_text = true
	site_select.custom_minimum_size.x = 220
	site_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	site_select.add_theme_font_size_override("font_size", 12)
	site_select.tooltip_text = "Места трасс в мире · [ ]"
	site_select.item_selected.connect(func(index: int) -> void: select_site(index))
	site_row.add_child(site_select)
	var site_next := Button.new()
	site_next.text = "›"
	site_next.focus_mode = Control.FOCUS_NONE
	site_next.tooltip_text = "Следующее место · ]"
	site_next.pressed.connect(func() -> void: select_site(Sites.current + 1))
	site_row.add_child(site_next)
	generator_label.theme_type_variation = "HintLabel"
	generator_label.add_theme_font_size_override("font_size", 11)
	generator_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	generator_label.custom_minimum_size.x = 280
	generator_label.visible = false
	box.add_child(generator_label)
	_mark_preset()

## Генераторы лаборатории: new_terrain — новая местность (сид и характер), иначе прежняя; трасса — новый сид и стиль.
## Строится тем же путём, что готовая трасса (select_preset): при отказе остаётся прежняя.
func generate_random(new_terrain: bool) -> bool:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	# v3: новый мир — в фоне (география игры целиком), трассы мест — по выбору; другая линия — на текущем месте
	if new_terrain:
		return generate_world(rng.randi_range(1, 99999))
	if Sites.active():
		var ok := Sites.reroll(Sites.current, rng.randi_range(1, 99999))
		_fill_sites()
		if ok: draft_project = Sites.project(); show_projects()
		return ok
	if new_terrain or TrailLabTerrain.cells.is_empty():
		TrailLabTerrain.seed = rng.randi_range(1, 99999)
		TrailLabTerrain.kind = TrailLabTerrain.ORDER[rng.randi() % TrailLabTerrain.ORDER.size()]
	TrailLabBuilder.seed = rng.randi_range(1, 99999)
	var index := -1
	for i in TrailLabCatalog.LIST.size():
		if TrailLabCatalog.LIST[i].ground == "generated": index = i
	var ok := select_preset(index)
	if not ok and not TrailLabBuilder.stats.get("reason", "").is_empty(): show_message(str(TrailLabBuilder.stats.reason))
	return ok

## v3: мир размером с карту игры и места трасс — в фоновом потоке (лаборатория остаётся живой); по готовности —
## список мест и первое место. Повторное нажатие во время генерации ничего не делает.
func open_game_world(source: Dictionary) -> bool:
	if source.has("save_snapshot"):
		if TrailLabTerrain.world_input == null or str(source.save_snapshot).is_empty():
			show_message("Откройте игровой мир и укажите путь .res для снимка")
			return false
		var error := ResourceSaver.save(TrailLabTerrain.world_input, source.save_snapshot)
		show_message("Снимок сохранён" if error == OK else "Не удалось сохранить снимок: %s" % error)
		return error == OK
	return generate_world(0, source)

func generate_world(seed_value: int, source := {}) -> bool:
	if _world_thread != null: return false
	show_message("Мир %d: география как в игре и поиск мест…" % seed_value)
	generator_label.visible = true
	generator_label.text = "Генерирую мир %d…" % seed_value
	if source.has("game_seed"):
		generator_label.text = "Игровой мир «%s»: подготовка и поиск…" % source.game_seed
		show_message(generator_label.text)
	elif source.has("snapshot_path"):
		generator_label.text = "Открываю снимок мира и ищу места…"
		show_message(generator_label.text)
	_world_started = Time.get_ticks_msec()
	_world_request += 1
	_world_job = Sites.WorldJob.new(_world_request, seed_value, source if not source.is_empty() else TrailLabTerrain.world_snapshot())
	_world_thread = Thread.new()
	var error := _world_thread.start(_world_job.run)
	if error != OK:
		_world_thread = null
		_world_job = null
		show_message("Не удалось запустить задачу мира")
		return false
	return true

func _poll_world() -> void:
	if _world_thread == null: return
	var additions := []
	for update: Dictionary in _world_job.take_updates():
		if update.request_id != _world_request: continue
		if update.has("terrain"):
			Sites.publish_world({request_id = _world_request, terrain = update.terrain, sites = [], scout = {}, timings = {}}, _world_request)
			draft_project = null
			project_panel.description.text = "Ищу выразительные места…"
			show_projects()
		elif update.has("site"): additions.append(update.site)
	if not additions.is_empty() and Sites.append_sites(additions, _world_request):
		_fill_sites()
		project_panel.map.sites = Sites.sites.duplicate(true)
		project_panel.map.queue_redraw()
		generator_label.text = "Найдено мест: %d · поиск продолжается · можно выбирать" % Sites.sites.size()
		if draft_project == null: project_panel.description.text = "Найдено мест: %d. Выберите коридор на карте — поиск продолжится." % Sites.sites.size()
	if _world_thread.is_alive(): return
	var result = _world_thread.wait_to_finish()
	_world_thread = null
	_world_job = null
	if not result is Dictionary:
		show_message("Задача мира завершилась без результата")
		return
	if result.has("error"):
		show_message(str(result.error))
		return
	if Sites.published_request != _world_request:
		if not Sites.publish_world(result, _world_request): return
	else:
		Sites.append_sites(result.sites.slice(Sites.sites.size()), _world_request)
		TrailLabScout.stats = result.scout.duplicate(true)
		Sites.world_timings = result.timings.duplicate(true)
	_fill_sites()
	project_panel.map.sites = Sites.sites.duplicate(true)
	project_panel.map.queue_redraw()
	var count := Sites.sites.size()
	var seconds := (Time.get_ticks_msec() - _world_started) / 1000.0
	if count == 0:
		show_message("Мир готов за %.0f с, но мест под трассы нет: %s" % [seconds, TrailLabScout.stats.get("reason", "")])
		generator_label.text = "Мест не нашлось — F7, другой мир"
		project_panel.description.text = "Свободных коридоров не найдено."
		return
	show_message("Мир готов за %.0f с · мест под трассы: %d" % [seconds, count])
	generator_label.text = "Мест: %d · выберите коридор на карте" % count
	if draft_project == null: project_panel.description.text = "Найдено мест: %d. Выберите коридор на карте." % count
	_refresh_projects()

## Место i большого мира: окно земли, трасса места (строится при первом выборе) и старт на ней.
func select_site(i: int) -> bool:
	if Sites.sites.is_empty() or (_world_thread != null and Sites.published_request != _world_request): return false
	i = posmod(i, Sites.sites.size())
	var ok := Sites.select(i)
	_fill_sites()
	return _show_site(ok)

func _show_site(ok: bool) -> bool:
	if not ok:
		show_message("Трасса места не проложилась: " + str(TrailLabBuilder.stats.get("reason", "")))
		return false
	draft_project = Sites.project()
	var index := -1
	for k in TrailLabCatalog.LIST.size():
		if TrailLabCatalog.LIST[k].ground == "generated": index = k
	lane = 0
	return select_preset(index)

func preview_site(index: int) -> bool:
	if (_world_thread != null and Sites.published_request != _world_request) or index < 0 or index >= Sites.sites.size(): return false
	var ok := Sites.select(index)
	draft_project = Sites.project()
	_fill_sites()
	show_projects()
	return ok

func show_projects() -> void:
	for slot in ["A", "B"]:
		var path := "user://trail_lab_variants/%s.tres" % slot
		if not variants.has(slot) and FileAccess.file_exists(path):
			var opened := Project.open(path)
			if opened.has("project"): variants[slot] = opened.project
	project_panel.map.set_world(TrailLabTerrain.world_snapshot(), Sites.sites)
	project_panel.map.selected = Sites.current
	_refresh_projects()
	project_panel.popup_centered(Vector2i(mini(680, int(get_viewport().get_visible_rect().size.x) - 32), mini(600, int(get_viewport().get_visible_rect().size.y) - 32)))

func _refresh_projects() -> void:
	project_panel.map.slot_a = variants.get("A")
	project_panel.map.slot_b = variants.get("B")
	project_panel.map.queue_redraw()
	if draft_project != null:
		var m := Project.metrics(draft_project)
		var project_status := "полотно проверено" if m.accepted else "проект без проверки полотна"
		if not m.accepted and draft_project.report.get("base_surface", {}).get("accepted", false): project_status = "базовое полотно проверено; итоговая сцена ещё не проверена"
		if not m.accepted and draft_project.report.has("reason"): project_status = "отклонён: " + str(draft_project.report.reason)
		project_panel.description.text = "%s · сид %d · %.0f м · элементов %d · %s" % [m.title, m.seed, m.length, m.elements, project_status]
		if draft_project.source.river_policy == draft_project.source.RiverPolicy.LAB_DRY_CHANNELS: project_panel.description.text += " · сухие русла (Trail Lab)"
		var validation: Dictionary = draft_project.report.get("validation", {})
		if not validation.is_empty():
			var assessments: Dictionary = validation.values()[0].get("assessments", {})
			if not assessments.is_empty():
				var jump_result := "не предусмотрены" if int(draft_project.report.get("jumps", 0)) == 0 else ("да" if assessments.jump_intent else "не подтверждены")
				project_panel.description.text += "\nРасчёт: безопасность %s · задуманные прыжки %s · быстро (≥12 м/с в среднем) %s" % ["да" if assessments.safety else "нет", jump_result, "да" if assessments.fast_pass else "не подтверждено"]
	var compared := Project.compare(variants.get("A"), variants.get("B"))
	project_panel.comparison.text = "Сохраните удачные варианты А и Б после проверки полотна. Файлы переживают перезапуск."
	if not compared.has("error"):
		project_panel.comparison.text = "А (голубой): %.0f м, %d эл. · Б (розовый): %.0f м, %d эл. · Б−А: %+.0f м, %+d эл., выемка %+.0f м³, насыпь %+.0f м³ · %s" % [compared.a.length, compared.a.elements, compared.b.length, compared.b.elements, compared.delta_length, compared.delta_elements, compared.delta_cut_m3, compared.delta_fill_m3, "одни входные данные" if compared.same_source else "разные входные данные"]
	project_panel.timings.text = "География %.0f мс · поиск %.0f мс · проект %.0f мс · сцена %.0f мс" % [Sites.world_timings.get("geography_ms", 0), Sites.world_timings.get("search_ms", 0), draft_project.timings.get("project_ms", 0) if draft_project != null else 0, build_timings.get("total_ms", 0)]

func build_draft_project() -> bool:
	if draft_project == null or draft_project.routes.is_empty(): return false
	var report := draft_project.report.duplicate(true)
	var first := draft_project.routes[0]
	var drop := draft_project.source.ground(first.points[0]) - draft_project.source.ground(first.points[-1])
	report.merge({title = TrailLabBuilder.STYLES.get(draft_project.style, {title = draft_project.title}).title,
		length = first.route_length(), drop = drop, grade = -drop / maxf(1, first.route_length()) * 100,
		elements = first.elements.size()}, true)
	TrailLabBuilder.publish_project({stats = report, cuts = draft_project.cuts, speeds = PackedFloat32Array(), seed = draft_project.seed, style = draft_project.style})
	var source = draft_project.source.duplicate(true)
	source.apply_cuts(draft_project.cuts)
	var candidate := draft_project.copy_routes()
	var previous := ground_kind
	ground_kind = "generated"
	var ready := Fixture.prepare(candidate, true, "generated", source)
	var ok := rebuild(candidate, -1, ready)
	if not ok: ground_kind = previous
	_refresh_projects()
	return ok

func open_game_example(path := GAME_EXAMPLE) -> bool:
	if _world_thread != null: return false
	var opened := Project.open(path)
	if not opened.has("project"):
		show_message(opened.get("error", "Игровой пример не найден")); return false
	close_game_example()
	draft_project = opened.project
	Sites.current = -1
	if not build_draft_project(): return false
	var location := Trial.safe_spawn(heights, routes[0], active_project.source)
	if not location.accepted: show_message(location.reason); return false
	trial = Trial.new()
	trial.configure(routes[0], location)
	trial.title = active_project.title
	if not active_project.report.get("fast_pass_confirmed", true): trial.pace_note = "Проверен осторожный темп · скоростной проезд не подтверждён"
	preload("res://scripts/lab/trail_lab_trial_visuals.gd").build(trial_visuals, heights, routes[0], location, active_project.source)
	set_editor_visible(false)
	set_overview(false)
	project_panel.hide()
	trial_hud.show()
	hud_panel.hide(); preset_panel.hide(); markers.hide(); survey_markers.hide()
	reset_ride()
	status.hide()
	generator_label.hide()
	return true

func close_game_example() -> void:
	trial = null
	trial_hud.hide()
	hud_panel.show(); preset_panel.show()
	markers.visible = overview or diagnostics_visible
	survey_markers.visible = overview or diagnostics_visible
	for child in trial_visuals.get_children(): child.free()

func save_project_slot(slot: String) -> bool:
	if slot not in ["A", "B"] or active_project == null or not active_project.accepted:
		show_message("Сначала постройте и проверьте удачный проект")
		return false
	DirAccess.make_dir_recursive_absolute("user://trail_lab_variants")
	var saved := active_project.detached() as Project
	if saved.save_to("user://trail_lab_variants/%s.tres" % slot) != OK:
		show_message("Не удалось сохранить вариант " + slot)
		return false
	variants[slot] = saved
	_refresh_projects()
	show_message("Вариант %s сохранён" % slot)
	return true

func restore_project_slot(slot: String) -> bool:
	if not variants.has(slot): show_message("Вариант %s ещё не сохранён" % slot); return false
	draft_project = variants[slot].detached() as Project
	return build_draft_project()

func _fill_sites() -> void:
	site_select.clear()
	for k in Sites.sites.size(): site_select.add_item(Sites.title(k), k)
	if Sites.current >= 0: site_select.select(Sites.current)
	site_row.visible = not Sites.sites.is_empty()
	if Sites.active():
		var site: Dictionary = Sites.sites[Sites.current]
		editor.set_generator_site(site.styles, site.style, site.settings)

func configure_generator(settings: Dictionary) -> bool:
	if _world_thread != null: return false
	if Sites.active():
		var site: Dictionary = Sites.sites[Sites.current]
		if settings.style not in site.styles:
			show_message("Этот характер не подтверждён пробной прокладкой участка")
			return false
		site.style = settings.style
		site.settings = settings.duplicate(true)
		Sites._built.erase(Sites.current)
		return select_site(Sites.current)
	if settings.get("short_route", false):
		show_message("Короткий маршрут требует выбранного места с пробным коридором")
		return false
	TrailLabBuilder.style = settings.style
	TrailLabBuilder.difficulty = settings.difficulty
	TrailLabBuilder.modification = settings.modification
	TrailLabBuilder.mandatory_gaps = settings.mandatory_gaps
	TrailLabBuilder.park_layout = settings.park_layout
	for i in TrailLabCatalog.LIST.size():
		if TrailLabCatalog.LIST[i].ground == "generated": return select_preset(i)
	return false

## Значок кубика 16×16: светлая грань с пятью точками.
static func _dice_icon() -> ImageTexture:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for y in range(1, 15):
		for x in range(1, 15):
			var corner := (x < 3 or x > 12) and (y < 3 or y > 12) and Vector2(x, y).distance_to(Vector2(clampi(x, 3, 12), clampi(y, 3, 12))) > 2.0
			if not corner: img.set_pixel(x, y, Color(0.93, 0.93, 0.9))
	for c: Vector2i in [Vector2i(4, 4), Vector2i(11, 4), Vector2i(7, 7), Vector2i(4, 11), Vector2i(11, 11)]:
		for oy in range(0, 2):
			for ox in range(0, 2): img.set_pixel(c.x + ox, c.y + oy, Color(0.15, 0.17, 0.2))
	return ImageTexture.create_from_image(img)

## Значок «ещё раз» 16×16: дуга со стрелкой.
static func _again_icon() -> ImageTexture:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var ink := Color(0.93, 0.93, 0.9)
	for k in 64:
		var a := lerpf(0.5, TAU - 0.3, k / 63.0)
		var p := Vector2(7.5, 8.0) + Vector2(cos(a), sin(a)) * 5.5
		img.set_pixel(clampi(roundi(p.x), 0, 15), clampi(roundi(p.y), 0, 15), ink)
		img.set_pixel(clampi(roundi(p.x + 0.5), 0, 15), clampi(roundi(p.y), 0, 15), ink)
	for t: Vector2i in [Vector2i(12, 2), Vector2i(13, 3), Vector2i(14, 4), Vector2i(12, 3), Vector2i(12, 4), Vector2i(13, 4), Vector2i(11, 4), Vector2i(10, 4)]:
		img.set_pixel(t.x, t.y, ink)
	return ImageTexture.create_from_image(img)

func _place_presets() -> void:
	var viewport_size := get_viewport().get_visible_rect().size
	preset_panel.position = Vector2(12, maxf(12.0, viewport_size.y - preset_panel.size.y - 12))

func _mark_preset() -> void:
	preset_select.select(preset)
	preset_label.text = "ТРАССА  %d / %d   ·   PgUp / PgDn" % [preset + 1, TrailLabCatalog.LIST.size()]
	preset_select.tooltip_text = TrailLabCatalog.LIST[preset].title + "\nF2 или V — курсор"
	generator_label.visible = TrailLabCatalog.LIST[preset].ground == "generated" or _world_thread != null or Sites.active()
	if generator_label.visible and _world_thread == null:
		generator_label.text = Sites.label() if Sites.active() else "%s\n%s" % [TrailLabTerrain.label(), TrailLabBuilder.label()]
	site_row.visible = not Sites.sites.is_empty()

## Построить готовую трассу номер index вместо текущей (тем же путём, что «Построить» в F2); при отказе остаётся прежняя
func select_preset(index: int) -> bool:
	index = posmod(index, TrailLabCatalog.LIST.size())
	var previous := ground_kind
	var previous_preset := preset
	preset = index
	ground_kind = TrailLabCatalog.LIST[index].ground
	var kit := TrailLabCatalog.routes(index, Fixture)
	if kit.is_empty() or not rebuild(kit, Fixture.compose_ms):
		ground_kind = previous
		preset = previous_preset
		_mark_preset()
		return false
	preset = index
	_mark_preset()
	return true

func _place_editor() -> void:
	var viewport_size := get_viewport().get_visible_rect().size
	preset_panel.size = Vector2(minf(viewport_size.x - 24.0, 320.0), 0)
	_place_presets()
	editor.size = Vector2(360, maxf(100.0, viewport_size.y - 36))
	editor.position = Vector2(maxf(18.0, viewport_size.x - editor.size.x - 18), 18)

func _copy_routes(source: Array[TrailDefinition]) -> Array[TrailDefinition]:
	var copies: Array[TrailDefinition] = []
	for d in source: copies.append(d.duplicate(true) as TrailDefinition if d != null else null)
	return copies

## Transactional edit: prepare data and mesh first, then replace the live session.
## `compose_ms` — time the caller spent composing the elements (-1 — not composed); counted in the total.
## `ready` — a Fixture.prepare result the caller already built for exactly these routes (the line builder): not rebuilt.
func rebuild(candidate: Array[TrailDefinition], compose_ms := -1.0, ready := {}, input_source = null) -> bool:
	var started := Time.get_ticks_usec()
	if candidate.is_empty():
		show_message("Нужна хотя бы одна трасса")
		return false
	var prepared := ready if not ready.is_empty() else Fixture.prepare(candidate, true, ground_kind, input_source)
	if Sites.active(): _fill_sites()
	if not prepared.errors.is_empty():
		show_message("Правка отклонена: " + "; ".join(prepared.errors))
		return false
	var timings: Dictionary = prepared.timings.duplicate()
	timings.compose_ms = compose_ms
	var next_heights: Heightfield = prepared.heights
	var stage := Time.get_ticks_usec()
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, TerrainBuilder.build_arrays(next_heights.world, next_heights))
	timings.mesh_ms = (Time.get_ticks_usec() - stage) / 1000.0
	stage = Time.get_ticks_usec()
	var next_technical: Dictionary = prepared.technical if prepared.has("technical") else TrailTechnical.build(next_heights, candidate)
	timings.technical_ms = float(timings.get("technical_ms", 0.0)) + (Time.get_ticks_usec() - stage) / 1000.0
	# Measured after the earthworks and the decks: the profile the wheel will actually ride.
	stage = Time.get_ticks_usec()
	var next_surveys := {}
	for d in candidate:
		var survey := TrailSurvey.measure(next_heights, d, grade_requirement)
		if not survey.errors.is_empty():
			show_message("Правка отклонена: " + "; ".join(survey.errors))
			return false
		next_surveys[d.id] = survey
	timings.survey_ms = (Time.get_ticks_usec() - stage) / 1000.0
	stage = Time.get_ticks_usec()
	if trial != null: close_game_example()
	crash.abort()
	heights = next_heights
	routes = candidate
	technical = next_technical
	_apply_look()
	heights.obstacles.set_trail(technical.collide, technical.bumps)
	for child in props.get_children(): child.free()
	TrailLabProps.populate(props, technical.props)
	terrain.mesh = mesh
	_plant_forest()
	lane = clampi(lane, 0, routes.size() - 1)
	element_index = clampi(element_index, 0, maxi(0, routes[lane].elements.size() - 1))
	for child in markers.get_children(): child.free()
	for d in routes:
		_label(d.title, d.points[0], 3.0)
		for s: Dictionary in d.sections:
			_label("Участок · %s · сложность %.2f" % [TrailComposer.MOODS[s.mood].title, s.difficulty], d.point_at(s.from), 4.2)
		for e in d.elements:
			_label("%s · %.1f м / %.1f м" % [TrailElementLibrary.title(e.profile), e.height, e.length], d.point_at(e.station), 1.8)
	surveys = next_surveys
	_mark_survey()
	editor.present(routes, lane, element_index)
	reset_ride()
	timings.apply_ms = (Time.get_ticks_usec() - stage) / 1000.0
	timings.total_ms = (Time.get_ticks_usec() - started) / 1000.0 + maxf(0.0, compose_ms) + (float(prepared.timings.get("prepare_total_ms", 0)) if not ready.is_empty() else 0.0)
	build_timings = timings
	if prepared.get("source") != null:
		var template: Project
		if draft_project != null and not draft_project.routes.is_empty() and draft_project.routes[0].id == candidate[0].id: template = draft_project
		elif active_project != null and not active_project.routes.is_empty() and active_project.routes[0].id == candidate[0].id: template = active_project
		var project := Project.new() if template == null else template.detached() as Project
		if template == null:
			project.title = candidate[0].title
			project.seed = TrailLabBuilder.seed
			project.style = TrailLabBuilder.style
			project.settings = {difficulty = TrailLabBuilder.stats.get("difficulty", 0.5), modification = TrailLabBuilder.stats.get("modification", 0.5)}
			project.cuts = TrailLabBuilder.cuts.duplicate(true)
		project.source = prepared.source.duplicate(true)
		project.source_hash = project.source.fingerprint()
		project.routes = _copy_routes(candidate)
		project.accepted = true
		project.timings.merge(timings, true)
		project.report = TrailLabBuilder.stats.duplicate(true)
		active_project = project
		draft_project = project.detached() as Project
		_refresh_projects()
	show_message("Готово за %.0f мс · правки действуют в текущем запуске" % timings.total_ms)
	return true

## Лес мира лаборатории (объекты StageVegetation, их кладёт Fixture.prepare для главного полигона) рисует свой
## VegetationLayer; без объектов прежний слой убирается.
func _plant_forest() -> void:
	if vegetation != null:
		vegetation.queue_free()
		vegetation = null
	if heights.world.obj_count == 0: return
	vegetation = VegetationLayer.new()
	vegetation.settings = services.settings
	add_child(vegetation)
	vegetation.setup(heights.world, heights, Models.tree_defs(), Models.grass_mesh())
	vegetation.update(player.x, player.z, true)

## Line builder on the saved site: search over the natural ground, one full build of the chosen candidate
## (TrailRouter), then the usual transactional replacement with that build. A refusal or an unmet requirement
## keeps the previous route and scene. `values` — the route_* numbers of the panel.
func build_line(values: Dictionary) -> bool:
	var pressed := Time.get_ticks_usec()
	var site := Fixture.site()
	if site == null:
		show_message("Площадка не открыта: " + Fixture.site_error)
		return false
	var request := _line_requirements(values)
	request.merge({start = Vector2(values.route_start_x, values.route_start_z), finish = Vector2(values.route_finish_x, values.route_finish_z),
		budget = int(values.route_budget * 1000.0)})
	var result := TrailRouter.build(site, request)
	line_result = result
	pick_result = null
	editor.line_report.text = result.summary()
	if not result.accepted:
		show_message("Линия не построена, прежняя трасса сохранена: " + result.reason)
		return false
	if not _apply_line(result, pressed): return false
	editor.line_report.text = result.summary() + "\n" + _line_time()
	show_message("Линия построена: %.0f м · от нажатия до сцены %.0f мс" % [result.stats.length, build_timings.total_ms])
	return true

## Automatic choice of the place (TrailPicker over the same TrailRouter): the panel's requirements, length range and
## minimal descent; no coordinates. A refusal keeps the previous route; the requirements are never relaxed.
func find_trail(values: Dictionary) -> bool:
	var pressed := Time.get_ticks_usec()
	var site := Fixture.site()
	if site == null:
		show_message("Площадка не открыта: " + Fixture.site_error)
		return false
	var request := _line_requirements(values)
	request.merge({length_min = values.route_length_min, min_drop = values.route_drop})
	var picked := TrailPicker.find(site, request)
	pick_result = picked
	line_result = picked.router
	flow_result = null
	editor.line_report.text = picked.summary()
	if not picked.accepted:
		show_message("Трасса не найдена, прежняя трасса сохранена")
		return false
	# Elements on the accepted line: placed by TrailComposer, built on a fresh copy of the site (TrailFlow).
	var d := picked.router.definition
	var ready: Dictionary = picked.router.prepared
	var compose_ms := -1.0
	if int(values.get("route_flow", 0)) == 1:
		flow_result = TrailFlow.dress(site, picked.router, int(values.get("route_seed", 1)))
		d = flow_result.definition
		ready = flow_result.prepared
		compose_ms = flow_result.stats.compose_ms
	if not _apply_line(picked.router, pressed, d, ready, compose_ms): return false
	for pair: Array in [["route_start_x", picked.start.x], ["route_start_z", picked.start.y], ["route_finish_x", picked.finish.x], ["route_finish_z", picked.finish.y]]:
		editor.numbers[pair[0]].set_value_no_signal(pair[1])
	editor.line_report.text = picked.summary() + ("\n" + flow_result.summary() if flow_result != null else "") + "\n" + _line_time()
	var elements := " · элементов %d" % d.elements.size() if flow_result != null else ""
	show_message("Трасса найдена: %.0f м, вниз %.1f м%s · от нажатия до сцены %.0f мс" % [picked.router.stats.length, picked.router.stats.drop, elements, build_timings.total_ms])
	if flow_result != null and not flow_result.accepted: show_message("Элементы не поставлены, оставлена базовая линия: " + flow_result.message)
	return true

func _line_requirements(values: Dictionary) -> Dictionary:
	return {width = values.route_width, grade = values.route_grade / 100.0, min_radius = values.route_radius}

## Replace the scene with the builder's own full build (not prepared again). The stage times of that build stay in
## the builder's time; the total is measured once, from the press to the ready scene.
## `d` / `ready` — the trail with elements and its build (TrailFlow), when it differs from the builder's base line.
func _apply_line(result: TrailRouter, pressed: int, d: TrailDefinition = null, ready := {}, compose_ms := -1.0) -> bool:
	var builder_ms := (Time.get_ticks_usec() - pressed) / 1000.0
	var previous := ground_kind
	ground_kind = "site"
	# The finished surface is judged by the line's own requirement; the panel shows it.
	grade_requirement = result.request.grade
	editor.numbers.required_grade.set_value_no_signal(result.request.grade * 100.0)
	if not rebuild([d if d != null else result.definition] as Array[TrailDefinition], compose_ms, ready if not ready.is_empty() else result.prepared):
		ground_kind = previous
		return false
	_draw_line(result)
	set_overview(true)
	build_timings.builder_ms = builder_ms
	build_timings.total_ms = (Time.get_ticks_usec() - pressed) / 1000.0
	return true

## Time from the press to the ready scene: the builder (search, estimate, full build) plus the scene (mesh, objects,
## survey, apply), each counted once.
func _line_time() -> String:
	if not build_timings.has("builder_ms"): return ""
	return "От нажатия до готовой сцены %.0f мс: построитель %.0f · сцена %.0f (меш %.0f, анализ %.0f, применение %.0f)" % [
		build_timings.total_ms, build_timings.builder_ms, build_timings.total_ms - build_timings.builder_ms,
		build_timings.get("mesh_ms", 0.0), build_timings.get("survey_ms", 0.0), build_timings.get("apply_ms", 0.0)]

## The found line over the finished surface (cyan), its ends and, faint, the straight between them.
func _draw_line(result: TrailRouter) -> void:
	var d := result.definition
	var strip := ImmediateMesh.new()
	strip.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	var station := 0.0
	while station <= d.route_length():
		var p := d.point_at(station)
		var side := Vector2(d.tangent_at(station).y, -d.tangent_at(station).x) * 0.35
		var y := heights.surface_at(p.x, p.y, INF) + 0.35
		strip.surface_add_vertex(Vector3(p.x + side.x, y, p.y + side.y))
		strip.surface_add_vertex(Vector3(p.x - side.x, y, p.y - side.y))
		station += 1.0
	strip.surface_end()
	_add_strip(strip, Color(0.2, 0.9, 1.0))
	var straight := ImmediateMesh.new()
	straight.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	var a: Vector2 = result.request.start
	var b: Vector2 = result.request.finish
	for k in 41:
		var p := a.lerp(b, k / 40.0)
		straight.surface_add_vertex(Vector3(p.x, maxf(heights.ground_at(p.x, p.y), heights.surface_at(p.x, p.y, INF)) + 0.6, p.y))
	straight.surface_end()
	_add_strip(straight, Color(1, 1, 1, 0.6))
	_label("Старт", a, 4.0)
	_label("Финиш", b, 4.0)

func _add_strip(mesh: ImmediateMesh, color: Color) -> void:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = color
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = material
	node.visible = overview
	node.add_to_group("trail_lab_line") # shown only in the overview: from the rider's view it would hide the tread
	markers.add_child(node)

## Terrain material and water of the current ground, rebuilt only when the ground changes. A saved site gets its
## piece of the world texture (when the cache had one), the world offset of the shader detail and road bumps, and
## the game's water meshes; lab grounds keep the plain green texture and no water.
func _apply_look() -> void:
	var site := Fixture.site() if ground_kind == "site" else null
	var key := "site:" + str(heights.world.world_origin) if site != null else "lab"
	if key == _look: return
	_look = key
	var image := site.base_image() if site != null else null
	if image == null:
		image = Image.create(64, 64, false, Image.FORMAT_RGB8)
		image.fill(Color(0.32, 0.42, 0.23))
	var material := services.terrain.material(image)
	material.set_shader_parameter("world_offset", Vector2(heights.world.world_origin) * GameConfig.TILE)
	terrain.material_override = material
	for child in water.get_children(): child.free()
	for child in structures.get_children(): child.free()
	if site != null:
		for node in WaterBuilder.build(heights.world, WaterBuilder.prepare(heights.world, heights)): water.add_child(node)
		# The site's own bridges and tunnels: the first entries of the list, before the decks of lab elements.
		# Built once per site: their levels are saved and their approaches are pinned against trail earthworks.
		StructuresBuilder.build(structures, heights, heights.structures.slice(0, site.structures.size()))

## Overview camera target: the middle of the lab's square (256 m, the main polygon 512 m), or of a saved site's working rectangle.
func _overview_target() -> Vector3:
	if ground_kind != "site" or Fixture.site() == null:
		var half := heights.world.W * GameConfig.TILE * 0.5
		return Vector3(half, heights.ground_at(half, half), half)
	var c := Vector2(Fixture.site().work.get_center()) * GameConfig.TILE
	return Vector3(c.x, heights.ground_at(c.x, c.y), c.y)

## Re-judge the current surface by a new requirement; the terrain is not rebuilt.
func set_grade_requirement(grade: float) -> void:
	grade_requirement = maxf(0.0, grade)
	if heights == null: return
	for d in routes: surveys[d.id] = TrailSurvey.measure(heights, d, grade_requirement)
	_mark_survey()

func _mark_survey() -> void:
	for child in survey_markers.get_children(): child.free()
	for d in routes:
		var survey: TrailSurvey = surveys.get(d.id)
		if survey == null: continue
		for run: Dictionary in survey.exceeded:
			_survey_label(d, run, "Уклон 4 м %+.0f%% · %.0f–%.0f м%s" % [run.peak * 100.0, run.from, run.to, " · элемент" if not (run.elements as Array).is_empty() else ""], Color(1.0, 0.35, 0.3))
		for run: Dictionary in survey.unmeasured:
			_survey_label(d, run, "Не измерено: %s · %.0f–%.0f м" % [run.reason, run.from, run.to], Color(1.0, 0.7, 0.25))

## A coloured strip over the interval (readable from the overview) and a caption above its middle.
func _survey_label(d: TrailDefinition, run: Dictionary, text: String, color: Color) -> void:
	var strip := ImmediateMesh.new()
	strip.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	var station: float = run.from - 1.0
	# An interval through the seam of a circuit (from > to) continues past the route length; point_at wraps it.
	var to: float = run.to + (d.route_length() if run.from > run.to else 0.0)
	while station <= to + 1.0:
		var p := d.point_at(station)
		var side := Vector2(d.tangent_at(station).y, -d.tangent_at(station).x) * (d.width * 0.5 + 0.4)
		var y := heights.surface_at(p.x, p.y, INF) + 0.3
		strip.surface_add_vertex(Vector3(p.x + side.x, y, p.y + side.y))
		strip.surface_add_vertex(Vector3(p.x - side.x, y, p.y - side.y))
		station += 1.0
	strip.surface_end()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = color
	var band := MeshInstance3D.new()
	band.mesh = strip
	band.material_override = material
	survey_markers.add_child(band)
	var at := d.point_at((run.from + to) * 0.5)
	var label := Label3D.new()
	label.text = text
	label.modulate = color
	label.outline_size = 8
	label.font_size = 40
	label.pixel_size = 0.03
	label.no_depth_test = true
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = Vector3(at.x, heights.surface_at(at.x, at.y, INF) + 4.0, at.y)
	survey_markers.add_child(label)

## Stage times of the last build: "—" for a stage that did not run.
func _build_report() -> String:
	if build_timings.is_empty(): return "Сборка: нет данных"
	var t := build_timings
	var ms := func(key: String) -> String: return "—" if t.get(key, -1.0) < 0.0 else "%.0f" % t[key]
	return "Сборка %s мс: площадка %s · композиция %s · полотно и сетка %s\nземляные элементы %s · объекты и настилы %s · анализ %s · меш %s · сцена %s\nпроезд %s · ограничения %s" % [
		ms.call("total_ms"), ms.call("setup_ms"), ms.call("compose_ms"), ms.call("surface_ms"),
		ms.call("earthworks_ms"), ms.call("technical_ms"), ms.call("survey_ms"), ms.call("mesh_ms"), ms.call("apply_ms"), ms.call("validation_ms"), ms.call("constraints_ms")]

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
	if not rebuild(candidate, -1, {}, _active_input()): return false
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
	return rebuild(candidate, -1, {}, _active_input())

func _active_input():
	if active_project == null: return null
	var input = active_project.source.duplicate(true)
	input.apply_cuts(active_project.cuts)
	return input

func reset_ride(station := 0.0, speed := 0.0) -> void:
	if heights == null: return
	crash.abort()
	controller = BikeController.new()
	controller.message.connect(show_message)
	player = PlayerState.new()
	bike = BikeRide.new()
	if trial != null: contact_model = bike.contact_model
	bike.contact_model = contact_model
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
	if trial != null:
		if station == 0.0 and speed == 0.0:
			trial.retry()
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			player.x = trial.spawn.position.x; player.z = trial.spawn.position.y; player.feet = trial.spawn.height
			bike.x = player.x; bike.z = player.z; bike.y = player.feet; bike.heading = trial.spawn.heading
		else: trial.fail("Тренировочный запуск вне старта")
	last_land_impact = 0.0
	last_bottom_out = 0.0
	if vegetation != null: vegetation.update(player.x, player.z, true)
	heights.obstacles.update(player.x, player.z, _forest_obstacles(), _forest_version(), true)
	if autopilot != null: autopilot.reset(d, heights, station)
	view.snap(bike)
	brake_effects.clear()
	metrics.reset(bike)
	recorder.begin(self, "R/смена трассы: станция %.0f, скорость %.1f м/с" % [station, speed])
	_cam_to = Vector4(player.x, player.feet, player.z, bike.heading)
	_cam_from = _cam_to
	_cam_feet = player.feet
	_cam_yaw = bike.heading
	_cam_pitch = -0.464
	services.controls.reset()
	if trial != null:
		if autopilot != null: trial.assisted = true
		trial_hud.present(trial)
		_sync_mouse()

func launch_element() -> void:
	if heights == null: return
	var station := 0.0
	if not routes[lane].elements.is_empty():
		var e := routes[lane].elements[element_index]
		station = maxf(0.0, e.station - e.length * 0.5 - 12.0)
	reset_ride(station, editor.numbers.speed.value / 3.6)
	set_overview(false)
	set_editor_visible(false)
	get_viewport().gui_release_focus()
	show_message("Заезд с %.0f км/ч · R — старт трассы" % editor.numbers.speed.value)

func show_message(text: String) -> void:
	status.text = text
	status.visible = true
	status_time = 4.0

func set_overview(enabled: bool) -> void:
	overview = enabled
	_sync_mouse()
	markers.visible = overview or diagnostics_visible
	survey_markers.visible = overview or diagnostics_visible
	editor.set_camera_overview(enabled)
	for node in markers.get_children():
		if node.is_in_group("trail_lab_line"): node.visible = enabled
	camera_control.text = "V  Сверху" if enabled else "V  Камера"
	camera_control.tooltip_text = "Сейчас: обзор сверху. Переключить на вид за велосипедистом" if enabled else "Сейчас: вид за велосипедистом. Переключить на обзор сверху"

func set_editor_visible(enabled: bool) -> void:
	editor.visible = enabled
	_sync_mouse()
	get_viewport().gui_release_focus()

func set_diagnostics_visible(enabled: bool) -> void:
	diagnostics_visible = enabled
	diagnostics_scroll.visible = enabled
	diagnostics.visible = enabled
	markers.visible = overview or diagnostics_visible
	survey_markers.visible = overview or diagnostics_visible
	details_control.text = "F3  Скрыть" if enabled else "F3  Инфо"
	hud_panel.reset_size()
	get_viewport().gui_release_focus()

## Release ragdoll bodies before the owning menu removes the scene.
func shutdown() -> void:
	_world_request += 1
	# фоновая генерация мира: дождаться (поток пишет только свои поля и скоро закончит)
	if _world_thread != null:
		_world_job.cancel()
		_world_thread.wait_to_finish()
		_world_thread = null
	_world_job = null
	project_panel.hide()
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
	if key == KEY_F10:
		open_game_example()
		get_viewport().set_input_as_handled()
		return
	if key == KEY_F2:
		set_editor_visible(not editor.visible)
	if key == KEY_F5: reload_sources()
	if key == KEY_F6:
		if trial != null: trial.fail("Модель управления изменена во время заезда")
		contact_model = not contact_model
		bike.contact_model = contact_model
		show_message("Модель контактов колёс: " + ("два контакта" if contact_model else "прежняя"))
	if key == KEY_F3:
		set_diagnostics_visible(not diagnostics_visible)
		get_viewport().set_input_as_handled()
		return
	if (key == KEY_BRACKETLEFT or key == KEY_BRACKETRIGHT) and Sites.active():
		select_site(Sites.current + (1 if key == KEY_BRACKETRIGHT else -1))
		get_viewport().set_input_as_handled()
		return
	if key == KEY_F7 or key == KEY_F8:
		generate_random(key == KEY_F7)
		get_viewport().set_input_as_handled()
		return
	if key == KEY_F9:
		save_ride_log()
		get_viewport().set_input_as_handled()
		return
	if key == KEY_V:
		set_overview(not overview)
		get_viewport().set_input_as_handled()
		return
	if heights == null or editor.visible: return
	if key >= KEY_1 and key < KEY_1 + mini(routes.size(), 9): select_route(key - KEY_1)
	if key == KEY_R: reset_ride()
	if key == KEY_PAGEUP: select_preset(preset - 1)
	if key == KEY_PAGEDOWN: select_preset(preset + 1)
	if key == KEY_G: launch_element()
	if key == KEY_P: _cycle_autopilot()

## F3: участок впереди с ожиданиями (точка и скорость входа, кромка, приземление, радиус) и итог прошлого — из записи
func _live_analysis() -> String:
	if not recorder.enabled or bike == null: return ""
	var near := routes[lane].nearest_along(Vector2(bike.x, bike.z), recorder._previous_station, 20.0)
	var text: String = recorder.analysis.live(near.x if is_finite(near.z) else -1.0, bike.horizontal_velocity().length())
	return "" if text.is_empty() else "\n" + text

## Сохранить запись сессии тестов в ride_logs/<дата>/ (кнопка и F9)
func save_ride_log() -> void:
	var saved: String = recorder.save(self)
	if saved.is_empty():
		show_message("Нечего сохранять: запись начинается с первого нажатия или движения" if recorder.enabled else "Запись выключена")
		return
	show_message("Запись сохранена: %s" % saved.trim_prefix("res://"))

## Колёса по отдельности: нагрузка (доли веса) и использованный запас сцепления
func _contact_report() -> String:
	if not bike.contact_model:
		return "Контакты: прежняя модель (F6)"
	return "Перед: нагрузка %.2f (шина %.2f) · сцепление %.0f%%%s  ·  зад: %.2f (%.2f) · %.0f%%%s  (F6)" % [bike.load_f, bike.tire_f, bike.use_f * 100,
		"" if bike.contact_f() else " · НЕТ КОНТАКТА", bike.load_r, bike.tire_r, bike.use_r * 100, "" if bike.contact_r() else " · НЕТ КОНТАКТА"]

func _sync_mouse() -> void:
	# 30.10: движение мыши вращает камеру; зажатый Alt (и панель F2, вид сверху) отпускает курсор для интерфейса,
	# камера при этом стоит. Проверяется каждый кадр (_process).
	var trial_menu: bool = trial != null and trial.phase in [Trial.Phase.READY, Trial.Phase.FINISHED, Trial.Phase.FAILED]
	var free: bool = overview or editor.visible or Input.is_key_pressed(KEY_ALT) or trial_menu
	var want := Input.MOUSE_MODE_VISIBLE if free else Input.MOUSE_MODE_CAPTURED
	if Input.mouse_mode != want: Input.mouse_mode = want

func _exit_tree() -> void:
	recorder.close() # несохранённое остаётся только во временной папке user://ride_log_unsaved
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _input(event: InputEvent) -> void:
	services.controls.note(event)
	recorder.note_input(event)
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and not overview and not editor.visible:
		_orbit_camera(event.relative)

func _orbit_camera(delta: Vector2) -> void:
	var k := GameConfig.MOUSE * services.settings.mouse
	_cam_yaw -= delta.x * k
	_cam_pitch = clampf(_cam_pitch - delta.y * k * (-1.0 if services.settings.invert_y else 1.0), -1.2, 0.35)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause") or event.is_action_pressed("ui_cancel"):
		if editor.visible:
			set_editor_visible(false)
			get_viewport().gui_release_focus()
		else:
			_request_exit()
		get_viewport().set_input_as_handled()
		return
	if heights != null and not editor.visible and event.is_action_pressed("interact") and not crash.active():
		controller.toggle_mount(player, bike, heights.world, heights)
		view.snap(bike)

## P: выкл → осторожно → flow → на пределе → выкл. Автопилот подхватывает с текущего места трассы.
func _cycle_autopilot() -> void:
	var next := 0 if autopilot == null else Autopilot.ORDER.find(autopilot.style) + 1
	if next >= Autopilot.ORDER.size():
		autopilot = null
		show_message("Автопилот выключен · P — снова")
		return
	if autopilot == null:
		autopilot = Autopilot.new()
		var near := routes[lane].nearest(Vector2(bike.x, bike.z))
		autopilot.reset(routes[lane], heights, near.x if is_finite(near.z) else 0.0)
	autopilot.style = Autopilot.ORDER[next]
	if not bike.riding and not crash.active(): controller.toggle_mount(player, bike, heights.world, heights)
	show_message("Автопилот: %s · P — следующая манера, R — со старта" % autopilot.title())

func _forest_obstacles() -> PackedFloat32Array:
	return vegetation.obstacles if vegetation != null else PackedFloat32Array()

func _forest_version() -> int:
	return vegetation.obstacles_version if vegetation != null else 1

func _physics_process(dt: float) -> void:
	if heights == null: return
	var input_allowed := not editor.visible and not overview
	var throttle := services.controls.bike_brake(Input.get_axis("move_back", "move_forward") if input_allowed else 0.0, dt)
	var turn := services.controls.bike_steer(Input.get_axis("move_left", "move_right") if input_allowed else 0.0, dt, bike.speed if bike != null else 0.0)
	var jump := input_allowed and Input.is_action_just_pressed("jump")
	var run := input_allowed and Input.is_action_pressed("run")
	if autopilot != null and bike.riding and not crash.active():
		var input: Dictionary = autopilot.drive(bike, routes[lane])
		throttle = input.throttle
		turn = input.turn
		run = input.run
		jump = input.jump
	step_simulation(dt, throttle, turn, run, jump)

## Same controller/foot lifecycle as GameWorld; callable by the isolated scene regression.
func step_simulation(dt: float, throttle: float, turn: float, run: bool, jump: bool) -> void:
	if trial != null:
		if editor.visible or overview: return
		if autopilot != null: trial.assisted = true
		if trial.phase == Trial.Phase.READY:
			if throttle > 0.1: trial.begin()
			else: trial_hud.present(trial); return
		if trial.phase in [Trial.Phase.FINISHED, Trial.Phase.FAILED]: trial_hud.present(trial); return
	var w := heights.world
	_cam_from = _cam_to
	heights.obstacles.update(player.x, player.z, _forest_obstacles(), _forest_version())
	if crash.active():
		controller.recover(dt, player, bike, crash, w, heights)
	elif bike.riding:
		# Q — тело назад (рывок разгружает переднее колесо), E — вперёд (заднее); отпустить — нейтраль
		services.controls.read_bike_body(bike, not editor.visible and not overview)
		if body_back_forced:
			bike.body_back = body_back
			bike.body_forward = false
		throttle = controller.ride(dt, player, bike, w, heights, throttle, turn, run, jump, false)
		if bike.crashed:
			metrics.crash(bike)
			view.tick(bike, dt, throttle)
			view.draw(1.0)
			controller.begin_crash(view, bike, crash, heights)
	else:
		var moving := player.step(throttle, turn, run, jump, bike.heading, dt, w, heights)
		controller.stamina.tick_foot(dt, run and moving)
		player.land_impact = 0.0
	if not crash.active():
		view.tick(bike, dt, throttle, bike.riding and controller.stamina.can_boost(run, throttle))
		brake_effects.tick(dt, bike, w, heights)
	_cam_to = Vector4(player.x, player.feet, player.z, bike.heading)
	if bike.riding and not crash.active(): metrics.tick(dt, bike, routes[lane])
	if trial != null:
		trial.tick(dt, Vector2(bike.x, bike.z), bike.crashed or crash.active(), bike.riding)
		trial_hud.present(trial)
		if trial.phase in [Trial.Phase.FINISHED, Trial.Phase.FAILED]: Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	recorder.tick(self, dt, throttle, turn, run, jump)
	bike.landing_info = {}
	if bike.land_impact > 0.0: last_land_impact = bike.land_impact
	if bike.bottom_out > 0.0: last_bottom_out = bike.bottom_out
	# These are one-tick events. Leaving them latched repeats the rider's landing animation.
	bike.land_impact = 0.0
	bike.wheel_impact = Vector2()
	bike.bottom_out = 0.0

func _shaping_report() -> String:
	var stats: Dictionary = heights.road_refinement.trail_shaping.get(routes[lane].id, {})
	if stats.is_empty(): return "Рельеф: без земляных работ"
	return "Рельеф: выемка %.0f м³ (до %.2f м) · насыпь %.0f м³ (до %.2f м) · зона %.1f м от оси
Проект полотна без элементов: уклон %.0f%% → %.0f%% · вираж до %.0f%%" % [stats.get("cut_m3", 0.0), stats.get("max_cut", 0.0), stats.get("fill_m3", 0.0), stats.get("max_fill", 0.0), stats.get("reach", 0.0), stats.grade_natural * 100.0, stats.grade_designed * 100.0, stats.bank_peak * 100.0]

func _line_report() -> String:
	if line_result == null or routes[lane].id != "site_route": return ""
	if pick_result != null: return "\nАвтовыбор трассы:\n" + pick_result.summary() + ("\n" + flow_result.summary() if flow_result != null else "") + "\n" + _line_time()
	return "\nПостроитель линии:\n" + line_result.summary() + "\n" + _line_time()

func _survey_report() -> String:
	var survey: TrailSurvey = surveys.get(routes[lane].id)
	return survey.summary() if survey != null else "Поверхность: не измерена"

func _process(dt: float) -> void:
	_poll_world()
	if heights == null: return
	_sync_mouse()
	if not overview and not editor.visible:
		_orbit_camera(services.controls.look_delta(dt))
	if status_time > 0.0:
		status_time -= dt
		if status_time <= 0.0: status.hide()
	if vegetation != null: vegetation.update(player.x, player.z, false)
	var alpha := Engine.get_physics_interpolation_fraction()
	if crash.active(): crash.draw()
	else: view.draw(alpha)
	# Same interpolation as the bike model: the camera must not step at the physics rate.
	var at := _cam_from.lerp(_cam_to, alpha)
	# Terrain bumps move the feet by whole centimetres per tick; follow them softly.
	_cam_feet = lerpf(_cam_feet, at.y, Util.damp(10.0, dt)) if absf(at.y - _cam_feet) < 3.0 else at.y
	var target := Vector3(at.x, _cam_feet + 1.0, at.z)
	if overview:
		var focus := _overview_target()
		# farther above a larger square (the main polygon) so the whole course is in view
		camera.position = focus + Vector3(0, 228, 117) * maxf(1.0, heights.world.W / 64.0 * 1.05)
		camera.look_at(focus)
		if _cam_fov >= 0.0: camera.fov = _cam_fov
	else:
		var riding := bike.riding and not crash.active()
		_cam_surge = lerpf(_cam_surge, clampf(bike.feel_acceleration, -9.0, 5.0) if riding else 0.0, Util.damp(5.0, dt))
		_cam_brake = lerpf(_cam_brake, bike.brake_deceleration if riding else 0.0, Util.damp(6.0, dt))
		var brake := clampf(_cam_brake / 7.0, 0.0, 1.0)
		var push := clampf(_cam_surge / 4.0, 0.0, 1.0)
		var back := 7.0 - 1.6 * brake + 0.8 * push
		var direction := Vector3(-sin(_cam_yaw) * cos(_cam_pitch), sin(_cam_pitch), -cos(_cam_yaw) * cos(_cam_pitch))
		var cam := target - direction * back / cos(0.464)
		cam.y = maxf(cam.y, heights.surface_at(cam.x, cam.z, cam.y) + 0.4)
		camera.position = cam
		camera.look_at(target)
		if _cam_fov < 0.0: _cam_fov = camera.fov
		camera.fov = _cam_fov - 6.0 * brake + 3.0 * push
	var contact := RideSurface.sample(heights.world, heights, bike.x, bike.z)
	var name := "вне трассы" if contact.surface == 0 else str(RoadSurface.LIST[contact.surface].name)
	telemetry.text = "TRAIL LAB  /  " + routes[lane].title
	route_hint.text = "Space прыжок  ·  ЛКМ памп  ·  Q→E хоп  ·  Alt курсор"
	if bike.contact_model:
		route_hint.tooltip_text = "Потяните Q, затем через 0,1–0,3 с нажмите E. Точная подготовка даёт более высокий прыжок."
	else:
		route_hint.tooltip_text = ""
	speed_label.text = "%.0f км/ч  " % (absf(bike.speed) * 3.6)
	surface_label.text = name + ("  ·  ПАДЕНИЕ" if crash.active() else ("  ·  ПОЛЁТ" if bike.airborne else ""))
	stamina_label.text = "Выносливость  %.0f%%" % (controller.stamina.value * 100)
	stamina_bar.value = controller.stamina.value * 100
	save_control.disabled = not recorder.has_data()
	save_control.text = ("F9  Сохранить запись (%.0f с)" % recorder.seconds()) if recorder.has_data() else "F9  Сохранить запись"
	save_control.tooltip_text = "Записывает всю сессию (все поездки с R): ввод, положение, данные F3, события. В проект сохраняется только по нажатию"
	if diagnostics_visible:
		diagnostics.text = "R старт  ·  G заезд  ·  P автопилот  ·  %s посадка/сход\nW/S педали и тормоз (стоя: отпустить и держать S — назад)  ·  A/D руль\nSpace прыжок  ·  Shift усилие  ·  Q тело назад  ·  E вперёд\nF5 перечитать  ·  Esc назад\nПокрытие %.0f%%  ·  уклон %.1f%%\nСнос %.1f°  ·  сцепление %.0f%%\nПодвеска %.3f / %.3f м\n%s  ·  удар %.1f м/с
%s
%s" % [services.controls.label("interact"), contact.weight * 100, bike.grade(heights) * 100, rad_to_deg(bike.slip), bike.grip_usage * 100, bike.squash_f, bike.squash_r, "ПАДЕНИЕ" if crash.active() else ("ПОЛЁТ" if bike.airborne else "ЗЕМЛЯ"), last_land_impact, _contact_report(), metrics.report(routes[lane]) + _live_analysis() + "
" + _shaping_report() + "
" + _survey_report() + "
" + _build_report() + _line_report()]
	status.position.y = hud_panel.position.y + hud_panel.size.y + 10
