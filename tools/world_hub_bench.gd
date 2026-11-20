extends SceneTree
func _initialize() -> void:
	_run.call_deferred()
func _run() -> void:
	root.size = Vector2i(1280, 720)
	var settings := GameContext.scope.settings
	settings.settings_path = "res://.godot/hub_bench_settings_%d.cfg" % OS.get_process_id()
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	settings.recent_seeds.clear()
	settings.favorite_seeds.clear()
	main._world_cards.clear()
	main._carousel_seeds.clear()
	main._saved_seeds.clear()
	main._previews.clear()
	for i in 500:
		var seed_text := "Bench-%04d" % i
		main._world_cards[seed_text] = {seed = seed_text, saved = false, summary = "", ready = false, map_ready = false}
		main._carousel_seeds.append(seed_text)
		main._previews[seed_text] = null
	var start_us := Time.get_ticks_usec()
	main._open_all_worlds()
	var open_ms := float(Time.get_ticks_usec() - start_us) / 1000.0
	var initial_rows: int = main._hub_rows.size()
	var frames := 0
	while not main._hub_build_queue.is_empty():
		frames += 1
		await process_frame
	start_us = Time.get_ticks_usec()
	main._on_star("Bench-0300", main._hub_rows["Bench-0300"].get_meta("star_button"))
	var favorite_ms := float(Time.get_ticks_usec() - start_us) / 1000.0
	print("HUB_500 open_ms=", open_ms, " initial_rows=", initial_rows, " fill_frames=", frames, " favorite_ms=", favorite_ms)
	main.queue_free()
	await process_frame
	if FileAccess.file_exists(settings.settings_path): DirAccess.remove_absolute(settings.settings_path)
	quit()
