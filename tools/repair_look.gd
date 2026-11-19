extends SceneTree
## 18.11.2026: изолированная сцена починяемых объектов без генерации мира: рыбацкий домик с причалом и лодкой на берегу озера,
## смотровые лавки, тур на вершине — целые и сломанные. Синтетический рельеф 192 × 192 (общий с trail_world_network_test) и озеро справа.
## 1. Настоящий SettlementsBuilder + RepairLayer: сломанные объекты рисует слой, после ремонта на их месте целая модель.
## 2. Причал (FishingLayout) как настил: ходок выходит по нему в воду до конца и возвращается; C# и GDScript совпадают.
## 3. Лавка: коробка наведения, сиденье и поворот; сломанная лавка — «починить», целая — «сесть».
## Снимки до и после ремонта в user://repair_look. Нужно окно. Лимит 90 с.
##   godot --path . --script res://tools/repair_look.gd -- [--out <папка>] [--no-shots]

const Fixture := preload("res://tools/trail_world_network_test.gd") # общий синтетический мир 192 × 192 с пологим склоном
const TILE := GameConfig.TILE
const DT := 1.0 / 60.0
const CENTER := Vector2(96.5, 96.5)
const UiAudio := preload("res://scripts/ui/ui_audio.gd")

class TestControls extends Controls:
	var pulses: Array[Vector3] = []
	func rumble(weak: float, strong: float, seconds: float) -> void:
		pulses.append(Vector3(weak, strong, seconds))


class TestAudio extends UiAudio:
	var pitches: Array[float] = []
	func play(kind: StringName, pitch := 1.0) -> void:
		if kind == &"repair_work":
			pitches.append(pitch)
		super(kind, pitch)

var out := ""
var failures := 0
var w: WorldData
var h: Heightfield
var layer: RepairLayer
var repairs: Repairables
var built: Dictionary


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
	out = _arg("out", OS.get_user_data_dir().path_join("repair_look"))
	DirAccess.make_dir_recursive_absolute(out)
	run.call_deferred()


## Координаты, где id места (место "site", тип kind) исходно сломан или цел — чтобы увидеть оба вида
func _spot(start: Vector2, step: Vector2, broken: bool) -> Vector2:
	var at := start
	for k in 200:
		if Repairables.initially_broken(w.seed_num, WorldData.place_id("site", at.x, at.y)) == broken:
			return at
		at += step
	return start


func _site(at: Vector2, type: String, huts: Array[HutData]) -> SiteData:
	return SiteData.new(at.x, at.y, floori(at.y) * w.W + floori(at.x), type, 1, "Проба %s" % type, 1.0, huts)


func _peak(at: Vector2, broken: bool) -> Dictionary:
	var step := Vector2(1.0, 0.0)
	for k in 200:
		var p := at + step * k
		if Repairables.initially_broken(w.seed_num, WorldData.place_id("peak", p.x, p.y)) == broken:
			return {x = p.x, y = p.y, i = 0, name = "Проба"}
	return {x = at.x, y = at.y, i = 0, name = "Проба"}


func run() -> void:
	w = Fixture.synthetic()
	w.available_rect = Rect2i(0, 0, w.W, w.H)
	# озеро на востоке: дно опущено на 3 м, вода у отметки прежнего берега
	for z in range(84, 116):
		for x in range(100, 140):
			var i := z * w.W + x
			w.lake[i] = 1
			w.filled[i] = w.h[i] # вода у прежнего берега (чуть ниже него на LAKE_DROP)
			w.h[i] -= 3.0 / GameConfig.HS
	w.base_heights = Heightfield.new(w, false)
	var bench_whole := _spot(Vector2(88.5, 88.5), Vector2(1.0, 0.0), false)
	var bench_broken := _spot(Vector2(88.5, 92.5), Vector2(1.0, 0.0), true)
	var pier_at := _spot(Vector2(97.5, 97.5), Vector2(0.0, 1.0), true)
	var sites: Array = [
		_site(bench_whole, "bench", [HutData.new(bench_whole.x, bench_whole.y, 0, "bench", 0.4)] as Array[HutData]),
		_site(bench_broken, "bench", [HutData.new(bench_broken.x, bench_broken.y, 0, "bench", 0.4)] as Array[HutData]),
		_site(pier_at, "fishing", [HutData.new(pier_at.x, pier_at.y, 1, "house_timber", PI * 0.5), HutData.new(pier_at.x, pier_at.y, 1, "pier", PI * 0.5)] as Array[HutData]),
	]
	w.sites = sites
	var cairn_whole := _peak(Vector2(80.5, 100.5), false)
	var cairn_broken := _peak(Vector2(80.5, 104.5), true)
	w.peaks = [cairn_whole, cairn_broken]
	h = w.base_heights.copy()
	h.build_structures()
	h.native_ride = true
	Heightfield.verify_native_ride = true
	h.add_site_decks(w.sites)
	repairs = Repairables.new(w.seed_num)
	var pier_id := WorldData.place_id("site", pier_at.x, pier_at.y)
	var bench_id := WorldData.place_id("site", bench_broken.x, bench_broken.y)
	var whole_id := WorldData.place_id("site", bench_whole.x, bench_whole.y)
	var cairn_id := WorldData.place_id("peak", cairn_broken.x, cairn_broken.y)
	check(repairs.is_broken(pier_id) and repairs.is_broken(bench_id) and repairs.is_broken(cairn_id) and not repairs.is_broken(whole_id), "исходное состояние: причал, лавка и тур сломаны, одна лавка цела")
	check(Repairables.kind_of({kind = "site", src = sites[0]}) == "bench" and Repairables.kind_of({kind = "site", src = sites[2]}) == "pier" and Repairables.kind_of({kind = "peak"}) == "cairn" and Repairables.kind_of({kind = "lake"}) == "", "виды объектов по видам мест")
	var measured := FishingLayout.measure(h, Vector3(pier_at.x * TILE, h.ground_at(pier_at.x * TILE, pier_at.y * TILE), pier_at.y * TILE), PI * 0.5)
	check(measured.len > 6.0 and measured.len < FishingLayout.MAX_LEN and measured.dy > measured.water, "длина причала по воде: %.1f м, верх %.2f над домиком, вода %.2f" % [measured.len, measured.dy, measured.water])
	_walk_pier(pier_at)
	check(Heightfield.native_ride_checks > 100 and Heightfield.native_ride_mismatches.is_empty(),
		"C# и GDScript совпадают: сверок %d, расхождений %d" % [Heightfield.native_ride_checks, Heightfield.native_ride_mismatches.size()])
	var parent := Node3D.new()
	root.add_child(parent)
	var settlements := Node3D.new()
	parent.add_child(settlements)
	built = SettlementsBuilder.build(settlements, w, h)
	layer = RepairLayer.new()
	parent.add_child(layer)
	layer.setup(built.repairables, built.windows, repairs)
	check(layer.has(pier_id) and layer.has(bench_id) and layer.has(whole_id) and layer.has(cairn_id) and layer.kind(pier_id) == "pier", "слой знает все объекты (%d)" % built.repairables.size())
	check(layer._nodes.has(pier_id) and layer._nodes.has(bench_id) and layer._nodes.has(cairn_id) and not layer._nodes.has(whole_id), "слой рисует причал и сломанные; целая лавка — в общем батче")
	# наведение: сломанное — «починить», целая лавка — «сесть»; сиденье смотрит туда же, куда модель
	var near := layer.items(Vector3(bench_whole.x * TILE, h.ground_at(bench_whole.x * TILE, bench_whole.y * TILE) + 1.6, bench_whole.y * TILE), 3.0)
	check(near.any(func(it: Dictionary) -> bool: return it.kind == "bench" and it.id == whole_id) and not near.any(func(it: Dictionary) -> bool: return it.kind == "repair"), "у целой лавки — «сесть»")
	var seat := layer.seat(whole_id)
	var facing := Vector2(-sin(seat.yaw), -cos(seat.yaw))
	check(not seat.is_empty() and facing.distance_to(Vector2(sin(0.4), cos(0.4))) < 0.01, "сиденье смотрит вперёд по модели")
	var broken_items := layer.items(Vector3(bench_broken.x * TILE, h.ground_at(bench_broken.x * TILE, bench_broken.y * TILE) + 1.6, bench_broken.y * TILE), 3.0)
	check(broken_items.any(func(it: Dictionary) -> bool: return it.kind == "repair" and it.id == bench_id and it.repair_kind == "bench"), "у сломанной лавки — «починить»")
	var shots := not ("--no-shots" in OS.get_cmdline_user_args()) and DisplayServer.get_name() != "headless"
	if shots:
		await _shots(parent, "broken", [pier_at, bench_whole, bench_broken, Vector2(cairn_whole.x, cairn_whole.y), Vector2(cairn_broken.x, cairn_broken.y)])
	var before: Node = layer._nodes[bench_id]
	_check_repair_hold(bench_id, pier_id)
	layer.repair(pier_id)
	layer.repair(cairn_id)
	check(not repairs.is_broken(bench_id) and layer._nodes.get(bench_id) != before and not repairs.is_broken(pier_id) and not repairs.is_broken(cairn_id), "после ремонта состояние сменилось, модели пересобраны")
	var near_fixed := layer.items(Vector3(bench_broken.x * TILE, h.ground_at(bench_broken.x * TILE, bench_broken.y * TILE) + 1.6, bench_broken.y * TILE), 3.0)
	check(near_fixed.any(func(it: Dictionary) -> bool: return it.kind == "bench" and it.id == bench_id), "починенная лавка — снова «сесть»")
	var saved := repairs.save_state()
	var again := Repairables.new(w.seed_num)
	check(Repairables.valid_save(saved) and not Repairables.valid_save({repaired = {"x": false}}) and not Repairables.valid_save({}), "сохранение починенного проверяется")
	again.restore(saved)
	check(not again.is_broken(bench_id) and not again.is_broken(pier_id) and not again.is_broken(cairn_id), "после загрузки починенное цело")
	if shots:
		await _shots(parent, "fixed", [pier_at, bench_whole, bench_broken, Vector2(cairn_whole.x, cairn_whole.y), Vector2(cairn_broken.x, cairn_broken.y)])
	print("ИТОГО: %s" % ("всё прошло" if failures == 0 else "%d провалов" % failures))
	quit(1 if failures else 0)


func _check_repair_hold(bench_id: String, other_id: String) -> void:
	var shell: Node = load("res://scenes/main.tscn").instantiate()
	shell.set_script(null)
	root.add_child(shell)
	var hud := shell.get_node("%Hud") as Hud
	hud.world = w
	hud.show()
	var sounds := TestAudio.new()
	hud.add_child(sounds)
	hud.interaction_audio = sounds
	var game: GameWorld = load("res://scenes/game_world.tscn").instantiate()
	root.add_child(game)
	game.set_process(false)
	game.set_physics_process(false)
	game.services = ServiceScope.new()
	var pad := TestControls.new()
	game.services.controls = pad
	game.world = w
	game.heights = h
	game.hud = hud
	game.player = PlayerState.new()
	game.bike = BikeRide.new()
	game.crash = BikeCrash.new()
	game.add_child(game.crash)
	game.photo = GameWorld.PhotoCamera.new()
	game.add_child(game.photo)
	game.quests = GameWorld.Quests.new()
	game.repair_layer = layer

	var center: Vector3 = layer._specs[bench_id].box.at.origin
	var eye := center + Vector3(0, 0.45, 2.0)
	game.player.x = eye.x
	game.player.z = eye.z
	game.player.feet = eye.y - GameConfig.EYE
	game.camera.position = eye
	game.camera.look_at(center)
	var bench := game._aim()
	check(bench.get("id") == bench_id, "прицел захватывает сломанную лавку")
	game._target = bench
	game._update_hints()
	hud.note_interaction_target(bench_id)
	hud.note_interaction_target(bench_id)
	hud._reticle_tween.custom_step(0.065)
	check(sounds.play_counts.get(&"reticle_target_lock", 0) == 1 and hud._reticle_open > 1.0,
		"прицел раскрывается с EaseOutBack и одним звуком на объект")
	hud._reticle_tween.custom_step(0.045)
	check(is_equal_approx(hud._reticle_open, 1.0), "уголки приходят на место за 110 мс")

	Input.action_press("interact")
	game._tick_repair(DT)
	var arc := hud._repair
	check(arc.visible and is_equal_approx(arc.scale.x, 0.88), "дуга появляется в масштабе 0.88")
	arc._motion.custom_step(0.10)
	for i in 26:
		game._tick_repair(DT)
	check(sounds.pitches == [0.9] and pad.pulses.size() == 1 and is_equal_approx(pad.pulses[0].x, 0.12),
		"ровно на 0.45 с звучит первая отметка и идёт лёгкий импульс")
	arc._motion.custom_step(0.055)
	check(is_equal_approx(arc.scale.x, 1.02), "дуга откликается микропульсацией")
	Input.action_release("interact")
	game._tick_repair(DT)
	var released_value := arc.value
	arc._motion.custom_step(0.09)
	check(sounds.play_counts.get(&"repair_reset", 0) == 1 and arc.value < released_value
		and arc.modulate.a < 1.0 and arc.visible, "отпускание запускает спад дуги и звук сброса")
	arc._motion.custom_step(0.091)
	check(not arc.visible and repairs.is_broken(bench_id), "через 180 мс дуга скрыта, лавка ещё сломана")

	Input.action_press("interact")
	game._tick_repair(1.5)
	game._target = {kind = "repair", id = other_id}
	game._tick_repair(DT)
	check(game._fix_target == other_id and is_equal_approx(game._fix_elapsed, DT),
		"перевод взгляда на другой объект не переносит удержание")
	game._target = {}
	game._tick_repair(DT)
	check(game._fix_target.is_empty() and sounds.play_counts.get(&"repair_reset", 0) == 3,
		"потеря цели сбрасывает удержание при нажатой кнопке")

	sounds.pitches.clear()
	pad.pulses.clear()
	game._target = bench
	for i in 239:
		game._tick_repair(DT)
	check(repairs.is_broken(bench_id) and sounds.pitches.size() == 8 and pad.pulses.size() == 8
		and is_equal_approx(sounds.pitches.front(), 0.9) and is_equal_approx(sounds.pitches.back(), 1.25),
		"до 4 с идут восемь повышающихся отметок, объект ещё сломан")
	game._tick_repair(DT)
	game._tick_repair(DT) # Наведение ещё не обновилось, но завершение должно быть однократным.
	Input.action_release("interact")
	check(not repairs.is_broken(bench_id) and sounds.play_counts.get(&"repair_done", 0) == 1
		and pad.pulses.size() == 9 and pad.pulses.back().is_equal_approx(Vector3(0.35, 0.5, 0.12))
		and arc.visible and is_equal_approx(arc.value, 1.0), "на 4 с смена модели, полная дуга, стук и тяжёлый импульс")
	arc._motion.custom_step(0.08)
	check(is_equal_approx(arc._flash, 1.0) and arc.scale.x > 1.0, "после ремонта дуга белеет и расширяется")
	arc._motion.custom_step(0.181)
	check(not arc.visible, "вспышка длится 260 мс")
	game.queue_free()
	shell.queue_free()


## Выйти по причалу от суши до конца и вернуться: с настила не упасть (ноги на отметке), вода по бокам не пускает
func _walk_pier(at: Vector2) -> void:
	var yaw := PI * 0.5
	var basis := Basis(Vector3.UP, yaw)
	var origin := Vector3(at.x * TILE, 0.0, at.y * TILE)
	origin.y = SettlementsBuilder.hut_floor(h, origin.x, origin.z, yaw, "house_timber")
	var m := FishingLayout.measure(h, origin, yaw)
	var start := origin + basis * Vector3(0.0, 0.0, FishingLayout.START + 0.2)
	var p := PlayerState.new()
	p.x = start.x
	p.z = start.z
	p.feet = h.surface_at(p.x, p.z, -INF)
	var end_distance: float = FishingLayout.START + m.len - 0.6
	var look := atan2(-basis.z.x, -basis.z.z)
	var reached := false
	var lowest := INF
	for tick in 60 * 40:
		p.step(1.0, 0.0, false, false, look, DT, w, h)
		var along := (Vector3(p.x, 0, p.z) - Vector3(origin.x, 0, origin.z)).dot(basis.z)
		lowest = minf(lowest, p.feet)
		if along >= end_distance:
			reached = true
			break
	check(reached, "ходок дошёл по причалу до конца (%.1f м, ноги %.2f, настил %.2f)" % [FishingLayout.START + m.len, p.feet, origin.y + m.dy])
	check(absf(p.feet - (origin.y + m.dy)) < 0.2, "на конце причала ноги на настиле, не в воде")
	# вбок с настила не уйти «по воде»: поперёк упираемся в глубину, ноги остаются на досках или на дне, а не плывут
	var side := atan2(-basis.x.x, -basis.x.z)
	var from := Vector2(p.x, p.z)
	for tick in 60 * 4:
		p.step(1.0, 0.0, false, false, side, DT, w, h)
	var lateral := Vector2(p.x, p.z).distance_to(from)
	check(lateral < 3.0, "с причала в сторону на глубину не выйти (сдвиг %.1f м)" % lateral)


func _shots(parent: Node3D, tag: String, spots: Array) -> void:
	if not parent.has_node("Env"):
		var ground := _ground_mesh()
		ground.name = "Ground"
		parent.add_child(ground)
		var water := MeshInstance3D.new()
		var plane := PlaneMesh.new()
		plane.size = Vector2(160, 120)
		water.mesh = plane
		var wm := StandardMaterial3D.new()
		wm.albedo_color = Color(0.2, 0.45, 0.6)
		water.material_override = wm
		water.position = Vector3(CENTER.x * TILE + 60.0, h.lake_level(110.0 * TILE, 96.0 * TILE), 96.0 * TILE)
		parent.add_child(water)
		var sun := DirectionalLight3D.new()
		sun.rotation_degrees = Vector3(-45, 40, 0)
		sun.shadow_enabled = true
		parent.add_child(sun)
		var env := WorldEnvironment.new()
		env.name = "Env"
		env.environment = Environment.new()
		env.environment.background_mode = Environment.BG_COLOR
		env.environment.background_color = Color(0.62, 0.78, 0.92)
		env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.environment.ambient_light_color = Color(0.7, 0.75, 0.8)
		parent.add_child(env)
		var cam := Camera3D.new()
		cam.name = "Cam"
		cam.far = 400.0
		parent.add_child(cam)
		root.size = Vector2i(1280, 720)
	var cam: Camera3D = parent.get_node("Cam")
	var names := ["pier", "bench_whole", "bench_broken", "cairn_whole", "cairn_broken"]
	var offsets: Array[Vector3] = [Vector3(-6, 4, 14), Vector3(3.5, 1.8, 3.5), Vector3(3.5, 1.8, 3.5), Vector3(5, 2.6, 5), Vector3(5, 2.6, 5)]
	var looks: Array[Vector3] = [Vector3(8, -0.5, 0), Vector3(0, 0.5, 0), Vector3(0, 0.5, 0), Vector3(0, 1.2, 0), Vector3(0, 1.2, 0)]
	for k in spots.size():
		var at: Vector2 = spots[k]
		var ground_at := Vector3(at.x * TILE, h.ground_at(at.x * TILE, at.y * TILE), at.y * TILE)
		cam.position = ground_at + offsets[k]
		cam.look_at(ground_at + looks[k])
		for i in 8:
			await process_frame
		var path := out.path_join("repair_%s_%s.png" % [names[k], tag])
		root.get_viewport().get_texture().get_image().save_png(path)
	print("снимки ", out)


func _ground_mesh() -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cx := CENTER.x * TILE
	var cz := CENTER.y * TILE
	var step := 2.0
	var n := 60
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
