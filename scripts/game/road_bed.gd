class_name RoadBed
extends RefCounted
## Слой дорожного полотна (с 4.3), часть 2: высоты. Работает поверх готовых линий путей (w.trails) и
## меняет только игровой рельеф Heightfield.hv рядом с ними. Маршруты, мир и генерация не меняются.
## Вдоль линии профиль земли сглаживается скользящим средним (мелкие бугры и ямы срезаются),
## но часть местной неровности остаётся (keep), а срез и подсыпка ограничены (cut, side): склоны,
## перевалы и долины остаются собой, дорога лишь ложится на них ровной полкой без поперечного крена.
## К обочине изменение плавно сходит на нет. Не трогаются вода и ближайший берег, очень крутые склоны
## (серпантины), концы мостов и туннелей (их высоты считает build_structures) и звериные тропы.
## 16.11.2026: вся математика (профиль пути, узлы и касания путей, штамп по клеткам) только на C#:
## scripts/core/FastGrid.RoadBed.cs (FastGrid.RoadBedRefine). Здесь — фасад: числа видов, сбор столбцов, запись hv.
## Эталон результата — tools/road_golden.gd, описание — docs/ROADS_CSHARP.md. Замеры было/стало — tools/road_bed_test.gd.

const TILE := GameConfig.TILE
const STEP := 1.0        # шаг выборки профиля вдоль линии, м
const PIN := 6.0         # точки рельефа ближе этого к оси моста или туннеля (м) не меняются: концы настила
const PIN_FADE := 4.0    # и пола остаются вровень с землёй; дальше на столько метров полотно включается плавно
## Виды путей с полотном, в порядке обработки и номеров вида в C#. Числа вида (flat, shoulder, window, keep, cut, side)
## с 16.11.2026 — в файле параметров дорог: RoadTuning.current().kind(<вид>) (resources/road_tuning.tres).
const KINDS := {road = 0, trail = 1, mountain = 2}
const WATER_GAP := 0.4   # рельеф у воды не опускается ниже уровня соседней воды плюс это, м
const STEEP := Vector2(0.5, 0.9) # на склоне круче (уклон земли у линии) полотно сходит на нет: серпантин
                                 # и скальный участок остаются собой, а выравнивание не рвёт соседние петли
const SHORE := Vector2(1.0, 2.5) # у воды (клеток до неё, w.dist_water) полотно сходит на нет: подход к броду
                                 # или мосту не становится ступенькой между выровненной землёй и руслом


## Выровнять полотно всех путей мира в heights.hv. Возвращает клетки, высота которых изменилась
## (для TerrainBuilder.patch). Вызывается один раз, до build_structures.
## only — номера путей w.trails (ключи): выровнять только их (Trail Lab: новая трасса на готовом участке, где
## полотно прежних путей уже в рельефе); frozen — 1 у клеток, которые не меняются (углы готовых метровых патчей).
## Пусто — все пути, как в игре.
## 11.11.2026: три прохода — профиль каждого пути; узлы (путь подтягивает профиль к высоте пути, обработанного
## раньше, в точке касания — у перекрёстка и примыкания одна высота); клетки рельефа, где несколько путей смешиваются
## по весам (раньше побеждал один путь — ступень или вал вдоль стыка). Порядок: дороги, тропы, горные тропы.
## 16.11.2026: без C# (сборка .NET, dotnet build) полотно не строится — сообщение об ошибке и пустой список; w.outer не
## учитывается (в игре полотно строится до подключения OuterLand, в Trail Lab его нет).
static func refine(heights: Heightfield, only := {}, frozen := PackedByteArray()) -> PackedInt32Array:
	var fast := Grid.native_grid()
	if fast == null:
		push_error("RoadBed: полотно дорог считается только на C#: нужна сборка Godot .NET и dotnet build")
		return PackedInt32Array()
	var native: Variant = _refine_native(fast, heights, frozen, only)
	if native == null:
		push_error("RoadBed: C# не построил полотно (исключение внутри расчёта или неполный патч опоры), hv не тронут")
		return PackedInt32Array()
	return native


## Весь этап одним вызовом C# (FastGrid.RoadBedRefine), пути — столбцами: hv правится на месте.
static func _refine_native(fast: Object, heights: Heightfield, frozen: PackedByteArray, only := {}) -> Variant:
	var w := heights.world
	var names: Array = KINDS.keys()
	var tuning := RoadTuning.for_world(w)
	var params := PackedFloat64Array()
	for name: String in names:
		params.append_array(tuning.kind(name).bed_params())
	var kinds := PackedInt32Array()
	var starts := PackedInt32Array()
	var xs := PackedFloat64Array()
	var ys := PackedFloat64Array()
	var ws := PackedFloat64Array()
	for k in w.trails.size():
		var t: Dictionary = w.trails[k]
		if KINDS.has(t.kind) and t.pts.size() >= 2 and (only.is_empty() or only.has(k)):
			kinds.append(names.find(t.kind))
			starts.append(xs.size())
			for p: Dictionary in t.pts:
				xs.append(p.x)
				ys.append(p.y)
				ws.append(p.w)
	starts.append(xs.size())
	var ends := PackedInt32Array()
	for s: EntityRecord in w.bridges + w.tunnels:
		ends.append(s.a)
		ends.append(s.b)
	# патчи готовой метровой сетки (частичная пересборка Trail Lab): ключи клеток, высоты по 25 на патч, число строк клеток
	var patch_keys := PackedInt32Array()
	var patch_h := PackedFloat32Array()
	var rows := 0
	var r := heights.road_refinement
	if r != null:
		rows = r._height
		for key: int in r.patches:
			var hs: PackedFloat32Array = r.patches[key].h
			if hs.size() != RoadRefinement.STRIDE * RoadRefinement.STRIDE:
				return null # неполный патч (не 5×5 вершин): опора линии не читается, полотно не строится
			patch_keys.append(key)
			patch_h.append_array(hs)
	var out: Variant = fast.RoadBedRefine(w.W, w.H, TILE, heights.hv, heights.water_level, w.dist_water, ends, kinds, starts,
		xs, ys, ws, params, frozen, STEP, STEEP.x, STEEP.y, SHORE.x, SHORE.y, PIN, PIN_FADE, WATER_GAP, patch_keys, patch_h, rows)
	if not out is Dictionary:
		return null   # исключение внутри C#: hv не тронут
	var changed: PackedInt32Array = out.changed
	var done: PackedFloat32Array = out.hv
	var hv := heights.hv
	for i: int in changed:
		hv[i] = done[i]
	return changed


## Наибольший уровень воды в соседних клетках (или -INF)
static func wet_near(heights: Heightfield, i: int) -> float:
	var W := heights.world.W
	var H := heights.world.H
	var cx := i % W
	var cy := i / W
	var top := -INF
	for k in 8:
		var nx: int = cx + Grid.DX[k]
		var ny: int = cy + Grid.DY[k]
		if nx >= 0 and ny >= 0 and nx < W and ny < H:
			top = maxf(top, heights.water_level[ny * W + nx])
	return top
