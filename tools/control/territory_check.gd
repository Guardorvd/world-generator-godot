extends "res://tools/control/check.gd"
## Реальный экран паузы и карта 8.5 за одну загрузку; использует обычный check.gd.
## godot --path . --script res://tools/control/territory_check.gd -- --size 256 --views spawn,map --fps off
var ui_phase := 0
var ui_wait := 0
var saved := {}


func _cached(_id: String, _views: Array, _fps: bool) -> bool:
	return false # снимки check.gd не заменяют нажатия кнопок этого сценария


func _process(delta: float) -> bool:
	if ui_phase > 0 and not done:
		return _finish()
	return super._process(delta)


func verify(ok: bool, label: String) -> void:
	if not ok:
		failed = true
		printerr("territory_check: " + label)


func _expand_to(side: int) -> void:
	var game: GameWorld = main.game
	game.set_paused(true)
	main._show("pause")
	var button: Button = main.get_node("%ExpandTerritory")
	verify(not button.disabled, "Кнопка расширения недоступна")
	button.pressed.emit()
	game.set_paused(true)
	verify(game.world.available_rect.size == Vector2i(side, side), "Кнопка не открыла территорию %d" % side)
	verify(game.world == saved.world and game.heights == saved.heights, "Кнопка пересоздала данные мира")
	verify(game.get_node("Terrain").mesh == saved.mesh and main.hud.map_tex == saved.map, "Кнопка пересобрала рельеф или карту")
	verify(game.player == saved.player and game.bike == saved.bike, "Кнопка пересоздала игрока или велосипед")
	verify(Vector3(game.player.x, game.player.feet, game.player.z) == saved.position, "Расширение переместило игрока")
	verify(main.hud.visited == saved.visited, "Расширение забыло посещённые места")
	for place: Dictionary in main.hud.places():
		verify(game.world.accessible(place.x, place.y), "Цель за пределами доступной территории")
	main.hud.visible = true
	main.hud.set_map_visible(true)
	ui_wait = 0


func _finish() -> bool:
	if ui_phase == 0:
		var game: GameWorld = main.game
		verify(game.world.available_rect.size == Vector2i(256, 256), "Запускать с --size 256")
		saved = {world = game.world, heights = game.heights, mesh = game.get_node("Terrain").mesh,
			map = main.hud.map_tex, player = game.player, bike = game.bike,
			position = Vector3(game.player.x, game.player.feet, game.player.z), visited = main.hud.visited.duplicate()}
		main.hud.visible = true
		main.hud.set_map_visible(true)
		ui_phase = 1
		return false
	ui_wait += 1
	if ui_wait < SETTLE_FRAMES:
		return false
	match ui_phase:
		1:
			_save(root.get_texture().get_image(), "territory_256", true)
			_expand_to(512)
			ui_phase = 2
		2:
			_save(root.get_texture().get_image(), "territory_512", true)
			_expand_to(768)
			ui_phase = 3
		3:
			_save(root.get_texture().get_image(), "territory_768", true)
			main.hud.visible = false
			main._show("pause")
			verify(main.get_node("%ExpandTerritory").disabled, "Расширение не отключено на максимуме")
			ui_wait = 0
			ui_phase = 4
		4:
			_save(root.get_texture().get_image(), "territory_pause", true)
			print("territory_check: " + ("OK" if not failed else "FAILED"))
			saved.clear()
			return super._finish()
	return false
