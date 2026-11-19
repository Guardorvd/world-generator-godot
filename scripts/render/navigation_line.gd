extends MeshInstance3D
## Пунктир готовых дорог и парящие стрелки проходимых подходов. Геометрия 4 раза/с,
## поиск по событию: цель, отклонение, новая территория или препятствие. Непроходимый путь
## не рисуется. Фаза штрихов привязана к дуге маршрута; красный цвет — движение против него.
const Roads = preload("res://scripts/game/road_navigation.gd")
const REACH := 70.0
const SEARCH_BLOCK := 32
const REDRAW_STEP := 0.4
const PIECE := 0.75     # длина кусочка штриха, м; штрих — DASH кусочков, пауза — столько же
const DASH := 2
const HALF := 0.14      # полуширина штриха, м
const ARCH := 0.03      # насколько середина штриха выше краёв, м
const STEP := 7.0       # шаг стрелок вне дороги, м
const HOVER := 1.2      # высота середины стрелки над опорой, м
const ARM := 1.15       # длина стрелки в её плоскости, м
const WING := 0.62      # полуширина стрелки, м
const BAND := 0.16      # ширина полосы крыла, м
const TILT := 0.96      # наклон плоскости стрелки к земле, рад: остриё выше вылетов
const FLOW := 3.0       # скорость обратного хода штрихов при движении не туда, м/с
const CORE := Color(1.0, 0.88, 0.55)
const EDGE := Color(0.95, 0.72, 0.3)
const WARN := Color(1.0, 0.3, 0.18)
const WARN_EDGE := Color(0.9, 0.14, 0.08)
const Snapshot = preload("res://scripts/game/navigation_snapshot.gd")
var background_search := false # GameWorld enables this; isolated synchronous callers retain their contract.
var _search_task := -1
var _search_roads: Roads
var _search_out := {}
var _search_revision := Vector4i.ZERO
var _search_serial := 0
var _serial := 0
var _request := {}
var roads: Roads
var path := PackedVector2Array()
var _cum := PackedFloat32Array() # длина маршрута от начала до каждой точки, м
var _world: WorldData
var _heights: Heightfield
var _goal := {}
var _target := Vector2.ZERO
var _road_first := 0 # границы дорожной части пути в _cum
var _road_last := -1
var _last_here := Vector2.ZERO
var _wrong := 0.0   # 1 — движение против маршрута; плавно гаснет
var _flow := 0.0    # сдвиг штрихов навстречу при движении не туда, м
var _timer := 0.0
var _reroute_timer := 0.0
var status := ""
var route_revision := 0   # 18.11.2026: растёт при каждом новом пути или сбросе — мини-карта перерисовывает маршрут
var _revision := Vector4i.ZERO
var _progress := 0.0
var _blocks: Array[Rect2] = []
var _painted_at := Vector3.INF
var _painted_wrong := 0.0
var _painted_obstacles := -1
var _painter := RoutePaint.new()
var _paint_task := -1
var _paint_out := {}
var _retire_tasks: Array[int] = []
var timings_us := {}
var _ledger_version := -1
var _region_key_hash := 0
var _outer_trails := 0

func _network_revision() -> Vector4i:
	var outer_trails := 0
	if _world.outer != null:
		var outer := _world.outer
		if outer.ledger_version != _ledger_version:
			var ledger := outer.get_ledger()
			_region_key_hash = ledger.get("regions", {}).keys().hash()
			_ledger_version = outer.ledger_version
			_outer_trails = ledger.get("trails", []).size()
		outer_trails = _outer_trails
	return Vector4i(_world.territory_revision, _world.trails.size(), outer_trails, _region_key_hash)


func setup(w: WorldData, h: Heightfield) -> void:
	_stop_search()
	_finish_paint()
	_painter = RoutePaint.new()
	_world = w
	_heights = h
	roads = null
	_revision = Vector4i(-1, -1, -1, 0)
	_ledger_version = -1
	_region_key_hash = 0
	_goal = {}
	path.clear()
	status = ""
	mesh = null
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.vertex_color_use_as_albedo = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material_override = material


func set_goal(goal: Dictionary, at: Vector2, feet := INF) -> void:
	_serial += 1
	_request = {}
	if _search_roads != null: _search_roads.cancelled = true
	_goal = goal
	path.clear()
	route_revision += 1
	mesh = null
	_wrong = 0.0
	_flow = 0.0
	_last_here = at
	_progress = 0.0
	status = ""
	_reroute_timer = 0.0
	if goal.is_empty():
		return
	if roads == null:
		roads = Roads.new()
		roads._world = _world
		roads._heights = _heights
	if not background_search and _revision != _network_revision():
		roads.build(_world, _heights)
		_revision = _network_revision()
	_target = Vector2(goal.x, goal.y) * GameConfig.TILE
	if goal.kind == "lake":
		_target = Vector2(goal.src.sx, goal.src.sy) * GameConfig.TILE
	elif goal.kind == "paint":
		_target = goal.approach
	_rebuild(at, feet)


func _rebuild(at: Vector2, feet := INF, recheck_graph := false) -> void:
	if background_search:
		_request_search(at, feet, recheck_graph)
		return
	if recheck_graph: roads.build(_world, _heights)
	path = roads.route_to(at, _target, feet)
	_last_here = at
	_accept_path()

func _accept_path(index := {}) -> void:
	route_revision += 1
	status = roads.status
	mesh = null
	_progress = 0.0
	_wrong = 0.0
	_flow = 0.0
	_road_first = roads.road_first
	_road_last = roads.road_last
	_painter = RoutePaint.new()
	if index.is_empty():
		index = _path_index(path)
	_cum = index.arc
	_blocks = index.blocks
	_painted_at = Vector3.INF
	_reroute_timer = 8.0 if path.is_empty() else 2.0
	_timer = 0.0


static func _path_index(points: PackedVector2Array) -> Dictionary:
	var arc := PackedFloat32Array()
	arc.resize(points.size())
	var blocks: Array[Rect2] = []
	var total := 0.0
	for i in range(1, points.size()):
		total += points[i - 1].distance_to(points[i])
		arc[i] = total
		if (i - 1) % SEARCH_BLOCK == 0:
			blocks.append(Rect2(points[i - 1], Vector2.ZERO))
		blocks[-1] = blocks[-1].expand(points[i])
	return {arc = arc, blocks = blocks}


func update_line(at: Vector3, dt: float, active: bool, shown := true) -> void:
	timings_us.clear()
	if background_search:
		var started := Time.get_ticks_usec()
		_poll_retired()
		_poll_search(Vector2(at.x, at.z))
		timings_us.search_poll = Time.get_ticks_usec() - started
	var draw_line := active and shown and not _goal.is_empty()
	if draw_line and not visible:
		_timer = 0.0
		_painted_at = Vector3.INF
	visible = draw_line
	if background_search:
		var started := Time.get_ticks_usec()
		_poll_paint(at, draw_line)
		timings_us.paint_poll = Time.get_ticks_usec() - started
	if not active or _goal.is_empty():
		_last_here = Vector2(at.x, at.z)
		_wrong = 0.0
		return
	_timer -= dt
	_reroute_timer -= dt
	_wrong = maxf(_wrong - dt * 3.0, 0.0)
	if _wrong > 0.0:
		_flow = fmod(_flow + dt * FLOW * _wrong, PIECE * DASH * 2.0)
	if _timer > 0.0:
		return
	_timer = 0.125 if _wrong > 0.0 else 0.25 # при предупреждении штрихи бегут плавнее
	var here := Vector2(at.x, at.z)
	if _revision != _network_revision():
		if background_search:
			_request_search(here, at.y)
			return
		roads.build(_world, _heights)
		_revision = _network_revision()
		_rebuild(here, at.y)
		return
	if path.is_empty():
		if _reroute_timer <= 0:
			_rebuild(here, at.y)
		return
	var segment := -1
	var nearest := Vector2.ZERO
	var distance := INF
	for block in maxi(1, _blocks.size()):
		if not _blocks.is_empty():
			var box := _blocks[block]
			if here.distance_squared_to(here.clamp(box.position, box.end)) > distance * distance:
				continue
		var first := block * SEARCH_BLOCK + 1
		var end := mini(path.size(), first + SEARCH_BLOCK) if not _blocks.is_empty() else path.size()
		for i in range(first, end):
			var a := path[i - 1]
			var p := Geometry2D.get_closest_point_to_segment(here, a, path[i])
			var arc: float = _cum[i - 1] + a.distance_to(p)
			# At intersections prefer the current branch, unless another is clearly closer.
			var score := here.distance_to(p) + minf(absf(arc - _progress) * 0.025, 3.0)
			if score < distance:
				distance = score
				segment = i
				nearest = p
	if distance > 24.0 and _reroute_timer <= 0.0 and _search_task == -1:
		_rebuild(here, at.y)
		return
	if segment == -1 or distance > REACH:
		mesh = null
		_painted_at = Vector3.INF
		return
	var start: float = _cum[segment - 1] + path[segment - 1].distance_to(nearest)
	_progress = start
	# После перехода на последний участок ближайшая старая дорожная точка уже не должна тянуть назад.
	if _road_last >= 0 and segment > _road_last and _reroute_timer <= 0 and distance > 6.0 and _search_task == -1:
		_rebuild(here, at.y)
		return
	_check_direction(here, nearest, start)
	if not draw_line or _paint_task != -1:
		return
	var obstacle_revision := _heights.obstacles.revision if _heights.obstacles != null else -1
	if obstacle_revision != _painted_obstacles:
		_painted_at = Vector3.INF
		_painted_obstacles = obstacle_revision
	if _painted_at.is_finite() and _painted_at.distance_squared_to(at) < REDRAW_STEP * REDRAW_STEP and _painted_wrong == 0.0 and _wrong == 0.0:
		return
	_painted_at = at
	_painted_wrong = _wrong
	var request := {at = at, nearest = nearest, start = start, segment = segment, path = path,
		arc = _cum, road_first = _road_first, road_last = _road_last, obstacles = obstacle_revision,
		wrong = _wrong, flow = _flow, route = route_revision, terrain = _revision}
	if background_search:
		_start_paint(request)
	else:
		_publish_paint(_painter.build(request, roads, _heights), here, at.y)


func _start_paint(request: Dictionary) -> void:
	var started := Time.get_ticks_usec()
	var h := Snapshot.capture(_heights, false)
	var checker := Roads.new()
	checker._world = h.world
	checker._heights = h
	# A newer route can clear or replace these buffers while the worker is still reading.
	request.path = path.duplicate()
	request.arc = _cum.duplicate()
	var painter := _painter
	var out := {request = request}
	_paint_out = out
	_paint_task = WorkerThreadPool.add_task(func() -> void:
		out.geometry = painter.build(request, checker, checker._heights)
		checker._heights = null
		checker._world = null, false, "Геометрия маршрута")
	timings_us.paint_start = Time.get_ticks_usec() - started


func _poll_paint(at: Vector3, shown: bool) -> void:
	if _paint_task == -1 or not WorkerThreadPool.is_task_completed(_paint_task):
		return
	WorkerThreadPool.wait_for_task_completion(_paint_task)
	_paint_task = -1
	var out := _paint_out
	_paint_out = {}
	var request: Dictionary = out.request
	if not shown or request.route != route_revision or request.terrain != _network_revision():
		return
	var obstacle_revision := _heights.obstacles.revision if _heights.obstacles != null else -1
	if request.obstacles != obstacle_revision or at.distance_squared_to(request.at) > 16.0:
		_painted_at = Vector3.INF
		_timer = 0.0
		return
	_publish_paint(out.geometry, Vector2(at.x, at.z), at.y)


func _publish_paint(geometry: Dictionary, here: Vector2, feet: float) -> void:
	if geometry.has("blocked"):
		mesh = null
		_painted_at = Vector3.INF
		if _reroute_timer <= 0.0:
			var i: int = geometry.blocked
			_rebuild(here, feet, i > _road_first and i <= _road_last)
		return
	if geometry.vertices.is_empty():
		mesh = null
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = geometry.vertices
	arrays[Mesh.ARRAY_COLOR] = geometry.colors
	var started := Time.get_ticks_usec()
	var line := ArrayMesh.new()
	line.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh = line
	timings_us.paint_upload = Time.get_ticks_usec() - started


func can_arrive(at: Vector3) -> bool:
	if _goal.get("kind") != "marker": return true
	# HUD only accepts markers within 3m; do not trace kilometres every physics tick.
	if Vector2(at.x, at.z).distance_squared_to(_target) > 9.0: return false
	if not _heights.known(_target.x, _target.y): return false
	var target_y := _heights.surface_at(_target.x, _target.y, INF)
	return absf(target_y - at.y) < 1.5 and roads != null and roads._segment(Vector2(at.x, at.z), _target, at.y) < INF


## Геометрия и проверка маршрута работают по снимку, включая запросы высоты и препятствий.
class RoutePaint extends RefCounted:
	var _heights: Heightfield
	var _wrong := 0.0
	var _flow := 0.0
	var _checked := {}
	var _levels := {}
	var _lifts := {}
	var _obstacles := -1

	func build(request: Dictionary, roads: Roads, heights: Heightfield) -> Dictionary:
		if request.obstacles != _obstacles:
			_checked.clear()
			_levels.clear()
			_obstacles = request.obstacles
		_heights = heights
		_wrong = request.wrong
		_flow = request.flow
		var result := _project(request, roads)
		_heights = null
		return result

	func _project(request: Dictionary, roads: Roads) -> Dictionary:
		var at: Vector3 = request.at
		var here := Vector2(at.x, at.z)
		var nearest: Vector2 = request.nearest
		var start: float = request.start
		var segment: int = request.segment
		var path: PackedVector2Array = request.path
		var arc: PackedFloat32Array = request.arc
		var road_first: int = request.road_first
		var road_last: int = request.road_last
		var vertices := PackedVector3Array()
		var colors := PackedColorArray()
		var ground := at.y + 0.25
		for i in range(segment, path.size()):
			var a0 := path[i - 1]
			var base: float = arc[i - 1]
			var length: float = arc[i] - base
			if length <= 0.0:
				continue
			var direction := a0.direction_to(path[i])
			var c0 := maxf(start, base)
			var c1 := minf(arc[i], start + REACH)
			var end := a0 + direction * (c1 - base)
			# короткий подход к дороге (до STEP) — тот же пунктир, чтобы не было стрелки под ногами
			var on_road := (i > road_first and i <= road_last) or (i == road_first and length < STEP)
			var next_ground := INF
			var checked: float = _checked.get(i, -INF)
			if c1 <= checked + 0.01:
				next_ground = _levels[i]
			else:
				# проверяется только ещё не проверенная часть участка (от прежней границы или от игрока)
				var from := nearest if i == segment else a0
				var from_level := ground
				if checked > c0:
					from = a0 + direction * (checked - base)
					from_level = _levels[i]
				next_ground = roads._segment(from, end, from_level)
				if next_ground != INF:
					_checked[i] = c1
					_levels[i] = next_ground
			if next_ground == INF:
				return {blocked = i}
			var reference := maxf(ground, next_ground)
			if on_road:
				_dashes(vertices, colors, a0, direction, base, c0, c1, reference, start, here)
			else:
				_arrows(vertices, colors, a0, direction, base, c0, c1, reference, start, here)
			ground = next_ground
			if c1 - start >= REACH:
				break
		return {vertices = vertices, colors = colors}

	## Штрихи на дороге: кусочки по сетке PIECE от начала маршрута; при предупреждении сетка едет назад
	func _dashes(vertices: PackedVector3Array, colors: PackedColorArray, a0: Vector2, direction: Vector2,
			base: float, c0: float, c1: float, ground: float, start: float, here: Vector2) -> void:
		var side := Vector2(-direction.y, direction.x) * HALF
		var k := floori((c0 + _flow) / PIECE)
		while k * PIECE - _flow < c1 and k * PIECE - _flow - start < REACH:
			var s0 := maxf(k * PIECE - _flow, c0)
			var s1 := minf((k + 1) * PIECE - _flow, c1)
			if posmod(k, DASH * 2) < DASH and s1 > s0:
				_piece(vertices, colors, a0 + direction * (s0 - base), a0 + direction * (s1 - base), side, ground, s0 - start, here)
			k += 1


	## Стрелки вне дороги: шаг STEP от начала маршрута, шаг общий с соседними отрезками — без пропусков
	func _arrows(vertices: PackedVector3Array, colors: PackedColorArray, a0: Vector2, direction: Vector2,
			base: float, c0: float, c1: float, ground: float, start: float, here: Vector2) -> void:
		var k := floori(c0 / STEP)
		while (k + 0.5) * STEP < c1 and (k + 0.5) * STEP - start < REACH:
			var s := (k + 0.5) * STEP
			if s >= c0:
				_arrow(vertices, colors, a0 + direction * (s - base), direction, ground, s - start, here)
			k += 1


	## Кусочек штриха от pa до pb: две половины арки, края на земле и прозрачные, середина выше и ярче
	func _piece(vertices: PackedVector3Array, colors: PackedColorArray, pa: Vector2, pb: Vector2, side: Vector2,
			ground: float, along: float, here: Vector2) -> void:
		var fade := (1.0 - smoothstep(50.0, REACH, along)) * smoothstep(1.0, 4.0, here.distance_to((pa + pb) * 0.5))
		if fade <= 0.01:
			return
		var key := Vector4(pa.x, pa.y, pb.x, pb.y)
		var lifted: PackedVector3Array = _lifts.get(key, PackedVector3Array())
		if lifted.is_empty():
			for corner: Array in [[pa - side, 0.0], [pa, ARCH], [pa + side, 0.0], [pb - side, 0.0], [pb, ARCH], [pb + side, 0.0]]:
				var p: Vector2 = corner[0]
				lifted.append(Vector3(p.x, _heights.surface_at(p.x, p.y, ground) + 0.10 + corner[1], p.y))
			_remember(key, lifted)
		var al := lifted[0]
		var ac := lifted[1]
		var ar := lifted[2]
		var bl := lifted[3]
		var bc := lifted[4]
		var br := lifted[5]
		var edge := Color(EDGE.lerp(WARN_EDGE, _wrong), fade * (0.12 + 0.08 * _wrong))
		var core := Color(CORE.lerp(WARN, _wrong), fade * (0.62 + 0.28 * _wrong))
		for v: Array in [[al, edge], [ac, core], [bc, core], [al, edge], [bc, core], [bl, edge],
				[ac, core], [ar, edge], [br, edge], [ac, core], [br, edge], [bc, core]]:
			vertices.append(v[0])
			colors.append(v[1])


	## Одна стрелка: плоскость наклонена к земле, остриё выше вылетов — с седла видно остриё вперёд.
	## Две полосы от острия к вылетам; остриё ярче, вылеты гаснут
	func _arrow(vertices: PackedVector3Array, colors: PackedColorArray, p: Vector2, dir: Vector2,
			ground: float, along: float, here: Vector2) -> void:
		var fade := (1.0 - smoothstep(50.0, REACH, along)) * smoothstep(2.0, 6.0, here.distance_to(p))
		if fade <= 0.01:
			return
		var key := Vector4(p.x, p.y, -1e9, 0.0)
		var cached: PackedVector3Array = _lifts.get(key, PackedVector3Array())
		if cached.is_empty():
			cached = PackedVector3Array([Vector3(p.x, _heights.surface_at(p.x, p.y, ground) + HOVER, p.y)])
			_remember(key, cached)
		var base := cached[0]
		var ahead := Vector3(dir.x, 0.0, dir.y) * cos(TILT) + Vector3.UP * sin(TILT)
		var side := Vector3(-dir.y, 0.0, dir.x)
		var tip := base + ahead * (ARM * 0.5)
		var core := Color(CORE.lerp(WARN, _wrong), fade * (0.65 + 0.25 * _wrong))
		var edge := Color(EDGE.lerp(WARN_EDGE, _wrong), fade * 0.06)
		for w: float in [-1.0, 1.0]:
			var wing := base - ahead * (ARM * 0.5) + side * (WING * w)
			var band := (ahead * (-WING * w) + side * (-ARM)).normalized() * (BAND * 0.5)
			for v: Array in [[tip - band, core], [tip + band, core], [wing + band, edge],
					[tip - band, core], [wing + band, edge], [wing - band, edge]]:
				vertices.append(v[0])
				colors.append(v[1])


	func _remember(key: Vector4, lifted: PackedVector3Array) -> void:
		if _lifts.size() > 6000:
			_lifts.clear()
		_lifts[key] = lifted


	## Движение против маршрута: направление пути берём сразу за ближайшей точкой, чтобы развилка
	## дороги не путала; шаг меньше 0,3 м направлением не считается


func _check_direction(here: Vector2, nearest: Vector2, start: float) -> void:
	var step := here - _last_here
	_last_here = here
	if step.length_squared() < 0.09:
		return
	var dir := nearest.direction_to(_ahead(start, 1.5))
	if dir.is_zero_approx():
		return
	if step.dot(dir) < -0.3 * step.length():
		_wrong = 1.0


## Точка маршрута через dist метров вперёд от дуги s
func _ahead(s: float, dist: float) -> Vector2:
	var target := s + dist
	var i := maxi(1, _cum.bsearch(target))
	if i >= path.size():
		return path[-1]
	var span: float = _cum[i] - _cum[i - 1]
	var t := 0.0 if span <= 0.0 else (target - _cum[i - 1]) / span
	return path[i - 1].lerp(path[i], t)

## Only one worker exists. A newer goal/revision supersedes its result without blocking a frame.
func _request_search(at: Vector2, feet: float, recheck_graph := false) -> void:
	var revision := _network_revision()
	if _search_task != -1 and _search_serial == _serial and _search_revision == revision: return
	_request = {at=at, feet=feet, target=_target, revision=revision, serial=_serial, recheck_graph=recheck_graph}
	if _search_task != -1:
		_search_roads.cancelled = true
		return
	_start_search()

func _start_search() -> void:
	var started := Time.get_ticks_usec()
	var request := _request
	_request = {}
	var reuse: bool = roads != null and _revision == request.revision and not request.recheck_graph
	var h := Snapshot.capture(_heights, not reuse)
	var search := Roads.new()
	_search_roads = search
	_search_revision = request.revision
	_search_serial = request.serial
	search._world = h.world
	search._heights = h
	if reuse:
		# Graph dictionaries are published once, route_to only reads them.
		search.points = roads.points
		search.links = roads.links
		search.levels = roads.levels
		search._cells = roads._cells
		search._node_keys = roads._node_keys
		search._edges = roads._edges
		search._components = roads._components
	status = "Расчёт маршрута…"
	var out := {}
	_search_out = out
	_search_task = WorkerThreadPool.add_task(func() -> void:
		if not reuse: search.build(search._world, search._heights)
		var found := search.route_to(request.at, request.target, request.feet) if not search.cancelled else PackedVector2Array()
		out.path = found
		out.index = _path_index(found)
		search._heights = null
		search._world = null, false, "Навигация")
	timings_us.search_start = Time.get_ticks_usec() - started

func _poll_search(here: Vector2) -> void:
	if _search_task != -1 and WorkerThreadPool.is_task_completed(_search_task):
		var started := Time.get_ticks_usec()
		WorkerThreadPool.wait_for_task_completion(_search_task)
		timings_us.search_join = Time.get_ticks_usec() - started
		_search_task = -1
		var retired: Array[RefCounted] = []
		if not _search_roads.cancelled and _search_serial == _serial and not _goal.is_empty() and _search_revision == _network_revision():
			retired.assign([roads, _painter])
			roads = _search_roads
			# Draw/arrival checks always use the current terrain and obstacles.
			roads._world = _world
			roads._heights = _heights
			path = _search_out.path
			_revision = _search_revision
			_last_here = here
			_accept_path(_search_out.index)
		else:
			retired.append(_search_roads)
		_search_roads = null
		_search_out = {}
		# Снятие последней ссылки на большой граф освобождает тысячи словарей и массивов.
		_retire_tasks.append(WorkerThreadPool.add_task(func() -> void: retired.clear(), false, "Старый граф маршрута"))
	if _search_task == -1 and not _request.is_empty(): _start_search()


func _poll_retired() -> void:
	for i in range(_retire_tasks.size() - 1, -1, -1):
		var task := _retire_tasks[i]
		if WorkerThreadPool.is_task_completed(task):
			WorkerThreadPool.wait_for_task_completion(task)
			_retire_tasks.remove_at(i)


func _stop_search() -> void:
	_request = {}
	if _search_task != -1:
		_search_roads.cancelled = true
		WorkerThreadPool.wait_for_task_completion(_search_task)
		_search_task = -1
	_search_roads = null
	_search_out = {}
	for task in _retire_tasks:
		WorkerThreadPool.wait_for_task_completion(task)
	_retire_tasks.clear()

func _finish_paint() -> void:
	if _paint_task != -1:
		WorkerThreadPool.wait_for_task_completion(_paint_task)
		_paint_task = -1
	_paint_out = {}


func _exit_tree() -> void:
	_stop_search()
	_finish_paint()
