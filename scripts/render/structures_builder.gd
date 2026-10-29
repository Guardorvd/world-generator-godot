class_name StructuresBuilder
extends RefCounted
## Мосты и туннели в 3D из простых ящиков: деревянный настил с перилами и опорами, каменная галерея
## со стенами, сводом и порталами. С 10.4 короткие переправы дорог — каменные мостики с парапетом,
## тропы — несколько досок на поперечинах (Heightfield._style). Размеры и высоты берутся из Heightfield.structures, по ним же
## считается движение, поэтому модель и опора для ног совпадают.

const TUNNEL_HEIGHT := Heightfield.TUNNEL_HEIGHT

static var _build_lock := Mutex.new()
static var _boxes := {} # Vector3 (размер) -> BoxMesh


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


## Добавляет все мосты и туннели в parent общими мешами по квадратам мира (см. MeshBatch)
## only — свой список сооружений (13.9: мосты закреплённой области), иначе все heights.structures
static func build(parent: Node3D, heights: Heightfield, only: Variant = null) -> void:
	_build_lock.lock()
	var batch := MeshBatch.new()
	var wood := SettlementsBuilder.mat(Color8(0x8a, 0x6a, 0x48))
	var board := SettlementsBuilder.mat(Color8(0x80, 0x64, 0x47))
	var rail := SettlementsBuilder.mat(Color8(0x6b, 0x4f, 0x35))
	var stone := SettlementsBuilder.mat(Color8(0x8c, 0x87, 0x80))
	var portal := SettlementsBuilder.mat(Color8(0x6f, 0x6a, 0x63))
	var slab := SettlementsBuilder.mat(Color8(0x9d, 0x97, 0x8c))
	var slab_dark := SettlementsBuilder.mat(Color8(0x86, 0x80, 0x76))
	var plank_light := SettlementsBuilder.mat(Color8(0x9a, 0x7a, 0x55))
	for s: Dictionary in (heights.structures if only == null else only):
		if s.get("deck", false):
			continue # настил трассы: его рисует TrailLabProps вместе с остальными объектами трассы
		if s.tunnel:
			var a := Vector3(s.ax, s.ay, s.az)
			var b := Vector3(s.bx, s.by, s.bz)
			if a.distance_to(b) < 0.01:
				continue  # вырожденный туннель без оси: нечего строить
			# система координат в начале оси, -Z смотрит вдоль неё (с уклоном), X — вбок.
			# Почти вертикальная ось (крутой въезд) — сверяем с мировым Z, иначе Up даёт вырожденный базис
			var up := Vector3.UP if absf((b - a).normalized().y) < 0.99 else Vector3.BACK
			tunnel(batch, Transform3D(Basis.looking_at(b - a, up), a), s.half, a.distance_to(b), -a.distance_to(b) * 0.5, stone, portal)
		elif s.style == "stone":
			stone_bridge(batch, heights, s, slab, slab_dark, portal)
		elif s.style == "planks":
			planks(batch, heights, s, plank_light, board, rail)
		else:
			bridge(batch, heights, s, wood, rail, board)
	# у каждого моста свои длины пролётов: кэш нужен только на время сборки, иначе он растёт от мира к миру
	_boxes.clear()
	var mi := batch.build("Structures")
	if mi != null:
		parent.add_child(mi)
	_build_lock.unlock()


## Мост: невысокий деревянный настил, перила и сваи; профиль общий с движением.
static func bridge(batch: MeshBatch, heights: Heightfield, s: Dictionary, wood: Material, rail: Material, board: Material) -> void:
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


## Каменный мостик: плиты настила, низкий парапет и устои до дна у обоих берегов и под серединой.
static func stone_bridge(batch: MeshBatch, heights: Heightfield, s: Dictionary, slab: Material, dark: Material, block: Material) -> void:
	var half: float = s.half
	var n := maxi(1, ceili(s.len / Heightfield.BRIDGE_SECTION))
	for k in n:
		var t0: float = s.len * k / n
		var t1: float = s.len * (k + 1) / n
		var p0 := Vector3(s.ax + s.ux * t0, heights.level(s, t0), s.az + s.uz * t0)
		var p1 := Vector3(s.ax + s.ux * t1, heights.level(s, t1), s.az + s.uz * t1)
		var seg := p0.distance_to(p1)
		if seg < 0.01:
			continue
		var at := Transform3D(Basis.looking_at(p1 - p0, Vector3.UP), p0)
		var plates := maxi(1, ceili((t1 - t0) / 0.7))
		for plate in plates:
			_deck(batch, p0.lerp(p1, float(plate) / plates), p0.lerp(p1, float(plate + 1) / plates), half,
				slab if (plate + k) % 3 != 0 else dark)
		# парапет из камня: невысокий, но по нему видно край
		for sd: float in [-1.0, 1.0]:
			_box(batch, at, Vector3(0.45, 0.55, seg + 0.02), Vector3(sd * (half + 0.12), 0.12, -seg * 0.5), block)
		# свод под настилом: толстая кладка, вниз до воды у концов и под серединой
		_box(batch, at, Vector3(half * 2.0 + 0.6, 0.5, seg), Vector3(0, -0.45, -seg * 0.5), dark)
	for t: float in [0.0, s.len * 0.5, s.len]:
		if t == s.len * 0.5 and s.len < 14.0:
			continue
		var q := Vector3(s.ax + s.ux * t, heights.level(s, t), s.az + s.uz * t)
		var g := minf(heights.ground_at(q.x, q.z), q.y - 0.7)
		var tall := q.y - 0.6 - (g - 1.0)
		var face := Transform3D(Basis.looking_at(Vector3(s.ux, 0, s.uz), Vector3.UP), Vector3(q.x, g - 1.0 + tall * 0.5, q.z))
		_box(batch, face, Vector3(half * 2.0 + 0.9, tall, 1.6 if t == s.len * 0.5 else 2.2), Vector3.ZERO, block)


## Переправа тропы: три доски вдоль с щелями на поперечинах, без перил, у концов колышки.
static func planks(batch: MeshBatch, heights: Heightfield, s: Dictionary, light: Material, board: Material, dark: Material) -> void:
	var half: float = s.half
	var n := maxi(1, ceili(s.len / Heightfield.BRIDGE_SECTION))
	var width := half * 2.0 / 3.0
	for k in n:
		var t0: float = s.len * k / n
		var t1: float = s.len * (k + 1) / n
		var p0 := Vector3(s.ax + s.ux * t0, heights.level(s, t0), s.az + s.uz * t0)
		var p1 := Vector3(s.ax + s.ux * t1, heights.level(s, t1), s.az + s.uz * t1)
		var seg := p0.distance_to(p1)
		if seg < 0.01:
			continue
		var at := Transform3D(Basis.looking_at(p1 - p0, Vector3.UP), p0)
		for j in 3:
			var x := -half + width * (j + 0.5)
			# у досок чуть разные цвет и толщина: настил собран из того, что было под рукой
			var mat := light if (j + k) % 2 == 0 else board
			_box(batch, at, Vector3(width - 0.07, 0.09 if (j + k) % 3 else 0.11, seg + 0.03), Vector3(x, -0.05, -seg * 0.5), mat)
		# поперечина и свая в стыке пролётов
		_box(batch, at, Vector3(half * 2.0 + 0.3, 0.14, 0.2), Vector3(0, -0.17, 0), dark)
		if k > 0 and k % 2 == 0:
			for sd: float in [-1.0, 1.0]:
				var q := p0 + Vector3(s.uz, 0, -s.ux) * sd * (half + 0.05)
				var g := heights.ground_at(q.x, q.z)
				var tall: float = q.y - 0.2 - g + 0.8
				if tall >= 0.8:
					_box(batch, Transform3D(), Vector3(0.16, tall, 0.16), Vector3(q.x, g - 0.8 + tall * 0.5, q.z), dark)
	for e: Vector3 in [Vector3(s.ax, s.ay, s.az), Vector3(s.bx, s.by, s.bz)]:
		for sd: float in [-1.0, 1.0]:
			var q := e + Vector3(s.uz, 0, -s.ux) * sd * (half + 0.15)
			_box(batch, Transform3D(), Vector3(0.12, 0.6, 0.12), q + Vector3(0, 0.15, 0), dark)


## Верх точно совпадает с level(), толщина откладывается вертикально.
static func _deck(batch: MeshBatch, a: Vector3, b: Vector3, half: float, mat: Material) -> void:
	var forward := (b - a).normalized()
	var side := Vector3(-forward.z, 0, forward.x).normalized()
	var length := Vector2(b.x - a.x, b.z - a.z).length()
	var basis := Basis(side, Vector3.UP, -(b - a) / length)
	_box(batch, Transform3D(basis, (a + b) * 0.5), Vector3(half * 2.0, 0.24, length), Vector3(0, -0.12, 0), mat)


static func tunnel(batch: MeshBatch, at: Transform3D, half: float, length: float, mid: float, stone: Material, portal: Material) -> void:
	var h := TUNNEL_HEIGHT
	for side: float in [-1.0, 1.0]:
		_box(batch, at, Vector3(1.0, h + 1.0, length), Vector3(side * (half + 0.5), h * 0.5 - 0.5, mid), stone)
	_box(batch, at, Vector3(half * 2.0 + 2.0, 0.8, length), Vector3(0, h + 0.4, mid), stone)
	# порталы на обоих концах: два столба и перемычка
	for z: float in [0.0, -length]:
		for side: float in [-1.0, 1.0]:
			_box(batch, at, Vector3(1.4, h + 2.0, 1.0), Vector3(side * (half + 0.7), h * 0.5, z), portal)
		_box(batch, at, Vector3(half * 2.0 + 2.8, 1.2, 1.0), Vector3(0, h + 0.8, z), portal)
