extends SceneTree
const TrailStandards := preload("res://scripts/trails/trail_standards.gd")
const TrailLabTerrain := preload("res://scripts/lab/trail_lab_terrain.gd")
const TrailLabBuilder := preload("res://scripts/lab/trail_lab_builder.gd")
## Генераторы Trail Lab (01.11): местность (TrailLabTerrain) и трасса по ней (TrailLabBuilder) без мира игры.
## По каждому характеру местности и стилю трассы: время генерации, длина, перепад, уклон, элементы, отказы
## стандартов; сборка тем же путём, что в лаборатории (Fixture.prepare с «generated»), и проверка готовой поверхности
## (TrailSurvey). Для каждого прыжка — скорость седока у элемента против окна элемента (TrailStandards.window).
## v2: тугие повороты — на скорости седока проходятся или с виражом; разнообразие — три сида на одной местности дают
## разные линии, два сида одного характера — разные местности.
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

## Повороты оси туже 40 м: скорость на подходе не выше turn_speed (с наклоном трассы) или в повороте стоит вираж.
## Печатает худшие; допускается один (разворот у края, где места на вираж нет).
func turns_ok(d: TrailDefinition, speeds: PackedFloat32Array) -> bool:
	var shape := d.shape()
	var bad := []
	var at := 4.0
	while at < d.route_length() - 4.0:
		if absf(d.curvature_at(at)) < 1.0 / 40.0:
			at += 1.0
			continue
		var from := at
		var sign := signf(d.curvature_at(at))
		while at < d.route_length() - 4.0 and absf(d.curvature_at(at)) >= 0.7 / 40.0 and signf(d.curvature_at(at)) == sign: at += 1.0
		var r := TrailStandards.tightest(d, from, at)
		var v := 0.0
		for k in range(maxi(0, int(from) - 8), mini(speeds.size(), int(from) + 1)): v = maxf(v, speeds[k])
		var bank := minf(absf(d.curvature_at((from + at) * 0.5)) * shape.bank_gain, shape.bank_max) * d.auto_bank
		var tight := from
		for k in range(int(from), int(at) + 1):
			if absf(d.curvature_at(k)) > absf(d.curvature_at(tight)): tight = k
		var berm := false
		for e in d.elements:
			if e.profile in [TrailElement.Profile.BERM, TrailElement.Profile.S_BERM] and absf(e.station - tight) < e.length * 0.5 + 1.0: berm = true
		if is_finite(r) and not berm and v > TrailStandards.turn_speed(r, bank, 0.8) + 0.5: bad.append("R %.0f у %.0f м на %.1f м/с" % [r, from, v])
		at += 2.0
	if not bad.is_empty(): print("    без виража не пройти: ", bad.slice(0, 5))
	return bad.size() <= 1

## Разнообразие: три сида трассы на одной местности — разные старты и линии; два сида местности — разные высоты.
func variety(seed: int) -> void:
	print("\nРазнообразие")
	TrailLabTerrain.generate(seed, "mountain")
	var lines: Array[PackedVector2Array] = []
	for k in 3:
		var routes := TrailLabBuilder.build(TrailLabTerrain.ground, TrailLabTerrain.SIZE, seed + 100 * k, "flow")
		if routes.is_empty(): continue
		lines.append(routes[0].points)
		print("  сид %d: старт %s, %s" % [seed + 100 * k, TrailLabBuilder.stats.start.round(), TrailLabBuilder.label()])
	var similar := 0
	for i in lines.size():
		for j in range(i + 1, lines.size()):
			if share_near(lines[i], lines[j]) > 0.5: similar += 1
	check(lines.size() == 3 and similar == 0, "три сида на одной местности — разные трассы (похожих пар %d)" % similar)
	var a := TrailLabTerrain.cells.duplicate()
	TrailLabTerrain.generate(seed + 1, "mountain")
	var differ := 0.0
	for i in range(0, a.size(), 97): differ += absf(a[i] - TrailLabTerrain.cells[i])
	differ /= float(a.size() / 97)
	check(differ > 5.0, "два сида горы — разная местность (средняя разница высот %.0f м)" % differ)

## Доля точек линии a ближе 10 м к линии b.
func share_near(a: PackedVector2Array, b: PackedVector2Array) -> float:
	var near := 0
	for i in range(0, a.size(), 5):
		for j in range(0, b.size(), 2):
			if a[i].distance_squared_to(b[j]) < 100.0:
				near += 1
				break
	return near / float(ceili(a.size() / 5.0))

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
			check(st.length > 350.0, "%s: длина %.0f м" % [style, st.length]) # поле 512 м: крутой спуск честно 400–600 м
			var started := Time.get_ticks_usec()
			var prepared := Fixture.prepare(routes, true, "generated")
			var build_ms := (Time.get_ticks_usec() - started) / 1000.0
			if not prepared.errors.is_empty():
				check(false, "%s: сборка %s" % [style, prepared.errors])
				continue
			var survey := TrailSurvey.measure(prepared.heights, d, 0.2)
			check(survey.errors.is_empty(), "%s: собрана за %.0f мс, поверхность измерена %s" % [style, build_ms, survey.errors])
			print("    радиус поворотов (медиана) %.0f м · целевой уклон %.1f %% · тяга к цели %.2f" % [st.radius_median, st.target_grade, st.pull])
			# скорость седока («как едут», по ней ставились элементы) у прыжков против их окон
			var speeds := TrailLabBuilder.speeds
			check(turns_ok(d, speeds), "%s: тугие повороты проходятся на скорости седока или с виражом" % style)
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
	variety(seed)
	print("\nИТОГ: %s" % ("PASS" if failures == 0 else "FAIL (%d)" % failures))
	quit(1 if failures > 0 else 0)
