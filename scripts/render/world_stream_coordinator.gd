class_name WorldStreamCoordinator
extends RefCounted
## The frame's upload budget and ordering, independent of concrete scene nodes.
signal region_committed
var vegetation_update: Callable
var terrain_update: Callable
var outer_update: Callable
var region_update: Callable
var region_restore: Callable

func restore_regions(pos: Vector3) -> void:
	if region_restore.is_valid():
		region_restore.call(pos.x, pos.z)

func force_terrain(pos: Vector3, radius: float) -> void:
	terrain_update.call(pos.x, pos.z, true, true, radius)

func force_vegetation(pos: Vector3) -> void:
	vegetation_update.call(pos.x, pos.z, true)

func update(pos: Vector3) -> void:
	var uploaded: bool = vegetation_update.call(pos.x, pos.z, false)
	uploaded = terrain_update.call(pos.x, pos.z, false, not uploaded) or uploaded
	if outer_update.is_valid():
		outer_update.call(pos.x, pos.z, not uploaded)
	if not uploaded and region_update.is_valid() and region_update.call(pos.x, pos.z):
		region_committed.emit()
