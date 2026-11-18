extends Control
## Локальная карта с севером сверху. Все слои внутри одного круглого окна:
## новые линии (трек, маршрут) используют ту же проекцию и обрезку, что дороги.
##
## 18.11.2026, цена кадра: подложка (участки, дороги, реки, точки поселений) рисуется в SubViewport вдвое больше
## круга вокруг опорной точки _anchor и перерисовывается, только когда игрок отошёл от неё дальше SHIFT_M или пришли
## новые участки. Каждый кадр меняется лишь сдвиг выборки в шейдере маски (view_offset) и верхний слой _marks
## (стрелка игрока, велосипед, цели, подпись, легенда) — несколько кругов и строк. Раньше всё окно со всеми линиями
## и сглаживанием перерисовывалось и заново рендерилось каждый кадр, пока игрок двигался или поворачивался.
## Новые участки строятся не больше TILE_BUDGET за кадр: на скорости рывок от разом собранных картинок пропал.

const MapData = preload("res://scripts/ui/local_map_data.gd")
const Paint = preload("res://scripts/ui/map_paint.gd")
const DIAMETER := 220.0
const VIEW_SIZE := 208
const MAP_SIZE := VIEW_SIZE * 2   # подложка с запасом: круг сдвигается по ней без перерисовки
const CENTER := Vector2.ONE * (VIEW_SIZE * 0.5)
const MAP_CENTER := Vector2.ONE * (MAP_SIZE * 0.5)
const RADIUS_M := 180.0
const PIXELS_PER_METER := CENTER.x / RADIUS_M
const SHIFT_M := 80.0     # дальше от опорной точки — подложка перерисовывается вокруг игрока (запас окна 180 м)
const TILE_BUDGET := 1    # новых участков подложки за кадр
const SCALE_M := 50.0
const INK := Color("#344d56")
## 18.11.2026: маршрут навигации на подложке и метки целей за краем круга (стрелка на ободке и расстояние)
const ROUTE := Color("#f08a24")
const ROUTE_EDGE := Color(1, 1, 1, 0.95)
const GOAL := Color("#d98c28")
const BIKE := Color("#276582")
const RIM_INSET := 17.0

var _viewport: SubViewport
var _canvas: Node2D
var _face: TextureRect
var _mask: ShaderMaterial
var _marks: Control
var _data: MapData
var _position := Vector2.INF
var _anchor := Vector2.INF
var _heading := 0.0
var _bike := Vector2.INF
var _goal := Vector2.INF
var _quest := Vector2.INF
var _quest_color := Color.WHITE
var _knows: Callable
var _route := PackedVector2Array()  # путь навигации, мировые метры


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(MAP_SIZE, MAP_SIZE)
	_viewport.disable_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)
	_canvas = Node2D.new()
	_viewport.add_child(_canvas)
	_canvas.draw.connect(_draw_map)

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
	visibility_changed.connect(_on_visibility_changed)


func set_world(world: WorldData, knows := Callable(), source: MapData = null) -> void:
	_data = MapData.new(world, source) if world != null else null
	_knows = knows
	_position = Vector2.INF
	_anchor = Vector2.INF
	_bike = Vector2.INF
	_goal = Vector2.INF
	_quest = Vector2.INF
	_route = PackedVector2Array()
	queue_redraw()
	refresh()


func set_view(at: Vector2, heading: float) -> void:
	if at != _position or heading != _heading:
		_position = at
		_heading = heading
		if _anchor.is_finite() and _position.distance_to(_anchor) > SHIFT_M:
			refresh()
		else:
			_slide()


func set_destinations(goal: Dictionary, quest: Dictionary, quest_color: Color) -> void:
	var next_goal := _place_position(goal)
	var next_quest := _place_position(quest)
	if next_goal == _goal and next_quest == _quest and quest_color == _quest_color:
		return
	_goal = next_goal
	_quest = next_quest
	_quest_color = quest_color
	_redraw_marks()


## Путь навигации (NavigationLine.path); пустой — маршрута нет. Подложка перерисовывается один раз
func set_route(points: PackedVector2Array) -> void:
	if points == _route:
		return
	_route = points.duplicate()
	if _anchor.is_finite():
		_render()


func set_bike(at: Vector2) -> void:
	if _bike != at:
		_bike = at
		_redraw_marks()


func _process(_delta: float) -> void:
	if _data == null or not _position.is_finite() or not is_visible_in_tree():
		return
	var moved := not _anchor.is_finite() or _position.distance_to(_anchor) > SHIFT_M
	if moved:
		_anchor = _position
	var half := MAP_CENTER.x / PIXELS_PER_METER
	if _data.update(Rect2(_anchor - Vector2.ONE * half, Vector2.ONE * half * 2.0), TILE_BUDGET) or moved:
		_render()
		_slide()


## Подложку — перерисовать (новый мир, показ, сдвиг дальше SHIFT_M); опорная точка переставится в _process
func refresh() -> void:
	_anchor = Vector2.INF
	if _canvas != null and is_visible_in_tree():
		_process(0.0)
		_redraw_marks()


func _render() -> void:
	_canvas.queue_redraw()
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


## Сдвиг круга по готовой подложке и верхний слой — то, что меняется каждый кадр
func _slide() -> void:
	if _mask == null or not _anchor.is_finite() or not _position.is_finite():
		_redraw_marks()
		return
	var corner := MAP_CENTER - CENTER + (_position - _anchor) * PIXELS_PER_METER
	_mask.set_shader_parameter("view_offset", corner / MAP_SIZE)
	_redraw_marks()


func _redraw_marks() -> void:
	if _marks != null and is_visible_in_tree():
		_marks.queue_redraw()


func _on_visibility_changed() -> void:
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
	draw_circle(center + Vector2(0.0, 2.0), CENTER.x + 5.0, Color(0.03, 0.08, 0.10, 0.32), true, -1.0, true)
	draw_circle(center, CENTER.x + 4.0, Color("#f4f7f5"), true, -1.0, true)
	draw_arc(center, CENTER.x + 4.5, 0.0, TAU, 128, Color(0.1, 0.17, 0.19, 0.62), 1.0, true)


func _draw_map() -> void:
	_canvas.draw_rect(Rect2(Vector2.ZERO, MAP_CENTER * 2.0), MapData.EMPTY)
	if _data == null or not _anchor.is_finite():
		return
	Paint.surface(_canvas, _data, _to_canvas(Vector2.ZERO), PIXELS_PER_METER)
	_draw_route()
	for place: Dictionary in _visible_settlements():
		var at := _to_canvas(place.position)
		_canvas.draw_circle(at, 4.0, Color.WHITE, true, -1.0, true)
		_canvas.draw_circle(at, 2.5, Color("#706387"), true, -1.0, true)


## Маршрут поверх дорог: широкая белая кайма и яркая середина, только отрезки в пределах подложки
func _draw_route() -> void:
	if _route.size() < 2:
		return
	var area := Rect2(Vector2.ZERO, MAP_CENTER * 2.0).grow(8.0)
	var lines := PackedVector2Array()
	var a := _to_canvas(_route[0])
	for i in range(1, _route.size()):
		var b := _to_canvas(_route[i])
		if area.has_point(a) or area.has_point(b):
			lines.append(a)
			lines.append(b)
		a = b
	if lines.is_empty():
		return
	_canvas.draw_multiline(lines, ROUTE_EDGE, 7.0, true)
	_canvas.draw_multiline(lines, ROUTE, 4.2, true)
	# стыки отрезков без зазоров
	for i in range(0, lines.size(), 2):
		_canvas.draw_circle(lines[i], 2.1, ROUTE, true, -1.0, true)


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
		_draw_label()
		_draw_markers()
		Paint.player(_marks, CENTER, _heading)
	_draw_legend()


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


func _draw_markers() -> void:
	if _bike.is_finite():
		var at := world_to_map(_bike)
		if _fits(at, 7.0):
			_marks.draw_circle(at, 4.0, Color.WHITE, true, -1.0, true)
			_marks.draw_circle(at, 2.6, BIKE, true, -1.0, true)
		elif _position.distance_to(_bike) > 8.0:
			_rim(_bike, BIKE, "bike", false)
	var same := _goal.is_finite() and _quest.is_finite() and _goal.distance_to(_quest) < 6.0
	if _goal.is_finite() and not same:
		var at := world_to_map(_goal)
		if _fits(at, 8.0):
			_marks.draw_circle(at, 6.5, Color.WHITE, true, -1.0, true)
			_marks.draw_circle(at, 4.5, GOAL, false, 2.5, true)
		else:
			_rim(_goal, GOAL, "goal", true)
	if _quest.is_finite():
		var at := world_to_map(_quest)
		if _fits(at, 8.0):
			_marks.draw_rect(Rect2(at - Vector2.ONE * 4.0, Vector2.ONE * 8.0), _quest_color)
			_marks.draw_rect(Rect2(at - Vector2.ONE * 4.0, Vector2.ONE * 8.0), INK, false, 1.5)
		else:
			_rim(_quest, _quest_color, "quest", true)


## Цель за краем круга: значок на ободке в её сторону, остриё наружу, расстояние — внутрь круга
func _rim(target: Vector2, color: Color, kind: String, distance: bool) -> void:
	var dir := (target - _position).normalized()
	if dir.is_zero_approx():
		return
	var at := CENTER + dir * (CENTER.x - RIM_INSET)
	var side := Vector2(-dir.y, dir.x)
	_marks.draw_circle(at, 7.5, Color.WHITE, true, -1.0, true)
	# остриё за значком — куда ехать
	_marks.draw_colored_polygon(PackedVector2Array([at + dir * 14.5, at + dir * 8.0 + side * 5.0, at + dir * 8.0 - side * 5.0]), INK)
	match kind:
		"quest":
			_marks.draw_rect(Rect2(at - Vector2.ONE * 4.0, Vector2.ONE * 8.0), color)
			_marks.draw_rect(Rect2(at - Vector2.ONE * 4.0, Vector2.ONE * 8.0), INK, false, 1.2)
		"goal":
			_marks.draw_circle(at, 4.5, color, false, 2.5, true)
		_:
			_marks.draw_circle(at, 4.0, color, true, -1.0, true)
	if distance:
		var label := Util.distance_text(_position.distance_to(target))
		var inward := at - dir * (18.0 + absf(dir.x) * _text_width(label, 11) * 0.5)
		_text(label, inward + Vector2(0.0, 4.0), 11)


func _draw_legend() -> void:
	_marks.draw_circle(Vector2(CENTER.x, 16.0), 10.0, Color(1, 1, 1, 0.92), true, -1.0, true)
	_text("С", Vector2(CENTER.x, 20.0), 13, false)
	var y := VIEW_SIZE - 17.0
	var half := SCALE_M * PIXELS_PER_METER * 0.5
	var left := Vector2(CENTER.x - half, y)
	var right := Vector2(CENTER.x + half, y)
	_marks.draw_polyline(PackedVector2Array([left - Vector2(0, 3), left, right, right - Vector2(0, 3)]), INK, 1.4, true)
	_text("50 м", Vector2(CENTER.x, y - 6.0), 11)


func _fits(at: Vector2, margin: float) -> bool:
	return CENTER.distance_squared_to(at) <= pow(CENTER.x - margin, 2)


static func _text_width(title: String, font_size: int) -> float:
	return ThemeDB.fallback_font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x


func _text(title: String, at: Vector2, font_size: int, outline := true) -> void:
	var font := ThemeDB.fallback_font
	at.x -= _text_width(title, font_size) * 0.5
	if outline:
		_marks.draw_string_outline(font, at, title, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 4, Color(1, 1, 1, 0.95))
	_marks.draw_string(font, at, title, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, INK)
