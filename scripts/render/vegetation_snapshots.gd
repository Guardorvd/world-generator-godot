extends RefCounted
## История отображения отделена от CPU-раскладки и физических препятствий.
## INSTANCE_CUSTOM.w: 0 — зрелое растение, +время — появление, −время — уход.
const STRIDE := 20
const DURATION := 0.5
const LIVE_CONTACT := 1.0 # source-only marker in the timestamp column, never sent to the shader
var displayed := {}
var shown := {} # число показанных строк: буфер в displayed может быть дополнен до ёмкости MultiMesh
var deadlines := {}
var _bounds := {}
static var allow_fast_stamps := true

static func opacity(stamp: float, now: float) -> float:
	if stamp == 0.0:
		return 1.0
	return clampf((now - stamp) / DURATION if stamp > 0 else 1.0 - (now + stamp) / DURATION, 0.0, 1.0)

static func key(buffer: PackedFloat32Array, at: int) -> Vector2:
	return Vector2(buffer[at + 3], buffer[at + 11])

func reset() -> void:
	displayed.clear()
	shown.clear()
	deadlines.clear()
	_bounds.clear()

func cleanup_due(now: float) -> bool:
	for deadline: float in deadlines.values():
		if deadline > 0.0 and now >= deadline:
			return true
	return false


## Match refresh's removal from live MultiMeshes without restarting unaffected fades.
## Call only when the preparation worker no longer reads displayed history.
func exclude_rect(box: Rect2) -> void:
	for group: int in displayed:
		var bounds: AABB = _bounds[group]
		var area := Rect2(Vector2(bounds.position.x, bounds.position.z), Vector2(bounds.size.x, bounds.size.z))
		if area.has_area() and not area.intersects(box):
			continue
		var data: PackedFloat32Array = displayed[group]
		var kept := PackedFloat32Array()
		for at in range(0, int(shown[group]) * STRIDE, STRIDE):
			if not box.has_point(key(data, at)):
				kept.append_array(data.slice(at, at + STRIDE))
		displayed[group] = kept
		shown[group] = kept.size() / STRIDE

func merge(group: int, source: PackedFloat32Array, count: int, bounds: AABB, radius: float, now: float, immediate := false, contact_rows := false) -> Dictionary:
	return commit(group, prepare(group, source, count, bounds, radius, now, immediate, contact_rows), now)


## Two meshes at the same planting site share the history of the plant.
func form_history(group: int, source: PackedFloat32Array, count: int) -> Dictionary:
	var stamps := {}
	var previous: PackedFloat32Array = displayed.get(group, PackedFloat32Array())
	for at in range(0, int(shown.get(group, 0)) * STRIDE, STRIDE):
		stamps[key(previous, at)] = previous[at + 19]
	var incoming := {}
	for at in range(0, count * STRIDE, STRIDE):
		incoming[key(source, at)] = true
	return {stamps = stamps, incoming = incoming}


## Подготовка выполняется фоновым потоком. История неизменна до завершения задачи.
## Препятствия видны сразу после передачи группы, когда для неё могут включиться контакты.
func prepare(group: int, source: PackedFloat32Array, count: int, bounds: AABB, radius: float, now: float, immediate := false, contact_rows := false, other_form := {}) -> Dictionary:
	var previous: PackedFloat32Array = displayed.get(group, PackedFloat32Array())
	var rows: int = shown.get(group, previous.size() / STRIDE)
	var changes := PackedFloat64Array()
	var deadline := 0.0
	var old := {}
	var other_stamps: Dictionary = other_form.get("stamps", {})
	var other_incoming: Dictionary = other_form.get("incoming", {})
	if not immediate:
		for at in range(0, rows * STRIDE, STRIDE):
			old[key(previous, at)] = at
	var result := source.slice(0, count * STRIDE)
	for at in range(0, result.size(), STRIDE):
		var id := key(result, at)
		var old_at: int = old.get(id, -1)
		var stamp := 0.0
		if not immediate and not (contact_rows and result[at + 19] == LIVE_CONTACT):
			stamp = previous[old_at + 19] if old_at >= 0 else other_stamps.get(id, INF)
			if stamp == INF:
				changes.append_array(PackedFloat64Array([at, 2, 0]))
				stamp = 0.0
			elif stamp < 0.0:
				changes.append_array(PackedFloat64Array([at, 1, stamp]))
		if old_at >= 0:
			old.erase(id)
		result[at + 19] = stamp
	var box := bounds
	var have_bounds := count > 0
	# Уходящие экземпляры остаются только на время растворения; общие растения не дублируются.
	for id: Vector2 in old:
		if other_incoming.has(id):
			continue
		var at: int = old[id]
		var stamp := previous[at + 19]
		var alpha := opacity(stamp, now)
		if alpha <= 0.0:
			continue
		if stamp >= 0.0:
			changes.append_array(PackedFloat64Array([result.size(), -1, stamp]))
		else:
			deadline = maxf(deadline, -stamp + DURATION)
		var row := previous.slice(at, at + STRIDE)
		row[19] = stamp
		result.append_array(row)
		var center := Vector3(row[3], row[7], row[11])
		var scale := maxf(Vector3(row[0], row[4], row[8]).length(), maxf(Vector3(row[1], row[5], row[9]).length(), Vector3(row[2], row[6], row[10]).length()))
		var margin := radius * scale
		var outgoing := AABB(center - Vector3.ONE * margin, Vector3.ONE * margin * 2.0)
		box = box.merge(outgoing) if have_bounds else outgoing
		have_bounds = true
	return {buffer = result, count = result.size() / STRIDE, bounds = box if have_bounds else AABB(), changes = changes, deadline = deadline, base_deadline = deadline}


## Stamp changed rows with the actual upload time.
func stamp(frame: Dictionary, now: float) -> void:
	var result: PackedFloat32Array = frame.buffer
	var changes: PackedFloat64Array = frame.changes
	var deadline: float = frame.get("base_deadline", frame.deadline)
	if changes.is_empty():
		frame.stamped = true
		frame.stamped_at = now
		return
	# Interop copies the entire packed buffer. Write sparse changes in place and
	# reserve the native batch for dense updates where the loop pays for the copy.
	var use_batch := changes.size() / 3 >= 96 + result.size() / (STRIDE * 8)
	var fast := Grid.fast_grid() if allow_fast_stamps and use_batch else null
	if fast != null:
		var stamped: Variant = fast.StampVegetation(result, changes, deadline, now, DURATION)
		if stamped is Dictionary:
			frame.buffer = stamped.buffer
			frame.deadline = stamped.deadline
			frame.stamped = true
			frame.stamped_at = now
			return
		push_error("VegetationSnapshots: C# вернул null, метки ставятся на GDScript")
	for i in range(0, changes.size(), 3):
		var at := int(changes[i])
		var mode := changes[i + 1]
		var alpha := opacity(changes[i + 2], now)
		result[at + 19] = now if mode == 2 else (now - alpha * DURATION if mode == 1 else -(now - (1.0 - alpha) * DURATION))
		if mode < 0:
			deadline = maxf(deadline, -result[at + 19] + DURATION)
	frame.buffer = result
	frame.deadline = deadline
	frame.stamped = true
	frame.stamped_at = now


func commit(group: int, frame: Dictionary, now: float) -> Dictionary:
	# A queued group starts or reverses its fade when its buffer reaches the GPU.
	if frame.get("stamped_at", -INF) != now:
		stamp(frame, now)
	displayed[group] = frame.buffer
	shown[group] = frame.count
	deadlines[group] = frame.deadline
	_bounds[group] = frame.bounds
	return frame
