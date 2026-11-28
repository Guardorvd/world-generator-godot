extends SceneTree
## Карта остаётся просторной, а ориентир и сведения о задании открываются по необходимости.
var failures := 0

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 30)
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	print("PASS " if condition else "FAIL ", message)
	if not condition:
		failures += 1

func _run() -> void:
	var state := {quest = {}}
	var panel = preload("res://scripts/ui/journal_panel.gd").new()
	panel.quest_provider = func() -> Dictionary: return state.quest
	root.add_child(panel)
	panel.open_tab(panel.Tab.MAP, "test")
	await process_frame
	check(not panel._dock.visible and not panel._right_dock.visible, "пустые панели не занимают карту")
	check(not panel._track_layer.visible and not panel._photo_layer.visible, "слои свёрнуты по умолчанию")
	panel._map_info_toggle.button_pressed = true
	check(panel._right_dock.visible and not panel._track_layer.visible, "легенда не открывает слои")
	panel._map_info_toggle.button_pressed = false
	panel._map_layers_toggle.button_pressed = true
	check(not panel._right_dock.visible and panel._track_layer.visible and panel._photo_layer.visible, "слои открываются независимо от легенды")
	panel._map_layers_toggle.button_pressed = false
	panel.refresh_inspector({name = "Ольховка", key = "settlement:1", x = 1, y = 1})
	check(panel._dock.visible and panel._place_title.text == "Ольховка", "выбранное место открывает сведения")
	state.quest = {title = "Маршрут", steps = [], index = 0}
	panel.refresh_quest()
	check(panel._right_dock.visible and panel._map_info_toggle.button_pressed, "новое задание открывает сведения")
	panel._map_info_toggle.button_pressed = false
	panel.refresh_quest()
	check(not panel._right_dock.visible, "игрок может снова свернуть сведения")
	var narrow := SubViewport.new()
	narrow.size = Vector2i(400, 720)
	root.add_child(narrow)
	var compact = preload("res://scripts/ui/journal_panel.gd").new()
	narrow.add_child(compact)
	compact.open_tab(compact.Tab.MAP, "test")
	await process_frame
	await process_frame
	var controls_fit := true
	for child: Node in compact._map_footer.get_children():
		if child is Button and child.visible:
			controls_fit = controls_fit and child.get_global_rect().end.x <= 400.0 and child.get_global_rect().end.y <= 720.0
	check(controls_fit, "кнопки карты доступны в узком окне")
	var atlas = preload("res://scripts/ui/world_map_view.gd").new()
	root.add_child(atlas)
	atlas.size = Vector2(800, 600)
	await process_frame
	atlas.field_sheet = true
	atlas._bounds = Rect2(0, 0, 4000, 4000)
	atlas._center = atlas._bounds.get_center()
	atlas._scale = 1.0
	atlas._min_scale = 0.01
	var cursor := Vector2(600, 200)
	var anchor: Vector2 = atlas.screen_to_world(cursor)
	atlas._zoom_at(cursor, 1.2)
	check(anchor.distance_to(atlas.screen_to_world(cursor)) < 0.01, "масштаб удерживает точку под курсором, когда движение не ограничено")
	atlas._scale = 0.1
	atlas._center = atlas._bounds.get_center()
	atlas._zoom_at(cursor, 1.2)
	check(atlas._center.is_equal_approx(atlas._bounds.get_center()), "небольшой лист остаётся по центру у границ")
	atlas.queue_free()
	narrow.queue_free()
	panel.queue_free()
	await process_frame
	quit(1 if failures else 0)
