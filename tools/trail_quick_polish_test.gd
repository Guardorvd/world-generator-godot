extends SceneTree
var failures := 0

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 30)
	run.call_deferred()

func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1

func run() -> void:
	var world := WorldData.new()
	world.W = 64; world.H = 64; world.N = 64 * 64
	var points := PackedVector2Array([Vector2(40, 40), Vector2(80, 40)])
	var definition := {id = "world_trail_0", title = "Старт трассы", points = points}
	world.trail_plan = {state = "found", definition = definition, routes = [definition]}
	var hud := Hud.new()
	hud.world = world
	hud.restore_goal("world_trail_0")
	check(hud.goal.get("key") == "world_trail_0", "saved trail destination restores from the actual map catalogue")
	check(hud.goal.get("points") == points, "restored destination keeps the line needed for travel heading")
	check(not hud.at_place(hud.goal, 60, 40), "goal remains active twenty metres before the trail start")
	check(hud.at_place(hud.goal, 42, 40), "goal completes when the player reaches the start")
	var heading := PlayerState.arrival_heading(hud.goal, Vector2(40, 40), 0.0)
	check(Vector2(-sin(heading), -cos(heading)).dot(Vector2.RIGHT) > 0.999, "arrival faces along the trail rather than the world axis")
	var reverse := hud.goal.duplicate()
	reverse.points = PackedVector2Array([Vector2(80, 40), Vector2(80, 40), Vector2(40, 40)])
	heading = PlayerState.arrival_heading(reverse, Vector2(80, 40), 0.0)
	check(Vector2(-sin(heading), -cos(heading)).dot(Vector2.LEFT) > 0.999, "reversed line and repeated first waypoint retain the correct heading")
	check(PlayerState.arrival_heading({kind = "peak"}, Vector2.ZERO, 1.2) == 1.2, "peak arrival preserves the current view")
	hud.restore_goal("removed_trail")
	check(hud.goal.is_empty(), "a removed destination clears without stale coordinates")
	hud.free()
	print("trail_quick_polish: ", failures, " failures")
	quit(1 if failures else 0)
