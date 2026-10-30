extends RefCounted
## Only lab fixtures live here. All construction, contacts and motion use production code.
static func definitions() -> Array[TrailDefinition]:
	var result: Array[TrailDefinition] = []
	for name in ["rollers", "tabletop", "berm", "braking"]:
		result.append(load("res://resources/trails/lab/%s.tres" % name) as TrailDefinition)
	return result

static func build(routes: Array[TrailDefinition], with_elements := true) -> Heightfield:
	return prepare(routes, with_elements).heights as Heightfield

## Test grounds under a course: "flat" is the lab's own gentle slope; "hills" and "mountain" take a 256 m window
## of the world generator's relief (StageRelief noise, normalisation and micro relief; no rivers, roads or towns);
## "site" is a saved piece of a real prepared world (TrailSite: roads, water, bridges, surfaces as in the game).
const GROUNDS := ["flat", "hills", "mountain", "site", "polygon"]
## "polygon" — the main polygon's own 512 m land (a slope with hills and a ravine) under its own course (scripts/lab/trail_lab_polygon.gd).
const Polygon = preload("res://scripts/lab/trail_lab_polygon.gd")
## Wanted fall from edge to edge of the window, m.
const GROUND_DROP := {hills = Vector2(14, 30), mountain = Vector2(22, 40)}
static var _relief := {}
## Saved real-world site of the "site" ground (tools/trail_site_export.gd writes it).
const SITE := "res://resources/trails/sites/ushchelye_bridge.tsite"
static var _site: TrailSite
static var site_error := ""
## Time of the last site open, ms (-1 — taken from memory).
static var site_open_ms := -1.0

## The saved site, opened once per run; null with site_error when the file is missing or unreadable.
static func site() -> TrailSite:
	site_open_ms = -1.0
	if _site != null: return _site
	var started := Time.get_ticks_usec()
	var got := TrailSite.open(SITE)
	site_error = got.get("error", "")
	_site = got.get("site")
	site_open_ms = (Time.get_ticks_usec() - started) / 1000.0
	return _site

## Natural ground under the lab, m: what prepare() writes into the world and what the composer reads.
static func ground(at: Vector2, kind := "flat", course := true) -> float:
	if kind == "site":
		return site().ground_at(at) if site() != null else 0.0
	if kind == "polygon": return Polygon.ground(at)
	if kind == "flat" or not GROUND_DROP.has(kind):
		var bumps := 3.5 * sin(at.x / 36.0) * sin(at.y / 48.0) + 1.1 * sin(at.y / 9.0) if course else 0.0
		return 12.0 + at.y * 0.035 + bumps
	var cells := relief(kind)
	var fx := clampf(at.x / GameConfig.TILE - 0.5, 0.0, 63.0)
	var fz := clampf(at.y / GameConfig.TILE - 0.5, 0.0, 63.0)
	var ix := mini(floori(fx), 62)
	var iz := mini(floori(fz), 62)
	var a := lerpf(cells[iz * 64 + ix], cells[iz * 64 + ix + 1], fx - ix)
	var b := lerpf(cells[(iz + 1) * 64 + ix], cells[(iz + 1) * 64 + ix + 1], fx - ix)
	return 12.0 + lerpf(a, b, fz - iz)

## 64 × 64 cells of world relief in metres above the window's lowest point, highest side at the course start
## (large z). Picked once per kind from an 8 × 8 grid of windows of the seed's start area by the fall from one
## edge to the opposite one (not the peak-to-pit range: the lab courses run edge to edge), then cached.
static func relief(kind: String) -> PackedFloat32Array:
	if _relief.has(kind): return _relief[kind]
	var w := WorldData.new()
	w.W = 64
	w.H = 64
	w.N = w.W * w.H
	w.seed_text = "Trail Lab"
	w.seed_num = WGRandom.hash_string(w.seed_text)
	for name: String in WorldGenerator.NOISE_SLOTS: w.noise[name] = Simplex.new(WorldGenerator.noise_rng(w.seed_num, name))
	StageRelief.run(w) # world-wide mountain settings and the start shift, as in the game
	var want: Vector2 = GROUND_DROP[kind]
	var n := w.noise
	var best := Vector2i.ZERO
	var best_score := INF
	var across := false # the window falls along x: turn it so it falls along z
	for cy in 8:
		for cx in 8:
			var lo := INF
			var hi := -INF
			var edges := Vector4() # rows z = first, last; columns x = first, last
			for sj in 6:
				for si in 6:
					var sample := StageRelief.raw_at(n.warpX, n.warpY, n.cont, n.mask, n.ridge, n.hill, cx * 64 + si * 12.6, cy * 64 + sj * 12.6, w.macro_x, w.macro_y, w.mountain_scale, w.mountain_bias, w.mountain_height, w.foothill_spread)
					var m := StageRelief.normalize(sample) * GameConfig.HS
					lo = minf(lo, m)
					hi = maxf(hi, m)
					edges += Vector4(float(sj == 0), float(sj == 5), float(si == 0), float(si == 5)) * m / 6.0
			var fall_z := absf(edges.y - edges.x)
			var fall_x := absf(edges.w - edges.z)
			# A plain slope: relief beyond the edge-to-edge fall (ridges, hollows across the course) counts against it.
			var fall := maxf(fall_z, fall_x)
			var score := absf(fall - (want.x + want.y) * 0.5) + (hi - lo - fall) + (1000.0 if lo < 2.0 else 0.0) # dry land only
			if score < best_score:
				best_score = score
				best = Vector2i(cx * 64, cy * 64)
				across = fall_x > fall_z
	var raw := StageRelief.raw_rect(w, best.x, best.y, 64, 64, false)
	var micro := Parallel.fbm_rect(n.micro, best.x, best.y, 64, 64, 9.0, 2)
	var cells := PackedFloat32Array()
	cells.resize(64 * 64)
	var low := INF
	for i in cells.size():
		var source := (i % 64) * 64 + int(i / 64.0) if across else i
		cells[i] = StageRelief.add_micro(StageRelief.normalize(raw[source]), micro[source]) * GameConfig.HS
		low = minf(low, cells[i])
	var near := 0.0
	var far := 0.0
	for x in 64:
		near += cells[x]
		far += cells[63 * 64 + x]
	var flipped := PackedFloat32Array()
	flipped.resize(cells.size())
	for z in 64:
		for x in 64:
			flipped[z * 64 + x] = cells[(z if far >= near else 63 - z) * 64 + x] - low
	_relief[kind] = flipped
	return flipped

## A failed edit leaves the caller's current session untouched.
## `timings` (ms, disjoint stages): setup — the lab's source world, routes and obstacle grid; surface — Heightfield
## with the tread and the metre grid (finish_paths); earthworks — TrailBuilder's own trail_elements_ms, -1 when not baked.
static func prepare(routes: Array[TrailDefinition], with_elements := true, kind := "flat") -> Dictionary:
	var started := Time.get_ticks_usec()
	var timings := {setup_ms = 0.0, surface_ms = -1.0, earthworks_ms = -1.0}
	if kind == "site":
		# A fresh copy of the saved prepared surface; only the new routes are formed (TrailSite.prepare).
		if site() == null: return {heights = null, errors = PackedStringArray(["Площадка не открыта: " + site_error]), timings = timings}
		return _site.prepare(routes, with_elements)
	var w := WorldData.new()
	w.W = Polygon.CELLS if kind == "polygon" else 64
	w.H = w.W
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
			w.h[i] = ground(at, kind, routes.size() == 1 and routes[0].id.begins_with("course_")) / GameConfig.HS
			w.elev[i] = w.h[i]
			w.filled[i] = w.h[i]
			w.slope[i] = 0.035
	if kind == "polygon": Polygon.forest(w, routes) # the polygon's forest up to the trail edges
	var errors := TrailBuilder.append_routes(w, routes)
	timings.setup_ms = (Time.get_ticks_usec() - started) / 1000.0
	if not errors.is_empty(): return {heights = null, errors = errors, timings = timings}
	started = Time.get_ticks_usec()
	var h := Heightfield.new(w)
	timings.surface_ms = (Time.get_ticks_usec() - started) / 1000.0
	if with_elements:
		errors = TrailBuilder.bake_elements(h, routes)
		if not errors.is_empty(): return {heights = null, errors = errors, timings = timings}
		timings.earthworks_ms = h.road_refinement.build_timings.trail_elements_ms
	started = Time.get_ticks_usec()
	h.obstacles = ForestObstacles.new(w, h)
	timings.setup_ms += (Time.get_ticks_usec() - started) / 1000.0
	return {heights = h, errors = PackedStringArray(), timings = timings}

## Each course occupies the same lab region; select a course instead of overlapping test lanes.
## `style` — a TrailComposer profile that replaces the shape's own elements; `ground` — one of GROUNDS.
## compose_ms — time of the last call's element composition, -1 when the course was not composed.
static var compose_ms := -1.0
## On the saved site every shape is the site's own explicit demo route (its points are tied to that land);
## `style` composes elements on it over the site's surface, otherwise it keeps the demo elements. Empty — no site.
static func course(index: int, kind := "mountain", style := "", ground_kind := "flat") -> Array[TrailDefinition]:
	compose_ms = -1.0
	if ground_kind == "site":
		if site() == null: return []
		var route := _site.demo_route(kind)
		if not style.is_empty():
			var started := Time.get_ticks_usec()
			var profile: Dictionary = TrailComposer.PROFILES[style]
			route.title += " · " + str(profile.title)
			route.width = profile.route.width
			route.auto_bank = profile.route.auto_bank
			var composed := TrailComposer.compose(route, profile, 4242, func(at: Vector2) -> float: return _site.ground_at(at))
			route.elements.assign(composed.elements)
			route.sections.assign(composed.sections)
			compose_ms = (Time.get_ticks_usec() - started) / 1000.0
		return [route]
	if index == 0: return definitions()
	if index == 10:
		var own: Array[TrailDefinition] = [Polygon.route()]
		return own
	var d := TrailDefinition.new()
	d.id = "course_%d" % index
	d.title = ["", "S-повороты", "Серпантин", "Кольцо", "Спираль", "Восьмёрка", "Flow-трасса", "Технический лес", "Байк-парк", "Маршрут"][index]
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
			# Long uneven line for composed routes: sweeping bends with straights between them, about 400 m.
			9: pts.append(Vector2(128 + 62 * sin(a * 1.25) + 18 * sin(a * 3.3), 232 - 208 * t))
	d.closed = index in [3, 5]
	if d.closed: pts[-1] = pts[0]
	if index == 8:
		pts = park_points()
		d.auto_bank = 0.0 # the shaper's own superelevation (up to 38 %) would cancel the off-camber turn
	d.points = pts
	var started := Time.get_ticks_usec()
	if index in [6, 7] or (index == 9 and style.is_empty()) or not style.is_empty(): compose_ms = 0.0
	if index == 6: d.elements = TrailElementLibrary.compose(d, 4242, 0.5)
	if index == 7: d.elements = TrailElementLibrary.compose(d, 777, 0.5, 0.7, 0.85)
	if index == 8: d.elements = park_elements(d)
	if index == 9 and style.is_empty(): style = "mixed"
	if not style.is_empty():
		var profile: Dictionary = TrailComposer.PROFILES[style]
		d.title += " · " + str(profile.title)
		d.width = profile.route.width
		d.auto_bank = profile.route.auto_bank
		var composed := TrailComposer.compose(d, profile, 4242 + index, func(at: Vector2) -> float: return ground(at, ground_kind))
		d.elements.assign(composed.elements)
		d.sections.assign(composed.sections)
	if compose_ms == 0.0: compose_ms = (Time.get_ticks_usec() - started) / 1000.0
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
