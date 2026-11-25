extends Node3D
## Bounded, world-anchored patches sampled only from resident geography.
## No generation, worker jobs, per-tree nodes or persisted fog state.
const VOLUME_SHADER := preload("res://resources/local_mist.gdshader")
const ANALYTIC_SHADER := preload("res://resources/analytic_mist.gdshader")
const SPACING := 112.0
const RADIUS := 218.0
const FADE_BEGIN := 140.0
const FADE_END := 190.0
const LIMIT := 20
const POOL_LIMIT := LIMIT
const PLAN_CACHE_MAX := 1024
const BUILD_BUDGET := 2
const MATERIAL_INTERVAL := 0.1
const OFFSETS := [Vector2.ZERO, Vector2(-28, 0), Vector2(28, 0), Vector2(0, -28), Vector2(0, 28)]
enum Mode { OFF, ANALYTIC, VOLUMETRIC }

var use_node_pool := true
var world: WorldData
var heights: Heightfield
var _atm: WorldAtmosphereConfig = null
var patches := {}
var _pool: Array[Node3D] = []
var mode := Mode.OFF
var _proxy_mesh: BoxMesh
var _scan := 0.0
var _material_elapsed := 0.0
var _pending: Array[Vector2i] = []
var _examined := {}
var _last_at := Vector2.INF
var _plan_sites := {} # Immutable plan geography only; regional fields may be replaced/unloaded.
var stats := {evaluated = 0, sampled = 0, created = 0, material_updates = 0, cache_hits = 0, pooled = 0, reused = 0}

func setup(w: WorldData, h: Heightfield) -> void:
	world = w
	heights = h
	_atm = WorldTemplate.atmosphere_config(w.template_id)
	_plan_sites.clear()

func set_quality(level: int, env: Environment) -> void:
	var next := Mode.OFF
	if level > 0 and level < GameSettings.FOG_OFF and env.fog_enabled:
		next = Mode.VOLUMETRIC if env.volumetric_fog_enabled else Mode.ANALYTIC
	if next == mode:
		return
	for key: Vector2i in patches.keys():
		_remove_patch(key)
	_clear_pool()
	_pending.clear()
	_examined.clear()
	_scan = 0.0
	_material_elapsed = 0.0
	mode = next
	if mode == Mode.ANALYTIC and _proxy_mesh == null:
		var material := ShaderMaterial.new()
		material.shader = ANALYTIC_SHADER
		# Draw onto the opaque scene before water and other transparent effects.
		material.render_priority = -1
		_proxy_mesh = BoxMesh.new()
		_proxy_mesh.size = Vector3.ONE * 2.0
		_proxy_mesh.material = material


## Прогреть формат текущего режима без запроса географии и изменения живых пятен.
func make_pipeline_probe() -> Node3D:
	if mode == Mode.OFF:
		return null
	var probe := _patch_node(Vector3.ONE)
	# Скрытый меш участвует в Surface. Для compute-прохода нужен видимый объём с плотностью 0.
	if probe is FogVolume:
		probe.material.set_shader_parameter("density", 0.0)
	else:
		probe.hide()
	return probe


func update(at: Vector3, delta: float) -> void:
	if mode == Mode.OFF or not visible:
		return
	var point := Vector2(at.x, at.z)
	_scan -= delta
	if _scan <= 0.0 or point.distance_to(_last_at) > SPACING * 0.5:
		_scan = 0.5
		_refresh(point)
	_build_pending()
	_material_elapsed += delta
	if _material_elapsed + 0.000001 < MATERIAL_INTERVAL: return
	var step := _material_elapsed
	_material_elapsed = 0.0
	for key: Vector2i in patches.keys():
		var entry: Dictionary = patches[key]
		var distance := at.distance_to(entry.node.position)
		var target := (1.0 - smoothstep(FADE_BEGIN, FADE_END, distance)) if entry.resident else 0.0
		entry.fade = move_toward(entry.fade, target, step / 0.9)
		var density: float = entry.strength * entry.fade
		if density != entry.density:
			if mode == Mode.VOLUMETRIC:
				entry.node.material.set_shader_parameter("density", density)
			else:
				entry.node.set_instance_shader_parameter("density", density)
			entry.node.visible = density > 0.0
			entry.density = density
			stats.material_updates += 1
		if not entry.resident and entry.fade <= 0.0:
			_remove_patch(key)

func _refresh(at: Vector2) -> void:
	_last_at = at
	for key: Vector2i in patches.keys():
		var entry: Dictionary = patches[key]
		# The distance fade ends inside this radius, leaving time to preload sites.
		if entry.point.distance_to(at) > RADIUS:
			_remove_patch(key)
		else:
			entry.resident = _resident(entry.point)
	if _pending.is_empty(): _examined.clear()
	var wanted: Array[Vector2i] = []
	var center := Vector2i((at / SPACING).floor())
	var cells := Rect2i(center - Vector2i(2, 2), Vector2i(5, 5))
	# Include the asymmetric cell edge and the maximum sampling offset.
	for y in range(cells.position.y, cells.end.y):
		for x in range(cells.position.x, cells.end.x):
			var key := Vector2i(x, y)
			var point := (Vector2(key) + Vector2(0.5, 0.5)) * SPACING
			if point.distance_to(at) > RADIUS + 28.0: continue
			if not patches.has(key) and not _examined.has(key): wanted.append(key)
	wanted.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return ((Vector2(a) + Vector2.ONE * 0.5) * SPACING).distance_squared_to(at) < ((Vector2(b) + Vector2.ONE * 0.5) * SPACING).distance_squared_to(at))
	_pending = wanted
	for key: Vector2i in _examined.keys():
		if not cells.has_point(key): _examined.erase(key)

func _exit_tree() -> void:
	_clear_pool()

func _clear_pool() -> void:
	for node: Node3D in _pool:
		if is_instance_valid(node):
			node.queue_free()
	_pool.clear()

func _resident(point: Vector2) -> bool:
	var cell := Vector2i((point / GameConfig.TILE).floor())
	return Rect2i(0, 0, world.W, world.H).has_point(cell) or (world.outer != null and world.outer.committed(cell.x, cell.y))

func _build_pending() -> void:
	for i in BUILD_BUDGET:
		if _pending.is_empty() or patches.size() >= LIMIT: return
		var key: Vector2i = _pending.pop_front()
		_examined[key] = true
		stats.evaluated += 1
		var site := _cached_site(key)
		if site.is_empty() or site.point.distance_to(_last_at) > RADIUS: continue
		var node := _acquire_patch_node(site.size)
		node.position = Vector3(site.point.x, site.height + 3.0, site.point.y)
		patches[key] = {node = node, point = site.point, strength = site.strength, fade = 0.0, density = 0.0, resident = true}
		stats.created += 1


func _acquire_patch_node(size: Vector3) -> Node3D:
	if use_node_pool and not _pool.is_empty():
		var reused: Node3D = _pool.pop_back()
		if mode == Mode.VOLUMETRIC:
			(reused as FogVolume).size = size
			(reused as FogVolume).material.set_shader_parameter("density", 0.0)
		else:
			reused.scale = size * 0.5
			(reused as GeometryInstance3D).set_instance_shader_parameter("density", 0.0)
		reused.hide()
		stats.reused += 1
		return reused
	var created := _patch_node(size)
	created.hide()
	add_child(created)
	return created


func _patch_node(size: Vector3) -> Node3D:
	if mode == Mode.VOLUMETRIC:
		var volume := FogVolume.new()
		volume.shape = RenderingServer.FOG_VOLUME_SHAPE_ELLIPSOID
		volume.size = size
		var material := ShaderMaterial.new()
		material.shader = VOLUME_SHADER
		volume.material = material
		return volume
	var proxy := MeshInstance3D.new()
	proxy.mesh = _proxy_mesh
	proxy.scale = size * 0.5
	proxy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return proxy


func _remove_patch(key: Vector2i) -> void:
	var node: Node3D = patches[key].node
	node.hide()
	if mode == Mode.VOLUMETRIC:
		(node as FogVolume).material.set_shader_parameter("density", 0.0)
	else:
		(node as GeometryInstance3D).set_instance_shader_parameter("density", 0.0)
	if use_node_pool and _pool.size() < POOL_LIMIT:
		_pool.append(node)
		stats.pooled += 1
	else:
		node.queue_free()
	patches.erase(key)

func _cached_site(key: Vector2i) -> Dictionary:
	if _plan_sites.has(key):
		stats.cache_hits += 1
		return _plan_sites[key]
	stats.sampled += 1
	var site := _site(key)
	# All selection and relief probes must be inside the immutable plan. Never cache
	# a partial regional result or a missing field: it could arrive on the next scan.
	var center := (Vector2(key) + Vector2.ONE * 0.5) * SPACING
	var bounds := Rect2(Vector2.ZERO, Vector2(world.W, world.H) * GameConfig.TILE).grow(-60.0)
	if bounds.has_point(center):
		if _plan_sites.size() >= PLAN_CACHE_MAX:
			_plan_sites.erase(_plan_sites.keys()[0])
		_plan_sites[key] = site
	return site

func _site(key: Vector2i) -> Dictionary:
	var center := (Vector2(key) + Vector2.ONE * 0.5) * SPACING
	var best := {}
	var score := -INF
	for offset: Vector2 in OFFSETS:
		var point := center + offset
		if not _resident(point) or not heights.known(point.x, point.y): continue
		var cell := Vector2i((point / GameConfig.TILE).floor())
		var data := world.tile_info(cell.x, cell.y)
		if data.is_empty(): continue
		var strength := suitability(data, _atm)
		if strength <= 0.0: continue
		if _atm != null:
			strength *= _atm.local_mist_patch_mul
		var ground := heights.ground_at(point.x, point.y)
		var water := maxf(heights.river_level(point.x, point.y), heights.lake_level(point.x, point.y))
		if not Rect2i(0, 0, world.W, world.H).has_point(cell):
			water = world.outer.water_at(point.x, point.y) * GameConfig.HS
		# Stable tie breaking; prefer wet low ground, independent of camera/visit order.
		var candidate := strength * (1.25 if is_finite(water) else 1.0) - maxf(ground, water) * 0.00001
		if candidate <= score: continue
		score = candidate
		best = {point = point, strength = strength, height = maxf(ground, water), size = Vector3(100, 12 if is_finite(water) else 20, 100)}
	if best.is_empty(): return best
	# Narrow a bank on uneven terrain instead of suspending it over a slope.
	var relief := Vector2.ZERO
	for offset: Vector2 in OFFSETS.slice(1):
		var point: Vector2 = best.point + offset
		var axis := 0 if offset.x != 0.0 else 1
		if not _resident(point) or not heights.known(point.x, point.y):
			relief[axis] = maxf(relief[axis], 20.0)
			continue
		relief[axis] = maxf(relief[axis], absf(heights.ground_at(point.x, point.y) - float(best.height)))
	# Different footprints, but stable through streaming and never larger than the budget.
	var phase := float(key.x) * 1.37 + float(key.y) * 2.11 + float(posmod(world.seed_num, 997))
	best.size.x = maxf(48.0, lerpf(100.0, 48.0, smoothstep(3.0, 16.0, relief.x)) * (0.9 + 0.1 * sin(phase)))
	best.size.z = maxf(48.0, lerpf(100.0, 48.0, smoothstep(3.0, 16.0, relief.y)) * (0.9 + 0.1 * cos(phase)))
	return best

static func suitability(data: Dictionary, atm: WorldAtmosphereConfig = null) -> float:
	var biome: int = data.get("biome", Biomes.ROCK)
	if biome in [Biomes.DEEP, Biomes.OCEAN, Biomes.SHALLOW, Biomes.SNOW, Biomes.PEAK]: return 0.0
	var moist_lo := atm.local_mist_moist_range.x if atm != null else 0.48
	var moist_hi := atm.local_mist_moist_range.y if atm != null else 0.82
	var slope_lo := atm.local_mist_slope_range.x if atm != null else 0.12
	var slope_hi := atm.local_mist_slope_range.y if atm != null else 0.4
	var min_suit := atm.local_mist_min_suitability if atm != null else 0.2
	var moisture := smoothstep(moist_lo, moist_hi, float(data.get("moist", 0.0)))
	var lowland := 1.0 - smoothstep(0.35, 0.72, float(data.get("elev", 1.0)))
	var gentle := 1.0 - smoothstep(slope_lo, slope_hi, float(data.get("slope", 1.0)))
	var habitat := 1.0 if biome in [Biomes.FOREST, Biomes.JUNGLE, Biomes.TAIGA, Biomes.SWAMP, Biomes.LAKE] or data.get("river", false) else 0.45
	var value := moisture * lowland * gentle * habitat
	return 0.007 * value if value > min_suit else 0.0
