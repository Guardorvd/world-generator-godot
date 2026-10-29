extends RefCounted
## История отображения отделена от CPU-раскладки и физических препятствий.
## INSTANCE_CUSTOM.w: 0 — зрелое растение, +время — появление, −время — уход.
const STRIDE := 20
const DURATION := 0.5
var displayed := {}
var shown := {} # число показанных строк: буфер в displayed может быть дополнен до ёмкости MultiMesh
var deadlines := {}

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

func cleanup_due(now: float) -> bool:
	for deadline: float in deadlines.values():
		if deadline > 0.0 and now >= deadline:
			return true
	return false

func merge(group: int, source: PackedFloat32Array, count: int, bounds: AABB, radius: float, now: float, immediate := false) -> Dictionary:
	return commit(group, prepare(group, source, count, bounds, radius, now, immediate), now)


## Подготовка выполняется фоновым потоком. История неизменна до завершения задачи.
func prepare(group: int, source: PackedFloat32Array, count: int, bounds: AABB, radius: float, now: float, immediate := false) -> Dictionary:
	var previous: PackedFloat32Array = displayed.get(group, PackedFloat32Array())
	var rows: int = shown.get(group, previous.size() / STRIDE)
	var changes := PackedFloat64Array()
	var deadline := 0.0
	var old := {}
	if not immediate:
		for at in range(0, rows * STRIDE, STRIDE):
			old[key(previous, at)] = at
	var result := source.slice(0, count * STRIDE)
	for at in range(0, result.size(), STRIDE):
		var id := key(result, at)
		var stamp := 0.0
		if old.has(id):
			stamp = previous[old[id] + 19]
			if stamp < 0.0:
				changes.append_array(PackedFloat64Array([at, 1, stamp]))
			old.erase(id)
		elif not immediate:
			changes.append_array(PackedFloat64Array([at, 2, 0]))
		result[at + 19] = stamp
	var box := bounds
	var have_bounds := count > 0
	# Уходящие экземпляры остаются только на время растворения; общие растения не дублируются.
	for at: int in old.values():
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
	return {buffer = result, count = result.size() / STRIDE, bounds = box if have_bounds else AABB(), changes = changes, deadline = deadline}


## Отметки времени изменившихся растений. Фоновая подгрузка ставит их в задаче (now — часы на её конец),
## тогда commit на главном потоке только запоминает показанный снимок.
func stamp(frame: Dictionary, now: float) -> void:
	var result: PackedFloat32Array = frame.buffer
	var changes: PackedFloat64Array = frame.changes
	var deadline: float = frame.deadline
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


func commit(group: int, frame: Dictionary, now: float) -> Dictionary:
	if not frame.get("stamped", false):
		stamp(frame, now)
	displayed[group] = frame.buffer
	shown[group] = frame.count
	deadlines[group] = frame.deadline
	return frame
