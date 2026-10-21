extends SceneTree
## Контакт с водой, мост, прыжок, два колеса, затухание и перенос.

class TestWorld extends WorldData:
	func tile_info(_x: float, _z: float) -> Dictionary:
		return {biome = Biomes.GRASS, path = 0}

class TestGround extends Heightfield:
	var depth := 0.2
	var bridge := false
	var current := Vector2.ZERO
	func _init() -> void:
		super(WorldData.new(), false)
	func ground_at(_x: float, _z: float, _raw := false) -> float:
		return 0.0
	func depth_at(_x: float, _z: float, _feet := -INF) -> float:
		return 0.0 if bridge else depth
	func current_at(_x: float, _z: float) -> Vector2:
		return current
	func known(_x: float, _z: float) -> bool:
		return true

var fails := 0

func check(ok: bool, label: String) -> void:
	print(("OK " if ok else "FAIL ") + label)
	fails += int(not ok)

func _init() -> void:
	_run.call_deferred()

func walking(h: Heightfield, w: WorldData) -> float:
	var p := PlayerState.new()
	for i in 60:
		p.step(1, 0, false, false, 0, 1.0 / 60.0, w, h)
	return p.ground_speed()

func cycling(h: Heightfield, w: WorldData) -> float:
	var p := PlayerState.new()
	var b := BikeRide.new()
	for i in 120:
		b.step(p, 1, 0, false, false, 1.0 / 60.0, w, h)
	return b.speed

func _run() -> void:
	var h := TestGround.new()
	var w := TestWorld.new()
	check(is_equal_approx(h.immersion_at(0, 0, 0), 0.2) and h.immersion_at(0, 0, 1) == 0,
		"Погружение учитывает высоту над водой")
	h.depth = 0.29
	var walk_before := walking(h, w)
	var bike_before := cycling(h, w)
	h.depth = 0.31
	check(absf(walk_before - walking(h, w)) < 0.1 and absf(bike_before - cycling(h, w)) < 0.15,
		"На глубине 30 см нет скачка скорости пешехода и велосипеда")
	h.depth = 0.8
	check(walking(h, w) < walk_before and cycling(h, w) < bike_before, "Глубокий брод ощутимо замедляет")
	h.bridge = true
	check(walking(h, w) > walk_before and cycling(h, w) > bike_before, "Мост не наследует сопротивление воды")
	h.bridge = false
	h.depth = 0.2
	var p := PlayerState.new()
	var b := BikeRide.new()
	var water := Node3D.new()
	var plane := PlaneMesh.new()
	plane.material = WaterBuilder._material()
	var surface := MeshInstance3D.new()
	surface.mesh = plane
	water.add_child(surface)
	root.add_child(water)
	var fx := WaterEffects.new()
	fx.setup(water)
	water.add_child(fx)
	var previous := Vector3(-0.05, 0, 0)
	fx.tick(1.0 / 60.0, p, b, previous, h)
	check(fx._ring == 1 and fx.rings[0].w > 0, "Ходьба создаёт всплеск")
	check(absf(fx.levels[0] - 0.2) < 0.001, "Круги на игровом уровне воды")
	var slow := fx.rings[0].w
	fx.clear()
	fx.tick(1.0 / 60.0, p, b, Vector3(-0.15, 0, 0), h)
	check(fx.rings[1].w > slow, "Быстрое движение усиливает всплеск")
	fx.clear()
	h.depth = 0.05
	var shallow_ring := fx._ring
	fx.tick(1.0 / 60.0, p, b, previous, h)
	check(fx.rings[shallow_ring].w < slow, "На мелководье всплеск слабее")
	fx.clear()
	h.depth = 0.2
	var landing_ring := fx._ring
	fx.tick(1.0 / 60.0, p, b, Vector3(0, 0.1, 0), h)
	check(fx._ring != landing_ring and fx.rings[landing_ring].w > slow, "Вертикальное приземление создаёт всплеск")
	fx.clear()
	h.depth = 0.0
	var ring := fx._ring
	fx.tick(1.0 / 60.0, p, b, previous, h)
	check(fx._ring == ring, "На суше эффектов нет")
	h.depth = 0.2
	h.bridge = true
	fx.tick(1.0 / 60.0, p, b, previous, h)
	check(fx._ring == ring, "На мосту эффектов нет")
	h.bridge = false
	p.feet = 1.0
	fx.tick(1.0 / 60.0, p, b, Vector3(-0.05, 1, 0), h)
	check(fx._ring == ring, "В прыжке над водой эффектов нет")
	p.feet = 0.0
	b.riding = true
	fx.tick(1.0 / 60.0, p, b, previous, h)
	check(fx._ring == (ring + 2) % WaterEffects.RINGS, "Два колеса оставляют отдельные следы")
	var first := ring
	check(absf(fx.rings[first].y - fx.rings[(first + 1) % WaterEffects.RINGS].y) > 1.0, "Следы расположены у колёс")
	ring = fx._ring
	for i in 120:
		fx.tick(1.0 / 60.0, p, b, Vector3.ZERO, h)
	check(fx._ring == ring, "Остановка не создаёт непрерывные всплески")
	check(fx.rings[first].z > WaterEffects.LIFETIME, "След затухает за 1.6 секунды")
	check(fx._life.count(0.0) == WaterEffects.DROPS, "Капли освобождаются")
	fx.tick(1.0 / 60.0, p, b, Vector3(100, 0, 0), h)
	var cleared := true
	for event in fx.rings:
		cleared = cleared and event.w == 0.0
	check(cleared, "Перенос очищает след")
	h.current = Vector2.RIGHT
	b.riding = false
	var drifting := fx._ring
	fx.tick(1.0 / 60.0, p, b, Vector3.ZERO, h)
	fx.tick(1.0 / 60.0, p, b, Vector3.ZERO, h)
	check(fx.rings[drifting].x > 0.0, "След уносит вниз по течению")
	water.free()
	print("Ошибок взаимодействия с водой: %d" % fails)
	quit(1 if fails else 0)
