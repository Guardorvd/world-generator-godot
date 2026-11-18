extends SceneTree
## 18.11.2026: изолированная сцена обелисков без генерации мира: пять форм памятника с табличкой (целый, разрушенный, статуя,
## обломки колонны, стела) на синтетическом рельефе (общий с trail_world_network_test), тропа с севера.
## Настоящий SettlementsBuilder по каталогу (после правки ObeliskModels — пересборка bake_assets.gd): форма по сиду и id места,
## поворот табличкой к тропе, записи табличек (их читает GameWorld, снимает PhotoCamera). Тексты табличек — ObeliskLore:
## одинаковы при повторе, различаются между обелисками. Лист 3×2 obelisk_sheet.png (пять форм вблизи и общий вид) в user://obelisk_look.
## Нужно окно. Лимит 60 с.
##   godot --path . --script res://tools/obelisk_look.gd -- [--out <папка>] [--no-shots]

const Fixture := preload("res://tools/trail_world_network_test.gd") # общий синтетический мир 192 × 192 с пологим склоном
const TILE := GameConfig.TILE
const ROW_Z := 92.5
const PATH_Z := 84

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
	preload("res://tools/watchdog.gd").arm(self, 60)
	out = _arg("out", OS.get_user_data_dir().path_join("obelisk_look"))
	DirAccess.make_dir_recursive_absolute(out)
	run.call_deferred()


## Абсцисса, где обелиск получает форму form (по тому же хешу, что в игре)
func _spot(form: int, from: float) -> Vector2:
	var x := from
	for k in 400:
		if ObeliskLore.form_of(w.seed_num, WorldData.place_id("site", x, ROW_Z)) == form:
			return Vector2(x, ROW_Z)
		x += 1.0
	return Vector2(from, ROW_Z)


func run() -> void:
	w = Fixture.synthetic()
	w.available_rect = Rect2i(0, 0, w.W, w.H)
	var paths := PackedByteArray()
	paths.resize(w.N)
	for x in range(70, 130):
		paths[PATH_Z * w.W + x] = 3 # тропа вдоль севера ряда
	w.path_mask = paths
	var spots: Array[Vector2] = []
	var from := 76.5
	for form in ObeliskLore.FORMS:
		var at := _spot(form, from)
		spots.append(at)
		from = at.x + 6.0
	var sites: Array = []
	for at: Vector2 in spots:
		sites.append(SiteData.new(at.x, at.y, floori(at.y) * w.W + floori(at.x), "obelisk", 2, "Обелиск %d" % sites.size(), 1.5,
			[HutData.new(at.x, at.y, 0, "obelisk", 0.37 * (sites.size() + 1))] as Array[HutData]))
	w.sites = sites
	var counts := {}
	for k in 300:
		var f := ObeliskLore.form_of(w.seed_num, "site:%d:%d" % [k, k * 7])
		counts[f] = counts.get(f, 0) + 1
	check(counts.size() == ObeliskLore.FORMS and counts.values().all(func(n: int) -> bool: return n >= 30), "пять форм встречаются в мире примерно поровну (%s)" % counts)
	h = w.base_heights.copy()
	h.build_structures()
	var parent := Node3D.new()
	root.add_child(parent)
	var built := SettlementsBuilder.build(parent, w, h)
	var plaques: Array = built.plaques
	check(plaques.size() == 5, "по табличке на обелиск (%d)" % plaques.size())
	var forms := {}
	for p: Dictionary in plaques:
		forms[p.form] = true
	check(forms.size() == 5, "в мире все пять форм")
	var lods: Dictionary = preload("res://scripts/render/asset_catalog.gd").get_catalog().site_lods
	check(ObeliskModels.KEYS.all(func(key: String) -> bool: return lods.has(key) and lods[key].size() == 3), "в каталоге пять форм по три уровня детализации")
	var north := Vector3(0, 0, -1)
	var faced := plaques.all(func(p: Dictionary) -> bool: return p.at.basis.z.dot(north) > 0.7)
	check(faced, "таблички смотрят к тропе (на север) в пределах 45°: поворот кратен 90° от поворота места, ящик столкновения не меняется")
	var texts := {}
	for p: Dictionary in plaques:
		var place := w.place(p.id)
		var lore := ObeliskLore.describe(w, place if place.has("key") else place.merged({key = p.id}))
		check(lore.title == p.name and lore.form == p.form and lore.text.split(".", false).size() >= 3 and lore.text.length() > 120, "%s: текст таблички (форма %d, %d знаков)" % [p.name, p.form, lore.text.length()])
		check(lore.text == ObeliskLore.describe(w, place if place.has("key") else place.merged({key = p.id})).text, "%s: тот же текст при повторе" % p.name)
		texts[lore.text] = true
	check(texts.size() == 5, "тексты разных обелисков различаются")
	if "--no-shots" not in OS.get_cmdline_user_args() and DisplayServer.get_name() != "headless":
		await _shots(parent, plaques)
	print("ИТОГО: %s" % ("всё прошло" if failures == 0 else "%d провалов" % failures))
	quit(1 if failures else 0)


func _shots(parent: Node3D, plaques: Array) -> void:
	var ground := MeshInstance3D.new()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cx := 98.0 * TILE
	var cz := ROW_Z * TILE
	for iz in 30:
		for ix in 40:
			var x0 := cx + (ix - 20) * 2.0
			var z0 := cz + (iz - 15) * 2.0
			var a := Vector3(x0, h.ground_at(x0, z0), z0)
			var b := Vector3(x0 + 2.0, h.ground_at(x0 + 2.0, z0), z0)
			var c := Vector3(x0, h.ground_at(x0, z0 + 2.0), z0 + 2.0)
			var d := Vector3(x0 + 2.0, h.ground_at(x0 + 2.0, z0 + 2.0), z0 + 2.0)
			for tri: Array in [[a, c, b], [b, c, d]]:
				for v: Vector3 in tri:
					st.set_normal(Vector3.UP)
					st.add_vertex(v)
	ground.mesh = st.commit()
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.36, 0.5, 0.26)
	gm.cull_mode = BaseMaterial3D.CULL_DISABLED
	ground.material_override = gm
	parent.add_child(ground)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, 160, 0)
	sun.shadow_enabled = true
	parent.add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.62, 0.78, 0.92)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.72, 0.75, 0.8)
	parent.add_child(env)
	var cam := Camera3D.new()
	cam.far = 300.0
	cam.fov = 55.0
	parent.add_child(cam)
	root.size = Vector2i(640, 360)
	var images: Array[Image] = []
	var order := plaques.duplicate()
	order.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.form < b.form)
	for p: Dictionary in order:
		var target: Vector3 = p.at.origin
		cam.position = target + p.at.basis.z * 8.5 + Vector3(0, 2.4, 0)
		cam.look_at(target + Vector3(0, 2.0, 0))
		for i in 8:
			await process_frame
		var image := root.get_viewport().get_texture().get_image()
		image.convert(Image.FORMAT_RGB8)
		image.save_png(out.path_join("obelisk_form%d.png" % p.form))
		images.append(image)
	var middle: Vector3 = order[2].at.origin
	cam.position = middle + Vector3(0, 7.5, -23)
	cam.position.z = middle.z - 22.0
	cam.position.x = middle.x
	cam.look_at(middle + Vector3(0, 1.5, 0))
	# обзор с севера: то же направление, что у табличек
	cam.position = middle + Vector3(0, 4.0, -13.0)
	cam.look_at(middle + Vector3(0, 1.5, 0))
	for i in 8:
		await process_frame
	var overview := root.get_viewport().get_texture().get_image()
	overview.convert(Image.FORMAT_RGB8)
	images.append(overview)
	var sheet := Image.create(1920, 720, false, Image.FORMAT_RGB8)
	for k in images.size():
		sheet.blit_rect(images[k], Rect2i(Vector2i.ZERO, images[k].get_size()), Vector2i((k % 3) * 640, (k / 3) * 360))
	sheet.save_png(out.path_join("obelisk_sheet.png"))
	print("лист ", out.path_join("obelisk_sheet.png"))
	# 18.11.2026: ночь — подсветка снизу с четырёх сторон (ObeliskModels.glow_node) и светящиеся стёкла фонарей
	sun.visible = false
	env.environment.background_color = Color(0.03, 0.04, 0.08)
	env.environment.ambient_light_color = Color(0.09, 0.1, 0.16)
	SettlementsBuilder.set_night(SettlementsBuilder.shared_opaque_mat, 1.0)
	var night: Array[Image] = []
	for p: Dictionary in order:
		var target: Vector3 = p.at.origin
		cam.position = target + p.at.basis.z * 7.0 + p.at.basis.x * 3.0 + Vector3(0, 1.8, 0)
		cam.look_at(target + Vector3(0, 1.6, 0))
		for i in 8:
			await process_frame
		var image := root.get_viewport().get_texture().get_image()
		image.convert(Image.FORMAT_RGB8)
		night.append(image)
	var night_sheet := Image.create(1920, 720, false, Image.FORMAT_RGB8)
	for k in night.size():
		night_sheet.blit_rect(night[k], Rect2i(Vector2i.ZERO, night[k].get_size()), Vector2i((k % 3) * 640, (k / 3) * 360))
	night_sheet.save_png(out.path_join("obelisk_night.png"))
	SettlementsBuilder.set_night(SettlementsBuilder.shared_opaque_mat, 0.0)
	print("ночь ", out.path_join("obelisk_night.png"))
