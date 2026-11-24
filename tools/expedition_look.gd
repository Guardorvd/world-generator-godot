extends SceneTree
## Стенд Типа 2 «Речная экспедиция» (docs/WORLD_TEMPLATES.md):
##   -- --geo              география плана, лист-карта с продольным профилем, биомы, время этапов
##   -- --short            короткая версия (256 × 768) для быстрой отладки
##   -- --height <N>       явная длина плана (кратно 64, <= 4096)
##   -- --seeds a,b        сиды (по умолчанию CONTROL)
##   -- --tag <имя>        суффикс файлов
##   -- --verify-phase1    проверка изоляции кэша/сейвов/настроек, отсутствия невидимой стены и px <= 4096
##   -- --verify-phase2    проверка монотонности реки, краёв ленты, глубины/течения, стыков OuterLand и C# == GDScript
##   -- --roads            фаза 3: одна дорога, метрики (длина, берег/лес, набор/сброс, прямые, валидация) и лист-карта
##   -- --shots            3D-снимки долины в настоящей сцене GameWorld (нужно окно; короткий мир 256×768)
##   -- --phase8          кадры растительности из GameWorld; --short-expedition для короткого плана
##   -- --phase8-drive    отдельный проезд с замером кадров на том же сохранённом плане
##   -- --maple           клён на лесной дороге и влажной террасе в GameWorld
##   -- --shots-p3         3D-снимки фазы 3: старт, берег, лесной отрог, финиш с причалом (нужно окно)
##   -- --verify-phase4    проверка меню, большой карты M (масштаб вокруг игрока), доски заданий/альбома и сохранения Типа 2 (нужно окно)
##   -- --verify-phase5    проверка изоляции per-template RoadTuning, 16-поточности, ключей кэша, SurfaceSnapshot и шейдеров
##   -- --verify-phase7    проверка полотна Типа 2: корыто, косогор, контруклон, препятствия, паритет RoadBump и проезд
##   -- --shots-p7         крупные планы тропы Типа 2 с высоты руля: спуск, косогор, контруклон, корни (нужно окно)
## Лимит 240 с.

const CONTROL := ["Север-1234", "Туман-4821"]
const OUT := "res://tools/control/runs"
const Saves := preload("res://scripts/game/save_game.gd")
const RoadRecords := preload("res://scripts/world/road_records.gd")
const OpeningRoute := preload("res://scripts/game/opening_route.gd")

const GROUPS := {
	forest = [Biomes.FOREST, Biomes.TAIGA, Biomes.JUNGLE],
	meadow = [Biomes.GRASS],
	steppe = [Biomes.STEPPE, Biomes.SAVANNA, Biomes.DESERT],
	tundra = [Biomes.TUNDRA],
	swamp = [Biomes.SWAMP],
	rock = [Biomes.ROCK, Biomes.PEAK, Biomes.SNOW],
	shore = [Biomes.BEACH, Biomes.STONESHORE],
	water = [Biomes.DEEP, Biomes.OCEAN, Biomes.SHALLOW, Biomes.LAKE],
}


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 240)
	call_deferred("_run")


func _arg(name: String, fallback: String = "") -> String:
	var args := OS.get_cmdline_user_args()
	var at := args.find(name)
	if at < 0:
		return fallback
	return args[at + 1] if at + 1 < args.size() and not args[at + 1].begins_with("--") else ""


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var maple := args.has("--maple")
	var tag := _arg("--tag", "")
	var short_dev := args.has("--short")
	var explicit_h := int(_arg("--height", "0"))
	var seeds: PackedStringArray = _arg("--seeds", ",".join(CONTROL)).split(",", false)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))

	var ok := true
	if args.has("--verify-phase1"):
		ok = _verify_phase1(short_dev) and ok

	if args.has("--verify-phase2"):
		ok = _verify_phase2(seeds[0], short_dev, explicit_h) and ok

	if args.has("--roads"):
		ok = _verify_phase3_roads(seeds, tag, short_dev, explicit_h) and ok

	var fp_out := _arg("--fingerprint", "")
	var fp_cmp := _arg("--compare-fp", "")
	if not fp_out.is_empty() or not fp_cmp.is_empty():
		ok = _run_fingerprint(seeds[0], short_dev, explicit_h, fp_out, fp_cmp) and ok

	if args.has("--geo") or (not args.has("--verify-phase1") and not args.has("--verify-phase2") and not args.has("--roads") and not args.has("--shots") and not args.has("--shots-p3") and not args.has("--shots-p7") and not args.has("--phase8") and not args.has("--phase8-drive") and not maple and not args.has("--verify-phase4") and not args.has("--verify-phase5") and not args.has("--verify-phase7") and fp_out.is_empty() and fp_cmp.is_empty()):
		var maps: Array[Image] = []
		var rows := []
		for seed_text: String in seeds:
			var t0 := Time.get_ticks_usec()
			var w := WorldGenerator._geography(seed_text, WorldGenerator.PLAN_SIZE, Callable(), Callable(),
				WorldTemplate.EXPEDITION_ID, short_dev, explicit_h)
			var total_ms := (Time.get_ticks_usec() - t0) / 1000.0
			var row := _stats(w, total_ms)
			rows.append(row)
			maps.append(_render_strip_with_profile(w))
			_print_row(row)
			w.clear_noise_fields()
			w.base_heights = null
		var sheet := _sheet(maps)
		var png_path := ProjectSettings.globalize_path(OUT.path_join("expedition_geo%s.png" % tag))
		sheet.save_png(png_path)
		var json_path := ProjectSettings.globalize_path(OUT.path_join("expedition_geo%s.json" % tag))
		var f := FileAccess.open(json_path, FileAccess.WRITE)
		f.store_string(JSON.stringify({short = short_dev, rows = rows}, "\t"))
		f.close()
		print("Expedition geo sheet: ", png_path)

	if args.has("--shots"):
		ok = await _capture_3d_shots(seeds[0], tag) and ok

	if args.has("--shots-p3"):
		ok = await _capture_phase3_shots(seeds[0], tag) and ok

	if args.has("--shots-p7"):
		ok = await _capture_phase7_shots(seeds[0], tag) and ok

	if args.has("--phase8") or args.has("--phase8-drive") or maple:
		ok = await _capture_phase3_shots(seeds[0], tag, true, args.has("--phase8-drive"), maple) and ok

	if args.has("--verify-phase4"):
		ok = await _verify_phase4(seeds[0], tag) and ok

	if args.has("--verify-phase5"):
		ok = _verify_phase5() and ok

	if args.has("--verify-phase7"):
		ok = _verify_phase7(seeds, short_dev, explicit_h) and ok

	quit(0 if ok else 1)


func _verify_phase2(seed_text: String, short_dev: bool, explicit_h: int) -> bool:
	var failures: Array[String] = []
	var w := WorldGenerator._geography(seed_text, WorldGenerator.PLAN_SIZE, Callable(), Callable(),
		WorldTemplate.EXPEDITION_ID, short_dev, explicit_h)
	if w == null:
		push_error("PHASE2_VERIFY FAIL: geography returned null")
		return false
	var axis := ValleyAxis.for_world(w)
	var surf: Heightfield = w.base_heights
	if surf == null or surf.ribbons.size() != 1:
		failures.append("expected 1 river ribbon, got %d" % (surf.ribbons.size() if surf != null else -1))
	else:
		var pts: Array = surf.ribbons[0]
		# 1. Монотонность уровня реки
		var uphill := 0
		for k in range(1, pts.size()):
			if pts[k].y > pts[k - 1].y + 1e-5:
				uphill += 1
		if uphill > 0:
			failures.append("river goes uphill at %d stations" % uphill)
		# 2. Края ленты заходят в берег (вода не висит и нет щелей)
		var floating := 0
		var dry_center := 0
		var zero_current := 0
		var sample_step := maxi(1, pts.size() / 80)
		for k in range(2, pts.size() - 2, sample_step):
			var p: Dictionary = pts[k]
			var gl := surf.ground_at(p.left.x, p.left.z)
			var gr := surf.ground_at(p.right.x, p.right.z)
			if gl < p.y - 0.05 or gr < p.y - 0.05:
				floating += 1
			var dc := surf.depth_at(p.x, p.z)
			if dc < 0.8:
				dry_center += 1
			var cur := surf.current_at(p.x, p.z)
			if cur.length() < 0.1:
				zero_current += 1
		if floating > 0:
			failures.append("river ribbon edge floats above bank at %d samples" % floating)
		if dry_center > 0:
			failures.append("river center too shallow (<0.8m) at %d samples" % dry_center)
		if zero_current > 0:
			failures.append("river current_at is zero at %d samples" % zero_current)
		# 3. C# RideGround parity on river center & banks
		surf.native_ride = true
		var ride_mismatch := 0
		for k in range(4, pts.size() - 4, maxi(1, pts.size() / 20)):
			var p: Dictionary = pts[k]
			var d_nat := surf.depth_at(p.x, p.z)
			surf.native_ride = false
			var d_gd := surf.depth_at(p.x, p.z)
			surf.native_ride = true
			if absf(d_nat - d_gd) > 0.02:
				ride_mismatch += 1
		if ride_mismatch > 0:
			failures.append("RideGround depth mismatch vs GDScript at %d river samples" % ride_mismatch)
		# 4. SurfaceSnapshot validation
		var snap := preload("res://scripts/game/surface_snapshot.gd").capture(surf, "base")
		if not preload("res://scripts/game/surface_snapshot.gd").valid(w, snap, "base"):
			failures.append("SurfaceSnapshot.valid failed for Type 2 base heightfield")

	# 5. Нет океана в плане
	var ocean_n := 0
	for i in w.N:
		if w.ocean[i] != 0:
			ocean_n += 1
	if ocean_n > 0:
		failures.append("ocean cells inside valley plan: %d" % ocean_n)

	# 6. Стык с OuterLand без ступеньки на всех 4 краях
	var outer := OuterLand.new(w)
	var max_step_m := 0.0
	for y in range(0, w.H, maxi(1, w.H / 40)):
		var h_in_l := w.h[y * w.W + 0] * GameConfig.HS
		var h_out_l := outer.height(-1, y) * GameConfig.HS
		max_step_m = maxf(max_step_m, absf(h_in_l - h_out_l))
		var h_in_r := w.h[y * w.W + (w.W - 1)] * GameConfig.HS
		var h_out_r := outer.height(w.W, y) * GameConfig.HS
		max_step_m = maxf(max_step_m, absf(h_in_r - h_out_r))
	for x in range(0, w.W, 8):
		max_step_m = maxf(max_step_m, absf(w.h[x] - outer.height(x, -1)) * GameConfig.HS)
		max_step_m = maxf(max_step_m, absf(w.h[(w.H - 1) * w.W + x] - outer.height(x, w.H)) * GameConfig.HS)
	if max_step_m > 10.0:
		failures.append("plan/OuterLand edge jump too large: %.2f m" % max_step_m)

	# 7. C# == GDScript паритет рельефа долины (ближний 64×64 и разрежённый 35×35 с шагом 4)
	var fast_patch := StageRelief.height_rect(w, 64, w.H / 3, 64, 64, false, true)
	StageRelief.allow_fast_valley = false
	var gd_patch := StageRelief.height_rect(w, 64, w.H / 3, 64, 64, false, true)
	StageRelief.allow_fast_valley = true
	var max_diff := 0.0
	for k in fast_patch.size():
		max_diff = maxf(max_diff, absf(fast_patch[k] - gd_patch[k]))
	if max_diff > 1e-4:
		failures.append("C# vs GDScript valley relief max diff = %.6f" % max_diff)

	var coarse_fast := StageRelief.valley_coarse_rect(w, -16, w.H / 3, 35, 35, 4, false)
	StageRelief.allow_fast_valley = false
	var coarse_gd := StageRelief.valley_coarse_rect(w, -16, w.H / 3, 35, 35, 4, false)
	StageRelief.allow_fast_valley = true
	var coarse_diff := 0.0
	for k in coarse_fast.size():
		coarse_diff = maxf(coarse_diff, absf(coarse_fast[k] - coarse_gd[k]))
	if coarse_diff > 1e-4:
		failures.append("C# vs GDScript valley_coarse_rect max diff = %.6f" % coarse_diff)

	# 7b. Метрики извилистости реки (Фаза 6)
	var curv := _river_curvature_metrics(axis)
	if float(curv.sinuosity) < 1.04:
		failures.append("river sinuosity too low: %.3f (< 1.04)" % float(curv.sinuosity))
	if w.W >= 384 and float(curv.x_span) < 80.0:
		failures.append("river x_span too narrow: %.1f (< 80.0)" % float(curv.x_span))

	# 7c. Тест лёгкого дальнего пояса OuterTerrain (гольцы за краем плана)
	var ot := OuterTerrain.new()
	ot.setup(w, surf)
	if ot._far_radius <= 0.0:
		failures.append("OuterTerrain._far_radius <= 0.0 for Type 2")
	else:
		var fkeys := ot._wanted_far(float(w.W) * 2.0, float(w.H) * 2.0, ot._far_radius)
		if fkeys.is_empty():
			failures.append("OuterTerrain._wanted_far returned empty")
		else:
			var fb := ot._compute_far(fkeys[0])
			var arr: Array = fb.get("arrays", [])
			if arr.is_empty() or arr[Mesh.ARRAY_VERTEX].is_empty() or arr[Mesh.ARRAY_INDEX].is_empty():
				failures.append("OuterTerrain._compute_far produced empty mesh arrays")
	ot.finish()
	ot.free()

	# 8. Проверка доли биомов в полосе дороги (по нормали к руслу)
	var cor_n := 0
	var cor_forest := 0
	var cor_swamp := 0
	var cor_rock_tundra := 0
	for y in range(20, w.H - 20, 2):
		var ax := axis.axis_x_at(float(y))
		var rhw := axis.river_hw_at(y)
		var cos_t := maxf(axis.axis_cos_at(y), 0.25)
		for sd_i in range(ceili(rhw + 4.0), 75, 2):
			var x := roundi(ax + (float(sd_i) / cos_t) * float(axis.road_side))
			if x < 0 or x >= w.W:
				continue
			var bi := w.biome[y * w.W + x]
			cor_n += 1
			if bi in GROUPS.forest:
				cor_forest += 1
			elif bi == Biomes.SWAMP:
				cor_swamp += 1
			elif bi in GROUPS.rock or bi == Biomes.TUNDRA:
				cor_rock_tundra += 1
	var f_pct := 100.0 * float(cor_forest) / float(maxi(1, cor_n))
	var s_pct := 100.0 * float(cor_swamp) / float(maxi(1, cor_n))
	var rt_pct := 100.0 * float(cor_rock_tundra) / float(maxi(1, cor_n))
	print("PHASE2_METRICS seed=%s %dx%d drop=%.1fm spurs=%d opp_spurs=%d edge_step=%.2fm cs_gd_diff=%.6f coarse_diff=%.6f sinuosity=%.3f x_span=%.1f bends20=%d sight=%.0fm corridor(forest=%.1f%% swamp=%.1f%% rock+tundra=%.1f%%)" % [
		seed_text, w.W, w.H, (axis.top_h - axis.bot_h) * GameConfig.HS, axis.spurs.size(), axis.opp_spurs.size(),
		max_step_m, max_diff, coarse_diff, float(curv.sinuosity), float(curv.x_span), int(curv.bends_20), float(curv.max_sight_m),
		f_pct, s_pct, rt_pct])

	w.clear_noise_fields()
	w.base_heights = null
	if failures.is_empty():
		print("PHASE2_VERIFY: PASS")
		return true
	for msg: String in failures:
		push_error("PHASE2_VERIFY FAIL: " + msg)
	return false


static func _river_curvature_metrics(axis: ValleyAxis) -> Dictionary:
	var y_start := 20
	var y_end := maxi(y_start + 40, axis.H - 20)
	var prev_x := axis.axis_x_at(float(y_start))
	var prev_y := float(y_start)
	var min_x := prev_x
	var max_x := prev_x
	var arc_len := 0.0
	var y := y_start + 2
	while y <= y_end:
		var ax := axis.axis_x_at(float(y))
		arc_len += Vector2(ax - prev_x, float(y) - prev_y).length()
		min_x = minf(min_x, ax)
		max_x = maxf(max_x, ax)
		prev_x = ax
		prev_y = float(y)
		y += 2
	var straight_len := Vector2(axis.axis_x_at(float(y_end)) - axis.axis_x_at(float(y_start)), float(y_end - y_start)).length()
	var sinuosity := arc_len / maxf(1.0, straight_len)

	var bends_20 := 0
	var prev_dir := Vector2.ZERO
	var cy := y_start + 40
	var cy_prev := y_start
	while cy <= y_end:
		var p0 := Vector2(axis.axis_x_at(float(cy_prev)), float(cy_prev))
		var p1 := Vector2(axis.axis_x_at(float(cy)), float(cy))
		var dir := (p1 - p0).normalized()
		if prev_dir != Vector2.ZERO and absf(prev_dir.angle_to(dir)) >= deg_to_rad(20.0):
			bends_20 += 1
		prev_dir = dir
		cy_prev = cy
		cy += 40

	var max_sight_cells := 0.0
	var s0 := y_start
	while s0 < y_end - 20:
		var x0 := axis.axis_x_at(float(s0))
		var s1 := s0 + 20
		while s1 <= y_end:
			var x1 := axis.axis_x_at(float(s1))
			var occluded := false
			var probe := s0 + 4
			while probe < s1:
				var t := float(probe - s0) / float(s1 - s0)
				var line_x := lerpf(x0, x1, t)
				var ax := axis.axis_x_at(float(probe))
				var half_corr := (axis.river_hw_at(probe) + 8.0) / maxf(axis.axis_cos_at(probe), 0.25)
				if absf(line_x - ax) > half_corr:
					occluded = true
					break
				probe += 4
			if occluded:
				break
			max_sight_cells = maxf(max_sight_cells, Vector2(x1 - x0, float(s1 - s0)).length())
			s1 += 10
		s0 += 10

	return {
		sinuosity = sinuosity,
		x_span = max_x - min_x,
		bends_20 = bends_20,
		max_sight_m = max_sight_cells * GameConfig.TILE,
	}


func _capture_3d_shots(seed_text: String, tag: String) -> bool:
	if DisplayServer.get_name() == "headless":
		push_error("PHASE2_SHOTS: window required (do not pass --headless)")
		return false
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(Vector2i(1280, 720))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	for _i in 20:
		await process_frame
	GameContext.scope.cache.enabled = false
	main.start_game(seed_text, WorldGenerator.START_SIZE, "", false, WorldTemplate.EXPEDITION_ID)
	var wait_frames := 0
	while (main.busy or main.game == null or main.game.player == null) and wait_frames < 12000:
		await process_frame
		wait_frames += 1
	if main.game == null or main.game.player == null:
		push_error("PHASE2_SHOTS: GameWorld failed to start")
		main.queue_free()
		return false
	var gw: GameWorld = main.game
	gw.paused = true
	main.hud.visible = false
	if gw.pause_requested.is_connected(main._toggle_pause):
		gw.pause_requested.disconnect(main._toggle_pause)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if gw.opening_active():
		gw._finish_opening()
	gw.hour = 10.5
	if gw.day != null:
		gw.day.apply(10.5, 100.0)
	gw.camera.fov = 70.0
	gw.camera.current = true

	var w: WorldData = gw.world
	var h: Heightfield = gw.heights
	var axis := ValleyAxis.for_world(w)
	var T := GameConfig.TILE

	var bend_y := float(w.H) * 0.42
	var best_k := -1.0
	for sy in range(maxi(60, w.H / 4), mini(w.H - 120, w.H * 3 / 4), 6):
		var k := absf(axis.axis_x_at(float(sy + 18)) - 2.0 * axis.axis_x_at(float(sy)) + axis.axis_x_at(float(sy - 18)))
		if k > best_k:
			best_k = k
			bend_y = float(sy)
	var wall_y := clampf(bend_y + 70.0, 90.0, float(w.H) - 140.0)
	var view_y := float(w.H) * 0.54
	var bank_y := float(w.H) * 0.64
	var views := [
		{name = "river_bend", y = maxf(24.0, bend_y - 34.0), sd = 26.0, lift = 34.0, look_dy = 115.0, look_sd = -8.0, look_lift = -2.0},
		{name = "gully_couloir", y = wall_y, sd = 22.0, lift = 38.0, look_dy = 35.0, look_sd = -85.0, look_lift = -10.0},
		{name = "valley_golets", y = view_y, sd = 52.0, lift = 68.0, look_dy = 220.0, look_sd = -55.0, look_lift = -5.0},
		{name = "river_bank", y = bank_y, sd = axis.river_hw_at(int(bank_y)) + 2.5, lift = 4.5, look_dy = 95.0, look_sd = 0.0, look_lift = -0.5},
	]
	for v: Dictionary in views:
		var c_cos := maxf(axis.axis_cos_at(roundi(v.y)), 0.25)
		var cx_cell := clampf(axis.axis_x_at(v.y) + (float(v.sd) / c_cos) * float(axis.road_side), 12.0, float(w.W - 12))
		var cx := (cx_cell + 0.5) * T
		var cz := (float(v.y) + 0.5) * T
		var cy := h.ground_at(cx, cz) + float(v.lift)
		var ly := minf(float(w.H - 4), float(v.y) + float(v.look_dy))
		var l_cos := maxf(axis.axis_cos_at(roundi(ly)), 0.25)
		var lx_cell := clampf(axis.axis_x_at(ly) + (float(v.look_sd) / l_cos) * float(axis.road_side), 12.0, float(w.W - 12))
		var lx := (lx_cell + 0.5) * T
		var lz := (ly + 0.5) * T
		var lgy := maxf(h.ground_at(lx, lz), axis.floor_h_at(int(ly)) * GameConfig.HS) + float(v.look_lift)
		var pos := Vector3(cx, cy, cz)
		var target := Vector3(lx, lgy, lz)
		gw.player.x = pos.x
		gw.player.z = pos.z
		gw.player.feet = h.ground_at(pos.x, pos.z)
		gw.stream_coordinator.force_terrain(pos, GameWorld.NEAR)
		if gw.outer != null:
			gw.outer.preload_around(pos.x, pos.z, OuterTerrain.RADIUS)
		gw.stream_coordinator.force_vegetation(pos)
		gw.camera.look_at_from_position(pos, target, Vector3.UP)
		for _f in 18:
			await process_frame
		var img := root.get_viewport().get_texture().get_image()
		var out_path := ProjectSettings.globalize_path(OUT.path_join("expedition_%s%s.png" % [v.name, tag]))
		img.save_png(out_path)
		print("SHOT: ", out_path)

	main._free_game()
	main.queue_free()
	await process_frame
	return true


func _verify_phase3_roads(seeds: PackedStringArray, tag: String, short_dev: bool, explicit_h: int) -> bool:
	var failures: Array[String] = []
	var maps: Array[Image] = []
	var rows := []
	for seed_text: String in seeds:
		var t0 := Time.get_ticks_usec()
		var w := WorldGenerator._generate_plan(seed_text, WorldGenerator.PLAN_SIZE, Callable(), Callable(),
			null, 0, Callable(), WorldGenerator.PlanMode.WORLD, Callable(),
			WorldTemplate.EXPEDITION_ID, short_dev, explicit_h)
		if w != null:
			w.territory_center = WorldGenerator.start_center(w)
			w.expand_territory(maxi(w.W, w.H))
		var total_ms := (Time.get_ticks_usec() - t0) / 1000.0
		if w == null:
			failures.append("%s: WorldGenerator.generate returned null" % seed_text)
			continue
		var axis := ValleyAxis.for_world(w)
		var surf := Heightfield.new(w, true)
		var val_err := RoadRecords.validation_error(w.trails, "expedition(%s)" % seed_text, RoadRecords.Phase.SURFACED)
		if not val_err.is_empty():
			failures.append("%s: validation_error=%s" % [seed_text, val_err])
		if w.settlements.size() != 2:
			failures.append("%s: expected 2 settlements, got %d" % [seed_text, w.settlements.size()])
		if not w.bridges.is_empty() or not w.tunnels.is_empty():
			failures.append("%s: expected 0 bridges/tunnels, got %d/%d" % [seed_text, w.bridges.size(), w.tunnels.size()])
		var route_kind := WorldTemplate.expedition_route_kind(w.template_id)
		var roads: Array = w.trails.filter(func(t: Dictionary) -> bool: return t.kind == route_kind)
		if roads.size() != 1 or w.trails.size() != 1:
			failures.append("%s: expected single %s trail, got matches=%d total=%d" % [seed_text, route_kind, roads.size(), w.trails.size()])
			w.clear_noise_fields()
			w.base_heights = null
			continue
		var pts: Array = roads[0].pts
		var T := GameConfig.TILE
		var len_m := 0.0
		var near_river_m := 0.0
		var deep_forest_m := 0.0
		var climb_m := 0.0
		var descent_m := 0.0
		var max_grade := 0.0
		var wet_hits := 0
		var bend_m := 0.0
		var straight_run := 0.0
		var max_straight := 0.0
		var prev_p := Vector2(pts[0].x, pts[0].y) * T
		var prev_h := surf.ground_at(prev_p.x, prev_p.y)
		var prev_dir := Vector2.ZERO
		for k in range(1, pts.size()):
			var p := Vector2(pts[k].x, pts[k].y) * T
			var seg := p.distance_to(prev_p)
			if seg < 0.05:
				continue
			var cur_h := surf.ground_at(p.x, p.y)
			var dh := cur_h - prev_h
			if dh > 0.0: climb_m += dh
			else: descent_m += -dh
			max_grade = maxf(max_grade, absf(dh) / seg)
			len_m += seg
			var mx := 0.5 * (prev_p.x + p.x)
			var mz := 0.5 * (prev_p.y + p.y)
			var cy := clampf(mz / T - 0.5, 0.0, float(w.H - 1))
			var cx := mx / T - 0.5
			var sd := (cx - axis.axis_x_at(cy)) * axis.axis_cos_at(roundi(cy)) * float(axis.road_side)
			var rhw := axis.river_hw_at(roundi(cy))
			if sd <= rhw + 14.0: near_river_m += seg
			if sd >= 26.0: deep_forest_m += seg
			if surf.depth_at(mx, mz) > 0.08:
				wet_hits += 1
			var dir := (p - prev_p) / seg
			if prev_dir != Vector2.ZERO:
				var ang := absf(prev_dir.angle_to(dir))
				if ang / maxf(seg, 1.0) > 0.0045:
					bend_m += seg
					max_straight = maxf(max_straight, straight_run)
					straight_run = 0.0
				else:
					straight_run += seg
			prev_dir = dir
			prev_p = p
			prev_h = cur_h
		max_straight = maxf(max_straight, straight_run)
		if wet_hits > 0:
			failures.append("%s: road touches river water (%d samples)" % [seed_text, wet_hits])
		if descent_m <= climb_m:
			failures.append("%s: descent (%.1fm) <= climb (%.1fm)" % [seed_text, descent_m, climb_m])
		# Проверка OpeningRoute: старт у лагеря верховья лицом вниз (+y)
		var rng := RandomNumberGenerator.new()
		rng.seed = 42
		var op := OpeningRoute.choose(w, surf, rng)
		if op.is_empty():
			failures.append("%s: OpeningRoute returned empty" % seed_text)
		else:
			var s0: SettlementData = w.settlements[0]
			var s1: SettlementData = w.settlements[1]
			var pos2 := Vector2(op.position.x, op.position.z)
			var d0 := pos2.distance_to(Vector2(s0.x, s0.y) * T)
			var d1 := pos2.distance_to(Vector2(s1.x, s1.y) * T)
			if d0 > 120.0 or d0 >= d1:
				failures.append("%s: OpeningRoute spawned wrong place d_start=%.1fm d_finish=%.1fm" % [seed_text, d0, d1])
			var op_pts: Array = op.points
			if op_pts.size() < 2 or op_pts[1].y <= op_pts[0].y:
				failures.append("%s: OpeningRoute not facing downstream" % seed_text)
		# Проверка мест (рыбацкий домик с причалом на реке)
		var site_counts := {}
		var pier_ok := false
		for site: SiteData in w.sites:
			site_counts[site.type] = int(site_counts.get(site.type, 0)) + 1
			if site.type == "fishing" and not site.huts.is_empty():
				var h0: HutData = site.huts[0]
				var origin := Vector3(h0.x * T, surf.ground_at(h0.x * T, h0.y * T), h0.y * T)
				var m := FishingLayout.measure(surf, origin, h0.a)
				var tip := origin + Basis(Vector3.UP, h0.a) * Vector3(0.0, 0.0, FishingLayout.START + m.len)
				if surf.depth_at(tip.x, tip.z) > 0.3:
					pier_ok = true
		if not pier_ok:
			failures.append("%s: missing valid river pier fishing site (sites=%s)" % [seed_text, str(site_counts)])
		var surf_keys := ["none", "gravel", "dirt", "packed", "stone", "sand", "forest", "meadow"]
		var surf_counts := {}
		var route_surf: PackedByteArray = roads[0].get("surf", PackedByteArray())
		for sv: int in route_surf:
			var sname: String = surf_keys[sv] if sv >= 0 and sv < surf_keys.size() else str(sv)
			surf_counts[sname] = int(surf_counts.get(sname, 0)) + 1
		var surf_pct := {}
		for sname: String in surf_counts:
			surf_pct[sname] = snappedf(100.0 * float(surf_counts[sname]) / maxf(1.0, float(route_surf.size())), 0.1)
		if route_kind == "trail" and int(surf_counts.get("forest", 0)) <= 0:
			failures.append("%s: expected RoadSurface.FOREST points on %s route, got surfaces=%s" % [seed_text, route_kind, str(surf_counts)])
		var forest_img := preload("res://scripts/render/forest_floor.gd").surface_image(w)
		var placement := preload("res://scripts/render/vegetation_placement.gd").new(w, surf)
		var centre := Vector2(w.W, w.H) * T * 0.5
		placement.prepare(centre.x, centre.y, maxf(centre.x, centre.y))
		var obstacles := preload("res://scripts/game/road_obstacles.gd").new(w)
		obstacles.sync_regions({}, placement)
		var obs := obstacles.measure_candidates(surf, forest_img, 0)
		var gaps_count: int = surf.road_refinement.gaps.size() if surf.road_refinement != null else 0
		if route_kind == "trail":
			if int(obs.get("occupied", 0)) <= 0:
				failures.append("%s: expected RoadObstacles occupied > 0 on %s (obs=%s)" % [seed_text, route_kind, str(obs)])
			if int(obs.get("parts", {}).get("root", 0)) <= 0:
				failures.append("%s: expected RoadObstacles root parts > 0 on %s (obs=%s)" % [seed_text, route_kind, str(obs)])
		var stages: Dictionary = w.generation_profile.get("stages_ms", {})
		var row := {
			seed = seed_text, size = "%dx%d" % [w.W, w.H], total_ms = snappedf(total_ms, 1.0),
			trails_ms = snappedf(float(stages.get("trails", 0.0)), 1.0),
			len_km = snappedf(len_m / 1000.0, 0.02),
			near_river_pct = snappedf(100.0 * near_river_m / maxf(1.0, len_m), 0.1),
			deep_forest_pct = snappedf(100.0 * deep_forest_m / maxf(1.0, len_m), 0.1),
			climb_m = snappedf(climb_m, 1.0), descent_m = snappedf(descent_m, 1.0),
			max_grade_pct = snappedf(max_grade * 100.0, 0.1),
			bend_pct = snappedf(100.0 * bend_m / maxf(1.0, len_m), 0.1),
			max_straight_m = snappedf(max_straight, 1.0),
			anchors = "%d/%d" % [int(w.generation_profile.get("expedition_anchors_used", 0)), int(w.generation_profile.get("expedition_anchors_total", 0))],
			sites = site_counts,
			homes = [w.settlements[0].huts.size(), w.settlements[1].huts.size()],
			surfaces = surf_pct,
			obstacles_occupied = int(obs.get("occupied", 0)),
			obstacles_parts = obs.get("parts", {}),
			gaps = gaps_count,
		}
		rows.append(row)
		print("PHASE3_ROAD %-11s %s  %.2fkm  river=%.1f%% forest=%.1f%%  +%3.0fm/-%3.0fm  maxG=%.1f%%  bend=%.1f%% maxStr=%.0fm  anc=%s  trails=%.0fms total=%.0fms  sites=%s" % [
			row.seed, row.size, row.len_km, row.near_river_pct, row.deep_forest_pct,
			row.climb_m, row.descent_m, row.max_grade_pct, row.bend_pct, row.max_straight_m,
			row.anchors, row.trails_ms, row.total_ms, str(row.sites)])
		print("  PHASE5_OBS %-11s kind=%s gaps=%d occupied=%d parts=%s surf=%s" % [
			seed_text, route_kind, gaps_count, int(obs.get("occupied", 0)), str(obs.get("parts", {})), str(surf_pct)])
		maps.append(_render_road_strip(w, surf))
		w.clear_noise_fields()
		w.base_heights = null
	if not maps.is_empty():
		var sheet := _sheet(maps)
		var png_path := ProjectSettings.globalize_path(OUT.path_join("expedition_roads%s.png" % tag))
		sheet.save_png(png_path)
		var json_path := ProjectSettings.globalize_path(OUT.path_join("expedition_roads%s.json" % tag))
		var f := FileAccess.open(json_path, FileAccess.WRITE)
		f.store_string(JSON.stringify({short = short_dev, rows = rows}, "\t"))
		f.close()
		print("Expedition roads sheet: ", png_path)
	if failures.is_empty():
		print("PHASE3_VERIFY: PASS")
		return true
	for msg: String in failures:
		push_error("PHASE3_VERIFY FAIL: " + msg)
	return false


func _render_road_strip(w: WorldData, surf: Heightfield) -> Image:
	var img := _render_strip_with_profile(w)
	var step := 2 if w.H > 1536 else 1
	var iw := ceili(float(w.W) / step)
	var ih := ceili(float(w.H) / step)
	var prof_w := 96
	# Рисуем дорогу на карте-полосе (тёплая охра) и профиль высоты дороги справа (оранжевый).
	var road_col := Color(0.95, 0.78, 0.34)
	var road_edge := Color(0.28, 0.19, 0.08)
	var road_y_h := {}
	var route_kind := WorldTemplate.expedition_route_kind(w.template_id)
	for t: Dictionary in w.trails:
		if t.kind != route_kind: continue
		for p: Dictionary in t.pts:
			var px := clampi(roundi(float(p.x) / step), 1, iw - 2)
			var py := clampi(roundi(float(p.y) / step), 1, ih - 2)
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					if absi(dx) + absi(dy) <= 1:
						img.set_pixel(px + dx, py + dy, road_col if dx == 0 and dy == 0 else road_edge)
			var hm := surf.ground_at(float(p.x) * GameConfig.TILE, float(p.y) * GameConfig.TILE)
			road_y_h[py] = hm
	for py_key: int in road_y_h:
		var rx := clampi(roundi(float(road_y_h[py_key]) / 220.0 * float(prof_w - 4)), 0, prof_w - 1)
		img.set_pixel(iw + 6 + rx, py_key, Color(0.98, 0.62, 0.16))
		if rx + 1 < prof_w:
			img.set_pixel(iw + 6 + rx + 1, py_key, Color(0.98, 0.62, 0.16))
	# Маркеры старта (зелёный), финиша (красный) и редких мест (белый/голубой).
	var draw_dot := func(cx: float, cy: float, r: int, col: Color) -> void:
		var px := clampi(roundi(cx / step), r, iw - 1 - r)
		var py := clampi(roundi(cy / step), r, ih - 1 - r)
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if dx * dx + dy * dy <= r * r:
					img.set_pixel(px + dx, py + dy, col)
	if w.settlements.size() >= 1:
		draw_dot.call(w.settlements[0].x, w.settlements[0].y, 4, Color(0.25, 0.96, 0.40))
	if w.settlements.size() >= 2:
		draw_dot.call(w.settlements[1].x, w.settlements[1].y, 4, Color(0.98, 0.30, 0.25))
	for s: SiteData in w.sites:
		var col := Color(0.20, 0.92, 0.98) if s.type == "fishing" else Color(1.0, 0.96, 0.55)
		draw_dot.call(s.x, s.y, 3, col)
	return img


func _capture_phase3_shots(seed_text: String, tag: String, phase8 := false, drive_only := false, maple := false) -> bool:
	if DisplayServer.get_name() == "headless":
		push_error("PHASE3_SHOTS: window required (do not pass --headless)")
		return false
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(Vector2i(1280, 720))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	for _i in 20:
		await process_frame
	GameContext.scope.cache.enabled = phase8
	if phase8:
		StageVegetation.verify = true
		StageVegetation.verify_report.clear()
	main.start_game(seed_text, WorldGenerator.START_SIZE, "", false, WorldTemplate.EXPEDITION_ID)
	var wait_frames := 0
	while main.busy and wait_frames < 12000:
		await process_frame
		wait_frames += 1
	if main.busy or main.game == null or main.game.player == null:
		push_error("PHASE3_SHOTS: GameWorld failed to start")
		main.queue_free()
		return false
	var gw: GameWorld = main.game
	gw.paused = true
	main.hud.visible = false
	if gw.pause_requested.is_connected(main._toggle_pause):
		gw.pause_requested.disconnect(main._toggle_pause)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if gw.opening_active():
		gw._finish_opening()
	gw.hour = 10.5
	if gw.day != null:
		gw.day.apply(10.5, 100.0)
	gw.camera.fov = 70.0
	gw.camera.current = true

	var w: WorldData = gw.world
	var h: Heightfield = gw.heights
	var axis := ValleyAxis.for_world(w)
	var T := GameConfig.TILE
	var road_pts: Array = w.trails[0].pts if not w.trails.is_empty() else []
	if phase8:
		StageVegetation.verify = false
		var counts := {}
		for kind: int in w.obj_k:
			counts[kind] = counts.get(kind, 0) + 1
		print("PHASE8 OBJECTS ", counts)
		print("PHASE8 PARITY ", StageVegetation.verify_report)
		var report_ok: bool = StageVegetation.verify_report.is_empty() or StageVegetation.verify_report[0].same
		var captured: bool
		if maple:
			captured = await _maple_capture(gw, road_pts, tag)
		else:
			captured = await _phase8_capture(gw, road_pts, tag, drive_only)
		GameContext.scope.cache.wait_writes()
		main._free_game()
		main.queue_free()
		await process_frame
		return report_ok and captured
	var shots: Array[Dictionary] = []

	# 1. Старт в лагере верховья — взгляд прямо вниз по дороге
	if road_pts.size() > 16:
		var p0 := Vector2(road_pts[4].x, road_pts[4].y) * T
		var p1 := Vector2(road_pts[mini(24, road_pts.size() - 1)].x, road_pts[mini(24, road_pts.size() - 1)].y) * T
		shots.append({name = "p3_start", pos = Vector3(p0.x, h.ground_at(p0.x, p0.y) + 4.5, p0.y),
			target = Vector3(p1.x, h.ground_at(p1.x, p1.y) + 1.5, p1.y)})

	# 2. Участок дороги у самой воды + 3. Участок дороги в лесной глубине на отроге
	var best_river_k := -1
	var best_river_sd := INF
	var best_forest_k := -1
	var best_forest_sd := -INF
	for k in range(30, maxi(31, road_pts.size() - 40)):
		var pt: Dictionary = road_pts[k]
		var sd := (float(pt.x) - axis.axis_x_at(float(pt.y))) * float(axis.road_side)
		if sd < best_river_sd:
			best_river_sd = sd
			best_river_k = k
		if sd > best_forest_sd:
			best_forest_sd = sd
			best_forest_k = k
	if best_river_k >= 0:
		var k1 := mini(road_pts.size() - 1, best_river_k + 22)
		var p0 := Vector2(road_pts[best_river_k].x, road_pts[best_river_k].y) * T
		var p1 := Vector2(road_pts[k1].x, road_pts[k1].y) * T
		shots.append({name = "p3_waterfront", pos = Vector3(p0.x, h.ground_at(p0.x, p0.y) + 3.6, p0.y),
			target = Vector3(p1.x, h.ground_at(p1.x, p1.y) + 1.2, p1.y)})
	if best_forest_k >= 0:
		var k1 := mini(road_pts.size() - 1, best_forest_k + 22)
		var p0 := Vector2(road_pts[best_forest_k].x, road_pts[best_forest_k].y) * T
		var p1 := Vector2(road_pts[k1].x, road_pts[k1].y) * T
		shots.append({name = "p3_forest_spur", pos = Vector3(p0.x, h.ground_at(p0.x, p0.y) + 3.8, p0.y),
			target = Vector3(p1.x, h.ground_at(p1.x, p1.y) + 1.4, p1.y)})

	# 4. Финишная база и рыбацкий причал у широкой реки
	var fish_site: SiteData = null
	for s: SiteData in w.sites:
		if s.type == "fishing":
			fish_site = s
			break
	if fish_site != null:
		var fp := Vector2(fish_site.x, fish_site.y) * T
		var cam_p := fp + Vector2(float(axis.road_side) * 26.0, -30.0)
		var look_p := Vector2((axis.axis_x_at(fish_site.y) + 0.5) * T, fp.y + 8.0)
		shots.append({name = "p3_finish_pier", pos = Vector3(cam_p.x, h.ground_at(cam_p.x, cam_p.y) + 9.0, cam_p.y),
			target = Vector3(look_p.x, h.ground_at(fp.x, fp.y) + 0.5, look_p.y)})

	for sh: Dictionary in shots:
		var pos: Vector3 = sh.pos
		var target: Vector3 = sh.target
		await _load_shot_view(gw, pos, 0.7)
		gw.camera.look_at_from_position(pos, target, Vector3.UP)
		for _f in 18:
			await process_frame
		var img := root.get_viewport().get_texture().get_image()
		var out_path := ProjectSettings.globalize_path(OUT.path_join("expedition_%s%s.png" % [sh.name, tag]))
		img.save_png(out_path)
		print("SHOT: ", out_path)

	main._free_game()
	main.queue_free()
	await process_frame
	return true


func _load_shot_view(gw: GameWorld, pos: Vector3, outer_scale := 0.6) -> int:
	gw.player.x = pos.x
	gw.player.z = pos.z
	gw.player.feet = gw.heights.ground_at(pos.x, pos.z)
	gw.stream_coordinator.force_terrain(pos, GameWorld.NEAR)
	if gw.outer != null:
		gw.outer.preload_around(pos.x, pos.z, OuterTerrain.RADIUS * outer_scale)
	gw.stream_coordinator.force_vegetation(pos)
	if gw.terrain_stream == null:
		return 0
	gw.terrain_stream._lod_at = Vector2.INF
	gw.terrain_stream._far_at = Vector2.INF
	var p2 := Vector2(pos.x, pos.z)
	var ck := Vector2i(floori(pos.x / PlanTerrain.SIDE), floori(pos.z / PlanTerrain.SIDE))
	var lod0_r := PlanTerrain.LOD1_DIST - PlanTerrain.LOD_HYSTERESIS
	var wait := 0
	while wait < 400:
		if gw.chunk_source != null:
			gw.chunk_source.poll()
		gw.terrain_stream.update(pos.x, pos.z, false, true, INF)
		var ready: bool = gw.terrain_stream.nodes.has(ck) and gw.terrain_stream._node_lod.get(ck, -1) == 0 and gw.terrain_stream.nodes[ck].material_override == gw.terrain_stream.material
		if ready:
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					var nk := ck + Vector2i(dx, dy)
					if gw.terrain_stream.chunks.has(nk) and gw.terrain_stream.distance_to_chunk(nk, p2) < lod0_r:
						if not gw.terrain_stream.nodes.has(nk) or gw.terrain_stream._node_lod.get(nk, -1) != 0:
							ready = false
							break
				if not ready:
					break
		if ready:
			break
		await process_frame
		wait += 1
	return gw.terrain_stream._node_lod.get(ck, -1)


func _maple_capture(gw: GameWorld, road: Array, tag: String) -> bool:
	var w := gw.world
	var maples: Array[int] = []
	var ages := [0, 0, 0]
	var max_elev := 0.0
	var min_water := INF
	for o in w.obj_count:
		if w.obj_k[o] != Biomes.T_MAPLE:
			continue
		maples.append(o)
		ages[w.obj_v[o] / 3] += 1
		var cell := floori(w.obj_y[o]) * w.W + floori(w.obj_x[o])
		max_elev = maxf(max_elev, w.elev[cell])
		min_water = minf(min_water, w.dist_water[cell])
	print("MAPLE SITES count=", maples.size(), " ages=", ages, " max_elev=", max_elev, " min_water_cells=", min_water)
	if maples.is_empty() or road.size() < 16:
		push_error("MAPLE: the seed needs maples and a generated road")
		return false
	var tile := GameConfig.TILE
	var road_line := PackedVector2Array()
	for p: Dictionary in road:
		road_line.append(Vector2(p.x, p.y) * tile)
	var scores := {road = -INF, grove = -INF, old = -INF}
	var sites := {}
	var near_road := 0
	for o: int in maples:
		var at := Vector2(w.obj_x[o], w.obj_y[o]) * tile
		var road_index := 0
		var distance := INF
		for k in range(4, road_line.size() - 4):
			var d := at.distance_squared_to(road_line[k])
			if d < distance:
				distance = d
				road_index = k
		distance = sqrt(distance)
		var cluster := 0.0
		for neighbor: int in maples:
			var delta := (Vector2(w.obj_x[neighbor], w.obj_y[neighbor]) * tile).distance_to(at)
			if delta > 0.0 and delta < 28.0:
				cluster += 1.0 - delta / 32.0
		var size := float(w.obj_s[o])
		var age: int = w.obj_v[o] / 3
		if distance < 12.0 and age != ForestModels.YOUNG_AGE:
			near_road += 1
		var candidates := {
			road = size * 2.2 - absf(distance - 6.5) * 0.57,
			grove = cluster + size * 0.3 - maxf(0.0, distance - 32.0) * 0.015,
		}
		if age == ForestModels.OLD_AGE:
			candidates.old = size - distance * 0.006
		for name: String in candidates:
			if candidates[name] > scores[name]:
				sites[name] = [o, at, road_index, distance]
				scores[name] = candidates[name]
	print("MAPLE ROAD mature_within_12m=", near_road, " selected=", sites)
	var ok := true
	for name: String in sites:
		var site: Array = sites[name]
		var o: int = site[0]
		var at: Vector2 = site[1]
		var k: int = site[2]
		var p := road_line[k]
		var dir := (at - p).normalized()
		var road_dir := (road_line[k + 3] - road_line[k - 3]).normalized()
		if name == "road":
			var eye := p - road_dir * 8.0
			ok = await _maple_shot(gw, "road", tag, eye, 1.65, at + road_dir * 6.0, 4.5, 69.0, true) and ok
			ok = await _maple_shot(gw, "adult", tag, p - road_dir * 21.0, 3.0, at, 10.0, 58.0, false) and ok
			ok = await _maple_shot(gw, "middle", tag, p - dir * 67.0, 22.0, at, 11.0, 43.0, true) and ok
			ok = await _maple_shot(gw, "distant", tag, p - dir * 350.0, 132.0, at, 15.0, 25.0, true) and ok
		elif name == "old":
			ok = await _maple_shot(gw, "old", tag, at - dir * 6.5, 1.8, at, 3.5, 67.0, true) and ok
		else:
			ok = await _maple_shot(gw, "grove", tag, at - dir * 23.0 + road_dir * 7.0, 4.0, at, 7.0, 73.0, true) and ok
		print("MAPLE CAMERA ", name, " age=", w.obj_v[o] / 3, " scale=", w.obj_s[o], " road_m=", site[3])
	return ok


func _maple_shot(gw: GameWorld, name: String, tag: String, pos: Vector2, height: float, focus: Vector2,
		focus_height: float, fov: float, stream: bool) -> bool:
	var h := gw.heights
	var eye := Vector3(pos.x, h.ground_at(pos.x, pos.y) + height, pos.y)
	var target := Vector3(focus.x, h.ground_at(focus.x, focus.y) + focus_height, focus.y)
	if stream:
		gw.player.x = pos.x
		gw.player.z = pos.y
		gw.player.feet = h.ground_at(pos.x, pos.y)
		gw.stream_coordinator.force_terrain(eye, GameWorld.NEAR)
		gw.stream_coordinator.force_vegetation(eye)
	gw.camera.fov = fov
	gw.camera.look_at_from_position(eye, target, Vector3.UP)
	for _f in 12:
		await process_frame
	await RenderingServer.frame_post_draw
	var out := OUT.path_join("expedition_maple_%s%s.jpg" % [name, tag])
	var saved := root.get_texture().get_image().save_jpg(ProjectSettings.globalize_path(out), 0.92) == OK
	print("MAPLE SHOT ", out, " eye=", eye, " target=", target)
	return saved


func _phase8_capture(gw: GameWorld, road: Array, tag: String, drive_only: bool) -> bool:
	if road.size() < 60:
		push_error("PHASE8: требуется сформированная дорога")
		return false
	var w := gw.world
	var h := gw.heights
	var axis := ValleyAxis.for_world(w)
	var tile := GameConfig.TILE
	var sites := {}
	var scores := {}
	# Ракурсы выбираются по географии и дороге, одинаково для старой и новой растительности.
	for k in range(24, road.size() - 24, 3):
		var p: Dictionary = road[k]
		var at := clampi(floori(p.y), 0, w.H - 1) * w.W + clampi(floori(p.x), 0, w.W - 1)
		var cross := absf(p.x - axis.axis_x_at(p.y)) - axis.river_hw_at(p.y)
		var forest := 0.0
		for row in range(-3, 4, 3):
			for col in range(-3, 4, 3):
				var sample := clampi(floori(p.y) + row, 0, w.H - 1) * w.W + clampi(floori(p.x) + col, 0, w.W - 1)
				forest += float(w.biome[sample] in [Biomes.FOREST, Biomes.TAIGA])
		forest /= 9.0
		var candidates := {
			bank = -cross - w.slope[at] * 7.0,
			wet_forest = forest * (0.30 + 0.70 * w.moist[at]) + minf(cross, 18.0) * 0.01,
			old_forest = forest * (0.80 + 0.50 * StageVegetation.age_at(w, p.x, p.y)) + w.elev[at] * 0.35,
			transition = 1.0 - absf(forest - 0.55) + w.slope[at] * 0.2 + minf(cross, 45.0) * 0.006,
			slope = w.elev[at] * 2.5 + w.slope[at] * 0.35 + forest * 0.15,
		}
		for name: String in candidates:
			if candidates[name] > scores.get(name, -INF):
				sites[name] = k
				scores[name] = candidates[name]
	if drive_only:
		return await _phase8_drive(gw, road, sites.wet_forest)
	var ok := true
	for name: String in sites:
		var k: int = sites[name]
		var p := Vector2(road[k].x, road[k].y) * tile
		var forward := (Vector2(road[k + 6].x, road[k + 6].y) * tile - p).normalized()
		var direction := forward
		var cam_height := 1.65
		if name == "bank" or name == "slope":
			var river := Vector2(axis.axis_x_at(p.y / tile) * tile, p.y)
			direction = forward.lerp((river - p).normalized(), 0.67 if name == "bank" else 0.48).normalized()
		if name == "slope":
			cam_height = 8.0
		var eye := Vector3(p.x, h.ground_at(p.x, p.y) + cam_height, p.y)
		var look := p + direction * 24.0
		look = look.clamp(Vector2.ONE, Vector2(w.W - 1, w.H - 1) * tile)
		var target := Vector3(look.x, h.ground_at(look.x, look.y) + 1.15, look.y)
		gw.player.x = p.x
		gw.player.z = p.y
		gw.player.feet = h.ground_at(p.x, p.y)
		gw.stream_coordinator.force_terrain(eye, GameWorld.NEAR)
		gw.stream_coordinator.force_vegetation(eye)
		gw.camera.look_at_from_position(eye, target, Vector3.UP)
		for _f in 15:
			await process_frame
		await RenderingServer.frame_post_draw
		var out := OUT.path_join("expedition_phase8_%s%s.jpg" % [name, tag])
		ok = root.get_texture().get_image().save_jpg(ProjectSettings.globalize_path(out), 0.91) == OK and ok
		print("PHASE8 SHOT ", out, " k=", k, " at=", p)
	return ok


func _phase8_drive(gw: GameWorld, road: Array, start: int) -> bool:
	var tile := GameConfig.TILE
	var path := Curve2D.new()
	for k in range(start, mini(start + 150, road.size())):
		path.add_point(Vector2(road[k].x, road[k].y) * tile)
	var length := minf(path.get_baked_length() - 3.0, 210.0)
	if length < 60.0:
		return false
	var p := path.sample_baked(0.0)
	var eye := Vector3(p.x, gw.heights.ground_at(p.x, p.y) + 1.65, p.y)
	gw.stream_coordinator.force_terrain(eye, GameWorld.NEAR)
	gw.stream_coordinator.force_vegetation(eye)
	var intervals := PackedFloat64Array()
	var calls := 0.0
	var primitives := 0.0
	var lag := 0.0
	var start_us := Time.get_ticks_usec()
	var began := start_us
	var distance := 0.0
	while distance < length:
		p = path.sample_baked(distance)
		var next := path.sample_baked(distance + 3.0)
		var dir := (next - p).normalized()
		eye = Vector3(p.x, gw.heights.ground_at(p.x, p.y) + 1.65, p.y)
		gw.player.x = p.x
		gw.player.z = p.y
		gw.player.feet = eye.y - 1.65
		gw.camera.look_at_from_position(eye, eye + Vector3(dir.x, -0.04, dir.y), Vector3.UP)
		gw.stream_coordinator.update(eye)
		await process_frame
		var now := Time.get_ticks_usec()
		if distance >= 15.0:
			intervals.append((now - began) / 1000.0)
			calls += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
			primitives += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
			lag = maxf(lag, gw.vegetation.coverage_lag(p))
		began = now
		distance = (now - start_us) * 0.000014 # 14 м/с
	intervals.sort()
	if intervals.is_empty():
		return false
	var n := intervals.size()
	print("PHASE8 DRIVE ", {frames = n, p50_ms = intervals[n / 2], p95_ms = intervals[ceili(n * 0.95) - 1],
		p99_ms = intervals[ceili(n * 0.99) - 1], max_ms = intervals[-1], max_coverage_lag_m = lag,
		draw_calls = calls / n, primitives = primitives / n, memory_mib = OS.get_static_memory_usage() / 1048576.0,
		stream_groups_max_us = gw.stream_coordinator.stats.group_max_us})
	return true


func _verify_phase4(seed_text: String, tag: String) -> bool:
	if DisplayServer.get_name() == "headless":
		push_error("PHASE4_VERIFY: window required (do not pass --headless)")
		return false
	var failures: Array[String] = []
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(Vector2i(1280, 720))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var tmp := ProjectSettings.globalize_path("res://.godot/expedition_phase4_test")
	DirAccess.make_dir_recursive_absolute(tmp)
	var old_save_dir := Saves.dir
	var old_cache_enabled := GameContext.scope.cache.enabled
	var old_cache_dir := GameContext.scope.cache.dir
	var old_settings_path: String = GameContext.scope.settings.settings_path
	Saves.dir = tmp.path_join("saves_t1")
	GameContext.scope.cache.enabled = true
	GameContext.scope.cache.dir = tmp.path_join("cache_t1")
	GameContext.scope.settings.settings_path = tmp.path_join("settings.cfg")

	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	main._progress_enabled = true
	for _i in 24:
		await process_frame
	# 1. Переключение в меню на Тип 2 «Речная экспедиция»
	var carousel: Node = main.get_node("%Carousel")
	carousel.select_type(WorldTemplate.EXPEDITION_ID)
	main._on_type_changed()
	GameContext.scope.cache.enabled = true
	GameContext.scope.cache.dir = tmp.path_join("cache_t2")
	for _i in 12:
		await process_frame
	if carousel.selected_type_id() != WorldTemplate.EXPEDITION_ID:
		failures.append("carousel failed to select river_expedition")

	# 2. Запуск Типа 2 (холодная загрузка), проверка карты M, FPS, систем доски заданий / альбома и сохранения
	GameContext.scope.settings.remember_seed(seed_text)
	main._selected_seed = seed_text
	var t_cold := Time.get_ticks_msec()
	main.start_game(seed_text, WorldGenerator.START_SIZE, "", false, WorldTemplate.EXPEDITION_ID)
	var wait_frames := 0
	while (main.busy or main.game == null or main.game.player == null) and wait_frames < 12000:
		await process_frame
		wait_frames += 1
	var cold_ms := Time.get_ticks_msec() - t_cold
	if main.game == null or main.game.player == null:
		failures.append("GameWorld failed to start")
	else:
		var gw: GameWorld = main.game
		if gw.opening_active():
			gw._finish_opening()
		for _i in 20:
			await process_frame
		# Замер живых 60 кадров на дороге в 3D
		var frame_ms: Array[float] = []
		var prev_us := Time.get_ticks_usec()
		for _f in 60:
			await process_frame
			var now_us := Time.get_ticks_usec()
			frame_ms.append((now_us - prev_us) / 1000.0)
			prev_us = now_us
		frame_ms.sort()
		var med_ms := frame_ms[frame_ms.size() / 2]
		var p95_ms := frame_ms[mini(frame_ms.size() - 1, int(frame_ms.size() * 0.95))]
		print("PHASE4_PERF seed=%s size=%dx%d cold_ms=%d fps_med=%.1f p95_ms=%.1f" % [
			seed_text, gw.world.W, gw.world.H, cold_ms, 1000.0 / maxf(0.1, med_ms), p95_ms])
		# Доска заданий, маяки, краска, обелиски, far_destination, альбом — без падений
		for s: SettlementData in gw.world.settlements:
			var offers: Array = gw.interaction_service.offers_all(s)
			var far := gw.world.far_destination(WorldData.place_id("settlement", s.x, s.y))
			print("PHASE4_SETTLEMENT %s offers=%d far=%s" % [s.name, offers.size(), str(far.get("name", ""))])
		var jdata: Dictionary = main.hud.journey_data()
		if jdata.is_empty():
			failures.append("hud.journey_data() returned empty")
		# Открываем большую карту M и проверяем стартовый масштаб вокруг игрока
		main.hud.set_map_visible(true)
		for _i in 24:
			await process_frame
		var bm: Control = main.hud.big_map
		var fit_s: float = bm._min_scale
		var cur_s: float = bm._scale
		print("PHASE4_MAP scale=%.4f min_scale=%.4f center=%s player=%s" % [cur_s, fit_s, str(bm._center), str(bm.player)])
		if cur_s < fit_s * 1.15:
			failures.append("big_map did not zoom in around player for elongated world (scale=%.4f min=%.4f)" % [cur_s, fit_s])
		var map_img := root.get_viewport().get_texture().get_image()
		var map_path := ProjectSettings.globalize_path(OUT.path_join("expedition_p4_map%s.png" % tag))
		map_img.save_png(map_path)
		print("SHOT: ", map_path)
		main.hud.set_map_visible(false)
		for _i in 6:
			await process_frame
		# Сохранение и проверка, что сейв лёг именно в папку Типа 2 (а не Типа 1)
		if not main._save_current("manual"):
			failures.append("manual save failed for Type 2")
		var t2_read := Saves.read_slot(seed_text, "manual", WorldTemplate.EXPEDITION_ID)
		var t1_read := Saves.read_slot(seed_text, "manual", WorldTemplate.DEFAULT_ID)
		if t2_read.data.is_empty():
			failures.append("Type 2 save unreadable: %s" % t2_read.error)
		if not t1_read.data.is_empty():
			failures.append("Type 2 save leaked into Type 1 folder")
		# Возврат в меню настоящим путём игрока: проверяем карточку сохранённого мира Типа 2 с превью и длиной долины
		main._back_to_menu()
		for _i in 30:
			await process_frame
		if carousel.selected_texture() == null:
			failures.append("Type 2 menu card preview texture missing after returning to menu")
		var menu_img := root.get_viewport().get_texture().get_image()
		var menu_path := ProjectSettings.globalize_path(OUT.path_join("expedition_p4_menu%s.png" % tag))
		menu_img.save_png(menu_path)
		print("SHOT: ", menu_path)
		# 3. Повторный вход из кэша (тёплая загрузка) — проверяем скорость и чтение сохранения
		var t_warm := Time.get_ticks_msec()
		main.start_game(seed_text, WorldGenerator.START_SIZE, "manual", false, WorldTemplate.EXPEDITION_ID)
		wait_frames = 0
		while (main.busy or main.game == null or main.game.player == null) and wait_frames < 12000:
			await process_frame
			wait_frames += 1
		var warm_ms := Time.get_ticks_msec() - t_warm
		if main.game == null or main.game.player == null:
			failures.append("warm reload from Type 2 cache/save failed")
		else:
			print("PHASE4_WARM seed=%s size=%dx%d warm_ms=%d" % [seed_text, main.game.world.W, main.game.world.H, warm_ms])
			main._back_to_menu()

	main.queue_free()
	await process_frame
	Saves.dir = old_save_dir
	GameContext.scope.cache.enabled = old_cache_enabled
	GameContext.scope.cache.dir = old_cache_dir
	GameContext.scope.settings.settings_path = old_settings_path
	if failures.is_empty():
		print("PHASE4_VERIFY: PASS")
		return true
	for msg: String in failures:
		push_error("PHASE4_VERIFY FAIL: " + msg)
	return false


func _run_fingerprint(seed_text: String, short_dev: bool, explicit_h: int, out_path: String, cmp_path: String) -> bool:
	var w := WorldGenerator._generate_plan(seed_text, WorldGenerator.PLAN_SIZE, Callable(), Callable(),
		null, 0, Callable(), WorldGenerator.PlanMode.WORLD, Callable(),
		WorldTemplate.EXPEDITION_ID, short_dev, explicit_h)
	if w == null:
		push_error("FINGERPRINT FAIL: null world")
		return false
	w.territory_center = WorldGenerator.start_center(w)
	w.expand_territory(maxi(w.W, w.H))
	var settle_str := PackedStringArray()
	for s: SettlementData in w.settlements:
		settle_str.append("%s:%.3f,%.3f:%d:%s" % [s.name, s.x, s.y, s.huts.size(), s.role])
	var site_str := PackedStringArray()
	for s: SiteData in w.sites:
		site_str.append("%s:%s:%.3f,%.3f:%d" % [s.type, s.name, s.x, s.y, s.huts.size()])
	var road_pts := PackedFloat64Array()
	for t: Dictionary in w.trails:
		for p: Dictionary in t.pts:
			road_pts.append_array([float(p.x), float(p.y), float(p.w)])
	var fp := {
		seed = seed_text,
		size = "%dx%d" % [w.W, w.H],
		h_sha = Util.sha256(w.h.to_byte_array()).hex_encode(),
		elev_sha = Util.sha256(w.elev.to_byte_array()).hex_encode(),
		biome_sha = Util.sha256(w.biome).hex_encode(),
		river_sha = Util.sha256(w.river_cells()).hex_encode(),
		path_sha = Util.sha256(w.path_mask).hex_encode(),
		road_sha = Util.sha256(road_pts.to_byte_array()).hex_encode(),
		road_pts_n = road_pts.size() / 3,
		settlements = "|".join(settle_str),
		sites = "|".join(site_str),
		objects = w.obj_count,
		obj_sha = Util.sha256(w.obj_x.to_byte_array()).hex_encode(),
	}
	w.clear_noise_fields()
	w.base_heights = null
	if not out_path.is_empty():
		var abs_out := ProjectSettings.globalize_path(out_path)
		var f := FileAccess.open(abs_out, FileAccess.WRITE)
		f.store_string(JSON.stringify(fp, "\t"))
		f.close()
		print("FINGERPRINT SAVED: ", abs_out)
	if not cmp_path.is_empty():
		var abs_cmp := ProjectSettings.globalize_path(cmp_path)
		var raw := FileAccess.get_file_as_string(abs_cmp)
		var prev: Variant = JSON.parse_string(raw)
		if not prev is Dictionary:
			push_error("FINGERPRINT CMP FAIL: unreadable " + abs_cmp)
			return false
		var diffs: Array[String] = []
		for k: String in fp:
			var cur: Variant = fp[k]
			var old: Variant = prev.get(k, null)
			var same: bool = false
			if (cur is int or cur is float) and (old is int or old is float):
				same = is_equal_approx(float(cur), float(old))
			else:
				same = str(cur) == str(old)
			if not same:
				diffs.append("%s: before=%s after=%s" % [k, str(old), str(cur)])
		if diffs.is_empty():
			print("FINGERPRINT COMPARE: BIT-EXACT MATCH (%d/%d fields)" % [fp.size(), fp.size()])
			return true
		for d: String in diffs:
			push_error("FINGERPRINT DIFF: " + d)
		return false
	return true


func _verify_phase1(short_dev: bool) -> bool:
	var failures: Array[String] = []
	var tmp := ProjectSettings.globalize_path("res://.godot/expedition_phase1_test")
	DirAccess.make_dir_recursive_absolute(tmp)
	var old_save_dir := Saves.dir
	Saves.dir = tmp.path_join("saves_t1")
	var cfg_path := tmp.path_join("settings.cfg")

	var exp_cfg := WorldTemplate.config(WorldTemplate.EXPEDITION_ID)
	for seed_text: String in ["Север-1234", "Туман-4821", "Янтарь-5150", "b2"]:
		var sz := WorldTemplate.plan_size(WorldTemplate.EXPEDITION_ID, WGRandom.hash_string(seed_text), false)
		var px := WorldLoader.px_for(maxi(sz.x, sz.y))
		var map_px := mini(2, px)
		if sz.x != exp_cfg.plan_width or not (sz.y in Array(exp_cfg.plan_heights)) or sz.y > 4096 or sz.y % 64 != 0:
			failures.append("invalid full size for %s: %s (expected W=%d H in %s)" % [seed_text, sz, exp_cfg.plan_width, str(exp_cfg.plan_heights)])
		if sz.y * px > 4096 or sz.y * map_px > 4096:
			failures.append("texture exceeds 4096 for %s: %s px=%d map_px=%d" % [seed_text, sz, px, map_px])

	var base_save := func(tid: String, px: float) -> Dictionary:
		return {
			format = 1, seed = "Общий-100", template_id = tid, saved_at = 1000.0,
			signature = "sig", goal = "", visited = {},
			quest = {active = {}, by_giver = {}, known = {}, completed = {}, cargo = false, done = 0, last = ""},
			player = {x = px, z = 20.0, feet = 10.0, yaw = 0.0, pitch = 0.0, hour = 9.0},
			bike = {x = px + 2.0, z = 20.0, y = 10.0, heading = 0.0, riding = false},
		}
	var err1 := Saves.write_slot(base_save.call(WorldTemplate.DEFAULT_ID, 111.0), "auto", WorldTemplate.DEFAULT_ID)
	var err2 := Saves.write_slot(base_save.call(WorldTemplate.EXPEDITION_ID, 222.0), "auto", WorldTemplate.EXPEDITION_ID)
	if err1 != OK or err2 != OK:
		failures.append("save write failed: t1=%s t2=%s" % [error_string(err1), error_string(err2)])
	var r1 := Saves.read_slot("Общий-100", "auto", WorldTemplate.DEFAULT_ID)
	var r2 := Saves.read_slot("Общий-100", "auto", WorldTemplate.EXPEDITION_ID)
	if r1.data.is_empty() or not is_equal_approx(float(r1.data.player.x), 111.0):
		failures.append("t1 save mismatch")
	if r2.data.is_empty() or not is_equal_approx(float(r2.data.player.x), 222.0):
		failures.append("t2 save mismatch")
	var foreign: Dictionary = base_save.call(WorldTemplate.EXPEDITION_ID, 333.0)
	var raw_foreign := Saves.encode(foreign)
	Saves.write_bytes("Чужой-200", raw_foreign, "auto", WorldTemplate.DEFAULT_ID)
	var r_foreign := Saves.read_slot("Чужой-200", "auto", WorldTemplate.DEFAULT_ID)
	if not r_foreign.data.is_empty() or r_foreign.error.is_empty():
		failures.append("foreign template save was not rejected")

	var st := GameSettings.new()
	st.settings_path = cfg_path
	st.set_active_template(WorldTemplate.DEFAULT_ID)
	st.remember_seed("Мир-Т1")
	st.toggle_favorite("Мир-Т1")
	st.set_active_template(WorldTemplate.EXPEDITION_ID)
	st.remember_seed("Мир-Т2")
	st.save_settings()
	var st2 := GameSettings.new()
	st2.settings_path = cfg_path
	st2.load_settings()
	if st2.last_seed != "Мир-Т1" or "Мир-Т2" in st2.recent_seeds or "Мир-Т2" in st2.favorite_seeds:
		failures.append("settings leaked t2 into t1")
	st2.set_active_template(WorldTemplate.EXPEDITION_ID)
	if st2.last_seed != "Мир-Т2" or "Мир-Т1" in st2.recent_seeds:
		failures.append("settings leaked t1 into t2")

	var w := WorldGenerator.generate("Тест-Эксп", WorldGenerator.START_SIZE, Callable(), Callable(), Callable(),
		WorldTemplate.EXPEDITION_ID, true if short_dev else true)
	if w == null:
		failures.append("failed to generate short Type 2 world")
	else:
		var want_sz := WorldTemplate.plan_size(WorldTemplate.EXPEDITION_ID, w.seed_num, true)
		if w.W != want_sz.x or w.H != want_sz.y or w.template_id != WorldTemplate.EXPEDITION_ID:
			failures.append("unexpected Type 2 dimensions: %dx%d tpl=%s (expected %s)" % [w.W, w.H, w.template_id, want_sz])
		if w.available_rect != Rect2i(0, 0, w.W, w.H):
			failures.append("available_rect is not full plan: %s" % w.available_rect)
		if not w.accessible(float(w.W) * 0.5, 20.0, 1.0) or not w.accessible(float(w.W) * 0.5, float(w.H) - 20.0, 1.0):
			failures.append("invisible wall inside Type 2 plan")
		if w.trails.size() != 1:
			failures.append("expected connected expedition road on Тест-Эксп, got %d trails" % w.trails.size())
		w.expand_territory(w.W)
		if w.available_rect != Rect2i(0, 0, w.W, w.H):
			failures.append("expand_territory(W) shrank Type 2 available_rect to %s" % w.available_rect)
		if WorldTemplate.allow_infinite_regions(w.template_id):
			failures.append("RegionStream should be disabled for Type 2")
		# Проверка: правка .tres-настройки меняет ключ кэша Типа 2 и не трогает ключ Типа 1.
		var cfg2 := WorldTemplate.config(WorldTemplate.EXPEDITION_ID)
		var g_before := WorldTemplate.geo_cache_suffix(WorldTemplate.EXPEDITION_ID)
		var p_before := WorldTemplate.places_cache_suffix(WorldTemplate.EXPEDITION_ID)
		var t1_g := WorldTemplate.geo_cache_suffix(WorldTemplate.DEFAULT_ID)
		var t1_p := WorldTemplate.places_cache_suffix(WorldTemplate.DEFAULT_ID)
		var old_hw := cfg2.river_hw_end
		cfg2.river_hw_end = old_hw + 0.5
		if WorldTemplate.geo_cache_suffix(WorldTemplate.EXPEDITION_ID) == g_before:
			failures.append("geo cache suffix did not change after editing river_hw_end")
		cfg2.river_hw_end = old_hw
		var old_anch := cfg2.anchor_min_dy
		cfg2.anchor_min_dy = old_anch + 10
		if WorldTemplate.places_cache_suffix(WorldTemplate.EXPEDITION_ID) == p_before:
			failures.append("places cache suffix did not change after editing anchor_min_dy")
		cfg2.anchor_min_dy = old_anch
		if not t1_g.is_empty() or not t1_p.is_empty():
			failures.append("Type 1 cache suffixes must remain empty")
		var scope := ServiceScope.new()
		scope.cache.enabled = true
		scope.cache.set_template(WorldTemplate.EXPEDITION_ID)
		scope.cache.dir = tmp.path_join("cache_loader_t2")
		var loaded := WorldLoader.load_world("Тест-Эксп", WorldGenerator.START_SIZE, Callable(), scope, Vector2.INF, Callable(), WorldTemplate.EXPEDITION_ID, true)
		if loaded == null or not loaded.error.is_empty() or loaded.world == null:
			failures.append("WorldLoader cold load failed: %s" % (loaded.error if loaded != null else "null"))
		else:
			if loaded.terrain_image.get_height() > 4096 or loaded.map_image.get_height() > 4096:
				failures.append("loaded images exceed 4096")
			if loaded.chunk_source != null:
				loaded.chunk_source.close()
		scope.cache.wait_writes()
		var warm := WorldLoader.load_world("Тест-Эксп", WorldGenerator.START_SIZE, Callable(), scope, Vector2.INF, Callable(), WorldTemplate.EXPEDITION_ID, true)
		if warm == null or not warm.error.is_empty() or warm.world == null:
			failures.append("WorldLoader warm load failed: %s" % (warm.error if warm != null else "null"))
		else:
			if warm.chunk_source != null:
				warm.chunk_source.close()

	Saves.dir = old_save_dir
	if failures.is_empty():
		print("PHASE1_VERIFY: PASS")
		return true
	for msg: String in failures:
		push_error("PHASE1_VERIFY FAIL: " + msg)
	return false


func _stats(w: WorldData, total_ms: float) -> Dictionary:
	var counts := {}
	for g: String in GROUPS:
		counts[g] = 0
	var b2g := {}
	for g: String in GROUPS:
		for bid: int in GROUPS[g]:
			b2g[bid] = g
	var min_h := INF
	var max_h := -INF
	var river_n := 0
	for i in w.N:
		var g: String = b2g.get(w.biome[i], "other")
		counts[g] = int(counts.get(g, 0)) + 1
		var hm := w.h[i] * GameConfig.HS
		min_h = minf(min_h, hm)
		max_h = maxf(max_h, hm)
		if w.river[i] != 0 or (w.river_area.size() == w.N and w.river_area[i] != 0):
			river_n += 1
	var pct := {}
	for g: String in counts:
		pct[g] = snappedf(100.0 * float(counts[g]) / float(maxi(1, w.N)), 0.1)
	return {
		seed = w.seed_text,
		size = "%dx%d" % [w.W, w.H],
		total_ms = snappedf(total_ms, 1.0),
		stages_ms = w.generation_profile.get("stages_ms", {}),
		min_h_m = snappedf(min_h, 0.1),
		max_h_m = snappedf(max_h, 0.1),
		river_cells = river_n,
		biomes_pct = pct,
	}


func _print_row(row: Dictionary) -> void:
	var b: Dictionary = row.biomes_pct
	print("%-12s %s  %6.0f ms  h=[%5.1f..%5.1f]m  river=%d  forest=%.1f%% meadow=%.1f%% rock=%.1f%% tundra=%.1f%% swamp=%.1f%% water=%.1f%%" % [
		row.seed, row.size, row.total_ms, row.min_h_m, row.max_h_m, row.river_cells,
		b.get("forest", 0.0), b.get("meadow", 0.0), b.get("rock", 0.0), b.get("tundra", 0.0), b.get("swamp", 0.0), b.get("water", 0.0)])


## Карта-полоса + продольный профиль реки (синий) и дорожных предгорий (зелёный) справа.
func _render_strip_with_profile(w: WorldData) -> Image:
	var step := 2 if w.H > 1536 else 1
	var iw := ceili(float(w.W) / step)
	var ih := ceili(float(w.H) / step)
	var prof_w := 96
	var img := Image.create(iw + 6 + prof_w, ih, false, Image.FORMAT_RGB8)
	img.fill(Color(0.10, 0.11, 0.13))
	var river := w.river_cells()
	var axis := ValleyAxis.for_world(w)
	for py in ih:
		var y := mini(w.H - 1, py * step)
		for px in iw:
			var x := mini(w.W - 1, px * step)
			var i := y * w.W + x
			var rgb: Array = Biomes.LIST[clampi(w.biome[i], 0, Biomes.LIST.size() - 1)].color
			var col := Color(rgb[0] / 255.0, rgb[1] / 255.0, rgb[2] / 255.0)
			if river.size() == w.N and river[i] != 0:
				col = Color(0.16, 0.46, 0.76)
			elif w.ocean[i] == 0 and w.lake[i] == 0:
				var west: float = w.h[y * w.W + maxi(0, x - 2)]
				var north: float = w.h[maxi(0, y - 2) * w.W + x]
				col *= 1.0 + clampf((west + north - 2.0 * w.h[i]) * 8.0, -0.35, 0.25)
			img.set_pixel(px, py, col)
		# Продольный профиль справа: 0..220 м
		var fh_m := axis.floor_h_at(y) * GameConfig.HS
		var ax := axis.axis_x_at(float(y))
		var spur_x := clampi(roundi(ax + 38.0 * float(axis.road_side)), 0, w.W - 1)
		var spur_m := w.h[y * w.W + spur_x] * GameConfig.HS
		var x_riv := clampi(roundi(fh_m / 220.0 * float(prof_w - 4)), 0, prof_w - 1)
		var x_sp := clampi(roundi(spur_m / 220.0 * float(prof_w - 4)), 0, prof_w - 1)
		var ox := iw + 6
		for k in range(0, prof_w, 24):
			img.set_pixel(ox + k, py, Color(0.18, 0.20, 0.23))
		for k in range(mini(x_riv, x_sp), maxi(x_riv, x_sp) + 1):
			img.set_pixel(ox + k, py, Color(0.24, 0.42, 0.26))
		img.set_pixel(ox + x_sp, py, Color(0.55, 0.85, 0.45))
		img.set_pixel(ox + x_riv, py, Color(0.32, 0.68, 0.96))
	return img


func _sheet(maps: Array[Image]) -> Image:
	var gap := 12
	var total_w := gap
	var max_h := 0
	for m: Image in maps:
		total_w += m.get_width() + gap
		max_h = maxi(max_h, m.get_height())
	var out := Image.create(maxi(1, total_w), maxi(1, max_h + 2 * gap), false, Image.FORMAT_RGB8)
	out.fill(Color(0.08, 0.09, 0.11))
	var x := gap
	for m: Image in maps:
		out.blit_rect(m, Rect2i(Vector2i.ZERO, m.get_size()), Vector2i(x, gap))
		x += m.get_width() + gap
	return out


func _verify_phase5() -> bool:
	var failures: Array[String] = []
	var t1 := RoadTuning.for_template(WorldTemplate.DEFAULT_ID)
	var t2 := RoadTuning.for_template(WorldTemplate.EXPEDITION_ID)
	if t1 != RoadTuning.current():
		failures.append("for_template(DEFAULT_ID) did not return RoadTuning.current()")
	if t2 == null or not t2.valid():
		failures.append("for_template(EXPEDITION_ID) returned null or invalid RoadTuning")
	if t2 == t1:
		failures.append("for_template(EXPEDITION_ID) aliased Type 1 RoadTuning.current()")
	var wd1 := WorldData.new()
	wd1.template_id = WorldTemplate.DEFAULT_ID
	var wd2 := WorldData.new()
	wd2.template_id = WorldTemplate.EXPEDITION_ID
	if RoadTuning.for_world(wd1) != t1:
		failures.append("for_world(Type 1) != current()")
	if RoadTuning.for_world(wd2) != t2:
		failures.append("for_world(Type 2) != EXPEDITION RoadTuning")
	if RoadTuning.for_world(null) != t1:
		failures.append("for_world(null) != current()")
	if WorldTemplate.expedition_route_kind(WorldTemplate.EXPEDITION_ID) != "trail":
		failures.append("expedition_route_kind != trail")

	# 16-worker concurrent cache cold-load check.
	RoadTuning.clear_template_cache()
	var res_t1: Array = []
	var res_t2: Array = []
	res_t1.resize(32)
	res_t2.resize(32)
	var gid := WorkerThreadPool.add_group_task(func(idx: int) -> void:
		res_t2[idx] = RoadTuning.for_template(WorldTemplate.EXPEDITION_ID)
		res_t1[idx] = RoadTuning.for_template(WorldTemplate.DEFAULT_ID)
	, 32, -1, true)
	WorkerThreadPool.wait_for_group_task_completion(gid)
	var first_t2: Variant = res_t2[0]
	if first_t2 == null or not (first_t2 as RoadTuning).valid() or first_t2 == t1:
		failures.append("concurrent first Type 2 RoadTuning invalid or aliased")
	for idx in 32:
		if res_t2[idx] != first_t2:
			failures.append("concurrent Type 2 RoadTuning instance mismatch at idx %d" % idx)
			break
		if res_t1[idx] != t1:
			failures.append("concurrent Type 1 RoadTuning mismatch at idx %d" % idx)
			break

	# Cache key invalidation and Type 1 invariance across RoadTuning fields.
	t2 = RoadTuning.for_template(WorldTemplate.EXPEDITION_ID)
	var cache_snapshot := func(tid: String) -> Dictionary:
		var c := WorldCache.new()
		c.set_template(tid)
		return {layers = c.layer_keys(), surf = c.artifact_key("Север-1234", 512, "surface")}
	var base1: Dictionary = cache_snapshot.call(WorldTemplate.DEFAULT_ID)
	var base2: Dictionary = cache_snapshot.call(WorldTemplate.EXPEDITION_ID)
	var old_climb := float(t2.routing.climb_costs.trail)
	var old_clear := float(t2.section.clearance.trail)
	var old_dish := t2.trail.dish
	var old_edge := t2.section.edge

	t2.routing.climb_costs.trail = old_climb + 1.0
	var s1: Dictionary = cache_snapshot.call(WorldTemplate.DEFAULT_ID)
	var s2: Dictionary = cache_snapshot.call(WorldTemplate.EXPEDITION_ID)
	if s2.layers[1] == base2.layers[1]:
		failures.append("Type 2 places key unchanged after routing.climb_costs.trail edit")
	if s1.layers != base1.layers or s1.surf != base1.surf:
		failures.append("Type 1 keys changed after Type 2 routing edit")
	t2.routing.climb_costs.trail = old_climb

	t2.section.clearance.trail = old_clear + 0.25
	s1 = cache_snapshot.call(WorldTemplate.DEFAULT_ID)
	s2 = cache_snapshot.call(WorldTemplate.EXPEDITION_ID)
	if s2.layers[2] == base2.layers[2]:
		failures.append("Type 2 nature key unchanged after section.clearance.trail edit")
	if s1.layers != base1.layers or s1.surf != base1.surf:
		failures.append("Type 1 keys changed after Type 2 clearance edit")
	t2.section.clearance.trail = old_clear

	t2.trail.dish = old_dish - 0.02
	s1 = cache_snapshot.call(WorldTemplate.DEFAULT_ID)
	s2 = cache_snapshot.call(WorldTemplate.EXPEDITION_ID)
	if s2.layers[2] == base2.layers[2] or s2.surf == base2.surf:
		failures.append("Type 2 nature/surface key unchanged after trail.dish edit")
	if s1.layers != base1.layers or s1.surf != base1.surf:
		failures.append("Type 1 keys changed after Type 2 trail.dish edit")
	t2.trail.dish = old_dish

	t2.section.edge = old_edge + 0.05
	s1 = cache_snapshot.call(WorldTemplate.DEFAULT_ID)
	s2 = cache_snapshot.call(WorldTemplate.EXPEDITION_ID)
	if s2.surf == base2.surf:
		failures.append("Type 2 surface artifact key unchanged after section.edge edit")
	if s1.layers != base1.layers or s1.surf != base1.surf:
		failures.append("Type 1 keys changed after Type 2 section.edge edit")

	# RoadRefinement.from_patches warm restore section affinity.
	var r2 := RoadRefinement.from_patches({}, 768, WorldTemplate.EXPEDITION_ID)
	var r1 := RoadRefinement.from_patches({}, 768, WorldTemplate.DEFAULT_ID)
	if r2._section != t2.section:
		failures.append("from_patches(EXPEDITION_ID)._section did not match Type 2 section")
	if r1._section != t1.section or r2._section == r1._section:
		failures.append("from_patches(DEFAULT_ID)._section mismatched or aliased")

	# TerrainBuilder shader isolation when Type 2 has tuned edge and Type 1 keeps default SHADER.
	var tb := TerrainBuilder.new()
	var mat_t2 := tb.outer_material(WorldTemplate.EXPEDITION_ID)
	var far_t2 := tb.far_material(mat_t2)
	var mat_t1 := tb.outer_material(WorldTemplate.DEFAULT_ID)
	var far_t1 := tb.far_material(mat_t1)
	if mat_t2.shader == TerrainBuilder.SHADER:
		failures.append("Type 2 material used un-tuned SHADER despite modified section.edge")
	if far_t2 == null or far_t2.shader == TerrainBuilder._far_shader:
		failures.append("Type 2 far_material missed or reused Type 1 _far_shader")
	if mat_t1.shader != TerrainBuilder.SHADER:
		failures.append("Type 1 material did not keep TerrainBuilder.SHADER")
	if far_t1 == null or far_t1.shader != TerrainBuilder._far_shader or far_t1.shader == far_t2.shader:
		failures.append("Type 1 far_material mismatched or aliased Type 2 far shader")

	t2.section.edge = old_edge
	WorldTemplate.reload()
	var t2_reloaded := RoadTuning.for_template(WorldTemplate.EXPEDITION_ID)
	if t2_reloaded == null or not t2_reloaded.valid():
		failures.append("reloaded Type 2 RoadTuning invalid")
	elif (not is_equal_approx(float(t2_reloaded.routing.climb_costs.trail), old_climb)
			or not is_equal_approx(float(t2_reloaded.section.clearance.trail), old_clear)
			or not is_equal_approx(t2_reloaded.trail.dish, old_dish)
			or not is_equal_approx(t2_reloaded.section.edge, old_edge)):
		failures.append("reloaded Type 2 RoadTuning did not restore original .tres values")

	if failures.is_empty():
		print("PHASE5_VERIFY: PASS")
		return true
	for msg: String in failures:
		push_error("PHASE5_VERIFY FAIL: " + msg)
	return false


func _verify_phase7(seeds: PackedStringArray, short_dev: bool, explicit_h: int) -> bool:
	const Floor := preload("res://scripts/render/forest_floor.gd")
	const Samples := preload("res://tools/road_surface_samples.gd")
	var failures: Array[String] = []
	var t1 := RoadTuning.for_template(WorldTemplate.DEFAULT_ID)
	var t2 := RoadTuning.for_template(WorldTemplate.EXPEDITION_ID)
	if not is_equal_approx(t1.section.crown, 0.035) or t1.trail.bench_scale != 1.0 or t1.trail.turn_bank != 0.0 or t1.obstacles.root_reach != 3.5:
		failures.append("Type 1 defaults changed: crown=%.4f bench=%.3f bank=%.3f root_reach=%.2f" % [
			t1.section.crown, t1.trail.bench_scale, t1.trail.turn_bank, t1.obstacles.root_reach])
	if t2.section.crown != 0.0 or t2.trail.bench_scale >= 0.5 or t2.trail.turn_bank <= 0.5 or t2.obstacles.root_reach <= 4.0:
		failures.append("Type 2 Phase 7 tuning unexpected: crown=%.4f bench=%.3f bank=%.3f root_reach=%.2f" % [
			t2.section.crown, t2.trail.bench_scale, t2.trail.turn_bank, t2.obstacles.root_reach])
	if RoadBump.rut_params(WorldTemplate.DEFAULT_ID) != Vector2(RoadBump.RUT_AT, RoadBump.RUT_W):
		failures.append("Type 1 rut_params altered")
	if RoadBump.rut_params(WorldTemplate.EXPEDITION_ID).x != 0.0:
		failures.append("Type 2 trail_single_rut expected center rut at 0.0")

	for seed_text: String in seeds:
		var w := WorldGenerator._generate_plan(seed_text, WorldGenerator.PLAN_SIZE, Callable(), Callable(),
			null, 0, Callable(), WorldGenerator.PlanMode.WORLD, Callable(),
			WorldTemplate.EXPEDITION_ID, short_dev, explicit_h)
		if w == null:
			failures.append("%s: generation returned null" % seed_text)
			continue
		w.territory_center = WorldGenerator.start_center(w)
		w.expand_territory(maxi(w.W, w.H))
		var h := Heightfield.new(w, true)
		if RoadRefinement.code_version() <= 0 or h.road_refinement == null or h.road_refinement.patches.is_empty():
			failures.append("%s: C# RoadRefinement missing or produced no patches" % seed_text)
			continue
		var val_err := RoadRecords.validation_error(w.trails, "phase7(%s)" % seed_text, RoadRecords.Phase.SURFACED)
		if not val_err.is_empty():
			failures.append("%s: RoadRecords invalid: %s" % [seed_text, val_err])

		var r := h.road_refinement
		var fit: Dictionary = r.fit_routes.get(0, {})
		var span: Vector2i = r.corridor_routes.get(0, Vector2i.ZERO)
		var st := Samples.stations(w.trails[0])
		var ps: PackedVector2Array = st.p
		var hw: PackedFloat32Array = st.half
		var n := mini(ps.size(), mini(span.y, fit.get("strength", PackedFloat32Array()).size()))

		var dish_sum := 0.0
		var dish_n := 0
		var keep_sum := 0.0
		var keep_n := 0
		var cor_bank_sum := 0.0
		var final_bank_sum := 0.0
		var bank_n := 0
		var grade1_max := 0.0
		var grade1_raw_max := 0.0
		var grade1_gap_max := 0.0
		var raw_g1_at_max := 0.0
		var grades := PackedFloat64Array()
		var forest_sample_pos := Vector2.INF
		var forest_grade := 0.0

		for j in range(6, n - 6):
			var p := ps[j]
			var tangent := (ps[j + 2] - ps[j - 2]).normalized()
			var across_v := Vector2(tangent.y, -tangent.x)
			var half := hw[j]
			var c := h.ground_at(p.x, p.y)
			var el := h.ground_at(p.x - across_v.x * half * 0.9, p.y - across_v.y * half * 0.9)
			var er := h.ground_at(p.x + across_v.x * half * 0.9, p.y + across_v.y * half * 0.9)
			var c_prev := h.ground_at(ps[j - 1].x, ps[j - 1].y)
			var g1 := absf(c - c_prev)
			var in_gap := false
			for gap: Dictionary in r.gaps:
				if (gap.area as Rect2).grow(2.0).has_point(p):
					in_gap = true
					break
			if in_gap:
				grade1_gap_max = maxf(grade1_gap_max, g1)
			else:
				grades.append(g1)
				if g1 > grade1_max:
					grade1_max = g1
					raw_g1_at_max = absf(h.ground_at(p.x, p.y, true) - h.ground_at(ps[j - 1].x, ps[j - 1].y, true))
					grade1_raw_max = raw_g1_at_max

			var strength := float(fit.strength[j])
			var cor_dish := r.corridor[(span.x + j) * RoadRefinement.CORRIDOR_STRIDE + 2]
			var cor_open := absf(cor_dish) > 0.001
			if strength > 0.2 and cor_open and not in_gap:
				dish_sum += c - (el + er) * 0.5
				dish_n += 1
				var raw_l := h.ground_at(p.x - across_v.x * half * 0.9, p.y - across_v.y * half * 0.9, true)
				var raw_r := h.ground_at(p.x + across_v.x * half * 0.9, p.y + across_v.y * half * 0.9, true)
				var raw_cross := (raw_r - raw_l) / (1.8 * half)
				var final_cross := (er - el) / (1.8 * half)
				if absf(raw_cross) > 0.14:
					keep_sum += absf(final_cross) / absf(raw_cross)
					keep_n += 1
				var t_prev := (ps[j] - ps[j - 5]).normalized()
				var t_next := (ps[j + 5] - ps[j]).normalized()
				var kappa := (t_next - t_prev).dot(across_v) / 5.0
				if absf(kappa) > 0.035:
					var cor_tilt := r.corridor[(span.x + j) * RoadRefinement.CORRIDOR_STRIDE + 1]
					cor_bank_sum += -cor_tilt * signf(kappa) / half
					final_bank_sum += -(final_cross - raw_cross * t2.trail.tilt_keep) * signf(kappa)
					bank_n += 1
			if forest_sample_pos == Vector2.INF and strength > 0.2 and not in_gap and w.road_surface[Samples.cell(w, p)] == RoadSurface.FOREST:
				forest_sample_pos = p
				forest_grade = absf(h.ground_at(ps[j + 4].x, ps[j + 4].y) - h.ground_at(ps[j - 4].x, ps[j - 4].y)) / 8.0

		grades.sort()
		var grade1_p99 := grades[int(grades.size() * 0.99)] if not grades.is_empty() else 0.0
		var mean_dish_cm := 100.0 * dish_sum / maxi(1, dish_n)
		var mean_keep := keep_sum / maxi(1, keep_n)
		var mean_cor_bank := cor_bank_sum / maxi(1, bank_n)
		var mean_final_bank := final_bank_sum / maxi(1, bank_n)

		if mean_dish_cm >= -1.5:
			failures.append("%s: trail dish not trough-like (mean_dish=%.2f cm, expected <= -1.5 cm)" % [seed_text, mean_dish_cm])
		if keep_n > 0 and mean_keep < 0.25:
			failures.append("%s: off-camber cross-slope overly flattened (keep=%.2f)" % [seed_text, mean_keep])
		if bank_n < 10 or mean_cor_bank <= 0.03 or mean_final_bank <= 0.01:
			failures.append("%s: inward turn bank too weak/wrong sign (samples=%d cor=%.3f final=%.3f)" % [
				seed_text, bank_n, mean_cor_bank, mean_final_bank])
		if grade1_p99 > 0.42 or (grade1_max > 0.55 and grade1_max - grade1_raw_max > 0.25):
			failures.append("%s: aliasing/step spike on non-gap 1m stations (p99=%.3f max=%.3f raw_at_max=%.3f gap_max=%.3f)" % [seed_text, grade1_p99, grade1_max, grade1_raw_max, grade1_gap_max])

		var surf_img := Floor.surface_image(w)
		var obs := RoadObstacles.new(w)
		var cand := obs.measure_candidates(h, surf_img, 0)
		var parts: Dictionary = cand.parts
		if int(parts.get("root", 0)) < 5 or int(cand.occupied) < 20:
			failures.append("%s: too few trail obstacles/roots (%s)" % [seed_text, str(cand)])

		var bump_delta := 0.0
		if forest_sample_pos != Vector2.INF:
			var contact := h.path_contact(forest_sample_pos.x, forest_sample_pos.y)
			var cb: Vector4 = contact.get("bump", Vector4.ZERO)
			var base_forest := RoadBump.LIST[RoadSurface.FOREST]
			if cb.x <= base_forest.x * 1.3 or cb.z <= base_forest.z * 1.3:
				failures.append("%s: Type 2 RoadBump contact did not receive boosted FOREST params (%s)" % [seed_text, str(cb)])
			bump_delta = RoadBump.height(forest_sample_pos.x, forest_sample_pos.y, RoadSurface.FOREST, forest_grade, 0.0, w.template_id)

		# Полный проезд по тропе на велосипеде со всеми живыми препятствиями VegetationLayer / ForestObstacles
		var veg := VegetationLayer.new()
		veg.carpet_enabled = false
		veg.use_shared_forest_ranges = false
		root.add_child(veg)
		veg.setup(w, h, {}, Models.grass_mesh(), surf_img)
		veg.settings.trail_clutter = true
		veg.grass_r = 16.0
		veg.under_r = 32.0
		veg._reserve_details(Vector2.ZERO)
		h.obstacles = ForestObstacles.new(w, h)
		var b := BikeRide.new()
		var p := PlayerState.new()
		var control := BikeController.new()
		var from := 6
		b.x = ps[from].x
		b.z = ps[from].y
		var ahead0 := ps[mini(ps.size() - 1, from + 5)] - ps[from]
		b.heading = atan2(-ahead0.x, -ahead0.y)
		b.y = h.ground_at(b.x, b.z)
		b.mount(p)
		b.speed = 6.5
		var dt := 1.0 / 60.0
		var near := from
		var fill_at := Vector2.INF
		var ticks := 0
		var stuck_ticks := 0
		var best_near := from
		var max_off := 0.0
		var sq_sum := 0.0
		var air_ticks := 0
		var max_bumps := 0
		var bypasses_used := 0
		var active_gap_id := -1
		var max_ticks := maxi(3600, int(ps.size() * 60 / 3))
		while ticks < max_ticks and not b.crashed and near < ps.size() - 14:
			var pos := Vector2(b.x, b.z)
			if pos.distance_squared_to(fill_at) >= 24.0 * 24.0:
				veg._fill_grass(pos.x, pos.y, {}, true)
				veg._accept_contacts()
				h.obstacles.update(pos.x, pos.y, veg.obstacles, veg.obstacles_version, true)
				h.obstacles.set_bumps(veg.bumps, veg.obstacles_version)
				max_bumps = maxi(max_bumps, veg.bumps.size() / 6)
				fill_at = pos
			var best_d := INF
			for j in range(maxi(0, near - 2), mini(ps.size(), near + 14)):
				var d := pos.distance_squared_to(ps[j])
				if d < best_d:
					best_d = d
					near = j
			if near > best_near:
				best_near = near
				stuck_ticks = 0
			else:
				stuck_ticks += 1
				if stuck_ticks > 360:
					break
			var look_pt := ps[mini(ps.size() - 1, near + 6)]
			var in_bypass := false
			for gi in r.gaps.size():
				var gap: Dictionary = r.gaps[gi]
				if (gap.area as Rect2).grow(4.0).has_point(pos):
					var bpts: Array = gap.bypass.pts
					var bp_best := 0
					var bp_d := INF
					for bi in bpts.size():
						var bd := pos.distance_squared_to(Vector2(bpts[bi].x, bpts[bi].y) * GameConfig.TILE)
						if bd < bp_d:
							bp_d = bd
							bp_best = bi
					if bp_best < bpts.size() - 2:
						var target_pt: Dictionary = bpts[mini(bpts.size() - 1, bp_best + 4)]
						look_pt = Vector2(target_pt.x, target_pt.y) * GameConfig.TILE
						in_bypass = true
						if active_gap_id != gi:
							active_gap_id = gi
							bypasses_used += 1
						break
			if not in_bypass:
				max_off = maxf(max_off, sqrt(best_d))
			var goal := look_pt - pos
			var want := atan2(-goal.x, -goal.y)
			var steer := clampf(-wrapf(want - b.heading, -PI, PI) * 2.6, -1.0, 1.0)
			var d1 := (ps[mini(ps.size() - 1, near + 4)] - ps[near]).normalized()
			var d2 := (ps[mini(ps.size() - 1, near + 14)] - ps[mini(ps.size() - 1, near + 6)]).normalized()
			var turn_ahead := absf(d1.angle_to(d2))
			var target_spd := clampf(7.5 - turn_ahead * 3.8, 4.8, 7.5)
			var throttle := clampf((target_spd - b.speed) * 0.7, -1.0, 1.0)
			control.ride(dt, p, b, w, h, throttle, steer, false, false, false)
			sq_sum += b.squash_f * b.squash_f + b.squash_r * b.squash_r
			air_ticks += int(b.airborne)
			ticks += 1
		var susp_rms_cm := sqrt(sq_sum / maxf(1.0, float(ticks * 2))) * 100.0
		var finished := not b.crashed and stuck_ticks <= 360 and near >= ps.size() - 14
		if not finished:
			var near_gap := INF
			for gap: Dictionary in r.gaps:
				near_gap = minf(near_gap, pos_to_rect_dist(Vector2(b.x, b.z), gap.area as Rect2))
			failures.append("%s: full BikeRide did not finish cleanly (crashed=%s cause=%s stuck=%d near=%d/%d at=(%.1f,%.1f) gap_d=%.1fm)" % [
				seed_text, b.crashed, BikeRide.CrashCause.keys()[b.crash_cause], stuck_ticks, near, ps.size(), b.x, b.z, near_gap])
		if max_bumps == 0:
			failures.append("%s: live VegetationLayer loaded 0 road bump contacts along the route" % seed_text)
		if susp_rms_cm < 0.25:
			failures.append("%s: suspension RMS unrealistically flat (%.2f cm)" % [seed_text, susp_rms_cm])
		veg.free()
		print("PHASE7_METRICS seed=%s len=%dm dish=%.2fcm keep=%.2f(n=%d) bank_cor=%.3f bank_final=%.3f(n=%d) g1_p99=%.3f g1_max=%.3f(raw=%.3f gap=%.3f) obs=%s bump_sample=%.2fcm max_bumps=%d bypasses=%d ride=(%d/%dm max_off=%.2fm susp=%.2fcm air=%d crashed=%s)" % [
			seed_text, n, mean_dish_cm, mean_keep, keep_n, mean_cor_bank, mean_final_bank, bank_n, grade1_p99, grade1_max, grade1_raw_max, grade1_gap_max,
			JSON.stringify(parts), bump_delta * 100.0, max_bumps, bypasses_used, near, ps.size(), max_off, susp_rms_cm, air_ticks, str(b.crashed)])
		w.clear_noise_fields()
		w.base_heights = null

	if failures.is_empty():
		print("PHASE7_VERIFY: PASS")
		return true
	for msg: String in failures:
		push_error("PHASE7_VERIFY FAIL: " + msg)
	return false


static func pos_to_rect_dist(p: Vector2, rect: Rect2) -> float:
	var c := p.clamp(rect.position, rect.end)
	return p.distance_to(c)


func _capture_phase7_shots(seed_text: String, tag: String) -> bool:
	const Floor := preload("res://scripts/render/forest_floor.gd")
	const Samples := preload("res://tools/road_surface_samples.gd")
	if DisplayServer.get_name() == "headless":
		push_error("PHASE7_SHOTS: window required (do not pass --headless)")
		return false
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(Vector2i(1280, 720))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	for _i in 20:
		await process_frame
	GameContext.scope.cache.enabled = false
	main.start_game(seed_text, WorldGenerator.START_SIZE, "", false, WorldTemplate.EXPEDITION_ID)
	var wait_frames := 0
	while (main.busy or main.game == null or main.game.player == null) and wait_frames < 12000:
		await process_frame
		wait_frames += 1
	if main.busy or main.game == null or main.game.player == null:
		push_error("PHASE7_SHOTS: GameWorld failed to start")
		main.queue_free()
		return false
	var gw: GameWorld = main.game
	gw.paused = true
	main.hud.visible = false
	if gw.pause_requested.is_connected(main._toggle_pause):
		gw.pause_requested.disconnect(main._toggle_pause)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if gw.opening_active():
		gw._finish_opening()
	if gw.vegetation != null:
		gw.vegetation.settings.trail_clutter = true
	gw.hour = 10.5
	if gw.day != null:
		gw.day.apply(10.5, 100.0)
	gw.camera.fov = 68.0
	gw.camera.current = true

	var w: WorldData = gw.world
	var h: Heightfield = gw.heights
	var r := h.road_refinement
	var fit: Dictionary = r.fit_routes.get(0, {})
	var span: Vector2i = r.corridor_routes.get(0, Vector2i.ZERO)
	var st := Samples.stations(w.trails[0])
	var ps: PackedVector2Array = st.p
	var hw: PackedFloat32Array = st.half
	var n := mini(ps.size(), mini(span.y, fit.get("strength", PackedFloat32Array()).size()))

	var best_descent_k := -1
	var best_descent_score := -INF
	var best_camber_k := -1
	var best_camber_score := -INF
	var best_berm_k := -1
	var best_berm_score := -INF
	var best_berm_fallback_k := -1
	var best_berm_fallback_score := -INF
	var forest_probe_k := -1
	var best_forest_score := -INF
	var surf_img := Floor.surface_image(w)

	for j in range(45, n - 45):
		if float(fit.strength[j]) < 0.2 or absf(r.corridor[(span.x + j) * RoadRefinement.CORRIDOR_STRIDE + 2]) <= 0.001:
			continue
		var p := ps[j]
		if w.road_surface[Samples.cell(w, p)] != RoadSurface.FOREST:
			continue
		var tangent := (ps[j + 3] - ps[j - 3]).normalized()
		var nn := Vector2(-tangent.y, tangent.x)
		var across_v := Vector2(tangent.y, -tangent.x)
		var half := hw[j]
		var grade := (h.ground_at(ps[j - 6].x, ps[j - 6].y) - h.ground_at(ps[j + 6].x, ps[j + 6].y)) / 12.0
		var raw_cross := absf(h.ground_at(p.x + nn.x * half, p.y + nn.y * half, true) - h.ground_at(p.x - nn.x * half, p.y - nn.y * half, true)) / (2.0 * half)
		var final_cross := absf(h.ground_at(p.x + nn.x * half, p.y + nn.y * half) - h.ground_at(p.x - nn.x * half, p.y - nn.y * half)) / (2.0 * half)
		var t_prev := (ps[j] - ps[j - 5]).normalized()
		var t_next := (ps[j + 5] - ps[j]).normalized()
		var curv := (t_next - t_prev).length() / 5.0

		var descent_sc := grade - curv * 1.5
		if grade > 0.04 and curv < 0.03 and descent_sc > best_descent_score:
			best_descent_score = descent_sc
			best_descent_k = j
		var camber_sc := final_cross + raw_cross * 0.5 - curv * 2.0
		if raw_cross > 0.14 and camber_sc > best_camber_score:
			best_camber_score = camber_sc
			best_camber_k = j
		var berm_fallback_sc := curv - absf(grade) * 0.2
		if curv > 0.035 and berm_fallback_sc > best_berm_fallback_score:
			best_berm_fallback_score = berm_fallback_sc
			best_berm_fallback_k = j
		var turn_dot := (t_next - t_prev).dot(across_v)
		var crest := h.ground_at(p.x, p.y) - 0.5 * (h.ground_at(ps[j - 5].x, ps[j - 5].y) + h.ground_at(ps[j + 5].x, ps[j + 5].y))
		var bank_slope := (((h.ground_at(p.x + across_v.x * half, p.y + across_v.y * half) - h.ground_at(p.x - across_v.x * half, p.y - across_v.y * half)) / (2.0 * half)) * (-signf(turn_dot))) if absf(turn_dot) > 1e-4 else 0.0
		var berm_sc := bank_slope * 2.5 + curv - absf(grade) * 0.3 - maxf(0.0, crest) * 1.5
		if curv > 0.035 and crest < 0.08 and bank_slope > 0.03 and berm_sc > best_berm_score:
			best_berm_score = berm_sc
			best_berm_k = j
		var cell_at := Samples.cell(w, p)
		var tree_cover := float(surf_img.get_pixelv(Vector2i(cell_at % w.W, cell_at / w.W)).r) if j % 4 == 0 else -INF
		if tree_cover > best_forest_score:
			best_forest_score = tree_cover
			forest_probe_k = j

	var berm_k := best_berm_k if best_berm_k >= 0 else best_berm_fallback_k
	var shots: Array[Dictionary] = []
	for entry: Array in [["p7_descent", best_descent_k, -2, 7, 1.25], ["p7_offcamber", best_camber_k, -2, 6, 1.25], ["p7_berm", berm_k, -5, 3, 1.45]]:
		var k: int = entry[1]
		if k < 0:
			continue
		var p0 := ps[maxi(0, k + int(entry[2]))]
		var look := ps[mini(ps.size() - 1, k + int(entry[3]))]
		shots.append({
			name = entry[0],
			pos = Vector3(p0.x, h.ground_at(p0.x, p0.y) + float(entry[4]), p0.y),
			target = Vector3(look.x, h.ground_at(look.x, look.y) + 0.12, look.y),
		})

	# 4-й крупный план — на реальный корень, пересекающий саму колею в лесу (расстояние до оси тропы < 1.35 м)
	var probe_candidates: Array[int] = [maxi(45, forest_probe_k if forest_probe_k >= 0 else n / 3), n / 6, n / 4, n / 3, n / 2, (2 * n) / 3, (3 * n) / 4, (5 * n) / 6]
	var best_root := Vector2.INF
	var best_root_d := INF
	var root_k := probe_candidates[0]
	for cand_k: int in probe_candidates:
		var ck := clampi(cand_k, 45, n - 45)
		var probe_pos := Vector3(ps[ck].x, h.ground_at(ps[ck].x, ps[ck].y) + 1.2, ps[ck].y)
		gw.player.x = probe_pos.x
		gw.player.z = probe_pos.z
		gw.player.feet = probe_pos.y - 1.2
		gw.stream_coordinator.force_vegetation(probe_pos)
		if gw.vegetation != null and gw.vegetation.understory.size() > Floor.FIRST + Floor.ROOT_SPAN_C:
			for form: int in [Floor.ROOT_SPAN, Floor.ROOT_SPAN_B, Floor.ROOT_SPAN_C]:
				var entry: Dictionary = gw.vegetation.understory[Floor.FIRST + form]
				var buffer: PackedFloat32Array = entry.buf
				for i in entry.count:
					var offset: int = i * VegetationLayer.STRIDE
					var rp := Vector2(buffer[offset + 3], buffer[offset + 11])
					var d_trail := INF
					var rk_local := ck
					for j in range(maxi(0, ck - 90), mini(ps.size(), ck + 90)):
						var dj := ps[j].distance_to(rp)
						if dj < d_trail:
							d_trail = dj
							rk_local = j
					if w.road_surface[Samples.cell(w, ps[rk_local])] == RoadSurface.FOREST and d_trail < 1.35 and d_trail < best_root_d:
						best_root_d = d_trail
						best_root = rp
						root_k = rk_local
	if best_root != Vector2.INF:
		var cam_p := ps[maxi(0, root_k - 3)]
		var aim := ps[root_k].lerp(best_root, 0.35)
		print("PHASE7_ROOT_SHOT at=", best_root, " trail_d=", snappedf(best_root_d, 0.05), " trail_k=", root_k)
		shots.append({
			name = "p7_roots",
			pos = Vector3(cam_p.x, h.ground_at(cam_p.x, cam_p.y) + 1.10, cam_p.y),
			target = Vector3(aim.x, h.ground_at(aim.x, aim.y) + 0.04, aim.y),
		})
	else:
		print("PHASE7_ROOT_SHOT fallback at trail_k=", root_k)
		var cam_p := ps[maxi(0, root_k - 4)]
		var look := ps[mini(ps.size() - 1, root_k + 4)]
		shots.append({
			name = "p7_roots",
			pos = Vector3(cam_p.x, h.ground_at(cam_p.x, cam_p.y) + 1.15, cam_p.y),
			target = Vector3(look.x, h.ground_at(look.x, look.y) + 0.05, look.y),
		})

	var all_ok := true
	for sh: Dictionary in shots:
		var pos: Vector3 = sh.pos
		var target: Vector3 = sh.target
		var chunk_lod := await _load_shot_view(gw, pos, 0.6)
		gw.camera.look_at_from_position(pos, target, Vector3.UP)
		for _f in 18:
			await process_frame
		var img := root.get_viewport().get_texture().get_image()
		var out_path := ProjectSettings.globalize_path(OUT.path_join("expedition_%s%s.png" % [sh.name, tag]))
		img.save_png(out_path)
		print("SHOT: ", out_path, " lod=", chunk_lod)
		if chunk_lod != 0:
			push_error("PHASE7_SHOTS: expected LOD0 for %s, got %d" % [sh.name, chunk_lod])
			all_ok = false

	main._free_game()
	main.queue_free()
	await process_frame
	return all_ok
