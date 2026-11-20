extends RefCounted
## 11.9: задания с досок поселений. Без движка: места приходят словарями (Hud.all_places, ключ key),
## прибытие проверяет тот, кто знает мир (arrived в tick), поэтому логику гоняет изолированная tools/quest_look.gd.
## Задание — список шагов, как журнал заданий в большинстве игр: шаг — место и что там сделать (STEPS).
## Активно одно задание: метка задания одна, и задания не спорят за цель компаса. Виды (KINDS) собираются из шагов,
## новый вид — запись в KINDS и сборка в _make; новый шаг — запись в STEPS и событие, которое его закрывает.
## Задания предлагает доска: до трёх (доставка, снимок, посещение или обход), одни и те же, пока задание не выполнено.
## 11.9+: снимок засчитывается не дальше SHOT_REACH_M от места, места для заданий — не ближе SPOT_MIN_CELLS к поселению
## (иначе снимок «с порога» закрывал задание, не выходя из деревни), обход двух мест, счёт по поселениям.
## 12.3: формулировки по виду места и с вариантами (выбор по id задания — устойчив), два новых вида из тех же
## шагов: «Хрупкий груз» (доставка; падение с велосипеда разбивает груз — за новым к доске, crashed())
## и «Летопись» (снять два места и привезти снимки). Доска по-прежнему предлагает до трёх заданий.

signal changed  # взято, пройден шаг, выполнено или брошено: интерфейсу пора перерисоваться
var reward_for := Callable()
var completion_note := Callable()

func reward_points(id: String) -> int:
	return int(reward_for.call(id)) if reward_for.is_valid() else 0


func _reward_note(ids: Array) -> String:
	return str(completion_note.call(ids)) if completion_note.is_valid() else ""

const BeaconSites = preload("res://scripts/game/beacon_sites.gd")
const PaintTargets = preload("res://scripts/game/paint_targets.gd")
const FIELD_STEPS := {"beacons": "install", "paint": "paint"}
const FIELD_COUNTS := {"beacons": BeaconSites.COUNT, "paint": PaintTargets.COUNT}
const FIELD_PLACES := ["beacon", "paint"]
## Виды заданий: подпись и цвет для доски, счётчика и меток; значок — UiIcons.QUESTS (с 12.5 векторный)
const KINDS := {
	visit = {title = "Посещение", color = Color(0.55, 0.85, 1.0)},
	tour = {title = "Обход", color = Color(0.72, 0.65, 1.0)},
	delivery = {title = "Доставка", color = Color(1.0, 0.7, 0.4)},
	photo = {title = "Снимок", color = Color(0.75, 0.95, 0.6)},
	fragile = {title = "Хрупкий груз", color = Color(1.0, 0.55, 0.45)},
	chronicle = {title = "Летопись", color = Color(0.6, 0.9, 0.75)},
	supplies = {title = "Припасы", color = Color(0.92, 0.8, 0.38)},
	repair = {title = "Ремонт", color = Color(0.6, 0.78, 1.0)},
	obelisks = {title = "Летопись обелисков", color = Color(0.6, 0.9, 0.75)},
	beacons = {title = "Связь", color = Color(0.45, 0.88, 0.83)},
	paint = {title = "Разметка", color = Color(1.0, 0.79, 0.34)},
}
## Что предлагает доска (18.11.2026). Остальные виды (посещение, обход, снимок, летопись и прежняя доставка в поселение)
## отключены, но их сборка и шаги остаются: взятое в старом сохранении задание грузится, выполняется и бросается как раньше.
## Вернуть вид на доску — добавить его сюда (снимок, летопись, посещение и обход включаются вместе).
const OFFERED := ["supplies", "fragile", "repair", "obelisks", "beacons", "paint"]
const SIGHT_KINDS := ["photo", "chronicle", "visit", "tour"]
## 19.11.2026: на доске не больше трёх листков. Отбор — board_pick: разные виды, взятое с этой доски остаётся
const BOARD_OFFERS := 3
## Виды с сумкой за спиной (доставка): быстрое перемещение недоступно, сумка у доски
const CARGO_KINDS := ["delivery", "fragile", "supplies", "beacons", "paint"]
## Шаги. reach — дойти до места; pickup — взять сумку у доски (E); carry — довезти сумку;
## shoot — снять место в видоискателе (в прицеле его название); bring — довезти снимок.
## goal — ставить ли место шага целью на компасе (у pickup сумка рядом, хватает метки задания)
const STEPS := {
	reach = {text = "Доберитесь до %s «%s»", case = "gen", goal = true},
	pickup = {text = "Наденьте сумку у доски %s «%s»", case = "gen", goal = false},
	carry = {text = "Довезите сумку в %s «%s»", case = "acc", goal = true},
	climb = {text = "Поднимитесь с сумкой на верхнюю площадку %s «%s»: велосипед оставьте внизу", case = "gen", goal = true},
	shoot = {text = "Сфотографируйте %s «%s»", case = "acc", goal = true},
	bring = {text = "Отвезите снимок в %s «%s»", case = "acc", goal = true},
	plaque = {text = "Сфотографируйте вблизи табличку: %s «%s»", case = "acc", goal = true},
	fix = {text = "Почините %s «%s»: подойдите и удерживайте клавишу взаимодействия", case = "acc", goal = true},
	install = {text = "Установите маяк связи · %d из %d", goal = true},
	paint = {text = "Отметьте краской %s · %d из %d", goal = true},
}
## Вид места в нужном падеже: название в кавычках остаётся как есть
const CASES := {
	gen = {settlement = "поселения", peak = "вершины", lake = "озера", site = "места"},
	acc = {settlement = "поселение", peak = "вершину", lake = "озеро", site = "место"},
}
## Виды места в нужном падеже для мест, куда возят припасы (вместо общего «места»)
const SITE_WORDS := {
	tower = {gen = "вышки", acc = "вышку"},
	house = {gen = "дома", acc = "дом"},
	farm = {gen = "хутора", acc = "хутор"},
	obelisk = {gen = "обелиска", acc = "обелиск"},
}
const SUPPLY_GROUPS := [["tower"], ["house", "farm"]]  # одно задание на группу: вышка и одинокий дом или хутор
const SUPPLY_TITLES := {
	tower = ["Дозорным: «%s»", "Масло для фонаря: «%s»", "Провиант: «%s»"],
	house = ["Припасы: «%s»", "Соль и спички: «%s»", "Крупа и свечи: «%s»"],
	farm = ["Припасы: «%s»", "Мука и керосин: «%s»", "Зерно и гвозди: «%s»"],
}
const SUPPLY_TEXTS := {
	tower = ["Дозорные просидели на вышке всю неделю. Отвезите им еду и масло, а сумку занесите наверх по лестнице: велосипед оставьте у подножия.",
		"На вышке кончилось масло для фонаря. Доберитесь, оставьте велосипед внизу и поднимитесь с сумкой на верхнюю площадку.",
		"Дозорный ждёт провиант. Лестница длинная — несколько пролётов, зато сверху видно далеко."],
	house = ["В одиноком доме на отшибе ждут соль, спички и крупу. Сумку берите у доски — и по дороге к дому.",
		"Хозяин редко выбирается в деревню. Привезите ему всё нужное прямо к порогу."],
	farm = ["Хутор далеко от лавки: там ждут муку, керосин и гвозди. Сумку берите у доски — и по дороге к хутору.",
		"К хутору дорога идёт полями. Привезите припасы к дому, пока не стемнело."],
}
## Ремонт (Repairables): задание берут у доски, ехать к сломанному объекту и чинить его удержанием «взаимодействия»
const REPAIR_TITLES := {
	bench = ["Починить лавку: «%s»", "Лавка на обрыве: «%s»"],
	cairn = ["Сложить тур: «%s»", "Тур на вершине: «%s»"],
	pier = ["Залатать причал: «%s»", "Причал у воды: «%s»"],
}
const REPAIR_TEXTS := {
	bench = ["На смотровой лавке выпала доска и подломилась ножка. Подъедьте и приведите её в порядок.",
		"Туристы жалуются: на лавке с видом не присесть. Подъедьте и поставьте её на ножки."],
	cairn = ["Ветер или чьи-то шаги развалили тур на вершине, веха сломана. Подъедьте к вершине и сложите всё заново.",
		"Тур на вершине осыпался: путники не видят знака. Верните камни на место."],
	pier = ["У рыбацкого причала выпали доски, свая завалилась. Починим — рыбаки снова смогут грузить лодку.",
		"Причал на озере совсем обветшал. Подъедьте к воде и залатайте настил."],
}
const SPOT_MIN_CELLS := 60.0  # клеток (240 м): ближе к поселению место не задание — его видно и снимешь с порога
const FAR_CELLS := 500.0       # клеток (2 км): дальше места для посещения и снимка не предлагаются
const PLAQUE_REACH_M := 4.5   # м: табличку обелиска снимают не дальше этого (PhotoCamera.plaque_near); 18.11.2026
const SHOT_REACH_M := 150.0 # м: снимок для задания — не дальше этого от места (до 18.11.2026 — 400 м: с ×4 снимали с соседнего холма)
const TOUR_CHANCE := 0.4 # доля досок, где вместо посещения — обход двух мест
const CARGO_CRASH_LOSS := 55  # 20.11: падение отнимает у хрупкого груза столько процентов (два падения — разбит)
const FRAGILE_CHANCE := 0.35   # доля досок, где вместо доставки — хрупкий груз
## 18.11.2026: задания ведут в разные стороны и постепенно дальше. travel = {explored: клетки EXPLORED_CELL м, где проходил
## трек (MapJournal.explored_cells), from: точка трека в 300 м до доски — откуда игрок приехал (MapJournal.came_from)}.
## Цена цели (_direction_cost): отклонение от желаемой дальности (растёт с числом выполненных: IDEAL_M + DONE_STEP_M · done),
## назад по своим следам, по уже изъезженному, в ту же сторону, что другое задание этой доски. Из двух лучших — по жребию.
const EXPLORED_CELL := 128.0
const IDEAL_M := 350.0
const DONE_STEP_M := 120.0
const IDEAL_MAX_M := 1600.0
const BACK_ANGLE := 0.96   # рад (55°): в этом секторе от направления, откуда приехали, — «назад»
const CHRONICLE_CHANCE := 0.35 # доля досок, где вместо снимка — летопись двух мест

## Формулировки: %s — название цели (в кавычках, без склонения — поэтому через двоеточие). Выбор варианта — по хешу id задания (одно и то же на каждой доске).
const DELIVERY_TITLES := ["Посылка: «%s»", "Письма: «%s»", "Инструменты: «%s»", "Соль и мука: «%s»"]
const DELIVERY_TEXTS := [
	"Отвезите сумку с письмами и припасами. Дорога надёжнее троп: на ней меньше брёвен и камней.",
	"Там ждут инструменты из нашей кузни. Сумка тяжёлая, но падение ей не страшно — главное, довезите.",
	"Обменяемся припасами с соседями. Сумку берите у доски — и в путь по дороге.",
]
## 16.11.2026: доставка в поселение с ролью (SettlementRoles) — путешествие; ROLE_CHANCE — доля досок, где цель такая
const ROLE_CHANCE := 0.5
const ROLE_DELIVERY_TEXTS := {
	remote = ["До них одна дальняя дорога, и бываем мы там редко. Отвезите припасы — по пути не раз сменится местность.",
		"Дальнее поселение ждёт почту с осени. Путь неблизкий: рассчитайте силы."],
	forest = ["Деревня в глубине леса: последняя часть пути — лесом, где на тропе ветки и корни.",
		"Отвезите инструменты лесным соседям. Под кронами темнее — не торопитесь на корнях."],
	foothill = ["Деревня у самых гор: в конце пути подъём, его легче взять стоя на педалях.",
		"Отвезите соль и муку к подножию гор. Обратная дорога — под горку, отдохнёте."],
}
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
var active := QuestData.new()       # {id, kind, giver — id поселения, title, text, steps: [{do, place}], step}
var cargo := false     # сумка за спиной
var cargo_hp := 100    # 20.11: целостность хрупкого груза, %: жёсткие удары отнимают часть, падение — больше; 0 — разбит
var done := 0          # выполнено заданий
var last := ""         # название последнего выполненного
var by_giver := {}     # id поселения -> выполнено его заданий
var known := {}        # id мест взятых заданий: как посещённые, их названия видны в мире, на карте и в видоискателе
var _done := {}        # id выполненных: доска их больше не предлагает
var installed_beacons := {} # координатные ключи маяков завершённых заданий
var painted_objects := {} # адреса объектов, на которые уже нанесена краска
## «Летопись обелисков» — серия, а не обычное задание: идёт параллельно с активным (доставка, ремонт), снимки табличек всех
## обелисков в любом порядке. steps — по одному шагу plaque на обелиск, снятые стоят первыми (step — сколько снято)
var series := QuestData.new()
var series_done := false   # серия выполнена: доска её больше не предлагает
## 18.11.2026: починено по пути, без задания с доски. Ремонт засчитан сразу, а ближайшее поселение ждёт игрока
## с благодарностью: приехал туда — выполненное задание в счёт поселения (thank). id объекта -> {village — id
## поселения, name — его название, what — что починено, «лавка «…»»}
var thanks := {}


## Задания доски поселения here (место с key). places — все места мира, neighbors — поселения по дорогам,
## far — дальнее поселение по сети или пусто, visited — посещённые id. Порядок и выбор устойчивы для мира и счёта done
func offers(here: Dictionary, places: Array, neighbors: Array, far: Dictionary, visited: Dictionary, seed_num: int,
		broken := Callable(), beacon_route := Callable(), paint_route := Callable(), travel := {}) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%s|%d|%d" % [here.key, seed_num, done])
	var center := Vector2(here.x, here.y)
	var spots: Array = []  # места для посещения и снимка: не поселения, не у порога и не за горизонтом
	for p: Dictionary in places:
		var d := center.distance_to(Vector2(p.x, p.y))
		if p.kind != "settlement" and d > SPOT_MIN_CELLS and d < FAR_CELLS and (p.kind != "site" or EntityCodec.value(p.src, "rank", 0) >= 1):
			spots.append(p)
	spots.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return center.distance_squared_to(Vector2(a.x, a.y)) < center.distance_squared_to(Vector2(b.x, b.y)))
	var towns := neighbors.duplicate()
	if not far.is_empty() and not towns.any(func(t: Dictionary) -> bool: return t.key == far.key):
		towns.append(far)
	var out: Array = []
	var aims: Array[Vector2] = []  # направления уже предложенных заданий этой доски, м
	if _offers_field("beacons", here.key, beacon_route):
		var cells: Array[Vector2i] = beacon_route.call()
		if cells.size() == BeaconSites.COUNT:
			var targets: Array[Dictionary] = []
			for i in cells.size():
				targets.append(BeaconSites.place(cells[i], i + 1))
			out.append(_make("beacons", here, targets))
	if _offers_field("paint", here.key, paint_route):
		var targets: Array[Dictionary] = paint_route.call()
		if targets.size() == PaintTargets.COUNT:
			out.append(_make("paint", here, targets))
	# припасы: на вышку (сумку надо занести наверх по лестнице) и в одинокий дом или на хутор; ближние места первыми
	if "supplies" in OFFERED:
		for group: Array in SUPPLY_GROUPS:
			var sites := spots.filter(func(p: Dictionary) -> bool: return p.kind == "site" and _site_type(p) in group and not _done.has(_id("supplies", here, p)))
			var supply := _pick_toward(sites, rng, center, travel, aims)
			if not supply.is_empty():
				out.append(_make("supplies", here, [supply]))
	# доставка в поселение: хрупкий груз (падение разбивает его); прежняя «Доставка» — только если её вернули на доску
	var carry_kind := ""
	if "fragile" in OFFERED and ("delivery" not in OFFERED or rng.randf() < FRAGILE_CHANCE):
		carry_kind = "fragile"
	elif "delivery" in OFFERED:
		carry_kind = "delivery"
	if carry_kind != "":
		var open := towns.filter(func(t: Dictionary) -> bool: return not _done.has(_id(carry_kind, here, t)))
		# 16.11.2026: доставка чаще ведёт в дальнее, лесное или предгорное поселение (SettlementRoles) — путешествие,
		# а не соседняя улица; где таких по дорогам нет, выбор прежний.
		var trips := open.filter(func(t: Dictionary) -> bool: return ROLE_DELIVERY_TEXTS.has(_role(t)))
		var to := _pick_toward(trips if not trips.is_empty() and rng.randf() < ROLE_CHANCE else open, rng, center, travel, aims)
		if not to.is_empty():
			out.append(_make(carry_kind, here, [to]))
	# ремонт: ближайшие сломанные лавка, тур или причал (broken(id) — Repairables.is_broken), не выполненные раньше
	if "repair" in OFFERED and broken.is_valid():
		var wrecks := spots.filter(func(p: Dictionary) -> bool: return Repairables.kind_of(p) != "" and broken.call(p.key) and not _done.has(_id("repair", here, p)))
		var fix := _pick_toward(wrecks, rng, center, travel, aims)
		if not fix.is_empty():
			out.append(_make("repair", here, [fix]))
	# летопись обелисков: одна на мир, пока не взята и не выполнена; все обелиски мира, ближние к доске первыми
	if "obelisks" in OFFERED and not series_done and series.is_empty():
		var obelisks := places.filter(func(p: Dictionary) -> bool: return p.kind == "site" and _site_type(p) == "obelisk")
		obelisks.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return center.distance_squared_to(Vector2(a.x, a.y)) < center.distance_squared_to(Vector2(b.x, b.y)))
		if not obelisks.is_empty():
			out.append(_make("obelisks", here, obelisks))
	if not SIGHT_KINDS.any(func(k: String) -> bool: return k in OFFERED):
		return out
	# снимок: одно из ближних мест, отвезти в соседнее поселение или обратно сюда;
	# иногда летопись — два соседних места и обратно сюда
	var used := {}
	var shot_kind := "chronicle" if rng.randf() < CHRONICLE_CHANCE else "photo"
	var shot := _pick(spots.slice(0, 6).filter(func(p: Dictionary) -> bool: return not _done.has(_id(shot_kind, here, p))), rng)
	if not shot.is_empty():
		used[shot.key] = true
		var pair := _nearest(spots.slice(0, 8).filter(func(p: Dictionary) -> bool: return p.key != shot.key), shot) if shot_kind == "chronicle" else {}
		if not pair.is_empty() and Vector2(shot.x, shot.y).distance_to(Vector2(pair.x, pair.y)) < FAR_CELLS * 0.5:
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
		if not second.is_empty() and rng.randf() < TOUR_CHANCE and Vector2(walk.x, walk.y).distance_to(Vector2(second.x, second.y)) < FAR_CELLS * 0.6:
			out.append(_make("tour", here, [walk, second]))
		else:
			out.append(_make("visit", here, [walk]))
	return out


## Вид места-сооружения (SiteData.type: tower, house, farm…) или ""
static func _site_type(place: Dictionary) -> String:
	var src: Variant = place.get("src")
	return "" if src == null or place.get("kind") != "site" else str(EntityCodec.value(src, "type", ""))


## Вид места в падеже: для вышки, дома и хутора — своё слово, для остальных общее (CASES)
static func _word(case: String, place: Dictionary, do := "") -> String:
	if do == "fix": # «лавку», «тур», «причал» — по объекту места, а не по виду места
		return Repairables.KINDS.get(Repairables.kind_of(place), {}).get(case, "объект")
	return SITE_WORDS.get(_site_type(place), {}).get(case, CASES[case].get(place.kind, "места"))


## Роль поселения-цели (SettlementData.role) или "" — у мест и старых миров её нет
static func _role(place: Dictionary) -> String:
	var src: Variant = place.get("src")
	return "" if src == null else str(EntityCodec.value(src, "role", ""))


static func _id(kind: String, here: Dictionary, target: Dictionary) -> String:
	return "%s:%s>%s" % [kind, here.key, target.key]


## Три листка доски из предложений offers (порядок offers сохраняется). Взятое задание (active_id) остаётся,
## остальные — разных видов в порядке, устойчивом для доски giver и счёта done (другая доска — другой набор,
## после выполненного задания набор меняется). Виды повторяются, только если разных меньше трёх
static func board_pick(offers: Array, giver: String, done_count: int, active_id := "") -> Array:
	if offers.size() <= BOARD_OFFERS:
		return offers
	var order := range(offers.size())
	order.sort_custom(func(a: int, b: int) -> bool:
		var qa: QuestData = offers[a]
		var qb: QuestData = offers[b]
		if (qa.id == active_id) != (qb.id == active_id):
			return qa.id == active_id
		return hash("%s|%d|%s" % [giver, done_count, qa.id]) < hash("%s|%d|%s" % [giver, done_count, qb.id]))
	var chosen: Array[int] = []
	var kinds := {}
	for pass_i in 2:
		for i: int in order:
			if chosen.size() >= BOARD_OFFERS:
				break
			var q: QuestData = offers[i]
			if i in chosen or (pass_i == 0 and kinds.has(q.kind)):
				continue
			chosen.append(i)
			kinds[q.kind] = true
	chosen.sort()
	var out: Array = []
	for i: int in chosen:
		out.append(offers[i])
	return out


func _offers_field(kind: String, giver: String, route: Callable) -> bool:
	var id := _field_id(kind, giver)
	return kind in OFFERED and route.is_valid() and active.id != id and not _done.has(id)


static func _field_id(kind: String, giver: String) -> String:
	return "%s:%s" % [kind, giver]


## Цена цели target (клетки) от доски center (клетки): меньше — лучше. with_distance = false — только направление
## (маяки и метки краской: дальность у них задана своими пределами)
func _direction_cost(center: Vector2, target: Vector2, travel: Dictionary, used: Array, with_distance := true) -> float:
	var to := (target - center) * GameConfig.TILE
	var d := to.length()
	var cost := 0.0
	if with_distance:
		var ideal := minf(IDEAL_M + DONE_STEP_M * done, IDEAL_MAX_M)
		cost += absf(d - ideal) / ideal * 0.8
	if d < 1.0:
		return cost
	var from: Variant = travel.get("from", Vector2.INF)
	if from is Vector2 and from.is_finite():
		var back: Vector2 = from - center * GameConfig.TILE
		if back.length() > 1.0 and absf(to.angle_to(back)) < BACK_ANGLE:
			cost += 1.0
	var explored: Dictionary = travel.get("explored", {})
	if explored.has(Vector2i((target * GameConfig.TILE / EXPLORED_CELL).floor())):
		cost += 0.6
	for dir: Vector2 in used:
		if absf(to.angle_to(dir)) < 0.8:
			cost += 0.4
	return cost


## Цель из list по цене направления: из двух лучших — по жребию; её направление пополняет used
func _pick_toward(list: Array, rng: RandomNumberGenerator, center: Vector2, travel: Dictionary, used: Array[Vector2]) -> Dictionary:
	if list.is_empty():
		return {}
	var scored: Array = []
	for p: Dictionary in list:
		scored.append([_direction_cost(center, Vector2(p.x, p.y), travel, used), p])
	scored.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0] or (a[0] == b[0] and str(a[1].key) < str(b[1].key)))
	var pick: Dictionary = scored[rng.randi() % mini(2, scored.size())][1]
	used.append((Vector2(pick.x, pick.y) - center) * GameConfig.TILE)
	return pick


## Для маяков и меток краской (BeaconSites.route, PaintTargets.route): цена точки в клетках — только направление
func prefer(here: Dictionary, travel: Dictionary) -> Callable:
	var center := Vector2(here.x, here.y)
	return func(cell: Vector2) -> float: return _direction_cost(center, cell, travel, [], false)


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
static func _make(kind: String, here: Dictionary, at: Array) -> QuestData:
	var target: Dictionary = at[0]
	var id := _id(kind, here, target)
	var q := QuestData.new(id, kind, here.key, target)
	var known_text := " Названия мест задания видны на карте и над ними."
	match kind:
		"delivery":
			q.title = _variant(DELIVERY_TITLES, id) % target.name
			q.text = _variant(ROLE_DELIVERY_TEXTS.get(_role(target), DELIVERY_TEXTS), id, 1) + " С сумкой за спиной быстрое перемещение недоступно."
			q.steps = [{do = "pickup", place = here}, {do = "carry", place = target}]
		"supplies":
			var type := _site_type(target)
			if not SUPPLY_TITLES.has(type):
				type = "house"
			q.title = _variant(SUPPLY_TITLES[type], id) % target.name
			q.text = _variant(SUPPLY_TEXTS[type], id, 1) + " С сумкой за спиной быстрое перемещение недоступно."
			# на вышку сумку заносят наверх (шаг climb: игрок на верхней площадке), к дому и хутору — довозят (carry: у места)
			q.steps = [{do = "pickup", place = here}, {do = "climb" if type == "tower" else "carry", place = target}]
		"obelisks":
			q.id = "obelisks:series"
			q.title = "Летопись обелисков"
			q.text = "Летописцу нужны таблички всех обелисков в округе: %d. Снимайте каждую вблизи, лицом к ней, в любом порядке — задание идёт параллельно с другими.%s" % [at.size(), known_text]
			q.steps = []
			for p: Dictionary in at:
				q.steps.append({do = "plaque", place = p})
		"repair":
			var object := Repairables.kind_of(target)
			q.title = _variant(REPAIR_TITLES[object], id) % target.name
			q.text = _variant(REPAIR_TEXTS[object], id, 1) + " Удерживайте клавишу взаимодействия у объекта, пока он не будет починен."
			q.steps = [{do = "fix", place = target}]
		"fragile":
			q.title = _variant(FRAGILE_TITLES, id) % target.name
			q.text = _variant(FRAGILE_TEXTS, id, 1) + " Быстрое перемещение с грузом недоступно."
			q.steps = [{do = "pickup", place = here}, {do = "carry", place = target}]
		"beacons", "paint":
			q.id = _field_id(kind, here.key)
			if kind == "beacons":
				q.title = "Три маяка связи"
				q.text = "Возьмите сумку у доски. У каждой отметки сойдите с велосипеда и установите маяк. После установки откроется следующая точка."
			else:
				q.title = "Метки у дороги"
				q.text = "Возьмите сумку с краской. Спешьтесь, наведитесь на подсвеченное дерево или камень и нанесите метку."
			q.steps = [{do = "pickup", place = here}]
			for i in at.size():
				q.steps.append({do = FIELD_STEPS[kind], place = at[i], number = i + 1})
		"photo":
			var back: Dictionary = at[1]
			q.title = "Снимок: «%s»" % target.name
			q.text = _variant(PHOTO_TEXTS, id, 1) % ["%d м" % int(SHOT_REACH_M), "сюда" if back.key == here.key else "в поселение «%s»" % back.name]
			q.steps = [{do = "shoot", place = target}, {do = "bring", place = back}]
		"chronicle":
			var second: Dictionary = at[1]
			var back: Dictionary = at[2]
			q.title = "Летопись: «%s» и «%s»" % [target.name, second.name]
			q.text = "Летописцу нужны два снимка: сначала «%s», потом «%s» — каждое не дальше %s. Снимки привезите %s.%s" % [
				target.name, second.name, "%d м" % int(SHOT_REACH_M), "сюда" if back.key == here.key else "в «%s»" % back.name, known_text]
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


## 18.11.2026: основное задание новой игры — доехать до поселения target (ближайшего к старту); вид «Посещение»
static func start(target: Dictionary) -> QuestData:
	var q := QuestData.new("start:%s" % target.key, "visit", target.key, target)
	q.title = "Дорога в «%s»" % target.name
	q.text = "Доберитесь до поселения «%s»: у костра — доска заданий и указатели дорог. Путь к нему на земле и на мини-карте." % target.name
	q.steps = [{do = "reach", place = target}]
	return q


## Взять задание q (из offers). Прошлое активное бросается
func accept(q: QuestData) -> void:
	if q.kind == "obelisks":
		# серия не вытесняет активное задание и не берёт сумку
		series = q.duplicate(true)
		series.step = 0
		for s: Dictionary in series.steps:
			known[s.place.key] = true
		changed.emit()
		return
	active = q.duplicate(true)
	active.step = 0
	cargo = false
	# взятое задание называет свои места: их не надо «открывать» заново, название узнаётся сразу
	for s: Dictionary in active.steps:
		if s.place.kind not in FIELD_PLACES:
			known[s.place.key] = true
	changed.emit()


func abandon() -> void:
	active = QuestData.new()
	cargo = false
	changed.emit()


## Седок упал с велосипеда. С 20.11 хрупкий груз теряет CARGO_CRASH_LOSS целостности (damage_cargo); разбит —
## задание возвращается к шагу «взять у доски». Возвращает сообщение о разбитом грузе или пусто
func crashed() -> String:
	var hit := damage_cargo(CARGO_CRASH_LOSS)
	return str(hit.text) if hit.get("broken", false) else ""


## 20.11: удар по хрупкому грузу (loss — сколько процентов целостности он отнимает). Пусто — груза нет или он не хрупкий;
## иначе {hp, broken, text}: при 0 % груз разбит и задание возвращается к доске, как прежде при падении
func damage_cargo(loss: int) -> Dictionary:
	if active.kind != "fragile" or not cargo or loss <= 0:
		return {}
	cargo_hp = maxi(0, cargo_hp - loss)
	if cargo_hp > 0:
		# шаг задания не меняется: changed не шлём — он пересобирает цель, маршрут и слои мира (рывок на кочке)
		return {hp = cargo_hp, broken = false, text = "Груз звякнул: цел на %d %%" % cargo_hp}
	cargo = false
	cargo_hp = 100
	active.step = 0
	changed.emit()
	return {hp = 0, broken = true, text = "Груз разбился. Новый — у доски поселения «%s»" % active.steps[0].place.name}


## Текущий шаг активного задания или пусто
func step() -> Dictionary:
	return {} if active.is_empty() else active.steps[active.step]


func step_text(s: Dictionary = step()) -> String:
	if s.is_empty():
		return ""
	var step_def: Dictionary = STEPS[s.do]
	if s.do == "install":
		return step_def.text % [s.number, BeaconSites.COUNT]
	if s.do == "paint":
		return step_def.text % [s.place.name.to_lower(), s.number, PaintTargets.COUNT]
	return step_def.text % [_word(step_def.case, s.place, s.do), s.place.name]


## Место, которое надо держать целью на компасе, или пусто
func goal() -> Dictionary:
	var s := step()
	return s.place if not s.is_empty() and STEPS[s.do].goal else {}


## Место текущего шага (метка задания на компасе и картах) или пусто
func marker() -> Dictionary:
	return step().get("place", {})


## Снимок сделан, табличка обелиска place_id в кадре вблизи (PhotoCamera.shot.plaque), distance — м до неё. Возвращает сообщение или пусто
func plaque_photographed(place_id: String, distance := 0.0) -> String:
	if series.is_empty() or distance > PLAQUE_REACH_M:
		return ""
	var i := series.step
	while i < series.steps.size() and series.steps[i].place.key != place_id:
		i += 1
	if i >= series.steps.size():
		return ""
	var taken: Dictionary = series.steps[i]
	series.steps.remove_at(i)
	series.steps.insert(series.step, taken)
	series.step += 1
	if series.step >= series.steps.size():
		var completed_id := series.id
		last = series.title
		_done[series.id] = true
		series_done = true
		done += 1
		series = QuestData.new()
		changed.emit()
		return "Летопись обелисков завершена: все таблички сняты" + _reward_note([completed_id])
	changed.emit()
	return "Табличка снята: «%s» · %d из %d" % [taken.place.name, series.step, series.steps.size()]


## Сколько табличек снято и сколько всего: Vector2i(0, 0), если серия не идёт
func series_progress() -> Vector2i:
	return Vector2i(series.step, series.steps.size()) if not series.is_empty() else Vector2i.ZERO


## Подсказка у таблички place_id в окне чтения: нужна ли она летописи и снята ли уже
func series_note(place_id: String) -> String:
	if series.is_empty():
		return ""
	for i in series.steps.size():
		if series.steps[i].place.key == place_id:
			return "Эта табличка уже снята для летописи." if i < series.step else "Для летописи: сфотографируйте эту табличку вблизи."
	return ""


## Объект place_id починен (удержание у сломанного, GameWorld). Возвращает сообщение или пусто
func repaired(place_id: String) -> String:
	var s := step()
	if s.get("do") != "fix" or s.place.key != place_id:
		return ""
	return _advance()


## Починено по пути (не шаг активного задания): place — починенное место, village — поселение, где отблагодарят
## (InteractionService.target). Возвращает уведомление
func repaired_on_way(place: Dictionary, village: Dictionary) -> String:
	var what := "%s «%s»" % [Repairables.KINDS.get(Repairables.kind_of(place), {}).get("title", "объект"), place.name]
	if village.is_empty():
		return "Починено: %s" % what
	thanks[place.key] = {village = village.key, name = village.name, what = what}
	changed.emit()
	return "Починено: %s. Загляните в поселение «%s» — там отблагодарят" % [what, village.name]


## Игрок у поселения: arrived(village_id) -> bool. Благодарности этого поселения засчитываются как выполненные
## задания «Ремонт». Возвращает сообщение или пусто
func thank(arrived: Callable) -> String:
	var texts := PackedStringArray()
	var completed_ids: Array[String] = []
	for id: String in thanks.keys():
		var entry: Dictionary = thanks[id]
		if not arrived.call(entry.village):
			continue
		thanks.erase(id)
		var completed_id := "repair:%s>%s" % [entry.village, id]
		_done[completed_id] = true
		completed_ids.append(completed_id)
		done += 1
		by_giver[entry.village] = by_giver.get(entry.village, 0) + 1
		last = "Ремонт: %s" % entry.what
		texts.append("Поселение «%s» благодарит за ремонт: %s" % [entry.name, entry.what])
	if texts.is_empty():
		return ""
	changed.emit()
	return "\n".join(texts) + _reward_note(completed_ids)


## Поселения, где ждут благодарность: строки для счётчика задания
func thanks_lines() -> PackedStringArray:
	var by_village := {}
	for entry: Dictionary in thanks.values():
		by_village[entry.name] = by_village.get(entry.name, 0) + 1
	var out := PackedStringArray()
	for village: String in by_village:
		out.append("Загляните в «%s»: благодарность за ремонт%s" % [village, "" if by_village[village] == 1 else " ×%d" % by_village[village]])
	return out


## Сумку у доски взяли (E)
func pick_up() -> String:
	if step().get("do") != "pickup":
		return ""
	cargo = true
	cargo_hp = 100
	return _advance()


## Установка только в текущей точке; близость проверяет GameWorld.
func install_beacon(place_id: String) -> String:
	var s := step()
	if not cargo or s.get("do") != "install" or s.place.key != place_id:
		return ""
	if active.step == BeaconSites.COUNT:
		for i in range(1, active.steps.size()):
			installed_beacons[active.steps[i].place.key] = true
	return _advance()


func beacons_in_world() -> Dictionary:
	var result := installed_beacons.duplicate()
	if active.kind == "beacons":
		for i in range(1, active.step):
			result[active.steps[i].place.key] = true
	return result


func paint_object(place_id: String) -> String:
	var s := step()
	if not cargo or s.get("do") != "paint" or s.place.key != place_id or painted_objects.has(place_id):
		return ""
	painted_objects[place_id] = true
	return _advance()


## Нужен ли для задания снимок места place_id
func wants_photo(place_id: String) -> bool:
	var s := step()
	return s.get("do") == "shoot" and s.place.key == place_id


## Снимок сделан, в прицеле было место place_id, до него distance м (PhotoCamera.photo_taken)
func photographed(place_id: String, distance := 0.0) -> String:
	if not wants_photo(place_id) or distance > SHOT_REACH_M:
		return ""
	return _advance()


## Такт игры: arrived(place) -> bool — игрок у места. Возвращает сообщение, если шаг пройден
func tick(arrived: Callable) -> String:
	var s := step()
	if s.is_empty() or s.do not in ["reach", "carry", "climb", "bring"] or not arrived.call(s.place):
		return ""
	if s.do in ["carry", "climb"]:
		cargo = false
	return _advance()


func _advance() -> String:
	active.step += 1
	if active.step < active.steps.size():
		changed.emit()
		return step_text()
	last = active.title
	var completed_id := active.id
	_done[active.id] = true
	done += 1
	by_giver[active.giver] = by_giver.get(active.giver, 0) + 1
	active = QuestData.new()
	cargo = false
	changed.emit()
	return "Задание выполнено\n" + last + _reward_note([completed_id])


## Только адреса мест: src и данные мира берутся из текущего мира.
func save_state() -> Dictionary:
	return {active = _addresses(active), cargo = cargo, cargo_hp = cargo_hp, done = done, last = last,
		by_giver = by_giver.duplicate(), known = known.duplicate(), completed = _done.duplicate(),
		series = _addresses(series), series_done = series_done, beacons = installed_beacons.duplicate(),
		painted = painted_objects.duplicate(), thanks = thanks.duplicate(true)}


static func _addresses(quest: QuestData) -> Dictionary:
	var q := quest.to_dict()
	if not q.is_empty():
		q.target = q.target.key
		for s: Dictionary in q.steps:
			if s.do == "paint":
				s.approach = s.place.approach
			s.place = s.place.key
	return q


## Запись задания (active или series) в сохранении: строки, шаги из STEPS, адреса мест
static func _valid_quest(q: Dictionary) -> bool:
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
		if s.do in FIELD_STEPS.values() and s.do != FIELD_STEPS.get(q.kind):
			return false
	if q.kind in FIELD_STEPS:
		if q.id != _field_id(q.kind, q.giver) or q.steps.size() != FIELD_COUNTS[q.kind] + 1 \
				or q.steps[0].do != "pickup" or q.steps[0].place != q.giver or q.steps[1].place != q.target:
			return false
		var seen := {}
		for i in range(1, q.steps.size()):
			var s: Dictionary = q.steps[i]
			if s.do != FIELD_STEPS[q.kind] or s.get("number") != i or s.place in seen:
				return false
			if s.do == "install" and BeaconSites.cell_of(s.place) == BeaconSites.NO_CELL:
				return false
			if s.do == "paint":
				if PaintTargets.address(s.place).is_empty() or not s.get("approach") is Vector2 or not s.approach.is_finite():
					return false
			seen[s.place] = true
	return true


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
	# серия летописи — необязательное поле: старые сохранения без неё читаются
	if d.has("series") and (not d.series is Dictionary or (not d.series.is_empty() and not _valid_quest(d.series))):
		return false
	if d.has("series_done") and not d.series_done is bool:
		return false
	var beacons: Variant = d.get("beacons", {})
	if not beacons is Dictionary:
		return false
	for id: Variant in beacons:
		if not id is String or BeaconSites.cell_of(id) == BeaconSites.NO_CELL or beacons[id] != true:
			return false
	var painted: Variant = d.get("painted", {})
	if not painted is Dictionary:
		return false
	for id: Variant in painted:
		if not id is String or PaintTargets.address(id).is_empty() or painted[id] != true:
			return false
	# благодарности за ремонт по пути — необязательное поле (с 18.11.2026)
	var thanked: Variant = d.get("thanks", {})
	if not thanked is Dictionary:
		return false
	for id: Variant in thanked:
		var entry: Variant = thanked[id]
		if not id is String or not entry is Dictionary:
			return false
		for key: String in ["village", "name", "what"]:
			if not entry.get(key) is String:
				return false
	var q: Dictionary = d.active
	if q.is_empty():
		return not d.cargo
	if not _valid_quest(q):
		return false
	if q.kind == "paint":
		for i in range(1, q.steps.size()):
			if painted.has(q.steps[i].place) != (i < q.step):
				return false
	return d.cargo == (q.kind in CARGO_KINDS and q.steps[q.step].do in ["carry", "climb", "install", "paint"])


func restore_state(d: Dictionary, places: Dictionary, plan := Rect2i(), world: WorldData = null) -> bool:
	if not valid_save(d):
		return false
	var q := _resolve(d.active, places, world)
	if q == null:
		# При изменении растительности снимается только задание, потерявшее цель.
		if d.active.get("kind") != "paint" or world == null:
			return false
		q = QuestData.new()
	var beacons: Dictionary = d.get("beacons", {})
	if plan.has_area():
		for id: String in beacons:
			if not plan.has_point(BeaconSites.cell_of(id)):
				return false
		if q.kind == "beacons":
			for s: Dictionary in q.steps:
				if s.do == "install" and not plan.has_point(BeaconSites.cell_of(s.place.key)):
					return false
	active = q
	cargo = d.cargo and not q.is_empty()
	var hp: Variant = d.get("cargo_hp", 100) # 20.11: в прежних сохранениях целостности нет — груз цел
	cargo_hp = clampi(int(hp), 1, 100) if (hp is int or hp is float) else 100
	done = d.done
	last = d.last
	by_giver = d.by_giver.duplicate()
	known = d.known.duplicate()
	_done = d.completed.duplicate()
	installed_beacons = beacons.duplicate()
	painted_objects = d.get("painted", {}).duplicate()
	thanks = d.get("thanks", {}).duplicate(true)
	series = QuestData.new()
	series_done = d.get("series_done", false)
	if not d.get("series", {}).is_empty():
		# серия, у которой пропало место, не грузится (мир изменился), остальное сохранение остаётся
		var resumed := _resolve(d.series, places)
		if resumed != null:
			series = resumed
	return true


## Задание из записи сохранения с местами из places (ключ → место); null, если какого-то места нет
static func _resolve(saved: Dictionary, places: Dictionary, world: WorldData = null) -> QuestData:
	var q := saved.duplicate(true)
	if not q.is_empty():
		if not places.has(q.giver):
			return null
		for s: Dictionary in q.steps:
			if s.do == "install":
				s.place = BeaconSites.place(BeaconSites.cell_of(s.place), s.number)
			elif s.do == "paint":
				s.place = PaintTargets.resolve(world, s.place)
				if s.place.is_empty():
					return null
				s.place.approach = s.approach
				s.erase("approach")
			elif places.has(s.place):
				s.place = places[s.place]
			else:
				return null
		if q.kind in FIELD_STEPS:
			q.target = q.steps[1].place
		elif places.has(q.target):
			q.target = places[q.target]
		else:
			return null
	return QuestData.from_dict(q)
