extends SceneTree
## Место старта (OpeningRoute.choose, 18.11.2026) без генерации мира: сохранённые миры tools/control/runs/road_relief/<сид>.fixture.bin
## (как roadside_probe). На каждом мире несколько сидов RNG: деревня, путь по прямой до неё, видна ли она, на дороге ли старт.
##   godot --headless --path . --script res://tools/opening_probe.gd -- [--seeds Север-1234,Туман-4821,Ущелье] [--tries 4]
## Миры фикстур старше ролей поселений (16.11): «удалённых» в них нет, проверяется запасной выбор — самые обособленные.

const OpeningRoute = preload("res://scripts/game/opening_route.gd")
var failures := 0


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 150)
	var seeds := PackedStringArray(["Север-1234", "Туман-4821", "Ущелье"])
	var tries := 4
	var args := OS.get_cmdline_user_args()
	for i in args.size() - 1:
		if args[i] == "--seeds": seeds = args[i + 1].split(",")
		if args[i] == "--tries": tries = int(args[i + 1])
	for seed_text in seeds:
		var path := "res://tools/control/runs/road_relief".path_join(seed_text + ".fixture.bin")
		if not FileAccess.file_exists(path):
			printerr("OPENING: нет фикстуры ", seed_text)
			failures += 1
			continue
		var saved: Dictionary = FileAccess.open(path, FileAccess.READ).get_var()
		var w: WorldData = WorldCache.new()._restore(saved.world, true)
		saved = {}
		var h := Heightfield.new(w)
		for t in tries:
			var rng := RandomNumberGenerator.new()
			rng.seed = 1000 + t
			var started := Time.get_ticks_usec()
			var spot := OpeningRoute.choose(w, h, rng)
			var ms := (Time.get_ticks_usec() - started) / 1000.0
			if spot.is_empty():
				print("%s #%d: пусто (%.0f мс)" % [seed_text, t, ms])
				failures += 1
				continue
			var at := Vector2(spot.position.x, spot.position.z)
			var place: Dictionary = spot.place
			var center := Vector2(place.x, place.y) * GameConfig.TILE
			var forward := Vector2(-sin(spot.heading), -cos(spot.heading))
			var facing := rad_to_deg(forward.angle_to(center - at))
			var eye := Vector3(at.x, h.ground_at(at.x, at.y) + 1.7, at.y)
			var seen := not OpeningRoute._occluded(h, eye, Vector3(center.x, h.ground_at(center.x, center.y) + 6.0, center.y))
			var cell := (at / GameConfig.TILE).floor()
			var on_path: bool = w.path_mask[int(cell.y) * w.W + int(cell.x)] >= 2
			print("%s #%d: %s «%s», по прямой %d м, курс на неё %+.0f°, видна %s, на пути %s, вступление %s (%.0f мс)" % [
				seed_text, t, place.kind, place.name, roundi(at.distance_to(center)), facing, seen, on_path, spot.cinematic, ms])
			if place.kind != "settlement" or not on_path:
				failures += 1
	print("OPENING DONE failures=", failures)
	quit(1 if failures else 0)
