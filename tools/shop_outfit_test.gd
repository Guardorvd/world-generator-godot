extends SceneTree
## Применение купленной части образа не покупает остальные вещи и сохраняется целиком.
const Shop = preload("res://scripts/ui/shop_panel.gd")
var failures := 0

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 30)
	root.size = Vector2i(1280, 720)
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	print("PASS " if condition else "FAIL ", message)
	if not condition:
		failures += 1

func _run() -> void:
	var profile = Shop.Progress.new()
	profile.award("test", ["start:home", "supplies:home>farm", "repair:home>farm", "paint:home", "visit:home", "tour:home"])
	check(profile.buy("moss") == OK and profile.buy("tires_rose") == OK, "куплены расцветка и шины")
	var balance: int = profile.balance
	var before: Dictionary = profile._state.duplicate(true)
	check(profile.equip_set(["moss", "helmet_trail", Shop.Progress.DEFAULT_GRIPS, Shop.Progress.DEFAULT_PEDALS, Shop.Progress.DEFAULT_HELMET]) == ERR_INVALID_PARAMETER and profile._state == before,
		"неверный набор отклоняется целиком")
	profile.load_error = ERR_CANT_CREATE
	check(profile.equip_set(["moss", "tires_rose", Shop.Progress.DEFAULT_GRIPS, Shop.Progress.DEFAULT_PEDALS, Shop.Progress.DEFAULT_HELMET]) != OK and profile._state == before,
		"ошибка сохранения не меняет часть образа")
	profile.load_error = OK
	var panel = Shop.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.set_profile(profile)
	root.add_child(panel)
	panel.open()
	panel._fitting_button.button_pressed = true
	panel._select("moss")
	panel._select_category(Shop.Progress.Category.TIRES)
	panel._select("tires_rose")
	panel._select_category(Shop.Progress.Category.HELMET)
	panel._select("helmet_trail")
	check(not panel._fitting_apply.disabled, "купленный набор доступен для применения")
	panel._apply_fitting()
	check(profile.equipped == "moss" and profile.equipped_tires == "tires_rose" and profile.equipped_helmet == Shop.Progress.DEFAULT_HELMET,
		"надеты купленные вещи, непроданный шлем не изменён")
	check(profile.balance == balance and not profile.owns("helmet_trail") and panel._fitting_items[4] == "helmet_trail",
		"примерка не списывает очки и сохраняет некупленную вещь в образе")
	panel.queue_free()
	await process_frame
	quit(1 if failures else 0)
