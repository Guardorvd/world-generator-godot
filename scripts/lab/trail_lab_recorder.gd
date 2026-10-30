extends RefCounted
## Запись сессии тестов в Trail Lab (30.10.2026): с первого нажатия каждый такт физики пишется всё, что видно в F3 и
## что нужно, чтобы понять заезд, не видя его: где велосипед (координаты, станция и отступ от оси трассы, элемент),
## что нажато (сырые клавиши и то, что дошло до физики), состояние, силы, колёса, подвеска, покрытие, падения.
## Сессия — все поездки подряд (R, смена трассы — только отметка «новая поездка»), пока не нажато «Сохранить запись»
## (кнопка в панели или F9): только тогда файлы попадают в проект, после сохранения начинается новая сессия.
##   ride_logs/<дата>/ride_<время начала>_p<трасса>.csv          — такт за тактом (60 Гц), колонки — в .header.json
##   ride_logs/<дата>/ride_<время начала>_p<трасса>.events.txt   — события: падения, удары колёс, отрывы и приземления,
##                                                                 тормоз, остановка с газом, элементы, клавиши, F3/F2/V, поездки
##   ride_logs/<дата>/ride_<время начала>_p<трасса>.header.json  — версия кода, трасса и её элементы, настройки, константы физики
##   ride_logs/<дата>/ride_<время начала>_p<трасса>.summary.txt  — краткая сводка сессии
## До сохранения запись идёт во временные файлы user://ride_log_unsaved (не в проекте): закрыли игру без «Сохранить» —
## в проект ничего не попало, временные файлы пережили сбой, но следующая сессия их перезапишет.
## Пустые сессии (ничего не нажато, велосипед не ехал) не пишутся. В headless (тесты) запись выключена:
## enabled = true, папки — root (проект) и temp_root (временные).

const ROOT := "res://ride_logs"
const TEMP := "user://ride_log_unsaved"
const FLUSH_EVERY := 60       # тактов между сбросами CSV на диск
const PENDING_MAX := 1800     # строк, которые ждут первой активности (30 с)
const STUCK_SPEED := 0.3      # м/с: медленнее — стоит
const STUCK_TIME := 1.5       # с с газом на месте — событие «стоит»

var enabled := DisplayServer.get_name() != "headless"
var root := ROOT
var temp_root := TEMP
var path := ""                 # общее начало имён файлов последней сохранённой сессии

var _columns := PackedStringArray()
var _format := ""
var _session := false          # сессия идёт (даже если файл ещё не создан)
var _file: FileAccess
var _events: FileAccess
var _pending := PackedStringArray()
var _pending_events := PackedStringArray()
var _t := 0.0                  # секунды с начала сессии
var _ride := 0                 # номер поездки в сессии (R — новая)
var _ride_t := 0.0
var _rides: Array = []
var _stamp := {}               # время создания файла: по нему имя при сохранении
var _preset := 0
var _ticks := 0
var _last_wall := 0
var _stats := {}
var _prev := {}
var _stuck := 0.0
var _stuck_reported := false
var _event_counts := {}
var _event_lines := PackedStringArray() # первые события для сводки
static var _git := ""


func _init() -> void:
	var rows := [
		["t", "f3"], ["ride", "i"], ["ride_t", "f3"], ["tick", "i"], ["wall_ms", "f1"], ["fps", "i"],
		["x", "f3"], ["y", "f3"], ["z", "f3"], ["heading_deg", "f2"], ["station", "f2"], ["lateral", "f3"], ["line_err_deg", "f2"],
		["on_route", "i"], ["element", "i"], ["player_x", "f3"], ["player_z", "f3"],
		["riding", "i"], ["airborne", "i"], ["crashed", "i"], ["crash_phase", "i"], ["fallen", "i"], ["state", "s"],
		["in_fwd", "f2"], ["in_steer", "f2"], ["in_jump", "i"], ["in_run", "i"], ["in_q", "i"], ["in_e", "i"], ["in_pump", "i"],
		["in_interact", "i"], ["in_lmb", "i"], ["in_rmb", "i"],
		["throttle", "f3"], ["turn", "f3"], ["run_applied", "i"], ["jump_applied", "i"], ["autopilot", "s"],
		["f3_open", "i"], ["editor_open", "i"], ["overview", "i"], ["cam_yaw_deg", "f1"], ["cam_pitch_deg", "f1"],
		["speed", "f3"], ["lateral_speed", "f3"], ["accel", "f3"], ["feel_accel", "f3"], ["vy", "f3"], ["air_time", "f3"],
		["steer", "f3"], ["yaw_rate", "f3"], ["slip_deg", "f2"], ["lean_deg", "f2"], ["tilt_deg", "f2"], ["bank_slope", "f3"], ["vertical_g", "f3"],
		["effort", "f3"], ["drive_request", "f3"], ["drive", "f3"], ["brake_pressure", "f3"], ["brake_decel", "f3"], ["brake_f", "f3"], ["brake_r", "f3"],
		["roll_loss", "f3"], ["air_loss", "f3"], ["rough_loss", "f3"], ["slope_force", "f3"], ["pump_force", "f3"], ["grade_geo", "f4"], ["grade_f3", "f4"],
		["front_load", "f3"], ["skid", "f3"], ["brake_risk", "f3"], ["brake_lift", "f3"], ["brace", "f3"],
		["pump_pressed", "i"], ["pump_active", "f3"], ["pump_wave", "f3"], ["pump_body", "f3"], ["pump_accel", "f3"], ["pump_motion", "f3"], ["pump_reach", "f3"],
		["body_x", "f3"], ["body_v", "f3"], ["unweight", "f3"], ["lift_f", "f3"], ["lift_r", "f3"], ["hop_used", "i"], ["hop_height", "f3"],
		["load_f", "f3"], ["load_r", "f3"], ["tire_f", "f3"], ["tire_r", "f3"], ["side_f", "f3"], ["side_r", "f3"], ["slick_f", "f2"], ["slick_r", "f2"],
		["use_f", "f3"], ["use_r", "f3"], ["grip_usage", "f3"], ["force_f_long", "f3"], ["force_f_side", "f3"], ["force_r_long", "f3"], ["force_r_side", "f3"],
		["contact_f", "i"], ["contact_r", "i"], ["on_obstacle_f", "i"], ["on_obstacle_r", "i"],
		["squash_f", "f4"], ["squash_r", "f4"], ["squash_fv", "f3"], ["squash_rv", "f3"], ["bottom_out", "f3"], ["land_impact", "f3"],
		["wheel_impact_f", "f3"], ["wheel_impact_r", "f3"], ["hit_dv_f", "f3"], ["hit_dv_r", "f3"], ["impacts_f", "i"], ["impacts_r", "i"],
		["surface", "s"], ["surface_weight", "f2"], ["surface_across", "f2"], ["stamina", "f3"], ["exhausted", "i"],
	]
	var parts := PackedStringArray()
	for row: Array in rows:
		_columns.append(row[0])
		parts.append({"f1": "%.1f", "f2": "%.2f", "f3": "%.3f", "f4": "%.4f", "i": "%d", "s": "%s"}[row[1]])
	_format = ",".join(parts)


## Начало поездки (R, смена трассы, запуск элемента): в сессии это только отметка; сессия начинается с первой поездки
func begin(lab, reason: String) -> void:
	if not enabled: return
	if not _session: _start_session()
	_ride += 1
	_ride_t = 0.0
	_last_wall = 0 # пересборка трассы перед поездкой — не долгий кадр езды
	_stuck = 0.0
	_stuck_reported = false
	_prev = {}
	_preset = lab.preset
	var near: Vector3 = lab.routes[lab.lane].nearest(Vector2(lab.bike.x, lab.bike.z))
	var info := {n = _ride, t = _t, tick = _ticks, reason = reason, preset = lab.preset + 1, route = lab.routes[lab.lane].title,
		station = near.x if is_finite(near.z) else -1.0, speed = lab.bike.speed, x = lab.bike.x, z = lab.bike.z}
	_rides.append(info)
	if _ride > 1: _event("НОВАЯ ПОЕЗДКА", info)
	_stats.last = Vector2(lab.bike.x, lab.bike.z)


func _start_session() -> void:
	_session = true
	_t = 0.0
	_ride = 0
	_ride_t = 0.0
	_rides = []
	_ticks = 0
	_last_wall = 0
	_pending.clear()
	_pending_events.clear()
	_stuck = 0.0
	_stuck_reported = false
	_event_counts = {}
	_event_lines = PackedStringArray()
	_stats = {distance = 0.0, top = 0.0, air = 0.0, fwd = 0.0, back = 0.0, left = 0.0, right = 0.0, q = 0.0, e = 0.0, pump = 0.0, run = 0.0,
		jumps = 0, crashes = 0, stuck = 0.0, surfaces = {}, peak_slip = 0.0, peak_grip = 0.0, peak_decel = 0.0,
		min_fps = 1000, slow_ticks = 0, last = Vector2.ZERO}
	_prev = {}
	_stamp = {}


## Есть ли что сохранять: файл создан (в сессии что-то началось)
func has_data() -> bool:
	return enabled and _session and _file != null


## Секунд записано в сессии (для надписи на кнопке)
func seconds() -> float:
	return _t if has_data() else 0.0


## Клавиши и кнопки мыши — в события (лаборатория зовёт из _input)
func note_input(event: InputEvent) -> void:
	if not enabled or not _session: return
	if event is InputEventKey and not event.echo:
		var key: int = event.physical_keycode if event.physical_keycode != 0 else event.keycode
		_event("клавиша", {key = OS.get_keycode_string(key), down = event.pressed})
	elif event is InputEventMouseButton:
		_event("мышь", {button = event.button_index, down = event.pressed})
	elif event is InputEventJoypadButton:
		_event("геймпад", {button = event.button_index, down = event.pressed})


## Конец такта физики лаборатории: throttle — педали и тормоз после выносливости, turn — руль, как они дошли до физики
func tick(lab, dt: float, throttle: float, turn: float, run: bool, jump: bool) -> void:
	if not enabled or lab.bike == null: return
	if not _session: begin(lab, "сессия началась без R")
	# номер трассы известен только после пересборки: уточняем в первом такте поездки
	if _ride_t == 0.0 and not _rides.is_empty():
		_rides[-1].preset = lab.preset + 1
		_rides[-1].route = lab.routes[lab.lane].title
	var bike: BikeRide = lab.bike
	var now := Time.get_ticks_usec()
	var wall_ms := (now - _last_wall) / 1000.0 if _last_wall > 0 else dt * 1000.0
	_last_wall = now
	_t += dt
	_ride_t += dt
	_ticks += 1
	var raw := _raw_input()
	var route: TrailDefinition = lab.routes[lab.lane]
	var here := Vector2(bike.x, bike.z)
	var near: Vector3 = route.nearest(here)
	var on_route := is_finite(near.z)
	var contact := RideSurface.sample(lab.heights.world, lab.heights, bike.x, bike.z)
	var surface := "вне трассы" if contact.surface == 0 else str(RoadSurface.LIST[contact.surface].name)
	var phase: int = lab.crash.phase if lab.crash.active() else -1
	var state := "ПАДЕНИЕ" if lab.crash.active() else ("ПОЛЁТ" if bike.airborne else "ЗЕМЛЯ")
	var yaw = lab.get("_cam_yaw")
	var pitch = lab.get("_cam_pitch")
	var line_err := rad_to_deg(wrapf(bike.heading - route.heading_at(near.x), -PI, PI)) if on_route else 0.0
	var autopilot: String = lab.autopilot.style if lab.autopilot != null else ""
	var pumped = bike.get("pump_pressed")
	var values := [
		_t, _ride, _ride_t, _ticks, wall_ms, Engine.get_frames_per_second(),
		bike.x, bike.y, bike.z, rad_to_deg(bike.heading), near.x if on_route else -1.0, near.y if on_route else 0.0, line_err,
		int(on_route), lab.metrics.element, lab.player.x, lab.player.z,
		int(bike.riding), int(bike.airborne), int(bike.crashed), phase, int(bike.fallen), state,
		raw.fwd, raw.steer, int(raw.jump), int(raw.run), int(raw.q), int(raw.e), int(raw.pump), int(raw.interact), int(raw.lmb), int(raw.rmb),
		throttle, turn, int(run), int(jump), autopilot,
		int(lab.diagnostics_visible), int(lab.editor.visible), int(lab.overview), rad_to_deg(yaw) if yaw != null else 0.0, rad_to_deg(pitch) if pitch != null else 0.0,
		bike.speed, bike.lateral_speed, bike.acceleration, bike.feel_acceleration, bike.vy, bike.air_time,
		bike.steer, bike._yaw_rate, rad_to_deg(bike.slip), rad_to_deg(bike.lean), rad_to_deg(bike.tilt), bike.bank_slope, bike.vertical_g,
		bike.effort, bike.drive_request, bike.drive_force, bike.brake_pressure, bike.brake_deceleration, bike.brake_force.x, bike.brake_force.y,
		bike.roll_loss, bike.air_loss, bike.rough_loss, bike.slope_force, bike.pump_force, bike.grade_now, bike.grade(lab.heights),
		bike.brakes.front_load, bike.brakes.skid, bike.brakes.risk, bike.brakes.lift, bike.brakes.brace,
		int(pumped) if pumped != null else 0, bike.pump_active, bike.pump_wave, bike.pump_body, bike.pump_accel, bike.pump_motion, bike._pump_reach,
		bike.body_x, bike.body_v, bike.unweight, bike.lift_f, bike.lift_r, int(bike._hop_used), bike.hop_height,
		bike.load_f, bike.load_r, bike.tire_f, bike.tire_r, bike.side_f, bike.side_r, bike.slick_f, bike.slick_r,
		bike.use_f, bike.use_r, bike.grip_usage, bike.force_f.x, bike.force_f.y, bike.force_r.x, bike.force_r.y,
		int(bike.contact_f()), int(bike.contact_r()), int(bike._on_f >= 0), int(bike._on_r >= 0),
		bike.squash_f, bike.squash_r, bike.squash_fv, bike.squash_rv, bike.bottom_out, bike.land_impact,
		bike.wheel_impact.x, bike.wheel_impact.y, bike.hit_dv.x, bike.hit_dv.y, bike.impacts.x, bike.impacts.y,
		surface, contact.weight, contact.across, lab.controller.stamina.value, int(lab.controller.stamina.exhausted),
	]
	if _ticks == 1 and values.size() != _columns.size():
		push_error("Trail Lab recorder: %d значений на %d колонок" % [values.size(), _columns.size()])
		enabled = false
		return
	var line := _format % values
	if _file == null and (absf(bike.speed) > 0.2 or raw.any or absf(throttle) > 0.01 or absf(turn) > 0.01):
		_open(lab)
	if _file != null:
		_file.store_line(line)
		if _ticks % FLUSH_EVERY == 0: _file.flush()
	else:
		_pending.append(line)
		if _pending.size() > PENDING_MAX: _pending.remove_at(0)
	_track(lab, bike, route, near, on_route, surface, raw, throttle, turn, jump, wall_ms, state)


## Сырой ввод игрока: клавиши, оси и кнопки мыши в этот такт
func _raw_input() -> Dictionary:
	var raw := {
		fwd = Input.get_axis("move_back", "move_forward"), steer = Input.get_axis("move_left", "move_right"),
		jump = Input.is_action_pressed("jump"), run = Input.is_action_pressed("run"),
		q = Input.is_action_pressed("bike_back"), e = Input.is_action_pressed("bike_forward"),
		pump = InputMap.has_action("bike_pump") and Input.is_action_pressed("bike_pump"),
		interact = Input.is_action_pressed("interact"),
		lmb = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT), rmb = Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT),
	}
	raw.any = absf(raw.fwd) > 0.01 or absf(raw.steer) > 0.01 or raw.jump or raw.run or raw.q or raw.e or raw.pump or raw.lmb or raw.rmb
	return raw


## Статистика и события по смене состояния
func _track(lab, bike: BikeRide, route: TrailDefinition, near: Vector3, on_route: bool, surface: String, raw: Dictionary, throttle: float, turn: float, jump: bool, wall_ms: float, state: String) -> void:
	var here := Vector2(bike.x, bike.z)
	_stats.distance += _stats.last.distance_to(here)
	_stats.last = here
	_stats.top = maxf(_stats.top, absf(bike.speed))
	_stats.peak_slip = maxf(_stats.peak_slip, absf(bike.slip))
	_stats.peak_grip = maxf(_stats.peak_grip, bike.grip_usage)
	_stats.peak_decel = maxf(_stats.peak_decel, bike.brake_deceleration)
	# первые 2 с поездки FPS ещё помнит пересборку трассы (R, смена трассы)
	if _ride_t > 2.0: _stats.min_fps = mini(_stats.min_fps, int(Engine.get_frames_per_second()))
	var dt := 1.0 / 60.0
	if bike.airborne: _stats.air += dt
	if raw.fwd > 0.1: _stats.fwd += dt
	if raw.fwd < -0.1: _stats.back += dt
	if raw.steer < -0.1: _stats.left += dt
	if raw.steer > 0.1: _stats.right += dt
	if raw.q: _stats.q += dt
	if raw.e: _stats.e += dt
	if raw.pump: _stats.pump += dt
	if raw.run: _stats.run += dt
	if jump: _stats.jumps += 1
	_stats.surfaces[surface] = _stats.surfaces.get(surface, 0.0) + dt
	if wall_ms > 50.0:
		_stats.slow_ticks += 1
		if wall_ms > 100.0: _event("долгий кадр", {wall_ms = wall_ms})
	var station := near.x if on_route else -1.0
	# смена состояния
	var changed := func(key: String, value: Variant) -> bool:
		var was: Variant = _prev.get(key)
		_prev[key] = value
		return was != null and was != value
	if changed.call("riding", bike.riding): _event("посадка" if bike.riding else "сход с велосипеда", _where(bike, station))
	if changed.call("air", bike.airborne):
		if bike.airborne: _event("отрыв", _where(bike, station).merged({vy = bike.vy, speed = bike.speed, hop = bike._hop_used}))
		else: _event("приземление", _where(bike, station).merged({impact = bike.land_impact, speed = bike.speed, air = bike.air_time, hop_height = bike.hop_height}))
	var crashing: bool = lab.crash.active() or bike.crashed
	if changed.call("crash", crashing):
		if crashing:
			_stats.crashes += 1
			_event("ПАДЕНИЕ", _where(bike, station).merged({cause = BikeRide.CrashCause.keys()[bike.crash_cause], speed = bike.crash_velocity.length(),
				normal = bike.crash_normal, info = lab.metrics.crash_info, load_f = bike.load_f, load_r = bike.load_r, last_hit = bike.last_hit}))
		else:
			_event("падение закончено", _where(bike, station))
	if bike.wheel_impact != Vector2.ZERO:
		_event("удар колеса о кромку", _where(bike, station).merged({front = bike.wheel_impact.x, rear = bike.wheel_impact.y, last_hit = bike.last_hit}))
	if bike.bottom_out > 0.0: _event("пробой подвески", _where(bike, station).merged({speed = bike.bottom_out}))
	if changed.call("brake", bike.brake_pressure > 0.1):
		_event("тормоз" if bike.brake_pressure > 0.1 else "тормоз отпущен", _where(bike, station).merged({speed = bike.speed, pressure = bike.brake_pressure}))
	if changed.call("element", lab.metrics.element) and lab.metrics.element >= 0 and lab.metrics.element < route.elements.size():
		var e := route.elements[lab.metrics.element]
		_event("элемент", {n = lab.metrics.element + 1, name = TrailElementLibrary.title(e.profile), speed = bike.speed, station = station})
	if changed.call("f3", lab.diagnostics_visible): _event("F3 " + ("открыт" if lab.diagnostics_visible else "закрыт"), {})
	if changed.call("editor", lab.editor.visible): _event("F2 " + ("открыт" if lab.editor.visible else "закрыт"), {})
	if changed.call("overview", lab.overview): _event("вид сверху " + ("включён" if lab.overview else "выключен"), {})
	if changed.call("lane", lab.lane): _event("трасса", {lane = lab.lane, title = route.title})
	if changed.call("auto", lab.autopilot.style if lab.autopilot != null else ""): _event("автопилот", {style = lab.autopilot.style if lab.autopilot != null else "выкл"})
	if changed.call("contact_model", lab.contact_model): _event("F6 модель контактов", {two_contacts = lab.contact_model})
	# стоит с газом: так остановка видна как отдельное событие, а не как минута нулевой скорости
	if bike.riding and absf(bike.speed) < STUCK_SPEED and raw.fwd > 0.3 and not lab.crash.active():
		_stuck += dt
		_stats.stuck += dt
		if _stuck >= STUCK_TIME and not _stuck_reported:
			_stuck_reported = true
			_event("СТОИТ с газом", _where(bike, station).merged({
				seconds = _stuck, effort = bike.effort, drive = bike.drive_force, brake = bike.brake_pressure, slope = bike.grade_now,
				fits = bike.fits(bike.x, bike.z, bike.heading, lab.heights.world, lab.heights), contact_r = bike.contact_r(),
				tire_r = bike.tire_r, load_r = bike.load_r, stamina = lab.controller.stamina.value, fallen = bike.fallen,
				roll = bike.roll_loss, slope_force = bike.slope_force, obstacle_f = bike._on_f, obstacle_r = bike._on_r}))
	else:
		if _stuck_reported: _event("поехал после остановки", _where(bike, station).merged({stood = _stuck, speed = bike.speed}))
		_stuck = 0.0
		_stuck_reported = false


func _where(bike: BikeRide, station: float) -> Dictionary:
	return {station = station, x = bike.x, z = bike.z, y = bike.y, heading = rad_to_deg(bike.heading)}


func _event(kind: String, data: Dictionary) -> void:
	var line := "t=%.2f тик=%d %s %s" % [_t, _ticks, kind, JSON.stringify(_round(data))]
	_event_counts[kind] = _event_counts.get(kind, 0) + 1
	# клавиши и мелкие события не раздувают сводку
	if kind not in ["клавиша", "мышь", "геймпад", "удар колеса о кромку", "тормоз", "тормоз отпущен", "долгий кадр"] and _event_lines.size() < 80:
		_event_lines.append(line)
	if _events != null:
		_events.store_line(line)
		_events.flush()
	else:
		_pending_events.append(line)


## Числа в событиях без хвоста знаков
func _round(value: Variant) -> Variant:
	if value is float: return snappedf(value, 0.001)
	if value is Vector2: return [snappedf(value.x, 0.001), snappedf(value.y, 0.001)]
	if value is Vector3: return [snappedf(value.x, 0.001), snappedf(value.y, 0.001), snappedf(value.z, 0.001)]
	if value is Dictionary:
		var out := {}
		for key in value: out[key] = _round(value[key])
		return out
	return value


## Первая активность сессии: создать временные файлы и записать накопленное
func _open(lab) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(temp_root))
	_file = FileAccess.open(temp_root + "/unsaved.csv", FileAccess.WRITE)
	_events = FileAccess.open(temp_root + "/unsaved.events.txt", FileAccess.WRITE)
	if _file == null or _events == null:
		push_warning("Trail Lab: не удалось создать временную запись в " + temp_root)
		_file = null
		_events = null
		enabled = false
		return
	_stamp = Time.get_datetime_dict_from_system()
	_preset = lab.preset
	_file.store_line(",".join(_columns))
	for line in _pending: _file.store_line(line)
	_pending.clear()
	_events.store_line("# события сессии; t — секунды с начала сессии, тик — номер такта физики в CSV, ride — поездка (R)")
	for line in _pending_events: _events.store_line(line)
	_pending_events.clear()
	_events.flush()


## «Сохранить запись»: временные файлы уходят в проект (ride_logs/<дата>/), рядом — заголовок и сводка.
## Возвращает путь без расширения или "", если сохранять нечего. После сохранения начинается новая сессия.
func save(lab, reason := "кнопка «Сохранить запись»") -> String:
	if not has_data(): return ""
	_event("СОХРАНЕНО", {reason = reason})
	_file.flush()
	_file.close()
	_events.flush()
	_events.close()
	_file = null
	_events = null
	var folder := "%s/%04d-%02d-%02d" % [root, _stamp.year, _stamp.month, _stamp.day]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	# csv в res:// Godot принял бы за таблицу переводов: папку скрываем от импорта
	var ignore := root + "/.gdignore"
	if not FileAccess.file_exists(ignore):
		var marker := FileAccess.open(ignore, FileAccess.WRITE)
		if marker != null: marker.close()
	var base := "%s/ride_%02d-%02d-%02d_p%d" % [folder, _stamp.hour, _stamp.minute, _stamp.second, _preset + 1]
	var n := 2
	while FileAccess.file_exists(base + ".csv"):
		base = "%s/ride_%02d-%02d-%02d_p%d_%d" % [folder, _stamp.hour, _stamp.minute, _stamp.second, _preset + 1, n]
		n += 1
	var copied := DirAccess.copy_absolute(ProjectSettings.globalize_path(temp_root + "/unsaved.csv"), ProjectSettings.globalize_path(base + ".csv")) == OK \
		and DirAccess.copy_absolute(ProjectSettings.globalize_path(temp_root + "/unsaved.events.txt"), ProjectSettings.globalize_path(base + ".events.txt")) == OK
	if not copied:
		push_warning("Trail Lab: не удалось сохранить запись в " + base)
		return ""
	path = base
	var header := FileAccess.open(base + ".header.json", FileAccess.WRITE)
	if header != null:
		header.store_string(JSON.stringify(_header(lab), "\t"))
		header.close()
	var summary := FileAccess.open(base + ".summary.txt", FileAccess.WRITE)
	if summary != null:
		summary.store_string(_summary(lab, reason))
		summary.close()
	_session = false
	return base


## Выход из лаборатории: файлы закрыть; несохранённое остаётся только во временной папке
func close() -> void:
	if _file != null:
		_file.flush()
		_file.close()
		_file = null
	if _events != null:
		_events.flush()
		_events.close()
		_events = null
	_session = false

func _header(lab) -> Dictionary:
	var route: TrailDefinition = lab.routes[lab.lane]
	var elements := []
	for e in route.elements:
		elements.append({station = snappedf(e.station, 0.1), length = snappedf(e.length, 0.1), profile = TrailElementLibrary.title(e.profile), height = snappedf(e.height, 0.01), count = e.count})
	var settings = lab.services.settings
	var now := Time.get_datetime_dict_from_system()
	return {
		format = 1,
		started = "%04d-%02d-%02d %02d:%02d:%02d (время компьютера)" % [now.year, now.month, now.day, now.hour, now.minute, now.second],
		rides = _round(_rides),
		session_seconds = snappedf(_t, 0.01),
		code = _code_version(),
		godot = Engine.get_version_info().string,
		route = {preset = lab.preset + 1, lane = lab.lane, id = route.id, title = route.title, length = snappedf(route.route_length(), 0.1),
			width = route.width, ground = lab.ground_kind, elements = elements},
		contact_model = lab.contact_model,
		settings = {fov = settings.fov, mouse = settings.mouse, invert_y = settings.invert_y, head_bob = settings.head_bob},
		rate_hz = 60,
		columns = Array(_columns),
		units = "м, м/с, м/с², секунды, градусы; нагрузки — доли веса; lateral — отступ от оси трассы, + вправо по ходу; station — метры вдоль трассы (-1: вне трассы)",
		bike_constants = _constants(BikeRide),
		brake_constants = _constants(preload("res://scripts/game/bike_brakes.gd")),
		game_config = _constants(GameConfig),
		controls_constants = _constants(Controls),
	}


func _constants(script: Script) -> Dictionary:
	var map := script.get_script_constant_map()
	var out := {}
	for key in map:
		var value: Variant = map[key]
		if value is float or value is int or value is bool or value is String:
			out[key] = _round(value)
		elif value is Vector2:
			out[key] = _round(value)
		elif value is Array and not (value as Array).is_empty() and (value as Array).all(func(v: Variant) -> bool: return v is float or v is int):
			out[key] = value
	return out


## Версия кода: коммит и число изменённых файлов; один раз за запуск игры
func _code_version() -> Dictionary:
	if _git.is_empty():
		var out := []
		var commit := OS.execute("git", ["-C", ProjectSettings.globalize_path("res://"), "log", "-1", "--format=%h %ci %s"], out)
		var dirty := []
		OS.execute("git", ["-C", ProjectSettings.globalize_path("res://"), "status", "--porcelain", "--untracked-files=no"], dirty)
		var files := str(dirty[0]).strip_edges().split("\n", false) if not dirty.is_empty() else PackedStringArray()
		_git = JSON.stringify({commit = str(out[0]).strip_edges() if commit == 0 and not out.is_empty() else "неизвестно",
			uncommitted_files = Array(files)})
	return JSON.parse_string(_git)


func _summary(lab, reason: String) -> String:
	var lines := PackedStringArray()
	var route: TrailDefinition = lab.routes[lab.lane]
	var code := _code_version()
	lines.append("ЗАЕЗД %s" % path.get_file())
	lines.append("Сессия: поездок %d · сохранена: %s · последняя трасса %d «%s»" % [_ride, reason, lab.preset + 1, route.title])
	for ride: Dictionary in _rides:
		lines.append("  поездка %d: с %.1f с · трасса %d «%s» · старт станция %.0f, %.1f м/с · %s" % [ride.n, ride.t, ride.preset, ride.route, ride.station, ride.speed, ride.reason])
	lines.append("Код: %s%s" % [code.commit, " (+%d изменённых файлов без коммита)" % code.uncommitted_files.size() if not code.uncommitted_files.is_empty() else ""])
	lines.append("Длительность %.1f с · %d тактов · путь %.0f м · макс. скорость %.1f м/с (%.0f км/ч)" % [_t, _ticks, _stats.distance, _stats.top, _stats.top * 3.6])
	lines.append("Ввод (время удержания, с): вперёд %.1f · назад/тормоз %.1f · влево %.1f · вправо %.1f · Q %.1f · E %.1f · памп (ЛКМ) %.1f · Shift %.1f · прыжков (пробел) %d" % [
		_stats.fwd, _stats.back, _stats.left, _stats.right, _stats.q, _stats.e, _stats.pump, _stats.run, _stats.jumps])
	lines.append("В воздухе %.1f с · падений %d · стоял с газом %.1f с · пик сноса %.1f° · пик сцепления %.0f%% · пик торможения %.1f м/с²" % [
		_stats.air, _stats.crashes, _stats.stuck, rad_to_deg(_stats.peak_slip), _stats.peak_grip * 100.0, _stats.peak_decel])
	lines.append("Кадры: минимальный FPS %d · долгих тактов (>50 мс) %d" % [_stats.min_fps, _stats.slow_ticks])
	var surfaces := []
	for key in _stats.surfaces: surfaces.append("%s %.1f с" % [key, _stats.surfaces[key]])
	lines.append("Покрытия: " + " · ".join(surfaces))
	var counts := []
	for key in _event_counts:
		if key not in ["клавиша", "мышь", "геймпад"]: counts.append("%s %d" % [key, _event_counts[key]])
	lines.append("События: " + " · ".join(counts))
	lines.append("")
	lines.append("Ключевые события (полный список — .events.txt):")
	lines.append_array(_event_lines)
	lines.append("")
	lines.append("F3 на конец заезда:")
	lines.append(lab.metrics.report(route))
	lines.append("")
	lines.append("Колонки CSV и константы физики — в .header.json. Станция — метры вдоль трассы, lateral — отступ от оси (+ вправо).")
	return "\n".join(lines) + "\n"
