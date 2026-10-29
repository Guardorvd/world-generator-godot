# Ревизия состояния проекта (29.10.2026, ветка visuals)

Анализ по коду, без запусков. Что исправлено сразу — в конце, остальное — список с предложениями.

## 1. Главные модули: что входит, что выходит

Слои по `docs/GODOT_NOTES.md`: `core` → `data` → `world` → `map` → `game` → `render` → `ui`
(папки `trails` и `lab` в правиле не названы; по факту `trails` стоит между `world` и `game`, `lab` — рядом с `render`).

| Модуль | Вход | Выход | Кто владеет данными |
|---|---|---|---|
| `WorldGenerator` (`world`) | зерно, размер плана | `WorldData`: поля клеток (`h`, `filled`, `elev`, `ocean`, `lake`, `river`, `biome`, `cost`, `path_mask`, …), списки (`settlements`, `bridges`, `tunnels`, `trails`, `peaks`, `sites`, `lakes`), растительность `obj_*` | `WorldData` после генерации |
| `FastGrid` (C#, `core`) | массивы и числа (размеры, `TILE`, `HS` передаются аргументами) | массивы того же размера | ничего не хранит, кроме кэша A* |
| `WorldCache` (`world`) | `WorldData` после генерации | файлы `user://world_cache` (zstd + SHA-256), восстановленный `WorldData` | диск; ключ = версия + `FORMAT` + зерно + размер |
| `StageTrailPlan` / `BikePark` (`world`/`trails`) | `WorldData`, закрытая копия рельефа | `w.trail_plan` (маршруты, площадка) | `WorldData.trail_plan` |
| `WorldLoader` (`render`) | зерно, размер, `ServiceScope` | словарь `loaded`: `world`, `heights`, `terrain_image`, `forest_surface`, `terrain_chunks`, `terrain_arrays`, `water_arrays`, `map_image`, `timings` | передаёт всё в `GameWorld` |
| `Heightfield` (`game`) | `WorldData` (+ `RoadBed`, мосты/туннели) | высоты в метрах: `ground_at`, `surface_at`, `depth_at`, `wall_at`, `ceiling_at` | свой экземпляр на мир; у генератора — свой (`w.base_heights`) |
| `PlayerState` / `BikeRide` (`game`) | ввод, `Heightfield`, `WorldData` | положение (м), скорость, флаги | `GameWorld` (такт физики 60 Гц) |
| `GameWorld` (`render`) | `loaded`, ввод, настройки | кадр, вызовы `Hud`, сохранение (`save_state`) | игровой цикл; держит `world`, `heights`, игрока, велосипед |
| `RegionStream` (`render`) | `WorldData`, рельеф, журнал областей | области за краем: поля, поселения, дороги, трассы; журнал `user://regions/<сид>/ledger.bin` | свой `ledger`; `world.outer.set_ledger` — копия для чтения |
| `VegetationLayer` (`render`) | `WorldData.obj_*`, `OuterLand.veg`, положение игрока | узлы растительности, `obstacles`, `bumps` | свои словари кусков |
| `Hud` (`ui`) | вызовы `GameWorld` (`set_player`, `set_hints`, `update_info`, …), `Hud.world` | экран, сигнал `travel_requested` | `visited`, `goal` |
| `SaveGame` (`game`) | `GameWorld.save_state()` | файл `user://saves/<sha>.<slot>.save` (`WGS1`, SHA-256, `.bak`) | диск |
| `GameSettings` (`game`) | `user://settings.cfg` | значения настроек | `ServiceScope.settings` |

## 2. Данные, которые хранятся в нескольких местах

1. **Положение игрока**: `PlayerState.x/z` (истина) → `GameWorld._prev` (для интерполяции) → `Hud.px/pz/yaw` (копия на кадр, `set_player`). Копия в HUD обновляется каждый кадр; при паузе или телепорте до первого кадра HUD показывает старое место. Безопасно, но лучше читать из одного места.
2. **Посещённые места**: `Hud.visited` (по ним — фото, быстрые переезды, подписи мест) и `Quests.known`; `PlaceNames` получает обе таблицы каждый кадр. В сохранение идут обе. Логика «известно ли место» размазана по трём модулям. Предложение: один объект знаний игрока (`visited` + `known`) в `game`, HUD и подписи только читают его.
3. **Журнал областей**: `RegionStream.ledger` и его копия в `world.outer` (`set_ledger` после каждого изменения). Пока вызов идёт сразу за каждой заменой `ledger`, расхождения нет, но правило держится на дисциплине. Предложение: `OuterLand` читает журнал через `RegionStream`, а не хранит его.
4. **Рельеф**: `w.base_heights` (рельеф генератора, без полотна дорог) и игровой `Heightfield` (с `RoadBed`). Разделение намеренное (см. 4.3, 9.7): тот, кто читает не тот экземпляр, получит землю без полотна.
5. **Константы рельефа в C#** (`FastGrid.cs`: `Macro`, `LandBias`, `SeaRaw`, `Valley`, …) — копии `StageRelief`. Проверено скриптом: все 30 значений совпадают с GDScript. Правка одной стороны без другой молча даст разные миры в C#- и `--gdscript`-сборке. Предложение: передавать их из GDScript аргументами, как уже сделано с `TILE`/`HS`.
6. **`TILE`, `HS`** объявлены в 20 файлах, но все как `GameConfig.TILE`/`GameConfig.HS`: значение одно, это просто короткие имена.
7. **Состояние камеры**: 16 свойств `GameWorld` (`_cam_y`, `_cam_dist`, `_speed_rush`, `_trauma`, …) — сквозные get/set на приватные поля `PlayerCameraController`. Нужны тестам (`feel_test`, `reported_bugs_test`). Две точки входа к одному состоянию.

## 3. Одновременная запись одних и тех же данных

- **Журнал областей** (`RegionStream._persist`): запись идёт задачей `WorkerThreadPool` через `ledger.bin.tmp`. Новая задача запускалась без ожидания предыдущей. Сейчас две записи подряд не пересекаются по ходу игры (следующая область стартует только после записи), но `_persist` вызывается из двух мест: при закреплении области и при публикации трассы. **Исправлено**: `_persist` сначала дожидается прошлой записи.
- **Подготовка области** работает на снимке журнала (`ledger.duplicate()`), а результат переносит поля, загруженные или выгруженные за это время (`_apply`). Перетирания нет.
- **`TrailRouter._prepared`** — статический кэш общий для всех потоков. Его пишут поиск трассы стартовой области (поток загрузки) и трассы областей (задача `RegionStream`). Одновременно они не идут (области стартуют после загрузки), но защиты нет. Предложение: кэш в экземпляре или под `Mutex`, как `StructuresBuilder._build_lock`.
- **`StageTrailPlan.skip`** — статический словарь, пишет `WorldLoader`, читает генерация. Общая очередь — та же задача загрузки, гонки нет.
- **Генерация после климата** (`after_climate`: краска, высоты, меши параллельно): по 2.0 поток не читает того, что пишет этап троп. Держится на правиле, проверка — только хеши `check.gd`.
- **`OuterLand.chunks`** — только главный поток (так записано в 1.9.5), `VegetationLayer` читает в потоке кольцо клеток, которое не меняется.

## 4. Типы, форматы и единицы на границах

- **Клетки и метры.** `WorldData`, места (`place.x/y`), `Quests.SPOT_MIN`/`FAR` — в клетках; игрок, камера, `Heightfield`, `Quests.SHOT_REACH`, снимки (`place.pos`) — в метрах. Перевод везде через `TILE`. Опасное место — `Quests`: константы в клетках и в метрах лежат рядом, единица видна только из комментария.
- **Высоты.** `WorldData.h/filled/elev` — доли (`× HS` = метры суши, `× OCEAN_DEPTH` под водой); `OuterLand.h` в единицах карты, в метры переводит `Heightfield.outer_meters` (так и задумано в 1.9.9.1). Ошибок перевода в коде не найдено.
- **float32 и float64.** `Vector2`/`Vector3` в Godot — float32, а `float` в GDScript — 64 бита. Положение при скольжении уже идёт через `PackedFloat64Array` (2.2). Остальные `Vector2` с мировыми метрами (подписи, карты, регионы) допустимы: на 100 км точность около 8 мм. Новые настройки не стоит хранить в `Vector2`: значение вроде 0.6 в нём округляется.
- **Сущности.** `settlements`, `bridges`, `tunnels` в `WorldData` — типизированные (`SettlementData`, `BridgeData`, `TunnelData`), старые словари переводятся при присваивании (`architecture_test` это проверяет). Места (`places`) и цели заданий — словари; ключ цели — `key = id` (`InteractionService.target`).
- **Файлы.** Кэш мира, сохранения, журнал областей и площадки трасс пишутся каждый в своём формате (`MAGIC`/`FORMAT`, `WGS1`, `FORMAT` в словаре, `.tsite`), все через временный файл и переименование, три из четырёх с SHA-256 (у журнала областей контрольной суммы нет, только `format`).

## 5. Паразитные связи (обход слоёв и чужие приватные члены)

Обращения «снизу вверх» по слоям:

| Откуда (слой) | Куда (слой) | Что берётся | Опасность |
|---|---|---|---|
| `world` (этапы, области, `WorldData`) | `game`: `Heightfield`, `GameConfig`, `PlayerState`, `RoadRefinement` | высоты в метрах, `TILE`, размеры построек (`PlayerState.SITE_HALF`) | правка игрового рельефа или размеров меняет генерацию мира |
| `world` | `trails`: `BikePark`, `TrailScout`, `TrailSite`, … | построение трасс в генерации | ожидаемо, но правило слоёв это не описывает |
| `trails` | `game`: `Heightfield`, `RoadBed`, `RoadRefinement`, `BikeRide`, `ForestObstacles`, `RideSurface` | полотно и физика | правка езды меняет поиск трасс |
| `trails` (`TrailSite`) | `render`: `WaterBuilder` | только в тексте описания полей | безвредно |
| `game` (`Heightfield`) | `render`: `WaterBuilder.LAKE_DROP` | уровень озёр | константу воды лучше держать в `game`/`GameConfig` |
| `game` (`ForestObstacles`) | `render`: `VegetationLayer.WATER_MARGIN`, `RockModels.has_seat/supported` | правило «где стоит камень» | столкновения зависят от модуля отрисовки |
| `game` (`BikeController`) | `render`: `BikeCrash`, `BikeView` | падение и поза | контроллер игры знает про узлы сцены |
| `game` (`ServiceScope`) | `render`: `TerrainBuilder` | общий материал рельефа | то же |
| `render` (`GameWorld`) | `ui`: `Hud` | разрешённое исключение | — |

Чужие приватные члены (`obj._name` вне своего класса):

- `CrashEnvironment` → `StructuresBuilder._bridge/_stone_bridge/_planks/_tunnel`, `SettlementsBuilder._footing`: обломки падения собираются из внутренних функций сборщиков. Правка внутренностей моста ломает падение.
- `RegionStream` → `WaterBuilder._arrays/_flat_mesh/_material`, `GameWorld._boards` (через переменную), `terrain_source._build`.
- `NavigationLine` → `RoadNavigation._world/_heights/_segment/_components`.
- `NavigationSnapshot` → `Heightfield._cells/_outer_cells`, `ForestObstacles._grid`, `OuterLand._ledger/_ring`.
- `OuterTerrain` → `OuterLand._overlay_regions`; `StructuresBuilder` → `Heightfield._style`.
- `BikeCrash` → `BikeRide._obstacle_normal`; `RoadRefinement`/`TrailBuilder` → `RoadBed._wet_near`; `TrailSurvey` → `TrailShaping._peak_grade`.
- `GameWorld` → 16 полей `PlayerCameraController` (см. 2.7) и `SettlementsBuilder._label`.
- Генераторы моделей (`ForestFloor`, `UnderstoryModels`, `RockModels`) → `Models._cyl/_moved/_noise3`, `Plants._mound/_colored/_leaves`: общие помощники форм, по сути публичные.

Предложение без переделки поведения: те функции, которыми пользуются снаружи, переименовать в публичные (без `_`) и описать как часть интерфейса модуля. Тогда правка «внутренней» функции будет видна как правка интерфейса. Начать с `StructuresBuilder` (падение), `RoadNavigation` (линия навигации) и `NavigationSnapshot`.

## 6. Что исправлено сейчас

- `RegionStream._persist` ждёт предыдущую запись журнала: две записи `ledger.bin` больше не могут идти одновременно через один `.tmp`.

## 7. Что не проверялось

- Запусков не было (кроме `--check-only` и короткого запуска после правки `_persist`); гонки найдены чтением кода.
- Тексты интерфейса и шейдеры не просматривались.
- Полный аудит всех словарей-«мест» на совпадение полей между планом и областями не делался.
