extends Node3D
## Bounded, world-anchored patches sampled only from resident geography.
## No generation, worker jobs, per-tree nodes or persisted fog state.
const SHADER := preload("res://resources/local_mist.gdshader")
const SPACING := 112.0
const RADIUS := 360.0
const LIMIT := 48
var world: WorldData
var heights: Heightfield
var patches := {}
var _scan := 0.0

func setup(w: WorldData, h: Heightfield) -> void:
	world = w
	heights = h

func update(at: Vector3, day: DayCycle, delta: float, time: float) -> void:
	if not day.env.volumetric_fog_enabled:
		for entry: Dictionary in patches.values():
			entry.node.queue_free()
		patches.clear()
		_scan = 0.0
		return
	_scan -= delta
	if _scan <= 0.0:
		_scan = 0.5
		_refresh(Vector2(at.x, at.z))
	for key: Vector2i in patches.keys():
		var entry: Dictionary = patches[key]
		var distance := Vector2(entry.node.position.x - at.x, entry.node.position.z - at.z).length()
		var target := (1.0 - smoothstep(230.0, RADIUS, distance)) if entry.resident else 0.0
		entry.fade = move_toward(entry.fade, target, delta / 5.0)
		entry.material.set_shader_parameter("density", entry.strength * (0.12 + day.local_mist * 0.88) * entry.fade)
		entry.material.set_shader_parameter("tint", day.env.volumetric_fog_albedo)
		entry.material.set_shader_parameter("clock", time)
		if target == 0.0 and entry.fade <= 0.0:
			entry.node.queue_free()
			patches.erase(key)

func _refresh(at: Vector2) -> void:
	for entry: Dictionary in patches.values():
		entry.resident = false
	var center := Vector2i((at / SPACING).floor())
	for y in range(center.y - 3, center.y + 4):
		for x in range(center.x - 3, center.x + 4):
			var key := Vector2i(x, y)
			var point := (Vector2(key) + Vector2(0.5, 0.5)) * SPACING
			if point.distance_to(at) > RADIUS: continue
			var cell := Vector2i((point / GameConfig.TILE).floor())
			var in_plan := Rect2i(0, 0, world.W, world.H).has_point(cell)
			if not in_plan and (world.outer == null or not world.outer.committed(cell.x, cell.y)): continue
			if patches.has(key):
				patches[key].resident = true
				continue
			if patches.size() >= LIMIT: continue
			var data := world.tile_info(cell.x, cell.y)
			if data.is_empty() or not heights.known(point.x, point.y): continue
			var strength := suitability(data)
			if strength <= 0.0: continue
			var ground := heights.ground_at(point.x, point.y)
			var water := maxf(heights.river_level(point.x, point.y), heights.lake_level(point.x, point.y))
			if not in_plan: water = world.outer.water_at(point.x, point.y) * GameConfig.HS
			var wet := is_finite(water)
			var volume := FogVolume.new()
			volume.shape = RenderingServer.FOG_VOLUME_SHAPE_ELLIPSOID
			volume.size = Vector3(100.0, 12.0 if wet else 20.0, 100.0)
			volume.position = Vector3(point.x, maxf(ground, water) + 3.0, point.y)
			var material := ShaderMaterial.new()
			material.shader = SHADER
			volume.material = material
			add_child(volume)
			patches[key] = {node = volume, material = material, strength = strength, fade = 0.0, resident = true}

static func suitability(data: Dictionary) -> float:
	var biome: int = data.get("biome", Biomes.ROCK)
	if biome in [Biomes.DEEP, Biomes.OCEAN, Biomes.SHALLOW, Biomes.SNOW, Biomes.PEAK]: return 0.0
	var moisture := smoothstep(0.48, 0.82, float(data.get("moist", 0.0)))
	var lowland := 1.0 - smoothstep(0.35, 0.72, float(data.get("elev", 1.0)))
	var gentle := 1.0 - smoothstep(0.12, 0.4, float(data.get("slope", 1.0)))
	var habitat := 1.0 if biome in [Biomes.FOREST, Biomes.JUNGLE, Biomes.TAIGA, Biomes.SWAMP, Biomes.LAKE] or data.get("river", false) else 0.45
	var value := moisture * lowland * gentle * habitat
	return 0.007 * value if value > 0.2 else 0.0
