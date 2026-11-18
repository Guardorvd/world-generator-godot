class_name RepairModels
extends RefCounted
## Модели того, что можно починить (Repairables): смотровая лавка, тур на вершине, причал с лодкой у рыбацкого домика.
## У каждой — целый и сломанный вид на общем атласе поселений, три уровня детализации (как у TowerModels).
## Лавку и тур собирает SettlementModels._build_site_mesh в общий каталог (ключи bench, bench_broken, peak_cairn_broken);
## причал зависит от рельефа (длина и высота воды у домика), поэтому его меши строятся при загрузке мира
## (FishingLayout.measure) и в каталог не попадают.
## Размеры лавки: сиденье 1,8 × 0,5 м на высоте 0,46 м, спинка до 0,9 м; фронт — +z.

const TIMBER := SettlementModels.CELL_TIMBER
const DARK := SettlementModels.CELL_DARK_WOOD
const STONE := SettlementModels.CELL_STONE
const HULL := SettlementModels.CELL_SHUTTER
const FLAG := SettlementModels.CELL_FLOWER_A
const SEAT_Y := 0.46


static func _box(st: SurfaceTool, size: Vector3, center: Vector3, basis: Basis, cell: int) -> void:
	SettlementModels._box(st, size, center, basis, cell)


## Лавка у смотровой точки. broken: средняя доска сиденья выпала, передняя повисла, ножка упала рядом, верхняя доска спинки сломана
static func bench(st: SurfaceTool, level: int, broken: bool) -> void:
	if level == 2:
		_box(st, Vector3(1.8, 0.07, 0.5), Vector3(0, SEAT_Y, 0), Basis(Vector3.BACK, 0.10 if broken else 0.0), TIMBER)
		_box(st, Vector3(1.8, 0.34, 0.05), Vector3(0, 0.72, -0.22), Basis(Vector3.RIGHT, -0.28 if broken else 0.0), DARK)
		return
	for sx: float in [-0.75, 0.75]:
		_box(st, Vector3(0.08, SEAT_Y, 0.08), Vector3(sx, SEAT_Y * 0.5, 0.2), Basis.IDENTITY, DARK)
		if broken and sx > 0.0:
			# задняя ножка упала: лежит рядом, спинка с этой стороны провисла
			_box(st, Vector3(0.08, 0.9, 0.08), Vector3(1.1, 0.06, -0.15), Basis.from_euler(Vector3(0.0, 0.5, PI * 0.5)), DARK)
		else:
			_box(st, Vector3(0.08, 0.9, 0.08), Vector3(sx, 0.45, -0.2), Basis.IDENTITY, DARK)
	if level == 1:
		if broken:
			_box(st, Vector3(0.88, 0.05, 0.5), Vector3(-0.44, SEAT_Y, 0), Basis.IDENTITY, TIMBER)
			_box(st, Vector3(0.88, 0.05, 0.5), Vector3(0.50, SEAT_Y - 0.14, 0), Basis(Vector3.BACK, -0.30), TIMBER)
			_box(st, Vector3(1.8, 0.14, 0.04), Vector3(0, 0.60, -0.22), Basis(Vector3.RIGHT, -0.1), DARK)
		else:
			_box(st, Vector3(1.8, 0.05, 0.5), Vector3(0, SEAT_Y, 0), Basis.IDENTITY, TIMBER)
			_box(st, Vector3(1.8, 0.3, 0.04), Vector3(0, 0.72, -0.22), Basis.IDENTITY, DARK)
		return
	# LOD0: три доски сиденья, две перекладины спинки, брус под сиденьем
	_box(st, Vector3(1.8, 0.06, 0.06), Vector3(0, SEAT_Y - 0.09, 0.0), Basis.IDENTITY, DARK)
	_box(st, Vector3(1.8, 0.04, 0.12), Vector3(0, 0.60, -0.22), Basis.IDENTITY, TIMBER)
	for k in 3:
		var z := -0.16 + 0.16 * k
		if broken and k == 1:
			continue # средняя доска выпала
		if broken and k == 2:
			_box(st, Vector3(1.8, 0.05, 0.14), Vector3(0.0, SEAT_Y - 0.10, z + 0.06), Basis(Vector3.RIGHT, 0.55), TIMBER)
			continue
		_box(st, Vector3(1.8, 0.05, 0.14), Vector3(0, SEAT_Y, z), Basis.IDENTITY, TIMBER)
	if broken:
		_box(st, Vector3(0.8, 0.12, 0.04), Vector3(-0.45, 0.80, -0.22), Basis(Vector3.BACK, 0.08), TIMBER)
		_box(st, Vector3(0.7, 0.12, 0.04), Vector3(0.95, 0.12, 0.25), Basis.from_euler(Vector3(0.0, 0.7, 0.1)), TIMBER) # обломок на земле
	else:
		_box(st, Vector3(1.8, 0.12, 0.04), Vector3(0, 0.80, -0.22), Basis.IDENTITY, TIMBER)


## Сломанный тур на вершине: верхний ярус рассыпался по земле, веха сломана, флаг лежит рядом
static func cairn_broken(st: SurfaceTool, level: int) -> void:
	var seg := 5 if level <= 1 else 4
	for rh: Vector2 in [Vector2(0.90, 0.50), Vector2(0.65, 1.30)]:
		SettlementModels._cyl(st, rh.x * 0.85, rh.x, rh.x * 1.15, seg, Vector3(0, rh.y, 0), Basis.IDENTITY, STONE)
	for stone: Array in [[Vector3(1.25, 0.22, 0.45), 0.34], [Vector3(0.95, 0.18, -0.95), 0.27], [Vector3(-1.1, 0.2, 0.7), 0.30]]:
		var at: Vector3 = stone[0]
		var r: float = stone[1]
		SettlementModels._cyl(st, r * 0.8, r, r * 1.3, seg, at, Basis.from_euler(Vector3(0.4, at.x, 0.5)), STONE)
	if level <= 1:
		_box(st, Vector3(0.10, 0.75, 0.10), Vector3(0.05, 2.0, 0.0), Basis(Vector3.BACK, 0.08), DARK)       # обломок вехи
		_box(st, Vector3(0.10, 1.5, 0.10), Vector3(-0.7, 0.18, -1.05), Basis.from_euler(Vector3(0.0, 0.6, PI * 0.5)), DARK)
		_box(st, Vector3(0.7, 0.05, 0.4), Vector3(-0.2, 0.07, -1.25), Basis(Vector3.UP, 0.4), FLAG)


## Причал и лодка рыбацкого домика. m — FishingLayout.measure (len, dy — верх настила, water — вода), местные координаты
## домика: настил от z = START вдоль +z. broken: три доски выпали, одна висит, угловая свая завалилась, лодка та же.
static func pier(st: SurfaceTool, level: int, m: Dictionary, broken: bool) -> void:
	var z0 := FishingLayout.START
	var length: float = m.len
	var dy: float = m.dy
	var half := FishingLayout.HALF
	if level == 2:
		if broken:
			var gap := length * 0.5
			_box(st, Vector3(2.0 * half, 0.1, gap - 0.5), Vector3(0, dy - 0.05, z0 + (gap - 0.5) * 0.5), Basis.IDENTITY, TIMBER)
			_box(st, Vector3(2.0 * half, 0.1, length - gap - 0.5), Vector3(0, dy - 0.05, z0 + gap + 0.5 + (length - gap - 0.5) * 0.5), Basis.IDENTITY, TIMBER)
		else:
			_box(st, Vector3(2.0 * half, 0.1, length), Vector3(0, dy - 0.05, z0 + length * 0.5), Basis.IDENTITY, TIMBER)
		_boat(st, m, level)
		return
	var count := maxi(1, floori(length / 0.34))
	var pitch := length / count
	if level == 1:
		if broken:
			var gap := length * 0.5
			_box(st, Vector3(2.0 * half, 0.08, gap - 0.5), Vector3(0, dy - 0.04, z0 + (gap - 0.5) * 0.5), Basis.IDENTITY, TIMBER)
			_box(st, Vector3(2.0 * half, 0.08, length - gap - 0.5), Vector3(0, dy - 0.04, z0 + gap + 0.5 + (length - gap - 0.5) * 0.5), Basis.IDENTITY, TIMBER)
		else:
			_box(st, Vector3(2.0 * half, 0.08, length), Vector3(0, dy - 0.04, z0 + length * 0.5), Basis.IDENTITY, TIMBER)
	else:
		var hole := count / 2
		for k in count:
			var z := z0 + (k + 0.5) * pitch
			if broken and k >= hole and k < hole + 3:
				if k == hole + 2:
					_box(st, Vector3(2.0 * half, 0.07, pitch - 0.04), Vector3(0, dy - 0.2, z + 0.1), Basis(Vector3.RIGHT, 0.5), TIMBER) # повисла на одном краю
				continue
			_box(st, Vector3(2.0 * half, 0.07, pitch - 0.04), Vector3(0, dy - 0.035, z), Basis.IDENTITY, TIMBER)
	for sx: float in [-0.62, 0.62]:
		_box(st, Vector3(0.14, 0.16, length), Vector3(sx, dy - 0.15, z0 + length * 0.5), Basis.IDENTITY, DARK)
	# сваи парами через 2,5 м; у конца — высокие, к ним привязана лодка
	var posts := maxi(2, ceili(length / 2.5) + 1)
	for k in posts:
		var z := z0 + length * float(k) / (posts - 1)
		var tall := k == posts - 1
		for sx: float in [-half + 0.06, half - 0.06]:
			var top := dy + (0.75 if tall else 0.2)
			var bottom: float = minf(dy, m.water) - 1.8
			var fallen := broken and k == posts / 2 and sx > 0.0
			if fallen:
				_box(st, Vector3(0.18, top - bottom, 0.18), Vector3(sx + 0.2, (top + bottom) * 0.5, z), Basis(Vector3.BACK, 0.5), DARK) # свая завалилась
			else:
				_box(st, Vector3(0.18, top - bottom, 0.18), Vector3(sx, (top + bottom) * 0.5, z), Basis.IDENTITY, DARK)
			if level == 1 and not tall:
				break # на средней детализации — по одной свае на пару
	_boat(st, m, level)


static func pier_lods(m: Dictionary, broken: bool) -> Array[ArrayMesh]:
	var out: Array[ArrayMesh] = []
	for level in 3:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		pier(st, level, m, broken)
		st.index()
		out.append(st.commit())
	return out


## Лодка у правого борта причала, у конца настила
static func _boat(st: SurfaceTool, m: Dictionary, level: int) -> void:
	var water: float = m.water
	var x := FishingLayout.BOAT_SIDE
	var z: float = FishingLayout.START + m.len - FishingLayout.BOAT_BACK
	var y := water + 0.04
	_box(st, Vector3(0.95, 0.08, 2.8), Vector3(x, y + 0.04, z), Basis.IDENTITY, HULL)
	if level == 2:
		_box(st, Vector3(1.1, 0.3, 2.7), Vector3(x, y + 0.22, z), Basis.IDENTITY, HULL)
		return
	for side: float in [-1.0, 1.0]:
		_box(st, Vector3(0.06, 0.38, 2.9), Vector3(x + side * 0.5, y + 0.22, z), Basis(Vector3.FORWARD, side * 0.18), HULL)
	for end: float in [-1.0, 1.0]:
		_box(st, Vector3(1.0, 0.36, 0.06), Vector3(x, y + 0.22, z + end * 1.4), Basis(Vector3.RIGHT, end * -0.25), HULL)
	if level == 0:
		_box(st, Vector3(0.95, 0.05, 0.26), Vector3(x, y + 0.34, z + 0.2), Basis.IDENTITY, TIMBER)
		_box(st, Vector3(0.05, 0.05, 1.7), Vector3(x + 0.15, y + 0.5, z - 0.3), Basis.from_euler(Vector3(0.15, 0.2, 0.0)), DARK)
		_box(st, Vector3(0.03, 0.03, 1.0), Vector3(x - 0.7, y + 0.55, z + 1.5), Basis(Vector3.UP, 0.6), DARK) # швартов к свае
