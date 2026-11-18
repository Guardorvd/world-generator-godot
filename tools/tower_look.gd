extends SceneTree
## 18.11.2026: изолированная сцена дозорной вышки без генерации мира. Синтетический рельеф 192 × 192 клеток
## (как у trail_world_network_test) с одной вышкой (StageSites, вид "tower"), поворот 0,6 рад.
## 1. Настилы лестницы (Heightfield.add_site_decks) и ходок: PlayerState.step поднимается по пяти маршам на верхнюю
##    площадку и спускается назад (пройден ли путь, время, ноги на площадке); с краёв площадки и марша не падает (перила);
##    C# RideGround и GDScript отвечают одинаково (verify_native_ride, 0 расхождений).
## 2. Модель: настоящий SettlementsBuilder.build по каталогу (нужна пересборка bake_assets.gd) — снимки сбоку и с площадки.
## Нужно окно (не headless). Лимит 90 с.
##   godot --path . --script res://tools/tower_look.gd -- [--out <папка>] [--no-shots]

const Fixture := preload("res://tools/trail_world_network_test.gd") # общий синтетический мир 192 × 192 с пологим склоном
const TILE := GameConfig.TILE
const DT := 1.0 / 60.0
const YAW := 0.6
const TOWER_CELL := Vector2(96.5, 96.5)

var out := ""
var failures := 0
var w: WorldData
var h: Heightfield


func _arg(name: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--" + name)
	return args[at + 1] if at >= 0 and at + 1 < args.size() else fallback


func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok:
		failures += 1


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 90)
	out = _arg("out", OS.get_user_data_dir().path_join("tower_look"))
	DirAccess.make_dir_recursive_absolute(out)
	run.call_deferred()



func local_to_world(at: Vector2) -> Vector2:
	var p := Basis(Vector3.UP, YAW) * Vector3(at.x, 0.0, at.y)
	return Vector2(TOWER_CELL.x * TILE + p.x, TOWER_CELL.y * TILE + p.z)


func run() -> void:
	w = Fixture.synthetic()
	w.available_rect = Rect2i(0, 0, w.W, w.H)
	var site := SiteData.new(TOWER_CELL.x, TOWER_CELL.y, floori(TOWER_CELL.y) * w.W + floori(TOWER_CELL.x), "tower", 3, "Сторожевая", 2.0,
		[HutData.new(TOWER_CELL.x, TOWER_CELL.y, 0, "tower", YAW)] as Array[HutData])
	w.sites = [site]
	h = w.base_heights.copy()
	h.build_structures()
	h.native_ride = true
	Heightfield.verify_native_ride = true
	var count := h.structures.size()
	h.add_site_decks(w.sites)
	h.add_site_decks(w.sites)
	check(h.structures.size() == count + TowerLayout.structures(Vector3.ZERO, 0.0, "k").size(), "настилы вышки добавлены один раз (%d)" % (h.structures.size() - count))
	check(h.towers.size() == 1, "вышка записана для проверки площадки")
	var base: float = h.towers[0].base
	print("низ каркаса %.2f м, площадка %.2f м" % [base, base + TowerLayout.DECK_Y])
	var started := Time.get_ticks_msec()
	_climb(base)
	_edges(base)
	check(Heightfield.native_ride_checks > 1000 and Heightfield.native_ride_mismatches.is_empty(),
		"C# и GDScript совпадают: сверок %d, расхождений %d" % [Heightfield.native_ride_checks, Heightfield.native_ride_mismatches.size()])
	print("ходок и края: %d мс" % (Time.get_ticks_msec() - started))
	if "--no-shots" not in OS.get_cmdline_user_args() and DisplayServer.get_name() != "headless":
		await _shots(base)
	print("ИТОГО: %s" % ("всё прошло" if failures == 0 else "%d провалов" % failures))
	quit(1 if failures else 0)


## Идти по осевой лестницы к площадке и обратно
func _climb(base: float) -> void:
	var c := TowerLayout.LOOP
	var up: Array[Vector2] = [Vector2(-1.2, c), Vector2(c, c), Vector2(c, -c), Vector2(-c, -c), Vector2(-c, c), Vector2(-0.2, c), Vector2(0.0, 2.0), Vector2(0.0, 0.0)]
	var p := PlayerState.new()
	var start := local_to_world(up[0])
	p.x = start.x
	p.z = start.y
	p.feet = h.surface_at(p.x, p.z, -INF)
	var ground0 := p.feet
	var tick := 0
	var top_tick := -1
	var worst_drop := 0.0
	var route: Array[Vector2] = up.duplicate()
	var k := 0
	var phase_up := true
	var lowest_on_way_up := INF
	while tick < 60 * 120:
		var target := local_to_world(route[k])
		var d := target - Vector2(p.x, p.z)
		if d.length() < 0.35:
			k += 1
			if k >= route.size():
				if phase_up:
					top_tick = tick
					phase_up = false
					var back: Array[Vector2] = up.duplicate()
					back.reverse()
					route = back.slice(1)
					k = 0
					continue
				break
		else:
			var yaw := atan2(-d.x, -d.y)
			p.step(1.0, 0.0, false, false, yaw, DT, w, h)
			tick += 1
			if phase_up and tick > 30:
				lowest_on_way_up = minf(lowest_on_way_up, p.feet)
	check(top_tick > 0, "вверх по маршам до площадки за %.1f с" % (top_tick * DT))
	var feet := p.feet
	if top_tick > 0:
		check(tick < 60 * 120, "и вниз обратно за %.1f с всего" % (tick * DT))
		check(absf(feet - ground0) < 0.6, "ноги внизу после спуска: %.2f (было %.2f)" % [feet, ground0])
	check(lowest_on_way_up > ground0 - 0.5, "по пути вверх не падали (самое низкое %.2f, земля у входа %.2f)" % [lowest_on_way_up, ground0])
	var deck_p := PlayerState.new()
	var at := local_to_world(Vector2(0.0, 0.5))
	deck_p.x = at.x
	deck_p.z = at.y
	deck_p.feet = h.surface_at(deck_p.x, deck_p.z, base + TowerLayout.DECK_Y)
	check(TowerLayout.on_deck(h.towers[0], deck_p.x, deck_p.z, deck_p.feet), "на верхней площадке видно (ноги %.2f, площадка %.2f)" % [deck_p.feet, base + TowerLayout.DECK_Y])
	check(not TowerLayout.on_deck(h.towers[0], p.x, p.z, p.feet), "внизу площадкой не считается")


## С краёв площадки, марша и угловой площадки не упасть: пять секунд упираться наружу
func _edges(base: float) -> void:
	var cases := [
		["край площадки +x", Vector2(0.0, -1.0), Vector2(1, 0), TowerLayout.DECK_Y, 3.3],
		["край площадки -z", Vector2(0.0, 0.0), Vector2(0, -1), TowerLayout.DECK_Y, 3.3],
		["сбоку марша 2", Vector2(TowerLayout.LOOP, 0.0), Vector2(1, 0), -1.0, 0.7],
		["сбоку марша 3", Vector2(0.0, -TowerLayout.LOOP), Vector2(0, -1), -1.0, 0.7],
		["угловая площадка 1, наружу", Vector2(TowerLayout.LOOP, TowerLayout.LOOP), Vector2(1, 1).normalized(), -1.0, 1.2],
	]
	for case: Array in cases:
		var from: Vector2 = case[1]
		var dir: Vector2 = case[2]
		var start := local_to_world(from)
		var p := PlayerState.new()
		p.x = start.x
		p.z = start.y
		var level: float = case[3]
		# высота настила под точкой: на марше — по сооружению, на площадке — верх каркаса
		p.feet = h.surface_at(p.x, p.z, base + (level if level > 0.0 else 12.4))
		var feet0 := p.feet
		var world_dir := (Basis(Vector3.UP, YAW) * Vector3(dir.x, 0.0, dir.y))
		var yaw := atan2(-world_dir.x, -world_dir.z)
		for tick in 60 * 5:
			p.step(1.0, 0.0, false, false, yaw, DT, w, h)
		var moved := Vector2(p.x, p.z).distance_to(start)
		check(p.feet > feet0 - 0.4 and moved < float(case[4]), "%s: не упал и не ушёл (сдвиг %.2f м, ноги %.2f → %.2f)" % [case[0], moved, feet0, p.feet])


func _shots(base: float) -> void:
	var parent := Node3D.new()
	root.add_child(parent)
	var ground := _ground_mesh()
	parent.add_child(ground)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, 35, 0)
	sun.shadow_enabled = true
	parent.add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.62, 0.78, 0.92)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.7, 0.75, 0.8)
	parent.add_child(env)
	var settlements := Node3D.new()
	parent.add_child(settlements)
	SettlementsBuilder.build(settlements, w, h)
	var cam := Camera3D.new()
	cam.far = 400.0
	cam.fov = 60.0
	parent.add_child(cam)
	root.size = Vector2i(1280, 720)
	var centre := Vector3(TOWER_CELL.x * TILE, base, TOWER_CELL.y * TILE)
	var views := [
		["side", centre + Vector3(23, 7, 18), centre + Vector3(0, 7.5, 0)],
		["stairs", centre + Vector3(9.0, 2.0, 8.0), centre + Vector3(0, 4.0, 0)],
		["deck", centre + Basis(Vector3.UP, YAW) * Vector3(0.0, TowerLayout.DECK_Y + 1.65, 1.5), centre + Basis(Vector3.UP, YAW) * Vector3(-6, TowerLayout.DECK_Y - 3.5, 30)],
	]
	for view: Array in views:
		cam.position = view[1]
		cam.look_at(view[2])
		for i in 8:
			await process_frame
		var image := root.get_viewport().get_texture().get_image()
		var path := out.path_join("tower_%s.png" % view[0])
		image.save_png(path)
		print("снимок ", path)


func _ground_mesh() -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cx := TOWER_CELL.x * TILE
	var cz := TOWER_CELL.y * TILE
	var step := 2.0
	var n := 40
	for iz in n:
		for ix in n:
			var x0 := cx + (ix - n / 2) * step
			var z0 := cz + (iz - n / 2) * step
			var a := Vector3(x0, h.ground_at(x0, z0), z0)
			var b := Vector3(x0 + step, h.ground_at(x0 + step, z0), z0)
			var c := Vector3(x0, h.ground_at(x0, z0 + step), z0 + step)
			var d := Vector3(x0 + step, h.ground_at(x0 + step, z0 + step), z0 + step)
			for tri: Array in [[a, c, b], [b, c, d]]:
				for v: Vector3 in tri:
					st.set_normal(Vector3.UP)
					st.add_vertex(v)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.36, 0.5, 0.26)
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = m
	return mi
