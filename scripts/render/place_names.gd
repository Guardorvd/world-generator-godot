extends RefCounted
## Ближние названия: цель имеет приоритет, затем ближайшее место. Без перестановки подписей.
## С 11.8 видны только названия посещённых мест и цели; остальные узнают через фотоаппарат (PhotoCamera).
## В видоискателе подписи над миром спрятаны: снимок без них.
const FADE_FROM := 180.0
const RANGE := 300.0
const GOAL_FADE_FROM := 300.0
const GOAL_RANGE := 450.0
var _items: Array[Dictionary] = []
var _goal_id := ""
var _timer := 0.0


func setup(root: Node3D) -> void:
	for child in root.get_children():
		if child is Label3D and child.has_meta("place_id"):
			var label := child as Label3D
			var font := label.font if label.font != null else ThemeDB.fallback_font
			var size := font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, label.font_size)
			size.y = font.get_height(label.font_size)
			_items.append({label = label, color = label.modulate, alpha = 0.0, want = 0.0, size = size})
			label.visible = false


func set_goal(goal: Dictionary) -> void:
	_goal_id = str(goal.get("id", goal.get("key", "")))
	_timer = 0.0


## visited — посещённые места (Hud.visited); hidden — спрятать все подписи сразу (фотоаппарат)
func update(camera: Camera3D, dt: float, visited: Dictionary, hidden := false) -> void:
	_timer -= dt
	if _timer <= 0.0:
		_timer = 0.1
		_select(camera, visited)
	for item: Dictionary in _items:
		var label: Label3D = item.label
		item.alpha = 0.0 if hidden else lerpf(item.alpha, item.want, 1.0 - exp(-dt * 10.0))
		label.visible = item.alpha > 0.01
		var selected: bool = label.get_meta("place_id") == _goal_id
		var color: Color = Color(1.0, 0.88, 0.50) if selected else item.color
		color.a = item.alpha
		label.modulate = color
		label.outline_size = 12 if selected else 8
		label.outline_modulate = Color(0.40, 0.24, 0.05, item.alpha * 0.95) if selected else Color(0, 0, 0, item.alpha * 0.7)


func _select(camera: Camera3D, visited: Dictionary) -> void:
	var candidates: Array[Dictionary] = []
	var view := camera.get_viewport().get_visible_rect()
	var pixels := (view.size.y if camera.keep_aspect == Camera3D.KEEP_HEIGHT else view.size.x) / (2.0 * tan(deg_to_rad(camera.fov) * 0.5))
	for item: Dictionary in _items:
		item.want = 0.0
		var label: Label3D = item.label
		var selected: bool = label.get_meta("place_id") == _goal_id
		if not selected and not visited.has(label.get_meta("place_id")):
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
