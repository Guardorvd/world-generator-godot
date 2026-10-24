class_name CivilInfrastructureData
extends RefCounted
## Стоимость прохода, дорожные покрытия, сооружения, поселения и места инфраструктуры.
const GridBuffer = preload("res://scripts/core/grid_buffer_2d.gd")
const CACHE_FIELDS := ["cost", "path_mask", "road_surface", "trails", "bridges", "tunnels", "settlements", "sites"]
var layout: GridBuffer.Layout
var cost: GridBuffer.Float32
var path_mask: GridBuffer.Byte
var road_surface: GridBuffer.Byte
var trails: Array = []        # [{kind: "animal" | "trail" | "mountain" | "road", pts, surf — покрытие точек (RoadSurface)}]
var bridges: Array[BridgeData] = []       # мосты [{a, b}]: клетки на берегах, мост — прямой отрезок между их центрами
var tunnels: Array[TunnelData] = []       # туннели [{a, b}]: клетки у входов, туннель — прямой отрезок между ними
var settlements: Array[SettlementData] = []   # [{x, y, i, name, character, spacing, importance, huts: [{x, y, v}], connections: [i соседей по путям]}]
var sites: Array[SiteData] = []         # места вне поселений (с 9.3) [{x, y, i, type, rank, name, clear, huts: [{x, y, v, t, a}]}], см. StageSites


func _init(shape: GridBuffer.Layout) -> void:
	layout = shape
	cost = GridBuffer.Float32.new(shape)
	path_mask = GridBuffer.Byte.new(shape)
	road_surface = GridBuffer.Byte.new(shape)
