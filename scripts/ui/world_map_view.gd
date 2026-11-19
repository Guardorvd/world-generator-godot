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
const UiIcons = preload("res://scripts/ui/ui_icons.gd")
const HudStyle = preload("res://scripts/ui/hud_style.gd")
const TILE := GameConfig.TILE
const PICK := 17.0
const MIN_SCALE := 0.06
const MAX_SCALE := 2.2
const STROKE_SETTLE_USEC := 120000
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
var quest_kind := ""
var move_hint := ""
var _data: Data
var _base: Control
var _tiles: Control
var _lines: Control
var _track: Control
var _track_window := Rect2()
var _player_arrow: Node2D
var _legend: Control
var _overlay: Control
var _center := Vector2.ZERO
var _scale := 0.2
var _min_scale := MIN_SCALE
var _drawn_scale := -1.0
var _stroke_scale := 0.2
var _stroke_redraw_at := 0
var _line_window := Rect2()
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
var _fog_current_points := 0
var _fog_current_leg := -1
var _fog_last := Vector2.INF
var _fog_player_cell := Vector2.INF
var _fog_pending := false
var _fog_dirty := false
var _fog_places := {}


func _ready() -> void:
	clip_contents = true
	mouse_default_cursor_shape = Control.CURSOR_ARROW if park else Control.CURSOR_DRAG
	_base = Control.new()
	_base.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_base)
	_tiles = Control.new()
	_tiles.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tiles.draw.connect(_draw_tiles)
	_base.add_child(_tiles)
	_lines = Control.new()
	_lines.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_lines.draw.connect(_draw_base)
	_base.add_child(_lines)
	_fog_node = Control.new()
	_fog_node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fog_material := ShaderMaterial.new()
	fog_material.shader = preload("res://resources/map_fog.gdshader")
	_fog_node.material = fog_material
	_fog_node.draw.connect(_draw_fog)
	_base.add_child(_fog_node)
	_track = Control.new()
	_track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_track.draw.connect(_draw_track)
	_base.add_child(_track)
	_overlay = Control.new()
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_overlay)
	_overlay.draw.connect(_draw_overlay)
	_player_arrow = Node2D.new()
	_player_arrow.hide()
	_player_arrow.draw.connect(func() -> void: Paint.player(_player_arrow, Vector2.ZERO, 0.0))
	add_child(_player_arrow)
	_legend = Control.new()
	_legend.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_legend.draw.connect(_draw_legend)
	add_child(_legend)
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
	quest_kind = ""
	_last_revision = -1
	_fog = null
	_fog_texture = null
	_fog_legs = 0
	_fog_last = Vector2.INF
	_fog_player_cell = Vector2.INF
	_fog_current_leg = -1
	_fog_current_points = 0
	_fog_pending = paper
	_fog_dirty = false
	_fog_places = {}
	if _base != null:
		_tiles.queue_redraw()
		_lines.queue_redraw()
		_fog_node.queue_redraw()
		_track.queue_redraw()
		_update_player_arrow()
	_drawn_scale = -1.0
	_stroke_redraw_at = 0
	_line_window = Rect2()
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
	_fog_pending = paper
	_reframe()


func set_places(pins: Array) -> void:
	if places == pins:
		return
	places = pins
	if paper:
		_fog_pending = true
	_set_hover({})
	refresh_overlay()


func set_player(at: Vector2, yaw: float) -> void:
	if player == at and heading == yaw:
		return
	player = at
	heading = yaw
	_update_player_arrow()
	if paper and (at / FOG_CELL).round() != _fog_player_cell:
		_fog_pending = true


func _update_player_arrow() -> void:
	if _player_arrow == null:
		return
	_player_arrow.visible = not park and player.is_finite()
	if _player_arrow.visible:
		_player_arrow.position = world_to_screen(player)
		_player_arrow.rotation = -heading


func refresh_overlay() -> void:
	if _overlay != null and is_visible_in_tree():
		_overlay.queue_redraw()
		_legend.queue_redraw()


func _visibility_changed() -> void:
	set_process(is_visible_in_tree())
	if is_visible_in_tree():
		_update_base()
		refresh_overlay()
	elif _data != null:
		_data.release_view()
		_line_window = Rect2()
		_stroke_redraw_at = 0
		_drawn_scale = -1.0
		_pressed = Vector2.INF
		_button = MOUSE_BUTTON_NONE
		_dragged = false


func _process(_delta: float) -> void:
	if _data != null and (_base_dirty or _data.pending):
		_refresh_base()
	if _stroke_redraw_at != 0 and Time.get_ticks_usec() >= _stroke_redraw_at:
		_stroke_redraw_at = 0
		_stroke_scale = _scale
		_lines.queue_redraw()
		_track.queue_redraw()
	if journal != null and journal.revision != _last_revision:
		_last_revision = journal.revision
		_track.queue_redraw()
		_fog_pending = paper
		refresh_overlay()
	if _fog_pending:
		_update_fog()


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
	var lines_changed := false
	var baked_atlas := paper and _data.atlas_texture != null
	if baked_atlas:
		if not _line_window.has_area() or not _line_window.encloses(frame):
			_line_window = frame.grow(Data.SPAN * 0.5)
			lines_changed = _data.update_atlas_lines(_line_window.intersection(_bounds))
		if _drawn_scale < 0.0:
			_tiles.queue_redraw()
	else:
		var tile_revision := _data.tile_revision
		var feature_revision := _data.feature_revision
		_data.update(frame, 1, not paper)
		if _data.tile_revision != tile_revision or _drawn_scale < 0.0:
			_tiles.queue_redraw()
		lines_changed = _data.feature_revision != feature_revision
	_base.position = world_to_screen(Vector2.ZERO)
	_base.scale = Vector2.ONE * _scale
	if _drawn_scale < 0.0 or (park and _drawn_scale != _scale):
		_stroke_scale = _scale
		_lines.queue_redraw()
	elif _drawn_scale != _scale:
		# Keep the drawn strokes while the wheel is active and update widths when it settles.
		_stroke_redraw_at = Time.get_ticks_usec() + STROKE_SETTLE_USEC
	if lines_changed:
		_lines.queue_redraw()
	var track_frame := _world_rect().grow(12.0 / _scale)
	if journal != null and (_drawn_scale < 0.0 or not _track_window.encloses(track_frame)):
		_track_window = track_frame.grow(Data.SPAN * 0.5)
		_track.queue_redraw()
	_drawn_scale = _scale
	_update_player_arrow()
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
	var next_scale := clampf(_scale * factor, _min_scale, MAX_SCALE)
	if is_equal_approx(_scale, next_scale):
		return
	_scale = next_scale
	_center = (_center + anchor - screen_to_world(at)).clamp(_bounds.position, _bounds.end)
	_update_base()
	refresh_overlay()


## Фон и засечки — в экранных координатах, сама подложка — слой _base
func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Paint.PARK_PAPER if _styled() else Data.EMPTY)


## Подложка в мировых метрах: положение и масштаб слоя задаёт _refresh_base
func _draw_tiles() -> void:
	if _data == null:
		return
	if paper and _data.atlas_texture != null:
		_tiles.draw_texture_rect(_data.atlas_texture, _bounds, false, Color("#f3e5c5"))
	else:
		Paint.tiles(_tiles, _data, _styled())


func _draw_base() -> void:
	if _data == null:
		return
	Paint.lines(_lines, _data, _stroke_scale, _styled())
	if paper:
		# за краем стартовой области — чистая бумага: соседние земли на личной карте не показываются
		var plan := Rect2(Vector2.ZERO, Vector2(_data.world.W, _data.world.H) * TILE)
		var far := 4000.0
		for side: Rect2 in [Rect2(plan.position.x - far, plan.position.y - far, plan.size.x + far * 2.0, far),
				Rect2(plan.position.x - far, plan.end.y, plan.size.x + far * 2.0, far),
				Rect2(plan.position.x - far, plan.position.y, far, plan.size.y), Rect2(plan.end.x, plan.position.y, far, plan.size.y)]:
			_lines.draw_rect(side, Paint.PARK_PAPER)


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
	_fog_pending = false
	if not paper or _data == null or journal == null:
		return
	if _fog == null:
		var w := _data.world
		var px := Vector2i(ceili(w.W * TILE / FOG_CELL), ceili(w.H * TILE / FOG_CELL))
		_fog = Image.create(px.x, px.y, false, Image.FORMAT_RGBA8)
		_fog.fill(Paint.PARK_PAPER)
		_fog_dirty = true
	var completed := journal.completed_legs
	var first := completed - journal.legs.size()
	_fog_legs = maxi(_fog_legs, first)
	# A restored journal may contain thousands of points. Reveal it over several frames.
	var finish := mini(completed, _fog_legs + 4)
	while _fog_legs < finish:
		var points: PackedVector2Array = journal.legs[_fog_legs - first].points
		_open_track(points, 0, points.size(), Vector2.INF)
		_fog_legs += 1
	_fog_pending = _fog_legs < completed

	if completed != _fog_current_leg or _fog_current_points >= journal.current.size():
		_fog_current_leg = completed
		_fog_current_points = 0
		_fog_last = Vector2.INF
	# The final point of the live leg can still be moved by track simplification.
	var stable := maxi(0, journal.current.size() - 1)
	_fog_last = _open_track(journal.current, _fog_current_points, stable, _fog_last)
	_fog_current_points = stable
	if player.is_finite():
		var cell := (player / FOG_CELL).round()
		if cell != _fog_player_cell:
			_fog_player_cell = cell
			_open_fog(player, FOG_TRACK)
	for place: Dictionary in places:
		if not _fog_places.has(place.key):
			_fog_places[place.key] = true
			_open_fog(place_at(place), FOG_PLACE)
	if _fog_dirty:
		_publish_fog()
		_fog_dirty = false


func _open_track(points: PackedVector2Array, from: int, to: int, previous: Vector2) -> Vector2:
	for i in range(from, to):
		var point := points[i]
		if previous.is_finite() and previous.distance_squared_to(point) < FOG_STEP * FOG_STEP:
			continue
		previous = point
		_open_fog(point, FOG_TRACK)
	return previous


## Открыть круг radius м вокруг at (метры): три пересекающихся прямоугольника — почти круг, мягкий край даёт фильтрация
func _open_fog(at: Vector2, radius: float) -> void:
	if _fog == null:
		return
	var c := Vector2i((at / FOG_CELL).round())
	var r := int(radius / FOG_CELL)
	var clear := Color(Paint.PARK_PAPER, 0.0)
	var bounds := Rect2i(Vector2i.ZERO, _fog.get_size())
	if not bounds.grow(r).has_point(c):
		return
	_fog_dirty = true
	_fog.fill_rect(Rect2i(c - Vector2i(r, r * 7 / 10), Vector2i(r * 2 + 1, r * 14 / 10 + 1)).intersection(bounds), clear)
	_fog.fill_rect(Rect2i(c - Vector2i(r * 7 / 10, r), Vector2i(r * 14 / 10 + 1, r * 2 + 1)).intersection(bounds), clear)
	_fog.fill_rect(Rect2i(c - Vector2i(r * 9 / 10, r * 9 / 10), Vector2i(r * 18 / 10 + 1, r * 18 / 10 + 1)).intersection(bounds), clear)


func _publish_fog() -> void:
	if _fog == null:
		return
	if _fog_texture == null or Vector2i(_fog_texture.get_size()) != _fog.get_size():
		_fog_texture = ImageTexture.create_from_image(_fog)
		(_fog_node.material as ShaderMaterial).set_shader_parameter("texel", Vector2.ONE / Vector2(_fog.get_size()))
		_fog_node.queue_redraw()
	else:
		_fog_texture.update(_fog)


func _draw_overlay() -> void:
	if _data == null:
		return
	if _styled():
		_park_grid() # засечки поверх бумаги и подложки, как сетка на печатной карте
	_draw_pins()
	if not park:
		if goal.is_finite():
			var at := world_to_screen(goal)
			_overlay.draw_circle(at, 11.5, Color("#fff9e9"), true, -1.0, true)
			_overlay.draw_circle(at, 9.5, HudStyle.SURFACE, true, -1.0, true)
			_overlay.draw_arc(at, 9.5, 0.0, TAU, 24, Color("#cc822c"), 2.0, true)
			_overlay.draw_texture_rect(UiIcons.map_icon("goal"), Rect2(at - Vector2.ONE * 6.5, Vector2.ONE * 13.0), false, HudStyle.AMBER)
		if quest.is_finite():
			var at := world_to_screen(quest)
			_overlay.draw_circle(at, 11.5, Color("#fff9e9"), true, -1.0, true)
			_overlay.draw_circle(at, 9.5, HudStyle.SURFACE, true, -1.0, true)
			_overlay.draw_arc(at, 9.5, 0.0, TAU, 24, quest_color, 2.0, true)
			_overlay.draw_texture_rect(UiIcons.quest_small(quest_kind), Rect2(at - Vector2.ONE * 6.5, Vector2.ONE * 13.0), false, quest_color)


func _draw_track() -> void:
	if _data == null or journal == null:
		return
	for leg: Dictionary in journal.legs:
		if _track_window.intersects(leg.bounds.grow(1.0)):
			_draw_leg(leg.points)
	if journal.current.size() > 1 and _track_window.intersects(journal.current_bounds.grow(1.0)):
		_draw_leg(journal.current)


func _draw_leg(points: PackedVector2Array) -> void:
	_track.draw_polyline(points, Color("#fffaff"), 5.5 / _stroke_scale, true)
	_track.draw_polyline(points, Paint.TRACE, 3.1 / _stroke_scale, true)


static func _pin_color(kind: String) -> Color:
	match kind:
		"peak": return Color("#866038")
		"lake": return Color("#2f6d8c")
		"site": return Color("#316760")
		_: return Color("#5f507a")


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
		var kind := str(place.get("kind", "settlement"))
		var color := Color("#c14930") if here else _pin_color(kind)
		var halo := 10.0 if _styled() else 8.5
		var radius := 8.2 if _styled() else 6.8
		var icon_size := 12.0 if _styled() else 10.0
		if focused:
			_overlay.draw_circle(at, halo + 4.5, Color(color, 0.28), true, -1.0, true)
		_overlay.draw_circle(at, halo, Color("#fff9e9"), true, -1.0, true)
		_overlay.draw_circle(at, radius, color, true, -1.0, true)
		_overlay.draw_texture_rect(UiIcons.map_icon(kind), Rect2(at - Vector2.ONE * icon_size * 0.5, Vector2.ONE * icon_size), false, Color.WHITE)
		var title: String = "Вы здесь" if here else place.name
		var width := font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var x := clampf(at.x, width * 0.5 + 10.0, maxf(width * 0.5 + 10.0, size.x - width * 0.5 - 10.0))
		for offset: float in [-15.0, 27.0]:
			var label_at := Vector2(x, at.y + offset)
			var rect := Rect2(label_at - Vector2(width * 0.5, fs), Vector2(width, fs + 4)).grow(4.0)
			if rect.position.y < 0.0 or rect.end.y >= size.y or labels.any(func(other: Rect2) -> bool: return other.intersects(rect)):
				continue
			labels.append(rect)
			Paint.text(_overlay, label_at, title, Paint.PARK_INK if _styled() else Paint.INK, fs, font)
			break


func _draw_legend() -> void:
	if _data == null:
		return
	var color := Paint.PARK_INK if _styled() else Paint.INK
	var north := Vector2(size.x - (26.0 if park else 87.0), 28.0)
	_legend.draw_colored_polygon(PackedVector2Array([north + Vector2(0, -8), north + Vector2(5, 7),
		north + Vector2(0, 4), north + Vector2(-5, 7)]), color)
	Paint.text(_legend, north + Vector2(0, 23), "С", color, 12)
	var metres := 50.0 if _scale > 0.9 else (100.0 if _scale > 0.4 else (250.0 if _scale > 0.18 else 500.0))
	var start := Vector2(18, size.y - 16)
	var end := start + Vector2(metres * _scale, 0)
	_legend.draw_polyline(PackedVector2Array([start - Vector2(0, 5), start, end, end - Vector2(0, 5)]), color, 1.7, true)
	Paint.text(_legend, (start + end) * 0.5 - Vector2(0, 8), "%d м" % metres, color, 12)
	if _styled():
		_legend.draw_rect(Rect2(Vector2.ONE, size - Vector2.ONE * 2), Color("#aca17e"), false, 2.0)
	if not park and journal != null:
		var panel := Color("#f2e7cd") if paper else Color("#f5f8f3")
		_legend.draw_rect(Rect2(16, 12, 210, 92), panel)
		if paper:
			_legend.draw_rect(Rect2(16, 12, 210, 92), Color("#aca17e"), false, 1.5)
		var font: Font = _park_font if paper else null
		Paint.text(_legend, Vector2(121, 39), "Карта поездок", color, 22, font)
		Paint.text(_legend, Vector2(121, 63), "Трек · %s" % Util.distance_text(journal.distance), Paint.TRACE, 15, font)
		Paint.text(_legend, Vector2(121, 85), "Открыто мест · %d" % places.size(), color, 14, font)
		Paint.text(_legend, Vector2(size.x * 0.5, size.y - 19), move_hint, color, 13)
