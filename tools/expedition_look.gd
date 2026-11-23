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

	if args.has("--geo") or (not args.has("--verify-phase1") and not args.has("--verify-phase2") and not args.has("--roads") and not args.has("--shots") and not args.has("--shots-p3") and not args.has("--phase8") and not args.has("--phase8-drive") and not maple and not args.has("--verify-phase4") and fp_out.is_empty() and fp_cmp.is_empty()):
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

	if args.has("--phase8") or args.has("--phase8-drive") or maple:
		ok = await _capture_phase3_shots(seeds[0], tag, true, args.has("--phase8-drive"), maple) and ok

	if args.has("--verify-phase4"):
		ok = await _verify_phase4(seeds[0], tag) and ok

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

	# 7. C# == GDScript паритет рельефа долины на полосе 64×64
	var fast_patch := StageRelief.height_rect(w, 64, w.H / 3, 64, 64, false, true)
	StageRelief.allow_fast_valley = false
	var gd_patch := StageRelief.height_rect(w, 64, w.H / 3, 64, 64, false, true)
	StageRelief.allow_fast_valley = true
	var max_diff := 0.0
	for k in fast_patch.size():
		max_diff = maxf(max_diff, absf(fast_patch[k] - gd_patch[k]))
	if max_diff > 1e-4:
		failures.append("C# vs GDScript valley relief max diff = %.6f" % max_diff)

	# 8. Проверка доли биомов в полосе дороги (лес в предгорьях, без болот и тундры на дне)
	var cor_n := 0
	var cor_forest := 0
	var cor_swamp := 0
	var cor_rock_tundra := 0
	for y in range(20, w.H - 20, 2):
		var ax := axis.axis_x_at(float(y))
		var rhw := axis.river_hw_at(y)
		for sd_i in range(ceili(rhw + 4.0), 75, 2):
			var x := roundi(ax + float(sd_i * axis.road_side))
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
	print("PHASE2_METRICS seed=%s %dx%d drop=%.1fm spurs=%d edge_step=%.2fm cs_gd_diff=%.6f corridor(forest=%.1f%% swamp=%.1f%% rock+tundra=%.1f%%)" % [
		seed_text, w.W, w.H, (axis.top_h - axis.bot_h) * GameConfig.HS, axis.spurs.size(),
		max_step_m, max_diff, f_pct, s_pct, rt_pct])

	w.clear_noise_fields()
	w.base_heights = null
	if failures.is_empty():
		print("PHASE2_VERIFY: PASS")
		return true
	for msg: String in failures:
		push_error("PHASE2_VERIFY FAIL: " + msg)
	return false


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

	var views := [
		{name = "headwaters", y = 55.0, sd = 24.0, lift = 18.0, look_dy = 105.0, look_sd = -6.0, look_lift = -4.0},
		{name = "valley_mid", y = float(w.H) * 0.44, sd = 42.0, lift = 28.0, look_dy = 135.0, look_sd = -14.0, look_lift = -6.0},
		{name = "river_bank", y = float(w.H) * 0.62, sd = axis.river_hw_at(int(w.H * 0.62)) + 2.2, lift = 5.2, look_dy = 75.0, look_sd = 0.0, look_lift = -0.8},
		{name = "finish_bend", y = float(w.H) - 108.0, sd = 22.0, lift = 18.0, look_dy = 98.0, look_sd = -28.0, look_lift = -2.0},
	]
	for v: Dictionary in views:
		var cx := (axis.axis_x_at(v.y) + float(v.sd) * float(axis.road_side) + 0.5) * T
		var cz := (float(v.y) + 0.5) * T
		var cy := h.ground_at(cx, cz) + float(v.lift)
		var ly := minf(float(w.H - 4), float(v.y) + float(v.look_dy))
		var lx := (axis.axis_x_at(ly) + float(v.look_sd) * float(axis.road_side) + 0.5) * T
		var lz := (ly + 0.5) * T
		var lgy := maxf(h.ground_at(lx, lz), axis.floor_h_at(int(ly)) * GameConfig.HS) + float(v.look_lift)
		var pos := Vector3(cx, cy, cz)
		var target := Vector3(lx, lgy, lz)
		gw.player.x = pos.x
		gw.player.z = pos.z
		gw.player.feet = h.ground_at(pos.x, pos.z)
		gw.stream_coordinator.force_terrain(pos, GameWorld.NEAR)
		if gw.outer != null:
			gw.outer.preload_around(pos.x, pos.z, OuterTerrain.RADIUS * 0.7)
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
		var roads: Array = w.trails.filter(func(t: Dictionary) -> bool: return t.kind == "road")
		if roads.size() != 1 or w.trails.size() != 1:
			failures.append("%s: expected single road trail, got roads=%d total=%d" % [seed_text, roads.size(), w.trails.size()])
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
			var sd := (cx - axis.axis_x_at(cy)) * float(axis.road_side)
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
		}
		rows.append(row)
		print("PHASE3_ROAD %-11s %s  %.2fkm  river=%.1f%% forest=%.1f%%  +%3.0fm/-%3.0fm  maxG=%.1f%%  bend=%.1f%% maxStr=%.0fm  anc=%s  trails=%.0fms total=%.0fms  sites=%s" % [
			row.seed, row.size, row.len_km, row.near_river_pct, row.deep_forest_pct,
			row.climb_m, row.descent_m, row.max_grade_pct, row.bend_pct, row.max_straight_m,
			row.anchors, row.trails_ms, row.total_ms, str(row.sites)])
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
	for t: Dictionary in w.trails:
		if t.kind != "road": continue
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
		gw.player.x = pos.x
		gw.player.z = pos.z
		gw.player.feet = h.ground_at(pos.x, pos.z)
		gw.stream_coordinator.force_terrain(pos, GameWorld.NEAR)
		if gw.outer != null:
			gw.outer.preload_around(pos.x, pos.z, OuterTerrain.RADIUS * 0.7)
		gw.stream_coordinator.force_vegetation(pos)
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

	for seed_text: String in ["Север-1234", "Туман-4821", "Янтарь-5150", "b2"]:
		var sz := WorldTemplate.plan_size(WorldTemplate.EXPEDITION_ID, WGRandom.hash_string(seed_text), false)
		var px := WorldLoader.px_for(maxi(sz.x, sz.y))
		var map_px := mini(2, px)
		if sz.x != 256 or sz.y > 4096 or sz.y % 64 != 0:
			failures.append("invalid full size for %s: %s" % [seed_text, sz])
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
		if w.W != 256 or w.H != 768 or w.template_id != WorldTemplate.EXPEDITION_ID:
			failures.append("unexpected Type 2 dimensions: %dx%d tpl=%s" % [w.W, w.H, w.template_id])
		if w.available_rect != Rect2i(0, 0, w.W, w.H):
			failures.append("available_rect is not full plan: %s" % w.available_rect)
		if not w.accessible(128.0, 20.0, 1.0) or not w.accessible(128.0, float(w.H) - 20.0, 1.0):
			failures.append("invisible wall inside Type 2 plan")
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
