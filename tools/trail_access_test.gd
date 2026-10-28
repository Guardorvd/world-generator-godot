extends SceneTree
## Isolated check of the access of a trail to the road network (TrailAccess, step 2) on saved sites with roads, no world,
## no cache, no generation: TrailPicker with joins (every vertex of the site's roads and trails) builds the kit
## inbound approach + trail + outbound exit and judges it as one set under one shared budget.
##   godot --headless --path . --script res://tools/trail_access_test.gd
## Per site and profile: found or not, the verdict, why pairs were refused (access), costs of the approaches.
## For the first found kit: real junctions (exact road vertices, shared ends), turns in the joints, continuity of the
## finished surface, one short ride over the whole kit, connectivity in the existing RoadNavigation graph (start reachable
## from the road network, the road network reachable from the finish). Then: impossible access, bounded budget, atomic
## rejection of an apply that cannot succeed, and the stored "no trail" result. Report: tools/control/runs/trail_access.
const OUT := "res://tools/control/runs/trail_access"
const SITES := ["sever_gentle", "sever_sidehill", "ushchelye_bridge"]
var failures := 0
var checks := 0


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 240)
	run.call_deferred()


func check(ok: bool, label: String) -> void:
	checks += 1
	print("trail_access: ", "PASS " if ok else "FAIL ", label)
	if not ok: failures += 1


func joins_of(site: TrailSite) -> Array:
	var out: Array = []
	var inner := site.work.grow(-TrailScout.JOIN_EDGE)
	for t: Dictionary in site.trails:
		if not RoadBed.KINDS.has(t.kind): continue
		for p: Dictionary in t.pts:
			if inner.has_point(Vector2i(floori(p.x), floori(p.y))):
				out.append(Vector2(p.x, p.y) * GameConfig.TILE)
	return out


func run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var report := {runs = []}
	var first := {}
	for name: String in SITES:
		var path := TrailSite.DIR.path_join(name + TrailSite.EXT)
		var before := FileAccess.get_sha256(path)
		var got := TrailSite.open(path)
		check(not got.has("error"), "%s opens" % name)
		if got.has("error"): continue
		var site: TrailSite = got.site
		var joins := joins_of(site)
		for profile: String in TrailPicker.PROFILES:
			var gate := TrailAccess.new()
			gate.joins = joins
			var req: Dictionary = TrailPicker.PROFILES[profile].duplicate()
			req.merge({near = joins, access = gate}, true)
			var p := TrailPicker.find(site, req)
			var tag := "%s · %s" % [name, profile]
			print("— ", tag, " (joins ", joins.size(), ")\n", p.summary())
			var q := p.request
			check(p.stats.pairs_searched <= q.pairs and p.stats.builds <= q.builds and p.stats.expansions <= q.budget and p.stats.repairs <= q.repairs,
				"%s: shared budget holds — pairs %d/%d, builds %d/%d, expansions %d/%d (access %d), repairs %d/%d" % [tag, p.stats.pairs_searched, q.pairs,
				p.stats.builds, q.builds, p.stats.expansions, q.budget, p.stats.access_expansions, p.stats.repairs, q.repairs])
			check(p.accepted or p.verdict in ["no_pairs", "refused_all", "budget"], "%s: a normal result (%s)" % [tag, p.verdict])
			report.runs.append({run = tag, joins = joins.size(), verdict = p.verdict, found = p.accepted, reason = p.reason, stats = p.stats, rejected = p.rejected})
			if p.accepted and first.is_empty():
				first = {site = site, picker = p, gate = gate, name = tag}
		check(FileAccess.get_sha256(path) == before, "%s: site file unchanged" % name)
	check(not first.is_empty(), "at least one site gets a kit with access")
	if not first.is_empty():
		kit_checks(first)
		await apply_checks(first)
	refusal_checks()
	none_roundtrip()
	report.failures = failures
	report.checks = checks
	FileAccess.open(OUT + "/metrics.json", FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	print("trail_access: ", failures, " failures / ", checks, " checks")
	quit(1 if failures else 0)


func kit_checks(first: Dictionary) -> void:
	var site: TrailSite = first.site
	var p: TrailPicker = first.picker
	var gate: TrailAccess = first.gate
	var r := p.router
	var inbound := r.extras[0]
	var outbound := r.extras[1]
	var trail := r.definition
	var tag: String = first.name
	var roads := {}
	for t: Dictionary in site.trails:
		if not RoadBed.KINDS.has(t.kind): continue
		for pt: Dictionary in t.pts: roads[Vector2(pt.x, pt.y) * GameConfig.TILE] = true
	check(roads.has(inbound.points[0]) and roads.has(outbound.points[-1]), "%s: the kit starts and ends exactly on vertices of existing roads or trails" % tag)
	check(inbound.points[-1] == trail.points[0] and outbound.points[0] == trail.points[-1], "%s: the ends meet the trail exactly at its start and finish" % tag)
	var info: Dictionary = gate.last
	check(info.inbound.turn <= TrailAccess.ANGLE_MAX and info.outbound.turn <= TrailAccess.ANGLE_MAX and inbound.route_length() <= TrailAccess.LENGTH_MAX
		and outbound.route_length() <= TrailAccess.LENGTH_MAX, "%s: smooth joints — turns %.0f° / %.0f° (limit %.0f°), approach %.0f m, exit %.0f m" % [
		tag, info.inbound.turn, info.outbound.turn, TrailAccess.ANGLE_MAX, inbound.route_length(), outbound.route_length()])
	var h: Heightfield = r.prepared.heights
	var worst := 0.0
	for pair in [[inbound, trail, true], [trail, outbound, false]]:
		var a: TrailDefinition = pair[0]
		var b: TrailDefinition = pair[1]
		var joint := a.points[-1]
		for d in [-1.0, -0.25, 0.25, 1.0]:
			var fore := a.point_at(a.route_length() + minf(0.0, d))
			var aft := b.point_at(maxf(0.0, d))
			worst = maxf(worst, absf(h.surface_at(fore.x, fore.y, INF) - h.surface_at(aft.x, aft.y, INF)))
		worst = maxf(worst, absf(h.surface_at(joint.x, joint.y, INF) - h.surface_at(b.points[0].x, b.points[0].y, INF)))
	var road_gap := 0.0
	for pair in [[inbound.points[0], inbound.point_at(3.0)], [outbound.points[-1], outbound.point_at(outbound.route_length() - 3.0)]]:
		road_gap = maxf(road_gap, absf(h.surface_at(pair[0].x, pair[0].y, INF) - site.surface().surface_at(pair[0].x, pair[0].y, INF)))
	check(worst < 0.25 and road_gap < TrailAccess.ROAD_JUMP_MAX + 0.01, "%s: continuous finished surface — step across the joints up to %.2f m, difference from the road at the junctions %.2f m" % [tag, worst, road_gap])
	ride(h, [inbound, trail, outbound], tag)
	navigation(site, h, inbound, trail, outbound, tag)


## One short ride over the whole kit with the game's controller on the finished surface (forest obstacles of the site).
func ride(h: Heightfield, parts: Array, tag: String) -> void:
	var all := PackedVector2Array()
	for d: TrailDefinition in parts:
		for pt in d.points:
			if all.is_empty() or all[-1].distance_to(pt) > 0.01: all.append(pt)
	var line := TrailDefinition.new()
	line.points = all
	var controller := BikeController.new()
	var player := PlayerState.new()
	var bike := BikeRide.new()
	var at := line.point_at(2.0)
	player.x = at.x
	player.z = at.y
	player.feet = h.surface_at(at.x, at.y, -INF)
	player.on_ground = true
	bike.x = player.x
	bike.z = player.z
	bike.y = player.feet
	bike.heading = line.heading_at(2.0)
	bike.mount(player)
	bike.speed = 3.0
	var ticks := 0
	var worst := 0.0
	var crashed := false
	while ticks < 60 * 90:
		var here := Vector2(bike.x, bike.z)
		var near := line.nearest(here)
		worst = maxf(worst, near.z)
		if near.x > line.route_length() - 3.0: break
		var target := line.point_at(near.x + 6.0) - here
		var steer := clampf(-wrapf(atan2(-target.x, -target.y) - bike.heading, -PI, PI) * 2.0, -1.0, 1.0)
		h.obstacles.update(player.x, player.z, PackedFloat32Array(), -1)
		controller.ride(1.0 / 60.0, player, bike, h.world, h, 0.6, steer, false, false, false)
		ticks += 1
		if bike.crashed:
			crashed = true
			break
	var ridden := line.nearest(Vector2(bike.x, bike.z)).x
	check(ridden > line.route_length() - 4.0 and not crashed, "%s: one short ride over approach, trail and exit: %.0f of %.0f m in %.1f s, off axis up to %.2f m, fall: %s" % [
		tag, ridden, line.route_length(), ticks / 60.0, worst, crashed])


## Connectivity in the existing navigation graph on the kit world: shared nodes, one component, routes both ways.
func navigation(site: TrailSite, h: Heightfield, inbound: TrailDefinition, trail: TrailDefinition, outbound: TrailDefinition, tag: String) -> void:
	var w := h.world
	var nav = preload("res://scripts/game/road_navigation.gd").new()
	nav.build(w, h)
	var tile := GameConfig.TILE
	var comp_in: int = nav.component_near(inbound.points[0])
	var comp_start: int = nav.component_near(trail.points[0])
	var comp_finish: int = nav.component_near(trail.points[-1])
	var comp_out: int = nav.component_near(outbound.points[-1])
	check(comp_in >= 0 and comp_in == comp_start and comp_start == comp_finish and comp_finish == comp_out,
		"%s: approach, trail start, finish and exit are one component of the navigation graph (%d / %d / %d / %d)" % [tag, comp_in, comp_start, comp_finish, comp_out])
	# a road point far from the junction in the same component, from which the EXISTING network reaches the junction
	# (without that the check would test the old network, not the kit)
	var candidates: Array = []
	for t: Dictionary in site.trails:
		if not RoadBed.KINDS.has(t.kind): continue
		for pt: Dictionary in t.pts:
			var at := Vector2(pt.x, pt.y) * tile
			var d := at.distance_to(inbound.points[0])
			if d > 40.0 and d < 400.0 and nav.component_near(at) == comp_in:
				candidates.append({at = at, d = d})
	candidates.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return x.d > y.d)
	var far := Vector2.ZERO
	var far_d := 0.0
	for c: Dictionary in candidates.slice(0, 40):
		nav.route_to(c.at, inbound.points[0])
		if nav.complete:
			far = c.at
			far_d = c.d
			break
	var to_start: PackedVector2Array = nav.route_to(far, trail.points[0])
	var to_start_ok: bool = nav.complete
	var back: PackedVector2Array = nav.route_to(trail.points[-1], far)
	var back_ok: bool = nav.complete
	check(far_d > 20.0 and to_start_ok and back_ok, "%s: from the road network (%.0f m away) to the start and from the finish back to the network — routes found (%d and %d points)" % [
		tag, far_d, to_start.size(), back.size()])


## Atomic apply: a plan that cannot be applied changes nothing; a valid one bakes exactly once.
func apply_checks(first: Dictionary) -> void:
	var site: TrailSite = first.site
	var r: TrailRouter = first.picker.router
	var kit: Array[TrailDefinition] = [r.extras[0], r.definition, r.extras[1]]
	var plan := {version = StageTrailPlan.VERSION, state = "found", definition = StageTrailPlan.pack(r.definition),
		access = {inbound = StageTrailPlan.pack(r.extras[0]), outbound = StageTrailPlan.pack(r.extras[1])}}
	var fresh := site.prepare(kit, false) # kit appended and formed, earthworks NOT baked yet
	var h: Heightfield = fresh.heights
	h.world.trail_plan = plan
	var before := patch_hash(h)
	var broken: Dictionary = plan.duplicate(true)
	var points: PackedVector2Array = broken.definition.points
	points[3] += Vector2(1.0, 0.0) # the stored path no longer matches the path in the world: neither variant can be baked
	broken.definition.points = points
	h.world.trail_plan = broken
	var failed := StageTrailPlan.apply(h)
	check(not failed.applied and not failed.errors.is_empty() and patch_hash(h) == before and not h.road_refinement.trail_elements_baked,
		"a plan that cannot be applied is refused whole: nothing baked, ground unchanged (%s)" % ["; ".join(failed.errors).left(90)])
	h.world.trail_plan = plan
	var ok := StageTrailPlan.apply(h)
	check(ok.applied and ok.errors.is_empty() and patch_hash(h) != before and h.road_refinement.trail_elements_baked, "the valid plan is applied once (%s)" % ok.variant)
	var again := StageTrailPlan.apply(h)
	check(not again.applied, "a second apply on the same ground is refused instead of accumulating earthworks")
	await process_frame


func patch_hash(h: Heightfield) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var keys: Array = h.road_refinement.patches.keys()
	keys.sort()
	for key: int in keys:
		ctx.update((h.road_refinement.patches[key].h as PackedFloat32Array).to_byte_array())
	return ctx.finish().hex_encode()


## No access possible and a tight budget: normal refusals, nothing built, limits hold.
func refusal_checks() -> void:
	var got := TrailSite.open(TrailSite.DIR.path_join("sever_gentle" + TrailSite.EXT))
	var site: TrailSite = got.site
	var rolling: Dictionary = TrailPicker.PROFILES.rolling
	var far := TrailAccess.new()
	far.joins = [Vector2(site.work.position) * GameConfig.TILE - Vector2(8.0, 8.0)] # outside the working area: not a place for a junction
	var none := TrailPicker.find(site, rolling.merged({near = far.joins, near_max = 400.0, access = far}, true))
	var refused_for_access := none.tried.filter(func(t: Dictionary) -> bool: return t.outcome == "access").size()
	check(not none.accepted and none.stats.builds == 0 and (none.verdict == "no_pairs" or refused_for_access > 0),
		"impossible access (the only junction is outside the working area): refusal %s — no pair has a usable junction (%s) or %d pairs refused for lack of access; no build" % [
		none.verdict, "no_pairs" if none.verdict == "no_pairs" else "-", refused_for_access])
	var away := TrailPicker.find(site, rolling.merged({near = [Vector2(9000.0, 9000.0)], access = far}, true))
	check(not away.accepted and away.verdict == "no_pairs", "no road within reach of any point: %s" % away.verdict)
	var gate := TrailAccess.new()
	gate.joins = joins_of(site)
	var tight := TrailPicker.find(site, rolling.merged({near = gate.joins, access = gate, budget = 1200, repairs = 1, pairs = 2, builds = 1}, true))
	var q := tight.request
	check(tight.stats.expansions <= q.budget and tight.stats.pairs_searched <= q.pairs and tight.stats.builds <= q.builds and tight.stats.repairs <= q.repairs,
		"a tight budget holds with the approaches counted: expansions %d/%d (access %d), pairs %d/%d, builds %d/%d, verdict %s" % [
		tight.stats.expansions, q.budget, tight.stats.access_expansions, tight.stats.pairs_searched, q.pairs, tight.stats.builds, q.builds, tight.verdict])


## The stored "no trail" result survives the cache's own serialisation unchanged and applies as a no-op.
func none_roundtrip() -> void:
	var plan := {version = StageTrailPlan.VERSION, state = "none", verdict = "no_window", reason = "в области нет подходящего окна", area = Rect2i(0, 0, 768, 768),
		stats = {surface_ms = 7000.0, total_ms = 9000.0, searched = 0}}
	var back: Variant = bytes_to_var(var_to_bytes(plan))
	check(back == plan, "the stored result «no trail» is identical after serialisation")
	var site := TrailSite.open(TrailSite.DIR.path_join("sever_hills" + TrailSite.EXT)).site as TrailSite
	var h := site.surface()
	h.world.trail_plan = back
	var applied := StageTrailPlan.apply(h)
	check(applied.state == "none" and not applied.applied and applied.errors.is_empty(), "«no trail» is applied as a no-op without errors")
	h.world.trail_plan = {}
