extends "res://tools/control/shots.gd"
## Крупные планы воды в двух настоящих мирах; общий запуск и --out как у shots.gd.

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 420)
	super._initialize()
	worlds = [["Туман-4821", 256], ["Север-1234", 256]]

func _place(game: GameWorld, v: Dictionary) -> void:
	if v.name == "spawn":
		views = []
		var calm := {}
		var rapid := {}
		var widest := -INF
		var steepest := -INF
		for ribbon: Array in game.heights.ribbons:
			for k in range(1, ribbon.size() - 1):
				var p: Dictionary = ribbon[k]
				if p.x < 25 or p.z < 25 or p.x > game.world.W * 4 - 25 or p.z > game.world.H * 4 - 25:
					continue
				var cell := floori(p.z / 4) * game.world.W + floori(p.x / 4)
				if game.world.lake[cell] != 0 or game.world.ocean[cell] != 0:
					continue
				if game.heights.lake_level(p.x, p.z) > -INF:
					continue
				var a: Dictionary = ribbon[k - 1]
				var b: Dictionary = ribbon[k + 1]
				var grade: float = (a.y - b.y) / maxf(Vector2(b.x - a.x, b.z - a.z).length(), 0.01)
				if p.w / (1 + grade * 15) > widest:
					widest = p.w / (1 + grade * 15)
					calm = p
				var score: float = minf(grade, 0.3) * minf(p.w, 2.5) / (1.0 + maxf(0, grade - 0.5) * 5)
				if score > steepest:
					steepest = score
					rapid = p
		for entry: Array in [["pool", calm], ["rapids", rapid]]:
			if entry[1].is_empty():
				continue
			var p: Dictionary = entry[1]
			var target := Vector3(p.x, p.y, p.z)
			views.append({name = entry[0], pos = Dev._look_from(game.heights, target, 14, 3, 5), target = target})
		var deepest := -INF
		var lake := Vector3.ZERO
		for i in game.world.N:
			if game.world.lake[i] == 0:
				continue
			var depth: float = game.world.filled[i] - game.world.h[i]
			if depth > deepest:
				deepest = depth
				lake = Vector3((i % game.world.W + 0.5) * 4, game.world.filled[i] * GameConfig.HS - WaterBuilder.LAKE_DROP, (i / game.world.W + 0.5) * 4)
		if deepest > 0:
			views.append({name = "lake", pos = Dev._look_from(game.heights, lake, 32, 4, 8), target = lake})
		if views.is_empty():
			views = [v]
		v = views[0]
	super._place(game, v)
