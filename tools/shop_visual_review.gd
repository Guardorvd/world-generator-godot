extends SceneTree
## Изолированный визуальный осмотр витрины в меню и дневнике, без генерации мира.
const Shop := preload("res://scripts/ui/shop_panel.gd")
const Journal := preload("res://scripts/ui/journal_panel.gd")
const OUTPUT := "res://.godot/shop_visual_review"
var failures := 0

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 30)
	_run.call_deferred()

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	root.size = Vector2i(1280, 720)
	var profile := Shop.Progress.new()
	profile.award("visual", ["start:home", "supplies:home>farm", "repair:home>farm"])
	var panel := Shop.new()
	panel.show_back = true
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.set_profile(profile)
	root.add_child(panel)
	panel.open()
	await process_frame
	await process_frame
	for id: String in Shop.Progress.PRICES:
		if Shop.Progress.category_for(id) != Shop.Progress.category_for(panel._selection):
			panel._select_category(Shop.Progress.category_for(id))
		panel._select(id)
		while not panel._full_portraits.has(id) and panel.is_processing():
			await process_frame
		_check(panel._preview.texture != null and panel._portraits[id][0] != null and panel._portraits[id][1] != null, "оба ракурса и выбор: " + id)
	panel._select_category(Shop.Progress.Category.SCHEME)
	panel._rows.moss.grab_focus()
	profile.set_purchase_goal("night")
	panel._compare_button.button_pressed = true
	await _shot("comparison")
	panel._activate()
	await _shot("review")
	_check(panel._review_title.text.contains("Мох") and panel._review_balance.text.contains("80 очков") and panel._review_balance.text.contains("30 очков") and panel._note.text.contains("Ночь") and panel._note.text.contains("20 очков"), "подтверждение, баланс и влияние на цель")
	profile.buy("moss")
	_check(panel._confirm_buy.disabled and panel._review_balance.text.contains("30 очков"), "изменение данных блокирует старое подтверждение")
	await _shot("changed")
	panel.dismiss_purchase()
	panel._rows.glacier.grab_focus()
	panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	panel.size = Vector2(400, 650)
	await process_frame
	await process_frame
	panel._compare_button.grab_focus()
	panel._compare_button.button_pressed = true
	await process_frame
	await process_frame
	_check(panel.size.x == 400.0 and panel._heading_title.text == "Магазин" and panel._back.get_global_rect().end.x <= panel.get_global_rect().end.x and panel._compare_labels[1].text.contains("\n"), "компактный экран и подписи")
	await _shot("compact", Vector2i(400, 650))
	panel._view_buttons[0].grab_focus()
	_press("ui_right")
	var second_focused := panel._view_buttons[1].has_focus()
	_press("ui_right")
	var compare_focused := panel._compare_button.has_focus()
	_press("ui_down")
	_check(second_focused and compare_focused and panel._rows.glacier.has_focus(), "управление ракурсом и сравнением стрелками")
	panel._goal_action.grab_focus()
	await process_frame
	await process_frame
	_check(panel._scroll.scroll_vertical > 0 and panel._goal_action.has_focus() and panel._goal_action.get_global_rect().end.y <= panel._scroll.get_global_rect().end.y, "прокрутка к действию и фокус")
	await _shot("compact_action", Vector2i(400, 650))
	panel._fitting_button.button_pressed = true
	await process_frame
	await process_frame
	_check(panel._scroll.scroll_vertical == 0 and panel._scroll.get_global_rect().encloses(panel._stage.get_global_rect()), "примерочная на узком экране открывает модель целиком")
	_check(panel._fitting.get_global_rect().position.y >= panel._stage_controls.get_global_rect().end.y, "кнопки ракурса не перекрывают модель")
	await _shot("compact_fitting", Vector2i(400, 650))
	panel.queue_free()
	await process_frame
	var journal := Journal.new()
	root.add_child(journal)
	journal.enable_shop(profile)
	journal.open_tab(Journal.Tab.SHOP, "Витрина")
	await process_frame
	await process_frame
	journal.shop_panel._rows.night.grab_focus()
	await _shot("journal")
	_check(journal.shop_panel._selection == "night" and journal.shop_panel.is_visible_in_tree(), "витрина в дневнике")
	profile.load_error = ERR_FILE_CORRUPT
	journal.shop_panel._refresh()
	_check(journal.shop_panel._balance.text == "—" and journal.shop_panel._action.disabled and not journal.shop_panel._goal_action.visible and journal.shop_panel._card_status.night.text == "Нет данных", "ошибка загрузки скрывает недостоверные данные")
	await _shot("unavailable")
	journal.queue_free()
	await process_frame
	print("shop_visual_review failures: ", failures)
	quit(1 if failures else 0)

func _check(ok: bool, description: String) -> void:
	print(("OK " if ok else "FAIL ") + description)
	if not ok:
		failures += 1

func _press(action: StringName) -> void:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = true
	root.push_input(event)
	event = event.duplicate()
	event.pressed = false
	root.push_input(event)

func _shot(name: String, extent := Vector2i.ZERO) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	var picture := root.get_texture().get_image()
	if extent != Vector2i.ZERO:
		picture = picture.get_region(Rect2i(Vector2i.ZERO, extent))
	var err := picture.save_png(OUTPUT.path_join(name + ".png"))
	_check(err == OK, "снимок " + name)
