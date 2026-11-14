class_name TreeGarlandsLayer
extends Node3D
## Слой парковых гирлянд: фоновая сборка кластеров по снимку мира, дистанционное
## кеширование, управление ночным ореолом и пулом локальных тёплых OmniLight3D.

const WIRE_SHADER := preload("res://resources/tree_garland_wire.gdshader")
const BULB_SHADER := preload("res://resources/tree_garland_bulb.gdshader")
const HALO_SHADER := preload("res://resources/tree_garland_halo.gdshader")
const NavigationSnapshot := preload("res://scripts/game/navigation_snapshot.gd")

const MAX_LIGHTS := 3
const LIGHT_RANGE := 16.5
const LIGHT_ATTENUATION := 1.35
const LIGHT_ENERGY := 2.45
const LIGHT_RADIUS := 78.0
const LIGHT_HYSTERESIS := 4.5
const FIRE_SUPPRESS_INNER := 22.0
const FIRE_SUPPRESS_OUTER := 42.0
const LIGHT_COLOR := Color(1.0, 0.72, 0.34)

var _enabled := true
var _world: WorldData
var _heights: Heightfield
var _clear_spots: Array[Vector2] = []
var _huts: Array[Vector3] = []
var _gates: Array[Vector2] = []

var _clusters: Array[Dictionary] = []
var _known_ids: Dictionary = {}
var _region_keys: Dictionary = {}
var _loaded: Dictionary = {}
var _failed_ids: Dictionary = {}

var _pending_task := -1
var _pending_id := -1
var _pending_state: Dictionary = {}

var _wire_mat: ShaderMaterial
var _bulb_mat: ShaderMaterial
var _halo_mat: ShaderMaterial
var _bulb_mesh: ArrayMesh
var _halo_mesh: ArrayMesh

var _lights: Array[Dictionary] = []
var _last_draw := -1
var _last_night := 0.0


func _ready() -> void:
	_ensure_resources()


func _exit_tree() -> void:
	finish()


## Инициализирует индекс кластеров базовой области без изменения WorldData.
func setup(world: WorldData, heights: Heightfield, clear_spots: Array[Vector2] = [], huts: Array[Vector3] = []) -> void:
	finish()
	_ensure_resources()
	_world = world
	_heights = heights
	_clear_spots = clear_spots.duplicate()
	_huts = huts.duplicate()
	_gates = TreeGarlandsLayout._gate_positions(heights) if heights != null else []
	_clusters = TreeGarlandsLayout.find_base_clusters(world, heights, _clear_spots)
	for c: Dictionary in _clusters:
		_known_ids[c.id] = true


## Синхронизирует новые внешние регионы из RegionStream и обновляет список построек.
func sync_regions(regions: Dictionary, huts: Array[Vector3] = []) -> void:
	if _world == null or _heights == null:
		return
	if not huts.is_empty():
		_huts = huts.duplicate()
	var dirty_gates := false
	for key: Variant in regions:
		if not (key is Vector2i):
			continue
		if _region_keys.has(key):
			continue
		var reg: Dictionary = regions[key]
		if not reg.has("rect") or not reg.has("fields"):
			continue
		_region_keys[key] = true
		dirty_gates = true
		var found := TreeGarlandsLayout.find_region_clusters(_world, _heights, key, reg, _clusters, _clear_spots)
		for c: Dictionary in found:
			if not _known_ids.has(c.id):
				_known_ids[c.id] = true
				_clusters.append(c)
	if dirty_gates:
		_gates = TreeGarlandsLayout._gate_positions(_heights)


## Синхронно собирает одиночный кластер для изолированных тестовых сцен (garland_look.gd).
func setup_override(
	trees_override: Array,
	route_pts: PackedVector2Array,
	route_widths: PackedFloat32Array,
	heights: Heightfield,
	center: Vector2,
	archetype := TreeGarlandsLayout.Archetype.ALLEY_ZIGZAG,
	seed_val := 4242,
	huts: Array[Vector3] = [],
	gates: Array[Vector2] = []
) -> bool:
	finish()
	_ensure_resources()
	_heights = heights
	_huts = huts.duplicate()
	_gates = gates.duplicate()
	var desc := {
		id = seed_val,
		center = center,
		route_pts = route_pts,
		route_widths = route_widths,
		archetype = archetype,
		seed = seed_val,
		priority = 1.0,
		is_outer = false,
		bbox = Rect2(center - Vector2.ONE * (TreeGarlandsLayout.CLUSTER_RADIUS + 18.0), Vector2.ONE * (TreeGarlandsLayout.CLUSTER_RADIUS + 18.0) * 2.0),
	}
	_clusters = [desc]
	_known_ids[desc.id] = true
	var snap := {
		heights = heights,
		trees_override = trees_override,
		huts = huts,
		gates = gates,
	}
	var res := TreeGarlandsLayout.build_cluster(desc, snap)
	if not res.get("valid", false):
		return false
	_mount_cluster(res)
	return true


## Включает или отключает слой гирлянд; при отключении освобождает загруженные узлы и пул света.
func set_enabled(on: bool) -> void:
	if _enabled == on:
		return
	_enabled = on
	visible = on
	if not on:
		_cancel_pending()
		_clear_loaded()
		_mute_all_lights()


func is_enabled() -> bool:
	return _enabled


## Обновляет фоновую загрузку/выгрузку кластеров, видимость ореолов и пул OmniLight3D.
func update(
	player_pos: Vector3,
	cam_pos: Vector3,
	fire_pos: Vector3,
	fire_active: bool,
	night: float,
	draw_level: int,
	lighting_level: int,
	delta: float,
	budget = null
) -> void:
	if not _enabled:
		return
	night = clampf(night, 0.0, 1.0)
	_last_night = night

	var trees_r: float = GameSettings.DRAW_LEVELS[clampi(draw_level, 0, GameSettings.DRAW_LEVELS.size() - 1)].trees
	var max_vis := minf(200.0, trees_r * 0.52)
	var wire_max := minf(105.0, max_vis * 0.58)
	var bulb_max := minf(178.0, max_vis * 0.90)
	var load_r := max_vis + 80.0
	var drop_r := load_r + 90.0

	if _last_draw != draw_level:
		_last_draw = draw_level
		_ensure_resources()
		_wire_mat.set_shader_parameter("max_distance", wire_max)
		_bulb_mat.set_shader_parameter("max_distance", bulb_max)
		_halo_mat.set_shader_parameter("max_distance", max_vis)

	var cam2 := Vector2(cam_pos.x, cam_pos.z)
	var pos2 := Vector2(player_pos.x, player_pos.z)
	_poll_pending(budget)
	_evict_distant(pos2, drop_r)
	if _pending_task == -1 and (budget == null or budget.allows_work()):
		_start_nearest_pending(pos2, load_r)

	var halos_on := night > 0.004
	var wire_vis_r := wire_max + TreeGarlandsLayout.CLUSTER_RADIUS + 20.0
	var bulb_vis_r := bulb_max + TreeGarlandsLayout.CLUSTER_RADIUS + 20.0
	var halo_vis_r := max_vis + TreeGarlandsLayout.CLUSTER_RADIUS + 20.0
	for entry: Dictionary in _loaded.values():
		var d := cam2.distance_to(entry.center)
		if entry.wire != null:
			entry.wire.visible = d <= wire_vis_r
		entry.bulbs.visible = d <= bulb_vis_r
		entry.halos.visible = halos_on and d <= halo_vis_r

	_update_lights(player_pos, fire_pos, fire_active, night, lighting_level, delta)


## Немедленно дожидается фоновой задачи и монтирует результат (удобно для тестов).
func flush_pending() -> void:
	if _pending_task == -1:
		return
	WorkerThreadPool.wait_for_task_completion(_pending_task)
	_pending_task = -1
	var res := _extract_pending_result()
	var cid := _pending_id
	_pending_id = -1
	_pending_state = {}
	if res.get("valid", false):
		_mount_cluster(res)
	elif cid != -1:
		_failed_ids[cid] = true


## Отменяет фоновые задачи и полностью очищает узлы и ссылки (вызывается из _exit_tree).
func finish() -> void:
	_cancel_pending()
	_clear_loaded()
	for slot: Dictionary in _lights:
		var l: OmniLight3D = slot.node
		if is_instance_valid(l):
			l.queue_free()
	_lights.clear()
	_clusters.clear()
	_known_ids.clear()
	_region_keys.clear()
	_failed_ids.clear()
	_clear_spots.clear()
	_huts.clear()
	_gates.clear()
	_world = null
	_heights = null
	_last_draw = -1


func cluster_count() -> int:
	return _clusters.size()


func loaded_count() -> int:
	return _loaded.size()


func total_bulb_count() -> int:
	var n := 0
	for entry: Dictionary in _loaded.values():
		n += entry.bulb_count
	return n


func active_light_count() -> int:
	var n := 0
	for slot: Dictionary in _lights:
		if slot.node.visible and slot.energy > 0.01:
			n += 1
	return n


func cluster_descriptors() -> Array[Dictionary]:
	return _clusters


func loaded_entries() -> Dictionary:
	return _loaded


func _ensure_resources() -> void:
	if _wire_mat == null:
		_wire_mat = ShaderMaterial.new()
		_wire_mat.shader = WIRE_SHADER
	if _bulb_mat == null:
		_bulb_mat = ShaderMaterial.new()
		_bulb_mat.shader = BULB_SHADER
	if _halo_mat == null:
		_halo_mat = ShaderMaterial.new()
		_halo_mat.shader = HALO_SHADER
	if _bulb_mesh == null:
		_bulb_mesh = TreeGarlandsLayout.bulb_mesh()
	if _halo_mesh == null:
		_halo_mesh = TreeGarlandsLayout.halo_quad_mesh()


func _ensure_light_pool() -> void:
	if _lights.size() == MAX_LIGHTS:
		return
	for i in range(_lights.size(), MAX_LIGHTS):
		var l := OmniLight3D.new()
		l.name = "GarlandPoolLight_%d" % i
		l.shadow_enabled = false
		l.light_color = LIGHT_COLOR
		l.light_energy = 0.0
		l.omni_range = LIGHT_RANGE
		l.omni_attenuation = LIGHT_ATTENUATION
		l.distance_fade_enabled = true
		l.distance_fade_begin = 66.0
		l.distance_fade_length = 22.0
		l.visible = false
		add_child(l)
		_lights.append({
			node = l,
			anchor = Vector3.ZERO,
			has_anchor = false,
			energy = 0.0,
			target_anchor = Vector3.ZERO,
			pending_swap = false,
		})


func _poll_pending(budget) -> void:
	if _pending_task == -1:
		return
	if not WorkerThreadPool.is_task_completed(_pending_task):
		return
	if budget != null and not budget.allows_work():
		return
	WorkerThreadPool.wait_for_task_completion(_pending_task)
	_pending_task = -1
	var res := _extract_pending_result()
	var cid := _pending_id
	_pending_id = -1
	_pending_state = {}
	if not _enabled:
		return
	if res.get("valid", false):
		_mount_cluster(res)
	elif cid != -1:
		_failed_ids[cid] = true


func _extract_pending_result() -> Dictionary:
	if _pending_state.is_empty():
		return {}
	var mtx: Mutex = _pending_state.mutex
	mtx.lock()
	var res: Dictionary = _pending_state.result
	var cancelled: bool = _pending_state.cancelled
	mtx.unlock()
	return {} if cancelled else res


func _start_nearest_pending(pos2: Vector2, load_r: float) -> void:
	if _world == null or _heights == null or _clusters.is_empty():
		return
	var best_idx := -1
	var best_d := load_r
	for i in _clusters.size():
		var c: Dictionary = _clusters[i]
		var cid: int = c.id
		if _loaded.has(cid) or _failed_ids.has(cid):
			continue
		var d := pos2.distance_to(c.center)
		if d < best_d:
			best_d = d
			best_idx = i
	if best_idx == -1:
		return
	var desc: Dictionary = _clusters[best_idx]
	var snap := {
		world = _world,
		heights = NavigationSnapshot.capture(_heights, false),
		outer_veg = _world.outer.veg.duplicate(false) if _world.outer != null else {},
		huts = _huts.duplicate(),
		gates = _gates.duplicate(),
	}
	var state := {
		cancelled = false,
		done = false,
		result = {},
		mutex = Mutex.new(),
	}
	_pending_state = state
	_pending_id = desc.id
	_pending_task = WorkerThreadPool.add_task(func() -> void:
		var mtx: Mutex = state.mutex
		mtx.lock()
		var stopped: bool = state.cancelled
		mtx.unlock()
		if stopped:
			return
		var res := TreeGarlandsLayout.build_cluster(desc, snap)
		mtx.lock()
		if not state.cancelled:
			state.result = res
			state.done = true
		mtx.unlock()
	, false, "TreeGarlandCluster")


func _cancel_pending() -> void:
	if _pending_state.has("mutex"):
		var mtx: Mutex = _pending_state.mutex
		mtx.lock()
		_pending_state.cancelled = true
		mtx.unlock()
	if _pending_task != -1:
		WorkerThreadPool.wait_for_task_completion(_pending_task)
		_pending_task = -1
	_pending_id = -1
	_pending_state = {}


func _evict_distant(pos2: Vector2, drop_r: float) -> void:
	var to_drop: Array[int] = []
	for cid: int in _loaded:
		var entry: Dictionary = _loaded[cid]
		if pos2.distance_to(entry.center) > drop_r:
			to_drop.append(cid)
	for cid: int in to_drop:
		var entry: Dictionary = _loaded[cid]
		if is_instance_valid(entry.node):
			entry.node.queue_free()
		_loaded.erase(cid)


func _clear_loaded() -> void:
	for entry: Dictionary in _loaded.values():
		if is_instance_valid(entry.node):
			entry.node.queue_free()
	_loaded.clear()


func _mount_cluster(res: Dictionary) -> void:
	_ensure_resources()
	var cid: int = res.id
	if _loaded.has(cid):
		return
	var root := Node3D.new()
	root.name = "GarlandCluster_%d" % cid
	root.position = res.origin

	var wire_node: MeshInstance3D = null
	var wire_arrays: Array = res.wire_arrays
	var w_verts: PackedVector3Array = wire_arrays[Mesh.ARRAY_VERTEX]
	if not w_verts.is_empty():
		var wire_mesh := ArrayMesh.new()
		wire_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, wire_arrays)
		wire_mesh.custom_aabb = res.bounds
		wire_node = MeshInstance3D.new()
		wire_node.name = "Wires"
		wire_node.mesh = wire_mesh
		wire_node.material_override = _wire_mat
		wire_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		wire_node.custom_aabb = res.bounds
		root.add_child(wire_node)

	var bulbs_mm := _make_multimesh(_bulb_mesh, res.bulb_xfs, res.bulb_customs)
	var bulbs_mmi := MultiMeshInstance3D.new()
	bulbs_mmi.name = "Bulbs"
	bulbs_mmi.multimesh = bulbs_mm
	bulbs_mmi.material_override = _bulb_mat
	bulbs_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	bulbs_mmi.custom_aabb = res.bounds
	root.add_child(bulbs_mmi)

	var halos_mm := _make_multimesh(_halo_mesh, res.halo_xfs, res.bulb_customs)
	var halos_mmi := MultiMeshInstance3D.new()
	halos_mmi.name = "Halos"
	halos_mmi.multimesh = halos_mm
	halos_mmi.material_override = _halo_mat
	halos_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	halos_mmi.custom_aabb = res.bounds
	halos_mmi.visible = _enabled and _last_night > 0.004
	root.add_child(halos_mmi)

	add_child(root)
	_loaded[cid] = {
		node = root,
		wire = wire_node,
		bulbs = bulbs_mmi,
		halos = halos_mmi,
		center = res.center,
		light_anchors = res.light_anchors,
		bulb_count = res.bulb_count,
		span_count = res.span_count,
	}


func _make_multimesh(mesh: Mesh, xfs: Array[Transform3D], customs: PackedColorArray) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	# Важно для Compatibility (GLES3): use_colors=true без цветов вершин заливает инстансы чёрным.
	mm.use_colors = false
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = xfs.size()
	for i in xfs.size():
		mm.set_instance_transform(i, xfs[i])
		mm.set_instance_custom_data(i, customs[i])
	return mm


func _light_budget(lighting_level: int) -> int:
	if lighting_level <= 0:
		return 0
	var is_forward := RenderingServer.get_current_rendering_method() == "forward_plus"
	if is_forward:
		return 1 if lighting_level == 1 else 3
	return 1 if lighting_level == 1 else 2


func _mute_all_lights() -> void:
	for slot: Dictionary in _lights:
		slot.has_anchor = false
		slot.pending_swap = false
		slot.energy = 0.0
		var l: OmniLight3D = slot.node
		l.light_energy = 0.0
		l.visible = false


func _update_lights(player_pos: Vector3, fire_pos: Vector3, fire_active: bool, night: float, lighting_level: int, delta: float) -> void:
	var cap := _light_budget(lighting_level)
	if cap <= 0 or night <= 0.01 or _loaded.is_empty():
		for slot: Dictionary in _lights:
			slot.energy = move_toward(slot.energy, 0.0, delta * 4.5)
			var l: OmniLight3D = slot.node
			l.light_energy = slot.energy
			l.visible = slot.energy > 0.01
			if not l.visible:
				slot.has_anchor = false
				slot.pending_swap = false
		return

	_ensure_light_pool()
	var candidates: Array[Dictionary] = []
	for entry: Dictionary in _loaded.values():
		var anchors: PackedVector3Array = entry.light_anchors
		for a in anchors:
			var d := a.distance_to(player_pos)
			if d <= LIGHT_RADIUS:
				candidates.append({pos = a, dist = d})
	candidates.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return x.dist < y.dist)
	if candidates.size() > cap:
		candidates.resize(cap)

	var desired: Array[Vector3] = []
	for c: Dictionary in candidates:
		desired.append(c.pos)

	# Сначала оставляем слоты, которые уже сидят на нужных или близких якорях (гистерезис от перескока).
	var claimed_desired: Array[bool] = []
	claimed_desired.resize(desired.size())
	var slot_target: Array[int] = []
	slot_target.resize(_lights.size())
	slot_target.fill(-1)

	for si in mini(cap, _lights.size()):
		var slot: Dictionary = _lights[si]
		if not slot.has_anchor:
			continue
		for di in desired.size():
			if claimed_desired[di]:
				continue
			if slot.anchor.distance_to(desired[di]) < LIGHT_HYSTERESIS:
				claimed_desired[di] = true
				slot_target[si] = di
				break

	for si in mini(cap, _lights.size()):
		if slot_target[si] != -1:
			continue
		for di in desired.size():
			if not claimed_desired[di]:
				claimed_desired[di] = true
				slot_target[si] = di
				break

	var night_k := smoothstep(0.02, 0.42, night)
	var fade_rate := maxf(delta, 0.001) * 4.2
	for si in _lights.size():
		var slot: Dictionary = _lights[si]
		var l: OmniLight3D = slot.node
		var tidx := slot_target[si]
		if si >= cap or tidx == -1:
			slot.energy = move_toward(slot.energy, 0.0, fade_rate)
			l.light_energy = slot.energy
			l.visible = slot.energy > 0.01
			if not l.visible:
				slot.has_anchor = false
				slot.pending_swap = false
			continue

		var target_pos := desired[tidx]
		if not slot.has_anchor:
			slot.anchor = target_pos
			slot.has_anchor = true
			slot.pending_swap = false
			l.position = target_pos
		elif slot.anchor.distance_to(target_pos) > 0.25:
			# Плавно гасим старый якорь до нуля и только потом переставляем свет (без скачков яркости).
			slot.target_anchor = target_pos
			slot.pending_swap = true

		if slot.pending_swap:
			slot.energy = move_toward(slot.energy, 0.0, fade_rate * 1.4)
			if slot.energy <= 0.02:
				slot.anchor = slot.target_anchor
				slot.pending_swap = false
				l.position = slot.anchor
		else:
			var slot_pos: Vector3 = slot.anchor
			var dist := slot_pos.distance_to(player_pos)
			var dist_k := 1.0 - smoothstep(LIGHT_RADIUS - 18.0, LIGHT_RADIUS, dist)
			var fire_k := 1.0
			if fire_active:
				var fd := slot_pos.distance_to(fire_pos)
				if fd < FIRE_SUPPRESS_OUTER:
					fire_k = lerpf(0.18, 1.0, smoothstep(FIRE_SUPPRESS_INNER, FIRE_SUPPRESS_OUTER, fd))
			var target_e := LIGHT_ENERGY * night_k * dist_k * fire_k
			slot.energy = move_toward(slot.energy, target_e, fade_rate)

		l.light_energy = slot.energy
		l.visible = slot.energy > 0.01
