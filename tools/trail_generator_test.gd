extends SceneTree
const TrailStandards := preload("res://scripts/trails/trail_standards.gd")
const TrailLabTerrain := preload("res://scripts/lab/trail_lab_terrain.gd")
const TrailLabBuilder := preload("res://scripts/lab/trail_lab_builder.gd")
## Генераторы Trail Lab (01.11): местность (TrailLabTerrain) и трасса по ней (TrailLabBuilder) без мира игры.
## По каждому характеру местности и стилю трассы: время генерации, длина, перепад, уклон, элементы, отказы
## стандартов; сборка тем же путём, что в лаборатории (Fixture.prepare с «generated»), и проверка готовой поверхности
## (TrailSurvey). Для каждого прыжка — скорость седока у элемента против окна элемента (TrailStandards.window).
##   godot --headless --path . --script res://tools/trail_generator_test.gd [-- --quick] [--seed 3]
## --quick — одна местность и один стиль (как кнопки лаборатории по умолчанию). Лимит 300 с.
const Fixture = preload("res://tools/trail_lab_fixture.gd")
var failures := 0

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 300)
	run.call_deferred()

func check(ok: bool, text: String) -> void:
	print(("  ✓ " if ok else "  ✗ ") + text)
	if not ok: failures += 1

func run() -> void:
	var args := OS.get_cmdline_user_args()
	var seed := int(args[args.find("--seed") + 1]) if "--seed" in args else 1
	var kinds: Array = ["mountain"] if "--quick" in args else TrailLabTerrain.ORDER
	var styles: Array = ["flow"] if "--quick" in args else TrailLabBuilder.ORDER
	for kind: String in kinds:
		TrailLabTerrain.generate(seed, kind)
		print("\nМестность: %s · %.0f мс" % [TrailLabTerrain.label(), TrailLabTerrain.info.ms])
		var want: Vector2 = TrailLabTerrain.KINDS[kind].fall
		check(TrailLabTerrain.info.fall > want.x * 0.6 and TrailLabTerrain.info.fall < want.y * 1.6, "перепад %.0f м в характере %s (%.0f–%.0f)" % [TrailLabTerrain.info.fall, kind, want.x, want.y])
		for style: String in styles:
			var routes := TrailLabBuilder.build(TrailLabTerrain.ground, TrailLabTerrain.SIZE, seed, style)
			if routes.is_empty():
				check(false, "%s: %s" % [style, TrailLabBuilder.stats.get("reason", "нет линии")])
				continue
			var st := TrailLabBuilder.stats
			print("  трасса: %s · %.0f мс · отказы %s" % [TrailLabBuilder.label(), st.ms, st.refused])
			var d := routes[0]
			check(d.validate().is_empty(), "%s: определение верно %s" % [style, d.validate()])
			check(st.length > 500.0, "%s: длина %.0f м" % [style, st.length])
			var started := Time.get_ticks_usec()
			var prepared := Fixture.prepare(routes, true, "generated")
			var build_ms := (Time.get_ticks_usec() - started) / 1000.0
			if not prepared.errors.is_empty():
				check(false, "%s: сборка %s" % [style, prepared.errors])
				continue
			var survey := TrailSurvey.measure(prepared.heights, d, 0.2)
			check(survey.errors.is_empty(), "%s: собрана за %.0f мс, поверхность измерена %s" % [style, build_ms, survey.errors])
			# скорость седока у прыжков против их окон
			var speeds := TrailStandards.speed_profile(d, TrailLabTerrain.ground, 2)
			var jumps := 0
			var inside := 0
			for e in d.elements:
				if e.profile not in [TrailElement.Profile.TABLETOP, TrailElement.Profile.GAP]: continue
				jumps += 1
				var w := TrailStandards.window(e, d, TrailStandards.element_grade(d, TrailLabTerrain.ground, e.station - e.length * 0.5))
				var v := speeds[clampi(int(e.station - e.length * 0.5), 0, speeds.size() - 1)]
				var ok: bool = w.has("speed_lo") and w.has("speed_hi") and v >= float(w.speed_lo) - 0.6 and v <= float(w.speed_hi) + 0.6
				inside += int(ok)
				print("    %s %.0f×%.1f у %.0f м: седок %.1f м/с, окно %s–%s (идеал %s)" % [TrailElementLibrary.title(e.profile), e.length, e.height, e.station, v,
					str(w.get("speed_lo", "—")), str(w.get("speed_hi", "—")), str(w.get("speed_ideal", "—"))])
			check(inside == jumps, "%s: прыжков в окне скорости %d из %d" % [style, inside, jumps])
	print("\nИТОГ: %s" % ("PASS" if failures == 0 else "FAIL (%d)" % failures))
	quit(1 if failures > 0 else 0)
