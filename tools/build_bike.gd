extends SceneTree
## Источник scenes/bike.tscn. Размеры и имена контактов — контракт BikeView/IK/ragdoll.
## Модель v4 (17.11.2026): один общий материал (resources/bike_rider.gdshader) на весь велосипед и седока.
## Вершина хранит место в палитре и вид поверхности (UV), запечённое затенение (COLOR.r, tools/vertex_ao.gd)
## и метку покрышки (COLOR.b). Детали, которые движутся вместе, — один меш с одной отрисовкой:
##   Frame — рама, седло, флягодержатель; StayShadow — тень перьев (только тень, перья её не отбрасывают);
##   Handlebar — вынос, руль, грипсы, корона и ноги вилки (поворачиваются вместе, Stem — пустой узел для контракта);
##   ForkL/Lower/Slider — оба штана вилки с аркой, суппортом и осью (ForkR/Lower — пустой, ход тот же);
##   колесо (Wheel) и диск (BrakeRotor: накал — свой шейдер), шатуны, педали, задний узел, рычаги тормозов.
## Перья и цепь — CylinderMesh (их тянет BikeView): тот же шейдер с постоянным местом палитры.
## Модель v3 (12.11.2026): перёд собран вокруг одной оси рулевой (BikeView.STEERING_PIVOT, наклон FORK_RAKE);
## точки переда задаются «до наклона» (ось вилки вертикальна) и ставятся на место через rk().
const AO := preload("res://tools/vertex_ao.gd")
const P := preload("res://scripts/render/bike_palette.gd")
const LEG := 0.070 # полурасстояние между ногами вилки
var bike := BikeView.new()
var shared: ShaderMaterial
# Краски: место палитры и вид поверхности
var paint := Vector2i(P.FRAME, P.PAINT)
var accent := Vector2i(P.FRAME_ACCENT, P.PAINT)
var rubber := Vector2i(P.RUBBER, P.RUBBER_KIND)
var sidewall := Vector2i(P.SIDEWALL, P.RUBBER_KIND)
var alloy := Vector2i(P.ALLOY, P.ALLOY_KIND)
var black := Vector2i(P.BLACK, P.HARD)
var trim := Vector2i(P.FRAME_ACCENT, P.MATTE)
var tail := Vector2i(P.TAIL, P.GLOW)
var coating := Vector2i(P.COATING, P.COATING_KIND)
var leather := Vector2i(P.DARK, P.MATTE)
var tool: SurfaceTool
var tyre := false # вершины покрышки: шейдер сплющивает их у земли
var pre := Transform3D.IDENTITY # перенос для всего, что добавляется (наклон вилки)
var axle := Vector3(0, BikeView.WHEEL_Y, -BikeRide.HUB)
var rake := Basis(Vector3.RIGHT, BikeView.FORK_RAKE)
var rake_xf := Transform3D(rake, axle - rake * axle)
var steer_z := (axle + rake.inverse() * (BikeView.STEERING_PIVOT - axle)).z # ось рулевой до наклона вилки
var bb := Vector3(0, 0.3, 0)
var top_end := rk(Vector3(0, 1.0, steer_z))
var down_top := rk(Vector3(0, 0.965, steer_z))
var seat_top := Vector3(0, 0.84, 0.17)
var stay_tubes: Array = [] # перья в покое: [a, b, радиус] — для тени и затенения рамы


## Точка переда, заданная до наклона вилки, — на своё место в велосипеде.
func rk(at: Vector3) -> Vector3:
	return axle + rake * (at - axle)


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


func tube_shape(radius: float, length: float, sides := 10, top_radius := -1.0, caps := true) -> CylinderMesh:
	var shape := CylinderMesh.new()
	shape.top_radius = radius if top_radius < 0.0 else top_radius
	shape.bottom_radius = radius
	shape.height = length
	shape.radial_segments = sides
	shape.rings = 0
	shape.cap_top = caps
	shape.cap_bottom = caps
	return shape


## Перо или цепь отдельным узлом: BikeView растягивает такой цилиндр до оси колеса.
func strut(parent: Node3D, label: String, a: Vector3, b: Vector3, radius: float, material: Material, sides := 10) -> MeshInstance3D:
	var n := mesh(parent, label, tube_shape(radius, a.distance_to(b), sides), material, (a + b) * 0.5, Basis(Quaternion(Vector3.UP, (b - a).normalized())))
	n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return n


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


func _vertex(p: Vector3, n: Vector3, c: Vector2i) -> void:
	tool.set_uv(Vector2(c.x, c.y))
	tool.set_color(Color(1.0, 0.0, 1.0 if tyre else 0.0, 1.0))
	tool.set_normal(n)
	tool.add_vertex(p)


func _begin() -> void:
	if tool == null:
		tool = SurfaceTool.new()
		tool.begin(Mesh.PRIMITIVE_TRIANGLES)


## Примитив или меш целиком одной краской.
func add(shape: Mesh, c: Vector2i, at: Transform3D) -> void:
	_begin()
	at = pre * at
	var arrays: Array = (shape as PrimitiveMesh).get_mesh_arrays() if shape is PrimitiveMesh else shape.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var indices: Variant = arrays[Mesh.ARRAY_INDEX]
	var has_idx := indices != null and (indices as PackedInt32Array).size() > 0
	var idx_arr: PackedInt32Array = indices if has_idx else PackedInt32Array()
	var tri_count := (idx_arr.size() if has_idx else verts.size()) / 3
	var nxf := at.basis.inverse().transposed()
	for t in tri_count:
		var i0 := idx_arr[t * 3] if has_idx else t * 3
		var i1 := idx_arr[t * 3 + 1] if has_idx else t * 3 + 1
		var i2 := idx_arr[t * 3 + 2] if has_idx else t * 3 + 2
		if i0 == i1 or i1 == i2 or i2 == i0:
			continue
		var p0 := at * verts[i0]
		var p1 := at * verts[i1]
		var p2 := at * verts[i2]
		if (p1 - p0).cross(p2 - p0).length_squared() < 1e-15:
			continue
		_vertex(p0, (nxf * normals[i0]).normalized(), c)
		_vertex(p1, (nxf * normals[i1]).normalized(), c)
		_vertex(p2, (nxf * normals[i2]).normalized(), c)


## Четырёхугольник a-b-c-d с гладкими нормалями в углах. Лицевая сторона — та, куда смотрят нормали:
## обход выбирается сам. Совпадающие углы (веер у торца) дают один треугольник.
func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, na: Vector3, nb: Vector3, nc: Vector3, nd: Vector3, col: Vector2i) -> void:
	_begin()
	var nx := pre.basis.inverse().transposed()
	var pts := [pre * a, pre * b, pre * c, pre * d]
	var ns := [(nx * na).normalized(), (nx * nb).normalized(), (nx * nc).normalized(), (nx * nd).normalized()]
	var face: Vector3 = (pts[2] - pts[0]).cross(pts[3] - pts[0]) + (pts[1] - pts[0]).cross(pts[2] - pts[0])
	# Godot рисует лицевыми треугольники с обходом по часовой стрелке, если смотреть снаружи
	var order := [0, 2, 1, 0, 3, 2] if face.dot(ns[0] + ns[1] + ns[2] + ns[3]) > 0.0 else [0, 1, 2, 0, 2, 3]
	for t in 2:
		var i0: int = order[t * 3]
		var i1: int = order[t * 3 + 1]
		var i2: int = order[t * 3 + 2]
		if (pts[i1] - pts[i0]).cross(pts[i2] - pts[i0]).length_squared() < 1e-16:
			continue
		for k: int in [i0, i1, i2]:
			_vertex(pts[k], ns[k], col)


## Труба от a к b с переменным сечением: радиусы ra → rb, сплющивание сечения fa → fb (поперёк, вдоль
## плоскости рамы), rings промежуточных колец. Торцы не закрыты: стык уходит в соседнюю деталь.
## arc — часть окружности (углы от местной X): наклейка, лежащая на трубе, без зазора.
func add_tube2(a: Vector3, b: Vector3, ra: float, rb: float, c: Vector2i, fa := Vector2.ONE, fb := Vector2.ONE, sides := 12, rings := 1, caps := false, arc := Vector2(0.0, TAU)) -> void:
	var basis := along(b - a)
	var full := arc.y - arc.x >= TAU - 0.001
	var count := sides if full else sides + 1
	var ring_pts: Array[PackedVector3Array] = []
	var ring_ns: Array[PackedVector3Array] = []
	for r in rings + 1:
		var t := float(r) / rings
		var center := a.lerp(b, t)
		var radius := lerpf(ra, rb, t)
		var f := fa.lerp(fb, t)
		var pts := PackedVector3Array()
		var ns := PackedVector3Array()
		for j in count:
			var ang := lerpf(arc.x, arc.y, float(j) / sides)
			pts.append(center + basis * Vector3(cos(ang) * radius * f.x, 0.0, sin(ang) * radius * f.y))
			ns.append(basis * Vector3(cos(ang) / f.x, 0.0, sin(ang) / f.y))
		ring_pts.append(pts)
		ring_ns.append(ns)
	for r in rings:
		for j in sides:
			var k := (j + 1) % count
			quad(ring_pts[r][j], ring_pts[r + 1][j], ring_pts[r + 1][k], ring_pts[r][k], ring_ns[r][j], ring_ns[r + 1][j], ring_ns[r + 1][k], ring_ns[r][k], c)
	if caps and full:
		for end in [0, rings]:
			var center := a if end == 0 else b
			var n := -basis.y if end == 0 else basis.y
			for j in sides:
				var k := (j + 1) % sides
				var p := ring_pts[end]
				if end == 0:
					quad(center, center, p[k], p[j], n, n, n, n, c)
				else:
					quad(center, center, p[j], p[k], n, n, n, n, c)


## Труба от a к b: радиус ra у a и rb у b, flat — сплющивание сечения (поперёк, вдоль).
func add_tube(a: Vector3, b: Vector3, ra: float, c: Vector2i, rb := -1.0, sides := 10, flat := Vector2.ONE) -> void:
	add(tube_shape(ra, a.distance_to(b), sides, rb), c, Transform3D(along(b - a) * Basis.from_scale(Vector3(flat.x, 1.0, flat.y)), (a + b) * 0.5))


## Сварной шов: валик вокруг трубы dir с радиусом radius в точке at.
func weld(at: Vector3, dir: Vector3, radius: float, c := paint) -> void:
	add(torus(radius - 0.001, radius + 0.0045, 14, 3), c, Transform3D(along(dir), at))


func add_box(size: Vector3, at: Vector3, c: Vector2i, basis := Basis.IDENTITY) -> void:
	add(box_shape(size), c, Transform3D(basis, at))


func add_ball(at: Vector3, radius: float, c: Vector2i, scale := Vector3.ONE) -> void:
	var shape := SphereMesh.new()
	shape.radius = radius
	shape.height = radius * 2.0
	shape.radial_segments = 8
	shape.rings = 4
	add(shape, c, Transform3D(Basis.from_scale(scale), at))


## Изогнутая труба по точкам, стыки закрыты шариками.
func add_path(points: Array, radius: float, c: Vector2i, sides := 8) -> void:
	for i in points.size() - 1:
		add_tube(points[i], points[i + 1], radius, c, -1.0, sides)
		if i > 0:
			add_ball(points[i], radius, c)


## Шайба или звезда вокруг оси X велосипеда.
func add_disc(at: Vector3, radius: float, width: float, c: Vector2i, sides := 16) -> void:
	add(tube_shape(radius, width, sides), c, Transform3D(Basis(Vector3.FORWARD, PI * 0.5), at))


## Тело вращения вокруг оси X: профиль — точки (x вдоль оси, r — радиус), краска на каждый отрезок профиля.
func lathe(profile: Array, colors: Array, steps: int, at := Vector3.ZERO) -> void:
	var count := profile.size()
	var normals: Array[Vector2] = []
	for i in count:
		var prev: Vector2 = profile[maxi(i - 1, 0)]
		var next: Vector2 = profile[mini(i + 1, count - 1)]
		var d := (next - prev).normalized()
		normals.append(Vector2(-d.y, d.x)) # наружу при обходе профиля от оси −X к +X поверх
	for s in steps:
		var a0 := TAU * s / steps
		var a1 := TAU * (s + 1) / steps
		for i in count - 1:
			var p: Vector2 = profile[i]
			var q: Vector2 = profile[i + 1]
			var np: Vector2 = normals[i]
			var nq: Vector2 = normals[i + 1]
			quad(at + _lp(p, a0), at + _lp(p, a1), at + _lp(q, a1), at + _lp(q, a0), _ln(np, a0), _ln(np, a1), _ln(nq, a1), _ln(nq, a0), colors[mini(i, colors.size() - 1)])


func _lp(p: Vector2, ang: float) -> Vector3:
	return Vector3(p.x, cos(ang) * p.y, sin(ang) * p.y)


func _ln(n: Vector2, ang: float) -> Vector3:
	return Vector3(n.x, cos(ang) * n.y, sin(ang) * n.y)


## Меш из набранного; затенение запекается по своим треугольникам и extra (заслоняющие соседи).
func commit_mesh(extra := PackedVector3Array(), reach := 0.05) -> ArrayMesh:
	tool.index()
	var result := tool.commit()
	tool = null
	var occluders := AO.triangles(result)
	occluders.append_array(extra)
	return AO.apply(result, occluders, reach, 0.006)


func commit(parent: Node3D, label: String, shadows := true, extra := PackedVector3Array()) -> MeshInstance3D:
	var n := mesh(parent, label, commit_mesh(extra), shared)
	if not shadows:
		n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return n


## Колесо: покрышка — тело вращения с беговой частью, плечами и светлой боковиной, шашки в три ряда;
## обод с бортами и тормозной полосой, 24 скрещённые спицы, втулка с фланцами, ниппель и паук диска.
## rotor_x и hub_width: у переднего колеса втулка уже, а диск ближе к спицам — он проходит внутри ноги вилки.
func wheel_mesh(rotor_x := -0.066, hub_width := 0.13) -> ArrayMesh:
	tyre = true
	# профиль покрышки от левого борта по верху к правому (x поперёк, r — радиус)
	var tyre_profile := [Vector2(-0.016, 0.284), Vector2(-0.027, 0.296), Vector2(-0.031, 0.312), Vector2(-0.028, 0.329),
		Vector2(-0.019, 0.340), Vector2(-0.007, 0.345), Vector2(0.007, 0.345), Vector2(0.019, 0.340),
		Vector2(0.028, 0.329), Vector2(0.031, 0.312), Vector2(0.027, 0.296), Vector2(0.016, 0.284)]
	lathe(tyre_profile, [rubber, sidewall, sidewall, rubber, rubber, rubber, rubber, rubber, sidewall, sidewall, rubber], 32)
	# шашки: средний ряд и плечевые вразбежку — без нижней грани (она в покрышке)
	for i in 24:
		var angle := TAU * i / 24.0
		var x := 0.006 if i % 2 == 0 else -0.006
		knob(Vector3(0.014, 0.008, 0.02), Vector3(x, cos(angle) * 0.348, sin(angle) * 0.348), Basis(Vector3.RIGHT, angle))
		var half := angle + TAU / 48.0
		for side: float in [-1.0, 1.0]:
			knob(Vector3(0.011, 0.008, 0.021), Vector3(side * 0.022, cos(half) * 0.3405, sin(half) * 0.3405),
				Basis(Vector3.RIGHT, half) * Basis(Vector3.BACK, -side * 0.62))
	tyre = false
	# обод: борта и внутренняя часть к спицам (полка под покрышкой не видна)
	lathe([Vector2(0.016, 0.285), Vector2(0.015, 0.262), Vector2(0.0, 0.255), Vector2(-0.015, 0.262), Vector2(-0.016, 0.285)],
		[black, black, black, black], 32)
	# метки на ободе: видно, как колесо вращается
	for i in 3:
		var angle := TAU * i / 3.0
		for side: float in [-1.0, 1.0]:
			add_box(Vector3(0.002, 0.012, 0.06), Vector3(side * 0.0158, cos(angle) * 0.275, sin(angle) * 0.275), trim, Basis(Vector3.RIGHT, angle))
	for i in 24:
		var angle := TAU * i / 24.0
		var side := -1.0 if i % 2 else 1.0
		var cross := 1.15 if (i / 2) % 2 == 0 else -1.15
		var a := Vector3(side * 0.032, cos(angle + cross) * 0.024, sin(angle + cross) * 0.024)
		var b := Vector3(0, cos(angle) * 0.258, sin(angle) * 0.258)
		add(tube_shape(0.0019, a.distance_to(b), 3, -1.0, false), alloy, Transform3D(along(b - a), (a + b) * 0.5))
	add_disc(Vector3.ZERO, 0.019, hub_width, black, 10)
	for side: float in [-1.0, 1.0]:
		add_disc(Vector3(side * 0.032, 0, 0), 0.029, 0.005, alloy, 12)
		add_disc(Vector3(side * hub_width * 0.5, 0, 0), 0.012, 0.012, alloy, 8)
	add_tube(Vector3(0, 0.258, 0), Vector3(0, 0.236, 0), 0.003, alloy, -1.0, 5)
	for i in 5:
		var angle := TAU * i / 5.0
		add_tube(Vector3(rotor_x, cos(angle) * 0.018, sin(angle) * 0.018), Vector3(rotor_x, cos(angle + 0.5) * 0.05, sin(angle + 0.5) * 0.05), 0.0045, black, -1.0, 4)
	return commit_mesh(PackedVector3Array(), 0.04)


## Шашка покрышки: коробка без нижней грани, местная Y — наружу от оси колеса.
func knob(size: Vector3, at: Vector3, basis: Basis) -> void:
	var h := size * 0.5
	var c := func(x: float, y: float, z: float) -> Vector3:
		return at + basis * Vector3(x * h.x, y * h.y, z * h.z)
	var up := basis.y
	quad(c.call(-1, 1, -1), c.call(1, 1, -1), c.call(1, 1, 1), c.call(-1, 1, 1), up, up, up, up, rubber)
	for f: Array in [[Vector3.RIGHT, [1, -1, -1], [1, 1, -1], [1, 1, 1], [1, -1, 1]], [Vector3.LEFT, [-1, -1, -1], [-1, -1, 1], [-1, 1, 1], [-1, 1, -1]],
			[Vector3.BACK, [-1, -1, 1], [1, -1, 1], [1, 1, 1], [-1, 1, 1]], [Vector3.FORWARD, [-1, -1, -1], [-1, 1, -1], [1, 1, -1], [1, -1, -1]]]:
		var n: Vector3 = basis * (f[0] as Vector3)
		var p: Array[Vector3] = []
		for k in range(1, 5):
			p.append(c.call(f[k][0], f[k][1], f[k][2]))
		quad(p[0], p[1], p[2], p[3], n, n, n, n, rubber)


## Диск: плоское кольцо в плоскости XZ узла (как ждёт resources/brake_rotor.gdshader), 32 сектора.
func rotor_mesh(thickness: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var inner := 0.047
	var outer := 0.083
	var h := thickness * 0.5
	for s in 32:
		var a0 := TAU * s / 32.0
		var a1 := TAU * (s + 1) / 32.0
		var i0 := Vector3(cos(a0) * inner, 0, sin(a0) * inner)
		var i1 := Vector3(cos(a1) * inner, 0, sin(a1) * inner)
		var o0 := Vector3(cos(a0) * outer, 0, sin(a0) * outer)
		var o1 := Vector3(cos(a1) * outer, 0, sin(a1) * outer)
		for y: float in [h, -h]:
			var n := Vector3.UP * signf(y)
			var face := [i0, o0, o1, i0, o1, i1] if y > 0.0 else [i0, o1, o0, i0, i1, o1]
			for p: Vector3 in face:
				st.set_normal(n)
				st.add_vertex(p + Vector3(0, y, 0))
		var en := Vector3(cos((a0 + a1) * 0.5), 0, sin((a0 + a1) * 0.5))
		for p: Vector3 in [o0 + Vector3(0, h, 0), o0 - Vector3(0, h, 0), o1 - Vector3(0, h, 0), o0 + Vector3(0, h, 0), o1 - Vector3(0, h, 0), o1 + Vector3(0, h, 0)]:
			st.set_normal(en)
			st.add_vertex(p)
	st.index()
	return st.commit()


## thin — толщина диска в долях прежней (передний диск тонкий: он стоит в щели суппорта).
func wheel(label: String, z: float, shape: ArrayMesh, rotor_x := -0.066, thin := 1.0) -> void:
	var w := node(bike, label, Vector3(0, 0.34, z))
	mesh(w, "Wheel", shape, shared)
	var rotor := mesh(w, "BrakeRotor", rotor_mesh(0.0045 * thin), null, Vector3(rotor_x, 0, 0), Basis(Vector3.FORWARD, PI * 0.5))
	rotor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## Седло: узкий нос, широкая задняя часть с подъёмом, выпуклый верх; покрышка тёмная, борта и низ — пластик.
func saddle(at: Vector3) -> void:
	var cross: Array[Vector2] = [Vector2(-1, -0.012), Vector2(-0.78, 0.0), Vector2(-0.35, 0.005), Vector2(0.35, 0.005), Vector2(0.78, 0.0), Vector2(1, -0.012), Vector2(0.7, -0.032), Vector2(-0.7, -0.032)]
	var cross_paint: Array[Vector2i] = [leather, leather, leather, leather, leather, black, black, black]
	var rings: Array[PackedVector3Array] = []
	for spec: Vector3 in [Vector3(-0.135, 0.016, 0.010), Vector3(-0.10, 0.026, 0.017), Vector3(-0.03, 0.044, 0.021), Vector3(0.04, 0.074, 0.023), Vector3(0.10, 0.082, 0.029), Vector3(0.135, 0.066, 0.036)]:
		var ring := PackedVector3Array()
		for c in cross:
			# канавка по центру верха
			var groove := -0.004 if absf(c.x) < 0.4 and c.y > 0.0 and spec.x > -0.08 and spec.x < 0.08 else 0.0
			ring.append(at + Vector3(c.x * spec.y, c.y + spec.z + groove, spec.x))
		rings.append(ring)
	var cross_n: Array[Vector3] = [Vector3(-0.9, 0.45, 0), Vector3(-0.45, 0.9, 0), Vector3(-0.1, 1, 0), Vector3(0.1, 1, 0), Vector3(0.45, 0.9, 0), Vector3(0.9, 0.45, 0), Vector3(0.5, -0.85, 0), Vector3(-0.5, -0.85, 0)]
	var n := cross.size()
	for i in rings.size() - 1:
		for j in n:
			var k := (j + 1) % n
			# верх покрышки гладкий, а у кромки к бортам — своё сечение (j 4→5 и 0←7 — граница цвета)
			quad(rings[i][j], rings[i + 1][j], rings[i + 1][k], rings[i][k], cross_n[j], cross_n[j], cross_n[k], cross_n[k], cross_paint[j])
	# торцы
	for end in [0, rings.size() - 1]:
		var center := Vector3.ZERO
		for p in rings[end]:
			center += p
		center /= n
		var en := Vector3(0, 0, -1 if end == 0 else 1)
		for j in n:
			var k := (j + 1) % n
			if end == 0:
				quad(center, center, rings[end][j], rings[end][k], en, en, en, en, black)
			else:
				quad(center, center, rings[end][k], rings[end][j], en, en, en, en, black)


## Рама одним мешем: трубы переменного сечения со сварными швами, рулевая с расширением книзу, каретка,
## подседельный штырь с зажимом, седло с рамками, сумочка с задним фонарём, флягодержатель с флягой, знак на нижней трубе.
func frame() -> void:
	var head_low := rk(Vector3(0, 0.905, steer_z))
	var head_top := rk(Vector3(0, 1.03, steer_z))
	var top_start := Vector3(0, 0.79, 0.155)
	var head_dir := (head_top - head_low).normalized()
	# подседельная: круглая, у каретки шире
	add_tube2(bb, seat_top, 0.029, 0.024, paint, Vector2(1.0, 1.05), Vector2.ONE, 12, 2)
	# верхняя: сплющена по высоте, к рулевой шире
	add_tube2(top_start, top_end, 0.021, 0.026, paint, Vector2(1.0, 0.82), Vector2(0.92, 0.95), 12, 2)
	# нижняя: у рулевой овал по высоте, у каретки широкая и плоская
	add_tube2(bb, down_top, 0.034, 0.033, paint, Vector2(1.18, 0.82), Vector2(0.86, 1.08), 12, 3)
	# рулевая: конус, шире книзу
	add_tube2(head_low - head_dir * 0.002, head_top, 0.037, 0.032, paint, Vector2.ONE, Vector2.ONE, 14, 1)
	add_tube2(head_low - head_dir * 0.013, head_low - head_dir * 0.002, 0.039, 0.038, black, Vector2.ONE, Vector2.ONE, 14, 1)
	add_tube2(head_top, head_top + head_dir * 0.009, 0.034, 0.034, black, Vector2.ONE, Vector2.ONE, 14, 1)
	add_tube2(head_top + head_dir * 0.009, head_top + head_dir * 0.015, 0.034, 0.027, black, Vector2.ONE, Vector2.ONE, 14, 1)
	# сварные швы у рулевой, каретки и подседельной
	weld(top_end, top_end - top_start, 0.025)
	weld(down_top.lerp(bb, 0.012), down_top - bb, 0.032)
	weld(bb.lerp(down_top, 0.06), down_top - bb, 0.033)
	weld(bb.lerp(seat_top, 0.05), seat_top - bb, 0.028)
	weld(top_start.lerp(top_end, 0.02), top_end - top_start, 0.022)
	# косынка между верхней и нижней трубой у рулевой
	var gusset_top := top_end.lerp(top_start, 0.13)
	var gusset_low := down_top.lerp(bb, 0.10)
	add_box(Vector3(0.010, gusset_top.distance_to(gusset_low), 0.07), (gusset_top + gusset_low) * 0.5, paint, along(gusset_top - gusset_low))
	# каретка
	add_disc(bb, 0.038, 0.092, paint, 16)
	add_disc(bb, 0.029, 0.118, black, 12)
	# мостики задних перьев у неподвижных концов
	add_tube(Vector3(-0.05, 0.8, 0.17), Vector3(0.05, 0.8, 0.17), 0.012, paint, -1.0, 8)
	add_tube(Vector3(-0.05, 0.303, 0.045), Vector3(0.05, 0.303, 0.045), 0.011, paint, -1.0, 8)
	# знак на нижней трубе с обеих сторон: светлая полоса и две черты акцентом лежат на самой трубе
	var down := (down_top - bb).normalized()
	var inside := Vector3(0, -down.z, down.y)
	for side_arc: Vector2 in [Vector2(-0.62, 0.62), Vector2(PI - 0.62, PI + 0.62)]:
		_down_decal(0.47, 0.76, side_arc, trim)
		_down_decal(0.395, 0.425, side_arc, accent)
		_down_decal(0.435, 0.455, side_arc, accent)
	# подседельный зажим, штырь, замок седла
	var seat_dir := (seat_top - bb).normalized()
	add_tube2(seat_top - seat_dir * 0.016, seat_top + seat_dir * 0.006, 0.030, 0.030, black, Vector2.ONE, Vector2.ONE, 12, 1, true)
	add_box(Vector3(0.012, 0.014, 0.022), seat_top + Vector3(0, -0.004, 0.034), alloy, along(seat_dir))
	add_tube2(Vector3(0, 0.8, 0.16), Vector3(0, 0.905, 0.196), 0.016, 0.016, black, Vector2.ONE, Vector2.ONE, 10, 1)
	add_box(Vector3(0.05, 0.022, 0.05), Vector3(0, 0.898, 0.197), alloy)
	saddle(Vector3(0, 0.915, 0.2))
	add_box(Vector3(0.03, 0.004, 0.11), Vector3(0, 0.9435, 0.255), trim)
	for side: float in [-1.0, 1.0]:
		add_path([Vector3(side * 0.02, 0.905, 0.085), Vector3(side * 0.032, 0.888, 0.13), Vector3(side * 0.032, 0.892, 0.27), Vector3(side * 0.03, 0.915, 0.315)], 0.0045, alloy, 5)
	# подседельная сумочка и задний фонарь: видны с игровой камеры
	var bag := Basis(Vector3.RIGHT, 0.2)
	add_tube2(Vector3(0, 0.868, 0.215), Vector3(0, 0.868, 0.31), 0.03, 0.022, black, Vector2(1.15, 0.85), Vector2(1.1, 0.8), 10, 2, true)
	add_box(Vector3(0.072, 0.006, 0.05), Vector3(0, 0.893, 0.24), trim, bag)
	add_box(Vector3(0.034, 0.02, 0.012), Vector3(0, 0.866, 0.316), tail, bag)
	add_box(Vector3(0.04, 0.026, 0.006), Vector3(0, 0.866, 0.309), black, bag)
	# флягодержатель внутри переднего треугольника, на нижней трубе
	var bottle := bb + down * 0.27 + inside * 0.072
	add_tube2(bottle - down * 0.085, bottle + down * 0.06, 0.034, 0.034, trim, Vector2.ONE, Vector2.ONE, 14, 1, true)
	add_tube2(bottle - down * 0.03, bottle + down * 0.02, 0.0352, 0.0352, paint, Vector2.ONE, Vector2.ONE, 14, 1)
	add_tube2(bottle + down * 0.06, bottle + down * 0.085, 0.034, 0.022, trim, Vector2.ONE, Vector2.ONE, 14, 1)
	add_tube2(bottle + down * 0.085, bottle + down * 0.112, 0.02, 0.016, black, Vector2.ONE, Vector2.ONE, 10, 1, true)
	for side: float in [-1.0, 1.0]:
		add_path([bottle - down * 0.1 - inside * 0.035, bottle - down * 0.095 + Vector3(side * 0.03, 0, 0), bottle + down * 0.03 + Vector3(side * 0.036, 0, 0) + inside * 0.012, bottle + down * 0.05 - inside * 0.035], 0.004, alloy, 5)
	# перья в покое заслоняют низ рамы у каретки и подседельной
	var occl := PackedVector3Array()
	for s: Array in stay_tubes:
		occl.append_array(AO.triangles(tube_shape(s[2], (s[0] as Vector3).distance_to(s[1]), 8), Transform3D(along(s[1] - s[0]), (s[0] + s[1]) * 0.5)))
	commit(bike, "Frame", true, occl)


## Наклейка на нижней трубе от t0 до t1 её длины — то же сечение, чуть шире (как add_tube2 нижней трубы).
func _down_decal(t0: float, t1: float, arc: Vector2, c: Vector2i) -> void:
	var r0 := lerpf(0.034, 0.033, t0) * 1.012
	var r1 := lerpf(0.034, 0.033, t1) * 1.012
	var f0 := Vector2(1.18, 0.82).lerp(Vector2(0.86, 1.08), t0)
	var f1 := Vector2(1.18, 0.82).lerp(Vector2(0.86, 1.08), t1)
	add_tube2(bb.lerp(down_top, t0), bb.lerp(down_top, t1), r0, r1, c, f0, f1, 6, 1, false, arc)


## Тень перьев: они растягиваются BikeView, а тень в покое почти та же — один меш только для тени.
func stay_shadow() -> void:
	for s: Array in stay_tubes:
		add_tube(s[0], s[1], s[2], paint, -1.0, 6)
	var n := mesh(bike, "StayShadow", commit_mesh(), shared)
	n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY


## Высота и вынос руля вдоль него: середина зажата в выносе, концы чуть отведены назад.
func bar_at(x: float) -> Vector3:
	return Vector3(x, BikeView.GRIP.y, BikeView.GRIP.z - 0.012 + maxf(absf(x) - 0.06, 0.0) * 0.0652)


## Грипса одной поверхностью: рёбра поперёк, утолщение у замка, торцевая заглушка.
func grip(side: float) -> void:
	var a := bar_at(side * 0.185)
	var b := bar_at(side * 0.288)
	var axis := (b - a).normalized()
	var length := a.distance_to(b)
	var profile := [Vector2(0.0, 0.0176)]
	for i in 5:
		var x := 0.01 + i * 0.018
		profile.append(Vector2(x, 0.0174))
		profile.append(Vector2(x + 0.006, 0.0197))
	profile.append(Vector2(length - 0.006, 0.0176))
	profile.append(Vector2(length, 0.0185))
	profile.append(Vector2(length, 0.006))
	var colors := []
	for i in profile.size() - 1:
		colors.append(trim if i >= profile.size() - 3 else rubber)
	var keep := pre
	# тело вращения строится вдоль X: поворачиваем X к оси грипсы (для левой — в обратную сторону)
	var basis := Basis(Quaternion(Vector3.RIGHT, axis))
	pre = keep * Transform3D(basis, a)
	lathe(profile, colors, 8)
	pre = keep
	add_tube(a - axis * 0.009, a, 0.0205, alloy, -1.0, 10)


## Вынос на штоке вилки, прямой руль, грипсы с замками, тормозные ручки с бачками, манетка, звонок,
## велокомпьютер, гидролинии и трос переключателя; корона и ноги вилки — в том же меше (поворачиваются с рулём).
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
	add_tube2(neck, clamp_at, 0.019, 0.0175, black, Vector2(1.0, 0.9), Vector2(1.0, 0.9), 10, 1)
	# зажим руля с лицевой крышкой на четырёх болтах
	add_disc(clamp_at, 0.0225, 0.05, black, 12)
	add_box(Vector3(0.05, 0.044, 0.012), clamp_at + Vector3(0, 0, -0.02), black)
	for x: float in [-0.017, 0.017]:
		for y: float in [-0.014, 0.014]:
			add_tube(clamp_at + Vector3(x, y, -0.025), clamp_at + Vector3(x, y, -0.029), 0.004, alloy, -1.0, 6)
	# руль: толще в середине, к концам тоньше
	for side: float in [-1.0, 1.0]:
		add_tube2(bar_at(side * 0.055), bar_at(side * 0.12), 0.0155, 0.0118, black, Vector2.ONE, Vector2.ONE, 10, 1)
		add_tube2(bar_at(side * 0.12), bar_at(side * 0.29), 0.0118, 0.0112, black, Vector2.ONE, Vector2.ONE, 10, 1)
	add_tube(bar_at(-0.055), bar_at(0.055), 0.0155, black, -1.0, 10)
	# велокомпьютер на выносе
	var computer_at := neck.lerp(clamp_at, 0.6) + Vector3(0, 0.026, 0)
	add_box(Vector3(0.042, 0.012, 0.058), computer_at, black, Basis(Vector3.RIGHT, 0.2))
	add_box(Vector3(0.032, 0.002, 0.04), computer_at + Vector3(0, 0.007, -0.002), Vector2i(P.LENS, P.LENS_KIND), Basis(Vector3.RIGHT, 0.2))
	for side: float in [-1.0, 1.0]:
		grip(side)
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
	fork_crown()
	commit(bike, "Handlebar")
	node(bike, "Stem")
	for side: float in [-1.0, 1.0]:
		# рычаг: лезвие с изгибом под палец и шариком на конце
		add_path([Vector3.ZERO, Vector3(side * 0.03, -0.004, -0.02), Vector3(side * 0.075, -0.01, -0.026), Vector3(side * 0.1, -0.012, -0.022)], 0.005, alloy, 6)
		add_ball(Vector3(side * 0.102, -0.012, -0.022), 0.0075, alloy)
		var lever := commit(bike, "Lever" + ("L" if side < 0.0 else "R"), false)
		lever.position = bar_at(side * 0.152) + Vector3(0, -0.01, -0.03)


## Корона и ноги вилки (неподвижны относительно руля): строятся стоя, с наклоном вилки через pre.
func fork_crown() -> void:
	var z := axle.z
	var crown_y := BikeView.FORK_CROWN_Y
	pre = rake_xf
	for side: float in [-1.0, 1.0]:
		var x := side * LEG
		add_tube2(Vector3(x, 0.44, z), Vector3(x, crown_y, z), 0.0155, 0.0155, coating, Vector2.ONE, Vector2.ONE, 12, 1)
	# корона: бобышка штока, два плеча к ногам, зажимы ног с крышками (справа — ручка блокировки)
	add_tube(Vector3(0, crown_y - 0.022, steer_z), Vector3(0, crown_y + 0.018, steer_z), 0.032, black, 0.028, 12)
	add_tube(Vector3(0, crown_y + 0.018, steer_z), Vector3(0, crown_y + 0.023, steer_z), 0.027, alloy, -1.0, 12)
	add_tube(Vector3(0, crown_y, steer_z), Vector3(0, 1.04, steer_z), 0.017, black, -1.0, 8)
	for side: float in [-1.0, 1.0]:
		var x := side * LEG
		add_tube2(Vector3(0, crown_y, steer_z), Vector3(x, crown_y - 0.002, z), 0.026, 0.022, black, Vector2(1.0, 0.72), Vector2(1.0, 0.72), 10, 1)
		add_tube(Vector3(x, crown_y - 0.024, z), Vector3(x, crown_y + 0.02, z), 0.0235, black, -1.0, 12)
		add_tube(Vector3(x, crown_y + 0.02, z), Vector3(x, crown_y + 0.03, z), 0.017, trim if side > 0.0 else alloy, 0.014, 10)
	pre = Transform3D.IDENTITY


## Штаны вилки: оба с аркой, проушинами, осью и суппортом в одном меше ForkL/Lower; ForkR/Lower — пустой узел
## (BikeView двигает оба одинаково вдоль ног вилки). Узлы ForkL/R наклонены на FORK_RAKE вокруг оси колеса.
func fork_lowers() -> void:
	var z := axle.z
	for side: float in [-1.0, 1.0]:
		var x := side * LEG
		# литые штаны: сужение к проушине, пыльник сверху, наклейка снаружи
		add_tube2(Vector3(x, 0.322, z), Vector3(x, 0.60, z), 0.0195, 0.0225, black, Vector2(1.0, 1.08), Vector2(1.0, 1.0), 12, 1)
		add_tube2(Vector3(x, 0.60, z), Vector3(x, 0.695, z), 0.0225, 0.0235, black, Vector2.ONE, Vector2.ONE, 12, 1)
		add_tube2(Vector3(x, 0.695, z), Vector3(x, 0.712, z), 0.0245, 0.018, rubber, Vector2.ONE, Vector2.ONE, 12, 1, true)
		add_box(Vector3(0.003, 0.11, 0.022), Vector3(x + side * 0.0218, 0.53, z), trim)
		add_box(Vector3(0.0032, 0.03, 0.0225), Vector3(x + side * 0.0219, 0.455, z), accent)
		# проушины оси и гайки
		add_box(Vector3(0.026, 0.046, 0.04), Vector3(side * (LEG - 0.007), 0.338, z), black)
		add_disc(Vector3(side * (LEG + 0.012), 0.34, z), 0.012, 0.01, alloy, 6)
	# арка между штанами проходит над покрышкой спереди
	add_path([Vector3(-LEG, 0.655, z - 0.016), Vector3(-LEG + 0.012, 0.714, z - 0.03), Vector3(LEG - 0.012, 0.714, z - 0.03), Vector3(LEG, 0.655, z - 0.016)], 0.0115, black, 8)
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
	for side: float in [-1.0, 1.0]:
		var leg := node(bike, "Fork" + ("L" if side < 0 else "R"))
		leg.transform = rake_xf
		var lower := node(leg, "Lower")
		if side < 0.0:
			commit(lower, "Slider")


## Задний узел едет вместе с колесом: кассета, переключатель с лапкой и двумя роликами, суппорт, дропауты.
func rear_mechanics() -> void:
	var rear := node(bike, "RearMechanics")
	var hub := Vector3(0, 0.34, 0.53)
	# кассета ступенями одним телом вращения
	var profile := [Vector2(0.054, 0.02)]
	for i in 7:
		var x := 0.056 + i * 0.006
		var r := 0.092 - i * 0.0055
		profile.append(Vector2(x, r))
		profile.append(Vector2(x + 0.003, r))
	profile.append(Vector2(0.0975, 0.03))
	profile.append(Vector2(0.0975, 0.012))
	# торцы звёзд светлые, промежутки между ними тёмные: кассета читается ступенями, а не белым диском
	var colors := []
	for i in profile.size() - 1:
		colors.append(alloy if i % 2 == 1 or i == 0 else black)
	lathe(profile, colors, 18, hub)
	for side: float in [-1.0, 1.0]:
		# дропаут: пластина с выемкой под ось
		add_box(Vector3(0.008, 0.05, 0.05), hub + Vector3(side * 0.052, 0.004, -0.006), paint)
		add_box(Vector3(0.0085, 0.022, 0.03), hub + Vector3(side * 0.052, 0.03, -0.03), paint, Basis(Vector3.RIGHT, 0.6))
		add_disc(hub + Vector3(side * 0.07, 0, 0), 0.012, 0.016, alloy, 10)
	add_box(Vector3(0.028, 0.05, 0.036), Vector3(-0.07, 0.39, 0.58), black, Basis(Vector3.RIGHT, -0.5))
	add_box(Vector3(0.012, 0.02, 0.03), Vector3(-0.062, 0.374, 0.558), alloy, Basis(Vector3.RIGHT, -0.5))
	# переключатель: лапка, параллелограмм, рамка с двумя роликами
	var upper := Vector3(0.09, 0.275, 0.548)
	var lower := Vector3(0.09, 0.21, 0.57)
	add_tube(hub + Vector3(0.094, 0, 0), Vector3(0.1, 0.30, 0.545), 0.009, black, -1.0, 6)
	add_box(Vector3(0.026, 0.034, 0.04), Vector3(0.104, 0.292, 0.548), black, Basis(Vector3.RIGHT, 0.3))
	add_box(Vector3(0.004, 0.012, 0.026), Vector3(0.118, 0.292, 0.548), accent, Basis(Vector3.RIGHT, 0.3))
	for x: float in [0.082, 0.098]:
		add_tube(Vector3(x, upper.y, upper.z), Vector3(x, lower.y, lower.z), 0.006, alloy, -1.0, 4, Vector2(0.25, 1.6))
	add_disc(upper, 0.021, 0.008, rubber, 10)
	add_disc(lower, 0.025, 0.008, rubber, 10)
	# цепь по роликам до кассеты; длинные ветви — отдельные узлы ChainTop/ChainBottom
	add_path([Vector3(0.085, 0.186, 0.56), Vector3(0.085, 0.205, 0.595), Vector3(0.085, 0.262, 0.569), Vector3(0.085, 0.285, 0.527)], 0.0045, black, 4)
	commit(rear, "Detail", false)


## Шатуны: звезда с зубьями и пауком, шатуны с фаской, педали-платформы с шипами.
func drivetrain() -> void:
	var chain_mat := P.fixed_material(shared, P.BLACK, P.HARD)
	strut(bike, "ChainTop", Vector3(0.085, 0.397, 0), Vector3(0.085, 0.409, 0.53), 0.0045, chain_mat, 4)
	strut(bike, "ChainBottom", Vector3(0.085, 0.202, 0), Vector3(0.085, 0.21, 0.57), 0.0045, chain_mat, 4)
	var crank := node(bike, "Crank", BikeView.CRANK_REST)
	# звезда: плоское кольцо с зубьями по краю
	add(torus(0.08, 0.097, 24, 4), black, Transform3D(Basis(Vector3.FORWARD, PI * 0.5) * Basis.from_scale(Vector3(1.0, 0.35, 1.0)), Vector3(0.085, 0, 0)))
	for i in 16:
		var angle := TAU * i / 16.0
		add_box(Vector3(0.003, 0.009, 0.012), Vector3(0.085, cos(angle) * 0.099, sin(angle) * 0.099), black, Basis(Vector3.RIGHT, angle))
	for i in 4:
		var angle := TAU * i / 4.0 + 0.4
		add_tube(Vector3(0.085, 0, 0), Vector3(0.085, cos(angle) * 0.084, sin(angle) * 0.084), 0.009, black, 0.007, 4, Vector2(0.4, 1.0))
	for side: float in [-1.0, 1.0]:
		var spindle_y := BikeView.RIGHT_PEDAL_REST.y * side
		add_tube(Vector3(side * 0.098, 0, 0), Vector3(side * 0.115, spindle_y, 0), 0.019, black, 0.013, 8, Vector2(0.5, 1.0))
		add_tube(Vector3(side * 0.1065, -side * 0.03, 0), Vector3(side * 0.1125, -side * 0.14, 0), 0.008, alloy, 0.006, 6, Vector2(0.4, 1.0))
		add_disc(Vector3(side * 0.105, 0, 0), 0.02, 0.014, alloy, 10)
		add_disc(Vector3(side * 0.12, spindle_y, 0), 0.008, 0.03, alloy, 6)
	commit(crank, "Body")
	for side: float in [-1.0, 1.0]:
		# верх платформы — на уровне подошвы (центр узла), рамка с двумя окнами и шипами по краям
		for z: float in [-0.036, 0.036]:
			add_box(Vector3(0.1, 0.016, 0.012), Vector3(0, -0.008, z), black)
			add_box(Vector3(0.06, 0.012, 0.004), Vector3(0, -0.008, z * 1.19), accent)
			for x: float in [-0.035, 0.0, 0.035]:
				add_box(Vector3(0.004, 0.006, 0.004), Vector3(x, 0.002, z), alloy)
		for x: float in [-0.045, 0.0, 0.045]:
			add_box(Vector3(0.012 if x != 0.0 else 0.02, 0.014, 0.064), Vector3(x, -0.008, 0), black)
		var pedal := commit(crank, "Pedal" + ("L" if side < 0 else "R"), false)
		pedal.position = BikeView.RIGHT_PEDAL_REST * side


func _init() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	var started := Time.get_ticks_msec()
	shared = P.save_material()
	bike.name = "Bike"
	bike.set_meta("model_version", 4)
	wheel("RearWheel", 0.53, wheel_mesh())
	wheel("FrontWheel", -0.53, wheel_mesh(-0.037, 0.11), -0.037, 0.4)
	var stay_mat := P.fixed_material(shared, P.FRAME, P.PAINT)
	for side in [-1.0, 1.0]:
		var s := "L" if side < 0 else "R"
		var chain_a := Vector3(side * 0.05, 0.3, 0)
		var chain_b := Vector3(side * 0.05, 0.34, 0.53)
		var seat_a := Vector3(side * 0.05, 0.8, 0.17)
		strut(bike, "ChainStay" + s, chain_a, chain_b, 0.013, stay_mat)
		strut(bike, "SeatStay" + s, seat_a, chain_b, 0.011, stay_mat)
		stay_tubes.append([chain_a, chain_b, 0.013])
		stay_tubes.append([seat_a, chain_b, 0.011])
	frame()
	stay_shadow()
	cockpit()
	fork_lowers()
	rear_mechanics()
	drivetrain()
	var rider := ResourceLoader.load("res://scenes/cyclist.tscn", "PackedScene", ResourceLoader.CACHE_MODE_IGNORE).instantiate() as Node3D
	rider.name = "Rider"
	bike.add_child(rider)
	rider.owner = bike
	var triangles := 0
	var draws := 0
	for item: Node in bike.find_children("*", "MeshInstance3D", true, false):
		if rider.is_ancestor_of(item) or (item as MeshInstance3D).cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY:
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
	print("Bike model v4: ", error_string(error), "; triangles=", triangles, " surfaces=", draws, " build ", Time.get_ticks_msec() - started, " ms")
	bike.free()
	quit(error)
