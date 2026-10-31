extends SceneTree
## Стенд руля и тормоза с клавиатуры (31.10): ровная земля без мира, тот же путь ввода, что в игре
## (Controls.bike_steer / bike_brake → BikeRide.step). Только замеры, для было/стало:
##   нажатие 0,1 / 0,2 с — на сколько доворачивает курс; удержание 1,5 с — радиус дуги и боковая перегрузка;
##   удержание руля с тормозом; нажатие тормоза 0,15 с и удержание 1 с — сколько скорости снято.
##   godot --headless --path . --script res://tools/steer_stand.gd
const Friendly = preload("res://tools/bike_friendly_test.gd")
const DT := 1.0 / 60.0
const SPEEDS := [7.0, 10.0, 13.0, 16.0]

var w := Friendly.TestWorld.new()
var ground := Friendly.TestGround.new(w)
var p := PlayerState.new()

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	run.call_deferred()

func bike(pace: float) -> BikeRide:
	var b := BikeRide.new()
	b.contact_model = true
	b.y = ground.surface_at(0, 0)
	b.mount(p)
	b.speed = pace
	return b

func brake_input(c: Controls, raw: float) -> float:
	return c.bike_brake(raw, DT) if c.has_method("bike_brake") else raw

## seconds руля steer_for секунд (1 — вправо), затем руль отпущен; газ держит скорость; brake — тормоз всё время руля
func ride(pace: float, steer_for: float, total: float, brake := false) -> Dictionary:
	var b := bike(pace)
	var c := Controls.new()
	var h0 := b.heading
	var t := 0.0
	var radius := INF
	var lateral := 0.0
	while t < total:
		var key := 1.0 if t < steer_for else 0.0
		var turn := c.bike_steer(key, DT, b.speed)
		var throttle := brake_input(c, -1.0) if brake and key != 0.0 else clampf((pace - b.speed) * 0.6, 0.0, 1.0)
		b.step(p, throttle, turn, false, false, DT, w, ground)
		t += DT
		if key != 0.0 and absf(b._yaw_rate) > 0.01:
			radius = absf(b.speed) / absf(b._yaw_rate)
			lateral = absf(b.speed * b._yaw_rate) / GameConfig.GRAVITY
	return {turn = rad_to_deg(absf(wrapf(b.heading - h0, -PI, PI))), radius = radius, g = lateral, speed = b.speed}

func brake_ride(pace: float, hold: float) -> float:
	var b := bike(pace)
	var c := Controls.new()
	var t := 0.0
	while t < 1.2:
		b.step(p, brake_input(c, -1.0 if t < hold else 0.0), 0.0, false, false, DT, w, ground)
		t += DT
	return pace - b.speed

func run() -> void:
	print("скорость | нажатие 0,1 с | 0,2 с | удержание 1,5 с: радиус, g | с тормозом: радиус, скорость | тормоз 0,15 с / 1 с: −м/с")
	for pace: float in SPEEDS:
		var tap := ride(pace, 0.1, 1.2)
		var tap2 := ride(pace, 0.2, 1.2)
		var hold := ride(pace, 1.5, 1.5)
		var braked := ride(pace, 1.5, 1.5, true)
		print("%4.0f м/с | %5.1f° | %5.1f° | R %5.1f м, %.2f g | R %5.1f м, %4.1f м/с | %.1f / %.1f" % [
			pace, tap.turn, tap2.turn, hold.radius, hold.g, braked.radius, braked.speed, brake_ride(pace, 0.15), brake_ride(pace, 1.0)])
	quit()
