extends SceneTree
## Isolated check of the portability of one trail mechanism over a fixed set of natural sites: the same chain
## TrailPicker → TrailRouter → TrailFlow with one shared request on every site — no coordinates, no demo route,
## no per-site numbers. Only the saved site files (resources/trails/sites), no world or generation.
##   godot --headless --path . --script res://tools/trail_set_test.gd -- --no-lab   (table and maps only)
##   godot --path . --script res://tools/trail_set_test.gd -- --capture            (+ two rides and lab overviews)
## Per site: found or not, the verdict (no place / refused by requirements / stopped by budget), stage and reason,
## length, descent, grade, radii, cut and fill, elements, searches / expansions / builds, times (cold preparation of
## the site data separately). For every site a map of the suitability grid (map_<site>.png); for a refusal also a
## corridor estimate over the natural ground (an assumption, not proof). Repeatability of one found trail.
## Report: tools/control/runs/trail_set/metrics.json and REPORT.md. About 1 min headless on the second PC.
const Fixture = preload("res://tools/trail_lab_fixture.gd")
const OUT := "res://tools/control/runs/trail_set"
## The fixed set. Chosen by terrain figures of the source world (trail_site_export --scan) BEFORE the builder ran;
## a failing site is never dropped from it.
const SITES := [
	{file = "sever_gentle", kind = "пологая местность"},
	{file = "sever_hills", kind = "холмы"},
	{file = "sever_sidehill", kind = "косогор"},
	{file = "ushchelye_bridge", kind = "вода, мосты и дороги (ограниченные проходы)", note = "вода и ограниченные проходы: прежняя площадка разработки (Ущелье, 322, 300) — река, ручьи, дорога, тропы и два моста; вода 16 % клеток окна, средний уклон 12,8 %"},
	{file = "sever_steep", kind = "заведомо неподходящая (крутые горы)"},
]
const SEED := 1          # composition seed of TrailFlow, the same for every site
const RIDES := 2         # at most two meaningful automatic rides
var failures := 0
var checks := 0
var report := {sites = []}

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 300)
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	print("trail_set: ", "PASS " if ok else "FAIL ", label)
	if not ok: failures += 1

func run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var args := OS.get_cmdline_user_args()
	var found: Array[Dictionary] = [] # {site, picked, flow, row}
	for entry: Dictionary in SITES:
		var path := TrailSite.DIR.path_join(entry.file + TrailSite.EXT)
		var t0 := Time.get_ticks_usec()
		var got := TrailSite.open(path)
		var open_ms := (Time.get_ticks_usec() - t0) / 1000.0
		check(not got.has("error"), "%s opens: %s" % [entry.file, got.get("error", "%.0f ms" % open_ms)])
		if got.has("error"): continue
		var site: TrailSite = got.site
		# The two predefined trail classes, the same for every site; the site data are prepared once (cold) per site.
		for profile: String in TrailPicker.PROFILES:
			var name := "%s · %s" % [entry.file, TrailPicker.PROFILE_TITLES[profile]]
			var picked := TrailPicker.find(site, TrailPicker.PROFILES[profile])
			var flow: TrailFlow = TrailFlow.dress(site, picked.router, SEED) if picked.accepted else null
			var row := row_of(entry, site, picked, flow, open_ms)
			row.profile = TrailPicker.PROFILE_TITLES[profile]
			row.corridor = corridor(site, picked)
			report.sites.append(row)
			print("— ", name, " (", entry.kind, ")\n", picked.summary())
			if flow != null: print(flow.summary())
			save_map(site, picked, OUT + "/map_%s_%s.png" % [entry.file, profile])
			var q := picked.request
			check(picked.stats.pairs_searched <= q.pairs and picked.stats.builds <= q.builds and picked.stats.expansions <= q.budget
				and picked.stats.repairs <= q.repairs and (flow == null or flow.stats.builds <= TrailFlow.BUILDS),
				"%s: whole-operation budgets hold — pairs %d/%d, builds %d/%d (+%d elements), expansions %d/%d, repairs %d/%d, %.1f s" % [
				name, picked.stats.pairs_searched, q.pairs, picked.stats.builds, q.builds, flow.stats.builds if flow != null else 0,
				picked.stats.expansions, q.budget, picked.stats.repairs, q.repairs, row.time.operation_ms / 1000.0])
			check(picked.accepted or (not picked.reason.is_empty() and picked.verdict in ["no_pairs", "refused_all", "budget"]),
				"%s: %s" % [name, "found" if picked.accepted else "refused with a verdict (%s) and a reason" % picked.verdict])
			if picked.accepted:
				check(picked.router.accepted and picked.router.survey.level() == "within" and (flow == null or flow.accepted or flow.variant == "базовая линия"),
					"%s: the base line meets every checked requirement on the finished surface; elements judged anew" % name)
				found.append({site = site, picked = picked, flow = flow, row = row, entry = entry, name = name, profile = profile})
	# Repeatability of one found trail: same pair, line, expansions, builds and elements; site data from memory.
	if not found.is_empty():
		var first: Dictionary = found[0]
		var again := TrailPicker.find(first.site, TrailPicker.PROFILES[first.profile])
		var flow2: TrailFlow = TrailFlow.dress(first.site, again.router, SEED) if again.accepted else null
		var same: bool = again.accepted and again.start == first.picked.start and again.finish == first.picked.finish \
			and again.router.definition.points == first.picked.router.definition.points and again.stats.expansions == first.picked.stats.expansions \
			and again.stats.builds == first.picked.stats.builds and flow2 != null and elements_of(flow2.definition) == elements_of(first.flow.definition)
		report.repeat = {site = first.name, same = same, prepare_reused = again.stats.prepare_reused, prepare_ms = again.stats.prepare_ms,
			total_ms = again.stats.total_ms, cold_total_ms = first.picked.stats.total_ms}
		# The suitability cache keeps one site, and other sites were prepared in between: this repeat is cold again.
		check(same, "%s repeated: same start, finish, line, expansions, builds and elements (site data %s, %.0f ms); %.1f s, first time %.1f s" % [
			first.name, "from memory" if again.stats.prepare_reused else "prepared again", again.stats.prepare_cost_ms,
			again.stats.total_ms / 1000.0, first.picked.stats.total_ms / 1000.0])
	check(not found.is_empty(), "at least one site of the set gets a trail (found on %d of %d)" % [found.size(), SITES.size()])
	if not "--no-lab" in args:
		await lab_part(found, "--capture" in args)
	report.failures = failures
	report.checks = checks
	FileAccess.open(OUT + "/metrics.json", FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	FileAccess.open(OUT + "/REPORT.md", FileAccess.WRITE).store_string(table())
	print(table())
	print("trail_set: ", failures, " failures / ", checks, " checks")
	quit(1 if failures else 0)

func elements_of(d: TrailDefinition) -> Array:
	var out := []
	for e in d.elements: out.append([e.profile, e.station, e.length, e.height, e.bank])
	return out

func row_of(entry: Dictionary, site: TrailSite, p: TrailPicker, flow: TrailFlow, open_ms: float) -> Dictionary:
	var s := p.stats
	var row := {file = entry.file, kind = entry.kind, source = "%s, клетки %s, сторона %d" % [site.source.seed_text, site.origin + site.work.position, site.work.size.x],
		note = site.source.get("note", entry.get("note", "")), found = p.accepted, verdict = p.verdict, reason = p.reason, rejected = p.rejected.duplicate(),
		tried = [], points = s.points, points_kept = s.points_kept, pairs_kept = s.pairs_kept, pairs_searched = s.pairs_searched,
		searches = s.searches, expansions = s.expansions, repairs = s.repairs, builds = s.builds,
		time = {open_ms = open_ms, prepare_ms = s.prepare_ms, prepare_cold = not s.prepare_reused, select_ms = s.select_ms,
			search_ms = s.search_ms, build_ms = s.build_ms, picker_ms = s.total_ms, compose_ms = 0.0, flow_build_ms = 0.0,
			operation_ms = s.total_ms}}
	for t: Dictionary in p.tried:
		row.tried.append({start = str(t.start), finish = str(t.finish), straight = t.straight, drop = t.drop, outcome = t.outcome, reason = t.reason, expansions = t.expansions})
	if p.accepted:
		var r := p.router
		var sh: Dictionary = r.prepared.heights.road_refinement.trail_shaping.get(r.definition.id, {})
		row.route = {start = str(p.start), finish = str(p.finish), length = r.stats.length, drop = r.stats.drop, climb = r.stats.climb,
			descent = r.stats.descent, peak_grade = r.stats.peak_grade, radius_arcs = r.stats.min_radius, radius_axis = r.survey.min_radius,
			corners = r._shaped.get("corners", 0), max_cut = sh.get("max_cut", 0.0), max_fill = sh.get("max_fill", 0.0),
			cut_m3 = sh.get("cut_m3", 0.0), fill_m3 = sh.get("fill_m3", 0.0)}
	if flow != null:
		var kinds := {}
		for e in flow.definition.elements: kinds[TrailElementLibrary.title(e.profile)] = kinds.get(TrailElementLibrary.title(e.profile), 0) + 1
		row.elements = {accepted = flow.accepted, variant = flow.variant, message = flow.message, count = flow.definition.elements.size(),
			kinds = kinds, refusals = flow.refusals.duplicate(), builds = flow.stats.builds,
			peak_grade = flow.survey.peak_grade if flow.survey != null else 0.0}
		row.time.compose_ms = flow.stats.compose_ms
		row.time.flow_build_ms = flow.stats.build_ms
		row.time.operation_ms = s.total_ms + flow.stats.total_ms
	return row

## Suitability nodes of the site (the picker's own data, from memory): blocked, and the 4 m natural grade of the
## free ones. Connected free areas with the natural grade within the requirement: if one holds two nodes the
## requested length apart and min_drop lower, a corridor over the natural ground probably exists (an assumption —
## the line also needs room for radii and the ends; earthworks can add more).
func corridor(site: TrailSite, p: TrailPicker) -> Dictionary:
	var r := TrailRouter.new()
	if not r.setup(site, p._router_request()): return {}
	var grade := slopes(r)
	var q := p.request
	var free := 0
	var gentle := 0
	var label := PackedInt32Array()
	label.resize(r._w * r._h)
	label.fill(-1)
	var best := {drop = 0.0, length_ok = false, nodes = 0}
	var good := false
	var queue := PackedInt32Array()
	for i in r._w * r._h:
		if r._block[i] != TrailRouter.Block.FREE: continue
		free += 1
		if grade[i] > q.grade: continue
		gentle += 1
		if label[i] >= 0: continue
		queue.clear()
		queue.append(i)
		label[i] = i
		var head := 0
		while head < queue.size():
			var c := queue[head]
			head += 1
			for k in 8:
				var x := c % r._w + Grid.DX[k]
				var z := c / r._w + Grid.DY[k]
				if x < 0 or z < 0 or x >= r._w or z >= r._h: continue
				var n := z * r._w + x
				if label[n] >= 0 or r._block[n] != TrailRouter.Block.FREE or grade[n] > q.grade: continue
				label[n] = i
				queue.append(n)
		# highest and lowest node of the area, and whether a pair in the length range has the descent
		var ok := false
		var top := queue[0]
		var low := queue[0]
		for c in queue:
			if r._mean[c] > r._mean[top]: top = c
			if r._mean[c] < r._mean[low]: low = c
		var reach_lo: float = q.length_min / TrailPicker.DETOUR
		var step := maxi(1, queue.size() / 400) # bounded: at most ~400 × 400 pairs per area
		for a in range(0, queue.size(), step):
			if ok: break
			for b in range(0, queue.size(), step):
				var drop: float = r._mean[queue[a]] - r._mean[queue[b]]
				if drop < q.min_drop: continue
				var d := r._node_point(queue[a]).distance_to(r._node_point(queue[b]))
				if d >= reach_lo and d <= q.length_max:
					ok = true
					break
		var span: float = r._mean[top] - r._mean[low]
		if ok and not good or (ok == good and span > best.drop):
			best = {drop = span, length_ok = ok, nodes = queue.size()}
		good = good or ok
	return {free_share = float(free) / (r._w * r._h), gentle_share = float(gentle) / maxf(1.0, free), probable = good,
		area_nodes = best.nodes, area_drop = best.drop}

func slopes(r: TrailRouter) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(r._w * r._h)
	for z in r._h:
		for x in r._w:
			var xa := maxi(0, x - 1)
			var xb := mini(r._w - 1, x + 1)
			var za := maxi(0, z - 1)
			var zb := mini(r._h - 1, z + 1)
			var gx := (r._mean[z * r._w + xb] - r._mean[z * r._w + xa]) / ((xb - xa) * TrailRouter.GRID)
			var gz := (r._mean[zb * r._w + x] - r._mean[za * r._w + x]) / ((zb - za) * TrailRouter.GRID)
			out[z * r._w + x] = sqrt(gx * gx + gz * gz)
	return out

## Map of the suitability grid, 3 px per 2 m node: water blue, bridge zones violet, paths grey, outside the zone dark;
## free ground green (natural 4 m grade within the requirement), yellow (within the search cap), red (steeper).
## Tried pairs: white line start → finish (black dot); the accepted line cyan.
func save_map(site: TrailSite, p: TrailPicker, path: String) -> void:
	var r := TrailRouter.new()
	if not r.setup(site, p._router_request()): return
	var grade := slopes(r)
	var px := 3
	var img := Image.create(r._w * px, r._h * px, false, Image.FORMAT_RGB8)
	var colors := {TrailRouter.Block.BOUNDS: Color(0.15, 0.15, 0.15), TrailRouter.Block.WATER: Color(0.2, 0.4, 0.9),
		TrailRouter.Block.STRUCTURE: Color(0.6, 0.3, 0.8), TrailRouter.Block.PATH: Color(0.55, 0.55, 0.55)}
	for i in r._w * r._h:
		var c: Color = colors.get(r._block[i], Color.BLACK)
		if r._block[i] == TrailRouter.Block.FREE:
			c = Color(0.3, 0.75, 0.3) if grade[i] <= p.request.grade else (Color(0.9, 0.8, 0.2) if grade[i] <= r._cap else Color(0.85, 0.25, 0.2))
		img.fill_rect(Rect2i(i % r._w * px, i / r._w * px, px, px), c)
	var to_px := func(q: Vector2) -> Vector2i: return Vector2i((q - r._origin) / TrailRouter.GRID * px)
	for t: Dictionary in p.tried:
		var a: Vector2 = t.start
		var b: Vector2 = t.finish
		for k in 61: dot(img, to_px.call(a.lerp(b, k / 60.0)), 0, Color.WHITE)
		dot(img, to_px.call(a), 2, Color.WHITE)
		dot(img, to_px.call(b), 2, Color.BLACK)
	if p.accepted:
		for q in p.router.definition.points: dot(img, to_px.call(q), 1, Color(0.2, 0.9, 1.0))
	img.save_png(path)

func dot(img: Image, at: Vector2i, size: int, c: Color) -> void:
	img.fill_rect(Rect2i(at - Vector2i.ONE * size, Vector2i.ONE * (2 * size + 1)).intersection(Rect2i(Vector2i.ZERO, img.get_size())), c)

## Trail Lab on the found trails: the site injected into the lab's fixture, the trail applied from the result already
## built (not searched again); at most RIDES rides of trails with different geometry; overviews with --capture.
func lab_part(found: Array[Dictionary], capture: bool) -> void:
	var lab := preload("res://scenes/trail_lab.tscn").instantiate()
	root.size = Vector2i(1280, 720)
	root.add_child(lab)
	lab.set_physics_process(false)
	await process_frame
	var rides := 0
	var shapes: Array[Dictionary] = []
	for f: Dictionary in found:
		Fixture._site = f.site
		var picked: TrailPicker = f.picked
		var flow: TrailFlow = f.flow
		var d: TrailDefinition = flow.definition if flow != null else picked.router.definition
		var ready: Dictionary = flow.prepared if flow != null else picked.router.prepared
		var ok: bool = lab._apply_line(picked.router, Time.get_ticks_usec(), d, ready, flow.stats.compose_ms if flow != null else -1.0)
		check(ok, "%s: Trail Lab shows the built trail" % f.name)
		if not ok: continue
		if capture:
			lab.set_overview(true)
			for i in 3: await process_frame
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(OUT + "/overview_%s_%s.png" % [f.entry.file, f.profile])
		# a different geometry: length or descent or the number of corners differ clearly from the rides done
		var shape := {length = f.row.route.length, drop = f.row.route.drop, corners = f.row.route.corners}
		var differs := true
		for s: Dictionary in shapes:
			if absf(s.length - shape.length) < 20.0 and absf(s.drop - shape.drop) < 3.0 and s.corners == shape.corners: differs = false
		if rides >= RIDES or not differs: continue
		rides += 1
		shapes.append(shape)
		f.row.ride = ride(lab, d)
		check(f.row.ride.station > d.route_length() - 4.0 and not f.row.ride.crashed, "%s: automatic ride %.0f of %.0f m in %.1f s, off axis up to %.2f m, top %.1f m/s, in the air %.2f s, crash: %s (not a safety guarantee)" % [
			f.name, f.row.ride.station, d.route_length(), f.row.ride.seconds, f.row.ride.off_axis, f.row.ride.top_speed, f.row.ride.air_s, f.row.ride.crashed])
	Fixture._site = null
	lab.queue_free()
	await process_frame

func ride(lab: Node, d: TrailDefinition) -> Dictionary:
	lab.reset_ride(0.0, 4.0)
	var worst_off := 0.0
	var ticks := 0
	var top := 0.0
	var air := 0.0
	while ticks < 60 * 60:
		var here := Vector2(lab.bike.x, lab.bike.z)
		var near := d.nearest(here)
		worst_off = maxf(worst_off, near.z)
		if near.x > d.route_length() - 3.0: break
		var target := d.point_at(near.x + 6.0) - here
		var steer := clampf(-wrapf(atan2(-target.x, -target.y) - lab.bike.heading, -PI, PI) * 2.0, -1.0, 1.0)
		lab.step_simulation(1.0 / 60.0, 0.6, steer, false, false)
		top = maxf(top, absf(lab.bike.speed))
		if lab.bike.airborne: air += 1.0 / 60.0
		ticks += 1
		if lab.crash.active(): break
	return {station = d.nearest(Vector2(lab.bike.x, lab.bike.z)).x, seconds = ticks / 60.0, off_axis = worst_off, crashed = lab.crash.active(), top_speed = top, air_s = air}

## The comparable table of the set (Markdown).
func table() -> String:
	var lines := PackedStringArray(["| Площадка | Класс | Профиль | Итог | Этап / причина | Длина, м | Вниз, м | Уклон, % | Радиус, м | Выемка / насыпь, м (м³) | Элементы | Пары / поиски / раскрытия / сборки | Время, с |",
		"|---|---|---|---|---|---|---|---|---|---|---|---|---|"])
	for row: Dictionary in report.sites:
		var t: Dictionary = row.time
		var time := "%.1f (подг. %.2f%s, выбор %.2f, поиск %.2f, сборки %.1f%s)" % [t.operation_ms / 1000.0, t.prepare_ms / 1000.0,
			" хол." if t.prepare_cold else "", t.select_ms / 1000.0, t.search_ms / 1000.0, t.build_ms / 1000.0,
			", элем. %.0f мс + %.1f" % [t.compose_ms, t.flow_build_ms / 1000.0] if row.has("elements") else ""]
		var counts := "%d из %d / %d / %d / %d" % [row.pairs_searched, row.pairs_kept, row.searches, row.expansions, row.builds]
		if row.found:
			var r: Dictionary = row.route
			var e: Dictionary = row.get("elements", {})
			var kinds := PackedStringArray()
			for k: String in e.get("kinds", {}): kinds.append("%s %d" % [k, e.kinds[k]])
			lines.append("| %s | %s | %s | найдена | — | %.0f | %.1f | %.1f | %.1f (ось %.1f) | %.2f / %.2f (%.0f / %.0f) | %s | %s | %s |" % [row.file, row.kind, row.profile,
				r.length, r.drop, r.peak_grade * 100.0, r.radius_arcs, r.radius_axis, r.max_cut, r.max_fill, r.cut_m3, r.fill_m3,
				", ".join(kinds) if not kinds.is_empty() else "нет (%s)" % e.get("message", ""), counts, time])
		else:
			lines.append("| %s | %s | %s | не найдена: %s | %s | — | — | — | — | — | — | %s | %s |" % [row.file, row.kind, row.profile,
				TrailPicker.VERDICTS.get(row.verdict, row.verdict), row.reason.replace("|", "/"), counts, time])
	lines.append("")
	for row: Dictionary in report.sites:
		var c: Dictionary = row.get("corridor", {})
		lines.append("- %s (%s): %s. Свободно %.0f %% узлов, из них с уклоном земли в пределах требования %.0f %%; коридор по естественной земле %s (крупнейшая область %d узлов, перепад %.1f м)." % [
			row.file, row.profile, row.note, c.get("free_share", 0.0) * 100.0, c.get("gentle_share", 0.0) * 100.0,
			"вероятно есть" if c.get("probable", false) else "не найден", c.get("area_nodes", 0), c.get("area_drop", 0.0)])
	return "\n".join(lines)
