class_name SettlementModels
extends RefCounted
## Процедурные модели поселений (для сборки .glb), общий атлас текстур и валидатор импорта.
## Точка опоры каждой модели — центр пола (0, 0, 0), дверь в +Z, конёк вдоль Z, цоколь до -0,5 м.
## Все постройки используют один общий атлас (непрозрачный материал + вырез для цветов/декора).

const ATLAS_SIZE := 256
const CELL_PX := 64
const GRID := 4
const UV_PAD := 0.02

## Индексы ячеек 4×4 в общем атласе (слева направо, сверху вниз).
enum {
	CELL_STONE = 0,
	CELL_PLASTER = 1,
	CELL_TIMBER = 2,
	CELL_DARK_WOOD = 3,
	CELL_ROOF = 4,
	CELL_SHUTTER = 5,
	CELL_LOGS_END = 6,
	CELL_STRAW = 7,
	CELL_WATER = 8,
	CELL_RAIL = 9,
	CELL_METAL = 10,
	CELL_CHIMNEY = 11,
	CELL_LEAF = 12,
	CELL_FLOWER_A = 13,
	CELL_FLOWER_B = 14,
	CELL_WINDOW = 15,
}

## Палитра цветов по умолчанию (используется для тонирования экземпляров в SettlementsBuilder / MeshBatch).
const PLASTER_TINTS := [0xece2cc, 0xf3eee4, 0xdcc08a, 0xe6cbb8, 0xd3d6c6]
const TIMBER_TINTS := [0x7a4b2b, 0x5f3b23, 0x8d5e36]
const ROOF_TINTS := [0x4a3a30, 0x464b54, 0x94452f, 0x67503e]
const SHUTTER_TINTS := [0x3f6e3c, 0x9a3a2e, 0x4c6283, 0x2f2a24]
const FLOWER_TINTS := [0xd23a3f, 0xe0709a]


static func _hex(c: int) -> Color:
	return Color.hex((c << 8) | 0xff)


## Палитра тонов ячеек атласа для конкретного дома по стилю поселения и варианту дома.
static func cell_tints(style: int, v: int, outbuilding := false) -> Dictionary:
	var plaster := _hex(PLASTER_TINTS[(style * 2 + v) % PLASTER_TINTS.size()])
	var timber := _hex(TIMBER_TINTS[(style + v / 2) % TIMBER_TINTS.size()])
	var roof := Color.html("#4a3f36") if outbuilding else _hex(ROOF_TINTS[(style + (1 if v == 3 else 0)) % ROOF_TINTS.size()])
	var shutter := _hex(SHUTTER_TINTS[(style + (1 if v == 2 else 0)) % SHUTTER_TINTS.size()])
	return {
		CELL_STONE: Color.html("#7f786a"),
		CELL_PLASTER: plaster,
		CELL_TIMBER: Color.html("#8b6342") if outbuilding else timber,
		CELL_DARK_WOOD: Color.html("#4a3624"),
		CELL_ROOF: roof,
		CELL_SHUTTER: shutter,
		CELL_LOGS_END: Color.html("#c49b66"),
		CELL_STRAW: Color.html("#ceb064"),
		CELL_WATER: Color.html("#5d8ea6"),
		CELL_RAIL: Color.html("#a57446"),
		CELL_METAL: Color.html("#62666b"),
		CELL_CHIMNEY: Color.html("#82796e"),
		CELL_LEAF: Color.WHITE,
		CELL_FLOWER_A: Color.WHITE,
		CELL_FLOWER_B: Color.WHITE,
		CELL_WINDOW: Color.WHITE,
	}


## Номер ячейки атласа 0..15 по UV-координате.
static func cell_at_uv(uv: Vector2) -> int:
	var col := clampi(int(uv.x * GRID), 0, GRID - 1)
	var row := clampi(int(uv.y * GRID), 0, GRID - 1)
	return row * GRID + col


## UV-прямоугольник ячейки с отступом от границ мипмапов.
static func cell_uv_rect(cell: int) -> Rect2:
	var col := cell % GRID
	var row := cell / GRID
	var step := 1.0 / float(GRID)
	return Rect2(col * step + UV_PAD, row * step + UV_PAD, step - UV_PAD * 2.0, step - UV_PAD * 2.0)


## Общий атлас текстур поселений: [albedo: Image, emission: Image] размером 256×256 RGBA8 с мипмапами.
static func build_atlas() -> Array[Image]:
	var albedo := Image.create(ATLAS_SIZE, ATLAS_SIZE, false, Image.FORMAT_RGBA8)
	var emission := Image.create(ATLAS_SIZE, ATLAS_SIZE, false, Image.FORMAT_RGBA8)
	emission.fill(Color(0.0, 0.0, 0.0, 1.0))
	for cell in GRID * GRID:
		var ox := (cell % GRID) * CELL_PX
		var oy := (cell / GRID) * CELL_PX
		for py in CELL_PX:
			for px in CELL_PX:
				var u := float(px) / float(CELL_PX - 1)
				var v := float(py) / float(CELL_PX - 1)
				var h := WGRandom.hash2(px + cell * 73, py + cell * 137, 9101)
				var c := Color.WHITE
				var em := Color(0.0, 0.0, 0.0, 1.0)
				match cell:
					CELL_STONE:
						var row_st := int(v * 4.0)
						var shift := 0.5 if row_st % 2 == 1 else 0.0
						var seam := absf(fposmod(v * 4.0, 1.0) - 0.5) > 0.44 or absf(fposmod(u * 3.0 + shift, 1.0) - 0.5) > 0.44
						var val := (0.76 if seam else 0.94) + (h - 0.5) * 0.12
						c = Color(val, val * 0.98, val * 0.94, 1.0)
					CELL_PLASTER:
						var val := 0.96 + (h - 0.5) * 0.06
						c = Color(val, val * 0.99, val * 0.97, 1.0)
					CELL_TIMBER:
						var plank := absf(fposmod(v * 6.0, 1.0) - 0.5) > 0.44
						var val := (0.74 if plank else 0.96) + (h - 0.5) * 0.09
						c = Color(val, val * 0.96, val * 0.92, 1.0)
					CELL_DARK_WOOD:
						var grain := absf(fposmod(u * 5.0, 1.0) - 0.5) > 0.43
						var val := (0.78 if grain else 0.95) + (h - 0.5) * 0.08
						c = Color(val, val * 0.95, val * 0.90, 1.0)
					CELL_ROOF:
						var row_r := int(v * 6.0)
						var shift_r := 0.5 if row_r % 2 == 1 else 0.0
						var lip := fposmod(v * 6.0, 1.0) > 0.86
						var gap := absf(fposmod(u * 5.0 + shift_r, 1.0) - 0.5) > 0.45
						var val := (0.72 if lip else (0.82 if gap else 0.96)) + (h - 0.5) * 0.08
						c = Color(val, val * 0.99, val * 0.98, 1.0)
					CELL_SHUTTER:
						var slat := fposmod(v * 10.0, 1.0) > 0.72
						var val := (0.78 if slat else 0.98) + (h - 0.5) * 0.05
						c = Color(val, val, val, 1.0)
					CELL_LOGS_END:
						var lx := fposmod(u * 4.0, 1.0) - 0.5
						var ly := fposmod(v * 4.0, 1.0) - 0.5
						var d := sqrt(lx * lx + ly * ly)
						var val := (0.45 if d > 0.43 else (0.75 if d > 0.34 else 0.98)) + (h - 0.5) * 0.08
						c = Color(val, val * 0.95, val * 0.88, 1.0)
					CELL_STRAW:
						var strand := sin(u * 44.0 + h * 2.5) * 0.08
						var val := 0.94 + strand + (h - 0.5) * 0.08
						c = Color(val, val * 0.96, val * 0.84, 1.0)
					CELL_WATER:
						var wave := sin(u * 18.0 + v * 12.0) * 0.05
						c = Color(0.92 + wave, 0.96 + wave, 1.0, 1.0)
					CELL_RAIL:
						var val := 0.95 + (h - 0.5) * 0.08
						c = Color(val, val * 0.97, val * 0.92, 1.0)
					CELL_METAL:
						var val := 0.90 + (h - 0.5) * 0.08
						c = Color(val, val, val * 1.02, 1.0)
					CELL_CHIMNEY:
						var row_c := int(v * 5.0)
						var shift_c := 0.5 if row_c % 2 == 1 else 0.0
						var seam_c := fposmod(v * 5.0, 1.0) > 0.84 or fposmod(u * 3.0 + shift_c, 1.0) > 0.88
						var val := (0.70 if seam_c else 0.95) + (h - 0.5) * 0.10
						c = Color(val, val * 0.96, val * 0.92, 1.0)
					CELL_LEAF:
						var d := Vector2(u - 0.5, v - 0.5).length()
						var alpha := 1.0 if (d < 0.46 or (u > 0.12 and u < 0.88 and v > 0.12 and v < 0.88)) else 0.0
						var val := 0.88 + (h - 0.5) * 0.22
						var leaf_base := Color.html("#4f6e2f")
						c = Color(leaf_base.r * val, leaf_base.g * val, leaf_base.b * val, alpha)
					CELL_FLOWER_A, CELL_FLOWER_B:
						var d := Vector2(u - 0.5, v - 0.5).length()
						var blossom := sin(atan2(v - 0.5, u - 0.5) * 6.0) * 0.06
						var alpha := 1.0 if d < 0.42 + blossom else 0.0
						var val := 0.94 + (h - 0.5) * 0.14
						var f_col := _hex(FLOWER_TINTS[0] if cell == CELL_FLOWER_A else FLOWER_TINTS[1])
						c = Color(f_col.r * val, f_col.g * val, f_col.b * val, alpha)
					CELL_WINDOW:
						# Днём — тёмное стекло с переплётом; ночью светится стекло по карте излучения.
						var frame := u < 0.10 or u > 0.90 or v < 0.10 or v > 0.90
						var mullion := absf(u - 0.5) < 0.055 or absf(v - 0.48) < 0.055
						if frame or mullion:
							c = Color(0.24, 0.18, 0.12, 1.0)
							em = Color(0.0, 0.0, 0.0, 1.0)
						else:
							var warm_var := 0.94 + (h - 0.5) * 0.08
							c = Color(0.16, 0.18, 0.20, 1.0)
							em = Color(0.95 * warm_var, 0.82 * warm_var, 0.48 * warm_var, 1.0)
				albedo.set_pixel(ox + px, oy + py, c)
				emission.set_pixel(ox + px, oy + py, em)
	albedo.generate_mipmaps()
	emission.generate_mipmaps()
	return [albedo, emission]


## Создаёт два общих материала (непрозрачный со светящимися окнами и с вырезом) из текстур каталога.
static func make_materials(textures: Array) -> Dictionary:
	var opaque := StandardMaterial3D.new()
	opaque.resource_name = "settlement_opaque"
	opaque.roughness = 0.92
	opaque.vertex_color_use_as_albedo = true
	if textures.size() >= 1 and textures[0] != null:
		opaque.albedo_texture = textures[0]
	if textures.size() >= 2 and textures[1] != null:
		opaque.emission_enabled = true
		opaque.emission_texture = textures[1]
		opaque.emission_operator = BaseMaterial3D.EMISSION_OP_ADD
		opaque.emission_energy_multiplier = 0.0

	var cutout := StandardMaterial3D.new()
	cutout.resource_name = "settlement_cutout"
	cutout.roughness = 0.95
	cutout.vertex_color_use_as_albedo = true
	cutout.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	cutout.alpha_scissor_threshold = 0.5
	cutout.cull_mode = BaseMaterial3D.CULL_DISABLED
	if textures.size() >= 1 and textures[0] != null:
		cutout.albedo_texture = textures[0]
	return {opaque = opaque, cutout = cutout}


## Собирает сцену для экспорта в .glb (узлы LOD0, LOD1, LOD2) с единым общим материалом.
static func build_glb_scene(id: String, shared_mats: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = id
	var lods := build_model_lods(id)
	for level in lods.size():
		var mi := MeshInstance3D.new()
		mi.name = "LOD%d" % level
		var mesh := lods[level]
		if mesh.get_surface_count() >= 1:
			mesh.surface_set_material(0, shared_mats.opaque)
		if mesh.get_surface_count() >= 2:
			mesh.surface_set_material(1, shared_mats.cutout)
		mi.mesh = mesh
		root.add_child(mi)
		mi.owner = root
	return root


## Строит 3 явных уровня детализации [LOD0, LOD1, LOD2] для модели по строковому имени.
static func build_model_lods(id: String) -> Array[ArrayMesh]:
	match id:
		"house":
			return [_build_house(0), _build_house(1), _build_house(2)]
		"house_wing":
			return [_build_house_wing(0), _build_house_wing(1), _build_house_wing(2)]
		"house_steep":
			return [_build_house_steep(0), _build_house_steep(1), _build_house_steep(2)]
		"house_timber":
			return [_build_house_timber(0), _build_house_timber(1), _build_house_timber(2)]
		"cabin_long":
			return [_build_cabin_long(0), _build_cabin_long(1), _build_cabin_long(2)]
		"cabin_porch":
			return [_build_cabin_porch(0), _build_cabin_porch(1), _build_cabin_porch(2)]
		"chalet":
			return [_build_chalet(0), _build_chalet(1), _build_chalet(2)]
		"chalet_terrace":
			return [_build_chalet_terrace(0), _build_chalet_terrace(1), _build_chalet_terrace(2)]
		"chalet_stone":
			return [_build_chalet_stone(0), _build_chalet_stone(1), _build_chalet_stone(2)]
		"tall":
			return [_build_tall(0), _build_tall(1), _build_tall(2)]
		"tall_mansard":
			return [_build_tall_mansard(0), _build_tall_mansard(1), _build_tall_mansard(2)]
		"tall_hall":
			return [_build_tall_hall(0), _build_tall_hall(1), _build_tall_hall(2)]
		"barn":
			return [_build_barn(0), _build_barn(1), _build_barn(2)]
		"barn_loft":
			return [_build_barn_loft(0), _build_barn_loft(1), _build_barn_loft(2)]
		"shed":
			return [_build_shed(0), _build_shed(1), _build_shed(2)]
		"hay":
			return [_build_hay(0), _build_hay(1), _build_hay(2)]
		"fountain":
			return [_build_fountain(0), _build_fountain(1), _build_fountain(2)]
		"well_canopy":
			return [_build_well_canopy(0), _build_well_canopy(1), _build_well_canopy(2)]
		"market_stall":
			return [_build_market_stall(0), _build_market_stall(1), _build_market_stall(2)]
		"boat_shed":
			return [_build_boat_shed(0), _build_boat_shed(1), _build_boat_shed(2)]
		"woodpile_rack":
			return [_build_woodpile_rack(0), _build_woodpile_rack(1), _build_woodpile_rack(2)]
	return [_build_house(0), _build_house(1), _build_house(2)]


## Меши мелких повторяющихся деталей для MultiMesh (ящики с цветами, скамья, поленья, фонарь, прясло, мостки).
static func build_detail_meshes() -> Dictionary:
	var flower := SurfaceTool.new()
	flower.begin(Mesh.PRIMITIVE_TRIANGLES)
	_box(flower, Vector3(0.76, 0.16, 0.22), Vector3(0, 0.08, 0), Basis.IDENTITY, CELL_LEAF)
	_box(flower, Vector3(0.68, 0.13, 0.18), Vector3(0, 0.20, 0), Basis.IDENTITY, CELL_FLOWER_A)
	flower.index()

	var flower_b := SurfaceTool.new()
	flower_b.begin(Mesh.PRIMITIVE_TRIANGLES)
	_box(flower_b, Vector3(0.76, 0.16, 0.22), Vector3(0, 0.08, 0), Basis.IDENTITY, CELL_LEAF)
	_box(flower_b, Vector3(0.68, 0.13, 0.18), Vector3(0, 0.20, 0), Basis.IDENTITY, CELL_FLOWER_B)
	flower_b.index()

	var bench := SurfaceTool.new()
	bench.begin(Mesh.PRIMITIVE_TRIANGLES)
	_box(bench, Vector3(1.8, 0.16, 0.48), Vector3(0, 0.50, 0), Basis.IDENTITY, CELL_TIMBER)
	for leg: float in [-0.65, 0.65]:
		_box(bench, Vector3(0.15, 0.45, 0.40), Vector3(leg, 0.225, 0), Basis.IDENTITY, CELL_TIMBER)
	bench.index()

	var logs := SurfaceTool.new()
	logs.begin(Mesh.PRIMITIVE_TRIANGLES)
	for k in 3:
		var xf := Transform3D(Basis.from_euler(Vector3(0, k * PI / 3.0, PI / 2.0)), Vector3(0, 0.10, 0))
		_cyl(logs, 0.10, 0.10, 1.2, 5, xf.origin, xf.basis, CELL_DARK_WOOD)
	logs.index()

	var lantern := SurfaceTool.new()
	lantern.begin(Mesh.PRIMITIVE_TRIANGLES)
	var stone_c := Color.html("#7c7567")
	var wood_c := Color.html("#5f3e24")
	var dark_c := Color.html("#3c2b1d")
	_box(lantern, Vector3(0.32, 0.42, 0.32), Vector3(0, 0.11, 0), Basis.IDENTITY, CELL_STONE, stone_c)
	_box(lantern, Vector3(0.13, 2.35, 0.13), Vector3(0, 1.25, 0), Basis.IDENTITY, CELL_TIMBER, wood_c)
	_box(lantern, Vector3(0.11, 0.11, 0.62), Vector3(0, 2.34, 0.22), Basis.IDENTITY, CELL_DARK_WOOD, dark_c)
	_box(lantern, Vector3(0.28, 0.36, 0.28), Vector3(0, 2.02, 0.46), Basis.IDENTITY, CELL_WINDOW, Color.WHITE)
	_box(lantern, Vector3(0.36, 0.09, 0.36), Vector3(0, 2.24, 0.46), Basis.IDENTITY, CELL_DARK_WOOD, dark_c)
	lantern.index()

	var fence := SurfaceTool.new()
	fence.begin(Mesh.PRIMITIVE_TRIANGLES)
	for sx: float in [-0.98, 0.98]:
		_box(fence, Vector3(0.12, 1.05, 0.12), Vector3(sx, 0.38, 0), Basis.IDENTITY, CELL_TIMBER)
	for ry: float in [0.42, 0.72]:
		_box(fence, Vector3(2.24, 0.10, 0.07), Vector3(0, ry, 0), Basis.IDENTITY, CELL_TIMBER)
	fence.index()

	var jetty := SurfaceTool.new()
	jetty.begin(Mesh.PRIMITIVE_TRIANGLES)
	for px: float in [-0.75, 0.75]:
		for pz: float in [-1.25, 0.0, 1.25]:
			_box(jetty, Vector3(0.16, 1.35, 0.16), Vector3(px, -0.20, pz), Basis.IDENTITY, CELL_TIMBER)
		_box(jetty, Vector3(0.14, 0.14, 3.25), Vector3(px, 0.32, 0), Basis.IDENTITY, CELL_TIMBER)
	for idx in 6:
		_box(jetty, Vector3(1.85, 0.09, 0.44), Vector3(0, 0.43, -1.30 + idx * 0.52), Basis.IDENTITY, CELL_TIMBER)
	_box(jetty, Vector3(0.20, 0.45, 0.20), Vector3(0.72, 0.65, 1.30), Basis.IDENTITY, CELL_DARK_WOOD)
	jetty.index()

	return {
		flower_box = flower.commit(),
		flower_box_b = flower_b.commit(),
		bench = bench.commit(),
		fire_logs = logs.commit(),
		lantern_post = lantern.commit(),
		fence_section = fence.commit(),
		wooden_jetty = jetty.commit(),
	}


## Палитра ячеек общего атласа для сооружений и памятников вне поселений.
static func site_tints(kind: String, v: int) -> Dictionary:
	var stone_palette := [Color.html("#6b6a5c"), Color.html("#585749"), Color.html("#5d6b48")]
	var stone_c := Color.html("#736d60")
	if kind in ["obelisk", "stone"]:
		stone_c = Color.html("#9a958a")
	elif kind in ["ruin", "keep"]:
		stone_c = stone_palette[posmod(v, stone_palette.size())]
	elif kind == "peak_cairn":
		stone_c = Color.html("#8f8880")
	return {
		CELL_STONE: stone_c,
		CELL_PLASTER: Color.html("#dfd8c6"),
		CELL_TIMBER: Color.html("#755337"),
		CELL_DARK_WOOD: Color.html("#5a3d24"),
		CELL_ROOF: _hex(ROOF_TINTS[posmod(v, ROOF_TINTS.size())]),
		CELL_SHUTTER: Color.html("#4a5e44"),
		CELL_METAL: Color.html("#62666b"),
		CELL_FLOWER_A: Color.WHITE,
		CELL_WINDOW: Color.WHITE,
	}


## Три уровня детализации [LOD0, LOD1, LOD2] на общем атласе для вершин и сооружений StageSites.
static func build_site_lods() -> Dictionary:
	var out := {}
	for key: String in ["shelter", "tower", "obelisk", "ruin", "keep", "stone", "peak_cairn"]:
		var lods: Array[ArrayMesh] = []
		for level in 3:
			lods.append(_build_site_mesh(key, level))
		out[key] = lods
	return out


static func _build_site_mesh(kind: String, level: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	match kind:
		"shelter":
			_box(st, Vector3(3.10, 0.55, 3.10), Vector3(0, -0.225, 0), Basis.IDENTITY, CELL_STONE)
			_box(st, Vector3(3.00, 2.00, 3.00), Vector3(0, 1.00, 0), Basis.IDENTITY, CELL_STONE)
			_cyl(st, 0.0, 2.38, 1.38, 4, Vector3(0, 2.69, 0), Basis(Vector3.UP, PI / 4.0), CELL_ROOF)
			if level <= 1:
				_box(st, Vector3(0.92, 1.75, 0.12), Vector3(0, 0.88, 1.52), Basis.IDENTITY, CELL_DARK_WOOD)
				_box(st, Vector3(0.28, 0.42, 0.16), Vector3(0.85, 1.55, 1.52), Basis.IDENTITY, CELL_WINDOW)
			if level == 0:
				_box(st, Vector3(1.12, 0.16, 0.55), Vector3(0, 0.06, 1.72), Basis.IDENTITY, CELL_STONE)
				_box(st, Vector3(1.10, 0.12, 0.14), Vector3(0, 1.78, 1.53), Basis.IDENTITY, CELL_TIMBER)
				_box(st, Vector3(0.45, 0.70, 0.45), Vector3(-0.75, 2.65, -0.75), Basis.IDENTITY, CELL_STONE)
		"tower":
			if level == 2:
				_box(st, Vector3(1.45, 6.40, 1.45), Vector3(0, 3.10, 0), Basis.IDENTITY, CELL_TIMBER)
				_box(st, Vector3(2.80, 0.25, 2.80), Vector3(0, 6.40, 0), Basis.IDENTITY, CELL_TIMBER)
				_cyl(st, 0.0, 2.20, 1.65, 4, Vector3(0, 8.50, 0), Basis(Vector3.UP, PI / 4.0), CELL_ROOF)
			else:
				for cx: float in [-1.0, 1.0]:
					for cz: float in [-1.0, 1.0]:
						if level == 0:
							_box(st, Vector3(0.46, 0.55, 0.46), Vector3(cx, -0.10, cz), Basis.IDENTITY, CELL_STONE)
						_box(st, Vector3(0.25, 7.00, 0.25), Vector3(cx, 3.20, cz), Basis.IDENTITY, CELL_TIMBER)
				_box(st, Vector3(2.80, 0.20, 2.80), Vector3(0, 6.40, 0), Basis.IDENTITY, CELL_TIMBER)
				for k in 4:
					var b := Basis(Vector3.UP, k * PI / 2.0)
					_box(st, Vector3(2.80, 0.12, 0.10), b * Vector3(0, 7.20, 1.36), b, CELL_TIMBER)
				_cyl(st, 0.0, 2.25, 1.65, 4, Vector3(0, 8.50, 0), Basis(Vector3.UP, PI / 4.0), CELL_ROOF)
				_box(st, Vector3(0.10, 2.20, 0.10), Vector3(0, 9.95, 0), Basis.IDENTITY, CELL_DARK_WOOD)
				_box(st, Vector3(1.00, 0.60, 0.06), Vector3(0.50, 10.60, 0), Basis.IDENTITY, CELL_FLOWER_A)
				if level == 0:
					for sx: float in [-0.95, 0.95]:
						_box(st, Vector3(0.10, 0.90, 0.10), Vector3(sx, 6.85, 1.35), Basis.IDENTITY, CELL_DARK_WOOD)
						_box(st, Vector3(0.10, 0.90, 0.10), Vector3(sx, 6.85, -1.35), Basis.IDENTITY, CELL_DARK_WOOD)
					_box(st, Vector3(2.20, 0.12, 0.12), Vector3(0, 3.20, 1.0), Basis(Vector3.BACK, 0.55), CELL_TIMBER)
					_box(st, Vector3(2.20, 0.12, 0.12), Vector3(0, 3.20, -1.0), Basis(Vector3.BACK, -0.55), CELL_TIMBER)
		"obelisk":
			if level == 2:
				_box(st, Vector3(1.40, 1.00, 1.40), Vector3(0, 0.10, 0), Basis.IDENTITY, CELL_STONE)
				_box(st, Vector3(0.75, 4.70, 0.75), Vector3(0, 2.95, 0), Basis.IDENTITY, CELL_STONE)
				_cyl(st, 0.0, 0.54, 0.72, 4, Vector3(0, 5.65, 0), Basis(Vector3.UP, PI / 4.0), CELL_STONE)
			else:
				_box(st, Vector3(1.60, 1.15, 1.60), Vector3(0, 0.05, 0), Basis.IDENTITY, CELL_STONE)
				_box(st, Vector3(0.72, 4.60, 0.72), Vector3(0, 2.90, 0), Basis.IDENTITY, CELL_STONE)
				_cyl(st, 0.0, 0.52, 0.75, 4, Vector3(0, 5.56, 0), Basis(Vector3.UP, PI / 4.0), CELL_STONE)
				if level == 0:
					_box(st, Vector3(1.15, 0.35, 1.15), Vector3(0, 0.72, 0), Basis.IDENTITY, CELL_STONE)
		"ruin":
			if level == 2:
				_box(st, Vector3(3.40, 2.10, 3.40), Vector3(0, 0.65, 0), Basis.IDENTITY, CELL_STONE)
			else:
				_box(st, Vector3(3.40, 2.60, 0.48), Vector3(0, 0.90, -1.50), Basis.IDENTITY, CELL_STONE)
				_box(st, Vector3(0.48, 1.75, 3.40), Vector3(-1.50, 0.48, 0), Basis.IDENTITY, CELL_STONE)
				_box(st, Vector3(0.48, 1.15, 1.80), Vector3(1.50, 0.18, -0.80), Basis.IDENTITY, CELL_STONE)
				if level == 0:
					_box(st, Vector3(0.72, 0.55, 0.92), Vector3(1.20, 0.12, 1.40), Basis(Vector3.UP, 0.40), CELL_STONE)
					_box(st, Vector3(0.80, 0.42, 0.48), Vector3(-0.80, 2.38, -1.50), Basis.IDENTITY, CELL_STONE)
					_box(st, Vector3(0.75, 0.38, 0.48), Vector3(0.85, 2.36, -1.50), Basis.IDENTITY, CELL_STONE)
		"keep":
			var seg := 8 if level == 0 else (6 if level == 1 else 5)
			_cyl(st, 1.50, 1.65, 6.40, seg, Vector3(0, 2.80, 0), Basis.IDENTITY, CELL_STONE)
			if level == 0:
				_cyl(st, 1.65, 1.65, 0.38, 8, Vector3(0, 5.90, 0), Basis.IDENTITY, CELL_STONE)
				for k in 4:
					var b := Basis(Vector3.UP, k * PI * 0.5)
					_box(st, Vector3(0.55, 0.42, 0.32), b * Vector3(0, 6.26, 1.42), b, CELL_STONE)
		"stone":
			_box(st, Vector3(0.65, 2.40, 0.45), Vector3(0, 0.70, 0), Basis.IDENTITY, CELL_STONE)
			if level == 0:
				_box(st, Vector3(0.82, 0.45, 0.65), Vector3(0, -0.22, 0), Basis.IDENTITY, CELL_STONE)
		"peak_cairn":
			var seg := 5 if level <= 1 else 4
			for rh: Vector2 in [Vector2(0.90, 0.50), Vector2(0.65, 1.30), Vector2(0.45, 1.95)]:
				_cyl(st, rh.x * 0.85, rh.x, rh.x * 1.15, seg, Vector3(0, rh.y, 0), Basis.IDENTITY, CELL_STONE)
			if level <= 1:
				_box(st, Vector3(0.10, 2.20, 0.10), Vector3(0, 3.20, 0), Basis.IDENTITY, CELL_DARK_WOOD)
				_box(st, Vector3(1.00, 0.60, 0.06), Vector3(0.50, 3.90, 0), Basis.IDENTITY, CELL_FLOWER_A)
	st.index()
	return st.commit()


## Доборный каменный цоколь под склоны глубже -0.45 м (в той же системе координат, что и модель).
static func build_extra_plinth(half: Vector2, from_y: float, to_y: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var h := maxf(0.1, from_y - to_y)
	_box(st, Vector3(half.x * 2.0 + 0.10, h, half.y * 2.0 + 0.10), Vector3(0, (from_y + to_y) * 0.5, 0), Basis.IDENTITY, CELL_STONE)
	st.index()
	return st.commit()


# ---------------- Валидация GLB ----------------

static func validate_glb_file(id: String, path: String, expected_half: Vector2, category: String) -> String:
	var abs_path := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(abs_path):
		return "%s: файл не найден (%s)" % [id, path]
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(abs_path, state)
	if err != OK:
		return "%s: ошибка чтения GLB (%s)" % [id, error_string(err)]
	var scene := doc.generate_scene(state)
	if scene == null:
		return "%s: GLB не содержит сцены" % id
	var reason := validate_glb_scene(id, scene, expected_half, category)
	scene.free()
	return reason


static func extract_lods(scene: Node) -> Array[Mesh]:
	var out: Array[Mesh] = []
	for level in 3:
		var node := _find_mesh_node(scene, "LOD%d" % level)
		if node != null and node.mesh != null:
			out.append(node.mesh)
	return out


static func validate_glb_scene(id: String, scene: Node, expected_half: Vector2, category: String) -> String:
	var meshes: Array[Mesh] = []
	var tris: Array[int] = []
	for level in 3:
		var node := _find_mesh_node(scene, "LOD%d" % level)
		if node == null or node.mesh == null:
			return "%s: отсутствует узел или меш LOD%d" % [id, level]
		var m := node.mesh
		if m.get_surface_count() < 1 or m.get_surface_count() > 2:
			return "%s: у LOD%d %d поверхностей (допустимо 1..2)" % [id, level, m.get_surface_count()]
		meshes.append(m)
		tris.append(_mesh_tris(m))

	var max_lod0 := 4000 if category == "landmark" else 2000
	if tris[0] <= 0 or tris[0] > max_lod0:
		return "%s: LOD0 имеет %d треугольников (лимит <= %d)" % [id, tris[0], max_lod0]
	var min_lod1 := 300 if category == "home" else 24
	if tris[1] < min_lod1 or tris[1] > 600:
		return "%s: LOD1 имеет %d треугольников (ожидается %d..600)" % [id, tris[1], min_lod1]
	var min_lod2 := 30 if category in ["home", "outbuilding"] else 16
	if tris[2] < min_lod2 or tris[2] > 80:
		return "%s: LOD2 имеет %d треугольников (ожидается %d..80)" % [id, tris[2], min_lod2]
	if not (tris[0] > tris[1] and tris[1] > tris[2]):
		return "%s: треугольники не убывают по уровням (%d / %d / %d)" % [id, tris[0], tris[1], tris[2]]

	var aabb := meshes[0].get_aabb()
	if aabb.position.y > -0.35 or aabb.position.y < -0.75:
		return "%s: цоколь заглублён на %.2f м (ожидается -0.50 м)" % [id, aabb.position.y]
	if aabb.end.y < 1.0:
		return "%s: верх модели ниже 1.0 м (%.2f)" % [id, aabb.end.y]
	var center := aabb.get_center()
	if absf(center.x) > 0.45 or absf(center.z) > 0.55:
		return "%s: опора смещена от центра пола (центр X=%.2f, Z=%.2f)" % [id, center.x, center.z]

	var foot := _footprint_at_base(meshes[0])
	if not foot.has_area():
		return "%s: не найдено основание цоколя на глубине -0.25 м" % id
	var half_x := foot.size.x * 0.5
	var half_z := foot.size.y * 0.5
	if absf(half_x - expected_half.x) > 0.30 or absf(half_z - expected_half.y) > 0.30:
		return "%s: габарит цоколя (%.2f×%.2f) не совпадает с типоразмером (%.2f×%.2f)" % [id, half_x, half_z, expected_half.x, expected_half.y]
	return ""


static func _find_mesh_node(node: Node, target: String) -> MeshInstance3D:
	if node is MeshInstance3D and node.name == target:
		return node
	for child in node.get_children():
		var found := _find_mesh_node(child, target)
		if found != null:
			return found
	return null


static func _mesh_tris(mesh: Mesh) -> int:
	var total := 0
	for s in mesh.get_surface_count():
		var arr := mesh.surface_get_arrays(s)
		var idx: Variant = arr[Mesh.ARRAY_INDEX]
		if idx is PackedInt32Array and not idx.is_empty():
			total += idx.size() / 3
		elif arr[Mesh.ARRAY_VERTEX] is PackedVector3Array:
			total += (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	return total


static func _footprint_at_base(mesh: Mesh) -> Rect2:
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	var found := false
	for s in mesh.get_surface_count():
		var verts: PackedVector3Array = mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
		for p in verts:
			if p.y <= -0.25:
				found = true
				min_x = minf(min_x, p.x)
				max_x = maxf(max_x, p.x)
				min_z = minf(min_z, p.z)
				max_z = maxf(max_z, p.z)
	return Rect2(min_x, min_z, max_x - min_x, max_z - min_z) if found else Rect2()


# ---------------- Построение конкретных силуэтов ----------------

## Малый оштукатуренный дом: цоколь -0.5 м, фахверк/фронтон, козырёк крыльца у двери +Z, труба.
static func _build_house(level: int) -> ArrayMesh:
	var half := Vector2(1.6, 1.6)
	var wall_h := 2.5
	var pitch := 0.62
	var eave := 0.55
	var gable := half.x * tan(pitch)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	if level == 2:
		_box(st, Vector3(half.x * 2.0 + 0.1, 0.5, half.y * 2.0 + 0.1), Vector3(0, -0.25, 0), Basis.IDENTITY, CELL_STONE)
		_box(st, Vector3(half.x * 2.0, wall_h, half.y * 2.0), Vector3(0, wall_h * 0.5, 0), Basis.IDENTITY, CELL_PLASTER)
		_gable(st, half.x * 2.0, gable, half.y * 2.0, Vector3(0, wall_h, 0), CELL_TIMBER)
		_roof_slopes(st, half, wall_h, pitch, eave, 0.22, false)
		_box(st, Vector3(1.4, 0.16, 0.7), Vector3(0, 2.05, half.y + 0.35), Basis.IDENTITY, CELL_ROOF)
		st.index()
		return st.commit()

	_box(st, Vector3(half.x * 2.0 + 0.1, 0.5, half.y * 2.0 + 0.1), Vector3(0, -0.25, 0), Basis.IDENTITY, CELL_STONE)
	_box(st, Vector3(half.x * 2.0, wall_h, half.y * 2.0), Vector3(0, wall_h * 0.5, 0), Basis.IDENTITY, CELL_PLASTER)
	_gable(st, half.x * 2.0, gable, half.y * 2.0, Vector3(0, wall_h, 0), CELL_TIMBER)
	_roof_slopes(st, half, wall_h, pitch, eave, 0.22, true)

	# Дверь и крыльцо-козырёк в +Z (отличительный силуэт малого дома)
	_box(st, Vector3(0.95, 1.85, 0.10), Vector3(0, 0.925, half.y + 0.03), Basis.IDENTITY, CELL_DARK_WOOD)
	_box(st, Vector3(1.15, 0.18, 0.72), Vector3(0, 0.04, half.y + 0.30), Basis.IDENTITY, CELL_STONE)
	var porch_b := Basis(Vector3.RIGHT, 0.24)
	_box(st, Vector3(1.5, 0.12, 0.85), Vector3(0, 2.15, half.y + 0.38), porch_b, CELL_ROOF)
	for sx: float in [-0.62, 0.62]:
		_box(st, Vector3(0.11, 2.05, 0.11), Vector3(sx, 1.08, half.y + 0.68), Basis.IDENTITY, CELL_DARK_WOOD)
	# Труба
	_box(st, Vector3(0.50, 1.65, 0.50), Vector3(half.x * 0.45, wall_h + gable * 0.55 + 0.45, -half.y * 0.35), Basis.IDENTITY, CELL_CHIMNEY)

	# Окна: передние, боковые, заднее, чердачное
	_window(st, 0.0, Vector3(half.x * 0.62, 1.45, half.y), true)
	_window(st, 0.0, Vector3(-half.x * 0.62, 1.45, half.y), true)
	_window(st, PI / 2.0, Vector3(0.0, 1.45, half.x), true)
	_window(st, -PI / 2.0, Vector3(0.0, 1.45, half.x), true)
	_window(st, PI, Vector3(0.0, 1.45, half.y), true)
	_box(st, Vector3(0.42, 0.42, 0.08), Vector3(0, wall_h + gable * 0.36, half.y + 0.02), Basis.IDENTITY, CELL_WINDOW)

	if level == 0:
		# Угловые и карнизные балки + ободок трубы + наличник двери
		_box(st, Vector3(0.66, 0.14, 0.66), Vector3(half.x * 0.45, wall_h + gable * 0.55 + 1.28, -half.y * 0.35), Basis.IDENTITY, CELL_STONE)
		_box(st, Vector3(1.10, 0.12, 0.12), Vector3(0, 1.88, half.y + 0.04), Basis.IDENTITY, CELL_DARK_WOOD)
		for sx: float in [-1.0, 1.0]:
			_box(st, Vector3(0.12, wall_h, 0.12), Vector3(sx * (half.x - 0.02), wall_h * 0.5, half.y - 0.02), Basis.IDENTITY, CELL_DARK_WOOD)
			_box(st, Vector3(0.12, wall_h, 0.12), Vector3(sx * (half.x - 0.02), wall_h * 0.5, -half.y + 0.02), Basis.IDENTITY, CELL_DARK_WOOD)
	st.index()
	return st.commit()


## Лесной бревенчатый сруб с крутой крышей, выпусками брёвен и боковым дровяным навесом на -X.
static func _build_house_timber(level: int) -> ArrayMesh:
	var half := Vector2(1.6, 1.6)
	var base_h := 0.95
	var log_h := 1.65
	var wall_h := base_h + log_h
	var pitch := 0.78
	var eave := 0.50
	var gable := half.x * tan(pitch)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	if level == 2:
		_box(st, Vector3(half.x * 2.0 + 0.1, 0.5, half.y * 2.0 + 0.1), Vector3(0, -0.25, 0), Basis.IDENTITY, CELL_STONE)
		_box(st, Vector3(half.x * 2.0, wall_h, half.y * 2.0), Vector3(0, wall_h * 0.5, 0), Basis.IDENTITY, CELL_TIMBER)
		_gable(st, half.x * 2.0, gable, half.y * 2.0, Vector3(0, wall_h, 0), CELL_TIMBER)
		_roof_slopes(st, half, wall_h, pitch, eave, 0.22, false)
		_box(st, Vector3(0.55, 1.5, 2.2), Vector3(-half.x - 0.26, 0.85, 0), Basis.IDENTITY, CELL_ROOF)
		st.index()
		return st.commit()

	_box(st, Vector3(half.x * 2.0 + 0.1, 0.5 + base_h, half.y * 2.0 + 0.1), Vector3(0, (base_h - 0.5) * 0.5, 0), Basis.IDENTITY, CELL_STONE)
	_box(st, Vector3(half.x * 2.0, log_h, half.y * 2.0), Vector3(0, base_h + log_h * 0.5, 0), Basis.IDENTITY, CELL_TIMBER)
	_gable(st, half.x * 2.0, gable, half.y * 2.0, Vector3(0, wall_h, 0), CELL_TIMBER)
	_roof_slopes(st, half, wall_h, pitch, eave, 0.22, true)

	# Пристроенный боковой дровяной навес (-X) — меняет силуэт сбоку и спереди
	var lean_b := Basis(Vector3.BACK, 0.34)
	_box(st, Vector3(0.78, 0.12, 2.3), Vector3(-half.x - 0.34, 1.78, -0.1), lean_b, CELL_ROOF)
	_box(st, Vector3(0.52, 0.95, 1.9), Vector3(-half.x - 0.28, 0.48, -0.1), Basis.IDENTITY, CELL_LOGS_END)
	for sz: float in [-1.15, 0.95]:
		_box(st, Vector3(0.11, 1.65, 0.11), Vector3(-half.x - 0.60, 0.82, sz), Basis.IDENTITY, CELL_DARK_WOOD)

	# Дверь и крыльцо в +Z
	_box(st, Vector3(0.92, 1.85, 0.10), Vector3(-0.25, 0.925, half.y + 0.03), Basis.IDENTITY, CELL_DARK_WOOD)
	_box(st, Vector3(1.10, 0.18, 0.65), Vector3(-0.25, 0.04, half.y + 0.26), Basis.IDENTITY, CELL_STONE)
	_box(st, Vector3(0.48, 1.75, 0.48), Vector3(half.x * 0.48, wall_h + gable * 0.55 + 0.45, -half.y * 0.30), Basis.IDENTITY, CELL_CHIMNEY)

	# Окна с резными ставнями
	_window(st, 0.0, Vector3(half.x * 0.56, 1.62, half.y), true)
	_window(st, -PI / 2.0, Vector3(0.0, 1.62, half.x), true)
	_window(st, PI, Vector3(-0.4, 1.62, half.y), true)
	_window(st, PI, Vector3(0.5, 1.62, half.y), true)
	_box(st, Vector3(0.44, 0.48, 0.08), Vector3(0, wall_h + gable * 0.34, half.y + 0.02), Basis.IDENTITY, CELL_WINDOW)

	if level == 0:
		# Выпуски брёвен по углам и под свесами (охлупень)
		for sx: float in [-1.0, 1.0]:
			for sz: float in [-1.0, 1.0]:
				for row in 3:
					var ly := base_h + 0.25 + row * 0.55
					_box(st, Vector3(0.26, 0.16, 0.16), Vector3(sx * (half.x + 0.08), ly, sz * (half.y - 0.06)), Basis.IDENTITY, CELL_LOGS_END)
					_box(st, Vector3(0.16, 0.16, 0.26), Vector3(sx * (half.x - 0.06), ly + 0.08, sz * (half.y + 0.08)), Basis.IDENTITY, CELL_LOGS_END)
		_box(st, Vector3(0.24, 0.24, half.y * 2.0 + eave * 2.0 + 0.2), Vector3(0, wall_h + gable + 0.22, 0), Basis(Vector3.BACK, PI / 4.0), CELL_DARK_WOOD)
	st.index()
	return st.commit()


## Горное шале: широкий свес, каменный первый этаж, деревянный второй, балкон вдоль фасада +Z.
static func _build_chalet(level: int) -> ArrayMesh:
	var half := Vector2(2.2, 1.9)
	var h1 := 2.1
	var h2 := 2.2
	var wall_h := h1 + h2
	var pitch := 0.45
	var eave := 0.90
	var gable := half.x * tan(pitch)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	if level == 2:
		_box(st, Vector3(half.x * 2.0 + 0.1, 0.5, half.y * 2.0 + 0.1), Vector3(0, -0.25, 0), Basis.IDENTITY, CELL_STONE)
		_box(st, Vector3(half.x * 2.0, h1, half.y * 2.0), Vector3(0, h1 * 0.5, 0), Basis.IDENTITY, CELL_STONE)
		_box(st, Vector3(half.x * 2.0, h2, half.y * 2.0), Vector3(0, h1 + h2 * 0.5, 0), Basis.IDENTITY, CELL_TIMBER)
		_gable(st, half.x * 2.0, gable, half.y * 2.0, Vector3(0, wall_h, 0), CELL_TIMBER)
		_roof_slopes(st, half, wall_h, pitch, eave, 0.24, false)
		_box(st, Vector3(half.x * 2.0 + 0.3, 0.20, 0.95), Vector3(0, h1, half.y + 0.47), Basis.IDENTITY, CELL_TIMBER)
		st.index()
		return st.commit()

	_box(st, Vector3(half.x * 2.0 + 0.1, 0.5, half.y * 2.0 + 0.1), Vector3(0, -0.25, 0), Basis.IDENTITY, CELL_STONE)
	_box(st, Vector3(half.x * 2.0, h1, half.y * 2.0), Vector3(0, h1 * 0.5, 0), Basis.IDENTITY, CELL_STONE)
	_box(st, Vector3(half.x * 2.0, h2, half.y * 2.0), Vector3(0, h1 + h2 * 0.5, 0), Basis.IDENTITY, CELL_TIMBER)
	_gable(st, half.x * 2.0, gable, half.y * 2.0, Vector3(0, wall_h, 0), CELL_TIMBER)
	_roof_slopes(st, half, wall_h, pitch, eave, 0.24, true)

	# Балкон второго этажа
	var bw := half.x * 2.0 + 0.32
	_box(st, Vector3(bw, 0.12, 0.95), Vector3(0, h1, half.y + 0.47), Basis.IDENTITY, CELL_TIMBER)
	_box(st, Vector3(bw, 0.78, 0.08), Vector3(0, h1 + 0.45, half.y + 0.91), Basis.IDENTITY, CELL_RAIL)
	for sx: float in [-1.0, 1.0]:
		_box(st, Vector3(0.08, 0.78, 0.95), Vector3(sx * bw * 0.5, h1 + 0.45, half.y + 0.47), Basis.IDENTITY, CELL_RAIL)

	# Дверь и труба
	_box(st, Vector3(0.95, 1.85, 0.10), Vector3(-half.x * 0.45, 0.925, half.y + 0.03), Basis.IDENTITY, CELL_DARK_WOOD)
	_box(st, Vector3(1.15, 0.18, 0.65), Vector3(-half.x * 0.45, 0.04, half.y + 0.26), Basis.IDENTITY, CELL_STONE)
	_box(st, Vector3(0.55, 1.70, 0.55), Vector3(half.x * 0.45, wall_h + gable * 0.55 + 0.45, -half.y * 0.35), Basis.IDENTITY, CELL_CHIMNEY)

	# Окна
	_window(st, 0.0, Vector3(half.x * 0.50, 1.38, half.y), true)
	_window(st, 0.0, Vector3(-half.x * 0.50, h1 + h2 * 0.55, half.y), true)
	_window(st, 0.0, Vector3(half.x * 0.50, h1 + h2 * 0.55, half.y), true)
	_window(st, PI / 2.0, Vector3(-half.y * 0.45, h1 + h2 * 0.55, half.x), true)
	_window(st, -PI / 2.0, Vector3(half.y * 0.45, h1 + h2 * 0.55, half.x), true)
	_window(st, PI, Vector3(0, h1 + h2 * 0.55, half.y), true)
	_box(st, Vector3(0.46, 0.46, 0.08), Vector3(0, wall_h + gable * 0.36, half.y + 0.02), Basis.IDENTITY, CELL_WINDOW)

	if level == 0:
		# Консоли под балконом и прогоны под широкими свесами крыши
		for bx: float in [-bw * 0.42, -bw * 0.14, bw * 0.14, bw * 0.42]:
			_box(st, Vector3(0.14, 0.18, 0.85), Vector3(bx, h1 - 0.14, half.y + 0.42), Basis.IDENTITY, CELL_DARK_WOOD)
		for sx: float in [-1.0, 1.0]:
			_box(st, Vector3(0.16, 0.18, half.y * 2.0 + eave * 2.0), Vector3(sx * (half.x + 0.45), wall_h - 0.08, 0), Basis.IDENTITY, CELL_DARK_WOOD)
		_window(st, PI / 2.0, Vector3(half.y * 0.45, 1.38, half.x), true)
		_window(st, -PI / 2.0, Vector3(-half.y * 0.45, 1.38, half.x), true)
		_box(st, Vector3(0.72, 0.14, 0.72), Vector3(half.x * 0.45, wall_h + gable * 0.55 + 1.30, -half.y * 0.35), Basis.IDENTITY, CELL_STONE)
	st.index()
	return st.commit()


## Высокий двухэтажный дом (доминанта у площади центра): высокий крутой щипец, арка/крыльцо, башенка-труба.
static func _build_tall(level: int) -> ArrayMesh:
	var half := Vector2(1.9, 1.9)
	var h1 := 2.4
	var h2 := 2.3
	var wall_h := h1 + h2
	var pitch := 0.72
	var eave := 0.50
	var gable := half.x * tan(pitch)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	if level == 2:
		_box(st, Vector3(half.x * 2.0 + 0.1, 0.5, half.y * 2.0 + 0.1), Vector3(0, -0.25, 0), Basis.IDENTITY, CELL_STONE)
		_box(st, Vector3(half.x * 2.0, wall_h, half.y * 2.0), Vector3(0, wall_h * 0.5, 0), Basis.IDENTITY, CELL_PLASTER)
		_gable(st, half.x * 2.0, gable, half.y * 2.0, Vector3(0, wall_h, 0), CELL_PLASTER)
		_roof_slopes(st, half, wall_h, pitch, eave, 0.24, false)
		_box(st, Vector3(0.55, 1.6, 0.55), Vector3(half.x * 0.45, wall_h + gable * 0.65 + 0.4, -half.y * 0.35), Basis.IDENTITY, CELL_CHIMNEY)
		st.index()
		return st.commit()

	_box(st, Vector3(half.x * 2.0 + 0.1, 0.5, half.y * 2.0 + 0.1), Vector3(0, -0.25, 0), Basis.IDENTITY, CELL_STONE)
	_box(st, Vector3(half.x * 2.0, h1, half.y * 2.0), Vector3(0, h1 * 0.5, 0), Basis.IDENTITY, CELL_PLASTER)
	_box(st, Vector3(half.x * 2.0, h2, half.y * 2.0), Vector3(0, h1 + h2 * 0.5, 0), Basis.IDENTITY, CELL_PLASTER)
	_gable(st, half.x * 2.0, gable, half.y * 2.0, Vector3(0, wall_h, 0), CELL_PLASTER)
	_roof_slopes(st, half, wall_h, pitch, eave, 0.24, true)

	# Дверь и выступающий фронтонный козырёк
	_box(st, Vector3(1.05, 1.95, 0.10), Vector3(-half.x * 0.42, 0.975, half.y + 0.03), Basis.IDENTITY, CELL_DARK_WOOD)
	_box(st, Vector3(1.25, 0.20, 0.72), Vector3(-half.x * 0.42, 0.05, half.y + 0.28), Basis.IDENTITY, CELL_STONE)
	_box(st, Vector3(1.55, 0.14, 0.78), Vector3(-half.x * 0.42, 2.25, half.y + 0.36), Basis(Vector3.RIGHT, 0.28), CELL_ROOF)
	_box(st, Vector3(0.55, 1.75, 0.55), Vector3(half.x * 0.45, wall_h + gable * 0.55 + 0.50, -half.y * 0.35), Basis.IDENTITY, CELL_CHIMNEY)

	# Окна
	_window(st, 0.0, Vector3(half.x * 0.48, 1.45, half.y), true)
	_window(st, 0.0, Vector3(-half.x * 0.48, h1 + h2 * 0.55, half.y), true)
	_window(st, 0.0, Vector3(half.x * 0.48, h1 + h2 * 0.55, half.y), true)
	_window(st, PI / 2.0, Vector3(-half.y * 0.45, 1.45, half.x), true)
	_window(st, -PI / 2.0, Vector3(half.y * 0.45, 1.45, half.x), true)
	_window(st, PI / 2.0, Vector3(half.y * 0.45, h1 + h2 * 0.55, half.x), true)
	_window(st, PI, Vector3(0.0, h1 + h2 * 0.55, half.y), true)
	_box(st, Vector3(0.48, 0.52, 0.08), Vector3(0, wall_h + gable * 0.36, half.y + 0.02), Basis.IDENTITY, CELL_WINDOW)

	if level == 0:
		# Пояс между этажами, фахверковые стойки щипца, ободок трубы
		_box(st, Vector3(half.x * 2.0 + 0.14, 0.16, half.y * 2.0 + 0.14), Vector3(0, h1, 0), Basis.IDENTITY, CELL_DARK_WOOD)
		_box(st, Vector3(0.70, 0.14, 0.70), Vector3(half.x * 0.45, wall_h + gable * 0.55 + 1.35, -half.y * 0.35), Basis.IDENTITY, CELL_STONE)
		_window(st, -PI / 2.0, Vector3(-half.y * 0.45, h1 + h2 * 0.55, half.x), true)
		_window(st, PI, Vector3(0.0, 1.45, half.y), true)
		for sx: float in [-0.65, 0.65]:
			_box(st, Vector3(0.12, gable * 0.65, 0.10), Vector3(sx, wall_h + gable * 0.32, half.y + 0.01), Basis.IDENTITY, CELL_DARK_WOOD)
	st.index()
	return st.commit()


## Закрытый сарай: каменный низ, деревянный верх, большие ворота, люк сеновала.
static func _build_barn(level: int) -> ArrayMesh:
	var half := Vector2(2.0, 1.5)
	var gable := half.x * tan(0.50)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	if level == 2:
		_box(st, Vector3(half.x * 2.0 + 0.1, 0.5, half.y * 2.0 + 0.1), Vector3(0, -0.25, 0), Basis.IDENTITY, CELL_STONE)
		_box(st, Vector3(half.x * 2.0, 2.8, half.y * 2.0), Vector3(0, 1.4, 0), Basis.IDENTITY, CELL_TIMBER)
		_gable(st, half.x * 2.0, gable, half.y * 2.0, Vector3(0, 2.8, 0), CELL_TIMBER)
		_roof_slopes(st, half, 2.8, 0.50, 0.60, 0.22, false)
		st.index()
		return st.commit()

	_box(st, Vector3(half.x * 2.0 + 0.1, 1.3, half.y * 2.0 + 0.1), Vector3(0, 0.15, 0), Basis.IDENTITY, CELL_STONE)
	_box(st, Vector3(half.x * 2.0, 2.0, half.y * 2.0), Vector3(0, 1.8, 0), Basis.IDENTITY, CELL_TIMBER)
	_gable(st, half.x * 2.0, gable, half.y * 2.0, Vector3(0, 2.8, 0), CELL_TIMBER)
	_roof_slopes(st, half, 2.8, 0.50, 0.60, 0.22, true)
	_box(st, Vector3(1.6, 2.0, 0.10), Vector3(0, 1.0, half.y + 0.03), Basis.IDENTITY, CELL_DARK_WOOD)
	_box(st, Vector3(0.9, 0.65, 0.08), Vector3(0, 3.1, half.y + 0.03), Basis.IDENTITY, CELL_DARK_WOOD)

	if level == 0:
		# Рама ворот и боковые стойки
		_box(st, Vector3(1.8, 0.12, 0.12), Vector3(0, 2.02, half.y + 0.04), Basis.IDENTITY, CELL_RAIL)
		for sx: float in [-0.84, 0.84]:
			_box(st, Vector3(0.12, 2.0, 0.12), Vector3(sx, 1.0, half.y + 0.04), Basis.IDENTITY, CELL_RAIL)
		for sx: float in [-1.0, 1.0]:
			_box(st, Vector3(0.12, 2.0, 0.12), Vector3(sx * (half.x - 0.04), 1.8, half.y - 0.04), Basis.IDENTITY, CELL_RAIL)
			_box(st, Vector3(0.12, 2.0, 0.12), Vector3(sx * (half.x - 0.04), 1.8, -half.y + 0.04), Basis.IDENTITY, CELL_RAIL)
	st.index()
	return st.commit()


## Открытый дровяной навес.
static func _build_shed(level: int) -> ArrayMesh:
	var half := Vector2(1.1, 0.75)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	_box(st, Vector3(half.x * 2.0, 0.5, half.y * 2.0), Vector3(0, -0.25, 0), Basis.IDENTITY, CELL_STONE)
	_box(st, Vector3(half.x * 2.0, 1.9, 0.15), Vector3(0, 0.95, -half.y + 0.08), Basis.IDENTITY, CELL_TIMBER)
	_box(st, Vector3(half.x * 2.0 - 0.3, 1.25, half.y * 1.5), Vector3(0, 0.625, 0.05), Basis.IDENTITY, CELL_LOGS_END)
	var lean := Basis(Vector3.RIGHT, 0.28)
	_box(st, Vector3(half.x * 2.0 + 0.5, 0.14, half.y * 2.0 + 0.6), Vector3(0, 1.95, 0.05), lean, CELL_ROOF)
	if level <= 1:
		for sx: float in [-1.0, 1.0]:
			_box(st, Vector3(0.12, 1.7, half.y * 2.0), Vector3(sx * (half.x - 0.06), 0.85, 0), Basis.IDENTITY, CELL_TIMBER)
			_box(st, Vector3(0.12, 1.8, 0.12), Vector3(sx * (half.x - 0.08), 0.9, half.y - 0.08), Basis.IDENTITY, CELL_DARK_WOOD)
	if level == 0:
		for rx: float in [-0.55, 0.0, 0.55]:
			_box(st, Vector3(0.10, 0.10, half.y * 2.0 + 0.5), Vector3(rx, 1.85, 0.05), lean, CELL_DARK_WOOD)
	st.index()
	return st.commit()


## Сеновал / стог на низкой подкладке.
static func _build_hay(level: int) -> ArrayMesh:
	var seg := 8 if level == 0 else (6 if level == 1 else 5)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_box(st, Vector3(1.8, 0.5, 1.8), Vector3(0, -0.25, 0), Basis.IDENTITY, CELL_STONE)
	_cyl(st, 0.75, 0.90, 1.3, seg, Vector3(0, 0.65, 0), Basis.IDENTITY, CELL_STRAW)
	_cyl(st, 0.0, 0.75, 0.7, seg, Vector3(0, 1.65, 0), Basis.IDENTITY, CELL_STRAW)
	if level == 0:
		_cyl(st, 0.05, 0.05, 2.4, 5, Vector3(0, 1.2, 0), Basis.IDENTITY, CELL_DARK_WOOD)
	st.index()
	return st.commit()


## Колодец-корыто с водой и жёлобом.
static func _build_fountain(level: int) -> ArrayMesh:
	var half := Vector2(1.0, 0.45)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_box(st, Vector3(half.x * 2.0, 1.2, half.y * 2.0), Vector3(0, 0.10, 0), Basis.IDENTITY, CELL_STONE)
	_box(st, Vector3(half.x * 2.0 - 0.2, 0.06, half.y * 2.0 - 0.2), Vector3(0, 0.71, 0), Basis.IDENTITY, CELL_WATER)
	_box(st, Vector3(0.30, 1.5, 0.30), Vector3(-half.x + 0.15, 0.75, 0), Basis.IDENTITY, CELL_TIMBER)
	if level <= 1:
		_box(st, Vector3(0.36, 0.08, 0.08), Vector3(-half.x + 0.45, 1.25, 0), Basis.IDENTITY, CELL_METAL)
	if level == 0:
		_box(st, Vector3(0.42, 0.12, 0.42), Vector3(-half.x + 0.15, 1.54, 0), Basis.IDENTITY, CELL_STONE)
		_box(st, Vector3(half.x * 2.0 + 0.08, 0.10, half.y * 2.0 + 0.08), Vector3(0, 0.68, 0), Basis.IDENTITY, CELL_STONE)
	st.index()
	return st.commit()


## Малый жилой дом с боковой пристройкой на +X под односкатной кровлей и высокой трубой на -X.
static func _build_house_wing(level: int) -> ArrayMesh:
	var half := Vector2(1.6, 1.6)
	var wall_h := 2.45
	var pitch := 0.60
	var eave := 0.50
	var gable := half.x * tan(pitch)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	if level == 2:
		_box(st, Vector3(half.x * 2.0 + 0.1, 0.5, half.y * 2.0 + 0.1), Vector3(0, -0.25, 0), Basis.IDENTITY, CELL_STONE)
		_box(st, Vector3(half.x * 2.0, wall_h, half.y * 2.0), Vector3(0, wall_h * 0.5, 0), Basis.IDENTITY, CELL_PLASTER)
		_gable(st, half.x * 2.0, gable, half.y * 2.0, Vector3(0, wall_h, 0), CELL_PLASTER)
		_roof_slopes(st, half, wall_h, pitch, eave, 0.22, false)
		_box(st, Vector3(0.88, 1.95, 2.2), Vector3(half.x + 0.44, 0.92, -0.1), Basis.IDENTITY, CELL_TIMBER)
		st.index()
		return st.commit()

	_box(st, Vector3(half.x * 2.0 + 0.1, 0.5, half.y * 2.0 + 0.1), Vector3(0, -0.25, 0), Basis.IDENTITY, CELL_STONE)
	_box(st, Vector3(half.x * 2.0, wall_h, half.y * 2.0), Vector3(0, wall_h * 0.5, 0), Basis.IDENTITY, CELL_PLASTER)
	_gable(st, half.x * 2.0, gable, half.y * 2.0, Vector3(0, wall_h, 0), CELL_TIMBER)
	_roof_slopes(st, half, wall_h, pitch, eave, 0.22, true)

	# Боковая пристройка (+X) выше y=-0.16 м (не трогает проверку цоколя на -0.25 м)
	_box(st, Vector3(0.86, 0.72, 2.2), Vector3(half.x + 0.43, 0.20, -0.1), Basis.IDENTITY, CELL_STONE)
	_box(st, Vector3(0.84, 1.32, 2.16), Vector3(half.x + 0.42, 1.22, -0.1), Basis.IDENTITY, CELL_TIMBER)
	_box(st, Vector3(1.18, 0.12, 2.55), Vector3(half.x + 0.48, 1.92, -0.1), Basis(Vector3.BACK, -0.34), CELL_ROOF)

	# Дверь в +Z и козырёк-крыльцо + труба на -X для зрительного равновесия
	_box(st, Vector3(0.92, 1.85, 0.10), Vector3(-0.35, 0.925, half.y + 0.03), Basis.IDENTITY, CELL_DARK_WOOD)
	_box(st, Vector3(1.18, 0.18, 0.65), Vector3(-0.35, 0.04, half.y + 0.28), Basis.IDENTITY, CELL_STONE)
	_box(st, Vector3(1.26, 0.11, 0.70), Vector3(-0.35, 2.12, half.y + 0.32), Basis(Vector3.RIGHT, 0.26), CELL_ROOF)
	_box(st, Vector3(0.50, 1.85, 0.50), Vector3(-half.x * 0.56, wall_h + gable * 0.48 + 0.52, -half.y * 0.28), Basis.IDENTITY, CELL_CHIMNEY)

	# Окна (5 со ставнями = 180 + фронтонное = 192)
	_window(st, 0.0, Vector3(half.x * 0.56, 1.42, half.y), true)
	_window(st, 0.0, Vector3(half.x + 0.42, 1.30, 0.98), true)
	_window(st, PI / 2.0, Vector3(0.10, 1.30, half.x + 0.84), true)
	_window(st, -PI / 2.0, Vector3(0.0, 1.42, half.x), true)
	_window(st, PI, Vector3(0.15, 1.42, half.y), true)
	_box(st, Vector3(0.42, 0.42, 0.08), Vector3(0, wall_h + gable * 0.36, half.y + 0.02), Basis.IDENTITY, CELL_WINDOW)

	if level == 0:
		_box(st, Vector3(0.66, 0.14, 0.66), Vector3(-half.x * 0.56, wall_h + gable * 0.48 + 1.45, -half.y * 0.28), Basis.IDENTITY, CELL_STONE)
		_box(st, Vector3(1.10, 0.12, 0.12), Vector3(-0.35, 1.88, half.y + 0.04), Basis.IDENTITY, CELL_DARK_WOOD)
		_box(st, Vector3(0.11, 1.98, 0.11), Vector3(-0.92, 1.02, half.y + 0.58), Basis.IDENTITY, CELL_DARK_WOOD)
		_box(st, Vector3(0.11, 1.98, 0.11), Vector3(0.22, 1.02, half.y + 0.58), Basis.IDENTITY, CELL_DARK_WOOD)
		_window(st, PI, Vector3(-0.75, 1.42, half.y), true)
		_box(st, Vector3(0.12, 2.0, 0.12), Vector3(half.x + 0.80, 1.0, -1.12), Basis.IDENTITY, CELL_DARK_WOOD)
	st.index()
	return st.commit()


## Дом с крутой высокой крышей, дормером-люкарной на скате и широким каменным крыльцом.
static func _build_house_steep(level: int) -> ArrayMesh:
	var half := Vector2(1.6, 1.6)
	var wall_h := 2.05
	var pitch := 0.88
	var eave := 0.46
	var gable := half.x * tan(pitch)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	if level == 2:
		_box(st, Vector3(half.x * 2.0 + 0.1, 0.5, half.y * 2.0 + 0.1), Vector3(0, -0.25, 0), Basis.IDENTITY, CELL_STONE)
		_box(st, Vector3(half.x * 2.0, wall_h, half.y * 2.0), Vector3(0, wall_h * 0.5, 0), Basis.IDENTITY, CELL_PLASTER)
		_gable(st, half.x * 2.0, gable, half.y * 2.0, Vector3(0, wall_h, 0), CELL_PLASTER)
		_roof_slopes(st, half, wall_h, pitch, eave, 0.22, false)
		_box(st, Vector3(1.15, 0.90, 1.0), Vector3(0.95, wall_h + 0.75, 0.0), Basis.IDENTITY, CELL_ROOF)
		st.index()
		return st.commit()

	_box(st, Vector3(half.x * 2.0 + 0.1, 0.5, half.y * 2.0 + 0.1), Vector3(0, -0.25, 0), Basis.IDENTITY, CELL_STONE)
	_box(st, Vector3(half.x * 2.0, wall_h, half.y * 2.0), Vector3(0, wall_h * 0.5, 0), Basis.IDENTITY, CELL_PLASTER)
	_gable(st, half.x * 2.0, gable, half.y * 2.0, Vector3(0, wall_h, 0), CELL_TIMBER)
	_roof_slopes(st, half, wall_h, pitch, eave, 0.22, true)

	# Дормер-люкарна на правом скате (+X)
	_dormer(st, PI / 2.0, Vector3(0.75, wall_h + 0.42, 0.0), 1.05, 0.72, 0.52, 1.35, CELL_PLASTER, level)

	# Дверь и широкое каменное крыльцо в +Z
	_box(st, Vector3(0.92, 1.80, 0.10), Vector3(-0.48, 0.90, half.y + 0.03), Basis.IDENTITY, CELL_DARK_WOOD)
	_box(st, Vector3(2.20, 0.28, 0.78), Vector3(0.0, 0.02, half.y + 0.34), Basis.IDENTITY, CELL_STONE)
	_box(st, Vector3(0.48, 1.70, 0.48), Vector3(-half.x * 0.42, wall_h + gable * 0.60 + 0.50, -half.y * 0.35), Basis.IDENTITY, CELL_CHIMNEY)

	# Окна (5 со ставнями = 180 + чердачное = 12)
	_window(st, 0.0, Vector3(0.68, 1.25, half.y), true)
	_window(st, -PI / 2.0, Vector3(-0.55, 1.25, half.x), true)
	_window(st, -PI / 2.0, Vector3(0.55, 1.25, half.x), true)
	_window(st, PI, Vector3(-0.52, 1.25, half.y), true)
	_window(st, PI, Vector3(0.52, 1.25, half.y), true)
	_box(st, Vector3(0.46, 0.56, 0.08), Vector3(0, wall_h + gable * 0.42, half.y + 0.02), Basis.IDENTITY, CELL_WINDOW)

	if level == 0:
		# Перила крыльца, коньковая балка, подкосы щипца, наголовник трубы
		for sx: float in [-1.02, 1.02]:
			_box(st, Vector3(0.10, 0.85, 0.72), Vector3(sx, 0.54, half.y + 0.32), Basis.IDENTITY, CELL_RAIL)
		for sx: float in [-0.72, 0.72]:
			_box(st, Vector3(0.12, 0.14, 0.75), Vector3(sx, wall_h + 0.45, half.y + 0.25), Basis.IDENTITY, CELL_DARK_WOOD)
		_box(st, Vector3(0.62, 0.14, 0.62), Vector3(-half.x * 0.42, wall_h + gable * 0.60 + 1.38, -half.y * 0.35), Basis.IDENTITY, CELL_STONE)
		_box(st, Vector3(1.10, 0.12, 0.12), Vector3(-0.48, 1.82, half.y + 0.04), Basis.IDENTITY, CELL_DARK_WOOD)
	st.index()
	return st.commit()


## Вытянутый лесной сруб с низкой тяжёлой крышей и передней крытой галереей-рундуком.
static func _build_cabin_long(level: int) -> ArrayMesh:
	var half := Vector2(1.6, 1.6)
	var body_half := Vector2(1.42, 1.42)
	var roof_half := Vector2(1.42, 1.92)
	var wall_h := 2.25
	var pitch := 0.46
	var eave := 0.44
	var gable := roof_half.x * tan(pitch)
	var roof_z := -0.05
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	if level == 2:
		_box(st, Vector3(half.x * 2.0 + 0.1, 0.5, half.y * 2.0 + 0.1), Vector3(0, -0.25, 0), Basis.IDENTITY, CELL_STONE)
		_box(st, Vector3(body_half.x * 2.0, wall_h, 2.85), Vector3(0, wall_h * 0.5, -0.58), Basis.IDENTITY, CELL_TIMBER)
		_gable(st, roof_half.x * 2.0, gable, roof_half.y * 2.0, Vector3(0, wall_h, roof_z), CELL_TIMBER)
		_roof_slopes(st, roof_half, wall_h, pitch, eave, 0.22, false, Vector3(0, 0, roof_z))
		_box(st, Vector3(body_half.x * 2.0, 0.22, 1.10), Vector3(0, 0.04, 1.38), Basis.IDENTITY, CELL_STONE)
		st.index()
		return st.commit()

	_box(st, Vector3(half.x * 2.0 + 0.1, 0.5, half.y * 2.0 + 0.1), Vector3(0, -0.25, 0), Basis.IDENTITY, CELL_STONE)
	# Каменная подкладка под сруб и рундук выше -0.18 м
	_box(st, Vector3(body_half.x * 2.0 + 0.08, 0.44, 3.88), Vector3(0, 0.08, -0.05), Basis.IDENTITY, CELL_STONE)
	_box(st, Vector3(body_half.x * 2.0, 1.95, 2.84), Vector3(0, 1.28, -0.58), Basis.IDENTITY, CELL_TIMBER)
	_gable(st, roof_half.x * 2.0, gable, 2.84, Vector3(0, wall_h, -0.58), CELL_TIMBER)
	_roof_slopes(st, roof_half, wall_h, pitch, eave, 0.22, true, Vector3(0, 0, roof_z))

	# Столбы галереи и прогон (+Z)
	for sx: float in [-1.25, 0.0, 1.25]:
		_box(st, Vector3(0.16, 2.02, 0.16), Vector3(sx, 1.28, 1.76), Basis.IDENTITY, CELL_DARK_WOOD)
	_box(st, Vector3(body_half.x * 2.0 + 0.10, 0.18, 0.18), Vector3(0, wall_h - 0.06, 1.76), Basis.IDENTITY, CELL_DARK_WOOD)

	# Дверь и труба
	_box(st, Vector3(0.92, 1.80, 0.10), Vector3(-0.38, 1.20, 0.86), Basis.IDENTITY, CELL_DARK_WOOD)
	_box(st, Vector3(0.48, 1.65, 0.48), Vector3(0.55, wall_h + gable * 0.55 + 0.42, -0.85), Basis.IDENTITY, CELL_CHIMNEY)

	# Окна (5 со ставнями = 180 + фронтон = 12)
	_window(st, 0.0, Vector3(0.65, 1.52, 0.84), true)
	_window(st, PI / 2.0, Vector3(0.25, 1.52, body_half.x), true)
	_window(st, PI / 2.0, Vector3(1.15, 1.52, body_half.x), true)
	_window(st, -PI / 2.0, Vector3(-0.65, 1.52, body_half.x), true)
	_window(st, PI, Vector3(0.0, 1.52, 2.00), true)
	_box(st, Vector3(0.42, 0.42, 0.08), Vector3(0, wall_h + gable * 0.38, 0.85), Basis.IDENTITY, CELL_WINDOW)

	if level == 0:
		# Выпуски брёвен по углам сруба и скамейка под галереей
		for sx: float in [-1.0, 1.0]:
			for sz: float in [-2.00, 0.84]:
				for row in 3:
					var ly := 0.55 + row * 0.55
					_box(st, Vector3(0.24, 0.16, 0.16), Vector3(sx * (body_half.x + 0.08), ly, sz - signf(sz) * 0.06), Basis.IDENTITY, CELL_LOGS_END)
		_box(st, Vector3(1.15, 0.14, 0.36), Vector3(0.65, 0.66, 1.35), Basis.IDENTITY, CELL_RAIL)
		_box(st, Vector3(2.50, 0.55, 0.10), Vector3(0.0, 0.60, 1.76), Basis.IDENTITY, CELL_RAIL)
		_box(st, Vector3(0.22, 0.22, roof_half.y * 2.0 + eave * 2.0 + 0.15), Vector3(0, wall_h + gable + 0.20, roof_z), Basis(Vector3.BACK, PI / 4.0), CELL_DARK_WOOD)
		_box(st, Vector3(0.62, 0.14, 0.62), Vector3(0.55, wall_h + gable * 0.55 + 1.26, -0.85), Basis.IDENTITY, CELL_STONE)
	st.index()
	return st.commit()


## Высокий таёжный сруб на каменном подклете с двускатным крыльцом на резных столбах и боковой трубой.
static func _build_cabin_porch(level: int) -> ArrayMesh:
	var half := Vector2(1.6, 1.6)
	var base_h := 1.15
	var log_h := 1.48
	var wall_h := base_h + log_h
	var pitch := 0.68
	var eave := 0.50
	var gable := half.x * tan(pitch)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	if level == 2:
		_box(st, Vector3(half.x * 2.0 + 0.1, 0.5 + base_h, half.y * 2.0 + 0.1), Vector3(0, (base_h - 0.5) * 0.5, 0), Basis.IDENTITY, CELL_STONE)
		_box(st, Vector3(half.x * 2.0, log_h, half.y * 2.0), Vector3(0, base_h + log_h * 0.5, 0), Basis.IDENTITY, CELL_TIMBER)
		_gable(st, half.x * 2.0, gable, half.y * 2.0, Vector3(0, wall_h, 0), CELL_TIMBER)
		_roof_slopes(st, half, wall_h, pitch, eave, 0.22, false)
		_box(st, Vector3(0.55, 3.8, 0.72), Vector3(-half.x - 0.26, 1.78, -0.15), Basis.IDENTITY, CELL_CHIMNEY)
		st.index()
		return st.commit()

	_box(st, Vector3(half.x * 2.0 + 0.1, 0.5 + base_h, half.y * 2.0 + 0.1), Vector3(0, (base_h - 0.5) * 0.5, 0), Basis.IDENTITY, CELL_STONE)
	_box(st, Vector3(half.x * 2.0, log_h, half.y * 2.0), Vector3(0, base_h + log_h * 0.5, 0), Basis.IDENTITY, CELL_TIMBER)
	_gable(st, half.x * 2.0, gable, half.y * 2.0, Vector3(0, wall_h, 0), CELL_TIMBER)
	_roof_slopes(st, half, wall_h, pitch, eave, 0.22, true)

	# Массивная наружная каменная печная труба на -X (выше y=-0.16 м)
	_box(st, Vector3(0.58, 2.20, 0.90), Vector3(-half.x - 0.28, 0.96, -0.15), Basis.IDENTITY, CELL_STONE)
	_box(st, Vector3(0.46, 2.25, 0.56), Vector3(-half.x - 0.22, 3.12, -0.15), Basis.IDENTITY, CELL_CHIMNEY)

	# Двускатное крыльцо на столбах в +Z
	_box(st, Vector3(1.50, 0.55, 0.85), Vector3(-0.20, 0.22, half.y + 0.42), Basis.IDENTITY, CELL_STONE)
	_box(st, Vector3(1.05, 0.24, 0.45), Vector3(-0.20, 0.04, half.y + 0.96), Basis.IDENTITY, CELL_STONE)
	for sx: float in [-0.82, 0.42]:
		_cyl(st, 0.11, 0.12, 1.85, 6, Vector3(sx, 1.40, half.y + 0.72), Basis.IDENTITY, CELL_DARK_WOOD)
	_gable(st, 1.48, 0.62, 0.88, Vector3(-0.20, 2.28, half.y + 0.44), CELL_TIMBER)
	_roof_slopes(st, Vector2(0.74, 0.44), 2.28, 0.68, 0.16, 0.12, false, Vector3(-0.20, 0.0, half.y + 0.44))

	# Дверь и окна (5 со ставнями + фронтон)
	_box(st, Vector3(0.88, 1.75, 0.10), Vector3(-0.20, 1.38, half.y + 0.03), Basis.IDENTITY, CELL_DARK_WOOD)
	_window(st, 0.0, Vector3(half.x * 0.58, 1.90, half.y), true)
	_window(st, PI / 2.0, Vector3(-0.45, 1.90, half.x), true)
	_window(st, PI / 2.0, Vector3(0.55, 1.90, half.x), true)
	_window(st, -PI / 2.0, Vector3(0.75, 1.90, half.x), true)
	_window(st, PI, Vector3(0.35, 1.90, half.y), true)
	_box(st, Vector3(0.42, 0.44, 0.08), Vector3(0, wall_h + gable * 0.36, half.y + 0.02), Basis.IDENTITY, CELL_WINDOW)

	if level == 0:
		for sx: float in [-1.0, 1.0]:
			for sz: float in [-1.0, 1.0]:
				for row in 3:
					var ly := base_h + 0.25 + row * 0.48
					_box(st, Vector3(0.24, 0.15, 0.15), Vector3(sx * (half.x + 0.08), ly, sz * (half.y - 0.06)), Basis.IDENTITY, CELL_LOGS_END)
		_box(st, Vector3(0.62, 0.14, 0.72), Vector3(-half.x - 0.22, 4.30, -0.15), Basis.IDENTITY, CELL_STONE)
		_box(st, Vector3(1.36, 0.62, 0.08), Vector3(-0.20, 0.80, half.y + 0.78), Basis.IDENTITY, CELL_RAIL)
	st.index()
	return st.commit()


## Альпийское шале с крытой боковой террасой (+X) и наружной деревянной лестницей на второй этаж.
static func _build_chalet_terrace(level: int) -> ArrayMesh:
	var half := Vector2(2.2, 1.9)
	var h1 := 2.05
	var h2 := 2.15
	var wall_h := h1 + h2
	var pitch := 0.44
	var gable := half.x * tan(pitch)
	var eave_l := 0.72
	var eave_r := 1.24
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	if level == 2:
		_box(st, Vector3(half.x * 2.0 + 0.1, 0.5 + h1, half.y * 2.0 + 0.1), Vector3(0, (h1 - 0.5) * 0.5, 0), Basis.IDENTITY, CELL_STONE)
		_box(st, Vector3(half.x * 2.0, h2, half.y * 2.0), Vector3(0, h1 + h2 * 0.5, 0), Basis.IDENTITY, CELL_TIMBER)
		_gable(st, half.x * 2.0, gable, half.y * 2.0, Vector3(0, wall_h, 0), CELL_TIMBER)
		_roof_slopes_asym(st, half, wall_h, pitch, eave_l, eave_r, 0.55, 0.22, false)
		_box(st, Vector3(1.05, 0.28, 3.2), Vector3(half.x + 0.52, 0.12, 0.0), Basis.IDENTITY, CELL_TIMBER)
		st.index()
		return st.commit()

	_box(st, Vector3(half.x * 2.0 + 0.1, 0.5, half.y * 2.0 + 0.1), Vector3(0, -0.25, 0), Basis.IDENTITY, CELL_STONE)
	_box(st, Vector3(half.x * 2.0, h1, half.y * 2.0), Vector3(0, h1 * 0.5, 0), Basis.IDENTITY, CELL_STONE)
	_box(st, Vector3(half.x * 2.0, h2, half.y * 2.0), Vector3(0, h1 + h2 * 0.5, 0), Basis.IDENTITY, CELL_TIMBER)
	_gable(st, half.x * 2.0, gable, half.y * 2.0, Vector3(0, wall_h, 0), CELL_TIMBER)
	_roof_slopes_asym(st, half, wall_h, pitch, eave_l, eave_r, 0.65, 0.22, true)

	# Крытая боковая терраса на +X (выше y=-0.16 м)
	_box(st, Vector3(1.06, 0.34, 3.2), Vector3(half.x + 0.53, 0.02, 0.0), Basis.IDENTITY, CELL_STONE)
	_box(st, Vector3(1.08, 0.12, 3.22), Vector3(half.x + 0.54, 0.24, 0.0), Basis.IDENTITY, CELL_TIMBER)
	_box(st, Vector3(0.08, 0.72, 2.20), Vector3(half.x + 1.04, 0.65, -0.45), Basis.IDENTITY, CELL_RAIL)
	for tz: float in [-1.52, 0.0, 1.52]:
		_box(st, Vector3(0.14, 3.42, 0.14), Vector3(half.x + 0.98, 1.96, tz), Basis.IDENTITY, CELL_DARK_WOOD)

	# Наружная лестница спереди справа к боковой площадке 2-го этажа
	_box(st, Vector3(1.02, 0.14, 1.15), Vector3(half.x + 0.48, h1, half.y - 0.55), Basis.IDENTITY, CELL_TIMBER)
	_box(st, Vector3(0.86, 0.22, 0.55), Vector3(half.x + 0.48, 0.65, half.y + 0.35), Basis.IDENTITY, CELL_RAIL)
	_box(st, Vector3(0.86, 0.22, 0.55), Vector3(half.x + 0.48, 1.15, half.y + 0.05), Basis.IDENTITY, CELL_RAIL)
	_box(st, Vector3(0.86, 0.22, 0.55), Vector3(half.x + 0.48, 1.65, half.y - 0.25), Basis.IDENTITY, CELL_RAIL)

	# Передний вход и труба
	_box(st, Vector3(0.95, 1.85, 0.10), Vector3(-half.x * 0.40, 0.925, half.y + 0.03), Basis.IDENTITY, CELL_DARK_WOOD)
	_box(st, Vector3(1.15, 0.18, 0.65), Vector3(-half.x * 0.40, 0.04, half.y + 0.26), Basis.IDENTITY, CELL_STONE)
	_box(st, Vector3(0.55, 1.70, 0.55), Vector3(-half.x * 0.42, wall_h + gable * 0.55 + 0.45, -half.y * 0.35), Basis.IDENTITY, CELL_CHIMNEY)

	# 7 окон со ставнями + фронтонное окно
	_window(st, 0.0, Vector3(half.x * 0.50, 1.38, half.y), true)
	_window(st, 0.0, Vector3(-half.x * 0.48, h1 + h2 * 0.55, half.y), true)
	_window(st, 0.0, Vector3(half.x * 0.48, h1 + h2 * 0.55, half.y), true)
	_window(st, -PI / 2.0, Vector3(-half.y * 0.45, h1 + h2 * 0.55, half.x), true)
	_window(st, PI / 2.0, Vector3(-half.y * 0.45, h1 + h2 * 0.55, half.x), true)
	_window(st, PI / 2.0, Vector3(half.y * 0.45, 1.35, half.x), true)
	_window(st, PI, Vector3(0.0, h1 + h2 * 0.55, half.y), true)
	_box(st, Vector3(0.46, 0.46, 0.08), Vector3(0, wall_h + gable * 0.36, half.y + 0.02), Basis.IDENTITY, CELL_WINDOW)

	if level == 0:
		for sx: float in [-half.x - 0.38, half.x + 0.62]:
			_box(st, Vector3(0.16, 0.18, half.y * 2.0 + 1.30), Vector3(sx, wall_h - 0.14, 0), Basis.IDENTITY, CELL_DARK_WOOD)
		_box(st, Vector3(0.70, 0.14, 0.70), Vector3(-half.x * 0.42, wall_h + gable * 0.55 + 1.32, -half.y * 0.35), Basis.IDENTITY, CELL_STONE)
		_window(st, -PI / 2.0, Vector3(half.y * 0.45, 1.35, half.x), true)
		_box(st, Vector3(0.10, 0.72, 1.05), Vector3(half.x + 1.00, h1 + 0.40, half.y - 0.55), Basis.IDENTITY, CELL_RAIL)
	st.index()
	return st.commit()


## Суровое каменное шале: контрфорсы цоколя, врезанный верхний балкон, крутой щипец.
static func _build_chalet_stone(level: int) -> ArrayMesh:
	var half := Vector2(2.2, 1.9)
	var h1 := 2.2
	var h2 := 2.1
	var wall_h := h1 + h2
	var pitch := 0.58
	var eave := 0.70
	var gable := half.x * tan(pitch)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	if level == 2:
		_box(st, Vector3(half.x * 2.0 + 0.1, 0.5 + h1, half.y * 2.0 + 0.1), Vector3(0, (h1 - 0.5) * 0.5, 0), Basis.IDENTITY, CELL_STONE)
		_box(st, Vector3(half.x * 2.0, h2, half.y * 2.0), Vector3(0, h1 + h2 * 0.5, 0), Basis.IDENTITY, CELL_TIMBER)
		_gable(st, half.x * 2.0, gable, half.y * 2.0, Vector3(0, wall_h, 0), CELL_TIMBER)
		_roof_slopes(st, half, wall_h, pitch, eave, 0.24, false)
		_box(st, Vector3(2.8, 0.90, 0.80), Vector3(0, h1 + 0.35, half.y + 0.36), Basis.IDENTITY, CELL_STONE)
		st.index()
		return st.commit()

	_box(st, Vector3(half.x * 2.0 + 0.1, 0.5, half.y * 2.0 + 0.1), Vector3(0, -0.25, 0), Basis.IDENTITY, CELL_STONE)
	_box(st, Vector3(half.x * 2.0, h1, half.y * 2.0), Vector3(0, h1 * 0.5, 0), Basis.IDENTITY, CELL_STONE)
	_box(st, Vector3(half.x * 2.0, h2, half.y * 2.0), Vector3(0, h1 + h2 * 0.5, 0), Basis.IDENTITY, CELL_TIMBER)
	_gable(st, half.x * 2.0, gable, half.y * 2.0, Vector3(0, wall_h, 0), CELL_TIMBER)
	_roof_slopes(st, half, wall_h, pitch, eave, 0.24, true)

	# 4 каменных контрфорса по углам (выше y=-0.16 м)
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			_box(st, Vector3(0.46, 2.38, 0.46), Vector3(sx * (half.x + 0.12), 1.04, sz * (half.y - 0.10)), Basis.IDENTITY, CELL_STONE)

	# Центральный каменный крыльцо-портал и деревянный балкон второго этажа
	_box(st, Vector3(1.05, 1.90, 0.12), Vector3(0, 0.95, half.y + 0.04), Basis.IDENTITY, CELL_DARK_WOOD)
	_box(st, Vector3(1.55, 0.22, 0.72), Vector3(0, 0.06, half.y + 0.32), Basis.IDENTITY, CELL_STONE)
	_box(st, Vector3(2.80, 0.14, 0.85), Vector3(0, h1, half.y + 0.40), Basis.IDENTITY, CELL_TIMBER)
	_box(st, Vector3(2.80, 0.82, 0.10), Vector3(0, h1 + 0.46, half.y + 0.78), Basis.IDENTITY, CELL_RAIL)
	for sx: float in [-1.0, 1.0]:
		_box(st, Vector3(0.10, 0.82, 0.82), Vector3(sx * 1.36, h1 + 0.46, half.y + 0.40), Basis.IDENTITY, CELL_RAIL)
	_box(st, Vector3(0.60, 1.85, 0.60), Vector3(half.x * 0.48, wall_h + gable * 0.55 + 0.45, -half.y * 0.30), Basis.IDENTITY, CELL_CHIMNEY)

	# 7 окон со ставнями + щипцовое
	_window(st, 0.0, Vector3(-half.x * 0.62, 1.35, half.y), true)
	_window(st, 0.0, Vector3(half.x * 0.62, 1.35, half.y), true)
	_window(st, 0.0, Vector3(-half.x * 0.48, h1 + h2 * 0.55, half.y), true)
	_window(st, 0.0, Vector3(half.x * 0.48, h1 + h2 * 0.55, half.y), true)
	_window(st, PI / 2.0, Vector3(0.0, h1 + h2 * 0.55, half.x), true)
	_window(st, -PI / 2.0, Vector3(0.0, h1 + h2 * 0.55, half.x), true)
	_window(st, PI, Vector3(0.0, h1 + h2 * 0.55, half.y), true)
	_box(st, Vector3(0.46, 0.48, 0.08), Vector3(0, wall_h + gable * 0.36, half.y + 0.02), Basis.IDENTITY, CELL_WINDOW)

	if level == 0:
		for sx: float in [-1.0, 1.0]:
			for sz: float in [-1.0, 1.0]:
				_box(st, Vector3(0.54, 0.22, 0.54), Vector3(sx * (half.x + 0.14), 2.34, sz * (half.y - 0.10)), Basis.IDENTITY, CELL_STONE)
		for bx: float in [-1.1, 0.0, 1.1]:
			_box(st, Vector3(0.16, 0.22, 0.78), Vector3(bx, h1 - 0.14, half.y + 0.36), Basis.IDENTITY, CELL_DARK_WOOD)
		for sx: float in [-1.0, 1.0]:
			_box(st, Vector3(0.16, 0.18, half.y * 2.0 + eave * 2.0), Vector3(sx * (half.x + 0.38), wall_h - 0.10, 0), Basis.IDENTITY, CELL_DARK_WOOD)
		_box(st, Vector3(0.76, 0.14, 0.76), Vector3(half.x * 0.48, wall_h + gable * 0.55 + 1.38, -half.y * 0.30), Basis.IDENTITY, CELL_STONE)
	st.index()
	return st.commit()


## Двухэтажный крупный дом с ломаной мансардной крышей и боковыми слуховыми люкарнами.
static func _build_tall_mansard(level: int) -> ArrayMesh:
	var half := Vector2(1.9, 1.9)
	var h1 := 2.2
	var h2 := 2.0
	var wall_h := h1 + h2
	var dy1 := 1.25
	var x_mid := 1.05
	var y_mid := wall_h + dy1
	var pitch2 := 0.42
	var gable2 := x_mid * tan(pitch2)
	var eave := 0.38
	var depth := half.y * 2.0 + eave * 2.0
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var p1 := atan2(dy1, half.x - x_mid)
	var seg1 := sqrt(dy1 * dy1 + (half.x - x_mid) * (half.x - x_mid)) + 0.38
	var add_lower_mansard := func() -> void:
		for side: float in [-1.0, 1.0]:
			var mid_x := side * (half.x + x_mid) * 0.5 + side * 0.12
			var mid_y := wall_h + dy1 * 0.5 - 0.08
			mid_x += side * sin(p1) * 0.11
			mid_y += cos(p1) * 0.11
			_box(st, Vector3(seg1, 0.22, depth), Vector3(mid_x, mid_y, 0), Basis(Vector3.BACK, -side * p1), CELL_ROOF)

	if level == 2:
		_box(st, Vector3(half.x * 2.0 + 0.1, wall_h + 0.5, half.y * 2.0 + 0.1), Vector3(0, (wall_h - 0.5) * 0.5, 0), Basis.IDENTITY, CELL_PLASTER)
		_trapezoid(st, half.x * 2.0, x_mid * 2.0, dy1, half.y * 2.0, Vector3(0, wall_h, 0), CELL_PLASTER)
		add_lower_mansard.call()
		_roof_slopes(st, Vector2(x_mid, half.y), y_mid, pitch2, 0.24, 0.22, false, Vector3.ZERO, eave)
		st.index()
		return st.commit()

	_box(st, Vector3(half.x * 2.0 + 0.1, 0.5, half.y * 2.0 + 0.1), Vector3(0, -0.25, 0), Basis.IDENTITY, CELL_STONE)
	_box(st, Vector3(half.x * 2.0, h1, half.y * 2.0), Vector3(0, h1 * 0.5, 0), Basis.IDENTITY, CELL_PLASTER)
	_box(st, Vector3(half.x * 2.0, h2, half.y * 2.0), Vector3(0, h1 + h2 * 0.5, 0), Basis.IDENTITY, CELL_PLASTER)
	_trapezoid(st, half.x * 2.0, x_mid * 2.0, dy1, half.y * 2.0, Vector3(0, wall_h, 0), CELL_PLASTER)
	_gable(st, x_mid * 2.0, gable2, half.y * 2.0, Vector3(0, y_mid, 0), CELL_TIMBER)
	add_lower_mansard.call()
	_roof_slopes(st, Vector2(x_mid, half.y), y_mid, pitch2, 0.24, 0.22, true, Vector3.ZERO, eave)

	# Две боковые мансардные люкарны на крутом скате (-X и +X)
	_dormer(st, PI / 2.0, Vector3(1.12, wall_h + 0.20, 0.0), 1.05, 0.78, 0.48, 1.15, CELL_PLASTER, level)
	_dormer(st, -PI / 2.0, Vector3(-1.12, wall_h + 0.20, 0.0), 1.05, 0.78, 0.48, 1.15, CELL_PLASTER, level)

	# Вход, крыльцо и труба
	_box(st, Vector3(1.00, 1.90, 0.10), Vector3(0.0, 0.95, half.y + 0.03), Basis.IDENTITY, CELL_DARK_WOOD)
	_box(st, Vector3(1.40, 0.22, 0.72), Vector3(0.0, 0.06, half.y + 0.30), Basis.IDENTITY, CELL_STONE)
	_box(st, Vector3(1.50, 0.14, 0.65), Vector3(0.0, 2.15, half.y + 0.30), Basis(Vector3.RIGHT, 0.22), CELL_ROOF)
	_box(st, Vector3(0.55, 1.45, 0.55), Vector3(0.55, y_mid + gable2 + 0.35, -half.y * 0.35), Basis.IDENTITY, CELL_CHIMNEY)

	# 5 окон со ставнями + мансардное окно в +Z
	_window(st, 0.0, Vector3(-half.x * 0.58, 1.40, half.y), true)
	_window(st, 0.0, Vector3(half.x * 0.58, 1.40, half.y), true)
	_window(st, 0.0, Vector3(-half.x * 0.48, h1 + h2 * 0.55, half.y), true)
	_window(st, 0.0, Vector3(half.x * 0.48, h1 + h2 * 0.55, half.y), true)
	_window(st, PI, Vector3(0.0, h1 + h2 * 0.55, half.y), true)
	_box(st, Vector3(0.56, 0.62, 0.08), Vector3(0, wall_h + dy1 * 0.52, half.y + 0.02), Basis.IDENTITY, CELL_WINDOW)

	if level == 0:
		_box(st, Vector3(half.x * 2.0 + 0.14, 0.16, half.y * 2.0 + 0.14), Vector3(0, h1, 0), Basis.IDENTITY, CELL_DARK_WOOD)
		for sx: float in [-1.0, 1.0]:
			for sz: float in [-1.0, 1.0]:
				_box(st, Vector3(0.18, wall_h, 0.18), Vector3(sx * (half.x - 0.03), wall_h * 0.5, sz * (half.y - 0.03)), Basis.IDENTITY, CELL_STONE)
		_window(st, PI / 2.0, Vector3(0.0, 1.40, half.x), true)
		_window(st, -PI / 2.0, Vector3(0.0, 1.40, half.x), true)
		_window(st, PI, Vector3(0.0, 1.40, half.y), true)
		_box(st, Vector3(0.70, 0.14, 0.70), Vector3(0.55, y_mid + gable2 + 1.08, -half.y * 0.35), Basis.IDENTITY, CELL_STONE)
	st.index()
	return st.commit()


## Крупный общественный / торговый дом центра с входной аркадой и коньковой башенкой-звонницей.
static func _build_tall_hall(level: int) -> ArrayMesh:
	var half := Vector2(2.2, 1.9)
	var h1 := 2.3
	var h2 := 2.2
	var wall_h := h1 + h2
	var pitch := 0.68
	var eave := 0.55
	var gable := half.x * tan(pitch)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	if level == 2:
		_box(st, Vector3(half.x * 2.0 + 0.1, h1 + 0.5, half.y * 2.0 + 0.1), Vector3(0, (h1 - 0.5) * 0.5, 0), Basis.IDENTITY, CELL_STONE)
		_box(st, Vector3(half.x * 2.0, h2, half.y * 2.0), Vector3(0, h1 + h2 * 0.5, 0), Basis.IDENTITY, CELL_PLASTER)
		_gable(st, half.x * 2.0, gable, half.y * 2.0, Vector3(0, wall_h, 0), CELL_PLASTER)
		_roof_slopes(st, half, wall_h, pitch, eave, 0.24, false)
		_box(st, Vector3(1.05, 1.45, 1.05), Vector3(0, wall_h + gable + 0.45, 0.55), Basis.IDENTITY, CELL_TIMBER)
		_cyl(st, 0.0, 0.72, 1.15, 4, Vector3(0, wall_h + gable + 1.72, 0.55), Basis(Vector3.UP, PI / 4.0), CELL_ROOF)
		st.index()
		return st.commit()

	_box(st, Vector3(half.x * 2.0 + 0.1, 0.5, half.y * 2.0 + 0.1), Vector3(0, -0.25, 0), Basis.IDENTITY, CELL_STONE)
	_box(st, Vector3(half.x * 2.0, h1, half.y * 2.0), Vector3(0, h1 * 0.5, 0), Basis.IDENTITY, CELL_STONE)
	_box(st, Vector3(half.x * 2.0, h2, half.y * 2.0), Vector3(0, h1 + h2 * 0.5, 0), Basis.IDENTITY, CELL_PLASTER)
	_gable(st, half.x * 2.0, gable, half.y * 2.0, Vector3(0, wall_h, 0), CELL_PLASTER)
	_roof_slopes(st, half, wall_h, pitch, eave, 0.24, true)

	# Передняя входная аркада-портик (+Z)
	_box(st, Vector3(2.90, 0.24, 0.76), Vector3(0, 0.06, half.y + 0.34), Basis.IDENTITY, CELL_STONE)
	for px: float in [-1.25, 0.0, 1.25]:
		_box(st, Vector3(0.22, 2.25, 0.22), Vector3(px, 1.24, half.y + 0.56), Basis.IDENTITY, CELL_STONE)
	_box(st, Vector3(3.00, 0.16, 0.72), Vector3(0, 2.38, half.y + 0.34), Basis.IDENTITY, CELL_TIMBER)
	_box(st, Vector3(3.15, 0.14, 0.85), Vector3(0, 2.55, half.y + 0.36), Basis(Vector3.RIGHT, 0.24), CELL_ROOF)
	_box(st, Vector3(1.15, 2.00, 0.12), Vector3(0, 1.00, half.y + 0.04), Basis.IDENTITY, CELL_DARK_WOOD)

	# Коньковая башенка-звонница со шпилем (главная доминанта центра поселения)
	var belfry_y := wall_h + gable - 0.10
	_box(st, Vector3(1.06, 0.55, 1.06), Vector3(0, belfry_y + 0.15, 0.55), Basis.IDENTITY, CELL_TIMBER)
	for sx: float in [-0.40, 0.40]:
		for sz: float in [-0.40, 0.40]:
			_box(st, Vector3(0.14, 1.05, 0.14), Vector3(sx, belfry_y + 0.92, 0.55 + sz), Basis.IDENTITY, CELL_DARK_WOOD)
	_box(st, Vector3(0.38, 0.45, 0.38), Vector3(0, belfry_y + 1.00, 0.55), Basis.IDENTITY, CELL_METAL)
	_cyl(st, 0.0, 0.76, 1.20, 4, Vector3(0, belfry_y + 2.02, 0.55), Basis(Vector3.UP, PI / 4.0), CELL_ROOF)

	# Труба и окна (7 со ставнями = 252 + 2 арочных окна в щипце = 24)
	_box(st, Vector3(0.55, 1.75, 0.55), Vector3(half.x * 0.52, wall_h + gable * 0.50 + 0.45, -half.y * 0.48), Basis.IDENTITY, CELL_CHIMNEY)
	_window(st, 0.0, Vector3(-half.x * 0.65, h1 + h2 * 0.52, half.y), true)
	_window(st, 0.0, Vector3(0.0, h1 + h2 * 0.52, half.y), true)
	_window(st, 0.0, Vector3(half.x * 0.65, h1 + h2 * 0.52, half.y), true)
	_window(st, PI / 2.0, Vector3(-half.y * 0.42, h1 + h2 * 0.52, half.x), true)
	_window(st, -PI / 2.0, Vector3(half.y * 0.42, h1 + h2 * 0.52, half.x), true)
	_window(st, PI / 2.0, Vector3(half.y * 0.42, 1.35, half.x), true)
	_window(st, PI, Vector3(0.0, h1 + h2 * 0.52, half.y), true)
	for wx: float in [-0.42, 0.42]:
		_box(st, Vector3(0.42, 0.58, 0.08), Vector3(wx, wall_h + gable * 0.36, half.y + 0.02), Basis.IDENTITY, CELL_WINDOW)

	if level == 0:
		_box(st, Vector3(half.x * 2.0 + 0.14, 0.18, half.y * 2.0 + 0.14), Vector3(0, h1, 0), Basis.IDENTITY, CELL_DARK_WOOD)
		for sx: float in [-0.72, 0.72]:
			_box(st, Vector3(0.14, gable * 0.72, 0.10), Vector3(sx, wall_h + gable * 0.36, half.y + 0.01), Basis.IDENTITY, CELL_DARK_WOOD)
		_box(st, Vector3(1.14, 0.12, 1.14), Vector3(0, belfry_y + 1.44, 0.55), Basis.IDENTITY, CELL_DARK_WOOD)
		_box(st, Vector3(0.08, 0.42, 0.08), Vector3(0, belfry_y + 2.75, 0.55), Basis.IDENTITY, CELL_METAL)
		_box(st, Vector3(0.70, 0.14, 0.70), Vector3(half.x * 0.52, wall_h + gable * 0.50 + 1.35, -half.y * 0.48), Basis.IDENTITY, CELL_STONE)
		_window(st, -PI / 2.0, Vector3(-half.y * 0.42, 1.35, half.x), true)
		_window(st, PI, Vector3(0.0, 1.35, half.y), true)
	st.index()
	return st.commit()


## Высокий сарай-сеновал с коньковой балкой-клювом и боковым навесом (-X).
static func _build_barn_loft(level: int) -> ArrayMesh:
	var half := Vector2(2.0, 1.5)
	var wall_h := 3.05
	var pitch := 0.58
	var gable := half.x * tan(pitch)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	if level == 2:
		_box(st, Vector3(half.x * 2.0 + 0.1, 1.1, half.y * 2.0 + 0.1), Vector3(0, 0.05, 0), Basis.IDENTITY, CELL_STONE)
		_box(st, Vector3(half.x * 2.0, 2.45, half.y * 2.0), Vector3(0, 1.82, 0), Basis.IDENTITY, CELL_TIMBER)
		_gable(st, half.x * 2.0, gable, half.y * 2.0, Vector3(0, wall_h, 0), CELL_TIMBER)
		_roof_slopes(st, half, wall_h, pitch, 0.55, 0.22, false)
		_box(st, Vector3(0.85, 1.50, 2.30), Vector3(-half.x - 0.40, 0.85, 0), Basis.IDENTITY, CELL_ROOF)
		st.index()
		return st.commit()

	_box(st, Vector3(half.x * 2.0 + 0.1, 1.25, half.y * 2.0 + 0.1), Vector3(0, 0.125, 0), Basis.IDENTITY, CELL_STONE)
	_box(st, Vector3(half.x * 2.0, 2.30, half.y * 2.0), Vector3(0, 1.90, 0), Basis.IDENTITY, CELL_TIMBER)
	_gable(st, half.x * 2.0, gable, half.y * 2.0, Vector3(0, wall_h, 0), CELL_TIMBER)
	_roof_slopes(st, half, wall_h, pitch, 0.55, 0.22, true)

	# Выступающая коньковая балка-клюв и люк сеновала с торчащим сеном (+Z)
	_box(st, Vector3(0.22, 0.22, 0.90), Vector3(0, wall_h + gable - 0.10, half.y + 0.45), Basis.IDENTITY, CELL_DARK_WOOD)
	_box(st, Vector3(0.75, 0.10, 0.72), Vector3(0, wall_h + gable + 0.08, half.y + 0.42), Basis.IDENTITY, CELL_ROOF)
	_box(st, Vector3(1.05, 0.82, 0.08), Vector3(0, 3.05, half.y + 0.03), Basis.IDENTITY, CELL_DARK_WOOD)
	_box(st, Vector3(0.85, 0.52, 0.26), Vector3(0, 2.95, half.y + 0.12), Basis.IDENTITY, CELL_STRAW)

	# Ворота
	_box(st, Vector3(1.70, 2.00, 0.10), Vector3(0, 1.00, half.y + 0.03), Basis.IDENTITY, CELL_DARK_WOOD)

	# Боковой открытый навес на -X (выше y=-0.16 м)
	_box(st, Vector3(1.05, 0.12, 2.40), Vector3(-half.x - 0.42, 1.88, 0.0), Basis(Vector3.BACK, 0.30), CELL_ROOF)
	for sz: float in [-1.05, 1.05]:
		_box(st, Vector3(0.14, 1.82, 0.14), Vector3(-half.x - 0.82, 0.84, sz), Basis.IDENTITY, CELL_DARK_WOOD)
	_box(st, Vector3(0.65, 0.72, 1.85), Vector3(-half.x - 0.35, 0.32, 0.0), Basis.IDENTITY, CELL_STRAW)

	if level == 0:
		_cyl(st, 0.14, 0.14, 0.12, 6, Vector3(0, wall_h + gable - 0.34, half.y + 0.74), Basis(Vector3.BACK, PI / 2.0), CELL_METAL)
		_box(st, Vector3(1.88, 0.12, 0.12), Vector3(0, 2.02, half.y + 0.04), Basis.IDENTITY, CELL_RAIL)
		for sx: float in [-0.88, 0.88]:
			_box(st, Vector3(0.12, 2.00, 0.12), Vector3(sx, 1.00, half.y + 0.04), Basis.IDENTITY, CELL_RAIL)
		for sx: float in [-1.0, 1.0]:
			_box(st, Vector3(0.12, 2.25, 0.12), Vector3(sx * (half.x - 0.04), 1.90, half.y - 0.04), Basis.IDENTITY, CELL_RAIL)
	st.index()
	return st.commit()


## Деревянный колодец под двускатным шатром на двух столбах с воротом (hay size).
static func _build_well_canopy(level: int) -> ArrayMesh:
	var half := Vector2(0.9, 0.9)
	var roof_half := Vector2(0.90, 0.85)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	if level == 2:
		_box(st, Vector3(half.x * 2.0, 0.5, half.y * 2.0), Vector3(0, -0.25, 0), Basis.IDENTITY, CELL_STONE)
		_box(st, Vector3(1.36, 0.80, 1.36), Vector3(0, 0.40, 0), Basis.IDENTITY, CELL_TIMBER)
		_roof_slopes(st, roof_half, 1.90, 0.66, 0.18, 0.14, false)
		st.index()
		return st.commit()

	_box(st, Vector3(half.x * 2.0, 0.5, half.y * 2.0), Vector3(0, -0.25, 0), Basis.IDENTITY, CELL_STONE)
	_box(st, Vector3(1.36, 0.80, 1.36), Vector3(0, 0.40, 0), Basis.IDENTITY, CELL_TIMBER)
	_box(st, Vector3(1.12, 0.06, 1.12), Vector3(0, 0.72, 0), Basis.IDENTITY, CELL_WATER)
	for sx: float in [-0.58, 0.58]:
		_box(st, Vector3(0.14, 1.75, 0.14), Vector3(sx, 1.25, 0), Basis.IDENTITY, CELL_DARK_WOOD)
	_cyl(st, 0.10, 0.10, 1.18, 5, Vector3(0, 1.42, 0), Basis(Vector3.BACK, PI / 2.0), CELL_LOGS_END)
	_gable(st, roof_half.x * 2.0, roof_half.x * tan(0.66), roof_half.y * 2.0, Vector3(0, 1.92, 0), CELL_TIMBER)
	_roof_slopes(st, roof_half, 1.92, 0.66, 0.18, 0.14, level == 0)

	if level == 0:
		_cyl(st, 0.14, 0.12, 0.30, 5, Vector3(0.0, 1.04, 0.0), Basis.IDENTITY, CELL_DARK_WOOD)
		_box(st, Vector3(0.28, 0.08, 0.08), Vector3(0.74, 1.42, 0.0), Basis.IDENTITY, CELL_METAL)
		_box(st, Vector3(0.08, 0.24, 0.08), Vector3(0.86, 1.32, 0.0), Basis.IDENTITY, CELL_METAL)
		_box(st, Vector3(1.48, 0.10, 1.48), Vector3(0, 0.82, 0), Basis.IDENTITY, CELL_RAIL)
	st.index()
	return st.commit()


## Торговый навес с прилавком, полосатым тентом и товарами (shed size).
static func _build_market_stall(level: int) -> ArrayMesh:
	var half := Vector2(1.1, 0.75)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	_box(st, Vector3(half.x * 2.0, 0.5, half.y * 2.0), Vector3(0, -0.25, 0), Basis.IDENTITY, CELL_STONE)
	_box(st, Vector3(2.05, 0.82, 0.72), Vector3(0, 0.41, 0.24), Basis.IDENTITY, CELL_TIMBER)
	var tilt := Basis(Vector3.RIGHT, 0.26)
	_box(st, Vector3(half.x * 2.0 + 0.45, 0.12, half.y * 2.0 + 0.55), Vector3(0, 2.05, 0.05), tilt, CELL_SHUTTER)

	if level == 2:
		_box(st, Vector3(1.50, 0.35, 0.55), Vector3(0, 0.98, 0.24), Basis.IDENTITY, CELL_STRAW)
		st.index()
		return st.commit()

	for sx: float in [-0.96, 0.96]:
		for sz: float in [-0.62, 0.62]:
			_box(st, Vector3(0.11, 1.95, 0.11), Vector3(sx, 0.98, sz), Basis.IDENTITY, CELL_DARK_WOOD)
	_box(st, Vector3(half.x * 2.0 + 0.45, 0.22, 0.08), Vector3(0, 1.84, half.y + 0.28), Basis.IDENTITY, CELL_PLASTER)
	# Ящики и товары на прилавке
	_box(st, Vector3(0.55, 0.32, 0.45), Vector3(-0.52, 0.98, 0.24), Basis.IDENTITY, CELL_STRAW)
	_box(st, Vector3(0.48, 0.28, 0.42), Vector3(0.08, 0.96, 0.24), Basis.IDENTITY, CELL_FLOWER_A)
	_box(st, Vector3(0.52, 0.34, 0.45), Vector3(0.62, 0.99, 0.22), Basis.IDENTITY, CELL_LOGS_END)

	if level == 0:
		for ax: float in [-0.68, 0.0, 0.68]:
			_box(st, Vector3(0.42, 0.14, half.y * 2.0 + 0.56), Vector3(ax, 2.07, 0.05), tilt, CELL_PLASTER)
		_box(st, Vector3(0.24, 0.32, 0.24), Vector3(0.0, 1.72, half.y + 0.22), Basis.IDENTITY, CELL_WINDOW)
		_cyl(st, 0.22, 0.26, 0.65, 5, Vector3(-0.72, 0.33, -0.35), Basis.IDENTITY, CELL_STRAW)
		_box(st, Vector3(0.85, 0.38, 0.08), Vector3(0, 1.48, -0.62), Basis.IDENTITY, CELL_DARK_WOOD)
	st.index()
	return st.commit()


## Прибрежный лодочный навес на сваях с перевёрнутой деревянной лодкой и вешалами для сетей (barn size).
static func _build_boat_shed(level: int) -> ArrayMesh:
	var half := Vector2(2.0, 1.5)
	var wall_h := 2.15
	var pitch := 0.44
	var gable := half.x * tan(pitch)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	if level == 2:
		_box(st, Vector3(half.x * 2.0 + 0.1, 0.5, half.y * 2.0 + 0.1), Vector3(0, -0.25, 0), Basis.IDENTITY, CELL_STONE)
		_roof_slopes(st, half, wall_h, pitch, 0.55, 0.20, false)
		_box(st, Vector3(1.10, 0.65, 2.40), Vector3(-0.35, 0.85, 0.0), Basis.IDENTITY, CELL_DARK_WOOD)
		_box(st, Vector3(0.25, 1.55, 2.20), Vector3(1.55, 0.82, 0.0), Basis.IDENTITY, CELL_SHUTTER)
		st.index()
		return st.commit()

	_box(st, Vector3(half.x * 2.0 + 0.1, 0.5, half.y * 2.0 + 0.1), Vector3(0, -0.25, 0), Basis.IDENTITY, CELL_STONE)
	for sx: float in [-half.x + 0.12, half.x - 0.12]:
		for sz: float in [-half.y + 0.12, 0.0, half.y - 0.12]:
			_box(st, Vector3(0.18, wall_h, 0.18), Vector3(sx, wall_h * 0.5, sz), Basis.IDENTITY, CELL_DARK_WOOD)
	_gable(st, half.x * 2.0, gable, half.y * 2.0, Vector3(0, wall_h, 0), CELL_TIMBER)
	_roof_slopes(st, half, wall_h, pitch, 0.55, 0.20, true)

	# Перевёрнутая лодка на козлах
	for cz: float in [-0.75, 0.75]:
		_box(st, Vector3(1.15, 0.45, 0.16), Vector3(-0.35, 0.225, cz), Basis.IDENTITY, CELL_RAIL)
	_box(st, Vector3(0.95, 0.14, 2.45), Vector3(-0.35, 0.52, 0), Basis.IDENTITY, CELL_TIMBER)
	_box(st, Vector3(0.58, 0.14, 2.25), Vector3(-0.56, 0.72, 0), Basis(Vector3.BACK, 0.55), CELL_TIMBER)
	_box(st, Vector3(0.58, 0.14, 2.25), Vector3(-0.14, 0.72, 0), Basis(Vector3.BACK, -0.55), CELL_TIMBER)
	_box(st, Vector3(0.14, 0.16, 2.60), Vector3(-0.35, 0.90, 0), Basis.IDENTITY, CELL_DARK_WOOD)

	# Вешала с сетями у правого борта (+X)
	_box(st, Vector3(0.12, 1.50, 0.12), Vector3(1.48, 0.75, -1.05), Basis.IDENTITY, CELL_RAIL)
	_box(st, Vector3(0.12, 1.50, 0.12), Vector3(1.48, 0.75, 1.05), Basis.IDENTITY, CELL_RAIL)
	_box(st, Vector3(0.10, 0.10, 2.25), Vector3(1.48, 1.48, 0), Basis.IDENTITY, CELL_RAIL)
	_box(st, Vector3(0.16, 1.15, 1.95), Vector3(1.52, 0.85, 0), Basis.IDENTITY, CELL_SHUTTER)

	if level == 0:
		for sz: float in [-half.y + 0.12, 0.0, half.y - 0.12]:
			_box(st, Vector3(half.x * 2.0 - 0.1, 0.16, 0.16), Vector3(0, wall_h - 0.08, sz), Basis.IDENTITY, CELL_DARK_WOOD)
		_cyl(st, 0.26, 0.26, 0.22, 6, Vector3(0.68, 0.11, 0.92), Basis.IDENTITY, CELL_STRAW)
		_cyl(st, 0.24, 0.26, 0.72, 6, Vector3(0.85, 0.36, -0.78), Basis.IDENTITY, CELL_TIMBER)
		_box(st, Vector3(0.10, 1.85, 0.12), Vector3(0.45, 0.92, -1.35), Basis(Vector3.RIGHT, 0.20), CELL_RAIL)
	st.index()
	return st.commit()


## Длинная крытая поленница с козлами для распилки брёвен и колодой (shed size).
static func _build_woodpile_rack(level: int) -> ArrayMesh:
	var half := Vector2(1.1, 0.75)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	_box(st, Vector3(half.x * 2.0, 0.5, half.y * 2.0), Vector3(0, -0.25, 0), Basis.IDENTITY, CELL_STONE)
	_box(st, Vector3(2.15, 0.12, 0.95), Vector3(0, 1.65, -0.22), Basis(Vector3.RIGHT, 0.26), CELL_ROOF)
	_box(st, Vector3(1.90, 0.98, 0.62), Vector3(0, 0.50, -0.25), Basis.IDENTITY, CELL_LOGS_END)

	if level == 2:
		_box(st, Vector3(0.65, 0.58, 0.55), Vector3(0.55, 0.29, 0.38), Basis.IDENTITY, CELL_TIMBER)
		st.index()
		return st.commit()

	for sx: float in [-0.98, 0.0, 0.98]:
		_box(st, Vector3(0.11, 1.68, 0.11), Vector3(sx, 0.84, -0.62), Basis.IDENTITY, CELL_DARK_WOOD)
	_box(st, Vector3(1.94, 0.22, 0.66), Vector3(0, 1.05, -0.25), Basis.IDENTITY, CELL_TIMBER)
	_cyl(st, 0.24, 0.26, 0.58, 6, Vector3(0.62, 0.29, 0.38), Basis.IDENTITY, CELL_LOGS_END)
	_cyl(st, 0.11, 0.11, 1.35, 6, Vector3(-0.35, 0.54, 0.35), Basis(Vector3.BACK, PI / 2.0), CELL_TIMBER)

	if level == 0:
		for sx: float in [-0.72, 0.02]:
			_box(st, Vector3(0.08, 0.68, 0.08), Vector3(sx, 0.32, 0.35), Basis(Vector3.RIGHT, 0.45), CELL_DARK_WOOD)
			_box(st, Vector3(0.08, 0.68, 0.08), Vector3(sx, 0.32, 0.35), Basis(Vector3.RIGHT, -0.45), CELL_DARK_WOOD)
		_box(st, Vector3(0.06, 0.28, 0.18), Vector3(0.62, 0.66, 0.38), Basis(Vector3.BACK, -0.35), CELL_METAL)
		_box(st, Vector3(0.05, 0.45, 0.05), Vector3(0.76, 0.80, 0.38), Basis(Vector3.BACK, -0.55), CELL_RAIL)
		for lx: float in [-0.55, 0.0, 0.55]:
			_cyl(st, 0.12, 0.12, 0.58, 5, Vector3(lx, 1.24, -0.25), Basis(Vector3.RIGHT, PI / 2.0), CELL_LOGS_END)
	st.index()
	return st.commit()


# ---------------- Примитивы с точными UV атласа ----------------

static func _roof_slopes(st: SurfaceTool, half: Vector2, top: float, pitch: float, eave: float, thick: float, ridge: bool,
		origin: Vector3 = Vector3.ZERO, eave_z: float = -1.0) -> void:
	var ez := eave if eave_z < 0.0 else eave_z
	var gable := half.x * tan(pitch)
	var run := half.x + eave
	var depth := half.y * 2.0 + ez * 2.0
	for side: float in [-1.0, 1.0]:
		var mid := origin + Vector3(side * run * 0.5, top + gable - run * tan(pitch) * 0.5, 0)
		mid += Vector3(side * sin(pitch), cos(pitch), 0) * thick * 0.5
		var b := Basis(Vector3.BACK, -side * pitch)
		_box(st, Vector3(run / cos(pitch), thick, depth), mid, b, CELL_ROOF)
	if ridge:
		_box(st, Vector3(0.30, 0.30, depth), origin + Vector3(0, top + gable + thick * 0.8, 0), Basis(Vector3.BACK, PI / 4.0), CELL_ROOF)


static func _roof_slopes_asym(st: SurfaceTool, half: Vector2, top: float, pitch: float, eave_l: float, eave_r: float, eave_z: float,
		thick: float, ridge: bool) -> void:
	var gable := half.x * tan(pitch)
	var depth := half.y * 2.0 + eave_z * 2.0
	for item: Array in [[-1.0, eave_l], [1.0, eave_r]]:
		var side: float = item[0]
		var run: float = half.x + float(item[1])
		var mid := Vector3(side * run * 0.5, top + gable - run * tan(pitch) * 0.5, 0)
		mid += Vector3(side * sin(pitch), cos(pitch), 0) * thick * 0.5
		_box(st, Vector3(run / cos(pitch), thick, depth), mid, Basis(Vector3.BACK, -side * pitch), CELL_ROOF)
	if ridge:
		_box(st, Vector3(0.30, 0.30, depth), Vector3(0, top + gable + thick * 0.8, 0), Basis(Vector3.BACK, PI / 4.0), CELL_ROOF)


static func _dormer(st: SurfaceTool, rot_y: float, pos: Vector3, width: float, wall_h: float, gable_h: float, depth: float,
		wall_cell: int, level: int) -> void:
	var b := Basis(Vector3.UP, rot_y)
	_box(st, Vector3(width, wall_h, depth), pos + b * Vector3(0, wall_h * 0.5, 0), b, wall_cell)
	_gable(st, width, gable_h, depth, pos + b * Vector3(0, wall_h, 0), wall_cell, b)
	var pitch := atan2(gable_h, width * 0.5)
	var run := width * 0.5 + 0.16
	var rdepth := depth + 0.24
	for side: float in [-1.0, 1.0]:
		var local_mid := Vector3(side * run * 0.5, wall_h + gable_h - run * tan(pitch) * 0.5, 0.04)
		local_mid += Vector3(side * sin(pitch), cos(pitch), 0) * 0.06
		var rb := b * Basis(Vector3.BACK, -side * pitch)
		_box(st, Vector3(run / cos(pitch), 0.12, rdepth), pos + b * local_mid, rb, CELL_ROOF)
	var win_scale := 0.52 if level <= 1 else 0.45
	_box(st, Vector3(win_scale, win_scale * 1.15, 0.08), pos + b * Vector3(0, wall_h * 0.54, depth * 0.5 + 0.02), b, CELL_WINDOW)


static func _window(st: SurfaceTool, angle: float, pos: Vector3, shutters: bool) -> void:
	var b := Basis(Vector3.UP, angle)
	var origin := b * pos
	_box(st, Vector3(0.62, 0.78, 0.08), origin, b, CELL_WINDOW)
	if shutters:
		for sx: float in [-0.48, 0.48]:
			_box(st, Vector3(0.30, 0.84, 0.05), origin + b * Vector3(sx, 0, 0.04), b, CELL_SHUTTER)


## Прямоугольный ящик с лёгким затенением низа по вершинам и UV внутри ячейки cell.
static func _box(st: SurfaceTool, size: Vector3, center: Vector3, basis: Basis, cell: int, tint: Color = Color.WHITE) -> void:
	var hx := size.x * 0.5
	var hy := size.y * 0.5
	var hz := size.z * 0.5
	var uv_r := cell_uv_rect(cell)
	var faces := [
		[[Vector3(-hx, -hy, hz), Vector3(hx, -hy, hz), Vector3(hx, hy, hz), Vector3(-hx, hy, hz)], Vector3(0, 0, 1)],
		[[Vector3(hx, -hy, -hz), Vector3(-hx, -hy, -hz), Vector3(-hx, hy, -hz), Vector3(hx, hy, -hz)], Vector3(0, 0, -1)],
		[[Vector3(hx, -hy, hz), Vector3(hx, -hy, -hz), Vector3(hx, hy, -hz), Vector3(hx, hy, hz)], Vector3(1, 0, 0)],
		[[Vector3(-hx, -hy, -hz), Vector3(-hx, -hy, hz), Vector3(-hx, hy, hz), Vector3(-hx, hy, -hz)], Vector3(-1, 0, 0)],
		[[Vector3(-hx, hy, hz), Vector3(hx, hy, hz), Vector3(hx, hy, -hz), Vector3(-hx, hy, -hz)], Vector3(0, 1, 0)],
		[[Vector3(-hx, -hy, -hz), Vector3(hx, -hy, -hz), Vector3(hx, -hy, hz), Vector3(-hx, -hy, hz)], Vector3(0, -1, 0)],
	]
	var uvs := [
		Vector2(uv_r.position.x, uv_r.end.y),
		Vector2(uv_r.end.x, uv_r.end.y),
		Vector2(uv_r.end.x, uv_r.position.y),
		Vector2(uv_r.position.x, uv_r.position.y),
	]
	for f: Array in faces:
		var pts: Array = f[0]
		var nrm: Vector3 = (basis * (f[1] as Vector3)).normalized()
		for idx: int in [0, 2, 1, 0, 3, 2]:
			var lp: Vector3 = pts[idx]
			var shade := 0.88 if lp.y < 0.0 else 1.0
			st.set_color(Color(tint.r * shade, tint.g * shade, tint.b * shade, tint.a))
			st.set_normal(nrm)
			st.set_uv(uvs[idx])
			st.add_vertex(center + basis * lp)


## Треугольная призма фронтона (ось вдоль Z в локальной базе basis, конёк сверху).
static func _gable(st: SurfaceTool, width: float, height: float, depth: float, base_center: Vector3, cell: int,
		basis: Basis = Basis.IDENTITY) -> void:
	var hx := width * 0.5
	var hz := depth * 0.5
	var uv_r := cell_uv_rect(cell)
	var fl := base_center + basis * Vector3(-hx, 0, hz)
	var fr := base_center + basis * Vector3(hx, 0, hz)
	var ft := base_center + basis * Vector3(0, height, hz)
	var bl := base_center + basis * Vector3(-hx, 0, -hz)
	var br := base_center + basis * Vector3(hx, 0, -hz)
	var bt := base_center + basis * Vector3(0, height, -hz)
	var u_mid := (uv_r.position.x + uv_r.end.x) * 0.5
	var u_bl := Vector2(uv_r.position.x, uv_r.end.y)
	var u_br := Vector2(uv_r.end.x, uv_r.end.y)
	var u_top := Vector2(u_mid, uv_r.position.y)
	var u_tl := Vector2(uv_r.position.x, uv_r.position.y)
	var u_tr := Vector2(uv_r.end.x, uv_r.position.y)

	_tri(st, fl, ft, fr, (basis * Vector3(0, 0, 1)).normalized(), u_bl, u_top, u_br)
	_tri(st, br, bt, bl, (basis * Vector3(0, 0, -1)).normalized(), u_bl, u_top, u_br)
	var nr := (basis * Vector3(height, hx, 0)).normalized()
	var nl := (basis * Vector3(-height, hx, 0)).normalized()
	_tri(st, fr, ft, bt, nr, u_bl, u_tl, u_tr)
	_tri(st, fr, bt, br, nr, u_bl, u_tr, u_br)
	_tri(st, bl, bt, ft, nl, u_bl, u_tl, u_tr)
	_tri(st, bl, ft, fl, nl, u_bl, u_tr, u_br)
	var nd := (basis * Vector3(0, -1, 0)).normalized()
	_tri(st, fl, fr, br, nd, u_bl, u_br, u_tr)
	_tri(st, fl, br, bl, nd, u_bl, u_tr, u_tl)


## Трапецеидальная призма нижнего яруса мансарды (ось вдоль Z, bottom -> top сужается к верху).
static func _trapezoid(st: SurfaceTool, w_bot: float, w_top: float, height: float, depth: float, base_center: Vector3, cell: int) -> void:
	var hxb := w_bot * 0.5
	var hxt := w_top * 0.5
	var hz := depth * 0.5
	var uv_r := cell_uv_rect(cell)
	var u_bl := Vector2(uv_r.position.x, uv_r.end.y)
	var u_br := Vector2(uv_r.end.x, uv_r.end.y)
	var u_tl := Vector2(uv_r.position.x, uv_r.position.y)
	var u_tr := Vector2(uv_r.end.x, uv_r.position.y)

	var flb := base_center + Vector3(-hxb, 0, hz)
	var frb := base_center + Vector3(hxb, 0, hz)
	var flt := base_center + Vector3(-hxt, height, hz)
	var frt := base_center + Vector3(hxt, height, hz)
	var blb := base_center + Vector3(-hxb, 0, -hz)
	var brb := base_center + Vector3(hxb, 0, -hz)
	var blt := base_center + Vector3(-hxt, height, -hz)
	var brt := base_center + Vector3(hxt, height, -hz)

	_tri(st, flb, flt, frt, Vector3(0, 0, 1), u_bl, u_tl, u_tr)
	_tri(st, flb, frt, frb, Vector3(0, 0, 1), u_bl, u_tr, u_br)
	_tri(st, brb, brt, blt, Vector3(0, 0, -1), u_bl, u_tl, u_tr)
	_tri(st, brb, blt, blb, Vector3(0, 0, -1), u_bl, u_tr, u_br)
	var nr := Vector3(height, hxb - hxt, 0).normalized()
	var nl := Vector3(-height, hxb - hxt, 0).normalized()
	_tri(st, frb, frt, brt, nr, u_bl, u_tl, u_tr)
	_tri(st, frb, brt, brb, nr, u_bl, u_tr, u_br)
	_tri(st, blb, blt, flt, nl, u_bl, u_tl, u_tr)
	_tri(st, blb, flt, flb, nl, u_bl, u_tr, u_br)
	_tri(st, flt, blt, brt, Vector3(0, 1, 0), u_bl, u_tl, u_tr)
	_tri(st, flt, brt, frt, Vector3(0, 1, 0), u_bl, u_tr, u_br)
	_tri(st, flb, frb, brb, Vector3(0, -1, 0), u_bl, u_br, u_tr)
	_tri(st, flb, brb, blb, Vector3(0, -1, 0), u_bl, u_tr, u_tl)


static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, nrm: Vector3, uva: Vector2, uvb: Vector2, uvc: Vector2) -> void:
	for item: Array in [[a, uva], [b, uvb], [c, uvc]]:
		st.set_color(Color.WHITE)
		st.set_normal(nrm)
		st.set_uv(item[1])
		st.add_vertex(item[0])


static func _cyl(st: SurfaceTool, rt: float, rb: float, h: float, seg: int, center: Vector3, basis: Basis, cell: int) -> void:
	var uv_r := cell_uv_rect(cell)
	var hy := h * 0.5
	for k in seg:
		var a0 := TAU * k / seg
		var a1 := TAU * (k + 1) / seg
		var b0 := Vector3(cos(a0) * rb, -hy, sin(a0) * rb)
		var b1 := Vector3(cos(a1) * rb, -hy, sin(a1) * rb)
		var t0 := Vector3(cos(a0) * rt, hy, sin(a0) * rt)
		var t1 := Vector3(cos(a1) * rt, hy, sin(a1) * rt)
		var mid_a := (a0 + a1) * 0.5
		var nrm := (basis * Vector3(cos(mid_a), (rb - rt) / maxf(h, 0.1), sin(mid_a))).normalized()
		var u0 := lerpf(uv_r.position.x, uv_r.end.x, float(k) / seg)
		var u1 := lerpf(uv_r.position.x, uv_r.end.x, float(k + 1) / seg)
		if rt > 0.001:
			_tri(st, center + basis * b0, center + basis * t1, center + basis * t0, nrm, Vector2(u0, uv_r.end.y), Vector2(u1, uv_r.position.y), Vector2(u0, uv_r.position.y))
			_tri(st, center + basis * b0, center + basis * b1, center + basis * t1, nrm, Vector2(u0, uv_r.end.y), Vector2(u1, uv_r.end.y), Vector2(u1, uv_r.position.y))
			_tri(st, center + basis * Vector3(0, hy, 0), center + basis * t0, center + basis * t1, (basis * Vector3.UP).normalized(), uv_r.get_center(), uv_r.position, uv_r.end)
		else:
			_tri(st, center + basis * b0, center + basis * b1, center + basis * Vector3(0, hy, 0), nrm, Vector2(u0, uv_r.end.y), Vector2(u1, uv_r.end.y), Vector2((u0 + u1) * 0.5, uv_r.position.y))
		_tri(st, center + basis * Vector3(0, -hy, 0), center + basis * b1, center + basis * b0, (basis * Vector3.DOWN).normalized(), uv_r.get_center(), uv_r.position, uv_r.end)
