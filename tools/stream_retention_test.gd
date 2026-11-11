extends SceneTree
## Isolated retention regression: no world generation or player save/cache writes.
var fails := 0

func check(ok: bool, label: String) -> void:
	print(("OK " if ok else "FAIL ") + label)
	fails += int(not ok)

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 30)
	call_deferred("run")

func run() -> void:
	var w := WorldData.new()
	w.outer = OuterLand.new()
	var stream := RegionStream.new()
	stream.world = w
	stream.generation_enabled = false
	stream.ledger = {regions = {}}
	for x in range(100, 10100):
		var key := Vector2i(x, 0)
		stream.ledger.regions[key] = {rect = RegionStream.Regions.rect_for(key)}
	var far := Vector2i(100, 0)
	stream._publish_fields(far, {h = PackedFloat32Array([7.0])})
	check(stream._stream_candidates(Vector2.ZERO) == [far], "10,000 historical regions do not enter the frame queue; distant resident does")
	stream.update(0.0, 0.0)
	check(not stream.ledger.regions[far].has("fields") and stream._resident.is_empty(), "teleport evicts the former resident")
	check(stream._stream_candidates(Vector2.ZERO).is_empty(), "evicted region leaves the frame queue")
	# An in-flight read may complete after the player has already teleported.
	stream._publish_fields(far, {h = PackedFloat32Array([7.0])})
	check(stream._stream_candidates(Vector2.ZERO).has(far), "late field completion invalidates a stationary frame queue")
	stream.update(0.0, 0.0)
	var negative := Vector2i(-1, -1)
	stream.ledger.regions[negative] = {rect = RegionStream.Regions.rect_for(negative)}
	check(stream._stream_candidates(Vector2(-1, -1)).has(negative), "negative region coordinates are queried correctly")
	check(stream._field_bytes <= RegionStream.FIELD_CACHE_BYTES, "evicted fields respect their CPU cache budget")

	var h := Heightfield.new()
	h.world = w
	var plan := {plan = true}
	h.structures = [plan]
	var a := {ax = -100.0, az = -100.0, bx = -80.0, bz = -100.0, half = 2.0}
	var b := {ax = -200.0, az = -200.0, bx = -180.0, bz = -200.0, half = 2.0}
	h._add_outer([a, b])
	stream.heights = h
	var node := Node3D.new()
	stream.add_child(node)
	stream._shown[far] = {node = node}
	stream._bridges[far] = [a]
	stream._hide(far)
	check(h.structures.size() == 2 and is_same(h.structures[0], plan) and is_same(h.structures[1], b), "hide removes only owned bridges and preserves plan indices")
	var indexed := true
	for ids: Array in h._outer_cells.values():
		for id: int in ids: indexed = indexed and id == 1
	check(indexed and not h._outer_cells.is_empty() and stream._bridges.is_empty(), "remaining bridge collision indices are rebuilt")
	for i in 100:
		h._add_outer([a])
		h.remove_outer_bridges([a])
	check(h.structures.size() == 2 and h.outer_structures.size() == 1, "100 returns and unloads do not accumulate bridges")
	h.remove_outer_bridges([b])
	check(h.structures == [plan] and h._outer_cells.is_empty(), "last bridge unload releases the collision index")

	w.W = 32
	w.H = 32
	w.N = 1024
	w.path_mask.resize(w.N)
	w.path_mask.fill(2) # rejected outcrop seats still exercise the real cache path
	var bounded := true
	for i in Heightfield.ROCK_SEAT_LIMIT * 3:
		RockModels.seat(h, 64.0, 64.0, 0.5 + float(i) / 10000.0, RockModels.OUTCROP_V)
		bounded = bounded and h.rock_seats.size() <= Heightfield.ROCK_SEAT_LIMIT
	check(bounded, "rock cache stays bounded across three capacities of distinct queries")
	check(RockModels.seat(h, 64.0, 64.0, 0.5, RockModels.OUTCROP_V) == Vector4(INF, 0, 1, 0), "evicted rock results recompute identically")
	h.clear_rock_seats()
	check(h.rock_seats.is_empty(), "surface invalidation still clears rock seats")
	stream.free()
	await process_frame
	print("stream_retention_test: failures=", fails)
	quit(1 if fails else 0)
