extends SceneTree
## 8.5: выбранный размер открывает территорию одного плана, не меняя его географию.
## godot --headless --path . --script res://tools/world_plan_test.gd
const SelfTest := preload("res://tools/selftest.gd")
var fails := 0


func check(ok: bool, label: String) -> void:
	if not ok:
		fails += 1
		printerr(label)


static func geography(w: WorldData) -> int:
	var fields := {}
	for key in ["h", "filled", "elev", "ocean", "lake", "river", "river_area", "acc", "slope", "down",
		"order", "rain", "dist_ocean", "dist_water", "temp", "moist", "biome", "rivers", "river_exits",
		"cost", "path_mask", "trails", "road_surface", "bridges", "tunnels", "settlements", "peaks",
		"lakes", "lake_id", "obj_x", "obj_y", "obj_k", "obj_v", "obj_s", "chunks"]:
		fields[key] = w.get(key)
	return SelfTest.fnv(var_to_bytes(fields))


func _init() -> void:
	preload("res://tools/watchdog.gd").arm(self, 180)
	# Вложенность даже у края общего плана, и отрицательные мировые адреса областей.
	for center in [Vector2i(0, 0), Vector2i(767, 767), Vector2i(411, 27)]:
		var stub := WorldData.new()
		stub.W = 768
		stub.H = 768
		stub.territory_center = center
		stub.expand_territory(256)
		var small := stub.available_rect
		stub.expand_territory(512)
		check(stub.available_rect.encloses(small), "Расширение потеряло старые клетки у %s" % center)
		var medium := stub.available_rect
		stub.expand_territory(256)
		check(stub.available_rect == medium, "Меньший размер закрыл открытую территорию")
		stub.expand_territory(768)
		check(stub.available_rect == Rect2i(0, 0, 768, 768), "Большая территория не покрывает план")
		check(stub.region_at(Vector2i(-1, -257)) == Vector2i(-1, -2), "Неверные отрицательные адреса областей")
	var started := Time.get_ticks_msec()
	var w := WorldGenerator.generate("Север-1234", 256, func(_p: float, label: String) -> void: print(label))
	var before := geography(w)
	var spawn_home := PlayerState.home(w)
	check(w.W == WorldGenerator.PLAN_SIZE and w.available_rect.size == Vector2i(256, 256), "Размер плана смешан с доступностью")
	var home_pos := Vector2(spawn_home.x, spawn_home.y) if not spawn_home.is_empty() else Vector2(w.W / 2, w.H / 2)
	check(w.accessible(home_pos.x, home_pos.y, 4.0), "Стартовое место за границей малого окна")
	var heights := Heightfield.new(w)
	var spawn := PlayerState.spawn(w, heights)
	check(w.accessible(spawn.x / GameConfig.TILE, spawn.z / GameConfig.TILE), "Игрок появляется за границей")
	var outside := Vector2(w.available_rect.position.x - 1, w.available_rect.position.y + 20)
	check(not PlayerState.is_passable(w, heights, outside.x * GameConfig.TILE, outside.y * GameConfig.TILE), "Игрок проходит за доступную территорию")
	var original := w.available_rect
	var hv := SelfTest.fnv(heights.hv.to_byte_array())
	for side in [512, 768]:
		w.expand_territory(side)
		check(w.available_rect.encloses(original), "Расширение не содержит исходное окно")
		check(geography(w) == before, "Расширение перестроило географию")
		check(SelfTest.fnv(heights.hv.to_byte_array()) == hv, "Расширение перестроило игровой рельеф")
		check(PlayerState.home(w) == spawn_home, "Расширение изменило стартовое место")
	# Каждая область — те же клетки одного плана, независимо от порядка обращения.
	var forward := []
	for y in 3:
		for x in 3:
			forward.append(w.region_rect(Vector2i(x, y)))
	for i in range(8, -1, -1):
		check(w.region_rect(Vector2i(i % 3, i / 3)) == forward[i], "Адрес области зависит от порядка")
	# Независимые новые генерации: выбор размера не должен попасть ни в один этап.
	for side in [512, 768]:
		var other := WorldGenerator.generate("Север-1234", side)
		check(geography(other) == before, "Новый запуск с размером %d изменил мир" % side)
		check(PlayerState.home(other) == spawn_home, "Размер %d изменил стартовое место" % side)
		check(other.available_rect.size == Vector2i(side, side), "Размер %d не открывает нужное окно" % side)
	print("world_plan_test: %s (%d мс)" % ["OK" if fails == 0 else "ошибок %d" % fails, Time.get_ticks_msec() - started])
	quit(1 if fails > 0 else 0)
