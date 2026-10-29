class_name WorldStreamCoordinator
extends RefCounted
## The frame's upload budget and ordering, independent of concrete scene nodes.
signal region_committed
var vegetation_update: Callable
var vegetation_budgeted: Callable
var terrain_update: Callable
var water_update: Callable
var outer_update: Callable
var region_priority: Callable
var region_update: Callable
var region_restore: Callable
const MAX_REGION_WAIT := 8
var _region_wait := 0
var publication_budget_us := 2500
var _turn := 0
var stats := {frames = 0, elapsed_us = 0, max_us = 0, over_budget = 0, grants = [0, 0, 0]}

func restore_regions(pos: Vector3) -> void:
	if region_restore.is_valid():
		region_restore.call(pos.x, pos.z)

func force_terrain(pos: Vector3, radius: float) -> void:
	terrain_update.call(pos.x, pos.z, true, true, radius)
	if water_update.is_valid(): water_update.call(pos.x, pos.z, true, true, radius)

func force_vegetation(pos: Vector3) -> void:
	vegetation_update.call(pos.x, pos.z, true)

func update(pos: Vector3) -> void:
	var started := Time.get_ticks_usec()
	var uploaded := false
	var region_ticked := false
	# Длинная очередь леса не должна лишать соседние области возможности начать/закончить подготовку.
	if (_region_wait >= MAX_REGION_WAIT or (region_priority.is_valid() and region_priority.call())) and region_update.is_valid() and vegetation_budgeted.is_valid():
		uploaded = region_update.call(pos.x, pos.z)
		region_ticked = true
		_region_wait = 0
		if uploaded:
			region_committed.emit()
	# Rotate first opportunity. Housekeeping still runs with allow=false after budget exhaustion.
	for offset in 3:
		var group := (_turn + offset) % 3
		var allow := not uploaded and Time.get_ticks_usec() - started < publication_budget_us
		var changed := false
		if group == 0:
			if vegetation_budgeted.is_valid(): changed = vegetation_budgeted.call(pos.x, pos.z, false, allow)
			elif vegetation_update.is_valid() and allow: changed = vegetation_update.call(pos.x, pos.z, false)
		elif group == 1 and terrain_update.is_valid(): changed = terrain_update.call(pos.x, pos.z, false, allow)
		elif group == 2 and water_update.is_valid(): changed = water_update.call(pos.x, pos.z, false, allow)
		if changed: stats.grants[group] += 1
		uploaded = changed or uploaded
	_turn = (_turn + 1) % 3
	if outer_update.is_valid():
		outer_update.call(pos.x, pos.z, not uploaded and Time.get_ticks_usec() - started < publication_budget_us)
	if not region_ticked:
		if not uploaded and region_update.is_valid() and Time.get_ticks_usec() - started < publication_budget_us:
			_region_wait = 0
			if region_update.call(pos.x, pos.z):
				region_committed.emit()
		else:
			_region_wait += 1
	var elapsed := Time.get_ticks_usec() - started
	stats.frames += 1
	stats.elapsed_us += elapsed
	stats.max_us = maxi(stats.max_us, elapsed)
	stats.over_budget += int(elapsed > publication_budget_us)
