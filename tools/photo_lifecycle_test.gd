extends SceneTree
const PhotoCamera = preload("res://scripts/render/photo_camera.gd")
var fails := 0

class TestPhoto extends PhotoCamera:
	var reads := 0
	func _capture_image() -> Image:
		reads += 1
		return Image.create(32, 24, false, Image.FORMAT_RGB8)


func check(ok: bool, label: String) -> void:
	print(("OK " if ok else "FAIL ") + label)
	fails += int(not ok)


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	call_deferred("run")


func run() -> void:
	var photo := TestPhoto.new()
	root.add_child(photo)
	var events: Array[bool] = []
	photo.capturing.connect(func(on: bool) -> void: events.append(on))
	photo.enter()
	photo.shoot()
	photo.exit() # как GameWorld.set_paused(true)
	RenderingServer.frame_post_draw.emit()
	check(photo.reads == 0 and photo.shots.is_empty() and events == [true, false] and not photo._busy,
		"пауза/выход из видоискателя отменяет ожидающий кадр и восстанавливает интерфейс")
	photo.enter()
	photo.shoot()
	root.remove_child(photo)
	RenderingServer.frame_post_draw.emit()
	check(photo.reads == 0 and not photo._busy and not RenderingServer.frame_post_draw.is_connected(photo._capture_frame),
		"выход из дерева отключает обработчик кадра")
	root.add_child(photo)
	photo.enter()
	photo.shoot()
	paused = true
	RenderingServer.frame_post_draw.emit()
	paused = false
	check(photo.reads == 0 and not photo._busy, "пауза SceneTree до кадра отменяет съёмку")
	photo.enter()
	photo.shoot()
	RenderingServer.frame_post_draw.emit()
	check(photo.reads == 1 and photo.shots.is_empty() and photo.saving() and photo._busy,
		"кадр прочитан, файл пишется в фоне — снимок появится после записи")
	while photo.saving():
		await process_frame
	check(photo.shots.size() == 1 and FileAccess.file_exists(photo.shots[0].path) and photo._busy and photo._cooldown > 0,
		"снимок записан в фоне, перезарядка начинается без корутины")
	photo.shoot()
	check(photo.reads == 1 and not RenderingServer.frame_post_draw.is_connected(photo._capture_frame)
		and photo.feedback.play_counts.get(&"error_deny", 0) == 1,
		"перезарядка даёт отказ и не запускает повторную съёмку")
	photo._deny_tween.custom_step(0.03)
	check(is_equal_approx(photo._prompt_offset, 5.0), "при отказе подсказка сдвигается на 5 px")
	photo._deny_tween.custom_step(0.15)
	check(is_zero_approx(photo._prompt_offset), "через 180 мс подсказка возвращается на место")
	await check_plaque_lock(photo)
	photo._process(PhotoCamera.SHUTTER_COOLDOWN)
	check(not photo._busy, "перезарядка завершается в _process")
	photo.shoot()
	photo.queue_free()
	RenderingServer.frame_post_draw.emit()
	check(photo.reads == 1, "узел с queue_free не читает изображение")
	for shot: Dictionary in photo.shots:
		if not shot.path.is_empty() and FileAccess.file_exists(shot.path):
			DirAccess.remove_absolute(shot.path)
	await process_frame
	var immediate := TestPhoto.new()
	root.add_child(immediate)
	immediate.enter()
	immediate.capturing.connect(func(on: bool) -> void:
		if on: immediate.exit())
	immediate.shoot()
	check(not immediate._busy and not immediate._capturing, "синхронная отмена подписчиком capturing безопасна")
	immediate.free()
	var removed := TestPhoto.new()
	root.add_child(removed)
	removed.enter()
	removed.capturing.connect(func(on: bool) -> void:
		if not on:
			root.remove_child(removed)
			removed.queue_free())
	removed.shoot()
	RenderingServer.frame_post_draw.emit()
	check(not removed.is_inside_tree() and removed.shots.is_empty(), "удаление подписчиком после кадра не возобновляет работу с узлом")
	await process_frame
	print("photo_lifecycle_test: %d failures" % fails)
	quit(1 if fails else 0)


func check_plaque_lock(photo: TestPhoto) -> void:
	var camera := Camera3D.new()
	root.add_child(camera)
	await process_frame
	photo.plaques = [{id = "plaque", name = "Обелиск", at = Transform3D(Basis.IDENTITY, Vector3(0, 0, -3)), size = Vector2(0.6, 0.4)}]
	photo._track_plaques(camera)
	photo._track_plaques(camera)
	check(photo.plaque_view.get("state") == "ok" and photo.feedback.play_counts.get(&"photo_focus_lock", 0) == 1,
		"зелёная рамка даёт один тик захвата")
	camera.position.z = 4.0
	photo._track_plaques(camera)
	check(photo.plaque_view.get("state") == "far" and photo.feedback.play_counts.get(&"photo_focus_lock", 0) == 1,
		"выход за дистанцию фокуса не играет тик")
	camera.position.z = 0.0
	photo._track_plaques(camera)
	check(photo.feedback.play_counts.get(&"photo_focus_lock", 0) == 2, "повторный захват таблички снова слышен")
	camera.queue_free()
