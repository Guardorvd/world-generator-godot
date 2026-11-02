extends RefCounted
## Bounded base-tread solve BEFORE elements. Uses the same production bake as final preparation.
const GI := preload("res://scripts/trails/trail_generation_input.gd")
const RepairShape := preload("res://scripts/lab/trail_lab_repaired_shaping.gd")
const MAX_REPAIRS := 2

static func bake(input: GI, route: TrailDefinition) -> Dictionary:
	var started := Time.get_ticks_usec()
	var w := WorldData.new()
	w.W = input.size.x; w.H = input.size.y; w.N = w.W * w.H
	w.seed_num = 17027
	w.seed_text = "Trail Lab"
	for owner in [w.geology, w.climate, w.civil]:
		for property: Dictionary in owner.get_property_list():
			var value: Variant = owner.get(property.name)
			if value is GridBuffer2D.Float32 or value is GridBuffer2D.Byte or value is GridBuffer2D.Int32: value.resize()
	w.biome.fill(Biomes.GRASS); w.dist_water.fill(100); w.lake_id.fill(-1)
	for z in w.H:
		for x in w.W:
			var i := z * w.W + x
			w.h[i] = input.ground(Vector2(x + 0.5, z + 0.5) * GameConfig.TILE) / GameConfig.HS
			w.elev[i] = w.h[i]; w.filled[i] = w.h[i]; w.slope[i] = 0.035
	var routes: Array[TrailDefinition] = [route]
	var errors := TrailBuilder.append_routes(w, routes)
	if not errors.is_empty(): return {errors = errors, ms = (Time.get_ticks_usec() - started) / 1000.0}
	var h := Heightfield.new(w)
	errors = TrailBuilder.bake_elements(h, routes)
	return {heights = h, errors = errors, ms = (Time.get_ticks_usec() - started) / 1000.0}

## Audit the ENTIRE modified metre grid, including side slopes beyond the tread.
## Group every violating vertex into route intervals; never stop at the first bad vertex.
static func audit(input: GI, h: Heightfield, route: TrailDefinition) -> Dictionary:
	var bins := {}
	var seen := {}
	var report := {accepted = true, bad_vertices = 0, protected_vertices = 0, max_cut = 0.0, max_fill = 0.0, intervals = [], errors = []}
	for key: int in h.road_refinement.patches:
		var patch: Dictionary = h.road_refinement.patches[key]
		for z in RoadRefinement.STRIDE:
			for x in RoadRefinement.STRIDE:
				var vertex := Vector2i((key % h.world.W) * RoadRefinement.DIV + x, (key / h.world.W) * RoadRefinement.DIV + z)
				if seen.has(vertex): continue
				seen[vertex] = true
				var at := Vector2(vertex) * RoadRefinement.STEP + Vector2.ONE * GameConfig.TILE * 0.5
				var delta: float = patch.h[z * RoadRefinement.STRIDE + x] - input.natural_ground(at)
				report.max_cut = maxf(report.max_cut, -delta); report.max_fill = maxf(report.max_fill, delta)
				var protected_area: bool = absf(delta) > 0.05 and input.blocked(at)
				var excessive: bool = delta < -float(input.earthwork_limits.max_cut) - 0.05 or delta > float(input.earthwork_limits.max_fill) + 0.05
				if not protected_area and not excessive: continue
				report.bad_vertices += 1
				if protected_area: report.protected_vertices += 1
				var station := route.nearest(at).x
				var bin := floori(station / 8)
				if not bins.has(bin): bins[bin] = {from = maxf(0, station - 4), to = minf(route.route_length(), station + 4), protected_area = false, witness = at, count = 0, depth = 0.0}
				var record: Dictionary = bins[bin]
				record.from = minf(record.from, maxf(0, station - 4)); record.to = maxf(record.to, minf(route.route_length(), station + 4))
				record.count += 1
				record.depth = maxf(record.depth, absf(delta))
				if protected_area: record.protected_area = true; record.witness = at
	var keys := bins.keys(); keys.sort()
	for key in keys:
		var record: Dictionary = bins[key]
		if not report.intervals.is_empty() and record.from <= report.intervals[-1].to + 8:
			var last: Dictionary = report.intervals[-1]
			last.to = record.to; last.count += record.count; last.depth = maxf(last.depth, record.depth)
			if record.protected_area: last.protected_area = true; last.witness = record.witness
		else: report.intervals.append(record.duplicate(true))
	report.accepted = report.bad_vertices == 0
	if report.max_cut > float(input.earthwork_limits.max_cut) + 0.05 or report.max_fill > float(input.earthwork_limits.max_fill) + 0.05: report.errors.append("базовое полотно превышает предел выемки/насыпи")
	if report.protected_vertices > 0: report.errors.append("откосы базового полотна затрагивают защищённую область")
	return report

static func fit(input: GI, route: TrailDefinition, check_route: Callable) -> Dictionary:
	var report := {accepted = false, attempts = [], repairs = [], elements_before_solve = route.elements.size(), bake_ms = 0.0}
	if not route.elements.is_empty(): report.reason = "базовое полотно должно проверяться до элементов"; return report
	for attempt in MAX_REPAIRS + 1:
		var errors: PackedStringArray = check_route.call(route)
		if not errors.is_empty(): report.reason = "; ".join(errors); return report
		var built := bake(input, route)
		report.bake_ms += built.ms
		if not built.errors.is_empty(): report.reason = "; ".join(built.errors); return report
		var measured := audit(input, built.heights, route)
		report.attempts.append(measured)
		if measured.accepted:
			report.accepted = true
			report._heights = built.heights
			report.earthworks = built.heights.road_refinement.trail_shaping.get(route.id, {})
			return report
		if attempt == MAX_REPAIRS:
			report.reason = "; ".join(measured.errors)
			return report
		if attempt == 0:
			var repaired := RepairShape.new()
			for key in ["grade_limit", "level_window", "strength", "side_follow", "bank_max", "bank_gain", "bank_ramp", "crown", "batter", "end_fade"]: repaired.set(key, route.shape().get(key))
			for interval: Dictionary in measured.intervals: repaired.repair_intervals.append(Vector2(interval.from, interval.to))
			repaired.repair_shape = TrailShaping.preset("trail")
			repaired.repair_shape.grade_limit = minf(0.32, route.shape().grade_limit)
			route.shaping = repaired
			report.repairs.append({kind = "local_profile", intervals = repaired.repair_intervals, transition_m = RepairShape.TRANSITION, weight = repaired.repair_weight})
		else:
			var changed := move_intervals(input, route, measured.intervals)
			report.repairs.append({kind = "local_route", max_offset_m = 4.0, intervals = measured.intervals, moved = changed})
			if not changed: report.reason = "; ".join(measured.errors); return report
	return report

static func move_intervals(input: GI, route: TrailDefinition, intervals: Array) -> bool:
	# Authoring can contain only two endpoints. Repairs must still have interior degrees of freedom.
	var original := PackedVector2Array()
	var count := maxi(1, ceili(route.route_length() / 2.0))
	for i in count + 1: original.append(route.point_at(route.route_length() * i / count))
	var points := original.duplicate()
	var along := 0.0
	var changed := false
	for i in points.size():
		if i > 0: along += original[i - 1].distance_to(original[i])
		var p := original[i]
		var side := route.tangent_at(along).orthogonal()
		var offset := 0.0
		for interval: Dictionary in intervals:
			var weight := smoothstep(interval.from - 16, interval.from, along) * (1.0 - smoothstep(interval.to, interval.to + 16, along))
			weight *= smoothstep(0, 20, minf(along, route.route_length() - along))
			if weight <= 0: continue
			var direction := -signf((Vector2(interval.witness) - p).dot(side)) if interval.protected_area else 0.0
			if direction == 0:
				# Shift towards the locally gentler cross slope, never lower a water/infrastructure guard.
				var best := INF
				for sign_value: float in [-1.0, 1.0]:
					var at := p + side * 4 * sign_value
					var cross := absf(input.ground(at + side * 3) - input.ground(at - side * 3))
					if not input.blocked(at) and cross < best: best = cross; direction = sign_value
			if absf(weight * 4) > absf(offset): offset = weight * 4 * direction
		points[i] += side * offset
		changed = changed or absf(offset) > 0.01
	if changed: route.points = points
	return changed
