extends RefCounted
## Изолированные сверки внутри единого check.gd -- --verify-landmarks.
## Не генерирует второй мир; реальные поля проверяются после измерения загрузки.


static func run(w: WorldData) -> Dictionary:
	var fast := Grid.fast_grid()
	if fast == null:
		return {ok = false, reason = "FastGrid недоступен"}
	var ok := true
	# Пустые/узкие карты, чистая вода/суша, равные острова, нечётный пролёт и цепочки островов.
	for dims: Vector2i in [Vector2i.ZERO, Vector2i(1, 1), Vector2i(1, 19), Vector2i(23, 1), Vector2i(37, 21), Vector2i(160, 32)]:
		for mode in 4:
			var wet := PackedByteArray()
			wet.resize(dims.x * dims.y)
			for i in wet.size():
				wet[i] = 0 if mode == 0 else (1 if mode == 1 else int((i % dims.x) % 31 >= (5 if mode == 2 else 15)))
			for span in [-1, 0, 1, 7, 30, 60]:
				var reference := Grid.bridge_region_reference(dims.x, dims.y, wet, span)
				ok = (reference == fast.BridgeRegion(dims.x, dims.y, wet, span)) and ok
	# Плато сохраняет все равные максимумы; порог сравнивается в double после чтения float32.
	for dims: Vector2i in [Vector2i.ZERO, Vector2i(7, 11), Vector2i(19, 23)]:
		var elev := PackedFloat32Array()
		var ocean := PackedByteArray()
		var lake := PackedByteArray()
		elev.resize(dims.x * dims.y)
		ocean.resize(elev.size())
		lake.resize(elev.size())
		for mode in 4:
			for i in elev.size():
				elev[i] = 0.45 if mode == 0 else (0.5 if mode == 1 else float((i * 17) % 37) / 36.0)
				ocean[i] = int(mode == 3 and i % 7 == 0)
				lake[i] = int(mode == 3 and i % 11 == 0)
			ok = (StageLandmarks.peak_candidates_reference(dims.x, dims.y, elev, ocean, lake) == fast.PeakCandidates(dims.x, dims.y, elev, ocean, lake)) and ok
	var density_seed := WGRandom.derive(w.seed_num, "settlement.density")
	for y in range(-100, 800, 31):
		for x in range(-100, 800, 29):
			ok = (StageLandmarks._settlement_density(w, x, y) == StageLandmarks.patches(x, y, 96.0, density_seed)) and ok
	var wet := PackedByteArray()
	wet.resize(w.N)
	var river := w.river_cells()
	for i in w.N:
		wet[i] = int(w.ocean[i] != 0 or w.lake[i] != 0 or river[i] != 0)
	var t := Time.get_ticks_usec()
	var region_ref := Grid.bridge_region_reference(w.W, w.H, wet, StageTrails.SPAN)
	var region_gd_ms := (Time.get_ticks_usec() - t) / 1000.0
	t = Time.get_ticks_usec()
	var region_fast: PackedByteArray = fast.BridgeRegion(w.W, w.H, wet, StageTrails.SPAN)
	var region_fast_ms := (Time.get_ticks_usec() - t) / 1000.0
	ok = (region_ref == region_fast) and ok
	t = Time.get_ticks_usec()
	var peaks_ref := StageLandmarks.peak_candidates_reference(w.W, w.H, w.elev, w.ocean, w.lake)
	var peaks_gd_ms := (Time.get_ticks_usec() - t) / 1000.0
	t = Time.get_ticks_usec()
	var peaks_fast: PackedInt32Array = fast.PeakCandidates(w.W, w.H, w.elev, w.ocean, w.lake)
	var peaks_fast_ms := (Time.get_ticks_usec() - t) / 1000.0
	ok = (peaks_ref == peaks_fast) and ok
	var result := {ok = ok, size = w.W, bridge_region_gd_ms = region_gd_ms, bridge_region_fast_ms = region_fast_ms,
		peaks_gd_ms = peaks_gd_ms, peaks_fast_ms = peaks_fast_ms, peak_candidates = peaks_ref.size()}
	print("LANDMARK PARITY ", JSON.stringify(result))
	return result
