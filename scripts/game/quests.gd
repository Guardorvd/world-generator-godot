extends RefCounted
## 11.9: задания с досок поселений. Без движка: места приходят словарями (Hud.all_places, ключ key),
## прибытие проверяет тот, кто знает мир (arrived в tick), поэтому логику гоняет изолированная tools/quest_look.gd.
## Задание — список шагов, как журнал заданий в большинстве игр: шаг — место и что там сделать (STEPS).
## Активно одно задание: метка задания одна, и задания не спорят за цель компаса. Виды (KINDS) собираются из шагов,
## новый вид — запись в KINDS и сборка в _make; новый шаг — запись в STEPS и событие, которое его закрывает.
## Задания предлагает доска: до трёх (доставка, снимок, посещение или обход), одни и те же, пока задание не выполнено.
## 11.9+: снимок засчитывается не дальше SHOT_REACH от места, места для заданий — не ближе SPOT_MIN к поселению
## (иначе снимок «с порога» закрывал задание, не выходя из деревни), обход двух мест, счёт по поселениям.
## 12.3: формулировки по виду места и с вариантами (выбор по id задания — устойчив), два новых вида из тех же
## шагов: «Хрупкий груз» (доставка; падение с велосипеда разбивает груз — за новым к доске, crashed())
## и «Летопись» (снять два места и привезти снимки). Доска по-прежнему предлагает до трёх заданий.

signal changed  # взято, пройден шаг, выполнено или брошено: интерфейсу пора перерисоваться

## Виды заданий: подпись и цвет для доски, счётчика и меток; значок — UiIcons.QUESTS (с 12.5 векторный)
const KINDS := {
	visit = {title = "Посещение", color = Color(0.55, 0.85, 1.0)},
	tour = {title = "Обход", color = Color(0.55, 0.85, 1.0)},
	delivery = {title = "Доставка", color = Color(1.0, 0.7, 0.4)},
	photo = {title = "Снимок", color = Color(0.75, 0.95, 0.6)},
	fragile = {title = "Хрупкий груз", color = Color(1.0, 0.55, 0.45)},
	chronicle = {title = "Летопись", color = Color(0.6, 0.9, 0.75)},
}
## Виды с сумкой за спиной (доставка): быстрое перемещение недоступно, сумка у доски
const CARGO_KINDS := ["delivery", "fragile"]
## Шаги. reach — дойти до места; pickup — взять сумку у доски (E); carry — довезти сумку;
## shoot — снять место в видоискателе (в прицеле его название); bring — довезти снимок.
## goal — ставить ли место шага целью на компасе (у pickup сумка рядом, хватает метки задания)
const STEPS := {
	reach = {text = "Доберитесь до %s «%s»", case = "gen", goal = true},
	pickup = {text = "Наденьте сумку у доски %s «%s» (E)", case = "gen", goal = false},
	carry = {text = "Довезите сумку в %s «%s»", case = "acc", goal = true},
	shoot = {text = "Сфотографируйте %s «%s» (ПКМ)", case = "acc", goal = true},
	bring = {text = "Отвезите снимок в %s «%s»", case = "acc", goal = true},
}
## Вид места в нужном падеже: название в кавычках остаётся как есть
const CASES := {
	gen = {settlement = "поселения", peak = "вершины", lake = "озера", site = "места"},
	acc = {settlement = "поселение", peak = "вершину", lake = "озеро", site = "место"},
}
const SPOT_MIN := 60.0   # клеток (240 м): ближе к поселению место не задание — его видно и снимешь с порога
const FAR := 500.0       # клеток (2 км): дальше места для посещения и снимка не предлагаются
const SHOT_REACH := 400.0 # м: снимок для задания — не дальше этого от места
const TOUR_CHANCE := 0.4 # доля досок, где вместо посещения — обход двух мест
const FRAGILE_CHANCE := 0.35   # доля досок, где вместо доставки — хрупкий груз
const CHRONICLE_CHANCE := 0.35 # доля досок, где вместо снимка — летопись двух мест

## Формулировки: %s — название цели (в кавычках, без склонения — поэтому через двоеточие). Выбор варианта — по хешу id задания (одно и то же на каждой доске).
const DELIVERY_TITLES := ["Посылка: «%s»", "Письма: «%s»", "Инструменты: «%s»", "Соль и мука: «%s»"]
const DELIVERY_TEXTS := [
	"Отвезите сумку с письмами и припасами. Дорога надёжнее троп: на ней меньше брёвен и камней.",
	"Там ждут инструменты из нашей кузни. Сумка тяжёлая, но падение ей не страшно — главное, довезите.",
	"Обменяемся припасами с соседями. Сумку берите у доски — и в путь по дороге.",
]
const FRAGILE_TITLES := ["Склянки: «%s»", "Яйца: «%s»", "Стекло: «%s»"]
const FRAGILE_TEXTS := [
	"Бьётся от любого падения: объезжайте брёвна и валуны, на камнях и в ямах сбавляйте ход, не прыгайте с обрывов. Разобьёте — придётся вернуться за новым.",
	"Аккуратно: в лесу на тропах лежат ветки и брёвна, на разбитой грунтовке — ямы и колеи. Упадёте — груз пропал, новый ждёт у доски.",
]
const VISIT_TITLES := {
	peak = ["Подъём: «%s»", "Вершина «%s»"],
	lake = ["К озеру «%s»", "Озеро «%s»"],
	site = ["Разведка: «%s»", "Что у места «%s»?"],
}
const VISIT_TEXTS := {
	peak = ["Наверх ведут тропы: крутой подъём легче взять стоя на педалях, а камни на горной тропе — объехать.",
		"Говорят, оттуда видно полмира. Тропа к вершине каменистая — не торопитесь на спуске."],
	lake = ["Доберитесь до воды. Броды через ручьи мелкие, а вот в глубокую воду на велосипеде не въехать.",
		"Рыбаки давно не были на том берегу. Посмотрите, проходима ли туда дорога."],
	site = ["Странники рассказывают об этом месте. Проверьте, правда ли там что-то есть.",
		"Место отмечено на старой карте. Доберитесь и посмотрите своими глазами."],
}
const PHOTO_TEXTS := [
	"Нужен снимок для летописи. Подойдите ближе %s — в видоискателе место узнаётся сразу — снимите и привезите %s.",
	"Художник просит вид на это место. Снимите его не дальше %s и привезите снимок %s.",
]
var active := {}       # {id, kind, giver — id поселения, title, text, steps: [{do, place}], step}
var cargo := false     # сумка за спиной
var done := 0          # выполнено заданий
var last := ""         # название последнего выполненного
var by_giver := {}     # id поселения -> выполнено его заданий
var known := {}        # id мест взятых заданий: как посещённые, их названия видны в мире, на карте и в видоискателе
var _done := {}        # id выполненных: доска их больше не предлагает


## Задания доски поселения here (место с key). places — все места мира, neighbors — поселения по дорогам,
## far — дальнее поселение по сети или пусто, visited — посещённые id. Порядок и выбор устойчивы для мира и счёта done
func offers(here: Dictionary, places: Array, neighbors: Array, far: Dictionary, visited: Dictionary, seed_num: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%s|%d|%d" % [here.key, seed_num, done])
	var center := Vector2(here.x, here.y)
	var spots: Array = []  # места для посещения и снимка: не поселения, не у порога и не за горизонтом
	for p: Dictionary in places:
		var d := center.distance_to(Vector2(p.x, p.y))
		if p.kind != "settlement" and d > SPOT_MIN and d < FAR and (p.kind != "site" or p.src.get("rank", 0) >= 1):
			spots.append(p)
	spots.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return center.distance_squared_to(Vector2(a.x, a.y)) < center.distance_squared_to(Vector2(b.x, b.y)))
	var towns := neighbors.duplicate()
	if not far.is_empty() and not towns.any(func(t: Dictionary) -> bool: return t.key == far.key):
		towns.append(far)
	var out: Array = []
	# доставка: в соседнее по дороге поселение, иногда — в дальнее; иногда хрупкий груз
	var carry_kind := "fragile" if rng.randf() < FRAGILE_CHANCE else "delivery"
	var to := _pick(towns.filter(func(t: Dictionary) -> bool: return not _done.has(_id(carry_kind, here, t))), rng)
	if not to.is_empty():
		out.append(_make(carry_kind, here, [to]))
	# снимок: одно из ближних мест, отвезти в соседнее поселение или обратно сюда;
	# иногда летопись — два соседних места и обратно сюда
	var used := {}
	var shot_kind := "chronicle" if rng.randf() < CHRONICLE_CHANCE else "photo"
	var shot := _pick(spots.slice(0, 6).filter(func(p: Dictionary) -> bool: return not _done.has(_id(shot_kind, here, p))), rng)
	if not shot.is_empty():
		used[shot.key] = true
		var pair := _nearest(spots.slice(0, 8).filter(func(p: Dictionary) -> bool: return p.key != shot.key), shot) if shot_kind == "chronicle" else {}
		if not pair.is_empty() and Vector2(shot.x, shot.y).distance_to(Vector2(pair.x, pair.y)) < FAR * 0.5:
			used[pair.key] = true
			out.append(_make("chronicle", here, [shot, pair, here]))
		else:
			var bring: Dictionary = here if neighbors.is_empty() or rng.randf() < 0.5 else _nearest(neighbors, shot)
			out.append(_make("photo", here, [shot, bring]))
	# посещение: место, где игрок ещё не был, сначала ближние; иногда обход двух соседних мест
	var fresh := spots.filter(func(p: Dictionary) -> bool: return not used.has(p.key) and not visited.has(p.key))
	var walk := _pick(fresh.slice(0, 5).filter(func(p: Dictionary) -> bool: return not _done.has(_id("visit", here, p)) and not _done.has(_id("tour", here, p))), rng)
	if not walk.is_empty():
		var second := _nearest(fresh.filter(func(p: Dictionary) -> bool: return p.key != walk.key), walk)
		if not second.is_empty() and rng.randf() < TOUR_CHANCE and Vector2(walk.x, walk.y).distance_to(Vector2(second.x, second.y)) < FAR * 0.6:
			out.append(_make("tour", here, [walk, second]))
		else:
			out.append(_make("visit", here, [walk]))
	return out


static func _id(kind: String, here: Dictionary, target: Dictionary) -> String:
	return "%s:%s>%s" % [kind, here.key, target.key]


static func _pick(list: Array, rng: RandomNumberGenerator) -> Dictionary:
	return {} if list.is_empty() else list[rng.randi() % list.size()]


static func _nearest(list: Array, to: Dictionary) -> Dictionary:
	var best := {}
	var best_d := INF
	for p: Dictionary in list:
		var d := Vector2(p.x, p.y).distance_squared_to(Vector2(to.x, to.y))
		if d < best_d:
			best = p
			best_d = d
	return best


## Вариант формулировки из списка: устойчив для задания (по хешу id и соли)
static func _variant(list: Array, id: String, salt := 0) -> String:
	return list[absi(hash(id) + salt * 7919) % list.size()]


## Задание вида kind от поселения here: at[0] — главное место, дальше — следующие (куда отвезти снимок, второе место
## обхода и летописи, куда вернуться)
static func _make(kind: String, here: Dictionary, at: Array) -> Dictionary:
	var target: Dictionary = at[0]
	var id := _id(kind, here, target)
	var q := {id = id, kind = kind, giver = here.key, target = target, step = 0}
	var known_text := " Названия мест задания видны на карте и над ними."
	match kind:
		"delivery":
			q.title = _variant(DELIVERY_TITLES, id) % target.name
			q.text = _variant(DELIVERY_TEXTS, id, 1) + " С сумкой за спиной быстрое перемещение недоступно."
			q.steps = [{do = "pickup", place = here}, {do = "carry", place = target}]
		"fragile":
			q.title = _variant(FRAGILE_TITLES, id) % target.name
			q.text = _variant(FRAGILE_TEXTS, id, 1) + " Быстрое перемещение с грузом недоступно."
			q.steps = [{do = "pickup", place = here}, {do = "carry", place = target}]
		"photo":
			var back: Dictionary = at[1]
			q.title = "Снимок: «%s»" % target.name
			q.text = _variant(PHOTO_TEXTS, id, 1) % ["%d м" % int(SHOT_REACH), "сюда" if back.key == here.key else "в поселение «%s»" % back.name]
			q.steps = [{do = "shoot", place = target}, {do = "bring", place = back}]
		"chronicle":
			var second: Dictionary = at[1]
			var back: Dictionary = at[2]
			q.title = "Летопись: «%s» и «%s»" % [target.name, second.name]
			q.text = "Летописцу нужны два снимка: сначала «%s», потом «%s» — каждое не дальше %s. Снимки привезите %s.%s" % [
				target.name, second.name, "%d м" % int(SHOT_REACH), "сюда" if back.key == here.key else "в «%s»" % back.name, known_text]
			q.steps = [{do = "shoot", place = target}, {do = "shoot", place = second}, {do = "bring", place = back}]
		"tour":
			q.title = "Обход: «%s» и «%s»" % [target.name, at[1].name]
			q.text = "Побывайте в двух местах по очереди: путь между ними — по тропам и напрямик, как удобнее.%s" % known_text
			q.steps = [{do = "reach", place = target}, {do = "reach", place = at[1]}]
		_:
			var titles: Array = VISIT_TITLES.get(target.kind, ["Дорога: «%s»"])
			q.title = _variant(titles, id) % target.name
			q.text = "Вы там ещё не были. " + _variant(VISIT_TEXTS.get(target.kind, VISIT_TEXTS.site), id, 1) + known_text
			q.steps = [{do = "reach", place = target}]
	return q


## Взять задание q (из offers). Прошлое активное бросается
func accept(q: Dictionary) -> void:
	active = q.duplicate(true)
	active.step = 0
	cargo = false
	# взятое задание называет свои места: их не надо «открывать» заново, название узнаётся сразу
	for s: Dictionary in active.steps:
		known[s.place.key] = true
	changed.emit()


func abandon() -> void:
	active = {}
	cargo = false
	changed.emit()


## Седок упал с велосипеда. Хрупкий груз разбит: задание возвращается к шагу «взять у доски».
## Возвращает сообщение или пусто
func crashed() -> String:
	if active.get("kind") != "fragile" or not cargo:
		return ""
	cargo = false
	active.step = 0
	changed.emit()
	return "Груз разбился. Новый — у доски поселения «%s»" % active.steps[0].place.name


## Текущий шаг активного задания или пусто
func step() -> Dictionary:
	return {} if active.is_empty() else active.steps[active.step]


func step_text(s: Dictionary = step()) -> String:
	if s.is_empty():
		return ""
	var step_def: Dictionary = STEPS[s.do]
	return step_def.text % [CASES[step_def.case].get(s.place.kind, "места"), s.place.name]


## Место, которое надо держать целью на компасе, или пусто
func goal() -> Dictionary:
	var s := step()
	return s.place if not s.is_empty() and STEPS[s.do].goal else {}


## Место текущего шага (метка задания на компасе и картах) или пусто
func marker() -> Dictionary:
	return step().get("place", {})


## Сумку у доски взяли (E)
func pick_up() -> String:
	if step().get("do") != "pickup":
		return ""
	cargo = true
	return _advance()


## Нужен ли для задания снимок места place_id
func wants_photo(place_id: String) -> bool:
	var s := step()
	return s.get("do") == "shoot" and s.place.key == place_id


## Снимок сделан, в прицеле было место place_id, до него distance м (PhotoCamera.photo_taken)
func photographed(place_id: String, distance := 0.0) -> String:
	if not wants_photo(place_id) or distance > SHOT_REACH:
		return ""
	return _advance()


## Такт игры: arrived(place) -> bool — игрок у места. Возвращает сообщение, если шаг пройден
func tick(arrived: Callable) -> String:
	var s := step()
	if s.is_empty() or s.do not in ["reach", "carry", "bring"] or not arrived.call(s.place):
		return ""
	if s.do == "carry":
		cargo = false
	return _advance()


func _advance() -> String:
	active.step += 1
	if active.step < active.steps.size():
		changed.emit()
		return step_text()
	last = active.title
	_done[active.id] = true
	done += 1
	by_giver[active.giver] = by_giver.get(active.giver, 0) + 1
	active = {}
	changed.emit()
	return "Задание выполнено: %s" % last


## Только адреса мест: src и данные мира берутся из текущего мира.
func save_state() -> Dictionary:
	var q := active.duplicate(true)
	if not q.is_empty():
		q.target = q.target.key
		for s: Dictionary in q.steps:
			s.place = s.place.key
	return {active = q, cargo = cargo, done = done, last = last,
		by_giver = by_giver.duplicate(), known = known.duplicate(), completed = _done.duplicate()}


static func valid_save(d: Dictionary) -> bool:
	for key: String in ["active", "by_giver", "known", "completed"]:
		if not d.get(key) is Dictionary:
			return false
	if not d.get("cargo") is bool or not d.get("done") is int or d.done < 0 or not d.get("last") is String:
		return false
	for key: Variant in d.by_giver:
		if not key is String or not d.by_giver[key] is int or d.by_giver[key] < 0:
			return false
	for dict: Dictionary in [d.known, d.completed]:
		for key: Variant in dict:
			if not key is String or dict[key] != true:
				return false
	var q: Dictionary = d.active
	if q.is_empty():
		return not d.cargo
	for key: String in ["id", "kind", "giver", "target", "title", "text"]:
		if not q.get(key) is String:
			return false
	if not KINDS.has(q.kind) or not q.get("steps") is Array or not q.get("step") is int:
		return false
	if q.steps.is_empty() or q.step < 0 or q.step >= q.steps.size():
		return false
	for s: Variant in q.steps:
		if not s is Dictionary or not STEPS.has(s.get("do", "")) or not s.get("place") is String:
			return false
	return d.cargo == (q.kind in CARGO_KINDS and q.steps[q.step].do == "carry")


func restore_state(d: Dictionary, places: Dictionary) -> bool:
	if not valid_save(d):
		return false
	var q: Dictionary = d.active.duplicate(true)
	if not q.is_empty():
		if not places.has(q.giver) or not places.has(q.target):
			return false
		q.target = places[q.target]
		for s: Dictionary in q.steps:
			if not places.has(s.place):
				return false
			s.place = places[s.place]
	active = q
	cargo = d.cargo
	done = d.done
	last = d.last
	by_giver = d.by_giver.duplicate()
	known = d.known.duplicate()
	_done = d.completed.duplicate()
	return true
