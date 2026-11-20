extends SceneTree
var failures := 0
func check(condition: bool, message: String) -> void:
	print(("OK " if condition else "FAIL ") + message)
	failures += int(not condition)
func _initialize() -> void:
	_run.call_deferred()
func _run() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	var carousel = main.get_node("%Carousel")
	check(not carousel.is_processing(), "витрина не опрашивает поток в простое")
	var entries: Array[Dictionary] = [{seed = "preview-async-test", texture = null, map_ready = false}]
	carousel.set_entries(entries, "preview-async-test")
	carousel._request_preview()
	check(carousel._thread != null and carousel.is_processing() and not carousel._build_preview.visible, "явный запрос запускает фоновую подготовку")
	var frames := 0
	var deadline := Time.get_ticks_msec() + 30000
	while carousel._thread != null and Time.get_ticks_msec() < deadline:
		frames += 1
		await process_frame
	check(carousel._thread == null and frames > 1 and not carousel.is_processing(), "интерфейс обновляется во время вычислений и не опрашивает поток после завершения")
	check(carousel.generated_preview("preview-async-test") != null and main._previews.get("preview-async-test") != null, "готовый рельеф передаётся меню")
	check(carousel._derived.get("preview-async-test", []).size() == 2, "атлас и высоты сохраняются для выбора")
	for i in range(12):
		carousel._remember_maps("test-map-%d" % i, [])
	check(carousel._derived.size() <= carousel.MAX_DERIVED_MAPS, "кэш производных карт ограничен по числу миров")
	main._previews.clear()
	check(main._preview_tex("preview-async-test") != null, "предпросмотр переживает обновление списка миров")
	entries = [{seed = "preview-cancel-test", texture = null, map_ready = false}]
	carousel.set_entries(entries, "preview-cancel-test")
	carousel._request_preview()
	carousel.cancel_preview()
	while carousel._thread != null and Time.get_ticks_msec() < deadline:
		await process_frame
	check(carousel._thread == null and carousel.generated_preview("preview-cancel-test") == null, "отменённый расчёт не публикует результат")
	main.queue_free()
	await process_frame
	print("Async preview failures: ", failures)
	quit(1 if failures else 0)
