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
var navy := material(Color("243747"))
var teal := material(Color("299a9a"))
var panel := material(Color("206c73"))
var skin := material(Color("dba47d"))
var cream := material(Color("f0e5cc"))
var dark := material(Color("17252e"))
var lens := material(Color("315363"), 0.22)
# Шлем v5: низ оболочки (м над костью головы), её высота и полуоси низа.
const HELMET_Y := 0.052
const HELMET_H := 0.112
const HELMET_R := Vector2(0.118, 0.138)
const HELMET_Z := -0.012


func material(color: Color, roughness := 0.85) -> StandardMaterial3D:
	var result := StandardMaterial3D.new()
	result.albedo_color = color
	result.roughness = roughness
	return result


func _init() -> void:
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
	var rings: Array[Dictionary] = []
	# Сужение в талии, грудь и линия плеч вместо пересекающихся овалов.
	for spec: Vector3 in [Vector3(0.06, 0.14, 0.09), Vector3(0.25, 0.137, 0.095), Vector3(0.48, 0.154, 0.106), Vector3(0.72, 0.18, 0.112), Vector3(0.87, 0.196, 0.105), Vector3(0.90, 0.195, 0.104), Vector3(1.02, 0.18, 0.09), Vector3(1.06, 0.125, 0.065), Vector3(1.12, 0.052, 0.048)]:
		var t := spec.x
		var lower := "Hips" if t < 0.5 else "Spine"
		var upper := "Spine" if t < 0.5 else "Chest"
		var weight := clampf(t * 2.0 if t < 0.5 else (t - 0.5) * 2.0, 0.0, 1.0)
		rings.append(ring(hip.lerp(chest, t), Basis.IDENTITY, spec.y, spec.z, lower, upper, weight))
	loft(rings, teal, panel)
	patch(rings.slice(7, 9), PI * 0.5, PI, panel)
	local_loft("Hips", [Vector3(0, -0.09, 0), Vector3(0, 0.025, 0), Vector3(0, 0.055, 0)], [Vector2(0.135, 0.09), Vector2(0.15, 0.105), Vector2(0.14, 0.095)], navy)
	_neck()
	# Детали лежат на той же поверхности и имеют те же веса: не висят над одеждой.
	patch(rings.slice(0, 7), -PI * 0.5, 0.035, dark)
	patch(rings.slice(4, 6), -PI * 0.5 - 0.42, 0.28, cream)
	patch(rings.slice(4, 6), PI * 0.5, 0.7, cream)
	# Крупная кокетка и боковые вставки читаются с игровой камеры, повторяя веса торса.
	patch(rings.slice(5, 7), PI * 0.5, 0.8, panel)
	for angle in [0.18, PI - 0.18]:
		patch(rings.slice(2, 7), angle, 0.10, cream)
	# Три кармана и светоотражающая кромка на спине повторяют деформацию джерси.
	for angle in [PI * 0.5 - 0.40, PI * 0.5, PI * 0.5 + 0.40]:
		patch(rings.slice(1, 3), angle, 0.16, panel)
	patch(rings.slice(3, 4 + 1), PI * 0.5, 0.045, cream)



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
	local_loft("Head", centers, sizes, cream, 24)
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
	# v5: рукав до двух третей плеча, кромка тёмная, ниже — рука (одна поверхность)
	limb("UpperArm" + s, "Forearm" + s, [Vector3(0.0, 0.065, 0.060), Vector3(0.08, 0.067, 0.065), Vector3(0.18, 0.073, 0.067), Vector3(0.38, 0.064, 0.058), Vector3(0.58, 0.059, 0.054), Vector3(0.63, 0.058, 0.053), Vector3(0.634, 0.05, 0.047), Vector3(0.84, 0.045, 0.043), Vector3(1, 0.043, 0.046)], teal, "", true,
		[teal, teal, teal, teal, panel, panel, skin, skin])
	limb("Forearm" + s, "Hand" + s, [Vector3(0, 0.043, 0.046), Vector3(0.16, 0.049, 0.047), Vector3(0.35, 0.049, 0.044), Vector3(0.65, 0.038, 0.035), Vector3(0.86, 0.03, 0.03), Vector3(1, 0.028, 0.028)], skin, "UpperArm" + s)
	# Ладонь и согнутый большой палец вместо двух шаров. Весь хват жёстко следует Hand.
	local_loft("Hand" + s, [Vector3(0, -0.035, -0.018), Vector3(0, -0.016, -0.022), Vector3(0, 0.02, -0.012), Vector3(0, 0.038, 0)], [Vector2(0.035, 0.024), Vector2(0.044, 0.042), Vector2(0.043, 0.042), Vector2(0.032, 0.025)], navy, 8)
	local_loft("Hand" + s, [Vector3(-side * 0.03, -0.025, -0.005), Vector3(-side * 0.046, -0.012, -0.018), Vector3(-side * 0.032, 0.006, -0.036)], [Vector2(0.015, 0.017), Vector2(0.018, 0.019), Vector2(0.012, 0.014)], navy, 8)
	box("Hand" + s, Vector3(0.053, 0.009, 0.027), Vector3(0, 0.035, -0.008), panel)
	box("Hand" + s, Vector3(0.038, 0.004, 0.008), Vector3(0, 0.041, -0.007), cream)
	# v5: велотрусы до трёх четвертей бедра — кромка выше колена, сгиб колена — уже кожа
	limb("UpperLeg" + s, "LowerLeg" + s, [Vector3(0, 0.077, 0.08), Vector3(0.17, 0.086, 0.088), Vector3(0.4, 0.08, 0.081), Vector3(0.6, 0.073, 0.073), Vector3(0.7, 0.07, 0.07), Vector3(0.704, 0.063, 0.064), Vector3(0.88, 0.052, 0.054), Vector3(1, 0.047, 0.05)], navy, "", true,
		[navy, navy, navy, panel, navy, skin, skin])
	# v5: голень открыта, носок над обувью с отворотом
	limb("LowerLeg" + s, "Foot" + s, [Vector3(0, 0.052, 0.055), Vector3(0.12, 0.048, 0.051), Vector3(0.38, 0.058, 0.064), Vector3(0.7, 0.038, 0.042), Vector3(0.78, 0.035, 0.038), Vector3(0.782, 0.039, 0.042), Vector3(0.8, 0.039, 0.042), Vector3(0.9, 0.031, 0.034), Vector3(1, 0.027, 0.03)], skin, "UpperLeg" + s, false,
		[skin, skin, skin, skin, cream, cream, cream, cream])
	local_loft("Foot" + s, [Vector3(0, -0.048, -0.035), Vector3(0, -0.033, -0.035)], [Vector2(0.064, 0.124), Vector2(0.065, 0.125)], dark)
	local_loft("Foot" + s, [Vector3(0, -0.033, -0.035), Vector3(0, -0.005, -0.035), Vector3(0, 0.025, -0.015)], [Vector2(0.065, 0.125), Vector2(0.059, 0.105), Vector2(0.034, 0.055)], cream)
	box("Foot" + s, Vector3(0.1, 0.014, 0.026), Vector3(0, 0.013, -0.065), panel)
	box("Foot" + s, Vector3(0.08, 0.012, 0.023), Vector3(0, 0.026, -0.025), navy)
	box("Foot" + s, Vector3(0.09, 0.025, 0.015), Vector3(0, -0.012, 0.068), panel)
	box("Foot" + s, Vector3(0.10, 0.018, 0.018), Vector3(0, -0.026, -0.144), dark)


## Первые сечения рукава выходят из груди; отдельной шарообразной крышки нет.
func _shoulder(side: float) -> Array[Dictionary]:
	var suffix := "L" if side < 0 else "R"
	var arm := skeleton.get_bone_global_pose(skeleton.find_bone("UpperArm" + suffix))
	var rings: Array[Dictionary] = []
	var across := Basis(Quaternion(Vector3.UP, Vector3(side, 0, 0)))
	for i in 3:
		var t := float(i) / 3.0
		var inner := arm.origin + Vector3(-side * 0.09, -0.045, 0)
		var outer := arm.origin
		var basis := across.slerp(arm.basis, t)
		var radius := lerpf(0.045, 0.065, t)
		rings.append(ring(inner.lerp(outer, t), basis, radius, radius * 0.92, "Chest", "UpperArm" + suffix, t))
	return rings


## mats — материал каждого отрезка между сечениями (пусто — весь mat): смена ткани без торцов внутри
func limb(bone_name: String, next: String, profile: Array, mat: Material, previous := "", blend_end := false, mats: Array = []) -> void:
	var at := skeleton.get_bone_global_pose(skeleton.find_bone(bone_name))
	var end := skeleton.get_bone_global_pose(skeleton.find_bone(next))
	var rings: Array[Dictionary] = []
	for spec: Vector3 in profile:
		var basis := at.basis
		var other := bone_name
		var weight := 0.0
		if not previous.is_empty() and spec.x < 0.2:
			other = previous
			weight = (1.0 - spec.x / 0.2) * 0.5
			basis = at.basis.slerp(skeleton.get_bone_global_pose(skeleton.find_bone(previous)).basis, weight)
		elif blend_end and spec.x > 0.8:
			other = next
			weight = (spec.x - 0.8) / 0.2 * 0.5
			basis = at.basis.slerp(end.basis, weight)
		rings.append(ring(at.origin.lerp(end.origin, spec.x), basis, spec.y, spec.z, bone_name, other, weight))
	# Плечо и рукав — один loft с общими сечениями и нормалями на стыке.
	var sleeve := bone_name.begins_with("UpperArm")
	var geometry: Array[Dictionary] = []
	var segment_mats := mats.duplicate()
	if sleeve:
		geometry = _shoulder(-1.0 if bone_name.ends_with("L") else 1.0)
		for i in geometry.size():
			segment_mats.push_front(mat)
	geometry.append_array(rings)
	loft(geometry, mat, null, segment_mats)
	# Небольшие светоотражающие детали вплетены в поверхность, поэтому не отделяются при сгибе.
	if bone_name.begins_with("UpperArm"):
		var outer := PI if bone_name.ends_with("L") else 0.0
		patch(rings.slice(3, 5), outer, 0.22, cream)
	elif bone_name.begins_with("UpperLeg"):
		var outer := PI if bone_name.ends_with("L") else 0.0
		patch(rings.slice(2, 4), outer, 0.16, panel)


func local_loft(bone_name: String, centers: Array, sizes: Array, mat: Material, sides := 12) -> void:
	var at := skeleton.get_bone_global_pose(skeleton.find_bone(bone_name))
	var rings: Array[Dictionary] = []
	for i in centers.size():
		rings.append(ring(at * centers[i], at.basis, sizes[i].x, sizes[i].y, bone_name))
	loft(rings, mat, null, [], sides)


func ring(center: Vector3, basis: Basis, rx: float, rz: float, bone_name: String, other := "", weight := 0.0) -> Dictionary:
	var index := skeleton.find_bone(bone_name)
	var other_index := skeleton.find_bone(other) if not other.is_empty() else index
	return {center = center, basis = basis, rx = rx, rz = rz, bones = PackedInt32Array([index, other_index, 0, 0]), weights = PackedFloat32Array([1.0 - weight, weight, 0, 0])}


func point(r: Dictionary, angle: float) -> Dictionary:
	var result := {position = r.center + r.basis * Vector3(cos(angle) * r.rx, 0, sin(angle) * r.rz), bones = r.bones, weights = r.weights}
	if r.has("delta_center"):
		var axial: Vector3 = r.delta_center + cos(angle) * r.delta_x + sin(angle) * r.delta_z
		var around: Vector3 = r.basis * Vector3(-sin(angle) * r.rx, 0, cos(angle) * r.rz)
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
			var use_mat: Material = mats[i] if i < mats.size() else (side_mat if side_mat != null and j in [0, 5, 6, 11] else mat)
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
