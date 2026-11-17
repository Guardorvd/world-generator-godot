extends SceneTree
## Модель v9. Пересборка перезаписывает изолированную scenes/cyclist.tscn (после неё — tools/build_bike.gd).
## v9 (17.11): одна поверхность с общим материалом велосипеда и седока (resources/bike_rider.gdshader): вершина
## хранит место палитры и вид ткани (UV), запечённое затенение (COLOR.r, tools/vertex_ao.gd) и подвижность ткани
## на ветру (COLOR.g). Рисунок формы — участки самой поверхности (decal в loft), а не накладки поверх неё.
## Пальцы перчаток — трубки по дуге хвата, очки с толщиной оправы, покатые плечи, часы на левой руке (раньше
## их добавлял BikeView отдельными мешами).
## v8 (12.11): шлем закрывает затылок (задняя часть оболочки спускается к шее), шея толще,
## перчатка с манжетой на запястье (без скачка от тонкого запястья к кулаку).
## v5: шлем сидит на голове (ниже и плотнее, козырёк короче и под наклоном), из-под шлема видны волосы,
## велотрусы выше колена и открытые голени с носками, рукав джерси короче — у локтя видна рука.
## Смена ткани на конечности — одна непрерывная поверхность с узким отворотом (кромка), а не отдельные
## трубки с торцами: иначе на сгибе колена и локтя торцы выпирают рваными кольцами.
## Волосы — полоса по поверхности затылка (как вставки на джерси), а не эллипсоиды.
## Один штатный skinned ArrayMesh, прежние 22 кости, без внешних моделей и текстур.
const AO := preload("res://tools/vertex_ao.gd")
const P := preload("res://scripts/render/bike_palette.gd")
var rider: CyclistRig
var skeleton: Skeleton3D
var rests: Array[Vector3] = []
var tool: SurfaceTool
# Краски: место палитры и вид поверхности (BikePalette)
var navy := Vector2i(P.NAVY, P.FABRIC)
var teal := Vector2i(P.JERSEY, P.FABRIC)
var panel := Vector2i(P.JERSEY_PANEL, P.FABRIC)
var skin := Vector2i(P.SKIN, P.SKIN_KIND)
var cream := Vector2i(P.CREAM, P.FABRIC)
var shoe := Vector2i(P.CREAM, P.MATTE)
var helmet := Vector2i(P.HELMET, P.SHELL)
var dark := Vector2i(P.DARK, P.HARD)
var hair := Vector2i(P.DARK, P.MATTE)
var lens := Vector2i(P.LENS, P.LENS_KIND)
var alloy := Vector2i(P.ALLOY, P.ALLOY_KIND)
# Шлем v5: низ оболочки (м над костью головы), её высота и полуоси низа.
const HELMET_Y := 0.052
const HELMET_H := 0.112
const HELMET_R := Vector2(0.118, 0.138)
const HELMET_Z := -0.012


func _init() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	rider = CyclistRig.new()
	rider.name = "Rider"
	rider.set_meta("model_version", 9)
	rider.spine_bow = 0.0 # bind-поза — с прямой спиной: оболочка строится вдоль прямой таз–грудь
	skeleton = Skeleton3D.new()
	skeleton.name = "Skeleton3D"
	rider.add_child(skeleton)
	skeleton.owner = rider
	bone("Root", "", Vector3.ZERO)
	bone("Hips", "Root", Vector3(0, 0.97, 0.17))
	bone("Spine", "Hips", Vector3(0, 1.08, 0.11))
	bone("Chest", "Spine", Vector3(0, 1.3, -0.04))
	bone("Neck", "Chest", Vector3(0, 1.44, -0.1))
	bone("Head", "Neck", Vector3(0, 1.59, -0.17))
	for side in [-1.0, 1.0]:
		var s := "L" if side < 0 else "R"
		bone("Clavicle" + s, "Chest", Vector3(0, 1.37, -0.08))
		bone("UpperArm" + s, "Clavicle" + s, Vector3(side * 0.18, 1.37, -0.08))
		bone("Forearm" + s, "UpperArm" + s, Vector3(side * 0.25, 1.17, -0.2))
		bone("Hand" + s, "Forearm" + s, Vector3(side * 0.24, 0.98, -0.43))
		bone("UpperLeg" + s, "Hips", Vector3(side * 0.11, 0.97, 0.17))
		bone("LowerLeg" + s, "UpperLeg" + s, Vector3(side * 0.14, 0.65, -0.1))
		bone("Foot" + s, "LowerLeg" + s, Vector3(side * 0.14, 0.35, 0.025))
		bone("Toe" + s, "Foot" + s, Vector3(side * 0.14, 0.34, -0.07))
	root.add_child(rider)
	rider.skeleton = skeleton
	rider.pose(0, 0, Vector3(-0.24, 0.98, -0.43), Vector3(0.24, 0.98, -0.43))
	# Симметричная средняя точка хода педалей в bind-позе: левая и правая ноги строятся
	# зеркально, а отклонение тазобедренного и коленного суставов в верхней/нижней точках вдвое меньше.
	var bind_hip := skeleton.get_bone_global_pose(skeleton.find_bone("Hips")).origin
	for side: float in [-1.0, 1.0]:
		var s := "L" if side < 0 else "R"
		var h := bind_hip + Vector3(side * 0.11, 0, 0)
		var ankle := Vector3(side * 0.14, 0.355, 0.025)
		var knee := rider._joint(h, ankle, CyclistRig.LEG_LENGTH, Vector3(-side * 0.025, 0.3, -1.0))
		var leg_x := (ankle - h).cross(knee - h)
		rider._set_bone("UpperLeg" + s, h, rider._limb_basis(h, knee, leg_x))
		rider._set_bone("LowerLeg" + s, knee, rider._limb_basis(knee, ankle, leg_x))
		var foot_basis := Basis.from_euler(Vector3(0.0, -side * 0.03, 0.0))
		rider._set_bone("Foot" + s, ankle, foot_basis)
		rider._set_bone("Toe" + s, ankle + foot_basis * Vector3(0, -0.015, -0.095), foot_basis)
	for i in skeleton.get_bone_count():
		skeleton.set_bone_rest(i, skeleton.get_bone_pose(i))
	_body()
	_head()
	for side in [-1.0, 1.0]:
		_limbs(side)
	_watch()
	tool.index()
	var mesh := tool.commit()
	# затенение — в bind-позе по своим треугольникам (подмышки, пах, под шлемом, между пальцами)
	mesh = AO.apply(mesh, AO.triangles(mesh), 0.07, 0.007, 0.9)
	var body := MeshInstance3D.new()
	body.name = "Body"
	body.mesh = mesh
	body.material_override = P.material()
	body.skeleton = NodePath("..")
	body.skin = Skin.new()
	for i in skeleton.get_bone_count():
		body.skin.add_bind(i, skeleton.get_bone_global_rest(i).affine_inverse())
	rider.pose(0, 0, Vector3(-0.24, 0.98, -0.43), Vector3(0.24, 0.98, -0.43))
	# Запас для полёта, работы плеч и физической позы: skinned меш не отсекается по старой посадке.
	body.extra_cull_margin = BikeCrash.GROUND_R + 2.0
	skeleton.add_child(body)
	body.owner = rider
	_animation_reset()
	var packed := PackedScene.new()
	var error := packed.pack(rider)
	if error == OK:
		error = ResourceSaver.save(packed, "res://scenes/cyclist.tscn")
	print("Cyclist v9: ", error_string(error), "; surfaces=", mesh.get_surface_count(), " triangles=", (mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3)
	quit(error)


## Часы на левом запястье (раньше — три отдельных меша BikeView): корпус, безель, стекло.
func _watch() -> void:
	box("HandL", Vector3(0.066, 0.050, 0.034), Vector3(0.0, 0.0, 0.038), dark)
	box("HandL", Vector3(0.052, 0.010, 0.047), Vector3(0.0, 0.027, 0.036), alloy)
	box("HandL", Vector3(0.040, 0.003, 0.035), Vector3(0.0, 0.033, 0.036), lens)


func _body() -> void:
	var hip := skeleton.get_bone_global_pose(skeleton.find_bone("Hips")).origin
	var chest := Vector3(0, 1.37, -0.08)
	var head := skeleton.get_bone_global_pose(skeleton.find_bone("Head"))
	var collar := Vector3(0, 1.405, -0.11)
	var neck_basis := Basis(Quaternion(Vector3.UP, (head * Vector3(0, -0.075, 0.015) - collar).normalized()))
	var rings: Array[Dictionary] = [
		ring(hip + Vector3(0, -0.082, 0.006), Basis.IDENTITY, 0.132, 0.088, "Hips"),
		ring(hip + Vector3(0, -0.022, 0.004), Basis.IDENTITY, 0.148, 0.100, "Hips"),
		ring(hip.lerp(chest, 0.055) + Vector3(0, 0, 0.004), Basis.IDENTITY, 0.144, 0.097, "Hips", "Spine", 0.11),
	]
	# Единая поверхность таза и торса с отворотом джерси на поясе (LIP): велотрусы и джерси
	# делят веса Hips/Spine и не прорезают друг друга в глубокой посадке.
	# В местах сгиба (пояс спереди, переход к плечам) заложены умеренные складки, а на пояснице и лопатках — натяжение ткани.
	# Последний элемент — доля веса ключицы на боках грудной клетки (t = 0.72..1.04), чтобы грудь и плечевой пояс
	# тянулись за рукой вместе с рукавом и не расходились в подмышке.
	var clav_l := skeleton.find_bone("ClavicleL")
	var clav_r := skeleton.find_bone("ClavicleR")
	var torso_specs: Array[Array] = [
		[0.06, 0.148, 0.099, 0.002, 0.0, Vector3(0.025, 0.010, -0.002), 0.0],
		[0.15, 0.141, 0.095, 0.004, 0.0, Vector3(-0.032, 0.012, 0.002), 0.0],
		[0.25, 0.140, 0.097, 0.006, 0.0, Vector3(0.028, -0.008, -0.002), 0.0],
		[0.36, 0.147, 0.102, 0.007, 0.0, Vector3(-0.024, 0.010, 0.001), 0.0],
		[0.48, 0.156, 0.108, 0.008, 0.0, Vector3(0.018, 0.014, -0.001), 0.0],
		[0.72, 0.184, 0.114, 0.004, 0.0, Vector3(-0.014, 0.018, 0.0), 0.18],
		[0.87, 0.198, 0.108, 0.0, 0.0, Vector3(-0.018, 0.015, 0.001), 0.36],
		[0.91, 0.191, 0.105, -0.001, 0.08, Vector3.ZERO, 0.42],
		[0.99, 0.160, 0.090, -0.004, 0.32, Vector3.ZERO, 0.22],
		[1.04, 0.112, 0.068, -0.006, 0.68, Vector3.ZERO, 0.0],
		[1.09, 0.058, 0.058, -0.006, 1.0, Vector3.ZERO, 0.0],
	]
	# 17.11: плечи покатые (трапеция от шеи к плечу), а не ступенькой; низ джерси свободнее и треплется на ветру
	var flutter := [0.0, 0.0, 0.0, 0.55, 0.45, 0.32, 0.22, 0.12, 0.05, 0.0, 0.0, 0.0, 0.0, 0.0]
	for spec: Array in torso_specs:
		var t: float = spec[0]
		var lower := "Hips" if t < 0.5 else "Spine"
		var upper := "Chest" if t >= 0.7 else ("Spine" if t < 0.5 else "Chest")
		var weight := 1.0 if t >= 0.7 else clampf(t * 2.0 if t < 0.5 else (t - 0.5) * 5.0, 0.0, 1.0)
		var ring_basis := Basis.IDENTITY.slerp(neck_basis, float(spec[4]))
		var center := collar if float(spec[4]) >= 0.99 else hip.lerp(chest, t) + Vector3(0.0, 0.0, float(spec[3]))
		var r := ring(center, ring_basis, spec[1], spec[2], lower, upper, weight, Vector2.ZERO, Vector2.ZERO, spec[5] as Vector3)
		if float(spec[6]) > 0.0:
			r.extra = {pos = clav_r, neg = clav_l, amount = float(spec[6]), power = 2.0}
		rings.append(r)
	# Карманы на спине оттопырены (сечения 5–6 сзади шире), в них что-то лежит
	for i in [5, 6]:
		rings[i].bulge = Vector2(PI * 0.5, 0.05 if i == 5 else 0.035)
	for i in rings.size():
		rings[i].flutter = flutter[i]
	# Рисунок формы — участки той же поверхности (отрезки между сечениями, угол середины, полуширина):
	# по спине — три кармана с прострочкой и светоотражающая полоса над ними, по груди — светлая полоса,
	# кокетка плеч тёмная, спереди — молния. Боковые панели — side_mat (тёмные бока стройнят силуэт).
	var decals: Array = [
		{from = 4, to = 6, angle = PI * 0.5, half = 0.95, mat = panel},
		{from = 4, to = 6, angle = PI * 0.5 - 0.32, half = 0.018, mat = navy},
		{from = 4, to = 6, angle = PI * 0.5 + 0.32, half = 0.018, mat = navy},
		{from = 6, to = 7, angle = PI * 0.5, half = 0.55, mat = cream},
		{from = 9, to = 10, angle = -PI * 0.5, half = 1.15, mat = cream},
		{from = 10, to = 13, angle = PI * 0.5, half = PI, mat = panel},
		{from = 3, to = 12, angle = -PI * 0.5, half = 0.03, mat = dark},
	]
	loft(rings, teal, panel, [navy, navy, navy], 12, true, decals)
	_neck()



## v5: шея — одна поверхность от ворота джерси (внутри последнего сечения торса) до основания черепа
## (внутри головы), по оси шеи и с весами Chest → Neck → Head. Раньше эллипсоид на кости Neck висел
## отдельно и на наклоне торчал горбом за затылком, а спереди голова не соединялась с шеей.
func _neck() -> void:
	var head := skeleton.get_bone_global_pose(skeleton.find_bone("Head"))
	var collar := Vector3(0, 1.405, -0.11)
	var skull := head * Vector3(0, -0.075, 0.015)
	var axis := (skull - collar).normalized()
	var basis := Basis(Quaternion(Vector3.UP, axis))
	var rings: Array[Dictionary] = []
	for spec: Array in [[0.0, 0.068, 0.068, "Chest", "", 0.0], [0.3, 0.061, 0.063, "Chest", "Neck", 0.5], [0.6, 0.057, 0.061, "Neck", "Head", 0.3], [0.85, 0.059, 0.065, "Neck", "Head", 0.7], [1.0, 0.060, 0.066, "Head", "", 0.0]]:
		rings.append(ring(collar.lerp(skull, spec[0]), basis, spec[1], spec[2], spec[3], spec[4], spec[5]))
	loft(rings, skin)
	# Воротник джерси: низкая стойка вокруг шеи закрывает гранёный верх торса
	var band: Array[Dictionary] = []
	for spec: Vector3 in [Vector3(-0.008, 0.072, 0.072), Vector3(0.012, 0.069, 0.07), Vector3(0.027, 0.065, 0.067)]:
		band.append(ring(collar + axis * spec.x, basis, spec.y, spec.z, "Chest", "Neck", clampf(spec.x / 0.09, 0.0, 0.3)))
	loft(band, panel)


func _head() -> void:
	# Челюсть, скулы и лоб имеют разный профиль; лицо уже, чем у третьей модели.
	var head_centers: Array[Vector3] = []
	for i in HEAD_Y.size():
		head_centers.append(Vector3(0, HEAD_Y[i], HEAD_Z[i]))
	local_loft("Head", head_centers, HEAD_SIZE, skin)
	for side in [-1.0, 1.0]:
		ellipsoid("Head", Vector3(0.015, 0.026, 0.014), Vector3(side * 0.092, -0.001, 0.012), skin)
		var start := 0.075 if side > 0 else -1.05
		var end := 1.05 if side > 0 else -0.075
		goggle(start, end, 0.036, 0.018, 1.0, dark, 0.006)
		goggle(start + 0.055, end - 0.055, 0.024, 0.019, 1.018, lens)
		bar("Head", Vector3(side * 0.09, 0.018, -0.05), Vector3(side * 0.098, 0.012, 0.035), 0.01, dark)
		# Y-образный ремень проходит у уха и сходится под подбородком.
		var junction := Vector3(side * 0.086, -0.074, 0.018)
		bar("Head", Vector3(side * 0.098, HELMET_Y + 0.004, -0.06), junction, 0.007, navy)
		bar("Head", Vector3(side * 0.1, HELMET_Y + 0.004, 0.062), junction, 0.007, navy)
		bar("Head", junction, Vector3(side * 0.04, -0.135, -0.055), 0.007, navy)
	bar("Head", Vector3(-0.008, 0.02, -0.113), Vector3(0.008, 0.02, -0.113), 0.009, dark)
	# Нос скрыт маской: отдельная геометрия проступает сквозь её поверхность при повороте головы.
	_mask()
	_hair()
	var centers: Array[Vector3] = []
	var sizes: Array[Vector2] = []
	for i in 11:
		var theta := PI * 0.5 * i / 10.0
		centers.append(Vector3(0, HELMET_Y + sin(theta) * HELMET_H, HELMET_Z))
		sizes.append(HELMET_R * maxf(cos(theta), 0.01))
	# 24 грани вместо 12: прорези лежат на настоящей сфере и на гранёной оболочке торчали бы по контуру
	local_loft("Head", centers, sizes, helmet, 24)
	# Тёмный обод по краю оболочки и короткий козырёк под наклоном
	local_loft("Head", [Vector3(0, HELMET_Y - 0.008, HELMET_Z), Vector3(0, HELMET_Y + 0.006, HELMET_Z)], [HELMET_R * 1.02, HELMET_R * 1.024], navy, 24)
	box("Head", Vector3(0.15, 0.006, 0.036), Vector3(0, HELMET_Y + 0.008, HELMET_Z - HELMET_R.y - 0.01), navy, Basis(Vector3.RIGHT, 0.28))
	for x in [-0.075, -0.032, 0.032, 0.075]:
		helmet_strip(x, 0.012, dark)
	helmet_strip(0.0, 0.012, teal)
	_helmet_back()
	# 17.11: колесо регулировки на затылке под шлемом (видно с игровой камеры сзади) и его рамка
	box("Head", Vector3(0.05, 0.012, 0.014), Vector3(0, -0.026, head_z(-0.026) + head_size(-0.026).y + 0.01), dark)
	box("Head", Vector3(0.02, 0.018, 0.008), Vector3(0, -0.026, head_z(-0.026) + head_size(-0.026).y + 0.019), panel)


## v8: задняя часть шлема. Оболочка от обода спускается по затылку (посередине ниже, к ушам выше) и
## сужается к голове; снизу — тёмная кромка до кожи головы, чтобы под шлем не было видно насквозь.
func _helmet_back() -> void:
	const COLS := 10
	const ROWS := 3
	var at := skeleton.get_bone_global_pose(skeleton.find_bone("Head"))
	var r := ring(Vector3.ZERO, Basis.IDENTITY, 0, 0, "Head")
	var grid: Array[Dictionary] = []
	for row in ROWS + 2:
		for col in COLS + 1:
			var u := float(col) / COLS * 2.0 - 1.0
			var angle := PI * 0.5 + u * 1.3
			var bottom := lerpf(-0.012, HELMET_Y - 0.004, u * u)
			var t := float(maxi(row - 1, 0)) / ROWS
			var y := lerpf(bottom, HELMET_Y - 0.004, t)
			var size := (head_size(y) + Vector2(0.016, 0.026)).lerp(HELMET_R * 1.02, t)
			var z := lerpf(head_z(y), HELMET_Z, t)
			if row == 0:
				size = head_size(y) * 1.01
			var vertex := {position = at * Vector3(cos(angle) * size.x, y, z + sin(angle) * size.y), bones = r.bones, weights = r.weights}
			if row > 0:
				vertex.normal = at.basis * Vector3(cos(angle) / size.x, -0.3 / 0.09 * (1.0 - t), sin(angle) / size.y).normalized()
			grid.append(vertex)
	for row in ROWS + 1:
		for col in COLS:
			var a := grid[row * (COLS + 1) + col].duplicate()
			var b := grid[(row + 1) * (COLS + 1) + col].duplicate()
			var c := grid[row * (COLS + 1) + col + 1].duplicate()
			var d := grid[(row + 1) * (COLS + 1) + col + 1].duplicate()
			if row == 0:
				for v: Dictionary in [a, b, c, d]:
					v.erase("normal")
			triangle(a, b, c, navy if row == 0 else helmet)
			triangle(c, b, d, navy if row == 0 else helmet)


func _mask() -> void:
	# Веломаска поверх неизменённого лица: закрывает нос, рот и подбородок, глаза открыты.
	var at := skeleton.get_bone_global_pose(skeleton.find_bone("Head"))
	var skinning := ring(Vector3.ZERO, Basis.IDENTITY, 0, 0, "Head")
	var grid: Array[Dictionary] = []
	for row in 5:
		for col in 9:
			var angle := lerpf(-PI + 0.2, -0.2, float(col) / 8.0)
			var front := maxf(0.0, -sin(angle))
			var y := lerpf(-0.132, -0.038 + pow(front, 4.0) * 0.052, float(row) / 4.0)
			var size := head_size(y)
			var local := Vector3(cos(angle) * (size.x + 0.008), y,
				head_z(y) + sin(angle) * (size.y + 0.012) - pow(front, 6.0) * smoothstep(-0.09, -0.035, y) * 0.025)
			grid.append({position = at * local, bones = skinning.bones, weights = skinning.weights})
	for row in 4:
		for col in 8:
			var a := grid[row * 9 + col]
			var b := grid[(row + 1) * 9 + col]
			var c := grid[row * 9 + col + 1]
			var d := grid[(row + 1) * 9 + col + 1]
			triangle(a, b, c, navy)
			triangle(c, b, d, navy)
	for side in [-1.0, 1.0]:
		bar("Head", Vector3(side * 0.087, -0.04, -0.025), Vector3(side * 0.105, 0.005, 0.025), 0.005, navy)
		bar("Head", Vector3(side * 0.055, -0.115, -0.025), Vector3(side * 0.105, -0.025, 0.028), 0.005, navy)


## Волосы: короткая стрижка по затылку и за ушами, на 2,5 % над кожей головы, до края шлема.
## Линия роста — дугой: посередине затылка ниже, к ушам выше.
func _hair() -> void:
	const COLS := 8
	const ROWS := 3
	var at := skeleton.get_bone_global_pose(skeleton.find_bone("Head"))
	var r := ring(Vector3.ZERO, Basis.IDENTITY, 0, 0, "Head")
	var grid: Array[Dictionary] = []
	for row in ROWS + 1:
		for col in COLS + 1:
			var u := float(col) / COLS * 2.0 - 1.0
			var angle := PI * 0.5 + u * 0.95
			var bottom := lerpf(-0.035, 0.025, u * u)
			var y := lerpf(bottom, HELMET_Y + 0.01, float(row) / ROWS)
			var size := head_size(y) * 1.025
			var local := Vector3(cos(angle) * size.x, y, head_z(y) + sin(angle) * size.y)
			var normal := Vector3(cos(angle) / size.x, 0.25 / 0.09, sin(angle) / size.y).normalized()
			grid.append({position = at * local, normal = at.basis * normal, bones = r.bones, weights = r.weights})
	for row in ROWS:
		for col in COLS:
			var a := grid[row * (COLS + 1) + col]
			var b := grid[(row + 1) * (COLS + 1) + col]
			var c := grid[row * (COLS + 1) + col + 1]
			var d := grid[(row + 1) * (COLS + 1) + col + 1]
			triangle(a, b, c, hair)
			triangle(c, b, d, hair)


## Профиль головы (тот же, что у local_loft в _head): полуоси сечения и сдвиг по z на высоте y
const HEAD_Y := [-0.138, -0.107, -0.06, 0.005, 0.055, 0.095, 0.12]
const HEAD_Z := [-0.022, -0.012, -0.006, 0.0, 0.003, 0.005, 0.01]
const HEAD_SIZE := [Vector2(0.044, 0.054), Vector2(0.063, 0.075), Vector2(0.079, 0.09), Vector2(0.091, 0.096), Vector2(0.089, 0.09), Vector2(0.08, 0.08), Vector2(0.06, 0.064)]


func _head_t(y: float) -> Vector2:
	for i in HEAD_Y.size() - 1:
		if y <= HEAD_Y[i + 1]:
			return Vector2(i, clampf((y - HEAD_Y[i]) / (HEAD_Y[i + 1] - HEAD_Y[i]), 0.0, 1.0))
	return Vector2(HEAD_Y.size() - 2, 1.0)


func head_size(y: float) -> Vector2:
	var t := _head_t(y)
	return (HEAD_SIZE[int(t.x)] as Vector2).lerp(HEAD_SIZE[int(t.x) + 1], t.y)


func head_z(y: float) -> float:
	var t := _head_t(y)
	return lerpf(HEAD_Z[int(t.x)], HEAD_Z[int(t.x) + 1], t.y)


## Лента очков по дуге лица. depth > 0 — оправа с толщиной: верхняя и нижняя кромки и торцы видны сбоку.
func goggle(start: float, end: float, height: float, y: float, radius: float, mat: Vector2i, depth := 0.0) -> void:
	var at := skeleton.get_bone_global_pose(skeleton.find_bone("Head"))
	var r := ring(Vector3.ZERO, Basis.IDENTITY, 0, 0, "Head")
	var pt := func(angle: float, h: float, grow: float) -> Dictionary:
		return {position = at * Vector3(sin(angle) * (0.102 * radius + grow), y + h, -cos(angle) * (0.112 * radius + grow)), bones = r.bones, weights = r.weights}
	for i in 5:
		var a0 := lerpf(start, end, float(i) / 5)
		var a1 := lerpf(start, end, float(i + 1) / 5)
		var vertices: Array[Dictionary] = [pt.call(a0, -height * 0.5, depth), pt.call(a1, -height * 0.5, depth), pt.call(a1, height * 0.5, depth), pt.call(a0, height * 0.5, depth)]
		triangle(vertices[0], vertices[2], vertices[1], mat)
		triangle(vertices[0], vertices[3], vertices[2], mat)
		if depth > 0.0:
			for h: float in [-height * 0.5, height * 0.5]:
				var o0: Dictionary = pt.call(a0, h, depth)
				var o1: Dictionary = pt.call(a1, h, depth)
				var i0: Dictionary = pt.call(a0, h, 0.0)
				var i1: Dictionary = pt.call(a1, h, 0.0)
				var up := at.basis.y * signf(h)
				tri_out(i0, o0, o1, up, mat)
				tri_out(i0, o1, i1, up, mat)
	if depth > 0.0:
		for e: Array in [[start, -1.0], [end, 1.0]]:
			var a: float = e[0]
			var q: Array[Dictionary] = [pt.call(a, -height * 0.5, 0.0), pt.call(a, -height * 0.5, depth), pt.call(a, height * 0.5, depth), pt.call(a, height * 0.5, 0.0)]
			var tangent := at.basis * Vector3(cos(a) * 0.102, 0.0, sin(a) * 0.112) * float(e[1])
			tri_out(q[0], q[1], q[2], tangent, mat)
			tri_out(q[0], q[2], q[3], tangent, mat)


## Треугольник лицом в сторону hint (обход выбирается сам).
func tri_out(a: Dictionary, b: Dictionary, c: Dictionary, hint: Vector3, mat: Vector2i) -> void:
	var n: Vector3 = (b.position - a.position).cross(c.position - a.position)
	if n.dot(hint) < 0.0:
		triangle(a, c, b, mat)
	else:
		triangle(a, b, c, mat)


func helmet_strip(x: float, width: float, mat: Vector2i) -> void:
	var at := skeleton.get_bone_global_pose(skeleton.find_bone("Head"))
	var r := ring(Vector3.ZERO, Basis.IDENTITY, 0, 0, "Head")
	for i in 6:
		var vertices: Array[Dictionary] = []
		for corner: Vector2 in [Vector2(-0.5, float(i) / 6), Vector2(0.5, float(i) / 6), Vector2(0.5, float(i + 1) / 6), Vector2(-0.5, float(i + 1) / 6)]:
			var px := x + corner.x * width
			# прорезь кончается раньше, чем оболочка уходит вниз к краю: иначе её конец ныряет и перекручивается
			var span := HELMET_R.y * sqrt(maxf(0.05, 0.8 - pow(x / HELMET_R.x, 2)))
			var z := HELMET_Z + lerpf(-0.72, 0.6, corner.y) * span
			var y := HELMET_Y + 0.0015 + HELMET_H * sqrt(maxf(0.0, 1.0 - pow(px / HELMET_R.x, 2) - pow((z - HELMET_Z) / HELMET_R.y, 2)))
			vertices.append({position = at * Vector3(px, y, z), bones = r.bones, weights = r.weights})
		triangle(vertices[0], vertices[2], vertices[1], mat)
		triangle(vertices[0], vertices[3], vertices[2], mat)


func _limbs(side: float) -> void:
	var s := "L" if side < 0 else "R"
	_arm(side)
	# Ладонь и согнутый большой палец вместо двух шаров. Весь хват жёстко следует Hand.
	local_loft("Hand" + s, [Vector3(0, -0.035, -0.018), Vector3(0, -0.016, -0.022), Vector3(0, 0.02, -0.012), Vector3(0, 0.038, 0)], [Vector2(0.035, 0.024), Vector2(0.044, 0.042), Vector2(0.043, 0.042), Vector2(0.032, 0.025)], navy, 8)
	local_loft("Hand" + s, [Vector3(-side * 0.03, -0.025, -0.005), Vector3(-side * 0.046, -0.012, -0.018), Vector3(-side * 0.032, 0.006, -0.036)], [Vector2(0.015, 0.017), Vector2(0.018, 0.019), Vector2(0.012, 0.014)], navy, 8)
	box("Hand" + s, Vector3(0.053, 0.009, 0.027), Vector3(0, 0.035, -0.008), panel)
	box("Hand" + s, Vector3(0.038, 0.004, 0.008), Vector3(0, 0.041, -0.007), cream)
	# 17.11: четыре пальца перчатки — круглые трубки по дуге хвата (три фаланги), мизинец тоньше и короче;
	# на костяшках — накладка. Раньше пальцы были коробочками в два звена.
	for i in 4:
		var fx := (float(i) - 1.5) * 0.0205
		var k := 0.86 if (i == 0 and side > 0.0) or (i == 3 and side < 0.0) else 1.0 # мизинец снаружи
		path_loft("Hand" + s, [Vector3(fx, 0.017, -0.034), Vector3(fx, -0.003, -0.047), Vector3(fx, -0.024, -0.043 * k), Vector3(fx, -0.036 * k, -0.026 * k)],
			[0.0098 * k, 0.0094 * k, 0.0088 * k, 0.0078 * k], navy, 6)
	box("Hand" + s, Vector3(0.076, 0.009, 0.014), Vector3(0, 0.017, -0.046), panel, Basis(Vector3.RIGHT, 0.45))
	_leg(side)
	# 17.11: обувь — колодка вдоль стопы (сечения поперёк, от пятки к носку): поднятый задник, вырез у щиколотки,
	# носок ниже и уже; подошва плоская с рантом и чуть загнута у носка. Ремешки, задник и резиновый носок —
	# участки самой поверхности. Раньше — вертикальная «лодка» шириной 13 см с накладками-коробками.
	var zs := [0.088, 0.072, 0.035, -0.005, -0.045, -0.085, -0.12, -0.148, -0.162]
	var upper_w := [0.032, 0.043, 0.047, 0.049, 0.051, 0.052, 0.048, 0.036, 0.016]
	var upper_h := [0.034, 0.042, 0.045, 0.038, 0.030, 0.024, 0.018, 0.013, 0.007]
	var upper_c: Array[Vector3] = []
	var upper_s: Array[Vector2] = []
	var sole_c: Array[Vector3] = []
	var sole_s: Array[Vector2] = []
	for i in zs.size():
		upper_c.append(Vector3(0, upper_h[i] - 0.040, zs[i]))
		upper_s.append(Vector2(upper_w[i], upper_h[i]))
		sole_c.append(Vector3(0, -0.041 + (0.003 if i == 7 else (0.006 if i == 8 else 0.0)), zs[i] - (0.004 if i == 8 else 0.0)))
		sole_s.append(Vector2(upper_w[i] + 0.005, 0.0075 if i < 8 else 0.006))
	var shoe_decals := [
		{from = 0, to = 2, angle = -PI * 0.5, half = 1.35, mat = panel},
		{from = 3, to = 4, angle = PI * 0.5, half = 1.15, mat = navy},
		{from = 4, to = 5, angle = PI * 0.5, half = 1.2, mat = navy},
		{from = 4, to = 6, angle = 0.0, half = 0.3, mat = panel},
		{from = 4, to = 6, angle = PI, half = 0.3, mat = panel},
		{from = 6, to = 8, angle = -PI * 0.5, half = 1.45, mat = dark},
	]
	axis_loft("Foot" + s, upper_c, upper_s, shoe, 12, shoe_decals)
	axis_loft("Foot" + s, sole_c, sole_s, dark, 12)


const DOWN_BASIS := Basis(Vector3.RIGHT, Vector3.DOWN, Vector3.FORWARD)
const ARM_SIDES := 12


## Единая непрерывная поверхность руки: переход грудь–плечо, дельта, бицепс/трицепс,
## кромка рукава, локтевой отросток (olecranon) и предплечье до запястья без внутренних торцов.
func _arm(side: float) -> void:
	var s := "L" if side < 0 else "R"
	var arm := skeleton.get_bone_global_pose(skeleton.find_bone("UpperArm" + s))
	var forearm := skeleton.get_bone_global_pose(skeleton.find_bone("Forearm" + s))
	var hand := skeleton.get_bone_global_pose(skeleton.find_bone("Hand" + s))
	# Рукав выходит из грудной клетки и плавно переходит в руку: первые два сечения сидят внутри
	# верхней части торса (с весами Chest → Clavicle), затем через сустав — в плечевую кость,
	# с расширением по грудной/широчайшей мышцам в подмышке и сглаженной дельтой сверху.
	var root_a := Basis(arm.basis.z, -side * 0.42) * arm.basis
	var root_b := Basis(arm.basis.z, -side * 0.24) * arm.basis
	var root_c := Basis(arm.basis.z, -side * 0.10) * arm.basis
	var rings: Array[Dictionary] = [
		ring(arm.origin + Vector3(-side * 0.092, -0.024, 0.008), root_a, 0.052, 0.068, "Chest", "Clavicle" + s, 0.15, Vector2(0.0, 0.004)),
		ring(arm.origin + Vector3(-side * 0.052, -0.020, 0.005), root_b, 0.060, 0.072, "Chest", "Clavicle" + s, 0.55, Vector2(0.0, 0.004), Vector2.ZERO, Vector3(-0.020, 0.014, 0.002)),
		ring(arm.origin + Vector3(-side * 0.018, -0.016, 0.002), root_c, 0.063, 0.068, "Clavicle" + s, "UpperArm" + s, 0.38, Vector2(0.0, 0.002), Vector2.ZERO, Vector3(0.018, 0.016, -0.002)),
		ring(arm.origin.lerp(forearm.origin, 0.08) + Vector3(-side * 0.003, -0.008, 0.0), arm.basis, 0.065, 0.065, "Clavicle" + s, "UpperArm" + s, 0.78, Vector2.ZERO, Vector2.ZERO, Vector3(-0.018, 0.014, 0.001)),
		ring(arm.origin.lerp(forearm.origin, 0.17) + Vector3(0.0, -0.003, 0.0), arm.basis, 0.065, 0.063, "UpperArm" + s, "Clavicle" + s, 0.08, Vector2(side * 0.001, 0.0), Vector2.ZERO, Vector3(0.016, 0.012, -0.001)),
	]
	var root_count := rings.size()
	rings.append_array([
		ring(arm.origin.lerp(forearm.origin, 0.26), arm.basis, 0.064, 0.062, "UpperArm" + s, "", 0.0, Vector2(side * 0.002, 0.0), Vector2.ZERO, Vector3(0.020, 0.010, -0.001)),
		ring(arm.origin.lerp(forearm.origin, 0.42), arm.basis, 0.059, 0.059, "UpperArm" + s, "", 0.0, Vector2(side * 0.001, 0.001), Vector2.ZERO, Vector3(-0.016, 0.008, 0.001)),
		ring(arm.origin.lerp(forearm.origin, 0.58), arm.basis, 0.055, 0.056, "UpperArm" + s, "", 0.0, Vector2(0.0, 0.001), Vector2.ZERO, Vector3(0.014, 0.006, 0.0)),
		ring(arm.origin.lerp(forearm.origin, 0.63), arm.basis, 0.054, 0.055, "UpperArm" + s, "", 0.0, Vector2(0.0, 0.001)),
		ring(arm.origin.lerp(forearm.origin, 0.634), arm.basis, 0.047, 0.049, "UpperArm" + s, "", 0.0, Vector2(0.0, 0.001)),
	])
	rings.append_array(bend_rings(forearm.origin, arm.basis, forearm.basis, 0.036, Vector2(0.045, 0.047), Vector2(0.049, 0.048), "UpperArm" + s, "Forearm" + s, 0.065, 0.15))
	# 17.11: предплечье — широкое у локтя (мышцы-сгибатели), к запястью плоское
	rings.append_array([
		ring(forearm.origin.lerp(hand.origin, 0.38), forearm.basis, 0.049, 0.044, "Forearm" + s, "", 0.0, Vector2(side * 0.002, 0.001)),
		ring(forearm.origin.lerp(hand.origin, 0.64), forearm.basis, 0.040, 0.033, "Forearm" + s),
		ring(forearm.origin.lerp(hand.origin, 0.80), forearm.basis, 0.034, 0.027, "Forearm" + s),
		ring(forearm.origin.lerp(hand.origin, 0.804), forearm.basis, 0.038, 0.035, "Forearm" + s),
		ring(hand.origin, forearm.basis, 0.037, 0.034, "Forearm" + s),
	])
	var mats := []
	for i in root_count + 2:
		mats.append(teal)
	mats.append_array([panel, panel])
	# кожа до запястья, затем манжета перчатки от своей кромки до кулака
	for i in rings.size() - 1 - mats.size() - 2:
		mats.append(skin)
	mats.append_array([navy, navy])
	# рукав у края свободнее и треплется на ветру
	for i in rings.size():
		rings[i].flutter = 0.0 if i < root_count else (0.5 if i < root_count + 4 else 0.0)
	var outer := PI if side < 0 else 0.0
	# светлая полоса по внешней стороне рукава — участок самой поверхности
	loft(rings, skin, null, mats, ARM_SIDES, false, [{from = root_count, to = root_count + 2, angle = outer, half = 0.22, mat = cream}])


## Единая непрерывная поверхность ноги: ягодично-тазовый переход с защитой паха от сминания,
## свод квадрицепса, манжета велотрусов, коленная чашечка, высокая икроножная мышца, ахилл и носок.
func _leg(side: float) -> void:
	var s := "L" if side < 0 else "R"
	var thigh := skeleton.get_bone_global_pose(skeleton.find_bone("UpperLeg" + s))
	var calf := skeleton.get_bone_global_pose(skeleton.find_bone("LowerLeg" + s))
	var foot := skeleton.get_bone_global_pose(skeleton.find_bone("Foot" + s))
	var rings: Array[Dictionary] = [
		ring(thigh.origin + Vector3(-side * 0.025, -0.010, -0.010), thigh.basis, 0.062, 0.065, "Hips", "UpperLeg" + s, 0.0),
		ring(thigh.origin.lerp(calf.origin, 0.08) + Vector3(-side * 0.006, -0.006, 0.0), thigh.basis, 0.076, 0.081, "Hips", "UpperLeg" + s, 0.58, Vector2.ZERO, Vector2(side * 0.08, -0.18), Vector3(-0.026, 0.015, 0.002)),
		ring(thigh.origin.lerp(calf.origin, 0.22) + Vector3(-side * 0.002, -0.002, 0.0), thigh.basis, 0.084, 0.089, "UpperLeg" + s, "Hips", 0.10, Vector2(side * 0.002, 0.002), Vector2.ZERO, Vector3(0.022, 0.018, -0.002)),
		ring(thigh.origin.lerp(calf.origin, 0.38), thigh.basis, 0.081, 0.087, "UpperLeg" + s, "", 0.0, Vector2(side * 0.003, 0.005), Vector2.ZERO, Vector3(-0.014, 0.014, 0.001)),
		ring(thigh.origin.lerp(calf.origin, 0.56), thigh.basis, 0.074, 0.078, "UpperLeg" + s, "", 0.0, Vector2(side * 0.002, 0.004), Vector2.ZERO, Vector3(0.010, 0.010, 0.0)),
		ring(thigh.origin.lerp(calf.origin, 0.67), thigh.basis, 0.069, 0.072, "UpperLeg" + s, "", 0.0, Vector2(side * 0.001, 0.003)),
		ring(thigh.origin.lerp(calf.origin, 0.70), thigh.basis, 0.068, 0.070, "UpperLeg" + s, "", 0.0, Vector2(side * 0.001, 0.003)),
		ring(thigh.origin.lerp(calf.origin, 0.704), thigh.basis, 0.061, 0.064, "UpperLeg" + s, "", 0.0, Vector2(side * 0.001, 0.003)),
	]
	rings.append_array(bend_rings(calf.origin, thigh.basis, calf.basis, 0.046, Vector2(0.056, 0.059), Vector2(0.050, 0.053), "UpperLeg" + s, "LowerLeg" + s, 0.070, 0.13))
	rings.append_array([
		ring(calf.origin.lerp(foot.origin, 0.25), calf.basis, 0.058, 0.065, "LowerLeg" + s, "", 0.0, Vector2(side * 0.003, -0.009)),
		ring(calf.origin.lerp(foot.origin, 0.36), calf.basis, 0.061, 0.069, "LowerLeg" + s, "", 0.0, Vector2(side * 0.003, -0.012)),
		ring(calf.origin.lerp(foot.origin, 0.48), calf.basis, 0.053, 0.060, "LowerLeg" + s, "", 0.0, Vector2(side * 0.002, -0.008)),
		ring(calf.origin.lerp(foot.origin, 0.62), calf.basis, 0.042, 0.047, "LowerLeg" + s, "", 0.0, Vector2(0.0, -0.004)),
		ring(calf.origin.lerp(foot.origin, 0.76), calf.basis, 0.036, 0.040, "LowerLeg" + s, "", 0.0, Vector2(0.0, -0.002)),
		ring(calf.origin.lerp(foot.origin, 0.764), calf.basis, 0.040, 0.044, "LowerLeg" + s, "", 0.0, Vector2(0.0, -0.002)),
		ring(calf.origin.lerp(foot.origin, 0.79), calf.basis, 0.040, 0.044, "LowerLeg" + s, "", 0.0, Vector2(0.0, -0.002)),
		ring(calf.origin.lerp(foot.origin, 0.89), calf.basis, 0.034, 0.039, "LowerLeg" + s, "", 0.0, Vector2(0.0, -0.002)),
		ring(foot.origin, calf.basis.slerp(foot.basis, 0.35), 0.036, 0.040, "LowerLeg" + s, "Foot" + s, 0.35, Vector2(0.0, -0.002)),
	])
	# Сегменты: шорты до кромки (7), кожа через колено и икру, носок от своей кромки до щиколотки (4).
	var mats := [navy, navy, navy, navy, panel, navy, navy]
	for i in rings.size() - 1 - mats.size() - 4:
		mats.append(skin)
	mats.append_array([cream, cream, cream, cream])
	var outer := PI if side < 0 else 0.0
	# вставка другой ткани по внешней стороне бедра — участок самой поверхности
	loft(rings, skin, null, mats, 12, true, [{from = 2, to = 6, angle = outer, half = 0.2, mat = panel}])


## Сгиб локтя/колена. Ось конечности в зоне сустава идёт по дуге, касательной к обеим костям на расстоянии
## `tangent` от центра сустава; сечения веером поворачиваются вместе с ней (радиус дуги ≈ радиусу сечения,
## поэтому изнутри получается мягкая складка, а снаружи — округлый контур вместо угла двух цилиндров).
## Веса идут по smoothstep вдоль всей дуги и прилегающих прямых участков (spread), так что дополнительный
## сгиб в позе расходится по нескольким сечениям. Снаружи — выпуклость (локтевой отросток / надколенник).
func bend_rings(joint: Vector3, b1: Basis, b2: Basis, tangent: float, r1: Vector2, r2: Vector2, bone1: String, bone2: String, spread: float, bulge: float, fan := 5, straight: Array = [0.018, 0.04]) -> Array[Dictionary]:
	var d1 := b1.y
	var d2 := b2.y
	var theta := d1.angle_to(d2)
	var inside := (d2 - d1 * d1.dot(d2)).normalized()
	var radius := tangent / tan(theta * 0.5)
	var arc := radius * theta
	var pivot := joint - d1 * tangent + inside * radius
	var inside_local := b1.transposed() * inside
	var outer_angle := atan2(-inside_local.z, -inside_local.x)
	var half := arc * 0.5 + spread
	var items: Array[Array] = []
	for i in range(straight.size() - 1, -1, -1):
		items.append([joint - d1 * (tangent + float(straight[i])), b1, -(arc * 0.5 + float(straight[i]))])
	for i in fan:
		var f := float(i) / float(fan - 1)
		var bf := b1.slerp(b2, f).orthonormalized()
		items.append([pivot - (bf * inside_local) * radius, bf, (f - 0.5) * arc])
	for e in straight:
		items.append([joint + d2 * (tangent + float(e)), b2, arc * 0.5 + float(e)])
	var result: Array[Dictionary] = []
	for item in items:
		var s: float = item[2]
		var w := smoothstep(-half, half, s)
		var size := r1.lerp(r2, w)
		var r := ring(item[0], item[1], size.x, size.y, bone1, bone2, w)
		r.bulge = Vector2(outer_angle, bulge * exp(-pow(s / (arc * 0.5 + 0.012), 2.0)))
		result.append(r)
	return result


func local_loft(bone_name: String, centers: Array, sizes: Array, mat: Vector2i, sides := 12) -> void:
	var at := skeleton.get_bone_global_pose(skeleton.find_bone(bone_name))
	var rings: Array[Dictionary] = []
	for i in centers.size():
		rings.append(ring(at * centers[i], at.basis, sizes[i].x, sizes[i].y, bone_name))
	loft(rings, mat, null, [], sides)


## Тело вдоль стопы (−Z кости): сечения в плоскости XY кости, sizes — (полуширина, полувысота); угол π/2 — верх.
func axis_loft(bone_name: String, centers: Array, sizes: Array, mat: Vector2i, sides := 12, decals: Array = []) -> void:
	var at := skeleton.get_bone_global_pose(skeleton.find_bone(bone_name))
	var b := at.basis * Basis(Vector3.RIGHT, Vector3.FORWARD, Vector3.UP)
	var rings: Array[Dictionary] = []
	for i in centers.size():
		rings.append(ring(at * (centers[i] as Vector3), b, sizes[i].x, sizes[i].y, bone_name))
	loft(rings, mat, null, [], sides, true, decals)


## Трубка по точкам (в осях кости) с радиусами: сечения поперёк пути, жёстко на одной кости (пальцы).
func path_loft(bone_name: String, points: Array, radii: Array, mat: Vector2i, sides := 6) -> void:
	var at := skeleton.get_bone_global_pose(skeleton.find_bone(bone_name))
	var rings: Array[Dictionary] = []
	for i in points.size():
		var prev: Vector3 = points[maxi(i - 1, 0)]
		var next: Vector3 = points[mini(i + 1, points.size() - 1)]
		var y := (next - prev).normalized()
		var x := (Vector3.RIGHT - y * y.x).normalized()
		rings.append(ring(at * (points[i] as Vector3), at.basis * Basis(x, y, x.cross(y)), radii[i], radii[i], bone_name))
	loft(rings, mat, null, [], sides)


func ring(center: Vector3, basis: Basis, rx: float, rz: float, bone_name: String, other := "", weight := 0.0, offset := Vector2.ZERO, bias := Vector2.ZERO, fold := Vector3.ZERO) -> Dictionary:
	var index := skeleton.find_bone(bone_name)
	var other_index := skeleton.find_bone(other) if not other.is_empty() else index
	var shifted := center + basis * Vector3(offset.x, 0.0, offset.y)
	return {center = shifted, basis = basis, rx = rx, rz = rz, bone_index = index, other_index = other_index, weight = weight, bias = bias, fold = fold, bones = PackedInt32Array([index, other_index, 0, 0]), weights = PackedFloat32Array([1.0 - weight, weight, 0, 0])}


func point(r: Dictionary, angle: float) -> Dictionary:
	var weights: PackedFloat32Array = r.weights
	var bones: PackedInt32Array = r.bones
	var bias: Vector2 = r.get("bias", Vector2.ZERO)
	if bias != Vector2.ZERO and r.bone_index != r.other_index:
		var w := clampf(float(r.weight) + bias.x * cos(angle) + bias.y * sin(angle), 0.0, 1.0)
		weights = PackedFloat32Array([1.0 - w, w, 0.0, 0.0])
	# Третья кость по бокам сечения (ключицы на плечевом поясе торса): x > 0 — правая, x < 0 — левая.
	var extra: Dictionary = r.get("extra", {})
	if not extra.is_empty():
		var c := cos(angle)
		var we: float = float(extra.amount) * pow(absf(c), float(extra.power))
		if we > 0.0001:
			bones = PackedInt32Array([bones[0], bones[1], int(extra.pos) if c > 0.0 else int(extra.neg), 0])
			weights = PackedFloat32Array([weights[0] * (1.0 - we), weights[1] * (1.0 - we), we, 0.0])
	var fold: Vector3 = r.get("fold", Vector3.ZERO)
	var front := maxf(0.0, -sin(angle))
	var back := maxf(0.0, sin(angle))
	var scale := 1.0 + fold.x * front * front * cos(angle * 2.0) + fold.y * (back * back + 0.35 * cos(angle) * cos(angle))
	# Выпуклость с одной стороны сечения: локтевой отросток, надколенник, дельта (x — угол стороны, y — величина).
	var bulge: Vector2 = r.get("bulge", Vector2.ZERO)
	if bulge.y != 0.0:
		scale += bulge.y * pow(maxf(0.0, cos(angle - bulge.x)), 3.0)
	var axial_shift := fold.z * front * front
	var local := Vector3(cos(angle) * r.rx * scale, axial_shift, sin(angle) * r.rz * scale)
	var result := {position = r.center + r.basis * local, bones = bones, weights = weights, flutter = float(r.get("flutter", 0.0))}
	if r.has("delta_center"):
		var axial: Vector3 = r.delta_center + cos(angle) * r.delta_x + sin(angle) * r.delta_z
		var around: Vector3 = r.basis * Vector3(-sin(angle) * r.rx * scale, 0, cos(angle) * r.rz * scale)
		result.normal = axial.cross(around).normalized()
	return result


const LIP := 0.01 # сечения ближе этого (м) — кромка ткани: свет на ней плоский, соседей она не сглаживает


## Направления для гладких нормалей: по соседним сечениям, кромку соседом не считаем
func prepare(rings: Array[Dictionary]) -> void:
	for i in rings.size():
		var lower := rings[maxi(0, i - 1)]
		var upper := rings[mini(rings.size() - 1, i + 1)]
		if i > 0 and lower.center.distance_to(rings[i].center) < LIP:
			lower = rings[i]
		if i < rings.size() - 1 and upper.center.distance_to(rings[i].center) < LIP:
			upper = rings[i]
		rings[i].delta_center = upper.center - lower.center
		rings[i].delta_x = upper.basis.x * upper.rx - lower.basis.x * lower.rx
		rings[i].delta_z = upper.basis.z * upper.rz - lower.basis.z * lower.rz


## decals — участки рисунка на самой поверхности: {from, to — отрезки между сечениями [from, to), angle — середина,
## half — полуширина по углу, mat}. Грани делятся точно по краям участка, точки края лежат на гранях тела
## (как у соседних отрезков), поэтому рисунок не висит над тканью и не мерцает. Поздний участок перекрывает ранний.
func loft(rings: Array[Dictionary], mat: Vector2i, side_mat: Variant = null, mats: Array = [], sides := 12, cap_start := true, decals: Array = []) -> void:
	prepare(rings)
	for r in rings:
		r.sides = sides
	var step := TAU / sides
	for i in rings.size() - 1:
		var lip: bool = rings[i].center.distance_to(rings[i + 1].center) < LIP
		# столбцы отрезка: углы граней и края участков рисунка на нём
		var cols: Array[float] = []
		for j in sides + 1:
			cols.append(step * j)
		var here: Array = []
		for dcl: Dictionary in decals:
			if i >= int(dcl.from) and i < int(dcl.to):
				here.append(dcl)
				for edge: float in [float(dcl.angle) - float(dcl.half), float(dcl.angle) + float(dcl.half)]:
					var e := fposmod(edge, TAU)
					if float(dcl.half) < PI - 0.001 and e > 0.0005 and e < TAU - 0.0005:
						cols.append(e)
		cols.sort()
		for k in cols.size() - 1:
			var a0 := cols[k]
			var a1 := cols[k + 1]
			if a1 - a0 < 0.0005:
				continue
			var mid := (a0 + a1) * 0.5
			var j := int(floorf(mid / step))
			var use_mat: Vector2i = mats[i] if i < mats.size() and mats[i] != null else (side_mat if side_mat != null and j in [0, 5, 6, 11] else mat)
			for dcl: Dictionary in here:
				if absf(angle_difference(mid, float(dcl.angle))) < float(dcl.half):
					use_mat = dcl.mat
			var a := facet_point(rings[i], a0)
			var b := facet_point(rings[i + 1], a0)
			var c := facet_point(rings[i], a1)
			var d := facet_point(rings[i + 1], a1)
			if lip:
				for v: Dictionary in [a, b, c, d]:
					v.erase("normal")
			triangle(a, b, c, use_mat)
			triangle(c, b, d, use_mat)
	for end in [0, rings.size() - 1]:
		if end == 0 and not cap_start:
			continue
		var center := point(rings[end], 0)
		center.position = rings[end].center
		center.erase("normal")
		for j in sides:
			var a := point(rings[end], TAU * j / sides)
			var b := point(rings[end], TAU * (j + 1) / sides)
			a.erase("normal")
			b.erase("normal")
			var cap_mat: Vector2i = mat if mats.is_empty() else (mats[0] if end == 0 else mats[mats.size() - 1])
			triangle(center, a, b, cap_mat) if end == 0 else triangle(center, b, a, cap_mat)


## Точка сечения под углом angle на гранях тела: вершины граней — как point(), между ними — по прямой,
## с весами костей, смешанными так же (край участка рисунка не отстаёт от ткани на сгибе).
func facet_point(r: Dictionary, angle: float) -> Dictionary:
	var step := TAU / int(r.get("sides", 12))
	var section := angle / step
	var lower := floorf(section + 0.0001)
	var f := section - lower
	if f < 0.0005:
		return point(r, lower * step)
	var a := point(r, lower * step)
	var b := point(r, (lower + 1.0) * step)
	a.position = (a.position as Vector3).lerp(b.position, f)
	if a.has("normal") and b.has("normal"):
		a.normal = (a.normal as Vector3).lerp(b.normal, f).normalized()
	# Веса вставки — как у грани под ней (линейно между вершинами), иначе на сгибе она отстаёт от ткани.
	var mixed := {}
	for pair: Array in [[a, 1.0 - f], [b, f]]:
		var v: Dictionary = pair[0]
		for k in 4:
			var bone_index: int = v.bones[k]
			mixed[bone_index] = float(mixed.get(bone_index, 0.0)) + float(v.weights[k]) * float(pair[1])
	var keys := mixed.keys()
	keys.sort_custom(func(x, y): return mixed[x] > mixed[y])
	var bones := PackedInt32Array([0, 0, 0, 0])
	var weights := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	var total := 0.0
	for k in mini(4, keys.size()):
		bones[k] = keys[k]
		weights[k] = mixed[keys[k]]
		total += weights[k]
	for k in 4:
		weights[k] /= maxf(total, 0.0001)
	a.bones = bones
	a.weights = weights
	return a


## mat — краска (место палитры, вид поверхности): уходит в UV вершины; COLOR.g — подвижность ткани.
func triangle(a: Dictionary, b: Dictionary, c: Dictionary, mat: Vector2i) -> void:
	var normal: Vector3 = (b.position - a.position).cross(c.position - a.position).normalized()
	if normal.length_squared() < 0.5:
		return
	if tool == null:
		tool = SurfaceTool.new()
		tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for vertex: Dictionary in [a, c, b]: # Godot использует обход лицевых треугольников по часовой стрелке.
		var vertex_normal: Vector3 = vertex.get("normal", normal)
		# На резком переходе гладкая нормаль не должна уходить внутрь соседней грани.
		var facing := vertex_normal.dot(normal)
		if facing < 0.15:
			vertex_normal = (vertex_normal + normal * (0.15 - facing)).normalized()
		tool.set_uv(Vector2(mat.x, mat.y))
		tool.set_color(Color(1.0, float(vertex.get("flutter", 0.0)), 0.0, 1.0))
		tool.set_normal(vertex_normal)
		tool.set_bones(vertex.bones)
		tool.set_weights(vertex.weights)
		tool.add_vertex(vertex.position)


func ellipsoid(bone_name: String, size: Vector3, offset: Vector3, mat: Vector2i) -> void:
	var centers: Array[Vector3] = []
	var sizes: Array[Vector2] = []
	for i in 7:
		var angle := -PI * 0.5 + PI * i / 6.0
		centers.append(offset + Vector3(0, sin(angle) * size.y, 0))
		sizes.append(Vector2(size.x, size.z) * maxf(cos(angle), 0.01))
	local_loft(bone_name, centers, sizes, mat)


func box(bone_name: String, size: Vector3, offset: Vector3, mat: Vector2i, basis := Basis.IDENTITY) -> void:
	var at := skeleton.get_bone_global_pose(skeleton.find_bone(bone_name))
	var r := ring(at * offset, at.basis, 0, 0, bone_name)
	var vertices: Array[Dictionary] = []
	for corner: Vector3 in [Vector3(-1,-1,-1), Vector3(1,-1,-1), Vector3(1,1,-1), Vector3(-1,1,-1), Vector3(-1,-1,1), Vector3(1,-1,1), Vector3(1,1,1), Vector3(-1,1,1)]:
		vertices.append({position = at * (offset + basis * (corner * size * 0.5)), bones = r.bones, weights = r.weights})
	for face: Array in [[0,3,2,1], [4,5,6,7], [0,4,7,3], [1,2,6,5], [3,7,6,2], [0,1,5,4]]:
		triangle(vertices[face[0]], vertices[face[1]], vertices[face[2]], mat)
		triangle(vertices[face[0]], vertices[face[2]], vertices[face[3]], mat)


func bar(bone_name: String, a: Vector3, b: Vector3, thickness: float, mat: Vector2i) -> void:
	var direction := b - a
	box(bone_name, Vector3(thickness, direction.length(), thickness), (a + b) * 0.5, mat, Basis(Quaternion(Vector3.UP, direction.normalized())))


func bone(bone_name: String, parent: String, origin: Vector3) -> void:
	var index := skeleton.get_bone_count()
	skeleton.add_bone(bone_name)
	var parent_index := skeleton.find_bone(parent)
	skeleton.set_bone_parent(index, parent_index)
	var local := origin - rests[parent_index] if parent_index >= 0 else origin
	skeleton.set_bone_rest(index, Transform3D(Basis.IDENTITY, local))
	skeleton.set_bone_pose_position(index, local)
	rests.append(origin)


func _animation_reset() -> void:
	var player := AnimationPlayer.new()
	player.name = "AnimationPlayer"
	rider.add_child(player)
	player.owner = rider
	var library := AnimationLibrary.new()
	var reset := Animation.new()
	reset.length = 0.0
	library.add_animation("RESET", reset)
	player.add_animation_library("", library)
	for i in skeleton.get_bone_count():
		var path := NodePath("Skeleton3D:" + skeleton.get_bone_name(i))
		var position_track := reset.add_track(Animation.TYPE_POSITION_3D)
		reset.track_set_path(position_track, path)
		reset.position_track_insert_key(position_track, 0, skeleton.get_bone_pose_position(i))
		var rotation_track := reset.add_track(Animation.TYPE_ROTATION_3D)
		reset.track_set_path(rotation_track, path)
		reset.rotation_track_insert_key(rotation_track, 0, skeleton.get_bone_pose_rotation(i))
