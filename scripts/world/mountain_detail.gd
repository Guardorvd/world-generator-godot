extends RefCounted

## Слой детализации гор. Поверх макрорельефа на склонах добавляются формы
## 15–150 м. Слой зависит от уже посчитанной основы в клетке и её соседях:
##  - ложбины и отроги вытянуты по линии падения склона (направленный ridged-шум в четырёх
##    повёрнутых осях, вес оси — по направлению склона), глубина растёт с крутизной;
##  - перегибы и локальные формы следуют склону; общие плечи остаются частью макроформы;
##  - сила и характер меняются по местности: пологие склоны — волны, крутые — рёбра и ложбины.
## Низкая и почти горизонтальная суша исключена, на выпуклых гребнях детализация слабее. Это слой склонов:
## высокие холмы тоже подходят; отдельная маска массива не вычисляется повторно.
## Полоса соседей для уклона, в клетках
const DETAIL_PAD := 2
## Высота над морем, м: ниже DETAIL_LOW слоя нет, выше DETAIL_HIGH — в полную силу
const DETAIL_LOW := 30.0
const DETAIL_HIGH := 60.0
## Ширина рёбер поперёк склона (клетки): на пологих склонах, на крутых и мелкие; вдоль склона они
## в DETAIL_LONG раз длиннее
const DETAIL_RIB_BROAD := 40.0
const DETAIL_RIB := 22.0
const DETAIL_RIB_FINE := 9.0
const DETAIL_LONG := 3.5
## Амплитуда, м на единицу уклона. Ограничена шириной формы и запасом уклона основы.
const DETAIL_DEPTH := 26.0
## Предел перепада на крутом склоне: DETAIL_WALL × √(DETAIL_LIMIT² − уклон²), м. Тропа идёт, пока уклон
## вдоль неё до 55 %, а поперёк до 65 %: склон круче ~85 % для неё стена, и ложбины не должны
## превращать в стены проходимые склоны (выше DETAIL_LIMIT рёбер нет)
const DETAIL_WALL := 12.0
const DETAIL_LIMIT := 0.8
## Плавное выключение перед пределом: sqrt(limit²-s²) сам по себе даёт излом
## поправки там, где плавный склон пересекает DETAIL_LIMIT.
const DETAIL_STEEP_FROM := 0.65
## Перепад на метр ширины рёбер (крутизна их стенок, примерно в пять раз меньше уклона стенки)
const DETAIL_CROSS := 0.08


## Высота клетки k основы base (ширина строки bw) со слоем детализации; (x, y) — клетка мира.
## Независимый численный слой: основа только читается, поправка зависит от мировых координат.
## sea_raw/top_raw — шкала основы; height_scale/tile — единицы мира. Копия — FastGrid.Detail.
static func apply(ridge: Simplex, hill: Simplex, base: PackedFloat32Array, bw: int, k: int, x: float, y: float, sea_raw: float, top_raw: float, height_scale: float, tile: float) -> float:
	var v := base[k]
	var q := (v - sea_raw) / (top_raw - sea_raw)
	if q <= 0.0:
		return v
	# Нормированная высота в метрах и метров на единицу сырой высоты (как в normalize)
	var r4 := sqrt(sqrt(q))
	var elev := q * r4 * height_scale
	var t := clampf((elev - DETAIL_LOW) / (DETAIL_HIGH - DETAIL_LOW), 0.0, 1.0)
	if t <= 0.0:
		return v
	var lift := t * t * (3.0 - 2.0 * t)
	var per_raw := 1.25 * r4 / (top_raw - sea_raw) * height_scale
	# Уклон основы (Собель на ±2 клетки), м на м
	var b := 2 * bw
	var gx := ((base[k + 2 - b] + 2.0 * base[k + 2] + base[k + 2 + b]) - (base[k - 2 - b] + 2.0 * base[k - 2] + base[k - 2 + b])) * per_raw / (16.0 * tile)
	var gy := ((base[k - 2 + b] + 2.0 * base[k + b] + base[k + 2 + b]) - (base[k - 2 - b] + 2.0 * base[k - b] + base[k + 2 - b])) * per_raw / (16.0 * tile)
	var g2 := gx * gx + gy * gy
	if g2 < 0.0016:
		return v
	var s := sqrt(g2)
	if s >= DETAIL_LIMIT:
		return v
	# Гребни и вершины чистые: на выпуклом перегибе (лапласиан на ±2 клетки, м) слой затухает,
	# ложбины начинаются ниже гребня, а вершины не дробятся на бугры
	var bend := ((base[k + 2] + base[k - 2]) + (base[k + b] + base[k - b]) - 4.0 * base[k]) * per_raw
	t = clampf((-bend - 0.6) / (2.0 - 0.6), 0.0, 1.0)
	# Keep a share of the ribs on convex slopes; the grade envelope still limits them.
	var crest := 1.0 - 0.65 * t * t * (3.0 - 2.0 * t)
	# Характер местности: где-то склоны изрезаны сильнее, где-то спокойнее; мелкие рёбра
	# и уступы чередуются пятнами
	t = clampf((hill.noise(x / 170.0 + 211.7, y / 170.0 - 93.1) + 0.5) / 1.0, 0.0, 1.0)
	var vary := t * t * (3.0 - 2.0 * t)
	t = clampf((hill.noise(x / 95.0 - 57.3, y / 95.0 + 138.9) + 0.5) / 1.0, 0.0, 1.0)
	var patch := t * t * (3.0 - 2.0 * t)
	# Пологие склоны — слабые волны; крутые — глубже, но самые крутые ослаблены
	t = clampf((s - 0.04) / (0.12 - 0.04), 0.0, 1.0)
	var gentle := t * t * (3.0 - 2.0 * t)
	# Направление падения: веса четырёх осей (0°, 90°, 45°, 135°) по cos 2θ и sin 2θ, их сумма 1
	var c2 := (gx * gx - gy * gy) / g2
	var s2 := 2.0 * gx * gy / g2
	# Ширина форм растёт к пологим склонам: там, где ходят дороги, — широкие ложбины и увалы
	# (стенки их положе), на крутых — узкие рёбра и промоины; самые мелкие — от 40 % крутизны
	t = clampf((s - 0.25) / (0.45 - 0.25), 0.0, 1.0)
	var narrow := t * t * (3.0 - 2.0 * t)
	t = clampf((s - 0.4) / (0.6 - 0.4), 0.0, 1.0)
	var fine := (0.1 + 0.3 * patch) * (t * t * (3.0 - 2.0 * t))
	# Амплитуда растёт с крутизной. На крутом склоне стенки
	# складываются с его уклоном (DETAIL_WALL); стенка ложбины не круче, чем позволяет её ширина
	# (DETAIL_CROSS). Это оценка амплитуды, не жёсткий предел градиента итоговой поверхности:
	# направление и вес форм также меняются по месту. Дороги проверяют готовую геометрию.
	var cross := DETAIL_CROSS * tile / ((1.0 - narrow) / DETAIL_RIB_BROAD + narrow / DETAIL_RIB + fine / DETAIL_RIB_FINE)
	var steep_fade := 1.0 - smoothstep(DETAIL_STEEP_FROM, DETAIL_LIMIT, s)
	var depth := minf(minf(DETAIL_DEPTH * s * (0.4 + 0.8 * vary), sqrt(maxf(0.0, DETAIL_LIMIT * DETAIL_LIMIT - s * s)) * DETAIL_WALL), cross) * lift * gentle * crest * steep_fade
	var f := 0.0
	if narrow < 1.0:
		f += _ribs(ridge, x, y, DETAIL_RIB_BROAD, c2, s2, 37.9) * (1.0 - narrow)
	if narrow > 0.0:
		f += _ribs(ridge, x, y, DETAIL_RIB, c2, s2, 0.0) * narrow
	if fine > 0.0:
		f += _ribs(ridge, x, y, DETAIL_RIB_FINE, c2, s2, 71.3) * fine
	return v + depth * f / per_raw


## Рёбра и ложбины одного масштаба (L клеток поперёк склона) по направлению падения (c2, s2):
## шум в осях, повёрнутых на 0°, 90°, 45° и 135°, смешан по весам и нормирован, затем ложбина —
## узкое V у нуля шума, отрог — скруглённый верх. От −0.24 до 0.5, в среднем около нуля
static func _ribs(ridge: Simplex, x: float, y: float, L: float, c2: float, s2: float, o: float) -> float:
	var la := L * DETAIL_LONG
	var n := 0.0
	var ww := 0.0
	var a := 0.0
	if c2 > 0.0:
		a = c2 * c2
		n += a * ridge.noise(x / la + 13.7 + o, y / L - 41.2)
	elif c2 < 0.0:
		a = c2 * c2
		n += a * ridge.noise(y / la - 27.9 + o, x / L + 8.6)
	ww += a * a
	a = 0.0
	var d1 := (x + y) * 0.7071067811865476
	var d2 := (y - x) * 0.7071067811865476
	if s2 > 0.0:
		a = s2 * s2
		n += a * ridge.noise(d1 / la + 55.1 + o, d2 / L - 19.4)
	elif s2 < 0.0:
		a = s2 * s2
		n += a * ridge.noise(d2 / la - 64.8 + o, d1 / L + 33.3)
	ww += a * a
	n /= sqrt(ww)
	var d := minf(sqrt(n * n + 0.02), 1.0)
	return 0.5 - (1.0 - d) * (1.0 - d)
