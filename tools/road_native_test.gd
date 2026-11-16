extends SceneTree
## Дорожный C# на стенде Trail Lab (вода, сооружения, сдвиг начала координат, виды и покрытия вперемешку): сборка идёт на C#
## (в том числе частичная), результат не пустой и повторяется, полотно RoadBed читает патчи готовой сетки в опоре линии.
## С 16.11.2026 копии на GDScript нет: хеши результата — tools/road_golden.gd (стенд «lab»), здесь — поведение стенда.
const F = preload("res://scripts/lab/trail_lab_fixture.gd")
var failures := 0
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	run.call_deferred()
func check(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ", label)
	failures += int(not ok)
func run() -> void:
	var prepared := F.prepare(F.definitions())
	if not prepared.errors.is_empty(): push_error(str(prepared.errors)); quit(1); return
	var h: Heightfield = prepared.heights
	for i in h.world.N:
		h.hv[i] = 40.0 + (i % h.world.W) * 0.4 + sin(i * 0.03) * 2
		if i % 43 == 0: h.water_level[i] = h.hv[i] - 1
	h.world.world_origin = Vector2i(-71, 123)
	h.structures = [{ax = 40.0, az = 70.0, bx = 120.0, bz = 150.0}]
	for k in h.world.trails.size():
		var route: Dictionary = h.world.trails[k]
		route.kind = ["road", "trail", "mountain"][k % 3]
		for j in route.surf.size(): route.surf[j] = j % 7 + 1
	for fit in [false, true]:
		var first := RoadRefinement.build(h, fit)
		var second := RoadRefinement.build(h, fit)
		check(first.build_timings.has("native_points_ms") and not first.patches.is_empty(), "fit=%s: сетка построена на C#, патчей %d" % [fit, first.patches.size()])
		check(first.patches == second.patches and first.fit_routes == second.fit_routes and first.corridor == second.corridor, "fit=%s: повторная сборка совпадает" % fit)
		check(first.fit_routes.is_empty() != fit, "fit=%s: подгонка профиля %s" % [fit, "есть" if not first.fit_routes.is_empty() else "нет"])
	# частичная сборка (Trail Lab): тот же вызов C#, патчи только у своего пути и с владельцем
	var whole := RoadRefinement.build(h)
	var local := RoadRefinement.build(h, true, {0: true})
	check(local.build_timings.has("native_points_ms") and not local.patches.is_empty() and local.patches.size() < whole.patches.size(),
		"частичная сборка на C#: патчей %d из %d" % [local.patches.size(), whole.patches.size()])
	var owned := true
	for key: int in local.patches: owned = owned and local.patches[key].has("owner") and local.patches[key].owner.has(1)
	check(owned, "у патчей частичной сборки есть владелец")
	check_bed(h)
	print("road_native: ", failures, " failures")
	quit(1 if failures else 0)


## Полотно RoadBed на готовой метровой сетке (путь Trail Lab: only/frozen, патчи в опоре линии)
func check_bed(h: Heightfield) -> void:
	var frozen := PackedByteArray()
	frozen.resize(h.world.N)
	for i in h.world.N:
		frozen[i] = 1 if (i % 97) < 9 else 0
	var cases := [["все пути", {}, PackedByteArray()], ["один путь", {0: true}, PackedByteArray()],
		["два пути, углы заморожены", {1: true, 2: true}, frozen], ["все, заморожено", {}, frozen]]
	for c: Array in cases:
		var copy := h.copy()
		copy.road_refinement = h.road_refinement
		var changed := RoadBed.refine(copy, c[1], c[2])
		var again := h.copy()
		again.road_refinement = h.road_refinement
		var changed_again := RoadBed.refine(again, c[1], c[2])
		check(not changed.is_empty() and changed == changed_again and copy.hv == again.hv, "полотно, %s: изменено клеток %d, повтор совпадает" % [c[0], changed.size()])
		if c[2].size() == h.world.N:
			var held := true
			for i in h.world.N: held = held and (frozen[i] == 0 or copy.hv[i] == h.hv[i])
			check(held, "полотно, %s: замороженные клетки не тронуты" % c[0])
	# контроль: без патчей в опоре результат другой, значит проверка выше действительно проходит через патчи
	var bare := h.copy()
	RoadBed.refine(bare)
	var patched := h.copy()
	patched.road_refinement = h.road_refinement
	RoadBed.refine(patched)
	check(bare.hv != patched.hv, "опора с патчами (%d) отличается от опоры без них" % h.road_refinement.patches.size())
