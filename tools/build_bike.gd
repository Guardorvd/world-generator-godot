extends SceneTree
## Источник scenes/bike.tscn. Размеры и имена контактов — контракт BikeView/IK/ragdoll.
## Модель v3 (12.11.2026): перёд собран заново вокруг одной оси рулевой (BikeView.STEERING_PIVOT, наклон FORK_RAKE):
## рулевая труба, шток, корона, ноги и штаны вилки стоят на этой оси, колесо вынесено вперёд короной, как у
## настоящей вилки; короткий вынос, прямой руль, суппорт сзади левой ноги. Точки переда задаются «до наклона»
## (ось вилки вертикальна) и ставятся на место через rk().
## Модель v2 (11.11.2026): детали собраны в несколько общих мешей по материалам (колесо, рама, руль, вилка,
## шатуны, задний узел), поэтому отдельных отрисовок не больше, чем у первой модели из трубок.
## Имена узлов, которые ищет BikeView, и их размеры не менялись: колёса, Crank/Pedal*, Fork*/Lower/Slider,
## перья (CylinderMesh вдоль местной Y), ChainTop/Bottom, ForkCrown, ForkCrownStem, ForkArch, Stem, Handlebar,
## LeverL/R (ось вращения — в начале узла), RearMechanics, Rider.
const LEG := 0.070 # полурасстояние между ногами вилки
var bike := BikeView.new()
var paint := mat(Color("c95c32"), 0.4, 0.15)
var rubber := mat(Color("20272b"), 0.95)
var alloy := mat(Color("adb8b7"), 0.32, 0.7)
var black := mat(Color("303c43"), 0.55, 0.25)
var trim := mat(Color("e9d6a5"), 0.75)
var tail := glow(Color("d8322a"), 1.6)
var parts: Dictionary = {} # материал → SurfaceTool текущего общего меша
var axle := Vector3(0, BikeView.WHEEL_Y, -BikeRide.HUB)
var rake := Basis(Vector3.RIGHT, BikeView.FORK_RAKE)
var steer_z := (axle + rake.inverse() * (BikeView.STEERING_PIVOT - axle)).z # ось рулевой до наклона вилки
var bb := Vector3(0, 0.3, 0)
var top_end := rk(Vector3(0, 1.0, steer_z))
var down_top := rk(Vector3(0, 0.965, steer_z))


## Точка переда, заданная до наклона вилки, — на своё место в велосипеде.
func rk(at: Vector3) -> Vector3:
	return axle + rake * (at - axle)


func mat(color: Color, roughness: float, metal := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	m.metallic = metal
	return m


func glow(color: Color, energy: float) -> StandardMaterial3D:
	var m := mat(color, 0.35)
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = energy
	return m


func node(parent: Node3D, label: String, at := Vector3.ZERO) -> Node3D:
	var n := Node3D.new()
	n.name = label
	n.position = at
	parent.add_child(n)
	n.owner = bike
	return n


func mesh(parent: Node3D, label: String, shape: Mesh, material: Material, at := Vector3.ZERO, basis := Basis.IDENTITY) -> MeshInstance3D:
	var n := MeshInstance3D.new()
	n.name = label
	n.mesh = shape
	if material != null:
		n.material_override = material
	n.transform = Transform3D(basis, at)
	parent.add_child(n)
	n.owner = bike
	return n


func box_shape(size: Vector3) -> BoxMesh:
	var shape := BoxMesh.new()
	shape.size = size
	return shape


func tube_shape(radius: float, length: float, sides := 10, top_radius := -1.0) -> CylinderMesh:
	var shape := CylinderMesh.new()
	shape.top_radius = radius if top_radius < 0.0 else top_radius
	shape.bottom_radius = radius
	shape.height = length
	shape.radial_segments = sides
	shape.rings = 0
	return shape


## Перо или цепь отдельным узлом: BikeView растягивает такой цилиндр до оси колеса.
func tube(parent: Node3D, label: String, a: Vector3, b: Vector3, radius: float, material: Material, sides := 10) -> MeshInstance3D:
	return mesh(parent, label, tube_shape(radius, a.distance_to(b), sides), material, (a + b) * 0.5, Basis(Quaternion(Vector3.UP, (b - a).normalized())))


func torus(inner: float, outer: float, rings := 32, segments := 8) -> TorusMesh:
	var shape := TorusMesh.new()
	shape.inner_radius = inner
	shape.outer_radius = outer
	shape.rings = rings
	shape.ring_segments = segments
	return shape


## Базис с местной Y вдоль dir (в том числе строго вниз); местная X остаётся ближе к X велосипеда.
func along(dir: Vector3) -> Basis:
	var y := dir.normalized()
	var ref := Vector3.RIGHT if absf(y.x) < 0.9 else Vector3.FORWARD
	var x := (ref - y * ref.dot(y)).normalized()
	return Basis(x, y, x.cross(y))


func add(shape: Mesh, material: Material, at: Transform3D) -> void:
	var tool: SurfaceTool = parts.get(material)
	if tool == null:
		tool = SurfaceTool.new()
		tool.begin(Mesh.PRIMITIVE_TRIANGLES)
		tool.set_material(material)
		parts[material] = tool
	tool.append_from(shape, 0, at)


## Труба от a к b: радиус ra у a и rb у b, flat — сплющивание сечения (поперёк, вдоль).
func add_tube(a: Vector3, b: Vector3, ra: float, material: Material, rb := -1.0, sides := 10, flat := Vector2.ONE) -> void:
	add(tube_shape(ra, a.distance_to(b), sides, rb), material, Transform3D(along(b - a) * Basis.from_scale(Vector3(flat.x, 1.0, flat.y)), (a + b) * 0.5))


func add_box(size: Vector3, at: Vector3, material: Material, basis := Basis.IDENTITY) -> void:
	add(box_shape(size), material, Transform3D(basis, at))


func add_ball(at: Vector3, radius: float, material: Material, scale := Vector3.ONE) -> void:
	var shape := SphereMesh.new()
	shape.radius = radius
	shape.height = radius * 2.0
	shape.radial_segments = 8
	shape.rings = 4
	add(shape, material, Transform3D(Basis.from_scale(scale), at))


## Изогнутая труба по точкам, стыки закрыты шариками.
func add_path(points: Array, radius: float, material: Material, sides := 8) -> void:
	for i in points.size() - 1:
		add_tube(points[i], points[i + 1], radius, material, -1.0, sides)
		if i > 0:
			add_ball(points[i], radius, material)


## Шайба или звезда вокруг оси X велосипеда.
func add_disc(at: Vector3, radius: float, width: float, material: Material, sides := 16) -> void:
	add(tube_shape(radius, width, sides), material, Transform3D(Basis(Vector3.FORWARD, PI * 0.5), at))


func commit(parent: Node3D, label: String, shadows := true) -> MeshInstance3D:
	var result := ArrayMesh.new()
	for material: Material in parts:
		(parts[material] as SurfaceTool).commit(result)
	parts = {}
	var n := mesh(parent, label, result, null)
	if not shadows:
		n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return n


## Одно колесо на оба узла: покрышка с тремя рядами шашек, обод, 24 скрещённые спицы, втулка с фланцами,
## ниппель и паук тормозного диска. Диск — отдельный узел: его материал (накал) ставит BikeView.
## rotor_x и hub_width: у переднего колеса втулка уже, а диск ближе к спицам — он проходит внутри ноги вилки.
func wheel_mesh(rotor_x := -0.066, hub_width := 0.13) -> ArrayMesh:
	var sideways := Transform3D(Basis(Vector3.FORWARD, PI * 0.5), Vector3.ZERO)
	add(torus(0.285, 0.345, 36, 10), rubber, sideways)
	for i in 28:
		var angle := TAU * i / 28.0
		var x := 0.007 if i % 2 == 0 else -0.007
		add_box(Vector3(0.015, 0.010, 0.021), Vector3(x, cos(angle) * 0.346, sin(angle) * 0.346), rubber, Basis(Vector3.RIGHT, angle))
		var half := angle + TAU / 56.0
		for side: float in [-1.0, 1.0]:
			add_box(Vector3(0.012, 0.009, 0.023), Vector3(side * 0.019, cos(half) * 0.3405, sin(half) * 0.3405), rubber,
				Basis(Vector3.RIGHT, half) * Basis(Vector3.BACK, -side * 0.55))
	add(torus(0.268, 0.29, 36, 6), black, sideways)
	# метки на ободе: видно, как колесо вращается
	for i in 3:
		var angle := TAU * i / 3.0
		for side: float in [-1.0, 1.0]:
			add_box(Vector3(0.002, 0.012, 0.06), Vector3(side * 0.0105, cos(angle) * 0.279, sin(angle) * 0.279), trim, Basis(Vector3.RIGHT, angle))
	for i in 24:
		var angle := TAU * i / 24.0
		var side := -1.0 if i % 2 else 1.0
		var cross := 1.15 if (i / 2) % 2 == 0 else -1.15
		var a := Vector3(side * 0.032, cos(angle + cross) * 0.024, sin(angle + cross) * 0.024)
		var b := Vector3(0, cos(angle) * 0.272, sin(angle) * 0.272)
		add_tube(a, b, 0.0019, alloy, -1.0, 3)
	add_disc(Vector3.ZERO, 0.019, hub_width, alloy, 10)
	for side: float in [-1.0, 1.0]:
		add_disc(Vector3(side * 0.032, 0, 0), 0.029, 0.005, alloy, 14)
	add_tube(Vector3(0, 0.262, 0), Vector3(0, 0.236, 0), 0.003, alloy, -1.0, 5)
	for i in 5:
		var angle := TAU * i / 5.0
		add_tube(Vector3(rotor_x, cos(angle) * 0.018, sin(angle) * 0.018), Vector3(rotor_x, cos(angle + 0.5) * 0.05, sin(angle + 0.5) * 0.05), 0.0045, alloy, -1.0, 4)
	var result := ArrayMesh.new()
	for material: Material in parts:
		(parts[material] as SurfaceTool).commit(result)
	parts = {}
	return result


## thin — толщина диска в долях прежней (передний диск тонкий: он стоит в щели суппорта).
func wheel(label: String, z: float, shape: ArrayMesh, rotor_x := -0.066, thin := 1.0) -> void:
	var w := node(bike, label, Vector3(0, 0.34, z))
	mesh(w, "Wheel", shape, null)
	mesh(w, "BrakeRotor", torus(0.047, 0.083), alloy, Vector3(rotor_x, 0, 0), Basis(Vector3.FORWARD, PI * 0.5) * Basis.from_scale(Vector3(1.0, thin, 1.0)))


## Седло: узкий нос, широкая задняя часть с подъёмом, выпуклый верх.
func saddle_mesh() -> ArrayMesh:
	var shape := SurfaceTool.new()
	shape.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cross: Array[Vector2] = [Vector2(-1, -0.012), Vector2(-0.78, 0.0), Vector2(-0.35, 0.005), Vector2(0.35, 0.005), Vector2(0.78, 0.0), Vector2(1, -0.012), Vector2(0.7, -0.032), Vector2(-0.7, -0.032)]
	var rings: Array[PackedVector3Array] = []
	# z вдоль седла, полуширина, высота верха
	for spec: Vector3 in [Vector3(-0.135, 0.016, 0.010), Vector3(-0.10, 0.026, 0.017), Vector3(-0.03, 0.044, 0.021), Vector3(0.04, 0.074, 0.023), Vector3(0.10, 0.082, 0.029), Vector3(0.135, 0.066, 0.036)]:
		var ring := PackedVector3Array()
		for c in cross:
			ring.append(Vector3(c.x * spec.y, c.y + spec.z, spec.x))
		rings.append(ring)
	var n := cross.size()
	for i in rings.size() - 1:
		for j in n:
			for at in [rings[i][j], rings[i + 1][j], rings[i][(j + 1) % n], rings[i][(j + 1) % n], rings[i + 1][j], rings[i + 1][(j + 1) % n]]:
				shape.add_vertex(at)
	var last := rings.size() - 1
	for end in [0, last]:
		for j in range(1, n - 1):
			for at in [rings[end][0], rings[end][j if end == 0 else j + 1], rings[end][j + 1 if end == 0 else j]]:
				shape.add_vertex(at)
	shape.generate_normals()
	return shape.commit()


## Рама одним мешем: трубы со стыками, каретка, рулевая, подседельный штырь с зажимом, седло с рамками,
## сумочка с задним фонарём, флягодержатель с флягой.
func frame() -> void:
	var seat_top := Vector3(0, 0.84, 0.17)
	# рулевая труба — на оси вилки
	var head_low := rk(Vector3(0, 0.905, steer_z))
	var head_top := rk(Vector3(0, 1.03, steer_z))
	var top_start := Vector3(0, 0.79, 0.155)
	add_tube(bb, seat_top, 0.026, paint, 0.024)
	add_tube(top_start, top_end, 0.022, paint, 0.027, 10, Vector2(0.9, 1.0))
	# Straight MTB down tube leaves room for the tyre at full suspension travel.
	add_tube(bb, down_top, 0.030, paint, 0.034, 10, Vector2(0.85, 1.0))
	add_tube(head_low, head_top, 0.034, paint, -1.0, 12)
	var head_dir := (head_top - head_low).normalized()
	# чашки рулевой колонки
	add_tube(head_low - head_dir * 0.012, head_low + head_dir * 0.004, 0.037, black, -1.0, 12)
	add_tube(head_top - head_dir * 0.004, head_top + head_dir * 0.008, 0.037, black, -1.0, 12)
	add_tube(head_top + head_dir * 0.008, head_top + head_dir * 0.014, 0.037, black, 0.027, 12)
	# косынка между верхней и нижней трубой у рулевой
	var gusset_top := top_end.lerp(top_start, 0.13)
	var gusset_low := down_top.lerp(bb, 0.10)
	add_box(Vector3(0.010, gusset_top.distance_to(gusset_low), 0.07), (gusset_top + gusset_low) * 0.5, paint, along(gusset_top - gusset_low))
	add_disc(bb, 0.037, 0.092, paint, 14)
	add_disc(bb, 0.029, 0.118, alloy, 12)
	# мостики задних перьев у неподвижных концов
	add_tube(Vector3(-0.05, 0.8, 0.17), Vector3(0.05, 0.8, 0.17), 0.012, paint, -1.0, 8)
	add_tube(Vector3(-0.05, 0.303, 0.045), Vector3(0.05, 0.303, 0.045), 0.011, paint, -1.0, 8)
	# контрастная вставка на нижней трубе видна сбоку, без букв и текстур
	add_tube(bb.lerp(down_top, 0.45), bb.lerp(down_top, 0.75), 0.0375, trim, -1.0, 10, Vector2(0.85, 1.0))
	# подседельный зажим, штырь, замок седла
	var seat_dir := (seat_top - bb).normalized()
	add_tube(seat_top - seat_dir * 0.016, seat_top + seat_dir * 0.006, 0.030, black, -1.0, 12)
	add_box(Vector3(0.012, 0.014, 0.022), seat_top + Vector3(0, -0.004, 0.034), alloy, along(seat_dir))
	add_tube(Vector3(0, 0.8, 0.16), Vector3(0, 0.905, 0.196), 0.016, black)
	add_box(Vector3(0.05, 0.022, 0.05), Vector3(0, 0.898, 0.197), alloy)
	add(saddle_mesh(), rubber, Transform3D(Basis.IDENTITY, Vector3(0, 0.915, 0.2)))
	add_box(Vector3(0.03, 0.004, 0.11), Vector3(0, 0.9435, 0.255), black)
	for side: float in [-1.0, 1.0]:
		add_path([Vector3(side * 0.02, 0.905, 0.085), Vector3(side * 0.032, 0.888, 0.13), Vector3(side * 0.032, 0.892, 0.27), Vector3(side * 0.03, 0.915, 0.315)], 0.0045, alloy, 5)
	# подседельная сумочка и задний фонарь: видны с игровой камеры
	add_box(Vector3(0.07, 0.05, 0.095), Vector3(0, 0.868, 0.262), black, Basis(Vector3.RIGHT, 0.2))
	add_box(Vector3(0.072, 0.008, 0.06), Vector3(0, 0.87, 0.258), trim, Basis(Vector3.RIGHT, 0.2))
	add_box(Vector3(0.034, 0.022, 0.012), Vector3(0, 0.862, 0.315), tail, Basis(Vector3.RIGHT, 0.2))
	# флягодержатель внутри переднего треугольника, на нижней трубе
	var down := (down_top - bb).normalized()
	var inside := Vector3(0, -down.z, down.y)
	var bottle := bb + down * 0.27 + inside * 0.072
	add_tube(bottle - down * 0.085, bottle + down * 0.06, 0.034, trim, -1.0, 12)
	add_tube(bottle + down * 0.06, bottle + down * 0.085, 0.034, trim, 0.022, 12)
	add_tube(bottle + down * 0.085, bottle + down * 0.112, 0.02, black, 0.016, 10)
	add_tube(bottle - down * 0.02, bottle + down * 0.0, 0.0348, paint, -1.0, 12)
	for side: float in [-1.0, 1.0]:
		add_path([bottle - down * 0.1 - inside * 0.035, bottle - down * 0.095 + Vector3(side * 0.03, 0, 0), bottle + down * 0.03 + Vector3(side * 0.036, 0, 0) + inside * 0.012, bottle + down * 0.05 - inside * 0.035], 0.004, alloy, 5)
	commit(bike, "Frame")


## Высота и вынос руля вдоль него: середина зажата в выносе, концы чуть отведены назад.
func bar_at(x: float) -> Vector3:
	return Vector3(x, BikeView.GRIP.y, BikeView.GRIP.z - 0.012 + maxf(absf(x) - 0.06, 0.0) * 0.0652)


## Вынос на штоке вилки, прямой руль, грипсы с замками, тормозные ручки с бачками, манетка, звонок,
## велокомпьютер, гидролинии и трос переключателя.
func cockpit() -> void:
	# хомут выноса на штоке, крышка и болт рулевой
	add_tube(rk(Vector3(0, 1.044, steer_z)), rk(Vector3(0, 1.084, steer_z)), 0.0235, black, -1.0, 12)
	add_tube(rk(Vector3(0, 1.084, steer_z)), rk(Vector3(0, 1.089, steer_z)), 0.0195, alloy, 0.017, 12)
	add_tube(rk(Vector3(0, 1.089, steer_z)), rk(Vector3(0, 1.092, steer_z)), 0.006, black, -1.0, 6)
	add_box(Vector3(0.024, 0.04, 0.014), rk(Vector3(0, 1.064, steer_z + 0.024)), black, rake)
	for y: float in [1.054, 1.074]:
		add_disc(rk(Vector3(0, y, steer_z + 0.027)), 0.0045, 0.034, alloy, 6)
	var neck := rk(Vector3(0, 1.064, steer_z))
	var clamp_at := bar_at(0.0)
	add_tube(neck, clamp_at, 0.019, black, 0.0175, 10, Vector2(1.0, 0.9))
	# зажим руля с лицевой крышкой на четырёх болтах
	add_disc(clamp_at, 0.0225, 0.05, black, 12)
	add_box(Vector3(0.05, 0.044, 0.012), clamp_at + Vector3(0, 0, -0.02), black)
	for x: float in [-0.017, 0.017]:
		for y: float in [-0.014, 0.014]:
			add_tube(clamp_at + Vector3(x, y, -0.025), clamp_at + Vector3(x, y, -0.029), 0.004, alloy, -1.0, 6)
	commit(bike, "Stem")
	add_path([bar_at(-0.29), bar_at(-0.06), bar_at(0.06), bar_at(0.29)], 0.0115, black, 10)
	add_tube(bar_at(-0.055), bar_at(0.055), 0.0155, black, -1.0, 10)
	# велокомпьютер на выносе
	var computer_at := neck.lerp(clamp_at, 0.6) + Vector3(0, 0.026, 0)
	add_box(Vector3(0.042, 0.012, 0.058), computer_at, black, Basis(Vector3.RIGHT, 0.2))
	add_box(Vector3(0.032, 0.002, 0.04), computer_at + Vector3(0, 0.007, -0.002), trim, Basis(Vector3.RIGHT, 0.2))
	for side: float in [-1.0, 1.0]:
		var grip_a := bar_at(side * 0.185)
		var grip_b := bar_at(side * 0.288)
		add_tube(grip_a, grip_b, 0.0175, rubber, -1.0, 10)
		for t: float in [0.2, 0.4, 0.6, 0.8]:
			var at := grip_a.lerp(grip_b, t)
			add_tube(at - Vector3(side * 0.004, 0, 0), at + Vector3(side * 0.004, 0, 0), 0.0205, rubber, -1.0, 10)
		add_tube(grip_a - Vector3(side * 0.008, 0, 0), grip_a, 0.0205, alloy, -1.0, 10)
		add_tube(grip_b, grip_b + Vector3(side * 0.006, 0, 0), 0.0195, trim, -1.0, 10)
		# тормозная ручка: хомут на руле, бачок вдоль руля впереди него
		var brake_at := bar_at(side * 0.158)
		add_tube(brake_at - Vector3(side * 0.007, 0, 0), brake_at + Vector3(side * 0.007, 0, 0), 0.0165, black, -1.0, 10)
		add_box(Vector3(0.018, 0.02, 0.03), brake_at + Vector3(0, -0.008, -0.022), black)
		var tank_out := brake_at + Vector3(side * 0.006, -0.012, -0.034)
		var tank_in := brake_at + Vector3(-side * 0.046, -0.014, -0.036)
		add_tube(tank_out, tank_in, 0.0085, black, 0.007, 8)
		# гидролиния: левая (передний тормоз) идёт дугой перед рулевой к левой ноге вилки и продолжается на штанах,
		# правая (задний тормоз) уходит на нижнюю трубу рамы у рулевой
		var hose_end := rk(Vector3(-LEG - 0.02, 0.72, axle.z + 0.012)) if side < 0.0 else down_top.lerp(bb, 0.08) + Vector3(0.033, 0.0, 0.0)
		var hose_mid := Vector3(-0.108, 0.86, hose_end.z - 0.05) if side < 0.0 else Vector3(0.062, 0.93, down_top.z - 0.085)
		var hose: Array = [tank_in, tank_in + Vector3(-side * 0.012, -0.02, -0.035), hose_mid]
		if side > 0.0:
			hose.append(Vector3(0.06, 0.915, down_top.z - 0.01)) # в обход рулевой трубы
		hose.append(hose_end)
		add_path(hose, 0.0035, rubber, 5)
	# манетка справа с тросом на верхнюю трубу, звонок слева
	var shifter_at := bar_at(0.128) + Vector3(0, -0.016, 0.014)
	add_box(Vector3(0.032, 0.02, 0.034), shifter_at, black)
	add_box(Vector3(0.03, 0.005, 0.016), shifter_at + Vector3(0.008, -0.008, 0.022), alloy, Basis(Vector3.UP, 0.4))
	add_path([shifter_at + Vector3(-0.016, 0, -0.01), shifter_at + Vector3(-0.03, -0.02, -0.07), Vector3(0.078, 0.985, top_end.z - 0.06), Vector3(0.06, 0.975, top_end.z), top_end.lerp(Vector3(0, 0.79, 0.155), 0.1) + Vector3(0.026, 0.008, 0)], 0.0028, rubber, 5)
	var bell_at := bar_at(-0.125)
	add_ball(bell_at + Vector3(0, 0.017, 0), 0.016, alloy, Vector3(1.0, 0.75, 1.0))
	add_tube(bell_at, bell_at + Vector3(0, 0.013, 0), 0.008, black, -1.0, 6)
	commit(bike, "Handlebar")
	for side: float in [-1.0, 1.0]:
		add_path([Vector3.ZERO, Vector3(side * 0.03, -0.004, -0.02), Vector3(side * 0.1, -0.012, -0.024)], 0.005, alloy, 6)
		add_ball(Vector3(side * 0.102, -0.012, -0.024), 0.0075, alloy)
		var lever := commit(bike, "Lever" + ("L" if side < 0.0 else "R"), false)
		lever.position = bar_at(side * 0.152) + Vector3(0, -0.01, -0.03)


## Вилка. Собирается стоя прямо (ось вилки вертикальна, ноги проходят через ось колеса), затем целиком
## наклоняется вокруг оси колеса на FORK_RAKE. Шток стоит на оси рулевой, корона выносит ноги вперёд.
## Контракт BikeView: ForkL/R с подвижным узлом Lower (штаны), ForkCrown (неподвижная часть), ForkArch (едет со штанами).
func fork() -> void:
	var z := axle.z
	var crown_y := BikeView.FORK_CROWN_Y
	for side: float in [-1.0, 1.0]:
		var s := "L" if side < 0 else "R"
		var x := side * LEG
		var leg := node(bike, "Fork" + s)
		tube(leg, "Stanchion", Vector3(x, 0.44, z), Vector3(x, crown_y, z), 0.0155, alloy, 12)
		var lower := node(leg, "Lower")
		add_tube(Vector3(x, 0.322, z), Vector3(x, 0.60, z), 0.0205, black, 0.0225, 12)
		add_tube(Vector3(x, 0.60, z), Vector3(x, 0.70, z), 0.0225, black, 0.0235, 12)
		add_tube(Vector3(x, 0.70, z), Vector3(x, 0.71, z), 0.0245, rubber, 0.0185, 12)
		# наклейка на внешней стороне штанов
		add_box(Vector3(0.003, 0.11, 0.022), Vector3(x + side * 0.0215, 0.53, z), trim)
		commit(lower, "Slider")
	# корона: бобышка штока, два плеча к ногам, зажимы ног с крышками (справа — ручка блокировки)
	add_tube(Vector3(0, crown_y - 0.022, steer_z), Vector3(0, crown_y + 0.018, steer_z), 0.032, black, 0.028, 12)
	add_tube(Vector3(0, crown_y + 0.018, steer_z), Vector3(0, crown_y + 0.023, steer_z), 0.027, alloy, -1.0, 12)
	add_tube(Vector3(0, crown_y, steer_z), Vector3(0, 1.04, steer_z), 0.017, black, -1.0, 8)
	for side: float in [-1.0, 1.0]:
		var x := side * LEG
		add_tube(Vector3(0, crown_y, steer_z), Vector3(x, crown_y - 0.002, z), 0.026, black, 0.022, 10, Vector2(1.0, 0.72))
		add_tube(Vector3(x, crown_y - 0.024, z), Vector3(x, crown_y + 0.02, z), 0.0235, black, -1.0, 12)
		add_tube(Vector3(x, crown_y + 0.02, z), Vector3(x, crown_y + 0.03, z), 0.017, trim if side > 0.0 else alloy, 0.014, 10)
	commit(bike, "ForkCrown")
	var arch := node(bike, "ForkArch")
	# арка между штанами проходит над покрышкой спереди
	add_path([Vector3(-LEG, 0.655, z - 0.016), Vector3(-LEG + 0.012, 0.714, z - 0.03), Vector3(LEG - 0.012, 0.714, z - 0.03), Vector3(LEG, 0.655, z - 0.016)], 0.0115, black, 8)
	for side: float in [-1.0, 1.0]:
		# проушины оси и гайки
		add_box(Vector3(0.026, 0.046, 0.04), Vector3(side * (LEG - 0.007), 0.338, z), black)
		add_disc(Vector3(side * (LEG + 0.012), 0.34, z), 0.012, 0.01, alloy, 6)
	add_disc(Vector3(0, 0.34, z), 0.007, LEG * 2.0 + 0.02, alloy, 8)
	add_tube(Vector3(LEG + 0.018, 0.34, z), Vector3(LEG + 0.02, 0.385, z + 0.03), 0.004, alloy, -1.0, 5)
	# передний суппорт: кронштейн сзади левой ноги, корпус охватывает диск, два болта
	var caliper_at := Vector3(-0.037, 0.392, z + 0.052)
	var caliper_turn := Basis(Vector3.RIGHT, -PI * 0.25)
	add_box(Vector3(0.018, 0.085, 0.034), Vector3(-LEG + 0.012, 0.39, z + 0.03), black)
	add_box(Vector3(0.03, 0.058, 0.03), caliper_at, black, caliper_turn)
	for along_at: float in [-0.02, 0.02]:
		add_disc(caliper_at + caliper_turn * Vector3(-0.017, along_at, 0), 0.006, 0.006, alloy, 6)
	# гидролиния по задней стороне левых штанов до хомута у арки; выше её продолжает линия от руля
	add_path([caliper_at + caliper_turn * Vector3(-0.006, 0.03, 0.008), Vector3(-LEG - 0.016, 0.50, z + 0.02), Vector3(-LEG - 0.02, 0.66, z + 0.016), Vector3(-LEG - 0.02, 0.72, z + 0.012)], 0.0035, rubber, 5)
	add_box(Vector3(0.012, 0.012, 0.016), Vector3(-LEG - 0.016, 0.66, z + 0.012), black)
	commit(arch, "Detail")
	# наклон всей вилки вокруг оси колеса; штаны ходят вдоль своих ног
	for label: String in ["ForkL", "ForkR", "ForkCrown", "ForkArch"]:
		var part := bike.get_node(label) as Node3D
		part.transform = Transform3D(rake, axle - rake * axle) * part.transform


## Задний узел едет вместе с колесом: кассета, переключатель с лапкой и двумя роликами, суппорт, проушины.
func rear_mechanics() -> void:
	var rear := node(bike, "RearMechanics")
	var axle := Vector3(0, 0.34, 0.53)
	for i in 7:
		add_disc(axle + Vector3(0.056 + i * 0.006, 0, 0), 0.092 - i * 0.0055, 0.003, alloy, 18)
	add_disc(axle + Vector3(0.075, 0, 0), 0.03, 0.046, black, 10)
	for side: float in [-1.0, 1.0]:
		add_box(Vector3(0.008, 0.05, 0.05), axle + Vector3(side * 0.052, 0.004, -0.006), paint)
		add_disc(axle + Vector3(side * 0.07, 0, 0), 0.012, 0.016, alloy, 10)
	add_box(Vector3(0.028, 0.05, 0.036), Vector3(-0.07, 0.39, 0.58), black, Basis(Vector3.RIGHT, -0.5))
	add_box(Vector3(0.012, 0.02, 0.03), Vector3(-0.062, 0.374, 0.558), alloy, Basis(Vector3.RIGHT, -0.5))
	# переключатель: лапка, параллелограмм, рамка с двумя роликами
	var upper := Vector3(0.09, 0.275, 0.548)
	var lower := Vector3(0.09, 0.21, 0.57)
	add_tube(axle + Vector3(0.094, 0, 0), Vector3(0.1, 0.30, 0.545), 0.009, black, -1.0, 6)
	add_box(Vector3(0.026, 0.034, 0.04), Vector3(0.104, 0.292, 0.548), black, Basis(Vector3.RIGHT, 0.3))
	for x: float in [0.082, 0.098]:
		add_tube(Vector3(x, upper.y, upper.z), Vector3(x, lower.y, lower.z), 0.006, alloy, -1.0, 4, Vector2(0.25, 1.6))
	add_disc(upper, 0.021, 0.008, rubber, 10)
	add_disc(lower, 0.025, 0.008, rubber, 10)
	# цепь по роликам до кассеты; длинные ветви — отдельные узлы ChainTop/ChainBottom
	add_path([Vector3(0.085, 0.186, 0.56), Vector3(0.085, 0.205, 0.595), Vector3(0.085, 0.262, 0.569), Vector3(0.085, 0.285, 0.527)], 0.0045, black, 4)
	commit(rear, "Detail")


## Шатуны: звезда с зубьями и пауком, плоские шатуны, педали-платформы с отражателями.
func drivetrain() -> void:
	tube(bike, "ChainTop", Vector3(0.085, 0.397, 0), Vector3(0.085, 0.409, 0.53), 0.0045, black, 4).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	tube(bike, "ChainBottom", Vector3(0.085, 0.202, 0), Vector3(0.085, 0.21, 0.57), 0.0045, black, 4).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var crank := node(bike, "Crank", Vector3(0, 0.3, 0))
	add(torus(0.08, 0.097, 24, 4), black, Transform3D(Basis(Vector3.FORWARD, PI * 0.5) * Basis.from_scale(Vector3(1.0, 0.35, 1.0)), Vector3(0.085, 0, 0)))
	for i in 16:
		var angle := TAU * i / 16.0
		add_box(Vector3(0.003, 0.009, 0.012), Vector3(0.085, cos(angle) * 0.099, sin(angle) * 0.099), black, Basis(Vector3.RIGHT, angle))
	for i in 4:
		var angle := TAU * i / 4.0 + 0.4
		add_tube(Vector3(0.085, 0, 0), Vector3(0.085, cos(angle) * 0.084, sin(angle) * 0.084), 0.009, alloy, 0.007, 4, Vector2(0.4, 1.0))
	for side: float in [-1.0, 1.0]:
		var pedal_at := Vector3(side * 0.14, -side * 0.17, 0)
		add_tube(Vector3(side * 0.098, 0, 0), Vector3(side * 0.115, -side * 0.17, 0), 0.019, alloy, 0.013, 8, Vector2(0.5, 1.0))
		add_disc(Vector3(side * 0.105, 0, 0), 0.02, 0.014, alloy, 10)
		add_disc(Vector3(side * 0.12, -side * 0.17, 0), 0.008, 0.03, alloy, 6)
	commit(crank, "Body")
	for side: float in [-1.0, 1.0]:
		# верх платформы — на уровне подошвы (центр узла), рамка с двумя окнами
		for z: float in [-0.036, 0.036]:
			add_box(Vector3(0.1, 0.016, 0.012), Vector3(0, -0.008, z), black)
			add_box(Vector3(0.06, 0.012, 0.004), Vector3(0, -0.008, z * 1.19), trim)
		for x: float in [-0.045, 0.0, 0.045]:
			add_box(Vector3(0.012 if x != 0.0 else 0.02, 0.014, 0.064), Vector3(x, -0.008, 0), black)
		var pedal := commit(crank, "Pedal" + ("L" if side < 0 else "R"))
		pedal.position = Vector3(side * 0.14, -side * 0.17, 0)


func _init() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	bike.name = "Bike"
	bike.set_meta("model_version", 3)
	wheel("RearWheel", 0.53, wheel_mesh())
	wheel("FrontWheel", -0.53, wheel_mesh(-0.037, 0.11), -0.037, 0.4)
	frame()
	for side in [-1.0, 1.0]:
		var s := "L" if side < 0 else "R"
		tube(bike, "ChainStay" + s, Vector3(side * 0.05, 0.3, 0), Vector3(side * 0.05, 0.34, 0.53), 0.013, paint)
		tube(bike, "SeatStay" + s, Vector3(side * 0.05, 0.8, 0.17), Vector3(side * 0.05, 0.34, 0.53), 0.011, paint)
	fork()
	cockpit()
	rear_mechanics()
	drivetrain()
	var rider := ResourceLoader.load("res://scenes/cyclist.tscn", "PackedScene", ResourceLoader.CACHE_MODE_IGNORE).instantiate() as Node3D
	rider.name = "Rider"
	bike.add_child(rider)
	rider.owner = bike
	var triangles := 0
	var draws := 0
	for item: Node in bike.find_children("*", "MeshInstance3D", true, false):
		if rider.is_ancestor_of(item):
			continue
		var m := (item as MeshInstance3D).mesh
		for surface in m.get_surface_count():
			draws += 1
			var arrays := m.surface_get_arrays(surface)
			var index: Variant = arrays[Mesh.ARRAY_INDEX]
			triangles += (index.size() if index != null and index.size() > 0 else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
	var scene := PackedScene.new()
	var error := scene.pack(bike)
	if error == OK:
		error = ResourceSaver.save(scene, "res://scenes/bike.tscn")
	print("Bike model v3: ", error_string(error), "; triangles=", triangles, " surfaces=", draws)
	bike.free()
	quit(error)
