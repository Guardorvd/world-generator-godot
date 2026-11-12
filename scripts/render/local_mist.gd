extends Node3D
## Bounded, world-anchored patches sampled only from resident geography.
## No generation, worker jobs, per-tree nodes or persisted fog state.
const SHADER := preload("res://resources/local_mist.gdshader")
const SPACING := 112.0
const RADIUS := 360.0
const LIMIT := 48
const BUILD_BUDGET := 2
const MATERIAL_INTERVAL := 0.1
const OFFSETS := [Vector2.ZERO, Vector2(-28, 0), Vector2(28, 0), Vector2(0, -28), Vector2(0, 28)]
var world: WorldData
var heights: Heightfield
var patches := {}
var _scan := 0.0
var _material_elapsed := 0.0
var _pending: Array[Vector2i] = []
var _examined := {}
var _last_at := Vector2.INF
var stats := {evaluated = 0, created = 0, material_updates = 0}

func setup(w: WorldData, h: Heightfield) -> void:
	world = w
	heights = h

func update(at: Vector3, day: DayCycle, delta: float, time: float) -> void:
	if not day.env.volumetric_fog_enabled:
		for entry: Dictionary in patches.values():
			entry.node.queue_free()
		patches.clear()
		_pending.clear()
		_examined.clear()
		_material_elapsed = 0.0
		_last_at = Vector2.INF
		_scan = 0.0
		return
	var point := Vector2(at.x, at.z)
	_scan -= delta
	if _scan <= 0.0 or point.distance_to(_last_at) > SPACING:
		_scan = 0.5
		_refresh(point)
	_build_pending()
	_material_elapsed += delta
	if _material_elapsed + 0.000001 < MATERIAL_INTERVAL: return
	var step := _material_elapsed
	_material_elapsed = 0.0
	for key: Vector2i in patches.keys():
		var entry: Dictionary = patches[key]
		var distance := Vector2(entry.node.position.x - at.x, entry.node.position.z - at.z).length()
		var target := (1.0 - smoothstep(230.0, RADIUS, distance)) if entry.resident else 0.0
		entry.fade = move_toward(entry.fade, target, step / 5.0)
		entry.material.set_shader_parameter("density", entry.strength * (0.12 + day.local_mist * 0.88) * entry.fade)
		entry.material.set_shader_parameter("tint", day.env.volumetric_fog_albedo)
		entry.material.set_shader_parameter("clock", time)
		stats.material_updates += 1
		if target == 0.0 and entry.fade <= 0.0:
			entry.node.queue_free()
			patches.erase(key)

func _refresh(at: Vector2) -> void:
	_last_at = at
	for key: Vector2i in patches.keys():
		var entry: Dictionary = patches[key]
		# Entire volume is outside the 190 m buffer: release before admission.
		if entry.point.distance_to(at) > RADIUS:
			entry.node.queue_free()
			patches.erase(key)
		else:
			entry.resident = _resident(entry.point)
	if _pending.is_empty(): _examined.clear()
	var wanted: Array[Vector2i] = []
	var center := Vector2i((at / SPACING).floor())
	# Include the asymmetric cell edge and the maximum sampling offset.
	for y in range(center.y - 4, center.y + 5):
		for x in range(center.x - 4, center.x + 5):
			var key := Vector2i(x, y)
			var point := (Vector2(key) + Vector2(0.5, 0.5)) * SPACING
			if point.distance_to(at) > RADIUS + 28.0: continue
			if not patches.has(key) and not _examined.has(key): wanted.append(key)
	wanted.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return ((Vector2(a) + Vector2.ONE * 0.5) * SPACING).distance_squared_to(at) < ((Vector2(b) + Vector2.ONE * 0.5) * SPACING).distance_squared_to(at))
	_pending = wanted
	for key: Vector2i in _examined.keys():
		if Vector2(key - center).length_squared() > 32.0: _examined.erase(key)

func _resident(point: Vector2) -> bool:
	var cell := Vector2i((point / GameConfig.TILE).floor())
	return Rect2i(0, 0, world.W, world.H).has_point(cell) or (world.outer != null and world.outer.committed(cell.x, cell.y))

func _build_pending() -> void:
	for i in BUILD_BUDGET:
		if _pending.is_empty() or patches.size() >= LIMIT: return
		var key: Vector2i = _pending.pop_front()
		_examined[key] = true
		stats.evaluated += 1
		var site := _site(key)
		if site.is_empty() or site.point.distance_to(_last_at) > RADIUS: continue
		var volume := FogVolume.new()
		volume.shape = RenderingServer.FOG_VOLUME_SHAPE_ELLIPSOID
		volume.size = site.size
		volume.position = Vector3(site.point.x, site.height + 3.0, site.point.y)
		var material := ShaderMaterial.new()
		material.shader = SHADER
		volume.material = material
		add_child(volume)
		patches[key] = {node = volume, material = material, point = site.point, strength = site.strength, fade = 0.0, resident = true}
		stats.created += 1

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
		var strength := suitability(data)
		if strength <= 0.0: continue
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
	var relief := 0.0
	for offset: Vector2 in OFFSETS.slice(1):
		var point: Vector2 = best.point + offset
		if not _resident(point) or not heights.known(point.x, point.y):
			relief = maxf(relief, 20.0)
			continue
		relief = maxf(relief, absf(heights.ground_at(point.x, point.y) - float(best.height)))
	var width := lerpf(100.0, 48.0, smoothstep(3.0, 16.0, relief))
	best.size.x = width
	best.size.z = width
	return best

static func suitability(data: Dictionary) -> float:
	var biome: int = data.get("biome", Biomes.ROCK)
	if biome in [Biomes.DEEP, Biomes.OCEAN, Biomes.SHALLOW, Biomes.SNOW, Biomes.PEAK]: return 0.0
	var moisture := smoothstep(0.48, 0.82, float(data.get("moist", 0.0)))
	var lowland := 1.0 - smoothstep(0.35, 0.72, float(data.get("elev", 1.0)))
	var gentle := 1.0 - smoothstep(0.12, 0.4, float(data.get("slope", 1.0)))
	var habitat := 1.0 if biome in [Biomes.FOREST, Biomes.JUNGLE, Biomes.TAIGA, Biomes.SWAMP, Biomes.LAKE] or data.get("river", false) else 0.45
	var value := moisture * lowland * gentle * habitat
	return 0.007 * value if value > 0.2 else 0.0
