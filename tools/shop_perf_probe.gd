extends SceneTree
## Repeatable cold-open and category-switch measurements with a fresh profile.
const Shop = preload("res://scripts/ui/shop_panel.gd")

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 45)
	_run.call_deferred()

func _run() -> void:
	var panel = Shop.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.set_profile(Shop.Progress.new())
	root.add_child(panel)
	var started := Time.get_ticks_usec()
	panel.open()
	var open_ms := float(Time.get_ticks_usec() - started) / 1000.0
	var max_card_ms := 0.0
	while panel.is_processing():
		var card_started := Time.get_ticks_usec()
		panel._process(0.0)
		max_card_ms = maxf(max_card_ms, float(Time.get_ticks_usec() - card_started) / 1000.0)
		await process_frame
	var loaded: int = panel._portraits.size()
	var unique := {}
	var pixels := 0
	for id: String in panel._portraits:
		for texture: Texture2D in panel._portraits[id]:
			if texture != null and not unique.has(texture.get_instance_id()):
				unique[texture.get_instance_id()] = true
				pixels += texture.get_width() * texture.get_height()
	started = Time.get_ticks_usec()
	panel._select_category(Shop.Progress.Category.TIRES)
	var switch_ms := float(Time.get_ticks_usec() - started) / 1000.0
	started = Time.get_ticks_usec()
	panel._fitting_button.button_pressed = true
	var fitting_ms := float(Time.get_ticks_usec() - started) / 1000.0
	print("SHOP_PERF open_ms=%.2f items=%d textures=%d uncompressed_rgba_mib=%.2f switch_ms=%.2f max_card_ms=%.2f fitting_ms=%.2f" % [open_ms, loaded, unique.size(), pixels * 4.0 / 1048576.0, switch_ms, max_card_ms, fitting_ms])
	panel.queue_free()
	await process_frame
	quit()
