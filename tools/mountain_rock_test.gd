extends "res://tools/mountain_rock_look.gd"
## Isolated integration regressions: production poses/collisions, cropped fields, plants and streaming.

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	run.call_deferred()

func record(st: StageVegetation.ObjStore) -> PackedByteArray:
	return var_to_bytes([st.x, st.y, st.k, st.v, st.s])

func cropped(f: Dictionary, rect: Rect2i) -> Dictionary:
	var out := {}
	for name: String in f:
		var values: Variant = f[name].slice(0, 0)
		for y in range(rect.position.y, rect.end.y):
			values.append_array(f[name].slice(y * N + rect.position.x, y * N + rect.end.x))
		out[name] = values
	return out

func patch_scatter(f: Dictionary, rect: Rect2i, pad := -1) -> StageVegetation.ObjStore:
	var st := StageVegetation.ObjStore.new(null)
	st.begin_chunk(rect.position.x, rect.position.y, rect.end.x, rect.end.y)
	if pad < 0:
		RockScatter.place_chunk(29, rect.position.x, rect.position.y, rect.end.x, rect.end.y, f, 0, 0, N, st)
	else:
		var box := rect.grow(pad)
		RockScatter.place_chunk(29, rect.position.x, rect.position.y, rect.end.x, rect.end.y, cropped(f, box), box.position.x, box.position.y, box.size.x, st)
	return st

func run() -> void:
	massif_contracts()
	if "--massif-contracts-only" in OS.get_cmdline_user_args():
		print("MOUNTAIN ROCK REVIEW ", failures, " failures")
		quit(1 if failures else 0)
		return
	var hv := relief()
	var f := fields(hv)
	var old_halo_mismatches := 0
	for y in [32, 48, 64, 80, 96, 112]:
		for x in [32, 48, 64, 80, 96, 112]:
			var rect := Rect2i(x, y, 16, 16)
			var full := record(patch_scatter(f, rect))
			check(full == record(patch_scatter(f, rect, RockScatter.FIELD_HALO)), "full/cropped scatter agrees at %s" % rect.position)
			old_halo_mismatches += int(full != record(patch_scatter(f, rect, 2)))
	check(old_halo_mismatches > 0, "fixture exposes the old two-cell halo truncation (%d chunks)" % old_halo_mismatches)
	var st := scatter(RockScatter, f)
	var w := world_of(st, f)
	var h := Heightfield.new()
	h.world = w; h.hv = hv
	var defs := Models.tree_defs()
	var layer := VegetationLayer.new()
	layer.world = w; layer.heights = h
	for model: int in defs:
		if model % ForestModels.MODEL_STRIDE == Biomes.T_ROCK:
			layer._defs[model] = {crown = defs[model].crown, box = defs[model].crown.get_aabb(), leaves = defs[model].leaves}
	var checked := 0
	for o in st.x.size():
		if not RockModels.is_outcrop(st.v[o]): continue
		var x: float = st.x[o] * 4.0; var z: float = st.y[o] * 4.0
		var scale: float = st.s[o] * 1.2
		var seat := RockModels.seat(h, x, z, scale, st.v[o])
		if seat.x == INF: continue
		var up := Vector3(seat.y, seat.z, seat.w)
		var xf := RockModels.outcrop_transform(x, z, scale, up, seat.x, Vector2.ZERO, st.v[o])
		var raw := hv.duplicate()
		for i in raw.size(): raw[i] /= GameConfig.HS
		var snapshot := {h = raw, water = PackedFloat32Array(), path = w.path_mask, x0 = 0, y0 = 0, side = N}
		check(RockModels.seat_snapshot_any(snapshot, PackedFloat32Array(), 0, 0, x, z, scale, st.v[o]) == seat, "live and immutable-snapshot seating agree")
		var form := RockModels.form_of(st.v[o], x, z)
		var model: Mesh = defs[VegetationLayer.OUTCROP_MODEL + form * ForestModels.MODEL_STRIDE].crown
		var exposed := 0
		for point: Vector3 in model.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]:
			var p := xf * point
			exposed += int(p.y - h.ground_at(p.x, p.z) > scale * 0.15)
		check(exposed > 4, "the actual baked model protrudes above the slope")
		var expected := RockModels.outcrop_solids(xf, form)
		for at in range(0, expected.size(), 7):
			check(expected[at + 5] <= xf.origin.y + 0.0001, "upper plates use the whole rock foundation for wheel climb limits")
		var obstacles := ForestObstacles.new(w, h)
		obstacles.update(x, z, PackedFloat32Array(), 0, true)
		var matched := 0
		for at in range(0, expected.size(), 7):
			for p in range(0, obstacles.data.size(), 7):
				if expected.slice(at, at + 7) == obstacles.data.slice(p, p + 7): matched += 1; break
		check(matched == expected.size() / 7, "every visible block has the matching tilted collision core")
		var outer_world := WorldData.new()
		var outer_obstacles := ForestObstacles.new(outer_world, h)
		var out := {data = PackedFloat32Array(), grid = {}}
		var items := {x = PackedFloat64Array([x / 4]), y = PackedFloat64Array([z / 4]), k = PackedInt32Array([Biomes.T_ROCK]), v = PackedInt32Array([st.v[o]]), s = PackedFloat64Array([st.s[o]]), ground = PackedFloat32Array([seat.x]), normals = PackedVector3Array([up])}
		outer_obstacles._add_objects(out, x, z, {Vector2i.ZERO: items})
		check(out.data == expected, "plan and streamed collision are identical")
		var probe := {x = items.x, y = items.y, k = items.k, v = items.v, s = items.s, ground = items.ground, normals = items.normals}
		var built := layer._build_entries(probe)
		var expected_buffer := PackedFloat32Array(); expected_buffer.resize(12)
		VegetationLayer._put_transform(expected_buffer, 0, xf)
		check(built.entries[0].cbuf.slice(0, 12) == expected_buffer, "renderer uses the same transform as collision and seating")
		# The same physical point copied into a local site keeps its form and orientation.
		var shift := Vector2(12, -20)
		var rebased := RockModels.outcrop_transform(x - shift.x, z - shift.y, scale, up, seat.x, shift, st.v[o])
		check(rebased.basis == xf.basis and RockModels.form_of(st.v[o], x - shift.x, z - shift.y, shift) == form, "saved-site origin preserves geological form and orientation")
		checked += 1
		if checked == 4: break
	check(checked == 4, "four distinct seated outcrops examined")
	var flooded := RockModels.outcrop_seat(func(_x: float, _z: float) -> Vector2: return Vector2(20, 0.1), 100, 100, 1.0)
	check(flooded.x == INF, "water rejects the entire outcrop footprint")
	var wet_edge := RockModels.outcrop_seat(func(x: float, _z: float) -> Vector2: return Vector2(20, 0.1 if x > 101 else 0), 100, 100, 1.0)
	check(wet_edge.x == INF, "a dry centre cannot put an outcrop across a wet edge")
	plants(w)
	if "--bench" in OS.get_cmdline_user_args(): outer_cost()
	layer.free()
	print("MOUNTAIN ROCK REVIEW ", failures, " failures")
	quit(1 if failures else 0)


func massif_contracts() -> void:
	var store := StageVegetation.ObjStore.new(null)
	store.begin_chunk(0, 0, 16, 16)
	store.add(8.9, 8.0, Biomes.T_OAK, 0, 1.8)
	store.add(8.0, 8.0, Biomes.T_ROCK, RockModels.massif_v(RockModels.M_BLOCKS, 0, 0), 0.72)
	check(store.x.size() == 2, "accepted massif survives a neighbouring tree's crown spacing")
	var snapshot := {h = PackedFloat32Array(), water = PackedFloat32Array(), path = PackedByteArray(),
		x0 = 0, y0 = 0, side = 40, world_origin = Vector2.ZERO}
	snapshot.h.resize(1600)
	snapshot.h.fill(0.4)
	snapshot.water.resize(1600)
	snapshot.water.fill(1.0) # every foot sample is submerged
	snapshot.path.resize(1600)
	var candidates := PackedFloat32Array([20, 20, RockModels.massif_v(RockModels.M_WALL, 0, 0), 1.0, 0, 3, 1, 0, 20, 20])
	check(RockMassif.seated_snapshot(candidates, snapshot, PackedFloat32Array(), 0, 0).is_empty(),
		"unseated outer massif is rejected before it can clear plants or feed talus")
	var layer := VegetationLayer.new()
	layer.world = WorldData.new()
	for variant in RockModels.VARIANTS:
		layer._defs[Biomes.T_ROCK + variant * ForestModels.MODEL_STRIDE] = {box = AABB(Vector3.ZERO, Vector3.ONE)}
	var grouped := layer._build_entries({x = PackedFloat64Array([8, 8]), y = PackedFloat64Array([8, 8]),
		k = PackedInt32Array([Biomes.T_ROCK, Biomes.T_ROCK]), v = PackedInt32Array([0, 0]),
		s = PackedFloat64Array([0.1, 1.0]), ground = PackedFloat32Array([1, 1])})
	check(grouped.entries.size() == 2 and grouped.entries[0].small_rocks != grouped.entries[1].small_rocks
		and grouped.entries[0].get("key_kind", grouped.entries[0].kind) != grouped.entries[1].get("key_kind", grouped.entries[1].kind),
		"small fragments retain a separate streaming group beside a large rock of the same model")
	layer.free()
	var ramp := PackedFloat32Array([0, 4, 8, 0, 4, 8, 0, 4, 8])
	check(TerrainBuilder._normal(ramp, 3, 3, 0, 1).is_equal_approx(TerrainBuilder._normal(ramp, 3, 3, 1, 1)),
		"edge normal uses the actual one-sided sample distance")


func outer_cost() -> void:
	var output: Array = []
	if OS.execute("git", ["show", "3676c62:scripts/world/outer_land.gd"], output) != 0:
		check(false, "original outer snapshot implementation available"); return
	var path := "res://.godot/mountain_review/outer_before.gd"
	FileAccess.open(path, FileAccess.WRITE).store_string(str(output[0]).replace("class_name OuterLand", ""))
	var prior: Script = load(path)
	var w := preload("res://tools/mountain_detail_test.gd").world("Север-1234")
	StageRelief.configure(w)
	var before_ms := []
	var after_ms := []
	var bytes := [0, 0]
	for repeat in 4:
		for version in 2:
			var started := Time.get_ticks_usec()
			var result: Dictionary = prior.vegetation(w, Vector2i(-2, 3)) if version == 0 else OuterLand.vegetation(w, Vector2i(-2, 3))
			var ms := (Time.get_ticks_usec() - started) / 1000.0
			bytes[version] = var_to_bytes(result).size()
			if repeat > 0: (before_ms if version == 0 else after_ms).append(ms)
	before_ms.sort(); after_ms.sort()
	print("OUTER SNAPSHOT before_ms=", before_ms[1], " after_ms=", after_ms[1], " bytes=", bytes)

func plants(w: WorldData) -> void:
	var layer := VegetationLayer.new()
	layer.world = w
	layer.grass_r = 2000; layer.under_r = 2000
	layer.understory = []
	for kind in VegetationLayer.Floor.FIRST + VegetationLayer.Floor.ROOT_SPAN + 1:
		layer.understory.append({far = false})
	var allowed := {}
	for entry: Array in VegetationLayer.ROCK_HOLLOW: allowed[entry[0]] = true
	var forbidden := 0
	for y in range(32, 64):
		for x in range(32, 64):
			layer._fill_rock_hollow(x, y, 0, 0.2, Color(0, 0, 0.95, 0.1), x * 4.0, y * 4.0)
	for site: Array in layer._understory_sites: forbidden += int(not allowed.has(site[0]))
	check(layer._understory_sites.size() > 100 and forbidden == 0, "rock hollows select only configured species; no zero-weight branches/logs")
	layer._understory_sites.clear()
	layer._fill_rock_hollow(45, 45, 1, 0.2, Color(0, 0, 1, 0), 180, 180)
	check(layer._understory_sites.is_empty(), "rock hollow candidates avoid paths without a refined tread")
	var heights := Heightfield.new()
	heights.world = w
	var placement := VegetationLayer.Placement.new(w, heights)
	var cell := 45 * w.W + 45
	var previous_path: int = w.path_mask[cell]
	w.path_mask[cell] = 3
	check(not placement.ground_clear(182, 182, 0.1), "final plant placement rejects an authored route without refinement")
	w.path_mask[cell] = previous_path
	var pairs := []
	for shift: Vector2i in [Vector2i.ZERO, Vector2i(8, -8)]:
		w.world_origin = shift
		layer._understory_sites.clear()
		for gy in range(40, 56):
			for gx in range(40, 56):
				var x := gx - shift.x; var y := gy - shift.y
				layer._fill_rock_hollow(x, y, 0, 0.2, Color(0, 0, 0.95, 0.1), x * 4, y * 4)
		var sites := layer._understory_sites.duplicate(true)
		for site: Array in sites: site[1] += shift.x * 4; site[2] += shift.y * 4
		pairs.append(sites)
	var same: bool = pairs[0].size() > 0 and pairs[0].size() == pairs[1].size()
	if same:
		for i in pairs[0].size():
			for j in pairs[0][i].size():
				var a: Variant = pairs[0][i][j]
				var b: Variant = pairs[1][i][j]
				same = same and (a.is_equal_approx(b) if a is Color else absf(float(a) - float(b)) < 0.00001)
	check(same, "rock hollow species, transforms and density survive a saved-site origin shift")
	w.world_origin = Vector2i.ZERO
	layer.free()
