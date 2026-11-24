class_name WorldTypeConfig
extends Resource
## Настройки типа мира (docs/WORLD_TEMPLATES.md): правятся в инспекторе Godot без кода.
## Изменение любого параметра меняет ключ кэша этого типа; кэш Типа 1 не затрагивается.
## Для добавления третьего типа достаточно создать новый .tres этого класса и добавить строку в WorldTemplate._CATALOG.

## Индексы массива relief_params() для единой передачи чисел в C# (FastGrid.ValleyReliefField) и GDScript (StageRelief).
const RP_WARP_SCALE := 0
const RP_WARP_AMP := 1
const RP_BANK_HEIGHT := 2
const RP_BANK_DECAY := 3
const RP_DAMP_START := 4
const RP_DAMP_END := 5
const RP_FOLDS_FINE_SCALE := 6
const RP_FOLDS_BROAD_SCALE := 7
const RP_FOLDS_BROAD_AMP := 8
const RP_FOLDS_FINE_AMP := 9
const RP_BENCH_START_PAD := 10
const RP_BENCH_RISE_LIN := 11
const RP_BENCH_RISE_QUAD := 12
const RP_SPUR_START_PAD := 13
const RP_SPUR_SADDLE_OFFSET := 14
const RP_SPUR_SADDLE_WIDTH := 15
const RP_SPUR_SADDLE_DIP := 16
const RP_WALL_ROAD_START := 17
const RP_WALL_ROAD_END := 18
const RP_WALL_ROAD_BASE_START := 19
const RP_WALL_ROAD_BASE_END := 20
const RP_WALL_ROAD_BASE_H := 21
const RP_WALL_OPP_START := 22
const RP_WALL_OPP_END := 23
const RP_WALL_OPP_BASE_START := 24
const RP_WALL_OPP_BASE_END := 25
const RP_WALL_OPP_BASE_H := 26
const RP_END_WALL_MTN_MUL := 27
const RP_WALL_MTN_AMP := 28
const RP_WALL_FOLDS_SUPPRESS := 29
const RP_CLOSED_LIFT := 30
const RP_HEIGHT_FLOOR := 31
const RP_HEIGHT_KNEE := 32
const RP_HEIGHT_SOFT := 33
const RP_GULLY_SCALE_X := 34
const RP_GULLY_SCALE_Y := 35
const RP_GULLY_WIDTH := 36
const RP_GULLY_DEPTH := 37
const RP_GULLY_WALL_MIN := 38
const RP_GULLY_WALL_MAX := 39
const RP_COULOIR_SCALE_X := 40
const RP_COULOIR_SCALE_Y := 41
const RP_COULOIR_WIDTH := 42
const RP_COULOIR_DEPTH := 43
const RP_COULOIR_PATCH_SCALE := 44
const RP_COULOIR_PATCH_MIN := 45
const RP_COULOIR_PATCH_MAX := 46
const RP_COULOIR_WALL_MIN := 47
const RP_COULOIR_WALL_MAX := 48
const RP_OUTER_RIDGE_ROAD_START := 49
const RP_OUTER_RIDGE_OPP_START := 50
const RP_OUTER_RIDGE_SPAN := 51
const RP_OUTER_RIDGE_BASE_H := 52
const RP_OUTER_RIDGE_MTN_AMP := 53
const RP_OPP_SPUR_START_PAD := 54
const RP_COUNT := 55

@export_group("Тип мира и размеры")
## Уникальный id типа мира (задаёт папки кэша, сохранений и истории).
@export var id := "mountain_valley"
## Название типа мира в меню (длиннее текст — шире заголовок карточки).
@export var title := "Горная долина"
## Доступность типа в меню (false отключает выбор и показывает заглушку).
@export var available := true
## Ширина плана в клетках (4 м/клетку); увеличение делает мир шире.
@export var plan_width := 768
## Варианты длины плана в клетках (кратны 64, не выше 4096); увеличение удлиняет маршрут.
@export var plan_heights := PackedInt32Array([768])
## Длина короткой отладочной версии в клетках; увеличение удлиняет dev-мир.
@export var dev_height := 768
## Открывает весь прямоугольный план сразу без окна стартовой территории.
@export var full_plan_territory := false
## Разрешает бесконечную достройку соседних областей (RegionStream) за краем плана.
@export var allow_infinite_regions := true
## Подбирает стартовый сдвиг материков по морю/суше (выключается для долин).
@export var pick_start := true
## Назначает домом игрока первое поселение вместо центрального.
@export var home_is_first_settlement := false
## Показывает примерную длину долины в километрах в карточке меню.
@export var show_valley_length := false
## Включает генерацию долины (ось, предгорья, отроги, стены гор и торцы).
@export var valley_relief := false
## Включает единую ленту реки вдоль оси долины вместо старой гидрологии.
@export var valley_river := false
## Включает одну непрерывную дорогу по одному берегу, два опорных поселения и редкие места.
@export var single_road := false

@export_group("Долина и рельеф")
## Смещение оси реки от центра (доля ширины плана); увеличение расширяет дорожный берег и сужает противоположный.
@export var corridor_shift := 0.14
## Масштаб шумового искажения рельефа (клеток); увеличение делает складки более крупными и плавными.
@export var warp_scale := 220.0
## Амплитуда искажения координат (клеток); увеличение делает склоны и стены более изогнутыми.
@export var warp_amp := 18.0
## Масштаб мелких холмов предгорий (клеток); увеличение сглаживает мелкую волнистость.
@export var folds_fine_scale := 44.0
## Масштаб широких увалов предгорий (клеток); увеличение делает предгорные волны длиннее.
@export var folds_broad_scale := 105.0
## Высота широких увалов предгорий (ед. h); увеличение усиливает перепады предгорий.
@export var folds_broad_amp := 0.048
## Высота мелких холмов предгорий (ед. h); увеличение добавляет неровностей в лесу.
@export var folds_fine_amp := 0.032
## Ширина ровной прибрежной террасы (клеток от кромки реки); увеличение отодвигает подъём предгорий от воды.
@export var bench_start_pad := 3.0
## Линейный подъём предгорий от реки; увеличение поднимает всю дорожную сторону выше над рекой.
@export var bench_rise_lin := 0.00045
## Квадратичный подъём к горной стене; увеличение делает переход от предгорий к стене круче.
@export var bench_rise_quad := 0.0000045
## Начало горной стены на дорожной стороне (клеток от оси); увеличение расширяет лесной коридор дороги.
@export var wall_road_start := 88.0
## Выход горной стены на дорожной стороне на полную высоту (клеток); увеличение делает склон положе.
@export var wall_road_end := 185.0
## Начало подъёма подножия стены на дорожной стороне (клеток); увеличение отодвигает подножие от дороги.
@export var wall_road_base_start := 85.0
## Дистанция полного подъёма подножия на дорожной стороне (клеток); увеличение растягивает склон.
@export var wall_road_base_end := 240.0
## Базовая высота горной стены на дорожной стороне (ед. h); увеличение делает хребет выше.
@export var wall_road_base_h := 0.34
## Начало горной стены на противоположном берегу (клеток от оси); увеличение расширяет берег за рекой.
@export var wall_opp_start := 18.0
## Выход противоположной стены на полную высоту (клеток); увеличение делает склон за рекой положе.
@export var wall_opp_end := 95.0
## Начало подножия стены на противоположном берегу (клеток); увеличение отодвигает подножие от воды.
@export var wall_opp_base_start := 16.0
## Дистанция полного подъёма противоположного подножия (клеток); увеличение растягивает подъём.
@export var wall_opp_base_end := 160.0
## Базовая высота противоположной стены (ед. h); увеличение делает горный борт за рекой выше.
@export var wall_opp_base_h := 0.38
## Сила наложения горных хребтов на стены долины; увеличение делает пики и рёбра острее и выше.
@export var wall_mountain_amp := 0.72
## Подавление мелких холмов на горных стенах (0..1); увеличение делает стены чище от мелких кочек.
@export var wall_folds_suppress := 0.65
## Множитель горного рельефа на торцах долины; увеличение делает замыкающие хребты более гористыми.
@export var end_wall_mountain_mul := 1.4
## Высота речного берега над водой (ед. h); увеличение делает береговую бровку выше.
@export var bank_height := 0.013
## Плавность подъёма бровки берега (клеток); увеличение делает берег более пологим.
@export var bank_decay := 1.1
## Высота земли над дном при закрытии русла на торцах (ед. h); увеличение приподнимает дно за краем плана.
@export var channel_closed_lift := 0.012
## Начало выхода рельефа и детализации из русла (клеток от кромки); увеличение расширяет гладкую полосу берега.
@export var channel_damp_start := 0.6
## Полное включение рельефа и ряби (клеток от кромки); увеличение сглаживает более широкую пойму.
@export var channel_damp_end := 6.5
## Минимально допустимая высота суши/дна долины (ед. h); увеличение поднимает дно над уровнем моря.
@export var height_floor := 0.008
## Порог мягкого сжатия высоких пиков (ед. h); увеличение позволяет горам расти выше до сжатия.
@export var height_knee := 1.26
## Мягкость сжатия пиков выше порога; увеличение даёт более высокие вершины над порогом.
@export var height_soft := 0.16
## Продольный масштаб смены котловин и теснин (клеток); увеличение делает расширения долины длиннее.
@export var basin_scale := 310.0
## Сужение дна в теснинах (клеток на сторону); увеличение делает ущелья теснее.
@export var basin_narrow := 14.0
## Расширение дна в пойменных котловинах (клеток на сторону); увеличение делает котловины шире.
@export var basin_wide := 28.0
## Чувствительность асимметрии стен к кривизне излучины; увеличение сильнее проявляет прижимы и внутренние террасы.
@export var bend_asym_gain := 160.0
## Приближение стены к внешнему берегу излучины (клеток); увеличение делает склон-прижим круче и ближе.
@export var bend_wall_pull := 16.0
## Отодвигание стены на внутреннем берегу излучины (клеток); увеличение расширяет пологую пойменную террасу.
@export var bend_terrace_push := 22.0
## Минимальная гарантированная ширина дорожного коридора от оси реки (клеток); увеличение расширяет проход в теснинах.
@export var min_road_corridor := 48.0
## Поперечный масштаб боковых ложбин-распадков (клеток); увеличение делает распадки длиннее.
@export var gully_scale_x := 240.0
## Продольный шаг боковых ложбин-распадков (клеток); увеличение делает распадки реже вдоль долины.
@export var gully_scale_y := 95.0
## Относительная ширина вреза боковых распадков; увеличение расширяет ложбины.
@export var gully_width := 0.24
## Максимальная глубина вреза боковых распадков (ед. h); увеличение углубляет ложбины в склонах.
@export var gully_depth := 0.13
## Начало проявления распадков по маске стены; увеличение сдвигает врез выше по склону.
@export var gully_wall_min := 0.06
## Полное проявление распадков на стене; увеличение задерживает полный врез ближе к гребню.
@export var gully_wall_max := 0.42
## Поперечный масштаб осыпных кулуаров (клеток); увеличение удлиняет желоба.
@export var couloir_scale_x := 135.0
## Продольный шаг осыпных кулуаров (клеток); увеличение делает кулуары реже.
@export var couloir_scale_y := 30.0
## Относительная ширина осыпных кулуаров; увеличение расширяет скальные желоба.
@export var couloir_width := 0.18
## Глубина осыпных кулуаров (ед. h); увеличение делает жёлобы резче и обнажает больше осыпи.
@export var couloir_depth := 0.070
## Масштаб пятен концентрации кулуаров (клеток); увеличение укрупняет скальные участки стен.
@export var couloir_patch_scale := 160.0
## Нижний порог шума пятен кулуаров; увеличение сужает долю склонов с кулуарами.
@export var couloir_patch_min := -0.05
## Верхний порог шума пятен кулуаров; увеличение растягивает плавный переход частоты кулуаров.
@export var couloir_patch_max := 0.40
## Нижняя граница кулуаров по маске стены; увеличение поднимает желоба выше над лесом.
@export var couloir_wall_min := 0.15
## Полная глубина кулуаров по маске стены; увеличение задерживает максимум ближе к верху стены.
@export var couloir_wall_max := 0.62
## Начало второго эшелона дальних гольцов со стороны дороги (клеток); увеличение отодвигает гольцы глубже.
@export var outer_ridge_road_start := 185.0
## Начало второго эшелона дальних гольцов со стороны противоположного берега (клеток); увеличение отодвигает дальний хребет.
@export var outer_ridge_opp_start := 130.0
## Ширина подъёма второго эшелона гольцов (клеток); увеличение делает дальний подъём положе.
@export var outer_ridge_span := 195.0
## Базовая высота второго эшелона гольцов (ед. h); увеличение поднимает дальние гольцы.
@export var outer_ridge_base_h := 0.48
## Сила горного рельефа на втором эшелоне гольцов; увеличение делает дальние хребты острее и выше.
@export var outer_ridge_mtn_amp := 0.85
## Внешний радиус лёгкого дальнего пояса OuterTerrain (м, 0 отключает пояс); увеличение расширяет обзор дальних гольцов.
@export var outer_far_radius := 0.0
## Радиус выгрузки дальних чанков OuterTerrain (м); увеличение уменьшает пересборки при разворотах.
@export var outer_far_drop := 0.0
## Сторона дальнего чанка OuterTerrain в клетках; увеличение уменьшает число мешей за счёт детализации.
@export var outer_far_chunk_cells := 128
## Шаг сетки дальнего чанка в клетках; увеличение облегчает геометрию дальнего пояса.
@export var outer_far_step := 4
## Понижение дальнего пояса под ближними чанками (м); увеличение защищает от наложений на стыке.
@export var outer_far_sink_m := 3.0

@export_group("Поперечные отроги")
## Минимальный отступ первого отрога от старта (клеток); увеличение отодвигает первый подъём дальше от старта.
@export var spur_first_y_min := 88.0
## Случайный разброс положения первого отрога (клеток); увеличение усиливает отличие между сидами.
@export var spur_first_y_span := 48.0
## Отступ последнего отрога от финиша (клеток); увеличение освобождает больше ровного низовья.
@export var spur_end_margin := 115.0
## Минимальный шаг между отрогами (клеток); увеличение делает отроги реже.
@export var spur_gap_min := 96.0
## Случайная добавка к шагу между отрогами (клеток); увеличение делает ритм отрогов неравномернее.
@export var spur_gap_span := 78.0
## Минимальная полудлина отрога вдоль долины (клеток); увеличение делает отроги шире вдоль пути.
@export var spur_half_len_min := 30.0
## Случайная добавка к полудлине отрога (клеток); увеличение разнообразит ширину отрогов.
@export var spur_half_len_span := 26.0
## Минимальная высота поперечного отрога (м); увеличение делает подъёмы в лес ощутимее.
@export var spur_height_min_m := 20.0
## Случайная добавка к высоте отрога (м); увеличение повышает самые крупные отроги.
@export var spur_height_span_m := 19.0
## Минимальное расстояние носа отрога от реки (клеток); увеличение отодвигает отроги глубже в лес.
@export var spur_reach_min := 26.0
## Случайный разброс вылета отрога (клеток); увеличение меняет глубину залегания седловин.
@export var spur_reach_span := 28.0
## Отступ начала подъёма отрога от кромки реки (клеток); увеличение бережёт прибрежную полку.
@export var spur_start_pad := 2.0
## Сдвиг седловины отрога вглубь от его носа (клеток); увеличение уводит перевал дальше в лес.
@export var spur_saddle_offset := 16.0
## Ширина седловины на гребне отрога (клеток); увеличение делает перевал шире и мягче.
@export var spur_saddle_width := 14.0
## Глубина понижения седловины (доля высоты отрога); увеличение углубляет перевал для дороги.
@export var spur_saddle_dip := 0.25
## Минимальная высота отрога противоположного берега (м); увеличение поднимает встречные мысы-кулисы.
@export var opp_spur_height_min_m := 55.0
## Случайная добавка высоты противоположных отрогов (м); увеличение делает кулисы разнообразнее.
@export var opp_spur_height_span_m := 37.0
## Минимальный вылет отрогов противоположного берега (клеток); увеличение отодвигает склон за рекой.
@export var opp_spur_reach_min := 24.0
## Разброс вылета противоположных отрогов (клеток); увеличение меняет ширину противоположного склона.
@export var opp_spur_reach_span := 22.0
## Отступ противоположных отрогов от кромки реки (клеток); увеличение бережёт пойменную бровку.
@export var opp_spur_start_pad := 1.5
## Сила отталкивания оси реки от поперечных отрогов (клеток); увеличение усиливает излучины вокруг мысов.
@export var bend_push_amp := 14.0

@export_group("Река и торцы")
## Средний продольный уклон долины и реки (доля); увеличение ускоряет спуск и поднимает верховье.
@export var river_target_grade := 0.0092
## Минимальный общий сброс высоты (ед. h); увеличение делает короткую долину круче.
@export var river_drop_min := 0.095
## Максимальный общий сброс высоты (ед. h); увеличение позволяет длинным мирам иметь больший перепад.
@export var river_drop_max := 0.43
## Высота дна у финиша над уровнем моря (ед. h); увеличение поднимает всю долину выше над морем.
@export var river_bot_h := 0.070
## Длина крупных полок и сливов (клеток); увеличение делает смены уклона более длинными.
@export var slope_slow_scale := 210.0
## Длина средних волн уклона (клеток); увеличение сглаживает переходы между полками.
@export var slope_med_scale := 85.0
## Минимальная доля уклона на спокойных полках; увеличение делает полки круче и быстрее.
@export var slope_shelf_min := 0.24
## Размах ускорения уклона на сливах; увеличение усиливает контраст полок и спусков.
@export var slope_drop_span := 1.56
## Длина волны крупных S-образных колен долины (клеток); увеличение делает повороты длиннее.
@export var valley_swing_wave := 500.0
## Амплитуда крупных S-образных колен долины (клеток); увеличение делает долину извилистее.
@export var valley_swing_amp := 0.0
## Фазовое искривление S-колен шумом (рад); увеличение нарушает регулярность синусоиды.
@export var valley_swing_warp := 1.6
## Масштаб шумового сдвига фазы S-колен (клеток); увеличение делает смены ритма реже.
@export var valley_swing_warp_scale := 340.0
## Длина крупных излучин реки (клеток); увеличение делает повороты долины шире.
@export var meander_slow_scale := 360.0
## Длина средних изгибов реки (клеток); увеличение делает русло плавнее.
@export var meander_med_scale := 145.0
## Предельная амплитуда излучин реки (клеток); увеличение делает реку более извилистой.
@export var meander_amp_max := 34.0
## Предел амплитуды излучин как доля ширины плана; увеличение разрешает более сильные изгибы.
@export var meander_amp_width_frac := 0.13
## Начало отворота реки за стартом (клеток от y=0); увеличение раньше уводит реку в теснину.
@export var head_bend_y := 24.0
## Длина отворота реки за стартом (клеток); увеличение делает загиб за стартом плавнее.
@export var head_bend_span := 72.0
## Боковой уход реки за стартом (клеток); увеличение сильнее прячет исток за поворот.
@export var head_bend_shift := 24.0
## Длина закрытого поворота реки перед финишем (клеток); увеличение раньше начинает финальный изгиб.
@export var finish_bend_len := 118.0
## Боковой уход реки за лесистый мыс на финише (клеток); увеличение сильнее уводит реку за мыс.
@export var finish_bend_shift := 44.0
## Минимальный отступ оси реки от боковых краёв плана (клеток); увеличение держит реку ближе к центру.
@export var axis_margin_normal := 42.0
## Минимальный отступ оси реки со стороны дороги (клеток); увеличение оставляет шире лесной коридор.
@export var axis_margin_road := 84.0
## Минимальный отступ оси реки со стороны противоположного берега (клеток); увеличение даёт запас до края плана.
@export var axis_margin_opp := 68.0
## Минимальный отступ оси от края на финишном повороте (клеток); увеличение ограничивает уход за мыс.
@export var axis_margin_bend := 28.0
## Ширина мягкого скругления у границ допустимого коридора оси (клеток); увеличение сглаживает крайние излучины.
@export var axis_soft_margin := 26.0
## Полуширина реки в верховье (клеток); увеличение делает реку у старта шире.
@export var river_hw_start := 1.65
## Полуширина реки в низовье (клеток); увеличение делает реку у финиша шире.
@export var river_hw_end := 4.15
## Показатель темпа расширения реки; увеличение задерживает расширение ближе к низовью.
@export var river_hw_power := 0.85
## Амплитуда естественных сужений и плёсов; увеличение усиливает игру ширины реки.
@export var river_hw_mod := 0.16
## Минимально допустимая полуширина реки (клеток); увеличение не даёт реке становиться узким ручьём.
@export var river_hw_min := 1.35
## Максимально допустимая полуширина реки (клеток); увеличение позволяет более широкие плёсы.
@export var river_hw_max := 5.2
## Базовая глубина центра русла (м); увеличение углубляет реку по всей длине.
@export var river_depth_base_m := 1.75
## Дополнительная глубина на каждую клетку полуширины (м); увеличение делает широкое низовье глубже.
@export var river_depth_per_hw_m := 0.32
## Шаг вершин 3D-ленты воды (клеток); увеличение упрощает сетку воды, уменьшение делает повороты глаже.
@export var river_ribbon_step := 1.5
## Заход кромки водной ленты в берег (м); увеличение усиливает защиту от щелей на крутых берегах.
@export var river_ribbon_margin_m := 3.2
## Запас отметки водных клеток за полушириной (клеток); увеличение расширяет непроходимую полосу русла.
@export var river_mask_pad := 0.25
## Запретная полоса для редких озёр вокруг реки (клеток); увеличение отодвигает озёра дальше от русла.
@export var lake_exclude_margin := 22.0
## Отступ подъёма горного цирка за стартом (клеток за y=0); увеличение отодвигает замыкающую стену назад.
@export var cirque_start := 6.0
## Дистанция выхода цирка за стартом на полную высоту (клеток); увеличение делает замыкание положе.
@export var cirque_end := 190.0
## Высота горного цирка за стартом (ед. h); увеличение делает замыкающий хребет выше.
@export var cirque_height := 0.34
## Отступ подъёма дальней гряды за финишем (клеток за y=H); увеличение отодвигает гряду дальше за поворот.
@export var finish_ridge_start := 6.0
## Дистанция выхода дальней гряды на полную высоту (клеток); увеличение делает замыкающий склон положе.
@export var finish_ridge_end := 210.0
## Высота замыкающей гряды за финишем (ед. h); увеличение поднимает горный фон за поворотом.
@export var finish_ridge_height := 0.28

@export_group("Климат и экология")
## Режим расчёта широты: "fixed" (как в Типе 1) или "span" (растяжка от lat_start до lat_end).
@export var lat_mode := "fixed"
## Широта у верховья в режиме "span"; увеличение делает старт теплее и лиственнее.
@export var lat_start := 0.28
## Широта у низовья в режиме "span"; увеличение делает финиш теплее и лиственнее.
@export var lat_end := 0.46
## Базовая широта в режиме "fixed"; увеличение сдвигает весь мир в более тёплый пояс.
@export var lat_base := 0.5
## Строка центра широты в режиме "fixed"; увеличение сдвигает климатическую ось вниз.
@export var lat_center := 383.5
## Клеток на единицу широты в режиме "fixed"; увеличение ослабляет климатический градиент.
@export var lat_cells := 3072.0
## Базовая экологическая высота дна долины (> 0.12 убирает болота); увеличение переводит долину в более горный пояс.
@export var eco_base := 0.135
## Доля остаточного похолодания верховьев относительно низовья; увеличение делает верховья хвойнее.
@export var eco_residual := 0.12
## Падение температуры с высотой в OuterLand; увеличение опускает границу снега и тундры на дальних горах ниже.
@export var outer_temp_lapse := 0.6
## Высотный порог заснеженных пиков (PEAK); увеличение превращает высокие вершины в серые гольцы без белой шапки.
@export var peak_elev := 0.65
## Порог перехода холодных вершин в PEAK; увеличение поднимает границу вечной мерзлоты вверх.
@export var peak_cold_elev := 0.46
## Температурный порог перехода тайги/тундры в снег (SNOW); уменьшение оставляет гольцы бесснежными при низком холоде.
@export var snow_temp := 0.12
## Порог голых скал и курумов (ROCK); изменение сдвигает высоту обнажения скальных поясов.
@export var rock_elev := 0.45
## Порог крутизны обнажения скал выше rock_elev; уменьшение расширяет каменистые осыпи на склонах.
@export var rock_slope := 0.48
## Верхняя граница леса / переход к горной тундре и гольцам; увеличение поднимает лес выше на склоны.
@export var treeline_elev := 0.45

@export_group("Дорога и якоря")
## Путь к собственному ресурсу настроек дорог (RoadTuning); пустая строка использует resources/road_tuning.tres.
@export var road_tuning_path := ""
## Вид маршрута экспедиции из RoadTuning ("road", "trail", "mountain").
@export var expedition_route_kind := "road"
## Разрешить разрежённые неровности и выбоины RoadGaps на маршруте экспедиции.
@export var allow_road_gaps := true
## Отступ первых и последних якорей от старта и финиша (клеток); увеличение удлиняет спокойные концы маршрута.
@export var anchor_end_margin := 46.0
## Минимальный просвет между отрогами для вставки берегового узла (клеток); увеличение сокращает выходы к воде.
@export var anchor_basin_gap := 88.0
## Минимальное продольное расстояние между соседними якорями (клеток); увеличение делает линию дороги размашистее.
@export var anchor_min_dy := 68
## Запас продольного разгона на клетку бокового ухода; увеличение делает переходы «берег ↔ лес» положе.
@export var anchor_diag_ratio := 2.1
## Минимальный отступ береговых якорей от кромки реки (клеток); увеличение отодвигает дорогу от самой воды.
@export var anchor_river_pad_min := 4.2
## Максимальный отступ береговых якорей от кромки реки (клеток); увеличение расширяет прибрежную полосу.
@export var anchor_river_pad_max := 11.5
## Минимальная глубина лесных якорей от оси реки (клеток); увеличение уводит дорогу глубже в лес.
@export var anchor_inland_min := 32.0
## Максимальная глубина лесных якорей от оси реки (клеток); увеличение подводит дорогу ближе к стене.
@export var anchor_inland_max := 58.0
## Вероятность начать чередование с ухода в лес; увеличение чаще уводит дорогу в лес сразу после старта.
@export var anchor_inland_start_chance := 0.7
## Вероятность задержаться в лесу на два отрога подряд; увеличение удлиняет лесные отрезки.
@export var anchor_inland_streak_chance := 0.55
## Вероятность задержаться у реки на два узла подряд; увеличение удлиняет береговые отрезки.
@export var anchor_river_streak_chance := 0.30
## Боковой запас окна поиска A* между якорями (клеток); увеличение даёт поиску больше свободы обхода.
@export var segment_win_x := 56
## Продольный запас окна поиска A* между якорями (клеток); увеличение расширяет окно поиска.
@export var segment_win_y := 42
## Ограничение захода дороги назад за старт и вперёд за финиш (клеток); увеличение допускает шире разворот у концов.
@export var segment_end_y_cap := 6
## Минимальный отступ появления игрока от центра лагеря старта (м); увеличение ставит игрока дальше по дороге.
@export var opening_min_m := 14.0
## Максимальная дальность поиска прямого выезда вниз по долине (м); увеличение расширяет окно выбора старта.
@export var opening_max_m := 110.0

@export_group("Поселения и редкие места")
## Верхняя граница зоны лагеря старта (клеток от y=0); увеличение сдвигает старт глубже в долину.
@export var start_y_min := 42
## Нижняя граница зоны лагеря старта (клеток); увеличение расширяет поиск ровной площадки старта.
@export var start_y_max := 72
## Минимальный отступ лагеря старта от кромки реки (клеток); увеличение отодвигает лагерь от воды.
@export var start_sd_min := 5.5
## Максимальный отступ лагеря старта от кромки реки (клеток); увеличение позволяет поставить лагерь глубже в лес.
@export var start_sd_max := 16.0
## Минимальное число домов в лагере старта; увеличение делает стартовый лагерь крупнее.
@export var start_homes_min := 3
## Максимальное число домов в лагере старта; увеличение добавляет постройки на старте.
@export var start_homes_max := 4
## Наибольший отступ финишной базы от края плана y=H (клеток); увеличение сдвигает финиш раньше поворота.
@export var finish_from_end_max := 114
## Наименьший отступ финишной базы от края плана y=H (клеток); увеличение отодвигает финиш дальше от края.
@export var finish_from_end_min := 72
## Минимальный отступ финишной базы от кромки реки (клеток); увеличение отодвигает базу от берега.
@export var finish_sd_min := 5.5
## Максимальный отступ финишной базы от кромки реки (клеток); увеличение позволяет поставить базу выше.
@export var finish_sd_max := 15.0
## Минимальное число домов на финишной базе; увеличение делает финишную базу крупнее.
@export var finish_homes_min := 4
## Максимальное число домов на финишной базе; увеличение добавляет постройки на финише.
@export var finish_homes_max := 6
## Порог длины плана (клеток) для полного набора редких мест; увеличение оставляет меньше точек на средних картах.
@export var sites_full_min_h := 1500
## Число рыбацких домиков с причалом у финиша (0 выключает причал).
@export var site_fishing_count := 1
## Число дозорных вышек на короткой карте; увеличение добавляет вышки на dev-маршруте.
@export var site_towers_short := 1
## Число дозорных вышек на полном маршруте; увеличение добавляет ориентиры на отрогах.
@export var site_towers_full := 2
## Число горных приютов у дороги (0 выключает приют).
@export var site_shelters_count := 1
## Число смотровых лавок на короткой карте; увеличение добавляет видовые точки.
@export var site_benches_short := 2
## Число смотровых лавок на полном маршруте; увеличение добавляет видовые точки вдоль дороги.
@export var site_benches_full := 3
## Хутор на противоположном берегу для масштаба (0 выключает хутор за рекой).
@export var site_opposite_farm_count := 1
## Зона поиска берега под рыбацкий причал выше финиша (клеток); увеличение расширяет поиск вверх по реке.
@export var fishing_search_back := 84
## Зона поиска берега под рыбацкий причал ниже финиша (клеток); увеличение расширяет поиск к повороту.
@export var fishing_search_fwd := 56
## Минимальное расстояние от рыбацкого домика до центра финишной базы (клеток); увеличение отодвигает причал от домов.
@export var fishing_min_dist := 7.0
## Максимальное расстояние от рыбацкого домика до финишной базы (клеток); увеличение расширяет радиус поиска берега.
@export var fishing_max_dist := 86.0

@export_group("Большая карта")
## Соотношение сторон плана, при котором карта M открывается вокруг игрока; увеличение сужает автозум на более длинные карты.
@export var map_elongated_ratio := 1.8
## Минимальная видимая длина долины при открытии карты M (м); увеличение отдаляет стартовый обзор.
@export var map_corridor_min_m := 1800.0
## Видимая длина долины как кратность её ширины при открытии карты M; увеличение отдаляет стартовый обзор.
@export var map_corridor_width_mul := 2.3

@export_group("Полотно и микрорельеф")
## Множитель высоты кочек и глубины колеи лесной тропы RoadBump (1.0 — базовое значение Типа 1).
@export var trail_bump_scale := 1.0
## Доля клеток 2.5 м с грязевыми выбоинами на лесной тропе (0.0 — как в Типе 1).
@export var trail_forest_holes := 0.0
## Переключает колею полотна с двух автомобильных колей (RUT_AT) на одну узкую колею singletrack по центру (across = 0).
@export var trail_single_rut := false
## Ширина центральной велоколеи в долях полуширины полотна.
@export var trail_single_rut_w := 0.26
## Усиление тёмно-бурого влажного суглинка в ядре лесного singletrack (0.0 — вид Типа 1).
@export var trail_loam_darkness := 0.0
## Сила матового влажного блеска в пробитой колее и ямах лесной тропы (0.0 — без усиления).
@export var trail_wet_gloss := 0.0
## Плотность рваной каймы рыжего опада по краям лесной тропы 0.35..1.1 полуширины (0.0 — без усиления).
@export var trail_edge_litter := 0.0
## Усиление ближних микронормалей кочковатой лесной почвы вне полотна (0.0 — вид Типа 1).
@export var forest_micro_bump := 0.0
## Оттенок рыжей хвойно-лиственной подстилки по кромке лесной тропы.
@export var trail_russet_litter := Color(0.46, 0.24, 0.10)

@export_group("Растительность")
## Вложенный конфиг плотного зонирования растительности, подлеска и притропных объектов.
@export var vegetation: WorldVegetationConfig = null

@export_group("Атмосфера и сезон")
## Вложенный конфиг пасмурного неба, осенней палитры, тумана и 3D LUT (null для Типа 1).
@export var atmosphere: WorldAtmosphereConfig = null


func relief_params() -> PackedFloat64Array:
	var p := PackedFloat64Array()
	p.resize(RP_COUNT)
	p[RP_WARP_SCALE] = warp_scale
	p[RP_WARP_AMP] = warp_amp
	p[RP_BANK_HEIGHT] = bank_height
	p[RP_BANK_DECAY] = bank_decay
	p[RP_DAMP_START] = channel_damp_start
	p[RP_DAMP_END] = channel_damp_end
	p[RP_FOLDS_FINE_SCALE] = folds_fine_scale
	p[RP_FOLDS_BROAD_SCALE] = folds_broad_scale
	p[RP_FOLDS_BROAD_AMP] = folds_broad_amp
	p[RP_FOLDS_FINE_AMP] = folds_fine_amp
	p[RP_BENCH_START_PAD] = bench_start_pad
	p[RP_BENCH_RISE_LIN] = bench_rise_lin
	p[RP_BENCH_RISE_QUAD] = bench_rise_quad
	p[RP_SPUR_START_PAD] = spur_start_pad
	p[RP_SPUR_SADDLE_OFFSET] = spur_saddle_offset
	p[RP_SPUR_SADDLE_WIDTH] = spur_saddle_width
	p[RP_SPUR_SADDLE_DIP] = spur_saddle_dip
	p[RP_WALL_ROAD_START] = wall_road_start
	p[RP_WALL_ROAD_END] = wall_road_end
	p[RP_WALL_ROAD_BASE_START] = wall_road_base_start
	p[RP_WALL_ROAD_BASE_END] = wall_road_base_end
	p[RP_WALL_ROAD_BASE_H] = wall_road_base_h
	p[RP_WALL_OPP_START] = wall_opp_start
	p[RP_WALL_OPP_END] = wall_opp_end
	p[RP_WALL_OPP_BASE_START] = wall_opp_base_start
	p[RP_WALL_OPP_BASE_END] = wall_opp_base_end
	p[RP_WALL_OPP_BASE_H] = wall_opp_base_h
	p[RP_END_WALL_MTN_MUL] = end_wall_mountain_mul
	p[RP_WALL_MTN_AMP] = wall_mountain_amp
	p[RP_WALL_FOLDS_SUPPRESS] = wall_folds_suppress
	p[RP_CLOSED_LIFT] = channel_closed_lift
	p[RP_HEIGHT_FLOOR] = height_floor
	p[RP_HEIGHT_KNEE] = height_knee
	p[RP_HEIGHT_SOFT] = height_soft
	p[RP_GULLY_SCALE_X] = gully_scale_x
	p[RP_GULLY_SCALE_Y] = gully_scale_y
	p[RP_GULLY_WIDTH] = gully_width
	p[RP_GULLY_DEPTH] = gully_depth
	p[RP_GULLY_WALL_MIN] = gully_wall_min
	p[RP_GULLY_WALL_MAX] = gully_wall_max
	p[RP_COULOIR_SCALE_X] = couloir_scale_x
	p[RP_COULOIR_SCALE_Y] = couloir_scale_y
	p[RP_COULOIR_WIDTH] = couloir_width
	p[RP_COULOIR_DEPTH] = couloir_depth
	p[RP_COULOIR_PATCH_SCALE] = couloir_patch_scale
	p[RP_COULOIR_PATCH_MIN] = couloir_patch_min
	p[RP_COULOIR_PATCH_MAX] = couloir_patch_max
	p[RP_COULOIR_WALL_MIN] = couloir_wall_min
	p[RP_COULOIR_WALL_MAX] = couloir_wall_max
	p[RP_OUTER_RIDGE_ROAD_START] = outer_ridge_road_start
	p[RP_OUTER_RIDGE_OPP_START] = outer_ridge_opp_start
	p[RP_OUTER_RIDGE_SPAN] = outer_ridge_span
	p[RP_OUTER_RIDGE_BASE_H] = outer_ridge_base_h
	p[RP_OUTER_RIDGE_MTN_AMP] = outer_ridge_mtn_amp
	p[RP_OPP_SPUR_START_PAD] = opp_spur_start_pad
	return p


func site_counts(plan_height: int) -> Dictionary:
	if not single_road:
		return {}
	var full := plan_height >= sites_full_min_h
	return {
		fishing = site_fishing_count,
		tower = site_towers_full if full else site_towers_short,
		shelter = site_shelters_count,
		bench = site_benches_full if full else site_benches_short,
		opposite_farm = site_opposite_farm_count,
	}


## Детерминированный хеш всех параметров географии/рельефа/реки/климата: правка любого из них перестраивает кэш с geo.
func geo_cache_digest() -> String:
	var values: Array = [
		id, plan_width, Array(plan_heights), dev_height, full_plan_territory, pick_start,
		valley_relief, valley_river, corridor_shift, Array(relief_params()),
		basin_scale, basin_narrow, basin_wide, bend_asym_gain, bend_wall_pull, bend_terrace_push, min_road_corridor,
		spur_first_y_min, spur_first_y_span, spur_end_margin, spur_gap_min, spur_gap_span,
		spur_half_len_min, spur_half_len_span, spur_height_min_m, spur_height_span_m,
		spur_reach_min, spur_reach_span,
		opp_spur_height_min_m, opp_spur_height_span_m, opp_spur_reach_min, opp_spur_reach_span, opp_spur_start_pad, bend_push_amp,
		river_target_grade, river_drop_min, river_drop_max, river_bot_h,
		slope_slow_scale, slope_med_scale, slope_shelf_min, slope_drop_span,
		valley_swing_wave, valley_swing_amp, valley_swing_warp, valley_swing_warp_scale,
		meander_slow_scale, meander_med_scale, meander_amp_max, meander_amp_width_frac,
		head_bend_y, head_bend_span, head_bend_shift, finish_bend_len, finish_bend_shift,
		axis_margin_normal, axis_margin_road, axis_margin_opp, axis_margin_bend, axis_soft_margin,
		river_hw_start, river_hw_end, river_hw_power, river_hw_mod, river_hw_min, river_hw_max,
		river_depth_base_m, river_depth_per_hw_m, river_ribbon_step, river_ribbon_margin_m,
		river_mask_pad, lake_exclude_margin,
		cirque_start, cirque_end, cirque_height, finish_ridge_start, finish_ridge_end, finish_ridge_height,
		lat_mode, lat_start, lat_end, lat_base, lat_center, lat_cells, eco_base, eco_residual, outer_temp_lapse,
		peak_elev, peak_cold_elev, snow_temp, rock_elev, rock_slope, treeline_elev,
	]
	return var_to_str(values).sha256_text().left(16)


## Детерминированный хеш всех параметров дороги, якорей, поселений и редких мест: правка перестраивает кэш с places.
func places_cache_digest() -> String:
	var values: Array = [
		single_road, road_tuning_path, expedition_route_kind, allow_road_gaps, home_is_first_settlement,
		anchor_end_margin, anchor_basin_gap, anchor_min_dy, anchor_diag_ratio,
		anchor_river_pad_min, anchor_river_pad_max, anchor_inland_min, anchor_inland_max,
		anchor_inland_start_chance, anchor_inland_streak_chance, anchor_river_streak_chance,
		segment_win_x, segment_win_y, segment_end_y_cap, opening_min_m, opening_max_m,
		start_y_min, start_y_max, start_sd_min, start_sd_max, start_homes_min, start_homes_max,
		finish_from_end_max, finish_from_end_min, finish_sd_min, finish_sd_max, finish_homes_min, finish_homes_max,
		sites_full_min_h, site_fishing_count, site_towers_short, site_towers_full,
		site_shelters_count, site_benches_short, site_benches_full, site_opposite_farm_count,
		fishing_search_back, fishing_search_fwd, fishing_min_dist, fishing_max_dist,
	]
	return var_to_str(values).sha256_text().left(16)


## Детерминированный хеш параметров генерации растительности: правка перестраивает слой nature.
func nature_cache_digest() -> String:
	return vegetation.cache_digest() if vegetation != null else "none"
