extends Resource
## Настройки игрового слоя после генерации. Не участвуют в ключах кэша мира.
## Маска (где поле 2 м меняет высоты) — общая с эрозией генерации: WorldReliefGenerationConfig.
const MountainDetail := preload("res://scripts/world/mountain_detail.gd")

enum {
	RD_STEP_M, RD_BICUBIC, RD_CLAMP, RD_MAX_OFFSET_M, RD_TILE_BYTES,
	RD_FORMS, RD_FORM_GRADE_LIMIT, RD_FORM_GRADE_GAIN,
	RD_RILL_SPACING, RD_RILL_LENGTH, RD_RILL_STEP, RD_RILL_ACROSS, RD_RILL_WIDEN,
	RD_RILL_DEPTH, RD_RILL_MIN_SHARE, RD_RILL_COVER, RD_RILL_SLOPE_FROM, RD_RILL_SLOPE_FULL,
	RD_RILL_AREA_FROM, RD_RILL_AREA_TO, RD_RILL_RIM, RD_RILL_MERGE_SHARE,
	RD_RILL_THALWEG_M, RD_RILL_THALWEG_AREA, RD_RILL_THALWEG_RIDGE_OCT,
	RD_SWALE_SPACING, RD_SWALE_ALONG, RD_SWALE_ACROSS, RD_SWALE_DEPTH, RD_SWALE_COVER,
	RD_SWALE_WET_FROM, RD_SWALE_WET_TO, RD_SWALE_DEPOSIT_FROM, RD_SWALE_DEPOSIT_TO,
	RD_SWALE_GRADE, RD_SWALE_FLOW_GRADE,
	RD_HUMMOCK_SPACING, RD_HUMMOCK_RADIUS, RD_HUMMOCK_HEIGHT, RD_HUMMOCK_COVER,
	RD_FOREST_HUMMOCK_SPACING, RD_FOREST_HUMMOCK_RADIUS, RD_FOREST_HUMMOCK_HEIGHT, RD_FOREST_HUMMOCK_COVER,
	RD_WINDTHROW_SPACING, RD_WINDTHROW_ALONG, RD_WINDTHROW_ACROSS, RD_WINDTHROW_HEIGHT,
	RD_WINDTHROW_COVER, RD_WINDTHROW_PAIR_M, RD_WINDTHROW_PIT_SHARE, RD_WINDTHROW_MAX_GRADE,
	RD_COUNT,
}

## Включает точную поверхность для этого типа мира.
@export var enabled := false

@export_group("Сетка и уровни")
## Шаг узлов в метрах. Должен быть половиной GameConfig.TILE для совпадения диагоналей.
@export var step_m := GameConfig.TILE * 0.5
## Дальность полной геометрии от игрока, м.
@export var full_m := 0.0
## Дальность совпадения точного меша с уровнем 4 м, м.
@export var transition_end_m := 0.0
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

@export_group("Промоины и рёбрышки по стоку")
## Шаг сетки истоков промоин, м.
@export var rill_spacing_m := 0.0
## Наибольшая длина трассы промоины вниз по склону, м.
@export var rill_length_m := 0.0
## Длина одного шага трассировки промоины по градиенту, м.
@export var rill_step_m := 0.0
## Начальная полуширина промоины поперёк стока, м.
@export var rill_across_m := 0.0
## Относительное расширение промоины вниз по водосбору, доля.
@export var rill_widen := 0.0
## Наибольшая глубина промоины при полном водосборе, м.
@export var rill_depth_m := 0.0
## Доля глубины у истока относительно наибольшей глубины, доля.
@export var rill_min_share := 0.0
## Вероятность промоины на подходящем истоке, доля.
@export var rill_cover := 0.0
## Уклоны начала и полного проявления промоин, м/м.
@export var rill_slopes := Vector2.ZERO
## Водосборы начала усиления и полной глубины промоин, м².
@export var rill_area_m2 := Vector2.ZERO
## Высота боковых рёбрышек у промоины относительно её глубины, доля.
@export var rill_rim := 0.0
## Запас углубления при слиянии промоин сверх rill_depth_m, доля.
@export var rill_merge_share := 0.0
## Глубина непрерывной промоины по осям стока, м.
@export var rill_thalweg_m := 0.0
## Наименьший водосбор для непрерывной оси стока, м².
@export var rill_thalweg_area_m2 := 0.0
## Превышение водосбора над соседями поперёк склона для полной глубины оси, октав.
@export var rill_thalweg_ridge_oct := 0.0

@export_group("Кочки и ложбинки по влажности и наносам")
## Шаг поиска сырых и наносных ложбинок, м.
@export var swale_spacing_m := 0.0
## Полуоси ложбинки вдоль и поперёк направления стока, м.
@export var swale_radii_m := Vector2.ZERO
## Глубина ложбинки, м.
@export var swale_depth_m := 0.0
## Вероятность ложбинки на подходящем участке, доля.
@export var swale_cover := 0.0
## Влажность W начала и полного проявления ложбинок и кочек, доля.
@export var swale_wet := Vector2.ZERO
## Толщина наносов D начала и полного проявления ложбинок и кочек, м.
@export var swale_deposit_m := Vector2.ZERO
## Уклон, на котором ложбинки и кочки поймы затухают, м/м.
@export var swale_grade := 0.0
## Уклон перехода ориентации ложбинки от оси реки к падению склона, м/м.
@export var swale_flow_grade := 0.0
## Шаг поиска сырых и наносных кочек, м.
@export var hummock_spacing_m := 0.0
## Радиус сырой или наносной кочки, м.
@export var hummock_radius_m := 0.0
## Высота сырой или наносной кочки, м.
@export var hummock_height_m := 0.0
## Вероятность кочки на сыром или наносном участке, доля.
@export var hummock_cover := 0.0

@export_group("Лесные кочки и вывалы")
## Шаг поиска обычных лесных кочек, м.
@export var forest_hummock_spacing_m := 0.0
## Радиус обычной лесной кочки, м.
@export var forest_hummock_radius_m := 0.0
## Высота обычной лесной кочки, м.
@export var forest_hummock_height_m := 0.0
## Наибольшая доля обычных кочек в сомкнутом лесу.
@export var forest_hummock_cover := 0.0
## Шаг сетки поиска пар «яма–бугор» вывала, м.
@export var windthrow_spacing_m := 0.0
## Радиусы бугра и ямы вывала вдоль и поперёк оси падения дерева, м.
@export var windthrow_radii_m := Vector2.ZERO
## Высота бугра вывала, м.
@export var windthrow_height_m := 0.0
## Наибольшая доля вывалов в сомкнутом лесу.
@export var windthrow_cover := 0.0
## Расстояние между центрами ямы и бугра вывала, м.
@export var windthrow_pair_m := 0.0
## Глубина ямы вывала относительно высоты бугра, доля.
@export var windthrow_pit_share := 0.0
## Наибольший уклон склона для размещения вывала, м/м.
@export var windthrow_max_grade := 0.0

@export_group("Затенение впадин")
## Свет неба (AO рельефа) во впадинах: насколько клетка ниже средней высоты окрестности. Общее для обоих типов мира;
## значения по умолчанию — прежние числа TerrainBuilder.cavity_image (16.11.2026), Тип 1 их и получает.
## Окрестности — среднее по блокам 2^n клеток: ближняя (~16 м — ложбины, промоины) и дальняя (~64 м — днища долин).
@export var cavity_blur_levels := Vector2i(2, 4)
## Числа отдельными float, а не Vector2: Vector2 хранит float32, и карта Типа 1 разошлась бы с прежней в байте.
## Наибольшее ослабление света неба в мелких ложбинах, доля.
@export var cavity_near_occlusion := 0.18
## Наибольшее ослабление света неба в днищах долин, доля.
@export var cavity_far_occlusion := 0.12
## Глубина ниже средней ближней окрестности, с которой ложбина начинает темнеть, м.
@export var cavity_near_from_m := 0.3
## Глубина ниже средней ближней окрестности, на которой ложбина темнеет полностью, м. Та же глубина над средним —
## полное ребро (материал по стоку, выпуклость подлеска).
@export var cavity_near_full_m := 1.6
## То же для дальней окрестности (днища долин): начало и полное затенение, м.
@export var cavity_far_from_m := 0.6
@export var cavity_far_full_m := 6.0

@export_group("Материал по стоку")
## Земля по процессам эрозии (часть 2 плана рельефа, этап 5): цвет грунта по картам стока relief_flow. Выключено —
## шейдер получает нули и рисует как раньше (Тип 1). Влажность W входит сюда не отдельно, а через влажность мира
## (relief_generation.wet_moist_gain → Heightfield.ground_moisture → подстилка forest_tex.b).
@export var flow_material := false
## Водосбор, с которого дно лощины начинает и полностью становится промытым (галька, песок), м².
@export var bed_area_m2 := Vector2.ZERO
## Толщина наноса, с которой грунт начинает и полностью становится сырым наносом, м.
@export var deposit_m := Vector2.ZERO
## Доля гальки и щебня на полностью промытом дне, 0..1 (как каменистый участок: вблизи камешки, вдали тон).
@export var bed_stones := 0.0
## Насколько полностью промытое дно берёт тон bed_color, 0..1: так лощина читается цветом и вдали.
@export var bed_tone := 0.0
## Тон промытого грунта дна лощины (светлый песок с галькой).
@export var bed_color := Color.BLACK
## Прибавка влажности грунта на полном наносе, доля шкалы влажности: темнее, сочнее, мох в подстилке.
@export var deposit_wet := 0.0
## Убавка влажности грунта на полном ребре, доля: светлее и суше. Ребро — выше среднего ближней окрестности
## затенения впадин на cavity_near_full_m (та же величина, что ложбина затенения, с другим знаком).
@export var ridge_dry := 0.0
## Лёгкое высветление выпуклых рёбер по карте положения в рельефе (relief_maps.a), доля.
@export_range(0.0, 0.25, 0.01) var ridge_brighten := 0.0
## Доля влияния затенения впадин (cavity_tex.r) на прямой свет солнца (AO_LIGHT_AFFECT).
@export_range(0.0, 0.5, 0.01) var cavity_light_affect := 0.0

@export_group("Материал поверхности")
## Дифференцированная шероховатость и смешивание слоёв по высоте (Тип 2); false — прежняя формула.
@export var material_roughness_enabled := false
@export_range(0.55, 1.0, 0.01) var rough_turf := 0.94
@export_range(0.55, 1.0, 0.01) var rough_soil := 0.86
@export_range(0.55, 1.0, 0.01) var rough_rock := 0.78
@export_range(0.55, 1.0, 0.01) var rough_wet := 0.58
@export_range(0.0, 0.8, 0.01) var spec_dry := 0.28
@export_range(0.0, 0.8, 0.01) var spec_wet := 0.48
## Глубина окна height blending на границах мха, камней, проплешин и скалы (0 — линейное смешивание).
@export_range(0.0, 0.6, 0.01) var height_blend_depth := 0.0
## Дальняя карта нормалей (м): от начала до конца перехода; нули — выкл (Тип 1).
@export var far_normal_range := Vector2.ZERO
## Масштабы процедурных средне-дальних нормалей (м), основной и повёрнутый на 90°.
@export var mid_normal_scales := Vector2(17.0, 47.0)
## Диапазон проявления средне-дальних нормалей (м): вход и затухание.
@export var mid_normal_range := Vector2(45.0, 420.0)
## Сила средне-дальних нормалей рельефа (0 — выкл, Тип 1).
@export_range(0.0, 1.0, 0.01) var mid_normal_strength := 0.0

@export_group("Бюджет")
## Лимит Миб для плиток, карт стока и маски высот.
@export var tile_mib := 0
## Лимит Миб для массивов точных мешей в общем LRU.
@export var mesh_mib := 0

const MIB := 1024 * 1024


func params() -> PackedFloat64Array:
	return PackedFloat64Array([
		step_m, float(bicubic), float(clamp_bicubic), maxf(0.0, max_offset_m), tile_mib * MIB,
		float(forms_enabled), form_grade_limit, form_grade_gain,
		rill_spacing_m, rill_length_m, rill_step_m, rill_across_m, rill_widen,
		rill_depth_m, rill_min_share, rill_cover, rill_slopes.x, rill_slopes.y,
		rill_area_m2.x, rill_area_m2.y, rill_rim, rill_merge_share,
		rill_thalweg_m, rill_thalweg_area_m2, rill_thalweg_ridge_oct,
		swale_spacing_m, swale_radii_m.x, swale_radii_m.y, swale_depth_m, swale_cover,
		swale_wet.x, swale_wet.y, swale_deposit_m.x, swale_deposit_m.y,
		swale_grade, swale_flow_grade,
		hummock_spacing_m, hummock_radius_m, hummock_height_m, hummock_cover,
		forest_hummock_spacing_m, forest_hummock_radius_m, forest_hummock_height_m, forest_hummock_cover,
		windthrow_spacing_m, windthrow_radii_m.x, windthrow_radii_m.y, windthrow_height_m,
		windthrow_cover, windthrow_pair_m, windthrow_pit_share, windthrow_max_grade,
	])


## Числа карт поверхности для C# (ReliefMaterial.Parameter): затенение впадин и каналы стока. Ширина полосы
## промытого дна — наименьшая ширина лощины эрозии (relief_generation.min_width_m): полуширина в узлах 4 м.
func surface_map_params(generation: Resource = null) -> PackedFloat64Array:
	var min_width_m: float = generation.min_width_m if generation != null else 0.0
	return PackedFloat64Array([
		cavity_near_occlusion, cavity_far_occlusion, cavity_near_from_m, cavity_near_full_m,
		cavity_far_from_m, cavity_far_full_m, bed_area_m2.x, bed_area_m2.y, deposit_m.x, deposit_m.y,
		floorf(min_width_m * 0.5 / GameConfig.TILE), GameConfig.TILE,
	])


func valid_flow_material() -> bool:
	return bed_area_m2.y > bed_area_m2.x and bed_area_m2.x > 0.0 and deposit_m.y > deposit_m.x and deposit_m.x >= 0.0 \
		and bed_stones >= 0.0 and bed_stones <= 1.0 and bed_tone >= 0.0 and bed_tone <= 1.0 \
		and deposit_wet >= 0.0 and ridge_dry >= 0.0 and ridge_brighten >= 0.0 and cavity_light_affect >= 0.0


## Числа материала по стоку в шейдер рельефа (uniform-ами); выключено — нули, картинка прежняя.
func apply_flow_material(mat: ShaderMaterial) -> void:
	var on := flow_material and valid_flow_material()
	mat.set_shader_parameter("flow_bed_stones", bed_stones if on else 0.0)
	mat.set_shader_parameter("flow_bed_tone", bed_tone if on else 0.0)
	mat.set_shader_parameter("flow_bed_color", bed_color)
	mat.set_shader_parameter("flow_deposit_wet", deposit_wet if on else 0.0)
	mat.set_shader_parameter("flow_ridge_dry", ridge_dry if on else 0.0)
	mat.set_shader_parameter("flow_ridge_brighten", ridge_brighten if on else 0.0)
	mat.set_shader_parameter("cavity_light_affect", cavity_light_affect if on else 0.0)
	mat.set_shader_parameter("material_roughness_enabled", material_roughness_enabled)
	mat.set_shader_parameter("rough_turf", rough_turf)
	mat.set_shader_parameter("rough_soil", rough_soil)
	mat.set_shader_parameter("rough_rock", rough_rock)
	mat.set_shader_parameter("rough_wet", rough_wet)
	mat.set_shader_parameter("spec_dry", spec_dry)
	mat.set_shader_parameter("spec_wet", spec_wet)
	mat.set_shader_parameter("height_blend_depth", height_blend_depth)
	mat.set_shader_parameter("far_normal_range", far_normal_range)
	mat.set_shader_parameter("mid_normal_scales", mid_normal_scales)
	mat.set_shader_parameter("mid_normal_range", mid_normal_range)
	mat.set_shader_parameter("mid_normal_strength", mid_normal_strength)


func activation_distance_m() -> float:
	return transition_end_m + enter_margin_m


func piece_cells() -> int:
	return roundi(piece_m / GameConfig.TILE)


func valid(chunk_cells: int) -> bool:
	if not is_finite(piece_m) or piece_m > chunk_cells * GameConfig.TILE:
		return false
	var cells := piece_cells()
	return step_m * 2.0 == GameConfig.TILE and cells > 0 \
		and is_equal_approx(piece_m, cells * GameConfig.TILE) \
		and chunk_cells % cells == 0 and full_m > 0.0 and transition_end_m > full_m \
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
