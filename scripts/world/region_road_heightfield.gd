extends "res://scripts/game/heightfield.gd"
## Временный адаптер готовой растровой воды соседей для штатных проверок мостов.
## Русло уже вырезано RegionWaterSurface: повторно строить ленты и резать землю нельзя.
var prepared_levels := PackedFloat32Array()
var has_prepared_water := false


func _init(w: WorldData, levels: PackedFloat32Array) -> void:
	prepared_levels = levels
	for value: float in levels:
		if is_finite(value):
			has_prepared_water = true
			break
	super(w, false)


func river_level(x: float, z: float) -> float:
	var cx := floori(x / TILE)
	var cy := floori(z / TILE)
	if cx < 0 or cy < 0 or cx >= world.W or cy >= world.H: return -INF
	return prepared_levels[cy * world.W + cx] * HS


func fast_water() -> Object:
	# Штатный C# sampler принимает ленты рек, а здесь источником служит готовый растр.
	return null if has_prepared_water else super.fast_water()
