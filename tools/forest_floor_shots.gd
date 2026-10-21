extends "res://tools/control/shots.gd"
## Почва и валежник с близкой камеры в настоящем мире.

const Floor := preload("res://scripts/render/forest_floor.gd")


func _initialize() -> void:
	super._initialize()
	worlds = [["Туман-4821", 256]]


func _place(game: GameWorld, v: Dictionary) -> void:
	if v.name == "spawn":
		views = []
		var w := game.world
		for entry in [["deciduous_floor", Biomes.T_OAK], ["conifer_floor", Biomes.T_PINE]]:
			var best := -1
			var score := -INF
			for o in w.obj_count:
				if w.obj_k[o] != entry[1] or w.obj_s[o] < 0.95:
					continue
				var x := w.obj_x[o]
				var y := w.obj_y[o]
				if x < 14 or y < 14 or x > w.W - 14 or y > w.H - 14:
					continue
				var k := floori(y) * w.W + floori(x)
				if w.slope[k] > 0.45:
					continue
				var value := StageVegetation.canopy_at(w, x, y) + w.moist[k] * 0.5 - absf(w.obj_s[o] - 1.2)
				if value > score:
					score = value
					best = o
			if best < 0:
				continue
			var x := w.obj_x[best] * GameConfig.TILE + 0.8
			var z := w.obj_y[best] * GameConfig.TILE + 0.8
			var target := Vector3(x, game.heights.ground_at(x, z) + 0.25, z)
			views.append({name = entry[0], pos = Dev._look_from(game.heights, target, 5.5, 1.8, 1.6), target = target})
			game.vegetation.update(x, z, true)
			var logs: Dictionary = game.vegetation.understory[Floor.FIRST + Floor.MOSS_LOG]
			if entry[1] == Biomes.T_PINE and logs.count > 0:
				var buf: PackedFloat32Array = logs.buf
				var log_target := Vector3(buf[3], buf[7] + 0.2, buf[11])
				views.append({name = "mossy_deadwood", pos = Dev._look_from(game.heights, log_target, 5.5, 1.8, 1.6), target = log_target})
		if views.is_empty():
			views = [v]
		v = views[0]
	super._place(game, v)
