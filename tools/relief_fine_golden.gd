extends SceneTree
## Эталон плиток и инварианты поля 2 м на сохранённых планах. --save обновляет хеши после изменения формы.

const Fixture := preload("res://tools/relief_fine_fixture.gd")
const Metrics := preload("res://tools/relief_fine_metrics.gd")
const LodChecks := preload("res://tools/relief_fine_lod_checks.gd")
const Profile := preload("res://scripts/world/world_relief_detail_config.gd")
const Source := preload("res://scripts/render/chunk_source.gd")
const GOLDEN := "res://tools/control/baseline/relief_fine.json"
const TILE := GameConfig.TILE
const CELLS := PlanTerrain.CELLS
var _fails := 0


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 45)
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	if not ok:
		_fails += 1
		printerr("RELIEF_FAIL ", message)


func _run() -> void:
	var cfg := WorldTemplate.config(WorldTemplate.EXPEDITION_ID).relief_detail
	var p := cfg.params()
	_check(p.size() == Profile.RD_COUNT and p[Profile.RD_STEP_M] == cfg.step_m and p[Profile.RD_TILE_BYTES] == cfg.tile_mib * Profile.MIB,
		"контракт массива настроек")
	var old_profile := WorldTemplate.config(WorldTemplate.DEFAULT_ID).relief_detail
	_check(old_profile == null or not old_profile.enabled, "точное поле выключено у Типа 1")
	var hashes := {}
	for seed: String in Fixture.SEEDS:
		var fixture := Fixture.restore(seed)
		if fixture.is_empty():
			_check(false, "нет фикстуры: " + seed)
			continue
		hashes[seed] = _inspect(fixture)
	_check_profile_toggle(cfg)
	_check_form_groups(cfg)
	if "--save" in OS.get_cmdline_user_args():
		if _fails == 0:
			var file := FileAccess.open(GOLDEN, FileAccess.WRITE)
			_check(file != null, "запись эталона")
			if file != null:
				file.store_string(JSON.stringify(hashes, "\t") + "\n")
	else:
		_check(FileAccess.file_exists(GOLDEN) and JSON.parse_string(FileAccess.get_file_as_string(GOLDEN)) == hashes, "хеши плиток совпадают с эталоном")
	print("RELIEF_GOLDEN failures=", _fails)
	quit(int(_fails > 0))


func _check_profile_toggle(cfg: Profile) -> void:
	var fixture := Fixture.restore(Fixture.SEEDS[0])
	if fixture.is_empty():
		return
	var h: Heightfield = fixture.heights
	var eye: Vector3 = fixture.views[0].eye
	var cell := Vector2i(floori(eye.x / TILE), floori(eye.z / TILE))
	var key := cell / CELLS
	h.prepare_fine_relief()
	if h.fine_relief == null:
		_check(false, "ресурс включён, но точное поле не построилось")
		return
	var original: String = h.fine_relief.TileHash(key.x, key.y)
	h.fine_relief = null
	var bicubic := cfg.bicubic
	cfg.bicubic = not bicubic
	h.prepare_fine_relief()
	cfg.bicubic = bicubic
	_check(h.fine_relief != null and original != h.fine_relief.TileHash(key.x, key.y), "настройка восстановления меняет поле")


func _check_form_groups(cfg: Profile) -> void:
	var fixture := Fixture.restore(Fixture.SEEDS[0])
	if fixture.is_empty():
		return
	var h: Heightfield = fixture.heights
	var w: WorldData = fixture.world
	var biome := w.biome.duplicate()
	h.prepare_fine_relief()
	if h.fine_relief == null:
		return
	var original := {}
	var columns := ceili(float(w.W - 1) / CELLS)
	var rows := ceili(float(w.H - 1) / CELLS)
	h.fine_relief.Warm(PackedVector2Array([Vector2.ZERO]), INF)
	for z in rows:
		for x in columns:
			original[Vector2i(x, z)] = h.fine_relief.TileHash(x, z)
	for field: StringName in [&"rill_cover", &"root_cover", &"terrace_cover", &"flood_cover", &"bank_cover",
			&"knoll_cover", &"hollow_cover", &"gully_cover"]:
		h.fine_relief = null
		var cover: float = cfg.get(field)
		cfg.set(field, 0.0)
		h.prepare_fine_relief()
		cfg.set(field, cover)
		var changed := false
		if h.fine_relief != null:
			for key: Vector2i in original:
				if original[key] != h.fine_relief.TileHash(key.x, key.y):
					changed = true
					break
		_check(changed, "%s проявляется на сохранённом мире" % field)
	_check(w.biome == biome, "маска форм сохраняет исходные биомы")


func _inspect(fixture: Dictionary) -> Dictionary:
	var h: Heightfield = fixture.heights
	var w: WorldData = fixture.world
	var baseline := h.ride_snapshot()
	var original_hv := h.hv.duplicate()
	var original_water := var_to_bytes(WaterBuilder.prepare(w, h))
	h.prepare_fine_relief(false)
	var smooth_field := h.fine_relief
	var smooth := h.ride_snapshot(true)
	h.fine_relief = null
	var started := Time.get_ticks_usec()
	h.prepare_fine_relief()
	var prepare_ms := (Time.get_ticks_usec() - started) / 1000.0
	var detail := h.fine_relief
	_check(detail != null and baseline != null and smooth_field != null and smooth != null, "нативное поле и исходная опора " + w.seed_text)
	if detail == null or baseline == null or smooth_field == null or smooth == null:
		return {}
	var phases := {}
	var chunks := TerrainBuilder.build_chunks(w, h)
	var source := Source.new()
	source.setup(WorldCache.new(), w, h, w.W, [chunks.duplicate(), {}, {}], null)
	var on := h.ride_snapshot()
	var planted := h.ride_snapshot(true)
	var sample: Vector3 = fixture.views[0].eye
	var morph := LodChecks.inspect(detail, source, w, Vector2(sample.x, sample.z))
	_check(h.fine_lod and morph.samples > 0 and morph.height_failures == 0 and morph.normal_failures == 0 \
		and morph.seam_failures == 0 and morph.missing == 0, "совпадение концов морфинга 4/8/16 м и общих рёбер")
	print("RELIEF_LOD ", w.seed_text, " ", JSON.stringify(morph))
	var budget := LodChecks.budget(h, chunks, fixture.route)
	_check(budget.samples > 0 and budget.switches > 0 and budget.new_peak <= budget.old_peak,
		"пиковое число треугольников сеток 4/8/16 м на маршруте")
	print("RELIEF_LOD_BUDGET ", w.seed_text, " ", JSON.stringify(budget))
	_check(h.fine_medium, "поле 4 м со средними формами включено")
	var projected := {}
	var coarse_samples := 0
	var coarse_changed := 0
	var coarse_max := 0.0
	var lod_failures := 0
	for view: Dictionary in fixture.views:
		var eye: Vector3 = view.eye
		var focus: Vector2 = view.focus
		var pieces := []
		for key: Vector2i in chunks:
			if not Metrics.near_view(key, Vector2(eye.x, eye.z), focus):
				continue
			if not projected.has(key):
				var raw := var_to_bytes(chunks[key])
				var arrays := source.read(-1, key)
				_check(raw == var_to_bytes(chunks[key]), "проекция сохраняет исходные массивы чанка")
				projected[key] = arrays
				var before: PackedVector3Array = chunks[key][Mesh.ARRAY_VERTEX]
				var after: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				for i in after.size():
					var d := absf(after[i].y - before[i].y)
					coarse_changed += int(d > Metrics.TOLERANCE_M)
					coarse_max = maxf(coarse_max, d)
				for step: int in [PlanTerrain.LOD1_STEP, PlanTerrain.LOD2_STEP]:
					var lod: Array = detail.BuildCoarseLod(key.x, key.y, step, step * TILE * 0.5)
					lod_failures += _check_lod_nodes(detail, lod, w, key, step)
			pieces.append(projected[key])
		var coarse_stats := Metrics.mesh_stats(pieces, h, eye, focus, true)
		coarse_samples += coarse_stats.parity_samples
		_check(coarse_stats.parity_samples > 0 and coarse_stats.parity_failed == 0, "опора и меш 4 м до включения 2 м: " + w.seed_text)
	_check(coarse_changed > 0 and coarse_max <= h.fine_profile.mid_delta_m + Metrics.TOLERANCE_M and lod_failures == 0, "поле C передаётся всем трём грубым уровням")
	var origin := Vector2(sample.x, sample.z)
	var first_key := Vector2i(((origin - Vector2.ONE * TILE * 0.5) / PlanTerrain.SIDE).floor())
	if projected.has(first_key):
		source.prewarm([origin], 0.0)
		var expected := var_to_bytes(projected[first_key])
		_check(var_to_bytes(source.ready(-1, first_key)) == expected, "в загрузке подготовлен именно меш C")
		source.finish_startup()
		_check(var_to_bytes(source.ready(-1, first_key)) == expected, "завершение загрузки сохраняет меш C в ОЗУ")
		_check(var_to_bytes(source.read(-1, first_key)) == expected, "повторная сборка из исходных данных даёт тот же меш C")
	var medium_heights := PackedFloat32Array()
	medium_heights.resize(w.W * w.H)
	var edge_violations := 0
	for z in w.H:
		for x in w.W:
			var k := z * w.W + x
			medium_heights[k] = detail.CoarseNode(x, z)
			var edge := mini(mini(x, w.W - 1 - x), mini(z, w.H - 1 - z))
			if edge * TILE <= h.fine_profile.edge_guard_m:
				edge_violations += int(medium_heights[k] != original_hv[k])
	_check(edge_violations == 0, "C сохраняет высоты у стыка с OuterLand")
	var medium_grade_violations := _medium_grade_failures(w, original_hv, medium_heights, h.fine_profile)
	_check(medium_grade_violations == 0, "C соблюдает предел уклона на треугольниках 4 м")
	print("RELIEF_MEDIUM ", w.seed_text, " parity_samples=", coarse_samples, " shifted=", coarse_changed,
		" max_delta_m=", coarse_max, " lod_failures=", lod_failures, " edge_failures=", edge_violations,
		" grade_failures=", medium_grade_violations)
	started = Time.get_ticks_usec()
	detail.Warm(PackedVector2Array([Vector2(sample.x, sample.z)]), INF)
	var tiles_ms := (Time.get_ticks_usec() - started) / 1000.0
	for key: Vector2i in chunks:
		detail.SetActive(key.x, key.y, true)
	_check(original_hv == h.hv and original_water == var_to_bytes(WaterBuilder.prepare(w, h)), "исходные высоты и меши воды совпадают побитно")
	var protected := {}
	for key: int in h.road_refinement.patches:
		var x := key % w.W
		var z := key / w.W
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				if x + dx >= 0 and x + dx < w.W - 1 and z + dz >= 0 and z + dz < w.H - 1:
					protected[(z + dz) * w.W + x + dx] = true
	for water: PackedByteArray in [w.river_cells(), w.lake]:
		for key in water.size():
			if water[key] != 0 and key % w.W < w.W - 1 and key / w.W < w.H - 1:
				protected[key] = true
	for key: int in h._cells:
		if key % w.W < w.W - 1 and key / w.W < w.H - 1:
			protected[key] = true
	for place in w.settlements + w.sites:
		var cell := Vector2i(floori(place.x), floori(place.y))
		if cell.x >= 0 and cell.y >= 0 and cell.x < w.W - 1 and cell.y < w.H - 1:
			protected[cell.y * w.W + cell.x] = true
	var protected_bad := 0
	for key: int in protected:
		var x := (key % w.W + 0.75) * TILE
		var z := (key / w.W + 1.125) * TILE
		var y: float = baseline.Ground(x, z)
		protected_bad += int(is_nan(y) or y != on.Ground(x, z) or y != h.ground_at(x, z) or y != planted.Ground(x, z))
	_check(protected_bad == 0, "%s: %d нарушений защитной маски" % [w.seed_text, protected_bad])
	var meshes := {}
	for i in fixture.views.size():
		var view: Dictionary = fixture.views[i]
		var eye: Vector3 = view.eye
		var focus: Vector2 = view.focus
		var pieces := []
		for key: Vector2i in chunks:
			if not Metrics.near_view(key, Vector2(eye.x, eye.z), focus):
				continue
			if not meshes.has(key):
				phases[str(key)] = detail.TileHash(key.x, key.y)
				meshes[key] = detail.BuildMeshes(key.x, key.y, roundi(h.fine_profile.piece_m / TILE), projected[key])
			pieces.append_array(meshes[key])
		var stats := Metrics.mesh_stats(pieces, h, eye, focus, true)
		_check(stats.parity_samples > 0 and stats.parity_failed == 0, "%s %d: физика и меш (%d ошибок)" %
			[w.seed_text, i, stats.parity_failed])
	var changed := 0
	var morph_errors := 0
	var max_delta := 0.0
	var grade_violations := 0
	var max_grade_gain := 0.0
	var max_coarse_gain := 0.0
	var new_vertices := 0
	var max_extra_height := 0.0
	var profile := h.fine_profile
	var border_heights := {}
	var seam_violations := 0
	for parts: Array in meshes.values():
		for arrays: Array in parts:
			var xyz: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			var targets: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM0]
			var stage_one := PackedFloat32Array()
			stage_one.resize(xyz.size())
			for j in xyz.size():
				var delta := absf(xyz[j].y - targets[j * 4])
				max_delta = maxf(max_delta, delta)
				changed += int(delta > Metrics.TOLERANCE_M)
				var point := xyz[j]
				var local := Vector2i(roundi(point.x - TILE * 0.5), roundi(point.z - TILE * 0.5))
				if local.x % int(PlanTerrain.SIDE) == 0 or local.y % int(PlanTerrain.SIDE) == 0:
					seam_violations += int(absf(border_heights.get(local, point.y) - point.y) > Metrics.TOLERANCE_M)
					border_heights[local] = point.y
				var stage_one_y: float = smooth.Ground(point.x, point.z)
				if is_nan(stage_one_y):
					stage_one_y = targets[j * 4]
				stage_one[j] = stage_one_y
				var extra := absf(point.y - stage_one_y)
				max_extra_height = maxf(max_extra_height, extra)
				new_vertices += int(extra > Metrics.TOLERANCE_M)
			for j in range(0, indices.size(), 3):
				var a := indices[j]
				var b := indices[j + 1]
				var c := indices[j + 2]
				var x := (float(xyz[a].x) + xyz[b].x + xyz[c].x) / 3.0
				var z := (float(xyz[a].z) + xyz[b].z + xyz[c].z) / 3.0
				var y := (targets[a * 4] + targets[b * 4] + targets[c * 4]) / 3.0
				var cell_id := floori(z / TILE - 0.5) * w.W + floori(x / TILE - 0.5)
				var target_y: float = baseline.Ground(x, z) if h.road_refinement.patches.has(cell_id) else detail.SampleCoarse(x, z)
				morph_errors += int(is_nan(target_y) or absf(target_y - y) > Metrics.TOLERANCE_M)
				var ab := xyz[b] - xyz[a]
				var ac := xyz[c] - xyz[a]
				var grade := Metrics.grade(ab.cross(ac))
				ab.y = targets[b * 4] - targets[a * 4]
				ac.y = targets[c * 4] - targets[a * 4]
				max_coarse_gain = maxf(max_coarse_gain, grade - Metrics.grade(ab.cross(ac)))
				ab.y = stage_one[b] - stage_one[a]
				ac.y = stage_one[c] - stage_one[a]
				var old_grade := Metrics.grade(ab.cross(ac))
				max_grade_gain = maxf(max_grade_gain, grade - old_grade)
				# Float32 quantisation of heights in both meshes.
				if grade > minf(maxf(profile.form_grade_limit, old_grade), old_grade + profile.form_grade_gain) + 0.001:
					grade_violations += 1
	_check(changed > 0 and morph_errors == 0, "%s: %d изменённых вершин, %d расхождений морфинга" %
		[w.seed_text, changed, morph_errors])
	_check(max_delta <= maxf(profile.reconstruction_delta_m, profile.total_delta_m) + Metrics.TOLERANCE_M, "предел смещения от треугольника 4 м")
	_check(grade_violations == 0 and new_vertices > 0, "%s: %d нарушений предела уклона, %d новых вершин" % [w.seed_text, grade_violations, new_vertices])
	_check(seam_violations == 0, "%s: %d расхождений на границах плиток" % [w.seed_text, seam_violations])
	print("RELIEF_TILES ", w.seed_text, " init_ms=", prepare_ms, " build_ms=", tiles_ms, " bytes=", detail.Bytes(),
		" protected=", protected.size(), " changed=", changed, " morph_errors=", morph_errors, " max_delta_m=", max_delta)
	print("RELIEF_FORMS ", w.seed_text, " new_vertices=", new_vertices, " max_extra_height_m=", max_extra_height,
		" grade_gain_smooth=", max_grade_gain, " grade_gain_coarse=", max_coarse_gain, " grade_failures=", grade_violations,
		" seam_failures=", seam_violations)
	source.close()
	return phases


func _medium_grade_failures(w: WorldData, base: PackedFloat32Array, medium: PackedFloat32Array, profile: Resource) -> int:
	var failures := 0
	for z in w.H - 1:
		for x in w.W - 1:
			var a := z * w.W + x
			var b := a + 1
			var c := a + w.W
			var d := c + 1
			if base[a] == medium[a] and base[b] == medium[b] and base[c] == medium[c] and base[d] == medium[d]:
				continue
			var grade_a := Vector2(base[b] - base[a], base[c] - base[a]).length() / TILE
			var grade_d := Vector2(base[c] - base[d], base[b] - base[d]).length() / TILE
			var result_a := Vector2(medium[b] - medium[a], medium[c] - medium[a]).length() / TILE
			var result_d := Vector2(medium[c] - medium[d], medium[b] - medium[d]).length() / TILE
			failures += int(result_a > minf(maxf(profile.form_grade_limit, grade_a), grade_a + profile.mid_grade_gain) + 0.001)
			failures += int(result_d > minf(maxf(profile.form_grade_limit, grade_d), grade_d + profile.mid_grade_gain) + 0.001)
	return failures


func _check_lod_nodes(detail: Object, arrays: Array, w: WorldData, key: Vector2i, step: int) -> int:
	if arrays.is_empty():
		return 1
	var cols := ceili(float(mini(CELLS, w.W - 1 - key.x * CELLS)) / step) + 1
	var rows := ceili(float(mini(CELLS, w.H - 1 - key.y * CELLS)) / step) + 1
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var failures := 0
	for i in cols * rows:
		var p := vertices[i]
		failures += int(p.y != detail.CoarseNode(floori(p.x / TILE), floori(p.z / TILE)))
	return failures
