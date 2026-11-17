# Новые виды растительности: лещина, горная сосна, рябина (2026-11-17)

**Сверка с кодом.** Имена систем и файлов в репозитории проверены: `Biomes` (`scripts/data/biomes.gd`), `StageVegetation` (`scripts/world/stages/stage_vegetation.gd`), `ForestModels` (`scripts/render/forest_models.gd`), `Models` (`scripts/render/models.gd`), `UnderstoryModels` (`scripts/render/understory_models.gd` + сообщества `COMMUNITY`/`TEMPLATE`), `VegetationLayer` (`scripts/render/vegetation_layer.gd`), `VegetationPlacement` (`scripts/render/vegetation_placement.gd`), `ForestFloor` (`scripts/render/forest_floor.gd`), `ForestObstacles` (`scripts/game/forest_obstacles.gd`), `RoadObstacles` (`scripts/game/road_obstacles.gd`), `DistantForest` (`scripts/render/distant_forest.gd`), `AssetCatalog` (`scripts/render/asset_catalog.gd`), `WorldCache.SCHEMA_NATURE_VERSION` (`scripts/world/world_cache.gd`), `tools/bake_assets.gd`, `tools/tree_age_look.gd`, `tools/meadow_look.gd`, `tools/forest_scene_perf.gd`, `tools/control/check.gd`; в коде уже присутствуют возрастные формы высокого леса (`obj_s`, возрастной класс в `obj_v`, поле `ref`). Ветка: `NEW-ROAD`. Лиственница не добавлялась (исключена из задания 17.11).

## 1. Реализованные виды

### 1.1. Лещина (`Corylus avellana`) — `UnderstoryModels`
- **Модели**: `UnderstoryModels.HAZEL := 17` и `UnderstoryModels.HAZEL_TALL := 18` (`COUNT := 19`) в `scripts/render/understory_models.gd`, генератор `_hazel(variant, far)`:
  - Несколько расходящихся от основания стволов (5–6 вблизи, 4–5 вдали) с оголённой нижней частью стволов (`p.y >= base_h * 0.42`) и объёмными многоярусными группами листвы с просветами.
  - Разные высоты и асимметрия куста (`HAZEL` ~3.2 м, `280` треуг.; `HAZEL_TALL` до ~5.5 м, `324` треуг.).
  - Упрощённая дальняя форма сохраняет широкий многоствольный силуэт при малом бюджете геометрии (`44` и `54` треугольника).
  - Разметка `UV2.x`: структурные элементы `[0.0..0.44]`, детали `[0.54..0.96]`.
- **Размещение и сообщества**:
  - Веса в `UnderstoryModels.weights()` (`hazel_suit`), расширены таблицы `COMMUNITY` и `TEMPLATE`.
  - В `VegetationLayer`: усиление на широколиственных опушках (`rim`) и пятнах вдоль лесных троп (`patch > 0.44`) без образования сплошных стен, исключение из чисто хвойных и высокогорных открытых ячеек (`if conifer:`), вариации формы/оттенка, настройка ветра и теней (`_plant_wind`, `shadows`), исправление `custom_aabb` (`mesh_box` / `render_box`) и проверка `world.lake[cell] == 0` при кешировании `_open_valid`.
  - В `VegetationPlacement`: `HAZEL` и `HAZEL_TALL` включены в приоритет 1.
  - В `DistantForest`: учтены в подсчёте `woody` и `tall` в `scrub_site`.
- **Столкновения**: как и остальные декоративные формы подлеска (`UnderstoryModels`), лещина не создаёт стволовых препятствий физического слоя.

### 1.2. Горная сосна (`Pinus mugo`) — дерево
- **Регистрация и геометрия**: `Biomes.T_MUGO := 13`, `CROWN_RADIUS` (`0.52`), `ForestModels.NOMINAL` (`2.2` м), `Models.build_tree_defs()`. Генератор `ForestModels._mugo(variant)` в 4 узнаваемых формах стланика (без возрастных классов, высота `2.3–3.5` м, радиус кроны `2.78–4.39` м, `234–402` треугольника): компактная подушка, широкая раскидистая, асимметричная ветровая, стелющаяся по склону.
- **Размещение**: `StageVegetation` (`TRUNK[T_MUGO] = 0.24`, учет в `LOW_CROWN` в `clear_of_path`, субальпийский пояс `mugo_belt` в `place_chunk` с масштабом `0.74..1.30`, выбор в `_kind` на каменистых/субальпийских склонах, исключая голые скалы, снег и вершины).
- **Рендер и физика**:
  - `VegetationLayer`: `FAR_TRUNKLESS`, `BARK_PLATES`, `WIND`, без корневых лап у земли.
  - `ForestFloor`: `T_MUGO` учитывается как хвойная порода в `surface_image` и `canopy_image`.
  - `DistantForest`: отображение через `Form.BUSH` (`color.a = 0.0`) с расширенной подушкой (`r * 1.15`).
  - `ForestObstacles` и `RoadObstacles`: конечная высота столкновения ствола/куста (`base + 1.85 * s` вместо `INF`), исключена из дорожных корней.

### 1.3. Рябина (`Sorbus aucuparia`) — дерево второго яруса
- **Регистрация и геометрия**: `Biomes.T_ROWAN := 12`, `CROWN_RADIUS` (`0.48`), лёгкий осенний оттенок в `Biomes.leaf_tone()`, `ForestModels.NOMINAL` (`9.5` м), поддержка возрастных классов (`has_ages()`, 8 вариантов: молодые 4–5 `6.4–7.5` м, взрослые 0–3 `10.4–11.4` м в т.ч. многоствольный вариант 2, старые 6–7 `11.9–12.0` м; `184–570` треугольников).
- **Перистая листва и ягоды**: общая каталожная текстура `_pinnate_texture` (`textures[5]` в каталоге); на LOD0 через `_berry_cluster` и `#ifdef CUTOUT` (`UV.x > 1.5`, `cluster_uv` в `resources/vegetation.gdshaderinc`) рисуются гроздья оранжево-красных ягод с освещением от `COLOR.rgb`.
- **Размещение и дальний вид**: `StageVegetation` (`TRUNK[T_ROWAN] = 0.15`, масштаб `0.92`, второй ярус лиственных/смешанных лесов, опушки и поляны); в `DistantForest` — `Form.BROADLEAF`.

## 2. Каталог, кэш и тестовые инструменты
- Версия каталога: `AssetCatalog.VERSION := 12` (было `11`).
- Версия природного кэша: `WorldCache.SCHEMA_NATURE_VERSION := 18` (поверх `17` из `origin/NEW-ROAD`, коммит `7bbe931`).
- Пересобран `resources/catalog/standard.res` (`tools/bake_assets.gd`): `trees=82 settlements=21 LOD groups=138 bytes=2277630 exact roundtrip=true`.
- Обновлены инструменты и тесты под новые виды: `tools/bake_assets.gd`, `tools/tree_models_test.gd`, `tools/understory_models_test.gd`, `tools/asset_catalog_test.gd`, `tools/model_audit.gd`, `tools/tree_age_look.gd`, `tools/forest_scene_perf.gd`, `tools/meadow_look.gd`.

## 3. Проверки и производительность

Оборудование стенда: **NVIDIA GeForce GTX 1650 SUPER**, Vulkan 1.3.289 Forward+, Windows (второй ПК с Intel HD 4600 на месте не проверялся).

### 3.1. Постребейзные сборки, тесты и аудит (поверх `origin/NEW-ROAD` `7bbe931`)
- `dotnet build WorldGeneratorGodot.csproj` (из-за изменений `FastGrid.Relief.cs` в `origin/NEW-ROAD`) — 0 предупреждений, 0 ошибок.
- `--check-only` на изменённых скриптах (`vegetation_layer.gd`, `stage_vegetation.gd`, `world_cache.gd`, `distant_forest.gd`, `understory_models.gd`, `meadow_look.gd`) — код выхода `0`.
- `tools/bake_assets.gd` — `Asset catalog: trees=82 settlements=21 LOD groups=138 bytes=2277630 exact roundtrip=true`, код `0`.
- `tools/tree_models_test.gd` — `Total triangles LOD0/1/2: (21586, 5960, 2708)`, `Stored geometry arrays: 2343000 bytes`, `tree_models_test: 0 ошибок`, код `0`.
- `tools/understory_models_test.gd` — `Understory triangles/array bytes: (2072, 259552)`, `Floor triangles/array bytes: (2771, 324340)`, `understory_models_test: 0 ошибок`, код `0`.
- `tools/understory_test.gd` — `understory_test: 0 ошибок`, в выдаче по формам присутствуют близкие (`2`) и дальние (`359` + `99`) экземпляры лещины рядом с новыми формами дерновин (`50`, `305`).
- `tools/asset_catalog_test.gd` — `private instance lists=true`, `LOD0/1/2 pixels identical=true`, `failures=0`, код `0`.
- `tools/model_audit.gd` — код `0`, `Zero-idx tris: 0`, `Zero-area tris (<1e-10): 0`, `Unused verts: 0`; лещина `HAZEL` (`280` треуг. / far `44`), `HAZEL_TALL` (`324` треуг. / far `54`).

### 3.2. Визуальные и производительные прогоны
- Постребейзный `tools/meadow_look.gd -- --tag after_rebased` (код `0`): `moving.fps = 167.65`, `gpu_ms = 5.36`, `cpu_ms = 1.33`, `draw_calls = 464.18`, `primitives = 2,210,067`, `understory_triangles = 276046` (включая `15` + `7` ближних и `576` + `183` дальних экземпляров лещины вместе с групповыми формами дерновин `2122 x 32`); осмотрены кадры `after_rebased_foothill.png`, `forest_trail.png`, `meadow.png`, `road.png`.
- До ребейза поверх `7d2bfbe` (одни и те же модели и `standard.res`):
  - `tools/tree_age_look.gd` (код `0`): осмотрены `rowan_side.png`, `rowan_eye.png`, `mugo_side.png`, `mugo_eye.png`. Силуэты рябины (включая многоствольный вариант 2 и гроздья LOD0) и 4 формы горной сосны читаются без торчащих сучьев и артефактов.
  - `tools/meadow_look.gd` (`before` до правок vs `after` до финальной правки `leaf_r`): `before` `moving.fps = 186.93`, `understory_triangles = 174363`; `after` `176.68`, `173379`.
  - `tools/forest_scene_perf.gd -- --eye 27.4` (код `0`): `moving.fps = 136.97` (`gpu_ms = 6.60`, `cpu_ms = 3.58`, `p99_ms = 10.95`, `draw_calls = 2119.40`, `primitives = 2,982,150`), `still.fps = 142.41` (`gpu_ms = 6.09`, `cpu_ms = 3.14`, `draw_calls = 2053.0`, `trash_left = 0`), дальние лещины `818 x 44 = 35992` и `180 x 54 = 9720`.
  - `tools/control/check.gd` (`Север-1234@512`, код `0`, `177 с`): `load_s = 44.2 с`, `look = 119.3 FPS` (`low1 = 99.5`, `p95 = 9.54 мс`, `p99 = 10.06 мс`, `over_16_7 = 0`, `over_33_3 = 0`), `road = 99.7 FPS` (`low1 = 53.0`, `p95 = 14.58 мс`, `p99 = 18.87 мс`), `draw_calls = 1289`, `primitives = 2,320,460`, `veg_gap min_m = 450.0`, `grass_lag capped = 0`; снимки `road`, `trail`, `forest`, `mountain_road`, `peak` проверены (результаты записались в gitignored-папку `tools/control/runs/15.0`, т.к. `control.gd` ждёт `--out <dir>` через пробел).

### 3.3. Предуществующие сбои и ограничения прогонов
- `tools/forest_collision_test.gd` (код `1`): 6 проверок столкновений со стволами и пешие проверки бревна пройдены, не пройдены давние проверки (`велосипед 6 м/с в бревно z -26.49`, т.к. бревно `0.42 м < CLIMB_MAX = 0.45`, и три порога плотности леса `0%` для мира `"abc"`, см. также `docs/PATCH_8_9_EXTRA.md`).
- `tools/nature_test.gd`: вышел по внешнему таймауту `90 с` при собственном watchdog `300 с` (запускает `allow_fast = false` дважды); по правилам `CLAUDE.md` повторно не запускался.
- `tools/vegetation_test.gd`: завершился на предуществующей ошибке доступа к отсутствующему ключу `'cursor'` (строка 80, ранний возврат в `_apply_chunk` до 180 с watchdog); по правилам `CLAUDE.md` повторно не запускался.

## 4. Правки вечера 17.11: смена форм подлеска и распределение

### 4.1. Грубые формы у дороги, «после ожидания» подробные
- **Причина.** Ближняя или упрощённая форма подлеска (кусты, подрост, лещина, куртины открытых мест — их дальняя форма с 17.11 группа кочек-«шатров», мох, папоротник, детали подстилки) выбиралась при раскладке по расстоянию до её центра (`_fill_at`). Раскладка травы и подлеска на высоком качестве готовится 3,5–5 с (`meadow_look`: `detail_fill_s`), за это время на 12 м/с игрок уходит на ~45 м, и упрощённые формы оказывались у колёс до следующего снимка. Стоя на месте, снимок обновляется только после смены упреждения — отсюда «после ожидания».
- **Исправление (как LOD деревьев).** Растение у границы смены формы — с запасом на всю капсулу снимка (`_fill_at` + упреждение) и `FORM_SLACK` = шаг обновления 8 м — кладётся парой: ближняя и упрощённая форма, обе помечены `INSTANCE_CUSTOM.z + 2` (`VegetationLayer._put_twin`). Шейдер (`form_switch` в `vegetation.gdshaderinc`) делит пиксели пары по нынешнему расстоянию до игрока (`veg_center`) той же сеткой порогов, что уровни LOD деревьев; полоса `FORM_BAND` = 0,25 границы. Вне полосы — одна форма, как прежде; нет места в буфере ближних — одна упрощённая. Новых узлов и вызовов отрисовки нет.
- **Проверено** `meadow_look -- --shot-moving 8` (езда 12 м/с, «было» тем же кодом `--no-twins`): упрощённых форм ближе 0,85 границы от игрока 168 → 0 (пар 168, форму выбирает шейдер); GPU 5,15 → 5,42 мс, FPS 166 → 160 (в пределах шума).

### 4.2. Новые виды дополняют, а не вытесняют
- **Горная сосна** выбиралась в `_kind` первой с долей до 75 % в лесах выше e 0,2: на «Север-1234» и «Туман-4821» (фикстуры `road_relief`, раскладка заново) в поясе e 0,26–0,34 сосны стало на 35 % меньше, выше 0,34 — на 46 %, берёз — на 55 %. Теперь прибавка густоты пояса стланика (`mugo_belt`) — только стланик (доля проверки rng выше `mugo_from`), а прежняя густота остаётся прежним видам; примесь стланика в прежнем древостое — до 10 %. Итог: сосны в верхних поясах −13…−16 % (вместе с примесью рябины), стланик там же 3–6 тыс. объектов на мир. `SCHEMA_NATURE_VERSION` 18 → 19.
- **Лещина** входила в веса сообществ и подлеска и отнимала у кустов, подроста и куртин до трети мест, а её занятое место (вся крона до 5 м) вычищало луг под ней (`meadow_look`, вид луга: кусты 661 → 455, подрост 175 → 119, высокотравье 2704 → 1860). Теперь густота растёт на долю её весов (`_fill_forest_cell`, `_fill_open_cell`, дальние заросли `DistantForest.scrub_site` — так же), а место занимает пучок стволов (`HAZEL_CORE` = 0,4 ширины кроны). Стало: кусты 608, подрост 161, высокотравье 2440, лещина 989.
- **Рябина** — примесь 5–8 % деревьев (дуб, берёза, сосна −4…−6 %), оставлена.
