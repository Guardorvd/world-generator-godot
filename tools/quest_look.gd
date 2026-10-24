extends SceneTree
## 11.9: изолированная сцена заданий без генерации мира. Несколько мест словарями и WorldData только со списками
## мест — для доски. Проверяет Quests: три вида на доске, устойчивость выбора, шаги доставки (сумка), снимка
## (нужное место в прицеле) и посещения, отказ, выполненное не предлагается снова. Снимает доску с вкладкой
## заданий, доску с текущим заданием и седока с сумкой за спиной со счётчиком задания. Нужно окно.
##   godot --path . --script res://tools/quest_look.gd -- [--out <папка>]

const Quests = preload("res://scripts/game/quests.gd")
const SettlementPanel = preload("res://scripts/ui/settlement_panel.gd")

var out := ""
var failed := 0
var world := WorldData.new()
var main: Node
var camera: Camera3D
var hud: Hud
var places: Array = []
var at := Vector2.ZERO  # где игрок, клетки


func _initialize() -> void:
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
	world.sites = [{x = 130, y = 40, i = 4, name = "Сторожевая", type = "tower", rank = 2}, {x = 105, y = 104, i = 5, name = "Колодец", type = "tower", rank = 2}]
	for kind: String in WorldData.PLACE_KINDS:
		for src: Variant in world.get(kind + "s"):
			places.append(SettlementPanel._target(world.place(WorldData.place_id(kind, src.x, src.y))))
	_run()


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
	return quests.offers(_place("Ольховка"), places, [_place("Каменка")], {}, {}, 7)


func _arrived(place: Dictionary) -> bool:
	return Vector2(place.x, place.y).distance_to(at) < 5.0


func _by_kind(list: Array, kind: String) -> QuestData:
	for q: QuestData in list:
		if q.kind == kind:
			return q
	return QuestData.new()


func _logic() -> void:
	var quests := Quests.new()
	var offers := _offers(quests)
	var kinds := offers.map(func(q: QuestData) -> String: return q.kind)
	_check(kinds.size() == 3 and kinds[0] in Quests.CARGO_KINDS and kinds[1] in ["photo", "chronicle"] and kinds[2] in ["visit", "tour"], "доска предлагает доставку, снимок и посещение или обход (%s)" % ", ".join(PackedStringArray(kinds)))
	_check(offers == _offers(quests), "те же задания при повторном открытии доски")
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
	at = Vector2(150, 120)
	_check(quests.tick(_arrived) == "" and quests.cargo, "по дороге шаг не закрывается")
	at = Vector2(180, 130)
	var text := quests.tick(_arrived)
	_check(text.begins_with("Задание выполнено") and not quests.cargo and quests.active.is_empty() and quests.done == 1, "сумка доставлена — задание выполнено, сумки нет")
	_check(not _offers(quests).any(func(q: QuestData) -> bool: return q.id == delivery.id), "выполненная доставка больше не предлагается")
	# снимок: только нужное место в прицеле, потом отвезти
	var photo := Quests._make("photo", _place("Ольховка"), [_place("Седая"), _place("Каменка")])
	quests.accept(photo)
	_check(quests.step().do == "shoot" and quests.goal().key == photo.target.key, "снимок: цель — место съёмки")
	_check(quests.known.has(photo.target.key) and quests.known.has(quests.active.steps[1].place.key), "взятое задание открывает названия своих мест")
	_check(quests.photographed("") == "" and quests.photographed("peak:0:0") == "", "снимок без места или чужого места не засчитан")
	_check(quests.photographed(photo.target.key, Quests.SHOT_REACH + 50.0) == "" and quests.step().do == "shoot", "снимок издалека не засчитан")
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
	var broken := quests.crashed()
	_check(broken != "" and not quests.cargo and quests.step().do == "pickup", "падение с хрупким грузом — груз разбит, снова к доске")
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
	var texts := {}
	for kind: String in ["delivery", "fragile", "visit"]:
		for p: Dictionary in places:
			if p.kind != "settlement" or kind == "visit":
				texts[Quests._make(kind, _place("Ольховка"), [p, p, p]).title.split("«")[0]] = true
	_check(texts.size() >= 6, "формулировки разные (%d): %s" % [texts.size(), ", ".join(PackedStringArray(texts.keys()))])
	var saved := quests.save_state()
	_check(Quests.valid_save(saved), "сохранение после новых видов проходит проверку")


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
	var bike := _build()
	await process_frame
	bike.rider.pose(0.6, 0.3, Vector3(-0.24, 0.98, -0.43), Vector3(0.24, 0.98, -0.43))
	hud = main.get_node("UI/Root/Hud")
	for path: String in ["UI/Root/Back", "UI/Root/Menu"]:
		main.get_node(path).visible = false
	hud.visible = true
	hud.lock_hint.visible = false
	var quests := Quests.new()
	hud.quests = quests
	# доска с вкладкой заданий
	var home: SettlementData = world.settlements[0]
	var offers := _offers(quests)
	hud.settlement_panel.open(home, world, [], true, quests, offers)
	var buttons: Array[Node] = hud.settlement_panel.find_children("*", "Button", true, false)
	_check(buttons.filter(func(b: Button) -> bool: return b.text.begins_with("Взять")).size() == 3, "на доске три кнопки «Взять»")
	_check(buttons.any(func(b: Button) -> bool: return b.text.begins_with("Каменка")), "маршруты на второй вкладке")
	_check(hud.settlement_panel.size.y < root.size.y - 40, "доска помещается на экране 720 px (%d)" % hud.settlement_panel.size.y)
	await _shot("quest_board")
	# взять доставку кнопкой: текущее задание со шагами и «Отказаться»
	var accepted := []
	hud.settlement_panel.quest_accepted.connect(func(q: QuestData) -> void: accepted.append(q))
	for b: Button in buttons:
		if b.tooltip_text == "Взять задание: " + Quests.KINDS[offers[0].kind].title.to_lower():
			b.pressed.emit()
	_check(accepted.size() == 1 and accepted[0].kind in Quests.CARGO_KINDS, "кнопка «Взять» отдаёт задание")
	quests.accept(accepted[0])
	hud.settlement_panel.open(home, world, [], true, quests, offers)
	buttons = hud.settlement_panel.find_children("*", "Button", true, false)
	_check(buttons.any(func(b: Button) -> bool: return b.text == "Отказаться от задания") and not buttons.any(func(b: Button) -> bool: return b.text.begins_with("Взять")),
		"с текущим заданием — «Отказаться», новых не взять")
	await _shot("quest_board_active")
	var dropped := [0]
	hud.settlement_panel.quest_abandoned.connect(func() -> void: dropped[0] += 1)
	var drop: Button = buttons.filter(func(b: Button) -> bool: return b.text == "Отказаться от задания")[0]
	drop.pressed.emit()
	_check(dropped[0] == 0 and drop.text.begins_with("Точно"), "отказ — первое нажатие только переспрашивает")
	drop.pressed.emit()
	_check(dropped[0] == 1, "второе нажатие отказывается")
	hud.settlement_panel.hide()
	# сумка за спиной седока и счётчик
	quests.pick_up()
	bike.set_pack(quests.cargo)
	hud.px = 100 * GameConfig.TILE
	hud.pz = 100 * GameConfig.TILE
	# с 12.4 счётчик виден, пока зажат Tab
	Input.action_press("show_hud")
	for i in 2:
		await process_frame
	hud.update_tracker()
	_check(hud.tracker.visible and hud._tracker_note.text.contains("сумка за спиной"), "счётчик: шаг и сумка за спиной")
	var pack := bike.rider.skeleton.get_node_or_null("Pack") as Node3D
	_check(pack != null and pack.visible, "сумка висит на седоке")
	await _shot("quest_pack")
	Input.action_release("show_hud")
	camera.look_at_from_position(Vector3(2.6, 1.3, 0.2), Vector3(0.0, 1.0, 0.1), Vector3.UP)
	await _shot("quest_pack_side")
	camera.look_at_from_position(Vector3(1.7, 1.6, 2.4), Vector3(-0.3, 0.9, 0.0), Vector3.UP)
	hud.set_photo_mode(true)
	_check(not hud.tracker.visible, "в видоискателе счётчика нет")
	hud.set_photo_mode(false)
	hud.quest_done("Посылка: «Каменка»")
	hud.banner("Задание выполнено", "Посылка: «Каменка» · всего выполнено: 1", Hud.GOLD)
	quests.cargo = false
	bike.set_pack(false)
	_check(hud.tracker.visible and hud._tracker_icon.texture == hud.UiIcons.CHECK, "выполненное задание видно в счётчике")
	for i in 30:
		await process_frame
	_check(hud._banner.visible and hud._banner.modulate.a > 0.9, "крупная надпись «Задание выполнено» посередине")
	await _shot("quest_done")
	print("quest_look: %s, снимки в %s" % ["FAIL %d" % failed if failed else "ok", out])
	quit(1 if failed else 0)
