extends SceneTree
## Доля проезжей земли круче порогов CLIFF_GRADE (20.11.2026) на сохранённых мирах road_relief, без генерации.
## Уклон — по базе велосипеда (±HUB) в направлении наибольшего спуска, по одной точке на клетку (со сдвигом).
##   godot --headless --path . --script res://tools/cliff_slope_probe.gd
const Snapshot := preload("res://scripts/game/surface_snapshot.gd")
const GRADES := [1.0, 1.2, 1.5, 2.0]

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 240)
	run.call_deferred()

func run() -> void:
	var hub := BikeRide.HUB
	for seed_text in ["Север-1234", "Туман-4821", "Ущелье"]:
		var saved: Dictionary = FileAccess.open("res://tools/control/runs/road_relief/%s.fixture.bin" % seed_text, FileAccess.READ).get_var()
		var w: WorldData = WorldCache.new()._restore(saved.world, true)
		var h: Heightfield = Snapshot.restore(w, saved.base, "base")
		var rng := RandomNumberGenerator.new()
		rng.seed = 7
		var land := [0, 0, 0, 0, 0]
		var path := [0, 0, 0, 0, 0]
		var maxg := 0.0
		for ty in w.H:
			for tx in w.W:
				var x := (tx + rng.randf()) * GameConfig.TILE
				var z := (ty + rng.randf()) * GameConfig.TILE
				if not h.known(x, z) or h.depth_at(x, z) > 0.05: continue
				var gx := (h.ground_at(x + hub, z) - h.ground_at(x - hub, z)) / (2.0 * hub)
				var gz := (h.ground_at(x, z + hub) - h.ground_at(x, z - hub)) / (2.0 * hub)
				var g := sqrt(gx * gx + gz * gz)
				maxg = maxf(maxg, g)
				var on_path: bool = w.civil.path_mask.data.size() == w.N and w.civil.path_mask.get_cell(tx, ty) > 0
				var bucket := path if on_path else land
				bucket[0] += 1
				for k in GRADES.size():
					if g > GRADES[k]: bucket[k + 1] += 1
		for pair in [["земля", land], ["пути", path]]:
			var b: Array = pair[1]
			var line := "%s %s: %d клеток" % [seed_text, pair[0], b[0]]
			for k in GRADES.size():
				line += ", >%.1f (%.0f°) %.3f%%" % [GRADES[k], rad_to_deg(atan(GRADES[k])), 100.0 * b[k + 1] / maxf(b[0], 1)]
			print(line)
		print("%s наибольший уклон %.2f" % [seed_text, maxg])
	quit(0)
