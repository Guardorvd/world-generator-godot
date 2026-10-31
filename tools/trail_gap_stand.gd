extends SceneTree
## Стенд прыжковых элементов (31.10): прямая без мира, один элемент, заезды с разной скоростью ровным газом.
## По каждому заезду: скорость взлёта, время и длина полёта, высота над кромкой, место приземления относительно
## элемента (у гэпа — недолёт до кромки приземления, на спуск или перелёт), удар, падение. Только замеры.
##   godot --headless --path . --script res://tools/trail_gap_stand.gd [-- --only gap]
const Fixture = preload("res://tools/trail_lab_fixture.gd")
const SPEEDS := [7.0, 9.0, 11.0, 13.0, 15.0, 17.0]
static var TRACE := false
## вид, длина, высота, разрыв (гэп)
const CASES := [
	["gap", TrailElement.Profile.GAP, 18.0, 1.4, 3.5],
	["gap", TrailElement.Profile.GAP, 18.0, 1.4, 4.0],
	["gap", TrailElement.Profile.GAP, 20.0, 1.5, 4.0],
	["gap", TrailElement.Profile.GAP, 22.0, 1.7, 5.0],
	["table", TrailElement.Profile.TABLETOP, 18.0, 1.1, 1.6],
	["table", TrailElement.Profile.TABLETOP, 22.0, 1.6, 1.6],
	["table", TrailElement.Profile.TABLETOP, 24.0, 2.0, 1.6],
]

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 240)
	run.call_deferred()

func run() -> void:
	var args := OS.get_cmdline_user_args()
	var only := args[args.find("--only") + 1] if "--only" in args else ""
	TRACE = "--trace" in args
	for c: Array in CASES:
		if not only.is_empty() and c[0] != only: continue
		var d := TrailDefinition.new()
		d.id = "gap_stand"
		d.width = 4.5
		d.surface = RoadSurface.DIRT
		d.earthwork = 1.0
		d.points = PackedVector2Array([Vector2(128, 236), Vector2(128, 20)])
		var e := TrailElementLibrary.make(c[1], 100.0, c[2], c[3])
		e.gap = c[4]
		d.elements = [e]
		var errors := d.validate()
		if not errors.is_empty():
			print("%s L%.0f H%.1f gap %.1f: %s" % [c[0], c[2], c[3], c[4], errors])
			continue
		var routes: Array[TrailDefinition] = [d]
		var prepared := Fixture.prepare(routes)
		if not prepared.errors.is_empty():
			print("BUILD FAILED ", prepared.errors)
			continue
		var h: Heightfield = prepared.heights
		var start := e.station - e.length * 0.5
		var lip := start + (e.gap_lip() if c[1] == TrailElement.Profile.GAP else e.length * 0.3)
		var knuckle := lip + e.gap
		print("\n%s · длина %.0f м · высота %.1f м · разрыв %.1f м · кромка %.1f м, приземление с %.1f м" % [c[0], c[2], c[3], c[4], lip - start, knuckle - start])
		for v: float in ([13.0] if TRACE else SPEEDS):
			print("  " + ride(h, d, e, v, lip, knuckle))
	quit()

func ride(h: Heightfield, d: TrailDefinition, e: TrailElement, v: float, lip: float, knuckle: float) -> String:
	var dt := 1.0 / 60.0
	var p := PlayerState.new()
	var b := BikeRide.new()
	b.contact_model = true
	var from := e.station - e.length * 0.5 - 30.0
	var at := d.point_at(from)
	b.x = at.x
	b.z = at.y
	b.y = h.surface_at(b.x, b.z, -INF)
	b.heading = d.heading_at(from)
	b.mount(p)
	b.speed = v
	var control := BikeController.new()
	var takeoff := -1.0
	var takeoff_v := 0.0
	var y0 := 0.0
	var rise := 0.0
	var air := 0.0
	var land := -1.0
	var impact := 0.0
	var t := 0.0
	while t < 12.0:
		var station := d.nearest(Vector2(b.x, b.z)).x
		if station > e.station + e.length * 0.5 + 12.0: break
		var throttle := clampf((v - b.speed) * 0.6, 0.0, 1.0) if station < lip else 0.0
		var steer := clampf(-wrapf(d.heading_at(station + 6.0) - b.heading, -PI, PI) * 2.0 - d.nearest(Vector2(b.x, b.z)).z * 0.0, -1.0, 1.0)
		var was := b.airborne
		var before := b.speed
		control.ride(dt, p, b, h.world, h, throttle, steer, false, false, false)
		t += dt
		if b.crashed: return "%4.1f м/с: ПАДЕНИЕ %s у %.1f м от кромки" % [v, BikeRide.CrashCause.keys()[b.crash_cause], station - lip]
		if b.airborne and not was and takeoff < 0.0 and station > lip - 3.0:
			takeoff = station
			takeoff_v = before
			y0 = b.y
		if b.airborne and takeoff >= 0.0 and land < 0.0:
			air += dt
			rise = maxf(rise, b.y - y0)
		if was and not b.airborne and takeoff >= 0.0 and land < 0.0 and air > 0.1:
			land = station
			impact = b.land_impact
		if TRACE and takeoff >= 0.0 and station < knuckle + 8.0:
			print("    s %+.2f · y %.2f · земля %.2f · vy %+.2f · %s · сжатие %.3f/%.3f" % [station - knuckle, b.y, h.surface_at(b.x, b.z, b.y), b.vy, "ВОЗДУХ" if b.airborne else "земля", b.squash_f, b.squash_r])
	if takeoff < 0.0: return "%4.1f м/с: не взлетел" % v
	var where := "недолёт на кромку" if land < knuckle else ("на спуск" if land < e.station + e.length * 0.5 - 0.5 else "перелёт")
	return "%4.1f м/с: взлёт %.1f м/с у %+.1f м · %.2f с · выше %.2f м · %.1f м · приземление %+.1f м от кромки приземления (%s) · удар %.1f" % [
		v, takeoff_v, takeoff - lip, air, rise, land - takeoff, land - knuckle, where, impact]
