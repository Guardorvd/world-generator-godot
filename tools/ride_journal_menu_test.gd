extends SceneTree
## Настоящая сцена меню с изолированным журналом; без загрузки или генерации мира.

const Main = preload("res://scenes/main.tscn")
const Feed = preload("res://scripts/game/ride_feed.gd")
const Thumb = preload("res://scripts/ui/ride_thumb.gd")
var failures := 0


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 45)
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok:
		failures += 1


func _run() -> void:
	var folder := "user://ride_journal_menu_test/" + str(Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(folder)
	GameContext.scope.settings.settings_path = folder.path_join("settings.cfg")
	var feed = Feed.new(folder)
	var entry := {id = "stand", version = Feed.VERSION, start = 1795600000, time = 2490,
		bike = 6430, foot = 360, falls = 2, seed = "Туман-4821", world_title = "Туман-4821",
		template_id = WorldTemplate.DEFAULT_ID, walk = false, thumb = Feed.thumb_name("stand")}
	_check(feed.upsert(entry) == OK, "создан отдельный журнал")
	var image := Image.create(320, 200, false, Image.FORMAT_RGB8)
	image.fill(Color("#c7d7b8"))
	var route := {legs = [PackedVector2Array([Vector2(20, 40), Vector2(70, 70), Vector2(130, 90), Vector2(220, 140), Vector2(280, 175)])], fall_marks = [{x = 130, z = 90}]}
	Thumb.render(image, Vector2(320, 200), route).save_png(feed.thumb_path("stand"))
	var main := Main.instantiate()
	root.add_child(main)
	root.size = Vector2i(1280, 720)
	await process_frame
	await process_frame
	main._ride_feed_view.feed = Feed.new(folder)
	main.get_node("%OpenRides").pressed.emit()
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	_check(main._is_screen("ride_feed") and main.screens.back.visible, "журнал открывается поверх фона меню")
	_check(main._ride_feed_view._cards.has("stand"), "экран меню показывает отдельную запись")
	var out := "res://.godot/ride-journal-1_1"
	DirAccess.make_dir_recursive_absolute(out)
	root.get_texture().get_image().save_png(out.path_join("menu_integration.png"))
	root.size = Vector2i(720, 1280)
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	var column := main.screens.ride_feed.find_child("RideColumn", true, false) as Control
	_check(column.scale.x > 1.0 and column.get_global_rect().size.x > 0.0, "портретный журнал увеличивает текст и карточки")
	root.get_texture().get_image().save_png(out.path_join("menu_integration_portrait.png"))
	root.size = Vector2i(1280, 720)
	await process_frame
	await process_frame
	var next_focus := InputEventAction.new()
	next_focus.action = &"ui_focus_next"
	next_focus.pressed = true
	Input.parse_input_event(next_focus)
	await process_frame
	_check(main._ride_feed_view.is_ancestor_of(root.gui_get_focus_owner()), "клавиатура переводит фокус в журнал")
	next_focus.pressed = false
	Input.parse_input_event(next_focus)
	main._ride_feed_view._choose(entry)
	await process_frame
	var cancel := InputEventAction.new()
	cancel.action = &"ui_cancel"
	cancel.pressed = true
	Input.parse_input_event(cancel)
	await process_frame
	_check(main._is_screen("ride_feed") and not main._ride_feed_view._dialog.visible, "отмена сначала закрывает подробности")
	cancel.pressed = false
	Input.parse_input_event(cancel)
	var cancel_again := cancel.duplicate() as InputEventAction
	cancel_again.pressed = true
	Input.parse_input_event(cancel_again)
	await process_frame
	_check(main._is_screen("menu"), "следующая отмена возвращает главное меню")
	cancel_again.pressed = false
	Input.parse_input_event(cancel_again)
	print("ride_journal_menu_test: ", "ok" if failures == 0 else "FAIL %d" % failures)
	quit(1 if failures else 0)
