extends SceneTree
const Trails := preload("res://scripts/world/region_trails.gd")
const Regions := preload("res://scripts/world/region_preparation.gd")
const Rider := preload("res://tools/trail_world_test.gd")
const OUT := "res://tools/control/runs/trail_region"
var failures := 0
var checks := 0

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 180)
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	failures += int(not ok)
	print("trail_region: ", "PASS " if ok else "FAIL ", label)

static func fixture(seed: int, key := Vector2i(-1, 0)) -> Dictionary:
	var w := WorldData.new()
	w.W = 256
	w.H = 256
	w.N = w.W * w.H
	w.seed_num = seed
	w.seed_text = "fixed-%d" % seed
	for owner in [w.geology, w.climate, w.civil]:
		for property: Dictionary in owner.get_property_list():
			var v: Variant = owner.get(property.name)
			if v is GridBuffer2D.Float32 or v is GridBuffer2D.Byte or v is GridBuffer2D.Int32: v.resize()
	w.h.fill(0.15)
	w.dist_water.fill(30.0)
	w.biome.fill(Biomes.GRASS)
	var rect := Regions.rect_for(key)
	var fields := {h = PackedFloat32Array(), water_level = PackedFloat32Array(), dist = PackedFloat32Array(),
		river = PackedByteArray(), ocean = PackedByteArray(), lake = PackedByteArray(), biome = PackedByteArray(), path = PackedByteArray(),
		slope = PackedFloat32Array(), dw = PackedFloat32Array(), dist_path = PackedFloat32Array(), village = PackedByteArray()}
	for name: String in fields: fields[name].resize(w.N)
	fields.water_level.fill(-INF)
	fields.dist.fill(30.0)
	fields.dw.fill(30.0)
	fields.dist_path.fill(30.0)
	fields.biome.fill(Biomes.GRASS)
	for z in w.H:
		for x in w.W:
			fields.h[z * w.W + x] = 0.2 + x * 0.00005 + 0.003 * sin((z + seed) * 0.07)
	var route := {kind = "road", pts = [], surf = PackedByteArray()}
	for x in range(rect.position.x, rect.end.x + 5):
		route.pts.append({x = x + 0.5, y = rect.position.y + 128.5, w = 1.5})
		route.surf.append(RoadSurface.DIRT)
	for x in w.W: fields.path[128 * w.W + x] = 3
	w.trails = [{kind = "road", pts = [{x = rect.end.x + 0.5, y = rect.position.y + 128.5, w = 1.5}, {x = rect.end.x + 4.5, y = rect.position.y + 128.5, w = 1.5}], surf = PackedByteArray([2, 2])}]
	var ledger := {regions = {key: {rect = rect, fields = fields, decor = {trails = [route], bridges = [], settlements = []}}},
		trails = [route], settlements = [], bridges = []}
	return {world = w, ledger = ledger, key = key}

func run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	check(Trails.kit_id(Vector2i(-1, 2)) != Trails.kit_id(Vector2i(1, 2)), "signed regional IDs are distinct")
	var rect := Regions.rect_for(Vector2i(-1, 0))
	check(Trails.owns_zone(rect, rect.grow(-4), {}, Vector2i(-1, 0)), "negative region owns interior")
	check(not Trails.owns_zone(rect, rect.grow(1), {}, Vector2i(-1, 0)), "earthworks cannot cross a region boundary")
	check(not Trails.owns_zone(rect, rect.grow(-4), {regions = {Vector2i(0, 0): {trail_plan = {zone = rect.grow(-8)}}}}, Vector2i(-1, 0)), "accepted zones cannot overlap")
	var empty := fixture(7)
	var before := hash(empty.ledger)
	var cancel := Trails.prepare(empty.world, empty.key, empty.ledger, func() -> bool: return true)
	check(cancel.state == "cancelled" and hash(empty.ledger) == before, "cancellation leaves ledger untouched")
	var limited := fixture(7)
	var budget := Trails.prepare(limited.world, limited.key, limited.ledger, Callable(), 0)
	check(budget.state == "none" and budget.verdict == "budget" and not limited.ledger.regions[limited.key].fields.has("trail_patches"), "zero shared budget is distinct from no site; no deformation")
	var report := []
	# Fixed BEFORE running; no background seed search.
	for seed: int in [7, 41, 103]:
		var f := fixture(seed)
		var plan := Trails.prepare(f.world, f.key, f.ledger)
		print("fixed seed %d: %s / %s %s" % [seed, plan.state, plan.verdict, plan.stats])
		check(plan.state == "found", "fixed seed %d: accessible kit without any settlement (%s)" % [seed, plan.verdict])
		var searches := TrailScout.runs
		var ground_hash := hash(f.ledger.regions[f.key].fields)
		var repeated := Trails.prepare(f.world, f.key, f.ledger)
		check(repeated == plan and TrailScout.runs == searches and hash(f.ledger.regions[f.key].fields) == ground_hash,
			"same entry reused without search, duplicate or accumulated earthwork")
		check(plan.stats.total_ms <= Trails.BUDGET_MS + 100, "shared preparation time within budget")
		if plan.state == "found":
			var ids := []
			for d: Dictionary in [plan.access.inbound, plan.definition, plan.access.outbound]:
				ids.append(d.id)
				check(d.id.begins_with(Trails.kit_id(f.key)) and d.points[0].x < 0.0, "unique kit identity and global negative metre coordinates")
			check(ids.size() == 3 and ids[0] != ids[1] and ids[1] != ids[2], "three distinct route IDs")
			check(Trails.owns_zone(rect, plan.zone, {}, f.key), "entire final surface belongs to its region")
			f.world.outer = OuterLand.new()
			f.world.outer.W = f.world.W
			f.world.outer.H = f.world.H
			f.world.outer.set_ledger(f.ledger)
			var h := Heightfield.new(f.world, false)
			for at: Vector2 in plan.definition.points:
				var sample := OuterLand.refined_at(f.ledger.regions, at.x, at.y)
				check(not sample.is_empty() and absf(h.ground_at(at.x, at.y) - sample.h) < 0.0001, "published support equals stored triangles")
			RegionStream.root = OUT + "/store_%d" % seed
			var dir := RegionStream.store_dir(f.world)
			check(RegionStream.save(dir, f.ledger, f.key) == OK, "region and ledger saved")
			var loaded := RegionStream.read_ledger(f.world)
			var stream := RegionStream.new()
			stream.world = f.world
			stream.ledger = loaded
			stream._load_fields(f.key)
			check(stream.ledger.regions[f.key].trail_plan == plan and hash(stream.ledger.regions[f.key].fields) == ground_hash, "evicted fields and saved plan restored byte-for-byte")
			stream.free()
		report.append({seed = seed, state = plan.state, verdict = plan.verdict, stats = plan.stats})
	# Lengths are preferences, including a wish much larger than this site.
	var site := preload("res://tools/trail_lab_fixture.gd").site()
	var long_wish := TrailPicker.find(site, {length_min = 600.0, length_max = 20.0, min_drop = 1000.0})
	check(long_wish.accepted and long_wish.router.definition.route_length() < 600.0, "Picker accepts a valid shorter route despite length wishes")
	var no_network := fixture(7)
	no_network.world.trails = []
	no_network.ledger.regions[no_network.key].decor.trails = []
	no_network.ledger.trails = []
	var none := Trails.prepare(no_network.world, no_network.key, no_network.ledger)
	check(none.state == "none" and none.verdict == "no_network", "no accessible network is stored separately from budget exhaustion")
	FileAccess.open(OUT + "/metrics.json", FileAccess.WRITE).store_string(JSON.stringify({cases = report, checks = checks, failures = failures}, "\t"))
	print("trail_region: %d failures / %d checks" % [failures, checks])
	quit(1 if failures else 0)
