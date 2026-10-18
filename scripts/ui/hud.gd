class_name Hud
extends Control
## Интерфейс поверх 3D: сведения о местности, мини-карта, большая карта, всплывающие сообщения,
## прицел и подсказки. Прицел, панель сведений и надписи — узлы сцены main.tscn (правятся в редакторе),
## мини-карта и большая карта рисуются кодом (MiniMap, BigMap). Копия js/ui/hud.js. Подсказки внизу и у прицела меняются по тому, что игрок
## делает сейчас (GameWorld._update_hints); велосипед отмечен на картах, пока игрок не на нём.
## С 2.8 на большой карте можно выбрать цель путешествия (ЛКМ по поселению или вершине) — она видна
## только меткой на компасе вверху и на картах — и переместиться в любое из них (ПКМ; до 3.0.2 — только где уже побывали).
## С 2.9 к местам добавились крупные озёра с названиями (WorldData.lakes): открываются на берегу.

signal travel_requested(place: Dictionary)

const TILE := GameConfig.TILE
const DIRS := ["С", "СЗ", "З", "ЮЗ", "Ю", "ЮВ", "В", "СВ"]
const MINI := 200.0
const TOAST_TIME := 3.5 # сколько сообщение висит на экране (с)
const TOAST_FADE := 0.4 # сколько гаснет без очереди (с)
const TOAST_QUEUE := 3 # сколько сообщений ждут в очереди, старые отбрасываются
const GOLD := Color(1.0, 0.82, 0.32)  # цвет цели путешествия

var world: WorldData
var map_tex: ImageTexture
var minimap: MiniMap
var big_map: BigMap
var compass: Compass
var goal := {}  # цель путешествия — место из places() или пусто
@onready var info: Label = $InfoPanel/Info
@onready var toast_label: Label = $Toast
@onready var lock_hint: Label = $LockHint
@onready var hint: Label = $Hint
@onready var prompt: Label = $Prompt
var _toast_left := 0.0
var _toast_queue: PackedStringArray = []
var _toast_tween: Tween

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

	big_map = BigMap.new()
	big_map.hud = self
	big_map.set_anchors_preset(Control.PRESET_FULL_RECT)
	big_map.mouse_filter = Control.MOUSE_FILTER_IGNORE
	big_map.visible = false
	add_child(big_map)


## Новая игра: запомнить карту мира и забыть сообщения прошлой игры
func set_world(w: WorldData, map_image: Image) -> void:
	world = w
	map_tex = ImageTexture.create_from_image(map_image)
	visited = {}
	goal = {}
	_toast_queue.clear()
	_stop_toast_tween()
	_toast_left = 0.0
	toast_label.modulate.a = 0.0


## Выход из игры: забыть мир и карту, чтобы прошлый мир освободился, пока в меню
func clear_world() -> void:
	world = null
	map_tex = null
	visited = {}
	goal = {}


func set_map_visible(v: bool) -> void:
	big_map.visible = v
	# открытая карта ловит мышь: щелчки по ней выбирают цель и место перемещения
	big_map.mouse_filter = Control.MOUSE_FILTER_STOP if v else Control.MOUSE_FILTER_IGNORE
	big_map.hover = {}
	if v:
		big_map.queue_redraw()


## Места мира, которые можно выбрать на карте: поселения, вершины и озёра.
## {key — ключ в visited, name, x, y — клетки, kind — "settlement" | "peak" | "lake", src — запись места}
func places() -> Array:
	var out: Array = []
	if world == null:
		return out
	for s in world.settlements:
		out.append({key = "s%d" % s.i, name = s.name, x = s.x, y = s.y, kind = "settlement", src = s})
	for pk in world.peaks:
		out.append({key = "p%d" % pk.i, name = pk.name, x = pk.x, y = pk.y, kind = "peak", src = pk})
	for lk in world.lakes:
		out.append({key = "l%d" % lk.i, name = lk.name, x = lk.x, y = lk.y, kind = "lake", src = lk})
	return out


## Новая цель путешествия (пустой словарь — без цели)
func set_goal(place: Dictionary) -> void:
	goal = place
	# вне сцены (проверки без окна) карт и компаса нет
	if is_node_ready():
		compass.queue_redraw()
		minimap.queue_redraw()
		big_map.queue_redraw()


## Игрок в (x, z) метрах: если он дошёл до цели, цель снимается и возвращается текст сообщения
func check_goal(x: float, z: float) -> String:
	if goal.is_empty():
		return ""
	if goal.kind == "lake":
		if world.lake_near(x / TILE, z / TILE, PlayerState.LAKE_REACH) != goal.src.i:
			return ""
	elif Grid.hypot(goal.x - x / TILE, goal.y - z / TILE) >= (2.5 if goal.kind == "peak" else 6.0):
		return ""
	var text := "Вы добрались до цели: «%s»" % goal.name
	set_goal({})
	return text


## Курс на точку (x, z в метрах) от игрока — в тех же единицах, что yaw: 0 — север, PI/2 — запад
func heading_to(x: float, z: float) -> float:
	return atan2(-(x - px), -(z - pz))


## Строка подсказок внизу и подсказка у прицела (пустая — скрыта)
func set_hints(bottom: String, near: String) -> void:
	if hint.text != bottom:
		hint.text = bottom
	if prompt.text != near:
		prompt.text = near


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
	if _toast_left > 0.0:
		if toast_label.text == text:
			return
		if _toast_queue.is_empty() or _toast_queue[_toast_queue.size() - 1] != text:
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
	px = x
	pz = z
	yaw = y
	minimap.queue_redraw()
	compass.queue_redraw()
	if big_map.visible:
		big_map.queue_redraw()


## Строки о местности под ногами: биом, высота, температура, влажность, курс, ближайшее поселение
func update_info(p: PlayerState, look_yaw: float, depth: float) -> void:
	var w := world
	if w == null:
		return
	var ti := w.tile_info(p.x / TILE, p.z / TILE)
	if ti.is_empty():
		return
	var where: String = Biomes.LIST[ti.biome].name
	if ti.river:
		where += ", брод через реку"
	if ti.path == 2:
		where += ", тропа"
	elif ti.path == 1:
		where += ", звериная тропа"
	if depth > 0.3:
		where += " (по колено в воде)"
	var temp_c := roundi(-25.0 + ti.temp * 60.0)
	var nearest = null
	var nd := INF
	for s in w.settlements:
		var d := Grid.hypot(s.x * TILE - p.x, s.y * TILE - p.z)
		if d < nd:
			nd = d
			nearest = s
	var heading: String = DIRS[posmod(roundi(look_yaw / (PI / 4.0)), 8)]
	var text := "%s\nВысота: %d м · %s%d°C\nВлажность: %d%% · Курс: %s" % [
		where, roundi(p.feet), "+" if temp_c > 0 else "", temp_c, roundi(ti.moist * 100.0), heading]
	if not goal.is_empty():
		text += "\nЦель «%s»: %s" % [goal.name, _fmt_dist(Grid.hypot(goal.x * TILE - p.x, goal.y * TILE - p.z))]
	elif nearest != null:
		text += "\nДо «%s»: %s" % [nearest.name, _fmt_dist(nd)]
	# текст панели меняется не каждый кадр: не трогаем Label, пока строки те же
	if info.text != text:
		info.text = text


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


static func draw_label(c: CanvasItem, text: String, pos: Vector2, color: Color, font_size: int) -> void:
	var font := ThemeDB.fallback_font
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var at := pos - Vector2(w / 2.0, 0)
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
			draw_rect(Rect2(s.x * k - 1.5, s.y * k - 1.5, 3, 3), Color.html("#ffdd55"))
		if not hud.goal.is_empty():
			draw_arc(_inside(Vector2(hud.goal.x, hud.goal.y) * k, 5.0), 4.5, 0.0, TAU, 16, Hud.GOLD, 2.0)
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

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		if hud.world == null:
			return
		var half := size.x / 2.0
		var font := ThemeDB.fallback_font
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
			draw_string_outline(font, at, t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 4, Color(0, 0, 0, 0.45 * a))
			draw_string(font, at, t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.8 * a))
		if hud.goal.is_empty():
			return
		var g := hud.goal
		var off := wrapf(hud.heading_to(g.x * Hud.TILE, g.y * Hud.TILE) - hud.yaw, -PI, PI)
		var seen := absf(off) <= SPAN / 2.0
		var x := half - clampf(off / (SPAN / 2.0), -1.0, 1.0) * (half - 4.0)
		var c := Hud.GOLD if seen else Color(Hud.GOLD, 0.45)
		var y := size.y - 1.0
		draw_colored_polygon(PackedVector2Array([Vector2(x, y - 7), Vector2(x + 4, y - 3), Vector2(x, y + 1), Vector2(x - 4, y - 3)]), c)


## Большая карта (M): посещённые поселения и вершины отмечены жёлтым. С 2.8 карта ловит мышь:
## ЛКМ по месту — цель путешествия (ещё раз — снять), ПКМ по любому месту — перемещение туда (с 3.0.2 и туда, где ещё не были)
class BigMap extends Control:
	const PICK := 12.0  # на сколько пикселей можно промахнуться по метке места
	var hud: Hud
	var hover := {}     # место под курсором или пусто

	## Где на экране лежит карта: [левый верхний угол, сторона, пикселей на клетку]
	func _frame() -> Array:
		var sz := minf(size.x, size.y) * 0.88
		return [Vector2((size.x - sz) / 2.0, (size.y - sz) / 2.0), sz, sz / hud.world.W]

	## Ближайшее к точке экрана место не дальше PICK пикселей
	func _place_at(pos: Vector2) -> Dictionary:
		if hud.world == null:
			return {}
		var f := _frame()
		var best := {}
		var bd := PICK
		for pl: Dictionary in hud.places():
			var d := pos.distance_to(f[0] + Vector2(pl.x, pl.y) * f[2])
			if d < bd:
				bd = d
				best = pl
		return best

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseMotion:
			var h := _place_at(event.position)
			if h.get("key") != hover.get("key"):
				hover = h
				queue_redraw()
		elif event is InputEventMouseButton and event.pressed:
			var pl := _place_at(event.position)
			if event.button_index == MOUSE_BUTTON_LEFT and not pl.is_empty():
				var same: bool = pl.key == hud.goal.get("key")
				hud.set_goal({} if same else pl)
			elif event.button_index == MOUSE_BUTTON_RIGHT and not pl.is_empty():
				hud.travel_requested.emit(pl)
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
		draw_rect(Rect2(o, Vector2(sz, sz)), Color.html("#d8c79a"), false, 2.0)
		for s in w.settlements:
			var at := o + Vector2(s.x, s.y) * k
			draw_circle(at, 3.5, Color.html("#ffdd55") if hud.visited.has("s%d" % s.i) else Color.WHITE)
			Hud.draw_label(self, s.name, at - Vector2(0, 7), Color.html("#fff6d8"), 13)
		for pk in w.peaks:
			var col := Color.html("#ffdd55") if hud.visited.has("p%d" % pk.i) else Color.html("#e8f0ff")
			Hud.draw_label(self, "▲ " + pk.name, o + Vector2(pk.x, pk.y) * k, col, 13)
		for lk in w.lakes:
			var at := o + Vector2(lk.x, lk.y) * k
			var col := Color.html("#ffdd55") if hud.visited.has("l%d" % lk.i) else Color.html("#cfeaff")
			draw_arc(at, 3.0, 0.0, TAU, 12, col, 1.5)
			Hud.draw_label(self, lk.name, at - Vector2(0, 7), col, 12)
		if not hud.goal.is_empty():
			draw_arc(o + Vector2(hud.goal.x, hud.goal.y) * k, 9.0, 0.0, TAU, 24, Hud.GOLD, 2.5)
		if hud.bike_shown:
			Hud.draw_bike(self, _inside(o + hud.bike_pos / Hud.TILE * k, o, sz, 5.0), 5.0)
		Hud.draw_arrow(self, _inside(o + Vector2(hud.px, hud.pz) / Hud.TILE * k, o, sz, 9.0), 9.0, hud.yaw)
		# легенду про велосипед пишем, только когда он действительно нарисован
		var legend := "Карта мира «%s» — M или Esc, чтобы закрыть" % w.seed_text
		if hud.bike_shown:
			legend += " · синим отмечен велосипед"
		Hud.draw_label(self, legend, Vector2(cw / 2.0, o.y - 10.0), Color.WHITE, 16)
		Hud.draw_label(self, _found_line(), Vector2(cw / 2.0, o.y + sz + 44.0), Color(1, 1, 1, 0.6), 13)
		var tip := "Щёлкните по поселению, вершине или озеру, чтобы выбрать цель путешествия"
		if not hover.is_empty():
			var d := Grid.hypot(hover.x * Hud.TILE - hud.px, hover.y * Hud.TILE - hud.pz)
			tip = "«%s», %s · ЛКМ — %s · " % [hover.name, Hud._fmt_dist(d), "снять цель" if hover.key == hud.goal.get("key") else "цель"]
			tip += "ПКМ — переместиться сюда"
			draw_arc(o + Vector2(hover.x, hover.y) * k, 7.0, 0.0, TAU, 20, Color.WHITE, 1.5)
		Hud.draw_label(self, tip, Vector2(cw / 2.0, o.y + sz + 22.0), Color(1, 1, 1, 0.85), 15)

	## Сколько мест уже открыто: «Открыто: поселений 2 из 12 · вершин 0 из 6 · озёр 1 из 9»
	func _found_line() -> String:
		var n := {s = 0, p = 0, l = 0}
		for key: String in hud.visited:
			n[key.left(1)] += 1
		var w := hud.world
		var text := "Открыто: поселений %d из %d · вершин %d из %d" % [n.s, w.settlements.size(), n.p, w.peaks.size()]
		if not w.lakes.is_empty():
			text += " · озёр %d из %d" % [n.l, w.lakes.size()]
		return text

	## Маркер у края карты остаётся внутри её рамки
	func _inside(at: Vector2, o: Vector2, sz: float, margin: float) -> Vector2:
		return at.clamp(o + Vector2(margin, margin), o + Vector2(sz - margin, sz - margin))
