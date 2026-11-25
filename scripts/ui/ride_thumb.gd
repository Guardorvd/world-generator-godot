extends RefCounted
## Картинка трека на CPU: карта уже загружена, сцена и GPU не нужны.

const CONFIG = preload("res://resources/ride_journal.tres")
const RideLog = preload("res://scripts/game/ride_log.gd")


static func render(map_image: Image, world_size: Vector2, entry: Dictionary) -> Image:
	if map_image == null or map_image.is_empty() or world_size.x <= 0.0 or world_size.y <= 0.0:
		return null
	var width := maxi(1, CONFIG.thumb_width)
	var height := maxi(1, CONFIG.thumb_height)
	var canvas := Image.create(width, height, false, Image.FORMAT_RGBA8)
	canvas.fill(CONFIG.background_color)
	var legs: Array = entry.get("legs", [])
	var bounds := RideLog.bounds(entry)
	if legs.is_empty():
		bounds = Rect2(Vector2.ZERO, world_size)
	var frame: Rect2 = RideLog.framed_bounds(bounds, float(width) / float(height))
	var world := Rect2(Vector2.ZERO, world_size)
	var visible := frame.intersection(world)
	if visible.has_area():
		var source_size := Vector2(map_image.get_width(), map_image.get_height())
		var a := (visible.position / world_size * source_size).floor()
		var b := (visible.end / world_size * source_size).ceil().min(source_size)
		var source := Rect2i(Vector2i(a), Vector2i(b - a))
		if source.has_area():
			var part := map_image.get_region(source)
			part.convert(Image.FORMAT_RGBA8)
			var dest_a := _pixel(visible.position, frame, Vector2(width, height))
			var dest_b := _pixel(visible.end, frame, Vector2(width, height))
			var dest_size := Vector2i(maxi(1, dest_b.x - dest_a.x), maxi(1, dest_b.y - dest_a.y))
			part.resize(dest_size.x, dest_size.y, Image.INTERPOLATE_BILINEAR)
			canvas.blit_rect(part, Rect2i(Vector2i.ZERO, dest_size), dest_a)
	var modes: Array = entry.get("leg_modes", [])
	var first := Vector2.INF
	var last := Vector2.INF
	for index in legs.size():
		var points: PackedVector2Array = legs[index]
		var riding := bool(modes[index]) if index < modes.size() else true
		if points.is_empty():
			continue
		if not first.is_finite():
			first = points[0]
		last = points[-1]
		var outline := maxi(0, CONFIG.track_outline_width)
		# Сначала вся подложка, затем вся светлая линия: стыки не перекрывают её обводкой.
		for pass_index in 2:
			if pass_index == 0 and outline == 0:
				continue
			var phase := 0
			var ink: Color = CONFIG.track_outline_color if pass_index == 0 else (CONFIG.bike_color if riding else CONFIG.foot_color)
			var line_width: int = CONFIG.track_width + outline * 2 if pass_index == 0 else CONFIG.track_width
			for i in range(1, points.size()):
				var from := _pixel(points[i - 1], frame, Vector2(width, height))
				var to := _pixel(points[i], frame, Vector2(width, height))
				if from != to:
					phase = _line(canvas, from, to, ink, not riding, phase, line_width)
	if first.is_finite():
		_marker(canvas, _pixel(first, frame, Vector2(width, height)), CONFIG.start_color, false)
		_marker(canvas, _pixel(last, frame, Vector2(width, height)), CONFIG.finish_color, false)
	for mark: Dictionary in entry.get("fall_marks", []):
		_marker(canvas, _pixel(Vector2(float(mark.get("x", 0.0)), float(mark.get("z", 0.0))), frame, Vector2(width, height)), CONFIG.fall_color, true)
	return canvas


static func _pixel(point: Vector2, frame: Rect2, canvas_size: Vector2) -> Vector2i:
	return Vector2i(((point - frame.position) / frame.size * canvas_size).round())


static func _put(image: Image, point: Vector2i, color: Color) -> void:
	if point.x >= 0 and point.y >= 0 and point.x < image.get_width() and point.y < image.get_height():
		image.set_pixelv(point, color)


static func _line(image: Image, a: Vector2i, b: Vector2i, color: Color, dashed: bool, phase: int, line_width: int) -> int:
	var delta := b - a
	var steps := maxi(absi(delta.x), absi(delta.y))
	var dash := maxi(1, CONFIG.foot_dash)
	var width := maxi(1, line_width)
	for i in range(steps + 1):
		if not dashed or (phase / dash) % 2 == 0:
			var point := a if steps == 0 else Vector2i((Vector2(a) + Vector2(delta) * float(i) / float(steps)).round())
			for y in width:
				for x in width:
					_put(image, point + Vector2i(x - width / 2, y - width / 2), color)
		phase += 1
	return phase


static func _marker(image: Image, center: Vector2i, color: Color, cross: bool) -> void:
	var radius := maxi(1, CONFIG.marker_radius)
	for y in range(-radius, radius + 1):
		for x in range(-radius, radius + 1):
			if (cross and (x == y or x == -y)) or (not cross and x * x + y * y <= radius * radius):
				_put(image, center + Vector2i(x, y), color)
