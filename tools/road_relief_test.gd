extends SceneTree
const Fixture := preload("res://tools/road_relief_fixture.gd")
const OUT := "res://tools/control/runs/road_relief"
const LIMIT := 1.0 # m, largest change of one vertex by the corridor forms
var failures := 0
var profiles := []

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 600)
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ", label)
	if not ok: failures += 1

func build(h: Heightfield, enabled: bool) -> RoadRefinement:
	RoadRefinement.natural_relief = enabled
	return RoadRefinement.build(h)

func compare(w: WorldData, label: String, parity := false) -> void:
	var h := Heightfield.new(w, false)
	RoadBed.refine(h); h.build_structures()
	var before := build(h, false)
	var after := build(h, true)
	var original := before
	var baseline_path := OUT.path_join(label + "_before_patches.bin")
	if FileAccess.file_exists(baseline_path):
		original = RoadRefinement.from_patches(FileAccess.open(baseline_path, FileAccess.READ).get_var(), w.H)
	check(before.patches.size() == after.patches.size(), label + ": no extra patches")
	var peak := 0.0
	var original_peak := 0.0
	var wet := 0.0
	var outer_edge := 0.0
	for key: int in after.patches:
		var a: PackedFloat32Array = before.patches[key].h
		var b: PackedFloat32Array = after.patches[key].h
		for i in b.size():
			peak = maxf(peak, absf(b[i] - a[i]))
			original_peak = maxf(original_peak, absf(b[i] - original.patches[key].h[i]))
			var x := (key % w.W + 0.5) * GameConfig.TILE + (i % RoadRefinement.STRIDE) * RoadRefinement.STEP
			var z := (key / w.W + 0.5) * GameConfig.TILE + (i / RoadRefinement.STRIDE) * RoadRefinement.STEP
			var cell := clampi(floori(z / 4), 0, w.H - 1) * w.W + clampi(floori(x / 4), 0, w.W - 1)
			if h.water_level[cell] != -INF: wet = maxf(wet, absf(b[i] - a[i]))
			if x <= 2 or z <= 2 or x >= w.W * 4 - 2 or z >= w.H * 4 - 2: outer_edge = maxf(outer_edge, absf(b[i] - a[i]))
	# 14.11: формы коридора — подъём, сечение, продавленное место и обочина вместе; верх — с запасом к таблице CORRIDOR
	check(peak <= LIMIT and wet == 0.0, label + ": bounded displacement %.3f m; water unchanged" % peak)
	check(original_peak <= LIMIT + 0.2, label + ": change against the saved Git patches %.3f m" % original_peak)
	check(outer_edge == 0.0, label + ": no extra lip against the outer mesh")
	var grade := 0.0
	var pinned := 0.0
	var active := 0
	for route: int in after.corridor_routes:
		var span: Vector2i = after.corridor_routes[route]
		var kind: int = RoadRefinement.CORRIDOR_KINDS.find(w.trails[route].kind)
		var limit: float = RoadRefinement.CORRIDOR[RoadRefinement.CORRIDOR_KINDS[kind]][10]
		var fit: Dictionary = after.fit_routes.get(route, {})
		for j in span.y:
			var lift: float = after.corridor[(span.x + j) * RoadRefinement.CORRIDOR_STRIDE]
			active += int(absf(lift) > 0.01)
			if not fit.is_empty() and fit.strength[j] == 0.0: pinned = maxf(pinned, absf(lift))
			if j > 0: grade = maxf(grade, absf(lift - after.corridor[(span.x + j - 1) * RoadRefinement.CORRIDOR_STRIDE]) / RoadRefinement.STEP / limit)
	check(pinned < 0.02 and grade <= 1.000001, label + ": pins %.4f m, added grade %.3f of the limit" % [pinned, grade])
	var boundary := 0.0
	for key: int in after.patches:
		for z in RoadRefinement.STRIDE:
			for x in RoadRefinement.STRIDE:
				var cx := key % w.W; var cz := key / w.W
				var edge := (x == 0 and cx > 0 and not after.patches.has(key - 1)) or (x == 4 and cx < w.W - 2 and not after.patches.has(key + 1)) or (z == 0 and cz > 0 and not after.patches.has(key - w.W)) or (z == 4 and cz < w.H - 2 and not after.patches.has(key + w.W))
				if edge:
					var px := (cx + 0.5) * 4 + x; var pz := (cz + 0.5) * 4 + z
					boundary = maxf(boundary, absf(after.patches[key].h[z * 5 + x] - h.base_ground_at(px, pz)))
	check(boundary < 0.001, label + ": internal patch boundary %.6f m" % boundary)
	# Export the most changed real road/trail, including both wheel lines.
	var best := {}
	for route: int in after.fit_routes:
		var fit: Dictionary = after.fit_routes[route]
		var row := {label = label, kind = w.trails[route].kind, route = route, samples = [], peak = 0.0}
		for j in fit.points.size():
			var p: Vector2 = fit.points[j]
			var a := original.height_at(p.x, p.y, w.W)
			var b := after.height_at(p.x, p.y, w.W)
			if not is_finite(a) or not is_finite(b): continue
			row.peak = maxf(row.peak, absf(b - a))
			var tangent: Vector2 = (fit.points[mini(j + 2, fit.points.size() - 1)] - fit.points[maxi(0, j - 2)]).normalized()
			var normal := Vector2(-tangent.y, tangent.x) * 0.8
			row.samples.append([j * RoadRefinement.STEP, p.x, p.y, a, b, after.height_at(p.x + normal.x, p.y + normal.y, w.W), after.height_at(p.x - normal.x, p.y - normal.y, w.W)])
		if not best.has(row.kind) or row.peak > best[row.kind].peak: best[row.kind] = row
	for row: Dictionary in best.values(): profiles.append(row)
	print("RELIEF ", label, " peak_m=", peak, " active_stations=", active)
	if parity:
		RoadRefinement.allow_fast_patches = false
		var mixed := build(h, true)
		check(after.patches == mixed.patches, "native whole/batched vertices parity")
		RoadRefinement.allow_fast_nearest = false
		RoadRefinement.allow_fast_vertices = false
		var reference := build(h, true)
		check(after.patches == reference.patches, "native/GDScript vertex parity")
		check(after.fit_routes == reference.fit_routes, "native/GDScript profile fit parity")
		var same := after.corridor_routes.keys() == reference.corridor_routes.keys()
		for route: int in reference.corridor_routes:
			var a: Vector2i = after.corridor_routes.get(route, Vector2i.ZERO)
			var b: Vector2i = reference.corridor_routes[route]
			same = same and a.y == b.y and after.corridor.slice(a.x * 7, (a.x + a.y) * 7) == reference.corridor.slice(b.x * 7, (b.x + b.y) * 7)
		check(same, "native/GDScript corridor forms parity")
		RoadRefinement.allow_fast_patches = true; RoadRefinement.allow_fast_nearest = true; RoadRefinement.allow_fast_vertices = true
		check(after.patches == build(h, true).patches, "repeatable native bake")
		h.road_refinement = after
		for hz in [60, 120]:
			for lane in 3: ride(h, lane, hz)
		# Shaped authored courses (TrailShaping owns the tread) are byte-identical when the corridor forms are toggled;
		# an authored route without earthworks gets weaker natural forms.
		for route: Dictionary in w.trails:
			route.trail_id = "prepared"
			route.formation = Vector3(1.0, 0.0, 0.0)
		check(build(h, false).patches == build(h, true).patches, "shaped prepared tread is unchanged")
		for route: Dictionary in w.trails: route.formation = Vector3.ZERO
		var natural := build(h, true)
		var calm := 0.0
		var full := 0.0
		for key: int in natural.patches:
			for i in (natural.patches[key].h as PackedFloat32Array).size():
				calm = maxf(calm, absf(natural.patches[key].h[i] - before.patches[key].h[i]))
				full = maxf(full, absf(after.patches[key].h[i] - before.patches[key].h[i]))
		check(calm > 0.0 and calm < full, "prepared route without earthworks: weaker forms %.3f < %.3f m" % [calm, full])
		for route: Dictionary in w.trails:
			route.erase("trail_id")
			route.erase("formation")
		rebase()

func rebase() -> void:
	var a := Fixture.world()
	var b := Fixture.world(Vector2i(4, 0))
	for z in b.H:
		for x in b.W: b.h[z * b.W + x] = a.h[z * a.W + mini(x + 4, a.W - 1)]
	for route: Dictionary in b.trails:
		for p: Dictionary in route.pts: p.x -= 4.0
	var ha := Heightfield.new(a)
	var hb := Heightfield.new(b)
	var error := 0.0
	for lane in 3:
		for x in range(65, 330):
			var z := (16.5 + lane * 32) * 4
			error = maxf(error, absf(ha.ground_at(x, z) - hb.ground_at(x - 16, z)))
	check(error < 0.00001, "world-origin rebase has identical surface %.8f m" % error)
	junctions()

func junctions() -> void:
	# Include a 14 degree split: the old fitting mask only protected angles >26 degrees.
	for dz in [5.0, 20.0]:
		var w := Fixture.world()
		w.trails = [w.trails[1]]
		w.trails.append({kind = "trail", pts = [{x = 40.0, y = 48.5, w = 0.55}, {x = 60.0, y = 48.5 + dz, w = 0.55}], surf = PackedByteArray([RoadSurface.FOREST, RoadSurface.FOREST])})
		var h := Heightfield.new(w, false)
		RoadBed.refine(h); h.build_structures()
		var before := build(h, false)
		var after := build(h, true)
		var delta := 0.0
		for x in range(156, 165):
			delta = maxf(delta, absf(after.height_at(x, 194, w.W) - before.height_at(x, 194, w.W)))
		check(delta < 0.000001, "junction/fork dz %.0f: unchanged shared tread %.8f m" % [dz, delta])

func ride(h: Heightfield, lane: int, hz: int) -> void:
	var b := BikeRide.new()
	var p := PlayerState.new()
	var control := BikeController.new()
	b.x = 50.0; b.z = (16.5 + lane * 32) * 4; b.heading = -PI * 0.5
	b.y = h.ground_at(b.x, b.z); b.mount(p); b.speed = 10.0
	var air := 0
	var suspension := 0.0
	for tick in hz * 12:
		control.ride(1.0 / hz, p, b, h.world, h, 0.6, 0.0, false, false, false)
		air += int(b.airborne)
		suspension = maxf(suspension, maxf(absf(b.squash_f), absf(b.squash_r)))
		if b.crashed: break
	check(not b.crashed and air == 0 and b.x > 120 and is_finite(b.y), "ride lane %d @ %d Hz: %.1f m, air %d, suspension %.1f cm" % [lane, hz, b.x - 50, air, suspension * 100])

func run() -> void:
	check(Grid.fast_grid() != null, "native backend available")
	if failures: quit(1); return
	DirAccess.make_dir_recursive_absolute(OUT)
	compare(Fixture.world(), "isolated", true)
	if not "--synthetic-only" in OS.get_cmdline_user_args():
		for seed_text: String in ["Север-1234", "Туман-4821", "Ущелье"]:
			var path := OUT.path_join(seed_text + ".fixture.bin")
			var w: WorldData
			if FileAccess.file_exists(path): w = WorldCache.new()._restore(FileAccess.open(path, FileAccess.READ).get_var().world, true)
			else: w = WorldGenerator.generate(seed_text, 256)
			compare(w, seed_text)
	var name := "profiles_isolated.json" if "--synthetic-only" in OS.get_cmdline_user_args() else "profiles.json"
	FileAccess.open(OUT.path_join(name), FileAccess.WRITE).store_string(JSON.stringify(profiles))
	RoadRefinement.natural_relief = true
	print("ROAD RELIEF RESULT ", failures, " failures")
	quit(1 if failures else 0)
