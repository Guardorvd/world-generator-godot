extends SceneTree
## 28.11.2026: поиск резких переключений позы седока и рамы при смене условий — без мира.
## Игровая модель и BikeView, ввод как в игре (педали, накат, тормоз, руль, рывок), рельеф — профиль по пройденному пути.
## В каждом сценарии меняется одно условие; для каждого канала позы (BikeView._cur) и кости седока в осях велосипеда
## считается «рывок» — наибольшая вторая разность за такт (изменение скорости движения). Печатает худшие каналы
## сценария, такт пика и что в этот момент делал ввод. Без окна — секунды.
## --capture (нужно окно) — кадры из игровой камеры вокруг пика в .godot/pose_switch/<сценарий><tag>/, --only <имя,...>,
## --tag <суффикс>, --top <n> (по умолчанию 6).

const Stand := preload("res://tools/bike_stand.gd")
const DT := 1.0 / 60.0

class Road extends WorldData:
	func accessible(_x: float, _z: float, _margin := 0.0) -> bool:
		return true
	func tile_info(_x: float, _z: float) -> Dictionary:
		return {biome = Biomes.GRASS, path = 3}

## Профиль высоты по пройденному пути d = −z (велосипед едет на север).
class Profile extends Heightfield:
	var kind := "flat"
	func h(z: float) -> float:
		var d := -z
		match kind:
			"climb": # ровно, подъём 12 % с 30 м, снова ровно с 70 м (плавные перегибы по 6 м)
				return _ramp(d, 30.0, 70.0, 0.12)
			"descent":
				return _ramp(d, 30.0, 90.0, -0.12)
			"bumps": # ровно, потом гребёнка 0,8 м шагом, высота 3 см, с 40 до 70 м
				var k := smoothstep(38.0, 42.0, d) * (1.0 - smoothstep(68.0, 72.0, d))
				return k * 0.03 * sin(d * TAU / 0.8)
			"step": # ступень вниз 0,35 м на 40 м
				return -0.35 if d > 40.0 else 0.0
		return 0.0
	func _ramp(d: float, a: float, b: float, g: float) -> float:
		var s := 3.0
		return g * (_soft(d - a, s) - _soft(d - b, s))
	func _soft(x: float, s: float) -> float:
		# интеграл гладкой ступени: 0 до −s, x после +s, парабола между
		if x <= -s:
			return 0.0
		if x >= s:
			return x
		return (x + s) * (x + s) / (4.0 * s)
	func ground_at(_x: float, z: float, _raw := false) -> float:
		return h(z)
	func surface_at(_x: float, z: float, _feet := -INF) -> float:
		return h(z)
	func depth_at(_x: float, _z: float, _feet := -INF) -> float:
		return 0.0
	func known(_x: float, _z: float) -> bool:
		return true
	func ceiling_at(_x: float, _z: float, _feet := -INF) -> float:
		return INF

## Сценарий: начальная скорость, профиль, длина в тактах и ввод по отрезкам [с такта, газ (1 педали, 0 накат, <0 тормоз), руль, рывок].
const SCENES := {
	"pedal_coast": {pace = 8.0, ground = "flat", ticks = 300, input = [[0, 1.0, 0.0, false], [90, 0.0, 0.0, false], [190, 1.0, 0.0, false]]},
	"brake": {pace = 12.0, ground = "flat", ticks = 240, input = [[0, 0.0, 0.0, false], [60, -1.0, 0.0, false], [100, 0.0, 0.0, false]]},
	"brake_light": {pace = 10.0, ground = "flat", ticks = 240, input = [[0, 1.0, 0.0, false], [60, -0.35, 0.0, false], [120, 1.0, 0.0, false]]},
	"stop_start": {pace = 5.0, ground = "flat", ticks = 420, input = [[0, 0.0, 0.0, false], [30, -1.0, 0.0, false], [220, 1.0, 0.0, false]]},
	"climb": {pace = 7.0, ground = "climb", ticks = 720, input = [[0, 1.0, 0.0, false]]},
	"descent": {pace = 9.0, ground = "descent", ticks = 600, input = [[0, 0.0, 0.0, false]]},
	"bumps": {pace = 9.0, ground = "bumps", ticks = 480, input = [[0, 1.0, 0.0, false]]},
	"surge": {pace = 7.0, ground = "flat", ticks = 300, input = [[0, 1.0, 0.0, false], [60, 1.0, 0.0, true], [150, 1.0, 0.0, false]]},
	"step_down": {pace = 8.0, ground = "step", ticks = 360, input = [[0, 1.0, 0.0, false]]},
	"turn_brake": {pace = 11.0, ground = "flat", ticks = 300, input = [[0, 0.0, 1.0, false], [60, -0.6, 1.0, false], [120, 0.0, 1.0, false], [180, 0.0, 0.0, false]]},
	"turn_pedal": {pace = 8.0, ground = "flat", ticks = 300, input = [[0, 1.0, 0.0, false], [40, 1.0, 1.0, false], [100, 0.0, 1.0, false], [160, 1.0, 1.0, false], [220, 1.0, 0.0, false]]},
}

## Каналы позы, которые не стоит мерить (положение, накопительные углы, вращение колёс, нагрев).
const SKIP := ["S_X", "S_BODY_Y", "S_Z", "S_HEADING", "S_CRANK", "S_WHEEL_F", "S_WHEEL_R", "S_HEAT_F", "S_HEAT_R",
	"S_SPEED", "S_FOOT_X", "S_FOOT_Y", "S_FOOT_Z", "S_PLACEMENT"]
const BONES := ["Hips", "Chest", "Head", "HandL", "HandR", "FootL", "FootR", "LowerLegL", "LowerLegR"]

var view: BikeView
var cam: Camera3D
var capture := false
var tag := ""
var top := 6
var channels := {}

func _init() -> void:
	preload("res://tools/watchdog.gd").arm(self, 240)
	run.call_deferred()

func run() -> void:
	capture = OS.get_cmdline_user_args().has("--capture") and DisplayServer.get_name() != "headless"
	tag = Stand.arg("--tag", "")
	top = int(Stand.arg("--top", "6"))
	if capture:
		Stand.setup(root)
		((root.get_node("Ground") as MeshInstance3D).mesh as PlaneMesh).size = Vector2(60, 400)
	cam = Camera3D.new()
	root.add_child(cam)
	cam.current = true
	view = preload("res://scenes/bike.tscn").instantiate()
	root.add_child(view)
	# Имена каналов позы из перечисления BikeView.
	var consts := (BikeView as Script).get_script_constant_map()
	for name: String in consts:
		if name.begins_with("S_") and not SKIP.has(name) and consts[name] is int:
			channels[name] = consts[name]
	var only := Stand.arg("--only", "")
	print("POSE SWITCH | %s" % (tag if tag != "" else "текущий код"))
	print("рывок: каналы S_ — сотые доли (или сотые радиана)/такт², рама — °/такт², кости — мм/такт² в осях велосипеда; «ввод» — что было за 0,3 с до пика")
	for scene: String in SCENES:
		if only != "" and not only.split(",").has(scene):
			continue
		await ride(scene, SCENES[scene])
	quit()

func input_at(spec: Array, t: int) -> Array:
	var cur: Array = spec[0]
	for seg: Array in spec:
		if t >= int(seg[0]):
			cur = seg
	return cur

func ride(scene: String, spec: Dictionary) -> void:
	var road := Road.new()
	var ground := Profile.new()
	ground.kind = spec.ground
	ground.world = road
	var state := BikeRide.new()
	var player := PlayerState.new()
	state.mount(player)
	state.speed = spec.pace
	var controls := Controls.new()
	var camera := PlayerCameraController.new()
	camera.settings = GameSettings.new()
	camera.heights = ground
	camera.pitch = -0.08
	camera._cam_y = PlayerCameraController.RIDE_HEIGHT
	view.snap(state)
	var sk := view.rider.skeleton
	var series := {}
	var events := []
	var warm := 60
	for tick in warm + int(spec.ticks):
		var t := tick - warm
		var inp: Array = input_at(spec.input, maxi(t, 0))
		camera.store_previous(player, tick * DT)
		if t < 0:
			state.speed = spec.pace
		state.step(player, inp[1], controls.bike_steer(inp[2], DT, state.speed), inp[3], false, DT, road, ground)
		camera.tick_effects(DT)
		view.tick(state, DT, maxf(inp[1], 0.0), inp[3])
		view.draw(1.0)
		camera.update(1.0, DT, player, state, cam, tick * DT, false, false,
			false, false, camera.settings.fov, view.view_squash(), view.position.y, view.view_roll())
		if t < 0:
			state.clear_tick_events()
			continue
		events.append("v=%.1f %s%s%s" % [state.speed, "педали" if inp[1] > 0.0 else ("тормоз" if inp[1] < 0.0 else "накат"),
			" руль" if inp[2] != 0.0 else "", " рывок" if inp[3] else ""] + (" полёт" if state.airborne else ""))
		for name: String in channels:
			_add(series, name, view._cur[channels[name]] * 100.0)
		_add(series, "рама крен°", rad_to_deg(view._cur[BikeView.S_ROLL]))
		_add(series, "рама тангаж°", rad_to_deg(view._cur[BikeView.S_TILT]))
		for bone: String in BONES:
			var p := sk.get_bone_global_pose(sk.find_bone(bone)).origin * 1000.0
			_add(series, bone + ".x", p.x)
			_add(series, bone + ".y", p.y)
			_add(series, bone + ".z", p.z)
		if capture:
			await RenderingServer.frame_post_draw
			var dir := "res://.godot/pose_switch/%s%s" % [scene, tag]
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
			var img := root.get_texture().get_image()
			var c := cam.unproject_position(view.global_position)
			var size := Vector2i(int(img.get_height() * 0.36), int(img.get_height() * 0.42))
			var at := (Vector2i(int(c.x) - size.x / 2, int(c.y) - int(size.y * 0.8))).clamp(Vector2i.ZERO, Vector2i(img.get_width(), img.get_height()) - size)
			img.get_region(Rect2i(at, size)).save_png(ProjectSettings.globalize_path(dir).path_join("%03d.png" % t))
		state.clear_tick_events()
	# Худшие каналы по рывку.
	var ranked := []
	for name: String in series:
		var v: PackedFloat32Array = series[name]
		var best := 0.0
		var at := 0
		for i in range(2, v.size()):
			var d := absf(v[i] - 2.0 * v[i - 1] + v[i - 2])
			if d > best:
				best = d
				at = i
		ranked.append([best, name, at])
	ranked.sort_custom(func(a, b): return a[0] > b[0])
	print("\n== %s (%s, %.0f м/с)" % [scene, spec.ground, spec.pace])
	for i in mini(top, ranked.size()):
		var r: Array = ranked[i]
		var at: int = r[2]
		print("  %-16s %8.2f  такт %3d  | %s ← %s" % [r[1], r[0], at, events[at], events[maxi(at - 18, 0)]])

func _add(series: Dictionary, name: String, value: float) -> void:
	if not series.has(name):
		series[name] = PackedFloat32Array()
	series[name].append(value)
