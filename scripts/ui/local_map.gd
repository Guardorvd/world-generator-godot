extends Control
## North-up map. The viewport has room to slide the circular window over cached
## terrain, linework and route layers; the player arrow only updates its transform.

const MapData = preload("res://scripts/ui/local_map_data.gd")
const Paint = preload("res://scripts/ui/map_paint.gd")
const HudStyle = preload("res://scripts/ui/hud_style.gd")
const UiIcons = preload("res://scripts/ui/ui_icons.gd")
const DIAMETER := 220.0
const VIEW_SIZE := 208
const MAP_SIZE := VIEW_SIZE * 2   # подложка с запасом: круг сдвигается по ней без перерисовки
const CENTER := Vector2.ONE * (VIEW_SIZE * 0.5)
const MAP_CENTER := Vector2.ONE * (MAP_SIZE * 0.5)
const RADIUS_M := 180.0
const PIXELS_PER_METER := CENTER.x / RADIUS_M
const SHIFT_M := 80.0     # дальше от опорной точки — подложка перерисовывается вокруг игрока (запас окна 180 м)
const OUTER_POLL := 0.125
const MARK_STEP := 0.5 / PIXELS_PER_METER
const TILE_BUDGET := 1    # новых участков подложки за кадр
const SCALE_M := 50.0
const INK := Color("#344d56")
## 18.11.2026: маршрут навигации на подложке и метки целей за краем круга (стрелка на ободке и расстояние)
const ROUTE := Color("#ff9a2e")       # середина дороги маршрута
const ROUTE_EDGE := Color("#b5560f")  # её кромка: та же толщина, что у дороги подложки — дорога «загорается»
const GOAL := Color("#d98c28")
const BIKE := Color("#276582")
const RIM_INSET := 18.5

var _viewport: SubViewport
var _surface: Node2D
var _tiles_canvas: Node2D
var _lines_canvas: Node2D
var _route_canvas: Node2D
var _places_canvas: Node2D
var _arrow: Node2D
var _legend: Control
var _face: TextureRect
var _mask: ShaderMaterial
var _marks: Control
var _label_taken: Array[Rect2] = []  # 19.11.2026: занятые места подписей на верхнем слое (сброс при перерисовке)
var _data: MapData
var _position := Vector2.INF
var _anchor := Vector2.INF
var _heading := 0.0
var _marks_at := Vector2.INF
var _outer_poll := 0.0
var _bike := Vector2.INF
var _goal := Vector2.INF
var _quest := Vector2.INF
var _quest_color := Color.WHITE
var _quest_kind := ""
var _knows: Callable
var _route := PackedVector2Array()  # путь навигации, мировые метры
var _route_road := Vector2i(0, -1)
var _places: Array[Dictionary] = []  # известные места для значков: {at — м, kind: peak | site}
const PLACE_GAP := 22.0   # px: ближе друг к другу и к поселениям значки не ставятся — без мешанины
const PLACE_MAX := 14


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(MAP_SIZE, MAP_SIZE)
	_viewport.disable_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)
	var background := Node2D.new()
	background.draw.connect(func() -> void: background.draw_rect(Rect2(Vector2.ZERO, MAP_CENTER * 2.0), MapData.EMPTY))
	_viewport.add_child(background)
	_surface = Node2D.new()
	_surface.scale = Vector2.ONE * PIXELS_PER_METER
	_viewport.add_child(_surface)
	_tiles_canvas = Node2D.new()
	_tiles_canvas.draw.connect(_draw_tiles)
	_surface.add_child(_tiles_canvas)
	_lines_canvas = Node2D.new()
	_lines_canvas.draw.connect(_draw_lines)
	_surface.add_child(_lines_canvas)
	_route_canvas = Node2D.new()
	_viewport.add_child(_route_canvas)
	_route_canvas.draw.connect(_draw_route)
	_places_canvas = Node2D.new()
	_viewport.add_child(_places_canvas)
	_places_canvas.draw.connect(_draw_map_places)

	var inset := Vector2.ONE * ((DIAMETER - VIEW_SIZE) * 0.5)
	_face = TextureRect.new()
	_face.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_face.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_face.stretch_mode = TextureRect.STRETCH_SCALE
	_face.position = inset
	_face.size = Vector2.ONE * VIEW_SIZE
	_face.texture = _viewport.get_texture()
	_mask = ShaderMaterial.new()
	_mask.shader = preload("res://resources/local_map_mask.gdshader")
	_mask.set_shader_parameter("view_scale", float(VIEW_SIZE) / MAP_SIZE)
	_face.material = _mask
	add_child(_face)
	_marks = Control.new()
	_marks.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_marks.position = inset
	_marks.size = Vector2.ONE * VIEW_SIZE
	_marks.draw.connect(_draw_marks)
	add_child(_marks)
	_arrow = Node2D.new()
	_arrow.position = inset + CENTER
	_arrow.rotation = -_heading
	_arrow.draw.connect(func() -> void: Paint.player(_arrow, Vector2.ZERO, 0.0))
	add_child(_arrow)
	_legend = Control.new()
	_legend.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_legend.position = inset
	_legend.draw.connect(_draw_legend)
	add_child(_legend)
	visibility_changed.connect(_on_visibility_changed)


func set_world(world: WorldData, knows := Callable(), source: MapData = null) -> void:
	_data = MapData.new(world, source) if world != null else null
	_knows = knows
	_position = Vector2.INF
	_marks_at = Vector2.INF
	_anchor = Vector2.INF
	_bike = Vector2.INF
	_goal = Vector2.INF
	_quest = Vector2.INF
	_quest_kind = ""
	_route = PackedVector2Array()
	_places = []
	queue_redraw()
	refresh()


func set_view(at: Vector2, heading: float) -> void:
	if heading != _heading:
		_heading = heading
		if _arrow != null:
			_arrow.rotation = -heading
	if at == _position:
		return
	_position = at
	if not is_visible_in_tree():
		return
	if _anchor.is_finite() and _position.distance_squared_to(_anchor) <= SHIFT_M * SHIFT_M:
		_slide()
	if not _marks_at.is_finite() or _marks_at.distance_squared_to(at) >= MARK_STEP * MARK_STEP:
		_redraw_marks()


func set_destinations(goal: Dictionary, quest: Dictionary, quest_color: Color, quest_kind := "") -> void:
	var next_goal := _place_position(goal)
	var next_quest := _place_position(quest)
	if next_goal == _goal and next_quest == _quest and quest_color == _quest_color and quest_kind == _quest_kind:
		return
	_goal = next_goal
	_quest = next_quest
	_quest_color = quest_color
	_quest_kind = quest_kind
	_redraw_marks()


## Путь навигации (NavigationLine.path); пустой — маршрута нет. Подложка перерисовывается один раз
func set_route(points: PackedVector2Array, road_first := 0, road_last := -1) -> void:
	if points == _route and _route_road == Vector2i(road_first, road_last):
		return
	_route = points
	_route_road = Vector2i(road_first, road_last)
	if _anchor.is_finite() and is_visible_in_tree():
		_route_canvas.queue_redraw()
		_render()


## 18.11.2026: известные места (вершины и сооружения), значки на подложке; перерисовка только если список сменился
func set_places(places: Array[Dictionary]) -> void:
	if places == _places:
		return
	_places = places
	if _anchor.is_finite() and is_visible_in_tree():
		_places_canvas.queue_redraw()
		_render()


func set_bike(at: Vector2) -> void:
	if _bike != at:
		_bike = at
		_redraw_marks()


func _process(delta: float) -> void:
	if _data == null or not _position.is_finite():
		return
	var moved := not _anchor.is_finite() or _position.distance_squared_to(_anchor) > SHIFT_M * SHIFT_M
	_outer_poll -= delta
	if not moved and not _data.pending and not _data.outer_changed() and (_outer_poll > 0.0 or not _data.uses_outer()):
		return
	_outer_poll = OUTER_POLL
	if moved:
		_anchor = _position
		_surface.position = _to_canvas(Vector2.ZERO)
		_route_canvas.queue_redraw()
		_slide()
	var half := MAP_CENTER.x / PIXELS_PER_METER
	var old_features := _data.feature_revision
	var old_tiles := _data.tile_revision
	var changed := _data.update(Rect2(_anchor - Vector2.ONE * half, Vector2.ONE * half * 2.0), TILE_BUDGET)
	if moved or _data.tile_revision != old_tiles:
		_tiles_canvas.queue_redraw()
	if moved or _data.feature_revision != old_features:
		_lines_canvas.queue_redraw()
		_places_canvas.queue_redraw()
		_redraw_marks()
	if changed or moved:
		_render()


func refresh() -> void:
	_anchor = Vector2.INF
	_arrow.visible = _data != null and _position.is_finite()
	if is_visible_in_tree():
		_redraw_marks()


func _render() -> void:
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func _slide() -> void:
	var corner := MAP_CENTER - CENTER + (_position - _anchor) * PIXELS_PER_METER
	_mask.set_shader_parameter("view_offset", corner / MAP_SIZE)


func _redraw_marks() -> void:
	if _marks != null and is_visible_in_tree():
		_marks_at = _position
		_arrow.visible = _data != null and _position.is_finite()
		_marks.queue_redraw()


func _on_visibility_changed() -> void:
	set_process(is_visible_in_tree())
	if is_visible_in_tree():
		refresh()
	elif _data != null:
		_data.release_view()
		_anchor = Vector2.INF


## Мировые метры (x, z) в координаты слоёв внутри круглого окна.
func world_to_map(at: Vector2) -> Vector2:
	return CENTER + (at - _position) * PIXELS_PER_METER


## Мировые метры в координаты подложки (вокруг опорной точки)
func _to_canvas(at: Vector2) -> Vector2:
	return MAP_CENTER + (at - _anchor) * PIXELS_PER_METER


static func _place_position(place: Dictionary) -> Vector2:
	return Vector2.INF if place.is_empty() else Vector2(place.x, place.y) * GameConfig.TILE


func _draw() -> void:
	var center := Vector2.ONE * (DIAMETER * 0.5)
	# 18.11.2026: обод в палитре HUD (тёмная хвойная кайма + тонкое кольцо бумаги), а не яркий белый диск —
	# мини-карта не перетягивает взгляд в угол
	draw_circle(center + Vector2(0.0, 2.0), CENTER.x + 5.5, Color(0.03, 0.07, 0.06, 0.3), true, -1.0, true)
	draw_circle(center, CENTER.x + 5.0, Color(HudStyle.SURFACE, 0.92), true, -1.0, true)
	draw_arc(center, CENTER.x + 4.5, 0.0, TAU, 128, HudStyle.BORDER, 1.0, true)
	draw_circle(center, CENTER.x + 1.5, HudStyle.PAPER, true, -1.0, true)


func _draw_tiles() -> void:
	if _data != null:
		Paint.tiles(_tiles_canvas, _data, false)


func _draw_lines() -> void:
	if _data != null:
		Paint.lines(_lines_canvas, _data, PIXELS_PER_METER, false)


static func _draw_badge(canvas: CanvasItem, at: Vector2, bg: Color, halo: Color, icon: Texture2D,
		icon_color := Color.WHITE, radius := 7.2, icon_size := 11.0) -> void:
	canvas.draw_circle(at, radius + 1.3, halo, true, -1.0, true)
	canvas.draw_circle(at, radius, bg, true, -1.0, true)
	canvas.draw_texture_rect(icon, Rect2(at - Vector2.ONE * icon_size * 0.5, Vector2.ONE * icon_size), false, icon_color)


func _draw_map_places() -> void:
	if _data == null or not _anchor.is_finite():
		return
	var taken: Array[Vector2] = []
	for place: Dictionary in _visible_settlements():
		var at := _to_canvas(place.position)
		taken.append(at)
		_draw_badge(_places_canvas, at, Color("#5f507a"), Color.WHITE, UiIcons.map_icon("settlement"))
	_draw_places(taken)


## Значки известных мест: ближние к середине первыми, не теснее PLACE_GAP друг к другу и к поселениям, не больше PLACE_MAX
func _draw_places(taken: Array[Vector2]) -> void:
	var area := Rect2(Vector2.ZERO, MAP_CENTER * 2.0).grow(-6.0)
	var near: Array = []
	for place: Dictionary in _places:
		var at := _to_canvas(place.at)
		if area.has_point(at):
			near.append([at.distance_squared_to(MAP_CENTER), at, place.kind, place.get("icon", place.kind)])
	near.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var shown := 0
	for item: Array in near:
		var at: Vector2 = item[1]
		if shown >= PLACE_MAX or taken.any(func(t: Vector2) -> bool: return t.distance_squared_to(at) < PLACE_GAP * PLACE_GAP):
			continue
		taken.append(at)
		shown += 1
		var kind := str(item[2])
		var bg := Color("#866038") if kind == "peak" else (Color("#2f6d8c") if kind == "lake" else Color("#316760"))
		_draw_badge(_places_canvas, at, bg, Color.WHITE, UiIcons.map_icon(str(item[3])))


## Маршрут: дорожная часть пути идёт по тем же точкам участков, что и линии дорог подложки (граф навигации — вершины
## линий), поэтому её рисуем поверх дороги той же толщиной другим цветом — подсвечивается сама дорога. Подходы вне дорог
## — тонкий пунктир. Только отрезки в пределах подложки
func _draw_route() -> void:
	if _route.size() < 2 or not _anchor.is_finite():
		return
	var area := Rect2(Vector2.ZERO, MAP_CENTER * 2.0).grow(8.0)
	var roads: Array[PackedVector2Array] = []
	var run := PackedVector2Array()
	var a := _to_canvas(_route[0])
	for i in range(1, _route.size()):
		var b := _to_canvas(_route[i])
		if a == b:
			continue
		var visible_segment := area.intersects(Rect2(a, Vector2.ZERO).expand(b).grow(0.01))
		var on_road := i > _route_road.x and i <= _route_road.y
		if visible_segment and on_road:
			if run.is_empty():
				run.append(a)
			run.append(b)
		else:
			if not run.is_empty():
				roads.append(run)
				run = PackedVector2Array()
			if visible_segment:
				_route_canvas.draw_dashed_line(a, b, ROUTE_EDGE, 2.0, 4.0, true, true)
		a = b
	if not run.is_empty():
		roads.append(run)
	_draw_road_runs(roads, ROUTE_EDGE, 6.0)
	_draw_road_runs(roads, ROUTE, 4.0)


func _draw_road_runs(roads: Array[PackedVector2Array], color: Color, width: float) -> void:
	# The polyline joins dense route points in one command. Only the ends need round caps.
	for run in roads:
		_route_canvas.draw_polyline(run, color, width, true)
		_route_canvas.draw_circle(run[0], width * 0.5, color, true, -1.0, true)
		_route_canvas.draw_circle(run[-1], width * 0.5, color, true, -1.0, true)


## Поселения подложки на открытой земле
func _visible_settlements() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var bounds: Rect2i = _data.world.available_rect
	for place: Dictionary in _data.settlements:
		var cell := Vector2i((place.position / GameConfig.TILE).floor())
		if bounds.has_area() and not bounds.has_point(cell) and not _data.world.accessible(cell.x, cell.y):
			continue
		out.append(place)
	return out


func _draw_marks() -> void:
	if _data != null and _position.is_finite():
		# 19.11.2026: занятые места для подписей расстояний у ободка — «С», линейка, подпись деревни, соседняя подпись
		var half := SCALE_M * PIXELS_PER_METER * 0.5
		_label_taken = [Rect2(CENTER.x - 13.0, 3.0, 26.0, 27.0),
			Rect2(CENTER.x - half - 6.0, VIEW_SIZE - 33.0, half * 2.0 + 12.0, 22.0)]
		_draw_label()
		_draw_markers()


## Подпись ближайшего знакомого поселения
func _draw_label() -> void:
	var closest := 72.0 * 72.0
	var label := {}
	for place: Dictionary in _data.settlements:
		var at := world_to_map(place.position)
		var distance := at.distance_squared_to(CENTER)
		if distance >= closest or not _fits(at, 5.0) or not _knows.is_valid() or not _knows.call(place.key):
			continue
		closest = distance
		label = {title = place.title, at = at}
	if label.is_empty():
		return
	var at: Vector2 = label.at + Vector2(0, -12)
	if at.distance_to(CENTER) < 21.0:
		at.y += -14.0 if at.y < CENTER.y else 27.0
	var half := _text_width(label.title, 12) * 0.5
	if _fits(at + Vector2(-half, -10), 7.0) and _fits(at + Vector2(half, -10), 7.0) and at.y > 35.0 and at.y < VIEW_SIZE - 36.0:
		_text(label.title, at, 12)
		_label_taken.append(Rect2(at.x - half, at.y - 12.0, half * 2.0, 15.0))


func _draw_markers() -> void:
	if _bike.is_finite():
		var at := world_to_map(_bike)
		if _fits(at, 8.0):
			_draw_badge(_marks, at, BIKE, Color.WHITE, UiIcons.map_icon("bike"), Color.WHITE, 6.8, 10.5)
		elif _position.distance_to(_bike) > 8.0:
			_rim(_bike, BIKE, "bike", false)
	var same := _goal.is_finite() and _quest.is_finite() and _goal.distance_to(_quest) < 6.0
	if _goal.is_finite() and not same:
		var at := world_to_map(_goal)
		if _fits(at, 9.0):
			_draw_badge(_marks, at, HudStyle.SURFACE, Color.WHITE, UiIcons.map_icon("goal"), HudStyle.AMBER, 7.6, 11.5)
			_marks.draw_arc(at, 7.6, 0.0, TAU, 24, GOAL, 1.4, true)
		else:
			_rim(_goal, GOAL, "goal", true)
	if _quest.is_finite():
		var at := world_to_map(_quest)
		if _fits(at, 9.0):
			_draw_badge(_marks, at, HudStyle.SURFACE, Color.WHITE, UiIcons.quest_small(_quest_kind), _quest_color, 8.0, 12.0)
			_marks.draw_arc(at, 8.0, 0.0, TAU, 24, _quest_color, 1.5, true)
		else:
			_rim(_quest, _quest_color, "quest", true)


## Цель за краем круга: значок на ободке в её сторону, остриё наружу, расстояние — внутрь круга
func _rim(target: Vector2, color: Color, kind: String, distance: bool) -> void:
	var dir := (target - _position).normalized()
	if dir.is_zero_approx():
		return
	var at := CENTER + dir * (CENTER.x - RIM_INSET)
	var side := Vector2(-dir.y, dir.x)
	# остриё за значком — куда ехать
	_marks.draw_colored_polygon(PackedVector2Array([at + dir * 15.0, at + dir * 8.5 + side * 5.0, at + dir * 8.5 - side * 5.0]), INK)
	match kind:
		"quest":
			_draw_badge(_marks, at, HudStyle.SURFACE, Color.WHITE, UiIcons.quest_small(_quest_kind), color, 8.0, 12.0)
			_marks.draw_arc(at, 8.0, 0.0, TAU, 24, color, 1.5, true)
		"goal":
			_draw_badge(_marks, at, HudStyle.SURFACE, Color.WHITE, UiIcons.map_icon("goal"), HudStyle.AMBER, 7.6, 11.5)
			_marks.draw_arc(at, 7.6, 0.0, TAU, 24, color, 1.4, true)
		_:
			_draw_badge(_marks, at, color, Color.WHITE, UiIcons.map_icon("bike"), Color.WHITE, 6.8, 10.5)
	if distance:
		var label := Util.distance_text(_position.distance_to(target))
		var width := _text_width(label, 11)
		var inward := at - dir * (19.5 + absf(dir.x) * width * 0.5)
		# внутрь круга; если там «С», линейка, подпись деревни или соседнее расстояние — вбок вдоль ободка
		var shift := width * 0.5 + 16.0
		var chosen := inward
		for candidate: Vector2 in [inward, inward + side * shift, inward - side * shift, inward - dir * 16.0]:
			var rect := Rect2(candidate + Vector2(-width * 0.5, -7.0), Vector2(width, 14.0))
			if _fits(candidate, width * 0.5 + 4.0) and not _label_taken.any(func(r: Rect2) -> bool: return r.intersects(rect)):
				chosen = candidate
				break
		_label_taken.append(Rect2(chosen + Vector2(-width * 0.5, -7.0), Vector2(width, 14.0)))
		_text(label, chosen + Vector2(0.0, 4.0), 11)


func _draw_legend() -> void:
	_legend.draw_circle(Vector2(CENTER.x, 16.0), 10.0, Color(1, 1, 1, 0.92), true, -1.0, true)
	_text("С", Vector2(CENTER.x, 20.0), 13, false, _legend)
	var y := VIEW_SIZE - 17.0
	var half := SCALE_M * PIXELS_PER_METER * 0.5
	var left := Vector2(CENTER.x - half, y)
	var right := Vector2(CENTER.x + half, y)
	_legend.draw_polyline(PackedVector2Array([left - Vector2(0, 3), left, right, right - Vector2(0, 3)]), INK, 1.4, true)
	_text("50 м", Vector2(CENTER.x, y - 6.0), 11, true, _legend)


func _fits(at: Vector2, margin: float) -> bool:
	return CENTER.distance_squared_to(at) <= pow(CENTER.x - margin, 2)


static func _text_width(title: String, font_size: int) -> float:
	return ThemeDB.fallback_font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x


func _text(title: String, at: Vector2, font_size: int, outline := true, canvas: Control = null) -> void:
	if canvas == null:
		canvas = _marks
	var font := ThemeDB.fallback_font
	at.x -= _text_width(title, font_size) * 0.5
	if outline:
		canvas.draw_string_outline(font, at, title, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 4, Color(1, 1, 1, 0.95))
	canvas.draw_string(font, at, title, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, INK)
