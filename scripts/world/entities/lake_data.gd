class_name LakeData
extends EntityRecord
const FIELDS := ["x", "y", "i", "level", "name", "cells", "sx", "sy"]
var x: float = 0.0
var y: float = 0.0
var i: int = -1
var level: float = 0.0
var name: String = ""
var cells: int = 0
var sx: float = 0.0
var sy: float = 0.0

func _init(px: float = 0.0, py: float = 0.0, index: int = -1, height: float = 0.0, title: String = "", area: int = 0, shore_x: float = 0.0, shore_y: float = 0.0) -> void:
	x = px
	y = py
	i = index
	level = height
	name = title
	cells = area
	sx = shore_x
	sy = shore_y

static func from_dict(data: Dictionary) -> LakeData:
	var result := LakeData.new()
	if data.has("x"):
		result.x = data["x"]
	if data.has("y"):
		result.y = data["y"]
	if data.has("i"):
		result.i = data["i"]
	if data.has("level"):
		result.level = data["level"]
	if data.has("name"):
		result.name = data["name"]
	if data.has("cells"):
		result.cells = data["cells"]
	if data.has("sx"):
		result.sx = data["sx"]
	if data.has("sy"):
		result.sy = data["sy"]
	return result
