class_name Hud
extends Control
## Интерфейс поверх 3D: сведения о местности, мини-карта, большая карта, всплывающие сообщения,
## прицел и подсказки. Прицел, панель сведений и надписи — узлы сцены main.tscn (правятся в редакторе),
## мини-карта и большая карта рисуются кодом (MiniMap, BigMap). Копия js/ui/hud.js. Подсказки внизу и у прицела меняются по тому, что игрок
## делает сейчас (GameWorld._update_hints); велосипед отмечен на картах, пока игрок не на нём.
## С 2.8 на большой карте можно выбрать цель путешествия (ЛКМ по поселению или вершине) — она видна
## только меткой на компасе вверху и на картах — и переместиться в любое из них (ПКМ; до 3.0.2 — только где уже побывали).
## С 2.9 к местам добавились крупные озёра с названиями (WorldData.lakes): открываются на берегу.
## С 12.5+ у каждого сведения одно место: курс и расстояния до цели и задания — на компасе, что делать — в
## счётчике задания, местность под ногами — в панели сведений. Перемещение с большой карты — с подтверждением.

signal travel_requested(place: Dictionary)
signal goal_changed(place: Dictionary)

const TILE := GameConfig.TILE
const DIRS := ["С", "СЗ", "З", "ЮЗ", "Ю", "ЮВ", "В", "СВ"]
const MINI := 200.0
const TOAST_TIME := 3.5 # сколько сообщение висит на экране (с)
const TOAST_FADE := 0.4 # сколько гаснет без очереди (с)
const TOAST_QUEUE := 3 # сколько сообщений ждут в очереди, старые отбрасываются
const GOLD := Color(1.0, 0.82, 0.32)  # цвет цели путешествия
const Quests = preload("res://scripts/game/quests.gd")
const UiIcons = preload("res://scripts/ui/ui_icons.gd")
const DONE_TIME := 4.0 # сколько висит «Задание выполнено» в счётчике (с)
## 14.2: края экрана темнеют к углам, середина не тронута; strength — от StaminaArc.warning
const VIGNETTE_CODE := """shader_type canvas_item;
uniform float strength = 0.0;
void fragment() {
	float d = length((UV - 0.5) * vec2(1.25, 1.0));
	COLOR = vec4(0.12, 0.02, 0.02, strength * smoothstep(0.42, 0.85, d));
}
"""

var world: WorldData
var map_tex: ImageTexture
var minimap: MiniMap
var big_map: BigMap
var compass: Compass
var settlement_panel
var goal := {}  # цель путешествия — место из places() или пусто
var quests: Quests  # 11.9: задания игры (GameWorld), счётчик под мини-картой показывает активное
var tracker: PanelContainer
var _tracker_title: Label
var _tracker_icon: TextureRect  # 12.5: пиктограмма вида задания или галочка выполненного
var _tracker_step: Label
var _tracker_note: Label
var _done_text := ""
var _done_left := 0.0
var _photo_mode := false
var _revealed := false # 12.4: мини-карта, компас, сведения, задание и подсказки видны, пока зажат Tab
var _hint_urgent := false # подсказка, которую видно и без Tab (падение)
var _banner: VBoxContainer
var _banner_title: Label
var _banner_sub: Label
var _banner_tween: Tween
var _flash_tween: Tween
var _travel_dialog: ConfirmationDialog  # 12.5+: подтверждение перемещения с большой карты
var _stamina: StaminaArc  # 14.2: дуга выносливости (14.4: в левом нижнем углу), видна, пока силы тратятся или копятся
var _vignette: ColorRect  # 14.2: затемнение краёв экрана, когда силы на исходе
var _hint_items: Array = []   # 14.2: чипы подсказок внизу и у прицела: [[клавиша, действие], ...]
var _prompt_items: Array = []
var _chip_style: StyleBoxFlat
@onready var info: Label = $InfoPanel/Info
@onready var toast_label: Label = $Toast
@onready var lock_hint: Label = $LockHint
@onready var hint: HBoxContainer = $Hint
@onready var prompt: HBoxContainer = $Prompt
var _toast_left := 0.0
var _toast_queue: PackedStringArray = []
var _toast_tween: Tween
var _places: Array = []
var _region_tex := {} # 13.9+final: картинки соседних областей для большой карты (область -> ImageTexture)
var _places_revision := -1 # доступные места обновляются при расширении территории

# Состояние игрока для отрисовки карт
var px := 0.0
var pz := 0.0
var yaw := 0.0
var visited := {}
var bike_pos := Vector2.ZERO
var bike_shown := false


func _ready() -> void:
	# мини-карта в правом верхнем углу, под надписями (как вторым узлом после панели сведений)
	minimap = MiniMap.new()
	minimap.hud = self
	minimap.anchor_left = 1.0
	minimap.anchor_right = 1.0
	minimap.offset_left = -MINI - 14
	minimap.offset_top = 14
	minimap.offset_right = -14
	minimap.offset_bottom = MINI + 14
	add_child(minimap)
	move_child(minimap, $InfoPanel.get_index() + 1)

	compass = Compass.new()
	compass.hud = self
	compass.anchor_left = 0.5
	compass.anchor_right = 0.5
	compass.offset_left = -150
	compass.offset_right = 150
	compass.offset_top = 10
	compass.offset_bottom = 38
	add_child(compass)
	move_child(compass, minimap.get_index() + 1)

	tracker = _build_tracker()
	add_child(tracker)
	move_child(tracker, compass.get_index() + 1)
	_banner = _build_banner()
	add_child(_banner)
	move_child(_banner, tracker.get_index() + 1)

	big_map = BigMap.new()
	big_map.hud = self
	big_map.set_anchors_preset(Control.PRESET_FULL_RECT)
	big_map.mouse_filter = Control.MOUSE_FILTER_IGNORE
	big_map.visible = false
	add_child(big_map)
	settlement_panel = preload("res://scripts/ui/settlement_panel.gd").new()
	add_child(settlement_panel)
	_vignette = ColorRect.new()
	_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var vignette_shader := Shader.new()
	vignette_shader.code = VIGNETTE_CODE
	_vignette.material = ShaderMaterial.new()
	_vignette.material.shader = vignette_shader
	_chip_style = StyleBoxFlat.new()
	_chip_style.bg_color = Color(0.04, 0.06, 0.1, 0.82)
	_chip_style.border_color = Color(1, 1, 1, 0.9)
	_chip_style.set_border_width_all(2)
	_chip_style.set_corner_radius_all(4)
	# светлая рамка видна на тёмном, тёмная кайма за ней — на снегу
	_chip_style.shadow_color = Color(0, 0, 0, 0.75)
	_chip_style.shadow_size = 2
	_chip_style.content_margin_left = 7
	_chip_style.content_margin_right = 7
	_chip_style.content_margin_top = 1
	_chip_style.content_margin_bottom = 1
	_vignette.visible = false
	add_child(_vignette)
	move_child(_vignette, 0)
	# 14.4: в левом нижнем углу, а не у прицела
	_stamina = StaminaArc.new()
	_stamina.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_stamina.offset_left = 18
	_stamina.offset_right = 18 + (StaminaArc.R + 12) * 2.0
	_stamina.offset_top = -18 - (StaminaArc.R + 12) * 2.0
	_stamina.offset_bottom = -18
	_stamina.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_stamina)
	move_child(_stamina, big_map.get_index())
	_apply_reveal()


## Новая игра: запомнить карту мира и забыть сообщения прошлой игры
func set_world(w: WorldData, map_image: Image) -> void:
	world = w
	map_tex = ImageTexture.create_from_image(map_image)
	_places = []
	_region_tex = {}
	if big_map != null:
		big_map.reset_view()
	px = NAN # первый set_player нового мира точно перерисует карты
	visited = {}
	goal = {}
	_done_left = 0.0
	_toast_queue.clear()
	_stop_toast_tween()
	_toast_left = 0.0
	toast_label.modulate.a = 0.0


## Выход из игры: забыть мир и карту, чтобы прошлый мир освободился, пока в меню
func clear_world() -> void:
	if settlement_panel != null:
		settlement_panel.clear()
	world = null
	_places = []
	_region_tex = {}
	map_tex = null
	visited = {}
	goal = {}
	quests = null
	_done_left = 0.0
	update_tracker()
	if _banner_tween != null and _banner_tween.is_valid():
		_banner_tween.kill()
	_banner.visible = false
	bike_pos = Vector2.ZERO
	bike_shown = false
	_toast_queue.clear()
	_stop_toast_tween()
	_toast_left = 0.0
	toast_label.modulate.a = 0.0
	set_hints([], [])
	set_photo_mode(false)
	big_map.visible = false
	big_map.mouse_filter = Control.MOUSE_FILTER_IGNORE
	big_map.hover = {}


func set_map_visible(v: bool) -> void:
	if not v:
		_close_travel()
	big_map.visible = v
	# открытая карта ловит мышь: щелчки по ней выбирают цель и место перемещения
	big_map.mouse_filter = Control.MOUSE_FILTER_STOP if v else Control.MOUSE_FILTER_IGNORE
	big_map.hover = {}
	if v:
		big_map.queue_redraw()


## Открытые места мира: поселения, вершины и озёра из индекса WorldData (с 8.9 extra).
## {key = id — устойчивый адрес и ключ в visited, name, x, y — клетки, kind, region, src — запись места}
## Быстрое перемещение — только после подтверждения: случайный ПКМ по карте не переносит игрока.
## Фокус на «Остаться», Esc закрывает вопрос, а не карту
func ask_travel(place: Dictionary) -> void:
	_close_travel()
	var dialog := ConfirmationDialog.new()
	_travel_dialog = dialog
	dialog.title = "Переместиться?"
	dialog.dialog_text = "В «%s», %s отсюда. Велосипед будет рядом." % [place.name,
		_fmt_dist(Grid.hypot(place.x * TILE - px, place.y * TILE - pz))]
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
	if _places_revision == world.territory_revision and not _places.is_empty():
		return _places
	_places_revision = world.territory_revision
	var out: Array = []
	for p: Dictionary in all_places():
		if in_open_land(p):
			out.append(p)
	_places = out
	return out


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


## Место на открытой территории: туда можно переместиться с карты.
func in_open_land(p: Dictionary) -> bool:
	match p.kind:
		"settlement": return world.accessible(p.x, p.y, 2.0)
		"lake": return world.accessible(p.x, p.y) and world.accessible(p.src.sx, p.src.sy, 3.0)
	return world.accessible(p.x, p.y)


## Картинка соседней области для карты (из её записи журнала), один раз на область
func region_texture(key: Vector2i, png: PackedByteArray) -> ImageTexture:
	if not _region_tex.has(key):
		var img := Image.new()
		_region_tex[key] = ImageTexture.create_from_image(img) if img.load_png_from_buffer(png) == OK else null
	return _region_tex[key]


## Новая цель путешествия (пустой словарь — без цели)
func set_goal(place: Dictionary) -> void:
	goal = place
	goal_changed.emit(place)
	# вне сцены (проверки без окна) карт и компаса нет
	if is_node_ready():
		compass.queue_redraw()
		minimap.queue_redraw()
		big_map.queue_redraw()


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
	if place.kind == "marker":
		return Grid.hypot(place.x - x / TILE, place.y - z / TILE) < 0.75
	return Grid.hypot(place.x - x / TILE, place.y - z / TILE) < (2.5 if place.kind in ["peak", "marker"] else (4.0 if place.kind == "site" else 6.0))


## Название места известно: посещено, цель или место взятого задания (11.9+)
func knows(id: String) -> bool:
	return visited.has(id) or goal.get("key") == id or (quests != null and quests.known.has(id))


## Место текущего шага задания (метка на компасе и картах) или пусто
func quest_place() -> Dictionary:
	return {} if quests == null else quests.marker()


## Цвет вида активного задания
func quest_color() -> Color:
	return GOLD if quests == null or quests.active.is_empty() else Quests.KINDS[quests.active.kind].color


## Метка задания: квадрат, повёрнутый ромбом, с тёмной обводкой и точкой — не путается с целью (золотой ромб)
static func draw_quest_mark(c: CanvasItem, at: Vector2, r: float, color: Color) -> void:
	var pts := PackedVector2Array([at + Vector2(-r, -r), at + Vector2(r, -r), at + Vector2(r, r), at + Vector2(-r, r)])
	c.draw_colored_polygon(pts, color)
	pts.append(pts[0])
	c.draw_polyline(pts, Color(0, 0, 0, 0.7 * color.a), 1.5)
	c.draw_circle(at, r * 0.35, Color(0, 0, 0, 0.7 * color.a))


## Крупная надпись посередине экрана: взято задание, выполнено. Всплывает, держится и гаснет
func banner(title: String, sub: String, color: Color) -> void:
	if _banner == null:
		return
	_banner_title.text = title
	_banner_title.add_theme_color_override("font_color", color)
	_banner_sub.text = sub
	if _banner_tween != null and _banner_tween.is_valid():
		_banner_tween.kill()
	_banner.visible = true
	_banner.modulate.a = 0.0
	_banner.scale = Vector2.ONE * 0.92
	_banner.pivot_offset = _banner.size * 0.5
	_banner_tween = create_tween()
	_banner_tween.set_parallel(true)
	_banner_tween.tween_property(_banner, "modulate:a", 1.0, 0.25)
	_banner_tween.tween_property(_banner, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_banner_tween.chain().tween_property(_banner, "modulate:a", 0.0, 0.6).set_delay(2.4)
	_banner_tween.chain().tween_callback(func() -> void: _banner.visible = false)


func _build_banner() -> VBoxContainer:
	var box := VBoxContainer.new()
	box.anchor_left = 0.0
	box.anchor_right = 1.0
	box.anchor_top = 0.26
	box.anchor_bottom = 0.26
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	_banner_title = Label.new()
	_banner_sub = Label.new()
	for l: Label in [_banner_title, _banner_sub]:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.75))
		l.add_theme_constant_override("outline_size", 6)
		box.add_child(l)
	_banner_title.add_theme_font_size_override("font_size", 30)
	_banner_sub.add_theme_font_size_override("font_size", 18)
	box.visible = false
	return box


## 11.9: счётчик задания под мини-картой — вид и название, текущий шаг с расстоянием, шаг из скольких, груз
func _build_tracker() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.offset_left = -MINI - 74
	panel.offset_right = -14
	panel.offset_top = MINI + 24
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.theme_type_variation = &"TrackerPanel"  # золотая черта слева, поля 12 и 8 px
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	panel.add_child(box)
	var head := HBoxContainer.new()
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(head)
	_tracker_icon = UiIcons.rect(null, 18)
	head.add_child(_tracker_icon)
	_tracker_title = _tracker_label(head, 15, GOLD, 18 + 8)
	_tracker_step = _tracker_label(box, 14, Color(1, 1, 1, 0.95))
	_tracker_note = _tracker_label(box, 12, Color(1, 1, 1, 0.6))
	panel.visible = false
	return panel


func _tracker_label(box: BoxContainer, font_size: int, color: Color, inset := 0.0) -> Label:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.6))
	label.add_theme_constant_override("outline_size", 3)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size.x = MINI + 60 - 20 - inset # ширина счётчика без полей: перенос считает высоту по ней
	box.add_child(label)
	return label


## Задание выполнено: счётчик ещё DONE_TIME секунд показывает это вместо шага
func quest_done(text: String) -> void:
	_done_text = text
	_done_left = DONE_TIME
	update_tracker()


## Задание изменилось: счётчик вспыхивает, чтобы взгляд заметил новый шаг; карты и компас — с новой меткой
func quest_changed() -> void:
	update_tracker()
	if is_node_ready():
		compass.queue_redraw()
		minimap.queue_redraw()
		big_map.queue_redraw()
	if not tracker.visible:
		return
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	tracker.modulate = Color(1.6, 1.5, 1.2)
	_flash_tween = create_tween()
	_flash_tween.tween_property(tracker, "modulate", Color.WHITE, 0.8)


## Перерисовать счётчик задания (игрок в px, pz)
func update_tracker() -> void:
	if tracker == null:
		return
	var title := ""
	var line := ""
	var note := ""
	if _done_left > 0.0:
		title = _done_text
		_tracker_icon.texture = UiIcons.CHECK
		_tracker_icon.modulate = GOLD
		_tracker_title.add_theme_color_override("font_color", GOLD)
		if quests != null:
			note = "Выполнено заданий: %d" % quests.done
	elif quests != null and not quests.active.is_empty():
		var q := quests.active
		title = q.title
		_tracker_icon.texture = UiIcons.quest(q.kind)
		_tracker_icon.modulate = quest_color()
		var s := quests.step()
		line = quests.step_text(s)  # расстояние до места шага — на компасе у метки задания
		# шаги точками: ● пройден или текущий, ○ впереди
		var pips := ""
		for i in q.steps.size():
			pips += "●" if i <= q.step else "○"
		note = "%s %s · шаг %d из %d" % [pips, Quests.KINDS[q.kind].title, q.step + 1, q.steps.size()]
		if quests.cargo:
			note += " · сумка за спиной"
		_tracker_title.add_theme_color_override("font_color", quest_color())
	tracker.visible = title != "" and not _photo_mode and (_revealed or _done_left > 0.0)
	if _tracker_title.text != title:
		_tracker_title.text = title
	if _tracker_step.text != line:
		_tracker_step.text = line
	_tracker_step.visible = line != ""
	if _tracker_note.text != note:
		_tracker_note.text = note


## Курс на точку (x, z в метрах) от игрока — в тех же единицах, что yaw: 0 — север, PI/2 — запад
func heading_to(x: float, z: float) -> float:
	return atan2(-(x - px), -(z - pz))


## 11.8: с фотоаппаратом у глаз (GameWorld.photo) видны только рамка видоискателя и сообщения
func set_photo_mode(on: bool) -> void:
	_photo_mode = on
	_apply_reveal()
	update_tracker()


## 12.4: интерфейс чистый — подсказка у прицела и сообщения; остальное только с зажатым Tab.
## 12.7: прицел тоже только с Tab; наведение и E работают и без него
func _apply_reveal() -> void:
	var shown := _revealed and not _photo_mode
	for node: CanvasItem in [$InfoPanel, minimap, compass]:
		node.visible = shown
	hint.visible = (shown or _hint_urgent) and not _photo_mode
	$Crosshair.visible = shown
	prompt.visible = not _photo_mode


## Подсказки внизу и у прицела — чипы [клавиша] действие (пустой список — скрыты).
## urgent — нижние видно и без Tab (падение: как восстановиться)
func set_hints(bottom: Array, near: Array, urgent := false) -> void:
	if _hint_items != bottom:
		_hint_items = bottom.duplicate()
		_fill_chips(hint, bottom)
	if _prompt_items != near:
		_prompt_items = near.duplicate()
		_fill_chips(prompt, near)
	if _hint_urgent != urgent:
		_hint_urgent = urgent
		_apply_reveal()


## 14.0: выносливость 0..1; exhausted — опустела и ещё не восстановилась до Stamina.RECOVERED.
## 14.2: state — Stamina.State: трата ниже LOW пульсирует и затемняет края, накат подсвечен
func set_stamina(value: float, exhausted: bool, state: Stamina.State) -> void:
	var allowed := not _photo_mode and not big_map.visible
	_stamina.set_value(value, exhausted, state, allowed)
	var mat: ShaderMaterial = _vignette.material
	mat.set_shader_parameter("strength", _stamina.warning * 0.4)
	_vignette.visible = _stamina.warning > 0.01


## 14.2: чипы клавиш — тёмная плашка с контрастной обводкой, рядом действие; читаются боковым зрением
func _fill_chips(row: HBoxContainer, items: Array) -> void:
	for child in row.get_children():
		row.remove_child(child)
		child.queue_free()
	for item: Array in items:
		var pair := HBoxContainer.new()
		pair.add_theme_constant_override("separation", 6)
		pair.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var chip := PanelContainer.new()
		chip.add_theme_stylebox_override("panel", _chip_style)
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var key := Label.new()
		key.text = str(item[0])
		key.add_theme_font_size_override("font_size", 14)
		key.add_theme_color_override("font_color", Color.WHITE)
		chip.add_child(key)
		pair.add_child(chip)
		var what := Label.new()
		what.text = str(item[1])
		what.add_theme_font_size_override("font_size", 15)
		what.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.95))
		what.add_theme_constant_override("outline_size", 5)
		pair.add_child(what)
		row.add_child(pair)


## Где стоит велосипед (метры) и показывать ли его на картах
func set_bike(x: float, z: float, shown: bool) -> void:
	bike_pos = Vector2(x, z)
	bike_shown = shown


static func draw_bike(c: CanvasItem, at: Vector2, r: float) -> void:
	c.draw_circle(at, r, Color.html("#3fa7ff"))
	c.draw_arc(at, r, 0.0, TAU, 16, Color.WHITE, 1.5)


## Сообщение внизу у прицела. Пока одно висит на экране, следующие ждут в очереди,
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
		while _toast_queue.size() > TOAST_QUEUE:
			_toast_queue.remove_at(0)
		return
	_show_toast(text)


## Сообщение сразу, без очереди: прежние уже не к месту (например, после быстрого перемещения)
func toast_now(text: String) -> void:
	_toast_queue.clear()
	_show_toast(text)


func _show_toast(text: String) -> void:
	_stop_toast_tween()
	toast_label.text = text
	toast_label.modulate.a = 1.0
	_toast_left = TOAST_TIME


func _stop_toast_tween() -> void:
	if _toast_tween != null and _toast_tween.is_valid():
		_toast_tween.kill()


func _process(delta: float) -> void:
	var reveal := Input.is_action_pressed("show_hud")
	if reveal != _revealed:
		_revealed = reveal
		_apply_reveal()
		update_tracker()
		if reveal:
			minimap.queue_redraw()
			compass.queue_redraw()
	if _done_left > 0.0:
		_done_left -= delta
		if _done_left <= 0.0:
			update_tracker()
	if _toast_left <= 0.0:
		return
	_toast_left -= delta
	if _toast_left > 0.0:
		return
	if not _toast_queue.is_empty():
		var next := _toast_queue[0]
		_toast_queue.remove_at(0)
		_show_toast(next)
	else:
		_stop_toast_tween()
		_toast_tween = create_tween()
		_toast_tween.tween_property(toast_label, "modulate:a", 0.0, TOAST_FADE)


## Положение игрока для мини-карты и большой карты
func set_player(x: float, z: float, y: float) -> void:
	# стоит на месте и не крутит головой — карты и компас не перерисовываются каждый кадр
	if x == px and z == pz and y == yaw:
		return
	px = x
	pz = z
	yaw = y
	minimap.queue_redraw()
	compass.queue_redraw()
	if big_map.visible:
		big_map.queue_redraw()


## Строки о местности под ногами: биом и дорога, высота и температура; без цели — ближайшее поселение.
## Курс, цель и задание сюда не пишутся: они на компасе (12.5+)
func update_info(p: PlayerState, _look_yaw: float, depth: float) -> void:
	var w := world
	if w == null:
		return
	var ti := w.tile_info(p.x / TILE, p.z / TILE)
	if ti.is_empty():
		return
	var where: String = Biomes.LIST[ti.biome].name
	if ti.river:
		where += ", брод через реку"
	var surf := PlayerState.surface(ti)
	if surf != RoadSurface.NONE:
		where += ", %s (%s)" % ["дорога" if ti.path == 3 else "тропа", RoadSurface.LIST[surf].name]
	elif ti.path == 1:
		where += ", звериная тропа"
	if depth > 0.3:
		where += " (по колено в воде)"
	var temp_c := roundi(-25.0 + ti.temp * 60.0)
	var nearest = null
	var nd := INF
	for s in w.settlements:
		if not w.accessible(s.x, s.y):
			continue
		var d := Grid.hypot(s.x * TILE - p.x, s.y * TILE - p.z)
		if d < nd:
			nd = d
			nearest = s
	var text := "%s\nВысота: %d м · %s%d°C" % [where, roundi(p.feet), "+" if temp_c > 0 else "", temp_c]
	if goal.is_empty() and nearest != null:
		text += "\nБлижайшее поселение: «%s», %s" % [nearest.name, _fmt_dist(nd)]
	# текст панели меняется не каждый кадр: не трогаем Label, пока строки те же
	if info.text != text:
		info.text = text
	update_tracker()


## Расстояние в метрах или километрах
static func _fmt_dist(m: float) -> String:
	if m < 1000.0:
		return "%d м" % roundi(m)
	return "%.1f км" % (m / 1000.0)


static func draw_arrow(c: CanvasItem, pos: Vector2, size: float, look_yaw: float) -> void:
	c.draw_set_transform(pos, -look_yaw, Vector2.ONE)
	var pts := PackedVector2Array([Vector2(0, -size), Vector2(size * 0.65, size * 0.7), Vector2(0, size * 0.35), Vector2(-size * 0.65, size * 0.7)])
	c.draw_colored_polygon(pts, Color.html("#ff3b30"))
	pts.append(pts[0])
	c.draw_polyline(pts, Color.WHITE, 1.5)
	c.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


static func draw_label(c: CanvasItem, text: String, pos: Vector2, color: Color, font_size: int, selected := false) -> void:
	var font := ThemeDB.fallback_font
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var at := pos - Vector2(w / 2.0, 0)
	if selected:
		c.draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 8, Color(GOLD, 0.85))
	c.draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 6, Color(0, 0, 0, 0.7))
	c.draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)


## Мини-карта 200×200 в углу экрана
class MiniMap extends Control:
	var hud: Hud

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		if hud.world == null:
			return
		var w := hud.world
		var k := Hud.MINI / w.W
		draw_texture_rect(hud.map_tex, Rect2(Vector2.ZERO, Vector2(Hud.MINI, Hud.MINI)), false)
		draw_rect(Rect2(Vector2.ZERO, Vector2(Hud.MINI, Hud.MINI)), Color(1, 1, 1, 0.5), false, 2.0)
		for s in w.settlements:
			if not w.accessible(s.x, s.y):
				continue
			draw_rect(Rect2(s.x * k - 1.5, s.y * k - 1.5, 3, 3), Color.html("#ffdd55"))
		if not hud.goal.is_empty():
			draw_arc(_inside(Vector2(hud.goal.x, hud.goal.y) * k, 5.0), 4.5, 0.0, TAU, 16, Hud.GOLD, 2.0)
		var q := hud.quest_place()
		if not q.is_empty():
			Hud.draw_quest_mark(self, _inside(Vector2(q.x, q.y) * k, 6.0), 4.0, hud.quest_color())
		if hud.bike_shown:
			Hud.draw_bike(self, _inside(hud.bike_pos / Hud.TILE * k, 4.0), 3.0)
		Hud.draw_arrow(self, _inside(Vector2(hud.px, hud.pz) / Hud.TILE * k, 8.0), 6.0, hud.yaw)

	## Маркер у края мира прижимается к рамке, а не вылезает за неё
	func _inside(at: Vector2, margin: float) -> Vector2:
		return at.clamp(Vector2(margin, margin), Vector2(Hud.MINI - margin, Hud.MINI - margin))


## Компас вверху экрана: стороны света по курсу взгляда и неяркая метка цели, если она выбрана.
## Метка цели за краем видимой дуги прижимается к краю и бледнеет
class Compass extends Control:
	const SPAN := PI * 0.8   # видимая дуга курса
	var hud: Hud
	var _back := StyleBoxFlat.new()

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		_back.bg_color = Color(0.04, 0.06, 0.1, 0.45)
		_back.set_corner_radius_all(8)

	func _draw() -> void:
		if hud.world == null:
			return
		var half := size.x / 2.0
		var font := ThemeDB.fallback_font
		# 14.2: тёмная подложка, чтобы буквы не терялись на снегу и в ярком небе
		draw_style_box(_back, Rect2(Vector2(-10, -2), size + Vector2(20, 4)))
		draw_line(Vector2(0, size.y - 1), Vector2(size.x, size.y - 1), Color(1, 1, 1, 0.18), 1.0)
		for d in 8:
			var off := wrapf(d * PI / 4.0 - hud.yaw, -PI, PI)
			if absf(off) > SPAN / 2.0:
				continue
			var x := half - off / (SPAN / 2.0) * half
			var a := 1.0 - absf(off) / (SPAN / 2.0)
			var fs := 15 if d % 2 == 0 else 11
			var t: String = Hud.DIRS[d]
			var tw := font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			var at := Vector2(x - tw / 2.0, size.y - 8.0)
			draw_string_outline(font, at, t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 5, Color(0, 0, 0, 0.9 * a))
			draw_string(font, at, t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.8 * a))
		# метка задания (11.9+) — квадрат цвета вида над линией; за краем дуги прижата к краю и бледнее.
		# Расстояние подписано под меткой (12.5+ только здесь, не в счётчике и не в панели сведений)
		var q := hud.quest_place()
		var qx := -INF
		if not q.is_empty():
			var qoff := wrapf(hud.heading_to(q.x * Hud.TILE, q.y * Hud.TILE) - hud.yaw, -PI, PI)
			var qseen := absf(qoff) <= SPAN / 2.0
			qx = half - clampf(qoff / (SPAN / 2.0), -1.0, 1.0) * (half - 6.0)
			var qc := hud.quest_color() if qseen else Color(hud.quest_color(), 0.5)
			Hud.draw_quest_mark(self, Vector2(qx, size.y - 15.0), 4.5, qc)
			_distance(font, qx, q, qc)
		if hud.goal.is_empty():
			return
		var g := hud.goal
		var off := wrapf(hud.heading_to(g.x * Hud.TILE, g.y * Hud.TILE) - hud.yaw, -PI, PI)
		var seen := absf(off) <= SPAN / 2.0
		var x := half - clampf(off / (SPAN / 2.0), -1.0, 1.0) * (half - 4.0)
		var c := Hud.GOLD if seen else Color(Hud.GOLD, 0.45)
		var y := size.y - 1.0
		draw_colored_polygon(PackedVector2Array([Vector2(x, y - 7), Vector2(x + 4, y - 3), Vector2(x, y + 1), Vector2(x - 4, y - 3)]), c)
		# у задания и цели в одной стороне подпись одна (задания): иначе они наползают друг на друга
		if absf(x - qx) > 40.0:
			_distance(font, x, g, c)

	## Расстояние до места под его меткой
	func _distance(font: Font, x: float, place: Dictionary, color: Color) -> void:
		var dist := Hud._fmt_dist(Grid.hypot(place.x * Hud.TILE - hud.px, place.y * Hud.TILE - hud.pz))
		var dw := font.get_string_size(dist, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
		var dat := Vector2(clampf(x - dw / 2.0, 0.0, size.x - dw), size.y + 13.0)
		draw_string_outline(font, dat, dist, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, 4, Color(0, 0, 0, 0.9))
		draw_string(font, dat, dist, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, color)


## 13.9+final: колесо мыши — масштаб вокруг курсора, перетаскивание ЛКМ или средней кнопкой — сдвиг,
## щелчок средней кнопкой — к игроку. Видны и закреплённые соседние области с их поселениями.
## Большая карта (M): посещённые поселения и вершины отмечены жёлтым. С 2.8 карта ловит мышь:
## ЛКМ по месту — цель путешествия (ещё раз — снять), ПКМ по любому месту — перемещение туда (с 3.0.2 и туда, где ещё не были).
## С 12.5+ метку легче поймать (PICK 24 px), а перемещение спрашивает подтверждение (Hud.ask_travel)
class BigMap extends Control:
	const PICK := 24.0  # на сколько пикселей можно промахнуться по метке места
	const ZOOM_MIN := 0.25 # доля масштаба «весь план в рамке»
	const ZOOM_MAX := 16.0
	const ZOOM_STEP := 1.25
	const DRAG := 6.0      # пикселей: дальше нажатие ЛКМ — перетаскивание, а не выбор
	var hud: Hud
	var hover := {}     # место под курсором или пусто
	var zoom := 1.0
	var center := Vector2.INF  # клетка в середине экрана; INF — середина плана
	var _press := Vector2.INF  # где нажата ЛКМ или средняя кнопка
	var _dragged := false

	func _init() -> void:
		clip_contents = true

	func reset_view() -> void:
		zoom = 1.0
		center = Vector2.INF

	func _queue_name(names: Array[Dictionary], pl: Dictionary, at: Vector2, color: Color, fs: int, text := "") -> void:
		var selected: bool = pl.key == hud.goal.get("key")
		names.append({text = pl.name if text.is_empty() else text, at = at, color = Hud.GOLD if selected else color,
			fs = fs, selected = selected, distance = Vector2(pl.x * Hud.TILE - hud.px, pl.y * Hud.TILE - hud.pz).length_squared()})

	func _draw_names(names: Array[Dictionary]) -> void:
		names.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return a.selected if a.selected != b.selected else a.distance < b.distance)
		var occupied: Array[Rect2] = []
		var font := ThemeDB.fallback_font
		for item: Dictionary in names:
			var size := font.get_string_size(item.text, HORIZONTAL_ALIGNMENT_LEFT, -1, item.fs)
			var rect := Rect2(item.at - Vector2(size.x * 0.5, font.get_ascent(item.fs)), Vector2(size.x, font.get_height(item.fs))).grow(6.0)
			var overlaps := false
			for other: Rect2 in occupied:
				if rect.intersects(other):
					overlaps = true
					break
			if overlaps:
				continue
			occupied.append(rect)
			Hud.draw_label(self, item.text, item.at, item.color, item.fs, item.selected)

	## Где на экране лежит карта плана: [левый верхний угол, сторона, пикселей на клетку]
	func _frame() -> Array:
		var k := minf(size.x, size.y) * 0.88 / hud.world.W * zoom
		var c := center if center != Vector2.INF else Vector2(hud.world.W, hud.world.H) * 0.5
		var o := size * 0.5 - c * k
		return [o, hud.world.W * k, k]

	## Масштаб вокруг точки экрана: клетка под курсором остаётся под ним
	func _zoom_at(pos: Vector2, factor: float) -> void:
		var f := _frame()
		var cell: Vector2 = (pos - f[0]) / float(f[2])
		zoom = clampf(zoom * factor, ZOOM_MIN, ZOOM_MAX)
		var k := minf(size.x, size.y) * 0.88 / hud.world.W * zoom
		center = cell - (pos - size * 0.5) / k
		_clamp_center()
		queue_redraw()

	## Середина экрана не уходит дальше области от плана и закреплённых земель
	func _clamp_center() -> void:
		var known := Rect2(Vector2.ZERO, Vector2(hud.world.W, hud.world.H))
		if hud.world.outer != null:
			for key: Vector2i in hud.world.outer.get_ledger().get("regions", {}):
				known = known.expand(Vector2(key * WorldData.REGION_SIZE)).expand(Vector2((key + Vector2i.ONE) * WorldData.REGION_SIZE))
		known = known.grow(WorldData.REGION_SIZE)
		center = center.clamp(known.position, known.end)

	## Ближайшее к точке экрана место не дальше PICK пикселей
	func _place_at(pos: Vector2) -> Dictionary:
		if hud.world == null:
			return {}
		var f := _frame()
		var best := {}
		var bd := PICK
		for pl: Dictionary in hud.all_places():
			if pl.kind != "settlement" and not hud.world.accessible(pl.x, pl.y):
				continue # за краем открытых земель на карте видны только поселения
			var d := pos.distance_to(f[0] + Vector2(pl.x, pl.y) * f[2])
			if d < bd:
				bd = d
				best = pl
		return best

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseMotion:
			if _press != Vector2.INF and event.button_mask & (MOUSE_BUTTON_MASK_LEFT | MOUSE_BUTTON_MASK_MIDDLE):
				if _dragged or event.position.distance_to(_press) > DRAG:
					if center == Vector2.INF:
						center = Vector2(hud.world.W, hud.world.H) * 0.5
					center -= event.relative / float(_frame()[2])
					_clamp_center()
					_dragged = true
					queue_redraw()
					accept_event()
					return
			var h := _place_at(event.position)
			if h.get("key") != hover.get("key"):
				hover = h
				queue_redraw()
		elif event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			if event.pressed:
				_zoom_at(event.position, ZOOM_STEP if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / ZOOM_STEP)
			accept_event()
		elif event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE] and event.pressed:
			# выбор — при отпускании без перетаскивания
			_press = event.position
			_dragged = false
			accept_event()
		elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_MIDDLE:
			if not _dragged:
				center = Vector2(hud.px, hud.pz) / Hud.TILE
				_clamp_center()
				queue_redraw()
			_press = Vector2.INF
			accept_event()
		elif event is InputEventMouseButton and (event.pressed or event.button_index == MOUSE_BUTTON_LEFT):
			var was_drag := _dragged
			var from_map: bool = _press != Vector2.INF or event.pressed
			_press = Vector2.INF
			_dragged = false
			if was_drag or not from_map: # отпускание после нажатия вне карты — не выбор
				accept_event()
				return
			var pl := _place_at(event.position)
			if event.button_index == MOUSE_BUTTON_LEFT and not pl.is_empty():
				var same: bool = pl.key == hud.goal.get("key")
				hud.set_goal({} if same else pl)
			elif event.button_index == MOUSE_BUTTON_LEFT:
				var frame := _frame()
				var cell: Vector2 = (event.position - frame[0]) / float(frame[2])
				var same: bool = hud.goal.get("kind") == "marker" and cell.distance_to(Vector2(hud.goal.x, hud.goal.y)) < 4.0
				hud.set_goal({} if same else {key = "marker", kind = "marker", name = "Метка", x = cell.x, y = cell.y})
			elif event.button_index == MOUSE_BUTTON_RIGHT and not pl.is_empty() and hud.in_open_land(pl):
				hud.ask_travel(pl)
			accept_event()

	func _draw() -> void:
		if hud.world == null:
			return
		var w := hud.world
		var cw := size.x
		draw_rect(Rect2(Vector2.ZERO, size), Color(8 / 255.0, 12 / 255.0, 20 / 255.0, 0.82))
		var f := _frame()
		var o: Vector2 = f[0]
		var sz: float = f[1]
		var k: float = f[2]
		draw_texture_rect(hud.map_tex, Rect2(o, Vector2(sz, sz)), false)
		# Закреплённые соседние области — их картинки по местам в мире
		if w.outer != null:
			var regions: Dictionary = w.outer.get_ledger().get("regions", {})
			for key: Vector2i in regions:
				var png: PackedByteArray = regions[key].get("map", PackedByteArray())
				var tex := hud.region_texture(key, png) if not png.is_empty() else null
				if tex != null:
					var r: Rect2i = regions[key].rect
					draw_texture_rect(tex, Rect2(o + Vector2(r.position) * k, Vector2(r.size) * k), false)
		draw_rect(Rect2(o, Vector2(sz, sz)), Color.html("#d8c79a"), false, 2.0)
		# За рамкой виден тот же мир; соседняя территория откроется при приближении.
		if w.available_rect.has_area():
			var a := o + Vector2(w.available_rect.position) * k
			var b := o + Vector2(w.available_rect.end) * k
			var shade := Color(0.0, 0.0, 0.0, 0.65)
			draw_rect(Rect2(o, Vector2(sz, a.y - o.y)), shade)
			draw_rect(Rect2(Vector2(o.x, b.y), Vector2(sz, o.y + sz - b.y)), shade)
			draw_rect(Rect2(Vector2(o.x, a.y), Vector2(a.x - o.x, b.y - a.y)), shade)
			draw_rect(Rect2(Vector2(b.x, a.y), Vector2(o.x + sz - b.x, b.y - a.y)), shade)
			draw_rect(Rect2(a, b - a), Hud.GOLD, false, 1.5)
		var names: Array[Dictionary] = []
		for pl: Dictionary in hud.all_places():
			var at := o + Vector2(pl.x, pl.y) * k
			if not w.accessible(pl.x, pl.y):
				# Дальние поселения — тусклые точки без подписи: их можно выбрать целью заранее.
				if pl.kind == "settlement":
					draw_circle(at, 2.5, Color(1, 1, 1, 0.45))
				if pl.key == hud.goal.get("key"):
					_queue_name(names, pl, at - Vector2(0, 7), Hud.GOLD, 13)
				continue
			var seen: bool = hud.visited.has(pl.key)
			match pl.kind:
				"settlement":
					draw_circle(at, 3.5, Color.html("#ffdd55") if seen else Color.WHITE)
					_queue_name(names, pl, at - Vector2(0, 7), Color.html("#fff6d8"), 13)
				"peak":
					var col := Color.html("#ffdd55") if seen else Color.html("#e8f0ff")
					draw_colored_polygon(PackedVector2Array([at + Vector2(0, -3), at + Vector2(3, 3), at + Vector2(-3, 3)]), col)
					_queue_name(names, pl, at - Vector2(0, 7), col, 13)
				"lake":
					var col := Color.html("#ffdd55") if seen else Color.html("#cfeaff")
					draw_arc(at, 3.0, 0.0, TAU, 12, col, 1.5)
					_queue_name(names, pl, at - Vector2(0, 7), col, 12)
				"site":
					# Ромбик по значимости; название — у крупных мест и у тех, где уже были.
					var col := Color.html("#ffdd55") if seen else Color.html("#e6d6b0")
					var r: float = 1.5 + pl.src.rank
					draw_colored_polygon(PackedVector2Array([at + Vector2(0, -r), at + Vector2(r, 0), at + Vector2(0, r), at + Vector2(-r, 0)]), col)
					if seen or pl.src.rank >= 3 or pl.key == hud.goal.get("key") or hud.knows(pl.key):
						_queue_name(names, pl, at - Vector2(0, 6), col, 11)
		_draw_names(names)
		if not hud.goal.is_empty():
			draw_arc(o + Vector2(hud.goal.x, hud.goal.y) * k, 9.0, 0.0, TAU, 24, Hud.GOLD, 2.5)
		var q := hud.quest_place()
		if not q.is_empty():
			var qat := _inside(o + Vector2(q.x, q.y) * k, 8.0)
			Hud.draw_quest_mark(self, qat + Vector2(11, -11), 5.5, hud.quest_color())
			# шаг задания — вверху внутри рамки карты: под ней уже две строки
			Hud.draw_label(self, "Задание: " + hud.quests.step_text(), Vector2(cw / 2.0, 54.0), hud.quest_color(), 15)
		if hud.bike_shown:
			Hud.draw_bike(self, _inside(o + hud.bike_pos / Hud.TILE * k, 5.0), 5.0)
		Hud.draw_arrow(self, _inside(o + Vector2(hud.px, hud.pz) / Hud.TILE * k, 9.0), 9.0, hud.yaw)
		# легенду про велосипед пишем, только когда он действительно нарисован
		var legend := "Мир «%s» · территория %d × %d — M или Esc, чтобы закрыть" % [w.seed_text, w.available_rect.size.x, w.available_rect.size.y]
		if hud.bike_shown:
			legend += " · синим отмечен велосипед"
		Hud.draw_label(self, legend, Vector2(cw / 2.0, 30.0), Color.WHITE, 16)
		Hud.draw_label(self, _found_line(), Vector2(cw / 2.0, size.y - 16.0), Color(1, 1, 1, 0.6), 13)
		var tip := "ЛКМ — цель или метка · колесо — масштаб · перетаскивание — сдвиг · средняя кнопка — к себе"
		if not hover.is_empty():
			var d := Grid.hypot(hover.x * Hud.TILE - hud.px, hover.y * Hud.TILE - hud.pz)
			tip = "«%s», %s · ЛКМ — %s · " % [hover.name, Hud._fmt_dist(d), "снять цель" if hover.key == hud.goal.get("key") else "цель"]
			tip += "ПКМ — переместиться сюда" if hud.in_open_land(hover) else "земли откроются по пути"
			draw_arc(o + Vector2(hover.x, hover.y) * k, 10.0, 0.0, TAU, 24, Color.WHITE, 2.0)
		Hud.draw_label(self, tip, Vector2(cw / 2.0, size.y - 38.0), Color(1, 1, 1, 0.85), 15)

	## Сколько мест уже открыто: «Открыто: поселений 2 из 12 · вершин 0 из 6 · озёр 1 из 9»
	func _found_line() -> String:
		var n := {settlement = 0, peak = 0, lake = 0, site = 0}
		for key: String in hud.visited:
			n[key.get_slice(":", 0)] += 1
		var counts := {settlement = 0, peak = 0, lake = 0, site = 0}
		for place: Dictionary in hud.places():
			counts[place.kind] += 1
		var text := "Открыто: поселений %d из %d · вершин %d из %d" % [n.settlement, counts.settlement, n.peak, counts.peak]
		if counts.lake > 0:
			text += " · озёр %d из %d" % [n.lake, counts.lake]
		if counts.site > 0:
			text += " · мест %d из %d" % [n.site, counts.site]
		return text

	## Маркер за краем видимой части карты прижимается к краю экрана
	func _inside(at: Vector2, margin: float) -> Vector2:
		return at.clamp(Vector2(margin, margin), size - Vector2(margin, margin))


## 14.2: дуга выносливости (с 14.4 — кольцо в левом нижнем углу). Появляется, пока силы тратятся или копятся, полная — гаснет.
## Засечка на Stamina.RECOVERED — с неё после истощения снова работает Shift. Белый шлейф за краем
## заливки быстро тает и показывает темп траты. Ниже LOW при трате дуга пульсирует, warning (0..1) затемняет
## края экрана; при восстановлении предупреждение гаснет быстро. Накат подсвечен холодным ореолом.
class StaminaArc extends Control:
	const R := 26.0                       # радиус кольца, px
	const FROM := deg_to_rad(135.0)       # кольцо с разрывом внизу: от левого низа через верх к правому низу
	const SPAN := deg_to_rad(270.0)
	const WIDTH := 5.0
	const LOW := 0.2
	const GHOST_LAG := 1.5                # 1/с: шлейф догоняет заливку с запаздыванием — чем быстрее трата, тем он
	                                      # длиннее (Shift в подъём — ~5 % дуги), рывок тает за доли секунды
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
		var active := st == Stamina.State.DRAIN or st == Stamina.State.COAST or st == Stamina.State.REST or v < 0.999
		_alpha = move_toward(_alpha, 1.0 if allowed and active else 0.0, dt * (4.0 if allowed and active else 1.5))
		_ghost = v if v >= _ghost else lerpf(_ghost, v, 1.0 - exp(-dt * GHOST_LAG))
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
		_arc(0.0, 1.0, WIDTH + 3.0, Color(0, 0, 0, 0.45 * a))
		if _coast > 0.0:
			_arc(0.0, value, WIDTH + 6.0, Color(0.45, 0.85, 1.0, 0.22 * _coast * a))
		_arc(value, _ghost, WIDTH, Color(1, 1, 1, 0.8 * a))
		var fill := Color(0.92, 0.95, 0.9)
		if exhausted:
			fill = Color(0.9, 0.3, 0.25)
		elif value < LOW:
			fill = Color(1.0, 0.72, 0.3)
		fill = fill.lerp(Color(0.6, 0.9, 1.0), _coast * 0.6)
		# 14.5: расход — тёплый оттенок и мягкий пульс, в начале расхода — вспышка шире и ярче
		if not exhausted and value >= LOW:
			fill = fill.lerp(Color(1.0, 0.8, 0.4), _drain * 0.55)
		fill = fill.lerp(Color.WHITE, _kick * 0.5)
		var pulse := 0.5 + 0.5 * sin(_t * 7.0)
		var spend := 0.5 + 0.5 * sin(_t * 4.5)
		fill.a = a * lerpf(lerpf(0.95, 0.75 + 0.25 * spend, _drain), 0.55 + 0.4 * pulse, warning)
		_arc(0.0, value, WIDTH + warning * pulse * 1.5 + _drain * spend * 1.0 + _kick * 3.0, fill)
		# засечка разблокировки Shift: поперёк дуги, светлая с тёмной обводкой
		var ang := FROM + SPAN * Stamina.RECOVERED
		var dir := Vector2(cos(ang), sin(ang))
		var c := size / 2.0
		var mark := Color(1, 1, 1, a) if exhausted or value < Stamina.RECOVERED + 0.1 else Color(1, 1, 1, 0.6 * a)
		draw_line(c + dir * (R - 6.0), c + dir * (R + 6.0), Color(0, 0, 0, 0.7 * a), 4.0)
		draw_line(c + dir * (R - 5.0), c + dir * (R + 5.0), mark, 2.0)

