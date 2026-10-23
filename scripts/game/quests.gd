extends RefCounted
## 11.9: задания с досок поселений. Без движка: места приходят словарями (Hud.all_places, ключ key),
## прибытие проверяет тот, кто знает мир (arrived в tick), поэтому логику гоняет изолированная tools/quest_look.gd.
## Задание — список шагов, как журнал заданий в большинстве игр: шаг — место и что там сделать (STEPS).
## Активно одно задание: цель на компасе одна, и задания не спорят за неё. Виды (KINDS) собираются из шагов,
## новый вид — запись в KINDS и сборка в _make; новый шаг — запись в STEPS и событие, которое его закрывает.
## Задания предлагает доска: до трёх, по одному каждого вида, одни и те же, пока задание не выполнено.

signal changed  # взято, пройден шаг, выполнено или брошено: интерфейсу пора перерисоваться

## Виды заданий: подпись и значок для доски и счётчика
const KINDS := {
	visit = {title = "Посещение", icon = "◎"},
	delivery = {title = "Доставка", icon = "▣"},
	photo = {title = "Снимок", icon = "◫"},
}
## Шаги. reach — дойти до места; pickup — взять сумку у доски (E); carry — довезти сумку;
## shoot — снять место в видоискателе (в прицеле его название); bring — довезти снимок.
## goal — ставить ли место шага целью на компасе (у pickup сумка рядом, цель не нужна)
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
const NEAR := 25.0     # клеток (100 м): ближе — не задание, а пара шагов
const FAR := 500.0     # клеток (2 км): дальше места для посещения и снимка не предлагаются

var active := {}       # {id, kind, giver — id поселения, title, text, steps: [{do, place}], step}
var cargo := false     # сумка за спиной
var done := 0          # выполнено заданий
var last := ""         # название последнего выполненного
var _done := {}        # id выполненных: доска их больше не предлагает


## Задания доски поселения here (место с key). places — все места мира, neighbors — поселения по дорогам,
## far — дальнее поселение по сети или пусто, visited — посещённые id. Порядок и выбор устойчивы для мира и счёта done
func offers(here: Dictionary, places: Array, neighbors: Array, far: Dictionary, visited: Dictionary, seed_num: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%s|%d|%d" % [here.key, seed_num, done])
	var center := Vector2(here.x, here.y)
	var spots: Array = []  # места для посещения и снимка: не поселения, не рядом и не за горизонтом
	for p: Dictionary in places:
		var d := center.distance_to(Vector2(p.x, p.y))
		if p.kind != "settlement" and d > NEAR and d < FAR and (p.kind != "site" or p.src.get("rank", 0) >= 1):
			spots.append(p)
	spots.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return center.distance_squared_to(Vector2(a.x, a.y)) < center.distance_squared_to(Vector2(b.x, b.y)))
	var towns := neighbors.duplicate()
	if not far.is_empty() and not towns.any(func(t: Dictionary) -> bool: return t.key == far.key):
		towns.append(far)
	var out: Array = []
	# доставка: в соседнее по дороге поселение, иногда — в дальнее
	var to := _pick(towns.filter(func(t: Dictionary) -> bool: return not _done.has(_id("delivery", here, t))), rng)
	if not to.is_empty():
		out.append(_make("delivery", here, to, here))
	# снимок: одно из ближних мест, отвезти в соседнее поселение или обратно сюда
	var used := {}
	var shot := _pick(spots.slice(0, 6).filter(func(p: Dictionary) -> bool: return not _done.has(_id("photo", here, p))), rng)
	if not shot.is_empty():
		used[shot.key] = true
		var bring: Dictionary = here if neighbors.is_empty() or rng.randf() < 0.5 else _nearest(neighbors, shot)
		out.append(_make("photo", here, shot, bring))
	# посещение: место, где игрок ещё не был, сначала ближние
	var fresh := spots.filter(func(p: Dictionary) -> bool: return not used.has(p.key) and not visited.has(p.key) and not _done.has(_id("visit", here, p)))
	var walk := _pick(fresh.slice(0, 5), rng)
	if not walk.is_empty():
		out.append(_make("visit", here, walk, here))
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


## Задание вида kind от поселения here: target — главное место, back — куда вернуться (у снимка)
static func _make(kind: String, here: Dictionary, target: Dictionary, back: Dictionary) -> Dictionary:
	var q := {id = _id(kind, here, target), kind = kind, giver = here.key, target = target, step = 0}
	match kind:
		"delivery":
			q.title = "Посылка: «%s»" % target.name
			q.text = "Отвезите сумку с письмами и припасами. С сумкой за спиной быстрое перемещение недоступно."
			q.steps = [{do = "pickup", place = here}, {do = "carry", place = target}]
		"photo":
			q.title = "Снимок: «%s»" % target.name
			q.text = "Сфотографируйте место — его название должно появиться в видоискателе — и привезите снимок %s." % (
				"сюда" if back.key == here.key else "в поселение «%s»" % back.name)
			q.steps = [{do = "shoot", place = target}, {do = "bring", place = back}]
		_:
			q.title = "Дорога: «%s»" % target.name
			q.text = "Доберитесь до места и посмотрите, что там."
			q.steps = [{do = "reach", place = target}]
	return q


## Взять задание q (из offers). Прошлое активное бросается
func accept(q: Dictionary) -> void:
	active = q.duplicate(true)
	active.step = 0
	cargo = false
	changed.emit()


func abandon() -> void:
	active = {}
	cargo = false
	changed.emit()


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


## Сумку у доски взяли (E)
func pick_up() -> String:
	if step().get("do") != "pickup":
		return ""
	cargo = true
	return _advance()


## Снимок сделан, в прицеле было место place_id (PhotoCamera.photo_taken)
func photographed(place_id: String) -> String:
	var s := step()
	if s.get("do") != "shoot" or s.place.key != place_id:
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
	active = {}
	changed.emit()
	return "Задание выполнено: %s" % last
