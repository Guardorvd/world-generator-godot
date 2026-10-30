extends "res://tools/bike_drive_test.gd"
## Вид сбоку на седока без генерации мира: один заезд старт → педали → накат → удар о бревно → Q→E прыжок →
## посадка → полный тормоз → стоянка. Физика — BikeRide.step, вид — BikeView, как в игре. Снимки ключевых моментов
## собираются в один лист side_sheet.png (3×3, слева направо и сверху вниз). Нужно окно.
##   godot --path . --script res://tools/bike_side_look.gd -- [--out <папка>]

const HZ := 60
const MOMENTS := ["старт 0,1 с", "педали", "накат", "удар передним", "удар задним", "Q: нос вверх", "прыжок", "посадка", "тормоз 0,3 с"]

var out := ""
var view: Node3D
var camera: Camera3D
var frames: Array[Image] = []


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 90)
	var args := OS.get_cmdline_user_args()
	var at := args.find("--out")
	out = args[at + 1] if at >= 0 and at + 1 < args.size() else OS.get_user_data_dir().path_join("bike_side_look")
	DirAccess.make_dir_recursive_absolute(out)
	root.size = Vector2i(960, 540)
	_scene()
	look.call_deferred()


func _scene() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.62, 0.72, 0.85)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.8, 0.82, 0.9)
	e.ambient_light_energy = 0.5
	env.environment = e
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, 30.0, 0.0)
	root.add_child(sun)
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(60, 80)
	_mesh(floor_mesh, Vector3(0, 100.0, -10.0), Color(0.45, 0.4, 0.3))
	# бревно поперёк пути — там же, где его опора у EdgeLog (z от -1,3 до -1,0, верх 0,15 м)
	var log_mesh := BoxMesh.new()
	log_mesh.size = Vector3(3.0, 0.15, 0.3)
	_mesh(log_mesh, Vector3(0, 100.075, -1.15), Color(0.4, 0.28, 0.18))
	# метки каждые 2 м, чтобы видеть ход
	for i in 20:
		var mark := BoxMesh.new()
		mark.size = Vector3(0.05, 0.01, 0.4)
		_mesh(mark, Vector3(1.2, 100.005, 14.0 - i * 2.0), Color(0.9, 0.9, 0.9))
	view = load("res://scenes/bike.tscn").instantiate()
	root.add_child(view)
	camera = Camera3D.new()
	camera.fov = 50.0
	root.add_child(camera)
	camera.make_current()


func _mesh(mesh: Mesh, at: Vector3, color: Color) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	var m := MeshInstance3D.new()
	m.mesh = mesh
	m.material_override = mat
	m.position = at
	root.add_child(m)


func _frame(b: BikeRide) -> void:
	camera.look_at_from_position(Vector3(b.x + 4.2, 101.1, b.z + 0.3), Vector3(b.x, 100.75, b.z))
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	img.resize(480, 270)
	frames.append(img)


func look() -> void:
	var edged := TestGround.new(w)
	var log_obstacle := EdgeLog.new(w, edged)
	log_obstacle.height = 0.0
	edged.obstacles = log_obstacle
	var b := BikeRide.new()
	b.y = 100.0
	b.z = 10.0
	b.mount(p)
	view.snap(b)
	var hit_f := false
	var hit_r := false
	var hop_at := -1
	var nose := false
	var flew := false
	var landed := false
	var brake_at := -1
	var pending := -1 # снимок через 5 тактов после события: седок успевает ответить
	var poses: Array[String] = []
	for tick_i in HZ * 9:
		var t := float(tick_i) / HZ
		var throttle := 1.0 if t < 1.6 else 0.0
		if brake_at >= 0: throttle = -1.0
		# Q→E за 3 м после бревна, как игрок: тело назад 0,2 с, затем вперёд
		if hop_at < 0 and hit_r and b.z < -4.0: hop_at = tick_i
		b.body_back = hop_at >= 0 and tick_i - hop_at < 12
		b.body_forward = hop_at >= 0 and tick_i - hop_at >= 12 and tick_i - hop_at < 30
		if landed and brake_at < 0 and not b.airborne and tick_i - hop_at > 60: brake_at = tick_i
		b.step(p, throttle, 0.0, false, false, 1.0 / HZ, w, edged)
		view.tick(b, 1.0 / HZ, throttle, false)
		view.draw(1.0)
		var shot := tick_i == 6 or tick_i == 70 or tick_i == 120
		var event := false
		if b.wheel_impact.x > 0.0 and not hit_f:
			hit_f = true
			event = true
		elif b.wheel_impact.y > 0.0 and not hit_r:
			hit_r = true
			event = true
		if hop_at >= 0 and not nose and b.lift_f > 0.1:
			nose = true
			shot = true
		if b.airborne and not flew and b.vy < 0.3 and b.vy > -0.3:
			flew = true
			shot = true
		if flew and not landed and b.land_impact > 0.0:
			landed = true
			event = true
		if brake_at >= 0 and tick_i - brake_at == 18:
			shot = true
		b.land_impact = 0.0
		b.wheel_impact = Vector2()
		b.bottom_out = 0.0
		if event: pending = tick_i + 5
		if tick_i == pending: shot = true
		if shot and frames.size() < MOMENTS.size():
			poses.append("%s: сдвиг %.3f, присед %.3f, руль %.2f" % [MOMENTS[frames.size()], view._cur[BikeView.S_SHIFT], view._cur[BikeView.S_CROUCH], view._cur[BikeView.S_STEER]])
			await _frame(b)
		else:
			await process_frame
		if b.crashed: break
	var sheet := Image.create(480 * 3, 270 * 3, false, frames[0].get_format() if not frames.is_empty() else Image.FORMAT_RGBA8)
	for i in frames.size():
		sheet.blit_rect(frames[i], Rect2i(0, 0, 480, 270), Vector2i((i % 3) * 480, (i / 3) * 270))
	sheet.save_png(out.path_join("side_sheet.png"))
	for line in poses: print("  ", line)
	print("bike_side_look: %d снимков из %d (%s) → %s; упал %s" % [frames.size(), MOMENTS.size(), ", ".join(MOMENTS.slice(0, frames.size())), out, b.crashed])
	quit(0)
