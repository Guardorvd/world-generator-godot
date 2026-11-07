class_name BikePark
extends RefCounted
## Прокладка линий трейл-парка: trail_world_network.gd берёт их как кандидатов, принимает и запекает как все трассы.
## Велопарки стартовой области (от одного до MAX_PARKS): простой дешёвый поиск пустых просторных площадок (без дорог,
## поселений, воды и сооружений) и прокладка в каждой сети длинных извилистых трасс с разворотами и элементами. Без
## перебора участков и без построителя линии по рельефу: линии ведёт простой «ходок», рельеф под них готовит общее
## формирование (TrailShaping при запекании), элементы ставит общий TrailComposer. Детерминирован по сиду.
##
## Поиск (build_all): сетка через STRIDE клеток, расстояние до ближайшей занятой клетки (дороги, поселения, море, озёра,
## реки, кручи; двухпроходная фаска 1 / √2). Оценка клетки — простор + подходящий склон + перепад высот в окне вокруг неё;
## лучшие клетки блоков сетки, не ближе друг к другу радиуса площадки, и есть кандидаты. Кандидату добавляется или
## вычитается доступность (расстояние от площадки до ближайшей дороги или тропы): парк, к которому нельзя подъехать, не
## нужен. Парки строятся по порядку ценности (с небольшой прибавкой за характер, которого ещё нет); следующий не ближе
## занятого предыдущими (по фактической дальности его линий) и должен быть не хуже EXTRA_QUALITY: лучше один хороший
## парк, чем три посредственных. Площадок нет — парков нет.
## Характер площадки (по среднему склону окна): поляна (пологая), холмы, предгорье (умеренный склон). От него зависят
## уклон, до которого ходок идёт, его тяга вниз и извилистость; вид трассы (park, flow, enduro, downhill, tech) — по уклону
## самой линии, так что у парка есть и пологие, и динамичные линии, а не одна заготовка.
## Прокладка: магистраль от верхней точки площадки, затем ветки из случайных мест уже проложенных линий. Ходок шагает по
## STEP м: плавные изгибы (сумма синусоид), уход к горизонтали на крутом склоне и лёгкий уклон вниз на пологом, разворот
## радиуса HAIRPIN у края площадки или перед чужой линией. Ветка в конце ищет ближайшую линию и примыкает к ней — сеть.

const MAX_PARKS := 3
const PARK_QUALITY := 1.15   # первый парк: площадка хуже этой оценки парка не получает (нет склона, простора или перепада)
const EXTRA_QUALITY := 1.5  # второй и третий парк только на заметно хорошей площадке
const DIVERSITY := 0.15      # прибавка к ценности площадки за характер, которого в мире ещё нет
const CANDIDATES := 8        # площадок-кандидатов с запасом: часть не пройдёт по доступу, соседству или длине
const LAYOUT_TRIES := 5      # не больше стольких прокладок (каждая — работа ходока)
const BLOCK := 12            # блок поиска кандидатов, клеток сетки: одна лучшая клетка на блок
const GAP := 60.0            # между фактическими линиями соседних парков не меньше, м
const ACCESS_FAR := 380.0    # парк дальше этого от дороги или тропы (от края площадки) не строится, м
const MIN_LENGTH := 1000.0   # меньше этого суммарной длины и двух линий — парка нет, м
const MIN_LINES := 2
const LINE_MIN := 280.0      # линия короче сети не нужна: PARK_MIN 250 м плюс отступы концов (TrailWorldNetwork), м
const CHARACTER_NAMES := {meadow = "Поляна", hills = "Холмы", foothill = "Предгорье"}
## Ходок по характеру: до какого уклона идёт без штрафа, тяга вниз, множитель извилистости
const WALKER := {meadow = {grade = 0.08, bias = 0.03, wind = 1.6}, hills = {grade = 0.10, bias = 0.04, wind = 1.0},
	foothill = {grade = 0.14, bias = 0.07, wind = 0.7}}
const STRIDE := 2            # шаг сетки поиска, клеток
const SETTLE_R := 14.0       # поселение занимает круг такого радиуса вокруг центра, клеток
const HUT_R := 4.0           # и вокруг каждого дома
const STEEP_LAND := 0.35     # круче (≈19°) земля для парка занята: на кручах полотно уходит в глубокие насыпи, а запекание
                             # рельефа под них (TrailBuilder.bake_elements при каждой загрузке) растёт с шириной зоны работ
const STEEP_ONE := 0.7       # одна клетка круче (≈35°) занята всегда
const MARGIN := 24.0        # запас от края области до линий, м
const R_MIN := 50.0          # меньше — парка нет, м
const R_GOOD := 160.0        # площадка такого радиуса — полный балл за простор: пустого места мира больше почти не бывает, м
const R_MAX := 450.0        # дальше от центра парк не уходит, м
const STEP := 4.0            # шаг линии, м
const HAIRPIN := 8.0         # радиус разворота, м
const SEP := 12.0            # линии не ближе друг к другу, м
const LOOK := 24.0           # взгляд вперёд, м
const OWN_SKIP := 70.0       # свою линию ближе этой станции назад не считаем препятствием, м
const CELL := 8.0            # клетка индекса занятости, м
const TRUNK := 2400.0        # длина магистрали, м
const BRANCH := Vector2(500.0, 1300.0)
const TARGET := 3000.0       # общая длина парка, м: ориентир для большой площадки (запекание растёт с длиной)
const TARGET_BASE := 600.0
const TARGET_PER_M := 10.0  # площадка меньше — парк короче: TARGET_BASE + радиус × это, м
const TARGET_MIN := 1400.0
const ATTEMPTS := 80
const DEAD_END := 300.0      # ветка без примыкания остаётся, если не короче, м
const SEEK := 220.0          # ветка ищет примыкание не дальше, м
const WIDTH := 3.5
## Вид линии по её среднему уклону (круче — динамичнее), по кругу внутри полосы: у парка и пологие, и крутые, и техничные линии
const STYLES := [[0.05, ["park", "park", "flow"]], [0.09, ["flow", "park", "tech", "flow"]], [0.14, ["enduro", "flow", "tech"]],
	[1.0, ["downhill", "enduro", "tech"]]]
const NAMES := ["Магистраль", "Горная", "Смешанная", "Техничная", "Флоу", "Лесная"]

var center := Vector2.ZERO   ## м
var quality := 0.0           ## оценка площадки: простор + подходящий склон + перепад высот (до ~2,1); 0 — выбора не было
var value := 0.0             ## оценка с учётом доступности: по ней парки идут по порядку
var access := INF            ## м от края площадки до ближайшей дороги или тропы (INF — не считалось)
var radius := 0.0            ## м, до ближайшего занятого места от центра
var extent := 0.0            ## м, самая дальняя точка трасс от центра
var character := "hills"     ## meadow (поляна), hills (холмы), foothill (предгорье)
var park_name := ""
var routes: Array[TrailDefinition] = []
var styles: Array[String] = []   ## вид каждой линии (по номеру в routes): park, flow, enduro, downhill, tech
var reason := ""
var stats := {find_ms = 0.0, layout_ms = 0.0, length = 0.0, attempts = 0, stops = {}}

var _h: Heightfield
var _avoid: Array[Vector3] = [] # занятые другими парками круги: центр и радиус, м
var _grade := 0.10
var _bias := 0.04
var _wind := 1.0
var _target := TARGET
var _rng := RandomNumberGenerator.new()
var _occ := {}
var _wet := {} # клетка -> у неё или рядом вода / край карты (_inside спрашивает одни и те же клетки много раз)
var _field := PackedFloat32Array() # расстояние до занятого, шагов сетки поиска
var _rect := Rect2i()
var _gw := 0
var _gh := 0
var _ground_fn := Callable()
var _inside_fn := Callable()


## Найти площадки в rect (клетки) и проложить на них парки: от нуля до MAX_PARKS, лучшие первыми. `access(Vector2) -> float` —
## необязательно: расстояние от точки (м) до ближайшей дороги или тропы; без него доступность не учитывается.
## Пустой массив — подходящего места нет (причина в stats последнего поиска: BikePark.last_reason).
static var last_reason := ""
static var last_stats := {}

static func build_all(w: WorldData, h: Heightfield, rect: Rect2i, prefix: String, access := Callable()) -> Array[BikePark]:
	var parks: Array[BikePark] = []
	last_reason = ""
	var t := Time.get_ticks_usec()
	var survey := _survey(w, h, rect)
	var sites := _sites(survey, access)
	var find_ms := (Time.get_ticks_usec() - t) / 1000.0
	last_stats = {find_ms = find_ms, layout_ms = 0.0, sites = sites.size(), best_quality = 0.0, refused = {},
		found = sites.map(func(s: Dictionary) -> String: return "%s r%.0f q%.2f v%.2f доступ %.0f (%.0f,%.0f)" % [s.character, s.radius, s.quality, s.value, s.access, s.center.x, s.center.y])}
	if sites.is_empty():
		last_reason = "нет пустой площадки радиусом от %.0f м с доступом к дорогам" % R_MIN
		return parks
	last_stats.best_quality = snappedf(float(sites[0].quality), 0.01)
	var avoid: Array[Vector3] = []
	var used := {}
	var tries := 0
	while parks.size() < MAX_PARKS and tries < LAYOUT_TRIES and not sites.is_empty():
		var pick := 0
		var best := -INF
		for i in sites.size():
			var v: float = sites[i].value + (0.0 if used.has(sites[i].character) else DIVERSITY)
			if v > best:
				best = v
				pick = i
		var site: Dictionary = sites.pop_at(pick)
		if float(site.value) < (PARK_QUALITY if parks.is_empty() else EXTRA_QUALITY):
			_refuse("оценка площадки ниже нужной")
			continue
		var near := false
		for a: Vector3 in avoid:
			if Vector2(a.x, a.y).distance_to(site.center) < a.z + R_MIN: near = true
		if near:
			_refuse("площадка у другого парка")
			continue
		tries += 1
		var park := BikePark.new()
		park._h = h
		park._rect = rect
		park._field = survey.d
		park._gw = survey.gw
		park._gh = survey.gh
		park.center = site.center
		park.radius = site.radius
		park.quality = site.quality
		park.value = site.value
		park.access = site.access
		park.character = site.character
		park._avoid = avoid.duplicate()
		park._setup()
		park._rng.seed = hash("%s|bike_park|%d,%d" % [w.seed_text, roundi(site.center.x), roundi(site.center.y)])
		var started := Time.get_ticks_usec()
		park._layout("%s%d" % [prefix, parks.size()])
		park.stats.layout_ms = (Time.get_ticks_usec() - started) / 1000.0
		last_stats.layout_ms += park.stats.layout_ms
		# считаются линии, которые сеть возьмёт (TrailWorldNetwork: без концов по PARK_END, не короче PARK_MIN)
		var usable := 0
		var usable_length := 0.0
		for d in park.routes:
			if d.route_length() >= LINE_MIN:
				usable += 1
				usable_length += d.route_length()
		if usable < MIN_LINES or usable_length < MIN_LENGTH:
			_refuse("линии парка не проложились (годных %d, %.0f м)" % [usable, usable_length])
			continue
		avoid.append(Vector3(park.center.x, park.center.y, park.extent + GAP))
		used[park.character] = true
		var base: String = CHARACTER_NAMES[park.character]
		var same := 0
		for other in parks:
			if other.character == park.character: same += 1
		park.park_name = base if same == 0 else "%s %d" % [base, same + 1]
		parks.append(park)
	if parks.is_empty(): last_reason = "площадки есть (%d), но парк ни на одной не вышел: %s" % [last_stats.sites, last_stats.refused]
	return parks


static func _refuse(why: String) -> void:
	last_stats.refused[why] = int(last_stats.refused.get(why, 0)) + 1


## Занятость сетки поиска и расстояние до занятого (в клетках сетки): {d, slope, height, gw, gh}.
static func _survey(w: WorldData, h: Heightfield, rect: Rect2i) -> Dictionary:
	var gw := maxi(1, rect.size.x / STRIDE)
	var gh := maxi(1, rect.size.y / STRIDE)
	var d := PackedFloat32Array()
	d.resize(gw * gh)
	d.fill(1e9)
	# занято: дороги и тропы (path_mask от 2; звериные тропы пересекать можно), море, озёра и настоящие реки (ручьи — нет)
	var mask := w.path_mask
	var has_mask := mask.size() == w.N
	var ocean := w.ocean
	var lake := w.lake
	var river := w.river
	var acc := w.acc
	var hv := h.hv
	var slope := PackedFloat32Array() # крутизна и высота клеток сетки поиска: для оценки, годится ли место под парк
	var height := PackedFloat32Array()
	slope.resize(gw * gh)
	height.resize(gw * gh)
	for gz in gh:
		for gx in gw:
			if gx == 0 or gz == 0 or gx == gw - 1 or gz == gh - 1:
				d[gz * gw + gx] = 0.0
				continue
			var cx := rect.position.x + gx * STRIDE
			var cz := rect.position.y + gz * STRIDE
			var busy := false
			var steepness := 0.0
			for oz in STRIDE:
				for ox in STRIDE:
					var i := (cz + oz) * w.W + cx + ox
					if (has_mask and mask[i] >= 2) or ocean[i] != 0 or lake[i] != 0 or (river[i] != 0 and acc[i] >= WorldData.RIVER_ACC): busy = true
					var sx := (hv[mini(i + 1, w.N - 1)] - hv[maxi(i - 1, 0)]) / (2.0 * GameConfig.TILE)
					var sz := (hv[mini(i + w.W, w.N - 1)] - hv[maxi(i - w.W, 0)]) / (2.0 * GameConfig.TILE)
					var here := sqrt(sx * sx + sz * sz)
					if here > STEEP_ONE: busy = true # отвесная клетка (скала, обрыв) — не пройти
					steepness += here
			# Крутая земля по клетке блока, а не по каждой клетке: рябь и овражки горной детали (GEO 9) единичными клетками круче
			# порога не делают площадку непригодной — полотно положат земляные работы
			if steepness / (STRIDE * STRIDE) > STEEP_LAND: busy = true
			slope[gz * gw + gx] = steepness / (STRIDE * STRIDE)
			height[gz * gw + gx] = hv[cz * w.W + cx]
			if busy: d[gz * gw + gx] = 0.0
	var discs: Array[Vector3] = []
	for v: SettlementData in w.settlements:
		discs.append(Vector3(v.x, v.y, SETTLE_R))
		for hut in v.huts: discs.append(Vector3(hut.x, hut.y, HUT_R))
	for s: Dictionary in h.structures:
		var foot := TrailSite.structure_foot(s)
		var c := foot.get_center() / GameConfig.TILE
		discs.append(Vector3(c.x, c.y, foot.size.length() * 0.5 / GameConfig.TILE + 2.0))
	for disc in discs:
		var r := disc.z / STRIDE
		var c := (Vector2(disc.x, disc.y) - Vector2(rect.position)) / STRIDE
		for gz in range(maxi(0, floori(c.y - r)), mini(gh, ceili(c.y + r) + 1)):
			for gx in range(maxi(0, floori(c.x - r)), mini(gw, ceili(c.x + r) + 1)):
				if Vector2(gx, gz).distance_to(c) <= r: d[gz * gw + gx] = 0.0
	# двухпроходная фаска: вперёд и назад
	var diag := sqrt(2.0)
	for gz in range(1, gh):
		for gx in range(1, gw - 1):
			var i := gz * gw + gx
			d[i] = minf(d[i], minf(minf(d[i - 1] + 1.0, d[i - gw] + 1.0), minf(d[i - gw - 1] + diag, d[i - gw + 1] + diag)))
	for gz in range(gh - 2, -1, -1):
		for gx in range(gw - 2, 0, -1):
			var i := gz * gw + gx
			d[i] = minf(d[i], minf(minf(d[i + 1] + 1.0, d[i + gw] + 1.0), minf(d[i + gw + 1] + diag, d[i + gw - 1] + diag)))
	return {d = d, slope = slope, height = height, gw = gw, gh = gh, rect = rect}


## Площадки-кандидаты, лучшие по ценности первыми: [{center, radius, quality, value, access, character, cell}].
## Не просто самая большая пустая область, а та, где есть чем кататься. Парку нужна просторная площадка (расстояние до
## занятого), склон около 4–20 % вокруг (на ровном нечего строить, на крутом линии уходят в глубокие насыпи) и перепад
## высот, из которого получаются развороты, прыжки и вид. Оценка по окну вокруг клетки; места с радиусом меньше R_MIN не
## берутся. От каждого блока сетки берётся лучшая клетка; кандидаты не ближе радиуса площадки друг к другу.
static func _sites(survey: Dictionary, access: Callable) -> Array[Dictionary]:
	const WINDOW := 14 # половина окна, клеток сетки поиска (около 110 м)
	var d: PackedFloat32Array = survey.d
	var slope: PackedFloat32Array = survey.slope
	var height: PackedFloat32Array = survey.height
	var gw: int = survey.gw
	var gh: int = survey.gh
	var rect: Rect2i = survey.rect
	var stride := gw + 1
	var sum_slope := PackedFloat64Array()
	var sum_h := PackedFloat64Array()
	var sum_h2 := PackedFloat64Array()
	sum_slope.resize(stride * (gh + 1))
	sum_h.resize(stride * (gh + 1))
	sum_h2.resize(stride * (gh + 1))
	for gz in gh:
		var row_s := 0.0
		var row_h := 0.0
		var row_h2 := 0.0
		for gx in gw:
			var k := gz * gw + gx
			row_s += slope[k]
			row_h += height[k]
			row_h2 += height[k] * height[k]
			var up := gz * stride + gx + 1
			var at := (gz + 1) * stride + gx + 1
			sum_slope[at] = sum_slope[up] + row_s
			sum_h[at] = sum_h[up] + row_h
			sum_h2[at] = sum_h2[up] + row_h2
	var bw := ceili(float(gw) / BLOCK)
	var bh := ceili(float(gh) / BLOCK)
	var block_score := PackedFloat32Array()
	var block_cell := PackedInt32Array()
	var block_slope := PackedFloat32Array()
	block_score.resize(bw * bh)
	block_score.fill(-1.0)
	block_cell.resize(bw * bh)
	block_slope.resize(bw * bh)
	var min_d := (R_MIN + MARGIN) / (STRIDE * GameConfig.TILE)
	for gz in range(1, gh - 1):
		for gx in range(1, gw - 1):
			var room := d[gz * gw + gx]
			if room < min_d: continue
			var x0 := maxi(0, gx - WINDOW)
			var z0 := maxi(0, gz - WINDOW)
			var x1 := mini(gw, gx + WINDOW + 1)
			var z1 := mini(gh, gz + WINDOW + 1)
			var count := float((x1 - x0) * (z1 - z0))
			var s := (sum_slope[z1 * stride + x1] - sum_slope[z0 * stride + x1] - sum_slope[z1 * stride + x0] + sum_slope[z0 * stride + x0]) / count
			var m := (sum_h[z1 * stride + x1] - sum_h[z0 * stride + x1] - sum_h[z1 * stride + x0] + sum_h[z0 * stride + x0]) / count
			var m2 := (sum_h2[z1 * stride + x1] - sum_h2[z0 * stride + x1] - sum_h2[z1 * stride + x0] + sum_h2[z0 * stride + x0]) / count
			var relief := sqrt(maxf(0.0, m2 - m * m))
			# полка вокруг 11 %: от 7,5 до 14,5 % — полная оценка, дальше убывает (поляна и предгорье тоже годятся, но хуже)
			var fit := clampf(1.0 - maxf(0.0, absf(s - 0.11) - 0.035) / 0.075, 0.0, 1.0)
			var size := minf(room * STRIDE * GameConfig.TILE - MARGIN, R_GOOD) / R_GOOD
			var score := size + 0.8 * fit + 0.3 * clampf(relief / 12.0, 0.0, 1.0)
			var b := (gz / BLOCK) * bw + gx / BLOCK
			if score > block_score[b]:
				block_score[b] = score
				block_cell[b] = gz * gw + gx
				block_slope[b] = s
	var order := range(bw * bh).filter(func(b: int) -> bool: return block_score[b] >= 0.0)
	order.sort_custom(func(a: int, b: int) -> bool: return block_score[a] > block_score[b])
	var sites: Array[Dictionary] = []
	for b: int in order:
		if sites.size() >= CANDIDATES: break
		var cell := block_cell[b]
		var at := (Vector2(rect.position) + Vector2(cell % gw, cell / gw) * STRIDE + Vector2.ONE * STRIDE * 0.5) * GameConfig.TILE
		var r := minf(R_MAX, d[cell] * STRIDE * GameConfig.TILE - MARGIN)
		var crowded := false
		for other: Dictionary in sites:
			if (other.center as Vector2).distance_to(at) < maxf(float(other.radius), r) + R_MIN: crowded = true
		if crowded: continue
		var s: float = block_slope[b]
		var distance := INF
		var bonus := 0.0
		if access.is_valid():
			distance = maxf(0.0, float(access.call(at)) - r)
			if distance > ACCESS_FAR: continue
			bonus = 0.2 if distance <= 120.0 else (0.0 if distance <= 260.0 else -0.2)
		sites.append({center = at, radius = r, quality = block_score[b], value = block_score[b] + bonus, access = distance,
			character = "meadow" if s < 0.06 else ("foothill" if s >= 0.13 else "hills"), cell = cell})
	sites.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.value > b.value)
	return sites


## Настройки ходка и длина парка по характеру и размеру площадки.
func _setup() -> void:
	var walker: Dictionary = WALKER[character]
	_grade = walker.grade
	_bias = walker.bias
	_wind = walker.wind
	_target = clampf(TARGET_BASE + radius * TARGET_PER_M, TARGET_MIN, TARGET)


func _ground(p: Vector2) -> float:
	return _h.ground_at(p.x, p.y) if _h != null else float(_ground_fn.call(p))


## Только прокладка на заданном рельефе и области (изолированная проверка tools/bike_park_look.gd, без мира).
static func lay_out(ground: Callable, inside: Callable, at: Vector2, r: float, seed_text: String, prefix: String) -> BikePark:
	var park := BikePark.new()
	park._ground_fn = ground
	park._inside_fn = inside
	park.center = at
	park.radius = r
	park._rng.seed = hash(seed_text + "|bike_park")
	var t := Time.get_ticks_usec()
	park._layout(prefix)
	park.stats.layout_ms = (Time.get_ticks_usec() - t) / 1000.0
	return park


func _layout(prefix: String) -> void:
	# магистраль — от самой высокой точки внутри области
	var top := center
	for k in 48:
		var p := center + Vector2.from_angle(TAU * k / 48.0) * radius * 0.8
		if _inside(p) and _ground(p) > _ground(top): top = p
	var heading := (center - top).angle() if top != center else _rng.randf() * TAU
	_mark(top, 0, 0.0)
	var trunk := _walk(top, heading, minf(TRUNK, _target * 0.8), 0, false)
	if trunk.size() < 20: return
	_add(trunk, prefix)
	var total := routes[0].route_length()
	while total < _target and stats.attempts < ATTEMPTS:
		stats.attempts += 1
		# начало ветки — лучшее из нескольких случайных мест: туда, где впереди больше свободной земли
		var at := Vector2.ZERO
		var dir := Vector2.ZERO
		var room := -1
		for k in 12:
			var parent := routes[_rng.randi() % routes.size()]
			var s := _rng.randf_range(0.05, 0.95) * parent.route_length()
			var side := 1.0 if _rng.randf() < 0.5 else -1.0
			var c_dir := parent.tangent_at(s).rotated(side * _rng.randf_range(0.9, 1.4))
			var c_at := parent.point_at(s)
			var free := 0
			for j in range(1, 13):
				var q := c_at + c_dir * (20.0 + j * 15.0)
				if not _inside(q): break
				if _blocked(q, -1, 0.0, Vector2.INF): continue
				free += 1
			if free > room:
				room = free
				at = c_at
				dir = c_dir
		if room < 3: continue
		var line := _walk(at, dir.angle(), _rng.randf_range(BRANCH.x, BRANCH.y), routes.size(), true)
		if line.size() < 50: # короче ~200 м ветка не нужна
			_purge(routes.size())
			continue
		_add(line, prefix)
		total += routes[-1].route_length()
	stats.length = total
	for d in routes:
		for q in d.points: extent = maxf(extent, q.distance_to(center))


## Линия от start: точки через STEP. route — номер линии в индексе занятости, seek — в конце искать примыкание
## к другой линии (не нашла — остаётся тупиком, если не короче DEAD_END). Каждый шаг — лучшее из направлений веером
## вокруг желаемого, поворот за шаг не круче радиуса HAIRPIN: свободно и внутри области, уклон не круче GRADE (иначе
## штраф), лёгкий спуск, поменьше поворот, и впереди свободно (взгляд на LOOK: чем ближе тупик, тем больше штраф).
## Упёрлась впереди — поворачивает до упора в одну сторону, так и получаются развороты и серпантины.
func _walk(start: Vector2, heading: float, length: float, route: int, seek: bool) -> PackedVector2Array:
	var pts := PackedVector2Array([start])
	var p := start
	var a := heading
	var s := 0.0
	var ph := Vector2(_rng.randf() * TAU, _rng.randf() * TAU)
	var limit := length + (SEEK if seek else 0.0)
	var target := Vector2.INF
	var bend := 0.0 # поворот прошлого шага
	var max_turn := STEP / HAIRPIN
	while s < limit:
		var seeking := seek and s >= length
		if seeking:
			var join := _nearest_other(p, route, SEEK)
			if join.z < INF:
				target = Vector2(join.x, join.y)
				if target.distance_to(p) < STEP * 1.5:
					if target.distance_to(pts[-1]) > 0.5: pts.append(target)
					return pts
		var want := (0.05 * sin(s / 43.0 + ph.x) + 0.035 * sin(s / 17.0 + ph.y)) * STEP * _wind
		if seeking and target != Vector2.INF:
			want = clampf(Vector2.from_angle(a).angle_to(target - p), -max_turn, max_turn)
		var best := INF
		var best_o := 0.0
		var here_y := _ground(p)
		for k in 11:
			var o := -max_turn + max_turn * 0.2 * k
			var dir := Vector2.from_angle(a + o)
			var next := p + dir * STEP
			var g := (_ground(next) - here_y) / STEP
			var cost := absf(o - want) + maxf(0.0, absf(g) - _grade) * 40.0 + absf(g + _bias) * 2.0
			# взгляд вперёд только добавляет к цене: ход, который уже не лучше найденного, дальше не проверяется
			if cost >= best or not _free(next, route, s, start, target): continue
			for j in range(1, 5):
				if not _free(p + dir * (STEP + LOOK * j / 4.0), route, s, start, target):
					cost += 40.0 / j - (1.0 if signf(o) == signf(bend) else 0.0)
					break
			if cost < best:
				best = cost
				best_o = o
		if best == INF:
			_stop("некуда шагнуть")
			if not seek or seeking: break
			length = s # ветка дальше ищет примыкание
			continue
		a += best_o
		bend = best_o
		p += Vector2.from_angle(a) * STEP
		s += STEP
		pts.append(p)
		_mark(p, route, s)
	if s >= limit: _stop("длина")
	if seek and s < DEAD_END: return PackedVector2Array()
	return pts


func _stop(why: String) -> void:
	stats.stops[why] = stats.stops.get(why, 0) + 1


## Внутри пустой области и не на чужой линии; у цели примыкания линии не мешают.
func _free(p: Vector2, route: int, s: float, start: Vector2, target: Vector2) -> bool:
	if not _inside(p): return false
	if target != Vector2.INF and p.distance_to(target) < SEP + STEP: return true
	return not _blocked(p, route, s, start)


func _inside(p: Vector2) -> bool:
	if _inside_fn.is_valid(): return _inside_fn.call(p)
	for a: Vector3 in _avoid:
		if Vector2(a.x, a.y).distance_squared_to(p) < a.z * a.z: return false
	# воду (и ручьи) линии пока обходят: у воды рельеф не формируется, и переход через ручей выходит крутым
	var cell := Vector2i((p / GameConfig.TILE).floor())
	var wet: Variant = _wet.get(cell)
	if wet == null:
		wet = false
		for oz in range(-1, 2):
			for ox in range(-1, 2):
				var q := cell + Vector2i(ox, oz)
				if q.x < 0 or q.y < 0 or q.x >= _h.world.W or q.y >= _h.world.H or _h.water_level[q.y * _h.world.W + q.x] != -INF: wet = true
		_wet[cell] = wet
	if wet: return false
	if p.distance_to(center) > R_MAX: return false
	var c := Vector2i(((p / GameConfig.TILE - Vector2(_rect.position)) / STRIDE).floor())
	if c.x < 0 or c.y < 0 or c.x >= _gw or c.y >= _gh: return false
	return _field[c.y * _gw + c.x] * STRIDE * GameConfig.TILE >= MARGIN


## Убрать из индекса линию, которую не приняли.
func _purge(route: int) -> void:
	for k: Vector2i in _occ:
		_occ[k] = (_occ[k] as Array).filter(func(e: Vector4) -> bool: return int(e.z) != route)


func _key(p: Vector2) -> Vector2i:
	return Vector2i((p / CELL).floor())


func _mark(p: Vector2, route: int, s: float) -> void:
	var k := _key(p)
	if not _occ.has(k): _occ[k] = []
	(_occ[k] as Array).append(Vector4(p.x, p.y, route, s))


## Занято чужой линией (или своей далеко назад). Начало ветки у родительской линии не считается.
func _blocked(p: Vector2, route: int, s: float, start: Vector2) -> bool:
	if s < 40.0 and p.distance_to(start) < 30.0: return false
	var k := _key(p)
	for oz in range(-2, 3):
		for ox in range(-2, 3):
			for e: Vector4 in _occ.get(k + Vector2i(ox, oz), []):
				if Vector2(e.x, e.y).distance_to(p) >= SEP: continue
				if int(e.z) == route and e.w > s - OWN_SKIP: continue
				return true
	return false


## Ближайшая точка другой линии (x, y, расстояние) не дальше reach, иначе z = INF.
func _nearest_other(p: Vector2, route: int, reach: float) -> Vector3:
	var best := Vector3(0, 0, INF)
	var n := ceili(reach / CELL)
	var k := _key(p)
	for oz in range(-n, n + 1):
		for ox in range(-n, n + 1):
			for e: Vector4 in _occ.get(k + Vector2i(ox, oz), []):
				if int(e.z) == route: continue
				var dist := Vector2(e.x, e.y).distance_to(p)
				if dist < best.z and dist <= reach: best = Vector3(e.x, e.y, dist)
	return best


func _add(points: PackedVector2Array, prefix: String) -> void:
	var n := routes.size()
	var d := TrailDefinition.new()
	d.id = "%s/%d" % [prefix, n]
	d.title = NAMES[n] if n < NAMES.size() else "Ветка %d" % n
	d.kind = "mountain"
	d.width = WIDTH
	d.surface = RoadSurface.DIRT
	d.earthwork = 1.0
	d.auto_bank = 1.0
	d.points = points
	routes.append(d)
	# вид линии — по её среднему уклону; в мире элементы ставит общий построитель при приёмке, черновые не нужны
	var grade := absf(_ground(points[0]) - _ground(points[-1])) / maxf(1.0, d.route_length())
	var kinds: Array = STYLES[-1][1]
	for band: Array in STYLES:
		if grade < float(band[0]):
			kinds = band[1]
			break
	styles.append(kinds[n % kinds.size()])
	if _h == null:
		var profile: Dictionary = TrailComposer.PROFILES[["flow", "mountain", "mixed", "technical", "flow", "forest"][n % 6]]
		d.elements.assign(TrailComposer.compose(d, profile, _rng.randi(), _ground).elements)
