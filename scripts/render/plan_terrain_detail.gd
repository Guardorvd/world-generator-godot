extends RefCounted
## Prepare hidden pieces under the terrain budget, then swap the entire tile. Physics already uses the 2 m field
## everywhere (FineRelief.Sample); the mesh catches up with it here and morphs to 4 m with distance.

const Source := preload("res://scripts/render/chunk_source.gd")
const ReliefDetailConfig := preload("res://scripts/world/world_relief_detail_config.gd")

var terrain: Node3D
var source: RefCounted
var heights: Heightfield
var profile: ReliefDetailConfig
var material: ShaderMaterial
var entries := {}
var _failed := {}
var _ordered: Array[Vector2i] = []
var _observer := Vector2.INF
var _priority_at := Vector2.INF
var _ahead := Vector2.INF
var enter_m := 0.0
var _transition_end_m := 0.0
var _exit_m := 0.0
var _vertical_margin := 0.0
var stats := {uploads = 0, switches = 0, late = 0, max_piece_ms = 0.0, active = 0, peak_active = 0}


func setup(owner: Node3D, h: Heightfield, chunks: RefCounted, mat: ShaderMaterial) -> void:
	terrain = owner
	source = chunks
	heights = h
	profile = h.fine_profile
	_transition_end_m = profile.transition_end_m
	enter_m = profile.activation_distance_m()
	_exit_m = _transition_end_m + profile.exit_margin_m
	_vertical_margin = profile.max_offset_m
	material = TerrainBuilder.fine_material(mat, profile, _transition_end_m, h.fine_lod)


func active(key: Vector2i) -> bool:
	return entries.has(key) and entries[key].get("coarse") != null


func ready_at(p: Vector2, radius: float) -> bool:
	var inside := minf(radius, enter_m)
	for key: Vector2i in terrain.nodes:
		if terrain.distance_to_chunk(key, p) <= inside and not (active(key) or _failed.has(key)):
			return false
	return true


func follow(p: Vector2, force: bool, lookahead: float, recheck: float) -> void:
	if _observer != p:
		_observer = p
		material.set_shader_parameter("relief_observer", p)
	if not force and terrain.frame_budget != null and not terrain.frame_budget.allows_work():
		return
	if force or p.distance_to(_priority_at) >= recheck:
		_ahead = p if force or not _priority_at.is_finite() else p + (p - _priority_at).normalized() * lookahead
		_priority_at = p
	var prefetch := enter_m + profile.prefetch_m
	var candidates: Array = []
	for key: Vector2i in terrain.nodes:
		if terrain._node_lod[key] != 0 or active(key) or _failed.has(key):
			continue
		var distance: float = terrain.distance_to_chunk(key, p)
		if distance > (enter_m if force else prefetch):
			continue
		# Within the switch radius actual distance wins, including after a turn or teleport.
		var priority: float = distance if distance <= enter_m else distance + terrain.distance_to_chunk(key, _ahead)
		candidates.append([priority, key, distance])
	candidates.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	_ordered.clear()
	for item: Array in candidates:
		_ordered.append(item[1])
	source.retain_layer(Source.DETAIL_LAYER, _ordered)
	if not force:
		for i in mini(_ordered.size(), Source.MAX_QUEUED):
			var distance: float = candidates[i][2]
			# Base terrain and water share this queue. A speculative precise tile must
			# not outrank a closer base chunk just because it belongs to another layer.
			source.request(Source.DETAIL_LAYER, _ordered[i], distance + maxf(0.0, distance - enter_m))


func step(p: Vector2, force: bool) -> bool:
	# Returning to the base mesh and retiring fine pieces also touches the renderer.
	for key: Vector2i in entries.keys():
		var limit := _exit_m if active(key) else enter_m + profile.prefetch_m
		if terrain.distance_to_chunk(key, p) > limit:
			forget(key)
			return true
	for key: Vector2i in _ordered:
		if active(key) or _failed.has(key):
			continue
		var d: float = terrain.distance_to_chunk(key, p)
		var entry: Dictionary = entries.get(key, {})
		if not entry.is_empty() and entry.parts.size() == entry.total:
			if d <= enter_m:
				_publish(key, entry, d, force)
				return true
			continue
		var parts: Variant = source.ready(Source.DETAIL_LAYER, key)
		if parts == null and force:
			var ready_coarse: Variant = source.ready(-1, key)
			parts = source.read_detail(key, ready_coarse if ready_coarse is Array else [])
			source._fine_cpu.put(source._id(Source.DETAIL_LAYER, key), parts)
		if parts == null:
			continue
		if parts.is_empty():
			_failed[key] = true
			forget(key)
			continue
		if entry.is_empty():
			entry = {parts = [], total = parts.size()}
			entries[key] = entry
		var started := Time.get_ticks_usec()
		var mesh := ArrayMesh.new()
		var arrays: Array = parts[entry.parts.size()]
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, TerrainBuilder.relief_mesh_format(arrays))
		var bounds := mesh.get_aabb()
		bounds.position.y -= _vertical_margin
		bounds.size.y += 2.0 * _vertical_margin
		mesh.custom_aabb = bounds
		var node: MeshInstance3D = terrain._acquire_mesh_node(mesh, material, GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED)
		if terrain.morph_lod != null:
			node.set_instance_shader_parameter("relief_chunk_bounds", terrain.morph_lod.bounds(key))
		node.visible = false
		entry.parts.append(node)
		stats.uploads += 1
		stats.max_piece_ms = maxf(stats.max_piece_ms, (Time.get_ticks_usec() - started) / 1000.0)
		if entry.parts.size() == entry.total:
			source._release_handoff(source._id(Source.DETAIL_LAYER, key))
			if d <= enter_m:
				_publish(key, entry, d, force)
		return true
	return false


func _publish(key: Vector2i, entry: Dictionary, distance: float, force: bool) -> void:
	var coarse: MeshInstance3D = terrain.nodes[key]
	entry.coarse = coarse.mesh
	coarse.mesh = null
	for node: MeshInstance3D in entry.parts:
		node.visible = true
	stats.active += 1
	stats.peak_active = maxi(stats.active, stats.peak_active)
	if not force:
		stats.switches += 1
		stats.late += int(distance < _transition_end_m)


func forget(key: Vector2i) -> void:
	if not entries.has(key):
		return
	var entry: Dictionary = entries[key]
	if active(key):
		terrain.nodes[key].mesh = entry.coarse
		stats.active -= 1
		stats.switches += 1
	for node: MeshInstance3D in entry.parts:
		terrain._release_mesh_node(node)
	entries.erase(key)


func close() -> void:
	entries.clear()
