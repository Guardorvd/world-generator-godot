extends Resource
## Настройки игрового слоя после генерации. Не участвуют в ключах кэша мира.
const MountainDetail := preload("res://scripts/world/mountain_detail.gd")

enum {
	RD_STEP_M, RD_ROAD_GUARD_M, RD_ROAD_FADE_M, RD_WATER_CLEARANCE_M, RD_WATER_FADE_M,
	RD_PLACE_FADE_M, RD_ROCK_FROM, RD_ROCK_TO, RD_STEEP_FROM, RD_STEEP_TO,
	RD_EDGE_GUARD_M, RD_EDGE_FADE_M, RD_BICUBIC, RD_CLAMP, RD_RECONSTRUCTION_DELTA_M, RD_TILE_BYTES,
	RD_FORMS, RD_FORM_GRADE_LIMIT, RD_FORM_GRADE_GAIN, RD_FORM_DELTA_M, RD_TOTAL_DELTA_M,
	RD_RILL, RD_RILL_ALONG, RD_RILL_ACROSS, RD_RILL_M, RD_RILL_COVER,
	RD_RILL_SLOPE_FROM, RD_RILL_SLOPE_TO, RD_RILL_CURVATURE_M, RD_RILL_RIM,
	RD_ROOT, RD_ROOT_ALONG, RD_ROOT_ACROSS, RD_ROOT_M, RD_ROOT_COVER, RD_ROOT_PAIR_M, RD_ROOT_PIT_SHARE,
	RD_TERRACE, RD_TERRACE_ALONG, RD_TERRACE_ACROSS, RD_TERRACE_M, RD_TERRACE_COVER,
	RD_TERRACE_SLOPE_FROM, RD_TERRACE_SLOPE_TO, RD_TERRACE_LIP_M,
	RD_FLOOD, RD_FLOOD_ALONG, RD_FLOOD_ACROSS, RD_FLOOD_M, RD_FLOOD_COVER,
	RD_FLOOD_NEAR_M, RD_FLOOD_FAR_M, RD_FLOOD_GRADE,
	RD_BANK, RD_BANK_ALONG, RD_BANK_ACROSS, RD_BANK_M, RD_BANK_COVER,
	RD_BANK_NEAR_M, RD_BANK_FAR_M, RD_BANK_LIP_M,
	RD_MID_FORMS, RD_MID_FADE_M, RD_MID_GRADE_GAIN, RD_MID_DELTA_M,
	RD_KNOLL, RD_KNOLL_ALONG, RD_KNOLL_ACROSS, RD_KNOLL_HEIGHT, RD_KNOLL_COVER,
	RD_HOLLOW, RD_HOLLOW_ALONG, RD_HOLLOW_ACROSS, RD_HOLLOW_DEPTH, RD_HOLLOW_COVER,
	RD_SHELF_GRADE, RD_SHELF_NEAR_M, RD_SHELF_FAR_M, RD_SHELF_CURVATURE_M,
	RD_GULLY, RD_GULLY_ALONG, RD_GULLY_ACROSS, RD_GULLY_DEPTH, RD_GULLY_COVER,
	RD_GULLY_SLOPE_FROM, RD_GULLY_SLOPE_TO, RD_GULLY_NEAR_M, RD_GULLY_FAR_M, RD_GULLY_CURVATURE_M, RD_COUNT,
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
## Минимальная дальность конца переходов 4→8 и 8→16, м.
@export var lod_end_min_m := Vector2.ZERO
## Максимальная дальность конца переходов, м.
@export var lod_end_max_m := Vector2.ZERO
## Ширина каждого плавного перехода, м.
@export var lod_fade_m := Vector2.ZERO
## Допустимое отношение вертикальной ошибки к расстоянию для обоих переходов.
@export var lod_error_ratio := Vector2.ZERO
## Переход к общему ребру соседних чанков, м от ребра.
@export var lod_edge_fade_m := Vector2.ZERO
## Запас за концом перехода для обратной подмены, м.
@export var lod_load_margin_m := 0.0
## Дополнительный гистерезис при удалении, м.
@export var lod_hysteresis_m := 0.0
## Длительность плавного восстановления, если поток опоздал к порогу, с.
@export var lod_recover_s := 0.0

@export_group("Маска")
## Неподвижная полоса вокруг дорожных патчей, м.
@export var road_guard_m := 0.0
## Выход из защитной полосы дороги, м.
@export var road_fade_m := 0.0
## Минимальная высота суши над соседним уровнем воды, м.
@export var water_clearance_m := 0.0
## Переход от защищённого берега к детали, м.
@export var water_fade_m := 0.0
## Переход от площадки или сооружения к детали, м.
@export var place_fade_m := 0.0
## Плавное затухание по доле обнажённой породы.
@export var rock_fade := Vector2(1.0, 1.0)
## Доли уклона, при которых начинается и заканчивается затухание.
@export var slope_fade := Vector2(MountainDetail.DETAIL_STEEP_FROM, MountainDetail.DETAIL_LIMIT)
## Ширина неподвижного края плана, м.
@export var edge_guard_m := 0.0
## Переход между неподвижным краем и деталью, м.
@export var edge_fade_m := 0.0

@export_group("Восстановление")
## Восстанавливать промежуточные высоты бикубиком Catmull–Rom.
@export var bicubic := true
## Ограничивать высоту диапазоном четырёх углов исходного квадрата.
@export var clamp_bicubic := true
## Предельное смещение восстановленной высоты от треугольника 4 м, м.
@export var reconstruction_delta_m := 0.0

@export_group("Малые формы")
## Добавлять природные формы в точное поле.
@export var forms_enabled := false
## Предельный уклон после добавления форм, м/м; уже более крутые грани сохраняют уклон.
@export var form_grade_limit := MountainDetail.DETAIL_LIMIT
## Допустимый прирост модуля градиента от форм, м/м.
@export var form_grade_gain := 0.0
## Максимальный вклад всех малых форм в высоту, м.
@export var form_delta_m := 0.0
## Наибольшее отклонение поля с формами от опоры 4 м, м.
@export var total_delta_m := 0.0

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

@export_group("Средние формы")
## Добавлять средние формы к игровому полю 4 м после генерации.
@export var mid_enabled := false
## Плавный выход из нулевой части общей маски для средних форм, м.
@export var mid_fade_m := 0.0
## Максимальный прирост уклона над исходной сеткой 4 м, м/м.
@export var mid_grade_gain := 0.0
## Предел общего смещения сетки 4 м, м.
@export var mid_delta_m := 0.0

@export_group("Бугры и западины на полках")
## Шаг поиска мест для бугров, м.
@export var knoll_spacing_m := 0.0
## Радиусы бугра вдоль и поперёк долины, м.
@export var knoll_radii_m := Vector2.ZERO
## Высота бугра до маскирования, м.
@export var knoll_height_m := 0.0
## Вероятность бугра на подходящей полке, доля.
@export var knoll_cover := 0.0
## Шаг поиска мест для западин, м.
@export var hollow_spacing_m := 0.0
## Радиусы западины вдоль и поперёк долины, м.
@export var hollow_radii_m := Vector2.ZERO
## Глубина западины до маскирования, м.
@export var hollow_depth_m := 0.0
## Вероятность западины на подходящей полке, доля.
@export var hollow_cover := 0.0
## Уклон, на котором формы полок исчезают, м/м.
@export var shelf_grade := 0.0
## Полоса расстояний от кромки реки для форм полок, м.
@export var shelf_shore_m := Vector2.ZERO
## Перепад, различающий выпуклость бугра и вогнутость западины, м.
@export var shelf_curvature_m := 0.0

@export_group("Короткие овражки к реке")
## Шаг поиска мест для овражков, м.
@export var gully_spacing_m := 0.0
## Радиусы овражка вдоль и поперёк падения, м.
@export var gully_radii_m := Vector2.ZERO
## Глубина овражка до маскирования, м.
@export var gully_depth_m := 0.0
## Вероятность формы на подходящем склоне, доля.
@export var gully_cover := 0.0
## Полоса уклонов, м/м.
@export var gully_slopes := Vector2.ZERO
## Полоса расстояний от кромки реки, м.
@export var gully_shore_m := Vector2.ZERO
## Перепад для плавного усиления в ложбинах, м.
@export var gully_curvature_m := 0.0

@export_group("Бюджет")
## Лимит Миб для плиток и маски высот.
@export var tile_mib := 0
## Лимит Миб для массивов точных мешей в общем LRU.
@export var mesh_mib := 0
## Разрешать точному уровню отбрасывать тени.
@export var cast_shadows := true

const MIB := 1024 * 1024


func params() -> PackedFloat64Array:
	return PackedFloat64Array([
		step_m, road_guard_m, road_fade_m, water_clearance_m, water_fade_m,
		place_fade_m, rock_fade.x, rock_fade.y, slope_fade.x, slope_fade.y,
		edge_guard_m, edge_fade_m, float(bicubic), float(clamp_bicubic), maxf(0.0, reconstruction_delta_m), tile_mib * MIB,
		float(forms_enabled), form_grade_limit, form_grade_gain, form_delta_m, total_delta_m,
		rill_spacing_m, rill_radii_m.x, rill_radii_m.y, rill_depth_m, rill_cover,
		rill_slopes.x, rill_slopes.y, rill_curvature_m, rill_rim,
		root_spacing_m, root_radii_m.x, root_radii_m.y, root_height_m, root_cover, root_pair_m, root_pit_share,
		terrace_spacing_m, terrace_radii_m.x, terrace_radii_m.y, terrace_height_m, terrace_cover,
		terrace_slopes.x, terrace_slopes.y, terrace_lip_m,
		flood_spacing_m, flood_radii_m.x, flood_radii_m.y, flood_depth_m, flood_cover,
		flood_shore_m.x, flood_shore_m.y, flood_grade,
		bank_spacing_m, bank_radii_m.x, bank_radii_m.y, bank_height_m, bank_cover,
		bank_shore_m.x, bank_shore_m.y, bank_lip_m,
		float(mid_enabled), mid_fade_m, mid_grade_gain, mid_delta_m,
		knoll_spacing_m, knoll_radii_m.x, knoll_radii_m.y, knoll_height_m, knoll_cover,
		hollow_spacing_m, hollow_radii_m.x, hollow_radii_m.y, hollow_depth_m, hollow_cover,
		shelf_grade, shelf_shore_m.x, shelf_shore_m.y, shelf_curvature_m,
		gully_spacing_m, gully_radii_m.x, gully_radii_m.y, gully_depth_m, gully_cover,
		gully_slopes.x, gully_slopes.y, gully_shore_m.x, gully_shore_m.y, gully_curvature_m,
	])


func valid(chunk_cells: int) -> bool:
	var piece_cells := roundi(piece_m / GameConfig.TILE)
	return step_m * 2.0 == GameConfig.TILE and piece_cells > 0 \
		and is_equal_approx(piece_m, piece_cells * GameConfig.TILE) \
		and chunk_cells % piece_cells == 0 and full_m > 0.0 and transition_end_m > full_m \
		and exit_margin_m >= enter_margin_m and enter_margin_m >= 0.0 and prefetch_m >= 0.0 \
		and tile_mib > 0 and mesh_mib > 0


func valid_lod(recheck_m: float) -> bool:
	return lod_edge_fade_m.x >= transition_end_m and lod_edge_fade_m.y > lod_edge_fade_m.x \
		and lod_end_min_m.x - lod_fade_m.x >= maxf(lod_edge_fade_m.y, transition_end_m + exit_margin_m) \
		and lod_end_min_m.y - lod_fade_m.y >= lod_end_max_m.x + lod_load_margin_m + lod_hysteresis_m \
		and lod_end_max_m.x >= lod_end_min_m.x and lod_end_max_m.y >= lod_end_min_m.y \
		and lod_fade_m.x > 0.0 and lod_fade_m.y > 0.0 and lod_error_ratio.x > 0.0 and lod_error_ratio.y > 0.0 \
		and lod_load_margin_m >= recheck_m and lod_hysteresis_m >= 0.0 and lod_recover_s > 0.0
