extends SceneTree
var fails := 0
func check(ok: bool, label: String) -> void:
	print("OK " if ok else "FAIL ", label)
	fails += int(not ok)
func world() -> WorldData:
	var w := WorldData.new()
	w.W = 64
	w.H = 64
	w.N = w.W * w.H
	w.seed_num = 44
	for key: String in ["h", "filled", "slope", "dist_water", "temp", "moist", "elev"]:
		var a := PackedFloat32Array()
		a.resize(w.N)
		w.set(key, a)
	w.dist_water.fill(100.0)
	for key: String in ["ocean", "lake", "river", "path_mask", "biome"]:
		var a := PackedByteArray()
		a.resize(w.N)
		w.set(key, a)
	w.biome.fill(Biomes.GRASS)
	for y in w.H:
		for x in w.W: w.h[y * w.W + x] = (40.0 + y * 0.8 + sin(x * 0.5) * 1.5) / GameConfig.HS
	return w
func route(a: Vector2, b: Vector2, kind := "road", width_a := 0.9, width_b := 0.9) -> Dictionary:
	return {kind = kind, pts = [{x = a.x, y = a.y, w = width_a}, {x = b.x, y = b.y, w = width_b}], surf = PackedByteArray([1, 1])}
func parity_check() -> void:
	var w := world()
	w.trails = [route(Vector2(0.5, 32.5), Vector2(63.5, 32.5)), route(Vector2(32.5, 0.5), Vector2(32.5, 63.5))]
	var h := Heightfield.new(w, false)
	RoadRefinement.allow_fast_vertices = false
	var reference := RoadRefinement.build(h)
	RoadRefinement.allow_fast_vertices = true
	var native := RoadRefinement.build(h)
	var error := 0.0
	for key: int in reference.patches:
		for j in reference.patches[key].h.size():
			error = maxf(error, absf(reference.patches[key].h[j] - native.patches[key].h[j]))
	print("EDGE parity max error ", error)
	check(reference.patches == native.patches, "native patches match reference, including all four map edges")
func width_check() -> void:
	var w := world()
	w.trails = [route(Vector2(8.5, 32.5), Vector2(55.5, 32.5), "road", 0.2, 2.5)]
	var h := Heightfield.new(w, false)
	# A uniform cross-slope makes the required cut depend on station width alone.
	for y in w.H:
		for x in w.W: h.hv[y * w.W + x] = 40.0 + y * 3.2
	var reference := {}
	for fast: bool in [false, true]:
		RoadRefinement.allow_fast_vertices = fast
		var r := RoadRefinement.build(h)
		if not fast: reference = r.patches
		else: check(r.patches == reference, "variable-width refinement has exact backend parity")
		var limits: PackedFloat32Array = r.fit_routes[0].limit
		check(limits[limits.size() - 20] > limits[20] * 1.5, "bench cap follows widening route (native=%s)" % fast)
func bed_width_check() -> void:
	var w := world()
	w.trails = [route(Vector2(8.5, 32.5), Vector2(55.5, 32.5), "road", 0.2, 2.5)]
	Grid.allow_fast = false
	var reference := Heightfield.new(w, false)
	RoadBed.refine(reference)
	Grid.allow_fast = true
	var native := Heightfield.new(w, false)
	RoadBed.refine(native)
	check(reference.hv == native.hv, "variable-width RoadBed has exact backend parity")

func anchor_check() -> void:
	var w := world()
	var h := Heightfield.new(w, false)
	for y in w.H:
		h.hv[y * w.W + 31] += 8.0
		h.hv[y * w.W + 32] += 8.0
	var d := TrailDefinition.new()
	d.id = "anchor"
	d.points = PackedVector2Array([Vector2(40, 130), Vector2(216, 130)])
	d.width = 3
	var shaping := TrailShaping.preset("road")
	var anchor := Vector2(128, 130)
	var p := shaping.profile(h, d, func(at: Vector2) -> float: return 0.0 if at.distance_to(anchor) < 0.1 else 1.0)
	var j := roundi(88.0 / p.total * (p.levels.size() - 1))
	var error := absf(p.levels[j] - h.ground_at(anchor.x, anchor.y))
	print("ANCHOR error ", error)
	check(error < 0.00001, "internal anchor stays at the actual ground after final smoothing")
func mountain_check() -> void:
	var w := world()
	w.trails = [route(Vector2(8.5, 32.5), Vector2(55.5, 32.5), "mountain", 0.42, 0.42)]
	w.settlements.append(SettlementData.from_dict({x = 32.5, y = 32.5, i = 32 * w.W + 32, huts = []}))
	var h := Heightfield.new(w, false)
	for fast: bool in [false, true]:
		RoadRefinement.allow_fast_vertices = fast
		var r := RoadRefinement.build(h)
		var error := 0.0
		for x in range(125, 136): error = maxf(error, absf(r.sample(x, 130, w.W).h - h.base_ground_at(x, 130)))
		print("MOUNTAIN protected error ", error)
		check(error < 0.00001, "mountain base shaping respects settlement protection (native=%s)" % fast)
func overlap_probe(gap := 4.0, road_half := 1.8, trail_half := 1.1) -> void:
	var w := world()
	w.trails = [route(Vector2(8.5, 31.5), Vector2(55.5, 31.5), "road", road_half * 0.5, road_half * 0.5), route(Vector2(8.5, 31.5 + gap / 4.0), Vector2(55.5, 31.5 + gap / 4.0), "trail", trail_half * 0.5, trail_half * 0.5)]
	var h := Heightfield.new(w, false)
	RoadRefinement.allow_fast_vertices = false
	var r := RoadRefinement.new()
	r._heights = h
	r._height = w.H
	r._dist_water = w.dist_water
	r._noise = FastNoiseLite.new()
	r._noise.seed = w.seed_num
	r._noise.frequency = 1.0
	r._noise.fractal_octaves = 2
	for index in w.trails.size(): r._index(w.trails[index], index)
	r._fit_network()
	# Evaluate the continuous formulas, rather than interpreting metre triangle edges as discontinuities.
	var worst := 0.0
	var boundary := 126.0 + (gap / trail_half + 0.08) / (1.0 / road_half + 1.0 / trail_half)
	for x in range(70, 180):
		var a := r._vertex(x, boundary - 0.0001)
		var b := r._vertex(x, boundary + 0.0001)
		if a.route != b.route: worst = maxf(worst, absf(a.h - b.h))
	print("OVERLAP switch height ", worst)
	check(worst < 0.01, "parallel tread selection has no height jump at equal rank")
	r._heights = null
func wheel_check() -> void:
	var w := world()
	var h := Heightfield.new(w, false)
	var patches := {}
	for cz in range(30, 35):
		for cx in range(30, 35):
			var hs := PackedFloat32Array()
			var color := PackedColorArray()
			var uv := PackedVector2Array()
			var surface := PackedByteArray()
			var road := PackedByteArray()
			for iz in RoadRefinement.STRIDE:
				for ix in RoadRefinement.STRIDE:
					var x := (cx + 0.5) * 4 + ix
					var z := (cz + 0.5) * 4 + iz
					var surf := 4 if z < 130 else 3
					hs.append(40 + x * 0.4)
					color.append(Color(1, 1, 1, 1))
					uv.append(Vector2((z - 130) * 0.2, surf))
					surface.append(surf)
					road.append(1)
			patches[cz * w.W + cx] = {h = hs, color = color, uv = uv, surface = surface, road = road}
	h.road_refinement = RoadRefinement.from_patches(patches, w.H)
	var bike := BikeRide.new()
	bike.x = 130
	bike.z = 130
	bike.y = 92
	bike.heading = 0
	var center := h.path_contact(bike.x, bike.z)
	bike._step_wheels(h, 0.0, 0.01, center.surface, 1.0, 0.0, center.across)
	var correct := true
	for front: bool in [true, false]:
		var z := bike.z + (-bike.HUB if front else bike.HUB)
		var c := h.path_contact(bike.x, z)
		var expected := RoadBump.height_params(bike.x, z, c.bump, 0.4, c.across)
		var actual: float = (bike.ground_f if front else bike.ground_r) + bike.y - bike._wheel_ground(bike.x, z, h)
		correct = correct and absf(c.grade - 0.4) < 0.0001 and absf(actual - expected) < 0.00001
	check(correct, "each wheel uses its own surface/rut and full terrain grade on a traverse")
	var contact := h.path_contact(130.0, 129.5)
	var expected_params := (RoadBump.LIST[4] + RoadBump.LIST[3]) * 0.5
	check(contact.bump.is_equal_approx(expected_params), "microterrain interpolates material parameters like the shader, retaining discrete grip category")
	var sampled := bike._wheel_road(h, 130, 129.5, RoadSurface.NONE, 0.0, 0.0, 0.0)
	check(absf(sampled.x - RoadBump.height_params(130, 129.5, expected_params, contact.grade, contact.across)) < 0.000001,
		"wheel microheight uses the interpolated material, not the nearest vertex category")


func coarse_seam_error(h: Heightfield) -> float:
	var pinned := h.road_refinement.patches.duplicate()
	RoadRefinement.pin_coarse_edges(h, pinned, pinned.keys())
	var error := 0.0
	for key: int in pinned:
		for j in pinned[key].h.size(): error = maxf(error, absf(pinned[key].h[j] - h.road_refinement.patches[key].h[j]))
	return error
func bake_seam_check() -> void:
	var w := world()
	var d := TrailDefinition.new()
	d.id = "bake_seam"
	d.points = PackedVector2Array([Vector2(64, 80), Vector2(192, 160)])
	d.width = 3
	d.shaping = TrailShaping.preset("mountain")
	d.earthwork = 1
	d.elements = [TrailElementLibrary.make(TrailElement.Profile.TABLETOP, 60, 18, 1.2)]
	check(TrailBuilder.append_routes(w, [d] as Array[TrailDefinition]).is_empty(), "seam control route accepted")
	var h := Heightfield.new(w)
	var limits := {keep_bake = true}
	check(TrailBuilder.bake_elements(h, [d] as Array[TrailDefinition], limits).is_empty(), "element bake succeeds")
	var error := coarse_seam_error(h)
	print("BAKE seam error ", error)
	check(error < 0.00001, "element bake keeps coarse boundaries without an extra pinning pass")
	var removed: Array[TrailElement] = [d.elements[0]]
	d.elements = []
	check(TrailBuilder.bake_without(h, d, removed, limits).is_empty(), "partial element removal succeeds")
	check(coarse_seam_error(h) < 0.00001, "partial rebake also keeps coarse boundaries")

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	check(Grid.fast_grid() != null, "native backend available")
	parity_check()
	width_check()
	bed_width_check()
	anchor_check()
	mountain_check()
	overlap_probe()
	overlap_probe(8.0, 5.0, 0.5)
	wheel_check()
	bake_seam_check()
	RoadRefinement.allow_fast_vertices = true
	print("FAILURES ", fails)
	quit(1 if fails else 0)
