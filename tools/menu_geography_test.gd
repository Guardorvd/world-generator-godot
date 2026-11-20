extends SceneTree
const Preview := preload("res://scripts/ui/menu_map_preview.gd")
func _initialize() -> void:
	var start := Time.get_ticks_msec()
	var cancelled := Preview.generate_geography("preview-cancel", func() -> bool: return true)
	if not cancelled.is_empty():
		printerr("FAIL: cancelled preview returned data")
		quit(1)
		return
	var images := Preview.generate_geography("preview-geography-test", func() -> bool: return false)
	var ok := images.size() == 3
	if ok:
		for img: Image in images:
			ok = ok and img.get_width() == 256 and img.get_height() == 256
	print("Geography preview: ", "OK" if ok else "FAIL", " time ms=", Time.get_ticks_msec() - start)
	quit(0 if ok else 1)
