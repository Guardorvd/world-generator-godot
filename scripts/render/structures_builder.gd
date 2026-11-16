class_name StructuresBuilder
extends RefCounted
## Мосты и туннели в 3D: деревянный настил с перилами, подкосами и сваями, каменный мостик с карнизом и устоями,
## галерея туннеля с замковым камнем и фонарями. Размеры и высоты берутся из Heightfield.structures, по ним же
## считается движение, поэтому модель и опора для ног совпадают.
## С 16.11 основной сборщик build() рисует все сооружения на едином общем атласе SettlementModels
## с поквадратным батчингом (256 м) и 3 явными уровнями детализации (LOD0/1/2: 60 / 250 / 1400 м).

const TUNNEL_HEIGHT := Heightfield.TUNNEL_HEIGHT
const SettlementModels := preload("res://scripts/render/settlement_models.gd")
const SettlementsBuilder := preload("res://scripts/render/settlements_builder.gd")
const Catalog := preload("res://scripts/render/asset_catalog.gd")

const COL_TIMBER_A := Color(0.55, 0.41, 0.27, 1.0)
const COL_TIMBER_B := Color(0.43, 0.31, 0.20, 1.0)
const COL_DARK_WOOD := Color(0.35, 0.25, 0.16, 1.0)
const COL_RAIL := Color(0.42, 0.30, 0.19, 1.0)
const COL_STONE_A := Color(0.61, 0.58, 0.54, 1.0)
const COL_STONE_B := Color(0.52, 0.50, 0.46, 1.0)
const COL_PORTAL := Color(0.44, 0.42, 0.39, 1.0)
const COL_COPING := Color(0.66, 0.63, 0.58, 1.0)

static var use_legacy := false
static var _build_lock := Mutex.new()
static var _boxes := {} # Vector3 (размер) -> BoxMesh (для прямых вызовов bridge/stone_bridge/planks и CrashEnvironment)
static var _uv_boxes := {} # int cell -> единичный ArrayMesh куб с UV ячейки атласа


## Ящик size с центром в offset в системе координат at
## Ящики одного размера (перила, столбики, доски) — один BoxMesh: на длинном мосту их тысячи
static func _box(batch: MeshBatch, at: Transform3D, size: Vector3, offset: Vector3, mat: Material) -> void:
	var b: BoxMesh = _boxes.get(size)
	if b == null:
		b = BoxMesh.new()
		b.size = size
		_boxes[size] = b
	batch.add(b, at * Transform3D(Basis(), offset), mat)


## Единичный куб (-0.5..0.5) с UV ячейки общего атласа cell: трансформируется через Basis.from_scale(size).
static func _uv_box(cell: int) -> ArrayMesh:
	var cached: ArrayMesh = _uv_boxes.get(cell)
	if cached != null:
		return cached
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	SettlementModels._box(st, Vector3.ONE, Vector3.ZERO, Basis.IDENTITY, cell)
	st.index()
	var mesh := st.commit()
	_uv_boxes[cell] = mesh
	return mesh


static func _add_lod_box(batch: MeshBatch, at: Transform3D, size: Vector3, offset: Vector3, mat: Material,
		level: int, cell: int, tint: Color, count_center := true) -> void:
	var safe := Vector3(maxf(0.01, size.x), maxf(0.01, size.y), maxf(0.01, size.z))
	var xf := at * Transform3D(Basis(), offset) * Transform3D(Basis.from_scale(safe), Vector3.ZERO)
	batch.add_lod(_uv_box(cell), xf, [mat], level, {cell: tint}, count_center)


static func _shared_opaque_mat() -> Material:
	if SettlementsBuilder.shared_opaque_mat != null:
		return SettlementsBuilder.shared_opaque_mat
	var catalog := Catalog.get_catalog()
	var textures: Array = catalog.settlement_textures if catalog != null else []
	var mats := SettlementModels.make_materials(textures)
	SettlementsBuilder.shared_opaque_mat = mats.opaque
	return mats.opaque


## Перило-столбик высотой 1 м, основанием в точке at
static func _post(batch: MeshBatch, at: Vector3, mat: Material) -> void:
	_box(batch, Transform3D(), Vector3(0.14, 1.0, 0.14), at + Vector3(0, 0.5, 0), mat)


## Добавляет все мосты и туннели в parent общими мешами по квадратам мира (см. MeshBatch)
## only — свой список сооружений (13.9: мосты закреплённой области), иначе все heights.structures
static func build(parent: Node3D, heights: Heightfield, only: Variant = null) -> void:
	_build_lock.lock()
	if use_legacy:
		_build_legacy(parent, heights, only)
		_build_lock.unlock()
		return
	var batch := MeshBatch.new()
	batch.keep_world_origin = (only != null and heights.world != null and heights.world.outer == null)
	var shared_mat := _shared_opaque_mat()
	for s: Dictionary in (heights.structures if only == null else only):
		if s.get("deck", false):
			continue # настил трассы: его рисует TrailLabProps вместе с остальными объектами трассы
		if s.tunnel:
			var a := Vector3(s.ax, s.ay, s.az)
			var b := Vector3(s.bx, s.by, s.bz)
			if a.distance_to(b) < 0.01:
				continue
			var up := Vector3.UP if absf((b - a).normalized().y) < 0.99 else Vector3.BACK
			_tunnel_lod(batch, Transform3D(Basis.looking_at(b - a, up), a), s.half, a.distance_to(b), -a.distance_to(b) * 0.5, shared_mat)
		elif s.style == "stone":
			_stone_bridge_lod(batch, heights, s, shared_mat)
		elif s.style == "planks":
			_planks_lod(batch, heights, s, shared_mat)
		else:
			_bridge_lod(batch, heights, s, shared_mat)
	var mi := batch.build("Structures")
	if mi != null:
		parent.add_child(mi)
	_build_lock.unlock()


static func _build_legacy(parent: Node3D, heights: Heightfield, only: Variant) -> void:
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
			continue
		if s.tunnel:
			var a := Vector3(s.ax, s.ay, s.az)
			var b := Vector3(s.bx, s.by, s.bz)
			if a.distance_to(b) < 0.01:
				continue
			var up := Vector3.UP if absf((b - a).normalized().y) < 0.99 else Vector3.BACK
			tunnel(batch, Transform3D(Basis.looking_at(b - a, up), a), s.half, a.distance_to(b), -a.distance_to(b) * 0.5, stone, portal)
		elif s.style == "stone":
			stone_bridge(batch, heights, s, slab, slab_dark, portal)
		elif s.style == "planks":
			planks(batch, heights, s, plank_light, board, rail)
		else:
			bridge(batch, heights, s, wood, rail, board)
	_boxes.clear()
	var mi := batch.build("Structures")
	if mi != null:
		parent.add_child(mi)


## Сплошной или дощатый настил (верх строго равен Heightfield.level(s, t)). step <= 0 — одна сплошная плита (LOD1/LOD2).
static func _deck_lod(batch: MeshBatch, a: Vector3, b: Vector3, half: float, mat: Material,
		level: int, cell: int, tint_a: Color, tint_b: Color, step: float, count_center := true) -> void:
	var flat_len := Vector2(b.x - a.x, b.z - a.z).length()
	if flat_len < 0.01:
		return
	var forward := (b - a).normalized()
	var side := Vector3(-forward.z, 0.0, forward.x).normalized()
	var parts := 1 if step <= 0.0 else maxi(1, ceili(flat_len / step))
	for p in parts:
		var pa := a if parts == 1 else a.lerp(b, float(p) / parts)
		var pb := b if parts == 1 else a.lerp(b, float(p + 1) / parts)
		var seg_flat := Vector2(pb.x - pa.x, pb.z - pa.z).length()
		if seg_flat < 0.01:
			continue
		var basis := Basis(side, Vector3.UP, -(pb - pa) / seg_flat)
		var tint := tint_a if p % 2 == 0 else tint_b
		_add_lod_box(batch, Transform3D(basis, (pa + pb) * 0.5), Vector3(half * 2.0, 0.24, seg_flat + (0.04 if parts == 1 else 0.0)),
			Vector3(0.0, -0.12, 0.0), mat, level, cell, tint, count_center and p == 0)


## Деревянный мост с 3 явными LOD на общем атласе:
## LOD0 — отдельные доски, нижние поперечины, бордюры, поручни, столбики и раскосы свай;
## LOD1 — единая полоса настила на секцию 2 м, поручни, бордюры и сваи;
## LOD2 — единая полоса настила и основные сваи без перил и теней.
static func _bridge_lod(batch: MeshBatch, heights: Heightfield, s: Dictionary, mat: Material) -> void:
	if s.len < 0.01 or Vector2(s.ux, s.uz).is_zero_approx():
		return
	var half: float = s.half
	var n := maxi(1, ceili(s.len / Heightfield.BRIDGE_SECTION))
	var side := Vector3(s.uz, 0.0, -s.ux) * (half + 0.1)
	for k in n:
		var t0: float = s.len * k / n
		var t1: float = s.len * (k + 1) / n
		var p0 := Vector3(s.ax + s.ux * t0, heights.level(s, t0), s.az + s.uz * t0)
		var p1 := Vector3(s.ax + s.ux * t1, heights.level(s, t1), s.az + s.uz * t1)
		var seg := p0.distance_to(p1)
		if seg < 0.01:
			continue
		var at := Transform3D(Basis.looking_at(p1 - p0, Vector3.UP), p0)
		_deck_lod(batch, p0, p1, half, mat, 0, SettlementModels.CELL_TIMBER, COL_TIMBER_A, COL_TIMBER_B, 0.42, true)
		_deck_lod(batch, p0, p1, half, mat, 1, SettlementModels.CELL_TIMBER, COL_TIMBER_A, COL_TIMBER_A, 0.0, false)
		_deck_lod(batch, p0, p1, half, mat, 2, SettlementModels.CELL_TIMBER, COL_TIMBER_A, COL_TIMBER_A, 0.0, false)

		for sd: float in [-1.0, 1.0]:
			# Прогон под пролётом (LOD0..LOD1)
			_add_lod_box(batch, at, Vector3(0.20, 0.28, seg + 0.02), Vector3(sd * (half - 0.30), -0.36, -seg * 0.5),
				mat, 0, SettlementModels.CELL_DARK_WOOD, COL_DARK_WOOD, false)
			_add_lod_box(batch, at, Vector3(0.20, 0.28, seg + 0.02), Vector3(sd * (half - 0.30), -0.36, -seg * 0.5),
				mat, 1, SettlementModels.CELL_DARK_WOOD, COL_DARK_WOOD, false)
			# Поручень и колёсоотбойный брус (LOD0..LOD1)
			_add_lod_box(batch, at, Vector3(0.13, 0.13, seg + 0.02), Vector3(sd * (half + 0.10), 1.00, -seg * 0.5),
				mat, 0, SettlementModels.CELL_RAIL, COL_RAIL, false)
			_add_lod_box(batch, at, Vector3(0.13, 0.13, seg + 0.02), Vector3(sd * (half + 0.10), 1.00, -seg * 0.5),
				mat, 1, SettlementModels.CELL_RAIL, COL_RAIL, false)
			_add_lod_box(batch, at, Vector3(0.16, 0.14, seg + 0.02), Vector3(sd * (half - 0.02), 0.05, -seg * 0.5),
				mat, 0, SettlementModels.CELL_DARK_WOOD, COL_DARK_WOOD, false)
		# Поперечина под настилом на стыке пролёта (LOD0)
		_add_lod_box(batch, at, Vector3(half * 2.0 + 0.55, 0.20, 0.22), Vector3(0.0, -0.32, 0.0),
			mat, 0, SettlementModels.CELL_DARK_WOOD, COL_DARK_WOOD, false)
		# Вертикальные стойки перил (LOD0)
		for q: Vector3 in [p0 + side, p0 - side]:
			_add_lod_box(batch, Transform3D(Basis.IDENTITY, q), Vector3(0.14, 1.02, 0.14), Vector3(0.0, 0.50, 0.0),
				mat, 0, SettlementModels.CELL_RAIL, COL_RAIL, false)
		# Сваи и раскосы под стыком пролётов примерно через 8 м (LOD0..LOD2)
		if k > 0 and k % 4 == 0:
			for sd: float in [-1.0, 1.0]:
				var q: Vector3 = p0 + side * (sd * 0.85)
				var g := heights.ground_at(q.x, q.z)
				var tall: float = q.y - 0.30 - g + 1.0
				if tall >= 1.0:
					for lvl in 3:
						_add_lod_box(batch, Transform3D.IDENTITY, Vector3(0.36, tall, 0.36),
							Vector3(q.x, g - 1.0 + tall * 0.5, q.z), mat, lvl, SettlementModels.CELL_DARK_WOOD, COL_DARK_WOOD, false)
					# Косые подкосы к свае (LOD0)
					for dir_s: float in [-1.0, 1.0]:
						var brace_xform := Transform3D(Basis.looking_at(p1 - p0, Vector3.UP).rotated(side.normalized(), dir_s * 0.65),
							Vector3(q.x, q.y - 0.85, q.z))
						_add_lod_box(batch, brace_xform, Vector3(0.14, 1.35, 0.14), Vector3(0.0, 0.0, 0.0),
							mat, 0, SettlementModels.CELL_TIMBER, COL_TIMBER_B, false)
	var end := Vector3(s.bx, s.by, s.bz)
	for q: Vector3 in [end + side, end - side]:
		_add_lod_box(batch, Transform3D(Basis.IDENTITY, q), Vector3(0.14, 1.02, 0.14), Vector3(0.0, 0.50, 0.0),
			mat, 0, SettlementModels.CELL_RAIL, COL_RAIL, false)


## Каменный мостик с 3 LOD на общем атласе.
static func _stone_bridge_lod(batch: MeshBatch, heights: Heightfield, s: Dictionary, mat: Material) -> void:
	if s.len < 0.01 or Vector2(s.ux, s.uz).is_zero_approx():
		return
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
		_deck_lod(batch, p0, p1, half, mat, 0, SettlementModels.CELL_STONE, COL_STONE_A, COL_STONE_B, 0.72, true)
		_deck_lod(batch, p0, p1, half, mat, 1, SettlementModels.CELL_STONE, COL_STONE_A, COL_STONE_A, 0.0, false)
		_deck_lod(batch, p0, p1, half, mat, 2, SettlementModels.CELL_STONE, COL_STONE_A, COL_STONE_A, 0.0, false)

		for sd: float in [-1.0, 1.0]:
			_add_lod_box(batch, at, Vector3(0.44, 0.54, seg + 0.03), Vector3(sd * (half + 0.12), 0.12, -seg * 0.5),
				mat, 0, SettlementModels.CELL_STONE, COL_PORTAL, false)
			_add_lod_box(batch, at, Vector3(0.50, 0.10, seg + 0.04), Vector3(sd * (half + 0.12), 0.41, -seg * 0.5),
				mat, 0, SettlementModels.CELL_PLASTER, COL_COPING, false)
			_add_lod_box(batch, at, Vector3(0.44, 0.54, seg + 0.03), Vector3(sd * (half + 0.12), 0.12, -seg * 0.5),
				mat, 1, SettlementModels.CELL_STONE, COL_PORTAL, false)
		for lvl in 3:
			_add_lod_box(batch, at, Vector3(half * 2.0 + 0.62, 0.52, seg + 0.02), Vector3(0.0, -0.45, -seg * 0.5),
				mat, lvl, SettlementModels.CELL_STONE, COL_STONE_B, false)
	for t: float in [0.0, s.len * 0.5, s.len]:
		if t == s.len * 0.5 and s.len < 14.0:
			continue
		var q := Vector3(s.ax + s.ux * t, heights.level(s, t), s.az + s.uz * t)
		var g := minf(heights.ground_at(q.x, q.z), q.y - 0.7)
		var tall := q.y - 0.6 - (g - 1.0)
		var face := Transform3D(Basis.looking_at(Vector3(s.ux, 0.0, s.uz), Vector3.UP), Vector3(q.x, g - 1.0 + tall * 0.5, q.z))
		var pier_len := 1.6 if t == s.len * 0.5 else 2.2
		for lvl in 3:
			_add_lod_box(batch, face, Vector3(half * 2.0 + 0.90, tall, pier_len), Vector3.ZERO,
				mat, lvl, SettlementModels.CELL_STONE, COL_PORTAL, false)
		_add_lod_box(batch, face, Vector3(half * 2.0 + 1.15, 0.65, pier_len + 0.25), Vector3(0.0, -tall * 0.5 + 0.55, 0.0),
			mat, 0, SettlementModels.CELL_STONE, COL_STONE_B, false)


## Дощатая переправа тропы с 3 LOD на общем атласе.
static func _planks_lod(batch: MeshBatch, heights: Heightfield, s: Dictionary, mat: Material) -> void:
	if s.len < 0.01 or Vector2(s.ux, s.uz).is_zero_approx():
		return
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
			var col := COL_TIMBER_A if (j + k) % 2 == 0 else COL_TIMBER_B
			_add_lod_box(batch, at, Vector3(width - 0.07, 0.09 if (j + k) % 3 else 0.11, seg + 0.03),
				Vector3(x, -0.05, -seg * 0.5), mat, 0, SettlementModels.CELL_TIMBER, col, j == 1)
		_add_lod_box(batch, at, Vector3(half * 2.0 - 0.06, 0.10, seg + 0.03), Vector3(0.0, -0.05, -seg * 0.5),
			mat, 1, SettlementModels.CELL_TIMBER, COL_TIMBER_A, false)
		_add_lod_box(batch, at, Vector3(half * 2.0 - 0.06, 0.10, seg + 0.03), Vector3(0.0, -0.05, -seg * 0.5),
			mat, 2, SettlementModels.CELL_TIMBER, COL_TIMBER_A, false)
		_add_lod_box(batch, at, Vector3(half * 2.0 + 0.30, 0.14, 0.20), Vector3(0.0, -0.17, 0.0),
			mat, 0, SettlementModels.CELL_DARK_WOOD, COL_DARK_WOOD, false)
		_add_lod_box(batch, at, Vector3(half * 2.0 + 0.30, 0.14, 0.20), Vector3(0.0, -0.17, 0.0),
			mat, 1, SettlementModels.CELL_DARK_WOOD, COL_DARK_WOOD, false)
		if k > 0 and k % 2 == 0:
			for sd: float in [-1.0, 1.0]:
				var q := p0 + Vector3(s.uz, 0.0, -s.ux) * sd * (half + 0.05)
				var g := heights.ground_at(q.x, q.z)
				var tall: float = q.y - 0.20 - g + 0.80
				if tall >= 0.80:
					for lvl in 3:
						_add_lod_box(batch, Transform3D.IDENTITY, Vector3(0.16, tall, 0.16),
							Vector3(q.x, g - 0.80 + tall * 0.5, q.z), mat, lvl, SettlementModels.CELL_DARK_WOOD, COL_DARK_WOOD, false)
	for e: Vector3 in [Vector3(s.ax, s.ay, s.az), Vector3(s.bx, s.by, s.bz)]:
		for sd: float in [-1.0, 1.0]:
			var q := e + Vector3(s.uz, 0.0, -s.ux) * sd * (half + 0.15)
			_add_lod_box(batch, Transform3D.IDENTITY, Vector3(0.12, 0.60, 0.12), q + Vector3(0.0, 0.15, 0.0),
				mat, 0, SettlementModels.CELL_RAIL, COL_RAIL, false)


## Туннель с 3 LOD на общем атласе: каменные стены, свод, порталы с замковым камнем и светящиеся фонари.
static func _tunnel_lod(batch: MeshBatch, at: Transform3D, half: float, length: float, mid: float, mat: Material) -> void:
	var h := TUNNEL_HEIGHT
	for lvl in 3:
		for side: float in [-1.0, 1.0]:
			_add_lod_box(batch, at, Vector3(1.0, h + 1.0, length), Vector3(side * (half + 0.5), h * 0.5 - 0.5, mid),
				mat, lvl, SettlementModels.CELL_STONE, COL_STONE_B, lvl == 0 and side < 0.0)
		_add_lod_box(batch, at, Vector3(half * 2.0 + 2.0, 0.8, length), Vector3(0.0, h + 0.4, mid),
			mat, lvl, SettlementModels.CELL_STONE, COL_STONE_B, false)
		for z: float in [0.0, -length]:
			for side: float in [-1.0, 1.0]:
				_add_lod_box(batch, at, Vector3(1.4, h + 2.0, 1.0), Vector3(side * (half + 0.7), h * 0.5, z),
					mat, lvl, SettlementModels.CELL_STONE, COL_PORTAL, false)
			_add_lod_box(batch, at, Vector3(half * 2.0 + 2.8, 1.2, 1.0), Vector3(0.0, h + 0.8, z),
				mat, lvl, SettlementModels.CELL_STONE, COL_PORTAL, false)
			if lvl <= 1:
				# Светящиеся портальные фонари внутри входов туннеля
				var in_dir := -1.2 if z == 0.0 else 1.2
				for side: float in [-1.0, 1.0]:
					_add_lod_box(batch, at, Vector3(0.22, 0.34, 0.22),
						Vector3(side * (half - 0.12), h - 0.62, z + in_dir),
						mat, lvl, SettlementModels.CELL_WINDOW, Color.WHITE, false)
			if lvl == 0:
				# Замковый камень и ступенчатый карниз портала
				_add_lod_box(batch, at, Vector3(0.75, 0.90, 1.18), Vector3(0.0, h + 0.82, z),
					mat, 0, SettlementModels.CELL_PLASTER, COL_COPING, false)
				_add_lod_box(batch, at, Vector3(half * 2.0 + 3.1, 0.24, 1.16), Vector3(0.0, h + 1.48, z),
					mat, 0, SettlementModels.CELL_PLASTER, COL_COPING, false)


## Мост: невысокий деревянный настил, перила и сваи; профиль общий с движением.
static func bridge(batch: MeshBatch, heights: Heightfield, s: Dictionary, wood: Material, rail: Material, board: Material) -> void:
	if s.len < 0.01 or Vector2(s.ux, s.uz).is_zero_approx(): return
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
	if s.len < 0.01 or Vector2(s.ux, s.uz).is_zero_approx(): return
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
	if s.len < 0.01 or Vector2(s.ux, s.uz).is_zero_approx(): return
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
	var length := Vector2(b.x - a.x, b.z - a.z).length()
	if length < 0.01: return # A vertical or coincident span has no deck plane.
	var forward := (b - a).normalized()
	var side := Vector3(-forward.z, 0, forward.x).normalized()
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
