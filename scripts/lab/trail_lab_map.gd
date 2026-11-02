extends Control
signal site_clicked(index: int)
var sites: Array = []
var world_size := 0.0
var selected := -1
var texture: ImageTexture
var slot_a
var slot_b
var world_seed := 0

func set_world(snapshot: Dictionary, places: Array) -> void:
	sites = places.duplicate(true)
	world_size = float(snapshot.get("size", 0)) * GameConfig.TILE
	world_seed = snapshot.get("seed", 0)
	if world_size <= 0: return
	var n: int = snapshot.size
	var pixels := mini(192, n)
	var image := Image.create(pixels, pixels, false, Image.FORMAT_RGB8)
	var low := INF
	var high := -INF
	for h in snapshot.heights: low = minf(low, h); high = maxf(high, h)
	for z in pixels:
		for x in pixels:
			var i := mini(n - 1, z * n / pixels) * n + mini(n - 1, x * n / pixels)
			var t := inverse_lerp(low, maxf(low + 1.0, high), float(snapshot.heights[i]))
			var color := Color(0.12, 0.22, 0.16).lerp(Color(0.75, 0.73, 0.57), t)
			if snapshot.water[i] != 0: color = Color(0.12, 0.32, 0.55)
			var input = snapshot.get("input")
			if input != null:
				# The scout's blocked mask also contains infrastructure; it is not all water.
				color = Color(0.12, 0.22, 0.16).lerp(Color(0.75, 0.73, 0.57), t)
				if input.forbidden[i] != 0: color = Color(0.52, 0.32, 0.20)
				if input.water[i] != 0 or input.rivers[i] != 0: color = Color(0.12, 0.32, 0.55)
			image.set_pixel(x, z, color)
	texture = ImageTexture.create_from_image(image)
	queue_redraw()

func map_rect() -> Rect2:
	var side := minf(size.x, size.y)
	return Rect2((size - Vector2.ONE * side) * 0.5, Vector2.ONE * side)

func point(at: Vector2) -> Vector2:
	var rect := map_rect()
	return rect.position + at / maxf(1, world_size) * rect.size

func _draw() -> void:
	if texture == null: return
	draw_texture_rect(texture, map_rect(), false)
	for i in sites.size():
		var site: Dictionary = sites[i]
		var region: Rect2i = site.region
		var color := Color(0.9, 0.9, 0.8, 0.18)
		if i == selected: color = Color(1, 0.8, 0.2, 0.9)
		draw_rect(Rect2(point(Vector2(region.position) * GameConfig.TILE), Vector2(region.size) * GameConfig.TILE / world_size * map_rect().size), color, false, 2 if i == selected else 1)
		if i == selected:
			var pts := PackedVector2Array()
			for p: Vector2 in site.probe.points: pts.append(point(p))
			if pts.size() > 1: draw_polyline(pts, Color(1, 0.8, 0.2), 2)
	_draw_slot(slot_a, Color(0.2, 0.8, 1))
	_draw_slot(slot_b, Color(1, 0.35, 0.6))

func _draw_slot(project, color: Color) -> void:
	if project == null or int(project.source.provenance.get("world_seed", -1)) != world_seed: return
	var offset := Vector2(project.source.provenance.get("origin", Vector2i.ZERO)) * GameConfig.TILE
	for route in project.routes:
		var pts := PackedVector2Array()
		for p in route.points: pts.append(point(p + offset))
		if pts.size() > 1: draw_polyline(pts, color, 2)

func pick(local: Vector2) -> int:
	if not map_rect().has_point(local) or world_size <= 0: return -1
	var world := (local - map_rect().position) / map_rect().size * world_size
	var best := -1
	var distance := INF
	for i in sites.size():
		var region: Rect2i = sites[i].region
		if not Rect2(Vector2(region.position) * GameConfig.TILE, Vector2(region.size) * GameConfig.TILE).has_point(world): continue
		var pts: PackedVector2Array = sites[i].probe.points
		for k in range(1, pts.size()):
			var d := Grid.segment_dist(world.x, world.y, pts[k - 1].x, pts[k - 1].y, pts[k].x, pts[k].y)
			if d < distance: distance = d; best = i
	return best

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var index := pick(event.position)
		if index >= 0: selected = index; queue_redraw(); site_clicked.emit(index)
