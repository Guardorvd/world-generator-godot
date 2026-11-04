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

## crossable — виды путей, которые не мешают новой линии (звериные тропы не формируют полотна).
static func from_world(w: WorldData, surface: Heightfield = null, crossable: Array[String] = []):
	var result = load("res://scripts/trails/trail_generation_input.gd").new()
	result.size = Vector2i(w.W, w.H)
	result.cell_size = GameConfig.TILE
	result.heights = surface.hv.duplicate() if surface != null and w.outer == null else PackedFloat32Array()
	result.heights.resize(w.N)
	if surface != null and w.outer == null:
		# At cell centres ground_at is exactly the coarse vertex, or vertex zero
		# of its metre patch. Keep the original clamped sampling at the far edges.
		if surface.road_refinement != null:
			for key: int in surface.road_refinement.patches:
				result.heights[key] = surface.road_refinement.patches[key].h[0]
		for z in w.H:
			result.heights[z * w.W + w.W - 1] = surface.ground_at((w.W - 0.5) * GameConfig.TILE, (z + 0.5) * GameConfig.TILE)
		for x in w.W - 1:
			result.heights[(w.H - 1) * w.W + x] = surface.ground_at((x + 0.5) * GameConfig.TILE, (w.H - 0.5) * GameConfig.TILE)
	result.water.resize(w.N)
	result.rivers = w.river_cells().duplicate()
	result.forbidden.resize(w.N)
	for i in w.N:
		if surface == null:
			result.heights[i] = w.h[i] * GameConfig.HS
		elif w.outer != null:
			result.heights[i] = surface.ground_at((i % w.W + 0.5) * GameConfig.TILE, (i / w.W + 0.5) * GameConfig.TILE)
		result.water[i] = int(w.ocean[i] != 0 or w.lake[i] != 0 or w.h[i] <= 0.0)
	for group in [w.settlements, w.sites]:
		for place in group:
			for hut in place.huts: result.protect(Vector2(hut.x, hut.y), 3)
	for group in [w.bridges, w.tunnels]:
		for structure in group:
			var a := Vector2(structure.a % w.W, structure.a / w.W)
			var b := Vector2(structure.b % w.W, structure.b / w.W)
			var steps := maxi(1, ceili(a.distance_to(b)))
			for k in steps + 1: result.protect(a.lerp(b, float(k) / steps), 3)
	for route: Dictionary in w.trails:
		if route.kind in crossable: continue
		var pts := PackedVector2Array()
		var half := 0.0
		for p: Dictionary in route.pts:
			pts.append(Vector2(p.x, p.y) * GameConfig.TILE)
			half = maxf(half, float(p.w) * GameConfig.TILE * 0.5)
		result.existing_paths.append({points = pts, half_width = half})
	result.provenance = {source = "WorldData", seed = w.seed_num, river_policy = "strict"}
	return result

func protect(at: Vector2, radius: int) -> void:
	for z in range(maxi(0, floori(at.y) - radius), mini(size.y, ceili(at.y) + radius + 1)):
		for x in range(maxi(0, floori(at.x) - radius), mini(size.x, ceili(at.x) + radius + 1)):
			forbidden[z * size.x + x] = 1

## Data window in local metres, retaining exact nearby path segments and source policy.
func window(corner: Vector2i, side: Vector2i):
	var out = load("res://scripts/trails/trail_indexed_input.gd").new()
	out.size = side
	out.cell_size = cell_size
	for key in ["heights", "water", "rivers", "forbidden"]:
		var values = get(key)
		# Allocate only the requested window, never a temporary full-world copy.
		var cropped = values.slice(0, 0)
		for z in side.y:
			var first := (corner.y + z) * size.x + corner.x
			cropped.append_array(values.slice(first, first + side.x))
		out.set(key, cropped)
	var offset := Vector2(corner) * cell_size
	var box := Rect2(offset, Vector2(side) * cell_size).grow(32.0)
	for path in existing_paths:
		var points: PackedVector2Array = path.points
		var half := float(path.get("half_width", 2.0))
		var local := PackedVector2Array()
		for k in range(1, points.size()):
			var segment := Rect2(points[k - 1], points[k] - points[k - 1]).abs().grow(half + 2.0)
			if box.intersects(segment, true):
				if local.is_empty(): local.append(points[k - 1] - offset)
				local.append(points[k] - offset)
			elif not local.is_empty():
				out.existing_paths.append({points = local, half_width = half})
				local = PackedVector2Array()
		if not local.is_empty(): out.existing_paths.append({points = local, half_width = half})
	out.earthwork_limits = earthwork_limits.duplicate(true)
	out.river_policy = river_policy
	out.provenance = provenance.duplicate(true)
	out.provenance.world_origin = corner
	out.provenance.origin = corner
	out.provenance.world_seed = hash(provenance.get("game_seed", "snapshot"))
	return out
