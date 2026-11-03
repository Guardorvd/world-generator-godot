extends SceneTree
const C := preload("res://scripts/lab/trail_lab_route_contract.gd")
const B := preload("res://scripts/lab/trail_lab_builder.gd")
var failures := 0
func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	var ground := func(p: Vector2) -> float: return 12 + p.y * 0.08
	var allowed := func(p: Vector2) -> bool: return Rect2(24, 24, 464, 464).has_point(p)
	var hint := PackedVector2Array([Vector2(250, 450), Vector2(250, 250), Vector2(250, 50)])
	var full := B._resample(hint, 4)
	var good := C.measure(full, hint, hint[-1], "reached_finish", ground, allowed, 4)
	check(good.complete and not good.fragment and good.corridor_progress > 0.99, "genuine full route reaches finish and advances along corridor")
	check(C.measure(PackedVector2Array([hint[0], hint[-1]]), hint, hint[-1], "reached_finish", ground, allowed, 4).complete, "completion does not depend on the density of authoring vertices")
	var fragment := C.measure(full.slice(0, 55), hint, hint[-1], "blocked_or_self_approach", ground, allowed, 4)
	check(not fragment.complete and fragment.fragment and fragment.length > 160, "long dead-end fragment is not a completed route")
	var budget := C.measure(full, hint, hint[-1], "length_budget", ground, allowed, 4)
	check(not budget.complete, "length budget cannot masquerade as finish")
	var u := PackedVector2Array([Vector2(100, 400), Vector2(400, 400), Vector2(400, 100), Vector2(100, 100)])
	var shortcut := B._resample(PackedVector2Array([u[0], u[-1]]), 4)
	var missed := C.measure(shortcut, u, u[-1], "reached_finish", ground, allowed, 4)
	check(missed.complete and not missed.fragment and missed.corridor_coverage < 0.85, "safe arrival is complete even when the route leaves the preferred corridor")
	var brief := PackedVector2Array([Vector2(250, 200), Vector2(250, 120)])
	check(C.measure(brief, brief, brief[-1], "reached_finish", ground, allowed, 4).complete, "a finished short line is not rejected by a 160 metre quota")
	check(not C.plan(brief, ground, allowed, 4, true).has("error"), "short finish selection also works below the old 180 metre lower bound")
	var plan := C.plan(hint, ground, allowed, 4, true)
	check(not plan.has("error") and plan.selected_before_walk and plan.kind == "short" and plan.planned_length < 320, "short route chooses an independent finish before walking")
	var short_line := B._resample(plan.hint, 4)
	var short_report := C.measure(short_line, plan.hint, plan.finish, "reached_finish", ground, allowed, 4, "short")
	check(short_report.complete and short_report.standalone.useful, "planned short route has stopping area, runout and its own descent")
	var flat := func(_p: Vector2) -> float: return 20
	var empty_value := C.measure(short_line, plan.hint, plan.finish, "reached_finish", flat, allowed, 4, "short")
	check(empty_value.complete and not empty_value.standalone.useful, "flat line completion is independent of character added by composition")
	var unsafe := C.measure(full, hint, hint[-1], "reached_finish", ground, func(p: Vector2) -> bool: return p.y > 48, 4)
	check(not unsafe.complete and not unsafe.fragment, "arrival without stopping runout is a finish refusal")
	quit(1 if failures else 0)
