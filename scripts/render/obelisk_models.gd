class_name ObeliskModels
extends RefCounted
## Формы памятников места "obelisk" (ObeliskLore.form_of): целый обелиск, разрушенный, старая статуя, обломки колонны на плите,
## памятная стела. Все на общем атласе поселений, три уровня детализации, в каталог как ключи KEYS (SettlementModels.build_site_lods).
## У всех квадратная подошва в пределах SITE_SIZES.obelisk (полуширина 0,75 м) — поворот на 90° не меняет ящик столкновения, поэтому
## модель можно развернуть табличкой к тропе (SettlementsBuilder) без расхождения с физикой.
## У каждой формы на цоколе — тёмная табличка лицом в +z: plaque(form) даёт её центр на лицевой стороне и размер (м) — по ним
## читается текст, рисуется зона съёмки в видоискателе и считается снимок.

const KEYS := ["obelisk", "obelisk_ruined", "obelisk_statue", "obelisk_fragments", "obelisk_stele"]
const STONE := SettlementModels.CELL_STONE
const DARK := SettlementModels.CELL_DARK_WOOD
const ROOF := SettlementModels.CELL_ROOF
const FRONT := 0.8   # лицевая грань цоколя от оси, м

## Табличка формы: центр лицевой стороны (местные координаты, +z наружу) и размер
const PLAQUES := [
	{pos = Vector3(0, 0.28, 0.85), size = Vector2(0.62, 0.36)},
	{pos = Vector3(0, 0.28, 0.85), size = Vector2(0.62, 0.36)},
	{pos = Vector3(0, 0.22, 0.80), size = Vector2(0.60, 0.30)},
	{pos = Vector3(0, 0.15, 0.90), size = Vector2(0.50, 0.24)},
	{pos = Vector3(0, 0.20, 0.80), size = Vector2(0.60, 0.30)},
]


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


## Статуя странника на постаменте: блочная фигура в плаще, одна рука поднята
static func _statue(st: SurfaceTool, level: int) -> void:
	_box(st, Vector3(1.50, 1.00, 1.50), Vector3(0, 0.0, 0), Basis.IDENTITY, STONE)
	if level == 2:
		_box(st, Vector3(0.8, 2.2, 0.5), Vector3(0, 1.6, 0), Basis.IDENTITY, STONE)
		_box(st, Vector3(0.38, 0.42, 0.38), Vector3(0, 2.95, 0), Basis.IDENTITY, STONE)
		return
	_box(st, Vector3(1.10, 0.20, 1.10), Vector3(0, 0.60, 0), Basis.IDENTITY, STONE) # верхний венец постамента
	if level == 1:
		_box(st, Vector3(0.62, 0.95, 0.38), Vector3(0, 1.30, 0), Basis.IDENTITY, STONE)
	else:
		for sx: float in [-0.17, 0.17]:
			_box(st, Vector3(0.26, 0.95, 0.30), Vector3(sx, 1.30, 0.02), Basis.IDENTITY, STONE)
	_box(st, Vector3(0.74, 1.10, 0.44), Vector3(0, 2.28, 0), Basis.IDENTITY, STONE)         # туловище в плаще
	_box(st, Vector3(0.84, 0.20, 0.50), Vector3(0, 2.90, 0), Basis.IDENTITY, STONE)         # плечи
	_box(st, Vector3(0.38, 0.42, 0.38), Vector3(0, 3.22, 0.02), Basis.IDENTITY, STONE)      # голова
	if level == 0:
		_box(st, Vector3(0.22, 0.85, 0.22), Vector3(-0.52, 2.15, 0.05), Basis.IDENTITY, STONE)                     # опущенная рука
		_box(st, Vector3(0.22, 0.80, 0.22), Vector3(0.58, 3.00, 0.30), Basis(Vector3.BACK, -0.45), STONE)         # поднятая рука
		_box(st, Vector3(0.50, 0.12, 0.50), Vector3(0, 3.46, 0.02), Basis(Vector3.UP, 0.3), ROOF)                  # шляпа странника


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
		_box(st, Vector3(1.00, 0.10, 0.36), Vector3(0, 1.20, 0), Basis.IDENTITY, DARK)   # полоса резьбы
		_box(st, Vector3(0.70, 0.08, 0.36), Vector3(0, 1.65, 0), Basis.IDENTITY, DARK)
