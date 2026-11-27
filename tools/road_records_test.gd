extends SceneTree

const Records := preload("res://scripts/world/road_records.gd")
const Topology := preload("res://scripts/world/road_topology.gd")
const Fixture := preload("res://tools/road_relief_fixture.gd")
var failures := 0


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 30)
	run.call_deferred()


func run() -> void:
	var legacy := _axis()
	var natural := Topology.section("road", [{x = 2.0, y = 3.5, w = 0.35}, {x = 5.0, y = 3.5, w = 1.1}], Vector2i.ZERO)
	var animal := _axis("animal")
	var prepared := TrailDefinition.new()
	prepared.id = "test-loop"
	prepared.width = 4.5
	prepared.closed = true
	prepared.points = PackedVector2Array([Vector2(40, 40), Vector2(60, 40), Vector2(60, 56), Vector2(40, 40)])
	var loop := prepared.path_record()
	var w := Fixture.world()
	w.trails = [legacy, natural, animal, loop]
	var before := var_to_bytes(w.trails)
	_check(Records.validation_error(w.trails, "fixture").is_empty(), "legacy, animal, natural and prepared axes may lack surf")
	_check(Records.validation_error([natural, animal, loop], "fixture", Records.Phase.PUBLISHED).is_empty(),
		"the publication contract accepts IDs for new natural sections and prepared records")
	_reject([legacy], "trails[0].road_id", Records.Phase.PUBLISHED)
	_reject([animal], "trails[0].surf is missing", Records.Phase.SURFACED)
	_check(Topology.sections(w).has(Topology.section_id(legacy.pts, w.world_origin)), "a legacy axis gets a derived topology ID")
	_check(var_to_bytes(w.trails) == before, "validation and legacy ID lookup leave serialized records byte-identical")
	RoadSurface.run(w)
	_check(Records.validation_error(w.trails, "fixture", Records.Phase.SURFACED).is_empty(), "RoadSurface assigns one material per station")
	_check(animal.surf == PackedByteArray([0, 0]), "finished animal tracks use zero material")

	_bad_inputs(natural, loop, animal)
	print("ROAD RECORDS RESULT ", failures, " failures")
	quit(int(failures != 0))


func _bad_inputs(natural: Dictionary, loop: Dictionary, animal: Dictionary) -> void:
	_reject({}, "fixture: trails must be an Array")
	_reject([natural, 1], "trails[1] must be a Dictionary")
	_reject([natural, {kind = "ditch", pts = []}], "trails[1].kind")
	_reject([{kind = "trail", pts = []}], "trails[0].pts")
	var broken := _axis()
	broken.pts[0].x = NAN
	_reject([broken], "trails[0].pts[0].x")
	broken.pts[0].x = -1.0
	broken.pts[1].y = INF
	_reject([broken], "trails[0].pts[1].y")
	broken.pts[1].y = 2
	broken.pts[0].w = -0.1
	_reject([broken], "trails[0].pts[0].w")
	broken.pts[0].w = 0.4
	broken.surf = PackedByteArray([RoadSurface.FOREST])
	_reject([broken], "trails[0].surf has 1 entries for 2 stations")
	var w := Fixture.world()
	w.trails = [broken]
	var before := var_to_bytes([w.trails, w.path_mask, w.road_surface])
	var definitions: Array[TrailDefinition] = []
	var errors := TrailBuilder.append_routes(w, definitions)
	_check(not errors.is_empty() and errors[0].contains("trails[0].surf"), "TrailBuilder reports malformed existing surfaces")
	_check(var_to_bytes([w.trails, w.path_mask, w.road_surface]) == before, "a failed prepare leaves the axes and rasters intact")
	broken.surf = [RoadSurface.FOREST, RoadSurface.FOREST]
	_reject([broken], "trails[0].surf must be a PackedByteArray")
	broken.surf = PackedByteArray([RoadSurface.FOREST, 255])
	_reject([broken], "trails[0].surf[1] has invalid material 255")
	_reject([animal.merged({surf = PackedByteArray([0, RoadSurface.DIRT])}, true)], "trails[0].surf[1]")
	_reject([natural, natural.duplicate(true)], "trails[1].road_id duplicates trails[0].road_id")
	var repair := natural.merged({reconstruction_ranges_m = PackedFloat64Array([2.0, 10.0])})
	_check(Records.validation_error(bytes_to_var(var_to_bytes([repair])), "fixture", Records.Phase.SURFACED).is_empty(),
		"local repair stations survive serialization of a natural road")
	_reject([natural.merged({reconstruction_ranges_m = PackedFloat64Array([2.0, 14.0])})], "trails[0].reconstruction_ranges_m")
	_reject([natural.merged({reconstruction_ranges_m = PackedFloat64Array([1.0, 6.0, 4.0, 8.0])})], "trails[0].reconstruction_ranges_m")
	_reject([animal.merged({reconstruction_ranges_m = PackedFloat64Array([2.0, 10.0])})], "trails[0].reconstruction_ranges_m")
	_reject([loop, loop.duplicate(true)], "trails[1].trail_id duplicates trails[0].trail_id")
	_reject([loop.merged({trail_id = ""}, true)], "trails[0].trail_id")
	_reject([loop.merged({formation = Vector3(INF, 0, 0)}, true)], "trails[0].formation")
	_reject([loop.merged({surface_override = 8}, true)], "trails[0].surface_override")
	var open := _axis()
	open.merge({trail_id = "bad-loop", closed = true})
	_reject([open], "trails[0].pts of a closed trail")
	_check(Records.validation_error([_axis().merged({trail_id = "old-prepared"})], "fixture").is_empty(),
		"legacy prepared metadata uses existing defaults")
	var ride := {ride = "ride_0", ride_style = "flow", ride_climb = "climb_0"}
	_check(Records.validation_error([_axis().merged(ride), natural.merged(ride)], "fixture").is_empty(),
		"ride identifiers are shared across physical sections and a climb may reuse the network")
	_reject([_axis().merged({ride_style = "flow"})], "ride metadata needs both ride and ride_style")


func _axis(kind := "trail") -> Dictionary:
	return {kind = kind, pts = [{x = -1.0, y = 2, w = 0.42}, {x = 6.0, y = 2, w = 0.55}]}


func _reject(records: Variant, expected: String, phase := Records.Phase.COMPATIBLE) -> void:
	var issue := Records.validation_error(records, "fixture", phase)
	_check(issue.contains(expected), "expected %s, got %s" % [expected, issue])


func _check(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ", label)
	failures += int(not ok)
