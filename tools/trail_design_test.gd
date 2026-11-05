extends SceneTree
## Изолированная проверка проекта уклона полотна до запекания (TrailBuilder.design): на учебных трассах Trail Lab, секунды.
## Запуск: godot --headless --script res://tools/trail_design_test.gd
const Fixture = preload("res://tools/trail_lab_fixture.gd")
var failures := 0

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	run.call_deferred()

func check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok: failures += 1

func run() -> void:
	for shape in [1, 3, 5]:
		var routes := Fixture.course(shape, "mountain")
		var d := routes[0]
		d.earthwork = 1.0
		var prepared := Fixture.prepare(routes, false)
		if not prepared.errors.is_empty():
			check(false, "учебная трасса %d собирается" % shape)
			continue
		var h: Heightfield = prepared.heights
		var strict := TrailBuilder.design(h, d, 0.05)
		var loose := TrailBuilder.design(h, d, 5.0)
		check(is_finite(strict.grade) and strict.grade > 0.0, "трасса %d: отношение уклона к пределу конечно" % shape)
		check(strict.grade > loose.grade, "трасса %d: строгий предел даёт большее отношение, чем свободный" % shape)
		check(loose.grade < 1.0 and loose.over.is_empty(), "трасса %d: при свободном пределе круч нет" % shape)
		check(strict.grade > 1.0 and not strict.over.is_empty(), "трасса %d: при очень строгом пределе круч отмечены точками" % shape)
		var apart := true
		for k in range(1, strict.over.size() - 1):
			if strict.over[k].distance_to(strict.over[k - 1]) < TrailBuilder.DESIGN_SPAN * 0.5: apart = false
		check(apart, "трасса %d: отмеченные точки не гуще, чем через половину базы" % shape)
		check(TrailBuilder.bake_elements(h, routes).is_empty(), "трасса %d: запекание проходит" % shape)
		var record: Dictionary = h.road_refinement.trail_shaping[d.id]
		check(record.has("used_at") and float(record.used_at) >= 0.0 and float(record.used_at) <= d.route_length(), "трасса %d: запись формирования знает станцию вынужденного шага" % shape)
	print("trail_design: %d failures" % failures)
	quit(1 if failures > 0 else 0)
