extends RefCounted
## One survey of a prepared world; one local preparation and final check per candidate.
## Accepted patches ARE the game surface. No synthetic world, repair loop or second bake.
const Search := preload("res://scripts/trails/trail_site_search.gd")
const Layout := preload("res://scripts/trails/trail_layout.gd")
const Validation := preload("res://scripts/trails/trail_validation.gd")
const GI := preload("res://scripts/trails/trail_generation_input.gd")
const MARGIN := 12
const BUDGET_MS := 30000
const EARTHWORKS := {max_cut = 8.0, max_fill = 6.0, modification = 1.0}
static var surveys := 0

static func build(w: WorldData, h: Heightfield, area: Rect2i, budget_ms := BUDGET_MS) -> Dictionary:
	var started := Time.get_ticks_msec()
	var deadline := started + budget_ms
	var input = GI.from_world(w, h)
	input.earthwork_limits = EARTHWORKS.duplicate()
	var search := Search.new({size = w.W, seed = w.seed_num, heights = input.heights, water = input.water, input = input},
		{area = area.grow(-MARGIN), deadline = started + budget_ms / 3})
	surveys += 1
	var candidates := search.find(w.seed_num)
	# Reuse the overview's construction estimate: spend the game budget on the
	# cheapest promising corridors first, without a second survey or a route quota.
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.probe.build_cost) < float(b.probe.build_cost) if a.probe.build_cost != b.probe.build_cost else a.trail_seed < b.trail_seed)
	var plan := {mode = "terrain_network", state = "none", reason = "нет принятых трасс", routes = [], entries = [],
		area = area, stats = {survey = search.stats, attempted = 0, accepted = 0, rejected = {}, budget_ms = budget_ms}}
	for candidate in candidates:
		if Time.get_ticks_msec() >= deadline: break
		plan.stats.attempted += 1
		var context := context_rect(h, candidate.region)
		var cut := TrailSite.cut(w, h, context, MARGIN)
		if not cut.errors.is_empty():
			_refuse(plan, "участок: " + cut.errors[0]); continue
		var site: TrailSite = cut.site
		var local_input = input.window(site.origin, site.size)
		var hint := PackedVector2Array()
		for p: Vector2 in candidate.probe.points: hint.append(p - site.origin_m())
		var style: String = candidate.styles[posmod(candidate.trail_seed, candidate.styles.size())]
		var result := Layout.generate(site.ground_at, Vector2(site.size) * GameConfig.TILE, candidate.trail_seed, style,
			local_input.blocked, {bounds = Rect2(Vector2(candidate.region.position - site.origin) * GameConfig.TILE, Vector2(candidate.region.size) * GameConfig.TILE),
				route_hint = hint, difficulty = 0.35, modification = 0.5})
		if result.routes.is_empty():
			_refuse(plan, result.stats.get("reason", "линия не построена")); continue
		var routes: Array[TrailDefinition] = []
		routes.assign(result.routes)
		var d := routes[0]
		d.id = "world_trail_%d" % plan.entries.size()
		d.title = "%s · %d" % [Layout.STYLES[style].title, plan.entries.size() + 1]
		# The saved world-space float32 line is canonical. Bake its roundtrip, so replay cannot
		# introduce a second geometry through precision lost when adding the window origin.
		var canonical := StageTrailPlan.to_world(d, site)
		var local_points := PackedVector2Array()
		for p in canonical.points: local_points.append(p - site.origin_m())
		d.points = local_points
		# The world accepts the finished route once. Lab-only base repairs are never called here.
		var prepared := site.prepare(routes, true, {deadline = deadline})
		if not prepared.errors.is_empty():
			_refuse(plan, prepared.errors[0]); continue
		var earth := audit(site, prepared.heights, local_input)
		if not earth.is_empty():
			_refuse(plan, earth[0]); continue
		var checked := Validation.measure(prepared.heights, d, func(p: Vector2) -> bool: return not local_input.blocked(p))
		if not checked.accepted:
			_refuse(plan, checked.errors[0]); continue
		var final_ground := func(p: Vector2) -> float: return prepared.heights.ground_at(p.x, p.y)
		var finish := preload("res://scripts/trails/trail_route_contract.gd").endpoint(d.points[-1], d.tangent_at(d.route_length()),
			final_ground, func(p: Vector2) -> bool: return not local_input.blocked(p), d.width)
		if not finish.suitable:
			_refuse(plan, "нет выката на готовом полотне"); continue
		var global := StageTrailPlan.to_world(d, site)
		var errors := TrailBuilder.append_routes(w, [global], false)
		if not errors.is_empty():
			_refuse(plan, errors[0]); continue
		publish(h, site, prepared.heights)
		# Reserve only an accepted line, not its search rectangle or a failed proposal.
		input.existing_paths.append({points = global.points, half_width = global.width * 0.5})
		plan.routes.append(StageTrailPlan.pack(global))
		plan.entries.append({rect = context, style = style, route = StageTrailPlan.pack(global),
			length = global.route_length(), elements = global.elements.size(), earthworks = h.road_refinement.trail_shaping[global.id]})
		plan.stats.accepted += 1
	if not plan.routes.is_empty():
		RoadSurface.rebuild_map(w)
		plan.state = "found"
		plan.reason = ""
		plan.definition = plan.routes[0]
	plan.stats.budget_exhausted = search.stats.budget_exhausted or plan.stats.attempted < candidates.size()
	plan.stats.total_ms = Time.get_ticks_msec() - started
	return plan

static func _refuse(plan: Dictionary, reason: String) -> void:
	plan.stats.rejected[reason] = int(plan.stats.rejected.get(reason, 0)) + 1

## Capture entire nearby structures once, even when only their protected end touches the data margin.
## This grows the read-only context, not the area offered to the route builder.
static func context_rect(h: Heightfield, work: Rect2i) -> Rect2i:
	var data := work.grow(MARGIN)
	for pass_index in h.structures.size() + 1:
		var before := data
		for structure: Dictionary in h.structures:
			var metres := TrailSite.structure_foot(structure)
			var foot := Rect2(metres.position / GameConfig.TILE, metres.size / GameConfig.TILE)
			var cells := Rect2i(Vector2i(foot.position.floor()), Vector2i(foot.end.ceil()) - Vector2i(foot.position.floor()))
			if data.intersects(cells): data = data.merge(cells)
		if data == before: break
	return data.grow(-MARGIN)

## Compare actual metre vertices against the prepared source, including side slopes.
## There is no universal 2 m laboratory limit, and protection is never relaxed.
static func audit(site: TrailSite, h: Heightfield, input: GI) -> PackedStringArray:
	for key: int in h.road_refinement.patches:
		var patch: Dictionary = h.road_refinement.patches[key]
		for z in RoadRefinement.STRIDE:
			for x in RoadRefinement.STRIDE:
				var at := Vector2((key % h.world.W) * RoadRefinement.DIV + x, (key / h.world.W) * RoadRefinement.DIV + z) * RoadRefinement.STEP + Vector2.ONE * GameConfig.TILE * 0.5
				var delta: float = patch.h[z * RoadRefinement.STRIDE + x] - site.ground_at(at)
				if not is_finite(delta): return PackedStringArray(["неконечная высота готового полотна"])
				if delta < -float(input.earthwork_limits.max_cut) - 0.05 or delta > float(input.earthwork_limits.max_fill) + 0.05:
					return PackedStringArray(["превышен игровой предел земляных работ"])
				if absf(delta) > 0.05 and input.blocked(at): return PackedStringArray(["земляные работы затрагивают воду, инфраструктуру или готовый путь"])
	return PackedStringArray()

## Publish exactly the accepted local surface; all values use the same world metre grid.
static func publish(h: Heightfield, site: TrailSite, local: Heightfield) -> void:
	for z in site.size.y:
		for x in site.size.x:
			h.hv[(site.origin.y + z) * h.world.W + site.origin.x + x] = local.hv[z * site.size.x + x]
	for key: int in local.road_refinement.patches:
		var global_key := (site.origin.y + key / site.size.x) * h.world.W + site.origin.x + key % site.size.x
		h.road_refinement.patches[global_key] = local.road_refinement.patches[key]
	h.road_refinement.trail_shaping.merge(local.road_refinement.trail_shaping, true)
	h.road_refinement.trail_elements_baked = true

## A missing derived surface replays saved definitions, never discovery or the world generator.
static func restore(h: Heightfield, plan: Dictionary) -> PackedStringArray:
	var w := h.world
	var original: Array = w.trails
	var ids := {}
	for record: Dictionary in plan.routes: ids[record.id] = true
	w.trails = original.filter(func(route: Dictionary) -> bool: return not ids.has(route.get("trail_id", "")))
	h.finish_paths()
	var errors := PackedStringArray()
	for entry: Dictionary in plan.entries:
		var cut := TrailSite.cut(w, h, entry.rect, MARGIN)
		if not cut.errors.is_empty(): errors = cut.errors; break
		var site: TrailSite = cut.site
		var global := StageTrailPlan.unpack(entry.route)
		var local := global.duplicate(true) as TrailDefinition
		var points := PackedVector2Array()
		for p in global.points: points.append(p - site.origin_m())
		local.points = points
		var prepared := site.prepare([local])
		if not prepared.errors.is_empty(): errors = prepared.errors; break
		errors = TrailBuilder.append_routes(w, [global], false)
		if not errors.is_empty(): break
		publish(h, site, prepared.heights)
	w.trails = original
	RoadSurface.rebuild_map(w)
	return errors
