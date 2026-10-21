extends "res://tools/control/shots.gd"
## Виды молодняка и старого леса в настоящем мире; запуск с окном, --out как у shots.gd.


func _initialize() -> void:
	super._initialize()
	worlds = [["Туман-4821", 256]]


func _place(game: GameWorld, v: Dictionary) -> void:
	if v.name == "spawn":
		views = []
		var w := game.world
		for entry in [["young", 0.55], ["old", 1.5]]:
			var best := -1
			var score := INF
			for o in w.obj_count:
				if not Biomes.is_tree(w.obj_k[o]):
					continue
				var x := w.obj_x[o]
				var y := w.obj_y[o]
				if x < 12 or y < 12 or x > w.W - 12 or y > w.H - 12:
					continue
				var cell := floori(y) * w.W + floori(x)
				if w.biome[cell] != Biomes.FOREST and w.biome[cell] != Biomes.TAIGA:
					continue
				var delta: float = absf(w.obj_s[o] - entry[1])
				if delta < score:
					score = delta
					best = o
			if best >= 0:
				var x := w.obj_x[best] * GameConfig.TILE
				var z := w.obj_y[best] * GameConfig.TILE
				var target := Vector3(x, game.heights.ground_at(x, z) + 3.0, z)
				views.append({name = entry[0], pos = Dev._look_from(game.heights, target, 14, 3, 7), target = target})
		if views.is_empty():
			views = [v]
		v = views[0]
	super._place(game, v)
