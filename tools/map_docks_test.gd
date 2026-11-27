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
	panel._map_info_toggle.button_pressed = true
	check(panel._right_dock.visible, "легенда открывается по кнопке")
	panel._map_info_toggle.button_pressed = false
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
	narrow.queue_free()
	panel.queue_free()
	await process_frame
	quit(1 if failures else 0)
