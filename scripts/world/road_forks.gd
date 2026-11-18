extends RefCounted
## Junction preferences over the paths already published by StageTrails.
## Distances follow each section's ordered search cells, so a bend across the
## valley (or the next turn of a switchback) does not count as the same approach.

const SPACING := 25.0 # 100 m along a section
const FORK_GAP := 37.0 # 148 m maximum search for a shared spur takeoff
const TOLL := 1.75

var _world: WorldData
var _axis: PackedByteArray
var _section_count := -1
var _degree := {}
var _distance := {}
var _tolls := {}
var _stations := {}
var _reserved := {}


func _init(w: WorldData, on_axis: PackedByteArray) -> void:
	_world = w
	_axis = on_axis


func refresh(on_axis: PackedByteArray) -> void:
	var sections := _world.generation.road_cells
	if sections.size() == _section_count:
		return
	_axis = on_axis
	_section_count = sections.size()
	_degree.clear()
	_distance.clear()
	_tolls.clear()
	_stations.clear()
	_reserved.clear()
	var directions := {}
	# Deduplicate directions used by both a branch and its host. A width/class
	# split with two continuing edges is not a junction.
	for cells: PackedInt32Array in sections:
		for i in range(1, cells.size()):
			var a := cells[i - 1]
			var b := cells[i]
			var delta := _cell(b) - _cell(a)
			if delta == Vector2i.ZERO:
				continue
			var direction := signi(delta.x) + 3 * signi(delta.y)
			directions[a] = int(directions.get(a, 0)) | (1 << (4 + direction))
			directions[b] = int(directions.get(b, 0)) | (1 << (4 - direction))
	for cell: int in directions:
		if _protected(cell):
			continue
		var mask: int = directions[cell]
		var count := 0
		while mask != 0:
			mask &= mask - 1
			count += 1
		if count >= 3:
			_degree[cell] = count
	for cells: PackedInt32Array in sections:
		_measure(cells, false)
		_measure(cells, true)
	var owner := _world.generation.road_owner
	for host in sections.size():
		var cells: PackedInt32Array = sections[host]
		var along := 0.0
		for i in cells.size():
			var c := cells[i]
			if i > 0: along += _cell(c).distance_to(_cell(cells[i - 1]))
			if owner[c] == host: _stations[c] = along


func _measure(cells: PackedInt32Array, reverse: bool) -> void:
	var previous := -1
	var run := INF
	for i in cells.size():
		var cell := cells[cells.size() - 1 - i] if reverse else cells[i]
		if _protected(cell):
			run = INF
		elif _degree.has(cell):
			run = 0.0
		elif run < SPACING:
			run += _cell(cell).distance_to(_cell(previous))
		if run < float(_distance.get(cell, SPACING)):
			_distance[cell] = run
		previous = cell


## Try the closest three-way junction first, then the nearest clear station on
## the same section. The caller keeps the unmodified route as its fallback.
func sources(source: int, settle_d: PackedFloat32Array, exit_radius: float) -> PackedInt32Array:
	if pressure_at(source) <= 0.0:
		return PackedInt32Array()
	var shared := -1
	var shifted := -1
	var shared_dist := INF
	var shifted_dist := INF
	var cost := _world.cost
	var stations := _nearby_stations(source, FORK_GAP)
	for c: int in stations:
		if cost[c] == INF or settle_d[c] < exit_radius:
			continue
		var run: float = stations[c]
		if _degree.get(c, 0) == 3 and run < shared_dist:
			shared = c
			shared_dist = run
		elif not _distance.has(c) and run < shifted_dist:
			shifted = c
			shifted_dist = run
	var out := PackedInt32Array()
	if shared >= 0: out.append(shared)
	if shifted >= 0: out.append(shifted)
	return out


func pressure_at(cell: int) -> float:
	if _degree.get(cell, 0) == 3:
		return 0.0
	return 1.0 - float(_distance.get(cell, SPACING)) / SPACING


func _contacts(path: PackedInt32Array) -> Dictionary:
	var owner := _world.generation.road_owner
	var contacts := {} # junction cell -> host section
	for i in range(1, path.size()):
		var a := path[i - 1]
		var b := path[i]
		if (owner[a] >= 0) == (owner[b] >= 0):
			continue
		var c := a if owner[a] >= 0 else b
		if not _protected(c): contacts[c] = owner[c]
	return contacts


## Also account for a single proposal that joins the same road twice in quick succession.
func pressure(path: PackedInt32Array) -> float:
	return _pressure(_contacts(path))


func ride_pressure(path: PackedInt32Array) -> float:
	var contacts := _contacts(path)
	# The ordinary ride needs two ends. Prefer routes that do not weave in and
	# out of the network repeatedly when another route of the same style fits.
	return _pressure(contacts) + 0.60 * maxi(0, contacts.size() - 2)


func _pressure(contacts: Dictionary) -> float:
	var previous := {}
	var sum := 0.0
	for c: int in contacts:
		sum += pressure_at(c)
		if not _stations.has(c): continue
		var prior: Array = previous.get_or_add(contacts[c], [])
		var station: float = _stations[c]
		var spacing := SPACING
		for other: float in prior:
			spacing = minf(spacing, absf(station - other))
		sum += 1.0 - spacing / SPACING
		prior.append(station)
	return sum


## Chosen rides have not been published yet. Reserve only their approaches on
## the existing roads so a later ride can prefer an uncrowded alternative.
func reserve(path: PackedInt32Array) -> void:
	for c: int in _contacts(path):
		_reserved[c] = true
		for next: int in _nearby_stations(c, SPACING):
			_reserved[next] = true


func crowds_chosen(path: PackedInt32Array) -> bool:
	for c: int in _contacts(path):
		if _reserved.has(c): return true
	return false


func crowded_takeoff(path: PackedInt32Array) -> int:
	var owner := _world.generation.road_owner
	for i in range(1, path.size()):
		var c := path[i - 1]
		if owner[c] >= 0 and owner[path[i]] < 0 and pressure_at(c) > 0.0:
			return c
	return -1


func _nearby_stations(source: int, reach: float) -> Dictionary:
	var host: int = _world.generation.road_owner[source]
	if host < 0: return {}
	var cells: PackedInt32Array = _world.generation.road_cells[host]
	var at := cells.find(source)
	if at < 0: return {}
	var out := {}
	for step: int in [-1, 1]:
		var run := 0.0
		var previous := source
		for i in range(at + step, -1 if step < 0 else cells.size(), step):
			var c := cells[i]
			run += _cell(c).distance_to(_cell(previous))
			if run > reach or _protected(c): break
			out[c] = run
			previous = c
	return out


## Price only the first step off a crowded approach. Leave the existing road
## and the mouth of a shared junction open so A* can reuse either one.
func preferred_cost(cost: PackedFloat32Array) -> PackedFloat32Array:
	if _tolls.is_empty():
		var owner := _world.generation.road_owner
		for c: int in _distance:
			var surcharge := pressure_at(c)
			for offset in 8:
				var at := _cell(c) + Vector2i(Grid.DX[offset], Grid.DY[offset])
				if at.x < 0 or at.y < 0 or at.x >= _world.W or at.y >= _world.H:
					continue
				var next := at.y * _world.W + at.x
				if owner[next] < 0 and not _protected(next):
					_tolls[next] = minf(_tolls[next], surcharge) if _tolls.has(next) else surcharge
	var out := cost.duplicate()
	for c: int in _tolls:
		out[c] *= 1.0 + TOLL * float(_tolls[c])
	return out


func _cell(i: int) -> Vector2i:
	return Vector2i(i % _world.W, i / _world.W)


func _protected(cell: int) -> bool:
	return not _axis.is_empty() and _axis[cell] != 0
