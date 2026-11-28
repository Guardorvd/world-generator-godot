extends SceneTree
## Комплексная проверка упрощённой физики велосипеда test4:
## 1) продольный разгон, накат, тормоз, удержание на склоне и задний ход;
## 2) двухосевое руление передним колесом на разных скоростях и скольжение вдоль стенки;
## 3) крутой подъём 50% и траверс 40% косогора (Тип 2) без срывов;
## 4) прыжок на Space и аркадный баланс Q/E в воздухе с проверкой чистого/плохого/аварийного приземления.

class FlatWorld extends WorldData:
	func _init() -> void:
		W = 64
		H = 64
		N = W * H
		river.resize(N)
		dist_water.resize(N)
		dist_water.fill(50.0)
		path_mask.resize(N)
		road_surface.resize(N)
	func tile_info(_x: float, _y: float) -> Dictionary:
		return {biome = Biomes.GRASS, path = 3, surface = RoadSurface.PACKED}

class SlopeGround extends Heightfield:
	var grade_z := 0.0
	var grade_x := 0.0
	var wall_x := -999.0
	func _init(w: WorldData) -> void:
		super()
		world = w
	func surface_at(x: float, z: float, _ref := -INF) -> float:
		return 100.0 + grade_x * x + grade_z * z
	func ground_at(x: float, z: float, _raw := false) -> float:
		return 100.0 + grade_x * x + grade_z * z
	func depth_at(_x: float, _z: float, _feet := -INF) -> float:
		return 0.0
	func immersion_at(_x: float, _z: float, _feet: float) -> float:
		return 0.0
	func wall_at(x: float, _z: float, _feet: float, r := 0.0) -> bool:
		return wall_x > -900.0 and x - r < wall_x
	func known(_x: float, _z: float) -> bool:
		return true

var fails := 0

func check(ok: bool, label: String) -> void:
	print(("✓ " if ok else "✗ ") + label)
	if not ok:
		fails += 1

func ride(initial: float, throttle: float, slope: float, seconds: float, boost := false, terrain := 1.0, hz := 60) -> BikeRide:
	var b := BikeRide.new()
	b.speed = initial
	for i in roundi(seconds * hz):
		b._step_speed(throttle, boost, slope, terrain, 1.0 / hz)
	return b

func _init() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	var cfg := BikePhysicsConfig.current()

	# 1. Продольная динамика
	var climb := ride(2.0, 1.0, 0.35, 2.0)
	var climb_push := ride(2.0, 1.0, 0.35, 2.0, true)
	check(climb_push.speed > climb.speed + 0.7, "Shift ощутимо помогает дожать крутой подъём")
	check(ride(9.0, 0.0, 0.25, 1.0).speed > ride(3.0, 0.0, 0.25, 1.0).speed + 4.0,
		"запас хода перед подъёмом помогает пройти его накатом")
	var descent := ride(0.0, 0.0, -0.4, 90.0, false, 1.4).speed
	check(descent > 21.0 and descent < 28.0, "длинный спуск по дороге: мягкое ограничение воздухом, %.2f м/с" % descent)
	check(ride(24.0, 0.0, -0.4, 0.1).speed > 23.0, "на быстром спуске нет мгновенного обрезания скорости")
	check(ride(12.0, -0.35, -0.25, 2.0).speed < 12.0, "лёгкое торможение позволяет дозировать скорость спуска")
	check(absf(ride(2.0, 1.0, 0.35, 4.0, true, 1.0, 30).speed - ride(2.0, 1.0, 0.35, 4.0, true, 1.0, 120).speed) < 0.12,
		"помощь в подъём близка при 30 и 120 тактах/с")
	var start := ride(0.0, 1.0, 0.0, 0.5).speed
	check(start > 1.8 and start < 3.5, "отзывчивый старт: %.2f м/с за 0.5 с" % start)
	var cruise := ride(0.0, 1.0, 0.0, 25.0).speed
	check(absf(cruise - cfg.cruise_speed) < 0.15, "плавный выход на крейсерскую: %.2f м/с" % cruise)
	check(ride(8.0, 1.0, 0.0, 0.5).speed - 8.0 < start * 0.5, "тяга плавно ослабевает с ростом скорости")
	var coast := ride(11.0, 0.0, 0.0, 2.0).speed
	check(coast > 8.6 and coast < 10.0, "накат сохраняет ход: %.2f м/с через 2 с" % coast)
	check(ride(1.0, 0.0, 0.0, 5.0).speed == 0.0, "накат останавливается без дрожания и смены направления")
	check(ride(0.0, 0.0, -0.15, 3.0).speed > 1.5, "спуск разгоняет без педалей")
	check(ride(8.0, 0.0, 0.15, 2.0).speed < ride(8.0, 0.0, 0.0, 2.0).speed, "подъём съедает инерцию")
	check(ride(0.0, 0.0, 0.3, 3.0).speed == 0.0, "в подъём нет самопроизвольного отката")
	check(ride(0.0, 1.0, 0.15, 20.0).speed < cruise, "под педалями подъём медленнее равнины")
	check(ride(18.0, 1.0, -0.3, 0.1).speed > 17.0, "педали не обрезают скорость спуска")
	var cruise_hold := BikeRide.new()
	cruise_hold.speed = cfg.cruise_speed
	cruise_hold.effort = 1.0
	for i in 30:
		cruise_hold._step_speed(1.0, false, 0.0, 1.0, 1.0 / 60.0)
	check(cruise_hold.speed > cfg.cruise_speed - 0.05, "педали поддерживают крейсерскую скорость")
	check(ride(0.0, 1.0, 0.0, 25.0, true).speed > cruise * 1.25, "Shift даёт дополнительную тягу")
	check(ride(11.0, 0.0, 0.0, 2.0, true).speed == coast, "Shift не меняет накат без педалей")
	check(ride(8.0, 0.0, 0.0, 2.0, false, 0.6).speed < ride(8.0, 0.0, 0.0, 2.0).speed, "мягкое покрытие сильнее замедляет")
	var brake := ride(11.0, -1.0, -0.3, 4.0)
	check(brake.speed == 0.0, "торможение со спуска до остановки без заднего хода")
	check(ride(0.0, -1.0, -0.3, 0.2).speed == 0.0, "тормоз удерживает на склоне")
	check(ride(0.0, -1.0, 0.0, 1.0).speed == -cfg.reverse_speed, "задний ход после паузы")
	check(ride(-1.5, 1.0, 0.0, 0.1).speed < 0.0, "смена направления проходит через торможение")
	var slow_tick := ride(0.0, 1.0, -0.1, 5.0, false, 1.0, 30).speed
	var fast_tick := ride(0.0, 1.0, -0.1, 5.0, false, 1.0, 120).speed
	check(absf(slow_tick - fast_tick) < 0.1, "близкий результат при 30 и 120 тактах/с")

	# 2. Двухосевое руление, соответствие руля/переднего колеса и касательное скольжение вдоль стены
	var w := FlatWorld.new()
	var g := SlopeGround.new(w)
	var p := PlayerState.new()
	var slow_turn := BikeRide.new()
	slow_turn.x = 128.0; slow_turn.z = 128.0; slow_turn.mount(p); slow_turn.speed = 4.0
	var fast_turn := BikeRide.new()
	fast_turn.x = 128.0; fast_turn.z = 128.0; fast_turn.mount(p); fast_turn.speed = 14.0
	for i in 30:
		slow_turn.step(p, 0.0, 1.0, false, false, 1.0 / 60.0, w, g)
		fast_turn.step(p, 0.0, 1.0, false, false, 1.0 / 60.0, w, g)
	check(absf(slow_turn.steer_angle) > absf(fast_turn.steer_angle) and slow_turn.heading < -0.5 and fast_turn.heading < -0.15,
		"малая скорость поворачивает круче, высокая — плавнее без опрокидывания")
	check(absf(slow_turn.steer_visual()) > 0.8 and signf(slow_turn.steer_visual()) == signf(slow_turn.steer_angle),
		"визуальный поворот руля совпадает с физическим углом переднего колеса")

	var wall := SlopeGround.new(w)
	wall.wall_x = 127.4
	var glance := BikeRide.new()
	glance.x = 128.0; glance.z = 128.0; glance.mount(p); glance.speed = 7.0; glance.heading = 0.25
	for i in 60:
		glance.step(p, 0.5, 0.0, false, false, 1.0 / 60.0, w, wall)
	check(not glance.crashed and glance.z < 125.0, "касательное задевание стены соскальзывает без залипания и аварии")

	# 3. Крутые дороги Типа 2: подъём 50% и косогор 40%
	var steep_climb := SlopeGround.new(w)
	steep_climb.grade_z = -0.50 # в сторону -Z высота растёт (+50%)
	var climber := BikeRide.new()
	climber.x = 128.0; climber.z = 128.0; climber.y = steep_climb.surface_at(128.0, 128.0); climber.mount(p); climber.speed = 3.0
	for i in 180:
		climber.step(p, 1.0, 0.0, false, false, 1.0 / 60.0, w, steep_climb)
	check(not climber.crashed and climber.speed > 2.2 and climber.z < 120.0,
		"подъём 50%% уверенно заезжается на педалях без отката (%.2f м/с)" % climber.speed)

	var camber := SlopeGround.new(w)
	camber.grade_x = 0.40
	var traverser := BikeRide.new()
	traverser.x = 128.0; traverser.z = 128.0; traverser.y = camber.surface_at(128.0, 128.0); traverser.mount(p); traverser.speed = 9.0
	for i in 120:
		traverser.step(p, 0.5, 0.0, false, false, 1.0 / 60.0, w, camber)
	check(not traverser.crashed and traverser.z < 110.0, "траверс по 40%% косогору проезжается чисто без ложных падений")

	# 4. Прыжок на Space и баланс Q (нос вверх) / E (нос вниз) в воздухе
	var air_up := BikeRide.new()
	air_up.x = 128.0; air_up.z = 128.0; air_up.mount(p); air_up.speed = 11.0
	air_up.step(p, 0.5, 0.0, false, true, 1.0 / 60.0, w, g)
	check(air_up.airborne and air_up.hop_used and air_up.vy > 3.0, "Space запускает банни-хоп")
	for i in 15:
		air_up.body_back = true
		air_up.body_forward = false
		air_up.step(p, 0.5, 0.0, false, false, 1.0 / 60.0, w, g)
	check(air_up.tilt > 0.35, "Q в воздухе поднимает нос вверх (tilt=%.2f)" % air_up.tilt)

	var air_down := BikeRide.new()
	air_down.x = 128.0; air_down.z = 128.0; air_down.mount(p); air_down.speed = 11.0
	air_down.step(p, 0.5, 0.0, false, true, 1.0 / 60.0, w, g)
	for i in 15:
		air_down.body_back = false
		air_down.body_forward = true
		air_down.step(p, 0.5, 0.0, false, false, 1.0 / 60.0, w, g)
	check(air_down.tilt < -0.35, "E в воздухе опускает нос вниз (tilt=%.2f)" % air_down.tilt)

	# Экстремальный носок вниз на приземлении после долгого полёта роняет велосипедиста, а ровный угол спасает
	var crash_land := BikeRide.new()
	crash_land.x = 128.0; crash_land.z = 128.0; crash_land.mount(p); crash_land.speed = 11.0
	crash_land.airborne = true; crash_land.y = 102.5; crash_land.vy = -1.0; crash_land.air_time = 0.5; crash_land.tilt = -0.82
	crash_land._land(100.0, 0.0, 1.0 / 60.0, g, cfg)
	check(crash_land.crashed and crash_land.crash_cause == BikeRide.CrashCause.OBSTACLE,
		"сильный клевок носом на приземлении вызывает падение")

	var smooth_land := BikeRide.new()
	smooth_land.x = 128.0; smooth_land.z = 128.0; smooth_land.mount(p); smooth_land.speed = 11.0
	smooth_land.airborne = true; smooth_land.y = 102.0; smooth_land.vy = -4.0; smooth_land.air_time = 0.5; smooth_land.tilt = 0.05
	smooth_land._land(100.0, 0.0, 1.0 / 60.0, g, cfg)
	check(not smooth_land.crashed and smooth_land.speed > 10.8,
		"ровное приземление сбалансированного велосипеда сохраняет скорость (%.2f)" % smooth_land.speed)

	# 5. Регрессии 1.1: разделение руля и крена, подъём с микроотката, выход от стены, устойчивый спуск
	var gentle := BikeRide.new()
	gentle.x = 128.0; gentle.z = 128.0; gentle.mount(p); gentle.speed = 9.0
	for i in 12:
		gentle.step(p, 0.4, 0.35, false, false, 1.0 / 60.0, w, g)
	check(absf(gentle.heading) > 0.04 and absf(gentle.lean) < 0.06,
		"лёгкое подруливание поворачивает передним колесом без сильного крена (heading=%.3f, lean=%.3f)" % [gentle.heading, gentle.lean])

	var carve := BikeRide.new()
	carve.x = 128.0; carve.z = 128.0; carve.mount(p); carve.speed = 11.0
	for i in 60:
		carve.step(p, 0.8, 1.0, false, false, 1.0 / 60.0, w, g)
	check(absf(carve.lean) >= 0.18 and absf(carve.lean) <= cfg.lean_max + 0.01,
		"быстрая затяжная дуга плавно раскрывает крен (lean=%.3f)" % carve.lean)

	var stall_climb := BikeRide.new()
	stall_climb.x = 128.0; stall_climb.z = 128.0; stall_climb.y = steep_climb.surface_at(128.0, 128.0)
	stall_climb.mount(p); stall_climb.speed = -0.015
	for i in 120:
		stall_climb.step(p, 1.0, 0.0, false, false, 1.0 / 60.0, w, steep_climb)
	check(not stall_climb.crashed and stall_climb.speed > 1.5 and stall_climb.z < 126.0,
		"старт с микроотката на крутом подъёме стабильно тянет вверх (%.2f м/с)" % stall_climb.speed)

	var stuck_wall := SlopeGround.new(w)
	stuck_wall.wall_x = 127.85
	var trapped := BikeRide.new()
	trapped.x = 128.0; trapped.z = 128.0; trapped.mount(p); trapped.speed = 6.0; trapped.heading = 0.05
	for i in 60:
		trapped.step(p, 0.8, 0.0, false, false, 1.0 / 60.0, w, stuck_wall)
	check(not trapped.crashed and trapped.z < 124.0 and trapped.speed > 2.5,
		"старт вплотную в зоне BODY_R стены не застревает и скользит вдоль (z=%.2f, speed=%.2f)" % [trapped.z, trapped.speed])

	var steep_desc := SlopeGround.new(w)
	steep_desc.grade_z = 0.28 # спуск вдоль -Z вниз
	var descender := BikeRide.new()
	descender.x = 128.0; descender.z = 128.0; descender.y = steep_desc.surface_at(128.0, 128.0)
	descender.mount(p); descender.speed = 11.0
	var stayed_grounded := true
	for i in 60:
		descender.step(p, 0.0, 0.45, false, false, 1.0 / 60.0, w, steep_desc)
		if descender.airborne:
			stayed_grounded = false
	check(stayed_grounded and not descender.crashed,
		"поворот на крутом 28%% спуске не вызывает ложного отрыва в воздух")

	quit(1 if fails else 0)
