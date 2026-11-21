extends Node3D
## 19.11.2026: щит доски поселения в мире показывает то же, что панель доски: карту окрестностей и листки заданий.
##
## Цена (главное требование — без нагрузки в игре):
## - Щит с содержимым один — у ближней доски (SHOW_M). Остальные доски остаются деревянными с надписью «МАРШРУТЫ».
## - Содержимое рисуется в SubViewport один раз: несколько кадров, пока карта догружает участки (не больше
##   BUILD_FRAMES), затем вьюпорт замирает (UPDATE_DISABLED, обработка узлов выключена), а текстура остаётся.
##   В обычном кадре — один прямоугольник с одной текстурой: один вызов отрисовки, ноль работы на CPU.
## - Ближняя доска ищется не каждый кадр, а раз в CHECK_S; перерисовка — только при смене доски или заданий
##   (Quests.changed), не на каждый шаг. Задания доски считаются тем же InteractionService.offers, что и для панели.
## - Вьюпорт создаётся при первом подъезде к доске и живёт дальше; на дальних досках его нет вовсе.

const Atlas = preload("res://scripts/ui/world_map_view.gd")
const MapData = preload("res://scripts/ui/local_map_data.gd")
const HudStyle = preload("res://scripts/ui/hud_style.gd")
const QuestNotice = preload("res://scripts/ui/quest_notice.gd")
const Quests = preload("res://scripts/game/quests.gd")
const Courtyard = preload("res://scripts/render/settlement_courtyard.gd")

const SHOW_M := 34.0          # м: ближе — на щите карта и задания
const HIDE_M := 40.0          # м: дальше — щит гаснет (запас, чтобы не мигал на границе)
const CHECK_S := 0.4          # с между поисками ближней доски
const TEX := Vector2i(1024, 540)  # текстура щита: 1,8 × 0,95 м
const FACE := Vector2(1.72, 0.9)  # прямоугольник поверх щита, м
const FACE_Z := 0.071         # м перед серединой щита (щит толщиной 0,13 м)
const BUILD_FRAMES := 40      # кадров на догрузку карты, потом рисуется как есть
const NOTICE := Vector2(176, 404)

var boards: Callable          # () -> Array досок {at, place, label}
var offers: Callable          # (place) -> Array[QuestData], как для панели доски
var offers_next: Callable     # (plan) -> Array листков или null (InteractionService.offers_next)
var pins: Callable            # (place) -> Array мест для карты, как для панели доски
var tick_us := {}             # накопленное время частей кадра (GameWorld.tick_us): сборка щита — «board»
var quests: Quests
var map_source: MapData       # общая подложка карты (Hud.map_data); у щита свой вид на неё
var world: WorldData

var builds := 0               # сколько раз щит перерисовывался (проверка tools/quest_look.gd)
var step_ms := PackedFloat32Array()  # время шагов последней сборки, мс (tools/stress world.board)
var _next_check_ms := 0
var _board := {}              # доска, у которой сейчас щит
var _key := ""                # что нарисовано: доска и ревизия заданий
var _revision := 0
var _viewport: SubViewport
var _atlas: Atlas
var _quad: MeshInstance3D
var _paper: Control
var _frames_left := 0
var _painted := false
var _steps: Array[Callable] = []  # оставшиеся шаги сборки щита
var _list: Array = []              # листки этого щита


func _ready() -> void:
	set_process(false)


func setup(w: WorldData, q: Quests, source: MapData, list: Callable, offers_of: Callable, pins_of: Callable,
		next_of := Callable()) -> void:
	world = w
	quests = q
	map_source = source
	boards = list
	offers = offers_of
	pins = pins_of
	offers_next = next_of
	if quests != null and not quests.changed.is_connected(invalidate):
		quests.changed.connect(invalidate)
	_ensure_nodes()  # вьюпорт и прямоугольник — при загрузке мира, не в кадре у доски


## Задания изменились (взяли, выполнили, бросили): щит перерисуется при следующей проверке
func invalidate() -> void:
	_revision += 1
	_next_check_ms = 0


## Из GameWorld._process: дёшево, раз в CHECK_S ищет ближнюю доску
func tick(eye: Vector3) -> void:
	var now := Time.get_ticks_msec()
	if now < _next_check_ms or not boards.is_valid():
		return
	_next_check_ms = now + int(CHECK_S * 1000.0)
	var best := {}
	var best_d := SHOW_M * SHOW_M
	var keep_d := HIDE_M * HIDE_M
	for b: Dictionary in boards.call():
		var d := eye.distance_squared_to(b.at.origin)
		if not _board.is_empty() and b.place == _board.place and d < keep_d:
			best = b  # нынешняя держится до HIDE_M
			break
		if d < best_d:
			best_d = d
			best = b
	if best.is_empty():
		_release()
		return
	var key := "%s|%d|%d|%s" % [_place_key(best.place), _revision, quests.done if quests != null else 0,
		quests.active.id if quests != null else ""]
	if key != _key or _board.is_empty() or best.place != _board.place:
		_show(best, key)


func _place_key(place: Variant) -> String:
	return WorldData.place_id("settlement", place.x, place.y)


func _show(board: Dictionary, key: String) -> void:
	_restore_label()
	_board = board
	_key = key
	if is_instance_valid(board.get("label")):
		(board.label as Node3D).visible = false
	_ensure_nodes()
	_quad.transform = (board.at as Transform3D).translated_local(Vector3(0.0, 0.0, FACE_Z))
	_quad.visible = true
	_build_content(board.place)
	builds += 1


func _release() -> void:
	_restore_label()
	_board = {}
	_key = ""
	if _quad != null:
		_quad.visible = false
	set_process(false)
	_steps.clear()
	if _viewport != null:
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		_viewport.process_mode = Node.PROCESS_MODE_DISABLED


func _restore_label() -> void:
	if not _board.is_empty() and is_instance_valid(_board.get("label")):
		(_board.label as Node3D).visible = true


func _ensure_nodes() -> void:
	if _viewport != null:
		return
	_viewport = SubViewport.new()
	_viewport.size = TEX
	_viewport.transparent_bg = true
	_viewport.disable_3d = true
	_viewport.gui_disable_input = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)
	var mesh := QuadMesh.new()
	mesh.size = FACE
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _viewport.get_texture()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	mat.alpha_scissor_threshold = 0.5
	mat.roughness = 0.95
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	_quad = MeshInstance3D.new()
	_quad.mesh = mesh
	_quad.material_override = mat
	_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_quad.visibility_range_end = HIDE_M + 4.0
	_quad.visible = false
	add_child(_quad)


## Щит: заголовок, карта слева, до трёх листков справа. Узлы пересоздаются только при смене доски или заданий.
## Сборка разложена по кадрам (_steps, по шагу за кадр, каждый ~1–4 мс): щит появляется за 34 м до доски,
## несколько кадров сборки не видны, а один кадр не берёт всю работу разом
func _build_content(place: Variant) -> void:
	for child: Node in _viewport.get_children():
		_viewport.remove_child(child)
		child.queue_free()
	_atlas = null
	_paper = null
	_viewport.process_mode = Node.PROCESS_MODE_INHERIT
	var root := Control.new()
	root.theme = HudStyle.theme()
	root.size = Vector2(TEX)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_viewport.add_child(root)
	_steps = [_step_frame.bind(root, place), _step_offers.bind(place)]
	step_ms.clear()
	_list = []
	_painted = false
	_frames_left = BUILD_FRAMES
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	set_process(true)


func _step_frame(root: Control, place: Variant) -> void:
	var title := Label.new()
	title.text = "МАРШРУТЫ · %s" % place.name
	title.position = Vector2(26, 10)
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", HudStyle.CREAM)
	root.add_child(title)
	# карта окрестностей — та же, что на панели доски (без перетаскивания, бумага, места перемещения)
	var frame := Panel.new()
	frame.position = Vector2(20, 62)
	frame.size = Vector2(420, 458)
	frame.add_theme_stylebox_override("panel", HudStyle.panel(HudStyle.PAPER, HudStyle.PAPER.darkened(0.35), 4, Vector2.ZERO, false))
	root.add_child(frame)
	if map_source == null or not pins.is_valid():
		return
	_atlas = Atlas.new()
	_atlas.park = true
	_atlas.position = Vector2(4, 4)
	_atlas.size = frame.size - Vector2(8, 8)
	_atlas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 20.11.2026: подложка — готовый атлас стартовой области (как у личной карты): текстура и сетки линий, без сборки
	# участков скриптом. Без атласа (сборка без C#) — прежний путь: подложку и дороги рисует узел под картой
	if map_source.atlas_texture == null:
		_paper = Control.new()
		_paper.position = _atlas.position
		_paper.size = _atlas.size
		_paper.clip_contents = true
		_paper.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_paper.draw.connect(_draw_paper)
		frame.add_child(_paper)
		_atlas.self_modulate.a = 0.0
	frame.add_child(_atlas)
	_atlas.configure_board(map_source, pins.call(place)) # у карты свой вид на общую подложку (Data.new(world, source))


## 21.11.2026: offers даёт листки (Array) или план отбора (Dictionary, InteractionService.offers_plan) — тогда
## дорогие поля (маяки, метки) считаются по одному за кадр через offers_next, и только попавшие на доску
func _step_offers(place: Variant) -> void:
	var got: Variant = offers.call(place) if offers.is_valid() else []
	if got is Dictionary:
		_steps.append(_step_pick.bind(got, place))
	else:
		_post_offers(got, place)


func _step_pick(plan: Dictionary, place: Variant) -> void:
	var got: Variant = offers_next.call(plan)
	if got == null:
		_steps.push_front(_step_pick.bind(plan, place))  # ещё поле — следующим кадром
	else:
		_post_offers(got, place)


func _post_offers(list: Array, place: Variant) -> void:
	_list = list.slice(0, Quests.BOARD_OFFERS)
	var root: Control = _viewport.get_child(0)
	if _list.is_empty():
		var empty := Label.new()
		empty.text = "Сейчас доске\nнечего предложить"
		empty.position = Vector2(500, 230)
		empty.add_theme_font_size_override("font_size", 26)
		empty.add_theme_color_override("font_color", HudStyle.MUTED)
		root.add_child(empty)
	for i in _list.size():
		_steps.append(_step_notice.bind(root, place, i))


func _step_notice(root: Control, place: Variant, i: int) -> void:
	var q: QuestData = _list[i]
	var distance := Vector2(place.x, place.y).distance_to(Vector2(q.target.x, q.target.y)) * GameConfig.TILE
	var active_id := quests.active.id if quests != null else ""
	var reward := quests.reward_points(q.id) if quests != null else 0
	var note := QuestNotice.build(q, NOTICE, 1.0, Callable(), "ВЗЯТО" if q.id == active_id else "", distance, reward)
	note.position = Vector2(460.0 + i * (NOTICE.x + 10.0), 100)
	note.size = NOTICE
	root.add_child(note)


## Пока щит строится: шаги сборки по одному за кадр, потом ждём, пока карта соберёт участки, последний кадр — и всё замирает
func _process(_delta: float) -> void:
	if not _steps.is_empty():
		var t0 := Time.get_ticks_usec()
		var step: Callable = _steps.pop_front()
		step.call()
		# 21.11.2026: сборка щита видна в записи сессии частью «board» (раньше пряталась в неразмеченной работе)
		var spent := Time.get_ticks_usec() - t0
		tick_us["board"] = tick_us.get("board", 0) + spent
		step_ms.append(spent / 1000.0)
		return
	_frames_left -= 1
	var map_busy := _atlas != null and (_atlas._base_dirty or (_atlas._data != null and _atlas._data.pending))
	if _frames_left > 0 and map_busy:
		return
	if _paper != null and not _painted:
		_painted = true
		_paper.queue_redraw()  # данные карты готовы: рисуем подложку и ещё кадр до заморозки
		return
	_freeze()


func _draw_paper() -> void:
	if _atlas == null or _atlas._data == null:
		return
	var data = _atlas._data
	_paper.draw_set_transform(_atlas._base.position, 0.0, _atlas._base.scale)
	Atlas.Paint.tiles(_paper, data, true)
	Atlas.Paint.lines(_paper, data, _atlas._scale, true)
	_paper.draw_set_transform(Vector2.ZERO)


func _freeze() -> void:
	set_process(false)
	if _viewport == null:
		return
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_viewport.process_mode = Node.PROCESS_MODE_DISABLED


## Число узлов, обрабатываемых каждый кадр, когда щит готов (проверка: должно быть 0)
func live_work() -> int:
	return int(is_processing()) + (1 if _viewport != null and _viewport.render_target_update_mode == SubViewport.UPDATE_ALWAYS else 0)
