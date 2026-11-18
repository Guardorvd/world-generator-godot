extends RefCounted
## Открытия по дорожным доскам и история поездок. Каждый отрезок хранится
## отдельно, поэтому при переносе, сходе с велосипеда и загрузке нет перемычек.

const POINTS_PER_LEG := 128
const MAX_LEGS := 256
const SAMPLE_TIME := 0.24
const MIN_STEP := 3.5
const MAX_STEP := 30.0  # дальше за такт — перенос или возврат после падения: трек рвётся, перемычки нет
const END_STEP := 1.0

var read := {}
var distance := 0.0
var revision := 0
var legs: Array[Dictionary] = []
var current := PackedVector2Array()
var current_bounds := Rect2()
var _elapsed := 0.0
var _position := Vector2.INF


func reveal(places: Array) -> void:
	for place: Dictionary in places:
		read[place.key] = true


func record(at: Vector2, dt: float) -> void:
	if not at.is_finite():
		return
	if current.is_empty():
		_begin(at)
		return
	var step := _position.distance_to(at)
	if step >= MAX_STEP:
		end_trip()
		_begin(at)
		return
	distance += step
	_position = at
	_elapsed += dt
	if _elapsed < SAMPLE_TIME:
		return
	_elapsed = fmod(_elapsed, SAMPLE_TIME)
	if current[-1].distance_squared_to(at) >= MIN_STEP * MIN_STEP:
		_add_point(at)
		current_bounds = current_bounds.expand(at)
		revision += 1
		if current.size() >= POINTS_PER_LEG:
			end_trip()
			_begin(at)


func _begin(at: Vector2) -> void:
	current.append(at)
	current_bounds = Rect2(at, Vector2.ZERO)
	_position = at


func _add_point(at: Vector2) -> void:
	# Почти прямые отрезки хранятся до 32 м между опорными точками.
	if current.size() >= 2:
		var anchor := current[-2]
		if anchor.distance_squared_to(at) <= 32.0 * 32.0:
			var projected := Geometry2D.get_closest_point_to_segment(current[-1], anchor, at)
			if projected.distance_squared_to(current[-1]) <= 0.65 * 0.65:
				current[-1] = at
				return
	current.append(at)


func end_trip() -> void:
	if current.is_empty():
		return
	var points := _with_endpoint(current)
	if points.size() > 1:
		legs.append({points = points, bounds = current_bounds.expand(points[-1])})
		if legs.size() > MAX_LEGS:
			legs.pop_front()
		revision += 1
	current = PackedVector2Array()
	_elapsed = 0.0


func _with_endpoint(points: PackedVector2Array) -> PackedVector2Array:
	if not points.is_empty() and points.size() < POINTS_PER_LEG and points[-1].distance_squared_to(_position) >= END_STEP * END_STEP:
		points.append(_position)
	return points


func save_state() -> Dictionary:
	var history: Array = []
	for leg: Dictionary in legs:
		history.append(leg.points)
	var points := _with_endpoint(current.duplicate())
	if points.size() > 1:
		history.append(points)
		if history.size() > MAX_LEGS:
			history.pop_front()
	return {read = read.duplicate(), legs = history, distance = distance}


func restore(state: Dictionary) -> void:
	read = state.get("read", {}).duplicate()
	distance = state.get("distance", 0.0)
	legs.clear()
	current = PackedVector2Array()
	_position = Vector2.INF
	_elapsed = 0.0
	for points: PackedVector2Array in state.get("legs", []):
		var bounds := Rect2(points[0], Vector2.ZERO)
		for point in points:
			bounds = bounds.expand(point)
		legs.append({points = points, bounds = bounds})
	revision += 1


static func valid(state: Variant) -> bool:
	if not state is Dictionary or not state.get("read") is Dictionary or not state.get("legs") is Array:
		return false
	var length: Variant = state.get("distance")
	if not (length is float or length is int) or not is_finite(float(length)) or length < 0.0:
		return false
	if state.legs.size() > MAX_LEGS:
		return false
	for key: Variant in state.read:
		if not key is String or state.read[key] != true:
			return false
	for points: Variant in state.legs:
		if not points is PackedVector2Array or points.size() < 2 or points.size() > POINTS_PER_LEG:
			return false
		for point: Vector2 in points:
			if not point.is_finite():
				return false
	return true
