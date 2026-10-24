class_name GeologyData
extends RefCounted
## Рельеф, гидрология и природные ориентиры. Единственный владелец этих полей; WorldData — фасад.
const GridBuffer = preload("res://scripts/core/grid_buffer_2d.gd")
const CACHE_FIELDS := ["h", "filled", "elev", "ocean", "lake", "river", "river_area", "acc", "slope", "watershed", "down", "rain", "dist_ocean", "dist_water", "lake_id", "macro_x", "macro_y", "mountain_scale", "mountain_bias", "mountain_height", "foothill_spread", "order", "order_n", "rivers", "river_exits", "peaks", "lakes"]
var layout: GridBuffer.Layout
var h: GridBuffer.Float32
var filled: GridBuffer.Float32
var elev: GridBuffer.Float32
var ocean: GridBuffer.Byte
var lake: GridBuffer.Byte
var river: GridBuffer.Byte
var river_area: GridBuffer.Byte
var acc: GridBuffer.Float32
var slope: GridBuffer.Float32
var watershed: GridBuffer.Int32
var down: GridBuffer.Int32
var rain: GridBuffer.Float32
var dist_ocean: GridBuffer.Float32
var dist_water: GridBuffer.Float32
var lake_id: GridBuffer.Int32
var macro_x := 0.0       # сдвиг шума материков в клетках: где в бесконечном мире лежит стартовая область (StageRelief)
var macro_y := 0.0
var mountain_scale := 1.0  # масштаб массивов, гребней и внутренних долин
var mountain_bias := 0.3   # распространённость гор: ниже — реже
var mountain_height := 1.0 # высота горного подъёма
var foothill_spread := 0.0 # ширина и выраженность предгорий (с 3.6), 0 — без дополнительного пояса
var order := PackedInt32Array()      # порядок заполнения впадин
var order_n := 0
var rivers: Array = []        # ломаные из точек {x, y, w — ширина в клетках, e — высота воды}
var river_exits: Array = []   # выходы за карту: {x, y, dx, dy, acc, e, w}; задел для продолжения стока
var peaks: Array = []         # [{x, y, i, elev, name}]
var lakes: Array[LakeData] = []         # озёра с названиями (с 2.9) [{x, y, i, level, name, cells, sx, sy}], см. StageLakes


func _init(shape: GridBuffer.Layout) -> void:
	layout = shape
	h = GridBuffer.Float32.new(shape)
	filled = GridBuffer.Float32.new(shape)
	elev = GridBuffer.Float32.new(shape)
	ocean = GridBuffer.Byte.new(shape)
	lake = GridBuffer.Byte.new(shape)
	river = GridBuffer.Byte.new(shape)
	river_area = GridBuffer.Byte.new(shape)
	acc = GridBuffer.Float32.new(shape)
	slope = GridBuffer.Float32.new(shape)
	watershed = GridBuffer.Int32.new(shape)
	down = GridBuffer.Int32.new(shape)
	rain = GridBuffer.Float32.new(shape)
	dist_ocean = GridBuffer.Float32.new(shape)
	dist_water = GridBuffer.Float32.new(shape)
	lake_id = GridBuffer.Int32.new(shape)


func river_mask(cell_count: int) -> GridBuffer.Byte:
	return river_area if river_area.data.size() == cell_count else river


func lake_near(x: float, y: float, r: int) -> int:
	if lake_id.data.is_empty():
		return -1
	var tx := floori(x)
	var ty := floori(y)
	for dy in range(maxi(0, ty - r), mini(layout.height, ty + r + 1)):
		for dx in range(maxi(0, tx - r), mini(layout.width, tx + r + 1)):
			var id := lake_id.get_cell(dx, dy)
			if id >= 0:
				return id
	return -1


## Есть ли озеро id в квадрате ±r клеток вокруг точки (клетки)
func lake_within(x: float, y: float, r: int, id: int) -> bool:
	if lake_id.data.is_empty():
		return false
	var tx := floori(x)
	var ty := floori(y)
	for dy in range(maxi(0, ty - r), mini(layout.height, ty + r + 1)):
		for dx in range(maxi(0, tx - r), mini(layout.width, tx + r + 1)):
			if lake_id.get_cell(dx, dy) == id:
				return true
	return false


