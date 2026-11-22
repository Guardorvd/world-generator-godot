extends SceneTree
var failures := 0
func check(value: bool, message: String) -> void:
	print(("OK " if value else "FAIL ") + message)
	failures += int(not value)
func _initialize() -> void:
	_run.call_deferred()
func _texture(color: Color) -> ImageTexture:
	var image := Image.create(8, 8, false, Image.FORMAT_RGB8)
	image.fill(color)
	return ImageTexture.create_from_image(image)
func _run() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	var carousel = main.get_node("%Carousel")
	carousel.force_animate_in_headless = true
	var first := _texture(Color.RED)
	var second := _texture(Color.BLUE)
	var entries: Array[Dictionary] = [{seed = "One", texture = first}, {seed = "Two", texture = second}]
	main._world_cards["One"] = {seed = "One", saved = false, summary = "", ready = false}
	main._world_cards["Two"] = {seed = "Two", saved = true, saved_at = 0, visited = 3, summary = "", ready = false}
	main._carousel_seeds.assign(["One", "Two"])
	main._previews["One"] = first
	main._previews["Two"] = second
	carousel.set_entries(entries, "One")
	await process_frame
	await process_frame
	var mode_button: Control = carousel._modes[0]
	check(carousel._indicator.size.is_equal_approx(mode_button.size)
		and carousel._indicator.position.is_equal_approx(mode_button.position + carousel._mode_buttons.position),
		"подложка точно совпадает с выбранным переключателем")
	main._select_world("One")
	var world_name: Label = carousel.get_node("Card/Slide/Frame/WorldInfo/Name")
	var old_name: String = world_name.text
	carousel.move(1)
	check(main._selected_seed == "Two" and "Two" in main.get_node("%Start").text, "кнопка запуска обновляется сразу при смене мира")
	check(world_name.text == old_name and carousel._slide_tween != null, "старая карточка уходит до смены содержимого")
	carousel._slide_tween.custom_step(0.04)
	check(carousel._slide.position.x < 0.0 and carousel._card.clip_contents, "уход ограничен обрезаемым контейнером")
	carousel._slide_tween.custom_step(0.04)
	check(world_name.text == "Two" and carousel._slide.position.x > 0.0, "новый мир появляется с противоположной стороны")
	carousel.move(-1)
	carousel.move(1)
	carousel._slide_tween.custom_step(0.4)
	check(carousel._index == 1 and is_zero_approx(carousel._slide.position.x) and world_name.text == "Two", "быстрые переключения завершаются на последнем мире")
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	carousel._card_input(wheel)
	check(main._selected_seed == "Two", "колесо не переключает мир на главном экране")
	main._select_world("One")
	if carousel._slide_tween != null: carousel._slide_tween.custom_step(0.4)
	carousel._derived["One"] = [second, first]
	carousel._set_mode(1)
	check(carousel._old_map.visible and carousel._old_map.texture == first and carousel._map.texture == second, "смена режима сохраняет старую и новую текстуры для кроссфейда")
	check(main._ui_audio.last_sound == &"carousel_step" and is_equal_approx(main._ui_audio.last_pitch, 1.06), "режим карты звучит с высотой вправо")
	carousel._map_tween.custom_step(0.08)
	check(carousel._map.modulate.a > 0.0 and carousel._map.modulate.a < 1.0, "текстуры перекрываются во время кроссфейда")
	carousel._set_mode(2)
	carousel._set_mode(0)
	if carousel._map_tween != null: carousel._map_tween.custom_step(0.3)
	check(carousel._map.texture == first and is_equal_approx(carousel._map.modulate.a, 1.0) and not carousel._old_map.visible, "прерванный кроссфейд сохраняет последний режим")
	var empty: Array[Dictionary] = []
	carousel.set_entries(empty, "")
	await process_frame
	check(carousel._slide.position.is_equal_approx(Vector2.ZERO) and carousel._slide.size.is_equal_approx(carousel._card.size), "содержимое пустой карточки полностью помещается в рамку")
	check(not carousel._quick_seed.visible and not carousel._create_first.visible and carousel._pattern.visible,
		"пустая карточка не дублирует создание мира")
	carousel.set_entries(entries, "One")
	var unbuilt: Array[Dictionary] = [{seed = "Fresh", texture = null, map_ready = false}]
	main._world_cards["Fresh"] = {seed = "Fresh", saved = false, map_ready = false}
	main._selected_seed = "Fresh"
	carousel.set_entries(unbuilt, "Fresh")
	main._update_hub_map()
	check(not carousel._build_preview.visible and main.get_node("%HubBuildPreview").visible,
		"построение карты доступно в списке миров, а не на главной")
	main._fit_menu()
	var panel: Control = main.get_node("%Loading/Panel")
	check(is_equal_approx(panel.offset_left, carousel.offset_left) and is_equal_approx(panel.offset_top, carousel.offset_top), "загрузка совмещена с витриной карты")
	check(main.get_node("%LoadPreview").stretch_mode == TextureRect.STRETCH_KEEP_ASPECT_CENTERED, "карта загрузки сохраняет квадрат без обрезки")
	check(is_equal_approx(float(main._ui_audio.SOUNDS[&"confirm"].db), -12.0), "подтверждение воспроизводится на -12 дБ")
	main.queue_free()
	await process_frame
	print("Menu interaction failures: ", failures)
	quit(1 if failures else 0)
