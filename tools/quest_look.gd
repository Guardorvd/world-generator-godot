extends SceneTree
## 11.9: изолированная сцена заданий без генерации мира. Несколько мест словарями и WorldData только со списками
## мест — для доски. Проверяет Quests: три вида на доске, устойчивость выбора, шаги доставки (сумка), снимка
## (нужное место в прицеле) и посещения, отказ, выполненное не предлагается снова.
## Снимает дорожную доску, личную карту и интерфейс доставки. Нужно окно.
##   godot --path . --script res://tools/quest_look.gd -- [--out <папка>] [--logic-only]

const Quests = preload("res://scripts/game/quests.gd")
const SettlementPanel = preload("res://scripts/ui/settlement_panel.gd")
const BeaconSites = Quests.BeaconSites
const PaintTargets = Quests.PaintTargets
const ShopProgress = preload("res://scripts/game/shop_progress.gd")

var out := ""
var failed := 0
var world := WorldData.new()
var heights := Heightfield.new()
var main: Node
var camera: Camera3D
var hud: Hud
var places: Array = []
var at := Vector2.ZERO  # где игрок, клетки


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	var args := OS.get_cmdline_user_args()
	var i := args.find("--out")
	out = args[i + 1] if i >= 0 and i + 1 < args.size() else OS.get_user_data_dir().path_join("quest_look")
	DirAccess.make_dir_recursive_absolute(out)
	root.size = Vector2i(1280, 720)
	var home := {x = 100, y = 100, i = 0, name = "Ольховка", character = "деревня", importance = 1.0, connections = [1],
		huts = [{t = "house"}, {t = "house"}, {t = "barn"}]}
	world.settlements = [home, {x = 180, y = 130, i = 1, name = "Каменка", importance = 1.0, connections = [0], huts = []}]
	world.peaks = [{x = 160, y = 40, i = 2, name = "Седая"}]
	world.lakes = [{x = 60, y = 150, i = 3, name = "Тихое", cells = 900, sx = 70, sy = 140}]
	world.sites = [{x = 130, y = 40, i = 4, name = "Сторожевая", type = "tower", rank = 2}, {x = 105, y = 104, i = 5, name = "Колодец", type = "tower", rank = 2},
		{x = 40, y = 60, i = 6, name = "Заречный", type = "farm", rank = 1},
		{x = 150, y = 150, i = 7, name = "Лавка у обрыва", type = "bench", rank = 1},
		{x = 60, y = 40, i = 8, name = "Серый обелиск", type = "obelisk", rank = 2},
		{x = 140, y = 20, i = 9, name = "Межевой обелиск", type = "obelisk", rank = 2},
		{x = 190, y = 70, i = 10, name = "Лунный обелиск", type = "obelisk", rank = 2}]
	_map_terrain()
	_roadside_objects()
	for kind: String in WorldData.PLACE_KINDS:
		for src: Variant in world.get(kind + "s"):
			places.append(InteractionService.target(world.place(WorldData.place_id(kind, src.x, src.y))))
	_run()


func _map_terrain() -> void:
	world.W = 224
	world.H = 192
	world.N = world.W * world.H
	var biomes := PackedByteArray()
	var relief := PackedFloat32Array()
	biomes.resize(world.N)
	relief.resize(world.N)
	for y in world.H:
		for x in world.W:
			var at := Vector2(x, y)
			var hill := exp(-at.distance_squared_to(Vector2(112, 66)) / 2600.0)
			var woods := x < 99 + sin(y * 0.045) * 17 or x > 146 + cos(y * 0.08) * 15
			var water := ((at - Vector2(59, 149)) / Vector2(22, 15)).length_squared() < 1.0
			var i := y * world.W + x
			biomes[i] = Biomes.LAKE if water else (Biomes.FOREST if woods else Biomes.GRASS)
			relief[i] = (25.0 + hill * 310.0) / GameConfig.HS
	world.biome = biomes
	world.h = relief
	world.rivers = [[{x = 84, y = 70}, {x = 91, y = 91}, {x = 88, y = 112},
		{x = 78, y = 128}, {x = 69, y = 140}]]
	world.trails = [{kind = "road", pts = [{x = 35, y = 121}, {x = 70, y = 111}, {x = 100, y = 100},
		{x = 133, y = 110}, {x = 161, y = 113}, {x = 180, y = 130}, {x = 210, y = 146}]},
		{kind = "trail", pts = [{x = 70, y = 111}, {x = 76, y = 125}, {x = 70, y = 140}]}]
	var paths := PackedByteArray()
	paths.resize(world.N)
	for trail: Dictionary in world.trails:
		Grid.stamp_path(paths, world.W, world.H, trail.pts, 3 if trail.kind == "road" else 2, 0.7)
	world.path_mask = paths
	var lake := PackedByteArray()
	lake.resize(world.N)
	var ground := PackedFloat32Array()
	ground.resize(world.N)
	var filled := relief.duplicate()
	for i in world.N:
		lake[i] = 1 if biomes[i] == Biomes.LAKE else 0
		ground[i] = 15.0 + relief[i] * GameConfig.HS * 0.25
		filled[i] = (ground[i] + 3.0 + GameConfig.LAKE_DROP) / GameConfig.HS
	world.lake = lake
	world.filled = filled
	heights.world = world
	heights.hv = ground


func _roadside_objects() -> void:
	world.CW = ceili(float(world.W) / world.CS)
	world.CH = ceili(float(world.H) / world.CS)
	var chunks: Array[PackedInt32Array] = []
	for i in world.CW * world.CH:
		chunks.append(PackedInt32Array())
	world.obj_x = PackedFloat64Array([112.0, 125.0, 137.0, 149.0, 161.0, 177.0])
	world.obj_y = PackedFloat64Array([107.0, 105.0, 114.0, 109.0, 117.0, 123.0])
	world.obj_k = PackedInt32Array([Biomes.T_OAK, Biomes.T_BIRCH, Biomes.T_ROCK, Biomes.T_PINE, Biomes.T_ROCK, Biomes.T_BIRCH])
	world.obj_s = PackedFloat64Array([1.3, 1.2, 1.0, 1.3, 1.1, 1.2])
	world.obj_count = world.obj_x.size()
	world.obj_v.resize(world.obj_count)
	for i in world.obj_count:
		var chunk := floori(world.obj_y[i] / world.CS) * world.CW + floori(world.obj_x[i] / world.CS)
		chunks[chunk].append(i)
	world.chunks = chunks


func _check(ok: bool, text: String) -> void:
	print(("ok   " if ok else "FAIL ") + text)
	if not ok:
		failed += 1


func _place(name: String) -> Dictionary:
	for p: Dictionary in places:
		if p.name == name:
			return p
	return {}


func _offers(quests: Quests) -> Array:
	var board := InteractionService.new()
	board.quests = quests
	board.world = world
	board.heights = heights
	board.visited = {}
	board.is_broken = _broken
	return board.offers_all(world.settlements[0], places)


## Сломанные объекты стенда: лавка — всегда, остальные по хешу мира (сид 0)
func _broken(id: String) -> bool:
	return id == _place("Лавка у обрыва").key or Repairables.initially_broken(0, id)


func _arrived(place: Dictionary) -> bool:
	return Vector2(place.x, place.y).distance_to(at) < 5.0


func _by_kind(list: Array, kind: String) -> QuestData:
	for q: QuestData in list:
		if q.kind == kind:
			return q
	return QuestData.new()


func _logic() -> void:
	var quests := Quests.new()
	var shop := ShopProgress.new()
	quests.completion_note = func(ids: Array) -> String: return " · +%d" % shop.award("quests", ids)
	var offers := _offers(quests)
	var kinds := offers.map(func(q: QuestData) -> String: return q.kind)
	_check(kinds == ["beacons", "paint", "supplies", "supplies", "fragile", "repair", "obelisks"],
		"на доске есть разметка, маяки и прежние задания (%s)" % ", ".join(PackedStringArray(kinds)))
	var supply_targets := offers.filter(func(q: QuestData) -> bool: return q.kind == "supplies").map(func(q: QuestData) -> String: return q.target.name)
	supply_targets.sort()
	_check(supply_targets == ["Заречный", "Сторожевая"], "припасы — на вышку и на хутор, не в поселение и не к месту у порога (%s)" % ", ".join(PackedStringArray(supply_targets)))
	var offer_id := func(q: QuestData) -> String: return q.id
	_check(offers.map(offer_id) == _offers(quests).map(offer_id), "те же задания при повторном открытии доски")
	_check(not offers.any(func(q: QuestData) -> bool: return q.target.name == "Колодец"), "место в паре шагов от поселения не задание")
	var changes := [0]
	quests.changed.connect(func() -> void: changes[0] += 1)
	# доставка: сумка у доски, цель на компасе только после неё, быстрое перемещение — по cargo
	var delivery := Quests._make("delivery", _place("Ольховка"), [_place("Каменка")])
	quests.accept(delivery)
	_check(quests.step().do == "pickup" and quests.goal().is_empty() and not quests.cargo, "доставка начинается у доски с сумкой, без цели на компасе")
	at = Vector2(180, 130)
	_check(quests.tick(_arrived) == "", "без сумки приезд в поселение не засчитан")
	_check(quests.pick_up() != "" and quests.cargo and quests.goal().name == "Каменка", "сумка за спиной, цель — поселение доставки")
	_check(shop.balance == 0, "за взятие задания и сумки очков нет")
	at = Vector2(150, 120)
	_check(quests.tick(_arrived) == "" and quests.cargo, "по дороге шаг не закрывается")
	at = Vector2(180, 130)
	var text := quests.tick(_arrived)
	_check(text.begins_with("Задание выполнено") and not quests.cargo and quests.active.is_empty() and quests.done == 1, "сумка доставлена — задание выполнено, сумки нет")
	_check(shop.balance == 30 and text.ends_with("+30"), "после доставки награда сохранена и видна в сообщении")
	_check(not _offers(quests).any(func(q: QuestData) -> bool: return q.id == delivery.id), "выполненная доставка больше не предлагается")
	# снимок: только нужное место в прицеле, потом отвезти
	var photo := Quests._make("photo", _place("Ольховка"), [_place("Седая"), _place("Каменка")])
	quests.accept(photo)
	_check(quests.step().do == "shoot" and quests.goal().key == photo.target.key, "снимок: цель — место съёмки")
	_check(quests.known.has(photo.target.key) and quests.known.has(quests.active.steps[1].place.key), "взятое задание открывает названия своих мест")
	_check(quests.photographed("") == "" and quests.photographed("peak:0:0") == "", "снимок без места или чужого места не засчитан")
	_check(quests.photographed(photo.target.key, Quests.SHOT_REACH_M + 50.0) == "" and quests.step().do == "shoot", "снимок издалека не засчитан")
	_check(quests.photographed(photo.target.key, 120.0) != "" and quests.step().do == "bring", "снимок нужного места вблизи — дальше отвезти его")
	var back: Dictionary = quests.step().place
	at = Vector2(back.x, back.y)
	_check(quests.tick(_arrived).begins_with("Задание выполнено") and quests.done == 2, "снимок привезён — задание выполнено")
	_check(quests.by_giver.get(_place("Ольховка").key, 0) == 2, "счёт выполненных для поселения")
	# обход: два места по очереди
	var tour := Quests._make("tour", _place("Ольховка"), [_place("Седая"), _place("Сторожевая")])
	quests.accept(tour)
	at = Vector2(160, 40)
	_check(quests.tick(_arrived) != "" and quests.goal().name == "Сторожевая" and quests.marker().name == "Сторожевая", "обход: после первого места цель — второе")
	at = Vector2(130, 40)
	_check(quests.tick(_arrived).begins_with("Задание выполнено"), "обход: второе место — задание выполнено")
	# посещение и отказ
	var visit := Quests._make("visit", _place("Ольховка"), [_place("Тихое")])
	quests.accept(visit)
	_check(quests.goal().key == visit.target.key, "посещение ставит место целью")
	quests.abandon()
	_check(quests.active.is_empty() and quests.done == 3, "отказ снимает задание без засчёта")
	_check(changes[0] == 11, "каждое изменение задания сообщается (%d)" % changes[0])
	# 12.3: хрупкий груз — падение возвращает к доске; летопись — два снимка и обратно
	var fragile := Quests._make("fragile", _place("Ольховка"), [_place("Каменка")])
	quests.accept(fragile)
	_check(quests.crashed() == "", "падение без груза ничего не бьёт")
	quests.pick_up()
	at = Vector2(150, 120)
	# 20.11: целостность груза: жёсткий удар отнимает часть, одно падение груз переживает, второе — разбит
	var jolt := quests.damage_cargo(20)
	_check(jolt.get("hp") == 80 and not jolt.broken and quests.cargo, "жёсткий удар — груз цел на 80 %")
	_check(quests.crashed() == "" and quests.cargo_hp == 25 and quests.cargo, "падение отнимает 55 %, груз ещё цел")
	_check(Quests.new().damage_cargo(20).is_empty(), "без хрупкого груза удары ничего не бьют")
	var broken := quests.crashed()
	_check(broken != "" and not quests.cargo and quests.cargo_hp == 100 and quests.step().do == "pickup", "второе падение — груз разбит, снова к доске")
	var saved_hp := quests.save_state()
	_check(saved_hp.get("cargo_hp") == 100, "целостность груза сохраняется")
	quests.pick_up()
	at = Vector2(180, 130)
	_check(quests.tick(_arrived).begins_with("Задание выполнено"), "хрупкий груз довезён без падения")
	var chronicle := Quests._make("chronicle", _place("Ольховка"), [_place("Седая"), _place("Сторожевая"), _place("Ольховка")])
	quests.accept(chronicle)
	_check(quests.photographed(_place("Сторожевая").key, 100.0) == "", "летопись: снимки по порядку")
	_check(quests.photographed(_place("Седая").key, 100.0) != "" and quests.wants_photo(_place("Сторожевая").key), "летопись: после первого — второе место")
	_check(quests.photographed(_place("Сторожевая").key, 100.0) != "" and quests.step().do == "bring", "летопись: оба снимка — отвезти")
	at = Vector2(100, 100)
	_check(quests.tick(_arrived).begins_with("Задание выполнено"), "летопись выполнена")
	_supplies_and_old_saves()
	_repair_quest()
	_series_quest()
	var texts := {}
	for kind: String in ["delivery", "fragile", "visit"]:
		for p: Dictionary in places:
			if p.kind != "settlement" or kind == "visit":
				texts[Quests._make(kind, _place("Ольховка"), [p, p, p]).title.split("«")[0]] = true
	_check(texts.size() >= 6, "формулировки разные (%d): %s" % [texts.size(), ", ".join(PackedStringArray(texts.keys()))])
	var saved := quests.save_state()
	_check(Quests.valid_save(saved), "сохранение после новых видов проходит проверку")


## «Летопись обелисков»: серия параллельно активному заданию; снимки табличек всех обелисков в любом порядке, только вблизи
func _series_quest() -> void:
	var quests := Quests.new()
	var series: QuestData = _by_kind(_offers(quests), "obelisks")
	_check(not series.is_empty() and series.steps.size() == 3 and series.steps.all(func(s: Dictionary) -> bool: return s.do == "plaque"), "серия предлагает все три обелиска")
	_check(series.steps[0].place.name == "Серый обелиск" and series.steps[2].place.name == "Лунный обелиск", "ближайшие к доске — первыми")
	quests.accept(series)
	_check(quests.active.is_empty() and not quests.cargo and quests.series_progress() == Vector2i(0, 3), "серия не занимает активное задание: 0 из 3")
	_check(quests.known.has(series.steps[1].place.key) and quests.known.has(series.steps[2].place.key), "места обелисков известны (видны на карте сквозь туман)")
	_check(_by_kind(_offers(quests), "obelisks").is_empty(), "взятая серия больше не предлагается")
	quests.accept(Quests._make("fragile", _place("Ольховка"), [_place("Каменка")]))
	_check(not quests.active.is_empty() and not quests.series.is_empty(), "обычное задание берётся рядом с серией")
	_check(quests.plaque_photographed("") == "" and quests.plaque_photographed("site:1:1", 1.0) == "" and quests.series_progress().x == 0, "чужая и пустая табличка не засчитаны")
	var far: String = series.steps[0].place.key
	_check(quests.plaque_photographed(far, Quests.PLAQUE_REACH_M + 1.0) == "" and quests.series_progress().x == 0, "табличка издалека не засчитана")
	var third: String = series.steps[2].place.key
	var message := quests.plaque_photographed(third, 2.0)
	_check(message.contains("1 из 3") and quests.series_progress() == Vector2i(1, 3) and quests.series.steps[0].place.key == third, "любой порядок: третья снята первой, она встала первой (%s)" % message)
	_check(quests.plaque_photographed(third, 2.0) == "" and quests.series_progress().x == 1, "повторная табличка не считается")
	_check(quests.series_note(third).begins_with("Эта табличка уже снята") and quests.series_note(far).begins_with("Для летописи"), "подсказка у таблички: снята или нужна")
	_check(not quests.active.is_empty(), "активное задание серия не трогает")
	var by_key := {}
	for p: Dictionary in places:
		by_key[p.key] = p
	var saved := quests.save_state()
	var again := Quests.new()
	_check(Quests.valid_save(saved) and again.restore_state(saved, by_key) and again.series_progress() == Vector2i(1, 3) and again.series.steps[0].place.key == third and not again.active.is_empty(), "серия и порядок переживают сохранение")
	var old_format := saved.duplicate(true)
	old_format.erase("series")
	old_format.erase("series_done")
	var legacy := Quests.new()
	_check(Quests.valid_save(old_format) and legacy.restore_state(old_format, by_key) and legacy.series.is_empty() and not legacy.series_done, "сохранение без серии читается")
	var rest: Array = quests.series.steps.slice(quests.series.step).map(func(s: Dictionary) -> String: return s.place.key)
	for k in rest.size() - 1:
		quests.plaque_photographed(rest[k], 3.0)
	var shop := ShopProgress.new()
	quests.completion_note = func(ids: Array) -> String: return " · +%d" % shop.award("obelisks", ids)
	var last := quests.plaque_photographed(rest[-1], 3.0)
	_check(shop.balance == 80 and last.ends_with("+80"), "последняя табличка закрывает одну выплату за серию")
	_check(last.begins_with("Летопись обелисков завершена") and quests.series.is_empty() and quests.series_done and quests.done == 1, "все таблички — серия выполнена, засчитана (%s)" % last)
	_check(_by_kind(_offers(quests), "obelisks").is_empty() and quests.series_progress() == Vector2i.ZERO, "выполненная серия не предлагается снова")
	var finished := Quests.new()
	_check(finished.restore_state(quests.save_state(), by_key) and finished.series_done and finished.series.is_empty(), "выполненность серии сохраняется")


## Ремонт: берётся у доски, цель — сломанный объект; засчитывается только удержанием у нужного объекта (GameWorld вызывает repaired)
func _repair_quest() -> void:
	var quests := Quests.new()
	var offered := _offers(quests)
	var repair: QuestData = _by_kind(offered, "repair")
	_check(not repair.is_empty() and Repairables.kind_of(repair.target) != "" and _broken(repair.target.key), "ремонт предлагает сломанное лавку, тур или причал (%s)" % repair.title)
	_check(_offers(quests).map(func(q: QuestData) -> String: return q.id) == offered.map(func(q: QuestData) -> String: return q.id), "ремонт на доске устойчив при повторном открытии")
	var calm := quests.offers(_place("Ольховка"), places, [_place("Каменка")], {}, {}, 7, func(_id: String) -> bool: return false)
	_check(_by_kind(calm, "repair").is_empty(), "если ничего не сломано, ремонта на доске нет")
	var bench := Quests._make("repair", _place("Ольховка"), [_place("Лавка у обрыва")])
	quests.accept(bench)
	_check(quests.step().do == "fix" and not quests.cargo and quests.goal().name == "Лавка у обрыва" and quests.known.has(bench.target.key), "ремонт: сразу цель, сумки нет, место известно")
	_check(quests.step_text().contains("лавку") and quests.step_text().contains("удерживайте"), "шаг называет объект и удержание (%s)" % quests.step_text())
	at = Vector2(150, 150)
	_check(quests.tick(_arrived) == "" and quests.step().do == "fix", "приезд к лавке задание не закрывает: нужен ремонт")
	_check(quests.repaired(_place("Седая").key) == "" and quests.step().do == "fix", "починка другого объекта не засчитана")
	_check(quests.repaired(bench.target.key).begins_with("Задание выполнено") and quests.active.is_empty() and quests.done == 1, "ремонт лавки засчитан")
	_check(not _offers(quests).any(func(q: QuestData) -> bool: return q.id == bench.id), "починенная лавка больше не предлагается")
	for place_name: String in ["Седая", "Лавка у обрыва"]:
		var q := Quests._make("repair", _place("Ольховка"), [_place(place_name)])
		var held := Quests.new()
		held.accept(q)
		var restored := Quests.new()
		var by_key := {}
		for p: Dictionary in places:
			by_key[p.key] = p
		_check(Quests.valid_save(held.save_state()) and restored.restore_state(held.save_state(), by_key) and restored.step().do == "fix", "задание ремонта («%s») сохраняется и грузится" % place_name)
		_check(restored.step_text().contains("тур") or restored.step_text().contains("лавку"), "объект в тексте: %s" % restored.step_text())
	# 18.11.2026: ремонт по пути без задания — благодарность ждёт в поселении, засчитывается по приезду и сохраняется
	var road := Quests.new()
	var village := _place("Ольховка")
	var note := road.repaired_on_way(_place("Седая"), village)
	_check(note.contains("Ольховка") and road.thanks.size() == 1 and road.done == 0 and road.thanks_lines().size() == 1, "ремонт по пути: зовут в поселение (%s)" % note)
	var by_place := {}
	for p: Dictionary in places:
		by_place[p.key] = p
	var kept := Quests.new()
	_check(Quests.valid_save(road.save_state()) and kept.restore_state(road.save_state(), by_place) and kept.thanks.size() == 1, "благодарность сохраняется")
	var shop := ShopProgress.new()
	kept.completion_note = func(ids: Array) -> String: return " · +%d" % shop.award("repairs", ids)
	kept.repaired_on_way(_place("Лавка у обрыва"), village)
	_check(kept.thank(func(_id: String) -> bool: return false) == "" and kept.done == 0, "вдали от поселения не засчитано")
	var thanked := kept.thank(func(id: String) -> bool: return id == village.key)
	_check(thanked.contains("благодарит") and kept.done == 2 and kept.by_giver.get(village.key) == 2 and kept.thanks.is_empty(), "в поселении засчитаны обе благодарности (%s)" % thanked)
	_check(shop.balance == 60 and thanked.ends_with("+60"), "одна выплата за каждую благодарность")


func _shop_save() -> void:
	var shop := ShopProgress.new()
	var equipment_events: Array[String] = []
	shop.equipment_changed.connect(func(id: String) -> void: equipment_events.append(id))
	var path := out.path_join("shop-%d.bin" % OS.get_process_id())
	var legacy := shop._state.duplicate()
	legacy.erase("purchase_goal")
	var raw := var_to_bytes(legacy)
	var legacy_bytes := raw.hex_encode().sha256_text().to_ascii_buffer()
	legacy_bytes.append_array(raw)
	_check(ShopProgress.Files.replace(path, legacy_bytes) == OK, "записан профиль магазина 1.0")
	shop.load_profile(path)
	_check(shop.load_error == OK and shop.purchase_goal == "", "профиль 1.0 открывается без цели")
	_check(shop.set_purchase_goal("ember") != OK and shop.set_purchase_goal("moss") == OK and shop.remaining("moss") == 50,
		"цель можно выбрать только среди покупных расцветок, которых ещё нет")
	var goal_on_disk := ShopProgress.new()
	goal_on_disk.load_profile(path)
	_check(goal_on_disk.purchase_goal == "moss", "цель переживает перезапуск")
	var completed := ["start:home", "supplies:home>farm"]
	_check(shop.award("first", completed) == 50 and shop.award("first", completed) == 0,
		"копия слота не выдаёт награды повторно")
	_check(shop.award("second", ["start:other"]) == 0, "вступительное задание платит один раз на профиль")
	_check(shop.buy("moss") == OK and shop.buy("moss") != OK and shop.balance == 0, "повторная покупка ничего не списывает")
	_check(shop.purchase_goal == "", "покупка выбранной расцветки закрывает цель")
	_check(equipment_events.is_empty(), "начисления и покупки не трогают материалы велосипеда")
	_check(shop.equip("moss") == OK and shop.equip("moss") == OK and equipment_events == ["moss"],
		"событие экипировки только при смене расцветки")
	var loaded := ShopProgress.new()
	loaded.load_profile(path)
	_check(loaded.equipped == "moss" and loaded.owns("moss") and loaded.award("first", completed) == 0,
		"покупка, выбор и история выплат переживают повторное чтение")
	_check(loaded.award("second", ["supplies:home>farm"]) == 30, "одинаковые ID заказов в разных мирах оплачиваются отдельно")
	var broken := FileAccess.open(path, FileAccess.WRITE)
	broken.store_string("broken")
	broken.close()
	var backup := ShopProgress.new()
	backup.load_profile(path)
	_check(backup.owns("moss") and backup.equipped == "moss" and backup.balance == 0, "повреждённый основной файл заменяет резервная копия")
	var blocked := path + ".tmp"
	DirAccess.make_dir_absolute(blocked)
	_check(backup.set_purchase_goal("glacier") != OK and backup.purchase_goal == "", "сбой записи сохраняет прежнюю цель")
	_check(backup.award("second", ["supplies:home>farm"]) == -1 and backup.balance == 0, "ошибка записи оставляет баланс прежним")
	DirAccess.remove_absolute(blocked)
	_check(backup.retry_rewards() == 30 and backup.retry_rewards() == 0, "после ошибки награда безопасно записывается один раз")
	backup.award("second", ["supplies:home>other"])
	DirAccess.make_dir_absolute(blocked)
	_check(backup.buy("night") != OK and backup.balance == 60 and not backup.owns("night"),
		"сбой покупки сохраняет баланс и коллекцию")
	DirAccess.remove_absolute(blocked)
	ShopProgress.Files.remove(path)
	var other_purchase := ShopProgress.new()
	var intro_points := other_purchase.award("first", ["start:home"])
	_check(not other_purchase.first_purchase_unlocked(intro_points), "вступление само по себе не обещает покупку")
	var order_points := other_purchase.award("first", ["supplies:home>farm"])
	_check(other_purchase.first_purchase_unlocked(order_points), "первая доступная расцветка отмечается при достижении цены")
	var later_points := other_purchase.award("first", ["supplies:home>other"])
	_check(not other_purchase.first_purchase_unlocked(later_points), "подсказка не повторяется, пока баланс выше порога")
	other_purchase.set_purchase_goal("moss")
	_check(other_purchase.buy("night") == OK and other_purchase.purchase_goal == "moss"
		and other_purchase.remaining("moss") == 20, "покупка другого комплекта сохраняет цель и пересчитывает прогресс")


## Припасы: на вышку — только с верхней площадки, на хутор — у места; задание из старого сохранения грузится и заканчивается
func _supplies_and_old_saves() -> void:
	var quests := Quests.new()
	var offered := _offers(quests)
	var tower_supply: QuestData = offered.filter(func(q: QuestData) -> bool: return q.target.name == "Сторожевая")[0]
	var farm_supply: QuestData = offered.filter(func(q: QuestData) -> bool: return q.target.name == "Заречный")[0]
	_check(tower_supply.steps[1].do == "climb" and farm_supply.steps[1].do == "carry", "вышка — шаг «подняться», хутор — «довезти»")
	_check(not farm_supply.title.is_empty() and not farm_supply.text.is_empty() and not tower_supply.title.is_empty() and tower_supply.text.length() > 40, "тексты припасов написаны")
	quests.accept(tower_supply)
	_check(quests.known.has(tower_supply.target.key) and quests.known.has(tower_supply.giver), "взятое задание открывает вышку и поселение")
	var on_deck := [false]
	var arrived := func(place: Dictionary) -> bool:
		return Vector2(place.x, place.y).distance_to(at) < 5.0 and (quests.step().do != "climb" or on_deck[0])
	quests.pick_up()
	_check(quests.cargo and quests.step().do == "climb" and quests.step_text().contains("вышки") and quests.step_text().contains("площадку"), "после сумки — подняться на площадку вышки (%s)" % quests.step_text())
	at = Vector2(130, 40)
	_check(quests.tick(arrived) == "" and quests.cargo, "у подножия вышки задание не засчитано")
	on_deck[0] = true
	_check(quests.tick(arrived).begins_with("Задание выполнено") and not quests.cargo and quests.done == 1, "на верхней площадке — припасы доставлены")
	_check(not _offers(quests).any(func(q: QuestData) -> bool: return q.id == tower_supply.id), "доставленные на вышку припасы больше не предлагаются")
	quests.accept(farm_supply)
	quests.pick_up()
	_check(quests.step_text().contains("хутор"), "хутор назван в шаге (%s)" % quests.step_text())
	at = Vector2(40, 60)
	_check(quests.tick(arrived).begins_with("Задание выполнено"), "на хутор довозят до места, без подъёма")
	# сохранение с припасами и с отключёнными видами: проверка, загрузка и выполнение
	var by_key := {}
	for p: Dictionary in places:
		by_key[p.key] = p
	for old: QuestData in [Quests._make("supplies", _place("Ольховка"), [_place("Сторожевая")]), Quests._make("visit", _place("Ольховка"), [_place("Тихое")]),
			Quests._make("photo", _place("Ольховка"), [_place("Седая"), _place("Каменка")]), Quests._make("delivery", _place("Ольховка"), [_place("Каменка")])]:
		var held := Quests.new()
		held.accept(old)
		var state := held.save_state()
		var restored := Quests.new()
		_check(Quests.valid_save(state) and restored.restore_state(state, by_key) and restored.active.kind == old.kind, "сохранённое задание «%s» (%s) грузится" % [old.kind, old.title])
		restored.abandon()
		_check(restored.active.is_empty(), "и бросается («%s»)" % old.kind)
	var visit_held := Quests.new()
	visit_held.accept(Quests._make("visit", _place("Ольховка"), [_place("Тихое")]))
	var back_from_save := Quests.new()
	back_from_save.restore_state(visit_held.save_state(), by_key)
	at = Vector2(60, 150)
	_check(back_from_save.tick(_arrived).begins_with("Задание выполнено"), "посещение из старого сохранения заканчивается")


func _beacon_quest() -> void:
	var quests := Quests.new()
	var offer := _by_kind(_offers(quests), "beacons")
	_check(not offer.is_empty() and offer.steps.size() == 4, "маяки: обычная сумка и три установки")
	if offer.is_empty():
		return
	_check(offer.steps == _by_kind(_offers(quests), "beacons").steps, "те же площадки при повторном открытии доски")
	var by_key := {}
	for place: Dictionary in places:
		by_key[place.key] = place
	var plan := Rect2i(0, 0, world.W, world.H)
	var sites: Array[Vector2] = []
	for s: Dictionary in offer.steps.slice(1):
		var cell := BeaconSites.cell_of(s.place.key)
		var xz := Vector2(s.place.x, s.place.y) * GameConfig.TILE
		_check(world.path_mask[cell.y * world.W + cell.x] == 0 and heights.depth_at(xz.x, xz.y) == 0.0,
			"маяк %d на суше вне дороги" % s.number)
		sites.append(Vector2(cell))
	_check(absf((sites[1] - sites[0]).cross(sites[2] - sites[0])) > 200.0, "площадки образуют треугольник")
	quests.accept(offer)
	var first: String = offer.steps[1].place.key
	var second: String = offer.steps[2].place.key
	var third: String = offer.steps[3].place.key
	var resumed := Quests.new()
	_check(resumed.restore_state(quests.save_state(), by_key, plan) and resumed.goal().is_empty()
		and resumed.step().do == "pickup", "до получения сумки восстанавливается шаг у доски")
	_check(quests.install_beacon(first).is_empty() and quests.goal().is_empty(), "без сумки площадка скрыта")
	quests.pick_up()
	_check(quests.cargo and quests.goal().key == first and not quests.known.has(second) and not quests.known.has(third),
		"с сумкой видна только первая точка")
	_check(quests.crashed().is_empty() and quests.install_beacon(second).is_empty()
		and quests.tick(func(_place: Dictionary) -> bool: return true).is_empty(), "падение и прибытие не устанавливают маяк")
	var game := GameWorld.new()
	game.heights = heights
	game.quests = quests
	game.bike = BikeRide.new()
	game.player = PlayerState.new()
	var at_m := sites[0] * GameConfig.TILE + Vector2.ONE * GameConfig.TILE * 0.5
	_check(game._beacon_interaction().is_empty(), "вдали от маяка установка недоступна")
	game.player.x = at_m.x
	game.player.z = at_m.y
	game.player.feet = heights.ground_at(at_m.x, at_m.y)
	game.bike.riding = true
	_check(game._beacon_interaction().is_empty(), "для установки нужно сойти с велосипеда")
	game.bike.riding = false
	_check(game._beacon_interaction().get("id") == first, "пешком рядом с площадкой доступна установка")
	game.free()
	quests.install_beacon(first)
	_check(quests.goal().key == second and quests.beacons_in_world().has(first)
		and quests.install_beacon(first).is_empty(), "повторно поставить первый маяк нельзя, открылась вторая точка")
	var layer := GameWorld.BeaconLayer.new()
	layer.sync(quests.beacons_in_world(), quests.goal(), heights)
	_check(layer.get_child_count() == 2, "установленный маяк и метка следующей площадки есть в мире")
	_check(resumed.restore_state(bytes_to_var(var_to_bytes(quests.save_state())), by_key, plan)
		and resumed.cargo and resumed.goal().key == second and resumed.beacons_in_world().has(first),
		"сохранение восстанавливает сумку, установленный маяк и текущую точку")
	resumed.abandon()
	_check(resumed.goal().is_empty() and not resumed.cargo and resumed.beacons_in_world().is_empty(),
		"отказ убирает сумку и маяки незавершённого задания")
	quests.install_beacon(second)
	_check(quests.goal().key == third and quests.cargo, "после второй установки открывается третья точка")
	quests.install_beacon(third)
	_check(quests.active.is_empty() and not quests.cargo and quests.done == 1
		and quests.by_giver.get(offer.giver) == 1 and _by_kind(_offers(quests), "beacons").is_empty(),
		"третий маяк завершает задание на месте и убирает его с доски")
	_check(resumed.restore_state(quests.save_state(), by_key, plan) and resumed.beacons_in_world().size() == 3,
		"три установленных маяка остаются после завершения и перезагрузки")
	layer.sync(resumed.beacons_in_world(), resumed.goal(), heights)
	_check(layer.get_children().filter(func(node: Node3D) -> bool: return node.visible).size() == 3,
		"после завершения в мире видны три маяка")
	layer.free()


func _paint_quest() -> void:
	var quests := Quests.new()
	var offer := _by_kind(_offers(quests), "paint")
	_check(offer.steps.size() == 4, "разметка: сумка и три объекта")
	if offer.is_empty():
		return
	var steps := offer.steps.slice(1)
	var ids: Array = steps.map(func(s: Dictionary) -> String: return s.place.key)
	_check(steps == _by_kind(_offers(quests), "paint").steps.slice(1), "разметка выбирает те же объекты при открытии доски")
	_check(steps[0].place.x < steps[1].place.x and steps[1].place.x < steps[2].place.x
		and steps.any(func(s: Dictionary) -> bool: return s.place.rock), "дерево и камень выбираются по ходу одной дороги")
	quests.accept(offer)
	_check(quests.goal().is_empty() and quests.paint_object(ids[0]).is_empty(), "без сумки цели и краски нет")
	quests.pick_up()
	_check(quests.goal().key == ids[0] and quests.paint_object(ids[1]).is_empty()
		and quests.known.keys().all(func(id: String) -> bool: return id not in ids), "разметка открывает только текущую цель")
	var goal := quests.goal()
	_check(goal.approach.distance_to(Vector2(goal.x, goal.y) * GameConfig.TILE) > goal.radius,
		"навигация ведёт к месту рядом с объектом")
	quests.paint_object(ids[0])
	_check(quests.goal().key == ids[1] and quests.painted_objects.has(ids[0]) and quests.paint_object(ids[0]).is_empty(),
		"после разметки краска остаётся и следующая цель открывается")
	var catalog := {}
	for p: Dictionary in places:
		catalog[p.key] = p
	var resumed := Quests.new()
	_check(resumed.restore_state(bytes_to_var(var_to_bytes(quests.save_state())), catalog, Rect2i(), world)
		and resumed.cargo and resumed.goal() == quests.goal() and resumed.painted_objects.has(ids[0]),
		"краска, сумка и текущий объект восстанавливаются")
	resumed.abandon()
	_check(resumed.painted_objects.has(ids[0]) and resumed.goal().is_empty() and not resumed.cargo, "нанесённая краска остаётся при отказе")
	var replacement := _by_kind(_offers(resumed), "paint")
	_check(not replacement.is_empty() and not replacement.steps.any(func(s: Dictionary) -> bool: return s.place.key == ids[0]),
		"на доске уже покрашенный объект не выбирается повторно")
	quests.paint_object(ids[1])
	quests.paint_object(ids[2])
	_check(quests.done == 1 and quests.active.is_empty() and not quests.cargo and _by_kind(_offers(quests), "paint").is_empty(),
		"третья метка завершает задание на месте")
	_check(resumed.restore_state(quests.save_state(), catalog, Rect2i(), world) and resumed.painted_objects.size() == 3,
		"краска на всех трёх объектах сохраняется после выполнения")


func _paint_look() -> void:
	var vegetation := VegetationLayer.new()
	vegetation.world = world
	vegetation.heights = heights
	for kind: int in [Biomes.T_OAK, Biomes.T_BIRCH, Biomes.T_PINE]:
		var def := ForestModels.definition(kind, 0)
		var mesh: Mesh = def.trunk
		vegetation._defs[kind] = {trunk = mesh, box = mesh.get_aabb(), ref = def.ref}
	var rock := Models.boulder(Vector3(1.3, 0.78, 1.05), 72, 0.24)
	vegetation._defs[Biomes.T_ROCK] = {crown = rock, box = rock.get_aabb(), leaves = [Color.GRAY]}
	var layer := GameWorld.PaintLayer.new()
	layer.vegetation = vegetation
	root.add_child(layer)
	var tree_place := PaintTargets.place(world, 0)
	var rock_place := PaintTargets.place(world, 2)
	layer.sync({tree_place.key: true}, rock_place)
	_check(layer._highlight != null and layer._painted[tree_place.key] != null and layer._highlight.mesh == rock,
		"краска и подсветка используют меши настоящего дерева и камня")
	var box_at: Vector3 = layer._item.at.origin
	var eye := box_at + Vector3(0.0, 0.3, 2.0)
	var item := layer.item(eye, GameWorld.REACH)
	_check(layer.item(eye + Vector3(0.0, 0.0, 7.0), GameWorld.REACH).is_empty()
		and InteractionService.new().select([item], eye, (box_at - eye).normalized()).get("id") == rock_place.key,
		"активный объект выбирается взглядом в пределах взаимодействия")
	var previous_view := camera.transform
	for p: Dictionary in [tree_place, rock_place]:
		var overlay: MeshInstance3D = layer._highlight if p.rock else layer._painted[p.key]
		overlay.position = Vector3(0.7 if p.rock else -0.7, 0.05, 0.0)
		var original := MeshInstance3D.new()
		original.mesh = overlay.mesh
		original.transform = overlay.transform
		var material := StandardMaterial3D.new()
		material.albedo_color = Color("#666969") if p.rock else Color("#624b36")
		original.material_override = material
		layer.add_child(original)
	camera.look_at_from_position(Vector3(0.1, 1.65, 4.0), Vector3(0.1, 1.10, 0.0), Vector3.UP)
	await _shot("quest_paint_objects")
	layer.sync({tree_place.key: true, rock_place.key: true}, {})
	var painted_rock: MeshInstance3D = layer._painted[rock_place.key]
	painted_rock.position = Vector3(0.7, 0.05, 0.0)
	_check(layer._highlight == null and layer.item(eye, GameWorld.REACH).is_empty(),
		"после разметки подсветка и взаимодействие исчезают, краска на камне остаётся")
	await _shot("quest_painted_objects")
	camera.transform = previous_view
	layer.queue_free()
	vegetation.free()


static func home_key(home: Variant) -> String:
	return WorldData.place_id("settlement", home.x, home.y)


## 19.11.2026: щит доски в мире (BoardDisplay): рисуется в текстуру один раз, потом ничего не делает каждый кадр
func _board_in_world(home: SettlementData, quests: Quests, picked: Array) -> void:
	hud.settlement_panel.hide()
	hud.visible = false
	var at := Transform3D(Basis.IDENTITY, Vector3(30.0, 0.0, 0.0))
	var panel := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1.8, 0.95, 0.13)
	panel.mesh = box
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.25, 0.17, 0.11)
	panel.material_override = wood
	var face := at.translated_local(Vector3.UP * 1.35)
	panel.transform = face
	root.add_child(panel)
	var label := Label3D.new()
	label.text = "МАРШРУТЫ"
	label.transform = face.translated_local(Vector3(0, 0, 0.08))
	root.add_child(label)
	var display := preload("res://scripts/render/board_display.gd").new()
	root.add_child(display)
	var offers_calls := [0]
	display.setup(world, quests, hud.map_data, func() -> Array: return [{at = face, place = home, label = label}],
		func(_place: Variant) -> Array:
			offers_calls[0] += 1
			return picked,
		func(place: Variant) -> Array: return hud.board_places(place))
	var cam := camera.global_transform
	camera.look_at_from_position(face * Vector3(0.0, 0.05, 2.1), face.origin, Vector3.UP)
	var far_eye := face * Vector3(0.0, 0.0, 60.0)
	display.tick(far_eye)
	_check(display.builds == 0 and not display._quad.visible and display.live_work() == 0, "дальняя доска: щита с заданиями нет, работы нет")
	var eye := face * Vector3(0.0, 0.0, 2.0)
	display._next_check_ms = 0  # проверка раз в CHECK_S — в стенде без ожидания
	var t0 := Time.get_ticks_usec()
	display.tick(eye)
	print("BOARD_BUILD_MS=%.2f" % ((Time.get_ticks_usec() - t0) / 1000.0))
	_check(display.builds == 1 and not label.visible, "у доски щит нарисован, надпись «МАРШРУТЫ» спрятана")
	var worst := 0.0
	var frames := 0
	for i in 60:
		if not display._steps.is_empty():
			var t1 := Time.get_ticks_usec()
			display._process(0.0)
			worst = maxf(worst, (Time.get_ticks_usec() - t1) / 1000.0)
		await process_frame
		frames += 1
		if display.live_work() == 0:
			break
	print("BOARD_STEP_MAX_MS=%.2f BOARD_FRAMES=%d" % [worst, frames])
	await _shot("quest_board_world")
	_check(display.live_work() == 0 and display._viewport.process_mode == Node.PROCESS_MODE_DISABLED,
		"готовый щит: ни обработки, ни перерисовки вьюпорта")
	display._next_check_ms = 0
	display.tick(eye)
	_check(display.builds == 1 and offers_calls[0] == 1, "повторная проверка у той же доски ничего не пересобирает")
	quests.changed.emit()
	display.tick(eye)  # invalidate() сбрасывает ожидание проверки
	_check(display.builds == 2, "задания изменились — щит перерисован один раз")
	for i in 60:
		await process_frame
		if display.live_work() == 0:
			break
	display._next_check_ms = 0
	display.tick(far_eye)
	_check(label.visible and not display._quad.visible, "отъехал — щит погас, надпись вернулась")
	display.queue_free()
	panel.queue_free()
	label.queue_free()
	camera.global_transform = cam
	hud.visible = true


func _shot(name: String) -> void:
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out.path_join(name + ".png"))


## Сцена: небо, земля, велосипед с седоком и сумкой, сумка на земле; интерфейс игры из main.tscn без мира
func _build() -> BikeView:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.environment.background_mode = Environment.BG_SKY
	env.environment.sky = sky
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, 30.0, 0.0)
	sun.shadow_enabled = true
	root.add_child(sun)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(200, 200)
	ground.mesh = plane
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.35, 0.5, 0.28)
	ground.material_override = m
	root.add_child(ground)
	var bike: BikeView = load("res://scenes/bike.tscn").instantiate()
	root.add_child(bike)
	var bag := preload("res://scripts/render/cargo_bag.gd").build()
	bag.position = Vector3(-1.4, 0.26, -0.6)
	bag.rotation.y = 0.5
	root.add_child(bag)
	camera = Camera3D.new()
	root.add_child(camera)
	camera.look_at_from_position(Vector3(1.7, 1.6, 2.4), Vector3(-0.3, 0.9, 0.0), Vector3.UP)
	camera.current = true
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	return bike


func _run() -> void:
	_logic()
	_shop_save()
	_beacon_quest()
	_paint_quest()
	if "--logic-only" in OS.get_cmdline_user_args():
		quit(1 if failed else 0)
		return
	var bike := _build()
	await process_frame
	bike.rider.pose(0.6, 0.3, Vector3(-0.24, 0.98, -0.43), Vector3(0.24, 0.98, -0.43))
	hud = main.get_node("UI/Root/Hud")
	for path: String in ["UI/Root/Back", "UI/Root/Menu"]:
		main.get_node(path).visible = false
	bike.hide()
	await _paint_look()
	bike.show()
	hud.visible = true
	hud.lock_hint.visible = false
	var quests := Quests.new()
	hud.quests = quests
	hud.set_world(world, null)
	hud.set_player(400.0, 400.0, 0.3)
	hud.set_map_visible(true)
	_check(hud.big_map.places.is_empty(), "личная карта не показывает неизвестные места")
	hud.set_map_visible(false)
	var home: SettlementData = world.settlements[0]
	var offers := _offers(quests)
	var pins := hud.board_places(home)
	hud.settlement_panel.open(home, world, pins, true, quests, offers, hud.map_data)
	var buttons: Array[Node] = hud.settlement_panel.find_children("*", "Button", true, false)
	# 19.11.2026: листков не больше трёх (Quests.BOARD_OFFERS) + карточка серии обелисков
	_check(buttons.filter(func(b: Button) -> bool: return b.text.begins_with("Взять")).size() == Quests.BOARD_OFFERS + 1, "на доске три листка и серия обелисков")
	var picked := Quests.board_pick(offers, home_key(home), 0)
	var kinds := {}
	for q: QuestData in picked:
		kinds[q.kind] = true
	_check(picked.size() == Quests.BOARD_OFFERS and kinds.size() == Quests.BOARD_OFFERS and Quests.board_pick(offers, home_key(home), 0) == picked,
		"отбор доски: три задания разных видов, устойчиво")
	_check(Quests.board_pick(offers, home_key(home), 0, offers[6].id).has(offers[6]), "взятое задание остаётся среди листков")
	_check(pins.size() == 3 and pins[1].name == "Колодец" and pins[2].name == "Тихое", "на доске два ближайших места")
	var travels := []
	hud.settlement_panel.travel_requested.connect(hud.ask_travel)
	hud.travel_requested.connect(func(place: Dictionary) -> void: travels.append(place.key))
	var transfer: Button = buttons.filter(func(b: Button) -> bool: return b.text.begins_with("Тихое"))[0]
	transfer.pressed.emit()
	_check(travels.is_empty() and hud._travel_dialog != null, "перемещение с доски требует подтверждения")
	hud._travel_dialog.confirmed.emit()
	_check(travels == [_place("Тихое").key], "подтверждение передаёт выбранное место")
	await _shot("quest_board")
	_check(hud.get_global_rect().encloses(hud.settlement_panel.get_global_rect()), "доска помещается на экране 720 px")
	await _board_in_world(home, quests, picked)
	# взять маяки кнопкой: текущее задание со шагами и «Отказаться»
	var accepted := []
	hud.settlement_panel.quest_accepted.connect(func(q: QuestData) -> void: accepted.append(q))
	for b: Button in buttons:
		if b.tooltip_text == "Взять задание: " + Quests.KINDS[offers[0].kind].title.to_lower():
			b.pressed.emit()
			break
	_check(accepted.size() == 1 and accepted[0].kind == "beacons", "кнопка «Взять» отдаёт задание на маяки")
	quests.accept(accepted[0])
	hud.settlement_panel.open(home, world, pins, true, quests, offers, hud.map_data)
	buttons = hud.settlement_panel.find_children("*", "Button", true, false)
	_check(buttons.any(func(b: Button) -> bool: return b.text == "Отказаться от задания") and buttons.filter(func(b: Button) -> bool: return b.text.begins_with("Взять")).size() == 1,
		"с текущим заданием — «Отказаться»; взять можно только серию летописи, она идёт параллельно")
	await _shot("quest_board_active")
	var dropped := [0]
	hud.settlement_panel.quest_abandoned.connect(func() -> void: dropped[0] += 1)
	var drop: Button = buttons.filter(func(b: Button) -> bool: return b.text == "Отказаться от задания")[0]
	drop.pressed.emit()
	_check(dropped[0] == 0 and drop.text.begins_with("Точно"), "отказ — первое нажатие только переспрашивает")
	drop.pressed.emit()
	_check(dropped[0] == 1, "второе нажатие отказывается")
	hud.settlement_panel.hide()
	hud.set_map_visible(true)
	_check(not hud.big_map.quest.is_finite(), "карта не показывает площадку до получения сумки")
	quests.pick_up()
	hud.quest_changed()
	var first_marker := hud.big_map.quest
	_check(first_marker == Hud.Atlas.place_at(quests.goal()), "на большой карте видна первая площадка")
	quests.install_beacon(quests.goal().key)
	hud.quest_changed()
	_check(hud.big_map.quest != first_marker and hud.big_map.quest == Hud.Atlas.place_at(quests.goal()),
		"метка на карте переключается на следующий маяк")
	await _shot("quest_beacon_map")
	quests.accept(_by_kind(offers, "paint"))
	hud.quest_changed()
	_check(not hud.big_map.quest.is_finite(), "до сумки карта не выдаёт объекты разметки")
	quests.pick_up()
	hud.quest_changed()
	_check(hud.big_map.quest == Hud.Atlas.place_at(quests.goal()), "на карте виден только текущий объект разметки")
	hud.set_map_visible(false)
	quests.accept(_by_kind(offers, "supplies"))
	await _personal_map()
	# сумка за спиной седока и счётчик
	quests.pick_up()
	bike.set_pack(quests.cargo)
	hud.px = 100 * GameConfig.TILE
	hud.pz = 100 * GameConfig.TILE
	for i in 2:
		await process_frame
	# 18.11.2026: игра начинается в лёгком виде (только мини-карта) — счётчик задания виден в полном
	hud.view_mode = Hud.View.FULL
	hud._revealed = true
	hud._summary_progress = 1.0
	hud.update_tracker()
	_check(hud.tracker.visible and hud._tracker_note.text.contains("сумка за спиной"), "счётчик: шаг и сумка за спиной")
	var pack := bike.rider.skeleton.get_node_or_null("Pack") as Node3D
	_check(pack != null and pack.visible, "сумка висит на седоке")
	await _shot("quest_pack")
	camera.look_at_from_position(Vector3(2.6, 1.3, 0.2), Vector3(0.0, 1.0, 0.1), Vector3.UP)
	await _shot("quest_pack_side")
	camera.look_at_from_position(Vector3(1.7, 1.6, 2.4), Vector3(-0.3, 0.9, 0.0), Vector3.UP)
	hud.set_photo_mode(true)
	_check(not hud.tracker.visible, "в видоискателе счётчика нет")
	hud.set_photo_mode(false)
	hud.toast("Задание выполнено\nПосылка: «Каменка»", &"quest")
	quests.cargo = false
	bike.set_pack(false)
	for i in 30:
		await process_frame
	_check(hud.toast_label.text.begins_with("Задание выполнено"), "о выполнении задания сообщает HUD")
	await _shot("quest_done")
	print("quest_look: %s, снимки в %s" % ["FAIL %d" % failed if failed else "ok", out])
	quit(1 if failed else 0)


func _personal_map() -> void:
	var short_ride := Hud.Journal.new()
	short_ride.record(Vector2.ZERO, 0.1)
	short_ride.record(Vector2(2, 0), 0.1)
	var short_save := short_ride.save_state()
	_check(short_ride.current.size() == 1, "сохранение короткого трека не меняет текущую запись")
	short_ride.record(Vector2(900, 0), 0.1)
	var short_track := short_ride.save_state()
	_check(short_save.legs.size() == 1 and short_save.legs[0][-1] == Vector2(2, 0)
		and short_track.legs == short_save.legs and is_equal_approx(short_track.foot + short_track.bike, 2.0),
		"короткая поездка сохраняется, скачок координат не попадает в трек")
	var trail := hud.map_journal
	for i in 25:
		trail.record(Vector2(201 + i * 9, 464 - i * 3), 0.3)
	trail.end_trip() # перенос
	for i in 22:
		trail.record(Vector2(534 + i * 6, 442 + i * 3.7), 0.3)
	var state: Dictionary = bytes_to_var(var_to_bytes(EntityCodec.encode(trail.save_state())))
	_check(Hud.Journal.valid(state) and state.legs.size() == 2 and state.legs[0][-1].distance_to(state.legs[1][0]) > 100.0,
		"сохранение содержит раздельные части поездки вокруг телепорта")
	trail.restore(state)
	_check(trail.current.is_empty() and trail.read.size() == 3 and trail.distance > 350.0, "трек и открытия восстанавливаются при загрузке")
	hud.visited[_place("Каменка").key] = true
	hud.sync_map_places() # как в игре после открытия места: список карты пересобирается только по сигналу
	hud.set_map_visible(true)
	# посещённые и прочитанные на доске + место взятого задания (вышка «Сторожевая»): оно видно на карте сквозь туман ориентиров
	_check(hud.big_map.places.size() == 5 and hud.big_map.places.any(func(p: Dictionary) -> bool: return p.name == "Сторожевая") and not hud.big_map.places.any(func(p: Dictionary) -> bool: return p.name == "Седая"),
		"личная карта показывает посещённые, прочитанные и названные заданием места")
	var cursor := Vector2(630.0, 320.0)
	var before := hud.big_map.screen_to_world(cursor)
	hud.big_map._zoom_at(cursor, 1.1)
	_check(before.distance_to(hud.big_map.screen_to_world(cursor)) < 0.01, "масштабирование удерживает место под курсором")
	await _shot("personal_map")
	hud.set_map_visible(false)
