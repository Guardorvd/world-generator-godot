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
	# Сохраняем природные перегибы на оси. Окно и пределы выемки всё ещё формируют проходимую полку.
	road = {flat = 0.6, shoulder = 3.0, window = 14.0, keep = 0.52, cut = 1.2, side = 1.6},
	trail = {flat = 0.4, shoulder = 2.0, window = 4.0, keep = 0.65, cut = 0.4, side = 0.8},
	mountain = {flat = 0.3, shoulder = 1.5, window = 2.0, keep = 0.85, cut = 0.2, side = 0.5},
}
const WATER_GAP := 0.4   # рельеф у воды не опускается ниже уровня соседней воды плюс это, м
const STEEP := Vector2(0.5, 0.9) # на склоне круче (уклон земли у линии) полотно сходит на нет: серпантин
                                 # и скальный участок остаются собой, а выравнивание не рвёт соседние петли
const SHORE := Vector2(1.0, 2.5) # у воды (клеток до неё, w.dist_water) полотно сходит на нет: подход к броду
                                 # или мосту не становится ступенькой между выровненной землёй и руслом
static var allow_fast := true # false — исходный GDScript для сверки с C# (tools/dod_verify.gd)


## Выровнять полотно всех путей мира в heights.hv. Возвращает клетки, высота которых изменилась
## (для TerrainBuilder.patch). Вызывается один раз, до build_structures.
## only — номера путей w.trails (ключи): выровнять только их (Trail Lab: новая трасса на готовом участке, где
## полотно прежних путей уже в рельефе); frozen — 1 у клеток, которые не меняются (углы готовых метровых патчей).
## Пусто — все пути, как в игре.
## 11.11.2026: три прохода — профиль каждого пути; узлы (_join: путь подтягивает профиль к высоте пути, обработанного
## раньше, в точке касания — у перекрёстка и примыкания одна высота); клетки рельефа, где несколько путей смешиваются
## по весам (раньше побеждал один путь — ступень или вал вдоль стыка). Порядок: дороги, тропы, горные тропы.
static func refine(heights: Heightfield, only := {}, frozen := PackedByteArray()) -> PackedInt32Array:
	var w := heights.world
	if allow_fast and only.is_empty() and w.outer == null and heights.road_refinement == null:
		var fast := Grid.fast_grid()
		if fast != null:
			var native: Variant = _refine_native(fast, heights, frozen)
			if native != null:
				return native
			push_error("RoadBed: C# вернул null, полотно считается на GDScript")
	var pin := _pins(w)
	if frozen.size() == w.N:
		for i in w.N:
			if frozen[i] != 0:
				pin[i] = 0.0
	var routes: Array = []
	for k in w.trails.size():
		var t: Dictionary = w.trails[k]
		if KINDS.has(t.kind) and t.pts.size() >= 2 and (only.is_empty() or only.has(k)):
			routes.append(k)
	var order := _order(w, routes)
	var profiles: Array = []
	for k: int in routes:
		profiles.append(_profile(heights, w.trails[k].pts, KINDS[w.trails[k].kind]))
	_join(heights, routes, order, profiles, pin)
	var weight := PackedFloat32Array()
	weight.resize(w.N)
	var sum := PackedFloat64Array()
	sum.resize(w.N)
	var total := PackedFloat64Array()
	total.resize(w.N)
	var near := PackedFloat32Array()   # расстояние до линии текущего пути, для ближайшей точки профиля
	near.resize(w.N)
	near.fill(INF)
	var slot := PackedInt32Array()     # номер клетки в списке текущего пути или -1
	slot.resize(w.N)
	slot.fill(-1)
	for at: int in order:
		var r: Array = _stamp(heights, profiles[at], KINDS[w.trails[routes[at]].kind], pin, near, slot)
		var cells: PackedInt32Array = r[0]
		var best_w: PackedFloat32Array = r[1]
		var best_h: PackedFloat32Array = r[2]
		for j in cells.size():
			var i := cells[j]
			if best_w[j] <= 0.0:
				continue
			sum[i] += best_w[j] * best_h[j]
			total[i] += best_w[j]
			if best_w[j] > weight[i]:
				weight[i] = best_w[j]
	var target := PackedFloat32Array()
	target.resize(w.N)
	var changed := PackedInt32Array()
	var hv := heights.hv
	for i in w.N:
		if weight[i] <= 0.0 or heights.water_level[i] != -INF:
			continue
		target[i] = sum[i] / total[i]
		var h := lerpf(hv[i], target[i], weight[i])
		if h < hv[i]:
			h = maxf(h, minf(hv[i], wet_near(heights, i) + WATER_GAP))
		if absf(h - hv[i]) > 0.005:
			hv[i] = h
			changed.append(i)
	return changed


## Номера в routes по порядку обработки: дороги, тропы, горные тропы; внутри вида — по номеру пути (как FastGrid.RbOrder)
static func _order(w: WorldData, routes: Array) -> Array:
	var names: Array = KINDS.keys()
	var order: Array = range(routes.size())
	order.sort_custom(func(a: int, b: int) -> bool:
		var ka := names.find(w.trails[routes[a]].kind)
		var kb := names.find(w.trails[routes[b]].kind)
		return ka < kb if ka != kb else a < b)
	return order


## DOD (ноябрь 2026): весь этап одним вызовом C# (FastGrid.RoadBedRefine), пути — столбцами. Результат тот же, что у
## GDScript-пути выше (он остаётся эталоном для tools/dod_verify.gd): hv правится на месте, как там.
static func _refine_native(fast: Object, heights: Heightfield, frozen: PackedByteArray) -> Variant:
	var w := heights.world
	var names: Array = KINDS.keys()
	var params := PackedFloat64Array()
	for name: String in names:
		var k: Dictionary = KINDS[name]
		params.append_array(PackedFloat64Array([k.flat, k.shoulder, k.window, k.keep, k.cut, k.side]))
	var kinds := PackedInt32Array()
	var starts := PackedInt32Array()
	var xs := PackedFloat64Array()
	var ys := PackedFloat64Array()
	var ws := PackedFloat64Array()
	for t: Dictionary in w.trails:
		if KINDS.has(t.kind) and t.pts.size() >= 2:
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
	var out: Variant = fast.RoadBedRefine(w.W, w.H, TILE, heights.hv, heights.water_level, w.dist_water, ends, kinds, starts,
		xs, ys, ws, params, frozen, STEP, STEEP.x, STEEP.y, SHORE.x, SHORE.y, PIN, PIN_FADE, WATER_GAP)
	if not out is Dictionary:
		return null   # исключение внутри C#: hv не тронут, вызывающий считает на GDScript
	var changed: PackedInt32Array = out.changed
	var done: PackedFloat32Array = out.hv
	var hv := heights.hv
	for i: int in changed:
		hv[i] = done[i]
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


## Профиль одного пути: выборка через STEP метров, скользящее среднее с сохранённой долей неровности и пределами
## среза; fade — полотно сходит на нет на крутом склоне. {xs, zs, half, prof, fade}
static func _profile(heights: Heightfield, pts: Array, k: Dictionary) -> Dictionary:
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
			half.append(lerpf(float(a.w), float(b.w), float(s) / m) * TILE * 0.5)
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
	var prof := PackedFloat64Array()
	prof.resize(n_pts)
	var fade := PackedFloat64Array()
	fade.resize(n_pts)
	for n in n_pts:
		# у концов окно симметрично сужается: начало и конец пути (поселение, развилка) не сдвигаются
		var r := mini(win, mini(n, n_pts - 1 - n))
		var smooth := (sum[n + r + 1] - sum[n - r]) / (2 * r + 1)
		prof[n] = clampf(smooth + k.keep * (g[n] - smooth), g[n] - k.cut, g[n] + k.cut)
		var gx := heights.ground_at(xs[n] + 2.0, zs[n]) - heights.ground_at(xs[n] - 2.0, zs[n])
		var gz := heights.ground_at(xs[n], zs[n] + 2.0) - heights.ground_at(xs[n], zs[n] - 2.0)
		fade[n] = 1.0 - smoothstep(STEEP.x, STEEP.y, Grid.hypot(gx, gz) / 4.0)
	return {xs = xs, zs = zs, half = half, prof = prof, fade = fade}


const JOIN_TOUCH := 0.05 # клеток: конец на оси другого пути
const JOIN_GRADE := 0.08 # добавленный продольный уклон при подтягивании к узлу
const JOIN_MIN := 6.0    # длина перехода, м
const JOIN_MAX := 30.0
const JOIN_BIN := 2


## Узлы (эталон FastGrid.RbJoin, те же операции в том же порядке): для каждого пути по порядку — точки касания с путями
## раньше него (пересечения отрезков, концы на оси); профиль вокруг точки подтягивается к профилю того пути.
## У сооружений и воды (pin < 0,5) узлы не трогаются.
static func _join(heights: Heightfield, routes: Array, order: Array, profiles: Array, pin: PackedFloat32Array) -> void:
	var w := heights.world
	var rank := PackedInt32Array()
	rank.resize(routes.size())
	for k in order.size():
		rank[order[k]] = k
	var bw := (w.W + JOIN_BIN - 1) / JOIN_BIN
	var bh := (w.H + JOIN_BIN - 1) / JOIN_BIN
	var bins := {}
	var owner := PackedInt32Array()
	var seg := [] # [путь, номер точки начала]
	for t in routes.size():
		var pts: Array = w.trails[routes[t]].pts
		for p in range(1, pts.size()):
			var id := owner.size()
			owner.append(t)
			seg.append(p - 1)
			for key: int in _bin_keys(pts[p - 1], pts[p], bw, bh):
				if not bins.has(key): bins[key] = []
				bins[key].append(id)
	for t: int in order:
		var pts: Array = w.trails[routes[t]].pts
		var contacts: Array = [] # [x, y, путь] в клетках; double, как в C# (Vector2 — float32)
		for p in range(1, pts.size()):
			var ax: float = pts[p - 1].x
			var ay: float = pts[p - 1].y
			var bx: float = pts[p].x
			var by: float = pts[p].y
			var first := p == 1
			var last := p == pts.size() - 1
			for key: int in _bin_keys(pts[p - 1], pts[p], bw, bh):
				for id: int in bins.get(key, []):
					var host := owner[id]
					if rank[host] >= rank[t]: continue
					var hp: Array = w.trails[routes[host]].pts
					var q: int = seg[id]
					var cx: float = hp[q].x
					var cy: float = hp[q].y
					var dx: float = hp[q + 1].x
					var dy: float = hp[q + 1].y
					var hit := _intersect(ax, ay, bx, by, cx, cy, dx, dy)
					if not hit.is_empty(): contacts.append([hit[0], hit[1], host])
					if first and Grid.segment_dist(ax, ay, cx, cy, dx, dy) < JOIN_TOUCH: contacts.append([ax, ay, host])
					if last and Grid.segment_dist(bx, by, cx, cy, dx, dy) < JOIN_TOUCH: contacts.append([bx, by, host])
					if q == 0 and Grid.segment_dist(cx, cy, ax, ay, bx, by) < JOIN_TOUCH: contacts.append([cx, cy, host])
					if q + 1 == hp.size() - 1 and Grid.segment_dist(dx, dy, ax, ay, bx, by) < JOIN_TOUCH: contacts.append([dx, dy, host])
		if contacts.is_empty(): continue
		var own: Dictionary = profiles[t]
		var prof: PackedFloat64Array = own.prof
		var done: Array = []
		for contact: Array in contacts:
			var x: float = contact[0]
			var y: float = contact[1]
			var seen := false
			for e: Array in done:
				if (e[0] - x) * (e[0] - x) + (e[1] - y) * (e[1] - y) < 0.125 * 0.125: seen = true
			if seen: continue
			done.append([x, y])
			var cell := clampi(floori(y), 0, w.H - 1) * w.W + clampi(floori(x), 0, w.W - 1)
			if pin[cell] < 0.5: continue
			var s := _nearest(own, x * TILE, y * TILE)
			var other: Dictionary = profiles[contact[2]]
			var value: float = (other.prof as PackedFloat64Array)[_nearest(other, x * TILE, y * TILE)]
			var shift := value - prof[s]
			if absf(shift) < 0.001: continue
			var reach := clampf(absf(shift) / JOIN_GRADE, JOIN_MIN, JOIN_MAX)
			for k in prof.size():
				var along := absi(k - s) * STEP
				if along >= reach: continue
				prof[k] += shift * (1.0 - smoothstep(0.0, reach, along))
		own.prof = prof

static func _bin_keys(a: Dictionary, b: Dictionary, bw: int, bh: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var x0 := clampi(int(floorf(minf(a.x, b.x) - JOIN_TOUCH)) / JOIN_BIN, 0, bw - 1)
	var x1 := clampi(int(floorf(maxf(a.x, b.x) + JOIN_TOUCH)) / JOIN_BIN, 0, bw - 1)
	var y0 := clampi(int(floorf(minf(a.y, b.y) - JOIN_TOUCH)) / JOIN_BIN, 0, bh - 1)
	var y1 := clampi(int(floorf(maxf(a.y, b.y) + JOIN_TOUCH)) / JOIN_BIN, 0, bh - 1)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			out.append(y * bw + x)
	return out


## Пересечение отрезков ab и cd, включая касание концом (как FastGrid.RbIntersect): [x, y] или пусто
static func _intersect(ax: float, ay: float, bx: float, by: float, cx: float, cy: float, dx: float, dy: float) -> Array:
	var rx := bx - ax
	var ry := by - ay
	var sx := dx - cx
	var sy := dy - cy
	var den := rx * sy - ry * sx
	if absf(den) < 1e-12: return []
	var t := ((cx - ax) * sy - (cy - ay) * sx) / den
	var u := ((cx - ax) * ry - (cy - ay) * rx) / den
	if t < -1e-9 or t > 1.0 + 1e-9 or u < -1e-9 or u > 1.0 + 1e-9: return []
	return [ax + rx * t, ay + ry * t]

static func _nearest(p: Dictionary, x: float, z: float) -> int:
	var xs: PackedFloat32Array = p.xs
	var zs: PackedFloat32Array = p.zs
	var best := 0
	var best_d := INF
	for k in xs.size():
		var d := (xs[k] - x) * (xs[k] - x) + (zs[k] - z) * (zs[k] - z)
		if d < best_d:
			best_d = d
			best = k
	return best


## Точки рельефа вокруг линии тянутся к профилю: [клетки, веса, высоты] (у клетки — ближайшая точка профиля)
static func _stamp(heights: Heightfield, p: Dictionary, k: Dictionary, pin: PackedFloat32Array,
		near: PackedFloat32Array, slot: PackedInt32Array) -> Array:
	var W := heights.world.W
	var H := heights.world.H
	var xs: PackedFloat32Array = p.xs
	var zs: PackedFloat32Array = p.zs
	var half: PackedFloat32Array = p.half
	var prof: PackedFloat64Array = p.prof
	var fades: PackedFloat64Array = p.fade
	var touched := PackedInt32Array()
	var best_w := PackedFloat32Array()
	var best_h := PackedFloat32Array()
	var reach: float = k.flat + k.shoulder
	for n in xs.size():
		var fade := fades[n]
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
				best_h[j] = clampf(prof[n], hv - k.side, hv + k.side)
	for i: int in touched:
		near[i] = INF
		slot[i] = -1
	return [touched, best_w, best_h]
