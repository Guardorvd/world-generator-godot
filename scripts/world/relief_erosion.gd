extends RefCounted
## Эрозия — последний шаг поверхности Типа 2 (docs/RELIEF_FINE_GEOMETRY_2.md, раздел 4.2; алгоритм —
## TerrainErosion в scripts/core/FineRelief.Erosion.cs, числа — WorldReliefGenerationConfig).
## Место: конец Heightfield.finish_paths — после RockRelief, полотна дорог, сооружений и RoadRefinement, до снимка
## поверхности, мешей чанков и StageVegetation. Тот же вызов идёт и при генерации, и когда загрузчик заново собирает
## поверхность без кэша, поэтому вход должен быть одинаковым на обоих путях: маска без объектов плана (камней) —
## при генерации их ещё нет.
## Договор шага:
## - меняет только hv и только в пределах общей маски (ReliefMask): дороги, вода, места, сооружения, скалы и край
##   плана остаются до бита, переход к ним — по уклону перехода;
## - карты стока h.relief_flow (area, deposit, wet — байтами) попадают в артефакт surface вместе с hv;
## - h.erosion_delta (изменение высот, м) живёт до растительности: StageVegetation.fields поправляет по нему
##   w.elev/w.slope и вливает влажность стока в w.moist в своих копиях полей, сам мир не меняется.

## Стенды отключают шаг, чтобы хранить поле до эрозии и прогонять её сами (relief_fine_fixture.gd).
static var allowed := true


static func run(h: Heightfield) -> PackedInt32Array:
	var cfg := WorldTemplate.config(h.world.template_id).relief_generation
	if not allowed or cfg == null or not cfg.erosion_enabled:
		return PackedInt32Array()
	var fast := Grid.fast_grid()
	if fast == null or not cfg.valid() or not cfg.valid_erosion():
		push_error("ReliefErosion: нет C# или настройки эрозии некорректны — поверхность без эрозии")
		return PackedInt32Array()
	var started := Time.get_ticks_usec()
	var inputs := h.relief_mask_inputs(false)
	inputs.erosion_seed = int(WorldGenerator.noise_rng(h.world.seed_num, "relief_erosion").next_float() * (WGRandom.MASK + 1))
	inputs.origin = h.world.world_origin
	var out: Variant = fast.ErodeRelief(inputs, cfg.mask_params(), cfg.erosion_params())
	if not out is Dictionary or not out.has("hv"):
		push_error("ReliefErosion: C# не вернул поле — поверхность без эрозии")
		return PackedInt32Array()
	h.hv = out.hv
	h.relief_flow = {area = out.area, deposit = out.deposit, wet = out.wet}
	h.erosion_delta = out.delta
	h.erosion_allowed = out.allowed
	h.path_timings.erosion_native_ms = (Time.get_ticks_usec() - started) / 1000.0
	h.path_timings.erosion_phase_ms = out.get("phase_ms", PackedFloat64Array())
	h.path_timings.erosion_sinks = out.get("sinks", 0)
	h.path_timings.erosion_max_area_m2 = out.get("max_area_m2", 0.0)
	return out.changed
