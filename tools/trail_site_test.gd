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

func compared(c: Dictionary) -> bool:
	return c.ground < 1e-4 and c.support < 1e-4 and c.depth < 1e-3 and c.weight < 1e-4 and c.across < 1e-4 and c.bump < 1e-5 \
		and c.surface_mismatch == 0 and c.cell_mismatch == 0

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
