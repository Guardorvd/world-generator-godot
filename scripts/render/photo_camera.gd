extends CanvasLayer
## 11.8: фотоаппарат. Пешком ПКМ — достать или убрать: взгляд «в видоискатель» (обзор уже, мышь медленнее,
## шаг тише и без бега), ЛКМ — снимок в user://photos, колесо — приближение. Снимок — кадр игры без рамки
## и интерфейса. Каждый снимок записывается в shots и photo_taken (для будущих заданий «сфотографируй…»).
## Наведение на интересные места (anchors): место выбирается по углу от центра кадра с поправкой на его размер
## и дальность; если между ним и камерой нет склона (occluded) и взгляд держится на нём DWELL секунд,
## над ним всплывает название. Посещённые, цель и уже узнанные в видоискателе узнаются сразу (QUICK).
## Без мира: anchors, occluded и familiar задаёт GameWorld или изолированная сцена tools/photo_look.gd.

signal photo_taken(shot: Dictionary)  # {path, place — id места в прицеле или "", name, dist — м до места}
signal capturing(on: bool)            # кадр снимается: интерфейс игры на этот кадр прячут

const DWELL := 1.5        # с: столько держать незнакомое место в прицеле, чтобы всплыло название
const QUICK := 0.3        # с: для посещённого, цели и узнанного раньше
const ZOOMS := [1.0, 1.5, 2.0, 3.0, 4.0]
const VIEW := 0.85        # без приближения видоискатель чуть уже обычного обзора
const SENSE := 0.7        # чувствительность мыши в видоискателе; с приближением ещё во столько раз ниже
const MIN_AIM := 0.035    # «пятно» наведения — не меньше этой доли угла обзора (далёкое место ловится)
const MAX_AIM := 0.2      # и не больше этой (близкое поселение не ловится краем кадра)
const KEEP := 1.4         # выбранное место держится, пока угол меньше пятна в столько раз: без мигания на краю
const PREVIEW := 2.6      # с: сколько висит карточка снимка
const SHUTTER_COOLDOWN := 0.35
const FOLDER := "user://photos"
const AMBER := Color(1.0, 0.78, 0.30)
const GREEN := Color(0.66, 0.92, 0.58)

var active := false
var anchors: Array[Dictionary] = []  # {id, name, kind — подпись вида, pos — точка над местом, radius, reach} (м)
var occluded := Callable()           # (from: Vector3, to: Vector3) -> bool: склон закрывает место
var familiar := Callable()           # (id: String) -> bool: посещено или цель
var known := {}                      # id -> true: узнанные в видоискателе
var wanted := ""                     # 11.9: id места, снимок которого нужен для задания (Quests, шаг shoot)
var wanted_reach := INF              # м: снимок для задания — не дальше этого от места
var shots: Array[Dictionary] = []
var bike_at := Vector3.INF           # 14.3: где оставлен велосипед (середина рамы); INF — на нём или его нет
var _bike_pos := Vector2.ZERO        # метка велосипеда на экране и расстояние до него
var _bike_dist := 0.0
var _bike_dir := 0.0                 # 0 — велосипед в кадре; иначе угол стрелки у края рамки
var _bike_a := 0.0
var zoom := 0
var target := {}                     # место в прицеле
var progress := 0.0                  # 0..1: сколько выдержан взгляд на target
var named := {}                      # место, над которым всплыло название
var _shown := {}                     # последнее всплывшее название: гаснет и после ухода взгляда
var _name_a := 0.0
var _name_pos := Vector2.ZERO
var _name_dist := 0.0
var _show := 0.0                     # 0..1: рамка видоискателя выезжает при входе и уходит при выходе
var _focus := 44.0                   # полусторона скобок фокуса, px: сжимается на месте в прицеле
var _flash := 0.0
var _pick := 0.0
var _busy := false
var _cooldown := 0.0
var _capturing := false
var _pending_place := {}
var _thumb: ImageTexture
var _thumb_text := ""
var _preview := 0.0
var _view: Control
var _click: AudioStreamPlayer
var _tick: AudioStreamPlayer


func _ready() -> void:
	layer = 0 # сообщения интерфейса игры остаются поверх рамки
	_view = Control.new()
	_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	_view.draw.connect(func() -> void: _draw_view(_view))
	_view.visible = false
	add_child(_view)
	var sound := _shutter()
	_click = AudioStreamPlayer.new()
	_click.stream = sound
	_click.volume_db = -6.0
	add_child(_click)
	_tick = AudioStreamPlayer.new()
	_tick.stream = sound
	_tick.pitch_scale = 2.2
	_tick.volume_db = -20.0
	add_child(_tick)


func enter() -> void:
	active = true
	zoom = 0
	target = {}
	named = {}
	progress = 0.0
	_pick = 0.0


func exit() -> void:
	active = false
	target = {}
	named = {}
	progress = 0.0
	_cancel_capture()


func _process(dt: float) -> void:
	if _cooldown > 0.0:
		_cooldown = maxf(0.0, _cooldown - dt)
		if _cooldown == 0.0:
			_busy = false


func _exit_tree() -> void:
	active = false
	_cooldown = 0.0
	_busy = false
	_cancel_capture()


func _cancel_capture() -> void:
	if RenderingServer.frame_post_draw.is_connected(_capture_frame):
		RenderingServer.frame_post_draw.disconnect(_capture_frame)
	_pending_place = {}
	visible = true
	if _capturing:
		_capturing = false
		_busy = false
		capturing.emit(false)


## Угол обзора видоискателя (градусы) при обычном угле base
func fov(base: float) -> float:
	return rad_to_deg(2.0 * atan(tan(deg_to_rad(base * VIEW) * 0.5) / ZOOMS[zoom]))


## Во сколько раз мышь медленнее обычного
func look_scale() -> float:
	return SENSE / ZOOMS[zoom]


func zoom_by(step: int) -> void:
	var z := clampi(zoom + step, 0, ZOOMS.size() - 1)
	if z != zoom:
		zoom = z
		_tick.play()


## Кадр: наведение (пока фотоаппарат в руках), анимации рамки, названия, вспышки и карточки снимка
func update(camera: Camera3D, dt: float) -> void:
	_show = move_toward(_show, 1.0 if active else 0.0, dt / 0.22)
	_flash = maxf(0.0, _flash - dt * 3.0)
	_preview = maxf(0.0, _preview - dt)
	if active:
		_aim(camera, dt)
	_focus = lerpf(_focus, 30.0 if not target.is_empty() else 44.0, 1.0 - exp(-dt * 12.0))
	_name_a = move_toward(_name_a, 1.0 if not named.is_empty() else 0.0, dt / (0.25 if not named.is_empty() else 0.2))
	if not named.is_empty():
		_shown = named
	if _name_a > 0.0 and not _shown.is_empty() and not camera.is_position_behind(_shown.pos):
		_name_pos = camera.unproject_position(_shown.pos)
		_name_dist = camera.global_position.distance_to(_shown.pos)
	_track_bike(camera, dt)
	_view.visible = _show > 0.0 or _flash > 0.0 or _preview > 0.0
	if _view.visible:
		_view.queue_redraw()


## 14.3: метка оставленного велосипеда в видоискателе — видна сквозь склоны и лес, ближе 8 м не нужна.
## Рисуется на рамке (_view), а рамка на кадр снимка прячется (shoot), поэтому на фото метки нет.
## Вне кадра — стрелка у края рамки в его сторону
func _track_bike(camera: Camera3D, dt: float) -> void:
	var on := active and bike_at.is_finite() and camera.global_position.distance_to(bike_at) > 8.0
	_bike_a = move_toward(_bike_a, 1.0 if on else 0.0, dt / 0.25)
	if not on:
		return
	_bike_dist = camera.global_position.distance_to(bike_at)
	var local := camera.global_transform.affine_inverse() * bike_at
	var s := _view.size
	var frame := Rect2(Vector2(s.x * 0.05, s.y * 0.07), s * Vector2(0.9, 0.86)).grow(-28.0)
	if local.z < 0.0:
		var at := camera.unproject_position(bike_at)
		if frame.has_point(at):
			_bike_pos = at
			_bike_dir = 0.0
			return
	# направление на экране: по осям камеры, сзади — к нижнему краю в нужную сторону
	var d := Vector2(local.x, -local.y if local.z < 0.0 else absf(local.y) + 1.0)
	if d.length() < 0.001:
		d = Vector2.DOWN
	d = d.normalized()
	var c := frame.get_center()
	var half := frame.size * 0.5
	var t := minf(half.x / maxf(absf(d.x), 0.001), half.y / maxf(absf(d.y), 0.001))
	_bike_pos = c + d * t
	_bike_dir = d.angle() + (0.0001 if is_zero_approx(d.angle()) else 0.0)


func _aim(camera: Camera3D, dt: float) -> void:
	_pick -= dt
	if _pick <= 0.0:
		_pick = 0.1
		var found := pick(camera)
		if found.get("id") != target.get("id"):
			target = found
			named = {}
			progress = 0.0
	if target.is_empty():
		return
	var quick: bool = known.has(target.id) or (familiar.is_valid() and familiar.call(target.id))
	progress = minf(1.0, progress + dt / (QUICK if quick else DWELL))
	if progress >= 1.0 and named.is_empty():
		named = target
		if not known.has(target.id):
			known[target.id] = true
			_tick.play()


## Место в прицеле: угол до него от центра кадра меньше «пятна» — его видимого размера, но не меньше
## MIN_AIM и не больше MAX_AIM угла обзора. Из нескольких — ближайшее к центру по этой мере,
## которое не закрыто склоном (проверяются не больше трёх)
func pick(camera: Camera3D) -> Dictionary:
	var from := camera.global_position
	var forward := -camera.global_basis.z
	var view := deg_to_rad(camera.fov)
	var found: Array = []
	for a: Dictionary in anchors:
		var to: Vector3 = a.pos - from
		var d := to.length()
		if d > a.reach or d < 6.0:
			continue
		var spot := clampf(atan2(a.radius, d), view * MIN_AIM, view * MAX_AIM)
		var score := to.angle_to(forward) / spot
		if score < (KEEP if a.id == target.get("id") else 1.0):
			found.append([score, a])
	found.sort_custom(func(x: Array, y: Array) -> bool: return x[0] < y[0])
	for k in mini(found.size(), 3):
		if not occluded.is_valid() or not occluded.call(from, found[k][1].pos):
			return found[k][1]
	return {}


## ЛКМ: снимок. Рамка и интерфейс прячутся на один кадр, он сохраняется в FOLDER, потом вспышка и карточка
func shoot() -> void:
	if not active or _busy or not is_inside_tree() or is_queued_for_deletion() or not can_process():
		return
	_busy = true
	_pending_place = named.duplicate(true)
	_capturing = true
	visible = false
	# Одноразовую подписку можно отменить при exit/_exit_tree; подвешенных корутин нет.
	RenderingServer.frame_post_draw.connect(_capture_frame, CONNECT_ONE_SHOT)
	capturing.emit(true)


func _capture_frame() -> void:
	if not is_inside_tree() or is_queued_for_deletion() or not active or not can_process():
		_cancel_capture()
		return
	var place := _pending_place
	_pending_place = {}
	var image := _capture_image()
	visible = true
	_capturing = false
	_cooldown = SHUTTER_COOLDOWN
	capturing.emit(false)
	# Подписчик сигнала может закрыть игру или убрать фотоаппарат синхронно.
	if not is_instance_valid(self) or not is_inside_tree() or is_queued_for_deletion() or not active or not can_process():
		return
	if image == null or image.is_empty():
		_busy = false
		_cooldown = 0.0
		return
	_flash = 0.85
	_click.play()
	var path := _save(image)
	var thumb := image.duplicate() as Image
	thumb.resize(240, maxi(1, roundi(240.0 * image.get_height() / image.get_width())), Image.INTERPOLATE_BILINEAR)
	_thumb = ImageTexture.create_from_image(thumb)
	_preview = PREVIEW
	# dist — от камеры до края места (м): задание засчитывает снимок только вблизи
	var camera := get_viewport().get_camera_3d()
	var dist: float = maxf(0.0, camera.global_position.distance_to(place.pos) - place.radius) if not place.is_empty() and camera != null else 0.0
	_thumb_text = "Снимок сохранён" + ("" if place.is_empty() else " · «%s»" % place.name)
	if not place.is_empty() and place.id == wanted:
		_thumb_text = ("Снимок для задания · «%s»" if dist <= wanted_reach else "Далеко для задания · «%s»") % place.name
	if path.is_empty():
		_thumb_text = "Не удалось сохранить снимок"
	# снимок для задания засчитывается и без файла: на диске могло не хватить места
	var shot := {path = path, place = place.get("id", ""), name = place.get("name", ""), dist = dist}
	shots.append(shot)
	photo_taken.emit(shot)


func _capture_image() -> Image:
	var texture := get_viewport().get_texture()
	return texture.get_image() if texture != null else null


## Файл снимка в FOLDER; пусто, если не записался
static func _save(image: Image) -> String:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(FOLDER))
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var path := FOLDER.path_join("photo_%s_%03d.jpg" % [stamp, Time.get_ticks_msec() % 1000])
	image.convert(Image.FORMAT_RGB8)
	return path if image.save_jpg(path, 0.92) == OK else ""


func _draw_view(c: Control) -> void:
	var s := c.size
	var font := ThemeDB.fallback_font
	if _show > 0.0:
		var e := 1.0 - pow(1.0 - _show, 3.0)
		# рамка кадра сходится к своему месту, за ней затемнение
		var inset := Vector2(s.x * 0.05, s.y * 0.07) * (0.3 + 0.7 * e)
		var frame := Rect2(inset, s - inset * 2.0)
		var dim := Color(0, 0, 0, 0.42 * e)
		c.draw_rect(Rect2(0, 0, s.x, frame.position.y), dim)
		c.draw_rect(Rect2(0, frame.end.y, s.x, s.y - frame.end.y), dim)
		c.draw_rect(Rect2(0, frame.position.y, frame.position.x, frame.size.y), dim)
		c.draw_rect(Rect2(frame.end.x, frame.position.y, s.x - frame.end.x, frame.size.y), dim)
		_corners(c, frame, 36.0, Color(1, 1, 1, 0.85 * e), 2.5)
		var faint := Color(1, 1, 1, 0.1 * e)
		for k: float in [1.0 / 3.0, 2.0 / 3.0]:
			var x := frame.position.x + frame.size.x * k
			var y := frame.position.y + frame.size.y * k
			c.draw_line(Vector2(x, frame.position.y), Vector2(x, frame.end.y), faint, 1.0)
			c.draw_line(Vector2(frame.position.x, y), Vector2(frame.end.x, y), faint, 1.0)
		# скобки фокуса: белые; на месте в прицеле сжимаются и желтеют, с названием — зеленеют
		var center := s * 0.5
		var col := Color(1, 1, 1, 0.8 * e)
		if not target.is_empty():
			col = Color(GREEN if not named.is_empty() else AMBER, 0.95 * e)
		_corners(c, Rect2(center - Vector2.ONE * _focus, Vector2.ONE * _focus * 2.0), 10.0, col, 2.0)
		c.draw_circle(center, 1.8, col)
		if not target.is_empty() and named.is_empty() and progress > 0.0:
			c.draw_arc(center, _focus + 9.0, -PI / 2.0, -PI / 2.0 + TAU * progress, 48, Color(AMBER, 0.9 * e), 3.0)
		# счётчик снимков, приближение со шкалой, подсказка
		var top := frame.position.y + 34.0
		c.draw_circle(Vector2(frame.position.x + 26.0, top - 7.0), 6.0, Color(1, 1, 1, 0.85 * e))
		c.draw_circle(Vector2(frame.position.x + 26.0, top - 7.0), 3.0, Color(0, 0, 0, 0.6 * e))
		_text(c, font, "%d" % shots.size(), Vector2(frame.position.x + 40.0, top), 18, Color(1, 1, 1, 0.9 * e), 0.0)
		_text(c, font, "×%s" % String.num(ZOOMS[zoom], 1).trim_suffix(".0"), Vector2(frame.end.x - 22.0, top), 22, Color(1, 1, 1, 0.9 * e), 1.0)
		var mid := frame.get_center().y
		for i in ZOOMS.size():
			var y := mid + (float(ZOOMS.size() - 1) / 2.0 - i) * 16.0
			var on := i == zoom
			c.draw_line(Vector2(frame.end.x - (20.0 if on else 12.0), y), Vector2(frame.end.x - 6.0, y), Color(1, 1, 1, (0.9 if on else 0.4) * e), 2.0 if on else 1.0)
		_text(c, font, ("%s — снимок · ← → — приближение · %s — убрать фотоаппарат" % [Controls.label("photo_shoot"), Controls.label("photo")]) if Controls.joypad else "ЛКМ — снимок · Колесо — приближение · ПКМ — убрать фотоаппарат", Vector2(center.x, frame.end.y - 18.0), 15, Color(1, 1, 1, 0.75 * e), 0.5)
		# название над местом: всплывает с лёгким увеличением
		if _name_a > 0.0 and not _shown.is_empty():
			var ne := 1.0 - pow(1.0 - _name_a, 3.0)
			# выше скобок фокуса: место в прицеле почти в центре кадра
			var at := (_name_pos - Vector2(0.0, 46.0)).clamp(frame.position + Vector2(120.0, 70.0), frame.end - Vector2(120.0, 40.0))
			var sc := 0.85 + 0.15 * ne
			c.draw_set_transform(at, 0.0, Vector2(sc, sc))
			var a := ne * e
			_text(c, font, _shown.name, Vector2(0.0, -30.0), 26, Color(1.0, 0.97, 0.88, a), 0.5)
			_text(c, font, "%s · %s" % [_shown.kind, _distance(_name_dist)], Vector2(0.0, -10.0), 15, Color(1, 1, 1, 0.75 * a), 0.5)
			if _shown.id == wanted:
				var close := maxf(0.0, _name_dist - _shown.radius) <= wanted_reach
				_text(c, font, "Снимок для задания · ЛКМ" if close else "Для задания — подойдите ближе %s" % _distance(wanted_reach),
					Vector2(0.0, -58.0), 15, Color(GREEN if close else AMBER, a), 0.5)
			c.draw_colored_polygon(PackedVector2Array([Vector2(-5, -1), Vector2(5, -1), Vector2(0, 5)]), Color(1, 1, 1, 0.8 * a))
			c.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if _bike_a > 0.0 and _show > 0.0:
		_draw_bike(c, font, _bike_a * _show)
	# карточка последнего снимка: выезжает справа, чуть повёрнута, гаснет
	if _preview > 0.0 and _thumb != null:
		var t := PREVIEW - _preview
		var slide := 1.0 - pow(1.0 - clampf(t / 0.3, 0.0, 1.0), 3.0)
		var fade := clampf(_preview / 0.4, 0.0, 1.0)
		var size := Vector2(_thumb.get_size())
		var at := Vector2(s.x - size.x * 0.5 - 50.0 + (1.0 - slide) * (size.x + 80.0), s.y - size.y * 0.5 - 110.0)
		c.draw_set_transform(at, deg_to_rad(-3.0) * slide, Vector2.ONE)
		c.draw_rect(Rect2(-size * 0.5 - Vector2(6, 6), size + Vector2(12, 34)), Color(0.97, 0.96, 0.92, fade))
		c.draw_texture_rect(_thumb, Rect2(-size * 0.5, size), false, Color(1, 1, 1, fade))
		_text(c, font, _thumb_text, Vector2(0.0, size.y * 0.5 + 21.0), 13, Color(0.15, 0.13, 0.1, fade), 0.5, false)
		c.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if _flash > 0.0:
		c.draw_rect(Rect2(Vector2.ZERO, s), Color(1, 1, 1, _flash * _flash))


## Метка велосипеда: голубой ромб (как на картах) с подписью расстояния, у края кадра — стрелка наружу
func _draw_bike(c: Control, font: Font, a: float) -> void:
	var blue := Color(0.25, 0.65, 1.0, 0.95 * a)
	var p := _bike_pos
	if _bike_dir == 0.0:
		var r := 7.0
		var diamond := PackedVector2Array([p + Vector2(0, -r), p + Vector2(r, 0), p + Vector2(0, r), p + Vector2(-r, 0)])
		c.draw_colored_polygon(diamond, blue)
		diamond.append(diamond[0])
		c.draw_polyline(diamond, Color(1, 1, 1, 0.9 * a), 1.5)
	else:
		var f := Vector2.from_angle(_bike_dir)
		var tri := PackedVector2Array([p + f * 10.0, p - f * 6.0 + f.orthogonal() * 7.0, p - f * 6.0 - f.orthogonal() * 7.0])
		c.draw_colored_polygon(tri, blue)
		tri.append(tri[0])
		c.draw_polyline(tri, Color(1, 1, 1, 0.9 * a), 1.5)
	var below := 22.0 if p.y < _view.size.y * 0.8 else -14.0
	_text(c, font, "Велосипед · %s" % _distance(_bike_dist), p + Vector2(0.0, below), 13, Color(0.85, 0.93, 1.0, 0.9 * a), 0.5)


## Уголки рамки rect длиной arm
static func _corners(c: Control, rect: Rect2, arm: float, color: Color, width: float) -> void:
	for corner: Vector2 in [rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]:
		var sx := 1.0 if corner.x < rect.get_center().x else -1.0
		var sy := 1.0 if corner.y < rect.get_center().y else -1.0
		c.draw_line(corner, corner + Vector2(arm * sx, 0.0), color, width)
		c.draw_line(corner, corner + Vector2(0.0, arm * sy), color, width)


## Строка с тенью; align: 0 — от at вправо, 0,5 — по центру, 1 — до at
static func _text(c: Control, font: Font, text: String, at: Vector2, size: int, color: Color, align: float, outline := true) -> void:
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var p := at - Vector2(w * align, 0.0)
	if outline:
		c.draw_string_outline(font, p, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, 5, Color(0, 0, 0, 0.6 * color.a))
	c.draw_string(font, p, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)


static func _distance(m: float) -> String:
	return "%d м" % roundi(m) if m < 1000.0 else "%.1f км" % (m / 1000.0)


## Звук затвора: два коротких щелчка (шум с тоном), без файлов
static func _shutter() -> AudioStreamWAV:
	var rate := 22050
	var n := int(rate * 0.16)
	var data := PackedByteArray()
	data.resize(n * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in n:
		var t := float(i) / rate
		var v := 0.0
		for click: Vector2 in [Vector2(0.0, 1.0), Vector2(0.075, 0.7)]: # (время, громкость)
			var u := t - click.x
			if u >= 0.0:
				v += (rng.randf_range(-1.0, 1.0) * 0.6 + sin(u * TAU * 900.0) * 0.4) * click.y * exp(-u / 0.008)
		data.encode_s16(i * 2, int(clampf(v * 0.8, -1.0, 1.0) * 32767.0))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = rate
	stream.data = data
	return stream
