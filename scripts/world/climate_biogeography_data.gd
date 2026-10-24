class_name ClimateBiogeographyData
extends RefCounted
## Климат, биомы и столбцы объектов растительности. Без потоков, стриминга и обратной ссылки на мир.
const GridBuffer = preload("res://scripts/core/grid_buffer_2d.gd")
const CACHE_FIELDS := ["temp", "moist", "biome", "obj_x", "obj_y", "obj_k", "obj_v", "obj_s", "chunks", "CS", "CW", "CH", "obj_count"]
var layout: GridBuffer.Layout
var temp: GridBuffer.Float32
var moist: GridBuffer.Float32
var biome: GridBuffer.Byte
var obj_x := PackedFloat64Array()
var obj_y := PackedFloat64Array()
var obj_k := PackedInt32Array()      # вид из Biomes.T_*
var obj_v := PackedInt32Array()      # вариант
var obj_s := PackedFloat64Array()    # масштаб
var chunks: Array[PackedInt32Array] = []
var CS := 0
var CW := 0
var CH := 0
var obj_count := 0


func _init(shape: GridBuffer.Layout, chunk_size: int) -> void:
	layout = shape
	CS = chunk_size
	temp = GridBuffer.Float32.new(shape)
	moist = GridBuffer.Float32.new(shape)
	biome = GridBuffer.Byte.new(shape)
