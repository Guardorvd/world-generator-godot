class_name Pathfinder
extends RefCounted
## Поиск пути A* по сетке со стоимостью прохода клеток (8 направлений). Основа — js/core/pathfinding.js;
## с 2.3 диагональный шаг не срезает углы, оценка остатка пути — 0.6 × восьмисвязное расстояние.
## Стоимость прохода передаётся в каждый поиск, поэтому её можно менять между вызовами
## (так протоптанные тропы становятся дешевле). INF — непроходимо. Знает только размер сетки, не мир.
## 16.11.2026: поиск только на C# — FastGrid.FindPath, Reach, Prefetch (scripts/core/FastGrid.Path.cs): алгоритм,
## штрафы поворота (TurnShape) и длинных галсов (BendShape, 3 шага), ширина прохода, кэш последних поисков и фоновый
## запасной поиск. Здесь — фасад с прежним API. Копия A* на GDScript удалена; эталон результата — tools/path_golden.gd
## (снят на C# и совпал с GDScript-копией), описание — docs/ROADS_CSHARP.md. Grid.allow_fast поиск не выключает.

## Дополнительные счётчики только для tools/bench.gd; в игре выключены.
static var profile_searches := false
var _search_us := 0
## Политика запасного поиска (P2 аудита 29.10): true — prefetch в фоне сразу (как с 9.9), false — запасной
## поиск только когда он понадобился (ленивый). Пути и остаток запаса одинаковы; разные CPU и задержка.
var eager_fallback := true
## Отказ без поиска при нулевом запасе
var _skipped := 0

var W := 0
var H := 0
## Высоты в тех же единицах, что шаг сетки. Пустой массив отключает учёт подъёмов.
var _heights_version := 0
var _links_version := 0
var _cost_version := 0
var heights := PackedFloat32Array():
	set(value):
		heights = value
		_heights_version += 1
## Разрешённые шаги по готовому настилу/полу: биты восьми направлений Grid.DX/DY.
var links := PackedByteArray():
	set(value):
		links = value
		_links_version += 1
var use_corridor := true # проверять ширину прохода
## Ревью дорожной сети 29.10, шаг 2: find_path, prefetch и can_reach не выходят из этого прямоугольника клеток.
## Пустой — вся карта (по умолчанию). Путь внутри окна — лучший внутри окна, а не на всей карте.
var window := Rect2i():
	set(value):
		window = value
		if _fast != null:
			if value.has_area(): _fast.SetWindow(value.position.x, value.position.y, value.end.x, value.end.y)
			else: _fast.SetWindow(0, 0, W, H)
var max_cross_grade := INF # предел земляных работ поперёк прохода
## Общий остаток раскрытий для нескольких поисков: -1 без ограничения, 0 — отказаться.
## Позволяет проверять кандидат поселения без полного перебора карты по каждому соседу.
var search_budget := -1
var _fast: Object = null


func _init(width: int, height: int, terrain: PackedFloat32Array = PackedFloat32Array()) -> void:
	W = width
	H = height
	heights = terrain
	_fast = Grid.native_grid()
	if _fast == null:
		push_error("Pathfinder: поиск пути идёт только на C#: нужна сборка Godot .NET и dotnet build")
		return
	_fast.Setup(W, H)
	_fast.ProfileSearches = profile_searches


func fast() -> Object:
	return _fast


## Новый неизменяемый снимок стоимости. После мутации/замены массива нужен новый номер.
## Номер действует только в этом Pathfinder; -1 в find_path безопасно отключает повторное использование.
func next_cost_version() -> int:
	_cost_version += 1
	return _cost_version


## Поэлементные правки heights/links обходят setters: вызывать перед пакетом таких правок.
func terrain_changed() -> void:
	_heights_version += 1
	_links_version += 1


func _search_versions(cost_version: int) -> void:
	_fast.CostVersion = cost_version
	_fast.HeightsVersion = _heights_version
	_fast.LinksVersion = _links_version


## Высоты в клетках, как heights. Кэш ленивый: считаются только просмотренные A* шаги.
## Вода под будущим мостом остаётся доступной; сухой шаг не может задеть её краем.
## water — минимальная высота сухого прохода (уровень воды минус разрешённая глубина).
func set_corridor(ground: PackedFloat32Array, water: PackedFloat32Array, wet: PackedByteArray, half: float) -> void:
	if _fast != null:
		_fast.SetCorridor(ground, water, wet, half)


## Метровые поля мира: C# переводит их в единицы поиска (высота / tile, вода — (max(0, уровень) − 0,1) / tile).
func set_world_corridor(ground_meters: PackedFloat32Array, water_meters: PackedFloat32Array,
		ocean: PackedByteArray, lake: PackedByteArray, river: PackedByteArray, tile: float, half: float) -> void:
	if _fast != null:
		_fast.SetWorldCorridor(ground_meters, water_meters, ocean, lake, river, tile, half)


## Путь от клетки s до клетки t (индексы клеток) по стоимости прохода cost или пустой массив, если пути нет.
## turn — штраф смены направления (15.11.2026, 0 — прежний поиск), bend — длинные галсы (поворот на 90° и круче в
## пределах трёх шагов). Без C# — пустой путь и сообщение об ошибке из _init.
func find_path(cost: PackedFloat32Array, s: int, t: int, climb: float = 0.0, max_grade: float = INF, cost_version: int = -1, turn: float = 0.0, bend: float = 0.0) -> PackedInt32Array:
	if search_budget == 0:
		_skipped += 1
		return PackedInt32Array()
	if _fast == null:
		return PackedInt32Array()
	_search_versions(cost_version)
	_fast.TurnCost = turn
	_fast.BendCost = bend
	_fast.SearchBudget = search_budget
	var started := Time.get_ticks_usec()
	var path: PackedInt32Array = _fast.FindPath(cost, s, t, heights, climb, max_grade, links, use_corridor, max_cross_grade)
	search_budget = _fast.SearchBudget
	if profile_searches:
		_search_us += Time.get_ticks_usec() - started
	return path


## Шаг 0–2 ревью дорожной сети 29.10: «невозможно» отдельно от «кончился запас». false — только если find_path
## с теми же входами (heights, links, use_corridor, max_cross_grade) точно не найдёт пути: s и t в разных
## областях, связанных разрешёнными шагами (FastGrid.Reach: поиск в ширину попеременно от обоих концов, запас не тратится).
func can_reach(cost: PackedFloat32Array, s: int, t: int, climb: float = 0.0, max_grade: float = INF) -> bool:
	if _fast == null:
		return false
	return _fast.Reach(cost, s, t, heights, climb, max_grade, links, use_corridor, max_cross_grade)


## Начать в фоне поиск find_path(cost, s, t, climb, max_grade) с нынешними heights, links, use_corridor и запасом
## не больше search_budget (с 9.9). Если следующий find_path с теми же входами будет именно таким, он возьмёт готовый
## результат; иначе фоновый поиск ни на что не влияет.
func prefetch(cost: PackedFloat32Array, s: int, t: int, climb: float = 0.0, max_grade: float = INF, cost_version: int = -1, turn: float = 0.0, bend: float = 0.0) -> void:
	if eager_fallback and _fast != null and search_budget != 0:
		_search_versions(cost_version)
		_fast.TurnCost = turn
		_fast.BendCost = bend
		_fast.Prefetch(cost, s, t, heights, climb, max_grade, links, use_corridor, max_cross_grade, search_budget)


func cancel_prefetch() -> void:
	if _fast != null:
		_fast.CancelPrefetch()


## Поиски закончены: C# отпускает кэш и возвращает буфер прохода в пул без принудительной сборки GC.
func release() -> void:
	if _fast != null:
		_fast.Release()


## expanded — раскрытия основного поиска; prefetch_expanded — фонового (в том числе отменённого и ненужного).
## budget_stops — запас кончился (путь мог существовать), no_path — поиск доказал, что пути нет.
func search_stats() -> Dictionary:
	if _fast == null:
		return {calls = 0, expanded = 0, budget_stops = _skipped, no_path = 0, skipped = _skipped,
			reach_calls = 0, reach_rejects = 0, reach_visited = 0}
	# Раскрытия, исходы и судьба фонового поиска считаются всегда: они нужны отчёту подготовки,
	# а не только bench.gd. calls/native_ms/call_ms — только с profile_searches.
	var stats: Dictionary = _fast.SearchStats()
	if not profile_searches:
		stats.erase("calls")
		stats.erase("native_ms")
	else:
		stats.call_ms = _search_us / 1000.0
	stats.budget_stops = int(stats.budget_stops) + _skipped
	stats.skipped = _skipped
	return stats
