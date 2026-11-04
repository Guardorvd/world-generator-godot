extends SceneTree
## Reach must agree with unlimited A*, including directed links and a blocked start.
var failures := 0

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	run.call_deferred()

func run() -> void:
	var rng := RandomNumberGenerator.new()
	for native in [false, true]:
		Grid.allow_fast = native
		rng.seed = 41291
		var finder := Pathfinder.new(6, 5)
		finder.use_corridor = false
		if native and finder.fast() == null:
			push_error("Native backend missing")
			failures += 1
		for trial in 1500:
			var costs := PackedFloat32Array()
			var heights := PackedFloat32Array()
			var links := PackedByteArray()
			for i in 30:
				costs.append(INF if rng.randf() < 0.35 else 1.0)
				heights.append(rng.randf_range(0.0, 2.0))
				links.append(rng.randi_range(0, 255))
			finder.heights = heights
			finder.links = links
			finder.window = Rect2i(1, 1, 4, 3) if trial % 2 else Rect2i()
			var s := rng.randi_range(0, 29)
			var t := rng.randi_range(0, 29)
			var grade := 0.9 if trial % 3 else INF
			var path := finder.find_path(costs, s, t, 0.0, grade)
			var reached := finder.can_reach(costs, s, t, 0.0, grade)
			if reached != not path.is_empty():
				failures += 1
				print("FAIL native=", native, " trial=", trial, " s=", s, " t=", t, " path=", path, " reach=", reached)
		finder.release()
	Grid.allow_fast = true
	print("grid_reach_regression: ", failures, " failures")
	quit(1 if failures else 0)
