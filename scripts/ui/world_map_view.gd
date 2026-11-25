extends Control
## Карта с двумя слоями: подложка перерисовывается при сдвиге, масштабе или
## поступлении участков. Положение игрока и трек обновляют только верхний слой.
##
## 18.11.2026: подложка — отдельный слой _base в мировых метрах; сдвиг и масштаб меняют только его положение и масштаб,
## без перезаписи команд отрисовки. Раньше каждое движение мыши при перетаскивании заново записывало все участки
## и все линии дорог со сглаживанием — карта тормозила. Перезапись — когда пришли участки или сменился масштаб
## (толщина линий). paper — стиль карты нацпарка (бумага, тёплые цвета, засечки) для личной карты, park — доска
## поселения (тот же стиль, без перетаскивания). Личная карта показывает всю стартовую область (туман _fog выключен
## FOG_OF_WAR с 20.11.2026), места — только открытые; отдаление — не дальше стартовой области.

signal place_selected(place: Dictionary)
signal marker_requested(at: Vector2)
signal hover_changed(place: Dictionary)
signal places_changed
signal photo_thumbnail_requested(path: String)

const Data = preload("res://scripts/ui/local_map_data.gd")
const Paint = preload("res://scripts/ui/map_paint.gd")
const Journal = preload("res://scripts/game/map_journal.gd")
const UiIcons = preload("res://scripts/ui/ui_icons.gd")
const HudStyle = preload("res://scripts/ui/hud_style.gd")
const ATLAS_STROKE := preload("res://resources/atlas_stroke.gdshader")
const ATLAS_RELIEF := preload("res://resources/atlas_relief.gdshader")
const TILE := GameConfig.TILE
const PICK := 17.0
const MIN_SCALE := 0.06
const MAX_SCALE := 2.2
const STROKE_SETTLE_USEC := 120000
const PAD_DEADZONE := 0.2
const PAD_PAN := 620.0      # пикс/с при полном отклонении стика
const PAD_ZOOM := 2.6       # во сколько раз за секунду меняется масштаб при полном отклонении
const FOG_CELL := 16.0     # м на пиксель маски исследованного
const FOG_TRACK := 260.0   # м открыто вокруг пройденного пути
const FOG_PLACE := 160.0   # м открыто вокруг открытого места
const FOG_STEP := 60.0     # м между отметками трека в маске
## 20.11.2026: личная карта показывает всю стартовую область с рельефом и дорогами (просьба пользователя); места
## (поселения, вершины, сооружения) по-прежнему появляются, только когда открыты. Туман неисследованного выключен
const FOG_OF_WAR := false
const RIDE_INK := Color("#d0582c")  # трек выбранного заезда

var park := false
var paper := false
var tablet := false
## Только вкладка личной карты; доска и карта поездок сохраняют прежнее поведение.
var field_sheet := false
enum Status { VISITED = 1, REVEALED = 2, PHOTO = 4, QUEST = 8 }
var selected_place := {}
var _show_photos := false
var show_travel_track := true
var ride_fall_marks: Array = []
var _photo_cache := {}
var journal: Journal
var ride_legs: Array = []    # 20.11.2026: трек выбранного заезда (вкладка «Заезды»): он ярче, остальной путь бледнее
var _ride_frame := Rect2()
var hover := {}
var places: Array = []
var player := Vector2.INF
var bike := Vector2.INF
var heading := 0.0
var goal := Vector2.INF
var quest := Vector2.INF
var quest_color := Color.WHITE
var quest_kind := ""
var move_hint := ""
## 19.11.2026: управление личной картой без мыши (геймпад, клавиатура). Ставит Hud; null — только мышь (доска)
var controls: Controls
var input_blocked := Callable()  # true — поверх карты вопрос (перемещение), стики заняты им
var _pad_cross := false          # прицел в центре нарисован (геймпад): метка и выбор места — по нему
var _data: Data
var _base: Control
## 20.11.2026: слои в мировых метрах — Node2D, а не Control. Control отсекается движком по своему прямоугольнику
## (размер 0 в начале координат): стоило углу области уйти за край экрана при перетаскивании или приближении —
## подложка и трек пропадали, оставались бумага и дороги (сетки дорог — Node2D, их это не касалось)
var _tiles: Node2D
var _lines: Node2D
var _atlas_clip: Control
var _atlas_layers: Array[MeshInstance2D] = []
var _track: Node2D
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
var _bounds := Rect2()
var _fit := Rect2()
var _non_field_view := {}
var _pressed := Vector2.INF
var _button := MOUSE_BUTTON_NONE
var _dragged := false
var _base_dirty := false
var _last_revision := -1
var _park_font: SystemFont
static var _serif: SystemFont
var _fog: Image
var _fog_texture: ImageTexture
var _fog_node: Node2D       # слой бумаги в _base: свой шейдер размывает край маски
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
	_tiles = Node2D.new()
	_tiles.draw.connect(_draw_tiles)
	_base.add_child(_tiles)
	_lines = Node2D.new()
	_lines.draw.connect(_draw_base)
	_base.add_child(_lines)
	_atlas_clip = Control.new()
	_atlas_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_atlas_clip.clip_contents = true
	_lines.add_child(_atlas_clip)
	_configure_atlas_strokes()
	_fog_node = Node2D.new()
	var fog_material := ShaderMaterial.new()
	fog_material.shader = preload("res://resources/map_fog.gdshader")
	_fog_node.material = fog_material
	_fog_node.draw.connect(_draw_fog)
	_base.add_child(_fog_node)
	_track = Node2D.new()
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
		if _serif == null:
			_serif = SystemFont.new()
			_serif.font_names = ["Georgia", "Noto Serif", "DejaVu Serif"]
		_park_font = _serif # один шрифт на все карты: у новой карты доски глифы не растрируются заново
	_visibility_changed()


## Бумажный стиль: доска поселения или личная карта
func _styled() -> bool:
	return park or paper


## 20.11.2026: подложка из готового атласа стартовой области (текстура, рельеф шейдером, линии сетками) — у личной
## карты и у карты доски. Раньше доска собирала участки подложки скриптом по клетке (64×64 с рельефом) и рисовала
## все линии заново — у первой доски кадр стоял до 0,35 с.
func _baked() -> bool:
	return _styled() and _data != null and _data.atlas_texture != null


func set_source(source: Data) -> void:
	_data = Data.new(source.world, source) if source != null else null
	_non_field_view.clear()
	if _data != null:
		_data.park = park
		_data.paper_tiles = paper
	hover = {}
	selected_place = {}
	places = []
	places_changed.emit()
	player = Vector2.INF
	bike = Vector2.INF
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
		_configure_atlas_strokes()
		_configure_relief()
		_tiles.queue_redraw()
		_lines.queue_redraw()
		_fog_node.queue_redraw()
		_track.queue_redraw()
		_update_player_arrow()
	_drawn_scale = -1.0
	_stroke_redraw_at = 0
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
	if not selected_place.is_empty():
		var id: String = selected_place.key
		selected_place = {}
		for place: Dictionary in pins:
			if place.key == id:
				selected_place = place
				break
	if paper:
		_fog_pending = true
	_set_hover({})
	refresh_overlay()
	places_changed.emit()


func set_photo_pins(on: bool, cache: Dictionary) -> void:
	_show_photos = on
	_photo_cache = cache
	refresh_overlay()


func set_travel_track(on: bool) -> void:
	show_travel_track = on
	if _track != null:
		_track.queue_redraw()


func set_player(at: Vector2, yaw: float) -> void:
	if player == at and heading == yaw:
		return
	player = at
	heading = yaw
	_update_player_arrow()
	if paper and (at / FOG_CELL).round() != _fog_player_cell:
		_fog_pending = true


func set_bike(at: Vector2) -> void:
	if bike != at:
		bike = at
		refresh_overlay()


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
		_stroke_redraw_at = 0
		_drawn_scale = -1.0
		_pressed = Vector2.INF
		_button = MOUSE_BUTTON_NONE
		_dragged = false


func _process(delta: float) -> void:
	_pad_navigate(delta)
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
		var inset := Vector2(24, 24) if field_sheet else (Vector2(92, 96) if park else Vector2(42, 80))
		var area := (size - inset).max(Vector2.ONE)
		var fit_scale := minf(area.x / _fit.size.x, area.y / _fit.size.y)
		var cfg := WorldTemplate.config(_data.world.template_id if _data != null and _data.world != null else WorldTemplate.DEFAULT_ID)
		var elongated := not park and _bounds.has_area() and _bounds.size.y > _bounds.size.x * cfg.map_elongated_ratio
		if elongated:
			# Для длинной долины стартовый масштаб показывает ближайший участок маршрута вокруг игрока,
			# а не тонкую нитку целиком; отдалить до всей долины при этом можно колесом.
			_min_scale = clampf(fit_scale, 0.001, MIN_SCALE)
			var corridor_span := maxf(cfg.map_corridor_min_m, minf(_bounds.size.x * cfg.map_corridor_width_mul, _bounds.size.y * 0.45))
			_scale = clampf(minf(area.x / (_bounds.size.x * 1.35), area.y / corridor_span), _min_scale, MAX_SCALE)
			var focus := player if player.is_finite() else Vector2(_bounds.get_center().x, _bounds.position.y + corridor_span * 0.45)
			_center = _bounded_center(focus)
		else:
			_scale = clampf(fit_scale, 0.001 if field_sheet else MIN_SCALE, MAX_SCALE)
			# личная карта не отдаляется дальше, чем видна вся стартовая область
			_min_scale = _scale if paper else MIN_SCALE
	if not ride_legs.is_empty():
		_frame_ride()
		return
	_update_base()
	refresh_overlay()


## Центр не позволяет увести лист за край; если лист меньше окна, он остаётся по центру.
func _bounded_center(candidate: Vector2) -> Vector2:
	if not field_sheet or not _bounds.has_area():
		return candidate.clamp(_bounds.position, _bounds.end)
	var half := size * 0.5 / maxf(_scale, 0.0001)
	var low := _bounds.position + half
	var high := _bounds.end - half
	return Vector2(clampf(candidate.x, low.x, high.x) if low.x <= high.x else _bounds.get_center().x,
		clampf(candidate.y, low.y, high.y) if low.y <= high.y else _bounds.get_center().y)


func set_field_sheet(enabled: bool) -> void:
	if field_sheet == enabled:
		return
	if enabled:
		_non_field_view = {center = _center, scale = _scale, min_scale = _min_scale}
	field_sheet = enabled
	if _lines != null:
		_lines.queue_redraw()
	queue_redraw()
	if enabled:
		_reframe()
	else:
		if not _non_field_view.is_empty():
			_center = _non_field_view.center
			_scale = _non_field_view.scale
			_min_scale = _non_field_view.min_scale
			_non_field_view.clear()
		_update_base()
		refresh_overlay()


func _update_base() -> void:
	_base_dirty = true


func _refresh_base() -> void:
	var frame := _world_rect()
	if _bounds.has_area():
		frame = frame.intersection(_bounds.grow(-0.01) if paper else _bounds.grow(160.0))
	var lines_changed := false
	if _baked():
		if _drawn_scale != _scale:
			_update_atlas_width()
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


func _configure_atlas_strokes() -> void:
	var ready := _baked()
	_atlas_clip.visible = ready
	if not ready:
		for layer in _atlas_layers:
			layer.mesh = null
		return
	_atlas_clip.size = Vector2(_data.world.W, _data.world.H) * TILE
	for kind in Paint.PAPER_STROKES.size():
		for pass_index in 2:
			var index := kind * 2 + pass_index
			if index == _atlas_layers.size():
				var layer := MeshInstance2D.new()
				var ink := ShaderMaterial.new()
				ink.shader = ATLAS_STROKE
				ink.set_shader_parameter("ink", Paint.PAPER_STROKES[kind][pass_index])
				layer.material = ink
				_atlas_clip.add_child(layer)
				_atlas_layers.append(layer)
			_atlas_layers[index].mesh = _data.atlas_strokes[kind]


func _configure_relief() -> void:
	_tiles.material = null
	if not _styled() or _data == null or _data.atlas_relief.is_empty():
		return
	var relief := ShaderMaterial.new()
	relief.shader = ATLAS_RELIEF
	relief.set_shader_parameter("heights", _data.atlas_relief[0])
	relief.set_shader_parameter("biomes", _data.atlas_relief[1])
	relief.set_shader_parameter("lakes", _data.atlas_relief[2])
	relief.set_shader_parameter("height_scale", GameConfig.HS)
	relief.set_shader_parameter("beach_index", float(Biomes.BEACH))
	_tiles.material = relief


func _update_atlas_width() -> void:
	var width := Paint.stroke_scale(_scale)
	for index in _atlas_layers.size():
		var ink := _atlas_layers[index].material as ShaderMaterial
		ink.set_shader_parameter("half_width", Paint.PAPER_STROKES[index / 2][2 + index % 2] * width * 0.5)
		ink.set_shader_parameter("fringe", 0.65 / _scale)


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
		hover_changed.emit(hover)


func _select_place(place: Dictionary) -> void:
	if tablet:
		selected_place = place
		hover_changed.emit(place)
		refresh_overlay()
	place_selected.emit(place)


func _gui_input(event: InputEvent) -> void:
	if _data == null:
		return
	if event is InputEventMouseMotion:
		_move_pointer(event.position)
	elif event is InputEventMouseButton:
		_map_button(event)


func _move_pointer(at: Vector2) -> void:
	if not park and _pressed.is_finite() and (_dragged or at.distance_to(_pressed) >= 5.0):
		var next_center := _bounded_center(_center - (at - _pressed) / _scale)
		_pressed = at
		_dragged = true
		if not next_center.is_equal_approx(_center):
			_center = next_center
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
					center_on_player()
				elif button == MOUSE_BUTTON_LEFT:
					var place := _pick(event.position)
					if not place.is_empty():
						_select_place(place)
					elif not park and event.ctrl_pressed:
						var marker := screen_to_world(event.position)
						if not field_sheet or _bounds.has_point(marker):
							marker_requested.emit(marker / TILE)
			_pressed = Vector2.INF
			_button = MOUSE_BUTTON_NONE
			_dragged = false
	accept_event()


## Левый стик / WASD / стрелки — обзор, правый стик по вертикали — масштаб к центру экрана.
## Курок газа (тоже «вперёд» в действиях) намеренно не двигает карту: с ним её открывают на ходу.
func _pad_navigate(delta: float) -> void:
	var cross := controls != null and controls.joypad and not park
	var device_changed := cross != _pad_cross
	if device_changed:
		_pad_cross = cross
		_legend.queue_redraw()
	if controls == null or park or _data == null or (input_blocked.is_valid() and input_blocked.call()):
		return
	var pan := Vector2.ZERO
	var zoom := 0.0
	for pad in Input.get_connected_joypads():
		var stick := Vector2(Input.get_joy_axis(pad, JOY_AXIS_LEFT_X), Input.get_joy_axis(pad, JOY_AXIS_LEFT_Y))
		if stick.length() > PAD_DEADZONE:
			pan += stick * inverse_lerp(PAD_DEADZONE, 1.0, minf(stick.length(), 1.0)) / stick.length()
		var right := -Input.get_joy_axis(pad, JOY_AXIS_RIGHT_Y)
		if absf(right) > PAD_DEADZONE:
			zoom += signf(right) * inverse_lerp(PAD_DEADZONE, 1.0, minf(absf(right), 1.0))
	if get_viewport().gui_get_focus_owner() == null:
		pan += Vector2(float(Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT))
				- float(Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT)),
			float(Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN))
				- float(Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP)))
	pan = pan.limit_length(1.0)
	if pan != Vector2.ZERO:
		var next_center := _bounded_center(_center + pan * PAD_PAN * delta / _scale)
		if not next_center.is_equal_approx(_center):
			_center = next_center
			_update_base()
			refresh_overlay()
	if zoom != 0.0:
		_zoom_at(size * 0.5, pow(PAD_ZOOM, clampf(zoom, -1.0, 1.0) * delta))
	if cross and (device_changed or pan != Vector2.ZERO or zoom != 0.0):
		_set_hover(_pick(size * 0.5))


## Действие игрока над личной картой (из GameWorld): «прыжок» — к себе, «взаимодействие» — выбрать место
## или поставить метку под прицелом (геймпад) или под курсором. true — событие обработано.
func map_action(event: InputEvent) -> bool:
	if park or _data == null or not is_visible_in_tree():
		return false
	if event.is_action_pressed("jump"):
		center_on_player()
		return true
	if event.is_action_pressed("interact"):
		var at := size * 0.5 if _pad_cross else get_local_mouse_position()
		var place := _pick(at)
		if not place.is_empty():
			_select_place(place)
		else:
			var marker := screen_to_world(at)
			if not field_sheet or _bounds.has_point(marker):
				marker_requested.emit(marker / TILE)
		return true
	return false


func center_on_player() -> void:
	if park or not player.is_finite():
		return
	var target := _bounded_center(player)
	if target.is_equal_approx(_center):
		return
	_center = target
	_update_base()
	refresh_overlay()


## Открыть уже известное место из дневника, не назначая его целью.
func focus_place(id: String) -> bool:
	for place: Dictionary in places:
		if str(place.get("key", "")) == id:
			selected_place = place
			_center = _bounded_center(place_at(place))
			_update_base()
			refresh_overlay()
			hover_changed.emit(place)
			return true
	return false


func _zoom_at(at: Vector2, factor: float) -> void:
	var anchor := screen_to_world(at)
	var next_scale := clampf(_scale * factor, _min_scale, MAX_SCALE)
	if is_equal_approx(_scale, next_scale):
		return
	_scale = next_scale
	_center = _bounded_center(_center + anchor - screen_to_world(at))
	_update_base()
	refresh_overlay()


## Фон и засечки — в экранных координатах, сама подложка — слой _base
func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("#26372f") if field_sheet else (Paint.PARK_PAPER if _styled() else Data.EMPTY))


## Подложка в мировых метрах: положение и масштаб слоя задаёт _refresh_base
func _draw_tiles() -> void:
	if _data == null:
		return
	if _baked():
		_tiles.draw_texture_rect(_data.atlas_texture, Rect2(Vector2.ZERO, Vector2(_data.world.W, _data.world.H) * TILE), false, Color("#f3e5c5"))
	else:
		Paint.tiles(_tiles, _data, _styled())


func _draw_base() -> void:
	if _data == null:
		return
	if not _baked():
		Paint.lines(_lines, _data, _stroke_scale, _styled())
	if _baked() and not field_sheet:
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
	if not FOG_OF_WAR or not paper or _data == null or journal == null:
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


## Круглая маска с мягким краем. Повторные штампы только открывают карту, не закрывая прежние открытия.
func _open_fog(at: Vector2, radius: float) -> void:
	if _fog == null or not at.is_finite():
		return
	var c := Vector2i((at / FOG_CELL).round())
	var r := radius / FOG_CELL
	var extent := ceili(r)
	var bounds := Rect2i(Vector2i.ZERO, _fog.get_size())
	if not bounds.grow(extent).has_point(c):
		return
	var inner := maxf(0.0, r - 2.0)
	var clear := Color(Paint.PARK_PAPER, 0.0)
	for dy in range(-extent, extent + 1):
		var y := c.y + dy
		if y < 0 or y >= bounds.size.y or absf(dy) >= r:
			continue
		var outer_x := floori(sqrt(maxf(0.0, r * r - float(dy * dy))))
		var inner_x := floori(sqrt(maxf(0.0, inner * inner - float(dy * dy)))) if absf(dy) < inner else -1
		if inner_x >= 0:
			_fog.fill_rect(Rect2i(c.x - inner_x, y, inner_x * 2 + 1, 1).intersection(bounds), clear)
		for dx in range(-outer_x, outer_x + 1):
			if absi(dx) <= inner_x:
				continue
			var x := c.x + dx
			if x < 0 or x >= bounds.size.x:
				continue
			var alpha := smoothstep(inner, r, Vector2(dx, dy).length())
			if alpha < _fog.get_pixel(x, y).a:
				_fog.set_pixel(x, y, Color(Paint.PARK_PAPER, alpha))
	_fog_dirty = true


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
	if _styled() and not field_sheet:
		_park_grid() # засечки поверх бумаги и подложки, как сетка на печатной карте
	_draw_pins()
	if not park:
		if bike.is_finite():
			var at := world_to_screen(bike)
			_overlay.draw_circle(at, 9.0, Color("#fff9e9"), true, -1.0, true)
			_overlay.draw_circle(at, 7.0, Color("#276582"), true, -1.0, true)
			_overlay.draw_texture_rect(UiIcons.map_icon("bike"), Rect2(at - Vector2.ONE * 5.5, Vector2.ONE * 11.0), false, Color.WHITE)
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
	var faded := not ride_legs.is_empty()
	if show_travel_track:
		for leg: Dictionary in journal.legs:
			if _track_window.intersects(leg.bounds.grow(1.0)):
				_draw_leg(leg.points, faded)
		if journal.current.size() > 1 and _track_window.intersects(journal.current_bounds.grow(1.0)):
			_draw_leg(journal.current, faded)
	for points: PackedVector2Array in ride_legs:
		_track.draw_polyline(points, Color("#fffaff"), 7.0 / _stroke_scale, true)
		_track.draw_polyline(points, RIDE_INK, 4.2 / _stroke_scale, true)
	for mark: Dictionary in ride_fall_marks:
		var at := Vector2(float(mark.get("x", 0.0)), float(mark.get("z", 0.0)))
		var radius := 6.0 / _stroke_scale
		_track.draw_line(at + Vector2(-radius, -radius), at + Vector2(radius, radius), Color.RED, 2.5 / _stroke_scale)
		_track.draw_line(at + Vector2(-radius, radius), at + Vector2(radius, -radius), Color.RED, 2.5 / _stroke_scale)


func _draw_leg(points: PackedVector2Array, faded := false) -> void:
	if faded:
		_track.draw_polyline(points, Color(Paint.TRACE, 0.35), 2.4 / _stroke_scale, true)
		return
	_track.draw_polyline(points, Color("#fffaff"), 5.5 / _stroke_scale, true)
	_track.draw_polyline(points, Paint.TRACE, 3.1 / _stroke_scale, true)


## 20.11.2026: показать заезд — его трек ярко, вид на всю его рамку (пустой список — обычный путь целиком)
func show_ride(legs: Array, frame: Rect2, fit_view := true, fall_marks: Array = []) -> void:
	ride_legs = legs
	ride_fall_marks = fall_marks
	_ride_frame = frame if not legs.is_empty() else Rect2()
	if _track != null:
		_track.queue_redraw()
	if not legs.is_empty() and fit_view:
		_frame_ride()


## Вид на рамку выбранного заезда (и после смены размера карты: список заездов сужает её)
func _frame_ride() -> void:
	if size.x < 2.0 or size.y < 2.0:
		return
	var area := (size - Vector2(80, 120)).max(Vector2.ONE * 40.0)
	var fit: Rect2 = preload("res://scripts/game/ride_log.gd").framed_bounds(_ride_frame, area.x / area.y)
	_center = fit.get_center().clamp(_bounds.position, _bounds.end)
	_scale = clampf(minf(area.x / maxf(fit.size.x, 1.0), area.y / maxf(fit.size.y, 1.0)), _min_scale, MAX_SCALE)
	_update_base()
	refresh_overlay()


static func _pin_color(kind: String) -> Color:
	match kind:
		"peak": return Color("#866038")
		"lake": return Color("#2f6d8c")
		"site": return Color("#316760")
		_: return Color("#5f507a")


static func pin_color(kind: String, icon: String) -> Color:
	match icon:
		"farm": return Color("#92613a")
		"house", "fishing": return Color("#7d7243")
		"ruin": return Color("#95534a")
		"tower", "obelisk", "stones": return Color("#397474")
		"shelter": return Color("#526c54")
		_: return _pin_color(kind)


func _draw_pins() -> void:
	var labels: Array[Rect2] = []
	var photos: Array[Dictionary] = []
	var font: Font = _park_font if _styled() else ThemeDB.fallback_font
	var fs := 16 if _styled() else 14
	for i in places.size():
		var place: Dictionary = places[i]
		var at := world_to_screen(place_at(place))
		if not Rect2(Vector2.ONE * 10.0, size - Vector2.ONE * 20.0).has_point(at):
			continue
		var focused: bool = place.key == hover.get("key") or (tablet and place.key == selected_place.get("key"))
		var here := park and i == 0
		var kind := str(place.get("kind", "settlement"))
		var icon_kind := UiIcons.map_place_icon(place)
		var color := Color("#c14930") if here else (pin_color(kind, icon_kind) if field_sheet else _pin_color(kind))
		var halo := 11.0 if field_sheet else (10.0 if _styled() else 8.5)
		var radius := 9.2 if field_sheet else (8.2 if _styled() else 6.8)
		var icon_size := 14.0 if field_sheet else (12.0 if _styled() else 10.0)
		if focused:
			_overlay.draw_circle(at, halo + 4.5, Color(color, 0.28), true, -1.0, true)
		_overlay.draw_circle(at, halo, Color("#fff9e9"), true, -1.0, true)
		_overlay.draw_circle(at, radius, color, true, -1.0, true)
		_overlay.draw_texture_rect(UiIcons.map_icon(icon_kind), Rect2(at - Vector2.ONE * icon_size * 0.5, Vector2.ONE * icon_size), false, Color.WHITE)
		if tablet:
			_draw_status(at, int(place.get("map_status", 0)))
			var path: String = place.get("map_photo", "")
			if _show_photos and not path.is_empty():
				if not _photo_cache.has(path):
					photo_thumbnail_requested.emit(path)
				elif _photo_cache[path] != null:
					photos.append({at = at, image = _photo_cache[path]})
		if field_sheet and not focused and kind != "settlement" and _scale <= _min_scale * 1.4:
			continue
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
	_draw_photo_pins(photos, labels)


func _draw_status(at: Vector2, status: int) -> void:
	if status & Status.QUEST:
		_overlay.draw_arc(at, 13.0, 0.0, TAU, 24, Color("#7a461a"), 2.0, true)
	if status & Status.VISITED:
		_draw_status_badge(at + Vector2(9, -8), UiIcons.CHECK, Color("#254a3e"))
	elif status & Status.REVEALED:
		var pos := at + Vector2(9, -8)
		_overlay.draw_circle(pos, 5.0, Color("#fff9e9"), true, -1.0, true)
		_overlay.draw_arc(pos, 3.1, 0.0, TAU, 12, Color("#655436"), 1.5, true)
	if status & Status.PHOTO:
		_draw_status_badge(at + Vector2(-9, 8), UiIcons.ALBUM, Color("#55416e"))


func _draw_status_badge(at: Vector2, icon: Texture2D, color: Color) -> void:
	_overlay.draw_circle(at, 6.0, Color("#fff9e9"), true, -1.0, true)
	_overlay.draw_circle(at, 4.9, color, true, -1.0, true)
	_overlay.draw_texture_rect(icon, Rect2(at - Vector2.ONE * 3.5, Vector2.ONE * 7.0), false, Color.WHITE)


func _draw_photo_pins(photos: Array[Dictionary], occupied: Array[Rect2]) -> void:
	if photos.is_empty():
		return
	for point: Vector2 in [player, goal, quest]:
		if point.is_finite():
			occupied.append(Rect2(world_to_screen(point) - Vector2.ONE * 12.0, Vector2.ONE * 24.0))
	var safe := Rect2(Vector2.ONE * 12.0, size - Vector2(24, 48))
	for photo: Dictionary in photos:
		var at: Vector2 = photo.at
		var image: Texture2D = photo.image
		var dimensions := image.get_size()
		dimensions *= minf(52.0 / dimensions.x, 34.0 / dimensions.y)
		var left := -16.0 - dimensions.x
		var top := -dimensions.y * 0.5
		for offset: Vector2 in [Vector2(16, top), Vector2(left, top), Vector2(16, top + 23),
				Vector2(left, top + 23), Vector2(16, top - 23), Vector2(left, top - 23)]:
			var rect := Rect2(at + offset, dimensions)
			if not safe.encloses(rect) or occupied.any(func(other: Rect2) -> bool: return other.intersects(rect.grow(3.0))):
				continue
			occupied.append(rect.grow(3.0))
			var edge := Vector2(at.x + signf(offset.x) * 16.0, clampf(at.y, rect.position.y + 2.0, rect.end.y - 2.0))
			_overlay.draw_line(at.move_toward(edge, 7.0), edge, Paint.PARK_INK, 1.0, true)
			_overlay.draw_rect(rect.grow(2.0), Color("#fff9e9"))
			_overlay.draw_texture_rect(image, rect, false)
			break


func _draw_legend() -> void:
	if _data == null:
		return
	var color := HudStyle.CREAM if field_sheet else (Paint.PARK_INK if _styled() else Paint.INK)
	var font: Font = _park_font if _styled() else ThemeDB.fallback_font
	var north := Vector2(size.x - 26.0, 28.0) if park or tablet else Vector2(size.x - 38.0, 84.0)
	_legend.draw_colored_polygon(PackedVector2Array([north + Vector2(0, -8), north + Vector2(5, 7),
		north + Vector2(0, 4), north + Vector2(-5, 7)]), color)
	_legend_text(north + Vector2(0, 23), "С", color, font)
	var metres := 50.0 if _scale > 0.9 else (100.0 if _scale > 0.4 else (250.0 if _scale > 0.18 else 500.0))
	var start := Vector2(18, size.y - 16)
	var end := start + Vector2(metres * _scale, 0)
	_legend.draw_polyline(PackedVector2Array([start - Vector2(0, 5), start, end, end - Vector2(0, 5)]), color, 1.7, true)
	_legend_text((start + end) * 0.5 - Vector2(0, 8), "%d м" % metres, color, font)
	if _styled():
		_legend.draw_rect(Rect2(Vector2.ONE, size - Vector2.ONE * 2), Color("#aca17e"), false, 2.0)
	if not park and journal != null and not tablet:
		var panel := Color("#f2e7cd") if paper else Color("#f5f8f3")
		_legend.draw_rect(Rect2(16, 12, 210, 92), panel)
		if paper:
			_legend.draw_rect(Rect2(16, 12, 210, 92), Color("#aca17e"), false, 1.5)
		Paint.text(_legend, Vector2(121, 39), "Карта поездок", color, 22, font)
		Paint.text(_legend, Vector2(121, 63), "Трек · %s" % Util.distance_text(journal.distance), Paint.TRACE, 14, font)
		Paint.text(_legend, Vector2(121, 85), "Открыто мест · %d" % places.size(), color, 14, font)
		Paint.text(_legend, Vector2(size.x * 0.5, size.y - 19), move_hint, color, 12, font)
		_draw_key(color, font)
	elif tablet and not field_sheet:
		_draw_key(color, _park_font)
	if _pad_cross:
		# прицел геймпада: метка и выбор места — под ним
		var c := size * 0.5
		for d: Vector2 in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
			_legend.draw_line(c + d * 5.0, c + d * 13.0, Color("#fffaf0"), 4.0, true)
			_legend.draw_line(c + d * 5.0, c + d * 13.0, color, 1.8, true)


func _legend_text(at: Vector2, caption: String, color: Color, font: Font) -> void:
	if not field_sheet:
		Paint.text(_legend, at, caption, color, 12, font)
		return
	var face := font if font != null else ThemeDB.fallback_font
	at.x -= face.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x * 0.5
	_legend.draw_string(face, at, caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, color)


## Условные знаки: только известные виды мест, чтобы легенда не раскрывала ещё не найденные объекты.
func _draw_key(color: Color, font: Font) -> void:
	# На низкой карте легенда перекрывает ориентиры и центр управления.
	if size.y < 320.0:
		return
	var rows := [["Дорога", Paint.PAPER_STROKES[2]], ["Тропа", Paint.PAPER_STROKES[1]],
		["Велотрасса", Paint.PAPER_STROKES[3]], ["Игрок", "player"], ["Цель", "goal"]]
	if show_travel_track:
		rows.push_front(["Мой трек", "track"])
	if not ride_legs.is_empty():
		rows.insert(1, ["Заезд", "ride"])
	if bike.is_finite():
		rows.append(["Велосипед", "bike"])
	if quest.is_finite():
		rows.append(["Задание", "quest"])
	if tablet:
		rows.append_array([["Узнано", "revealed"], ["Посещено", "visited"], ["Есть снимок", "photo"], ["Шаг задания", "quest_status"]])
	var names := {settlement = "Поселение", peak = "Вершина", lake = "Озеро", site = "Место",
		tower = "Вышка", obelisk = "Обелиск", ruin = "Руины", stones = "Каменный круг",
		shelter = "Приют", house = "Дом", farm = "Хутор", fishing = "Рыбацкий дом", bench = "Лавка"}
	var seen := {}
	for place: Dictionary in places:
		var icon := UiIcons.map_place_icon(place)
		if not names.has(icon):
			icon = "site"
		if not seen.has(icon):
			seen[icon] = true
			rows.append([names[icon], "place:" + icon])
	var columns := 2 if size.x >= 360.0 else 1
	var count := ceili(float(rows.size()) / columns)
	var box := Rect2(size.x - 16.0 - 156.0 * columns, size.y - 36.0 - count * 21.0, 156.0 * columns, count * 21.0 + 14.0)
	if box.position.y < 110.0 or box.position.x < 8.0:
		return
	_legend.draw_rect(box, Color("#f2e7cd"))
	_legend.draw_rect(box, Color("#aca17e"), false, 1.5)
	for i in rows.size():
		var column := i / count
		var row := i % count
		var y := box.position.y + 17.0 + row * 21.0
		var a := Vector2(box.position.x + 12.0 + column * 156.0, y)
		var b := a + Vector2(30.0, 0.0)
		var sample: Variant = rows[i][1]
		var at := (a + b) * 0.5
		if sample is Array:
			_legend.draw_line(a, b, sample[0], sample[2], true)
			_legend.draw_line(a, b, sample[1], sample[3], true)
		elif sample == "track":
			_legend.draw_line(a, b, Color("#fffaff"), 5.5, true)
			_legend.draw_line(a, b, Paint.TRACE, 3.1, true)
		elif sample == "ride":
			_legend.draw_line(a, b, Color("#fffaff"), 7.0, true)
			_legend.draw_line(a, b, RIDE_INK, 4.2, true)
		elif sample == "player":
			_legend.draw_colored_polygon(PackedVector2Array([at + Vector2(0, -8), at + Vector2(6, 6), at + Vector2(0, 3), at + Vector2(-6, 6)]), Paint.BLUE)
		elif sample in ["revealed", "visited", "photo", "quest_status"]:
			if sample == "revealed":
				_legend.draw_circle(at, 5.0, Color("#fff9e9"), true, -1.0, true)
				_legend.draw_arc(at, 3.1, 0.0, TAU, 12, Color("#655436"), 1.5, true)
			elif sample == "quest_status":
				_legend.draw_circle(at, 7.0, Color("#316760"), true, -1.0, true)
				_legend.draw_arc(at, 9.0, 0.0, TAU, 24, Color("#7a461a"), 2.0, true)
			else:
				_legend.draw_circle(at, 6.0, Color("#fff9e9"), true, -1.0, true)
				_legend.draw_circle(at, 4.9, Color("#254a3e") if sample == "visited" else Color("#55416e"), true, -1.0, true)
				_legend.draw_texture_rect(UiIcons.CHECK if sample == "visited" else UiIcons.ALBUM, Rect2(at - Vector2.ONE * 3.5, Vector2.ONE * 7.0), false, Color.WHITE)
		elif str(sample).begins_with("place:") or sample == "bike":
			var icon_kind := str(sample).trim_prefix("place:")
			var pin_kind := icon_kind if icon_kind in ["peak", "lake", "settlement"] else "site"
			_legend.draw_circle(at, 8.0, Color("#276582") if sample == "bike" else _pin_color(pin_kind), true, -1.0, true)
			_legend.draw_texture_rect(UiIcons.map_icon(icon_kind), Rect2(at - Vector2.ONE * 5.5, Vector2.ONE * 11.0), false, Color.WHITE)
		else:
			var tint: Color = HudStyle.AMBER if sample == "goal" else quest_color
			_legend.draw_circle(at, 8.5, HudStyle.SURFACE, true, -1.0, true)
			_legend.draw_arc(at, 8.5, 0.0, TAU, 20, Color("#cc822c") if sample == "goal" else quest_color, 1.6, true)
			var icon := UiIcons.map_icon("goal") if sample == "goal" else UiIcons.quest_small(quest_kind)
			_legend.draw_texture_rect(icon, Rect2(at - Vector2.ONE * 5.5, Vector2.ONE * 11.0), false, tint)
		_legend.draw_string(font if font != null else ThemeDB.fallback_font, Vector2(b.x + 12.0, y + 5.0), rows[i][0],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, color)
