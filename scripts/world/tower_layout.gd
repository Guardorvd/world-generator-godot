class_name TowerLayout
extends RefCounted
## Дозорная вышка вне поселений (StageSites, вид "tower"): одна геометрия на модель и на физику.
## Модель (TowerModels) и опора игрока (Heightfield.add_tower_stairs) берут размеры и положение
## лестницы только отсюда, поэтому ступени на экране и настилы под ногами совпадают.
## Координаты местные: начало — центр пола, вверх y, дверь и вход на лестницу со стороны +z; в мир переводятся
## поворотом Basis(UP, a) вокруг вертикали и сдвигом к центру места (как постройка из HutData).
## Устройство: деревянный каркас с четырьмя стойками, площадка наверху с перилами и крышей, снаружи каркаса
## вдоль его сторон идёт квадратная спираль из пяти маршей (≈36°) с площадками на углах. Марш: прямой отрезок
## настила (ay → by), площадка — плоский. Перила в физике — rails сооружения; где два настила сходятся,
## Heightfield.wall_at проход не перекрывает, поэтому у площадки две пересекающиеся полосы (вдоль x и вдоль z).

const FRAME_HALF := 2.1     # оси угловых стоек, м (каркас около 4,5 м в поперечнике)
const DECK_Y := 12.4        # высота верхней площадки над низом каркаса, м
const DECK_HALF := 2.5      # полуширина верхней площадки (5×5 м)
const LOOP := 2.9           # ось спирали от центра, м: марш снаружи каркаса вплотную к нему
const STAIR_HALF := 0.55    # полуширина марша (1,1 м)
const LAND_HALF := 0.75     # полуширина угловой площадки
const TOP_HALF := Vector2(0.75, 1.1)  # верхняя площадка у входа на настил: полуразмеры по x и z
const TOP_CENTER := Vector2(0.0, 2.7)
const OVERLAP := 0.1        # на сколько марш заходит на площадку, м: настилы перекрываются, а не стыкуются «в ноль»
const RISER := 0.2          # высота ступени, м
const HEIGHT := 16.5        # от земли до конька крыши и флага, м (для столкновения падающего тела и подписи)
const ON_DECK := 0.6        # ноги выше площадки не больше чем на столько и не ниже неё на столько: игрок на ней


## Марши по порядку подъёма: [{a: Vector3, b: Vector3, steps: int}] в местных метрах.
## Первый начинается на земле у середины южной стороны, пятый приводит на площадку у входа на настил.
static func flights() -> Array[Dictionary]:
	var c := LOOP
	var l := LAND_HALF - OVERLAP
	var runs: Array = [
		[Vector2(0.0, c), Vector2(c - l, c)],
		[Vector2(c, c - l), Vector2(c, -c + l)],
		[Vector2(c - l, -c), Vector2(-c + l, -c)],
		[Vector2(-c, -c + l), Vector2(-c, c - l)],
		[Vector2(-c + l, c), Vector2(-TOP_HALF.x + OVERLAP, c)],
	]
	var total := 0.0
	for run: Array in runs:
		total += (run[1] as Vector2).distance_to(run[0])
	var slope := DECK_Y / total
	var out: Array[Dictionary] = []
	var y := 0.0
	for run: Array in runs:
		var a: Vector2 = run[0]
		var b: Vector2 = run[1]
		var rise := a.distance_to(b) * slope
		out.append({a = Vector3(a.x, y, a.y), b = Vector3(b.x, y + rise, b.y), steps = maxi(1, roundi(rise / RISER))})
		y += rise
	return out


## Площадки: [{c: Vector2, y: float, half: Vector2}]; угловые (отметки концов маршей 1–4), верхняя у входа и сама верхняя площадка.
static func platforms() -> Array[Dictionary]:
	var c := LOOP
	var fl := flights()
	var out: Array[Dictionary] = []
	for k in 4:
		var corner := [Vector2(c, c), Vector2(c, -c), Vector2(-c, -c), Vector2(-c, c)][k] as Vector2
		out.append({c = corner, y = fl[k].b.y, half = Vector2(LAND_HALF, LAND_HALF)})
	out.append({c = TOP_CENTER, y = DECK_Y, half = TOP_HALF})
	out.append({c = Vector2.ZERO, y = DECK_Y, half = Vector2(DECK_HALF, DECK_HALF)})
	return out


## Ограждения площадок: [{a: Vector2, b: Vector2, y: float}] — отрезки плана, на которых стоят перила. Пустые места — проходы
## (вход с марша, выход на площадку). Марши ограждены своими перилами (TowerModels).
static func rails() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var d := DECK_HALF
	var gate := TOP_HALF.x
	var top := DECK_Y
	out.append({a = Vector2(-d, -d), b = Vector2(d, -d), y = top})
	out.append({a = Vector2(d, -d), b = Vector2(d, d), y = top})
	out.append({a = Vector2(-d, -d), b = Vector2(-d, d), y = top})
	out.append({a = Vector2(-d, d), b = Vector2(-gate, d), y = top})
	out.append({a = Vector2(gate, d), b = Vector2(d, d), y = top})
	var tc := TOP_CENTER
	var zt := tc.y + TOP_HALF.y
	out.append({a = Vector2(gate, d), b = Vector2(gate, zt), y = top})
	out.append({a = Vector2(gate, zt), b = Vector2(-gate, zt), y = top})
	out.append({a = Vector2(-gate, zt), b = Vector2(-gate, STAIR_HALF + LOOP), y = top})
	# угловые площадки: закрыты стороны «вперёд по ходу» и «позади выхода»
	var fl := flights()
	var c := LOOP
	var h := LAND_HALF
	var landings := [
		[Vector2(c, c), Vector2(1, 0), Vector2(0, -1)],
		[Vector2(c, -c), Vector2(0, -1), Vector2(-1, 0)],
		[Vector2(-c, -c), Vector2(-1, 0), Vector2(0, 1)],
		[Vector2(-c, c), Vector2(0, 1), Vector2(1, 0)],
	]
	for k in 4:
		var at: Vector2 = landings[k][0]
		var din: Vector2 = landings[k][1]
		var dout: Vector2 = landings[k][2]
		for side: Vector2 in [din, -dout]:
			var normal := side * h
			var tangent := Vector2(-side.y, side.x) * h
			out.append({a = at + normal - tangent, b = at + normal + tangent, y = fl[k].b.y})
	return out


## Сооружения для Heightfield (настилы с перилами): [{key, half, ax, az, ay, bx, bz, by, rails}] в метрах мира.
static func structures(origin: Vector3, yaw: float, key: String) -> Array[Dictionary]:
	var basis := Basis(Vector3.UP, yaw)
	var out: Array[Dictionary] = []
	var n := 0
	for f: Dictionary in flights():
		out.append(_piece(origin, basis, "%s:f%d" % [key, n], f.a, f.b, STAIR_HALF))
		n += 1
	n = 0
	for p: Dictionary in platforms():
		var at: Vector2 = p.c
		var half: Vector2 = p.half
		out.append(_piece(origin, basis, "%s:p%da" % [key, n], Vector3(at.x - half.x, p.y, at.y), Vector3(at.x + half.x, p.y, at.y), half.y))
		out.append(_piece(origin, basis, "%s:p%dc" % [key, n], Vector3(at.x, p.y, at.y - half.y), Vector3(at.x, p.y, at.y + half.y), half.x))
		n += 1
	return out


static func _piece(origin: Vector3, basis: Basis, key: String, a: Vector3, b: Vector3, half: float) -> Dictionary:
	var wa := origin + basis * a
	var wb := origin + basis * b
	return {key = key, half = half, ax = wa.x, az = wa.z, ay = wa.y, bx = wb.x, bz = wb.z, by = wb.y, rails = true}


## Низ каркаса: самая низкая земля под четырьмя стойками. Одна функция для модели и для настилов.
static func base_height(heights: Heightfield, x: float, z: float, yaw: float) -> float:
	var basis := Basis(Vector3.UP, yaw)
	var low := INF
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			var p := basis * Vector3(sx * FRAME_HALF, 0.0, sz * FRAME_HALF)
			low = minf(low, heights.ground_at(x + p.x, z + p.z))
	return low


## Стоит ли игрок (x, z, ноги feet) на верхней площадке вышки tower {x, z, yaw, base}
static func on_deck(tower: Dictionary, x: float, z: float, feet: float) -> bool:
	var level: float = tower.base + DECK_Y
	if feet < level - ON_DECK or feet > level + ON_DECK:
		return false
	var local := Basis(Vector3.UP, tower.yaw).inverse() * Vector3(x - tower.x, 0.0, z - tower.z)
	return absf(local.x) <= DECK_HALF and absf(local.z) <= DECK_HALF
