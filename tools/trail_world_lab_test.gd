extends SceneTree
## Генераторы Trail Lab v3 на большом мире (01.11): мир размером с план игры (TrailLabTerrain.generate_world),
## поисковик мест (TrailLabScout), трасса каждого места (TrailLabSites → TrailLabBuilder) и сборка её окна тем же путём,
## что в лаборатории (Fixture.prepare с «generated»). Проверки:
##   - число мест по пригодности карты; разные границы, без дубликатов пробных коридоров;
##   - трасса каждого места: принята после проверки полотна либо отклонена с конкретной причиной;
##   - овражки: под открытым пролётом земля ниже кромок пролёта (внизу овражек, а не насыпь);
##   - петля: верхний проход над нижним — просвет от полотна нижнего прохода до настила или траектории не меньше 2,5 м;
##   - сводно — прыжки (стол, гэп, дроп), овражки и петли на всех местах.
##   godot --headless --path . --script res://tools/trail_world_lab_test.gd [-- --seed 7] [--sites 3]
## География игры целиком — десятки секунд без C#; лимит 300 с.
const Fixture = preload("res://tools/trail_lab_fixture.gd")
const TrailLabTerrain := preload("res://scripts/lab/trail_lab_terrain.gd")
const Sites := preload("res://scripts/lab/trail_lab_sites.gd")
const TrailLabScout := preload("res://scripts/lab/trail_lab_scout.gd")
const TrailLabBuilder := preload("res://scripts/lab/trail_lab_builder.gd")
var failures := 0

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 300)
	run.call_deferred()

func check(ok: bool, text: String) -> void:
	print(("  ✓ " if ok else "  ✗ ") + text)
	if not ok: failures += 1

## Лаборатория: мир в фоне (тот же сид — из кэша), список мест, переключение места ставит его трассу.
func lab_check(seed: int) -> void:
	print("\nЛаборатория")
	var lab: Node = load("res://scenes/trail_lab.tscn").instantiate()
	root.add_child(lab)
	await process_frame
	await process_frame
	check(lab.generate_world(seed), "генерация мира запущена")
	var frames := 0
	while lab._world_thread != null and frames < 3000:
		await process_frame
		frames += 1
	check(lab._world_thread == null, "мир готов в фоне (%d кадров)" % frames)
	check(lab.site_select.item_count == Sites.sites.size() and lab.site_row.visible, "список мест: %d" % lab.site_select.item_count)
	var first_accepted: bool = Sites._built.has(0) and Sites._built[0].stats.get("accepted", false)
	check((not lab.routes.is_empty() and str(lab.routes[0].id).begins_with("site1_")) if first_accepted else not Sites._built[0].stats.get("reason", "").is_empty(), "место 1: принята проверенная трасса или показана причина отказа")
	if Sites.sites.size() > 1:
		var before: String = lab.routes[0].id
		var selected: bool = lab.select_site(1)
		if selected:
			check(str(lab.routes[0].id).begins_with("site2_") and Sites._built[1].stats.accepted, "место 2 принято после проверки")
			check(lab.player.x != 0.0 and lab.routes[0].nearest(Vector2(lab.bike.x, lab.bike.z)).z < 3.0, "седок на старте места 2")
		else:
			check(lab.routes[0].id == before and not Sites._built[1].stats.get("reason", "").is_empty(), "отказ места 2 сохраняет прежнюю сцену и причину")
	lab.shutdown()
	lab.queue_free()
	await process_frame

func run() -> void:
	var args := OS.get_cmdline_user_args()
	var seed := int(args[args.find("--seed") + 1]) if "--seed" in args else 7
	var limit := int(args[args.find("--sites") + 1]) if "--sites" in args else 8
	var t := Time.get_ticks_usec()
	var count := Sites.generate_world(seed)
	print("Мир %d: %d × %d клеток · %.1f с (%s) · поиск %.0f мс, окон %d, годных %d, отказы %s" % [seed, TrailLabTerrain.world_size, TrailLabTerrain.world_size,
		(Time.get_ticks_usec() - t) / 1e6, TrailLabTerrain.world_info.get("stages", {}), TrailLabScout.stats.get("ms", 0.0), TrailLabScout.stats.get("looked", 0),
		TrailLabScout.stats.get("fit", 0), TrailLabScout.stats.get("refused", {})])
	check(TrailLabTerrain.world_size == WorldGenerator.PLAN_SIZE, "мир размером с план игры (%d)" % TrailLabTerrain.world_size)
	check(count >= 1, "мест под трассы по пригодности карты: %d" % count)
	var apart := true
	for i in Sites.sites.size():
		for j in range(i + 1, Sites.sites.size()):
			if TrailLabScout.overlap(Sites.sites[i].corridor, Sites.sites[j].corridor) >= TrailLabScout.OVERLAP: apart = false
	check(apart, "нет дубликатов коридоров пробных трасс")
	var totals := {jumps = 0, gaps = 0, decks = 0, ravines = 0, loops = 0, length = 0.0}
	var proposed := {ravines = 0, loops = 0}
	for i in mini(count, limit):
		var site := Sites.sites[i]
		var started := Time.get_ticks_usec()
		var ok := Sites.select(i)
		var line_ms := (Time.get_ticks_usec() - started) / 1000.0
		print("\nМесто %s · %.0f мс" % [Sites.title(i), line_ms])
		if not ok:
			check(not TrailLabBuilder.stats.get("accepted", true) and not TrailLabBuilder.stats.get("reason", "").is_empty(), "место %d: явный отказ (%s)" % [i + 1, TrailLabBuilder.stats.get("reason", "")])
			continue
		var routes := Sites.routes()
		var d := routes[0]
		var st: Dictionary = Sites._built[i].stats
		proposed.ravines += int(st.get("ravines", 0))
		proposed.loops += int(st.get("loop", false))
		print("  %s · отказы %s · линия %s мс, петля и овражки %s мс, составитель %s мс" % [Sites._built[i].label, st.refused, st.get("walk_ms", 0), st.get("features_ms", 0), st.get("compose_ms", 0)])
		check(d.validate().is_empty(), "место %d: определение верно %s" % [i + 1, d.validate()])
		started = Time.get_ticks_usec()
		var prepared := Fixture.prepare(routes, true, "generated")
		var build_ms := (Time.get_ticks_usec() - started) / 1000.0
		if not prepared.errors.is_empty():
			check(prepared.has("validation") and prepared.heights == null and not TrailLabBuilder.stats.accepted, "место %d: итоговая проверка отклонила трассу %s" % [i + 1, prepared.errors])
			continue
		var h: Heightfield = prepared.heights
		var survey := TrailSurvey.measure(h, d, 0.2)
		check(survey.errors.is_empty(), "место %d: собрано за %.0f мс, поверхность измерена %s" % [i + 1, build_ms, survey.errors])
		# овражки: под пролётом земля ниже кромок
		for span in d.open_spans:
			var mid := d.point_at((span.x + span.y) * 0.5)
			var a := d.point_at(span.x - 1.0)
			var b := d.point_at(span.y + 1.0)
			var low := h.ground_at(mid.x, mid.y)
			var edge := minf(h.ground_at(a.x, a.y), h.ground_at(b.x, b.y))
			check(edge - low >= 0.6 and edge - low <= span.z + 1.5, "место %d: пролёт %.0f–%.0f м — внизу овражек на %.1f м ниже кромок" % [i + 1, span.x, span.y, edge - low])
		if st.get("loop", false):
			var cross := TrailLabBuilder._self_crossing(d)
			var x := d.point_at(cross.y)
			var floor_y := h.ground_at(x.x, x.y)
			var top := -INF
			for e in d.elements:
				if absf(e.station - cross.x) > e.length * 0.5: continue
				if e.profile == TrailElement.Profile.NORTHSHORE:
					var g0 := d.point_at(e.station - e.length * 0.5)
					var g1 := d.point_at(e.station + e.length * 0.5)
					top = TrailTechnical._deck_level(cross.x - (e.station - e.length * 0.5), e, h.ground_at(g0.x, g0.y), h.ground_at(g1.x, g1.y))
				elif e.profile == TrailElement.Profile.GAP:
					var lip := d.point_at(e.station - e.length * 0.5 + e.gap_lip())
					top = h.ground_at(lip.x, lip.y) # над разрывом седок не ниже кромки (полёт вверх)
			check(top - floor_y >= 2.5 and top - floor_y <= 7.0, "место %d: петля — просвет над нижним проходом %.1f м" % [i + 1, top - floor_y])
		totals.jumps += int(st.get("jumps", 0))
		totals.gaps += int(st.get("gaps", 0))
		totals.decks += int(st.get("decks", 0))
		totals.ravines += int(st.get("ravines", 0))
		totals.loops += int(st.get("loop", false))
		totals.length += float(st.length)
	print("\nВсего: %.1f км трасс · прыжков %d (гэпов по стандарту %d) · овражков %d · мостков %d · петель %d" % [totals.length / 1000.0, totals.jumps, totals.gaps, totals.ravines, totals.decks, totals.loops])
	check(totals.gaps == 0, "по умолчанию нет обязательных гэпов")
	if limit < count:
		print("Ограниченная выборка %d из %d мест: предложено овражков %d, петель %d; разнообразие всех мест не проверялось" % [limit, count, proposed.ravines, proposed.loops])
	await lab_check(seed)
	print("\nИТОГ: %s" % ("PASS" if failures == 0 else "FAIL (%d)" % failures))
	quit(1 if failures > 0 else 0)
