extends SceneTree
## Примерка меняет только изолированную модель, а не профиль игрока.
const Shop = preload("res://scripts/ui/shop_panel.gd")
var failures := 0

func check(condition: bool, message: String) -> void:
	print(("PASS " if condition else "FAIL ") + message)
	if not condition:
		failures += 1

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 40)
	root.size = Vector2i(1280, 720)
	_run.call_deferred()

func _run() -> void:
	var profile = Shop.Progress.new()
	var before: Dictionary = profile._state.duplicate(true)
	var panel = Shop.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.set_profile(profile)
	root.add_child(panel)
	panel.open()
	panel._fitting_button.button_pressed = true
	await process_frame
	check(is_instance_valid(panel._fitting) and is_instance_valid(panel._fitting._bike), "модель создаётся при открытии примерочной")
	check(panel._fitting._viewport.render_target_update_mode in [SubViewport.UPDATE_ONCE, SubViewport.UPDATE_DISABLED], "примерочная не включает постоянную перерисовку")
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		await process_frame
		check(panel._fitting._viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED, "после кадра примерочная перестаёт рендериться")
	panel._select("moss")
	panel._select_category(Shop.Progress.Category.TIRES)
	panel._select("tires_rose")
	panel._select_category(Shop.Progress.Category.HELMET)
	panel._select("helmet_trail")
	if DisplayServer.get_name() != "headless":
		await process_frame
		await RenderingServer.frame_post_draw
		DirAccess.make_dir_recursive_absolute("res://.godot/ui-redesign")
		root.get_texture().get_image().save_png("res://.godot/ui-redesign/fitting.png")
	check(panel._fitting_items[0] == "moss" and panel._fitting_items[1] == "tires_rose" and panel._fitting_items[4] == "helmet_trail", "сочетание сохраняется при смене категории")
	check(profile._state == before, "выбор товаров не меняет профиль, баланс или экипировку")
	panel._compare_button.button_pressed = true
	check(panel._compare_mode and panel._fitting_items[1] == "tires_rose" and panel._fitting != null, "сравнение сохраняет выбранное сочетание")
	panel._compare_button.button_pressed = false
	check(not panel._compare_mode and panel._fitting_items[4] == "helmet_trail", "после сравнения возвращается примеряемый образ")
	panel._fitting_zoom.button_pressed = true
	panel._set_view(1)
	check(panel._fitting._closeup and panel._fitting._look == 1, "ракурс и приближение переключаются")
	if DisplayServer.get_name() != "headless":
		check(panel._fitting._viewport.render_target_update_mode == SubViewport.UPDATE_ONCE, "смена ракурса запрашивает новый кадр")
		await RenderingServer.frame_post_draw
		await process_frame
		check(panel._fitting._viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED, "после смены ракурса рендер снова останавливается")
	panel._reset_fitting()
	check(panel._fitting_items == Shop.Progress.DEFAULT_ITEMS and profile._state == before, "возврат к своему образу не записывает профиль")
	check(panel.dismiss_purchase() and panel._fitting == null and profile._state == before, "отмена закрывает примерочную, освобождает сцену и сохраняет профиль")
	panel._owned_filter.button_pressed = true
	check(panel._rows[Shop.Progress.DEFAULT_HELMET].visible and not panel._rows.helmet_trail.visible, "фильтр оставляет купленные вещи")
	panel._owned_filter.button_pressed = false
	check(panel._rows.helmet_trail.visible, "выключение фильтра возвращает товары")
	panel.hide()
	while panel.is_processing():
		await process_frame
	check(panel._portraits.is_empty() and not panel.is_processing(), "после закрытия освобождаются изображения и останавливается очередь")
	panel.queue_free()
	await process_frame
	quit(1 if failures else 0)
