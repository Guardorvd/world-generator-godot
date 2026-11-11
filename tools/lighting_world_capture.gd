extends "res://tools/control/shots.gd"
## Real generated game, repeatable viewpoints from the existing capture suite.
## --seed Север-1234 --size 128 --hour 7.5 --quality 1 --cover 0.2 --out <dir>
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 300)
	out = Dev.out_dir()
	GameContext.scope.settings.settings_path = out.path_join("capture_settings.cfg")
	worlds = [[Dev.arg("seed", "Север-1234"), int(Dev.arg("size", "128"))]]
	GameContext.scope.settings.day_minutes = 0.0
	GameContext.scope.settings.start_hour = float(Dev.arg("hour", "7.5"))
	GameContext.scope.settings.start_hour_set = true
	GameContext.scope.settings.lighting = int(Dev.arg("quality", "1"))
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)

func _place(game: GameWorld, v: Dictionary) -> void:
	if game.opening_active():
		game._finish_opening()
	main.hud.visible = false
	super._place(game, v)
	preload("res://scripts/render/lighting_quality.gd").apply(
		game.get_node("WorldEnvironment").environment, game.get_node("Sun"), int(Dev.arg("quality", "1")), true)
	game.day.cloud_cover_override = float(Dev.arg("cover", "-1"))
	game.day.apply(float(Dev.arg("hour", "7.5")), 0.0)
