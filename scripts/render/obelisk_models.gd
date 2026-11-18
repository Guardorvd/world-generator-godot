class_name ObeliskModels
extends RefCounted
## Формы памятников места "obelisk" (ObeliskLore.form_of): целый обелиск, разрушенный, старая статуя, обломки колонны на плите,
## памятная стела. Все на общем атласе поселений, три уровня детализации, в каталог как ключи KEYS (SettlementModels.build_site_lods).
## У всех квадратная подошва в пределах SITE_SIZES.obelisk (полуширина 0,75 м) — поворот на 90° не меняет ящик столкновения, поэтому
## модель можно развернуть табличкой к тропе (SettlementsBuilder) без расхождения с физикой.
## У каждой формы — тёмная табличка лицом в +z: plaque(form) даёт её центр на лицевой стороне и размер (м) — по ним
## читается текст, рисуется зона съёмки в видоискателе и считается снимок.
## 18.11.2026: таблички подняты в середину памятника (на уровень глаз), у цоколя — четыре фонаря подсветки (стекло светится
## ночью), сама подсветка снизу — glow_node: один дешёвый меш на обелиск без источников света.

const KEYS := ["obelisk", "obelisk_ruined", "obelisk_statue", "obelisk_fragments", "obelisk_stele"]
const STONE := SettlementModels.CELL_STONE
const DARK := SettlementModels.CELL_DARK_WOOD
const ROOF := SettlementModels.CELL_ROOF
const LIGHT := SettlementModels.CELL_WINDOW  # стекло фонаря подсветки: ночью светится (эмиссия общего материала)
const METAL := SettlementModels.CELL_METAL
const FRONT := 0.8   # лицевая грань цоколя от оси, м

## Табличка формы: центр лицевой стороны (местные координаты, +z наружу) и размер.
## 18.11.2026: таблички подняты с цоколя (0,15–0,28 м — на склоне уходили в землю, их не находили) в середину памятника,
## на уровень глаз: столб, обломок столба, высокий постамент статуи, барабан колонны, середина стелы
const PLAQUES := [
	{pos = Vector3(0, 1.75, 0.37), size = Vector2(0.56, 0.36)},
	{pos = Vector3(0, 1.45, 0.37), size = Vector2(0.56, 0.34)},
	{pos = Vector3(0, 1.15, 0.51), size = Vector2(0.60, 0.32)},
	{pos = Vector3(0, 0.95, 0.47), size = Vector2(0.48, 0.26)},
	{pos = Vector3(0, 1.45, 0.18), size = Vector2(0.60, 0.30)},
]
## Подсветка снизу (glow_node): освещаемые части формы [полуширина по x, по z, низ, верх] и полуширина цоколя (фонари за ним)
const LIT := [
	{parts = [[0.80, 0.80, 0.0, 0.62], [0.36, 0.36, 0.62, 5.2]], base = 0.80},
	{parts = [[0.80, 0.80, 0.0, 0.62], [0.36, 0.36, 0.62, 2.15]], base = 0.80},
	{parts = [[0.75, 0.75, 0.0, 0.5], [0.50, 0.50, 0.5, 1.8]], base = 0.75}, # фигуру не освещаем плоскостью — у неё выступы
	{parts = [[0.85, 0.85, 0.0, 0.35], [0.45, 0.45, 0.35, 1.75]], base = 0.85},
	{parts = [[0.75, 0.75, 0.0, 0.4], [0.65, 0.17, 0.4, 2.25]], base = 0.75},
]
const LAMP_GAP := 0.38   # фонарь за цоколем, м
const GLOW_SEEN := 260.0 # м: дальше подсветка не рисуется
const GLOW_TOP := 4.2    # м: выше свет фонаря уже не достаёт
## Цвета фонарей по сторонам (+z, +x, -z, -x); у каждого обелиска палитра сдвинута — подсветка разная
const GLOW_COLORS := [Color(1.0, 0.8, 0.52), Color(1.0, 0.56, 0.22), Color(0.38, 0.74, 1.0), Color(0.72, 0.52, 1.0)]
static var _glow_material: ShaderMaterial


static func plaque(form: int) -> Dictionary:
	return PLAQUES[form]


static func _box(st: SurfaceTool, size: Vector3, center: Vector3, basis: Basis, cell: int) -> void:
	SettlementModels._box(st, size, center, basis, cell)


static func _plate(st: SurfaceTool, form: int, level: int) -> void:
	if level == 2:
		return
	var p: Dictionary = PLAQUES[form]
	var at: Vector3 = p.pos
	_box(st, Vector3(p.size.x, p.size.y, 0.06), at - Vector3(0, 0, 0.03), Basis.IDENTITY, DARK)
	if level == 0: # рамка
		_box(st, Vector3(p.size.x + 0.08, 0.05, 0.08), at + Vector3(0, p.size.y * 0.5 + 0.02, -0.04), Basis.IDENTITY, STONE)
		_box(st, Vector3(p.size.x + 0.08, 0.05, 0.08), at - Vector3(0, p.size.y * 0.5 + 0.02, 0.04), Basis.IDENTITY, STONE)


static func build(st: SurfaceTool, form: int, level: int) -> void:
	match form:
		0: _intact(st, level)
		1: _ruined(st, level)
		2: _statue(st, level)
		3: _fragments(st, level)
		_: _stele(st, level)
	_plate(st, form, level)
	_lamps(st, form, level)


static func _intact(st: SurfaceTool, level: int) -> void:
	if level == 2:
		_box(st, Vector3(1.40, 1.00, 1.40), Vector3(0, 0.10, 0), Basis.IDENTITY, STONE)
		_box(st, Vector3(0.75, 4.70, 0.75), Vector3(0, 2.95, 0), Basis.IDENTITY, STONE)
		SettlementModels._cyl(st, 0.0, 0.54, 0.72, 4, Vector3(0, 5.65, 0), Basis(Vector3.UP, PI / 4.0), STONE)
		return
	_box(st, Vector3(1.60, 1.15, 1.60), Vector3(0, 0.05, 0), Basis.IDENTITY, STONE)
	_box(st, Vector3(0.72, 4.60, 0.72), Vector3(0, 2.90, 0), Basis.IDENTITY, STONE)
	SettlementModels._cyl(st, 0.0, 0.52, 0.75, 4, Vector3(0, 5.56, 0), Basis(Vector3.UP, PI / 4.0), STONE)
	if level == 0:
		_box(st, Vector3(1.15, 0.35, 1.15), Vector3(0, 0.72, 0), Basis.IDENTITY, STONE)


## Столб сломан на высоте около двух метров, верхняя часть с навершием лежит рядом
static func _ruined(st: SurfaceTool, level: int) -> void:
	_box(st, Vector3(1.60, 1.15, 1.60), Vector3(0, 0.05, 0), Basis.IDENTITY, STONE)
	_box(st, Vector3(0.72, 1.55, 0.72), Vector3(0, 1.40, 0), Basis.IDENTITY, STONE)
	_box(st, Vector3(0.50, 0.40, 0.50), Vector3(0.08, 2.35, 0.04), Basis(Vector3.UP, 0.25), STONE) # зубец слома
	if level == 2:
		_box(st, Vector3(0.72, 2.0, 0.72), Vector3(1.55, 0.36, 0.50), Basis.from_euler(Vector3(0.0, 0.6, PI * 0.5)), STONE)
		return
	_box(st, Vector3(0.72, 2.1, 0.72), Vector3(1.55, 0.36, 0.50), Basis.from_euler(Vector3(0.0, 0.6, PI * 0.5)), STONE)
	SettlementModels._cyl(st, 0.0, 0.52, 0.75, 4, Vector3(2.45, 0.40, 0.90), Basis.from_euler(Vector3(0.0, 0.6 + PI * 0.25, PI * 0.5)), STONE)
	if level == 0:
		for k: Vector3 in [Vector3(0.95, 0.12, 1.15), Vector3(-1.05, 0.10, 0.9), Vector3(1.9, 0.10, -0.3)]:
			_box(st, Vector3(0.34, 0.24, 0.30), k, Basis(Vector3.UP, k.x), STONE)


## Статуя странника на высоком постаменте: блочная фигура в плаще, одна рука поднята.
## 18.11.2026: постамент выше (на нём табличка на уровне глаз), фигура поднята на RISE
static func _statue(st: SurfaceTool, level: int) -> void:
	const RISE := 1.2
	_box(st, Vector3(1.50, 1.00, 1.50), Vector3(0, 0.0, 0), Basis.IDENTITY, STONE)
	_box(st, Vector3(1.00, 1.30, 1.00), Vector3(0, 1.15, 0), Basis.IDENTITY, STONE) # тело постамента
	if level == 2:
		_box(st, Vector3(0.8, 2.2, 0.5), Vector3(0, 1.6 + RISE, 0), Basis.IDENTITY, STONE)
		_box(st, Vector3(0.38, 0.42, 0.38), Vector3(0, 2.95 + RISE, 0), Basis.IDENTITY, STONE)
		return
	_box(st, Vector3(1.10, 0.20, 1.10), Vector3(0, 0.60 + RISE, 0), Basis.IDENTITY, STONE) # верхний венец постамента
	if level == 1:
		_box(st, Vector3(0.62, 0.95, 0.38), Vector3(0, 1.30 + RISE, 0), Basis.IDENTITY, STONE)
	else:
		for sx: float in [-0.17, 0.17]:
			_box(st, Vector3(0.26, 0.95, 0.30), Vector3(sx, 1.30 + RISE, 0.02), Basis.IDENTITY, STONE)
	_box(st, Vector3(0.74, 1.10, 0.44), Vector3(0, 2.28 + RISE, 0), Basis.IDENTITY, STONE)         # туловище в плаще
	_box(st, Vector3(0.84, 0.20, 0.50), Vector3(0, 2.90 + RISE, 0), Basis.IDENTITY, STONE)         # плечи
	_box(st, Vector3(0.38, 0.42, 0.38), Vector3(0, 3.22 + RISE, 0.02), Basis.IDENTITY, STONE)      # голова
	if level == 0:
		_box(st, Vector3(1.10, 0.12, 1.10), Vector3(0, 0.56, 0), Basis.IDENTITY, STONE)                                   # нижний венец
		_box(st, Vector3(0.22, 0.85, 0.22), Vector3(-0.52, 2.15 + RISE, 0.05), Basis.IDENTITY, STONE)                     # опущенная рука
		_box(st, Vector3(0.22, 0.80, 0.22), Vector3(0.58, 3.00 + RISE, 0.30), Basis(Vector3.BACK, -0.45), STONE)         # поднятая рука
		_box(st, Vector3(0.50, 0.12, 0.50), Vector3(0, 3.46 + RISE, 0.02), Basis(Vector3.UP, 0.3), ROOF)                  # шляпа странника


## Обломки колонны на плите: барабан стоит, второй лежит, блоки разбросаны
static func _fragments(st: SurfaceTool, level: int) -> void:
	_box(st, Vector3(1.70, 0.70, 1.70), Vector3(0, 0.0, 0), Basis.IDENTITY, STONE)
	var seg := 8 if level == 0 else 6
	SettlementModels._cyl(st, 0.42, 0.50, 0.80, seg, Vector3(0, 0.75, 0.0), Basis.IDENTITY, STONE)
	SettlementModels._cyl(st, 0.40, 0.42, 0.60, seg, Vector3(0, 1.45, 0.0), Basis(Vector3.UP, 0.4), STONE)
	if level == 2:
		return
	SettlementModels._cyl(st, 0.42, 0.46, 1.10, seg, Vector3(1.20, 0.40, 0.55), Basis.from_euler(Vector3(0.0, 0.8, PI * 0.5)), STONE)
	_box(st, Vector3(0.55, 0.45, 0.50), Vector3(-1.15, 0.22, 0.65), Basis(Vector3.UP, 0.5), STONE)
	if level == 0:
		_box(st, Vector3(0.40, 0.30, 0.38), Vector3(0.35, 0.15, 1.45), Basis(Vector3.UP, 1.1), STONE)
		_box(st, Vector3(0.34, 0.26, 0.30), Vector3(-0.45, 0.13, -1.3), Basis(Vector3.UP, 0.2), STONE)


## Памятная стела: широкая плита на низком основании, один угол сколот
static func _stele(st: SurfaceTool, level: int) -> void:
	_box(st, Vector3(1.50, 0.90, 1.50), Vector3(0, -0.05, 0), Basis.IDENTITY, STONE)
	if level == 2:
		_box(st, Vector3(1.30, 2.5, 0.34), Vector3(0, 1.65, 0), Basis.IDENTITY, STONE)
		return
	_box(st, Vector3(1.30, 1.85, 0.34), Vector3(0, 1.33, 0), Basis.IDENTITY, STONE)
	_box(st, Vector3(0.70, 0.55, 0.34), Vector3(-0.30, 2.53, 0), Basis.IDENTITY, STONE)  # верх сколот справа
	_box(st, Vector3(0.28, 0.30, 0.34), Vector3(0.50, 2.40, 0), Basis(Vector3.BACK, 0.2), STONE)
	if level == 0:
		_box(st, Vector3(1.00, 0.10, 0.36), Vector3(0, 0.95, 0), Basis.IDENTITY, DARK)   # полосы резьбы под и над табличкой
		_box(st, Vector3(0.70, 0.08, 0.36), Vector3(0, 1.95, 0), Basis.IDENTITY, DARK)


## Фонари подсветки у цоколя с четырёх сторон: низкий металлический корпус и стекло (ночью светится). Дальний LOD — без них
static func _lamps(st: SurfaceTool, form: int, level: int) -> void:
	if level == 2:
		return
	var r: float = LIT[form].base + LAMP_GAP
	for dir: Vector3 in [Vector3.BACK, Vector3.RIGHT, Vector3.FORWARD, Vector3.LEFT]:
		var at := dir * r
		var basis := Basis.looking_at(-dir, Vector3.UP)
		_box(st, Vector3(0.26, 0.16, 0.2), at + Vector3(0, 0.08, 0), basis, METAL)
		_box(st, Vector3(0.2, 0.04, 0.14), at + Vector3(0, 0.17, 0) - dir * 0.02, basis, LIGHT)


## Ночная подсветка снизу одного обелиска формы form в xf (местные координаты модели): полосы света по граням от фонарей
## вверх и пятна у фонарей на земле — один меш, один вызов отрисовки, без источников света. salt — сдвиг палитры сторон
static func glow_node(form: int, xf: Transform3D, salt: int) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var spec: Dictionary = LIT[form]
	var parts: Array = spec.parts
	var height := 0.0
	for part: Array in parts:
		height = maxf(height, part[3])
	height = minf(height, GLOW_TOP)
	var r: float = spec.base + LAMP_GAP
	var dirs := [Vector3.BACK, Vector3.RIGHT, Vector3.FORWARD, Vector3.LEFT]
	for k in 4:
		var dir: Vector3 = dirs[k]
		var side := Vector3(dir.z, 0.0, -dir.x)
		var color: Color = GLOW_COLORS[posmod(k + salt, GLOW_COLORS.size())]
		for part: Array in parts:
			var y0: float = part[2]
			var y1: float = minf(part[3], height)
			if y1 <= y0:
				continue
			var depth: float = part[1] if absf(dir.z) > 0.5 else part[0]
			var half: float = part[0] if absf(dir.z) > 0.5 else part[1]
			var face := dir * (depth + 0.025)
			_glow_quad(st, face - side * half + Vector3(0, y0, 0), face + side * half + Vector3(0, y0, 0),
				face + side * half + Vector3(0, y1, 0), face - side * half + Vector3(0, y1, 0),
				Vector2(0, y0 / height), Vector2(1, y0 / height), Vector2(1, y1 / height), Vector2(0, y1 / height), Color(color, 1.0))
		# пятно на земле у фонаря, вытянутое к памятнику
		var lamp := dir * r
		var lift := Vector3(0, 0.04, 0)
		_glow_quad(st, lamp + dir * 0.55 - side * 0.7 + lift, lamp + dir * 0.55 + side * 0.7 + lift,
			lamp - dir * 0.75 + side * 0.7 + lift, lamp - dir * 0.75 - side * 0.7 + lift,
			Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1), Color(color, 0.5))
	var node := MeshInstance3D.new()
	node.name = "ObeliskGlow"
	node.mesh = st.commit()
	node.transform = xf
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.visibility_range_end = GLOW_SEEN
	node.material_override = glow_material()
	return node


static func _glow_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		ua: Vector2, ub: Vector2, uc: Vector2, ud: Vector2, color: Color) -> void:
	for v: Array in [[a, ua], [b, ub], [c, uc], [a, ua], [c, uc], [d, ud]]:
		st.set_color(color)
		st.set_uv(v[1])
		st.add_vertex(v[0])


static func glow_material() -> ShaderMaterial:
	if _glow_material == null:
		_glow_material = ShaderMaterial.new()
		_glow_material.shader = preload("res://resources/obelisk_glow.gdshader")
	return _glow_material


## lit 0..1 — насколько темно (SettlementsBuilder.set_night): подсветка разгорается вместе с окнами
static func set_night(lit: float) -> void:
	glow_material().set_shader_parameter("night", lit)
