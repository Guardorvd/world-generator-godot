class_name TrailGenerationInput
extends Resource
## Data-only generation boundary. No world publication, scene objects or lab defaults.
enum RiverPolicy { STRICT, LAB_DRY_CHANNELS }
@export var size := Vector2i.ZERO
@export var cell_size := 4.0
@export var origin := Vector2.ZERO
@export var heights := PackedFloat32Array()
@export var water := PackedByteArray()
@export var rivers := PackedByteArray()
@export var forbidden := PackedByteArray()
@export var existing_paths: Array[Dictionary] = []
@export var earthwork_limits := {max_cut = 2.0, max_fill = 2.0, modification = 1.0}
@export var river_policy: RiverPolicy = RiverPolicy.STRICT
@export var provenance := {}
var _working := PackedFloat32Array()
var cut_errors := PackedStringArray()

func validate() -> PackedStringArray:
	var errors := PackedStringArray()
	var n := size.x * size.y
	if size.x < 2 or size.y < 2 or not is_finite(cell_size) or cell_size <= 0 or not origin.is_finite(): errors.append("неверный размер рельефа")
	if heights.size() != n or water.size() != n or rivers.size() != n or forbidden.size() != n: errors.append("неполные маски входа генератора")
	for h in heights:
		if not is_finite(h): errors.append("неконечная высота"); break
	for key in ["max_cut", "max_fill", "modification"]:
		if not earthwork_limits.has(key) or not is_finite(float(earthwork_limits[key])) or float(earthwork_limits[key]) < 0: errors.append("неверный предел земляных работ: " + key)
	if float(earthwork_limits.get("modification", 1.0)) > 1.0: errors.append("изменение рельефа выше 100%")
	if river_policy == RiverPolicy.LAB_DRY_CHANNELS and provenance.get("source", "") != "Trail Lab": errors.append("сухие русла допускаются только явным адаптером Trail Lab")
	if river_policy not in [RiverPolicy.STRICT, RiverPolicy.LAB_DRY_CHANNELS]: errors.append("неизвестная политика рек")
	for path in existing_paths:
		if not path.get("points") is PackedVector2Array or path.points.size() < 2 or not is_finite(float(path.get("half_width", 2.0))) or float(path.get("half_width", 2.0)) < 0: errors.append("неверный существующий путь")
	return errors

func ground(at: Vector2) -> float:
	return _sample(_working if not _working.is_empty() else heights, at)

func natural_ground(at: Vector2) -> float:
	return _sample(heights, at)

func _sample(y: PackedFloat32Array, at: Vector2) -> float:
	var p := (at - origin) / cell_size - Vector2.ONE * 0.5
	p = p.clamp(Vector2.ZERO, Vector2(size - Vector2i.ONE))
	var x := mini(floori(p.x), size.x - 2)
	var z := mini(floori(p.y), size.y - 2)
	var tx := p.x - x
	var tz := p.y - z
	var a := y[z * size.x + x]
	var b := y[z * size.x + x + 1]
	var c := y[(z + 1) * size.x + x]
	var d := y[(z + 1) * size.x + x + 1]
	return a + (b - a) * tx + (c - a) * tz if tx + tz <= 1.0 else d + (c - d) * (1.0 - tx) + (b - d) * (1.0 - tz)

func blocked(at: Vector2) -> bool:
	var p := Vector2i(((at - origin) / cell_size).floor())
	if p.x < 0 or p.y < 0 or p.x >= size.x or p.y >= size.y: return true
	var i := p.y * size.x + p.x
	if water[i] != 0 or forbidden[i] != 0 or (river_policy == RiverPolicy.STRICT and rivers[i] != 0): return true
	for path in existing_paths:
		var pts: PackedVector2Array = path.points
		for k in range(1, pts.size()):
			if Grid.segment_dist(at.x, at.y, pts[k - 1].x, pts[k - 1].y, pts[k].x, pts[k].y) <= float(path.get("half_width", 2.0)) + 2.0: return true
	return false

func apply_cuts(cuts: Array) -> void:
	cut_errors.clear()
	var next := heights.duplicate()
	for cut: Dictionary in cuts:
		var pts: PackedVector2Array = cut.points
		var depths: PackedFloat32Array = cut.depth
		if pts.size() != depths.size() or pts.size() < 2: cut_errors.append("неполная врезка"); return
		for i in depths:
			if not is_finite(i) or i < 0 or (not earthwork_limits.get("unlimited", false) and i > float(earthwork_limits.max_cut)): cut_errors.append("врезка превышает max_cut или имеет неверную глубину"); return
		var deepest := 0.0
		for depth in depths: deepest = maxf(deepest, depth)
		if pts.is_empty(): continue
		var box := Rect2(pts[0], Vector2.ZERO)
		for p in pts: box = box.expand(p)
		box = box.grow(float(cut.half) + deepest * float(cut.wall) + cell_size)
		var lo := Vector2i(((box.position - origin) / cell_size).floor()).max(Vector2i.ZERO)
		var hi := Vector2i(((box.end - origin) / cell_size).ceil()).min(size - Vector2i.ONE)
		for z in range(lo.y, hi.y + 1):
			for x in range(lo.x, hi.x + 1):
				var at := origin + Vector2(x + 0.5, z + 0.5) * cell_size
				for k in range(1, pts.size()):
					var ab := pts[k] - pts[k - 1]
					var t := clampf((at - pts[k - 1]).dot(ab) / maxf(ab.length_squared(), 0.0001), 0, 1)
					var depth := lerpf(depths[k - 1], depths[k], t)
					var reach := float(cut.half) + depth * float(cut.wall) + cell_size * 0.5
					var displacement := depth * (1.0 - smoothstep(float(cut.half), reach, at.distance_to(pts[k - 1] + ab * t)))
					if displacement > 0.001 and blocked(at): cut_errors.append("врезка затрагивает защищённую область"); return
					var index := z * size.x + x
					next[index] = minf(next[index], heights[index] - displacement)
	_working = next

func fingerprint() -> String:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(var_to_bytes(_canonical([size, cell_size, origin, heights, water, rivers, forbidden, existing_paths, earthwork_limits, river_policy, provenance])))
	return h.finish().hex_encode()

static func _canonical(value: Variant) -> Variant:
	if value is Dictionary:
		var keys: Array = value.keys()
		keys.sort_custom(func(a: Variant, b: Variant) -> bool: return str(a) < str(b))
		var entries := []
		for key in keys: entries.append([key, _canonical(value[key])])
		return entries
	if value is Array:
		var items := []
		for item in value: items.append(_canonical(item))
		return items
	return value

## Audit actual refined vertices, not just feature specifications. A rejection never publishes the heightfield.
func audit_earthworks(h: Heightfield) -> PackedStringArray:
	var errors := PackedStringArray()
	var seen := {}
	for key: int in h.road_refinement.patches:
		var patch: Dictionary = h.road_refinement.patches[key]
		for z in RoadRefinement.STRIDE:
			for x in RoadRefinement.STRIDE:
				var vertex := Vector2i((key % h.world.W) * RoadRefinement.DIV + x, (key / h.world.W) * RoadRefinement.DIV + z)
				if seen.has(vertex): continue
				seen[vertex] = true
				var at := Vector2(vertex) * RoadRefinement.STEP + Vector2.ONE * GameConfig.TILE * 0.5
				var delta: float = patch.h[z * RoadRefinement.STRIDE + x] - natural_ground(at)
				if not earthwork_limits.get("unlimited", false) and (delta < -float(earthwork_limits.max_cut) - 0.05 or delta > float(earthwork_limits.max_fill) + 0.05):
					return PackedStringArray(["готовое полотно превышает предел выемки/насыпи у %s: %+.2f м" % [at, delta]])
				if absf(delta) > 0.05 and blocked(at): return PackedStringArray(["земляные работы затронули воду, запрет или существующий путь у %s" % at])
	return errors

static func from_world(w: WorldData):
	var result = load("res://scripts/trails/trail_generation_input.gd").new()
	result.size = Vector2i(w.W, w.H)
	result.cell_size = GameConfig.TILE
	result.heights.resize(w.N)
	result.water.resize(w.N)
	result.rivers = w.river_cells().duplicate()
	result.forbidden.resize(w.N)
	for i in w.N:
		result.heights[i] = w.h[i] * GameConfig.HS
		result.water[i] = int(w.ocean[i] != 0 or w.lake[i] != 0 or w.h[i] <= 0.0)
	for route: Dictionary in w.trails:
		var pts := PackedVector2Array()
		var half := 0.0
		for p: Dictionary in route.pts:
			pts.append(Vector2(p.x, p.y) * GameConfig.TILE)
			half = maxf(half, float(p.w) * GameConfig.TILE * 0.5)
		result.existing_paths.append({points = pts, half_width = half})
	result.provenance = {source = "WorldData", seed = w.seed_num, river_policy = "strict"}
	return result
