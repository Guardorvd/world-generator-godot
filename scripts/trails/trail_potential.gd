extends RefCounted
## Что местность вдоль линии даёт каждому виду катания, по рельефу и воде мира (без новых обзоров и построений).
## Оценка 0..1 для flow, downhill, enduro и tech: средний спуск, крутизна, подъёмы против хода, неровность профиля
## и боковой склон (полка в склоне). Вид с воды и гребня — отдельная прибавка к месту, а не к виду.
const SAMPLE := 16.0
const SIDE := 10.0       # половина поперечной выборки склона, м
const VIEW_RING := 120.0 # радиус, по которому высота линии сравнивается с окружением, м
const STYLES := ["flow", "downhill", "enduro", "tech"]
const STICK := 1.3        # прежний вид участка держится, пока другой не лучше его в столько раз
const ALT_MIN := 0.4        # вторая линия на месте: оценка второго вида не ниже этого
const ALT_SHARE := 0.75     # и не ниже этой доли оценки основного
## Типичная для холмистого мира неровность на 16 м (м) и боковой склон: техника начинается выше них, а не от них.
const TYPICAL_ROUGH := 2.5
const TYPICAL_SIDE := 0.2
const RIDGE_MARGIN := 1.5 # точка линии выше обеих сторон на 30 м не меньше чем на столько — хребет, м
const SHARE_M := 1500.0  # столько метров вида в сети уменьшают его оценку вдвое

static func _fit(x: float, low: float, target: float, high: float) -> float:
	if x <= low or x >= high: return 0.0
	return (x - low) / (target - low) if x < target else (high - x) / (high - target)

## {} если линия короче двух выборок. input — TrailGenerationInput; line — точки в мировых метрах в ходе седока.
## `cover` (необязательно) — Callable(Vector2 мировые метры) -> Vector2(полог, поляна): StageVegetation.cover_at; с ним лес и
## открытые склоны тоже влияют на оценку (лесные траверсы — эндуро, открытые мягкие склоны — flow).
static func assess(input, line: PackedVector2Array, cover := Callable()) -> Dictionary:
	var points := _resample(line)
	var n := points.size()
	if n < 4: return {}
	var y := PackedFloat32Array()
	for p in points: y.append(input.natural_ground(p))
	var length := SAMPLE * (n - 1)
	var drop := y[0] - y[n - 1]
	var steep := 0
	var climb := 0
	var rough := 0.0
	var side := 0.0
	var view := 0.0
	var watery := 0
	var looked := 0
	var crest := 0
	var wood := 0.0
	var woods := 0
	for i in range(1, n):
		var g := (y[i] - y[i - 1]) / SAMPLE
		if absf(g) > 0.25: steep += 1
		if g > 0.08: climb += 1
		if i < n - 1: rough += absf(y[i - 1] - 2.0 * y[i] + y[i + 1])
		var t := (points[i] - points[i - 1]).normalized().orthogonal()
		side += absf(input.natural_ground(points[i] + t * SIDE) - input.natural_ground(points[i] - t * SIDE)) / (2.0 * SIDE)
		# хребет: точка выше обеих сторон на 30 м поперёк линии не меньше чем на 1,5 м
		var wide := t * SIDE * 3.0
		if y[i] - maxf(input.natural_ground(points[i] + wide), input.natural_ground(points[i] - wide)) >= RIDGE_MARGIN: crest += 1
		if cover.is_valid():
			wood += float((cover.call(points[i]) as Vector2).x)
			woods += 1
		if i % 4 == 0:
			looked += 1
			var around := 0.0
			for k in 6:
				var q: Vector2 = points[i] + Vector2.from_angle(TAU * k / 6.0) * VIEW_RING
				around += input.natural_ground(q)
				if _wet(input, q): watery += 1
			view += maxf(0.0, y[i] - around / 6.0)
	var steps := float(n - 1)
	var down := drop / length
	var steep_share := steep / steps
	var climb_share := climb / steps
	rough /= maxf(1.0, steps - 1.0)
	side /= steps
	# Рельеф мира холмистый: неровность профиля на 16 м обычно 1,5–4 м, средний спуск коридора-траверса 0–10 %.
	var smooth := 1.0 - clampf((rough - 1.0) / 3.0, 0.0, 1.0)
	# Подъёмы против хода мешают меньше, чем раньше: извилистый коридор на мягком склоне всегда немного волнится (flow терпит волны)
	var uphill := 1.0 - clampf(climb_share * 1.5, 0.0, 0.8)
	var ridge := float(crest) / steps
	var forest := wood / woods if woods > 0 else -1.0 # -1: о лесе нет данных
	# Поток — мягкий равномерный спуск без круч по гладкому или перекатистому рельефу, лучше на открытом месте;
	# даунхил — длинный заметный спуск, лучше по гребню; эндуро — средний спуск с боковым склоном, лучше лесом и гребнем;
	# техника — только где рельеф сам неровный, крутой или боковой (основы «на всякий случай» у неё нет).
	var score := {
		# поток строится (подсыпка и срезка до WORK.flow.depth), поэтому гладкость земли для него важна меньше, чем мягкий уклон
		flow = _fit(down, 0.005, 0.045, 0.13) * (1.0 - clampf(steep_share * 1.5, 0.0, 1.0)) * (1.0 - clampf(climb_share * 1.2, 0.0, 0.7)) * (0.7 + 0.3 * smooth) * (1.0 + (0.2 * (1.0 - forest) if forest >= 0.0 else 0.0)),
		downhill = _fit(down, 0.05, 0.11, 0.24) * clampf(drop / 50.0, 0.0, 1.0) * uphill * (1.0 + 0.3 * ridge),
		enduro = _fit(down, 0.01, 0.055, 0.13) * (0.5 + 0.5 * clampf(side / 0.3, 0.0, 1.0)) * clampf(length / 900.0, 0.4, 1.0) * uphill * (1.0 + 0.25 * ridge + (0.35 * clampf(forest * 1.5, 0.0, 1.0) if forest >= 0.0 else 0.0)),
		tech = (0.06 + 0.5 * clampf((rough - TYPICAL_ROUGH) / 2.5, 0.0, 1.0) + 0.3 * clampf(steep_share * 3.0, 0.0, 1.0) + 0.4 * clampf((side - TYPICAL_SIDE) / 0.3, 0.0, 1.0)) * maxf(0.2, _fit(down, -0.02, 0.07, 0.24)),
	}
	for name: String in STYLES: score[name] = clampf(score[name], 0.0, 1.0)
	var best := "tech"
	for name: String in STYLES:
		if score[name] > score[best]: best = name
	return {score = score, best = best, value = score[best], drop = drop, grade = down, rough = rough, side = side, ridge = ridge, forest = forest,
		view = clampf(view / maxi(1, looked) / 30.0, 0.0, 1.0) * 0.7 + clampf(watery / maxf(1.0, looked * 6.0) * 4.0, 0.0, 1.0) * 0.3}

## Вид для участка по оценке его местности `a` (assess). Начало маршрута: лучший вид, а вида, которого в сети уже много
## (share: вид -> метры), реже. Продолжение (previous — вид прошлого участка): прежний вид держится, пока другой не лучше
## него заметно — так соседние участки одного маршрута сохраняют характер, а меняют его там, где местность другая.
## Пустая строка — оценить нельзя, звать прежний круговой порядок.
static func choose(a: Dictionary, share: Dictionary, previous := "") -> String:
	if a.is_empty(): return ""
	var best := ""
	var best_value := -1.0
	for name: String in STYLES:
		var value: float = a.score[name]
		if previous.is_empty(): value /= 1.0 + float(share.get(name, 0.0)) / SHARE_M
		elif name == previous: value *= STICK
		if value > best_value:
			best_value = value
			best = name
	return best

## Лучший вид, кроме `style`, если он почти так же хорош: место, где есть вторая интересная линия. {style, value} или {}.
static func alternative(a: Dictionary, style: String) -> Dictionary:
	if a.is_empty(): return {}
	var best := ""
	for name: String in STYLES:
		if name != style and (best.is_empty() or a.score[name] > a.score[best]): best = name
	if best.is_empty() or float(a.score[best]) < ALT_MIN or float(a.score[best]) < ALT_SHARE * float(a.score[style]): return {}
	return {style = best, value = a.score[best]}
## Насколько место стоит трассы: лучший вид, вид с него и длина (длинное предпочтительнее, но не любой ценой).
## work_ratio — цена прокладки коридора, делённая на среднюю по сети: где рельефу нужно больше работ, место чуть ниже
## (предел земляных работ — главная причина обрывов).
static func rank(a: Dictionary, length: float, work_ratio := 1.0) -> float:
	if a.is_empty(): return 0.0
	return (float(a.value) + 0.25 * float(a.view) + 0.15 * float(a.get("ridge", 0.0))) * (0.15 + 0.85 * minf(1.0, length / 2500.0)) * clampf(1.0 - 0.3 * (work_ratio - 1.0), 0.7, 1.2)

static func _wet(input, at: Vector2) -> bool:
	var p := Vector2i((at - input.origin) / input.cell_size)
	if p.x < 0 or p.y < 0 or p.x >= input.size.x or p.y >= input.size.y: return false
	var i: int = p.y * input.size.x + p.x
	return input.water[i] != 0 or input.rivers[i] != 0

static func _resample(line: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	if line.size() < 2: return out
	out.append(line[0])
	var carry := 0.0
	for k in range(1, line.size()):
		var a := line[k - 1]
		var b := line[k]
		var span := a.distance_to(b)
		var at := SAMPLE - carry
		while at <= span:
			out.append(a.lerp(b, at / span))
			at += SAMPLE
		carry = span - (at - SAMPLE)
	return out
