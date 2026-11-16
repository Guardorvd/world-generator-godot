extends SceneTree
const Fixture := preload("res://tools/trail_world_network_test.gd")
var failures := 0

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 90)
	run.call_deferred()

func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	failures += int(not ok)

func run() -> void:
	var w := Fixture.synthetic()
	var roads: Array[TrailDefinition] = []
	for x in range(16, 180, 16):
		var d := TrailDefinition.new()
		d.id = "source_%d" % x
		d.kind = "road" if x % 32 == 0 else "trail"
		d.points = PackedVector2Array([Vector2(x * 4, 36), Vector2(x * 4, 720)])
		roads.append(d)
	check(TrailBuilder.append_routes(w, roads).is_empty(), "source roads are valid")
	var h := w.base_heights.copy()
	h.finish_paths()
	var cut := TrailSite.cut(w, h, Rect2i(12, 12, 168, 168), 12)
	check(cut.errors.is_empty(), "prepared source can be cut")
	if not cut.errors.is_empty(): quit(1); return
	var site: TrailSite = cut.site
	var original := var_to_bytes([site.hv, site.patches])
	for kind in ["mountain", "trail", "road"]:
		var d := TrailDefinition.new()
		d.id = "local_" + kind
		d.kind = kind
		d.points = PackedVector2Array([Vector2(240, 640), Vector2(280, 520), Vector2(260, 400)])
		var start := Time.get_ticks_usec()
		var first := site.prepare([d], false)
		var first_ms := (Time.get_ticks_usec() - start) / 1000.0
		start = Time.get_ticks_usec()
		var second := site.prepare([d], false)
		var second_ms := (Time.get_ticks_usec() - start) / 1000.0
		check(first.errors.is_empty() and second.errors.is_empty(), kind + ": both builds complete")
		check(Fixture.same_surface(first.heights, second.heights), kind + ": every patch, edge, material and height matches the repeat")
		print("LOCAL INDEX ", JSON.stringify({kind = kind, first_ms = first_ms, second_ms = second_ms, timings = second.heights.path_timings}))
	check(original == var_to_bytes([site.hv, site.patches]), "preparation leaves shared source patches unchanged")
	print("LOCAL INDEX RESULT ", failures, " failures")
	quit(1 if failures else 0)
