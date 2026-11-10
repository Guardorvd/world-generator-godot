extends SceneTree
const Fixture := preload("res://tools/road_relief_fixture.gd")
const FORM_STRIDE := RoadRefinement.CORRIDOR_STRIDE
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

func surface_at(r: RoadRefinement, h: Heightfield, x: float, z: float) -> float:
	var y := r.height_at(x, z, h.world.W)
	return y if is_finite(y) else h.base_ground_at(x, z)

func compare(w: WorldData, label: String, parity := false) -> void:
	var h := Heightfield.new(w, false)
	RoadBed.refine(h); h.build_structures()
	var before := build(h, false)
	var after := build(h, true)
	var original := before
	var baseline_path := OUT.path_join(label + "_before_patches.bin")
	if FileAccess.file_exists(baseline_path):
		original = RoadRefinement.from_patches(FileAccess.open(baseline_path, FileAccess.READ).get_var(), w.H)
	var peak := 0.0
	var original_peak := 0.0
	var wet := 0.0
	var outer_edge := 0.0
	for key: int in after.patches:
		var b: PackedFloat32Array = after.patches[key].h
		for i in b.size():
			var x := (key % w.W + 0.5) * GameConfig.TILE + (i % RoadRefinement.STRIDE) * RoadRefinement.STEP
			var z := (key / w.W + 0.5) * GameConfig.TILE + (i / RoadRefinement.STRIDE) * RoadRefinement.STEP
			var base := h.base_ground_at(x, z)
			var a: float = before.patches[key].h[i] if before.patches.has(key) else base
			var old: float = original.patches[key].h[i] if original.patches.has(key) else base
			peak = maxf(peak, absf(b[i] - a))
			original_peak = maxf(original_peak, absf(b[i] - old))
			var cell := clampi(floori(z / 4), 0, w.H - 1) * w.W + clampi(floori(x / 4), 0, w.W - 1)
			if h.water_level[cell] != -INF: wet = maxf(wet, absf(b[i] - a))
			if x <= 2 or z <= 2 or x >= w.W * 4 - 2 or z >= w.H * 4 - 2: outer_edge = maxf(outer_edge, absf(b[i] - a))
	# 14.11: формы коридора — подъём, сечение, продавленное место и обочина вместе; верх — с запасом к таблице CORRIDOR
	check(peak <= LIMIT and wet < 0.0001, label + ": bounded displacement %.3f m; water unchanged" % peak)
	check(original_peak <= LIMIT + 0.2, label + ": change against the saved Git patches %.3f m" % original_peak)
	check(outer_edge < 0.0001, label + ": no extra lip against the outer mesh")
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
			same = same and a.y == b.y and after.corridor.slice(a.x * FORM_STRIDE, (a.x + a.y) * FORM_STRIDE) == reference.corridor.slice(b.x * FORM_STRIDE, (b.x + b.y) * FORM_STRIDE)
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
				# Authored masks may retain a patch that the natural sparse surface omitted.
				var x := (key % w.W + 0.5) * GameConfig.TILE + (i % RoadRefinement.STRIDE) * RoadRefinement.STEP
				var z := (key / w.W + 0.5) * GameConfig.TILE + (i / RoadRefinement.STRIDE) * RoadRefinement.STEP
				var base := surface_at(before, h, x, z)
				calm = maxf(calm, absf(natural.patches[key].h[i] - base))
				full = maxf(full, absf(surface_at(after, h, x, z) - base))
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
	corridor_contracts()
	terrain_profile_contracts()
	patch_contracts()
	if "--contracts-only" in OS.get_cmdline_user_args():
		print("ROAD RELIEF RESULT ", failures, " failures")
		quit(1 if failures else 0)
		return
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


func terrain_profile_contracts() -> void:
	var w := Fixture.world()
	var h := Heightfield.new(w, false)
	RoadBed.refine(h)
	var r := build(h, true)
	var span: Vector2i = r.corridor_routes[0]
	var crest := 103 # x = 135, raw natural knoll
	var hollow := 193 # x = 225, raw natural depression
	check(r.corridor[(span.x + crest) * FORM_STRIDE] > 0.05 and r.corridor[(span.x + hollow) * FORM_STRIDE] < -0.05,
		"corridor follows the real raw-terrain crest and drainage hollow")
	var fit: Dictionary = r.fit_routes[0]
	var error := 0.0
	for j in fit.points.size():
		var p: Vector2 = fit.points[j]
		error = maxf(error, absf(fit.profile[j] - h.base_ground_at(p.x, p.y)))
	check(error < 0.00001, "ordinary roads preserve RoadBed's axial profile instead of smoothing it twice")


func patch_contracts() -> void:
	var w := Fixture.world()
	var h := Heightfield.new(w, false)
	h.finish_paths()
	var cut := TrailSite.cut(w, h, Rect2i(16, 32, 48, 40), 8)
	check(cut.errors.is_empty(), "prepared road can be cut for a crossing")
	if not cut.errors.is_empty(): return
	var site: TrailSite = cut.site
	var line := TrailDefinition.new()
	line.id = "crossing"
	line.kind = "mountain"
	line.width = 3.0
	line.earthwork = 0.0
	line.points = PackedVector2Array([Vector2(120, 150) - site.origin_m(), Vector2(120, 238) - site.origin_m()])
	var formed := site.prepare([line], false)
	check(formed.errors.is_empty(), "crossing forms on the saved site")
	if formed.errors.is_empty():
		var result: Heightfield = formed.heights
		var stable := true
		for key: int in site.patches:
			stable = stable and result.road_refinement.patches[key].h == site.patches[key].h
		check(stable, "new trail preserves every height of the existing road before earthworks")
		var only := {result.world.trails.size() - 1: true}
		var local := RoadRefinement.build(result, true, only)
		check(local._reach == RoadRefinement.NATURAL_REACH, "natural trail indexes the full corridor")
	var isolated := PackedFloat32Array()
	isolated.resize(RoadRefinement.STRIDE * RoadRefinement.STRIDE)
	isolated.fill(42.0)
	var key := 10 * w.W + 10
	var patches := {key: {h = isolated}}
	RoadRefinement.pin_coarse_edges(h, patches, [key])
	check(patches[key].h[0] == h.hv[key] and is_equal_approx(patches[key].h[2], lerpf(h.hv[key], h.hv[key + 1], 0.5))
		and patches[key].h[12] == 42.0, "patch perimeter follows the adjacent coarse mesh")
	w.outer = OuterLand.new()
	var chunk := Rect2i(10, 14, 20, 8)
	var native := TerrainBuilder.build_arrays(w, h, chunk)
	TerrainBuilder.allow_fast_refine = false
	check(native == TerrainBuilder.build_arrays(w, h, chunk), "native interior rebuild matches the reference with OuterLand attached")
	TerrainBuilder.allow_fast_refine = true
	w.outer = null
	line.id = "deep_fill"
	line.earthwork = 1.0
	line.elevation_offset = 2.0
	line.shaping = TrailShaping.preset("mountain")
	line.shaping.batter = 0.2
	line.points = PackedVector2Array([Vector2(9, 40), Vector2(9, 120)])
	var appended := TrailBuilder.append_routes(w, [line])
	check(appended.is_empty(), "near-edge tread itself fits")
	if appended.is_empty():
		check("Trail earthworks outside prepared region: deep_fill" in TrailBuilder.bake_elements(h, [line]),
			"earthworks extending past prepared terrain are rejected")


func corridor_contracts() -> void:
	# A side slope exercises the natural component of tilt, absent from the flat ride fixture.
	var w := Fixture.world()
	w.trails = [w.trails[2]]
	w.trails[0].kind = "mountain"
	for z in w.H:
		for x in w.W:
			w.h[z * w.W + x] += (z + 0.5) * GameConfig.TILE * 0.12 / GameConfig.HS
	var h := Heightfield.new(w, false)
	var full := build(h, true)
	check(full.corridor_routes.has(0) and full.fit_routes.is_empty(), "mountain corridor without profile fitting")
	w.trails[0].trail_id = "natural"
	w.trails[0].formation = Vector3.ZERO
	var prepared := build(h, true)
	var natural_local := RoadRefinement.build(h, true, {0: true})
	w.trails[0].formation = Vector3(1.0, 0.0, 0.0)
	var authored_local := RoadRefinement.build(h, true, {0: true})
	w.trails[0].formation = Vector3.ZERO
	check(authored_local._reach == RoadRefinement.REACH and natural_local._reach == RoadRefinement.NATURAL_REACH,
		"local index covers natural forms and keeps the narrower authored tread")
	var a: Vector2i = full.corridor_routes[0]
	var b: Vector2i = prepared.corridor_routes[0]
	var error := 0.0
	for j in a.y:
		error = maxf(error, absf(prepared.corridor[(b.x + j) * FORM_STRIDE + 1] - full.corridor[(a.x + j) * FORM_STRIDE + 1] * RoadRefinement.PREPARED_SCALE))
	check(error < 0.0000001, "prepared cross-slope scales with all other forms: %.8f m" % error)
	RoadRefinement.allow_fast_patches = false
	RoadRefinement.allow_fast_nearest = false
	RoadRefinement.allow_fast_vertices = false
	var reference := build(h, true)
	check(prepared.patches == reference.patches and prepared.corridor == reference.corridor, "sloped mountain native/reference parity")
	RoadRefinement.allow_fast_patches = true
	RoadRefinement.allow_fast_nearest = true
	RoadRefinement.allow_fast_vertices = true
	# Coincident routes must keep their forms, including when one route runs in reverse.
	w.trails[0].erase("trail_id")
	w.trails[0].erase("formation")
	var duplicate: Dictionary = w.trails[0].duplicate(true)
	duplicate.pts.reverse()
	duplicate.surf.reverse()
	w.trails.append(duplicate)
	var duplicated := build(h, true)
	var physical_error := 0.0
	var same_channels := full.patches.size() == duplicated.patches.size()
	for key: int in full.patches:
		if not duplicated.patches.has(key):
			same_channels = false
			continue
		var original: Dictionary = full.patches[key]
		var repeated: Dictionary = duplicated.patches[key]
		same_channels = same_channels and original.surface == repeated.surface and original.road == repeated.road
		for j in (original.h as PackedFloat32Array).size():
			physical_error = maxf(physical_error, absf(original.h[j] - repeated.h[j]))
			# Signed UV.x follows route direction; reversing the selected segment can
			# flip it without changing the tread. Compare its magnitude and material.
			same_channels = same_channels and absf(absf(original.uv[j].x) - absf(repeated.uv[j].x)) < 0.00001 \
				and original.uv[j].y == repeated.uv[j].y and original.color[j].is_equal_approx(repeated.color[j])
	check(same_channels and physical_error < 0.00001, "reversed duplicate preserves the physical mountain surface: %.8f m" % physical_error)
	var base := build(h, false)
	var far_change := 0.0
	var parallel: Dictionary = w.trails[0].duplicate(true)
	for point: Dictionary in parallel.pts:
		point.y += 1.5 # 6 m between axes, 3.8 m between the treads
	for j in range(40, 330):
		var z: float = w.trails[0].pts[0].y * GameConfig.TILE - 4.6
		far_change = maxf(far_change, absf(surface_at(full, h, j, z) - surface_at(base, h, j, z)))
	check(far_change > 0.05, "land shape reaches beyond the old shoulder: %.3f m" % far_change)
	w.trails[1] = parallel
	var separate := build(h, true)
	var changed := false
	var wide := false
	for j in range(15, a.y - 15):
		changed = changed or absf(separate.corridor[j * FORM_STRIDE]) > 0.05
		wide = wide or separate.corridor[j * FORM_STRIDE + 7] > 0.0
	check(changed and not wide, "parallel treads retain core forms with wide terrain excluded")
	# A strict configured grade limit must reduce peaks, never move a protected zero.
	var r := RoadRefinement.new()
	r._heights = h
	r._noise = FastNoiseLite.new()
	r._noise.seed = w.seed_num
	r._noise.frequency = 1.0
	r._noise.fractal_octaves = 2
	var points := PackedVector2Array()
	var halves := PackedFloat32Array()
	var surfaces := PackedInt32Array()
	var gates := PackedFloat32Array()
	for j in 160:
		points.append(Vector2(50 + j, 100))
		halves.append(1.1)
		surfaces.append(RoadSurface.FOREST)
		gates.append(0.0 if j == 80 else 1.0)
	var table := PackedFloat64Array()
	for kind: String in RoadRefinement.CORRIDOR_KINDS:
		table.append_array(PackedFloat64Array(RoadRefinement.CORRIDOR[kind]))
	table.append_array(PackedFloat64Array(RoadRefinement.CORRIDOR_SURFACE))
	table[10] = 0.001
	var forms := r._corridor_reference(points, halves, surfaces, gates, PackedInt32Array([0, 160]), PackedInt32Array([0]),
		PackedFloat32Array([1.0]), PackedInt32Array([0]), table)
	var pinned := maxf(absf(forms[0]), maxf(absf(forms[80 * FORM_STRIDE]), absf(forms[159 * FORM_STRIDE])))
	var grade := 0.0
	for j in range(1, 160): grade = maxf(grade, absf(forms[j * FORM_STRIDE] - forms[(j - 1) * FORM_STRIDE]))
	check(pinned == 0.0 and grade <= table[10] + 0.0000001, "grade limiter preserves exact protected zeros: %.8f m" % pinned)
