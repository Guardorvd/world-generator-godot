extends RefCounted
## Эрозия — последний шаг поверхности Типа 2 (docs/RELIEF_FINE_GEOMETRY_2.md, раздел 4.2).
## Место: конец Heightfield.finish_paths — после RockRelief, полотна дорог, сооружений и RoadRefinement, до снимка
## поверхности, мешей чанков и StageVegetation. Тот же вызов идёт и при генерации, и когда загрузчик заново собирает
## поверхность без кэша, поэтому результат один (детерминизм).
## Договор шага (этап 3):
## - меняет только hv и только там, где общая маска (ReliefMask, Heightfield.relief_mask_inputs) это разрешает:
##   дороги, вода, места, сооружения, скалы и край плана остаются до бита;
## - список изменённых клеток добавляется к результату finish_paths (меши чанков);
## - растительность выбирается по w.elev, w.slope, w.moist, а не по hv: их нужно обновить на изменение высот
##   (w.slope из нового поля только там, где высоты сдвинулись; влажность стока вливается в w.moist).
## До этапа 3 алгоритма нет, шаг пустой: hv и кэш побайтно прежние.

## Стенды отключают шаг, чтобы хранить поле до эрозии и прогонять её сами (relief_fine_fixture.gd).
static var allowed := true


static func run(h: Heightfield) -> PackedInt32Array:
	var cfg := WorldTemplate.config(h.world.template_id).relief_generation
	if not allowed or cfg == null or not cfg.erosion_enabled:
		return PackedInt32Array()
	push_warning("ReliefErosion: эрозия включена, но алгоритма ещё нет (этап 3 плана части 2)")
	return PackedInt32Array()
