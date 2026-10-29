extends RefCounted
## Numeric contract, independent of RefCounted owners and native acceleration objects.
const VERSION := 1

static func capture(h: Heightfield, stage: String) -> Dictionary:
	var r := h.road_refinement
	return {version = VERSION, stage = stage, width = h.world.W, height = h.world.H,
		hv = h.hv, hv_raw = h.hv_raw, water_level = h.water_level, ribbons = h.ribbons.duplicate(true),
		structures = h.structures.duplicate(true), decks = h._deck_keys.duplicate(),
		patches = r.patches.duplicate(true) if r != null else {},
		shaping = r.trail_shaping.duplicate(true) if r != null else {},
		baked = r.trail_elements_baked if r != null else false}

static func restore(w: WorldData, data: Dictionary, stage: String) -> Heightfield:
	if not valid(w, data, stage): return null
	var h := Heightfield.new()
	h.world = w
	h.hv = data.hv
	h.hv_raw = data.hv_raw
	h.water_level = data.water_level
	h.ribbons = data.ribbons
	h.structures = data.structures
	h._deck_keys = data.decks
	h.index_ribbons()
	h.index_structures()
	if stage == "final":
		h.road_refinement = RoadRefinement.from_patches(data.patches, w.H)
		h.road_refinement.trail_shaping = data.shaping
		h.road_refinement.trail_elements_baked = data.baked
	return h

static func valid(w: WorldData, d: Dictionary, stage: String) -> bool:
	if d.get("version") != VERSION or d.get("stage") != stage or d.get("width") != w.W or d.get("height") != w.H: return false
	for field: String in ["hv", "hv_raw", "water_level"]:
		if not d.get(field) is PackedFloat32Array or d[field].size() != w.N: return false
	for value: float in d.hv:
		if not is_finite(value): return false
	for field: String in ["patches", "shaping", "decks"]:
		if not d.get(field) is Dictionary: return false
	if not d.get("baked") is bool or not d.get("ribbons") is Array or not d.get("structures") is Array: return false
	for ribbon: Variant in d.ribbons:
		if not ribbon is Array: return false
		for point: Variant in ribbon:
			if not point is Dictionary: return false
			for field: String in ["x", "z", "w", "y", "depth"]:
				if not point.get(field) is float and not point.get(field) is int: return false
			if not point.get("left") is Vector3 or not point.get("right") is Vector3: return false
	for s: Variant in d.structures:
		if not s is Dictionary: return false
		for field: String in ["ax", "az", "ay", "bx", "bz", "by", "half", "len", "ux", "uz"]:
			if not s.get(field) is float and not s.get(field) is int: return false
		if not s.get("tunnel") is bool: return false
	for key: Variant in d.patches:
		if not key is int or key < 0 or key >= w.N or key % w.W == w.W - 1 or key / w.W >= w.H - 1: return false
		var p: Variant = d.patches[key]
		if not p is Dictionary: return false
		var types := {h = TYPE_PACKED_FLOAT32_ARRAY, color = TYPE_PACKED_COLOR_ARRAY, uv = TYPE_PACKED_VECTOR2_ARRAY, surface = TYPE_PACKED_BYTE_ARRAY, road = TYPE_PACKED_BYTE_ARRAY}
		for field: String in types:
			if typeof(p.get(field)) != types[field] or p[field].size() != RoadRefinement.STRIDE * RoadRefinement.STRIDE: return false
	return stage == "final" or (d.patches.is_empty() and d.structures.is_empty() and not d.baked)

static func mesh_valid(a: Variant, allow_empty := true) -> bool:
	if not a is Array: return false
	if a.is_empty(): return allow_empty
	if a.size() != Mesh.ARRAY_MAX or not a[Mesh.ARRAY_VERTEX] is PackedVector3Array: return false
	var n: int = a[Mesh.ARRAY_VERTEX].size()
	if n == 0: return false
	var types := {Mesh.ARRAY_NORMAL: TYPE_PACKED_VECTOR3_ARRAY, Mesh.ARRAY_COLOR: TYPE_PACKED_COLOR_ARRAY,
		Mesh.ARRAY_TEX_UV: TYPE_PACKED_VECTOR2_ARRAY, Mesh.ARRAY_TEX_UV2: TYPE_PACKED_VECTOR2_ARRAY}
	for slot: int in types:
		if a[slot] != null and (typeof(a[slot]) != types[slot] or a[slot].size() != n): return false
	if a[Mesh.ARRAY_INDEX] != null:
		if not a[Mesh.ARRAY_INDEX] is PackedInt32Array or a[Mesh.ARRAY_INDEX].size() % 3 != 0: return false
		for id: int in a[Mesh.ARRAY_INDEX]:
			if id < 0 or id >= n: return false
	return true
