class_name ServiceScope
extends RefCounted
## Pass a separate scope to independent loaders/simulations; no process-wide state.
var settings := GameSettings.new()
var controls := Controls.new()
var cache := WorldCache.new()
var terrain := TerrainBuilder.new()

func reset() -> void:
	cache.reset()
	settings.reset()
	controls.reset()
	terrain.reset()
