extends Control
## Карта с двумя слоями: подложка перерисовывается при сдвиге, масштабе или
## поступлении участков. Положение игрока и трек обновляют только верхний слой.

signal place_selected(place: Dictionary)
signal marker_requested(at: Vector2)

const Data = preload("res://scripts/ui/local_map_data.gd")
const Paint = preload("res://scripts/ui/map_paint.gd")
const Journal = preload("res://scripts/game/map_journal.gd")
const TILE := GameConfig.TILE
const PICK := 17.0
const MIN_SCALE := 0.06
const MAX_SCALE := 2.2

var park := false
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
var _overlay: Control
var _center := Vector2.ZERO
var _scale := 0.2
var _bounds := Rect2()
var _fit := Rect2()
var _pressed := Vector2.INF
var _button := MOUSE_BUTTON_NONE
var _dragged := false
var _base_dirty := false
var _last_revision := -1
var _park_font: SystemFont


func _ready() -> void:
	clip_contents = true
	mouse_default_cursor_shape = Control.CURSOR_ARROW if park else Control.CURSOR_DRAG
	_overlay = Control.new()
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_overlay)
	_overlay.draw.connect(_draw_overlay)
	mouse_exited.connect(func() -> void: _set_hover({}))
	resized.connect(_reframe)
	visibility_changed.connect(_visibility_changed)
	if park:
		_park_font = SystemFont.new()
		_park_font.font_names = ["Georgia", "Noto Serif", "DejaVu Serif"]
	_visibility_changed()


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
	# Дальние открытые области влияют на границы перетаскивания, а не на начальный масштаб.
	var w := _data.world
	_bounds = Rect2(Vector2.ZERO, Vector2(w.W, w.H) * TILE)
	if w.outer != null:
		for entry: Dictionary in w.outer.get_ledger().get("regions", {}).values():
			var cells: Rect2i = entry.rect
			_bounds = _bounds.merge(Rect2(Vector2(cells.position) * TILE, Vector2(cells.size) * TILE))
	_update_base()
	refresh_overlay()


func set_places(pins: Array) -> void:
	places = pins
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
		_pressed = Vector2.INF
		_button = MOUSE_BUTTON_NONE
		_dragged = false


func _process(_delta: float) -> void:
	if _data != null and (_base_dirty or _data.pending):
		_refresh_base()
	if journal != null and journal.revision != _last_revision:
		_last_revision = journal.revision
		refresh_overlay()


func _reframe() -> void:
	if _fit.has_area() and size.x > 1.0 and size.y > 1.0:
		_center = _fit.get_center()
		var inset := Vector2(92, 96) if park else Vector2(42, 80)
		var area := (size - inset).max(Vector2.ONE)
		_scale = clampf(minf(area.x / _fit.size.x, area.y / _fit.size.y), MIN_SCALE, MAX_SCALE)
	_update_base()
	refresh_overlay()


func _update_base() -> void:
	_base_dirty = true


func _refresh_base() -> void:
	var frame := _world_rect()
	if _bounds.has_area():
		frame = frame.intersection(_bounds.grow(160.0))
	if _data.update(frame, 10) or _base_dirty:
		queue_redraw()
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
	_scale = clampf(_scale * factor, MIN_SCALE, MAX_SCALE)
	_center = (_center + anchor - screen_to_world(at)).clamp(_bounds.position, _bounds.end)
	_update_base()
	refresh_overlay()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Paint.PARK_PAPER if park else Data.EMPTY)
	if _data != null:
		if park:
			_park_grid()
		Paint.surface(self, _data, world_to_screen(Vector2.ZERO), _scale, park)


func _park_grid() -> void:
	var color := Color(0.48, 0.39, 0.26, 0.16)
	for x in range(32, int(size.x), 48):
		draw_line(Vector2(x, 0), Vector2(x, size.y), color)
	for y in range(24, int(size.y), 48):
		draw_line(Vector2(0, y), Vector2(size.x, y), color)


func _draw_overlay() -> void:
	if _data == null:
		return
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
	var font: Font = _park_font if park else ThemeDB.fallback_font
	var fs := 16 if park else 14
	for i in places.size():
		var place: Dictionary = places[i]
		var at := world_to_screen(place_at(place))
		if not Rect2(Vector2.ONE * 10.0, size - Vector2.ONE * 20.0).has_point(at):
			continue
		var focused: bool = place.key == hover.get("key")
		var here := park and i == 0
		var color := Color("#c14930") if here else (Color("#355b45") if park else Color("#466768"))
		if focused:
			_overlay.draw_circle(at, 12, Color(color, 0.25), true, -1.0, true)
		_overlay.draw_circle(at, 8 if park else 6, Color("#fff9e9"), true, -1.0, true)
		_overlay.draw_circle(at, 5.5 if park else 3.5, color, true, -1.0, true)
		var title: String = "Вы здесь" if here else place.name
		var width := font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var x := clampf(at.x, width * 0.5 + 10.0, maxf(width * 0.5 + 10.0, size.x - width * 0.5 - 10.0))
		for offset: float in [-12.0, 25.0]:
			var label_at := Vector2(x, at.y + offset)
			var rect := Rect2(label_at - Vector2(width * 0.5, fs), Vector2(width, fs + 4)).grow(4.0)
			if rect.position.y < 0.0 or rect.end.y >= size.y or labels.any(func(other: Rect2) -> bool: return other.intersects(rect)):
				continue
			labels.append(rect)
			Paint.text(_overlay, label_at, title, Paint.PARK_INK if park else Paint.INK, fs, font)
			break


func _draw_legend() -> void:
	var color := Paint.PARK_INK if park else Paint.INK
	var north := Vector2(size.x - (26.0 if park else 87.0), 28.0)
	_overlay.draw_colored_polygon(PackedVector2Array([north + Vector2(0, -8), north + Vector2(5, 7),
		north + Vector2(0, 4), north + Vector2(-5, 7)]), color)
	Paint.text(_overlay, north + Vector2(0, 23), "С", color, 12)
	var metres := 50.0 if _scale > 0.9 else (100.0 if _scale > 0.4 else (250.0 if _scale > 0.18 else 500.0))
	var start := Vector2(18, size.y - 16)
	var end := start + Vector2(metres * _scale, 0)
	_overlay.draw_polyline(PackedVector2Array([start - Vector2(0, 5), start, end, end - Vector2(0, 5)]), color, 1.7, true)
	Paint.text(_overlay, (start + end) * 0.5 - Vector2(0, 8), "%d м" % metres, color, 12)
	if park:
		_overlay.draw_rect(Rect2(Vector2.ONE, size - Vector2.ONE * 2), Color("#aca17e"), false, 2.0)
	elif journal != null:
		_overlay.draw_rect(Rect2(16, 12, 210, 92), Color("#f5f8f3"))
		Paint.text(_overlay, Vector2(121, 39), "Карта поездок", Paint.INK, 22)
		Paint.text(_overlay, Vector2(121, 63), "Трек · %s" % Util.distance_text(journal.distance), Paint.TRACE, 15)
		Paint.text(_overlay, Vector2(121, 85), "Открыто мест · %d" % places.size(), Paint.INK, 14)
		Paint.text(_overlay, Vector2(size.x * 0.5, size.y - 19), move_hint, Paint.INK, 13)
