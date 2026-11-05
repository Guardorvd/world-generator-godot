extends RefCounted
## Что местность вдоль линии даёт каждому виду катания, по рельефу и воде мира (без новых обзоров и построений).
## Оценка 0..1 для flow, downhill, enduro и tech: средний спуск, крутизна, подъёмы против хода, неровность профиля
## и боковой склон (полка в склоне). Вид с воды и гребня — отдельная прибавка к месту, а не к виду.
const SAMPLE := 16.0
const SIDE := 10.0       # половина поперечной выборки склона, м
const VIEW_RING := 120.0 # радиус, по которому высота линии сравнивается с окружением, м
const STYLES := ["flow", "downhill", "enduro", "tech"]
const SHARE_M := 1500.0  # столько метров вида в сети уменьшают его оценку вдвое

static func _fit(x: float, low: float, target: float, high: float) -> float:
	if x <= low or x >= high: return 0.0
	return (x - low) / (target - low) if x < target else (high - x) / (high - target)

## {} если линия короче двух выборок. input — TrailGenerationInput; line — точки в мировых метрах в ходе седока.
static func assess(input, line: PackedVector2Array) -> Dictionary:
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
	for i in range(1, n):
		var g := (y[i] - y[i - 1]) / SAMPLE
		if absf(g) > 0.25: steep += 1
		if g > 0.08: climb += 1
		if i < n - 1: rough += absf(y[i - 1] - 2.0 * y[i] + y[i + 1])
		var t := (points[i] - points[i - 1]).normalized().orthogonal()
		side += absf(input.natural_ground(points[i] + t * SIDE) - input.natural_ground(points[i] - t * SIDE)) / (2.0 * SIDE)
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
	var uphill := 1.0 - clampf(climb_share * 2.0, 0.0, 1.0)
	var score := {
		flow = _fit(down, 0.0, 0.05, 0.12) * (1.0 - clampf(steep_share * 2.0, 0.0, 1.0)) * uphill * (0.4 + 0.6 * smooth),
		downhill = _fit(down, 0.05, 0.10, 0.22) * clampf(drop / 50.0, 0.0, 1.0) * uphill,
		enduro = _fit(down, 0.01, 0.05, 0.12) * (0.5 + 0.5 * clampf(side / 0.3, 0.0, 1.0)) * clampf(length / 900.0, 0.4, 1.0) * uphill,
		tech = (0.1 + 0.5 * clampf((rough - 1.5) / 3.0, 0.0, 1.0) + 0.3 * clampf(steep_share * 3.0, 0.0, 1.0) + 0.4 * clampf(side / 0.5, 0.0, 1.0)) * maxf(0.3, _fit(down, -0.02, 0.07, 0.24)),
	}
	score.tech *= 0.8 # техничная по умолчанию годится везде, но отдельным видом её берём там, где она заметно лучше\n	for name: String in STYLES: score[name] = minf(1.0, score[name])
	var best := "tech"
	for name: String in STYLES:
		if score[name] > score[best]: best = name
	return {score = score, best = best, value = score[best], drop = drop, grade = down, rough = rough, side = side,
		view = clampf(view / maxi(1, looked) / 30.0, 0.0, 1.0) * 0.7 + clampf(watery / maxf(1.0, looked * 6.0) * 4.0, 0.0, 1.0) * 0.3}

## Вид для участка: лучший по оценке местности, а вида, которого в сети уже много (share: вид -> метры), — реже.
## Пустая строка — оценить нельзя, звать прежний круговой порядок.
static func choose(input, line: PackedVector2Array, share: Dictionary) -> String:
	var a := assess(input, line)
	if a.is_empty(): return ""
	var best := ""
	var best_value := -1.0
	for name: String in STYLES:
		var value: float = a.score[name] / (1.0 + float(share.get(name, 0.0)) / SHARE_M)
		if value > best_value:
			best_value = value
			best = name
	return best

## Насколько место стоит трассы: лучший вид, вид с него и длина (длинное предпочтительнее, но не любой ценой).
static func rank(a: Dictionary, length: float) -> float:
	if a.is_empty(): return 0.0
	return (float(a.value) + 0.25 * float(a.view)) * (0.4 + 0.6 * minf(1.0, length / 3000.0))

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
