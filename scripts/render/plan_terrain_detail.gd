extends RefCounted
## Prepare hidden pieces under the terrain budget, then swap the entire tile together with its physics.

const Source := preload("res://scripts/render/chunk_source.gd")
const ReliefDetailConfig := preload("res://scripts/world/world_relief_detail_config.gd")
const CUSTOM_FORMAT := Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT

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
var stats := {uploads = 0, switches = 0, late = 0, max_piece_ms = 0.0, active = 0, peak_active = 0}


func setup(owner: Node3D, h: Heightfield, chunks: RefCounted, mat: ShaderMaterial) -> void:
	terrain = owner
	source = chunks
	heights = h
	profile = h.fine_profile
	material = TerrainBuilder.fine_material(mat, profile)


func active(key: Vector2i) -> bool:
	return entries.has(key) and entries[key].get("coarse") != null


func ready_at(p: Vector2, radius: float) -> bool:
	var inside := minf(radius, profile.transition_end_m + profile.enter_margin_m)
	for key: Vector2i in terrain.nodes:
		if terrain.distance_to_chunk(key, p) <= inside and not (active(key) or _failed.has(key)):
			return false
	return true


func follow(p: Vector2, force: bool, lookahead: float, recheck: float) -> void:
	if _observer != p:
		_observer = p
		material.set_shader_parameter("relief_observer", p)
	if force or p.distance_to(_priority_at) >= recheck:
		_ahead = p if force or not _priority_at.is_finite() else p + (p - _priority_at).normalized() * lookahead
		_priority_at = p
	var enter := profile.transition_end_m + profile.enter_margin_m
	var exit := profile.transition_end_m + profile.exit_margin_m
	var prefetch := enter + profile.prefetch_m
	for key: Vector2i in entries.keys():
		var distance: float = terrain.distance_to_chunk(key, p)
		if distance > (exit if active(key) else prefetch):
			forget(key)
	var candidates: Array = []
	for key: Vector2i in terrain.nodes:
		if terrain._node_lod[key] != 0 or active(key) or _failed.has(key):
			continue
		var distance: float = terrain.distance_to_chunk(key, p)
		if distance > (enter if force else prefetch):
			continue
		# Within the switch radius actual distance wins, including after a turn or teleport.
		var priority: float = distance if distance <= enter else distance + terrain.distance_to_chunk(key, _ahead)
		candidates.append([priority, key, distance])
	candidates.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	_ordered.clear()
	for item: Array in candidates:
		_ordered.append(item[1])
	source.retain_layer(Source.DETAIL_LAYER, _ordered)
	if not force:
		for i in mini(_ordered.size(), Source.MAX_QUEUED):
			source.request(Source.DETAIL_LAYER, _ordered[i], candidates[i][2] - prefetch)


func step(p: Vector2, force: bool) -> bool:
	var enter := profile.transition_end_m + profile.enter_margin_m
	for key: Vector2i in _ordered:
		if active(key) or _failed.has(key):
			continue
		var d: float = terrain.distance_to_chunk(key, p)
		var entry: Dictionary = entries.get(key, {})
		if not entry.is_empty() and entry.parts.size() == entry.total:
			if d <= enter:
				_publish(key, entry, d, force)
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
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, parts[entry.parts.size()], [], {}, CUSTOM_FORMAT)
		var bounds := mesh.get_aabb()
		var vertical_margin := maxf(profile.reconstruction_delta_m, profile.total_delta_m)
		bounds.position.y -= vertical_margin
		bounds.size.y += 2.0 * vertical_margin
		mesh.custom_aabb = bounds
		var shadow := GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED if profile.cast_shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var node: MeshInstance3D = terrain._acquire_mesh_node(mesh, material, shadow)
		node.visible = false
		entry.parts.append(node)
		stats.uploads += 1
		stats.max_piece_ms = maxf(stats.max_piece_ms, (Time.get_ticks_usec() - started) / 1000.0)
		if entry.parts.size() == entry.total:
			source._release_handoff(source._id(Source.DETAIL_LAYER, key))
			if d <= enter:
				_publish(key, entry, d, force)
		return true
	return false


func _publish(key: Vector2i, entry: Dictionary, distance: float, force: bool) -> void:
	var coarse: MeshInstance3D = terrain.nodes[key]
	entry.coarse = coarse.mesh
	coarse.mesh = null
	for node: MeshInstance3D in entry.parts:
		node.visible = true
	heights.fine_relief.SetActive(key.x, key.y, true)
	heights.ground_changed(true)
	stats.active += 1
	stats.peak_active = maxi(stats.active, stats.peak_active)
	if not force:
		stats.switches += 1
		stats.late += int(distance < profile.transition_end_m)


func forget(key: Vector2i) -> void:
	if not entries.has(key):
		return
	var entry: Dictionary = entries[key]
	if active(key):
		terrain.nodes[key].mesh = entry.coarse
		heights.fine_relief.SetActive(key.x, key.y, false)
		heights.ground_changed(true)
		stats.active -= 1
		stats.switches += 1
	for node: MeshInstance3D in entry.parts:
		terrain._release_mesh_node(node)
	entries.erase(key)


func close() -> void:
	for key: Vector2i in entries.keys():
		if active(key):
			heights.fine_relief.SetActive(key.x, key.y, false)
	entries.clear()
