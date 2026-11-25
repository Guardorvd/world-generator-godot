class_name WorldVegetationConfig
extends Resource
## Настройки растительности, зонирования, подлеска и притропных объектов типа мира (Экспедиция и др.).

## Индексы плоского буфера veg_params для C# FastGrid.Vegetation и GDScript StageVegetation / RockScatter.
const VP_ECO_BASE := 0
const VP_CANOPY_FLOOR := 1
const VP_GLADE_MIN_KEEP := 2
const VP_STONY_MIN_KEEP := 3
const VP_GAP_K := 4
const VP_LINE_LO := 5
const VP_LINE_HI := 6
const VP_MUGO_LO := 7
const VP_MUGO_HI := 8
const VP_CANOPY_BOOST := 9
const VP_HEADWATER_END := 10
const VP_LOWER_START := 11
const VP_PATCH_COARSE := 12
const VP_PATCH_GROVE := 13
const VP_WATER_ALDER_DIST := 14
const VP_WATER_ALDER_ELEV := 15
const VP_WATER_ALDER_SHARE := 16
const VP_MAPLE_DIST := 17
const VP_MAPLE_ELEV := 18
const VP_MAPLE_SLOPE := 19
const VP_MAPLE_GROVE_THRESH := 20
const VP_MAPLE_HEAD_MUL := 21
const VP_MAPLE_MID_MUL := 22
const VP_MAPLE_LOW_MUL := 23
const VP_LOWER_BIRCH := 24
const VP_REDCEDAR_MOIST := 25
const VP_REDCEDAR_REL_ELEV := 26
const VP_REDCEDAR_SHARE := 27
const VP_SIB_CEDAR_HEAD := 28
const VP_SIB_CEDAR_SLOPE := 29
const VP_LARCH_SLOPE := 30
const VP_LARCH_ELEV_LO := 31
const VP_LARCH_ELEV_HI := 32
const VP_LARCH_HEAD := 33
const VP_SPRUCE_BASE := 34
const VP_PINE_DRY := 35
const VP_TREE_SCALE_BOOST := 36
const VP_RIVER_LEAN_CHANCE := 37
const VP_GNARLED_CHANCE := 38
const VP_SNAG_CHANCE := 39
const VP_TRAIL_EDGE_TREE_BOOST := 40
const VP_RIVER_ROCK_DIST := 41
const VP_RIVER_ROCK_BOOST := 42
const VP_VALLEY_BOT_H := 43
const VP_VALLEY_TOP_H := 44
const VP_YOUNG_SHARE := 45
const VP_INLAND_ALDER_SHARE := 46
const VP_MUGO_SLOPE_SHARE := 47
const VP_LARCH_BASE_SHARE := 48
const VP_HEMLOCK_SHARE := 49
const VP_DOUGLAS_FIR_SHARE := 50
const VP_COUNT := 51

@export_group("Крона и зонирование")
## Минимальный базовый покров глухого таёжного полога внутри леса, исключающий 300-метровые луга.
@export_range(0.0, 1.0, 0.01) var canopy_floor_density: float = 0.66
## Минимальный множитель сомкнутости на лесных окнах-полянах (малые мшистые просветы вместо вырубки).
@export_range(0.0, 1.0, 0.01) var glade_min_keep: float = 0.36
## Минимальный множитель плотности деревьев на крутых каменистых склонах.
@export_range(0.0, 1.0, 0.01) var stony_min_keep: float = 0.42
## Коэффициент зазора между кронами (ниже 0.75 у Долины — плотный тёмный коридор и сцеплённые кроны).
@export_range(0.35, 0.90, 0.01) var tree_gap_k: float = 0.54
## Нижняя граница высотного разрежения полога по высоте над дном долины (w.elev, над eco_base).
@export_range(0.10, 0.80, 0.01) var treeline_line_lo: float = 0.34
## Верхняя граница сомкнутого высотного леса по высоте над дном долины (w.elev, над eco_base).
@export_range(0.25, 1.00, 0.01) var treeline_line_hi: float = 0.58
## Нижняя граница пояса высокогорного стланика по высоте над дном долины (w.elev, над eco_base).
@export_range(0.20, 0.90, 0.01) var subalpine_shrub_lo: float = 0.38
## Верхняя граница пояса высокогорного стланика по высоте над дном долины (w.elev, над eco_base).
@export_range(0.40, 1.10, 0.01) var subalpine_shrub_hi: float = 0.72
## Общий множитель вероятности постановки ствола в глухом лесу экспедиции.
@export_range(0.50, 2.00, 0.01) var dense_canopy_boost: float = 1.28
## Продольная координата along, до которой тянутся суровые верховья (Саяны/кедр/лиственница).
@export_range(0.10, 0.60, 0.01) var headwater_end_along: float = 0.34
## Продольная координата along, с которой долина расширяется к тёплому низовью.
@export_range(0.40, 0.90, 0.01) var lower_start_along: float = 0.62
## Масштаб крупных лесных массивов (в клетках сетки) для чередования пихтово-еловых и кедровых стен.
@export_range(24.0, 160.0, 1.0) var patch_scale_coarse: float = 68.0
## Масштаб рощ (в клетках сетки) для компактных террасных пятен осеннего клёна и ольхи.
@export_range(8.0, 64.0, 1.0) var patch_scale_grove: float = 22.0

@export_group("Видовой состав деревьев")
## Максимальное расстояние dw от воды для прибрежной нависающей ольхи.
@export_range(3.0, 30.0, 0.5) var water_alder_dist: float = 14.0
## Максимальное превышение над уровнем реки для ольшаника на гальке и влажных берегах.
@export_range(0.01, 0.15, 0.005) var water_alder_max_elev: float = 0.06
## Базовая доля нависающей ольхи у самой кромки воды.
@export_range(0.0, 1.0, 0.01) var water_alder_share: float = 0.72
## Доля кряжистой многоствольной ольхи во влажных лесных логах и распадках вдали от берега.
@export_range(0.0, 1.0, 0.01) var inland_alder_share: float = 0.24
## Расстояние от воды dw для укрытых террас внутренних излучин, где гнездятся рощи клёна.
@export_range(8.0, 60.0, 0.5) var terrace_maple_dist: float = 34.0
## Максимальное превышение над рекой (elev - river) для террасных кленовых рощ.
@export_range(0.02, 0.25, 0.005) var terrace_maple_max_elev: float = 0.11
## Максимальная крутизна склона для кленовых террас.
@export_range(0.05, 0.60, 0.01) var terrace_maple_max_slope: float = 0.28
## Порог шума рощ, выше которого укрытые излучины образуют связные багряные пятна клёна.
@export_range(0.10, 0.90, 0.01) var terrace_maple_grove_thresh: float = 0.44
## Относительная встречаемость клёна в холодных верховьях.
@export_range(0.0, 1.5, 0.01) var terrace_maple_headwater_mul: float = 0.12
## Относительная встречаемость клёна в средней части каньона.
@export_range(0.0, 1.5, 0.01) var terrace_maple_mid_mul: float = 0.65
## Относительная встречаемость клёна на нижних пойменных террасах.
@export_range(0.0, 1.5, 0.01) var terrace_maple_lower_mul: float = 1.00
## Доля золотой осенней берёзы по нижним поймам и опушкам в низовьях.
@export_range(0.0, 0.80, 0.01) var lower_birch_share: float = 0.24
## Порог влажности для вековой туи складчатой (T_WESTERN_REDCEDAR) на влажных террасах и в ущелье.
@export_range(0.10, 0.90, 0.01) var redcedar_moist_min: float = 0.48
## Максимальное превышение над водой для гигантской западной туи в тенистых низинах.
@export_range(0.02, 0.30, 0.005) var redcedar_max_rel_elev: float = 0.14
## Доля западной туи среди хвойных на влажном дне и в тенистых распадках.
@export_range(0.0, 1.0, 0.01) var redcedar_share: float = 0.44
## Доля корявого сибирского кедра в суровых верховьях долины.
@export_range(0.0, 1.0, 0.01) var siberian_cedar_head_share: float = 0.56
## Доля сибирского кедра на каменистых и верхних склонах вдоль всей трассы.
@export_range(0.0, 1.0, 0.01) var siberian_cedar_slope_share: float = 0.34
## Порог крутизны/освещённого гребня для осенне-золотой лиственницы на сухих отрогах.
@export_range(0.05, 0.60, 0.01) var larch_sun_slope: float = 0.22
## Нижняя граница пояса лиственницы по высоте над дном долины (w.elev, над eco_base).
@export_range(0.0, 0.50, 0.01) var larch_elev_lo: float = 0.08
## Верхняя граница основного пояса лиственницы по высоте над дном долины (w.elev, над eco_base).
@export_range(0.10, 0.80, 0.01) var larch_elev_hi: float = 0.42
## Доля лиственницы на сухих светлых отрогах верховий.
@export_range(0.0, 1.0, 0.01) var larch_headwater_share: float = 0.36
## Базовый вес осенней золотисто-бронзовой лиственницы в среднем ярусе долины.
@export_range(0.0, 1.0, 0.01) var larch_base_share: float = 0.28
## Базовый вес тёмной ели/пихты, формирующей мрачный непролазный фон долины.
@export_range(0.05, 1.00, 0.01) var spruce_base_share: float = 0.64
## Редкая примесь сосны обыкновенной на самых сухих скалистых солнечных гребнях.
@export_range(0.0, 0.60, 0.01) var pine_dry_spur_share: float = 0.20
## Доля кряжистого стланика (T_MUGO) на крутых каменистых склонах и скальных уступах ниже верхней границы леса.
@export_range(0.0, 1.0, 0.01) var mugo_rocky_slope_share: float = 0.24
## Доля теневыносливой тсуги (T_HEMLOCK) на влажных участках и под пологом долины.
@export_range(0.0, 2.0, 0.02) var hemlock_share: float = 0.62
## Доля высокой дугласии (T_DOUGLAS_FIR) на укрытых и умеренно освещённых склонах.
@export_range(0.0, 2.0, 0.02) var douglas_fir_share: float = 0.56

@export_group("Формы и масштаб деревьев")
## Множитель высоты старых деревьев глухой долины.
@export_range(0.80, 1.40, 0.01) var canopy_scale_boost: float = 1.12
## Минимальная доля молодого 3–10 м яруса под старым пологом для загущения леса на уровне глаз.
@export_range(0.0, 0.65, 0.01) var young_understory_share: float = 0.34
## Вероятность наклонённой/изогнутой над водой формы у береговых и приуступных деревьев.
@export_range(0.0, 1.0, 0.01) var river_lean_chance: float = 0.62
## Вероятность корявой/ветровой формы кроны у деревьев верхних каменистых склонов.
@export_range(0.0, 1.0, 0.01) var gnarled_upper_chance: float = 0.52
## Доля мёртвых сушин (snag) в глубине хвойной чащи для мрачной атмосферы экспедиции.
@export_range(0.0, 0.35, 0.01) var snag_deep_chance: float = 0.09
## Усиление плотности постановки деревьев вдоль кромки тропы (внутри безопасного габарита).
@export_range(1.0, 2.0, 0.05) var trail_edge_tree_boost: float = 1.25

@export_group("Прибрежные валуны и камни")
## Ширина береговой полосы в клетках (dw), где усиливается россыпь замшелых береговых валунов.
@export_range(0.5, 8.0, 0.1) var riverbank_rock_dist: float = 3.2
## Дополнительный базовый шанс береговых валунов у кромки воды в RockScatter.
@export_range(0.0, 0.60, 0.01) var riverbank_rock_boost: float = 0.24

@export_group("Подлесок вдоль тропы")
## Максимальный вес проседания тропы, до которого мягкие папоротники и кустарники вплотную обступают край.
@export_range(0.05, 0.75, 0.01) var soft_verge_mask: float = 0.56
## Минимальный масштаб укорочения мягкого подлеска прямо на бровке тропы (не обнуляется).
@export_range(0.05, 1.00, 0.01) var soft_core_mul: float = 0.35
## Строгий порог веса полотна тропы, выше которого трава в _grass_cell никогда не прорастает.
@export_range(0.10, 0.80, 0.01) var grass_verge_mask: float = 0.50
## Строгий порог веса полотна для дёрна GroundCarpet (оставляет грязную колею чистой).
@export_range(0.10, 0.80, 0.01) var carpet_verge_mask: float = 0.34
## Дополнительное затемнение и помрачнение оттенка дёрна под плотным еловым пологом.
@export_range(0.0, 0.80, 0.01) var carpet_shade_boost: float = 0.28
## Множитель луговых цветов в дёрне GroundCarpet (0 отключает летние белые/жёлтые цветочки).
@export_range(0.0, 1.0, 0.05) var carpet_flowers_mul: float = 0.0
## Множитель покрытия зелёного дёрна GroundCarpet под лесным пологом (убирает парковый газон).
@export_range(0.05, 1.0, 0.01) var carpet_forest_cover_mul: float = 0.18
## Приглушение яркости альбедо дёрна GroundCarpet в лесу и на замшелых участках.
@export_range(0.30, 1.0, 0.01) var carpet_darken_mul: float = 0.62
## Множитель плотности обычной бледной травы в _grass_cell внутри леса (уступает место мху и папоротникам).
@export_range(0.05, 1.5, 0.01) var grass_forest_density_mul: float = 0.58

@export_group("Папоротники, валежник и пни")
## Количество попыток постановки крупного лесного подлеска на плитку 4 м в тёмной тайге.
@export_range(4, 16, 1) var forest_understory_slots: int = 11
## Множитель масштаба лесных папоротников, ягодников и травостоя до высоты по грудь/пояс.
@export_range(0.80, 1.80, 0.02) var forest_understory_scale_mul: float = 1.24
## Множитель густоты меч-папоротников и лесных папоротников на террасах и вдоль тропы.
@export_range(0.2, 5.0, 0.1) var forest_fern_boost: float = 2.6
## Множитель бруснично-черничного осеннего ягодника (вместо открытой луговой травы).
@export_range(0.2, 5.0, 0.1) var forest_berry_boost: float = 2.1
## Множитель крупнолистного лесного травостоя и белокопытника (BROADLEAF_HERB).
@export_range(0.2, 6.0, 0.1) var forest_broadleaf_boost: float = 3.8
## Множитель дикого подгольцового кустарника и багульника (ALPINE_SHRUB).
@export_range(0.2, 6.0, 0.1) var forest_alpine_shrub_boost: float = 3.2
## Множитель моховых кочек на сырой подстилке хвойного леса.
@export_range(0.2, 5.0, 0.1) var forest_moss_mound_boost: float = 2.2
## Множитель густоты лещиновых, можжевеловых и еловых зарослей на уровне взгляда.
@export_range(0.2, 5.0, 0.1) var forest_thicket_wall: float = 2.8
## Подавление светлых луговых цветов внутри лесного полога.
@export_range(0.0, 1.5, 0.02) var forest_flower_mul: float = 0.12
## Подавление яркого розового иван-чая (убирает весёлый розовый ковёр старого шаблона).
@export_range(0.0, 1.5, 0.02) var forest_fireweed_mul: float = 0.08
## Множитель замшелого лесного валежника (NURSE_LOG) на дне долины и в распадках.
@export_range(0.2, 5.0, 0.1) var forest_nurse_log_mul: float = 2.6
## Множитель замшелых древних выворотов и пней (ROOT_STUMP).
@export_range(0.2, 5.0, 0.1) var forest_root_stump_mul: float = 2.2
## Множитель замшелых лесных и береговых валунов в VegetationLayer.
@export_range(0.2, 5.0, 0.1) var forest_boulder_mul: float = 2.4
## Доля замшелых вариантов валунов, валежника и кочек в ForestFloor.expedition_variant.
@export_range(0.0, 1.0, 0.02) var mossy_boulder_share: float = 0.86
## Шанс россыпи прибрежных/подгольцовых валунов и стланика на открытых галечниках и каменистых кручах.
@export_range(0.0, 1.0, 0.02) var open_boulder_chance: float = 0.34
## Множитель лимита инстансов деталей на буфер MultiMesh для плотных папоротников в пределах бюджета кадров.
@export_range(0.5, 2.0, 0.05) var detail_cap_mul: float = 1.25

@export_group("Крупные объекты у края тропы")
## Доля узлов обочины, где ставится атмосферный замшелый валежник, древний пень или валун.
@export_range(0.0, 1.0, 0.02) var verge_log_chance: float = 0.42
## Минимальный боковой отступ от полуширины коридора тропы до кромки крупного притропного объекта (м).
@export_range(0.5, 3.0, 0.05) var verge_shoulder_min: float = 0.95
## Максимальный боковой отступ от полуширины коридора тропы до крупного притропного объекта (м).
@export_range(1.2, 6.0, 0.05) var verge_shoulder_max: float = 2.80
## Вероятность ориентации притропного валежника примерно вдоль бровки тропы (иначе укладывается под углом к склону).
@export_range(0.0, 1.0, 0.02) var verge_log_parallel_chance: float = 0.65


## Собирает плоский буфер VP_* для передачи в FastGrid.VegetationPlan и PlaceRockChunk.
func veg_params(eco_base: float, valley_bot_h := 0.07, valley_top_h := 0.22) -> PackedFloat64Array:
	var p := PackedFloat64Array()
	p.resize(VP_COUNT)
	p[VP_ECO_BASE] = eco_base
	p[VP_CANOPY_FLOOR] = canopy_floor_density
	p[VP_GLADE_MIN_KEEP] = glade_min_keep
	p[VP_STONY_MIN_KEEP] = stony_min_keep
	p[VP_GAP_K] = tree_gap_k
	p[VP_LINE_LO] = treeline_line_lo
	p[VP_LINE_HI] = treeline_line_hi
	p[VP_MUGO_LO] = subalpine_shrub_lo
	p[VP_MUGO_HI] = subalpine_shrub_hi
	p[VP_CANOPY_BOOST] = dense_canopy_boost
	p[VP_HEADWATER_END] = headwater_end_along
	p[VP_LOWER_START] = lower_start_along
	p[VP_PATCH_COARSE] = patch_scale_coarse
	p[VP_PATCH_GROVE] = patch_scale_grove
	p[VP_WATER_ALDER_DIST] = water_alder_dist
	p[VP_WATER_ALDER_ELEV] = water_alder_max_elev
	p[VP_WATER_ALDER_SHARE] = water_alder_share
	p[VP_MAPLE_DIST] = terrace_maple_dist
	p[VP_MAPLE_ELEV] = terrace_maple_max_elev
	p[VP_MAPLE_SLOPE] = terrace_maple_max_slope
	p[VP_MAPLE_GROVE_THRESH] = terrace_maple_grove_thresh
	p[VP_MAPLE_HEAD_MUL] = terrace_maple_headwater_mul
	p[VP_MAPLE_MID_MUL] = terrace_maple_mid_mul
	p[VP_MAPLE_LOW_MUL] = terrace_maple_lower_mul
	p[VP_LOWER_BIRCH] = lower_birch_share
	p[VP_REDCEDAR_MOIST] = redcedar_moist_min
	p[VP_REDCEDAR_REL_ELEV] = redcedar_max_rel_elev
	p[VP_REDCEDAR_SHARE] = redcedar_share
	p[VP_SIB_CEDAR_HEAD] = siberian_cedar_head_share
	p[VP_SIB_CEDAR_SLOPE] = siberian_cedar_slope_share
	p[VP_LARCH_SLOPE] = larch_sun_slope
	p[VP_LARCH_ELEV_LO] = larch_elev_lo
	p[VP_LARCH_ELEV_HI] = larch_elev_hi
	p[VP_LARCH_HEAD] = larch_headwater_share
	p[VP_SPRUCE_BASE] = spruce_base_share
	p[VP_PINE_DRY] = pine_dry_spur_share
	p[VP_TREE_SCALE_BOOST] = canopy_scale_boost
	p[VP_RIVER_LEAN_CHANCE] = river_lean_chance
	p[VP_GNARLED_CHANCE] = gnarled_upper_chance
	p[VP_SNAG_CHANCE] = snag_deep_chance
	p[VP_TRAIL_EDGE_TREE_BOOST] = trail_edge_tree_boost
	p[VP_RIVER_ROCK_DIST] = riverbank_rock_dist
	p[VP_RIVER_ROCK_BOOST] = riverbank_rock_boost
	p[VP_VALLEY_BOT_H] = valley_bot_h
	p[VP_VALLEY_TOP_H] = valley_top_h
	p[VP_YOUNG_SHARE] = young_understory_share
	p[VP_INLAND_ALDER_SHARE] = inland_alder_share
	p[VP_MUGO_SLOPE_SHARE] = mugo_rocky_slope_share
	p[VP_LARCH_BASE_SHARE] = larch_base_share
	p[VP_HEMLOCK_SHARE] = hemlock_share
	p[VP_DOUGLAS_FIR_SHARE] = douglas_fir_share
	return p


## Детерминированный хеш параметров генерации растительности и каменных россыпей для инвалидации слоя nature в WorldCache.
func cache_digest() -> String:
	return var_to_str(veg_params(0.0, 0.0, 0.0)).sha256_text().left(16)
