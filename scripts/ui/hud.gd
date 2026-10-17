class_name Hud
extends Control
## Интерфейс поверх 3D: сведения о местности, мини-карта, большая карта, всплывающие сообщения,
## прицел и подсказки. Копия js/ui/hud.js.

const TILE := GameConfig.TILE
const DIRS := ["С", "СЗ", "З", "ЮЗ", "Ю", "ЮВ", "В", "СВ"]
const MINI := 200.0

var world: WorldData
var map_tex: ImageTexture
var info: Label
var minimap: MiniMap
var big_map: BigMap
var toast_label: Label
var lock_hint: Label
var _toast_left := 0.0

# Состояние игрока для отрисовки карт
var px := 0.0
var pz := 0.0
var yaw := 0.0
var visited := {}


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var crosshair := ColorRect.new()
	crosshair.color = Color(1, 1, 1, 0.8)
	_place(crosshair, Vector4(0.5, 0.5, 0.5, 0.5), Vector4(-2, -2, 2, 2))
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(crosshair)

	var info_panel := PanelContainer.new()
	info_panel.position = Vector2(14, 14)
	info_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info_panel.add_theme_stylebox_override("panel", UiStyle.panel(Color(0.04, 0.06, 0.1, 0.55), 8, 10))
	info = Label.new()
	info.add_theme_font_size_override("font_size", 15)
	info_panel.add_child(info)
	add_child(info_panel)

	minimap = MiniMap.new()
	minimap.hud = self
	_place(minimap, Vector4(1, 0, 1, 0), Vector4(-MINI - 14, 14, -14, MINI + 14))
	add_child(minimap)

	var hint := Label.new()
	hint.text = "Мышь — осмотреться · WASD — идти · Shift — бег · Пробел — прыжок · F — велосипед · M — карта · Esc — пауза"
	hint.add_theme_font_size_override("font_size", 14)
	hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.75))
	_place(hint, Vector4(0, 1, 1, 1), Vector4(0, -40, 0, -14))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(hint)

	lock_hint = _center_label("Щёлкните по экрану, чтобы управлять взглядом мышью", 0.62)
	toast_label = _center_label("", 0.16)
	toast_label.add_theme_font_size_override("font_size", 22)
	toast_label.modulate.a = 0.0

	big_map = BigMap.new()
	big_map.hud = self
	big_map.set_anchors_preset(Control.PRESET_FULL_RECT)
	big_map.mouse_filter = Control.MOUSE_FILTER_IGNORE
	big_map.visible = false
	add_child(big_map)


## Якоря (left, top, right, bottom) и отступы от них
static func _place(c: Control, anchors: Vector4, offsets: Vector4) -> void:
	c.anchor_left = anchors.x
	c.anchor_top = anchors.y
	c.anchor_right = anchors.z
	c.anchor_bottom = anchors.w
	c.offset_left = offsets.x
	c.offset_top = offsets.y
	c.offset_right = offsets.z
	c.offset_bottom = offsets.w


func _center_label(text: String, y_frac: float) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_place(l, Vector4(0, y_frac, 1, y_frac), Vector4(0, 0, 0, 40))
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	l.add_theme_constant_override("outline_size", 6)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(l)
	return l


## Новая игра: запомнить карту мира
func set_world(w: WorldData, map_image: Image) -> void:
	world = w
	map_tex = ImageTexture.create_from_image(map_image)
	visited = {}


func set_map_visible(v: bool) -> void:
	big_map.visible = v


func toast(text: String) -> void:
	toast_label.text = text
	toast_label.modulate.a = 1.0
	_toast_left = 3.5


func _process(delta: float) -> void:
	if _toast_left > 0.0:
		_toast_left -= delta
		if _toast_left <= 0.0:
			create_tween().tween_property(toast_label, "modulate:a", 0.0, 0.4)


## Положение игрока для мини-карты и большой карты
func set_player(x: float, z: float, y: float) -> void:
	px = x
	pz = z
	yaw = y
	minimap.queue_redraw()
	if big_map.visible:
		big_map.queue_redraw()


## Строки о местности под ногами: биом, высота, температура, влажность, курс, ближайшее поселение
func update_info(p: PlayerState, look_yaw: float, depth: float) -> void:
	var w := world
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
	if nearest != null:
		text += "\nДо «%s»: %d м" % [nearest.name, roundi(nd)]
	info.text = text


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
		Hud.draw_arrow(self, Vector2(hud.px / Hud.TILE * k, hud.pz / Hud.TILE * k), 6.0, hud.yaw)


## Большая карта (M): посещённые поселения отмечены жёлтым
class BigMap extends Control:
	var hud: Hud

	func _draw() -> void:
		if hud.world == null:
			return
		var w := hud.world
		var cw := size.x
		var ch := size.y
		draw_rect(Rect2(Vector2.ZERO, size), Color(8 / 255.0, 12 / 255.0, 20 / 255.0, 0.82))
		var sz := minf(cw, ch) * 0.88
		var o := Vector2((cw - sz) / 2.0, (ch - sz) / 2.0)
		var k := sz / w.W
		draw_texture_rect(hud.map_tex, Rect2(o, Vector2(sz, sz)), false)
		draw_rect(Rect2(o, Vector2(sz, sz)), Color.html("#d8c79a"), false, 2.0)
		for s in w.settlements:
			var at := o + Vector2(s.x, s.y) * k
			draw_circle(at, 3.5, Color.html("#ffdd55") if hud.visited.has("s%d" % s.i) else Color.WHITE)
			Hud.draw_label(self, s.name, at - Vector2(0, 7), Color.html("#fff6d8"), 13)
		for pk in w.peaks:
			Hud.draw_label(self, "▲ " + pk.name, o + Vector2(pk.x, pk.y) * k, Color.html("#e8f0ff"), 13)
		Hud.draw_arrow(self, o + Vector2(hud.px, hud.pz) / Hud.TILE * k, 9.0, hud.yaw)
		Hud.draw_label(self, "Карта мира «%s» — M, чтобы закрыть" % w.seed_text, Vector2(cw / 2.0, o.y - 10.0), Color.WHITE, 16)
