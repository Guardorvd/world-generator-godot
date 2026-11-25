extends RefCounted
## Inspect emitted triangle planes and the packed morph attributes without a renderer.

const TILE := GameConfig.TILE
const CELLS := PlanTerrain.CELLS
const TOLERANCE := preload("res://tools/relief_fine_metrics.gd").TOLERANCE_M
const Adaptive := preload("res://scripts/render/plan_terrain_lod.gd")


static func inspect(detail: Object, source: RefCounted, w: WorldData, focus: Vector2) -> Dictionary:
	var last := Vector2i((w.W - 2) / CELLS, (w.H - 2) / CELLS)
	var beside := last - Vector2i(1, 0) if last.x > 0 else last - Vector2i(0, 1)
	var view := Vector2i(((focus - Vector2.ONE * TILE * 0.5) / PlanTerrain.SIDE).floor())
	var keys := {view: true, last: true, beside: true}
	var errors := {samples = 0, height_failures = 0, normal_failures = 0, seam_failures = 0, missing = 0, max_mm = 0.0}
	var meshes := {}
	for key: Vector2i in keys:
		if not source.groups[0].has(key):
			continue
		var arrays: Array = source.read(-1, key)
		var mid: Array = detail.BuildMorphLod(key.x, key.y, PlanTerrain.LOD1_STEP)
		var far: Array = detail.BuildMorphLod(key.x, key.y, PlanTerrain.LOD2_STEP)
		var mid_grid := _index(mid, key, w)
		var far_grid := _index(far, key, w)
		_compare(arrays, mid_grid, errors)
		_compare(mid, far_grid, errors)
		meshes[key] = {full = arrays, mid = mid_grid, far = far_grid}
	if meshes.has(last) and meshes.has(beside):
		var inside: Dictionary = meshes[last]
		var outside: Dictionary = meshes[beside]
		var positions: PackedVector3Array = inside.full[Mesh.ARRAY_VERTEX]
		var edge: PackedFloat32Array = inside.full[Mesh.ARRAY_CUSTOM1]
		var start := (Vector2(last * CELLS) + Vector2.ONE * 0.5) * TILE
		for i in positions.size():
			var p := Vector2(positions[i].x, positions[i].z)
			if (last.x != beside.x and p.x != start.x) or (last.y != beside.y and p.y != start.y):
				continue
			var a := _sample(outside.mid, p)
			var b := _sample(inside.far, p)
			var target := _attribute(edge, i)
			errors.seam_failures += int(absf(a.x - b.x) > TOLERANCE or (a - b).length() > TOLERANCE \
				or (target - b).length() > TOLERANCE or not a.is_finite() or not b.is_finite())
	return errors


static func resumes_after_recovery(h: Heightfield, source: RefCounted, key: Vector2i, point: Vector2) -> bool:
	var stream := PlanTerrain.new()
	Engine.get_main_loop().root.add_child(stream)
	var material := ShaderMaterial.new()
	material.shader = TerrainBuilder.SHADER
	stream.setup({key: source.groups[0][key]}, material, null, h.world, h, source)
	var node := MeshInstance3D.new()
	stream.add_child(node)
	stream.nodes[key] = node
	stream._node_lod[key] = 2
	stream._set_lod_mesh(node, key, 2, point, stream._lod_arrays(key, 2))
	var outside := point + Vector2(PlanTerrain.RADIUS * 2.0, 0.0)
	var ok := not stream._step_lod(outside, 0.0) and stream._lod_at == Vector2.INF
	# The first step from 16 m is late after a teleport. The second waits for its blend.
	stream.update(point.x, point.y)
	ok = ok and stream._node_lod[key] == 2 and stream._lod_task != -1 and stream._lod_at != point
	var deadline := Time.get_ticks_msec() + 1000
	while ok and not WorkerThreadPool.is_task_completed(stream._lod_task) and Time.get_ticks_msec() < deadline:
		OS.delay_usec(250)
	stream.update(point.x, point.y)
	stream.update(point.x, point.y)
	ok = ok and stream.stream_stats.lod_builds == 1 and stream._node_lod[key] == 1 and stream._lod_at == point and stream.morph_lod._recovering.has(key)
	if ok:
		var recovery: Array = stream.morph_lod._recovering[key]
		recovery[1] -= ceili(h.fine_profile.lod_recover_s * 1000000.0) + 1
		stream.update(point.x, point.y)
		ok = stream._node_lod[key] == 0
	stream.free()
	return ok


static func budget(h: Heightfield, chunks: Dictionary, route: PackedVector2Array) -> Dictionary:
	var original := PlanTerrain.new()
	var changed := PlanTerrain.new()
	changed._world = h.world
	changed.morph_lod = Adaptive.new()
	var mat := ShaderMaterial.new()
	mat.shader = TerrainBuilder.SHADER
	changed.morph_lod.setup(h, chunks.keys(), mat)
	var old_lod := {}
	var new_lod := {}
	var triangles := {}
	for key: Vector2i in chunks:
		var count: int = chunks[key][Mesh.ARRAY_INDEX].size() / 3
		var old := [count]
		var now := [count]
		for step: int in [PlanTerrain.LOD1_STEP, PlanTerrain.LOD2_STEP]:
			var a: Array = Grid.fast_grid().BuildTerrainLod(h.world.W, h.world.H, TILE, key.x, key.y, CELLS, step, h.hv,
				h.world.path_mask, step * TILE * 0.5)
			var b: Array = h.fine_relief.BuildMorphLod(key.x, key.y, step)
			old.append(a[Mesh.ARRAY_INDEX].size() / 3)
			now.append(b[Mesh.ARRAY_INDEX].size() / 3)
		triangles[key] = [old, now]
	var previous := Vector2.INF
	var result := {samples = 0, old_peak = 0, new_peak = 0, worst_increase = 0, switches = 0}
	for p: Vector2 in route:
		if previous.distance_to(p) < PlanTerrain.LOD_RECHECK:
			continue
		previous = p
		var totals := Vector2i.ZERO
		for key: Vector2i in chunks:
			var was: int = old_lod.get(key, 0)
			var current: int = new_lod.get(key, 0)
			old_lod[key] = original._desired_lod(key, p, was)
			new_lod[key] = changed._desired_lod(key, p, current, not new_lod.has(key))
			if original.distance_to_chunk(key, p) <= PlanTerrain.RADIUS:
				totals.x += triangles[key][0][old_lod[key]]
				totals.y += triangles[key][1][new_lod[key]]
				result.switches += int(result.samples > 0 and new_lod[key] != current)
		result.samples += 1
		result.old_peak = maxi(result.old_peak, totals.x)
		result.new_peak = maxi(result.new_peak, totals.y)
		result.worst_increase = maxi(result.worst_increase, totals.y - totals.x)
	original.free()
	changed.free()
	return result


static func _attribute(values: PackedFloat32Array, index: int) -> Vector4:
	var i := index * 4
	return Vector4(values[i], values[i + 1], values[i + 2], values[i + 3])


static func _index(arrays: Array, key: Vector2i, w: WorldData) -> Dictionary:
	var p: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var corners := {}
	for i in range(0, indices.size(), 3):
		var a := p[indices[i]]
		var b := p[indices[i + 1]]
		var c := p[indices[i + 2]]
		var x0 := int(minf(a.x, minf(b.x, c.x)) / TILE - 0.5)
		var z0 := int(minf(a.z, minf(b.z, c.z)) / TILE - 0.5)
		var x1 := int(maxf(a.x, maxf(b.x, c.x)) / TILE - 0.5)
		var z1 := int(maxf(a.z, maxf(b.z, c.z)) / TILE - 0.5)
		for z in range(z0, z1):
			for x in range(x0, x1):
				var cell := Vector2i(x, z)
				if not corners.has(cell):
					corners[cell] = []
				corners[cell].append(i)
	var lo := key * CELLS
	var hi := (lo + Vector2i.ONE * CELLS).min(Vector2i(w.W - 1, w.H - 1)) - Vector2i.ONE
	return {positions = p, normals = arrays[Mesh.ARRAY_CUSTOM1], indices = indices, cells = corners, lo = lo, hi = hi}


static func _sample(grid: Dictionary, p: Vector2) -> Vector4:
	var positions: PackedVector3Array = grid.positions
	var indices: PackedInt32Array = grid.indices
	var values: PackedFloat32Array = grid.normals
	var cell := Vector2i((p / TILE - Vector2.ONE * 0.5).floor()).clamp(grid.lo, grid.hi)
	for tri: int in grid.cells.get(cell, []):
		var i := indices[tri]
		var j := indices[tri + 1]
		var k := indices[tri + 2]
		var origin := Vector2(positions[i].x, positions[i].z)
		var b := Vector2(positions[j].x, positions[j].z) - origin
		var c := Vector2(positions[k].x, positions[k].z) - origin
		var d := p - origin
		var area := b.cross(c)
		var u := d.cross(c) / area
		var v := b.cross(d) / area
		if u >= -TOLERANCE and v >= -TOLERANCE and u + v <= 1.0 + TOLERANCE:
			return _attribute(values, i) * (1.0 - u - v) + _attribute(values, j) * u + _attribute(values, k) * v
	return Vector4(INF, INF, INF, INF)


static func _compare(source: Array, destination: Dictionary, errors: Dictionary) -> void:
	var p: PackedVector3Array = source[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = source[Mesh.ARRAY_INDEX]
	var target: PackedFloat32Array = source[Mesh.ARRAY_CUSTOM0]
	for i in range(0, indices.size(), 3):
		var a := indices[i]
		var b := indices[i + 1]
		var c := indices[i + 2]
		var ab := p[b] - p[a]
		var ac := p[c] - p[a]
		if Vector2(ab.x, ab.z).cross(Vector2(ac.x, ac.z)) == 0.0:
			continue
		var center := (p[a] + p[b] + p[c]) / 3.0
		var expected := _sample(destination, Vector2(center.x, center.z))
		var actual := (_attribute(target, a) + _attribute(target, b) + _attribute(target, c)) / 3.0
		var diff := actual - expected
		errors.samples += 1
		errors.missing += int(not expected.is_finite())
		errors.height_failures += int(absf(diff.x) > TOLERANCE)
		errors.normal_failures += int(Vector3(diff.y, diff.z, diff.w).length() > TOLERANCE)
		if expected.is_finite():
			errors.max_mm = maxf(errors.max_mm, absf(diff.x) * 1000.0)
