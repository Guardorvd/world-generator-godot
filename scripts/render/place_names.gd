extends RefCounted
## Ближние названия: цель имеет приоритет, затем ближайшее место. Без перестановки подписей.
## С 11.8 видны только названия посещённых мест и цели; остальные узнают через фотоаппарат (PhotoCamera).
## С 11.9+ и названия мест взятых заданий.
## В видоискателе подписи над миром спрятаны: снимок без них.
## 14.3: слева от названия — пиктограмма вида места (поселение, вершина, озеро, руины и вышки), под ним —
## тонкая черта до земли: видно, к какой точке относится подпись. Гаснут вместе с названием.
const FADE_FROM := 180.0
const ICONS := {
	settlement = preload("res://resources/icons/home.svg"),
	peak = preload("res://resources/icons/place_peak.svg"),
	lake = preload("res://resources/icons/place_lake.svg"),
	site = preload("res://resources/icons/place_site.svg"),
}
const STEM := 0.12   # ширина черты до земли, м
const RANGE := 300.0
const GOAL_FADE_FROM := 300.0
const GOAL_RANGE := 450.0
var _items: Array[Dictionary] = []
var _goal_id := ""
var _timer := 0.0


## heights — чтобы черта под подписью доставала до земли (без него — 6 м)
func setup(root: Node3D, heights: Heightfield = null) -> void:
	for child in root.get_children():
		if child is Label3D and child.has_meta("place_id"):
			var label := child as Label3D
			# у вершин раньше вместо пиктограммы был знак в тексте
			label.text = label.text.trim_prefix("▲ ")
			var font := label.font if label.font != null else ThemeDB.fallback_font
			var size := font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, label.font_size)
			size.y = font.get_height(label.font_size)
			var kind: String = str(label.get_meta("place_id")).get_slice(":", 0)
			var icon := _icon(label, kind, size)
			var stem := _stem(label, heights)
			# пиктограмма слева от текста: подпись в целом шире на неё
			size.x += icon.texture.get_width() + 12.0 if icon != null else 0.0
			_items.append({label = label, color = label.modulate, alpha = 0.0, want = 0.0, size = size, icon = icon, stem = stem})
			label.visible = false


func _icon(label: Label3D, kind: String, size: Vector2) -> Sprite3D:
	if not ICONS.has(kind):
		return null
	var icon := Sprite3D.new()
	icon.texture = ICONS[kind]
	icon.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	icon.fixed_size = true
	icon.pixel_size = label.pixel_size
	icon.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	icon.no_depth_test = label.no_depth_test
	icon.render_priority = label.render_priority
	icon.offset = Vector2(-(size.x + icon.texture.get_width()) * 0.5 - 8.0, 0.0)
	icon.visibility_range_end = label.visibility_range_end
	icon.visible = false
	label.add_child(icon)
	return icon


## Черта от подписи до земли: узкая полоска, повёрнутая к камере только вокруг вертикали
func _stem(label: Label3D, heights: Heightfield) -> MeshInstance3D:
	var drop := 6.0
	if heights != null:
		var p := label.global_position if label.is_inside_tree() else label.position
		drop = clampf(p.y - heights.ground_at(p.x, p.z), 1.0, 14.0)
	var quad := QuadMesh.new()
	quad.size = Vector2(STEM, drop - 1.2)
	quad.center_offset = Vector3(0.0, -(drop - 1.2) * 0.5 - 1.2, 0.0)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	m.billboard_keep_scale = true
	m.albedo_color = Color(1, 1, 1, 0.0)
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	var stem := MeshInstance3D.new()
	stem.mesh = quad
	stem.material_override = m
	stem.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	stem.visibility_range_end = label.visibility_range_end
	stem.visible = false
	label.add_child(stem)
	return stem


func set_goal(goal: Dictionary) -> void:
	_goal_id = str(goal.get("id", goal.get("key", "")))
	_timer = 0.0


## visited — посещённые места (Hud.visited); hidden — спрятать все подписи сразу (фотоаппарат);
## known — места взятых заданий (Quests.known, с 11.9+): их названия тоже видны
func update(camera: Camera3D, dt: float, visited: Dictionary, hidden := false, known := {}) -> void:
	_timer -= dt
	if _timer <= 0.0:
		_timer = 0.1
		_select(camera, visited, known)
	for item: Dictionary in _items:
		var label: Label3D = item.label
		item.alpha = 0.0 if hidden else lerpf(item.alpha, item.want, Util.damp(10.0, dt))
		label.visible = item.alpha > 0.01
		var selected: bool = label.get_meta("place_id") == _goal_id
		var color: Color = Color(1.0, 0.88, 0.50) if selected else item.color
		color.a = item.alpha
		label.modulate = color
		label.outline_size = 12 if selected else 8
		label.outline_modulate = Color(0.40, 0.24, 0.05, item.alpha * 0.95) if selected else Color(0, 0, 0, item.alpha * 0.7)
		var icon: Sprite3D = item.icon
		if icon != null:
			icon.visible = label.visible
			icon.modulate = color
		var stem: MeshInstance3D = item.stem
		stem.visible = label.visible
		(stem.material_override as StandardMaterial3D).albedo_color = Color(color, item.alpha * 0.45)


func _select(camera: Camera3D, visited: Dictionary, known: Dictionary) -> void:
	var candidates: Array[Dictionary] = []
	var view := camera.get_viewport().get_visible_rect()
	var pixels := (view.size.y if camera.keep_aspect == Camera3D.KEEP_HEIGHT else view.size.x) / (2.0 * tan(deg_to_rad(camera.fov) * 0.5))
	for item: Dictionary in _items:
		item.want = 0.0
		var label: Label3D = item.label
		var selected: bool = label.get_meta("place_id") == _goal_id
		if not selected and not visited.has(label.get_meta("place_id")) and not known.has(label.get_meta("place_id")):
			continue
		var distance := camera.global_position.distance_to(label.global_position)
		var limit := GOAL_RANGE if selected else RANGE
		if distance >= limit or camera.is_position_behind(label.global_position):
			continue
		var at := camera.unproject_position(label.global_position)
		var size: Vector2 = item.size * label.pixel_size * pixels
		var rect := Rect2(at - size * 0.5, size).grow(7.0)
		if not view.intersects(rect):
			continue
		item.rect = rect
		item.distance = distance
		item.selected = selected
		candidates.append(item)
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.selected if a.selected != b.selected else a.distance < b.distance)
	var occupied: Array[Rect2] = []
	for item: Dictionary in candidates:
		var overlaps := false
		for rect: Rect2 in occupied:
			if rect.intersects(item.rect):
				overlaps = true
				break
		if overlaps:
			continue
		var fade_from := GOAL_FADE_FROM if item.selected else FADE_FROM
		var limit := GOAL_RANGE if item.selected else RANGE
		item.want = (1.0 - smoothstep(fade_from, limit, item.distance)) * smoothstep(15.0, 30.0, item.distance)
		if item.want > 0.05:
			occupied.append(item.rect)
