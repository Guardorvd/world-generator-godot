extends RefCounted
## Выбирает площадку рядом с центром поселения на готовом рельефе.
## Координаты поселения остаются адресом для дорог, заданий и сохранений.

const TILE := GameConfig.TILE
const BIN := 32.0
const SEARCH := 24.0
const STEP := 2.0
const PAD_R := 4.5
const COMPACT_R := 3.7
const BOARD_R := 2.3
const ROAD_MARGIN := 0.6
const ROAD_EDGE := 1.35 # край ленты с затуханием, в долях рабочей полуширины
const BOARD_HEIGHT := 1.35
const BAG_OFFSET := Vector3(1.35, 0.0, 0.35)

var _heights: Heightfield
var _path_mask: PackedByteArray
var _bins := {}


func _init(places: WorldData, heights: Heightfield, regional_paths: Array = []) -> void:
	_heights = heights
	_path_mask = heights.world.path_mask
	for s: SettlementData in places.settlements:
		var center := Vector2(s.x, s.y) * TILE
		var reach := Vector2.ONE * (SEARCH + 6.0)
		var low := _cell(center - reach)
		var high := _cell(center + reach)
		for z in range(low.y, high.y + 1):
			for x in range(low.x, high.x + 1):
				_bins[Vector2i(x, z)] = []
	if _bins.is_empty():
		return
	_index_paths(heights.world.trails)
	_index_paths(regional_paths)


func _index_paths(paths: Array) -> void:
	for route: Dictionary in paths:
		if route.kind == "animal":
			continue
		var points: Array = route.pts
		for i in range(1, points.size()):
			var a := Vector2(points[i - 1].x, points[i - 1].y) * TILE
			var b := Vector2(points[i].x, points[i].y) * TILE
			var half := maxf(points[i - 1].w, points[i].w) * (TILE * 0.5)
			var reach := Vector2.ONE * (half * ROAD_EDGE + ROAD_MARGIN + PAD_R)
			var low := _cell(a.min(b) - reach)
			var high := _cell(a.max(b) + reach)
			var piece: Variant = null
			for z in range(low.y, high.y + 1):
				for x in range(low.x, high.x + 1):
					var key := Vector2i(x, z)
					if _bins.has(key):
						if piece == null:
							piece = {line = Vector4(a.x, a.y, b.x, b.y), edge = half * ROAD_EDGE}
						_bins[key].append(piece)


func choose(s: SettlementData) -> Dictionary:
	var center := Vector2(s.x, s.y) * TILE
	for radius: float in [PAD_R, COMPACT_R, BOARD_R]:
		var yard := _find_pad(s, center, radius)
		if not yard.is_empty():
			return yard
	return {}


func _find_pad(s: SettlementData, center: Vector2, radius: float) -> Dictionary:
	var best := {}
	var best_score := INF
	var limit := 1.65 if radius == PAD_R else (1.5 if radius == COMPACT_R else 1.25)
	var rings := roundi(SEARCH / STEP)
	for ring in range(rings + 1):
		var distance := ring * STEP
		if distance >= best_score:
			break
		var count := maxi(1, ring * 6)
		for n in count:
			var at := center + Vector2.DOWN.rotated(TAU * n / count) * distance
			if not road_clear(at, radius) or not _buildings_clear(s, at, radius):
				continue
			var relief := _pad_relief(at, radius, limit)
			if relief > limit:
				continue
			var score := distance + relief * 2.0
			if score < best_score:
				var yard := _layout(center, at, radius)
				if _objects_dry(yard):
					best_score = score
					best = yard
	return best


func road_clear(at: Vector2, radius: float) -> bool:
	for piece: Dictionary in _bins.get(_cell(at), []):
		var line: Vector4 = piece.line
		var a := Vector2(line.x, line.y)
		var b := Vector2(line.z, line.w)
		var nearest := Geometry2D.get_closest_point_to_segment(at, a, b)
		var gap: float = piece.edge + ROAD_MARGIN + radius
		if at.distance_squared_to(nearest) < gap * gap:
			return false
	return true


func _buildings_clear(s: SettlementData, at: Vector2, radius: float) -> bool:
	for hut: HutData in s.huts:
		var offset := at - Vector2(hut.x, hut.y) * TILE
		if PlayerState._box_hits(offset.x, offset.y, PlayerState.hut_angle(s, hut), PlayerState.hut_half(hut), radius + 0.8):
			return false
	return true


func _pad_relief(at: Vector2, radius: float, limit: float) -> float:
	var low := INF
	var high := -INF
	# Проверяем середину, внутреннюю часть площадки и край со всех сторон.
	for ring in 3:
		var count := 1 if ring == 0 else 8
		for n in count:
			var p := at + Vector2.RIGHT.rotated(TAU * n / count) * radius * ring * 0.5
			var y := _dry_ground(p)
			if not is_finite(y):
				return INF
			if _on_tread(p):
				return INF
			low = minf(low, y)
			high = maxf(high, y)
			if high - low > limit:
				return INF
	return high - low


func _on_tread(at: Vector2) -> bool:
	if _heights.path_contact(at.x, at.y).get("weight", 0.0) > 0.35:
		return true
	if _heights.road_refinement != null:
		return false
	var w := _heights.world
	var cell := Vector2i((at / TILE).floor())
	return (_path_mask.size() == w.N and w.grid.contains(cell.x, cell.y)
		and _path_mask[cell.y * w.W + cell.x] >= 2)


func _objects_dry(yard: Dictionary) -> bool:
	var board: Transform3D = yard.board
	# Обе стойки, место для сумки и место перед щитом, с которого его читают.
	var points := [
		board * Vector3(-0.7, 0.0, 0.0), board * Vector3(0.7, 0.0, 0.0),
		board * BAG_OFFSET, board * Vector3(0.0, 0.0, 1.65),
	]
	for bench: Transform3D in yard.benches:
		points.append(bench * Vector3(-0.8, 0.0, 0.0))
		points.append(bench * Vector3(0.8, 0.0, 0.0))
	for p: Vector3 in points:
		var at := Vector2(p.x, p.z)
		if not is_finite(_dry_ground(at)) or _on_tread(at):
			return false
	return true


func _dry_ground(at: Vector2) -> float:
	if not _heights.known(at.x, at.y):
		return INF
	var y := _heights.ground_at(at.x, at.y)
	if not is_finite(y) or _heights.depth_at(at.x, at.y, y) > 0.01 or _heights.wall_at(at.x, at.y, y, 0.3):
		return INF
	return y


func _layout(center: Vector2, at: Vector2, radius: float) -> Dictionary:
	var toward := center - at
	var best := INF
	for piece: Dictionary in _bins.get(_cell(at), []):
		var line: Vector4 = piece.line
		var near := Geometry2D.get_closest_point_to_segment(at, Vector2(line.x, line.y), Vector2(line.z, line.w))
		var d := at.distance_squared_to(near)
		if d < best:
			best = d
			toward = near - at
	var basis := Basis(Vector3.UP, atan2(toward.x, toward.y)) if toward.length_squared() > 0.01 else Basis.IDENTITY
	var origin := Transform3D(basis, _foot(at))
	var benches: Array[Transform3D] = []
	var board := origin.translated_local(Vector3(0.0, 0.0, -0.7))
	var fire := Vector3.INF
	if radius > BOARD_R:
		var scale := radius / PAD_R
		board = origin.translated_local(Vector3(-1.2, 0.0, -2.35) * scale)
		fire = origin.origin
		for side: float in [-1.0, 1.0]:
			var position := origin.translated_local(Vector3(side * 2.15, 0.0, 0.4) * scale).origin
			benches.append(Transform3D(basis.rotated(Vector3.UP, PI * 0.5), _foot(Vector2(position.x, position.z))))
	board.origin.y = _heights.ground_at(board.origin.x, board.origin.z)
	return {board = board, fire = fire, benches = benches}


func _foot(at: Vector2) -> Vector3:
	return Vector3(at.x, _heights.ground_at(at.x, at.y), at.y)


static func _cell(at: Vector2) -> Vector2i:
	return Vector2i((at / BIN).floor())
