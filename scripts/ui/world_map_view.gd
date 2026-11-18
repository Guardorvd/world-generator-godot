extends Control
## Карта с двумя слоями: подложка перерисовывается при сдвиге, масштабе или
## поступлении участков. Положение игрока и трек обновляют только верхний слой.
##
## 18.11.2026: подложка — отдельный слой _base в мировых метрах; сдвиг и масштаб меняют только его положение и масштаб,
## без перезаписи команд отрисовки. Раньше каждое движение мыши при перетаскивании заново записывало все участки
## и все линии дорог со сглаживанием — карта тормозила. Перезапись — когда пришли участки или сменился масштаб
## (толщина линий). paper — стиль карты нацпарка (бумага, тёплые цвета, засечки) для личной карты, park — доска
## поселения (тот же стиль, без перетаскивания). У личной карты неисследованное закрыто бумагой (_fog): открыто
## вокруг пройденного трека и открытых мест; отдаление — не дальше стартовой области.

signal place_selected(place: Dictionary)
signal marker_requested(at: Vector2)

const Data = preload("res://scripts/ui/local_map_data.gd")
const Paint = preload("res://scripts/ui/map_paint.gd")
const Journal = preload("res://scripts/game/map_journal.gd")
const TILE := GameConfig.TILE
const PICK := 17.0
const MIN_SCALE := 0.06
const MAX_SCALE := 2.2
const FOG_CELL := 16.0     # м на пиксель маски исследованного
const FOG_TRACK := 260.0   # м открыто вокруг пройденного пути
const FOG_PLACE := 160.0   # м открыто вокруг открытого места
const FOG_STEP := 60.0     # м между отметками трека в маске

var park := false
var paper := false
var journal: Journal
var hover := {}
var places: Array = []
var player := Vector2.INF
var heading := 0.0
var goal := Vector2.INF
var quest := Vector2.INF
var quest_color := Color.WHITE
var move_hint := ""
var _data: Data
var _base: Control
var _overlay: Control
var _center := Vector2.ZERO
var _scale := 0.2
var _min_scale := MIN_SCALE
var _drawn_scale := -1.0
var _bounds := Rect2()
var _fit := Rect2()
var _pressed := Vector2.INF
var _button := MOUSE_BUTTON_NONE
var _dragged := false
var _base_dirty := false
var _last_revision := -1
var _park_font: SystemFont
var _fog: Image
var _fog_texture: ImageTexture
var _fog_node: Control      # слой бумаги в _base: свой шейдер размывает край маски
var _fog_legs := 0          # сколько отрезков трека уже открыто в маске
var _fog_last := Vector2.INF
var _fog_places := {}


func _ready() -> void:
	clip_contents = true
	mouse_default_cursor_shape = Control.CURSOR_ARROW if park else Control.CURSOR_DRAG
	_base = Control.new()
	_base.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_base.draw.connect(_draw_base)
	add_child(_base)
	_fog_node = Control.new()
	_fog_node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fog_material := ShaderMaterial.new()
	fog_material.shader = preload("res://resources/map_fog.gdshader")
	_fog_node.material = fog_material
	_fog_node.draw.connect(_draw_fog)
	_base.add_child(_fog_node)
	_overlay = Control.new()
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_overlay)
	_overlay.draw.connect(_draw_overlay)
	mouse_exited.connect(func() -> void: _set_hover({}))
	resized.connect(_reframe)
	visibility_changed.connect(_visibility_changed)
	if _styled():
		_park_font = SystemFont.new()
		_park_font.font_names = ["Georgia", "Noto Serif", "DejaVu Serif"]
	_visibility_changed()


## Бумажный стиль: доска поселения или личная карта
func _styled() -> bool:
	return park or paper


func set_source(source: Data) -> void:
	_data = Data.new(source.world, source) if source != null else null
	if _data != null:
		_data.park = park
	hover = {}
	places = []
	player = Vector2.INF
	goal = Vector2.INF
	quest = Vector2.INF
	_last_revision = -1
	_fog = null
	_fog_texture = null
	_fog_legs = 0
	_fog_last = Vector2.INF
	_fog_places = {}
	reset_view()


func reset_view() -> void:
	if _data == null:
		return
	var extent := Vector2(_data.world.W, _data.world.H) * TILE
	_bounds = Rect2(Vector2.ZERO, extent)
	_fit = _bounds.grow(50.0)
	_reframe()


func configure_board(source: Data, pins: Array) -> void:
	set_source(source)
	set_places(pins)
	if places.is_empty():
		return
	var at := place_at(places[0])
	var area := Rect2(at - Vector2(110, 70), Vector2(220, 140))
	for place: Dictionary in places:
		area = area.expand(place_at(place))
	_fit = area.grow(44.0)
	_bounds = _bounds.merge(_fit)
	_reframe()


func prepare_player_view() -> void:
	if _data == null:
		return
	# 18.11.2026: только стартовая область — соседние области на личной карте не нужны, отдаление до её размера
	var w := _data.world
	_bounds = Rect2(Vector2.ZERO, Vector2(w.W, w.H) * TILE)
	_fit = _bounds.grow(50.0)
	_update_fog()
	_reframe()
	refresh_overlay()


func set_places(pins: Array) -> void:
	places = pins
	if paper and _fog != null:
		for place: Dictionary in places:
			if not _fog_places.has(place.key):
				_fog_places[place.key] = true
				_open_fog(place_at(place), FOG_PLACE)
		_publish_fog()
	_set_hover({})
	refresh_overlay()


func set_player(at: Vector2, yaw: float) -> void:
	var new_point := not player.is_finite() or player.distance_squared_to(at) * _scale * _scale >= 0.8
	var turned := absf(angle_difference(heading, yaw)) >= 0.045
	if new_point or turned:
		player = at
		heading = yaw
		refresh_overlay()


func refresh_overlay() -> void:
	if _overlay != null and is_visible_in_tree():
		_overlay.queue_redraw()


func _visibility_changed() -> void:
	set_process(is_visible_in_tree())
	if is_visible_in_tree():
		_update_base()
		refresh_overlay()
	elif _data != null:
		_data.release_view()
		_drawn_scale = -1.0
		_pressed = Vector2.INF
		_button = MOUSE_BUTTON_NONE
		_dragged = false


func _process(_delta: float) -> void:
	if _data != null and (_base_dirty or _data.pending):
		_refresh_base()
	if journal != null and journal.revision != _last_revision:
		_last_revision = journal.revision
		if paper and _fog != null:
			_update_fog()
		refresh_overlay()


func _reframe() -> void:
	if _fit.has_area() and size.x > 1.0 and size.y > 1.0:
		_center = _fit.get_center()
		var inset := Vector2(92, 96) if park else Vector2(42, 80)
		var area := (size - inset).max(Vector2.ONE)
		_scale = clampf(minf(area.x / _fit.size.x, area.y / _fit.size.y), MIN_SCALE, MAX_SCALE)
		# личная карта не отдаляется дальше, чем видна вся стартовая область
		_min_scale = _scale if paper else MIN_SCALE
	_update_base()
	refresh_overlay()


func _update_base() -> void:
	_base_dirty = true


func _refresh_base() -> void:
	var frame := _world_rect()
	if _bounds.has_area():
		frame = frame.intersection(_bounds.grow(-0.01) if paper else _bounds.grow(160.0))
	# не больше 4 новых участков за кадр: при перетаскивании и масштабе карта не замирает на сборке картинок
	var changed := _data.update(frame, 4)
	_base.position = world_to_screen(Vector2.ZERO)
	_base.scale = Vector2.ONE * _scale
	if changed or _drawn_scale != _scale:
		_drawn_scale = _scale
		_base.queue_redraw()
	_base_dirty = false


func _world_rect() -> Rect2:
	return Rect2(_center - size * 0.5 / _scale, size / _scale)


func world_to_screen(at: Vector2) -> Vector2:
	return size * 0.5 + (at - _center) * _scale


func screen_to_world(at: Vector2) -> Vector2:
	return _center + (at - size * 0.5) / _scale


static func place_at(place: Dictionary) -> Vector2:
	return Vector2(place.x, place.y) * TILE


func _pick(at: Vector2) -> Dictionary:
	var radius := PICK * PICK
	var selected := {}
	for place: Dictionary in places:
		var d := world_to_screen(place_at(place)).distance_squared_to(at)
		if d < radius:
			radius = d
			selected = place
	return selected


func _set_hover(place: Dictionary) -> void:
	if place.get("key") != hover.get("key"):
		hover = place
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if not hover.is_empty() else (Control.CURSOR_ARROW if park else Control.CURSOR_DRAG)
		refresh_overlay()


func _gui_input(event: InputEvent) -> void:
	if _data == null:
		return
	if event is InputEventMouseMotion:
		_move_pointer(event.position)
	elif event is InputEventMouseButton:
		_map_button(event)


func _move_pointer(at: Vector2) -> void:
	if not park and _pressed.is_finite() and (_dragged or at.distance_to(_pressed) >= 5.0):
		_center = (_center - (at - _pressed) / _scale).clamp(_bounds.position, _bounds.end)
		_pressed = at
		_dragged = true
		_update_base()
		refresh_overlay()
	_set_hover(_pick(at) if not _dragged else {})


func _map_button(event: InputEventMouseButton) -> void:
	var button := event.button_index
	if not park and event.pressed and button in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		var factor := 1.25 if button == MOUSE_BUTTON_WHEEL_UP else 0.8
		_zoom_at(event.position, factor)
	elif button in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE]:
		if event.pressed and _button == MOUSE_BUTTON_NONE:
			_button = button
			_pressed = event.position
			_dragged = false
		elif not event.pressed and button == _button and _pressed.is_finite():
			if not _dragged:
				if button == MOUSE_BUTTON_MIDDLE and not park and player.is_finite():
					_center = player
					_update_base()
					refresh_overlay()
				elif button == MOUSE_BUTTON_LEFT:
					var place := _pick(event.position)
					if not place.is_empty():
						place_selected.emit(place)
					elif not park and event.ctrl_pressed:
						marker_requested.emit(screen_to_world(event.position) / TILE)
			_pressed = Vector2.INF
			_button = MOUSE_BUTTON_NONE
			_dragged = false
	accept_event()


func _zoom_at(at: Vector2, factor: float) -> void:
	var anchor := screen_to_world(at)
	_scale = clampf(_scale * factor, _min_scale, MAX_SCALE)
	_center = (_center + anchor - screen_to_world(at)).clamp(_bounds.position, _bounds.end)
	_update_base()
	refresh_overlay()


## Фон и засечки — в экранных координатах, сама подложка — слой _base
func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Paint.PARK_PAPER if _styled() else Data.EMPTY)


## Подложка в мировых метрах: положение и масштаб слоя задаёт _refresh_base
func _draw_base() -> void:
	if _data == null:
		return
	Paint.surface(_base, _data, Vector2.ZERO, 1.0, _styled(), _scale)
	if paper:
		# за краем стартовой области — чистая бумага: соседние земли на личной карте не показываются
		var plan := Rect2(Vector2.ZERO, Vector2(_data.world.W, _data.world.H) * TILE)
		var far := 4000.0
		for side: Rect2 in [Rect2(plan.position.x - far, plan.position.y - far, plan.size.x + far * 2.0, far),
				Rect2(plan.position.x - far, plan.end.y, plan.size.x + far * 2.0, far),
				Rect2(plan.position.x - far, plan.position.y, far, plan.size.y), Rect2(plan.end.x, plan.position.y, far, plan.size.y)]:
			_base.draw_rect(side, Paint.PARK_PAPER)


func _draw_fog() -> void:
	if paper and _fog_texture != null and _data != null:
		_fog_node.draw_texture_rect(_fog_texture, Rect2(Vector2.ZERO, Vector2(_fog.get_size()) * FOG_CELL), false)


func _park_grid() -> void:
	var color := Color(0.48, 0.39, 0.26, 0.16)
	for x in range(32, int(size.x), 48):
		_overlay.draw_line(Vector2(x, 0), Vector2(x, size.y), color)
	for y in range(24, int(size.y), 48):
		_overlay.draw_line(Vector2(0, y), Vector2(size.x, y), color)


## Маска исследованного (только личная карта): бумага поверх неоткрытого. Новые отрезки трека и места дописываются
## в маску по мере поступления, а не пересчитываются целиком
func _update_fog() -> void:
	if not paper or _data == null or journal == null:
		return
	var w := _data.world
	if _fog == null:
		var px := Vector2i(ceili(w.W * TILE / FOG_CELL), ceili(w.H * TILE / FOG_CELL))
		_fog = Image.create(px.x, px.y, false, Image.FORMAT_RGBA8)
		_fog.fill(Paint.PARK_PAPER)
		_fog_legs = 0
		_fog_last = Vector2.INF
	while _fog_legs < journal.legs.size():
		_open_track(journal.legs[_fog_legs].points)
		_fog_legs += 1
		_fog_last = Vector2.INF
	_open_track(journal.current)
	if player.is_finite():
		_open_fog(player, FOG_TRACK)
	_publish_fog()


func _open_track(points: PackedVector2Array) -> void:
	for point: Vector2 in points:
		if _fog_last.is_finite() and _fog_last.distance_squared_to(point) < FOG_STEP * FOG_STEP:
			continue
		_fog_last = point
		_open_fog(point, FOG_TRACK)


## Открыть круг radius м вокруг at (метры): три пересекающихся прямоугольника — почти круг, мягкий край даёт фильтрация
func _open_fog(at: Vector2, radius: float) -> void:
	if _fog == null:
		return
	var c := Vector2i((at / FOG_CELL).round())
	var r := int(radius / FOG_CELL)
	var clear := Color(Paint.PARK_PAPER, 0.0)
	var bounds := Rect2i(Vector2i.ZERO, _fog.get_size())
	_fog.fill_rect(Rect2i(c - Vector2i(r, r * 7 / 10), Vector2i(r * 2 + 1, r * 14 / 10 + 1)).intersection(bounds), clear)
	_fog.fill_rect(Rect2i(c - Vector2i(r * 7 / 10, r), Vector2i(r * 14 / 10 + 1, r * 2 + 1)).intersection(bounds), clear)
	_fog.fill_rect(Rect2i(c - Vector2i(r * 9 / 10, r * 9 / 10), Vector2i(r * 18 / 10 + 1, r * 18 / 10 + 1)).intersection(bounds), clear)


func _publish_fog() -> void:
	if _fog == null:
		return
	if _fog_texture == null or Vector2i(_fog_texture.get_size()) != _fog.get_size():
		_fog_texture = ImageTexture.create_from_image(_fog)
		(_fog_node.material as ShaderMaterial).set_shader_parameter("texel", Vector2.ONE / Vector2(_fog.get_size()))
	else:
		_fog_texture.update(_fog)
	_fog_node.queue_redraw()


func _draw_overlay() -> void:
	if _data == null:
		return
	if _styled():
		_park_grid() # засечки поверх бумаги и подложки, как сетка на печатной карте
	if journal != null:
		_draw_track()
	_draw_pins()
	if not park:
		if goal.is_finite():
			_overlay.draw_circle(world_to_screen(goal), 10.0, Color("#cc822c"), false, 2.5, true)
		if quest.is_finite():
			var at := world_to_screen(quest)
			_overlay.draw_rect(Rect2(at - Vector2.ONE * 6.0, Vector2.ONE * 12.0), Color("#244648"))
			_overlay.draw_rect(Rect2(at - Vector2.ONE * 4.0, Vector2.ONE * 8.0), quest_color)
		if player.is_finite():
			Paint.player(_overlay, world_to_screen(player), heading)
	_draw_legend()


func _draw_track() -> void:
	var bounds := _world_rect().grow(12.0 / _scale)
	_overlay.draw_set_transform(world_to_screen(Vector2.ZERO), 0.0, Vector2.ONE * _scale)
	for leg: Dictionary in journal.legs:
		if bounds.intersects(leg.bounds.grow(1.0)):
			_draw_leg(leg.points)
	if journal.current.size() > 1 and bounds.intersects(journal.current_bounds.grow(1.0)):
		_draw_leg(journal.current)
	_overlay.draw_set_transform(Vector2.ZERO)


func _draw_leg(points: PackedVector2Array) -> void:
	_overlay.draw_polyline(points, Color("#fffaff"), 5.5 / _scale, true)
	_overlay.draw_polyline(points, Paint.TRACE, 3.1 / _scale, true)


func _draw_pins() -> void:
	var labels: Array[Rect2] = []
	var font: Font = _park_font if _styled() else ThemeDB.fallback_font
	var fs := 16 if _styled() else 14
	for i in places.size():
		var place: Dictionary = places[i]
		var at := world_to_screen(place_at(place))
		if not Rect2(Vector2.ONE * 10.0, size - Vector2.ONE * 20.0).has_point(at):
			continue
		var focused: bool = place.key == hover.get("key")
		var here := park and i == 0
		var color := Color("#c14930") if here else (Color("#355b45") if _styled() else Color("#466768"))
		if focused:
			_overlay.draw_circle(at, 12, Color(color, 0.25), true, -1.0, true)
		_overlay.draw_circle(at, 8 if _styled() else 6, Color("#fff9e9"), true, -1.0, true)
		_overlay.draw_circle(at, 5.5 if _styled() else 3.5, color, true, -1.0, true)
		var title: String = "Вы здесь" if here else place.name
		var width := font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var x := clampf(at.x, width * 0.5 + 10.0, maxf(width * 0.5 + 10.0, size.x - width * 0.5 - 10.0))
		for offset: float in [-12.0, 25.0]:
			var label_at := Vector2(x, at.y + offset)
			var rect := Rect2(label_at - Vector2(width * 0.5, fs), Vector2(width, fs + 4)).grow(4.0)
			if rect.position.y < 0.0 or rect.end.y >= size.y or labels.any(func(other: Rect2) -> bool: return other.intersects(rect)):
				continue
			labels.append(rect)
			Paint.text(_overlay, label_at, title, Paint.PARK_INK if _styled() else Paint.INK, fs, font)
			break


func _draw_legend() -> void:
	var color := Paint.PARK_INK if _styled() else Paint.INK
	var north := Vector2(size.x - (26.0 if park else 87.0), 28.0)
	_overlay.draw_colored_polygon(PackedVector2Array([north + Vector2(0, -8), north + Vector2(5, 7),
		north + Vector2(0, 4), north + Vector2(-5, 7)]), color)
	Paint.text(_overlay, north + Vector2(0, 23), "С", color, 12)
	var metres := 50.0 if _scale > 0.9 else (100.0 if _scale > 0.4 else (250.0 if _scale > 0.18 else 500.0))
	var start := Vector2(18, size.y - 16)
	var end := start + Vector2(metres * _scale, 0)
	_overlay.draw_polyline(PackedVector2Array([start - Vector2(0, 5), start, end, end - Vector2(0, 5)]), color, 1.7, true)
	Paint.text(_overlay, (start + end) * 0.5 - Vector2(0, 8), "%d м" % metres, color, 12)
	if _styled():
		_overlay.draw_rect(Rect2(Vector2.ONE, size - Vector2.ONE * 2), Color("#aca17e"), false, 2.0)
	if not park and journal != null:
		var panel := Color("#f2e7cd") if paper else Color("#f5f8f3")
		_overlay.draw_rect(Rect2(16, 12, 210, 92), panel)
		if paper:
			_overlay.draw_rect(Rect2(16, 12, 210, 92), Color("#aca17e"), false, 1.5)
		var font: Font = _park_font if paper else null
		Paint.text(_overlay, Vector2(121, 39), "Карта поездок", color, 22, font)
		Paint.text(_overlay, Vector2(121, 63), "Трек · %s" % Util.distance_text(journal.distance), Paint.TRACE, 15, font)
		Paint.text(_overlay, Vector2(121, 85), "Открыто мест · %d" % places.size(), color, 14, font)
		Paint.text(_overlay, Vector2(size.x * 0.5, size.y - 19), move_hint, color, 13)
