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
			var at := Vector2(x + 0.5, z + 0.5) * GameConfig.TILE
			var relief := 0.0
			if routes.size() == 1 and routes[0].id.begins_with("course_"):
				relief = 3.5 * sin(at.x / 36.0) * sin(at.y / 48.0) + 1.1 * sin(at.y / 9.0)
			w.h[i] = (12.0 + at.y * 0.035 + relief) / GameConfig.HS
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

## Each course occupies the same lab region; select a course instead of overlapping test lanes.
static func course(index: int, kind := "mountain") -> Array[TrailDefinition]:
	if index == 0: return definitions()
	var d := TrailDefinition.new()
	d.id = "course_%d" % index
	d.title = ["", "S-повороты", "Серпантин", "Кольцо", "Спираль", "Восьмёрка", "Flow-трасса", "Технический лес", "Байк-парк"][index]
	d.kind = kind
	d.width = 6.0 if kind == "road" else (3.0 if kind == "trail" else 5.0)
	d.surface = RoadSurface.PACKED if kind == "road" else RoadSurface.DIRT
	d.earthwork = 1.0
	d.auto_bank = 1.0
	var pts := PackedVector2Array()
	var count := 240
	for i in count + 1:
		var t := float(i) / count
		var a := t * TAU
		match index:
			1: pts.append(Vector2(128 + 52 * sin(a), 224 - 192 * t))
			2: pts.append(Vector2(128 + 72 * sin(a * 1.5), 224 - 192 * t))
			3: pts.append(Vector2(128, 128) + Vector2(sin(a), cos(a)) * 78)
			4: pts.append(Vector2(128, 128) + Vector2(sin(a * 1.65), cos(a * 1.65)) * lerpf(88, 28, t))
			5: pts.append(Vector2(128 + 78 * sin(a), 128 + 65 * sin(2 * a)))
			# Apex radius 1/(A·k²): flow ≈ 14 m (rideable at speed), technical ≈ 8 m (slower, tighter).
			6: pts.append(Vector2(128 + 30 * sin(a * 1.5), 224 - 192 * t))
			7: pts.append(Vector2(128 + 28 * sin(a * 2.0), 224 - 192 * t))
	d.closed = index in [3, 5]
	if d.closed: pts[-1] = pts[0]
	if index == 8:
		pts = park_points()
		d.auto_bank = 0.0 # the shaper's own superelevation (up to 38 %) would cancel the off-camber turn
	d.points = pts
	if index == 6: d.elements = TrailElementLibrary.compose(d, 4242, 0.5)
	if index == 7: d.elements = TrailElementLibrary.compose(d, 777, 0.5, 0.7, 0.85)
	if index == 8: d.elements = park_elements(d)
	return [d]

## Bike park line: a straight with the jump and boardwalk features, then a left turn and a straight.
static func park_points() -> PackedVector2Array:
	var pts := PackedVector2Array()
	var at := Vector2(128, 236)
	var heading := Vector2(0, -1)
	for i in 150:
		pts.append(at)
		at += heading
	for i in int(PI * 0.5 * 30.0):
		pts.append(at)
		heading = heading.rotated(-1.0 / 30.0)
		at += heading
	for i in 58:
		pts.append(at)
		at += heading
	pts.append(at)
	return pts

## Pump rollers, drop, table, northshore on the straight; off-camber on the outside of the turn.
static func park_elements(d: TrailDefinition) -> Array[TrailElement]:
	var T := TrailElement.Profile
	var result: Array[TrailElement] = []
	result.append(TrailElementLibrary.make(T.PUMP, 30.0, 25.0, 0.45, 1.0, 5))
	result.append(TrailElementLibrary.make(T.DROP, 62.0, 14.0, 0.8))
	result.append(TrailElementLibrary.make(T.TABLETOP, 92.0, 16.0, 0.8))
	var shore := TrailElementLibrary.make(T.NORTHSHORE, 125.0, 22.0, 1.0)
	shore.gap = 1.2
	result.append(shore)
	result.append(TrailElementLibrary.make(T.OFF_CAMBER, 175.0, 22.0, 0.8, signf(d.curvature_at(175.0))))
	return result
