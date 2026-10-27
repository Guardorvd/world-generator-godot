extends RefCounted
## Only lab fixtures live here. All construction, contacts and motion use production code.
static func definitions() -> Array[TrailDefinition]:
	var result: Array[TrailDefinition] = []
	for name in ["rollers", "tabletop", "berm", "braking"]:
		result.append(load("res://resources/trails/lab/%s.tres" % name) as TrailDefinition)
	return result

static func build(routes: Array[TrailDefinition], with_elements := true) -> Heightfield:
	return prepare(routes, with_elements).heights as Heightfield

## A failed edit leaves the caller's current session untouched.
static func prepare(routes: Array[TrailDefinition], with_elements := true) -> Dictionary:
	var w := WorldData.new()
	w.W = 64
	w.H = 64
	w.N = w.W * w.H
	w.seed_num = 17027
	w.seed_text = "Trail Lab"
	for owner in [w.geology, w.climate, w.civil]:
		for property: Dictionary in owner.get_property_list():
			var value: Variant = owner.get(property.name)
			if value is GridBuffer2D.Float32 or value is GridBuffer2D.Byte or value is GridBuffer2D.Int32:
				value.resize()
	w.biome.fill(Biomes.GRASS)
	w.dist_water.fill(100.0)
	w.lake_id.fill(-1)
	for z in w.H:
		for x in w.W:
			var i := z * w.W + x
			w.h[i] = (12.0 + (z + 0.5) * GameConfig.TILE * 0.035) / GameConfig.HS
			w.elev[i] = w.h[i]
			w.filled[i] = w.h[i]
			w.slope[i] = 0.035
	var errors := TrailBuilder.append_routes(w, routes)
	if not errors.is_empty(): return {heights = null, errors = errors}
	var h := Heightfield.new(w)
	if with_elements:
		errors = TrailBuilder.bake_elements(h, routes)
		if not errors.is_empty(): return {heights = null, errors = errors}
	h.obstacles = ForestObstacles.new(w, h)
	return {heights = h, errors = PackedStringArray()}
