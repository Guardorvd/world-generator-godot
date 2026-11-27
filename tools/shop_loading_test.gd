extends SceneTree
## Switching or closing during a background image request must not publish stale results.
const Shop = preload("res://scripts/ui/shop_panel.gd")
var failures := 0

func check(value: bool, message: String) -> void:
	print(("PASS " if value else "FAIL ") + message)
	if not value:
		failures += 1

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 45)
	_run.call_deferred()

func _run() -> void:
	var panel = Shop.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.set_profile(Shop.Progress.new())
	root.add_child(panel)
	panel.open()
	check(panel._portraits.size() < Shop.Progress.PRICES.size(), "открытие не загружает все категории")
	panel._process(0.0)
	panel._select_category(Shop.Progress.Category.TIRES)
	while panel.is_processing():
		await process_frame
	check(panel._loaded_category == Shop.Progress.Category.TIRES and panel._portraits.size() == 6, "быстрая смена загружает только новую категорию")
	check(not panel._portraits.has("moss") and panel._card_images.tires_rose.texture != null, "старые результаты не попадают в новую категорию")
	panel._select_category(Shop.Progress.Category.SCHEME)
	panel._process(0.0)
	panel.hide()
	while panel.is_processing():
		await process_frame
	check(panel._portraits.is_empty() and panel._portrait_job_path.is_empty(), "закрытие освобождает изображения и завершает фоновую задачу")
	panel.show()
	panel.open()
	while panel.is_processing():
		await process_frame
	check(panel._loaded_category == Shop.Progress.Category.SCHEME and panel._preview.texture != null, "после повторного открытия изображения доступны")
	panel.queue_free()
	await process_frame
	quit(1 if failures else 0)
