class_name Hud
extends Control
const BrakeIndicator = preload("res://scripts/ui/brake_indicator.gd")
var _brakes: BrakeIndicator
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
const MINI := LocalMap.DIAMETER
const SUMMARY_FADE := 0.24
const SUMMARY_HINT_TIME := 5.0
const TOAST_TIME := 3.5 # сколько сообщение висит на экране (с)
const TOAST_FADE := 0.4 # сколько гаснет без очереди (с)
const TOAST_QUEUE := 3 # сколько сообщений ждут в очереди, старые отбрасываются
const GOLD := Color(1.0, 0.82, 0.32)  # цвет цели путешествия
const Quests = preload("res://scripts/game/quests.gd")
const UiIcons = preload("res://scripts/ui/ui_icons.gd")
const HudStyle = preload("res://scripts/ui/hud_style.gd")
## 14.2: края экрана темнеют к углам, середина не тронута; strength — от StaminaArc.warning
const VIGNETTE_CODE := """shader_type canvas_item;
uniform float strength = 0.0;
void fragment() {
	float d = length((UV - 0.5) * vec2(1.25, 1.0));
	COLOR = vec4(0.12, 0.02, 0.02, strength * smoothstep(0.42, 0.85, d));
}
"""

var world: WorldData
var map_preview: Image
var map_data: MapData
var map_journal := Journal.new()
var explore := Exploration.new()  # открытое сверху, счётчики пути и альбом (с 18.11.2026); сохранение — поле "explore"
var journal_panel  # «Путешествие»: путь и альбом
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
var _tracker_progress: Control
var _step_count := 0
var _step_index := 0
var _photo_mode := false
var _revealed := true
var _summary_blocked := false
var _summary_progress := 1.0
var _summary_hint_left := SUMMARY_HINT_TIME
var _summary_hint: Label
var _summary_switch: PanelContainer
var _reticle_on_target := false
var _hint_urgent := false # подсказка, которую видно и без Tab (падение)
var _flash_tween: Tween
var _travel_dialog: ConfirmationDialog  # 12.5+: подтверждение перемещения с большой карты
var _stamina: StaminaArc  # 14.2: дуга выносливости (14.4: в левом нижнем углу), видна, пока силы тратятся или копятся
var _vignette: ColorRect  # 14.2: затемнение краёв экрана, когда силы на исходе
var _hint_items: Array = []   # 14.2: чипы подсказок внизу и у прицела: [[клавиша, действие], ...]
var _prompt_items: Array = []
var _key_style: StyleBoxFlat
var _hint_style: StyleBoxFlat
var _prompt_style: StyleBoxFlat
var _warning_style: StyleBoxFlat
@onready var _info_panel: PanelContainer = $InfoPanel
@onready var info: Label = $InfoPanel/Rows/Header/Info
@onready var _clock_label: Label = $InfoPanel/Rows/Header/Time/Clock
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
var _toast_queue: PackedStringArray = []
var _clock_minute := -1

# Состояние игрока для отрисовки карт
var px := 0.0
var pz := 0.0
var yaw := 0.0
var visited := {}
var bike_pos := Vector2.ZERO
var bike_shown := false


func _ready() -> void:
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
	move_child(tracker, compass.get_index() + 1)

	big_map = Atlas.new()
	big_map.journal = map_journal
	big_map.set_anchors_preset(Control.PRESET_FULL_RECT)
	big_map.mouse_filter = Control.MOUSE_FILTER_IGNORE
	big_map.visible = false
	add_child(big_map)
	var close_map := Button.new()
	close_map.text = "×"
	close_map.tooltip_text = "Закрыть карту"
	close_map.accessibility_name = "Закрыть карту"
	close_map.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	close_map.offset_left = -60
	close_map.offset_right = -16
	close_map.offset_top = 12
	close_map.offset_bottom = 56
	close_map.pressed.connect(func() -> void: map_close_requested.emit())
	big_map.add_child(close_map)
	big_map.move_child(close_map, 0)
	big_map.place_selected.connect(_select_map_goal)
	big_map.marker_requested.connect(func(at: Vector2) -> void: _select_map_goal(marker_goal(at)))
	settlement_panel = preload("res://scripts/ui/settlement_panel.gd").new()
	add_child(settlement_panel)
	journal_panel = preload("res://scripts/ui/journal_panel.gd").new()
	add_child(journal_panel)
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
	# 14.4: в левом нижнем углу, а не у прицела
	_stamina = StaminaArc.new()
	_stamina.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_stamina.offset_left = 18
	_stamina.offset_right = 18 + StaminaArc.DIAMETER
	_stamina.offset_top = -18 - StaminaArc.DIAMETER
	_stamina.offset_bottom = -18
	_stamina.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_stamina)
	move_child(_stamina, big_map.get_index())
	_brakes = BrakeIndicator.new()
	_brakes.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_brakes.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_brakes.offset_left = 102
	_brakes.offset_right = 102 + BrakeIndicator.DIAMETER
	_brakes.offset_top = -18 - BrakeIndicator.DIAMETER
	_brakes.offset_bottom = -18
	_brakes.hide()
	add_child(_brakes)
	move_child(_brakes, big_map.get_index())
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
	_info_panel.add_theme_stylebox_override("panel", HudStyle.panel(HudStyle.SURFACE, HudStyle.BORDER, 13, Vector2(14, 10)))
	HudStyle.label(info, 20)
	var clock_card := _clock_label.get_parent() as PanelContainer
	clock_card.add_theme_stylebox_override("panel", HudStyle.panel(HudStyle.RECESS, HudStyle.BORDER, 6, Vector2(8, 3), false))
	HudStyle.label(_clock_label, 14, HudStyle.MINT)
	HudStyle.label(_surface, 13, HudStyle.MUTED)
	HudStyle.label(_altitude, 17)
	HudStyle.label(_temperature, 17)
	HudStyle.label(_nearby, 13, HudStyle.MINT)
	HudStyle.label($InfoPanel/Rows/Readings/Altitude/Title, 11, HudStyle.MUTED)
	HudStyle.label($InfoPanel/Rows/Readings/Temperature/Title, 11, HudStyle.MUTED)
	$InfoPanel/Rows/Divider.color = HudStyle.BORDER
	_nearby.hide()
	_surface.hide()
	_info_panel.resized.connect(_place_toast)

	_hint_style = HudStyle.panel(HudStyle.SURFACE, HudStyle.BORDER, 8, Vector2(7, 4))
	_prompt_style = HudStyle.panel(HudStyle.SURFACE, HudStyle.MINT, 10, Vector2(8, 5))
	_warning_style = HudStyle.panel(HudStyle.SURFACE, HudStyle.AMBER, 8, Vector2(8, 5))
	_key_style = HudStyle.panel(HudStyle.RECESS, HudStyle.BORDER, 5, Vector2(6, 2), false)
	lock_hint.add_theme_stylebox_override("panel", _hint_style)
	HudStyle.label($LockHint/Text, 13, HudStyle.MUTED)
	_reticle.draw.connect(_draw_reticle)

	$Toast.add_theme_stylebox_override("panel", HudStyle.panel(HudStyle.SURFACE, HudStyle.BORDER, 11, Vector2(12, 9)))
	var icon := UiIcons.rect(UiIcons.QUESTS.visit, 17, HudStyle.MINT)
	$Toast/Stack/Line.add_child(icon)
	$Toast/Stack/Line.move_child(icon, 0)
	HudStyle.label(toast_label, 14)
	_toast_time.add_theme_stylebox_override("background", HudStyle.panel(HudStyle.RECESS, HudStyle.RECESS, 1, Vector2.ZERO, false))
	_toast_time.add_theme_stylebox_override("fill", HudStyle.panel(HudStyle.MINT, HudStyle.MINT, 1, Vector2.ZERO, false))


## Новая игра: запомнить карту мира и забыть сообщения прошлой игры
func set_world(w: WorldData, map_image: Image) -> void:
	world = w
	_clock_minute = -1
	_clock_label.get_parent().hide()
	info.text = ""
	_surface.hide()
	_nearby.hide()
	map_preview = map_image
	map_data = MapData.new(w)
	map_journal = Journal.new()
	explore = Exploration.new()
	if journal_panel != null:
		journal_panel.clear()
	minimap.set_world(w, knows, map_data)
	big_map.journal = map_journal
	big_map.set_source(map_data)
	px = NAN # первый set_player нового мира точно перерисует карты
	visited = {}
	goal = {}
	bike_shown = false
	_revealed = true
	_summary_progress = 1.0
	_summary_hint_left = SUMMARY_HINT_TIME
	_apply_reveal()
	_toast_queue.clear()
	_toast_left = 0.0
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
	explore = Exploration.new()
	if journal_panel != null:
		journal_panel.clear()
	big_map.journal = map_journal
	big_map.set_source(null)
	minimap.set_world(null)
	visited = {}
	goal = {}
	quests = null
	_summary_blocked = false
	update_tracker()
	bike_pos = Vector2.ZERO
	bike_shown = false
	_toast_queue.clear()
	_toast_left = 0.0
	$Toast.modulate.a = 0.0
	set_hints([], [])
	set_photo_mode(false)
	big_map.visible = false
	big_map.mouse_filter = Control.MOUSE_FILTER_IGNORE
	big_map.hover = {}


func set_map_visible(v: bool) -> void:
	if not v:
		_close_travel()
	else:
		big_map.prepare_player_view()
	big_map.visible = v
	# Личная карта перехватывает мышь и позволяет ставить цель.
	big_map.mouse_filter = Control.MOUSE_FILTER_STOP if v else Control.MOUSE_FILTER_IGNORE
	big_map.hover = {}
	_apply_reveal()
	if v:
		big_map.move_hint = "Колесо · масштаб     Перетащить · обзор     СКМ · к себе     Ctrl+ЛКМ · метка     %s · путешествие" % controls.label(&"journal")
		sync_map_places()
		big_map.set_player(Vector2(px, pz), yaw)


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


func map_place_count() -> int:
	return visited.size() + map_journal.read.size() + explore.revealed.size()


func sync_map_places() -> void:
	if not big_map.visible or world == null:
		return
	var known: Array = []
	var ids := map_journal.read.merged(visited).merged(explore.revealed)
	for id: String in ids:
		var place := world.place(id)
		if not place.is_empty():
			known.append(InteractionService.target(place))
	big_map.set_places(known)
	_sync_map_goal()


func _select_map_goal(place: Dictionary) -> void:
	var same: bool = place.key == goal.get("key")
	if same and place.kind == "marker":
		same = Vector2(place.x, place.y).distance_to(Vector2(goal.x, goal.y)) < 4.0
	set_goal({} if same else place)


func _sync_map_goal() -> void:
	var id: String = goal.get("key", "")
	var show_goal: bool = not goal.is_empty() and (goal.kind == "marker" or visited.has(id) or map_journal.read.has(id) or explore.revealed.has(id))
	big_map.goal = Atlas.place_at(goal) if show_goal else Vector2.INF
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
	if goal.is_empty() or not at_place(goal, x, z):
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
	return visited.has(id) or explore.revealed.has(id) or goal.get("key") == id or (quests != null and quests.known.has(id))


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
				var title: String = StageSites.TYPES[place.src.type].title if StageSites.TYPES.has(place.src.type) else "место"
				label = title.left(1).to_upper() + title.substr(1)
		if not total.has(label):
			total[label] = 0
			found[label] = 0
			order.append(label)
		total[label] += 1
		if visited.has(place.key) or explore.revealed.has(place.key) or map_journal.read.has(place.key):
			found[label] += 1
	var rows: Array = []
	for label: String in order:
		rows.append([label, found[label], total[label]])
	var pages: Array[Dictionary] = []
	for page: Dictionary in Exploration.pages():
		var entry := page.duplicate()
		entry.shot = explore.album.get(page.key, {})
		pages.append(entry)
	return {foot = explore.foot_m, bike = explore.bike_m, time = explore.play_s, alt = explore.max_alt, photos = explore.photos,
		quests = quests.done if quests != null else 0, places = rows, pages = pages, groups = Exploration.GROUPS}


## Место текущего шага задания (метка на компасе и картах) или пусто
func quest_place() -> Dictionary:
	return {} if quests == null else quests.marker()


## Цвет вида активного задания
func quest_color() -> Color:
	return GOLD if quests == null or quests.active.is_empty() else Quests.KINDS[quests.active.kind].color


## 11.9: счётчик задания под мини-картой — вид и название, текущий шаг с расстоянием, шаг из скольких, груз
func _build_tracker() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.offset_left = -288
	panel.offset_right = -18
	panel.offset_top = MINI + 30
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", HudStyle.panel(HudStyle.SURFACE, HudStyle.BORDER, 13, Vector2(12, 10)))
	var box := VBoxContainer.new()
	_tracker_content = box
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)
	var head := HBoxContainer.new()
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
	_tracker_note = _tracker_label(box, 12, HudStyle.MINT)
	_tracker_progress = Control.new()
	_tracker_progress.custom_minimum_size.y = 4
	_tracker_progress.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_tracker_progress)
	_tracker_progress.draw.connect(_draw_tracker_progress)
	_tracker_progress.resized.connect(_tracker_progress.queue_redraw)
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
	if is_node_ready():
		compass.queue_redraw()
		_sync_minimap_destinations()
		_sync_map_goal()
	if not tracker.visible:
		return
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	tracker.modulate = Color(1.12, 1.18, 1.15)
	_flash_tween = create_tween()
	_flash_tween.tween_property(tracker, "modulate", Color.WHITE, 0.8)


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
			note = "сумка за спиной"
		_tracker_kind.add_theme_color_override("font_color", quest_color())
	_tracker_kind.text = kind
	_tracker_count.text = "%d / %d" % [_step_index + 1, _step_count] if _step_count > 0 else ""
	_tracker_title.text = title
	_set_optional_text(_tracker_step, line)
	_set_optional_text(_tracker_note, note)
	_tracker_progress.queue_redraw()
	_apply_reveal()


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


func _summary_allowed() -> bool:
	return is_visible_in_tree() and not _photo_mode and not big_map.visible \
		and not settlement_panel.visible and not _summary_blocked


func set_summary_blocked(blocked: bool) -> void:
	if _summary_blocked != blocked:
		_summary_blocked = blocked
		_apply_reveal()


func _apply_reveal() -> void:
	var allowed := _summary_allowed()
	var alpha := smoothstep(0.0, 1.0, _summary_progress) if allowed else 0.0
	for node: CanvasItem in [minimap, compass]:
		node.visible = alpha > 0.0
		node.modulate.a = alpha
	_info_panel.visible = alpha > 0.0 and not info.text.is_empty()
	_info_panel.modulate.a = alpha
	_place_toast()
	tracker.visible = alpha > 0.0 and not _tracker_title.text.is_empty()
	# modulate оставлен вспышке задания. Для затухания используем родительский цвет панели и её строк.
	tracker.self_modulate.a = alpha
	_tracker_content.modulate.a = alpha
	var urgent: bool = _hint_urgent and not _photo_mode and not big_map.visible and not settlement_panel.visible
	hint.visible = (alpha > 0.0 or urgent) and hint.get_child_count() > 0
	hint.modulate.a = 1.0 if urgent else alpha
	prompt.visible = is_visible_in_tree() and not _photo_mode and not big_map.visible \
		and not settlement_panel.visible and (not _summary_blocked or _hint_urgent) and prompt.get_child_count() > 0
	_reticle.visible = alpha > 0.0 or prompt.visible
	_reticle.modulate.a = 1.0 if prompt.visible else alpha
	if _reticle_on_target != prompt.visible:
		_reticle_on_target = prompt.visible
		_reticle.queue_redraw()
	var show_switch := false
	if allowed and (not _revealed or _summary_hint_left > 0.0):
		var key := controls.label(&"show_hud")
		show_switch = not key.is_empty()
		if show_switch:
			var action := "скрыть сводку" if _revealed else "показать сводку"
			var caption := "%s · %s" % [key, action]
			if _summary_hint.text != caption:
				_summary_hint.text = caption
				_summary_switch.reset_size()
			_summary_switch.modulate.a = smoothstep(0.0, 0.5, _summary_hint_left) if _revealed else 1.0
	_summary_hint.visible = show_switch
	_summary_switch.visible = show_switch


func _draw_reticle() -> void:
	var center := _reticle.size * 0.5
	if not _reticle_on_target:
		_reticle.draw_circle(center, 3.2, Color(HudStyle.SURFACE, 0.85), true, -1, true)
		_reticle.draw_circle(center, 1.6, HudStyle.CREAM, true, -1, true)
		return
	for x: float in [-1.0, 1.0]:
		for y: float in [-1.0, 1.0]:
			var corner := center + Vector2(x, y) * 8.0
			var points := PackedVector2Array([corner - Vector2(x * 4, 0), corner, corner - Vector2(0, y * 4)])
			_reticle.draw_polyline(points, HudStyle.SURFACE, 4.0, true)
			_reticle.draw_polyline(points, HudStyle.CREAM, 1.5, true)


## Подсказки внизу и у прицела — чипы [клавиша] действие (пустой список — скрыты).
## urgent — нижние видно и без Tab (падение: как восстановиться)
func set_hints(bottom: Array, near: Array, urgent := false) -> void:
	if _hint_items == bottom and _prompt_items == near and _hint_urgent == urgent:
		return
	var urgency_changed := _hint_urgent != urgent
	if _hint_items != bottom or urgency_changed:
		_hint_items = bottom.duplicate()
		_fill_chips(hint, bottom, _warning_style if urgent else _hint_style)
	if _prompt_items != near or urgency_changed:
		_prompt_items = near.duplicate()
		_fill_chips(prompt, near, _warning_style if urgent else _prompt_style)
	_hint_urgent = urgent
	_apply_reveal()


## 14.0: выносливость 0..1; exhausted — опустела и ещё не восстановилась до Stamina.RECOVERED.
## 14.2: state — Stamina.State: трата ниже LOW пульсирует и затемняет края, накат подсвечен
func set_stamina(value: float, exhausted: bool, state: Stamina.State) -> void:
	var allowed: bool = not _photo_mode and not big_map.visible and not settlement_panel.visible and not _summary_blocked
	_stamina.set_value(value, exhausted, state, allowed)
	var urgent := state == Stamina.State.DRAIN and value < StaminaArc.LOW
	_stamina.visible = allowed and (_summary_progress > 0.0 or urgent)
	_stamina.modulate.a = 1.0 if urgent else smoothstep(0.0, 1.0, _summary_progress)
	var mat: ShaderMaterial = _vignette.material
	mat.set_shader_parameter("strength", _stamina.warning * 0.4)
	_vignette.visible = _stamina.warning > 0.01


func set_brakes(bike: BikeRide) -> void:
	var allowed: bool = not _photo_mode and not big_map.visible and not settlement_panel.visible and not _summary_blocked
	var urgent: bool = bike.brakes.risk > 0.65 or bike.brakes.skid > 0.2
	_brakes.update_state(bike, allowed and (_summary_progress > 0.0 or urgent))
	_brakes.modulate.a = 1.0 if urgent else smoothstep(0.0, 1.0, _summary_progress)


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


## Пока одно уведомление на экране, следующие ждут в очереди,
## чтобы не затирать друг друга (например, сразу два открытия поселений)
func toast(text: String) -> void:
	if text.is_empty():
		return
	if _toast_left > 0.0:
		# Одинаковое событие может прийти повторно, пока другое сообщение стоит между ним и очередью.
		# Не показываем его второй раз после опустошения очереди.
		if toast_label.text == text or _toast_queue.has(text):
			return
		_toast_queue.append(text)
		if _toast_queue.size() > TOAST_QUEUE:
			_toast_queue.resize(TOAST_QUEUE)
		return
	_show_toast(text)


## Контекстное предупреждение идёт следующим, сохраняя текущий кадр и остальные события.
func toast_now(text: String) -> void:
	if _toast_left <= 0.0:
		toast(text)
	elif not text.is_empty() and toast_label.text != text:
		var queued := _toast_queue.find(text)
		if queued >= 0:
			_toast_queue.remove_at(queued)
		_toast_queue.insert(0, text)
		if _toast_queue.size() > TOAST_QUEUE:
			_toast_queue.resize(TOAST_QUEUE)


func _show_toast(text: String) -> void:
	toast_label.text = text
	$Toast.modulate.a = 0.0
	_toast_left = TOAST_TIME
	_toast_time.value = 1.0


func _place_toast() -> void:
	var top := _info_panel.position.y + _info_panel.size.y + 10.0 if _info_panel.visible else 18.0
	if $Toast.position.y != top:
		$Toast.position.y = top


func _input(event: InputEvent) -> void:
	if event.is_action_pressed(&"show_hud") and _summary_allowed():
		_revealed = not _revealed
		_summary_hint_left = SUMMARY_HINT_TIME


func _process(delta: float) -> void:
	_summary_progress = move_toward(_summary_progress, 1.0 if _revealed else 0.0, delta / SUMMARY_FADE)
	if _summary_allowed() and _revealed:
		_summary_hint_left = maxf(0.0, _summary_hint_left - delta)
	_apply_reveal()
	var obscured: bool = not is_visible_in_tree() or big_map.visible or settlement_panel.visible
	$Toast.visible = not obscured and _toast_left > 0.0
	if obscured or _toast_left <= 0.0:
		return
	_toast_left -= delta
	_toast_time.value = clampf(_toast_left / TOAST_TIME, 0.0, 1.0)
	$Toast.modulate.a = smoothstep(0.0, 0.18, TOAST_TIME - _toast_left) * smoothstep(0.0, TOAST_FADE, _toast_left)
	if _toast_left > 0.0:
		return
	if not _toast_queue.is_empty():
		var next := _toast_queue[0]
		_toast_queue.remove_at(0)
		_show_toast(next)
	else:
		$Toast.hide()


## Положение игрока для мини-карты и большой карты
func set_player(x: float, z: float, y: float) -> void:
	# стоит на месте и не крутит головой — карты и компас не перерисовываются каждый кадр
	if x == px and z == pz and y == yaw:
		return
	px = x
	pz = z
	yaw = y
	minimap.set_view(Vector2(x, z), y)
	if compass.is_visible_in_tree():
		compass.queue_redraw()
	if big_map.visible:
		big_map.set_player(Vector2(x, z), y)


func _sync_minimap_destinations() -> void:
	minimap.set_destinations(goal, quest_place(), quest_color())


func set_clock(hour: float) -> void:
	var minute := DayCycle.clock_minute(hour)
	if minute == _clock_minute:
		return
	_clock_minute = minute
	_clock_label.text = "%02d:%02d" % [minute / 60, minute % 60]
	_clock_label.get_parent().show()


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
	_set_optional_text(_surface, surface)
	_set_optional_text(_altitude, "%d м" % altitude)
	_set_optional_text(_temperature, "%s%s °C" % ["+" if temp > 0 else "", str(temp).replace("-", "−")])
	_set_optional_text(_nearby, nearby)


static func _set_optional_text(label: Label, value: String) -> void:
	if label.text != value:
		label.text = value
	label.visible = not value.is_empty()


## Компас: градусы, лента направлений и две отдельные метки расстояния.
class Compass extends Control:
	const HALF_ANGLE := 72.0
	const TICK := 7.5
	const INSET := 18.0
	const BADGE_WIDTH := 72.0
	var hud: Hud
	var _back := HudStyle.panel(HudStyle.SURFACE, HudStyle.BORDER, 13)
	var _badge := HudStyle.panel(HudStyle.SURFACE, HudStyle.BORDER, 7, Vector2.ZERO, false)

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		if hud.world == null:
			return
		var heading := -rad_to_deg(hud.yaw)
		var mid := size.x * 0.5
		draw_style_box(_back, Rect2(Vector2.ZERO, size))
		HudStyle.centered(self, Vector2(mid, 21), "%03d°" % posmod(roundi(heading), 360), 16, HudStyle.CREAM)
		draw_line(Vector2(INSET, 31), Vector2(size.x - INSET, 31), Color(HudStyle.BORDER, 0.7), 1.0)
		for i in range(ceili((heading - HALF_ANGLE) / TICK), floori((heading + HALF_ANGLE) / TICK) + 1):
			var off := i * TICK - heading
			var x := _ruler_x(off)
			var direction := i % 6 == 0
			var a := lerpf(1.0, 0.36, smoothstep(HALF_ANGLE * 0.56, HALF_ANGLE, absf(off)))
			draw_line(Vector2(x, 31), Vector2(x, 38 if direction else 35), Color(HudStyle.MUTED, a), 1.0, true)
			if direction:
				var d := posmod(-roundi(i / 6.0), 8)
				HudStyle.centered(self, Vector2(x, 49), Hud.DIRS[d], 13 if d % 2 == 0 else 11, Color(HudStyle.CREAM, a))
		draw_colored_polygon(PackedVector2Array([Vector2(mid - 4, 26), Vector2(mid + 4, 26), Vector2(mid, 32)]), HudStyle.MINT)
		var quest := hud.quest_place()
		var qx := -INF
		if not quest.is_empty():
			qx = _destination(quest, hud.quest_color(), true, -INF)
		if not hud.goal.is_empty():
			_destination(hud.goal, HudStyle.AMBER, false, qx)

	func _ruler_x(offset: float) -> float:
		return size.x * 0.5 + clampf(offset / HALF_ANGLE, -1.0, 1.0) * (size.x * 0.5 - INSET)

	func _destination(place: Dictionary, color: Color, quest: bool, other_x: float) -> float:
		var dx: float = place.x * Hud.TILE - hud.px
		var dz: float = place.y * Hud.TILE - hud.pz
		var offset := -rad_to_deg(wrapf(hud.heading_to(place.x * Hud.TILE, place.y * Hud.TILE) - hud.yaw, -PI, PI))
		var x := _ruler_x(offset)
		var cx := clampf(x, BADGE_WIDTH * 0.5, size.x - BADGE_WIDTH * 0.5)
		var top := size.y + 6.0 + (25.0 if absf(cx - other_x) < BADGE_WIDTH else 0.0)
		var tint := color if absf(offset) <= HALF_ANGLE else color.lerp(HudStyle.MUTED, 0.42)
		draw_line(Vector2(x, size.y - 2), Vector2(x, size.y + 6), tint, 1.5, true)
		draw_style_box(_badge, Rect2(cx - BADGE_WIDTH * 0.5, top, BADGE_WIDTH, 21.0))
		var icon := Vector2(cx - BADGE_WIDTH * 0.5 + 10, top + 10.5)
		if quest:
			draw_rect(Rect2(icon - Vector2.ONE * 2.5, Vector2.ONE * 5.0), tint)
		else:
			draw_colored_polygon(PackedVector2Array([icon + Vector2(0, -4), icon + Vector2(4, 0),
				icon + Vector2(0, 4), icon + Vector2(-4, 0)]), tint)
		HudStyle.centered(self, Vector2(cx + 6.0, top + 14.5), Util.distance_text(Vector2(dx, dz).length()), 12, tint)
		return cx


## 14.2: дуга выносливости (с 14.4 — кольцо в левом нижнем углу). Появляется, пока силы тратятся или копятся, полная — гаснет.
## Засечка на Stamina.RECOVERED — с неё после истощения снова работает Shift. Белый шлейф за краем
## заливки быстро тает и показывает темп траты. Ниже LOW при трате дуга пульсирует, warning (0..1) затемняет
## края экрана; при восстановлении предупреждение гаснет быстро. Накат подсвечен холодным ореолом.
class StaminaArc extends Control:
	const DIAMETER := 76.0
	const R := 28.0
	const FROM := deg_to_rad(135.0)       # кольцо с разрывом внизу: от левого низа через верх к правому низу
	const SPAN := deg_to_rad(270.0)
	const WIDTH := 4.0
	const LOW := 0.2
	const GHOST_LAG := 1.5                # 1/с: шлейф догоняет заливку с запаздыванием — чем быстрее трата, тем он
	                                      # длиннее рывок Shift (треть дуги) тает за доли секунды
	var value := 1.0
	var exhausted := false
	var state := Stamina.State.IDLE
	var warning := 0.0                    # 0..1, сила предупреждения (виньетка, пульс)
	var _alpha := 0.0
	var _coast := 0.0                     # 0..1, ореол наката
	var _drain := 0.0                     # 14.5: 0..1, расход идёт — дуга тёплого цвета и мягко пульсирует
	var _kick := 0.0                      # 14.5: вспышка в момент, когда расход начался
	var _ghost := 1.0
	var _t := 0.0

	func set_value(v: float, tired: bool, st: Stamina.State, allowed: bool) -> void:
		var dt := get_process_delta_time()
		_t += dt
		var was_visible := _alpha > 0.01
		var active := st == Stamina.State.DRAIN or st == Stamina.State.COAST or st == Stamina.State.REST or v < 0.999
		_alpha = move_toward(_alpha, 1.0 if allowed and active else 0.0, dt * (4.0 if allowed and active else 1.5))
		_ghost = v if v >= _ghost else lerpf(_ghost, v, Util.damp(GHOST_LAG, dt))
		var low := 1.0 - smoothstep(0.05, LOW, v) if v < LOW or tired else 0.0
		# предупреждение нарастает мягко при трате и гаснет быстро, как только силы пошли в плюс
		var warn_goal := low if st == Stamina.State.DRAIN and allowed else 0.0
		warning = move_toward(warning, warn_goal, dt * (1.5 if warn_goal > warning else 5.0))
		_coast = move_toward(_coast, 1.0 if st == Stamina.State.COAST and allowed else 0.0, dt * 4.0)
		var draining := st == Stamina.State.DRAIN and allowed
		if draining and state != Stamina.State.DRAIN:
			_kick = 1.0
		_kick = maxf(0.0, _kick - dt * 2.5)
		_drain = move_toward(_drain, 1.0 if draining else 0.0, dt * (6.0 if draining else 3.0))
		value = v
		exhausted = tired
		state = st
		if was_visible or _alpha > 0.01:
			queue_redraw()

	func _arc(from: float, to: float, width: float, color: Color) -> void:
		if to - from < 0.002:
			return
		var c := size / 2.0
		draw_arc(c, R, FROM + SPAN * from, FROM + SPAN * to, 48, color, width, true)

	func _draw() -> void:
		if _alpha <= 0.01:
			return
		var a := _alpha
		var c := size / 2.0
		HudStyle.dial_face(self, c, DIAMETER * 0.5 - 2.0, a)
		_arc(0.0, 1.0, WIDTH, Color(HudStyle.BORDER, 0.65 * a))
		if _coast > 0.0:
			_arc(0.0, value, WIDTH + 5.0, Color(0.45, 0.85, 1.0, 0.20 * _coast * a))
		_arc(value, _ghost, WIDTH, Color(HudStyle.CREAM, 0.55 * a))
		var fill := HudStyle.MINT
		if exhausted:
			fill = HudStyle.RED
		elif value < LOW:
			fill = HudStyle.AMBER
		fill = fill.lerp(Color(0.6, 0.9, 1.0), _coast * 0.6)
		# 14.5: расход — тёплый оттенок и мягкий пульс, в начале расхода — вспышка шире и ярче
		if not exhausted and value >= LOW:
			fill = fill.lerp(HudStyle.AMBER, _drain * 0.55)
		fill = fill.lerp(Color.WHITE, _kick * 0.5)
		var pulse := 0.5 + 0.5 * sin(_t * 7.0)
		var spend := 0.5 + 0.5 * sin(_t * 4.5)
		fill.a = a * lerpf(lerpf(0.95, 0.75 + 0.25 * spend, _drain), 0.55 + 0.4 * pulse, warning)
		_arc(0.0, value, WIDTH + warning * pulse * 1.5 + _drain * spend * 1.0 + _kick * 3.0, fill)
		# засечка цены рывка (треть полоски): поперёк дуги, светлая с тёмной обводкой
		var ang := FROM + SPAN * Stamina.RECOVERED
		var dir := Vector2(cos(ang), sin(ang))
		var mark := Color(HudStyle.CREAM, a if exhausted or value < Stamina.RECOVERED + 0.1 else 0.6 * a)
		draw_line(c + dir * (R - 4.0), c + dir * (R + 4.0), Color(HudStyle.SURFACE, a), 3.0)
		draw_line(c + dir * (R - 3.0), c + dir * (R + 3.0), mark, 1.5, true)
		HudStyle.dial_text(self, c, value, "СИЛЫ", fill, a)
