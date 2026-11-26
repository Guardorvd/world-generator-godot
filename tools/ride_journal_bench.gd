extends SceneTree
## Изолированное сравнение ленты из HEAD и текущей версии на одинаковых PNG.

const Feed = preload("res://scripts/game/ride_feed.gd")
const CurrentView = preload("res://scripts/ui/ride_feed_view.gd")
const Style = preload("res://scripts/ui/hud_style.gd")

class Settings extends RefCounted:
	var show_walks := false
	func save_settings() -> Error:
		return OK


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	root.size = Vector2i(1280, 720)
	_run.call_deferred()


func _run() -> void:
	var old_script := GDScript.new()
	old_script.source_code = FileAccess.get_file_as_string("res://.godot/ride-journal-baseline/ride_feed_view.gd")
	if old_script.reload() != OK:
		push_error("Не удалось загрузить исходную версию ленты")
		quit(1)
		return
	var folder := "user://ride_journal_bench/" + str(Time.get_ticks_usec())
	var feed = Feed.new(folder)
	var rows: Array[Dictionary] = []
	var picture := Image.create(320, 200, false, Image.FORMAT_RGB8)
	picture.fill(Color("#b5c9aa"))
	DirAccess.make_dir_recursive_absolute(folder.path_join("thumbs"))
	for i in 200:
		var id := "ride-%d" % i
		rows.append({id = id, version = Feed.VERSION, start = i + 1, time = 120.0,
			bike = 300.0, foot = 0.0, falls = 0, seed = "Тест", world_title = "Тест",
			template_id = WorldTemplate.DEFAULT_ID, walk = false, thumb = Feed.thumb_name(id)})
		picture.save_png(feed.thumb_path(id))
	var scene := Control.new()
	scene.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scene.theme = Style.theme()
	root.add_child(scene)
	for count in [0, 20, 200]:
		var current_rows: Array[Dictionary] = []
		current_rows.assign(rows.slice(0, count))
		if feed._save(current_rows) != OK:
			push_error("Не удалось подготовить данные")
			quit(1)
			return
		await _measure(scene, old_script, folder, count, "до")
		await _measure(scene, CurrentView, folder, count, "после")
	quit()


func _measure(scene: Control, script: Script, folder: String, count: int, label: String) -> void:
	var panel := PanelContainer.new()
	panel.position = Vector2(190, 24) if label == "до" else Vector2(330, 24)
	panel.size = Vector2(900, 672) if label == "до" else Vector2(620, 672)
	scene.add_child(panel)
	var view = script.new()
	view.feed = Feed.new(folder)
	panel.add_child(view)
	var memory_before := Performance.get_monitor(Performance.MEMORY_STATIC)
	var started := Time.get_ticks_usec()
	view.setup(Settings.new())
	view.refresh()
	var open_us := Time.get_ticks_usec() - started
	await process_frame
	await process_frame
	var first_us := Time.get_ticks_usec() - started
	for i in 6:
		await process_frame
	var initial_cards: int = view._cards.size()
	var initial_memory := Performance.get_monitor(Performance.MEMORY_STATIC) - memory_before
	var max_frame := 0
	while not view._pending_entries.is_empty():
		var frame := Time.get_ticks_usec()
		var scroll := view.find_children("*", "ScrollContainer", true, false)[0] as ScrollContainer
		scroll.scroll_vertical = int(scroll.get_v_scroll_bar().max_value)
		await process_frame
		max_frame = maxi(max_frame, Time.get_ticks_usec() - frame)
	await process_frame
	var elapsed := Time.get_ticks_usec() - started
	var textures := 0
	var texture_bytes := 0
	for card in view._cards.values():
		if card._preview.texture != null:
			textures += 1
			texture_bytes += card._preview.texture.get_width() * card._preview.texture.get_height() * 4
	var memory_delta := Performance.get_monitor(Performance.MEMORY_STATIC) - memory_before
	print("BENCH %s %d: open=%.1fms first=%.1fms initial_cards=%d initial_static=%.2fMiB all=%.1fms max_frame=%.1fms cards=%d textures=%d rgba=%.2fMiB static_delta=%.2fMiB" % [label, count, open_us / 1000.0, first_us / 1000.0, initial_cards, initial_memory / 1048576.0, elapsed / 1000.0, max_frame / 1000.0, view._cards.size(), textures, texture_bytes / 1048576.0, memory_delta / 1048576.0])
	panel.queue_free()
	await process_frame
	await process_frame
