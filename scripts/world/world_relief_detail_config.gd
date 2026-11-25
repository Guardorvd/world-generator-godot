extends Resource
## Настройки игрового слоя после генерации. Не участвуют в ключах кэша мира.
## Маска (где поле 2 м меняет высоты) — общая с эрозией генерации: WorldReliefGenerationConfig.
const MountainDetail := preload("res://scripts/world/mountain_detail.gd")

enum {
	RD_STEP_M, RD_BICUBIC, RD_CLAMP, RD_MAX_OFFSET_M, RD_TILE_BYTES,
	RD_FORMS, RD_FORM_GRADE_LIMIT, RD_FORM_GRADE_GAIN,
	RD_RILL, RD_RILL_ALONG, RD_RILL_ACROSS, RD_RILL_M, RD_RILL_COVER,
	RD_RILL_SLOPE_FROM, RD_RILL_SLOPE_TO, RD_RILL_CURVATURE_M, RD_RILL_RIM,
	RD_ROOT, RD_ROOT_ALONG, RD_ROOT_ACROSS, RD_ROOT_M, RD_ROOT_COVER, RD_ROOT_PAIR_M, RD_ROOT_PIT_SHARE,
	RD_TERRACE, RD_TERRACE_ALONG, RD_TERRACE_ACROSS, RD_TERRACE_M, RD_TERRACE_COVER,
	RD_TERRACE_SLOPE_FROM, RD_TERRACE_SLOPE_TO, RD_TERRACE_LIP_M,
	RD_FLOOD, RD_FLOOD_ALONG, RD_FLOOD_ACROSS, RD_FLOOD_M, RD_FLOOD_COVER,
	RD_FLOOD_NEAR_M, RD_FLOOD_FAR_M, RD_FLOOD_GRADE,
	RD_BANK, RD_BANK_ALONG, RD_BANK_ACROSS, RD_BANK_M, RD_BANK_COVER,
	RD_BANK_NEAR_M, RD_BANK_FAR_M, RD_BANK_LIP_M, RD_COUNT,
}

## Включает точную поверхность для этого типа мира.
@export var enabled := false

@export_group("Сетка и уровни")
## Шаг узлов в метрах. Должен быть половиной GameConfig.TILE для совпадения диагоналей.
@export var step_m := GameConfig.TILE * 0.5
## Дальность полной геометрии от игрока, м.
@export var full_m := 0.0
## Дальность совпадения точного меша с уровнем 4 м при высокой детализации, м.
@export var transition_end_m := 0.0
## Дальность совпадения с уровнем 4 м при обычной детализации, м. Ноль использует высокую дальность.
@export var ordinary_transition_end_m := 0.0
## Запас за концом перехода для включения чанка, м.
@export var enter_margin_m := 0.0
## Запас за концом перехода для выключения чанка, м.
@export var exit_margin_m := 0.0
## Размер одной порции меша вдоль оси, м. Кратен GameConfig.TILE.
@export var piece_m := 0.0
## Дополнительная дальность подготовки меша до включения, м.
@export var prefetch_m := 0.0

@export_group("Средние и дальние уровни")
## Включает плавную смену сеток 4, 8 и 16 м.
@export var lod_morph := false
## Дальность конца переходов 4→8 и 8→16, м. Одна для всех чанков: выбор по ошибке формы давал −1 % треугольников
## (замер этапа 2 части 2) и вырождается в ту же дальность, когда склоны изрезаны.
@export var lod_end_m := Vector2.ZERO
## Ширина каждого плавного перехода, м.
@export var lod_fade_m := Vector2.ZERO
## Переход к общему ребру соседних чанков, м от ребра.
@export var lod_edge_fade_m := Vector2.ZERO
## Запас за концом перехода для обратной подмены, м.
@export var lod_load_margin_m := 0.0
## Дополнительный гистерезис при удалении, м.
@export var lod_hysteresis_m := 0.0
## Длительность плавного восстановления, если поток опоздал к порогу, с.
@export var lod_recover_s := 0.0

@export_group("Восстановление")
## Восстанавливать промежуточные высоты бикубиком Catmull–Rom.
@export var bicubic := true
## Ограничивать высоту диапазоном четырёх углов исходного квадрата.
@export var clamp_bicubic := true
## Наибольшее отклонение поля 2 м от треугольника 4 м, м. Единственный предел высоты слоя: ограничивает и бикубик,
## и малые формы; это же расхождение опоры объектов с мешем в зоне морфинга и запас высоты мешей.
@export var max_offset_m := 0.0

@export_group("Малые формы")
## Добавлять природные формы в точное поле.
@export var forms_enabled := false
## Предельный уклон после добавления форм, м/м; уже более крутые грани сохраняют уклон.
@export var form_grade_limit := MountainDetail.DETAIL_LIMIT
## Допустимый прирост модуля градиента от форм, м/м.
@export var form_grade_gain := 0.0

@export_group("Промоины и рёбра")
## Шаг поиска мест для промоин, м.
@export var rill_spacing_m := 0.0
## Радиусы вдоль и поперёк падения, м.
@export var rill_radii_m := Vector2.ZERO
## Глубина промоины, м.
@export var rill_depth_m := 0.0
## Вероятность формы на подходящем участке, доля.
@export var rill_cover := 0.0
## Полоса уклонов, м/м.
@export var rill_slopes := Vector2.ZERO
## Масштаб перегиба в высотах клеток для усиления ложбин и ослабления гребней, м.
@export var rill_curvature_m := 0.0
## Высота рёбер у промоины относительно глубины, доля.
@export var rill_rim := 0.0

@export_group("Лесные кочки и вывалы")
## Шаг поиска мест для вывала, м.
@export var root_spacing_m := 0.0
## Радиусы каждой половины вывала, м.
@export var root_radii_m := Vector2.ZERO
## Высота кочки, м.
@export var root_height_m := 0.0
## Максимальная доля занятых мест в сомкнутом лесу.
@export var root_cover := 0.0
## Расстояние от центра ямы до центра кочки, м.
@export var root_pair_m := 0.0
## Глубина ямы относительно высоты кочки, доля.
@export var root_pit_share := 0.0

@export_group("Террасетки на открытых склонах")
## Шаг поиска террасеток, м.
@export var terrace_spacing_m := 0.0
## Радиусы вдоль и поперёк горизонтали склона, м.
@export var terrace_radii_m := Vector2.ZERO
## Высота уступа со стороны низкого склона, м.
@export var terrace_height_m := 0.0
## Вероятность формы на подходящем участке, доля.
@export var terrace_cover := 0.0
## Полоса уклонов, м/м.
@export var terrace_slopes := Vector2.ZERO
## Ширина плавного перегиба, м.
@export var terrace_lip_m := 0.0

@export_group("Ложбины поймы")
## Шаг поиска ложбин, м.
@export var flood_spacing_m := 0.0
## Радиусы вдоль и поперёк долины, м.
@export var flood_radii_m := Vector2.ZERO
## Глубина ложбины, м.
@export var flood_depth_m := 0.0
## Вероятность на ровной пойме, доля.
@export var flood_cover := 0.0
## Полоса расстояний от кромки реки, м.
@export var flood_shore_m := Vector2.ZERO
## Уклон, на котором ложбина исчезает, м/м.
@export var flood_grade := 0.0

@export_group("Береговые уступчики")
## Шаг поиска коротких уступчиков, м.
@export var bank_spacing_m := 0.0
## Радиусы вдоль и поперёк реки, м.
@export var bank_radii_m := Vector2.ZERO
## Высота короткого уступчика, м.
@export var bank_height_m := 0.0
## Вероятность формы на подходящем участке, доля.
@export var bank_cover := 0.0
## Полоса расстояний за защитной зоной воды, м.
@export var bank_shore_m := Vector2.ZERO
## Ширина плавного перегиба, м.
@export var bank_lip_m := 0.0

@export_group("Бюджет")
## Лимит Миб для плиток и маски высот.
@export var tile_mib := 0
## Лимит Миб для массивов точных мешей в общем LRU.
@export var mesh_mib := 0
## Разрешать точному уровню отбрасывать тени при высокой детализации.
@export var cast_shadows := true

const MIB := 1024 * 1024


func params() -> PackedFloat64Array:
	return PackedFloat64Array([
		step_m, float(bicubic), float(clamp_bicubic), maxf(0.0, max_offset_m), tile_mib * MIB,
		float(forms_enabled), form_grade_limit, form_grade_gain,
		rill_spacing_m, rill_radii_m.x, rill_radii_m.y, rill_depth_m, rill_cover,
		rill_slopes.x, rill_slopes.y, rill_curvature_m, rill_rim,
		root_spacing_m, root_radii_m.x, root_radii_m.y, root_height_m, root_cover, root_pair_m, root_pit_share,
		terrace_spacing_m, terrace_radii_m.x, terrace_radii_m.y, terrace_height_m, terrace_cover,
		terrace_slopes.x, terrace_slopes.y, terrace_lip_m,
		flood_spacing_m, flood_radii_m.x, flood_radii_m.y, flood_depth_m, flood_cover,
		flood_shore_m.x, flood_shore_m.y, flood_grade,
		bank_spacing_m, bank_radii_m.x, bank_radii_m.y, bank_height_m, bank_cover,
		bank_shore_m.x, bank_shore_m.y, bank_lip_m,
	])


func transition_end_for(high: bool) -> float:
	return transition_end_m if high or ordinary_transition_end_m == 0.0 else ordinary_transition_end_m


func activation_distance_m(high: bool) -> float:
	return transition_end_for(high) + enter_margin_m


func piece_cells() -> int:
	return roundi(piece_m / GameConfig.TILE)


func valid(chunk_cells: int) -> bool:
	if not is_finite(piece_m) or piece_m > chunk_cells * GameConfig.TILE:
		return false
	var cells := piece_cells()
	var ordinary_end := transition_end_for(false)
	return step_m * 2.0 == GameConfig.TILE and cells > 0 \
		and is_equal_approx(piece_m, cells * GameConfig.TILE) \
		and chunk_cells % cells == 0 and full_m > 0.0 and ordinary_end > full_m and ordinary_end <= transition_end_m \
		and is_finite(transition_end_m) and is_finite(exit_margin_m) and is_finite(prefetch_m) \
		and exit_margin_m >= enter_margin_m and enter_margin_m >= 0.0 and prefetch_m >= 0.0 \
		and tile_mib > 0 and mesh_mib > 0


func valid_lod(recheck_m: float) -> bool:
	return lod_end_m.is_finite() and lod_fade_m.is_finite() and lod_edge_fade_m.is_finite() \
		and is_finite(lod_load_margin_m) and is_finite(lod_hysteresis_m) and is_finite(lod_recover_s) \
		and lod_edge_fade_m.x >= transition_end_m and lod_edge_fade_m.y > lod_edge_fade_m.x \
		and lod_end_m.x - lod_fade_m.x >= maxf(lod_edge_fade_m.y, transition_end_m + exit_margin_m) \
		and lod_end_m.y - lod_fade_m.y >= lod_end_m.x + lod_load_margin_m + lod_hysteresis_m \
		and lod_fade_m.x > 0.0 and lod_fade_m.y > 0.0 \
		and lod_load_margin_m >= recheck_m and lod_hysteresis_m >= 0.0 and lod_recover_s > 0.0
