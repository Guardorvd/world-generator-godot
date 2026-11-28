extends "res://tools/hud_look.gd"
## 19.11.2026: цена HUD без мира — те же вызовы, что GameWorld делает каждый кадр (стоя, езда в лёгком и
## полном виде, торможение). Печатает мкс скрипта HUD на кадр (среднее и худший) и сколько узлов HUD
## перерисовалось за кадр (сигнал draw). Нужно окно, ~15 с:
##   godot --path . --script res://tools/hud_cost.gd

const FRAMES := 240

var _draws := {}
var _part := {}
var _hints_riding := -1


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	root.size = Vector2i(1280, 720)
	_cost()


func _watch(node: Node) -> void:
	if node is CanvasItem:
		var key := str(node.get_path()).trim_prefix("/root/Main/UI/Root/Hud")
		node.draw.connect(func() -> void: _draws[key] = _draws.get(key, 0) + 1)
	for child in node.get_children():
		_watch(child)


func _cost() -> void:
	_build()
	await process_frame
	hud = main.get_node("UI/Root/Hud")
	for path: String in ["UI/Root/Back", "UI/Root/Menu"]:
		main.get_node(path).visible = false
	hud.visible = true
	hud.lock_hint.visible = false
	var world := _map_fixture()
	var map := Image.create(128, 128, false, Image.FORMAT_RGB8)
	map.fill(Color(0.85, 0.88, 0.9))
	hud.set_world(world, map)
	hud.quests = Hud.Quests.new()
	var delivery := QuestData.new("hud", "delivery")
	delivery.title = "Письма для Каменки"
	delivery.steps.append({do = "pickup", place = {name = "Ольховка", kind = "settlement", x = 126, y = 114}})
	delivery.steps.append({do = "carry", place = {name = "Каменка", kind = "settlement", x = 139, y = 120}})
	delivery.step = 1
	hud.quests.active = delivery
	hud.quests.cargo = true
	hud.quest_changed()
	hud.set_goal(Hud.marker_goal(Vector2(160, 100)))
	hud.set_process(false) # _process HUD вызываем сами внутри замера
	_watch(hud)
	var player := PlayerState.new()
	player.feet = 1240
	var stamina := Stamina.new()
	var bike := BikeRide.new()
	for scene in ["стоя, HUD скрыт", "езда, HUD скрыт", "езда, Tab", "езда с торможением, Tab"]:
		var riding: bool = scene != "стоя, HUD скрыт"
		hud._summary_held = scene.ends_with("Tab")
		bike.riding = riding
		bike.speed = 9.0 if riding else 0.0
		bike.brake_pressure = 0.8 if scene.begins_with("езда с торможением") else 0.0
		bike.brake_skid = 0.4 if scene.begins_with("езда с торможением") else 0.0
		var x := 512.0
		var z := 512.0
		var heading := 0.3
		var info_timer := 0.0
		var hour := 5.5
		for f in 30: # разгон: появления и затухания
			await _frame(f, riding, bike, stamina, player, x, z, heading, hour, info_timer)
		_draws.clear()
		_part.clear()
		var total := 0
		var worst := 0
		for f in FRAMES:
			if riding:
				x += 0.15
				z -= 0.05
				heading += 0.004 * sin(f * 0.05)
			hour += 1.0 / 3600.0
			info_timer -= 1.0 / 60.0
			var t0 := Time.get_ticks_usec()
			info_timer = _calls(riding, bike, stamina, player, x, z, heading, hour, info_timer)
			var spent := Time.get_ticks_usec() - t0
			total += spent
			worst = maxi(worst, spent)
			await process_frame
		var redraws := 0
		for key: String in _draws:
			redraws += _draws[key]
		var top := _draws.keys()
		top.sort_custom(func(a: String, b: String) -> bool: return _draws[a] > _draws[b])
		var lines := PackedStringArray()
		for key: String in top.slice(0, 6):
			lines.append("%s %.2f" % [key if not key.is_empty() else "Hud", _draws[key] / float(FRAMES)])
		print("%-36s скрипт %5.1f мкс/кадр (худший %4d)  перерисовок %.2f/кадр: %s" % [scene, total / float(FRAMES), worst,
			redraws / float(FRAMES), ", ".join(lines)])
		var parts := PackedStringArray()
		for key: String in _part:
			parts.append("%s %.1f" % [key.trim_prefix("hud."), _part[key] / float(FRAMES)])
		print("    по вызовам, мкс/кадр: ", ", ".join(parts))
	quit(0)


func _frame(_f: int, riding: bool, bike: BikeRide, stamina: Stamina, player: PlayerState, x: float, z: float,
		heading: float, hour: float, info_timer: float) -> void:
	_calls(riding, bike, stamina, player, x, z, heading, hour, info_timer)
	await process_frame


## Как GameWorld._process: блокировка сводки, силы, тормоз, подсказки, сведения раз в 0,15 с, игрок, велосипед, часы
func _calls(riding: bool, bike: BikeRide, stamina: Stamina, player: PlayerState, x: float, z: float,
		heading: float, hour: float, info_timer: float) -> float:
	var dt := 1.0 / 60.0
	var _t_3 := Time.get_ticks_usec()
	hud.set_summary_blocked(false)
	_part["hud.set_summary_blocked"] = _part.get("hud.set_summary_blocked", 0) + Time.get_ticks_usec() - _t_3
	if riding:
		stamina.tick_ride(dt, false, 0.6, false)
	else:
		stamina.tick_foot(dt, false)
	var _t_10 := Time.get_ticks_usec()
	hud.set_stamina(stamina.value, stamina.exhausted, stamina.state)
	_part["hud.set_stamina"] = _part.get("hud.set_stamina", 0) + Time.get_ticks_usec() - _t_10
	var _t_13 := Time.get_ticks_usec()
	hud.set_brakes(bike)
	_part["hud.set_brakes"] = _part.get("hud.set_brakes", 0) + Time.get_ticks_usec() - _t_13
	# как GameWorld с 19.11.2026: подсказки пересобираются только при смене обстановки (езда или пешком)
	if int(riding) != _hints_riding:
		_hints_riding = int(riding)
		var k: Callable = hud.controls.label
		if riding:
			hud.set_hints([[k.call("run"), "Сильнее"], [k.call("jump"), "Прыжок"], [k.call("interact"), "Слезть"], [k.call("recover_bike"), "Поставить велосипед"]], [])
		else:
			hud.set_hints([[k.call("run"), "Бег"], [k.call("jump"), "Прыжок"], ["ПКМ", "Фотоаппарат"], [k.call("recover_bike"), "Поставить велосипед"]], [])
	if hud.summary_requested() and info_timer <= 0.0:
		info_timer = 0.15
		player.x = x
		player.z = z
		var _t_29 := Time.get_ticks_usec()
		hud.update_info(player, heading, 0.0)
		_part["hud.update_info"] = _part.get("hud.update_info", 0) + Time.get_ticks_usec() - _t_29
	var _t_32 := Time.get_ticks_usec()
	hud.set_player(x, z, heading)
	_part["hud.set_player"] = _part.get("hud.set_player", 0) + Time.get_ticks_usec() - _t_32
	var _t_35 := Time.get_ticks_usec()
	hud.set_bike(x - 3.0, z, not riding)
	_part["hud.set_bike"] = _part.get("hud.set_bike", 0) + Time.get_ticks_usec() - _t_35
	var _t_38 := Time.get_ticks_usec()
	hud.set_clock(hour)
	_part["hud.set_clock"] = _part.get("hud.set_clock", 0) + Time.get_ticks_usec() - _t_38
	var _t_41 := Time.get_ticks_usec()
	hud.set_repair(0.0)
	_part["hud.set_repair"] = _part.get("hud.set_repair", 0) + Time.get_ticks_usec() - _t_41
	var _t_44 := Time.get_ticks_usec()
	hud._process(dt)
	_part["hud._process"] = _part.get("hud._process", 0) + Time.get_ticks_usec() - _t_44
	return info_timer
