extends SceneTree
const Policy := preload("res://scripts/render/vegetation_stream_policy.gd")
const Snapshots := preload("res://scripts/render/vegetation_snapshots.gd")
var fails := 0

class ContactLayer extends VegetationLayer:
	var version_at_upload := {}
	func _present_group(group: int, _immediate: bool) -> void:
		version_at_upload[group] = obstacles_version

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	if not ok:
		fails += 1
		printerr(label)

func rows(xs: Array) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(xs.size() * 20)
	for i in xs.size():
		VegetationLayer._put_xform(result, i * 20, xs[i], 0, 0, 0, 1, 1)
	return result

func stamp(frame: Dictionary, x: float) -> float:
	for at in range(0, frame.count * 20, 20):
		if is_equal_approx(frame.buffer[at + 3], x):
			return frame.buffer[at + 19]
	push_error("Missing instance %s" % x)
	fails += 1
	return 0.0

func contact_publication() -> void:
	var layer := ContactLayer.new()
	layer.understory = [{}, {}, {}]
	layer._last_contact_group = 1
	layer._obstacles_next = PackedFloat32Array([4, 0, 4, 0, 0.3, 0, 0.4])
	layer._bumps_next = PackedFloat32Array([5, 0, 5, 0, 0.3, 0.1])
	layer._begin_present()
	layer._present_next(Time.get_ticks_usec() - 1)
	check(layer.obstacles_version == 0 and layer.obstacles.is_empty() and layer.bumps.is_empty(),
		"Waiting for GPU budget leaves both contact buffers unpublished")
	layer._present_next(0)
	check(layer.version_at_upload == {-1: 0, 0: 0, 1: 0, 2: 1},
		"Contacts publish after the last obstacle group, without waiting for later decorations")
	check(layer.obstacles == layer._obstacles_next and layer.bumps == layer._bumps_next,
		"Solids and wheel bumps publish together")
	layer.version_at_upload.clear()
	layer._apply_grass(true)
	check(layer.version_at_upload == {-1: 1, 0: 1, 1: 1, 2: 1} and layer.obstacles_version == 2,
		"Forced publication also uploads before publishing contacts")
	layer.free()


func stale_contacts() -> void:
	var world := WorldData.new()
	var heights := Heightfield.new()
	var forest := ForestObstacles.new(world, heights)
	forest.async_rebuild = true
	forest.update(0, 0, PackedFloat32Array([4, 0, 4, 0, 0.3, 0, 0.4]), 1)
	while not WorkerThreadPool.is_task_completed(forest._task):
		await process_frame
	forest.update(0, 0, PackedFloat32Array(), 2)
	check(not forest.hits(4, 0, 0, 0.1), "A completed worker cannot install a superseded solid")
	forest.finish()


func run() -> void:
	contact_publication()
	await stale_contacts()
	var history := Snapshots.new()
	var bounds := AABB(Vector3.ZERO, Vector3.ONE * 40)
	var first := rows([10, 20])
	var frozen := first.duplicate()
	var frame := history.merge(0, first, 2, bounds, 1, 10, true)
	check(stamp(frame, 10) == 0.0, "Initial/teleported plants are immediately mature")
	frame = history.merge(0, rows([20, 30]), 2, bounds, 1, 10)
	check(frame.count == 3, "Outgoing instance is retained without duplicating the shared plant")
	check(stamp(frame, 20) == 0.0, "Shared plants do not restart their fade")
	check(is_equal_approx(Snapshots.opacity(stamp(frame, 30), 10), 0.0), "New plant starts invisible")
	check(is_equal_approx(Snapshots.opacity(stamp(frame, 30), 10.25), 0.5), "New plant fades in over time")
	check(is_equal_approx(Snapshots.opacity(stamp(frame, 10), 10.25), 0.5), "Removed plant fades out over time")
	check(not history.cleanup_due(10.25) and history.cleanup_due(10.51), "Expired outgoing records request cleanup even while the player is stationary")
	check(first == frozen, "Presentation does not mutate worker buffers")
	frame = history.merge(0, rows([20]), 1, bounds, 1, 10.1)
	check(absf(Snapshots.opacity(stamp(frame, 30), 10.1) - 0.2) < 0.00001, "Removing a half-born plant preserves its current opacity")
	var outgoing := stamp(frame, 30)
	frame = history.merge(0, rows([20, 30]), 2, bounds, 1, 10.15)
	check(absf(Snapshots.opacity(stamp(frame, 30), 10.15) - Snapshots.opacity(outgoing, 10.15)) < 0.00001, "Turning back reverses fading without an opacity jump")
	frame = history.merge(0, rows([20, 30]), 2, bounds, 1, 11)
	check(frame.count == 2, "Expired outgoing plants leave the history")
	check(not history.cleanup_due(11), "Cleanup does not schedule endless stationary rebuilds")
	var prepared := history.prepare(0, rows([20, 30, 40]), 3, bounds, 1, 11)
	check(history.displayed[0].size() == 40, "Worker preparation does not publish a partial snapshot")
	history.stamp(prepared, 11.5)
	frame = history.commit(0, prepared, 13)
	check(Snapshots.opacity(stamp(frame, 40), 13) == 0.0, "Late completion starts fading at upload, not at task launch")
	frame = history.merge(0, rows([]), 0, AABB(), 1, 14)
	frame = history.merge(0, rows([]), 0, AABB(), 1, 15)
	check(frame.count == 0, "Empty snapshots eventually release all retained plants")
	frame = history.merge(1, rows([10]), 1, bounds, 1, 16, true)
	frame = history.merge(1, rows([20]), 1, bounds, 1, 17, false, true)
	check(stamp(frame, 20) == 0.0 and stamp(frame, 10) < 0.0,
		"A new obstacle is visible immediately, while the outgoing obstacle can fade")
	frame = history.merge(1, rows([10, 20]), 2, bounds, 1, 17.2, false, true)
	check(stamp(frame, 10) == 0.0, "Returning obstacles are fully visible before their contacts can return")
	var stamped := []
	for fast in [false, true]:
		Snapshots.allow_fast_stamps = fast
		var probe := Snapshots.new()
		probe.merge(0, rows([10, 20]), 2, bounds, 1, 10, true)
		var pending := probe.prepare(0, rows([20, 30]), 2, bounds, 1, 10)
		probe.stamp(pending, 10.1)
		var published := probe.commit(0, pending, 10.3)
		stamped.append(published.buffer)
		check(Snapshots.opacity(stamp(published, 30), 10.3) < 0.00001, "Pre-stamped worker results begin fading at actual publication")
	check(stamped[0] == stamped[1], "Native timestamp batch exactly matches the GDScript reference")
	Snapshots.allow_fast_stamps = true
	for speed in [0.0, 11.0, 25.0, 45.0, 65.0, 90.0]:
		var policy := Policy.new()
		policy.record_latency(1.8)
		policy.sample(Vector2.ZERO, 1.0 / 60.0, true)
		var origin := Vector2(speed / 60.0, 0)
		policy.sample(origin, 1.0 / 60.0)
		var lead := policy.lead()
		var leading_visible := origin + Vector2(speed * (1.8 + Policy.FADE_SECONDS) + 40.0, 0)
		check(Policy.distance_to_coverage(leading_visible, origin, lead) <= 52.0, "Prefetch covers delayed arrival and fading at %s m/s" % speed)
		check(Policy.distance_to_coverage(origin + Vector2(-40, 0), origin, lead) <= 52, "The rear of the current visible circle remains covered")
		policy.sample(origin - Vector2(speed / 60.0, 0), 1.0 / 60.0)
		check(policy.lead().x <= 0.0, "A sharp reversal updates the prefetch direction")
		policy.sample(Vector2(10000, 10000), 1.0 / 60.0)
		check(policy.lead() == Vector2.ZERO, "Teleportation is not mistaken for extreme riding speed")
	var coordinator := WorldStreamCoordinator.new()
	var region_calls := [0]
	var yielded := [0]
	coordinator.vegetation_budgeted = func(_x: float, _z: float, _force: bool, allow: bool) -> bool:
		if not allow:
			yielded[0] += 1
		return allow
	coordinator.terrain_update = func(_x: float, _z: float, _force: bool, _allow: bool) -> bool: return false
	coordinator.region_update = func(_x: float, _z: float) -> bool:
		region_calls[0] += 1
		return true
	for i in 30:
		coordinator.update(Vector3.ZERO)
	check(region_calls[0] >= 3 and yielded[0] == region_calls[0], "A continuous vegetation queue cannot starve regions or upload twice in their reserved frame")
	print("vegetation_stream_test: %d failures; snapshots, delayed uploads, reversals, 0–90 m/s" % fails)
	quit(1 if fails else 0)
