extends SceneTree
## Isolated check of the saved real-world Trail Lab site (TrailSite): only the site file, no world, cache or generation.
##   godot --headless --path . --script res://tools/trail_site_test.gd
##   godot --path . --script res://tools/trail_site_test.gd -- --capture   (overview.png and rider.png of the site)
## Report: tools/control/runs/trail_site/metrics.json. About 30 s headless on the second PC.
const Fixture = preload("res://tools/trail_lab_fixture.gd")
const OUT := "res://tools/control/runs/trail_site"
var failures := 0
var checks := 0
var report := {}

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 180)
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	print("trail_site: ", "PASS " if ok else "FAIL ", label)
	if not ok: failures += 1

## Surface data of a build that must not depend on anything but the site and the routes.
func fingerprint(h: Heightfield) -> PackedByteArray:
	return var_to_bytes([h.hv, h.road_refinement.patches, h.world.path_mask, h.world.road_surface, h.road_refinement.trail_shaping.keys()])

func source_fingerprint(site: TrailSite) -> PackedByteArray:
	return var_to_bytes([site.hv, site.patches, site.cells, site.trails, site.structures, site.ribbons])

## The export's own tolerances (TrailSite.TOLERANCE): one rule for both.
func compared(c: Dictionary) -> bool:
	return TrailSite.mismatch(c).is_empty()

## A straight 60 m test route through `center` along `along`, with a roller across `center` (station 30) and one
## 18 m before it: the first one is where the protected surface is, the second shows the earthworks do work.
func cross_route(id: String, center: Vector2, along: Vector2) -> TrailDefinition:
	var d := TrailDefinition.new()
	d.id = id
	d.kind = "mountain"
	d.width = 4.0
	d.surface = RoadSurface.DIRT
	d.earthwork = 1.0
	d.auto_bank = 1.0
	var pts := PackedVector2Array()
	for k in 61: pts.append(center + along.normalized() * (k - 30.0))
	d.points = pts
	var T := TrailElement.Profile
	d.elements.assign([TrailElementLibrary.make(T.ROLLER, 12.0, 8.0, 0.5), TrailElementLibrary.make(T.ROLLER, 30.0, 8.0, 0.5)])
	return d

## Height, support and wheel contact at a point: the properties the protected surface must keep.
func contact_at(h: Heightfield, p: Vector2) -> PackedFloat32Array:
	var c := RideSurface.sample(h.world, h, p.x, p.y)
	return PackedFloat32Array([h.ground_at(p.x, p.y), h.surface_at(p.x, p.y, INF), c.surface, c.weight, c.across])

func worst_difference(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var worst := 0.0
	for k in a.size(): worst = maxf(worst, absf(a[k] - b[k]))
	return worst

## The metre-grid vertex at or below-left of p (vertices lie at TILE/2 + k·STEP).
func vertex_grid(p: Vector2) -> Vector2:
	var o := Vector2.ONE * GameConfig.TILE * 0.5
	return ((p - o) / RoadRefinement.STEP).floor() * RoadRefinement.STEP + o

## Distance from p to the polyline of a site path (local metres).
func path_distance(t: Dictionary, p: Vector2) -> float:
	var best := INF
	for n in range(1, t.pts.size()):
		best = minf(best, Grid.segment_dist(p.x, p.y, t.pts[n - 1].x * GameConfig.TILE, t.pts[n - 1].y * GameConfig.TILE, t.pts[n].x * GameConfig.TILE, t.pts[n].y * GameConfig.TILE))
	return best

## A new trail crossing the existing road: inside the road's tread the earthworks change nothing (heights, support,
## contact equal with and without elements), on the road axis outside the trail's reach the source surface stays,
## the off-road roller lifts the ground, and the mesh agrees with the support.
func check_road_crossing(site: TrailSite, bare: Heightfield) -> void:
	var work := Rect2(Vector2(site.work.position) * GameConfig.TILE, Vector2(site.work.size) * GameConfig.TILE).grow(-40.0)
	var road: Dictionary = {}
	var center := Vector2.ZERO
	var along := Vector2.ZERO
	var half := 0.0
	for t: Dictionary in site.trails:
		if t.kind != "road": continue
		for n in range(1, t.pts.size() - 1):
			var a := Vector2(t.pts[n - 1].x, t.pts[n - 1].y) * GameConfig.TILE
			var b := Vector2(t.pts[n + 1].x, t.pts[n + 1].y) * GameConfig.TILE
			var mid := Vector2(t.pts[n].x, t.pts[n].y) * GameConfig.TILE
			var normal := Vector2(-(b - a).y, (b - a).x).normalized()
			# The whole test route away from water and the shore pin: otherwise the bank, not the road, stops the earthworks.
			var dry := true
			for k in range(-30, 31, 2):
				var q := mid + normal * k
				var cell := floori(q.y / GameConfig.TILE) * bare.world.W + floori(q.x / GameConfig.TILE)
				dry = dry and work.has_point(q) and bare.depth_at(q.x, q.y) == 0.0 and bare.world.dist_water[cell] >= RoadBed.SHORE.y + 1.0
			var far_from_bridge := site.structures.all(func(s: Dictionary) -> bool: return Grid.segment_dist(mid.x, mid.y, s.ax, s.az, s.bx, s.bz) > 30.0)
			if dry and far_from_bridge and a.distance_to(b) > 0.5:
				road = t
				center = mid
				along = Vector2(-(b - a).y, (b - a).x)
				half = float(t.pts[n].w) * GameConfig.TILE * 0.5
				break
		if not road.is_empty(): break
	check(not road.is_empty(), "the site has a dry road inside the working rectangle for the crossing case")
	if road.is_empty(): return
	var d := cross_route("cross_road", center, along)
	var shaped := site.prepare([d] as Array[TrailDefinition], true)
	var formed := site.prepare([cross_route("cross_road", center, along)] as Array[TrailDefinition], false)
	check(shaped.errors.is_empty() and formed.errors.is_empty(), "crossing route builds: %s" % "; ".join(shaped.errors + formed.errors))
	if not shaped.errors.is_empty() or not formed.errors.is_empty(): return
	var h: Heightfield = shaped.heights
	var tread := 0.0
	var tread_points := 0
	var axis := 0.0
	var axis_points := 0
	var taken := 0
	# Protection is per vertex of the metre grid (a point between a pinned and a free vertex interpolates both):
	# the tread is checked at the vertices themselves, the road axis densely.
	var corner := vertex_grid(center - Vector2.ONE * 20.0)
	for iz in 41:
		for ix in 41:
			var v := corner + Vector2(ix, iz) * RoadRefinement.STEP
			if path_distance(road, v) <= half:
				var got := contact_at(h, v)
				tread = maxf(tread, worst_difference(got, contact_at(formed.heights, v)))
				tread_points += 1
				taken += int(got[2] == d.surface)
	var p := center - Vector2.ONE * 20.0
	while p.y <= center.y + 20.0:
		p.x = center.x - 20.0
		while p.x <= center.x + 20.0:
			if path_distance(road, p) < 0.25 and d.nearest(p, 20.0).z > d.width * 0.5 + RoadRefinement.REACH + 1.0:
				axis = maxf(axis, worst_difference(contact_at(h, p), contact_at(bare, p)))
				axis_points += 1
			p.x += 0.25
		p.y += 0.25
	report.road_crossing = {tread_points = tread_points, tread_difference = tread, axis_points = axis_points, axis_difference = axis, trail_surface_in_tread = taken}
	check(tread_points > 40 and tread < 1e-5, "earthworks leave the crossed road's tread as formed: %d grid vertices, largest change %.6f (height, support, surface, weight, across)" % [tread_points, tread])
	check(axis_points > 20 and axis < 1e-5, "road axis beyond the trail's reach keeps the source surface and contact: %d points, %.6f" % [axis_points, axis])
	var off_road := d.point_at(12.0)
	var lift: float = h.ground_at(off_road.x, off_road.y) - formed.heights.ground_at(off_road.x, off_road.y)
	check(lift > 0.25, "the roller away from the road is baked: +%.2f m" % lift)
	var error := mesh_error(h)
	check(error < 1e-4, "mesh agrees with the support after earthworks at the crossing: %.7f m" % error)

## A new trail across the approach to a bridge, 3 m beyond its end, with a roller there: within the structure pin
## (RoadBed.PIN of the axis) heights and support equal the source, the deck stays as it was, the mesh agrees.
func check_bridge_approach(site: TrailSite, bare: Heightfield) -> void:
	var work := Rect2(Vector2(site.work.position) * GameConfig.TILE, Vector2(site.work.size) * GameConfig.TILE).grow(-32.0)
	var bridge: Dictionary = {}
	var end := Vector2.ZERO
	for s: Dictionary in site.structures:
		if s.tunnel: continue
		for e: Array in [[Vector2(s.ax, s.az), -1.0], [Vector2(s.bx, s.bz), 1.0]]:
			var at: Vector2 = e[0] + Vector2(s.ux, s.uz) * e[1] * 3.0
			if work.has_point(at):
				bridge = s
				end = at
				break
		if not bridge.is_empty(): break
	check(not bridge.is_empty(), "the site has a bridge inside the working rectangle for the approach case")
	if bridge.is_empty(): return
	var d := cross_route("bridge_approach", end, Vector2(-bridge.uz, bridge.ux))
	var built := site.prepare([d] as Array[TrailDefinition])
	var formed := site.prepare([cross_route("bridge_approach", end, Vector2(-bridge.uz, bridge.ux))] as Array[TrailDefinition], false)
	check(built.errors.is_empty() and formed.errors.is_empty(), "approach route builds: %s" % "; ".join(built.errors + formed.errors))
	if not built.errors.is_empty() or not formed.errors.is_empty(): return
	var h: Heightfield = built.heights
	# (a) Earthworks: every metre-grid vertex within RoadBed.PIN of the axis is exactly as without the elements.
	var pinned := 0.0
	var pinned_points := 0
	var corner := vertex_grid(end - Vector2.ONE * 20.0)
	for iz in 41:
		for ix in 41:
			var v := corner + Vector2(ix, iz) * RoadRefinement.STEP
			if Grid.segment_dist(v.x, v.y, bridge.ax, bridge.az, bridge.bx, bridge.bz) < RoadBed.PIN:
				pinned = maxf(pinned, worst_difference(contact_at(h, v), contact_at(formed.heights, v)))
				pinned_points += 1
	# (b) The deck and its approach on the axis line (the ends and 3 m beyond them, where the deck meets the ground)
	# keep the source heights and support.
	var deck := 0.0
	for k in ceili(bridge.len * 2.0) + 13:
		var q := Vector2(bridge.ax, bridge.az) + Vector2(bridge.ux, bridge.uz) * (k * 0.5 - 3.0)
		deck = maxf(deck, maxf(absf(h.surface_at(q.x, q.y, INF) - bare.surface_at(q.x, q.y, INF)), absf(h.ground_at(q.x, q.y) - bare.ground_at(q.x, q.y))))
	var ends := maxf(absf(h.ground_at(bridge.ax, bridge.az) - bridge.ay), absf(h.ground_at(bridge.bx, bridge.bz) - bridge.by))
	report.bridge_approach = {pinned_vertices = pinned_points, pinned_difference = pinned, axis_difference = deck, ends_to_deck = ends}
	check(pinned_points > 40 and pinned < 1e-5, "earthworks leave the bridge approach (within %.0f m of the axis) as formed: %d grid vertices, %.6f (height, support, contact)" % [RoadBed.PIN, pinned_points, pinned])
	check(deck < 1e-5 and ends < 0.01, "deck, its ends and the approach on the axis keep the source support: %.6f m, ends to deck %.4f m" % [deck, ends])
	var error := mesh_error(h)
	check(error < 1e-4, "mesh agrees with the support after earthworks at the bridge approach: %.7f m" % error)

## Triangles of the lab's structure meshes: the highest one over each point of the bridge axis must be the deck
## the wheels stand on (Heightfield.deck_at). Returns {points, worst}.
func visible_deck(lab: Node, h: Heightfield, count: int) -> Dictionary:
	var tris := PackedVector3Array()
	for mi in lab.structures.find_children("*", "MeshInstance3D", true, false):
		var mesh: Mesh = (mi as MeshInstance3D).mesh
		for surface in mesh.get_surface_count():
			var arrays := mesh.surface_get_arrays(surface)
			var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			if idx.is_empty():
				tris.append_array(v)
			else:
				for i in idx: tris.append(v[i])
	var worst := 0.0
	var points := 0
	for s: Dictionary in h.structures.slice(0, count):
		if s.tunnel: continue
		for k in range(1, floori(s.len * 2.0)):
			var q := Vector2(s.ax, s.az) + Vector2(s.ux, s.uz) * k * 0.5
			var top := -INF
			for i in range(0, tris.size(), 3):
				var y := _triangle_y(tris[i], tris[i + 1], tris[i + 2], q)
				top = maxf(top, y)
			worst = maxf(worst, absf(top - h.deck_at(q.x, q.y, INF)))
			points += 1
	return {points = points, worst = worst}

static func _triangle_y(a: Vector3, b: Vector3, c: Vector3, p: Vector2) -> float:
	var den := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
	if absf(den) < 1e-9: return -INF
	var u := ((b.z - c.z) * (p.x - c.x) + (c.x - b.x) * (p.y - c.z)) / den
	var v := ((c.z - a.z) * (p.x - c.x) + (a.x - c.x) * (p.y - c.z)) / den
	if u < -1e-4 or v < -1e-4 or u + v > 1.0001: return -INF
	return u * a.y + v * b.y + (1.0 - u - v) * c.y

## Every mesh triangle centre on the support the wheels use: patches stitched without cracks.
func mesh_error(h: Heightfield) -> float:
	var arrays := TerrainBuilder.build_arrays(h.world, h)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var worst := 0.0
	for i in range(0, indices.size(), 3):
		var center := (vertices[indices[i]] + vertices[indices[i + 1]] + vertices[indices[i + 2]]) / 3.0
		worst = maxf(worst, absf(h.ground_at(center.x, center.z) - center.y))
	return worst

## Reference samples farther than `reach` from the route: there the new trail must not change anything.
func away_from(site: TrailSite, d: TrailDefinition, reach: float) -> Dictionary:
	var ref := site.reference
	var o := site.origin_m()
	var out := {x = PackedFloat32Array(), z = PackedFloat32Array(), near_road = PackedByteArray(), values = PackedFloat32Array()}
	var count := TrailSite.PROBE.size()
	for n in ref.x.size():
		var at := Vector2(ref.x[n], ref.z[n]) - o
		if d.nearest(at, reach).z < reach: continue
		out.x.append(ref.x[n])
		out.z.append(ref.z[n])
		out.near_road.append(ref.near_road[n])
		out.values.append_array(ref.values.slice(n * count, (n + 1) * count))
	return out

func run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var file_hash := FileAccess.get_sha256(Fixture.SITE)
	var started := Time.get_ticks_usec()
	var opened := TrailSite.open(Fixture.SITE)
	report.open_ms = (Time.get_ticks_usec() - started) / 1000.0
	check(not opened.has("error"), "saved site opens without the world or its cache: %s" % opened.get("error", "%.0f ms" % report.open_ms))
	if opened.has("error"):
		quit(1)
		return
	var site: TrailSite = opened.site
	report.site = {title = site.title, seed = site.source.seed_text, origin = str(site.origin), cells = str(site.size), work = str(site.work),
		paths = site.trails.size(), structures = site.structures.size(), river_pieces = site.ribbons.size(), patches = site.patches.size()}
	var before := source_fingerprint(site)
	# 1. The fresh surface before any new trail reproduces the source world (world points moved by the site origin).
	started = Time.get_ticks_usec()
	var bare := site.prepare([] as Array[TrailDefinition])
	report.bare_ms = (Time.get_ticks_usec() - started) / 1000.0
	var c := site.compare(bare.heights)
	report.source_match = c
	check(compared(c), "land, water, wheel surfaces, cell surfaces and bumps match the source at %d points (%d near paths): ground %.6f m, water %.6f m, bump %.6f m, surface mismatches %d/%d" % [
		c.points, c.road_points, c.ground, c.depth, c.bump, c.surface_mismatch, c.cell_mismatch])
	check(c.road_points > 1000, "the comparison covers the road and its shoulders (%d points)" % c.road_points)
	var bare_mesh := mesh_error(bare.heights)
	check(bare_mesh < 1e-4, "site mesh agrees with its support: %.7f m" % bare_mesh)
	# 2. The demo route: two fresh rebuilds give the same result; a third one does not accumulate earthworks.
	var demo := site.demo_route()
	var first := site.prepare([demo] as Array[TrailDefinition])
	check(first.errors.is_empty(), "demo route builds on the site: %s" % "; ".join(first.errors))
	if not first.errors.is_empty():
		quit(1)
		return
	var h: Heightfield = first.heights
	report.rebuild = first.timings
	var second := site.prepare([site.demo_route()] as Array[TrailDefinition])
	check(fingerprint(h) == fingerprint(second.heights), "two fresh rebuilds give the same surface, mask and surfaces")
	var third := site.prepare([site.demo_route()] as Array[TrailDefinition])
	var s1: Dictionary = h.road_refinement.trail_shaping.get(demo.id, {})
	var s3: Dictionary = third.heights.road_refinement.trail_shaping.get(demo.id, {})
	check(not s1.is_empty() and var_to_bytes(s1) == var_to_bytes(s3) and fingerprint(h) == fingerprint(third.heights),
		"no accumulated earthworks: cut %.1f m³, fill %.1f m³ on every rebuild" % [s1.get("cut_m3", 0.0), s1.get("fill_m3", 0.0)])
	check(source_fingerprint(site) == before, "the saved site data is unchanged by the rebuilds")
	# 3. The new trail really is formed and stitched; existing land away from it is untouched.
	var roller: TrailElement = demo.elements[0]
	var at := demo.point_at(roller.station)
	var lift: float = h.ground_at(at.x, at.y) - bare.heights.ground_at(at.x, at.y)
	check(lift > 0.25, "roller baked into the site support: +%.2f m" % lift)
	var contact := RideSurface.sample(h.world, h, demo.points[10].x, demo.points[10].y)
	check(contact.surface == demo.surface and contact.weight > 0.9, "new trail gets its tread and surface")
	var rebuilt_mesh := mesh_error(h)
	check(rebuilt_mesh < 1e-4, "new patches stitched to the saved ones without cracks: %.7f m" % rebuilt_mesh)
	var reach := demo.width * 0.5 + RoadRefinement.REACH + 2.0 * GameConfig.TILE
	var away := site.compare(h, away_from(site, demo, reach))
	check(compared(away) and away.road_points > 500, "farther than %.0f m from the new trail the source surface is unchanged (%d points, %d near paths)" % [reach, away.points, away.road_points])
	var crossing := 0
	for key: int in site.patches:
		if h.road_refinement.patches[key].h != site.patches[key].h: crossing += 1
	check(crossing < site.patches.size() / 4, "only patches the new trail reaches change: %d of %d saved" % [crossing, site.patches.size()])
	report.changed_saved_patches = crossing
	check_road_crossing(site, bare.heights)
	check_bridge_approach(site, bare.heights)
	# 4. World anchoring: the trail's tread noise and road bumps use world metres, not site metres.
	var shifted := site.world()
	shifted.world_origin = Vector2i.ZERO
	var local := site.heights(shifted)
	TrailBuilder.append_routes(shifted, [site.demo_route()] as Array[TrailDefinition])
	var only := {shifted.trails.size() - 1: true}
	RoadBed.refine(local, only)
	var zero := RoadRefinement.build(local, true, only)
	var anchored := RoadRefinement.build(_fresh_formed(site), true, _only_last(site))
	check(var_to_bytes(zero.patches) != var_to_bytes(anchored.patches), "tread noise of the new trail follows the world origin")
	# 5. Refusals: outside the working rectangle, damaged and foreign files.
	var outside := site.demo_route()
	var moved := PackedVector2Array()
	for p in outside.points: moved.append(p - Vector2(Vector2(site.work.position) * GameConfig.TILE))
	outside.points = moved
	var refused := site.prepare([outside] as Array[TrailDefinition])
	check(refused.heights == null and not refused.errors.is_empty(), "route outside the working rectangle refused: %s" % "; ".join(refused.errors))
	var bytes := FileAccess.get_file_as_bytes(Fixture.SITE)
	bytes[bytes.size() - 7] ^= 0x55
	var broken := OUT.path_join("broken.tsite")
	FileAccess.open(broken, FileAccess.WRITE).store_buffer(bytes)
	var damaged := TrailSite.open(broken)
	check(damaged.has("error"), "damaged site refused: %s" % damaged.get("error", "НЕТ ОТКАЗА"))
	bytes = FileAccess.get_file_as_bytes(Fixture.SITE)
	bytes.encode_u32(4, TrailSite.FORMAT + 1)
	FileAccess.open(broken, FileAccess.WRITE).store_buffer(bytes)
	var future := TrailSite.open(broken)
	check(future.has("error"), "other format version refused: %s" % future.get("error", "НЕТ ОТКАЗА"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(broken))
	# 6. Trail Lab: the site ground, a real ride, a rejected edit keeps the scene, an accepted edit rebuilds.
	var lab := preload("res://scenes/trail_lab.tscn").instantiate()
	root.size = Vector2i(1280, 720)
	root.add_child(lab)
	lab.set_physics_process(false)
	await process_frame
	lab.editor.course_selected.emit(0, "mountain", "", "site")
	check(lab.ground_kind == "site" and lab.routes[0].id == "site_demo" and lab.heights.world.world_origin == site.origin,
		"Trail Lab opens the saved site with its demo route: %.0f ms" % lab.build_timings.get("total_ms", -1.0))
	report.lab_site_build = lab.build_timings.duplicate()
	var built_structures: Array[Node] = lab.structures.get_children()
	var seen := visible_deck(lab, lab.heights, site.structures.size())
	report.visible_deck = seen
	check(built_structures.size() == 1 and seen.points > 10 and seen.worst < 0.02,
		"site bridges are drawn by StructuresBuilder and the visible deck is the wheel support: %d points, %.4f m" % [seen.points, seen.worst])
	lab.reset_ride(0.0, 8.0)
	var start := Vector2(lab.bike.x, lab.bike.z)
	var d: TrailDefinition = lab.routes[0]
	var worst_off := 0.0
	for tick in 600:
		var here := Vector2(lab.bike.x, lab.bike.z)
		var near := d.nearest(here)
		worst_off = maxf(worst_off, near.z)
		var target := d.point_at(near.x + 6.0) - here
		var steer := clampf(-wrapf(atan2(-target.x, -target.y) - lab.bike.heading, -PI, PI) * 2.0, -1.0, 1.0)
		lab.step_simulation(1.0 / 60.0, 0.6, steer, false, false)
		if tick % 60 == 0:
			print("trail_site: ride %.0f s station %.1f m speed %.1f m/s grade %.1f%% stamina %.2f" % [tick / 60.0, near.x, lab.bike.speed, lab.bike.grade(lab.heights) * 100.0, lab.controller.stamina.value])
		if lab.crash.active(): break
	var ridden := d.nearest(Vector2(lab.bike.x, lab.bike.z)).x
	report.ride = {station = ridden, off_axis = worst_off, crashed = lab.crash.active()}
	# 10 s at 60 % pedalling from 8 m/s: past the roller (40 m) on the gentle descent, about 7 m/s.
	check(ridden > 60.0 and not lab.crash.active(), "production bike rides the site route: %.0f m along it, off axis up to %.2f m" % [ridden, worst_off])
	var kept: Heightfield = lab.heights
	var bad: Array[TrailDefinition] = lab._copy_routes(lab.routes)
	var shifted_points := PackedVector2Array()
	for p in bad[0].points: shifted_points.append(p + Vector2(400, 0))
	bad[0].points = shifted_points
	check(not lab.rebuild(bad) and lab.heights == kept, "a failed rebuild keeps the previous site scene")
	var edited: bool = lab.apply_edit({width = 5.0, surface = RoadSurface.FOREST, profile = d.elements[0].profile})
	check(edited and lab.heights != kept and RideSurface.sample(lab.heights.world, lab.heights, d.points[10].x, d.points[10].y).surface == RoadSurface.FOREST,
		"an edit rebuilds the site route on a fresh copy: %.0f ms" % lab.build_timings.get("total_ms", -1.0))
	report.lab_edit_build = lab.build_timings.duplicate()
	check(is_instance_valid(built_structures[0]) and lab.structures.get_children() == built_structures,
		"an edit of the route keeps the built site structures")
	check(source_fingerprint(site) == before and FileAccess.get_sha256(Fixture.SITE) == file_hash, "site file and data unchanged after the lab session")
	if "--capture" in OS.get_cmdline_user_args():
		lab.set_overview(true)
		for i in 3: await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(OUT + "/overview.png")
		lab.set_overview(false)
		lab.reset_ride(60.0)
		for i in 3: await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(OUT + "/rider.png")
		# Close view of the site bridge from its upstream side, a little above the deck.
		var s: Dictionary = lab.heights.structures[0]
		var mid := Vector3((s.ax + s.bx) * 0.5, (s.ay + s.by) * 0.5, (s.az + s.bz) * 0.5)
		lab.set_process(false)
		lab.camera.position = mid + Vector3(s.uz, 0, -s.ux) * 14.0 + Vector3(s.ux, 0, s.uz) * 6.0 + Vector3(0, 4.0, 0)
		lab.camera.look_at(mid)
		for i in 3: await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(OUT + "/bridge.png")
		lab.set_process(true)
	lab.editor.course_selected.emit(0, "mountain", "", "flat")
	check(lab.ground_kind == "flat" and lab.structures.get_child_count() == 0 and lab.water.get_child_count() == 0,
		"switching to a lab ground removes the site's structures and water")
	lab.queue_free()
	await process_frame
	report.failures = failures
	report.checks = checks
	FileAccess.open(OUT + "/metrics.json", FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	print("trail_site: ", failures, " failures / ", checks, " checks; ", report)
	quit(1 if failures else 0)

## A site copy with the demo route appended and its coarse tread laid, keeping the site's world origin.
func _fresh_formed(site: TrailSite) -> Heightfield:
	var w := site.world()
	var h := site.heights(w)
	TrailBuilder.append_routes(w, [site.demo_route()] as Array[TrailDefinition])
	RoadBed.refine(h, _only_last(site))
	return h

func _only_last(site: TrailSite) -> Dictionary:
	return {site.trails.size(): true}
