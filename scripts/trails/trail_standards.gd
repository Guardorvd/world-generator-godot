extends RefCounted
## Расчётные стандарты элементов (01.11.2026, по разбору заездов 31.10 — docs/TRAIL_STANDARDS.md).
## Размер элемента задаётся не «сложностью на глаз», а скоростью, с которой на него приходят, и уровнем трассы:
## на какой скорости стол приземляет на спуск, гэп перелетают, роллер перекатывают, памп держит колёса, вираж
## поворачивает, техника проходится без жёсткого удара. Одни и те же формулы:
##   spec(kind, v, level)  — размеры элемента под скорость входа v и уровень (составитель, генератор трасс);
##   window(e, d)          — что ожидать от готового элемента: окно скорости, кромка, зона и идеал приземления
##                           (разбор заездов, F3 в Trail Lab);
##   speed_profile(d, ...) — скорость «среднего седока» вдоль оси трассы: педали до крейсерской, накат на спуске,
##                           торможение перед поворотами и техникой (куда ставить и какого размера).
## Модель — точка на профиле элемента по той же физике, что BikeRide: тяжесть GameConfig.GRAVITY, качение и воздух,
## отрыв, когда профиль уходит вниз круче, чем тянет тяжесть, затем баллистика до касания. Поправки (угол схода,
## потеря на кромке) подобраны стендом tools/trail_standards_stand.gd; там же `-- --check` проверяет, что элементы
## по стандарту на своей скорости приземляют в зону, памп не отрывает колёса, техника не бьёт жёстче уровня.

const T := TrailElement.Profile
const G := GameConfig.GRAVITY
## Скорости входа, под которые считаются стандарты (стенд проверяет каждую), м/с.
const DESIGN_SPEEDS := [8.0, 11.0, 14.0, 17.0]
## Удар приземления, с которого BikeRide гасит скорость (SOFT_IMPACT), м/с: выше — уже «жёстко».
const IMPACT_SOFT := BikeRide.SOFT_IMPACT

## Уровни трассы. height — доля диапазона высот прыжков (0 — самые низкие); impact — допустимый удар приземления
## и удар колеса о кромку на расчётной скорости, м/с; lat — доля предельной боковой перегрузки, на которую рассчитан
## поворот; window — допуск окна скорости прыжка, ±м/с; gap / drop — ставятся ли гэпы и дропы; tech — высота камней
## и корней, доля диапазона.
## top — комфортная скорость седока уровня: быстрее он притормаживает (профиль скорости не разгоняется выше), м/с.
const LEVELS := [
	{key = "green", title = "Зелёная", height = 0.0, impact = 4.5, lat = 0.6, window = 2.5, gap = false, drop = 0.5, tech = 0.0, top = 11.0},
	{key = "blue", title = "Синяя", height = 0.35, impact = 5.5, lat = 0.7, window = 2.0, gap = false, drop = 0.8, tech = 0.35, top = 14.0},
	{key = "red", title = "Красная", height = 0.7, impact = 6.5, lat = 0.8, window = 1.6, gap = true, drop = 1.1, tech = 0.7, top = 17.0},
	{key = "black", title = "Чёрная", height = 1.0, impact = 7.0, lat = 0.9, window = 1.3, gap = true, drop = 1.4, tech = 1.0, top = 20.0},
]
## Стол ниже этого не ставится (на малой скорости он уже роллер), м.
const TABLE_LOW := 0.4
## Высоты прыжков по уровню (от зелёной к чёрной), м.
const HEIGHTS := {T.TABLETOP: Vector2(0.6, 1.8), T.GAP: Vector2(1.1, 1.8), T.ROLLER: Vector2(0.3, 0.9), T.PUMP: Vector2(0.3, 0.55)}

## — Физика (из BikeRide / GameConfig) —
## Предельная боковая перегрузка с полным рулём на ровной плотной земле, м/с²: стенд tools/steer_stand.gd
## (31.10, 10–16 м/с: 0,67–0,69 g при GRAVITY 16). Выше доля LEVELS.lat — запас на неточный руль.
const LAT_MAX := 10.8
## Наклон полотна прибавляет боковой тяжести SIDE_GRAVITY · s / √(1 + s²) (BikeRide._step_turn), учитывается до этого.
const BANK_MAX := BikeRide.BANK_SLOPE_MAX
## Качение и воздух на плотной земле (GameConfig.BIKE_ROLL, BIKE_DRAG), м/с² и 1/м.
const ROLL := GameConfig.BIKE_ROLL
const DRAG := GameConfig.BIKE_DRAG
## «Средний седок» в профиле скорости: педали до крейсерской на ровном, комфортное торможение (не полный тормоз 9).
## Крейсерская — между обычной (11) и с Shift (14,3): в заездах 31.10 Shift держали 40–76 % времени, медиана скорости
## отрыва на прыжках ~14 м/с (разбор Хайку). Уточнять по новым записям.
const CRUISE := 13.0
const PEDAL := GameConfig.BIKE_ACCEL
const BRAKE := 5.0
## Модель прыжка повторяет BikeRide: шаг сетки рельефа (м) и база колёс (оси впереди и позади середины, м).
const GRID_STEP := 1.0
const HUB := BikeRide.HUB
## Тело гасит гребень пампа: столько вертикальной скорости (BikeRide.PUMP_ABSORB_V), м/с, и хода (PUMP_REACH), м.
const ABSORB_V := BikeRide.PUMP_ABSORB_V
const ABSORB_REACH := BikeRide.PUMP_REACH
## Высоты камней и корней по уровню (от зелёной к чёрной), м.
const TECH_HEIGHTS := {T.ROCK_GARDEN: Vector2(0.08, 0.18), T.ROOTS: Vector2(0.06, 0.15), T.ROUGH: Vector2(0.05, 0.14), T.RUTS: Vector2(0.08, 0.22)}


## — Прыжок: точка на профиле элемента —

## Высота оси трассы над исходной землёй на расстоянии s от начала элемента, как её видит колесо: профиль элемента
## в узлах метровой сетки рельефа с линейной интерполяцией между ними (сетка скругляет кромки), плюс уклон grade
## (отрицательный — спуск).
static func profile_at(e: TrailElement, s: float, grade := 0.0) -> float:
	return _lerp_nodes(nodes(e), s) + grade * s

## Профиль элемента в узлах сетки от −NODE_LEAD м до length + NODE_TAIL м (кэш по размерам элемента).
const NODE_LEAD := 8
const NODE_TAIL := 20
static var _nodes := {}
static func nodes(e: TrailElement) -> PackedFloat32Array:
	var key := "%d|%.3f|%.3f|%.3f|%.3f|%d" % [e.profile, e.length, e.height, e.gap, e.skew, e.count]
	if _nodes.has(key): return _nodes[key]
	if _nodes.size() > 4000: _nodes.clear()
	var from := e.station - e.length * 0.5
	var out := PackedFloat32Array()
	var n := NODE_LEAD + int(ceilf(e.length)) + NODE_TAIL
	out.resize(n)
	for k in n: out[k] = e.displacement(from + (k - NODE_LEAD) * GRID_STEP, 0.0, 2.0)
	_nodes[key] = out
	return out

static func _lerp_nodes(n: PackedFloat32Array, s: float) -> float:
	var f := s / GRID_STEP + NODE_LEAD
	if f <= 0.0 or f >= n.size() - 1: return 0.0
	var k := int(f)
	return lerpf(n[k], n[k + 1], f - k)

## Опора рамы: среднее двух колёс на базе ±HUB (как BikeRide._contact).
static func contact_at(e: TrailElement, s: float, grade := 0.0) -> float:
	var n := nodes(e)
	return (_lerp_nodes(n, s + HUB) + _lerp_nodes(n, s - HUB)) * 0.5 + grade * s

## Кромка прыжка (м от начала элемента): где профиль поднимается к вершине перед первым спадом.
static func lip(e: TrailElement) -> float:
	match e.profile:
		T.GAP: return e.gap_lip()
		T.TABLETOP: return clampf(e.height / (TrailElement.LIP_MAX * e.length) * 2.0, 0.25, 0.35) * e.length
		T.DROP: return e.length * TrailElement.DROP_LIP
		T.ROLLER: return e.length * 0.5
	return e.length * 0.5

## Полёт с элемента при скорости v у начала элемента. Повторяет BikeRide: на земле рама идёт по опоре двух колёс,
## вертикальная скорость — уклон на базе колёс × скорость; отрыв, когда за LOOK секунд земля уйдёт из-под полёта
## глубже LIFT; в полёте — тяжесть до касания опоры. Возвращает takeoff, land (м от начала), air (с), apex (м над
## точкой отрыва), takeoff_speed, impact (удар по нормали к земле касания, м/с); flew = false — не оторвался.
static func fly(e: TrailElement, v: float, grade := 0.0) -> Dictionary:
	var dt := 1.0 / BikeRide.SUB_HZ
	var s := -4.0
	var y := contact_at(e, s, grade)
	var speed := v
	var end := e.length + 14.0
	var guard := 0
	while s < end:
		guard += 1
		if guard > 20000: break # защита: столько шагов — уже не прыжок (трасса длиннее 200 м)
		# вертикальная скорость рамы — подъём опоры, не больше уклона на базе колёс (BikeRide._step_height)
		var hub := (profile_at(e, s + HUB, grade) - profile_at(e, s - HUB, grade)) / (2.0 * HUB)
		var own := (contact_at(e, s + 0.05, grade) - contact_at(e, s - 0.05, grade)) / 0.1
		var slope := minf(own, maxf(0.0, hub)) if own > 0.0 else own
		var vy := slope * speed
		var lifted := false
		for look: float in BikeRide.LOOK:
			var up := y + vy * look - G * look * look * 0.5
			if up - contact_at(e, s + speed * look, grade) > BikeRide.LIFT:
				lifted = true
				break
		if lifted:
			var f := _flight(e, s, y, speed, vy, grade, dt)
			if f.flew or f.land >= end: return f
			# короткий отскок (меньше 0,12 с) — не полёт: дальше по земле с места касания
			s = f.land
			y = contact_at(e, s, grade)
			continue
		var a := -G * hub / sqrt(1.0 + hub * hub) - ROLL - DRAG * speed * speed
		speed += a * dt
		if speed < 0.5: return {flew = false, stalled = true, takeoff = s, land = s, air = 0.0, apex = 0.0, takeoff_speed = 0.0, impact = 0.0}
		s += speed * dt
		y = contact_at(e, s, grade)
	return {flew = false, stalled = false, takeoff = -1.0, land = -1.0, air = 0.0, apex = 0.0, takeoff_speed = speed, impact = 0.0}

static func _flight(e: TrailElement, s: float, y: float, speed: float, vy: float, grade: float, dt: float) -> Dictionary:
	var start := s
	var start_y := y
	var vx := speed / sqrt(1.0 + pow(vy / maxf(speed, 0.1), 2.0))
	var t := 0.0
	var apex := 0.0
	while t < 4.0:
		s += vx * dt
		y += (vy - G * dt * 0.5) * dt
		vy -= G * dt
		t += dt
		apex = maxf(apex, y - start_y)
		var ground := contact_at(e, s, grade)
		if y <= ground:
			var gs := (profile_at(e, s + HUB, grade) - profile_at(e, s - HUB, grade)) / (2.0 * HUB)
			var impact := absf(vy - gs * vx) / sqrt(1.0 + gs * gs)
			return {flew = t >= 0.12, stalled = false, takeoff = start, land = s, air = t, apex = apex, takeoff_speed = vx, impact = impact}
	return {flew = true, stalled = false, takeoff = start, land = s, air = t, apex = apex, takeoff_speed = vx, impact = 99.0}

## Зона приземления элемента (м от начала): from — первая безопасная точка, ideal — лучшая, to — последняя.
static func landing(e: TrailElement) -> Vector3:
	match e.profile:
		T.GAP:
			var knuckle := e.gap_lip() + e.gap
			return Vector3(knuckle, knuckle + 2.5, e.length - 1.0)
		T.TABLETOP: return Vector3(0.7 * e.length, 0.78 * e.length, e.length + 2.0)
		T.DROP:
			# дроп падает с кромки почти отвесно: на 9–17 м/с касание в 1–3 м за кромкой (стенд), далеко не улетает
			var edge := e.length * TrailElement.DROP_LIP + TrailElement.DROP_EDGE * 0.5
			return Vector3(edge, edge + 1.5, e.length + 4.0)
		T.ROLLER: return Vector3(e.length * 0.5, e.length * 0.8, e.length + 3.0)
	return Vector3(e.length * 0.5, e.length * 0.75, e.length)

## Скорость входа, при которой приземление приходится на `target` м от начала (бисекция; INF — не долетает и на 26 м/с,
## 0 — долетает и на 3 м/с или не взлетает вовсе на этой цели).
static func speed_for(e: TrailElement, target: float, grade := 0.0) -> float:
	var lo := 3.0
	var hi := 26.0
	var far := fly(e, hi, grade)
	if not far.flew or far.land < target: return INF
	var near := fly(e, lo, grade)
	if near.flew and near.land >= target: return 0.0
	for i in 9:
		var mid := (lo + hi) * 0.5
		var f := fly(e, mid, grade)
		if f.flew and f.land >= target: hi = mid
		else: lo = mid
	return (lo + hi) * 0.5


## — Окно готового элемента: то, что сравнивает разбор заезда —

## Ожидания по элементу e на трассе d (d — для техники и поворотов, может быть null). Ключи как у разбора заезда
## (TrailRideAnalysis): станции — абсолютные, м вдоль трассы; скорости — у начала элемента, м/с.
static var _windows := {}
static func window(e: TrailElement, d: TrailDefinition = null, grade := 0.0, level := 1) -> Dictionary:
	var from := e.station - e.length * 0.5
	var r := {}
	match e.profile:
		T.GAP, T.TABLETOP:
			# окно прыжка зависит только от размеров и уклона: кэш, станции прибавляются к началу элемента
			var key := "%d|%.3f|%.3f|%.3f|%.2f" % [e.profile, e.length, e.height, e.gap, grade]
			if not _windows.has(key):
				var z := landing(e)
				var own := {lip = lip(e), land_from = z.x, ideal_land = z.y, land_to = z.z}
				# идеал — бисекцией; края зоны — по наклону «место приземления от скорости» около идеала (почти прямая)
				var ideal := speed_for(e, z.y, grade)
				if is_finite(ideal) and ideal > 0.0:
					own.speed_ideal = snappedf(ideal, 0.1)
					var a := fly(e, ideal - 1.0, grade)
					var b := fly(e, ideal + 1.0, grade)
					var per: float = (float(b.land) - float(a.land)) / 2.0 if a.flew and b.flew else 0.0
					if per > 0.2:
						own.speed_lo = snappedf(ideal + (z.x - z.y) / per, 0.1)
						own.speed_hi = snappedf(ideal + (z.z - z.y) / per, 0.1)
				elif is_finite(ideal):
					own.speed_hi = 3.0 # долетает и шагом: зона приземления всегда позади
				if _windows.size() > 2000: _windows.clear()
				_windows[key] = own
			r = (_windows[key] as Dictionary).duplicate()
			for k in ["lip", "land_from", "ideal_land", "land_to"]: r[k] = snappedf(from + float(r[k]), 0.1)
		T.DROP, T.ROLLER:
			var z := landing(e)
			r = {lip = snappedf(from + lip(e), 0.1), land_from = snappedf(from + z.x, 0.1), ideal_land = snappedf(from + z.y, 0.1),
				land_to = snappedf(from + z.z, 0.1)}
			if e.profile == T.DROP:
				r.speed_lo = 5.0 # медленнее — заднее колесо цепляет кромку; выше предела нет
			else:
				# роллер перекатывают: до этой скорости колёса на земле, выше — подлёт с гребня
				r.roll_speed = snappedf(roller_lift_speed(e), 0.1)
		T.PUMP, T.WAVES, T.RIPPLES:
			r = {speed_hi = snappedf(pump_speed(e), 0.1)}
		T.ROCK_GARDEN, T.ROOTS, T.ROUGH, T.RUTS, T.SLALOM, T.NARROW, T.LOG:
			r = {speed_hi = snappedf(tech_speed(e, d, level), 0.1)}
		T.BERM, T.S_BERM, T.OFF_CAMBER:
			if d != null:
				var radius := tightest(d, from, from + e.length)
				if is_finite(radius): r = {radius = snappedf(radius, 0.1), speed_hi = snappedf(turn_speed(radius, bank_of(e, d)), 0.1)}
	return r


## — Роллер, памп, волны —

## Роллер (sin²) отрывает колёса выше этой скорости у гребня: v² · κ = G, κ = 2h(π/L)², м/с у начала элемента.
static func roller_lift_speed(e: TrailElement) -> float:
	var k := 2.0 * e.height * pow(PI / e.length, 2.0)
	var at_crest := sqrt(G / maxf(k, 0.0001))
	return sqrt(at_crest * at_crest + 2.0 * G * e.height)

## Памп и волны: самая высокая скорость, на которой седок держит колёса на земле, м/с. Гребень sin² высоты h с шагом λ
## требует вниз v²·2h(π/λ)²; тело гасит часть гребня (ход ABSORB_REACH) и вертикальной скорости — PUMP_HOLD подобран
## стендом (памп 4,8×0,30: отрыв с 12–13 м/с; 5,5×0,55: с 9–11; 7,0×0,55: с 11–13).
const PUMP_HOLD := 1.25
static func pump_speed(e: TrailElement) -> float:
	var crests := maxi(1, e.count)
	var step := e.length / crests if e.profile != T.RIPPLES else e.period
	var h := maxf(0.02, e.height - ABSORB_REACH * 0.5) if e.profile != T.RIPPLES else e.height
	return PUMP_HOLD * sqrt(G / (2.0 * h * pow(PI / step, 2.0)))

## Шаг гребней пампа под скорость v и высоту h: колёса держатся до v · PUMP_MARGIN (запас на разгон в пампе).
const PUMP_MARGIN := 1.15
const PUMP_STEP_MAX := 9.0
static func pump_step(v: float, h: float) -> float:
	var held := maxf(0.02, h - ABSORB_REACH * 0.5)
	return PI * v * PUMP_MARGIN / PUMP_HOLD * sqrt(2.0 * held / G)


## — Повороты —

## Скорость, на которой поворот радиуса radius проходится на доле lat предельной перегрузки, при наклоне полотна bank.
static func turn_speed(radius: float, bank := 0.0, lat := 0.8) -> float:
	var s := clampf(bank, -BANK_MAX, BANK_MAX)
	var a := LAT_MAX * lat + 10.0 * s / sqrt(1.0 + s * s)
	return sqrt(maxf(1.0, a) * radius)

## Наклон полотна на оси от виража e и наклона самой трассы (TrailShaping), м на м; знак — в сторону поворота.
static func bank_of(e: TrailElement, d: TrailDefinition) -> float:
	var own := 0.0
	if e.profile in [T.BERM, T.S_BERM, T.OFF_CAMBER]:
		var span := BikeRide.BANK_SPAN
		var hw := d.width * 0.5
		var hi := e.displacement(e.station, span * 0.5 * e.bank, hw)
		var low := e.displacement(e.station, -span * 0.5 * e.bank, hw)
		own = (hi - low) / span * (-1.0 if e.profile == T.OFF_CAMBER else 1.0)
		own = absf(own) * (-1.0 if e.profile == T.OFF_CAMBER else 1.0)
	var shape := d.shape()
	var route := minf(absf(d.curvature_at(e.station)) * shape.bank_gain, shape.bank_max) * d.auto_bank
	return own + route

## Самый тугой радиус оси на [from, to], м (INF — прямая).
static func tightest(d: TrailDefinition, from: float, to: float) -> float:
	var peak := 0.0
	var s := from
	while s <= to:
		peak = maxf(peak, absf(d.curvature_at(s)))
		s += 1.0
	return 1.0 / peak if peak > 0.005 else INF

## Высота виража, с которой поворот радиуса radius проходится на скорости v (на уровне level); 0 — хватает без виража,
## INF — не хватит и предельного наклона (нужно тормозить до turn_speed).
static func berm_height(v: float, radius: float, level: int, width := 4.0) -> float:
	var lat: float = LEVELS[level].lat
	var need := v * v / radius - LAT_MAX * lat
	if need <= 0.0: return 0.0
	# s / √(1+s²) = need / 10
	var q := need / 10.0
	if q >= BANK_MAX / sqrt(1.0 + BANK_MAX * BANK_MAX): return INF
	var s := q / sqrt(1.0 - q * q)
	# наклон у оси от высоты виража: производная _berm_side у середины ≈ 1.5 · 0.26^0.5 / 1.35 / полуширина
	var per_metre := 1.5 * sqrt(0.35 / 1.35) / 1.35 / (width * 0.5)
	return clampf(s / per_metre, 0.3, 1.2)


## — Техника —

## Скорость, на которую рассчитан технический участок, м/с. Камни и корни до TrailTechnical.BUMP_LIMIT на прямой
## физически проходимы на любой скорости (стенд: ни ударов, ни пробоев до 17 м/с; с 01.11 они сбивают колесо вбок
## и выбивают руль, линию нужно держать), поэтому предел прямой — стандарт уровня TECH_SPEED (скорость, на которой
## седок этого уровня успевает выбирать линию между камнями), а в повороте — сцепление на скользком камне
## (BikeRide.ROOT_GRIP). Слалом — по кривизне линии между воротами на том же сцеплении.
const TECH_SPEED := [7.0, 9.0, 11.5, 14.0]
static func tech_speed(e: TrailElement, d: TrailDefinition = null, level := 1) -> float:
	var limit: float = TECH_SPEED[clampi(level, 0, TECH_SPEED.size() - 1)]
	if d == null: return limit
	if e.profile == T.SLALOM:
		var count := clampi(mini(e.count, int(e.length / 6.0)), 2, 8)
		var spacing := e.length / count
		var weave := absf(TrailTechnical.line_at(d, e, 0.0, e.station - e.length * 0.5 + spacing * 0.5))
		# линия −w·cos(π·фаза): наибольшая кривизна w·(π/шаг)²
		var k := maxf(0.001, weave * pow(PI / spacing, 2.0))
		return minf(limit + 2.0, sqrt(LAT_MAX * 0.8 * BikeRide.ROOT_GRIP / k))
	# бревно на оси: на 12,6 м/с — через руль (заезд 01.11); объезд узкий, не все его берут
	if e.profile == T.LOG: limit = minf(limit, LOG_SPEED)
	var radius := tightest(d, e.station - e.length * 0.5, e.station + e.length * 0.5)
	if is_finite(radius): limit = minf(limit, sqrt(LAT_MAX * float(LEVELS[level].lat) * BikeRide.ROOT_GRIP * radius))
	return limit
const LOG_SPEED := 9.0

## Высота камней или корней под уровень (доля диапазона уровня), м.
static func tech_height(kind: int, level: int) -> float:
	var span: Vector2 = TECH_HEIGHTS.get(kind, Vector2(0.06, 0.15))
	return lerpf(span.x, span.y, float(LEVELS[level].tech))

## Сколько метров нужно, чтобы с v_from сбросить до v_to комфортным торможением.
static func brake_distance(v_from: float, v_to: float) -> float:
	return maxf(0.0, v_from * v_from - v_to * v_to) / (2.0 * BRAKE)


## — Стандарт элемента под скорость и уровень —

## Размеры элемента kind ("table", "gap", "roller", "drop", "pump", "tech", "berm") под скорость входа v и уровень level.
## Пусто — на этой скорости и уровне элемент не ставится (why_not). Ключи: profile, length, height, gap, count, radius,
## v, level, и окно (speed_lo / speed_hi / ideal).
static var _specs := {}
static func spec(kind: String, v: float, level: int, grade := 0.0) -> Dictionary:
	if not why_not(kind, v, level).is_empty(): return {}
	var key := "%s|%d|%.1f|%.2f" % [kind, level, v, grade]
	if not _specs.has(key):
		if _specs.size() > 2000: _specs.clear()
		_specs[key] = _spec(kind, v, level, grade)
	return (_specs[key] as Dictionary).duplicate()

static func _spec(kind: String, v: float, level: int, grade: float) -> Dictionary:
	var lv: Dictionary = LEVELS[level]
	var share: float = lv.height
	match kind:
		"table":
			# длина, при которой на скорости v приземление у начала спуска (идеал landing); не долетает и на самом
			# коротком — стол ниже (на малой скорости высокий стол съедает разгон на подъёме)
			var h := lerpf(HEIGHTS[T.TABLETOP].x, HEIGHTS[T.TABLETOP].y, share)
			while h >= TABLE_LOW:
				var length := _solve_length(T.TABLETOP, h, v, grade, 7.0, 36.0)
				if length > 0.0: return _with_window({kind = kind, profile = T.TABLETOP, length = length, height = snappedf(h, 0.05), v = v, level = level}, grade)
				h -= 0.2 # 01.11: было 0,1 — невозможный стол перебирал до 450 полётов (1,4 с на каждую скорость)
			return {}
		"gap":
			var h := lerpf(HEIGHTS[T.GAP].x, HEIGHTS[T.GAP].y, share)
			var gap := _solve_gap(h, v, grade)
			if gap < 0.0: return {}
			var probe := TrailElementLibrary.make(T.GAP, 0.0, 30.0, h)
			probe.gap = gap
			var length := ceilf(probe.gap_min_length() + 2.0)
			return _with_window({kind = kind, profile = T.GAP, length = length, height = h, gap = gap, v = v, level = level}, grade)
		"roller":
			# роллер перекатывается на скорости v (без отрыва) с запасом 10 %: длина по кривизне гребня
			var h := lerpf(HEIGHTS[T.ROLLER].x, HEIGHTS[T.ROLLER].y, share)
			var crest := sqrt(maxf(1.0, v * v * 1.21 - 2.0 * G * h))
			var length := clampf(ceilf(PI * crest * sqrt(2.0 * h / G)), 8.0, 26.0)
			return _with_window({kind = kind, profile = T.ROLLER, length = length, height = h, v = v, level = level}, grade)
		"drop":
			# высота — по удару: приземление на ровную землю бьёт по вертикали √(2·G·h)
			var h := minf(float(lv.drop), pow(float(lv.impact), 2.0) / (2.0 * G))
			var length := clampf(roundf(v * 1.1), 12.0, 20.0)
			return _with_window({kind = kind, profile = T.DROP, length = length, height = h, v = v, level = level}, grade)
		"pump":
			var h := lerpf(HEIGHTS[T.PUMP].x, HEIGHTS[T.PUMP].y, share)
			# шаг длиннее PUMP_STEP_MAX уже не памп, а пологие волны: на большой скорости гребень ниже
			while h > HEIGHTS[T.PUMP].x and pump_step(v, h) > PUMP_STEP_MAX: h -= 0.05
			var step := clampf(pump_step(v, h), 4.0, PUMP_STEP_MAX)
			var count := 4
			var e := TrailElementLibrary.make(T.PUMP, 0.0, step * count, h, 1.0, count)
			return {kind = kind, profile = T.PUMP, length = snappedf(step * count, 0.1), height = h, count = count, v = v, level = level, speed_hi = snappedf(pump_speed(e), 0.1)}
		"tech":
			# техника ставится там, где седок едет не быстрее стандарта уровня (иначе перед ней нужно место для торможения)
			if v > TECH_SPEED[level] + 0.5: return {}
			var h := tech_height(T.ROCK_GARDEN, level)
			return {kind = kind, profile = T.ROCK_GARDEN, length = 16.0, height = snappedf(h, 0.01), v = v, level = level, speed_hi = TECH_SPEED[level]}
		"berm":
			# радиус, который на скорости v проходится с виражом средней высоты 0,8 м на доле lat уровня
			var hw := 2.25
			var per_metre := 1.5 * sqrt(0.35 / 1.35) / 1.35 / hw
			var s := minf(0.8 * per_metre, BANK_MAX)
			var radius := ceilf(v * v / (LAT_MAX * float(lv.lat) + 10.0 * s / sqrt(1.0 + s * s)))
			return {kind = kind, profile = T.BERM, length = ceilf(PI * 0.5 * radius + 6.0), height = 0.8, radius = radius, v = v, level = level,
				speed_hi = snappedf(turn_speed(radius, s, float(lv.lat)), 0.1)}
	return {}

## Почему элемент kind не ставится на скорости v и уровне level (пусто — ставится).
static func why_not(kind: String, v: float, level: int) -> String:
	var lv: Dictionary = LEVELS[level]
	if kind == "gap" and not lv.gap: return "гэпы — только на красной и чёрной"
	if kind == "gap" and v < 10.0: return "гэп меньше 10 м/с не перелетают"
	if kind == "table" and v < 8.0: return "стол меньше 8 м/с не взлетает"
	if kind == "drop" and v < 5.0: return "дроп меньше 5 м/с — недолёт на кромку"
	if kind == "tech" and v > TECH_SPEED[level] + 0.5: return "техника уровня — до %.1f м/с: перед ней нужно %.0f м торможения" % [TECH_SPEED[level], brake_distance(v, TECH_SPEED[level])]
	return ""

## Элемент по стандарту, по центру на станции station.
static func element(s: Dictionary, station: float) -> TrailElement:
	var e := TrailElementLibrary.make(s.profile, station, s.length, s.height, 1.0, int(s.get("count", 3)))
	if s.has("gap"): e.gap = s.gap
	if s.profile == T.ROCK_GARDEN:
		e.density = 0.5
		e.lines = 2
		e.seed = 7
	return e

## Короткая строка размеров стандарта для отчёта.
static func text(s: Dictionary) -> String:
	var parts := ["%s %.0f×%.2f м" % [TrailElementLibrary.title(s.profile), s.length, s.height]]
	if s.has("gap"): parts.append("разрыв %.1f" % s.gap)
	if s.has("radius"): parts.append("R %.0f" % s.radius)
	if s.has("count"): parts.append("гребней %d" % s.count)
	if s.has("speed_lo") or s.has("speed_hi"): parts.append("окно %s–%s" % [str(s.get("speed_lo", "—")), str(s.get("speed_hi", "—"))])
	return ", ".join(parts)

static func _with_window(s: Dictionary, grade: float) -> Dictionary:
	var e := element(s, s.length * 0.5)
	var w := window(e, null, grade)
	for key in ["speed_lo", "speed_ideal", "speed_hi"]:
		if w.has(key): s[key] = w[key]
	return s

## Длина стола высоты h, при которой скорость v приземляет на идеал: длины перебираются через 1 м от lo, первая смена
## «перелёт → недолёт» уточняется бисекцией; −1 — такой длины нет (не взлетает или недолёт и на самом коротком).
static func _solve_length(kind: int, h: float, v: float, grade: float, lo: float, hi: float) -> float:
	var e := TrailElementLibrary.make(kind, 0.0, lo, h)
	var miss := func(length: float) -> float:
		e.length = length
		e.station = length * 0.5
		var f := fly(e, v, grade)
		return (f.land - landing(e).y) if f.flew else NAN
	var prev := NAN
	var at := lo
	var flew := 0
	while at <= hi:
		var m: float = miss.call(at)
		if not is_nan(m): flew += 1
		# за первые 6 м не взлетел ни разу, или первый же полёт — недолёт: длиннее не поможет
		if is_nan(m) and flew == 0 and at - lo >= 6.0: return -1.0
		if not is_nan(m) and m < 0.0 and is_nan(prev) and flew == 1: return -1.0
		if not is_nan(prev) and not is_nan(m) and prev >= 0.0 and m < 0.0:
			var a := at - 1.0
			var b := at
			for i in 12:
				var mid := (a + b) * 0.5
				var mm: float = miss.call(mid)
				if not is_nan(mm) and mm >= 0.0: a = mid
				else: b = mid
			return snappedf((a + b) * 0.5, 0.5)
		prev = m
		at += 1.0
	return -1.0

## Разрыв гэпа высоты h, при котором скорость v приземляет на идеал (за кромкой 2,5 м); −1 — нет такого в 1,5–6 м.
static func _solve_gap(h: float, v: float, grade: float) -> float:
	var e := TrailElementLibrary.make(T.GAP, 0.0, 30.0, h)
	var lo := 1.5
	var hi := 6.0
	var miss := func(gap: float) -> float:
		e.gap = gap
		e.length = ceilf(e.gap_min_length() + 2.0)
		e.station = e.length * 0.5
		var f := fly(e, v, grade)
		return (f.land - landing(e).y) if f.flew else -99.0
	if miss.call(lo) < 0.0: return -1.0
	if miss.call(hi) > 0.0: return hi
	for i in 16:
		var mid := (lo + hi) * 0.5
		if miss.call(mid) > 0.0: lo = mid
		else: hi = mid
	return snappedf((lo + hi) * 0.5, 0.1)


## — Профиль скорости трассы —

## Скорость «среднего седока» на каждом метре оси d (м/с), level — уровень (доля перегрузки в поворотах).
## ground(Vector2) -> float — природная земля; без неё трасса ровная. Вперёд: педали до CRUISE (на спуске накат без
## предела, кроме воздуха), подъём забирает скорость; назад: перед поворотами (turn_speed с наклоном трассы) и
## техникой седок тормозит с BRAKE. Элементы трассы (их высоты) не учитываются: это скорость, которую даёт линия.
static func speed_profile(d: TrailDefinition, ground := Callable(), level := 1, caps := {}) -> PackedFloat32Array:
	return profile_from(d, line_heights(d, ground), level, caps)

## Земля под осью на каждом метре, сглаженная по 5 м (формирование полотна срезает мелкие неровности).
static func line_heights(d: TrailDefinition, ground := Callable()) -> PackedFloat32Array:
	var n := int(d.route_length()) + 1
	var y := PackedFloat32Array()
	y.resize(n)
	for i in n: y[i] = float(ground.call(d.point_at(i))) if ground.is_valid() else 0.0
	var smooth := y.duplicate()
	for i in n: smooth[i] = (y[maxi(0, i - 2)] + y[maxi(0, i - 1)] + y[i] + y[mini(n - 1, i + 1)] + y[mini(n - 1, i + 2)]) / 5.0
	return smooth

## Профиль скорости по готовой высоте оси (line_heights); caps — {станция: предел скорости} (техника и т. п.).
## braking = false — «как едут» (01.11, заезды по генератору: тормоз 10 % времени, в поворотах — в 29–47 % проездов):
## без торможения заранее, поворот срезает скорость только в нём самом, после него — снова разгон.
static func profile_from(d: TrailDefinition, y: PackedFloat32Array, level := 1, caps := {}, braking := true) -> PackedFloat32Array:
	var n := y.size()
	var v := PackedFloat32Array()
	v.resize(n)
	var cap := PackedFloat32Array()
	cap.resize(n)
	var lv: Dictionary = LEVELS[clampi(level, 0, LEVELS.size() - 1)]
	var lat: float = lv.lat
	var shape := d.shape()
	for i in n:
		var k := absf(d.curvature_at(i))
		var bank := minf(k * shape.bank_gain, shape.bank_max) * d.auto_bank
		cap[i] = minf(turn_speed(1.0 / k, bank, lat) if k > 0.004 else 30.0, float(lv.top))
	for station: int in caps:
		var at := clampi(station, 0, n - 1)
		cap[at] = minf(cap[at], float(caps[station]))
	if n == 0: return v
	v[0] = 3.0
	for i in range(1, n):
		var grade := y[i] - y[i - 1]
		var u := v[i - 1]
		var a := -G * grade / sqrt(1.0 + grade * grade) - ROLL - DRAG * u * u
		if u < CRUISE: a += PEDAL * (1.0 - u / CRUISE)
		v[i] = minf(sqrt(maxf(1.0, u * u + 2.0 * a)), cap[i])
	if braking:
		for i in range(n - 2, -1, -1):
			v[i] = minf(v[i], sqrt(v[i + 1] * v[i + 1] + 2.0 * BRAKE))
	return v

## Уклон, под который считается элемент с началом на station: средний по земле на 20 м вперёд, через 0,02 (ключ кэша).
static func element_grade(d: TrailDefinition, ground: Callable, station: float) -> float:
	return clampf(snappedf(grade_of(d, ground, station, minf(station + 20.0, d.route_length())), 0.02), -0.2, 0.2)

## Средний уклон оси по земле на [from, to] (м на м, отрицательный — спуск).
static func grade_of(d: TrailDefinition, ground: Callable, from: float, to: float) -> float:
	if not ground.is_valid() or to - from < 1.0: return 0.0
	return (float(ground.call(d.point_at(to))) - float(ground.call(d.point_at(from)))) / (to - from)
