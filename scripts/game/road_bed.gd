class_name RoadBed
extends RefCounted
## Слой дорожного полотна (с 4.3), часть 2: высоты. Работает поверх готовых линий путей (w.trails) и
## меняет только игровой рельеф Heightfield.hv рядом с ними. Маршруты, мир и генерация не меняются.
## Вдоль линии профиль земли сглаживается скользящим средним (мелкие бугры и ямы срезаются),
## но часть местной неровности остаётся (keep), а срез и подсыпка ограничены (cut, side): склоны,
## перевалы и долины остаются собой, дорога лишь ложится на них ровной полкой без поперечного крена.
## К обочине изменение плавно сходит на нет. Не трогаются вода и ближайший берег, очень крутые склоны
## (серпантины), концы мостов и туннелей (их высоты считает build_structures) и звериные тропы.
## Проверка и замеры было/стало — tools/road_bed_test.gd.

const TILE := GameConfig.TILE
const STEP := 1.0        # шаг выборки профиля вдоль линии, м
const PIN := 6.0         # точки рельефа ближе этого к оси моста или туннеля (м) не меняются: концы настила
const PIN_FADE := 4.0    # и пола остаются вровень с землёй; дальше на столько метров полотно включается плавно
## half — полуширина из линии; flat — сколько за краем полотна ещё ровно, м; shoulder — где за краем
## изменение сходит на нет, м; window — полуокно сглаживания вдоль линии, м; keep — доля местной
## неровности, которая остаётся; cut — наибольший срез или подсыпка профиля, м; side — то же для
## точки рельефа сбоку от линии (поперечный уклон), м
const KINDS := {
	road = {flat = 0.6, shoulder = 3.0, window = 14.0, keep = 0.12, cut = 1.2, side = 1.6},
	trail = {flat = 0.4, shoulder = 2.0, window = 4.0, keep = 0.65, cut = 0.4, side = 0.8},
	mountain = {flat = 0.3, shoulder = 1.5, window = 2.0, keep = 0.85, cut = 0.2, side = 0.5},
}
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
static func refine(heights: Heightfield, only := {}, frozen := PackedByteArray()) -> PackedInt32Array:
	var w := heights.world
	var weight := PackedFloat32Array()
	weight.resize(w.N)
	var target := PackedFloat32Array()
	target.resize(w.N)
	var near := PackedFloat32Array()   # расстояние до линии текущего пути, для ближайшей точки профиля
	near.resize(w.N)
	near.fill(INF)
	var slot := PackedInt32Array()     # номер клетки в списке текущего пути или -1
	slot.resize(w.N)
	slot.fill(-1)
	var pin := _pins(w)
	if frozen.size() == w.N:
		for i in w.N:
			if frozen[i] != 0:
				pin[i] = 0.0
	for k in w.trails.size():
		var t: Dictionary = w.trails[k]
		if KINDS.has(t.kind) and t.pts.size() >= 2 and (only.is_empty() or only.has(k)):
			_trail(heights, t.pts, KINDS[t.kind], pin, weight, target, near, slot)
	var changed := PackedInt32Array()
	var hv := heights.hv
	for i in w.N:
		if weight[i] <= 0.0 or heights.water_level[i] != -INF:
			continue
		var h := lerpf(hv[i], target[i], weight[i])
		if h < hv[i]:
			h = maxf(h, minf(hv[i], wet_near(heights, i) + WATER_GAP))
		if absf(h - hv[i]) > 0.005:
			hv[i] = h
			changed.append(i)
	return changed


## Доля полотна у каждой точки рельефа: 0 у осей мостов и туннелей и у воды, 1 вдали от них
static func _pins(w: WorldData) -> PackedFloat32Array:
	var pin := PackedFloat32Array()
	pin.resize(w.N)
	pin.fill(1.0)
	for i in w.N:
		pin[i] = smoothstep(SHORE.x, SHORE.y, w.dist_water[i])
	var r := (PIN + PIN_FADE) / TILE + 1.0
	for s: EntityRecord in w.bridges + w.tunnels:
		var ax: float = s.a % w.W + 0.5
		var ay: float = s.a / w.W + 0.5
		var bx: float = s.b % w.W + 0.5
		var by: float = s.b / w.W + 0.5
		for y in range(maxi(0, floori(minf(ay, by) - r)), mini(w.H, ceili(maxf(ay, by) + r))):
			for x in range(maxi(0, floori(minf(ax, bx) - r)), mini(w.W, ceili(maxf(ax, bx) + r))):
				var d := Grid.segment_dist(x + 0.5, y + 0.5, ax, ay, bx, by) * TILE
				pin[y * w.W + x] = minf(pin[y * w.W + x], smoothstep(PIN, PIN + PIN_FADE, d))
	return pin


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


## Один путь: профиль вдоль линии, сглаживание, затем точки рельефа вокруг линии тянутся к профилю
static func _trail(heights: Heightfield, pts: Array, k: Dictionary, pin: PackedFloat32Array, weight: PackedFloat32Array,
		target: PackedFloat32Array, near: PackedFloat32Array, slot: PackedInt32Array) -> void:
	var W := heights.world.W
	var H := heights.world.H
	# выборка через STEP метров
	var xs := PackedFloat32Array()
	var zs := PackedFloat32Array()
	var half := PackedFloat32Array()
	for n in range(1, pts.size()):
		var a: Dictionary = pts[n - 1]
		var b: Dictionary = pts[n]
		var ax: float = a.x * TILE
		var az: float = a.y * TILE
		var dx: float = b.x * TILE - ax
		var dz: float = b.y * TILE - az
		var m := maxi(1, ceili(Grid.hypot(dx, dz) / STEP))
		for s in m:
			xs.append(ax + dx * s / m)
			zs.append(az + dz * s / m)
			half.append(float(a.w) * TILE * 0.5)
	var last: Dictionary = pts[-1]
	xs.append(last.x * TILE)
	zs.append(last.y * TILE)
	half.append(float(last.w) * TILE * 0.5)
	var n_pts := xs.size()
	var g := PackedFloat32Array()
	g.resize(n_pts)
	var sum := PackedFloat64Array()   # префиксные суммы для скользящего среднего
	sum.resize(n_pts + 1)
	for n in n_pts:
		g[n] = heights.ground_at(xs[n], zs[n])
		sum[n + 1] = sum[n] + g[n]
	var win := int(k.window / STEP)
	var touched := PackedInt32Array()
	var best_w := PackedFloat32Array()
	var best_h := PackedFloat32Array()
	var reach: float = k.flat + k.shoulder
	for n in n_pts:
		# у концов окно симметрично сужается: начало и конец пути (поселение, развилка) не сдвигаются
		var r := mini(win, mini(n, n_pts - 1 - n))
		var smooth := (sum[n + r + 1] - sum[n - r]) / (2 * r + 1)
		var prof: float = clampf(smooth + k.keep * (g[n] - smooth), g[n] - k.cut, g[n] + k.cut)
		var gx := heights.ground_at(xs[n] + 2.0, zs[n]) - heights.ground_at(xs[n] - 2.0, zs[n])
		var gz := heights.ground_at(xs[n], zs[n] + 2.0) - heights.ground_at(xs[n], zs[n] - 2.0)
		var fade := 1.0 - smoothstep(STEEP.x, STEEP.y, Grid.hypot(gx, gz) / 4.0)
		if fade <= 0.0:
			continue
		var outer: float = half[n] + reach
		var x0 := maxi(0, floori((xs[n] - outer) / TILE - 0.5))
		var x1 := mini(W - 1, ceili((xs[n] + outer) / TILE - 0.5))
		var z0 := maxi(0, floori((zs[n] - outer) / TILE - 0.5))
		var z1 := mini(H - 1, ceili((zs[n] + outer) / TILE - 0.5))
		for cz in range(z0, z1 + 1):
			for cx in range(x0, x1 + 1):
				var d := Grid.hypot((cx + 0.5) * TILE - xs[n], (cz + 0.5) * TILE - zs[n])
				if d >= outer:
					continue
				var i := cz * W + cx
				if d >= near[i] or pin[i] <= 0.0:
					continue
				if slot[i] < 0:
					slot[i] = touched.size()
					touched.append(i)
					best_w.append(0.0)
					best_h.append(0.0)
				near[i] = d
				var j := slot[i]
				var hv := heights.hv[i]
				best_w[j] = (1.0 - smoothstep(half[n] + k.flat, outer, d)) * pin[i] * fade
				best_h[j] = clampf(prof, hv - k.side, hv + k.side)
	# слияние с другими путями: у точки рельефа побеждает путь, к которому она ближе всего по весу
	for j in touched.size():
		var i := touched[j]
		near[i] = INF
		slot[i] = -1
		if best_w[j] > weight[i]:
			weight[i] = best_w[j]
			target[i] = best_h[j]
