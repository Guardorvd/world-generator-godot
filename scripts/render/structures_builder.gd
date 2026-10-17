class_name StructuresBuilder
extends RefCounted
## Мосты и туннели в 3D из простых ящиков: деревянный настил с перилами и опорами, каменная галерея
## со стенами, сводом и порталами. Размеры и высоты берутся из Heightfield.structures, по ним же
## считается движение, поэтому модель и опора для ног совпадают.

const TUNNEL_HEIGHT := Heightfield.TUNNEL_HEIGHT


static func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 1.0
	return m


## Ящик size с центром в offset внутри parent
static func _box(parent: Node3D, size: Vector3, offset: Vector3, mat: Material) -> void:
	var b := BoxMesh.new()
	b.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = b
	mi.material_override = mat
	mi.position = offset
	parent.add_child(mi)


## Добавляет все мосты и туннели в parent
static func build(parent: Node3D, heights: Heightfield) -> void:
	var wood := _mat(Color8(0x8a, 0x6a, 0x48))
	var rail := _mat(Color8(0x6b, 0x4f, 0x35))
	var stone := _mat(Color8(0x8c, 0x87, 0x80))
	var portal := _mat(Color8(0x6f, 0x6a, 0x63))
	for s: Dictionary in heights.structures:
		if s.tunnel:
			var a := Vector3(s.ax, s.ay, s.az)
			var b := Vector3(s.bx, s.by, s.bz)
			if a.distance_to(b) < 0.01:
				continue  # вырожденный туннель без оси: нечего строить
			# узел в начале оси, -Z смотрит вдоль неё (с уклоном), X — вбок
			var node := Node3D.new()
			node.position = a
			# почти вертикальная ось (крутой въезд) — сверяем с мировым Z, иначе Up даёт вырожденный базис
			var up := Vector3.UP if absf((b - a).normalized().y) < 0.99 else Vector3.BACK
			node.basis = Basis.looking_at(b - a, up)
			_tunnel(node, s.half, a.distance_to(b), -a.distance_to(b) * 0.5, stone, portal)
			parent.add_child(node)
		else:
			_bridge(parent, heights, s, wood, rail)


## Мост: настил дугой из прямых пролётов около 4 м, перила со столбиками, опоры до земли или дна
static func _bridge(parent: Node3D, heights: Heightfield, s: Dictionary, wood: Material, rail: Material) -> void:
	var half: float = s.half
	var n := maxi(1, ceili(s.len / 4.0))
	var side := Vector3(s.uz, 0, -s.ux) * (half + 0.1)
	for k in n:
		var t0: float = s.len * k / n
		var t1: float = s.len * (k + 1) / n
		var p0 := Vector3(s.ax + s.ux * t0, heights.level(s, t0), s.az + s.uz * t0)
		var p1 := Vector3(s.ax + s.ux * t1, heights.level(s, t1), s.az + s.uz * t1)
		var seg := p0.distance_to(p1)
		if seg < 0.01:
			continue  # вырожденный пролёт: направление не задано
		var node := Node3D.new()
		node.position = p0
		node.basis = Basis.looking_at(p1 - p0, Vector3.UP)
		# у крайних пролётов настил чуть длиннее, чтобы концы лежали на берегу
		var extra := (0.5 if k == 0 else 0.0) + (0.5 if k == n - 1 else 0.0)
		var shift := (0.25 if k == n - 1 else 0.0) - (0.25 if k == 0 else 0.0)
		_box(node, Vector3(half * 2.0, 0.3, seg + extra + 0.05), Vector3(0, -0.15, -seg * 0.5 - shift), wood)
		for sd in [-1.0, 1.0]:
			_box(node, Vector3(0.12, 0.12, seg), Vector3(sd * (half + 0.1), 1.0, -seg * 0.5), rail)
		parent.add_child(node)
		for q in [p0 + side, p0 - side]:
			_box(parent, Vector3(0.14, 1.0, 0.14), q + Vector3(0, 0.5, 0), rail)
		# опора под стыком пролётов примерно через 8 м
		if k > 0 and k % 2 == 0:
			for q in [p0 + side * 0.85, p0 - side * 0.85]:
				var g := heights.ground_at(q.x, q.z)
				var tall: float = q.y - 0.3 - g + 1.0
				if tall >= 1.0:
					_box(parent, Vector3(0.35, tall, 0.35), Vector3(q.x, g - 1.0 + tall * 0.5, q.z), wood)
	var end := Vector3(s.bx, s.by, s.bz)
	for q in [end + side, end - side]:
		_box(parent, Vector3(0.14, 1.0, 0.14), q + Vector3(0, 0.5, 0), rail)


static func _tunnel(node: Node3D, half: float, length: float, mid: float, stone: Material, portal: Material) -> void:
	var h := TUNNEL_HEIGHT
	for side in [-1.0, 1.0]:
		_box(node, Vector3(1.0, h + 1.0, length), Vector3(side * (half + 0.5), h * 0.5 - 0.5, mid), stone)
	_box(node, Vector3(half * 2.0 + 2.0, 0.8, length), Vector3(0, h + 0.4, mid), stone)
	# порталы на обоих концах: два столба и перемычка
	for z in [0.0, -length]:
		for side in [-1.0, 1.0]:
			_box(node, Vector3(1.4, h + 2.0, 1.0), Vector3(side * (half + 0.7), h * 0.5, z), portal)
		_box(node, Vector3(half * 2.0 + 2.8, 1.2, 1.0), Vector3(0, h + 0.8, z), portal)
