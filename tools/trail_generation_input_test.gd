extends SceneTree
const I := preload("res://scripts/trails/trail_generation_input.gd")
const B := preload("res://scripts/lab/trail_lab_builder.gd")
const F := preload("res://tools/trail_lab_fixture.gd")
const T := preload("res://scripts/lab/trail_lab_terrain.gd")
const Adapter := preload("res://scripts/lab/trail_lab_input.gd")
var failures := 0
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 90)
	run.call_deferred()
func check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok: failures += 1
func run() -> void:
	var w := WorldData.new()
	w.W = 8
	w.H = 8
	w.N = 64
	for owner in [w.geology,w.climate,w.civil]:
		for property: Dictionary in owner.get_property_list():
			var value: Variant = owner.get(property.name)
			if value is GridBuffer2D.Float32 or value is GridBuffer2D.Byte or value is GridBuffer2D.Int32: value.resize()
	w.h.fill(0.2)
	w.ocean[0] = 1
	w.lake[1] = 1
	w.river_area[3*8+3] = 1
	w.trails = [{kind="trail",pts=[{x=1.0,y=1.0,w=1.0},{x=6.0,y=1.0,w=1.0}]}]
	var input = I.from_world(w)
	check(input.validate().is_empty() and input.river_policy == I.RiverPolicy.STRICT, "game adapter is strict and complete by default")
	check(input.blocked(Vector2(14,14)), "real river corridor is water for the game input")
	check(input.blocked(Vector2(2,2)) and input.blocked(Vector2(6,2)), "sea and lakes remain blocked")
	check(input.blocked(Vector2(16,4)), "existing path corridor participates in planning")
	input.forbidden[6*8+6] = 1
	check(input.blocked(Vector2(26,26)), "explicit forbidden regions are respected")
	var lab = input.duplicate(true)
	lab.river_policy = I.RiverPolicy.LAB_DRY_CHANNELS
	check(not lab.validate().is_empty(), "a game input cannot silently inherit dry river rules")
	lab.provenance = {source="Trail Lab"}
	check(lab.validate().is_empty() and not lab.blocked(Vector2(14,14)) and input.blocked(Vector2(14,14)), "dry river exception is explicit, local and does not change the game source")
	var corrupt = input.duplicate(true)
	corrupt.rivers = PackedByteArray()
	check(not corrupt.validate().is_empty(), "missing river data is rejected rather than interpreted as dry")
	var natural: float = input.ground(Vector2(18,18))
	input.earthwork_limits.max_cut = 0.5
	input.apply_cuts([{points=PackedVector2Array([Vector2(18,18),Vector2(24,18)]),depth=PackedFloat32Array([1.0,1.0]),half=0.5,wall=0.8}])
	check(not input.cut_errors.is_empty() and input.ground(Vector2(18,18)) == natural, "oversized cut rejects transactionally")
	var source := I.new()
	source.size = Vector2i(128,128)
	for field in ["heights","water","rivers","forbidden"]:
		var array = source.get(field)
		array.resize(128*128)
		source.set(field,array)
	for z in 128:
		for x in 128: source.heights[z*128+x] = 12 + z * 0.2
	source.earthwork_limits = {max_cut=0.1,max_fill=0.1,modification=1.0}
	var d := TrailDefinition.new()
	d.id = "generated_limit_stand"
	d.points = PackedVector2Array([Vector2(100,400),Vector2(100,100)])
	d.elements = [TrailElementLibrary.make(TrailElement.Profile.ROLLER,100,12,1.0)]
	var prepared := F.prepare([d] as Array[TrailDefinition],true,"generated",source)
	check(not prepared.errors.is_empty() and prepared.heights == null and str(prepared.errors).contains("предел"), "actual baked displacement is checked against cut/fill limits")
	source.earthwork_limits.modification = 0.1
	var project := B.build_project(source,8,"park",{modification=0.8})
	check(project.routes.is_empty() and project.stats.reason.contains("предел"), "planning respects construction constraints")
	var before := var_to_bytes([w.h,w.river_area,w.trails])
	input.heights[0] += 1
	check(before == var_to_bytes([w.h,w.river_area,w.trails]), "input owns data; editing it does not mutate the game world")
	check(T.CACHE.contains("v3"), "old cache without river masks is not reused")
	print("RESULT: %s" % ("PASS" if failures == 0 else "FAIL (%d)" % failures))
	quit(0 if failures == 0 else 1)
