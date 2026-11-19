extends RefCounted
## Подложка карт в мировых метрах (x, z). Окна делят индекс плана и текстуры
## стартовой области. Видимые линии и потоковые участки у каждого окна свои.

const Topology = preload("res://scripts/world/road_topology.gd")
const TILE := GameConfig.TILE
const CELLS := OuterLand.C
const SPAN := CELLS * TILE
const EMPTY := Color("#e9ece8")
const WATER := Color("#a4d4ed")
const PALETTE := [
	Color("#8cc1e1"), Color("#99cce8"), Color("#b0dbf0"), WATER,
	Color("#f7ecd5"), Color("#f1e7d1"), Color("#ecebcd"), Color("#e7ebd6"),
	Color("#dfeccf"), Color("#c5e3cd"), Color("#b7dcc4"), Color("#c0dcd1"),
	Color("#bddbcc"), Color("#e2e9dd"), Color("#f6f7f5"), Color("#dddcd6"),
	Color("#fafbf9"), Color("#e8e4d8"),
]

enum Line { RIVER, TRAIL, ROAD, BIKE_TRAIL }

var world: WorldData
var atlas_texture: ImageTexture
var atlas_strokes: Array[ArrayMesh] = []
var tiles := {}
var strokes: Array[PackedVector2Array] = [PackedVector2Array(), PackedVector2Array(), PackedVector2Array(), PackedVector2Array()]
var settlements: Array[Dictionary] = []
var pending := false
var feature_revision := 0
var tile_revision := 0
var park := false
var _plan_rect: Rect2i
var _base_biomes: PackedByteArray
var _base_lakes: PackedByteArray
var _base_heights: PackedFloat32Array
var _base_bins := {}
var _base_textures := {}
var _region_images := {}
var _outer_bins := {}
var _outer_trails: Array
var _outer_settlements: Array
var _region_count := -1
var _visible_bins := Rect2i()
var _keys: Array[Vector2i] = []
var _was_using_outer := false
var _outer_version := -1
var _outer_chunks := -1
var _line_id := 0


func _init(w: WorldData, source = null) -> void:
	world = w
	_plan_rect = Rect2i(0, 0, w.W, w.H)
	_base_biomes = w.biome
	_base_lakes = w.lake
	_base_heights = w.h
	if source != null:
		atlas_texture = source.atlas_texture
		atlas_strokes = source.atlas_strokes
		_base_bins = source._base_bins
		_base_textures = source._base_textures
		_region_images = source._region_images
		_line_id = source._line_id
		return
	for river: Array in w.rivers:
		_index_line(_base_bins, river, Line.RIVER)
	for section: Dictionary in Topology.sections(w).values():
		_index_line(_base_bins, section.pts, Line.ROAD if section.kind == "road" else Line.TRAIL)
	_index_bike_trails(_base_bins, w.trail_plan)
	for place in w.settlements:
		_index_settlement(_base_bins, place.x, place.y, place.name)


func prepare_atlas() -> void:
	if atlas_texture != null:
		return
	var painter := Grid.fast_grid()
	if painter == null or world.W <= 0 or world.H <= 0:
		return
	var rgb: PackedByteArray = painter.PaintAtlas(world.W * world.H, _base_biomes, _base_lakes, _palette_bytes())
	atlas_texture = ImageTexture.create_from_image(Image.create_from_data(world.W, world.H, false, Image.FORMAT_RGB8, rgb))
	# The atlas shows the complete plan. It keeps these meshes when closed or zoomed.
	_collect_features(_bin_rect(Rect2(Vector2.ZERO, Vector2(world.W, world.H) * TILE)))
	for paths in strokes:
		atlas_strokes.append(_atlas_mesh(paths))
	for nodes in strokes:
		nodes.clear()
	settlements.clear()


static func _atlas_mesh(lines: PackedVector2Array) -> ArrayMesh:
	if lines.is_empty():
		return null
	var vertices := PackedVector2Array()
	var uv := PackedVector2Array()
	var indices := PackedInt32Array()
	var count := lines.size() / 2
	vertices.resize(count * 4)
	uv.resize(count * 4)
	indices.resize(count * 6)
	for i in count:
		var a := lines[i * 2]
		var b := lines[i * 2 + 1]
		var normal_angle := (b - a).orthogonal().angle()
		var v := i * 4
		vertices[v] = a
		vertices[v + 1] = a
		vertices[v + 2] = b
		vertices[v + 3] = b
		var left := Vector2(normal_angle, -1.0)
		var right := Vector2(normal_angle, 1.0)
		uv[v] = left
		uv[v + 1] = right
		uv[v + 2] = left
		uv[v + 3] = right
		var t := i * 6
		indices[t] = v
		indices[t + 1] = v + 1
		indices[t + 2] = v + 2
		indices[t + 3] = v + 1
		indices[t + 4] = v + 3
		indices[t + 5] = v + 2
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.custom_aabb = mesh.get_aabb().grow(40.0) # include the shader-expanded edges when culling
	return mesh


func outer_changed() -> bool:
	return _was_using_outer and world.outer != null and (_outer_version != world.outer.ledger_version or _outer_chunks != world.outer.chunks.size())


func uses_outer() -> bool:
	return _was_using_outer


## Вызывать и на месте: соседние области могут приехать из потока после остановки.
func update(view: Rect2, tile_budget := 0, allow_outer := true) -> bool:
	var padded_view := view.grow(8.0)
	var visible_bins := _bin_rect(padded_view)
	var bins_changed := visible_bins != _visible_bins
	var features_changed := bins_changed
	var uses_outer := allow_outer and world.outer != null and not Rect2(Vector2.ZERO, Vector2(_plan_rect.size) * TILE).encloses(padded_view)
	if not uses_outer and not _was_using_outer and not pending and not features_changed:
		return false
	if not uses_outer and _was_using_outer and not _outer_bins.is_empty():
		_outer_bins.clear()
		_region_count = -1
		features_changed = true
	_was_using_outer = uses_outer
	var tiles_changed := false
	var work := 0
	pending = false
	var regions: Dictionary = {}
	var chunks: Dictionary = {}
	if uses_outer:
		_outer_version = world.outer.ledger_version
		_outer_chunks = world.outer.chunks.size()
		var ledger := world.outer.get_ledger()
		regions = ledger.get("regions", {})
		chunks = world.outer.chunks
		features_changed = _update_outer_features(ledger, regions) or features_changed
	for key: Vector2i in tiles.keys():
		if not visible_bins.has_point(key):
			tiles.erase(key)
			tiles_changed = true
	# 18.11.2026: ближние к середине окна участки первыми, в бюджет идут только собранные картинки (готовая текстура
	# плана из _base_textures почти ничего не стоит) — при бюджете середина карты не ждёт края
	if bins_changed:
		_keys.clear()
		for y in range(visible_bins.position.y, visible_bins.end.y):
			for x in range(visible_bins.position.x, visible_bins.end.x):
				_keys.append(Vector2i(x, y))
		var mid := view.get_center() / SPAN - Vector2.ONE * 0.5
		_keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return Vector2(a).distance_squared_to(mid) < Vector2(b).distance_squared_to(mid))
	for key: Vector2i in _keys:
		if tile_budget > 0 and work >= tile_budget:
			pending = pending or uses_outer or not tiles.has(key)
			continue
		var change := _update_tile(key, chunks, regions)
		if change != 0:
			tiles_changed = true
		if change == 2:
			work += 1
	if features_changed:
		_visible_bins = visible_bins
		_collect_features(visible_bins)
		feature_revision += 1
	if tiles_changed:
		tile_revision += 1
	return tiles_changed or features_changed


func release_view() -> void:
	tiles.clear()
	_keys.clear()
	_visible_bins = Rect2i()
	pending = false


func _update_outer_features(ledger: Dictionary, regions: Dictionary) -> bool:
	var trails: Array = ledger.get("trails", _outer_trails)
	var places: Array = ledger.get("settlements", _outer_settlements)
	if _region_count == regions.size() and is_same(trails, _outer_trails) and is_same(places, _outer_settlements):
		return false
	# Журнал может смениться при выгрузке полей. Храним ссылки только на линии
	# и места, чтобы карта не удерживала в памяти старые поля соседних областей.
	_region_count = regions.size()
	_outer_trails = trails
	_outer_settlements = places
	_outer_bins.clear()
	for section: Dictionary in trails:
		if section.kind != "animal":
			_index_line(_outer_bins, section.pts, Line.ROAD if section.kind == "road" else Line.TRAIL)
	for place in places:
		_index_settlement(_outer_bins, place.x, place.y, place.name)
	for region: Dictionary in regions.values():
		_index_bike_trails(_outer_bins, region.get("trail_plan", {}))
	return true


## 0 — участок не менялся, 1 — сменился без сборки (готовая текстура, убран), 2 — собрана новая картинка
func _update_tile(key: Vector2i, chunks: Dictionary, regions: Dictionary) -> int:
	var origin := key * CELLS
	var rect := Rect2i(origin, Vector2i(CELLS, CELLS))
	var inside := rect.intersects(_plan_rect)
	var plan_tile := _plan_rect.encloses(rect)
	var style_key := Vector3i(key.x, key.y, int(park))
	if plan_tile:
		if tiles.has(key):
			return 0
		if _base_textures.has(style_key):
			tiles[key] = {texture = _base_textures[style_key], fields = null, chunk = null}
			return 1
	var region_key := world.region_at(origin)
	var entry: Dictionary = regions.get(region_key, {})
	var fields: Variant = entry.get("fields")
	var chunk: Variant = chunks.get(key) if fields == null else null
	var old: Dictionary = tiles.get(key, {})
	var png: PackedByteArray = entry.get("map", PackedByteArray())
	var archived := fields == null and not png.is_empty()
	if (not old.is_empty() and is_same(fields, old.fields)
			and (old.get("used_archive", false) or is_same(chunk, old.chunk)) and archived == old.get("archived", false)):
		return 0
	var archive := _region_image(region_key, png) if archived else null
	if not inside and fields == null and chunk == null and archive == null:
		return 1 if tiles.erase(key) else 0
	# 18.11.2026: байты RGB8 вместо Image.set_pixel на каждую из 4096 клеток — участок собирается в разы быстрее
	var rgb := PackedByteArray()
	rgb.resize(CELLS * CELLS * 3)
	var region_rect: Rect2i = entry.get("rect", Rect2i())
	var archive_rect := Rect2i(region_rect.position, archive.get_size()).intersection(region_rect) if archive != null else Rect2i()
	var archive_covers_tile := archive_rect.encloses(rect)
	var regional_biomes: PackedByteArray = fields.biome if fields != null else PackedByteArray()
	var regional_lakes: PackedByteArray = fields.lake if fields != null else PackedByteArray()
	var regional_rivers: PackedByteArray = fields.river if fields != null else PackedByteArray()
	var chunk_biomes: PackedByteArray = chunk.biome if chunk != null else PackedByteArray()
	var bytes := _palette_bytes()
	var water := PALETTE.size() * 3
	var empty := water + 3
	var o := 0
	for y in CELLS:
		for x in CELLS:
			var cell := origin + Vector2i(x, y)
			var at := empty   # смещение цвета в bytes; -1 — цвет посчитан в color
			var color := EMPTY
			if _plan_rect.has_point(cell):
				var i := cell.y * world.W + cell.x
				if i < _base_biomes.size():
					at = _base_biomes[i] * 3
				if i < _base_lakes.size() and _base_lakes[i] != 0:
					at = water
				elif park and i < _base_biomes.size() and _base_biomes[i] >= Biomes.BEACH and _base_heights.size() == world.N:
					color = _paper_relief(cell, i, PALETTE[_base_biomes[i]])
					at = -1
			elif fields != null and region_rect.has_point(cell):
				var local := cell - region_rect.position
				var i := local.y * region_rect.size.x + local.x
				at = water if regional_lakes[i] != 0 or regional_rivers[i] != 0 else regional_biomes[i] * 3
			elif archive_rect.has_point(cell):
				color = archive.get_pixelv(cell - region_rect.position).lerp(EMPTY, 0.42)
				at = -1
			elif chunk != null:
				# У сырых кусков OuterLand по краям есть запас для меша.
				at = chunk_biomes[(y + 1) * (CELLS + 3) + x + 1] * 3
			if at >= 0:
				rgb[o] = bytes[at]
				rgb[o + 1] = bytes[at + 1]
				rgb[o + 2] = bytes[at + 2]
			else:
				rgb[o] = color.r8
				rgb[o + 1] = color.g8
				rgb[o + 2] = color.b8
			o += 3
	var texture := ImageTexture.create_from_image(Image.create_from_data(CELLS, CELLS, false, Image.FORMAT_RGB8, rgb))
	if plan_tile:
		_base_textures[style_key] = texture
	tiles[key] = {texture = texture, fields = fields, chunk = null if archive_covers_tile else chunk,
		archived = archived, used_archive = archive_covers_tile}
	return 2


static var _palette_rgb := PackedByteArray()

## PALETTE, затем WATER и EMPTY байтами RGB8 (по 3 на цвет)
static func _palette_bytes() -> PackedByteArray:
	if _palette_rgb.is_empty():
		for color: Color in PALETTE + [WATER, EMPTY]:
			_palette_rgb.append_array(PackedByteArray([color.r8, color.g8, color.b8]))
	return _palette_rgb


func _region_image(key: Vector2i, png: PackedByteArray) -> Image:
	if not _region_images.has(key):
		var image := Image.new()
		if _region_images.size() >= 12:
			_region_images.erase(_region_images.keys()[0])
		_region_images[key] = image if image.load_png_from_buffer(png) == OK else null
	return _region_images[key]


func _paper_relief(cell: Vector2i, index: int, color: Color) -> Color:
	var h := _base_heights[index] * GameConfig.HS
	var west := _base_heights[index - 1] * GameConfig.HS if cell.x > 0 else h
	var north := _base_heights[index - world.W] * GameConfig.HS if cell.y > 0 else h
	var color_at_height := color * (1.0 + clampf((west + north - 2.0 * h) * 0.012, -0.12, 0.09))
	if floori(h / 15.0) != floori(west / 15.0) or floori(h / 15.0) != floori(north / 15.0):
		color_at_height = color_at_height.lerp(Color("#8f7b50"), 0.25)
	return color_at_height


func _collect_features(visible_bins: Rect2i) -> void:
	for i in strokes.size():
		strokes[i].clear()
	settlements.clear()
	for bins: Dictionary in [_base_bins, _outer_bins]:
		var seen := {}
		for y in range(visible_bins.position.y, visible_bins.end.y):
			for x in range(visible_bins.position.x, visible_bins.end.x):
				for feature: Dictionary in bins.get(Vector2i(x, y), []):
					if feature.has("points"):
						if not seen.has(feature.id):
							seen[feature.id] = true
							var points: PackedVector2Array = feature.points
							for i in range(1, points.size()):
								strokes[feature.kind].append(points[i - 1])
								strokes[feature.kind].append(points[i])
					else:
						settlements.append(feature)


## Длинные линии разбиваются на короткие ломаные с общей точкой на стыке.
func _index_line(bins: Dictionary, points: Array, kind: Line) -> void:
	var line := PackedVector2Array()
	for point in points:
		line.append(Vector2(point.x, point.y) * TILE)
	_index_world_line(bins, line, kind)


func _index_bike_trails(bins: Dictionary, plan: Dictionary) -> void:
	if plan.get("state") != "found" or not plan.has("definition"):
		return
	for definition: Dictionary in plan.get("routes", [plan.definition]):
		_index_world_line(bins, definition.get("points", PackedVector2Array()), Line.BIKE_TRAIL)


func _index_world_line(bins: Dictionary, points: PackedVector2Array, kind: Line) -> void:
	for start in range(0, points.size() - 1, 23):
		var line := points.slice(start, start + 24)
		var bounds := Rect2(line[0], Vector2.ZERO)
		for point: Vector2 in line:
			bounds = bounds.expand(point)
		var cells := _bin_rect(bounds)
		# Уникальный идентификатор нужен, когда одну линию видят несколько участков.
		var feature := {id = _line_id, kind = kind, points = line}
		_line_id += 1
		for y in range(cells.position.y, cells.end.y):
			for x in range(cells.position.x, cells.end.x):
				_add_to_bin(bins, Vector2i(x, y), feature)


func _index_settlement(bins: Dictionary, x: float, y: float, title: String) -> void:
	var at := Vector2(x, y) * TILE
	_add_to_bin(bins, Vector2i((at / SPAN).floor()), {
		position = at, title = title, key = WorldData.place_id("settlement", x, y),
	})


static func _add_to_bin(bins: Dictionary, key: Vector2i, feature: Dictionary) -> void:
	if not bins.has(key):
		bins[key] = []
	bins[key].append(feature)


static func _bin_rect(rect: Rect2) -> Rect2i:
	var first := Vector2i((rect.position / SPAN).floor())
	var last := Vector2i((rect.end / SPAN).floor())
	return Rect2i(first, last - first + Vector2i.ONE)
