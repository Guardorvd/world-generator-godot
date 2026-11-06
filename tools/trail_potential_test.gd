extends SceneTree
## Изолированная проверка оценки местности для видов трасс (TrailPotential) и обхода варианта (Network._around).
## Синтетический склон, без мира: секунды. Запуск: godot --headless --script res://tools/trail_potential_test.gd
const Potential := preload("res://scripts/trails/trail_potential.gd")
const Network := preload("res://scripts/trails/trail_world_network.gd")
const GI := preload("res://scripts/trails/trail_generation_input.gd")

var failures := 0

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 30)
	run.call_deferred()

func check(ok: bool, what: String) -> void:
	print(("PASS " if ok else "FAIL ") + what)
	if not ok: failures += 1

## Склон grade (м на м) вдоль +x и лёгкая неровность; вода и запреты пусты.
func slope(grade: float, bumps: float) -> Resource:
	var n := 96
	var input = GI.new()
	input.size = Vector2i(n, n)
	input.cell_size = 4.0
	input.heights.resize(n * n)
	input.water.resize(n * n)
	input.rivers.resize(n * n)
	input.forbidden.resize(n * n)
	for z in n:
		for x in n:
			input.heights[z * n + x] = 100.0 - grade * x * 4.0 + bumps * sin(x * 0.7) * cos(z * 0.5)
	return input

func line() -> PackedVector2Array:
	return PackedVector2Array([Vector2(40, 192), Vector2(120, 192), Vector2(200, 192), Vector2(280, 192)])

func run() -> void:
	var gentle := Potential.assess(slope(0.04, 0.2), line())
	var steep := Potential.assess(slope(0.14, 0.2), line())
	check(not gentle.is_empty() and not steep.is_empty(), "оценка есть у линии в четыре выборки и больше")
	check(gentle.score.flow > gentle.score.downhill, "на пологом спуске flow лучше downhill")
	check(steep.score.downhill > steep.score.flow, "на крутом спуске downhill лучше flow")
	var ok := true
	for a in [gentle, steep]:
		for style: String in Potential.STYLES:
			if a.score[style] < 0.0 or a.score[style] > 1.0: ok = false
	check(ok, "оценки лежат в 0..1")
	check(Potential.assess(slope(0.1, 0.0), PackedVector2Array([Vector2(40, 192), Vector2(50, 192)])).is_empty(), "слишком короткая линия не оценивается")
	var fake := {score = {flow = 0.5, downhill = 0.6, enduro = 0.1, tech = 0.1}}
	check(Potential.choose(fake, {}) == "downhill", "начало маршрута берёт лучший вид")
	check(Potential.choose(fake, {}, "flow") == "flow", "продолжение держит прежний вид, пока другой не лучше заметно")
	check(Potential.choose(fake, {downhill = 3000.0}) == "flow", "вид, которого в сети много, берётся реже")
	check(Potential.choose({}, {}) == "", "без оценки вид не выбирается")
	check(Potential.alternative(fake, "downhill").get("style", "") == "flow", "рядом со вторым хорошим видом есть вариант")
	check(Potential.alternative({score = {flow = 0.2, downhill = 0.6, enduro = 0.1, tech = 0.1}}, "downhill").is_empty(), "слабый второй вид варианта не даёт")
	check(Potential.rank(steep, 1500.0, 2.0) < Potential.rank(steep, 1500.0, 1.0), "место с большими работами ниже в ранге")
	var input := slope(0.08, 0.0)
	var main := PackedVector2Array()
	for k in 21: main.append(Vector2(40.0 + k * 12.0, 192.0))
	var around := Network._around(input, main, 40.0)
	check(around.size() == main.size() and around[0] == main[0] and around[-1] == main[-1], "обход сохраняет начало и конец линии")
	check(absf(around[10].distance_to(main[10]) - 40.0) < 1.0, "посередине обход уходит на заданное расстояние")
	var d := TrailDefinition.new()
	check(Network._variant_error({}, d, d).is_empty(), "обычный участок (без основной линии) вариантом не проверяется")
	print("trail_potential: %d failures" % failures)
	quit(1 if failures > 0 else 0)
