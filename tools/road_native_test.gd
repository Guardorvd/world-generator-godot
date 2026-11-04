extends SceneTree
const F = preload("res://tools/trail_lab_fixture.gd")
var failures := 0
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	run.call_deferred()
func run() -> void:
	RoadRefinement.allow_fast_vertices = false
	var prepared := F.prepare(F.definitions())
	if not prepared.errors.is_empty(): push_error(str(prepared.errors)); quit(1); return
	var h: Heightfield = prepared.heights
	for i in h.world.N:
		h.hv[i] = 40.0 + (i % h.world.W) * 0.4 + sin(i * 0.03) * 2
		if i % 43 == 0: h.water_level[i] = h.hv[i] - 1
	h.world.world_origin = Vector2i(-71, 123)
	h.structures = [{ax = 40.0, az = 70.0, bx = 120.0, bz = 150.0}]
	for k in h.world.trails.size():
		var route: Dictionary = h.world.trails[k]
		route.kind = ["road", "trail", "mountain"][k % 3]
		for j in route.surf.size(): route.surf[j] = j % 7 + 1
	for fit in [false, true]:
		RoadRefinement.allow_fast_vertices = false
		var before := RoadRefinement.build(h, fit)
		for simd in [false, true]:
			RoadRefinement.allow_fast_vertices = true
			RoadRefinement.road_simd = simd
			var after := RoadRefinement.build(h, fit)
			var same := before.patches == after.patches
			print("ROAD fit=", fit, " simd=", simd, " same=", same, " before=", before.build_timings, " after=", after.build_timings)
			if not same:
				failures += 1
				var shown := 0
				for key: int in before.patches:
					for field: String in before.patches[key]:
						if before.patches[key][field] == after.patches[key][field]: continue
						for i in before.patches[key][field].size():
							if before.patches[key][field][i] != after.patches[key][field][i]:
								if shown < 5: print("DIFF ", key, " ", field, " ", i, " expected=", before.patches[key][field][i], " actual=", after.patches[key][field][i])
								if shown < 1 and field == "color":
									var a: Color = before.patches[key][field][i]
									var b: Color = after.patches[key][field][i]
									print("RGBA %.12f %.12f %.12f %.12f / %.12f %.12f %.12f %.12f" % [a.r,a.g,a.b,a.a,b.r,b.g,b.b,b.a])
								shown += 1
				print("mismatched values: ", shown)
	RoadRefinement.allow_fast_vertices = false
	var before_local := RoadRefinement.build(h, true, {0: true})
	RoadRefinement.allow_fast_vertices = true
	var after_local := RoadRefinement.build(h, true, {0: true})
	print("ROAD local same=", before_local.patches == after_local.patches)
	failures += int(before_local.patches != after_local.patches)
	RoadRefinement.allow_fast_vertices = true
	RoadRefinement.road_simd = true
	print("road_native: ", failures, " failures")
	quit(1 if failures else 0)
