extends RefCounted
## Level selection and shader parameters for the derived River Expedition terrain.

const ReliefDetailConfig := preload("res://scripts/world/world_relief_detail_config.gd")

var profile: ReliefDetailConfig
var _height_ranges := {}
var _tiles := Vector2i.ZERO
var _near_material: ShaderMaterial
var _far_material: ShaderMaterial
var _far_base: ShaderMaterial
var _observer := Vector2.INF
var _recovering := {}
var stats := {switches = 0, late = 0, by_pair = {}, max_upload_ms = 0.0}


func setup(h: Heightfield, keys: Array, base: ShaderMaterial) -> void:
	profile = h.fine_profile
	_tiles = Vector2i(h.world.W - 1, h.world.H - 1)
	_near_material = TerrainBuilder.coarse_morph_material(base, profile)
	for key: Vector2i in keys:
		_height_ranges[key] = h.fine_relief.LodHeightRange(key.x, key.y)


func follow(p: Vector2) -> bool:
	var finished := false
	if not _recovering.is_empty():
		var now := Time.get_ticks_usec()
		for key: Vector2i in _recovering.keys():
			var recovery: Array = _recovering[key]
			var node: MeshInstance3D = recovery[0]
			var alpha := 1.0 - smoothstep(0.0, profile.lod_recover_s, (now - int(recovery[1])) / 1000000.0)
			node.set_instance_shader_parameter("relief_lod_recovery", Vector2(recovery[2], alpha))
			if alpha <= 0.0:
				_recovering.erase(key)
				finished = true
	if p == _observer:
		return finished
	_observer = p
	_near_material.set_shader_parameter("relief_observer", p)
	if _far_material != null:
		_far_material.set_shader_parameter("relief_observer", p)
	return finished


func material_for(base: ShaderMaterial) -> ShaderMaterial:
	if base == null:
		return _near_material
	if base != _far_base:
		_far_base = base
		_far_material = TerrainBuilder.coarse_morph_material(_far_base, profile)
		_far_material.set_shader_parameter("relief_observer", _observer)
	return _far_material


func bounds(key: Vector2i) -> Vector4:
	var origin := key * PlanTerrain.CELLS
	var last := (origin + Vector2i.ONE * PlanTerrain.CELLS).min(_tiles)
	var lo := (Vector2(origin) + Vector2.ONE * 0.5) * GameConfig.TILE
	var hi := (Vector2(last) + Vector2.ONE * 0.5) * GameConfig.TILE
	return Vector4(lo.x, lo.y, hi.x, hi.y)


func mesh_bounds(key: Vector2i, bounds: AABB) -> AABB:
	var heights: Vector2 = _height_ranges[key]
	var low := minf(bounds.position.y, heights.x)
	var high := maxf(bounds.end.y, heights.y)
	bounds.position.y = low
	bounds.size.y = high - low
	return bounds


func configure(node: MeshInstance3D, key: Vector2i, lod: int) -> void:
	_recovering.erase(key)
	var ends := profile.lod_end_m
	var band := Vector2.ZERO
	if lod < 2:
		band = Vector2(ends[lod] - profile.lod_fade_m[lod], ends[lod])
	node.set_instance_shader_parameter("relief_chunk_bounds", bounds(key))
	node.set_instance_shader_parameter("relief_chunk_lod", Vector3(band.x, band.y, lod))
	node.set_instance_shader_parameter("relief_lod_recovery", Vector2.ZERO)


func desired(key: Vector2i, distance: float, current: int, immediate: bool) -> int:
	var ends := profile.lod_end_m
	var load := profile.lod_load_margin_m
	if immediate:
		return int(distance >= ends.x + load) + int(distance >= ends.y + load)
	if _recovering.has(key):
		return current
	var drop := load + profile.lod_hysteresis_m
	if current < 2 and distance >= ends[current] + drop:
		return current + 1
	if current > 0 and distance <= ends[current - 1] + load:
		return current - 1
	return current


func wants_full(key: Vector2i, distance: float, current: int) -> bool:
	return current == 1 and distance <= profile.lod_end_m.x + profile.lod_load_margin_m + profile.prefetch_m


func forget(key: Vector2i) -> void:
	_recovering.erase(key)


func record(node: MeshInstance3D, key: Vector2i, distance: float, from_lod: int, to_lod: int, upload_ms: float) -> void:
	var transition := mini(from_lod, to_lod)
	var ends := profile.lod_end_m
	stats.switches += 1
	var pair := "%d>%d" % [from_lod, to_lod]
	stats.by_pair[pair] = stats.by_pair.get(pair, 0) + 1
	var next_start := ends.y - profile.lod_fade_m.y if transition == 0 else INF
	if distance < ends[transition] or distance > next_start:
		# If the queue missed the overlap, start the new mesh at the old endpoint.
		var weight := float(to_lod < from_lod)
		node.set_instance_shader_parameter("relief_lod_recovery", Vector2(weight, 1.0))
		_recovering[key] = [node, Time.get_ticks_usec(), weight]
		stats.late += 1
	stats.max_upload_ms = maxf(stats.max_upload_ms, upload_ms)
