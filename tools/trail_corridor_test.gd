extends SceneTree
const B := preload("res://scripts/lab/trail_lab_builder.gd")
const Sites := preload("res://scripts/lab/trail_lab_sites.gd")
var failures := 0
func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	run.call_deferred()
func run() -> void:
	var ground := func(p: Vector2) -> float: return 12 + p.y * 0.08
	var left := PackedVector2Array([Vector2(250, 450), Vector2(120, 350), Vector2(120, 180), Vector2(250, 50)])
	var right := PackedVector2Array([Vector2(250, 450), Vector2(380, 350), Vector2(380, 180), Vector2(250, 50)])
	var a := B.build(ground, 512, 417, "flow", Callable(), Callable(), {route_hint = left})
	var score: Dictionary = B.stats.get("line_score", {}).duplicate()
	var b := B.build(ground, 512, 417, "flow", Callable(), Callable(), {route_hint = right})
	check(not a.is_empty() and not b.is_empty(), "both probe corridors produce projects")
	if not a.is_empty() and not b.is_empty():
		var ax := 0.0
		var bx := 0.0
		for p in a[0].points: ax += p.x
		for p in b[0].points: bx += p.x
		ax /= a[0].points.size()
		bx /= b[0].points.size()
		check(bx - ax > 40, "same endpoints, different interior corridor changes final geometry: %.1f m" % (bx - ax))
		check(score.has("rhythm") and score.has("element_space") and score.has("earthworks") and score.has("endpoints"), "score exposes the quality terms")
		check(score.total >= 0 and score.total <= 1, "score remains bounded")
	var straight := PackedVector2Array([Vector2(0, 0), Vector2(200, 0)])
	var cross := PackedVector2Array([Vector2(100, -100), Vector2(100, 100)])
	var same := Sites.final_relation(straight, straight)
	var crossing := Sites.final_relation(straight, cross)
	var apart := Sites.final_relation(straight, PackedVector2Array([Vector2(0, 100), Vector2(200, 100)]))
	check(same.duplicate and same.overlap == 1.0, "finished duplicate is identified")
	check(crossing.crossings > 0 and not crossing.duplicate, "short crossing is distinguished from repeated corridor")
	check(apart.crossings == 0 and not apart.duplicate, "separate final lines coexist")
	var park := B.build(ground, 512, 417, "park", Callable(), Callable(), {route_hint = left})
	check(not park.is_empty() and B.stats.get("line_score", {}).has("corridor"), "scouted park also follows and scores the whole corridor")
	# Distinct local windows, identical final WORLD line: a probe-only comparison cannot catch this.
	var previous := TrailDefinition.new()
	previous.id = "previous"
	previous.points = straight
	var candidate := TrailDefinition.new()
	candidate.id = "candidate"
	candidate.points = PackedVector2Array([Vector2(-100, 0), Vector2(100, 0)])
	var accepted := preload("res://scripts/lab/trail_lab_project.gd").new()
	accepted.accepted = true
	preload("res://scripts/lab/trail_lab_terrain.gd").world_seed = 9123
	Sites.world_seed = 9123
	Sites.current = 1
	Sites.sites.assign([{origin = Vector2i.ZERO}, {origin = Vector2i(25, 0)}])
	Sites._built = {0: {routes = [previous], project = accepted}, 1: {routes = [candidate]}}
	var errors := Sites.final_conflicts([candidate] as Array[TrailDefinition])
	check(not errors.is_empty() and errors[0].contains("повторяет"), "publication rejects a final duplicate across different local windows")
	candidate.points = PackedVector2Array([Vector2(0, -100), Vector2(0, 100)])
	errors = Sites.final_conflicts([candidate] as Array[TrailDefinition])
	check(not errors.is_empty() and errors[0].contains("пересекает"), "publication rejects an unplanned final crossing")
	accepted.accepted = false
	check(Sites.final_conflicts([candidate] as Array[TrailDefinition]).is_empty(), "unaccepted proposals do not reserve a final trail")
	print("RESULT ", "PASS" if failures == 0 else "FAIL")
	quit(1 if failures else 0)
