class_name WorldStreamCoordinator
extends RefCounted
## The frame's upload budget and ordering, independent of concrete scene nodes.
signal region_committed
var vegetation_update: Callable
var vegetation_budgeted: Callable
var terrain_update: Callable
var outer_update: Callable
var region_update: Callable
var region_restore: Callable
const MAX_REGION_WAIT := 8
var _region_wait := 0

func restore_regions(pos: Vector3) -> void:
	if region_restore.is_valid():
		region_restore.call(pos.x, pos.z)

func force_terrain(pos: Vector3, radius: float) -> void:
	terrain_update.call(pos.x, pos.z, true, true, radius)

func force_vegetation(pos: Vector3) -> void:
	vegetation_update.call(pos.x, pos.z, true)

func update(pos: Vector3) -> void:
	var uploaded := false
	var region_ticked := false
	# Длинная очередь леса не должна лишать соседние области возможности начать/закончить подготовку.
	if _region_wait >= MAX_REGION_WAIT and region_update.is_valid() and vegetation_budgeted.is_valid():
		uploaded = region_update.call(pos.x, pos.z)
		region_ticked = true
		_region_wait = 0
		if uploaded:
			region_committed.emit()
	if vegetation_budgeted.is_valid():
		uploaded = vegetation_budgeted.call(pos.x, pos.z, false, not uploaded) or uploaded
	else:
		uploaded = vegetation_update.call(pos.x, pos.z, false)
	uploaded = terrain_update.call(pos.x, pos.z, false, not uploaded) or uploaded
	if outer_update.is_valid():
		outer_update.call(pos.x, pos.z, not uploaded)
	if not region_ticked:
		if not uploaded and region_update.is_valid():
			_region_wait = 0
			if region_update.call(pos.x, pos.z):
				region_committed.emit()
		else:
			_region_wait += 1
