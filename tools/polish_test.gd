extends SceneTree
## Быстрые проверки полировки 4.6: очистка HUD, интерполяция велосипеда и обновление меша.

var fails := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, label: String) -> void:
	print(("✓ " if ok else "✗ ") + label)
	if not ok:
		fails += 1


func _run() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	var hud: Hud = main.get_node("UI/Root/Hud")
	hud.toast("")
	_check(hud._toast_left == 0.0 and hud._toast_queue.is_empty(), "пустое сообщение не занимает HUD")
	hud.toast("Сообщение прошлого мира")
	hud.toast("Сообщение в очереди")
	hud.toast("Ещё одно сообщение")
	hud.toast("Сообщение в очереди")
	hud.toast("Сообщение прошлого мира")
	_check(hud._toast_queue == PackedStringArray(["Сообщение в очереди", "Ещё одно сообщение"]),
		"повтор текущего и несоседнего сообщения в очереди не дублируется")
	hud.set_hints("Подсказка", "Действие")
	hud.bike_shown = true
	hud.bike_pos = Vector2(20, 30)
	hud.set_map_visible(true)
	hud.big_map.hover = {name = "Старое место"}
	hud.clear_world()
	_check(hud._toast_queue.is_empty() and hud._toast_left == 0.0 and hud.toast_label.modulate.a == 0.0,
		"выход в меню очищает текущие сообщения и очередь")
	_check(not hud.bike_shown and hud.bike_pos == Vector2.ZERO and hud.hint.text.is_empty() and hud.prompt.text.is_empty(),
		"выход в меню очищает маркер велосипеда и подсказки")
	_check(not hud.big_map.visible and hud.big_map.mouse_filter == Control.MOUSE_FILTER_IGNORE and hud.big_map.hover.is_empty(),
		"закрытая карта не перехватывает мышь и не хранит старое место")
	main.queue_free()
	await process_frame

	var view: BikeView = load("res://scenes/bike.tscn").instantiate()
	root.add_child(view)
	var bike := BikeRide.new()
	bike.x = 10.0
	view.snap(bike)
	view.draw(0.0)
	_check(is_equal_approx(view.position.x, 10.0), "первое положение велосипеда без перехода")
	for x in [20.0, 30.0, 40.0]:
		bike.x = x
		view.tick(bike)
		view.draw(0.25)
		_check(is_equal_approx(view.position.x, x - 7.5), "интерполяция после смены буферов: %.0f" % x)
	bike.x = 100.0
	view.snap(bike)
	view.draw(0.5)
	_check(is_equal_approx(view.position.x, 100.0), "перемещение сбрасывает интерполяцию")
	bike.x = 110.0
	view.tick(bike)
	view.draw(0.5)
	_check(is_equal_approx(view.position.x, 105.0), "новый такт сохраняет отдельный предыдущий буфер")
	view.queue_free()
	await process_frame

	var w := WorldData.new()
	w.W = 12
	w.H = 9
	w.N = w.W * w.H
	w.h.resize(w.N)
	w.ocean.resize(w.N)
	w.river.resize(w.N)
	w.lake.resize(w.N)
	var heights := Heightfield.new(w, false)
	for i in w.N:
		heights.hv[i] = sin(float(i))
	var arrays := TerrainBuilder.build_arrays(w, heights)
	var changed := PackedInt32Array([0, 1, 13, 14, 14, w.N - 1])
	for i in changed:
		heights.hv[i] += 1.0
	TerrainBuilder.patch(arrays, w, heights, changed)
	var rebuilt := TerrainBuilder.build_arrays(w, heights)
	_check(arrays == rebuilt, "обновление соседних и повторных клеток совпадает с полной сборкой меша")
	print("Полировка 4.6: ошибок %d" % fails)
	quit(0 if fails == 0 else 1)
