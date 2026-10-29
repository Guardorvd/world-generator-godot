class_name ServiceScope
extends RefCounted
## Pass a separate scope to independent loaders/simulations; no process-wide state.
var settings := GameSettings.new()
var controls := Controls.new()
var cache := WorldCache.new()
var terrain := TerrainBuilder.new()
var cpu_budget := preload("res://scripts/core/cpu_cache_budget.gd").new()
var resource_profile: RefCounted
var loaded_worlds := 0

func _init() -> void:
	cache.cpu_budget = cpu_budget

func reset() -> void:
	cache.reset()
	settings.reset()
	controls.reset()
	terrain.reset()
