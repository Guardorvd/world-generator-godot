# Технический долг

Что найдено при чистке и ревизии 29.10.2026 (см. [STATE_AUDIT.md](STATE_AUDIT.md)) и пока не сделано: не безопасно сделать быстро или нужна отдельная проверка.
Пункт закрыт — удалить его отсюда.

## Состояние и связи

1. **Один объект знаний игрока.** «Известные места» разделены между `Hud.visited` и `Quests.known`, а `PlaceNames` получает обе таблицы. Нужен один объект в `game` (посещённые, известные), который HUD, подписи и сохранение только читают. Затрагивает сохранения: проверить `save_test` и старые файлы.
2. **Журнал областей в одной копии.** `RegionStream.ledger` повторяется в `world.outer` (`set_ledger`). Пусть `OuterLand` читает журнал у владельца. Проверка: `territory_test -- --regions`, `region_travel_test`.
3. **Кэш `TrailRouter._prepared` общий для потоков.** Стартовая трасса и трассы областей сейчас не пересекаются по времени, но защиты нет. При этом `_prepared.area`/`.cost` читаются уже после `setup`, поэтому простой `Mutex` вокруг замены не поможет: кэш нужно перенести в экземпляр или отдавать поиску неизменяемый снимок. Проверка: `trail_route_test`, `trail_region_test`.
4. **Константы рельефа в C#** (`FastGrid.cs`: `Macro`, `LandBias`, `SeaRaw`, `Valley` и др.) повторяют `StageRelief`. Сейчас совпадают. Передавать их аргументами, как `TILE`/`HS`. Мир не должен измениться; проверка — хеши `check.gd`, C# и `--gdscript`.
5. **Прокси камеры в `GameWorld`.** 16 свойств (`_cam_y`, `_cam_dist`, `_speed_rush`, …) пробрасывают приватные поля `PlayerCameraController` для `feel_test` и `reported_bugs_test`. Тесты должны обращаться к `game.camera_controller`, а прокси нужно убрать.
6. **Чужие приватные поля** (функции уже сделаны публичными, поля — нет):
   - `NavigationLine` → `RoadNavigation._world/_heights/_segment/_components`;
   - `NavigationSnapshot` → `Heightfield._cells/_outer_cells`, `ForestObstacles._grid`, `OuterLand._ledger/_ring`;
   - `OuterTerrain` → `OuterLand._overlay_regions`;
   - `RegionStream` → `WaterBuilder._arrays/_material`, `GameWorld._boards`, `OuterTerrain._build`;
   - `GameWorld` → `SettlementsBuilder._label`.

   Выход — открыть эти поля через методы чтения. Имена `_label`, `_material`, `_arrays` пересекаются с другими функциями, поэтому переименовывать их нужно вручную, а не заменой.
7. **Слои.** Генерация (`world`) зависит от `game`: `Heightfield`, `GameConfig`, `PlayerState.SITE_HALF`, `RoadRefinement`. `trails` тоже зависит от `game` (`RoadBed`, `BikeRide`, `ForestObstacles`). В `game` остались ссылки на `render`: `BikeController` → `BikeCrash`/`BikeView`, `ForestObstacles` → `RockModels`, `ServiceScope` → `TerrainBuilder`. Варианты: либо записать фактический порядок слоёв в `GODOT_NOTES.md` (`trails` между `world` и `game`, `Heightfield` и `GameConfig` как общее ядро мира), либо переносить классы. Перенос `Heightfield` — крупная правка с проверкой хешей мира.
8. **Единицы в `Quests`.** `SPOT_MIN`/`FAR` заданы в клетках, `SHOT_REACH` — в метрах, рядом. Стоит добавить суффиксы (`_CELLS`, `_M`) или перевести всё в метры.
9. **У журнала областей нет контрольной суммы** (у кэша мира, сохранений и площадок она есть). Повреждённый файл отбрасывается только по `format`.

## Числа и тексты

10. **Тексты интерфейса** зашиты в `hud.gd`, `main.gd`, `settlement_panel.gd`, `photo_camera.gd` и др. Нужна таблица строк (например, `scripts/data/texts.gd` или файл перевода Godot). Это большая механическая правка, проверка — `hud_look`, `quest_look`, `photo_look`.
11. **Цвета и тайминги интерфейса** (HUD, фотоаппарат, подписи мест, звук) стоят прямо в формулах. По образцу `BikeRide`/`PlayerCameraController` их нужно вынести в именованные константы в начале файлов.
12. **Числа в моделях и генерации** (`forest_models`, `settlements_builder`, `understory_models`, этапы `world/stages`) — тысячи литералов формы. Выносить только при правке конкретной модели; в генерации любое изменение значения меняет мир.

## Инструменты и мелочи

13. **Около 39 старых тестов** в `tools/` упоминаются только в заметках `PATCH_*.md`. Все разбираются, но в таблице проверок CLAUDE.md их нет. Решить: оставить, добавить в таблицу или удалить.
14. **Папка `scripts/render/unused_water_massive_forest`** — отложенные модели деревьев, сейчас не подключены. Нужно решить, подключать их или удалить.
15. **Подписи клавиш в подсказках** (`Controls.label`) считаются каждый кадр, около 5 вызовов. Кэшировать по режиму (клавиатура/геймпад) со сбросом при переназначении клавиш.
16. **`lifecycle_test` не перезапускался** после правки утечки (`TrailRouter.release`) — при следующей проверке памяти прогнать `lifecycle_test -- --size 256 --worlds 3`.

## Порядок запуска

17. **Игрок и велосипед ставятся до препятствий.** В `GameWorld.start` сначала `PlayerState.spawn` и `safe_position` (позиция из сохранения), потом `ForestObstacles.new`, потом `BikeRide.park_near`, и только потом `force_vegetation` раскладывает валежник. Исправление: создать `heights.obstacles` и первый `update` до спавна, а велосипед перепроверить (`fits`) после `force_vegetation`. Это меняет место появления (редко, только у деревьев), поэтому проверка — `feel_test` или один запуск мира с загрузкой сохранения рядом с деревом.
18. **Кольца классов.** `WorldData` ↔ `Heightfield` (`base_heights` внутри данных мира) — вынести рельеф генератора в состояние генерации (`WorldGenerationState`), тогда обнулять его вручную не нужно. `RegionStream` ↔ `VegetationLayer` — растительности нужна только функция `snapshot_ground`: передать её как `Callable` или вынести в `OuterLand`. Мелкие пары (`BikeRide` ↔ `BikeRecovery`, `StageLandmarks` ↔ `StageSites`, `TrailDefinition` ↔ `TrailShaping`, `WorldGenerator` ↔ `StageTrailPlan`) — общие константы и помощники вынести в нижний модуль.
19. **`RegionStream.setup` с `terrain = null`.** `OuterTerrain` создаётся позже и присваивается отдельно. Лучше создавать `OuterTerrain` до `RegionStream` и передавать его в `setup`. Порядок тогда не будет держаться на том, что `restore` не трогает рельеф.
