class_name TrailLabCatalog
extends RefCounted
## Готовые трассы Trail Lab: форма курса (Fixture.course), тип полотна, профиль составителя (TrailComposer.PROFILES,
## пусто — свои элементы формы) и полигон (Fixture.GROUNDS). Строятся тем же путём, что кнопка «Построить» в F2;
## ручное построение остаётся там. Первая — прежний полигон из четырёх полос с базовыми элементами (клавиши 1–4).
## 30.10: оставлены трассы, которые дают разное (обзор tools/trail_catalog_survey.gd); убраны повторы формы без новых
## элементов (прогулочные S и дорога, второе кольцо, лесная спираль, flow со своими элементами, лесной техлес).

const LIST := [
	{title = "Полигон элементов", shape = 0, kind = "mountain", style = "", ground = "flat"},
	{title = "S-повороты · скоростная · холмы", shape = 1, kind = "mountain", style = "flow", ground = "hills"},
	{title = "Серпантин · горная · горы", shape = 2, kind = "mountain", style = "mountain", ground = "mountain"},
	{title = "Серпантин · техническая · холмы", shape = 2, kind = "trail", style = "technical", ground = "hills"},
	{title = "Кольцо · скоростная", shape = 3, kind = "mountain", style = "flow", ground = "flat"},
	{title = "Спираль · смешанная · горы", shape = 4, kind = "mountain", style = "mixed", ground = "mountain"},
	{title = "Восьмёрка · техническая", shape = 5, kind = "trail", style = "technical", ground = "flat"},
	{title = "Восьмёрка · скоростная · холмы", shape = 5, kind = "mountain", style = "flow", ground = "hills"},
	{title = "Flow-трасса · скоростная · горы", shape = 6, kind = "mountain", style = "flow", ground = "mountain"},
	{title = "Технический лес · свои элементы", shape = 7, kind = "trail", style = "", ground = "flat"},
	{title = "Байк-парк · прыжки, настил, контруклон", shape = 8, kind = "mountain", style = "", ground = "flat"},
	{title = "Маршрут · смешанная", shape = 9, kind = "mountain", style = "mixed", ground = "flat"},
	{title = "Маршрут · горная · горы", shape = 9, kind = "mountain", style = "mountain", ground = "mountain"},
	{title = "Маршрут · узкая техническая · горы", shape = 9, kind = "trail", style = "technical", ground = "mountain"},
	# Главный полигон (30.10): своя местность 512 м, 1,9 км, элементы расставлены по участкам вручную, прыжок над оврагом
	{title = "Главный полигон · flow через овраг", shape = 10, kind = "mountain", style = "", ground = "polygon"},
	{title = "Даунхилл · Хребет и папоротники", shape = 11, kind = "mountain", style = "", ground = "downhill"},
	{title = "Кросс-кантри · Два холма", shape = 12, kind = "trail", style = "", ground = "xc"},
	# Большой спуск (30.10): своя гора 512 м, ~3,2 км в пять глав — гребень, опушка, ущелье, терраса, долина
	{title = "Большой спуск · гребень, ущелье, терраса, долина", shape = 13, kind = "mountain", style = "", ground = "epic"},
]


## Определения трассы номер index (пусто, если номера нет); заголовок курса — из списка.
static func routes(index: int, fixture: Script) -> Array[TrailDefinition]:
	if index < 0 or index >= LIST.size(): return []
	var spec: Dictionary = LIST[index]
	var kit: Array[TrailDefinition] = []
	# копии: полосы полигона — загруженные ресурсы, правка в лаборатории не должна менять их
	for d: TrailDefinition in fixture.course(spec.shape, spec.kind, spec.style, spec.ground):
		var copy := d.duplicate(true) as TrailDefinition
		if spec.shape != 0: copy.title = spec.title
		# у полигонов и байк-парка элементы расставлены вручную; на остальных — виражи в тугих поворотах
		if spec.shape not in [0, 8, 10, 11, 12, 13]:
			brake_zones(copy)
			add_berms(copy)
		kit.append(copy)
	return kit


## Флоу (30.10): перед шпилькой (туже HAIRPIN) — место для торможения: прыжковые и волнистые элементы, кончающиеся
## ближе BRAKE_ZONE до неё, убираются. Иначе велосипед в воздухе или на волнах не тормозит и вылетает в шпильке.
const HAIRPIN := 8.0
const BRAKE_ZONE := 15.0
static func brake_zones(d: TrailDefinition) -> void:
	var T := TrailElement.Profile
	var airy := [T.ROLLER, T.TABLETOP, T.WAVES, T.DIP, T.ROLLOVER, T.DROP, T.PUMP, T.RIPPLES]
	var length := d.route_length()
	var keep: Array[TrailElement] = []
	for e in d.elements:
		var end := e.station + e.length * 0.5
		var blocked := false
		if e.profile in airy:
			var at := end
			while at < minf(end + BRAKE_ZONE, length):
				if absf(d.curvature_at(at)) > 1.0 / HAIRPIN: blocked = true
				at += 1.0
		if not blocked: keep.append(e)
	if keep.size() != d.elements.size(): d.elements = keep


## Флоу (30.10, по обзору трасс): в повороте туже BERM_RADIUS без своего элемента — вираж. Без него на скорости
## узкие трассы вылетали в шпильках (радиус 5 м после разгона до 36 км/ч), а вираж держит тяжестью через нагрузку колёс.
const BERM_RADIUS := 12.0
const BERM_HEIGHT := 0.8
static func add_berms(d: TrailDefinition) -> void:
	var length := d.route_length()
	var tight := 1.0 / BERM_RADIUS
	var at := 4.0
	var added: Array[TrailElement] = []
	while at < length - 4.0:
		if absf(d.curvature_at(at)) < tight:
			at += 1.0
			continue
		# весь тугой участок одного знака
		var sign := signf(d.curvature_at(at))
		var from := at
		while at < length - 4.0 and absf(d.curvature_at(at)) >= tight * 0.7 and signf(d.curvature_at(at)) == sign: at += 1.0
		var mid := (from + at) * 0.5
		var span := clampf(at - from + 6.0, 10.0, 26.0)
		var free := mid - span * 0.5 > 2.0 and mid + span * 0.5 < length - 2.0
		for e in d.elements + added:
			if absf(e.station - mid) < (e.length + span) * 0.5 + 2.0: free = false
		if free: added.append(TrailElementLibrary.make(TrailElement.Profile.BERM, mid, span, BERM_HEIGHT, sign))
		at += 2.0
	if added.is_empty(): return
	var list: Array[TrailElement] = d.elements.duplicate()
	list.append_array(added)
	list.sort_custom(func(a: TrailElement, b: TrailElement) -> bool: return a.station < b.station)
	var before := d.elements
	d.elements = list
	if not d.validate().is_empty(): d.elements = before
