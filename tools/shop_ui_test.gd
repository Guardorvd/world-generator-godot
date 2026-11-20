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
	for id: String in Shop.Progress.PRICES:
		_check(panel._portraits.has(id) and panel._portraits[id][0] != null and panel._portraits[id][1] != null and panel._card_images[id].texture != null, "оба ракурса и карточка доступны: " + id)
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.position = panel._card_images.moss.get_global_rect().get_center()
	click.pressed = true
	root.push_input(click)
	click = click.duplicate()
	click.pressed = false
	root.push_input(click)
	_check(panel._selection == "moss", "карточка выбирается щелчком по изображению")
	panel._rows.moss.grab_focus()
	_press_action("ui_up")
	_check(panel._compare_button.has_focus(), "стрелка вверх ведёт к сравнению")
	_press_action("ui_accept")
	_check(panel._compare_mode, "сравнение включается с клавиатуры")
	_press_action("ui_accept")
	_check(not panel._compare_mode, "повторное подтверждение закрывает сравнение")
	_press_action("ui_down")
	_check(panel._rows.moss.has_focus(), "стрелка вниз возвращает к выбранной карточке")
	_check(panel._card_images.moss.texture is AtlasTexture and panel._card_status.ember.text == "Надето", "карточки показывают модель и статус")
	panel._compare_button.button_pressed = true
	_check(panel._compare_mode and panel._compare_root.visible and not panel._preview.visible and panel._compare_labels[0].text.contains("Закат") and panel._compare_labels[1].text.contains("Мох"), "сравнение подписывает надетый и выбранный комплекты")
	await _capture("compare")
	var compared_side := panel._compare_images[0].texture as AtlasTexture
	panel._view_buttons[1].emit_signal("pressed")
	var compared_angle := panel._compare_images[0].texture as AtlasTexture
	_check(compared_angle.atlas != compared_side.atlas, "ракурс меняется у обоих комплектов в сравнении")
	panel._view_buttons[0].emit_signal("pressed")
	_check(panel.dismiss_purchase() and not panel._compare_mode and panel._compare_button.has_focus(), "Esc закрывает сравнение и возвращает фокус")
	panel._compare_button.button_pressed = true
	panel._rows.glacier.grab_focus()
	_check(panel._compare_mode and panel._compare_labels[1].text.contains("Ледник"), "сравнение обновляется при выборе другого комплекта")
	panel._rows.ember.grab_focus()
	_check(not panel._compare_mode and not panel._compare_button.visible and panel._preview.visible, "сравнение закрывается при выборе надетого комплекта")
	panel._rows.moss.grab_focus()
	var side := panel._preview.texture
	panel._view_buttons[1].emit_signal("pressed")
	_check(panel._view_index == 1 and panel._view_buttons[1].button_pressed and panel._preview.texture != null and panel._preview.texture != side, "второй ракурс показывает другую фотографию модели")
	await _capture("angle")
	panel._view_buttons[0].emit_signal("pressed")
	_check(panel._view_index == 0 and panel._preview.texture == side, "возврат к виду сбоку")
	_check(panel._action.disabled and panel._price_value.text == "50 очков" and panel._price_caption.text.contains("Не хватает 50") and panel._price_bar.value == 0.0, "недостаток очков виден рядом с товаром")
	panel._toggle_goal()
	profile.award("test", ["start:home"])
	_check(profile.purchase_goal == "moss" and panel._goal_status.text.contains("Осталось 30") and is_equal_approx(panel._price_bar.value, 0.4), "цель и прогресс после награды")
	await _capture("goal")
	profile.award("test", ["supplies:home>farm"])
	_check(not panel._action.disabled and panel._price_caption.text.contains("Доступно для покупки"), "товар доступен после накопления")
	panel._compare_button.button_pressed = true
	panel._activate()
	_check(panel._review_actions.visible and panel._review_card.visible and panel._review_title.text.contains("Мох") and panel._review_balance.text.contains("50 очков") and panel._review_balance.text.contains("0 очков") and panel._cancel_buy.has_focus() and profile.balance == 50, "подтверждение не списывает очки")
	await process_frame
	await _capture("confirm")
	_check(panel.dismiss_purchase() and profile.balance == 50, "отмена сохраняет баланс")
	panel._activate()
	panel._buy_reviewed()
	_check(profile.owns("moss") and profile.balance == 0 and profile.equipped == "moss" and panel._note.text.contains("куплен и надет"), "покупка сразу надевает комплект (20.11)")
	panel._activate()
	_check(profile.equipped == "moss" and panel._status.text == "НАДЕТО" and not panel._compare_mode and not panel._compare_button.visible, "экипировка обновляет состояние и закрывает сравнение")
	var equip_message := panel._note.text
	panel._view_buttons[1].emit_signal("pressed")
	_check(panel._note.text == equip_message, "смена ракурса сохраняет сообщение о применении")
	panel._view_buttons[0].emit_signal("pressed")
	panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	panel.size = Vector2(600, 650)
	await process_frame
	await process_frame
	_check(panel._layout.vertical and panel._row_grid.columns == 2, "узкий экран размещает коллекцию компактной сеткой")
	panel._rows.glacier.grab_focus()
	panel._compare_button.button_pressed = true
	await process_frame
	_check(panel._compare_root.visible and panel._compare_images[0].size.x > 0 and panel._compare_images[1].size.x > 0, "сравнение доступно на узком экране")
	await _capture("narrow_compare")
	panel.dismiss_purchase()
	panel._rows.moss.grab_focus()
	await _capture("narrow")
	panel.size = Vector2(400, 650)
	await process_frame
	await process_frame
	panel._rows.glacier.grab_focus()
	panel._compare_button.grab_focus()
	panel._compare_button.button_pressed = true
	await process_frame
	await process_frame
	_check(panel._heading_title.text == "Магазин" and panel._back.get_global_rect().end.x <= panel.get_global_rect().end.x and panel._compare_labels[1].text.contains("\n"), "компактная шапка и подписи сравнения не обрезаются")
	await _capture("compact")
	panel._goal_action.grab_focus()
	await process_frame
	await process_frame
	_check(panel._scroll.scroll_vertical > 0 and panel._goal_action.has_focus(), "фокус прокручивает экран к действию")
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
	_check(tablet_shop._rows.moss.has_focus(), "стрелка вправо переходит к следующей карточке")
	tablet_shop._rows.night.grab_focus()
	root.push_input(right)
	_check(tablet_shop._action.has_focus(), "навигация вправо от края коллекции ведёт к действию")
	tablet_shop._rows.glacier.grab_focus()
	await _capture("tablet")
	# 20.11: цель покупки видна в шапке дневника на всех вкладках
	var kept_goal := profile.purchase_goal
	profile.set_purchase_goal("glacier")
	_check(journal._goal_badge.visible and journal._goal_badge.text == "Цель: Ледник · %d / 50" % mini(profile.balance, 50), "цель покупки в шапке дневника")
	profile.set_purchase_goal(kept_goal)
	_check(journal._goal_badge.visible == (kept_goal != ""), "бейдж цели следует за сменой цели")
	tablet_shop._activate()
	_check(tablet_shop._review_actions.visible and journal.dismiss_subpanel() and profile.balance == 70, "отмена покупки в планшете не закрывает вкладку")
	tablet_shop._activate()
	journal._select(Journal.Tab.MAP)
	journal._select(Journal.Tab.SHOP)
	_check(not tablet_shop._review_actions.visible and profile.balance == 70, "смена вкладки отменяет подтверждение")
	profile.set_purchase_goal("night")
	tablet_shop._rows.glacier.grab_focus()
	tablet_shop._activate()
	_check(tablet_shop._review_card.visible and tablet_shop._note.text.contains("Ночь") and tablet_shop._note.text.contains("30 очков"), "подтверждение показывает влияние покупки на другую цель")
	profile.buy("glacier")
	_check(tablet_shop._confirm_buy.disabled and tablet_shop._review_balance.text.contains("20 очков"), "изменение данных блокирует устаревшее подтверждение")
	tablet_shop.dismiss_purchase()
	profile.load_error = ERR_FILE_CORRUPT
	tablet_shop._refresh()
	_check(tablet_shop._action.disabled and not tablet_shop._price_card.visible and tablet_shop._status.text == "НЕТ ДАННЫХ" and tablet_shop._balance.text == "—" and tablet_shop._card_status.ember.text == "Нет данных", "ошибка загрузки блокирует покупку и скрывает недостоверный прогресс")
	_check(tablet_shop._points(1) == "1 очко" and tablet_shop._points(2) == "2 очка" and tablet_shop._points(11) == "11 очков" and tablet_shop._points(21) == "21 очко", "название валюты согласовано с числом")
	journal.queue_free()
	await process_frame
	print("shop_ui_test failures: ", failures)
	quit(1 if failures else 0)


func _press_action(action: StringName) -> void:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = true
	root.push_input(event)
	event = event.duplicate()
	event.pressed = false
	root.push_input(event)


func _capture(name: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://.godot/shop_ui_test/" + name + ".png")
