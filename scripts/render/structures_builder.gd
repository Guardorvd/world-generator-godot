class_name StructuresBuilder
extends RefCounted
## Мосты и туннели в 3D из простых ящиков: деревянный настил с перилами и опорами, каменная галерея
## со стенами, сводом и порталами. Размеры и высоты берутся из Heightfield.structures, по ним же
## считается движение, поэтому модель и опора для ног совпадают.

const TUNNEL_HEIGHT := Heightfield.TUNNEL_HEIGHT

static var _boxes := {} # Vector3 (размер) -> BoxMesh


static func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 1.0
	return m


## Ящик size с центром в offset в системе координат at
## Ящики одного размера (перила, столбики, доски) — один BoxMesh: на длинном мосту их тысячи
static func _box(batch: MeshBatch, at: Transform3D, size: Vector3, offset: Vector3, mat: Material) -> void:
	var b: BoxMesh = _boxes.get(size)
	if b == null:
		b = BoxMesh.new()
		b.size = size
		_boxes[size] = b
	batch.add(b, at * Transform3D(Basis(), offset), mat)


## Перило-столбик высотой 1 м, основанием в точке at
static func _post(batch: MeshBatch, at: Vector3, mat: Material) -> void:
	_box(batch, Transform3D(), Vector3(0.14, 1.0, 0.14), at + Vector3(0, 0.5, 0), mat)


## Добавляет все мосты и туннели в parent одним мешем (см. MeshBatch)
static func build(parent: Node3D, heights: Heightfield) -> void:
	var batch := MeshBatch.new()
	var wood := _mat(Color8(0x8a, 0x6a, 0x48))
	var board := _mat(Color8(0x80, 0x64, 0x47))
	var rail := _mat(Color8(0x6b, 0x4f, 0x35))
	var stone := _mat(Color8(0x8c, 0x87, 0x80))
	var portal := _mat(Color8(0x6f, 0x6a, 0x63))
	for s: Dictionary in heights.structures:
		if s.tunnel:
			var a := Vector3(s.ax, s.ay, s.az)
			var b := Vector3(s.bx, s.by, s.bz)
			if a.distance_to(b) < 0.01:
				continue  # вырожденный туннель без оси: нечего строить
			# система координат в начале оси, -Z смотрит вдоль неё (с уклоном), X — вбок.
			# Почти вертикальная ось (крутой въезд) — сверяем с мировым Z, иначе Up даёт вырожденный базис
			var up := Vector3.UP if absf((b - a).normalized().y) < 0.99 else Vector3.BACK
			_tunnel(batch, Transform3D(Basis.looking_at(b - a, up), a), s.half, a.distance_to(b), -a.distance_to(b) * 0.5, stone, portal)
		else:
			_bridge(batch, heights, s, wood, rail, board)
	# у каждого моста свои длины пролётов: кэш нужен только на время сборки, иначе он растёт от мира к миру
	_boxes.clear()
	var mi := batch.build("Structures")
	if mi != null:
		parent.add_child(mi)


## Мост: невысокий деревянный настил, перила и сваи; профиль общий с движением.
static func _bridge(batch: MeshBatch, heights: Heightfield, s: Dictionary, wood: Material, rail: Material, board: Material) -> void:
	var half: float = s.half
	var n := maxi(1, ceili(s.len / Heightfield.BRIDGE_SECTION))
	var side := Vector3(s.uz, 0, -s.ux) * (half + 0.1)
	for k in n:
		var t0: float = s.len * k / n
		var t1: float = s.len * (k + 1) / n
		var p0 := Vector3(s.ax + s.ux * t0, heights.level(s, t0), s.az + s.uz * t0)
		var p1 := Vector3(s.ax + s.ux * t1, heights.level(s, t1), s.az + s.uz * t1)
		var seg := p0.distance_to(p1)
		if seg < 0.01:
			continue  # вырожденный пролёт: направление не задано
		var at := Transform3D(Basis.looking_at(p1 - p0, Vector3.UP), p0)
		# Поперечные доски лежат в одной плоскости: швы видны цветом, без щелей и ступенек.
		var boards := maxi(1, ceili((t1 - t0) / 0.4))
		for plank in boards:
			_deck(batch, p0.lerp(p1, float(plank) / boards),
				p0.lerp(p1, float(plank + 1) / boards), half, wood if plank % 2 == 0 else board)
		for sd: float in [-1.0, 1.0]:
			_box(batch, at, Vector3(0.18, 0.28, seg), Vector3(sd * (half - 0.3), -0.36, -seg * 0.5), rail)
		for sd: float in [-1.0, 1.0]:
			_box(batch, at, Vector3(0.12, 0.12, seg), Vector3(sd * (half + 0.1), 1.0, -seg * 0.5), rail)
		for q: Vector3 in [p0 + side, p0 - side]:
			_post(batch, q, rail)
		# опора под стыком пролётов примерно через 8 м
		if k > 0 and k % 4 == 0:
			for q: Vector3 in [p0 + side * 0.85, p0 - side * 0.85]:
				var g := heights.ground_at(q.x, q.z)
				var tall: float = q.y - 0.3 - g + 1.0
				if tall >= 1.0:
					_box(batch, Transform3D(), Vector3(0.35, tall, 0.35), Vector3(q.x, g - 1.0 + tall * 0.5, q.z), wood)
	var end := Vector3(s.bx, s.by, s.bz)
	for q: Vector3 in [end + side, end - side]:
		_post(batch, q, rail)


## Верх точно совпадает с level(), толщина откладывается вертикально.
static func _deck(batch: MeshBatch, a: Vector3, b: Vector3, half: float, mat: Material) -> void:
	var forward := (b - a).normalized()
	var side := Vector3(-forward.z, 0, forward.x).normalized()
	var length := Vector2(b.x - a.x, b.z - a.z).length()
	var basis := Basis(side, Vector3.UP, -(b - a) / length)
	_box(batch, Transform3D(basis, (a + b) * 0.5), Vector3(half * 2.0, 0.24, length), Vector3(0, -0.12, 0), mat)


static func _tunnel(batch: MeshBatch, at: Transform3D, half: float, length: float, mid: float, stone: Material, portal: Material) -> void:
	var h := TUNNEL_HEIGHT
	for side: float in [-1.0, 1.0]:
		_box(batch, at, Vector3(1.0, h + 1.0, length), Vector3(side * (half + 0.5), h * 0.5 - 0.5, mid), stone)
	_box(batch, at, Vector3(half * 2.0 + 2.0, 0.8, length), Vector3(0, h + 0.4, mid), stone)
	# порталы на обоих концах: два столба и перемычка
	for z: float in [0.0, -length]:
		for side: float in [-1.0, 1.0]:
			_box(batch, at, Vector3(1.4, h + 2.0, 1.0), Vector3(side * (half + 0.7), h * 0.5, z), portal)
		_box(batch, at, Vector3(half * 2.0 + 2.8, 1.2, 1.0), Vector3(0, h + 0.8, z), portal)
