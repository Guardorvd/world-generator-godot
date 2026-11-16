# Дорожные вычисления на C#

С 16.11.2026 полотно дорог, подгонка профиля, формы коридора и метровая сетка считаются **только на C#**.
Копии на GDScript удалены (коммит be86c3a, −1955 строк). Результат перед удалением совпал с прежним байт в байт
на всех 219 случаях эталона.

## Где что

| Что | C# | GDScript (оболочка) |
|---|---|---|
| Полотно в узлах и на путях | `FastGrid.RoadBedRefine` (`scripts/core/FastGrid.RoadBed.cs`) | `RoadBed.refine` (`scripts/game/road_bed.gd`) — собирает массивы и вызывает C# |
| Индекс отрезков, патчи метровой сетки | `FastGrid.RoadIndex`, `FastGrid.RoadPatches` (`FastGrid.RoadPatches.cs`) | `RoadRefinement.build` (`scripts/game/road_refinement.gd`), в том числе частичная сборка `only` (Trail Lab) |
| Подгонка профиля и формы коридора | `FastGrid.RoadFitNetwork` (`FastGrid.Road.cs`), параметры — `Roads.CorridorParams` (`scripts/core/roads/`) | `RoadRefinement.corridor_params` — собирает числа из `RoadTuning` |
| Числа полотна и форм | — | `RoadTuning` (`resources/road_tuning.tres`), см. ниже |
| Версия результата | `Roads.RoadCode.Version` (`scripts/core/roads/RoadCode.cs`) | входит в ключ кэша поверхности (`WorldCache.artifact_key`) |

На GDScript остались только чтение готовой сетки (`height_at`, `weight_at`, `edge_at`, `sample`, `from_patches`,
`pin_coarse_edges`) и `tread_mask` для `road_look`.

C# берётся через `Grid.native_grid()`. Он не зависит от `Grid.allow_fast`: тесты, которые выключают C# ради сверки
других систем, дорожный C# не выключают. Без сборки .NET или при ошибке внутри C# — `push_error` с понятным
текстом, а не тихий переход на старый код.

## Файл параметров дорог

С 16.11.2026 числа, которыми настраивают вид дорог, лежат в `resources/road_tuning.tres` (класс `RoadTuning`,
`scripts/game/road_tuning.gd`). Их можно менять в инспекторе Godot без правки кода и без `dotnet build`:

- по виду пути (`road`, `trail`, `mountain`, класс `RoadKindTuning`) — полотно `RoadBed` (flat, shoulder, window,
  bed_keep, cut, side), формы коридора (roll, bump, tilt, tilt_keep, tilt_max, dish, dish_var, hollow, ditch, lip,
  grade) и доля выравнивания спокойных участков (level);
- по покрытию (порядок `RoadSurface.LIST`) — выраженность форм, характер (roll, bump, wobble) и выравнивание;
- общие — радиус выравнивания, размах ритма участков, включение форм, зазоры, доля форм у подготовленных трасс.

В коде остались пределы и зазоры, на которые опираются трассы и другие системы: `RoadRefinement.REACH`,
`FIT_FADE`, `FIT_LIMIT`, `BENCH_LIMIT`, `TRAIL_BENCH_LIMIT`, `RoadBed.PIN`, `SHORE`, `WATER_GAP`, `STEEP`.

Хеш значений файла (`RoadTuning.digest`) входит в ключ кэша поверхности: после правки чисел поверхность мира
пересобирается сама, география и пути остаются в кэше. Правка чисел меняет результат дорог, поэтому `road_golden`
после неё расходится: это ожидаемо, эталон переснимается тем же коммитом. Посмотреть правку — `road_look`,
`road_relief_test -- --synthetic-only`.

## Как проверять

- **Результат** — `tools/road_golden.gd` (~10 с, без окна и генерации мира): 219 хешей полотна, профиля, форм и патчей,
  полная и частичная сборка. Сверка с `tools/control/golden/roads.txt`. Это единственная сверка результата дорог.
- **Поведение и повтор** — `road_relief_test.gd -- --synthetic-only`, `road_native_test.gd`.
- **Эталон переснимается** (`-- --save`) только когда результат дорог менять и хотели, и в том же коммите с
  объяснением. При правке алгоритма в C# ещё поднять `Roads.RoadCode.Version`; при правке только чисел
  `road_tuning.tres` версия не нужна, ключ кэша меняет хеш файла.

## Старая сборка

После правки любого `.cs` в `scripts/core` — сначала `dotnet build`. `Grid._fast_build_stale` сравнивает время
сборки с исходниками и старую сборку не грузит; стенд тогда пишет «нужен C# (dotnet build)».

До 16.11.2026 проверка смотрела только саму папку `scripts/core`, без вложенной `scripts/core/roads`. Правка
`CorridorParams.cs` или `RoadCode.cs` без пересборки молча шла на старой сборке, и эталон «расходился на первом
прогоне», а после пересборки совпадал. Теперь вложенные папки тоже проверяются.

Гонку потоков в C# проверили 16.11.2026 на втором ПК (8 потоков): эталон совпал после четырёх пересборок подряд,
на одном потоке (`DOTNET_PROCESSOR_COUNT=1`), без многоуровневого JIT (`DOTNET_TieredCompilation=0`) и в режиме
`DOTNET_JITMinOpts=1`. Результат не зависит ни от числа потоков, ни от уровня JIT.
