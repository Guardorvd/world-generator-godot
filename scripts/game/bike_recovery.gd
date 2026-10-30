class_name BikeRecovery
extends RefCounted
## Проверки опоры, габарита и подхода к велосипеду; используются посадкой и локальным размещением.

const TILE := GameConfig.TILE
const CLEARANCE := 1.8
const MAX_GRADE := 0.35


## Опора и габарит стоящего велосипеда, включая бока и небольшой запас впереди/сзади.
## reference = INF выбирает верх настила; при обычной посадке передаётся фактический уровень.
static func placement(w: WorldData, h: Heightfield, at: Vector3, heading: float, extra: ForestObstacles = null, recovering := false) -> Dictionary:
	if not is_finite(at.x) or not is_finite(at.z) or is_nan(at.y) or at.y == -INF or not is_finite(heading) or not h.known(at.x, at.z):
		return {}
	var floor_y := h.surface_at(at.x, at.z, at.y)
	if not is_finite(floor_y):
		return {}
	var fwd := Vector2(-sin(heading), -cos(heading))
	var side := Vector2(cos(heading), -sin(heading))
	var low := floor_y
	var high := floor_y
	for along: float in ([-1.5, -BikeRide.AXLE, 0.0, BikeRide.AXLE, 1.5] if recovering else [-BikeRide.AXLE, 0.0, BikeRide.AXLE]):
		for across: float in [-BikeRide.BODY_R, 0.0, BikeRide.BODY_R]:
			var p := Vector2(at.x, at.z) + fwd * along + side * across
			var y := h.surface_at(p.x, p.y, floor_y)
			if not is_finite(y) or absf(y - floor_y) > MAX_GRADE * maxf(0.7, absf(along)):
				return {}
			if not PlayerState.is_passable(w, h, p.x, p.y, y, BikeRide.BODY_R if across == 0.0 else 0.05):
				return {}
			if extra != null and extra.hits(p.x, p.y, y, BikeRide.BODY_R if across == 0.0 else 0.05):
				return {}
			if not headroom(h, p.x, p.y, y) or (recovering and h.depth_at(p.x, p.y, y) > 0.02):
				return {}
			low = minf(low, y)
			high = maxf(high, y)
	if recovering and high - low > 0.65:
		return {}
	return {position = Vector3(at.x, floor_y, at.z), heading = heading}


static func headroom(h: Heightfield, x: float, z: float, feet: float) -> bool:
	return roof(h, x, z, feet) >= feet + CLEARANCE


## Нижняя граница перекрытия над ногами на высоте feet: свод туннеля или низ моста; INF, если его нет.
static func roof(h: Heightfield, x: float, z: float, feet: float) -> float:
	var top := h.ceiling_at(x, z, feet)
	# ceiling_at описывает свод туннеля, но не нижнюю сторону моста.
	var cells: Variant = h._cell_list(x, z)
	for index: int in cells if cells != null else []:
		var s: Dictionary = h.structures[index]
		if s.tunnel:
			continue
		var along: float = (x - s.ax) * s.ux + (z - s.az) * s.uz
		var side: float = absf((x - s.ax) * s.uz - (z - s.az) * s.ux)
		if along < 0.0 or along > s.len or side > s.half:
			continue
		var deck := h.level(s, along)
		# Запас включает балки деревянного и нижнюю плиту каменного моста. Настил, на который можно въехать
		# (surface_at ставит на него ноги не ниже STEP), — опора, а не перекрытие: так колесо у начала настила
		# северного шора не упирается в него головой седока.
		if feet < deck - Heightfield.STEP:
			top = minf(top, deck - (0.7 if s.style == "stone" else (0.24 if s.style == "planks" else 0.5)))
	return top


## Прямой путь: посадка не должна срезать стену/угол, обрыв или перепад этажей.
static func clear_path(w: WorldData, h: Heightfield, from: Vector3, to: Vector3, objects_only := false) -> bool:
	var steps := maxi(1, ceili(Vector2(to.x - from.x, to.z - from.z).length() / PlayerState.PIECE))
	var previous := from.y
	for i in range(1, steps + 1):
		var p := from.lerp(to, float(i) / steps)
		var y := h.surface_at(p.x, p.z, previous + 0.1)
		if not is_finite(y) or absf(y - previous) > 0.3 or absf(y - from.y) > 0.6:
			return false
		# 30.10: низкое препятствие (бревно, пень, камень до ForestObstacles.CLIMB_MAX) перешагивают и переносят через
		# него велосипед; раньше после падения на бревне поперёк дороги сесть было нельзя, если седок встал за ним
		if not PlayerState.is_passable(w, h, p.x, p.z, y, BikeRide.BODY_R, objects_only, ForestObstacles.CLIMB_MAX):
			return false
		previous = y
	return absf(previous - to.y) < 0.3
