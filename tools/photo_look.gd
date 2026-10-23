extends SceneTree
## 11.8: изолированная сцена фотоаппарата (PhotoCamera) без генерации мира. Ровная земля, холм, вершина-конус,
## поселение из коробок, озеро и вышка за холмом. Проверяет наведение (пятно по размеру и дальности, склон
## закрывает место), всплытие названия через DWELL и сразу для узнанного и посещённого, приближение,
## снимок в user://photos (тестовый файл удаляется). Снимки рамки — в --out. Нужно окно.
##   godot --path . --script res://tools/photo_look.gd -- [--out <папка>]

const PhotoCamera = preload("res://scripts/render/photo_camera.gd")
const DT := 1.0 / 60.0
const FOV := 75.0
const HILL := Vector3(0.0, 60.0, -300.0) # вершина холма; радиус основания 120 м

var out := ""
var camera: Camera3D
var photo: PhotoCamera
var failed := 0
var places := {
	peak = {id = "peak", name = "Седая", kind = "Вершина", pos = Vector3(400, 258, -900), radius = 50.0, reach = 2500.0},
	village = {id = "village", name = "Ольховка", kind = "Поселение", pos = Vector3(-120, 9, -200), radius = 40.0, reach = 1500.0},
	lake = {id = "lake", name = "Тихое", kind = "Озеро", pos = Vector3(250, 6, -250), radius = 60.0, reach = 1500.0},
	tower = {id = "tower", name = "Сторожевая", kind = "Дозорная вышка", pos = Vector3(0, 27, -520), radius = 12.0, reach = 700.0},
}
var visited := {}


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--out")
	out = args[at + 1] if at >= 0 and at + 1 < args.size() else OS.get_user_data_dir().path_join("photo_look")
	DirAccess.make_dir_recursive_absolute(out)
	root.size = Vector2i(1280, 720)
	_build()
	_run()


static func ground(x: float, z: float) -> float:
	var d := Vector2(x - HILL.x, z - HILL.z).length() / 120.0
	return HILL.y * maxf(0.0, 1.0 - d * d)


func _build() -> void:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.environment.background_mode = Environment.BG_SKY
	env.environment.sky = sky
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, 30.0, 0.0)
	root.add_child(sun)
	var plane := PlaneMesh.new()
	plane.size = Vector2(4000, 4000)
	_mesh(plane, Vector3.ZERO, Color(0.35, 0.5, 0.28))
	var hill := SphereMesh.new()
	hill.radius = 120.0
	hill.height = 120.0
	_mesh(hill, Vector3(HILL.x, 0.0, HILL.z), Color(0.3, 0.45, 0.25))
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 220.0
	cone.height = 250.0
	_mesh(cone, Vector3(400, 125, -900), Color(0.55, 0.55, 0.6))
	for k in 5:
		var box := BoxMesh.new()
		box.size = Vector3(8, 6, 10)
		_mesh(box, Vector3(-120 + (k % 3) * 16 - 16, 3, -200 + (k / 3) * 18), Color(0.7, 0.55, 0.4))
	var lake := CylinderMesh.new()
	lake.top_radius = 60.0
	lake.bottom_radius = 60.0
	lake.height = 0.4
	_mesh(lake, Vector3(250, 0.2, -250), Color(0.25, 0.45, 0.7))
	var tower := BoxMesh.new()
	tower.size = Vector3(4, 22, 4)
	_mesh(tower, Vector3(0, 11, -520), Color(0.5, 0.4, 0.3))
	camera = Camera3D.new()
	camera.position = Vector3(0, 1.6, 0)
	camera.far = 4000.0
	root.add_child(camera)
	camera.current = true
	photo = PhotoCamera.new()
	root.add_child(photo)
	for p: Dictionary in places.values():
		photo.anchors.append(p)
	photo.occluded = func(from: Vector3, to: Vector3) -> bool:
		for i in range(1, 48):
			var t := i / 48.0
			var p := from.lerp(to, t)
			if t <= 0.92 and ground(p.x, p.z) > p.y + 1.0:
				return true
		return false
	photo.familiar = func(id: String) -> bool: return visited.has(id)


func _mesh(mesh: Mesh, at: Vector3, color: Color) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mesh.surface_set_material(0, mat)
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.position = at
	root.add_child(node)


func _check(ok: bool, text: String) -> void:
	print(("ok   " if ok else "FAIL ") + text)
	if not ok:
		failed += 1


## Смотреть на точку place.pos, сдвинутую в сторону на off долей пятна наведения
func _look(place: Dictionary, off := 0.0) -> void:
	camera.fov = photo.fov(FOV) if photo.active else FOV
	camera.look_at(place.pos, Vector3.UP)
	if off != 0.0:
		var d := camera.position.distance_to(place.pos)
		var spot := clampf(atan2(place.radius, d), deg_to_rad(camera.fov) * PhotoCamera.MIN_AIM, deg_to_rad(camera.fov) * PhotoCamera.MAX_AIM)
		camera.rotate_y(spot * off)


func _hold(seconds: float) -> void:
	for i in roundi(seconds / DT):
		photo.update(camera, DT)


func _shot(name: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out.path_join(name + ".png"))


func _run() -> void:
	await process_frame
	photo.enter()
	_look(places.peak)
	_hold(0.6)
	_check(photo.target.get("id") == "peak" and photo.named.is_empty(), "вершина в прицеле, через 0,6 с названия ещё нет")
	await _shot("photo_aim")
	_hold(1.0)
	_check(photo.named.get("id") == "peak", "через 1,6 с над вершиной всплыло название")
	_hold(0.4)
	await _shot("photo_named")
	_look(places.peak, 1.3)
	_hold(0.3)
	_check(photo.target.get("id") == "peak", "выбранное место держится чуть за краем пятна")
	_look(places.peak, 1.8)
	_hold(0.3)
	_check(photo.target.is_empty(), "мимо пятна — место не выбрано")
	_look(places.tower)
	_hold(2.0)
	_check(photo.target.is_empty(), "вышка за холмом не выбирается")
	_look(places.lake)
	_hold(0.5)
	_check(photo.target.get("id") == "lake" and photo.named.is_empty(), "незнакомое озеро за 0,5 с не узнаётся")
	_look(places.peak)
	_hold(0.4)
	_check(photo.named.get("id") == "peak", "узнанная вершина — название сразу")
	visited.village = true
	_look(places.village)
	_hold(0.4)
	_check(photo.named.get("id") == "village", "посещённое поселение — название сразу")
	photo.zoom_by(2)
	_check(absf(tan(deg_to_rad(photo.fov(FOV)) / 2.0) * 2.0 - tan(deg_to_rad(FOV * PhotoCamera.VIEW) / 2.0)) < 0.001 and photo.look_scale() < 0.4,
		"приближение ×2 сужает обзор вдвое и замедляет мышь")
	photo.zoom_by(-2)
	_look(places.peak)
	_hold(0.5)
	photo.shoot()
	for i in 4:
		await process_frame
		photo.update(camera, DT)
	var ok := photo.shots.size() == 1 and FileAccess.file_exists(photo.shots[0].path)
	_check(ok and photo.shots[0].place == "peak", "снимок сохранён в user://photos и помнит место в прицеле")
	if ok:
		var image := Image.load_from_file(ProjectSettings.globalize_path(photo.shots[0].path))
		_check(image != null and image.get_width() == root.size.x, "снимок — кадр размера окна")
		DirAccess.remove_absolute(ProjectSettings.globalize_path(photo.shots[0].path))
	for i in 12:
		await process_frame
		photo.update(camera, DT)
	await _shot("photo_card")
	photo.exit()
	_hold(0.3)
	_check(photo._show == 0.0, "рамка уходит после выхода")
	print("photo_look: %s, снимки в %s" % ["FAIL %d" % failed if failed else "ok", out])
	quit(1 if failed else 0)
