extends SceneTree
## Модель v7. Пересборка перезаписывает изолированную scenes/cyclist.tscn.
## v5: шлем сидит на голове (ниже и плотнее, козырёк короче и под наклоном), из-под шлема видны волосы,
## велотрусы выше колена и открытые голени с носками, рукав джерси короче — у локтя видна рука.
## Смена ткани на конечности — одна непрерывная поверхность с узким отворотом (кромка), а не отдельные
## трубки с торцами: иначе на сгибе колена и локтя торцы выпирают рваными кольцами.
## Волосы — полоса по поверхности затылка (как вставки на джерси), а не эллипсоиды.
## Один штатный skinned ArrayMesh, прежние 22 кости, без внешних моделей и текстур.
var rider: CyclistRig
var skeleton: Skeleton3D
var rests: Array[Vector3] = []
var surfaces: Dictionary = {}
var navy := material(Color("243747"), 0.72, 0.0, 0.38, 0.18, 0.45)
var teal := material(Color("299a9a"), 0.88, 0.0, 0.22, 0.28, 0.65)
var panel := material(Color("206c73"), 0.82, 0.0, 0.28, 0.22, 0.55)
var skin := material(Color("dba47d"), 0.62, 0.0, 0.35, 0.14, 0.35)
var cream := material(Color("f0e5cc"), 0.52, 0.02, 0.48)
var helmet := material(Color("f2e8d0"), 0.28, 0.04, 0.68, 0.0, 0.0, 0.55, 0.18)
var dark := material(Color("17252e"), 0.46, 0.06, 0.55)
var lens := material(Color("315363"), 0.10, 0.32, 0.92, 0.0, 0.0, 0.85, 0.08)
# Шлем v5: низ оболочки (м над костью головы), её высота и полуоси низа.
const HELMET_Y := 0.052
const HELMET_H := 0.112
const HELMET_R := Vector2(0.118, 0.138)
const HELMET_Z := -0.012


func material(color: Color, roughness := 0.85, metallic := 0.0, specular := 0.5, rim := 0.0, rim_tint := 0.5, clearcoat := 0.0, clearcoat_roughness := 0.2) -> StandardMaterial3D:
	var result := StandardMaterial3D.new()
	result.albedo_color = color
	result.roughness = roughness
	result.metallic = metallic
	result.metallic_specular = specular
	if rim > 0.0:
		result.rim_enabled = true
		result.rim = rim
		result.rim_tint = rim_tint
	if clearcoat > 0.0:
		result.clearcoat_enabled = true
		result.clearcoat = clearcoat
		result.clearcoat_roughness = clearcoat_roughness
	return result


func _init() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	rider = CyclistRig.new()
	rider.name = "Rider"
	rider.set_meta("model_version", 7)
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
	var mesh := ArrayMesh.new()
	for mat: Material in surfaces:
		var tool: SurfaceTool = surfaces[mat]
		tool.index()
		tool.commit(mesh)
	var body := MeshInstance3D.new()
	body.name = "Body"
	body.mesh = mesh
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
	print("Cyclist v7: ", error_string(error), "; surfaces=", mesh.get_surface_count())
	quit(error)


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
	var torso_specs: Array[Array] = [
		[0.06, 0.148, 0.099, 0.002, 0.0, Vector3(0.025, 0.010, -0.002)],
		[0.15, 0.141, 0.095, 0.004, 0.0, Vector3(-0.032, 0.012, 0.002)],
		[0.25, 0.140, 0.097, 0.006, 0.0, Vector3(0.028, -0.008, -0.002)],
		[0.36, 0.147, 0.102, 0.007, 0.0, Vector3(-0.024, 0.010, 0.001)],
		[0.48, 0.156, 0.108, 0.008, 0.0, Vector3(0.018, 0.014, -0.001)],
		[0.72, 0.182, 0.113, 0.004, 0.0, Vector3(-0.014, 0.018, 0.0)],
		[0.87, 0.196, 0.105, 0.0, 0.0, Vector3(-0.018, 0.015, 0.001)],
		[0.91, 0.194, 0.102, -0.001, 0.08, Vector3.ZERO],
		[0.99, 0.172, 0.088, -0.004, 0.32, Vector3.ZERO],
		[1.04, 0.118, 0.066, -0.006, 0.68, Vector3.ZERO],
		[1.09, 0.055, 0.056, -0.006, 1.0, Vector3.ZERO],
	]
	for spec: Array in torso_specs:
		var t: float = spec[0]
		var lower := "Hips" if t < 0.5 else "Spine"
		var upper := "Spine" if t < 0.5 else "Chest"
		var weight := clampf(t * 2.0 if t < 0.5 else (t - 0.5) * 2.0, 0.0, 1.0)
		var ring_basis := Basis.IDENTITY.slerp(neck_basis, float(spec[4]))
		var center := collar if float(spec[4]) >= 0.99 else hip.lerp(chest, t) + Vector3(0.0, 0.0, float(spec[3]))
		rings.append(ring(center, ring_basis, spec[1], spec[2], lower, upper, weight, Vector2.ZERO, Vector2.ZERO, spec[5] as Vector3))
	loft(rings, teal, panel, [navy, navy, navy])
	var jersey := rings.slice(3)
	patch(jersey.slice(9, 11), PI * 0.5, PI, panel)
	_neck()
	# Детали лежат на той же поверхности и имеют те же веса: не висят над одеждой.
	patch(jersey.slice(0, 9), -PI * 0.5, 0.035, dark)
	patch(jersey.slice(6, 8), -PI * 0.5 - 0.42, 0.28, cream)
	patch(jersey.slice(6, 8), PI * 0.5, 0.7, cream)
	# Умеренные складки на сгибе талии спереди-сбоку.
	for side_sign in [-1.0, 1.0]:
		patch(jersey.slice(1, 3), -PI * 0.5 + side_sign * 0.48, 0.18, panel)
		patch(jersey.slice(3, 4 + 1), -PI * 0.5 + side_sign * 0.52, 0.14, panel)
	# Крупная кокетка и боковые вставки читаются с игровой камеры, повторяя веса торса.
	patch(jersey.slice(7, 9), PI * 0.5, 0.8, panel)
	for angle in [0.18, PI - 0.18]:
		patch(jersey.slice(4, 9), angle, 0.10, cream)
	# Три кармана и светоотражающая кромка на спине повторяют деформацию джерси.
	for angle in [PI * 0.5 - 0.40, PI * 0.5, PI * 0.5 + 0.40]:
		patch(jersey.slice(2, 5), angle, 0.16, panel)
	patch(jersey.slice(5, 6 + 1), PI * 0.5, 0.045, cream)



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
	for spec: Array in [[0.0, 0.054, 0.056, "Chest", "", 0.0], [0.3, 0.052, 0.055, "Chest", "Neck", 0.5], [0.6, 0.051, 0.055, "Neck", "Head", 0.3], [0.85, 0.056, 0.062, "Neck", "Head", 0.7], [1.0, 0.058, 0.064, "Head", "", 0.0]]:
		rings.append(ring(collar.lerp(skull, spec[0]), basis, spec[1], spec[2], spec[3], spec[4], spec[5]))
	loft(rings, skin)
	# Воротник джерси: низкая стойка вокруг шеи закрывает гранёный верх торса
	var band: Array[Dictionary] = []
	for spec: Vector3 in [Vector3(-0.008, 0.057, 0.059), Vector3(0.012, 0.058, 0.060), Vector3(0.027, 0.055, 0.058)]:
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
		goggle(start, end, 0.036, 0.018, 1.0, dark)
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
			triangle(a, b, c, dark)
			triangle(c, b, d, dark)


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


func goggle(start: float, end: float, height: float, y: float, radius: float, mat: Material) -> void:
	var at := skeleton.get_bone_global_pose(skeleton.find_bone("Head"))
	var r := ring(Vector3.ZERO, Basis.IDENTITY, 0, 0, "Head")
	for i in 5:
		var vertices: Array[Dictionary] = []
		for corner: Vector2 in [Vector2(float(i) / 5, -0.5), Vector2(float(i + 1) / 5, -0.5), Vector2(float(i + 1) / 5, 0.5), Vector2(float(i) / 5, 0.5)]:
			var angle := lerpf(start, end, corner.x)
			var point_at := Vector3(sin(angle) * 0.102 * radius, y + corner.y * height, -cos(angle) * 0.112 * radius)
			vertices.append({position = at * point_at, bones = r.bones, weights = r.weights})
		triangle(vertices[0], vertices[2], vertices[1], mat)
		triangle(vertices[0], vertices[3], vertices[2], mat)


func helmet_strip(x: float, width: float, mat: Material) -> void:
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
	_leg(side)
	local_loft("Foot" + s, [Vector3(0, -0.048, -0.035), Vector3(0, -0.033, -0.035)], [Vector2(0.064, 0.124), Vector2(0.065, 0.125)], dark)
	local_loft("Foot" + s, [Vector3(0, -0.033, -0.035), Vector3(0, -0.018, -0.037), Vector3(0, -0.005, -0.035), Vector3(0, 0.025, -0.015)], [Vector2(0.065, 0.125), Vector2(0.062, 0.114), Vector2(0.059, 0.105), Vector2(0.034, 0.055)], cream)
	box("Foot" + s, Vector3(0.1, 0.014, 0.026), Vector3(0, 0.013, -0.065), panel)
	box("Foot" + s, Vector3(0.08, 0.012, 0.023), Vector3(0, 0.026, -0.025), navy)
	box("Foot" + s, Vector3(0.09, 0.025, 0.015), Vector3(0, -0.012, 0.068), panel)
	box("Foot" + s, Vector3(0.10, 0.018, 0.018), Vector3(0, -0.026, -0.144), dark)


const DOWN_BASIS := Basis(Vector3.RIGHT, Vector3.DOWN, Vector3.FORWARD)


## Единая непрерывная поверхность руки: переход грудь–плечо, дельта, бицепс/трицепс,
## кромка рукава, локтевой отросток (olecranon) и предплечье до запястья без внутренних торцов.
func _arm(side: float) -> void:
	var s := "L" if side < 0 else "R"
	var arm := skeleton.get_bone_global_pose(skeleton.find_bone("UpperArm" + s))
	var forearm := skeleton.get_bone_global_pose(skeleton.find_bone("Forearm" + s))
	var hand := skeleton.get_bone_global_pose(skeleton.find_bone("Hand" + s))
	var root_a := Basis(arm.basis.z, -side * 0.36) * arm.basis
	var root_b := Basis(arm.basis.z, -side * 0.18) * arm.basis
	var rings: Array[Dictionary] = [
		ring(arm.origin + Vector3(-side * 0.080, -0.025, 0.006), root_a, 0.046, 0.050, "Chest", "Clavicle" + s, 0.0),
		ring(arm.origin + Vector3(-side * 0.038, -0.020, 0.003), root_b, 0.056, 0.058, "Chest", "Clavicle" + s, 0.60, Vector2.ZERO, Vector2.ZERO, Vector3(-0.028, 0.016, 0.002)),
		ring(arm.origin + Vector3(-side * 0.004, -0.016, 0.0), arm.basis, 0.062, 0.061, "Clavicle" + s, "UpperArm" + s, 0.65, Vector2.ZERO, Vector2.ZERO, Vector3(0.022, 0.018, -0.002)),
		ring(arm.origin.lerp(forearm.origin, 0.13) + Vector3(0.0, -0.006, 0.0), arm.basis, 0.066, 0.063, "UpperArm" + s, "Clavicle" + s, 0.08, Vector2.ZERO, Vector2.ZERO, Vector3(-0.025, 0.014, 0.002)),
		ring(arm.origin.lerp(forearm.origin, 0.26), arm.basis, 0.064, 0.062, "UpperArm" + s, "", 0.0, Vector2(side * 0.002, 0.0), Vector2.ZERO, Vector3(0.020, 0.010, -0.001)),
		ring(arm.origin.lerp(forearm.origin, 0.42), arm.basis, 0.059, 0.059, "UpperArm" + s, "", 0.0, Vector2(side * 0.001, 0.001), Vector2.ZERO, Vector3(-0.016, 0.008, 0.001)),
		ring(arm.origin.lerp(forearm.origin, 0.58), arm.basis, 0.055, 0.056, "UpperArm" + s, "", 0.0, Vector2(0.0, 0.001), Vector2.ZERO, Vector3(0.014, 0.006, 0.0)),
		ring(arm.origin.lerp(forearm.origin, 0.63), arm.basis, 0.054, 0.055, "UpperArm" + s, "", 0.0, Vector2(0.0, 0.001)),
		ring(arm.origin.lerp(forearm.origin, 0.634), arm.basis, 0.047, 0.049, "UpperArm" + s, "", 0.0, Vector2(0.0, 0.001)),
		ring(arm.origin.lerp(forearm.origin, 0.82), arm.basis.slerp(forearm.basis, 0.14), 0.044, 0.046, "UpperArm" + s, "Forearm" + s, 0.14, Vector2(0.0, -0.001)),
		ring(arm.origin.lerp(forearm.origin, 0.93), arm.basis.slerp(forearm.basis, 0.34), 0.046, 0.048, "UpperArm" + s, "Forearm" + s, 0.34, Vector2(side * 0.002, -0.003)),
		ring(forearm.origin, arm.basis.slerp(forearm.basis, 0.50), 0.047, 0.050, "UpperArm" + s, "Forearm" + s, 0.50, Vector2(side * 0.002, -0.005)),
		ring(forearm.origin.lerp(hand.origin, 0.08), forearm.basis.slerp(arm.basis, 0.30), 0.048, 0.049, "Forearm" + s, "UpperArm" + s, 0.30, Vector2(side * 0.002, -0.003)),
		ring(forearm.origin.lerp(hand.origin, 0.20), forearm.basis.slerp(arm.basis, 0.08), 0.050, 0.048, "Forearm" + s, "UpperArm" + s, 0.08, Vector2(side * 0.003, 0.001)),
		ring(forearm.origin.lerp(hand.origin, 0.38), forearm.basis, 0.046, 0.044, "Forearm" + s, "", 0.0, Vector2(side * 0.002, 0.001)),
		ring(forearm.origin.lerp(hand.origin, 0.64), forearm.basis, 0.038, 0.035, "Forearm" + s),
		ring(forearm.origin.lerp(hand.origin, 0.85), forearm.basis, 0.032, 0.029, "Forearm" + s),
		ring(hand.origin, forearm.basis, 0.030, 0.026, "Forearm" + s),
	]
	var mats := [teal, teal, teal, teal, teal, teal, panel, panel, skin, skin, skin, skin, skin, skin, skin, skin, skin]
	loft(rings, skin, null, mats)
	var outer := PI if side < 0 else 0.0
	var inner := 0.0 if side < 0 else PI
	patch(rings.slice(4, 7), outer, 0.22, cream)
	# Складка рукава у переднего края подмышечной впадины.
	patch(rings.slice(2, 4), inner - side * 0.45, 0.16, panel)


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
		ring(thigh.origin.lerp(calf.origin, 0.84), thigh.basis.slerp(calf.basis, 0.16), 0.054, 0.057, "UpperLeg" + s, "LowerLeg" + s, 0.16, Vector2(side * 0.001, 0.002)),
		ring(thigh.origin.lerp(calf.origin, 0.93), thigh.basis.slerp(calf.basis, 0.34), 0.052, 0.055, "UpperLeg" + s, "LowerLeg" + s, 0.34, Vector2(side * 0.001, 0.003)),
		ring(calf.origin, thigh.basis.slerp(calf.basis, 0.50), 0.051, 0.053, "UpperLeg" + s, "LowerLeg" + s, 0.50, Vector2(side * 0.001, -0.003)),
		ring(calf.origin.lerp(foot.origin, 0.07), calf.basis.slerp(thigh.basis, 0.30), 0.050, 0.052, "LowerLeg" + s, "UpperLeg" + s, 0.30, Vector2(0.0, 0.002)),
		ring(calf.origin.lerp(foot.origin, 0.14), calf.basis.slerp(thigh.basis, 0.10), 0.048, 0.051, "LowerLeg" + s, "UpperLeg" + s, 0.10, Vector2(0.0, -0.001)),
		ring(calf.origin.lerp(foot.origin, 0.25), calf.basis, 0.058, 0.065, "LowerLeg" + s, "", 0.0, Vector2(side * 0.003, -0.009)),
		ring(calf.origin.lerp(foot.origin, 0.36), calf.basis, 0.061, 0.069, "LowerLeg" + s, "", 0.0, Vector2(side * 0.003, -0.012)),
		ring(calf.origin.lerp(foot.origin, 0.48), calf.basis, 0.053, 0.060, "LowerLeg" + s, "", 0.0, Vector2(side * 0.002, -0.008)),
		ring(calf.origin.lerp(foot.origin, 0.62), calf.basis, 0.042, 0.047, "LowerLeg" + s, "", 0.0, Vector2(0.0, -0.004)),
		ring(calf.origin.lerp(foot.origin, 0.76), calf.basis, 0.036, 0.040, "LowerLeg" + s, "", 0.0, Vector2(0.0, -0.002)),
		ring(calf.origin.lerp(foot.origin, 0.764), calf.basis, 0.040, 0.044, "LowerLeg" + s, "", 0.0, Vector2(0.0, -0.002)),
		ring(calf.origin.lerp(foot.origin, 0.79), calf.basis, 0.040, 0.044, "LowerLeg" + s, "", 0.0, Vector2(0.0, -0.002)),
		ring(calf.origin.lerp(foot.origin, 0.89), calf.basis, 0.034, 0.039, "LowerLeg" + s, "", 0.0, Vector2(0.0, -0.002)),
		ring(foot.origin, calf.basis.slerp(foot.basis, 0.35), 0.036, 0.040, "LowerLeg" + s, "Foot" + s, 0.35, Vector2(0.0, -0.002)),
	]
	var mats := [navy, navy, navy, navy, panel, navy, navy, skin, skin, skin, skin, skin, skin, skin, skin, skin, skin, cream, cream, cream, cream]
	loft(rings, skin, null, mats)
	var outer := PI if side < 0 else 0.0
	patch(rings.slice(3, 5), outer, 0.16, panel)
	# Складка натяжения велотрусов в паховом сгибе спереди.
	patch(rings.slice(1, 3), -PI * 0.5, 0.22, panel)


func local_loft(bone_name: String, centers: Array, sizes: Array, mat: Material, sides := 12) -> void:
	var at := skeleton.get_bone_global_pose(skeleton.find_bone(bone_name))
	var rings: Array[Dictionary] = []
	for i in centers.size():
		rings.append(ring(at * centers[i], at.basis, sizes[i].x, sizes[i].y, bone_name))
	loft(rings, mat, null, [], sides)


func ring(center: Vector3, basis: Basis, rx: float, rz: float, bone_name: String, other := "", weight := 0.0, offset := Vector2.ZERO, bias := Vector2.ZERO, fold := Vector3.ZERO) -> Dictionary:
	var index := skeleton.find_bone(bone_name)
	var other_index := skeleton.find_bone(other) if not other.is_empty() else index
	var shifted := center + basis * Vector3(offset.x, 0.0, offset.y)
	return {center = shifted, basis = basis, rx = rx, rz = rz, bone_index = index, other_index = other_index, weight = weight, bias = bias, fold = fold, bones = PackedInt32Array([index, other_index, 0, 0]), weights = PackedFloat32Array([1.0 - weight, weight, 0, 0])}


func point(r: Dictionary, angle: float) -> Dictionary:
	var weights: PackedFloat32Array = r.weights
	var bias: Vector2 = r.get("bias", Vector2.ZERO)
	if bias != Vector2.ZERO and r.bone_index != r.other_index:
		var w := clampf(float(r.weight) + bias.x * cos(angle) + bias.y * sin(angle), 0.0, 1.0)
		weights = PackedFloat32Array([1.0 - w, w, 0.0, 0.0])
	var fold: Vector3 = r.get("fold", Vector3.ZERO)
	var front := maxf(0.0, -sin(angle))
	var back := maxf(0.0, sin(angle))
	var scale := 1.0 + fold.x * front * front * cos(angle * 2.0) + fold.y * (back * back + 0.35 * cos(angle) * cos(angle))
	var axial_shift := fold.z * front * front
	var local := Vector3(cos(angle) * r.rx * scale, axial_shift, sin(angle) * r.rz * scale)
	var result := {position = r.center + r.basis * local, bones = r.bones, weights = weights}
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


func loft(rings: Array[Dictionary], mat: Material, side_mat: Material = null, mats: Array = [], sides := 12, cap_start := true) -> void:
	prepare(rings)
	for i in rings.size() - 1:
		var lip: bool = rings[i].center.distance_to(rings[i + 1].center) < LIP
		for j in sides:
			var use_mat: Material = mats[i] if i < mats.size() and mats[i] != null else (side_mat if side_mat != null and j in [0, 5, 6, 11] else mat)
			var a := point(rings[i], TAU * j / sides)
			var b := point(rings[i + 1], TAU * j / sides)
			var c := point(rings[i], TAU * (j + 1) / sides)
			var d := point(rings[i + 1], TAU * (j + 1) / sides)
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
			var cap_mat: Material = mat if mats.is_empty() else (mats[0] if end == 0 else mats[mats.size() - 1])
			triangle(center, a, b, cap_mat) if end == 0 else triangle(center, b, a, cap_mat)


func patch(rings: Array[Dictionary], angle: float, half_width: float, mat: Material) -> void:
	var angles: Array[float] = [angle - half_width]
	# Разбиваем вставку точно по граням тела, иначе широкая хорда провалится внутрь торса.
	for sector in range(floori((angle - half_width) / (TAU / 12.0)) + 1, ceili((angle + half_width) / (TAU / 12.0))):
		angles.append(sector * TAU / 12.0)
	angles.append(angle + half_width)
	for i in rings.size() - 1:
		for j in angles.size() - 1:
			var a := surface_point(rings[i], angles[j])
			var b := surface_point(rings[i + 1], angles[j])
			var c := surface_point(rings[i], angles[j + 1])
			var d := surface_point(rings[i + 1], angles[j + 1])
			triangle(a, b, c, mat)
			triangle(c, b, d, mat)


func surface_point(r: Dictionary, angle: float) -> Dictionary:
	var section := angle / (TAU / 12.0)
	var lower := floorf(section)
	var a := point(r, lower * TAU / 12.0)
	var b := point(r, (lower + 1.0) * TAU / 12.0)
	var position: Vector3 = a.position.lerp(b.position, section - lower)
	a.position = r.center + (position - r.center) * 1.012
	if a.has("normal") and b.has("normal"):
		a.normal = (a.normal as Vector3).lerp(b.normal, section - lower).normalized()
	return a


func triangle(a: Dictionary, b: Dictionary, c: Dictionary, mat: Material) -> void:
	var normal: Vector3 = (b.position - a.position).cross(c.position - a.position).normalized()
	if normal.length_squared() < 0.5:
		return
	var tool: SurfaceTool = surfaces.get(mat)
	if tool == null:
		tool = SurfaceTool.new()
		tool.begin(Mesh.PRIMITIVE_TRIANGLES)
		tool.set_material(mat)
		surfaces[mat] = tool
	for vertex: Dictionary in [a, c, b]: # Godot использует обход лицевых треугольников по часовой стрелке.
		var vertex_normal: Vector3 = vertex.get("normal", normal)
		# На резком переходе гладкая нормаль не должна уходить внутрь соседней грани.
		var facing := vertex_normal.dot(normal)
		if facing < 0.15:
			vertex_normal = (vertex_normal + normal * (0.15 - facing)).normalized()
		tool.set_normal(vertex_normal)
		tool.set_bones(vertex.bones)
		tool.set_weights(vertex.weights)
		tool.add_vertex(vertex.position)


func ellipsoid(bone_name: String, size: Vector3, offset: Vector3, mat: Material) -> void:
	var centers: Array[Vector3] = []
	var sizes: Array[Vector2] = []
	for i in 7:
		var angle := -PI * 0.5 + PI * i / 6.0
		centers.append(offset + Vector3(0, sin(angle) * size.y, 0))
		sizes.append(Vector2(size.x, size.z) * maxf(cos(angle), 0.01))
	local_loft(bone_name, centers, sizes, mat)


func box(bone_name: String, size: Vector3, offset: Vector3, mat: Material, basis := Basis.IDENTITY) -> void:
	var at := skeleton.get_bone_global_pose(skeleton.find_bone(bone_name))
	var r := ring(at * offset, at.basis, 0, 0, bone_name)
	var vertices: Array[Dictionary] = []
	for corner: Vector3 in [Vector3(-1,-1,-1), Vector3(1,-1,-1), Vector3(1,1,-1), Vector3(-1,1,-1), Vector3(-1,-1,1), Vector3(1,-1,1), Vector3(1,1,1), Vector3(-1,1,1)]:
		vertices.append({position = at * (offset + basis * (corner * size * 0.5)), bones = r.bones, weights = r.weights})
	for face: Array in [[0,3,2,1], [4,5,6,7], [0,4,7,3], [1,2,6,5], [3,7,6,2], [0,1,5,4]]:
		triangle(vertices[face[0]], vertices[face[1]], vertices[face[2]], mat)
		triangle(vertices[face[0]], vertices[face[2]], vertices[face[3]], mat)


func bar(bone_name: String, a: Vector3, b: Vector3, thickness: float, mat: Material) -> void:
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
