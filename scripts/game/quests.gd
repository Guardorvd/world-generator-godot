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
}
## Что предлагает доска (18.11.2026). Остальные виды (посещение, обход, снимок, летопись и прежняя доставка в поселение)
## отключены, но их сборка и шаги остаются: взятое в старом сохранении задание грузится, выполняется и бросается как раньше.
## Вернуть вид на доску — добавить его сюда (снимок, летопись, посещение и обход включаются вместе).
const OFFERED := ["supplies", "fragile", "repair", "obelisks"]
const SIGHT_KINDS := ["photo", "chronicle", "visit", "tour"]
## Виды с сумкой за спиной (доставка): быстрое перемещение недоступно, сумка у доски
const CARGO_KINDS := ["delivery", "fragile", "supplies"]
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
const SHOT_REACH_M := 400.0 # м: снимок для задания — не дальше этого от места
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
var done := 0          # выполнено заданий
var last := ""         # название последнего выполненного
var by_giver := {}     # id поселения -> выполнено его заданий
var known := {}        # id мест взятых заданий: как посещённые, их названия видны в мире, на карте и в видоискателе
var _done := {}        # id выполненных: доска их больше не предлагает
## «Летопись обелисков» — серия, а не обычное задание: идёт параллельно с активным (доставка, ремонт), снимки табличек всех
## обелисков в любом порядке. steps — по одному шагу plaque на обелиск, снятые стоят первыми (step — сколько снято)
var series := QuestData.new()
var series_done := false   # серия выполнена: доска её больше не предлагает


## Задания доски поселения here (место с key). places — все места мира, neighbors — поселения по дорогам,
## far — дальнее поселение по сети или пусто, visited — посещённые id. Порядок и выбор устойчивы для мира и счёта done
func offers(here: Dictionary, places: Array, neighbors: Array, far: Dictionary, visited: Dictionary, seed_num: int, broken := Callable()) -> Array:
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
	# припасы: на вышку (сумку надо занести наверх по лестнице) и в одинокий дом или на хутор; ближние места первыми
	if "supplies" in OFFERED:
		for group: Array in SUPPLY_GROUPS:
			var sites := spots.filter(func(p: Dictionary) -> bool: return p.kind == "site" and _site_type(p) in group and not _done.has(_id("supplies", here, p)))
			var supply := _pick(sites.slice(0, 3), rng)
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
		var to := _pick(trips if not trips.is_empty() and rng.randf() < ROLE_CHANCE else open, rng)
		if not to.is_empty():
			out.append(_make(carry_kind, here, [to]))
	# ремонт: ближайшие сломанные лавка, тур или причал (broken(id) — Repairables.is_broken), не выполненные раньше
	if "repair" in OFFERED and broken.is_valid():
		var wrecks := spots.filter(func(p: Dictionary) -> bool: return Repairables.kind_of(p) != "" and broken.call(p.key) and not _done.has(_id("repair", here, p)))
		var fix := _pick(wrecks.slice(0, 3), rng)
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
		known[s.place.key] = true
	changed.emit()


func abandon() -> void:
	active = QuestData.new()
	cargo = false
	changed.emit()


## Седок упал с велосипеда. Хрупкий груз разбит: задание возвращается к шагу «взять у доски».
## Возвращает сообщение или пусто
func crashed() -> String:
	if active.kind != "fragile" or not cargo:
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
		last = series.title
		_done[series.id] = true
		series_done = true
		done += 1
		series = QuestData.new()
		changed.emit()
		return "Летопись обелисков завершена: все таблички сняты"
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
	_done[active.id] = true
	done += 1
	by_giver[active.giver] = by_giver.get(active.giver, 0) + 1
	active = QuestData.new()
	changed.emit()
	return "Задание выполнено: %s" % last


## Только адреса мест: src и данные мира берутся из текущего мира.
func save_state() -> Dictionary:
	return {active = _addresses(active), cargo = cargo, done = done, last = last,
		by_giver = by_giver.duplicate(), known = known.duplicate(), completed = _done.duplicate(),
		series = _addresses(series), series_done = series_done}


static func _addresses(quest: QuestData) -> Dictionary:
	var q := quest.to_dict()
	if not q.is_empty():
		q.target = q.target.key
		for s: Dictionary in q.steps:
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
	var q: Dictionary = d.active
	if q.is_empty():
		return not d.cargo
	if not _valid_quest(q):
		return false
	return d.cargo == (q.kind in CARGO_KINDS and q.steps[q.step].do in ["carry", "climb"])


func restore_state(d: Dictionary, places: Dictionary) -> bool:
	if not valid_save(d):
		return false
	var q := _resolve(d.active, places)
	if q == null:
		return false
	active = q
	cargo = d.cargo
	done = d.done
	last = d.last
	by_giver = d.by_giver.duplicate()
	known = d.known.duplicate()
	_done = d.completed.duplicate()
	series = QuestData.new()
	series_done = d.get("series_done", false)
	if not d.get("series", {}).is_empty():
		# серия, у которой пропало место, не грузится (мир изменился), остальное сохранение остаётся
		var resumed := _resolve(d.series, places)
		if resumed != null:
			series = resumed
	return true


## Задание из записи сохранения с местами из places (ключ → место); null, если какого-то места нет
static func _resolve(saved: Dictionary, places: Dictionary) -> QuestData:
	var q := saved.duplicate(true)
	if not q.is_empty():
		if not places.has(q.giver) or not places.has(q.target):
			return null
		q.target = places[q.target]
		for s: Dictionary in q.steps:
			if not places.has(s.place):
				return null
			s.place = places[s.place]
	return QuestData.from_dict(q)