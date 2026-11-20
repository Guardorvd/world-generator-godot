class_name Hud
extends Control
const RideDial = preload("res://scripts/ui/ride_dial.gd")
## Интерфейс поверх 3D: сведения о местности, мини-карта, большая карта, всплывающие сообщения,
## прицел и подсказки. Прицел, панель сведений и надписи — узлы сцены main.tscn (правятся в редакторе),
## мини-карта и личная карта рисуются кодом (LocalMap, WorldMapView). Подсказки внизу и у прицела меняются по тому, что игрок
## делает сейчас (GameWorld._update_hints); велосипед отмечен на картах, пока игрок не на нём.
## С 2.9 к местам добавились крупные озёра с названиями (WorldData.lakes): открываются на берегу.
## С 12.5+ у каждого сведения одно место: курс и расстояния до цели и задания — на компасе, что делать — в
## счётчике задания, местность под ногами — в панели сведений. Перемещение с доски требует подтверждения.

signal travel_requested(place: Dictionary)
signal goal_changed(place: Dictionary)
signal map_close_requested

const TILE := GameConfig.TILE
const DIRS := ["С", "СЗ", "З", "ЮЗ", "Ю", "ЮВ", "В", "СВ"]
const LocalMap = preload("res://scripts/ui/local_map.gd")
const Atlas = preload("res://scripts/ui/world_map_view.gd")
const MapData = preload("res://scripts/ui/local_map_data.gd")
const Journal = preload("res://scripts/game/map_journal.gd")
const RideLog = preload("res://scripts/game/ride_log.gd")
const MINI := LocalMap.DIAMETER
const SUMMARY_FADE := 0.24
const SUMMARY_HINT_TIME := 5.0
const RIDE_PEEK_HOLD := 2.5
const RIDE_PEEK_IN := 0.22
const RIDE_PEEK_OUT := 0.65
const LEFT_MARGIN := 18.0  # левая колонка: отступ от края и зазор между карточками (с 19.11.2026)
const LEFT_GAP := 10.0
const LEFT_WIDTH := 282.0  # 19.11.2026: ширина левой колонки постоянна (как у сведений о месте), от соседей не зависит
const TOAST_TIME := 3.5 # сколько сообщение висит на экране (с)
const TOAST_FADE := 0.4 # сколько гаснет без очереди (с)
const TOAST_QUEUE := 2 # сколько сообщений ждут в очереди, старые отбрасываются (19.11.2026: было 3)
const TOAST_STALE := 8.0 # 19.11.2026: дольше этого (с) под картой или паузой — некритичное сообщение сгорает
const TOAST_REPEAT := 20.0 # 19.11.2026: то же сообщение раньше этого срока (с) не повторяется
const GOLD := Color(1.0, 0.82, 0.32)  # цвет цели путешествия
const Quests = preload("res://scripts/game/quests.gd")
const UiIcons = preload("res://scripts/ui/ui_icons.gd")
const UiAudio = preload("res://scripts/ui/ui_audio.gd")
const HudStyle = preload("res://scripts/ui/hud_style.gd")
## 14.2: края экрана темнеют к углам, середина не тронута; strength — от RideDial.warning
const VIGNETTE_CODE := """shader_type canvas_item;
uniform float strength = 0.0;
void fragment() {
	float d = length((UV - 0.5) * vec2(1.25, 1.0));
	COLOR = vec4(0.12, 0.02, 0.02, strength * smoothstep(0.42, 0.85, d));
}
"""

var world: WorldData
var _compass_quest := {}
var map_preview: Image
var map_data: MapData
var map_journal := Journal.new()
var ride_log := RideLog.new()     # 20.11.2026: история заездов (вкладка «Заезды» дневника); сохранение — поле "rides"
var explore := Exploration.new()  # открытое сверху, счётчики пути и альбом (с 18.11.2026); сохранение — поле "explore"
const Tablet := preload("res://scripts/ui/journal_panel.gd")
var journal_panel: Tablet
var _tablet_places_dirty := true
var plaque_panel   # табличка обелиска: название и описание
var minimap: LocalMap
var controls: Controls = GameContext.scope.controls
var big_map: Atlas
var compass: Compass
var settlement_panel
var goal := {}  # цель путешествия — место из places() или пусто
var quests: Quests  # 11.9: задания игры (GameWorld), счётчик под мини-картой показывает активное
var tracker: PanelContainer
var _tracker_content: VBoxContainer
var _tracker_title: Label
var _tracker_icon: TextureRect  # 12.5: пиктограмма вида задания или галочка выполненного
var _tracker_kind: Label
var _tracker_count: Label
var _tracker_step: Label
var _tracker_note: Label
var _tracker_note_row: HBoxContainer
var _tracker_note_icon: TextureRect
var _tracker_compact := -1  # 19.11.2026: 1 — лёгкий вид (значок, шаг, полоска), 0 — полный, -1 — не применено
var _tracker_progress: Control
var _tracker_head: HBoxContainer
var _tracker_series: Label  # вторая строка счётчика: «Летопись обелисков: 2 из 5» (серия идёт параллельно заданию)
var _step_count := 0
var _step_index := 0
var _photo_mode := false
## 18.11.2026: три вида сводки по Tab. LIGHT — основной: видна только мини-карта (LIGHT_ALPHA) и линия навигации;
## FULL — вся сводка; HIDDEN — ничего, кроме срочного. Порядок по Tab: лёгкий → полный → скрытый → лёгкий
enum View { HIDDEN, LIGHT, FULL }
const LIGHT_ALPHA := 0.75
var view_mode := View.LIGHT
var _revealed := false      # view_mode == FULL
var _light := 1.0           # 0..1: проявление лёгкого вида
var _summary_blocked := false
var _summary_progress := 0.0
var _ride_activity := false
var _ride_peek_left := 0.0
var _ride_peek := 0.0
var _summary_hint_left := SUMMARY_HINT_TIME
var _summary_hint: Label
var _summary_switch: PanelContainer
var _reticle_on_target := false
var _reticle_open := 0.0
var _reticle_tween: Tween
var _aim_id := ""
var _prompt_aimed := true
var interaction_audio: UiAudio
var _hint_urgent := false # подсказка, которую видно и без Tab (падение)
var _flash_tween: Tween
var _travel_dialog: ConfirmationDialog  # 12.5+: подтверждение перемещения с большой карты
var _reveal_key := Vector4.INF  # что было при последней раскладке сводки (_process)
var _reveal_dirty := true
var _map_hint_pad := -1  # для какого устройства написана подсказка под картой (1 — геймпад)
var _repair: RepairArc  # 18.11.2026: кольцо удержания «взаимодействия» при ремонте
var _ride: RideDial  # 18.11.2026: прибор движения слева внизу — скорость, дуга сил (14.2) и тормоза в одном круге
var _vignette_strength := -1.0
var _vignette: ColorRect  # 14.2: затемнение краёв экрана, когда силы на исходе
var _hint_items: Array = []   # 14.2: чипы подсказок внизу и у прицела: [[клавиша, действие], ...]
var _prompt_items: Array = []
var _key_style: StyleBoxFlat
var _hint_style: StyleBoxFlat
var _prompt_style: StyleBoxFlat
var _warning_style: StyleBoxFlat
@onready var _info_panel: PanelContainer = $InfoPanel
@onready var info: Label = $InfoPanel/Rows/Header/Info
@onready var _clock_card: PanelContainer = $InfoPanel/Rows/Header/Time
@onready var _clock_label: Label = $InfoPanel/Rows/Header/Time/Clock
var _clock_row: HBoxContainer
@onready var _surface: Label = $InfoPanel/Rows/Surface
@onready var _altitude: Label = $InfoPanel/Rows/Readings/Altitude/Value
@onready var _temperature: Label = $InfoPanel/Rows/Readings/Temperature/Value
@onready var _nearby: Label = $InfoPanel/Rows/Nearby
@onready var _reticle: Control = $Crosshair
@onready var toast_label: Label = $Toast/Stack/Line/Text
@onready var _toast_time: ProgressBar = $Toast/Stack/TimeLeft
@onready var lock_hint: PanelContainer = $LockHint
@onready var hint: HFlowContainer = $Hint
@onready var prompt: HBoxContainer = $Prompt
var _toast_left := 0.0
var _toast_hidden_for := 0.0 # сколько сообщение или очередь пролежали под окном поверх игры (с)
var _toast_queue: PackedStringArray = []
var _toast_kinds: Array[StringName] = []
var _toast_icon: TextureRect
var _toast_panel_style: StyleBoxFlat
var _toast_fill_style: StyleBoxFlat
var _toast_accent := HudStyle.MUTED
var _toast_reward := false
var _toast_flash := 0.0
var _toast_kind: StringName = &"info"
var _toast_seen := {}  # текст → время показа (мс): повтор того же сообщения не мелькает снова
static var _toast_points_pattern := RegEx.create_from_string(r" · \+[1-9][0-9]* очк\.")
var _clock_minute := -1

# Состояние игрока для отрисовки карт
var px := 0.0
var pz := 0.0
var yaw := 0.0
var visited := {}
var bike_pos := Vector2.ZERO
var bike_shown := false


func _ready() -> void:
	interaction_audio = UiAudio.new()
	add_child(interaction_audio)
	_style_summary()
	# мини-карта в правом верхнем углу, под надписями (как вторым узлом после панели сведений)
	minimap = LocalMap.new()
	minimap.anchor_left = 1.0
	minimap.anchor_right = 1.0
	minimap.offset_left = -MINI - 18
	minimap.offset_top = 18
	minimap.offset_right = -18
	minimap.offset_bottom = MINI + 18
	add_child(minimap)
	move_child(minimap, $InfoPanel.get_index() + 1)

	compass = Compass.new()
	compass.hud = self
	compass.anchor_left = 0.5
	compass.anchor_right = 0.5
	compass.offset_left = -162
	compass.offset_right = 162
	compass.offset_top = 18
	compass.offset_bottom = 74
	add_child(compass)
	compass.visibility_changed.connect(compass.queue_redraw)
	move_child(compass, minimap.get_index() + 1)

	tracker = _build_tracker()
	add_child(tracker)
	tracker.resized.connect(func() -> void: _reveal_dirty = true)
	move_child(tracker, compass.get_index() + 1)

	journal_panel = Tablet.new()
	journal_panel.data_provider = journey_data
	journal_panel.quest_provider = _tablet_quest
	journal_panel.goal_provider = func() -> Dictionary: return goal
	journal_panel.goal_requested.connect(_select_map_goal)
	journal_panel.cover_requested.connect(func(key: String, path: String) -> void:
		if explore.choose_album_photo(key, path):
			_tablet_places_dirty = true)
	add_child(journal_panel)
	big_map = journal_panel.map_view
	big_map.journal = map_journal
	big_map.controls = controls
	big_map.input_blocked = func() -> bool: return _travel_dialog != null
	big_map.place_selected.connect(_select_map_goal)
	big_map.visibility_changed.connect(_sync_tablet_map)
	big_map.marker_requested.connect(func(at: Vector2) -> void: _select_map_goal(marker_goal(at)))
	journal_panel.closed.connect(func() -> void: map_close_requested.emit())
	settlement_panel = preload("res://scripts/ui/settlement_panel.gd").new()
	add_child(settlement_panel)
	plaque_panel = preload("res://scripts/ui/plaque_panel.gd").new()
	add_child(plaque_panel)
	_vignette = ColorRect.new()
	_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var vignette_shader := Shader.new()
	vignette_shader.code = VIGNETTE_CODE
	_vignette.material = ShaderMaterial.new()
	_vignette.material.shader = vignette_shader
	_vignette.visible = false
	add_child(_vignette)
	move_child(_vignette, 0)
	_ride = RideDial.new()
	_ride.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_ride.offset_left = 18
	_ride.offset_right = 18 + RideDial.DIAMETER
	_ride.offset_top = -18 - RideDial.DIAMETER
	_ride.offset_bottom = -18
	_ride.hide()
	add_child(_ride)
	move_child(_ride, journal_panel.get_index())
	var brake_alert := RideDial.BrakeAlert.new()
	brake_alert.dial = _ride
	brake_alert.set_anchors_preset(Control.PRESET_CENTER)
	brake_alert.offset_left = -RideDial.BrakeAlert.SIZE.x * 0.5
	brake_alert.offset_right = RideDial.BrakeAlert.SIZE.x * 0.5
	brake_alert.offset_top = 66
	brake_alert.offset_bottom = 66 + RideDial.BrakeAlert.SIZE.y
	brake_alert.hide()
	add_child(brake_alert)
	move_child(brake_alert, journal_panel.get_index())
	_ride.alert = brake_alert
	_repair = RepairArc.new()
	_repair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_repair.set_anchors_preset(Control.PRESET_CENTER)
	_repair.offset_left = -RepairArc.DIAMETER * 0.5
	_repair.offset_right = RepairArc.DIAMETER * 0.5
	_repair.offset_top = 66
	_repair.offset_bottom = 66 + RepairArc.DIAMETER
	_repair.pivot_offset = Vector2.ONE * (RepairArc.DIAMETER * 0.5)
	_repair.hide()
	add_child(_repair)
	_summary_switch = PanelContainer.new()
	_summary_switch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_summary_switch.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_summary_switch.offset_left = -18
	_summary_switch.offset_right = -18
	_summary_switch.offset_top = -47
	_summary_switch.offset_bottom = -16
	_summary_switch.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_summary_switch.add_theme_stylebox_override("panel", _hint_style)
	add_child(_summary_switch)
	_summary_hint = Label.new()
	HudStyle.label(_summary_hint, 12, HudStyle.MUTED)
	_summary_switch.add_child(_summary_hint)
	_apply_reveal()


func _style_summary() -> void:
	# 18.11.2026: две строки вместо карточки — [биом · время] и [высота  температура  дорога]; подписи «Высота» и
	# «Температура» и разделитель скрыты (единицы говорят сами), дорога встала в строку показаний
	_info_panel.add_theme_stylebox_override("panel", HudStyle.panel(HudStyle.SURFACE, HudStyle.BORDER, 11, Vector2(12, 7)))
	$InfoPanel/Rows.add_theme_constant_override("separation", 3)
	HudStyle.label(info, 17)
	_clock_card.add_theme_stylebox_override("panel", HudStyle.panel(HudStyle.RECESS, HudStyle.BORDER, 6, Vector2(7, 1), false))
	_clock_row = HBoxContainer.new()
	_clock_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_clock_row.add_theme_constant_override("separation", 5)
	_clock_row.add_child(UiIcons.rect(UiIcons.CLOCK, 13, HudStyle.MINT))
	_clock_label.reparent(_clock_row, false)
	_clock_card.add_child(_clock_row)
	HudStyle.label(_clock_label, 13, HudStyle.MINT)
	HudStyle.label(_altitude, 14)
	HudStyle.label(_temperature, 14)
	HudStyle.label(_nearby, 12, HudStyle.MINT)
	$InfoPanel/Rows/Divider.hide()
	var readings: HBoxContainer = $InfoPanel/Rows/Readings
	readings.add_theme_constant_override("separation", 10)
	var alt_box: HBoxContainer = $InfoPanel/Rows/Readings/Altitude
	alt_box.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	alt_box.get_node("Title").hide()
	var alt_icon := UiIcons.rect(UiIcons.ALTITUDE, 14, Color(HudStyle.MUTED, 0.9))
	alt_box.add_child(alt_icon)
	alt_box.move_child(alt_icon, 0)
	var temp_box: HBoxContainer = $InfoPanel/Rows/Readings/Temperature
	temp_box.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	temp_box.get_node("Title").hide()
	var temp_icon := UiIcons.rect(UiIcons.THERMOMETER, 14, Color(HudStyle.MUTED, 0.9))
	temp_box.add_child(temp_icon)
	temp_box.move_child(temp_icon, 0)
	_surface.reparent(readings, false)
	HudStyle.label(_surface, 13, HudStyle.MUTED)
	_surface.autowrap_mode = TextServer.AUTOWRAP_OFF
	_surface.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_surface.clip_text = true
	_surface.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_surface.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_nearby.hide()
	_surface.hide()
	_info_panel.resized.connect(func() -> void: _reveal_dirty = true)

	# 19.11.2026: нижние подсказки — одна полупрозрачная пилюля без рамки, клавиша — заливкой без своей рамки
	_hint_style = HudStyle.panel(Color(HudStyle.SURFACE, 0.82), HudStyle.BORDER, 8, Vector2(7, 4))
	_hint_style.set_border_width_all(0)
	_prompt_style = HudStyle.panel(HudStyle.SURFACE, HudStyle.MINT, 10, Vector2(8, 5))
	_warning_style = HudStyle.panel(HudStyle.SURFACE, HudStyle.AMBER, 8, Vector2(8, 5))
	_key_style = HudStyle.panel(HudStyle.RECESS, HudStyle.BORDER, 5, Vector2(6, 2), false)
	_key_style.set_border_width_all(0)
	lock_hint.add_theme_stylebox_override("panel", _hint_style)
	HudStyle.label($LockHint/Text, 13, HudStyle.MUTED)
	_reticle.draw.connect(_draw_reticle)

	# 19.11.2026: плотнее по высоте — сообщение тонкой полосой, а не карточкой
	_toast_panel_style = HudStyle.panel(HudStyle.SURFACE, HudStyle.BORDER, 11, Vector2(12, 7))
	$Toast/Stack.add_theme_constant_override("separation", 5)
	_toast_panel_style.border_width_left = 3
	_toast_panel_style.corner_radius_top_left = 6
	_toast_panel_style.corner_radius_bottom_left = 6
	_toast_panel_style.content_margin_left = 14
	$Toast.add_theme_stylebox_override("panel", _toast_panel_style)
	$Toast.draw.connect(_draw_toast_accent)
	_toast_icon = UiIcons.rect(UiIcons.INFO, 17, HudStyle.MUTED)
	$Toast/Stack/Line.add_child(_toast_icon)
	$Toast/Stack/Line.move_child(_toast_icon, 0)
	HudStyle.label(toast_label, 14)
	# 19.11.2026: строка с переносом по словам не может стать уже колонки: иначе при узкой ширине каждое слово уходит
	# на свою строку, а карточка вытягивается вверх и сама обратно не сжимается
	var line_box: HBoxContainer = $Toast/Stack/Line
	toast_label.custom_minimum_size.x = LEFT_WIDTH - _toast_panel_style.get_margin(SIDE_LEFT) 		- _toast_panel_style.get_margin(SIDE_RIGHT) - 17.0 - line_box.get_theme_constant("separation")
	_toast_time.add_theme_stylebox_override("background", HudStyle.panel(HudStyle.RECESS, HudStyle.RECESS, 1, Vector2.ZERO, false))
	_toast_fill_style = HudStyle.panel(HudStyle.MINT, HudStyle.MINT, 1, Vector2.ZERO, false)
	_toast_time.add_theme_stylebox_override("fill", _toast_fill_style)


## Новая игра: запомнить карту мира и забыть сообщения прошлой игры
func set_world(w: WorldData, map_image: Image) -> void:
	world = w
	_clock_minute = -1
	_clock_card.hide()
	if _clock_row != null:
		_clock_row.hide()
	info.text = ""
	_surface.hide()
	_nearby.hide()
	map_preview = map_image
	map_data = MapData.new(w)
	_tablet_places_dirty = true
	map_data.prepare_atlas()
	map_journal = Journal.new()
	ride_log = RideLog.new()
	explore = Exploration.new()
	if journal_panel != null:
		journal_panel.clear()
		plaque_panel.clear()
	minimap.set_world(w, knows, map_data)
	big_map.journal = map_journal
	big_map.set_source(map_data)
	px = NAN # первый set_player нового мира точно перерисует карты
	visited = {}
	goal = {}
	_compass_quest = {}
	bike_shown = false
	view_mode = View.LIGHT
	_revealed = false
	_summary_progress = 0.0
	_ride_activity = false
	_ride_peek_left = 0.0
	_ride_peek = 0.0
	_light = 1.0
	_summary_hint_left = SUMMARY_HINT_TIME
	_apply_reveal()
	_toast_queue.clear()
	_toast_kinds.clear()
	_toast_seen.clear()
	_toast_left = 0.0
	_toast_hidden_for = 0.0
	$Toast.modulate.a = 0.0


## Выход из игры: забыть мир и карту, чтобы прошлый мир освободился, пока в меню
func clear_world() -> void:
	_close_travel()
	if settlement_panel != null:
		settlement_panel.clear()
	world = null
	map_preview = null
	map_data = null
	map_journal = Journal.new()
	ride_log = RideLog.new()
	explore = Exploration.new()
	if journal_panel != null:
		journal_panel.clear()
		plaque_panel.clear()
	big_map.journal = map_journal
	big_map.set_source(null)
	minimap.set_world(null)
	visited = {}
	goal = {}
	_compass_quest = {}
	quests = null
	_summary_blocked = false
	update_tracker()
	bike_pos = Vector2.ZERO
	bike_shown = false
	_toast_queue.clear()
	_toast_kinds.clear()
	_toast_seen.clear()
	_toast_left = 0.0
	_toast_hidden_for = 0.0
	$Toast.modulate.a = 0.0
	set_hints([], [])
	note_interaction_target("")
	_repair.reset()
	set_photo_mode(false)
	big_map.mouse_filter = Control.MOUSE_FILTER_IGNORE
	big_map.hover = {}


func set_map_visible(v: bool) -> void:
	if v:
		show_tablet(Tablet.Tab.MAP)
	else:
		_close_travel()
		journal_panel.clear()
		big_map.mouse_filter = Control.MOUSE_FILTER_IGNORE
		big_map.hover = {}
		_apply_reveal()


func show_tablet(tab: Tablet.Tab) -> void:
	var opening := not journal_panel.visible
	if opening:
		big_map.prepare_player_view()
		big_map.mouse_filter = Control.MOUSE_FILTER_STOP
		big_map.selected_place = {}
		big_map.hover = {}
	journal_panel.open_tab(tab, world.seed_text if world != null else "")
	_map_hint_pad = -1
	_sync_map_hint()
	_apply_reveal()


func _tablet_quest() -> Dictionary:
	if quests == null or quests.active.is_empty():
		return {}
	var q := quests.active
	var steps := PackedStringArray()
	for step: Dictionary in q.steps:
		steps.append(quests.step_text(step))
	return {title = q.title, steps = steps, index = q.step}


## Открытые места мира: поселения, вершины и озёра из индекса WorldData (с 8.9 extra).
## {key = id — устойчивый адрес и ключ в visited, name, x, y — клетки, kind, region, src — запись места}
## Быстрое перемещение с дорожной доски требует подтверждения.
## Фокус на «Остаться», Esc закрывает вопрос, а не карту
func ask_travel(place: Dictionary) -> void:
	_close_travel()
	var dialog := ConfirmationDialog.new()
	_travel_dialog = dialog
	dialog.title = "Переместиться?"
	dialog.dialog_text = "В «%s», %s отсюда. Велосипед будет рядом." % [place.name,
		Util.distance_text(Grid.hypot(place.x * TILE - px, place.y * TILE - pz))]
	dialog.dialog_autowrap = true
	dialog.ok_button_text = "Переместиться"
	dialog.cancel_button_text = "Остаться"
	dialog.get_ok_button().theme_type_variation = &"PrimaryButton"
	add_child(dialog)
	dialog.confirmed.connect(func() -> void:
		_close_travel()
		travel_requested.emit(place))
	dialog.canceled.connect(_close_travel)
	dialog.popup_centered(Vector2i(440, 0))
	dialog.get_cancel_button().grab_focus()


## 19.11.2026: подсказка под картой — под то устройство, с которого играют сейчас
func _sync_map_hint() -> void:
	if _map_hint_pad == int(controls.joypad):
		return
	_map_hint_pad = int(controls.joypad)
	var k := controls.label
	if controls.joypad:
		big_map.move_hint = "Левый стик · обзор   Правый стик · масштаб   %s · к себе   %s · цель или метка   %s/%s · вкладки" % [
			k.call(&"jump"), k.call(&"interact"), controls.button(JOY_BUTTON_LEFT_SHOULDER), controls.button(JOY_BUTTON_RIGHT_SHOULDER)]
	else:
		big_map.move_hint = "Перетащить или WASD · обзор   Колесо · масштаб   Ctrl+ЛКМ · метка"
	journal_panel.set_shortcuts(k.call(&"toggle_map"), k.call(&"journal"), big_map.move_hint)


func _close_travel() -> void:
	if _travel_dialog != null:
		_travel_dialog.hide()   # скрыть сразу: до удаления окно ещё держит модальность
		_travel_dialog.queue_free()
		_travel_dialog = null


func places() -> Array:
	if world == null:
		return []
	return all_places().filter(in_open_land)


## Все места плана, включая ещё не открытые земли: далёкую цель можно выбрать заранее.
func all_places() -> Array:
	var out: Array = []
	for kind: String in WorldData.PLACE_KINDS:
		for src: Variant in world.get(kind + "s"):
			var p := world.place(WorldData.place_id(kind, src.x, src.y)).duplicate()
			p.key = p.id
			out.append(p)
	# 13.9+final: поселения закреплённых соседних областей
	for src: Dictionary in world.region_places().list:
		var p: Dictionary = src.duplicate()
		p.key = p.id
		out.append(p)
	return out


## Trail definitions live in the start plan and in the persistent region ledger, even after field eviction.
func trail_places() -> Array:
	var plans: Array = [world.trail_plan]
	if world.outer != null:
		for entry: Dictionary in world.outer.get_ledger().get("regions", {}).values():
			plans.append(entry.get("trail_plan", {}))
	var result := []
	for plan: Dictionary in plans:
		if plan.get("state") != "found" or not plan.has("definition"): continue
		# велопарк хранит все свои трассы в routes, одиночная трасса — в definition
		for definition: Dictionary in plan.get("routes", [plan.definition]):
			var points: PackedVector2Array = definition.get("points", PackedVector2Array())
			if points.size() < 2: continue
			# Участки одного маршрута — одно место: старт первого, линия всех
			var length := 0.0
			for k in range(1, points.size()): length += points[k - 1].distance_to(points[k])
			if not result.is_empty() and result[-1].base == definition.get("title", "Велотрасса"):
				result[-1].points = result[-1].points + points
				result[-1].length += length
				continue
			var start := points[0] / TILE
			result.append({key = definition.id, kind = "trail", name = definition.get("title", "Велотрасса"), base = definition.get("title", "Велотрасса"),
				x = start.x, y = start.y, points = points, length = length})
	# в названии — длина маршрута со всеми его участками и связями: видно, куда и на сколько ехать
	for place: Dictionary in result:
		place.name = "%s · %.1f км" % [place.base, place.length / 1000.0]
	return result


## Место на открытой территории: туда можно переместиться с карты.
func in_open_land(p: Dictionary) -> bool:
	match p.kind:
		"settlement": return world.accessible(p.x, p.y, 2.0)
		"lake": return world.accessible(p.x, p.y) and world.accessible(p.src.sx, p.src.sy, 3.0)
	return world.accessible(p.x, p.y)


## Доска показывает само поселение и два ближайших доступных места.
func board_places(settlement: Variant, catalog: Variant = null) -> Array:
	var id := WorldData.place_id("settlement", settlement.x, settlement.y)
	var here := InteractionService.target(world.place(id))
	var center := Vector2(settlement.x, settlement.y)
	var options: Array = []
	var places_to_check: Array = all_places() if catalog == null else catalog
	for place: Dictionary in places_to_check:
		if place.key != id and in_open_land(place):
			options.append(place)
	options.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var da := center.distance_squared_to(Vector2(a.x, a.y))
		var db := center.distance_squared_to(Vector2(b.x, b.y))
		return a.key < b.key if da == db else da < db)
	var nearby := [here] + options.slice(0, 2)
	map_journal.reveal(nearby)
	return nearby


## Место открыто на большой карте: посещено, прочитано на доске, увидено сверху (вышка, вершина) или названо взятым заданием
func is_open(id: String) -> bool:
	return visited.has(id) or map_journal.read.has(id) or explore.revealed.has(id) or (quests != null and quests.known.has(id))


func map_place_count() -> int:
	return visited.size() + map_journal.read.size() + explore.revealed.size()


func sync_map_places() -> void:
	sync_minimap_places()
	_tablet_places_dirty = true
	_sync_tablet_map()


func _sync_tablet_map() -> void:
	if not big_map.is_visible_in_tree() or world == null:
		return
	big_map.set_player(Vector2(px, pz), yaw)
	if not _tablet_places_dirty:
		return
	_tablet_places_dirty = false
	var photos := explore.place_photos.duplicate()
	for key: String in explore.album:
		var shot: Dictionary = explore.album[key]
		var id: String = key.trim_prefix("plaque:") if key.begins_with("plaque:") else shot.get("place", "")
		var path: String = shot.get("path", "")
		if not id.is_empty() and not photos.has(id) and (key.begins_with("plaque:") or is_open(id)):
			photos[id] = path
	var known: Array = []
	var ids := _map_place_ids().merged(photos)
	var objective := quest_place()
	var quest_id: String = objective.get("key", "")
	if not quest_id.is_empty():
		ids[quest_id] = true
	for id: String in ids:
		var place := world.place(id)
		if place.is_empty():
			continue
		var pin := InteractionService.target(place)
		var status := 0
		if visited.has(id):
			status |= Atlas.Status.VISITED
		if map_journal.read.has(id) or explore.revealed.has(id) or (quests != null and quests.known.has(id)):
			status |= Atlas.Status.REVEALED
		if photos.has(id):
			status |= Atlas.Status.PHOTO
			pin.map_photo = photos[id]
		if quest_id == id:
			status |= Atlas.Status.QUEST
		pin.map_status = status
		known.append(pin)
	big_map.set_places(known)
	journal_panel.refresh_inspected_place()
	journal_panel.refresh_quest()
	_sync_map_goal()


## 18.11.2026: значки известных вершин и сооружений на мини-карте (поселения и озёра она рисует сама)
func sync_minimap_places() -> void:
	if world == null:
		return
	var list: Array[Dictionary] = []
	for id: String in _map_place_ids():
		if not (id.begins_with("peak:") or id.begins_with("site:")):
			continue
		var place := world.place(id)
		if not place.is_empty():
			list.append({at = Vector2(place.x, place.y) * TILE, kind = place.kind, icon = UiIcons.map_place_icon(place)})
	minimap.set_places(list)


func _map_place_ids() -> Dictionary:
	return map_journal.read.merged(visited).merged(explore.revealed).merged(quests.known if quests != null else {})


func _select_map_goal(place: Dictionary) -> void:
	var same: bool = place.key == goal.get("key")
	if same and place.kind == "marker":
		same = Vector2(place.x, place.y).distance_to(Vector2(goal.x, goal.y)) < 4.0
	if place.kind == "marker":
		big_map.selected_place = {} if same else place
		journal_panel.refresh_inspector(big_map.selected_place)
	set_goal({} if same else place)


func _sync_map_goal() -> void:
	var id: String = goal.get("key", "")
	var visible_pin := not id.is_empty() and journal_panel.visible and big_map.places.any(func(place: Dictionary) -> bool: return place.key == id)
	var show_goal: bool = not goal.is_empty() and (goal.kind == "marker" or is_open(id) or visible_pin)
	big_map.goal = Atlas.place_at(goal) if show_goal else Vector2.INF
	var objective := quest_place()
	big_map.quest = Atlas.place_at(objective) if objective.get("kind") in Quests.FIELD_PLACES else Vector2.INF
	big_map.quest_color = quest_color()
	big_map.quest_kind = quest_kind()
	big_map.refresh_overlay()


## Новая цель путешествия (пустой словарь — без цели)
func set_goal(place: Dictionary) -> void:
	goal = place
	goal_changed.emit(place)
	# вне сцены (проверки без окна) карт и компаса нет
	if is_node_ready():
		compass.queue_redraw()
		_sync_minimap_destinations()
		_sync_map_goal()
		journal_panel.refresh_inspector(big_map.selected_place)


static func marker_goal(at: Vector2) -> Dictionary:
	return {key = "marker", kind = "marker", name = "Метка", x = at.x, y = at.y}


## Именованные места восстанавливаются по каталогу, свободная метка — по координатам в клетках.
func restore_goal(key: String, marker_position := Vector2.INF) -> void:
	if key == "marker":
		set_goal(marker_goal(marker_position) if marker_position.is_finite() else {})
		return
	if not key.is_empty() and world != null:
		var known_place := world.place(key)
		if not known_place.is_empty():
			set_goal(InteractionService.target(known_place))
			return
		for place: Dictionary in trail_places():
			if place.key == key:
				set_goal(place)
				return
	set_goal({})


## Игрок в (x, z) метрах: если он дошёл до цели, цель снимается и возвращается текст сообщения
func check_goal(x: float, z: float) -> String:
	if goal.is_empty() or goal.kind in Quests.FIELD_PLACES or not at_place(goal, x, z):
		return ""
	var text := "Вы добрались до цели: «%s»" % goal.name
	set_goal({})
	return text


## Игрок в (x, z) метрах дошёл до места: у озера — на берегу, у остальных — ближе радиуса по виду места.
## Им же проверяют шаги заданий (Quests.tick)
func at_place(place: Dictionary, x: float, z: float) -> bool:
	if place.kind == "lake":
		return world.lake_within(x / TILE, z / TILE, PlayerState.LAKE_REACH, place.src.i)
	if place.kind in ["marker", "trail"]:
		return Grid.hypot(place.x - x / TILE, place.y - z / TILE) < 0.75
	return Grid.hypot(place.x - x / TILE, place.y - z / TILE) < (2.5 if place.kind in ["peak", "marker"] else (4.0 if place.kind == "site" else 6.0))


## Название места известно: посещено, цель, место взятого задания (11.9+) или открыто сверху (вышка, вершина)
func knows(id: String) -> bool:
	return is_open(id) or goal.get("key") == id


## Данные экрана «Путешествие» (JournalPanel.open): счётчики пути, открытые места по видам и страницы альбома
func journey_data() -> Dictionary:
	var places := all_places() if world != null else []
	var total := {}
	var found := {}
	var order: Array[String] = []
	for place: Dictionary in places:
		var label := "Поселения"
		match place.kind:
			"peak": label = "Вершины"
			"lake": label = "Озёра"
			"site":
				label = Exploration.site_title(place.src.type) if StageSites.TYPES.has(place.src.type) else "Места"
		if not total.has(label):
			total[label] = 0
			found[label] = 0
			order.append(label)
		total[label] += 1
		if is_open(place.key):
			found[label] += 1
	var rows: Array = []
	for label: String in order:
		rows.append([label, found[label], total[label]])
	var pages: Array[Dictionary] = []
	for page: Dictionary in Exploration.pages():
		var entry := page.duplicate()
		entry.shot = explore.album.get(page.key, {})
		if not entry.shot.is_empty() and str(entry.shot.get("place", "")) != "" and world != null:
			var shot_place := world.place(str(entry.shot.place))
			if not shot_place.is_empty():
				entry.place_name = str(shot_place.get("name", ""))
		pages.append(entry)
	# «Летопись обелисков»: страница на каждый обелиск мира, с названием и текстом таблички (ObeliskLore)
	for place: Dictionary in places:
		if place.kind == "site" and str(EntityCodec.value(place.src, "type", "")) == "obelisk":
			var key: String = "plaque:" + place.key
			var lore := ObeliskLore.describe(world, place)
			pages.append({key = key, group = Exploration.GROUPS.size() - 1, title = place.name,
				hint = "Снимите табличку вблизи (< 4,5 м)", text = lore.text, form = lore.form,
				place_name = place.name, shot = explore.album.get(key, {})})
	var active_quest := {}
	if quests != null and not quests.active.is_empty():
		var q := quests.active
		active_quest = {title = q.title, kind = q.kind, kind_title = Quests.KINDS[q.kind].title,
			color = quest_color(), step_text = quests.step_text(quests.step()),
			step_index = q.step + 1, step_count = q.steps.size(), cargo = quests.cargo}
	var sp := quests.series_progress() if quests != null else Vector2i.ZERO
	var series := {done = sp.x, total = sp.y, finished = quests.series_done if quests != null else false}
	var thanks: Array = Array(quests.thanks_lines()) if quests != null else []
	var helped: Array[String] = []
	if quests != null:
		for giver_id: String in quests.by_giver:
			var count := int(quests.by_giver[giver_id])
			if count <= 0:
				continue
			var vp := world.place(giver_id) if world != null else {}
			var vname: String = str(vp.get("name", giver_id)) if not vp.is_empty() else giver_id
			helped.append("%s (%d)" % [vname, count])
	var jkey := controls.label(&"journal") if controls != null else ""
	var close_hint := "%s / Esc" % jkey if not jkey.is_empty() else "J / Esc"
	var world_size := Vector2(world.W, world.H) * TILE if world != null else Vector2.ZERO
	var track := {legs = map_journal.legs, current = map_journal.current, player = Vector2(px, pz),
		yaw = yaw, world_size = world_size}
	var personal: Array = []
	for photo: Dictionary in explore.personal_photos:
		var item := photo.duplicate(true)
		var p := world.place(str(item.place)) if world != null and not str(item.place).is_empty() else {}
		item.place_name = str(p.get("name", ""))
		personal.append(item)
	return {seed = world.seed_text if world != null else "", close_hint = close_hint,
		foot = map_journal.foot, bike = map_journal.bike, time = explore.play_s, alt = explore.max_alt,
		photos = explore.photos, quests = quests.done if quests != null else 0, places = rows,
		pages = pages, groups = Exploration.GROUPS, active_quest = active_quest,
		series = series, thanks = thanks, helped = helped, track = track, rides = _ride_rows(), personal_photos = personal}


## 20.11.2026: заезды для вкладки дневника, новые первыми: подписи, счётчики, названия мест и трек
func _ride_rows() -> Array:
	var out: Array = []
	for entry: Dictionary in ride_log.history(map_journal, explore, quests.done if quests != null else 0):
		if not entry.get("current", false) and not RideLog.meaningful(entry):
			continue
		var names: Array[String] = []
		var locations: Array[Dictionary] = []
		for id: String in entry.places:
			var place := world.place(id) if world != null else {}
			if not place.is_empty():
				names.append(str(place.get("name", "")))
				locations.append({id = id, name = str(place.get("name", ""))})
		var distance: float = entry.bike + entry.foot
		out.append({current = entry.get("current", false),
			title = ("Сейчас" if entry.get("current", false) else RideLog.date_text(entry.start)),
			summary = "%s · %s" % [Util.distance_text(distance), RideLog.duration_text(entry.time)],
			bike = entry.bike, foot = entry.foot, time = entry.time, alt = entry.alt, photos = entry.photos,
			quests = entry.quests, places = names, locations = locations, legs = entry.legs, bounds = RideLog.bounds(entry),
			start = entry.start, end = entry.end})
	return out


## Место текущего шага задания (метка на компасе и картах) или пусто
func quest_place() -> Dictionary:
	return {} if quests == null else quests.marker()


## Цвет вида активного задания
func quest_color() -> Color:
	return GOLD if quests == null or quests.active.is_empty() else Quests.KINDS[quests.active.kind].color


## Вид активного задания или пусто
func quest_kind() -> String:
	return "" if quests == null or quests.active.is_empty() else quests.active.kind


## 11.9: счётчик задания под мини-картой — вид и название, текущий шаг с расстоянием, шаг из скольких, груз
func _build_tracker() -> PanelContainer:
	var panel := PanelContainer.new()
	# 19.11.2026: левая колонка под сведениями о месте, той же ширины; место по высоте задаёт _layout_left_column
	panel.offset_left = 18
	panel.offset_right = 300
	panel.offset_top = 18
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", HudStyle.panel(HudStyle.SURFACE, HudStyle.BORDER, 13, Vector2(12, 10)))
	var box := VBoxContainer.new()
	_tracker_content = box
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)
	var head := HBoxContainer.new()
	_tracker_head = head
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_theme_constant_override("separation", 7)
	box.add_child(head)
	var badge := PanelContainer.new()
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.add_theme_stylebox_override("panel", HudStyle.panel(HudStyle.RECESS, HudStyle.BORDER, 6, Vector2(5, 5), false))
	head.add_child(badge)
	_tracker_icon = UiIcons.rect(null, 15)
	badge.add_child(_tracker_icon)
	_tracker_kind = _tracker_label(head, 12, HudStyle.MINT)
	_tracker_kind.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tracker_count = _tracker_label(head, 12, HudStyle.MUTED)
	_tracker_count.autowrap_mode = TextServer.AUTOWRAP_OFF
	_tracker_title = _tracker_label(box, 18, HudStyle.CREAM)
	_tracker_step = _tracker_label(box, 13, HudStyle.MUTED)
	_tracker_note_row = HBoxContainer.new()
	_tracker_note_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tracker_note_row.add_theme_constant_override("separation", 6)
	_tracker_note_icon = UiIcons.rect(UiIcons.BAG, 14, HudStyle.AMBER)
	_tracker_note_row.add_child(_tracker_note_icon)
	_tracker_note = _tracker_label(_tracker_note_row, 12, HudStyle.AMBER)
	_tracker_note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tracker_note_row.hide()
	box.add_child(_tracker_note_row)
	_tracker_progress = Control.new()
	_tracker_progress.custom_minimum_size.y = 4
	_tracker_progress.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_tracker_progress)
	_tracker_progress.draw.connect(_draw_tracker_progress)
	_tracker_progress.resized.connect(_tracker_progress.queue_redraw)
	_tracker_series = _tracker_label(box, 12, Quests.KINDS.obelisks.color)
	panel.visible = false
	return panel


func _tracker_label(box: BoxContainer, font_size: int, color: Color) -> Label:
	var label := Label.new()
	HudStyle.label(label, font_size, color)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(label)
	return label


func _draw_tracker_progress() -> void:
	if _step_count == 0:
		return
	var gap := 4.0
	var width := (_tracker_progress.size.x + gap) / _step_count
	for i in _step_count:
		var color := HudStyle.RECESS
		if i < _step_index:
			color = quest_color().lerp(HudStyle.RECESS, 0.35)
		elif i == _step_index:
			color = quest_color()
		_tracker_progress.draw_rect(Rect2(Vector2(i * width, 0), Vector2(maxf(1.0, width - gap), 3.0)), color)


## Новый шаг подсвечивает карточку и обновляет метки на компасе и карте.
func quest_changed() -> void:
	update_tracker()
	sync_map_places() # взятое задание называет свои места
	if is_node_ready():
		compass.queue_redraw()
		_sync_minimap_destinations()
		_sync_map_goal()
	if not tracker.visible:
		return
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	# 19.11.2026: вспышка цветом задания и короткий импульс масштаба; затухание мягкое, а не линейное
	tracker.modulate = Color.WHITE.lerp(quest_color(), 0.35) * 1.15
	tracker.pivot_offset = tracker.size * 0.5
	tracker.scale = Vector2.ONE * 1.03
	_flash_tween = create_tween().set_parallel(true)
	_flash_tween.tween_property(tracker, "scale", Vector2.ONE, 0.24).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_flash_tween.tween_property(tracker, "modulate", Color.WHITE, 0.8).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


## Перерисовать счётчик задания (игрок в px, pz)
func update_tracker() -> void:
	if tracker == null:
		return
	var title := ""
	var line := ""
	var note := ""
	var kind := ""
	_step_count = 0
	_step_index = 0
	if quests != null and not quests.active.is_empty():
		var q := quests.active
		title = q.title
		kind = Quests.KINDS[q.kind].title
		_tracker_icon.texture = UiIcons.quest(q.kind)
		_tracker_icon.modulate = quest_color()
		line = quests.step_text(quests.step())
		_step_count = q.steps.size()
		_step_index = q.step
		if quests.cargo:
			# 19.11.2026: хрупкий груз — предупреждение (видно и в лёгком виде), обычная сумка — пометка
			var fragile: bool = q.kind == "fragile"
			note = ("Хрупкий груз · цел на %d %%" % quests.cargo_hp) if fragile else "сумка за спиной"
			_tracker_note_icon.texture = UiIcons.ALERT if fragile else UiIcons.BAG
			_tracker_note_icon.modulate = HudStyle.AMBER if fragile else HudStyle.MUTED
			_tracker_note.add_theme_color_override("font_color", HudStyle.AMBER if fragile else HudStyle.MUTED)
		_tracker_kind.add_theme_color_override("font_color", quest_color())
	var series := quests.series_progress() if quests != null else Vector2i.ZERO
	var side := PackedStringArray()
	if series.y > 0:
		side.append("Летопись обелисков: %d из %d" % [series.x, series.y])
	if quests != null:
		side.append_array(quests.thanks_lines()) # 18.11.2026: ремонт по пути — где ждут с благодарностью
	_set_optional_text(_tracker_series, "\n".join(side))
	_tracker_head.visible = not title.is_empty()
	_tracker_progress.visible = not title.is_empty()
	_tracker_kind.text = kind
	_tracker_count.text = "%d / %d" % [_step_index + 1, _step_count] if _step_count > 0 else ""
	_tracker_title.text = title
	_set_optional_text(_tracker_step, line)
	_set_optional_text(_tracker_note, note)
	_tracker_note_row.visible = _tracker_note.visible
	_tracker_progress.queue_redraw()
	_tracker_compact = -1
	_apply_reveal()


## 19.11.2026: в лёгком виде у трекера остаются вид задания, шаг и полоска шагов (и хрупкий груз);
## название, серия обелисков и благодарности — в полной сводке
func _set_tracker_compact(compact: bool) -> void:
	if _tracker_compact == int(compact):
		return
	_tracker_compact = int(compact)
	_tracker_title.visible = not compact and not _tracker_title.text.is_empty()
	_tracker_series.visible = not compact and not _tracker_series.text.is_empty()
	_tracker_note_row.visible = not _tracker_note.text.is_empty() 		and (not compact or _tracker_note.text.begins_with("Хрупкий"))


## Курс на точку (x, z в метрах) от игрока — в тех же единицах, что yaw: 0 — север, PI/2 — запад
func heading_to(x: float, z: float) -> float:
	return atan2(-(x - px), -(z - pz))


## 11.8: с фотоаппаратом у глаз (GameWorld.photo) видны только рамка видоискателя и сообщения
func set_photo_mode(on: bool) -> void:
	if _photo_mode == on:
		return
	_photo_mode = on
	_apply_reveal()


## Контекстная подсказка у прицела видна отдельно от сводки.
func summary_visible() -> bool:
	return _revealed and _summary_allowed()


## Линия навигации видна в лёгком и полном виде
func navigation_visible() -> bool:
	return view_mode != View.HIDDEN and _summary_allowed()


func _summary_allowed() -> bool:
	return is_visible_in_tree() and not _photo_mode and not _overlay_open() and not _summary_blocked


## 19.11.2026: окна поверх игры — карта, доска поселения, «Путешествие», табличка. Под ними сводка, прибор
## и сообщения не видны, а Tab не переключает вид вслепую (раньше журнал и табличка сюда не входили)
func _overlay_open() -> bool:
	return settlement_panel.visible \
		or (journal_panel != null and journal_panel.visible) or (plaque_panel != null and plaque_panel.visible)


func set_summary_blocked(blocked: bool) -> void:
	if _summary_blocked != blocked:
		_summary_blocked = blocked
		_apply_reveal()


func _apply_reveal() -> void:
	var allowed := _summary_allowed()
	var alpha := smoothstep(0.0, 1.0, _summary_progress) if allowed else 0.0
	compass.visible = alpha > 0.0
	compass.modulate.a = alpha
	var map_alpha := maxf(alpha, LIGHT_ALPHA * smoothstep(0.0, 1.0, _light)) if allowed else 0.0
	minimap.visible = map_alpha > 0.0
	minimap.modulate.a = map_alpha
	_info_panel.visible = alpha > 0.0 and not info.text.is_empty()
	_info_panel.modulate.a = alpha
	var quest_on := not _tracker_title.text.is_empty()
	var tracker_alpha := maxf(alpha, map_alpha if quest_on else 0.0)
	tracker.visible = tracker_alpha > 0.0 and (quest_on or (alpha > 0.0 and not _tracker_series.text.is_empty()))
	if tracker.visible:
		_set_tracker_compact(alpha < 0.5)
		# карточка сама не сжимается, когда строки прячутся или короче переносятся; ширина задана отступами
		var tracker_height := tracker.get_combined_minimum_size().y
		if tracker.size.y > tracker_height + 0.5:
			tracker.size = Vector2(tracker.size.x, tracker_height)
	# modulate оставлен вспышке задания. Для затухания используем родительский цвет панели и её строк.
	tracker.self_modulate.a = tracker_alpha
	_tracker_content.modulate.a = tracker_alpha
	_layout_left_column()
	var overlay := _overlay_open()
	var urgent: bool = _hint_urgent and not _photo_mode and not overlay
	hint.visible = (alpha > 0.0 or urgent) and hint.get_child_count() > 0
	hint.modulate.a = 1.0 if urgent else alpha
	prompt.visible = is_visible_in_tree() and not _photo_mode and not overlay \
		and (not _summary_blocked or _hint_urgent) and prompt.get_child_count() > 0
	_reticle.visible = alpha > 0.0 or prompt.visible
	_reticle.modulate.a = 1.0 if prompt.visible else alpha
	var aimed := prompt.visible and _prompt_aimed
	if _reticle_on_target != aimed:
		_reticle_on_target = aimed
		_animate_reticle()
	_repair.self_modulate.a = 0.0 if _photo_mode or overlay else 1.0
	var show_switch := false
	if allowed and (view_mode == View.HIDDEN or _summary_hint_left > 0.0):
		var key := controls.label(&"show_hud")
		show_switch = not key.is_empty()
		if show_switch:
			var action: String = {View.LIGHT: "вся сводка", View.FULL: "скрыть сводку", View.HIDDEN: "показать сводку"}[view_mode]
			var caption := "%s · %s" % [key, action]
			if _summary_hint.text != caption:
				_summary_hint.text = caption
				_summary_switch.reset_size()
			_summary_switch.modulate.a = 1.0 if view_mode == View.HIDDEN else smoothstep(0.0, 0.5, _summary_hint_left)
	_summary_hint.visible = show_switch
	_summary_switch.visible = show_switch


func note_interaction_target(id: String) -> void:
	if id == _aim_id:
		return
	var switching := not _aim_id.is_empty()
	_aim_id = id
	if id.is_empty() or not _reticle_on_target:
		return
	interaction_audio.play(&"reticle_target_lock")
	if switching:
		_reticle_open = minf(_reticle_open, 0.72)
		_animate_reticle()


func deny_placement() -> void:
	interaction_audio.play(&"error_deny")
	UiAudio.shake(prompt, 5.0)


func _animate_reticle() -> void:
	if _reticle_tween != null and _reticle_tween.is_valid():
		_reticle_tween.kill()
	_reticle_tween = _reticle.create_tween()
	var end := 1.0 if _reticle_on_target else 0.0
	_reticle_tween.tween_method(_set_reticle_open, _reticle_open, end, 0.11) \
		.set_trans(Tween.TRANS_BACK if _reticle_on_target else Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


func _set_reticle_open(amount: float) -> void:
	_reticle_open = amount
	_reticle.queue_redraw()


func _draw_reticle() -> void:
	var center := _reticle.size * 0.5
	var corners_alpha := clampf(_reticle_open, 0.0, 1.0)
	if corners_alpha < 1.0:
		_reticle.draw_circle(center, 3.2, Color(HudStyle.SURFACE, 0.85 * (1.0 - corners_alpha)), true, -1, true)
		_reticle.draw_circle(center, 1.6, Color(HudStyle.CREAM, 1.0 - corners_alpha), true, -1, true)
	if corners_alpha <= 0.0:
		return
	for x: float in [-1.0, 1.0]:
		for y: float in [-1.0, 1.0]:
			var corner := center + Vector2(x, y) * lerpf(2.0, 8.0, _reticle_open)
			var arm := 4.0 * corners_alpha
			var points := PackedVector2Array([corner - Vector2(x * arm, 0), corner, corner - Vector2(0, y * arm)])
			_reticle.draw_polyline(points, Color(HudStyle.SURFACE, corners_alpha), 4.0, true)
			_reticle.draw_polyline(points, Color(HudStyle.CREAM, corners_alpha), 1.5, true)


## Подсказки внизу и у прицела — чипы [клавиша] действие (пустой список — скрыты).
## urgent — нижние видно и без Tab (падение: как восстановиться)
func set_hints(bottom: Array, near: Array, urgent := false, aimed := true) -> void:
	if _hint_items == bottom and _prompt_items == near and _hint_urgent == urgent and _prompt_aimed == aimed:
		return
	var urgency_changed := _hint_urgent != urgent
	if _hint_items != bottom or urgency_changed:
		_hint_items = bottom.duplicate()
		_fill_chips(hint, bottom, _warning_style if urgent else _hint_style)
	if _prompt_items != near or urgency_changed:
		_prompt_items = near.duplicate()
		_fill_chips(prompt, near, _warning_style if urgent else _prompt_style)
	_hint_urgent = urgent
	_prompt_aimed = aimed
	_apply_reveal()


## 14.0: выносливость 0..1; exhausted — опустела и ещё не восстановилась до Stamina.RECOVERED.
## 14.2: state — Stamina.State: трата ниже LOW пульсирует и затемняет края, накат подсвечен
func set_stamina(value: float, exhausted: bool, state: Stamina.State) -> void:
	_ride.set_stamina(value, exhausted, state, _gauges_allowed())
	# затемнение краёв: параметр шейдера — только когда меняется (обычно он 0 и узел скрыт)
	var strength := _ride.warning * 0.4
	if strength != _vignette_strength:
		_vignette_strength = strength
		var mat: ShaderMaterial = _vignette.material
		mat.set_shader_parameter("strength", strength)
	# 19.11.2026: под окном поверх игры гаснет сразу, а не догорает ~0,2 с поверх карты
	var vignette_on := _ride.warning > 0.01 and _gauges_allowed()
	if _vignette.visible != vignette_on:
		_vignette.visible = vignette_on
	_show_ride()


## Скорость и тормоз велосипеда для прибора движения
func set_brakes(bike: BikeRide) -> void:
	_ride.set_ride(bike, _gauges_allowed())
	_show_ride()


func _gauges_allowed() -> bool:
	return not _photo_mode and not _overlay_open() and not _summary_blocked


## Активное управление удерживает прибор, после отпускания отсчитывается задержка.
func set_ride_activity(active: bool) -> void:
	_ride_activity = active


func pulse_pump() -> void:
	if view_mode == View.HIDDEN or not _summary_allowed():
		return
	_ride.pulse_pump()
	_ride_peek_left = maxf(_ride_peek_left, 0.5)


func _tick_ride_peek(delta: float) -> void:
	if view_mode != View.LIGHT or not _summary_allowed():
		_ride_activity = false
		_ride_peek_left = 0.0
		_ride_peek = 0.0
		return
	if _ride_activity:
		_ride_peek_left = RIDE_PEEK_HOLD
	else:
		var held_for := minf(_ride_peek_left, delta)
		_ride_peek_left = maxf(0.0, _ride_peek_left - delta)
		if _ride_peek_left <= 0.0:
			# Затухание начинается только после истечения задержки, даже при длинном кадре.
			_ride_peek = move_toward(_ride_peek, 0.0, (delta - held_for) / RIDE_PEEK_OUT)
			return
	var target := 1.0 if _ride_peek_left > 0.0 else 0.0
	_ride_peek = move_toward(_ride_peek, target, delta / (RIDE_PEEK_IN if target > _ride_peek else RIDE_PEEK_OUT))


## Срочные предупреждения и полная сводка имеют приоритет над временным показом.
func _show_ride() -> void:
	var urgent := _ride.stamina_urgent() or _ride.brake_urgent()
	var alpha := maxf(smoothstep(0.0, 1.0, _summary_progress), smoothstep(0.0, 1.0, _ride_peek))
	_ride.visible = _gauges_allowed() and (alpha > 0.0 or urgent)
	_ride.modulate.a = 1.0 if urgent else alpha


func _fill_chips(row: Container, items: Array, style: StyleBoxFlat) -> void:
	for child in row.get_children():
		row.remove_child(child)
		child.queue_free()
	for item: Array in items:
		if str(item[0]).is_empty():
			continue
		var action := PanelContainer.new()
		action.mouse_filter = Control.MOUSE_FILTER_IGNORE
		action.add_theme_stylebox_override("panel", style)
		row.add_child(action)
		var pair := HBoxContainer.new()
		pair.add_theme_constant_override("separation", 7)
		pair.mouse_filter = Control.MOUSE_FILTER_IGNORE
		action.add_child(pair)
		var chip := PanelContainer.new()
		chip.add_theme_stylebox_override("panel", _key_style)
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var key := Label.new()
		key.text = str(item[0])
		HudStyle.label(key, 13, HudStyle.MINT)
		chip.add_child(key)
		pair.add_child(chip)
		var what := Label.new()
		what.text = str(item[1])
		HudStyle.label(what, 15 if row == prompt else 13)
		pair.add_child(what)


## Где стоит велосипед (метры) и показывать ли его на картах
func set_bike(x: float, z: float, shown: bool) -> void:
	var changed := shown != bike_shown or (shown and bike_pos != Vector2(x, z))
	bike_pos = Vector2(x, z)
	bike_shown = shown
	if changed:
		minimap.set_bike(bike_pos if shown else Vector2.INF)
		big_map.set_bike(bike_pos if shown else Vector2.INF)


## Пока одно уведомление на экране, следующие ждут в очереди,
## чтобы не затирать друг друга (например, сразу два открытия поселений)
func toast(text: String, kind: StringName = &"info") -> void:
	if text.is_empty() or _repeated(text, kind):
		return
	if _toast_left > 0.0:
		# Одинаковое событие может прийти повторно, пока другое сообщение стоит между ним и очередью.
		# Не показываем его второй раз после опустошения очереди.
		if toast_label.text == text or _toast_queue.has(text):
			return
		_toast_queue.append(text)
		_toast_kinds.append(kind)
		_trim_toast_queue()
		return
	_show_toast(text, kind)


## Контекстное предупреждение идёт следующим, сохраняя текущий кадр и остальные события.
func toast_now(text: String, kind: StringName = &"info") -> void:
	if _repeated(text, kind):
		return
	if _toast_left <= 0.0:
		toast(text, kind)
	elif not text.is_empty() and toast_label.text != text:
		var queued := _toast_queue.find(text)
		if queued >= 0:
			_toast_queue.remove_at(queued)
			if queued < _toast_kinds.size():
				_toast_kinds.remove_at(queued)
		_toast_queue.insert(0, text)
		_toast_kinds.insert(0, kind)
		_trim_toast_queue()


## 19.11.2026: переполненная очередь теряет самое неважное (из равных — самое старое), а не последнее пришедшее:
## прежде resize срезал хвост, и «Задание выполнено» после нескольких открытий мест пропадало
func _trim_toast_queue() -> void:
	while _toast_queue.size() > TOAST_QUEUE:
		var drop := 0
		for i in _toast_queue.size():
			if _toast_rank(_toast_kinds[i]) < _toast_rank(_toast_kinds[drop]):
				drop = i
		_toast_queue.remove_at(drop)
		_toast_kinds.remove_at(drop)


static func _toast_rank(kind: StringName) -> int:
	match kind:
		&"quest", &"warning": return 2
		&"discovery", &"album": return 1
	return 0


## 19.11.2026: сообщения, пролежавшие под картой или паузой дольше TOAST_STALE, не всплывают после неё:
## остаются только задания (их итог важен и потом), остальное устарело
func _drop_stale_toasts() -> void:
	for i in range(_toast_queue.size() - 1, -1, -1):
		if _toast_kinds[i] != &"quest":
			_toast_queue.remove_at(i)
			_toast_kinds.remove_at(i)
	if _toast_left > 0.0 and _toast_kind != &"quest":
		_toast_left = 0.0
		if _toast_queue.is_empty():
			$Toast.hide()
		else:
			var next := _toast_queue[0]
			var next_kind: StringName = _toast_kinds[0]
			_toast_queue.remove_at(0)
			_toast_kinds.remove_at(0)
			_show_toast(next, next_kind)


## 19.11.2026: то же сообщение, показанное меньше TOAST_REPEAT секунд назад (или стоящее сейчас на экране), не повторяется.
## Предупреждения — ответ на действие игрока (сесть, сфотографировать): их повтор по времени не глушится
func _repeated(text: String, kind: StringName) -> bool:
	if _toast_left > 0.0 and toast_label.text == text:
		return true
	if kind == &"warning":
		return false
	var shown: int = _toast_seen.get(text, -1)
	return shown >= 0 and Time.get_ticks_msec() - shown < TOAST_REPEAT * 1000.0


func _show_toast(text: String, kind: StringName = &"info") -> void:
	toast_label.text = text
	var now := Time.get_ticks_msec()
	if _toast_seen.size() > 32:
		for key: String in _toast_seen.keys():
			if now - int(_toast_seen[key]) >= TOAST_REPEAT * 1000.0:
				_toast_seen.erase(key)
	_toast_seen[text] = now
	_apply_toast_style(kind, text)
	_toast_chime(kind, text)
	_fit_toast()
	$Toast.modulate.a = 0.0
	_toast_left = TOAST_TIME
	_toast_time.value = 1.0
	_animate_toast(0.0)


## 20.11: тихий отклик путешествия: открытие места, снимок в альбом и шаг задания — кварта, выполненное задание —
## неспешное трезвучие; предупреждения и справка звучат как прежде (без звука)
func _toast_chime(kind: StringName, text: String) -> void:
	if interaction_audio == null:
		return
	if kind == &"quest" and (text.begins_with("Задание выполнено") or text.begins_with("Награды")):
		interaction_audio.play(&"quest_complete")
	elif kind == &"discovery" or kind == &"album" or kind == &"quest":
		interaction_audio.play(&"discovery_chime")


func _apply_toast_style(kind: StringName, text: String) -> void:
	var accent := HudStyle.MUTED
	var tex: Texture2D = UiIcons.INFO
	match kind:
		&"discovery":
			accent = HudStyle.MINT
			tex = UiIcons.QUESTS.visit
		&"album":
			accent = HudStyle.AMBER
			tex = UiIcons.ALBUM
		&"warning":
			accent = HudStyle.RED
			tex = UiIcons.ALERT
		&"quest":
			if text.begins_with("Задание выполнено") or quests == null or quests.active.is_empty():
				accent = HudStyle.MINT
				tex = UiIcons.CHECK
			else:
				accent = quest_color()
				tex = UiIcons.quest(quests.active.kind)
	_toast_reward = _toast_points_pattern.search(text) != null
	if _toast_reward:
		tex = UiIcons.reward_token()
	_toast_kind = kind
	_toast_accent = accent
	if _toast_panel_style != null:
		_toast_panel_style.border_color = Color(accent, 0.9)
		$Toast.queue_redraw()
	if _toast_fill_style != null:
		_toast_fill_style.bg_color = accent
		_toast_fill_style.border_color = accent
	if _toast_icon != null:
		_toast_icon.texture = tex
		_toast_icon.modulate = HudStyle.AMBER if _toast_reward else accent


func _animate_toast(age: float) -> void:
	var panel: PanelContainer = $Toast
	var appear := clampf(age / 0.14, 0.0, 1.0)
	panel.scale = Vector2.ONE * Tween.interpolate_value(0.96, 0.04, appear, 1.0, Tween.TRANS_CUBIC, Tween.EASE_OUT)
	_toast_flash = smoothstep(0.0, 0.10, age) * (1.0 - smoothstep(0.10, 0.30, age))
	panel.queue_redraw()
	_toast_icon.pivot_offset = _toast_icon.size * 0.5
	var reward_pop := sin(PI * age / 0.32) if _toast_reward and age < 0.32 else 0.0
	_toast_icon.scale = Vector2.ONE * (1.0 + reward_pop * 0.28)


func _draw_toast_accent() -> void:
	if _toast_flash > 0.0:
		var panel: PanelContainer = $Toast
		var color := _toast_accent.lerp(Color.WHITE, 0.55)
		panel.draw_rect(Rect2(0.0, 6.0, 3.0, maxf(0.0, panel.size.y - 12.0)), Color(color, _toast_flash))


## 19.11.2026: левая колонка — сведения о месте, под ними задание, под ним сообщение; одна ширина LEFT_WIDTH, один зазор.
## Ширина постоянная: прежде она бралась у карточки места, и любая её смена переносила текст сообщения заново.
## Только сравнения: свойства пишутся, лишь когда что-то сдвинулось
func _layout_left_column() -> void:
	var y := LEFT_MARGIN
	if _info_panel.visible:
		y += _info_panel.size.y + LEFT_GAP
	_column(tracker, y, LEFT_WIDTH)
	if tracker.visible:
		y += tracker.size.y + LEFT_GAP
	_column($Toast, y, LEFT_WIDTH)


static func _column(panel: Control, y: float, width: float) -> void:
	if panel.position.y != y:
		panel.position.y = y
	width = maxf(width, panel.get_combined_minimum_size().x)  # иначе контейнер вернёт свой минимум и запись пойдёт каждый кадр
	if panel.size.x != width:
		panel.size.x = width


## 19.11.2026: карточка сообщения по высоте ровно под текст. Контейнер сам только растёт: после длинного сообщения
## короткое стояло в высокой пустой карточке. Ширина колонки постоянна, поэтому перенос строк известен сразу
func _fit_toast() -> void:
	var toast_panel: PanelContainer = $Toast
	var fit := Vector2(LEFT_WIDTH, 0.0)  # высота 0 — Control сам поднимет её до минимума под текст
	if toast_panel.size != fit:
		toast_panel.size = fit


static func _summary_toggle_learned() -> bool:
	var settings: GameSettings = GameContext.scope.settings
	return settings == null or settings.hud_toggle_learned


static func _learn_summary_toggle() -> void:
	if _summary_toggle_learned():
		return
	GameContext.scope.settings.hud_toggle_learned = true
	GameContext.scope.settings.save_settings()


## 20.11: хрупкий груз пострадал — значок груза в трекере вздрагивает и вспыхивает (видно и в лёгком виде)
func pulse_cargo() -> void:
	if _tracker_note_icon != null and _tracker_note_icon.is_visible_in_tree():
		UiAudio.shake(_tracker_note_icon, 4.0)
		HudStyle.pulse(_tracker_note_icon, HudStyle.RED)


func _input(event: InputEvent) -> void:
	if event.is_action_pressed(&"show_hud") and _summary_allowed():
		view_mode = {View.LIGHT: View.FULL, View.FULL: View.HIDDEN, View.HIDDEN: View.LIGHT}[view_mode]
		_revealed = view_mode == View.FULL
		_summary_hint_left = SUMMARY_HINT_TIME
		_learn_summary_toggle()


func _process(delta: float) -> void:
	_summary_progress = move_toward(_summary_progress, 1.0 if _revealed else 0.0, delta / SUMMARY_FADE)
	_light = move_toward(_light, 1.0 if view_mode == View.LIGHT else 0.0, delta / SUMMARY_FADE)
	_tick_ride_peek(delta)
	_show_ride()
	if _summary_allowed() and view_mode != View.HIDDEN:
		# 20.11: пока игрок ни разу не нажал переключатель сводки, подсказка о нём не гаснет (GameSettings.hud_toggle_learned)
		if _summary_toggle_learned():
			_summary_hint_left = maxf(0.0, _summary_hint_left - delta)
	if journal_panel.visible:
		_sync_map_hint()
	# 19.11.2026: сводка раскладывается только когда что-то сдвинулось (проявление, вид, экраны поверх игры);
	# остальные изменения отмечают _reveal_dirty
	var overlay := _overlay_open()
	var flags := int(overlay) | int(is_visible_in_tree()) << 2 | int(view_mode) << 3 | int(controls.joypad) << 5
	var key := Vector4(_summary_progress, _light, _summary_hint_left, flags)
	if _reveal_dirty or key != _reveal_key:
		_reveal_key = key
		_reveal_dirty = false
		_apply_reveal()
	var obscured: bool = not is_visible_in_tree() or overlay
	$Toast.visible = not obscured and _toast_left > 0.0
	if obscured:
		if _toast_left > 0.0 or not _toast_queue.is_empty():
			_toast_hidden_for += delta
		return
	if _toast_hidden_for > 0.0:
		if _toast_hidden_for >= TOAST_STALE:
			_drop_stale_toasts()
		_toast_hidden_for = 0.0
	if _toast_left <= 0.0:
		return
	var previous_age := TOAST_TIME - _toast_left
	_toast_left -= delta
	if previous_age < 0.32:
		_animate_toast(TOAST_TIME - _toast_left)
	_toast_time.value = clampf(_toast_left / TOAST_TIME, 0.0, 1.0)
	$Toast.modulate.a = smoothstep(0.0, 0.18, TOAST_TIME - _toast_left) * smoothstep(0.0, TOAST_FADE, _toast_left)
	if _toast_left > 0.0:
		return
	if not _toast_queue.is_empty():
		var next := _toast_queue[0]
		var next_kind: StringName = _toast_kinds[0] if not _toast_kinds.is_empty() else &"info"
		_toast_queue.remove_at(0)
		if not _toast_kinds.is_empty():
			_toast_kinds.remove_at(0)
		_show_toast(next, next_kind)
	else:
		$Toast.hide()


## Положение игрока для мини-карты и большой карты
func set_player(x: float, z: float, y: float) -> void:
	# стоит на месте и не крутит головой — карты и компас не перерисовываются каждый кадр
	if x == px and z == pz and y == yaw:
		return
	var compass_changed := y != yaw or (not goal.is_empty() or not _compass_quest.is_empty())
	px = x
	pz = z
	yaw = y
	minimap.set_view(Vector2(x, z), y)
	if compass_changed and compass.is_visible_in_tree():
		compass.queue_redraw()
	if big_map.visible:
		big_map.set_player(Vector2(x, z), y)


func _sync_minimap_destinations() -> void:
	_compass_quest = quest_place()
	minimap.set_destinations(goal, _compass_quest, quest_color(), quest_kind())


func set_clock(hour: float) -> void:
	var minute := DayCycle.clock_minute(hour)
	if minute == _clock_minute:
		return
	_clock_minute = minute
	_clock_label.text = "%02d:%02d" % [minute / 60, minute % 60]
	_clock_card.show()
	if _clock_row != null:
		_clock_row.show()


## Строки о местности под ногами: биом и дорога, высота и температура; без цели — ближайшее поселение.
## Курс, цель и задание сюда не пишутся: они на компасе (12.5+)
func update_info(p: PlayerState, _look_yaw: float, depth: float) -> void:
	var w := world
	if w == null:
		return
	var ti := w.tile_info(p.x / TILE, p.z / TILE)
	if ti.is_empty():
		return
	var terrain: Array[String] = []
	if ti.river:
		terrain.append("Брод через реку")
	var surf := PlayerState.surface(ti)
	if surf != RoadSurface.NONE:
		terrain.append("%s · %s" % ["Дорога" if ti.path == 3 else "Тропа", RoadSurface.LIST[surf].name])
	elif ti.path == 1:
		terrain.append("Звериная тропа")
	if depth > 0.3:
		terrain.append("Вода по колено")
	var temp_c := roundi(-25.0 + ti.temp * 60.0)
	var nearby := ""
	if goal.is_empty():
		var nearest = null
		var nd := INF
		for s in w.settlements:
			if not w.accessible(s.x, s.y):
				continue
			var d := Grid.hypot(s.x * TILE - p.x, s.y * TILE - p.z)
			if d < nd:
				nd = d
				nearest = s
		if nearest != null:
			nearby = "До «%s» · %s" % [nearest.name, Util.distance_text(nd)]
	_set_location(Biomes.LIST[ti.biome].name, " · ".join(terrain), roundi(p.feet), temp_c, nearby)


func _set_location(biome: String, surface: String, altitude: int, temp: int, nearby: String) -> void:
	if info.text != biome:
		info.text = biome
		_reveal_dirty = true
	_set_optional_text(_surface, surface)
	_set_optional_text(_altitude, "%d м" % altitude)
	_set_optional_text(_temperature, "%s%s °C" % ["+" if temp > 0 else "", str(temp).replace("-", "−")])
	_set_optional_text(_nearby, nearby)


static func _set_optional_text(label: Label, value: String) -> void:
	if label.text != value:
		label.text = value
	label.visible = not value.is_empty()


## Компас: градусы, лента направлений; цель и задание — значок прямо на ленте по своему курсу и расстояние рядом
## в той же строке, что градусы (18.11.2026: без свисающих под лентой плашек). За краем обзора значок прижат к краю
## ленты и приглушён, а расстояние встаёт внутрь.
class Compass extends Control:
	const HALF_ANGLE := 72.0
	const TICK := 7.5
	const INSET := 18.0
	const ROW := 17.0       # середина верхней строки: градусы, значки и расстояния
	const RULER := 31.0
	var hud: Hud
	var _back := HudStyle.panel(HudStyle.SURFACE, HudStyle.BORDER, 13)

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		if hud.world == null:
			return
		var heading := -rad_to_deg(hud.yaw)
		var mid := size.x * 0.5
		draw_style_box(_back, Rect2(Vector2.ZERO, size))
		HudStyle.centered(self, Vector2(mid, 21), "%03d°" % posmod(roundi(heading), 360), 16, HudStyle.CREAM)
		draw_line(Vector2(INSET, RULER), Vector2(size.x - INSET, RULER), Color(HudStyle.BORDER, 0.7), 1.0)
		for i in range(ceili((heading - HALF_ANGLE) / TICK), floori((heading + HALF_ANGLE) / TICK) + 1):
			var off := i * TICK - heading
			var x := _ruler_x(off)
			var direction := i % 6 == 0
			var a := lerpf(1.0, 0.36, smoothstep(HALF_ANGLE * 0.56, HALF_ANGLE, absf(off)))
			draw_line(Vector2(x, RULER), Vector2(x, RULER + (7 if direction else 4)), Color(HudStyle.MUTED, a), 1.0, true)
			if direction:
				var d := posmod(-roundi(i / 6.0), 8)
				HudStyle.centered(self, Vector2(x, 49), Hud.DIRS[d], 13 if d % 2 == 0 else 11, Color(HudStyle.CREAM, a))
		draw_colored_polygon(PackedVector2Array([Vector2(mid - 4, RULER - 5), Vector2(mid + 4, RULER - 5), Vector2(mid, RULER + 1)]), HudStyle.MINT)
		# занято: градусы посередине; расстояния не налезают на них и друг на друга
		var taken: Array[Rect2] = [Rect2(mid - 25.0, ROW - 9.0, 50.0, 18.0)]
		var quest := hud._compass_quest
		if not quest.is_empty():
			_destination(quest, hud.quest_color(), true, taken)
		if not hud.goal.is_empty():
			_destination(hud.goal, HudStyle.AMBER, false, taken)

	func _ruler_x(offset: float) -> float:
		return size.x * 0.5 + clampf(offset / HALF_ANGLE, -1.0, 1.0) * (size.x * 0.5 - INSET)

	func _destination(place: Dictionary, color: Color, quest: bool, taken: Array[Rect2]) -> void:
		var dx: float = place.x * Hud.TILE - hud.px
		var dz: float = place.y * Hud.TILE - hud.pz
		var offset := -rad_to_deg(wrapf(hud.heading_to(place.x * Hud.TILE, place.y * Hud.TILE) - hud.yaw, -PI, PI))
		var x := _ruler_x(offset)
		var inside := absf(offset) <= HALF_ANGLE
		var tint := color if inside else color.lerp(HudStyle.MUTED, 0.42)
		draw_line(Vector2(x, ROW + 7.5), Vector2(x, RULER), Color(tint, 0.8), 1.5, true)
		var text := Util.distance_text(Vector2(dx, dz).length())
		var font := ThemeDB.fallback_font
		var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
		# сторона подписи: наружу от середины, если там свободно, иначе внутрь; в пределах ленты
		var right := Rect2(x + 10.0, ROW - 8.0, width, 16.0)
		var left := Rect2(x - 10.0 - width, ROW - 8.0, width, 16.0)
		var sides: Array[Rect2] = [right, left]
		if x < size.x * 0.5:
			sides.reverse()
		var bounds := Rect2(6.0, 0.0, size.x - 12.0, size.y)
		var chosen: Rect2 = sides[0] if bounds.encloses(sides[0]) else sides[1]
		var free := false
		for side: Rect2 in sides:
			if bounds.encloses(side) and not taken.any(func(r: Rect2) -> bool: return r.intersects(side)):
				chosen = side
				free = true
				break
		# обе стороны заняты (цель и задание в одном курсе, чаще у края ленты) — встать дальше соседней подписи
		# со своим значком у подписи, чтобы было видно, чьё это расстояние
		var side := signf(chosen.position.x - x)
		var moved := false
		for attempt in 3:
			if free:
				break
			var next := Rect2(chosen.position + Vector2(side * (width + 24.0), 0.0), chosen.size)
			if not bounds.encloses(next):
				break
			chosen = next
			moved = true
			free = not taken.any(func(r: Rect2) -> bool: return r.intersects(next))
		taken.append(chosen.grow_individual(18.0 if moved and side > 0.0 else 0.0, 0.0, 18.0 if moved and side < 0.0 else 0.0, 0.0))
		# сдвинутая подпись несёт значок с собой: на курсе уже стоит значок соседа
		_mark(Vector2(chosen.end.x + 9.0 if side < 0.0 else chosen.position.x - 9.0, ROW) if moved else Vector2(x, ROW), quest, tint)
		draw_string(font, Vector2(chosen.position.x, ROW + 4.5), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, tint)

	## Значок места: иконка вида задания или звезда цели поверх тёмного диска
	func _mark(at: Vector2, quest: bool, tint: Color) -> void:
		draw_circle(at, 8.0, HudStyle.SURFACE, true, -1.0, true)
		var icon := UiIcons.quest_small(hud.quest_kind()) if quest else UiIcons.map_icon("goal")
		draw_texture_rect(icon, Rect2(at - Vector2.ONE * 6.5, Vector2.ONE * 13.0), false, tint)


func begin_repair() -> void:
	_repair.begin()


## Ремонт: доля удержания 0..1.
func set_repair(value: float) -> void:
	_repair.set_value(value)


func pulse_repair(pitch: float) -> void:
	interaction_audio.play(&"repair_work", pitch)
	_repair.pulse()


func cancel_repair() -> void:
	interaction_audio.play(&"repair_reset")
	_repair.cancel()


func finish_repair() -> void:
	interaction_audio.play(&"repair_done")
	_repair.finish()


## 18.11.2026: кольцо ремонта — растёт, пока игрок удерживает «взаимодействие» у сломанного объекта задания
class RepairArc extends Control:
	const DIAMETER := 64.0
	var value := 0.0
	var _flash := 0.0
	var _motion: Tween

	func begin() -> void:
		reset()
		scale = Vector2.ONE * 0.88
		show()
		_motion = create_tween()
		_motion.tween_property(self, "scale", Vector2.ONE, 0.10).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

	func set_value(v: float) -> void:
		if is_equal_approx(v, value):
			return
		value = v
		queue_redraw()

	func pulse() -> void:
		_replace_motion()
		_motion.tween_property(self, "scale", Vector2.ONE * 1.02, 0.055)
		_motion.tween_property(self, "scale", Vector2.ONE * 0.98, 0.065)
		_motion.tween_property(self, "scale", Vector2.ONE, 0.075)

	func cancel() -> void:
		_replace_motion()
		_motion.set_parallel(true)
		_motion.tween_method(set_value, value, 0.0, 0.18).set_ease(Tween.EASE_OUT)
		_motion.tween_property(self, "modulate:a", 0.0, 0.18)
		_motion.chain().tween_callback(_hide_arc)

	func finish() -> void:
		set_value(1.0)
		scale = Vector2.ONE
		_replace_motion()
		_motion.set_parallel(true)
		_motion.tween_property(self, "scale", Vector2.ONE * 1.18, 0.26).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		_motion.tween_method(_set_flash, 0.0, 1.0, 0.07)
		_motion.tween_property(self, "modulate:a", 0.0, 0.20).set_delay(0.06)
		_motion.chain().tween_callback(_hide_arc)

	func reset() -> void:
		if _motion != null and _motion.is_valid():
			_motion.kill()
		_hide_arc()

	func _replace_motion() -> void:
		if _motion != null and _motion.is_valid():
			_motion.kill()
		_motion = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

	func _hide_arc() -> void:
		hide()
		scale = Vector2.ONE
		modulate.a = 1.0
		value = 0.0
		_flash = 0.0
		_motion = null
		queue_redraw()

	func _set_flash(amount: float) -> void:
		_flash = amount
		queue_redraw()

	func _draw() -> void:
		var c := size * 0.5
		HudStyle.dial_face(self, c, DIAMETER * 0.5 - 2.0, 1.0)
		draw_arc(c, 22.0, 0.0, TAU, 48, Color(HudStyle.BORDER, 0.65), 4.0, true)
		if value > 0.0:
			draw_arc(c, 22.0, -PI * 0.5, -PI * 0.5 + TAU * value, 48, HudStyle.MINT.lerp(Color.WHITE, _flash), 4.0, true)
		HudStyle.centered(self, c + Vector2(0, 4), "ремонт", 11, HudStyle.MUTED)
