extends SceneTree
## 28.11.2026: подруливание с клавиатуры глазами игрока — без мира, на ровной земле, игровая модель, BikeView и камера.
## Ввод проходит тем же путём, что в игре (Controls.bike_steer → BikeRide.step → BikeView.tick/draw → PlayerCameraController).
## Сценарии: нажатия разной длины, перекладка, серия коротких нажатий. Из каждого вычитается прямой проезд.
## Печатает на каждый сценарий: поворот курса, наибольший крен рамы и седока, поворот головы и «рывок» —
## наибольшее изменение скорости (вторая разность за такт) крена, головы на экране и взгляда.
## Без окна — только числа (секунды). С --capture (нужно окно) пишет кадры и листы:
##   steer_motion_<скорость>.png — по строке на сценарий, кадры через 3 такта, вырезка вокруг седока.
## Ключи: --pace 8,16 (м/с), --mode pedal|coast, --out <папка>, --tag <суффикс к именам>, --frames (сохранить все кадры).
## «Было» — тем же запуском на прежнем коде (копия проекта или git stash), с --tag _old.

const Stand := preload("res://tools/bike_stand.gd")
const DT := 1.0 / 60.0
const WARMUP := 90
const LENGTH := 96
const SHEET_EVERY := 3
const SHEET_FRAMES := 16

class Road extends WorldData:
	func accessible(_x: float, _z: float, _margin := 0.0) -> bool:
		return true
	func tile_info(_x: float, _z: float) -> Dictionary:
		return {biome = Biomes.GRASS, path = 3}

class Floor extends Heightfield:
	func ground_at(_x: float, _z: float, _raw := false) -> float:
		return 0.0
	func surface_at(_x: float, _z: float, _feet := -INF) -> float:
		return 0.0
	func depth_at(_x: float, _z: float, _feet := -INF) -> float:
		return 0.0
	func known(_x: float, _z: float) -> bool:
		return true
	func ceiling_at(_x: float, _z: float, _feet := -INF) -> float:
		return INF

## Сценарий: список отрезков [начало такта, конец такта, команда −1..1].
const SCENES := {
	"tap_03": [[0, 3, 1.0]],
	"tap_06": [[0, 6, 1.0]],
	"tap_09": [[0, 9, 1.0]],
	"tap_12": [[0, 12, 1.0]],
	"tap_15": [[0, 15, 1.0]],
	"tap_20": [[0, 20, 1.0]],
	"tap_30": [[0, 30, 1.0]],
	"hold_60": [[0, 60, 1.0]],
	"swap": [[0, 24, 1.0], [24, 48, -1.0]],
	"pulses": [[0, 4, 1.0], [10, 14, 1.0], [20, 24, 1.0], [30, 34, 1.0]],
}

var output: String
var tag: String
var capture := false
var all_frames := false
var cam: Camera3D
var view: BikeView

func _init() -> void:
	preload("res://tools/watchdog.gd").arm(self, 240)
	run.call_deferred()

func run() -> void:
	output = Stand.arg("--out", "res://.godot/steer_motion")
	tag = Stand.arg("--tag", "")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	capture = OS.get_cmdline_user_args().has("--capture") and DisplayServer.get_name() != "headless"
	all_frames = OS.get_cmdline_user_args().has("--frames")
	var mode := Stand.arg("--mode", "pedal")
	if capture:
		Stand.setup(root)
		var ground := root.get_node("Ground") as MeshInstance3D
		(ground.mesh as PlaneMesh).size = Vector2(160, 400)
		# Две светлые полосы дороги, чтобы курс читался на кадре.
		for side in [-1.0, 1.0]:
			var stripe := MeshInstance3D.new()
			var strip := PlaneMesh.new()
			strip.size = Vector2(0.08, 380)
			stripe.mesh = strip
			var material := StandardMaterial3D.new()
			material.albedo_color = Color(0.58, 0.55, 0.47)
			stripe.material_override = material
			root.add_child(stripe)
			stripe.position = Vector3(side * 2.0, 0.003, -150.0)
	cam = Camera3D.new()
	root.add_child(cam)
	cam.current = true
	view = preload("res://scenes/bike.tscn").instantiate()
	root.add_child(view)
	print("STEER MOTION %s | %s" % [mode, tag if tag != "" else "текущий код"])
	print("сценарий   | курс° | крен рамы° | крен седока° | взгляд° | рывок: крен°/т² | голова px/т² | взгляд°/т² | кисть px/т²")
	for pace_text in Stand.arg("--pace", "8,16").split(","):
		var pace := float(pace_text)
		var base := await ride("straight", [], pace, mode)
		var rows := {}
		for scene: String in SCENES:
			rows[scene] = await ride(scene, SCENES[scene], pace, mode)
			report(scene, pace, rows[scene], base)
		if capture:
			sheet(pace, rows)
	quit()

func command(segments: Array, t: int) -> float:
	for seg: Array in segments:
		if t >= int(seg[0]) and t < int(seg[1]):
			return float(seg[2])
	return 0.0

func ride(scene: String, segments: Array, pace: float, mode: String) -> Array:
	var road := Road.new()
	var floor := Floor.new()
	floor.world = road
	var state := BikeRide.new()
	var player := PlayerState.new()
	state.mount(player)
	state.speed = pace
	var controls := Controls.new()
	var camera := PlayerCameraController.new()
	camera.settings = GameSettings.new()
	camera.heights = floor
	camera.pitch = -0.08
	camera.yaw = 0.0
	camera._cam_y = PlayerCameraController.RIDE_HEIGHT
	cam.fov = camera.settings.fov
	view.snap(state)
	var sk := view.rider.skeleton
	var head := sk.find_bone("Head")
	var hand := sk.find_bone("HandR")
	var hips := sk.find_bone("Hips")
	var rows := []
	var throttle := 1.0 if mode == "pedal" else 0.0
	for tick in WARMUP + LENGTH:
		var t := tick - WARMUP
		var raw := command(segments, t) if t >= 0 else 0.0
		camera.store_previous(player, tick * DT)
		# Скорость держится постоянной: сравнивается сам переход, а не разгон.
		state.speed = pace
		state.step(player, throttle, controls.bike_steer(raw, DT, state.speed), false, false, DT, road, floor)
		camera.tick_effects(DT)
		view.tick(state, DT, throttle)
		view.draw(1.0)
		camera.update(1.0, DT, player, state, cam, tick * DT, false, false,
			false, false, camera.settings.fov, view.view_squash(), view.position.y, view.view_roll())
		if t >= 0:
			var bike_px := cam.unproject_position(view.global_position)
			rows.append({
				"raw": raw, "steer": state.steer, "heading": state.heading, "lean": state.lean,
				"rider": state.rider_lean, "look": view._mix[BikeView.S_LOOK], "side": view._mix[BikeView.S_SIDE],
				"head": cam.unproject_position(sk.to_global(sk.get_bone_global_pose(head).origin)) - bike_px,
				"hand": cam.unproject_position(sk.to_global(sk.get_bone_global_pose(hand).origin)) - bike_px,
				"hips": cam.unproject_position(sk.to_global(sk.get_bone_global_pose(hips).origin)) - bike_px,
				"x": view.global_position.x,
			})
			if capture and segments.size() > 0 and (all_frames or (t % SHEET_EVERY == 0 and t < SHEET_EVERY * SHEET_FRAMES)):
				await RenderingServer.frame_post_draw
				var img := root.get_texture().get_image()
				rows[-1]["img"] = crop(img, bike_px)
				if all_frames:
					var dir := output.path_join("%s_%d%s" % [scene, int(pace), tag])
					DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
					rows[-1]["img"].save_png(dir.path_join("%03d.png" % t))
		state.clear_tick_events()
	return rows

func crop(img: Image, center: Vector2) -> Image:
	# Вырезка вокруг седока (камера вида от третьего лица держит его в одном месте кадра).
	var size := Vector2i(int(img.get_height() * 0.30), int(img.get_height() * 0.36))
	var at := Vector2i(int(center.x) - size.x / 2, int(center.y) - int(size.y * 0.80))
	at = at.clamp(Vector2i.ZERO, Vector2i(img.get_width(), img.get_height()) - size)
	return img.get_region(Rect2i(at, size))

## Наибольшая вторая разность ряда (изменение скорости за такт) — мера рывка.
func jerk(values: Array) -> float:
	var top := 0.0
	for i in range(2, values.size()):
		var a: Variant = values[i]
		var b: Variant = values[i - 1]
		var c: Variant = values[i - 2]
		var d: Variant = a - 2.0 * b + c
		top = maxf(top, d.length() if d is Vector2 else absf(d))
	return top

func peak(values: Array) -> float:
	var top := 0.0
	for v: float in values:
		top = maxf(top, absf(v))
	return top

func report(scene: String, pace: float, rows: Array, base: Array) -> void:
	var roll := []
	var rider := []
	var look := []
	var head := []
	var hand := []
	for i in rows.size():
		roll.append(rad_to_deg(rows[i].lean - base[i].lean))
		rider.append(rad_to_deg(rows[i].rider - base[i].rider))
		look.append(rad_to_deg(rows[i].look - base[i].look))
		head.append(rows[i].head - base[i].head)
		hand.append(rows[i].hand - base[i].hand)
	var turn := rad_to_deg(angle_difference(base[-1].heading, rows[-1].heading))
	print("%-6s %2d | %5.1f | %10.2f | %12.2f | %7.2f | %15.3f | %12.2f | %10.3f | %11.2f" % [
		scene, int(pace), turn, peak(roll), peak(rider), peak(look),
		jerk(roll), jerk(head), jerk(look), jerk(hand)])
	# Ход по тактам для разбора: команда, руль, крен рамы, взгляд (каждый 3-й такт).
	var line := "   ход %s %d:" % [scene, int(pace)]
	for i in range(0, mini(rows.size(), 60), 3):
		line += " %d:%.2f/%.1f/%.1f" % [i, rows[i].steer, roll[i], look[i]]
	print(line)

func sheet(pace: float, rows: Dictionary) -> void:
	var first: Image = null
	for scene: String in rows:
		if rows[scene].size() > 0 and rows[scene][0].has("img"):
			first = rows[scene][0]["img"]
			break
	if first == null:
		return
	var w := first.get_width()
	var h := first.get_height()
	var out := Image.create(w * SHEET_FRAMES, h * rows.size(), false, first.get_format())
	var r := 0
	for scene: String in rows:
		var c := 0
		for i in range(0, rows[scene].size(), SHEET_EVERY if all_frames else 1):
			if not rows[scene][i].has("img"):
				continue
			if c >= SHEET_FRAMES:
				break
			var img: Image = rows[scene][i]["img"]
			out.blit_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), Vector2i(c * w, r * h))
			# Полоска над кадром: зелёная, пока клавиша нажата.
			if rows[scene][i].raw != 0.0:
				out.fill_rect(Rect2i(c * w, r * h, w, 6), Color(0.2, 0.8, 0.3) if rows[scene][i].raw > 0.0 else Color(0.9, 0.4, 0.2))
			c += 1
		r += 1
	var path := output.path_join("steer_motion_%d%s.png" % [int(pace), tag])
	out.save_png(path)
	print("лист: %s (строки: %s)" % [ProjectSettings.globalize_path(path), ", ".join(rows.keys())])
