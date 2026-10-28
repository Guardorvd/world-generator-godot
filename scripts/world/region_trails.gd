extends RefCounted
## Regional adapter only: the production Scout/Picker/Router/Access/Flow builds the kit.
const VERSION := 1
const BUDGET_MS := 10000
const Ground := preload("res://scripts/world/region_road_heightfield.gd")

static func kit_id(key: Vector2i) -> String:
	return "region/%d/%d/kit/0" % [key.x, key.y]

static func prepare(source: WorldData, key: Vector2i, ledger: Dictionary, stop := Callable(), budget_ms := BUDGET_MS) -> Dictionary:
	var saved: Dictionary = ledger.regions[key].get("trail_plan", {})
	if saved.get("version", 0) == VERSION and saved.get("builder_version", 0) == StageTrailPlan.VERSION:
		return saved
	var staged := ledger.duplicate()
	staged.regions = ledger.regions.duplicate()
	staged.regions[key] = ledger.regions[key].duplicate(true)
	staged.trails = ledger.get("trails", []).duplicate()
	var plan := _prepare(source, key, staged, stop, budget_ms)
	if stop.is_valid() and stop.call(): return {state = "cancelled"}
	if plan.verdict == "budget":
		plan.state = "none"
		plan.erase("definition")
		plan.erase("access")
		plan.erase("zone")
		ledger.regions[key].trail_plan = plan
	else:
		ledger.regions[key] = staged.regions[key]
		ledger.trails = staged.trails
	return plan

static func _prepare(source: WorldData, key: Vector2i, ledger: Dictionary, stop := Callable(), budget_ms := BUDGET_MS) -> Dictionary:
	var started := Time.get_ticks_msec()
	var deadline := started + budget_ms
	var entry: Dictionary = ledger.regions[key]
	var plan := {version = VERSION, builder_version = StageTrailPlan.VERSION, id = kit_id(key), state = "none", verdict = "no_network", stats = {}}
	var expired := func() -> bool: return Time.get_ticks_msec() >= deadline or (stop.is_valid() and stop.call())
	# Select a component connected to the already available world, through regional road data.
	var graph_world := WorldData.new()
	graph_world.trails = source.trails + ledger.get("trails", [])
	var nav = preload("res://scripts/game/road_navigation.gd").new()
	nav.build(graph_world)
	var available := {}
	for route: Dictionary in source.trails:
		if route.kind == "animal" or route.pts.is_empty(): continue
		var p: Dictionary = route.pts[0]
		available[nav.component_near(Vector2(p.x, p.y) * GameConfig.TILE)] = true
	var anchor := Vector2.INF
	var connected := false
	var candidates := {}
	for route: Dictionary in entry.decor.trails:
		if route.kind == "animal": continue
		for p: Dictionary in route.pts:
			var at := Vector2(p.x, p.y)
			if not entry.rect.grow(-12).has_point(Vector2i(at.floor())): continue
			var component: int = nav.component_near(at * GameConfig.TILE)
			if not candidates.has(component): candidates[component] = {at = at, count = 0, linked = available.has(component)}
			candidates[component].count += 1
	var best := -INF
	for component: int in candidates:
		var candidate: Dictionary = candidates[component]
		var score: float = candidate.count + (20 if candidate.linked else 0)
		if score > best:
			best = score
			anchor = candidate.at
			connected = candidate.linked
	plan.network = {anchor = anchor * GameConfig.TILE, connected_to_plan = connected}
	plan.stats.network_ms = Time.get_ticks_msec() - started
	if not anchor.is_finite() or expired.call():
		plan.verdict = "budget" if expired.call() else "no_network"
		plan.stats.total_ms = Time.get_ticks_msec() - started
		plan.stats.budget_ms = budget_ms
		entry.trail_plan = plan
		return plan
	var t := Time.get_ticks_msec()
	var rect: Rect2i = entry.rect
	var f: Dictionary = entry.fields
	var w := WorldData.new()
	w.W = rect.size.x
	w.H = rect.size.y
	w.N = w.W * w.H
	w.world_origin = rect.position
	w.seed_num = source.seed_num
	w.seed_text = source.seed_text
	for owner in [w.geology, w.climate, w.civil]:
		for property: Dictionary in owner.get_property_list():
			var v: Variant = owner.get(property.name)
			if v is GridBuffer2D.Float32 or v is GridBuffer2D.Byte or v is GridBuffer2D.Int32: v.resize()
	w.h = f.h.duplicate()
	w.filled = f.water_level.duplicate()
	w.ocean = f.ocean.duplicate()
	w.lake = f.lake.duplicate()
	w.river = f.river.duplicate()
	w.biome = f.biome.duplicate()
	w.slope = f.slope.duplicate()
	w.dist_water = f.dw.duplicate()
	w.path_mask = f.path.duplicate()
	w.lake_id.fill(-1)
	for route: Dictionary in entry.decor.trails:
		w.trails.append_array(TrailSite._clip_route(route, 0, Rect2(Vector2(rect.position), Vector2(rect.size)), rect.position))
	for place: SettlementData in entry.decor.settlements:
		var s: SettlementData = place.duplicate(true)
		s.x -= rect.position.x
		s.y -= rect.position.y
		w.settlements.append(s)
	RoadSurface.run(w)
	var h := Ground.new(w, f.water_level)
	# These road surfaces are already published as raw regional triangles; do not reform them.
	h.road_refinement = RoadRefinement.from_patches({}, w.H)
	plan.stats.surface_ms = Time.get_ticks_msec() - t
	if expired.call():
		plan.verdict = "budget"
	else:
		var scout := TrailScout.find(w, h, {area = Rect2i(0, 0, w.W, w.H), network_at = (anchor - Vector2(rect.position)) * GameConfig.TILE,
			deadline = deadline, timeout_ms = maxi(0, deadline - Time.get_ticks_msec()), cancel = stop})
		var network_ms: int = plan.stats.network_ms
		var packed := StageTrailPlan.from_scout(w, scout, Rect2i(0, 0, w.W, w.H), plan.stats.surface_ms, kit_id(key))
		plan.merge(packed, true)
		plan.stats.network_ms = network_ms
		plan.rejected = scout.rejected.duplicate()
		plan.area = rect
		if plan.has("window"): plan.window.position += rect.position
		for candidate: Dictionary in plan.windows: candidate.rect.position += rect.position
		plan.version = VERSION
		plan.builder_version = StageTrailPlan.VERSION
		plan.id = kit_id(key)
		if scout.accepted and plan.state == "found" and not expired.call():
			# Reuse the accepted final build. It is never baked over another kit.
			plan.stats.final_build = scout.flow.prepared.timings.duplicate()
			plan.stats.search_ms = scout.picker.stats.search_ms
			var apply_started := Time.get_ticks_usec()
			var final: Heightfield = scout.flow.prepared.heights
			var local_origin := scout.site.origin
			var patches := {}
			var zone := Rect2i()
			for k: int in final.road_refinement.patches:
				var cell := rect.position + local_origin + Vector2i(k % final.world.W, k / final.world.W)
				patches[cell] = final.road_refinement.patches[k]
				var box := Rect2i(cell, Vector2i(2, 2))
				zone = zone.merge(box) if zone.has_area() else box
			# Include changes to the coarse support grid made by RoadBed, too.
			var changed := {}
			for z in final.world.H:
				for x in final.world.W:
					var local := local_origin + Vector2i(x, z)
					var value: float = final.hv[z * final.world.W + x]
					if absf(value - h.hv[local.y * w.W + local.x]) > 0.00001:
						var cell := rect.position + local
						changed[cell] = value
						var box := Rect2i(cell - Vector2i.ONE, Vector2i(3, 3))
						zone = zone.merge(box) if zone.has_area() else box
			if not owns_zone(rect, zone, ledger, key):
				plan.state = "none"
				plan.verdict = "zone_conflict"
			else:
				for cell: Vector2i in changed:
					var i := (cell.y - rect.position.y) * w.W + cell.x - rect.position.x
					f.h[i] = changed[cell] / GameConfig.HS
				f.trail_patches = patches
				plan.zone = zone
				# Definitions and records are in GLOBAL metres/cells, never start_trail IDs.
				for name: String in ["inbound", "outbound"]:
					if plan.access.info[name].has("join"): plan.access.info[name].join += Vector2(rect.position) * GameConfig.TILE
					plan.access[name].points = shift_points(plan.access[name].points, Vector2(rect.position) * GameConfig.TILE)
				plan.definition.points = shift_points(plan.definition.points, Vector2(rect.position) * GameConfig.TILE)
				for fields: Dictionary in [plan.access.inbound, plan.definition, plan.access.outbound]:
					var d := StageTrailPlan.unpack(fields)
					var record := d.path_record()
					RoadSurface.assign_route(source, record)
					entry.decor.trails.append(record)
					ledger.trails.append(record)
				f.path = w.path_mask.duplicate()
				var mask := PackedByteArray()
				mask.resize(w.N)
				for i in w.N: mask[i] = int(f.path[i] > 0)
				f.dist_path = Grid.distance_field(w.W, w.H, mask)
			plan.stats.apply_ms = (Time.get_ticks_usec() - apply_started) / 1000.0
		if expired.call():
			plan.state = "none"
			plan.verdict = "budget"
	plan.stats.total_ms = Time.get_ticks_msec() - started
	plan.stats.budget_ms = budget_ms
	entry.trail_plan = plan
	return plan

static func shift_points(points: PackedVector2Array, shift: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in points: out.append(p + shift)
	return out

static func owns_zone(rect: Rect2i, zone: Rect2i, ledger: Dictionary, key: Vector2i) -> bool:
	if not zone.has_area() or not rect.grow(-2).encloses(zone): return false
	for k: Vector2i in ledger.get("regions", {}):
		if k == key: continue
		var accepted: Rect2i = ledger.regions[k].get("trail_plan", {}).get("zone", Rect2i())
		if accepted.has_area() and accepted.intersects(zone): return false
	return true
