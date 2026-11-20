extends SceneTree
## Изолированная проверка витрины без генерации мира; снимки — в .godot/shop_ui_test.

const Shop := preload("res://scripts/ui/shop_panel.gd")
const Journal := preload("res://scripts/ui/journal_panel.gd")
var failures := 0


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 30)
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	print(("OK " if ok else "FAIL ") + message)
	if not ok:
		failures += 1


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://.godot/shop_ui_test"))
	root.size = Vector2i(1280, 720)
	var profile := Shop.Progress.new()
	var panel := Shop.new()
	panel.show_back = true
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.set_profile(profile)
	root.add_child(panel)
	panel.open()
	await process_frame
	await process_frame
	_check(panel._rows.ember.has_focus() and panel._preview.texture != null, "начальный комплект и фокус")
	panel._rows.moss.grab_focus()
	_check(panel._action.disabled and panel._price_caption.text.contains("Не хватает 50") and panel._price_bar.value == 0.0, "недостаток очков виден рядом с товаром")
	panel._toggle_goal()
	profile.award("test", ["start:home"])
	_check(profile.purchase_goal == "moss" and panel._goal_status.text.contains("Осталось 30") and is_equal_approx(panel._price_bar.value, 0.4), "цель и прогресс после награды")
	await _capture("goal")
	profile.award("test", ["supplies:home>farm"])
	_check(not panel._action.disabled and panel._price_caption.text.contains("Доступно для покупки"), "товар доступен после накопления")
	panel._activate()
	_check(panel._review_actions.visible and panel._cancel_buy.has_focus() and profile.balance == 50, "подтверждение не списывает очки")
	await process_frame
	await _capture("confirm")
	_check(panel.dismiss_purchase() and profile.balance == 50, "отмена сохраняет баланс")
	panel._activate()
	panel._buy_reviewed()
	_check(profile.owns("moss") and profile.balance == 0 and profile.equipped == "ember" and panel._note.text.contains("Надеть"), "покупка отдельно от экипировки")
	panel._activate()
	_check(profile.equipped == "moss" and panel._status.text == "НАДЕТО", "экипировка обновляет состояние")
	panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	panel.size = Vector2(600, 650)
	await process_frame
	await process_frame
	_check(panel._layout.vertical and panel._row_grid.columns == 2, "узкий экран размещает коллекцию компактной сеткой")
	await _capture("narrow")
	panel.queue_free()
	await process_frame
	var journal := Journal.new()
	root.add_child(journal)
	journal.enable_shop(profile)
	journal.open_tab(Journal.Tab.SHOP, "Тест")
	await process_frame
	var tablet_shop: Shop = journal.shop_panel
	_check(tablet_shop.is_visible_in_tree() and tablet_shop._rows.moss.has_focus() and tablet_shop._status.text == "НАДЕТО", "планшет открывает общую коллекцию и экипировку")
	profile.award("test", ["repair:home>farm", "fragile:home>farm"])
	tablet_shop._rows.glacier.grab_focus()
	await process_frame
	var right := InputEventAction.new()
	right.action = &"ui_right"
	right.pressed = true
	root.push_input(right)
	_check(tablet_shop._action.has_focus(), "навигация вправо ведёт от товара к действию")
	await _capture("tablet")
	tablet_shop._activate()
	_check(tablet_shop._review_actions.visible and journal.dismiss_subpanel() and profile.balance == 70, "отмена покупки в планшете не закрывает вкладку")
	tablet_shop._activate()
	journal._select(Journal.Tab.MAP)
	journal._select(Journal.Tab.SHOP)
	_check(not tablet_shop._review_actions.visible and profile.balance == 70, "смена вкладки отменяет подтверждение")
	profile.load_error = ERR_FILE_CORRUPT
	tablet_shop._refresh()
	_check(tablet_shop._action.disabled and not tablet_shop._price_card.visible and tablet_shop._status.text == "НЕТ ДАННЫХ", "ошибка загрузки блокирует покупку и скрывает недостоверный прогресс")
	journal.queue_free()
	await process_frame
	print("shop_ui_test failures: ", failures)
	quit(1 if failures else 0)


func _capture(name: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://.godot/shop_ui_test/" + name + ".png")
