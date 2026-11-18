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
var tiles := {}
var strokes: Array[PackedVector2Array] = [PackedVector2Array(), PackedVector2Array(), PackedVector2Array(), PackedVector2Array()]
var settlements: Array[Dictionary] = []
var pending := false
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
var _was_using_outer := false
var _line_id := 0


func _init(w: WorldData, source = null) -> void:
	world = w
	_plan_rect = Rect2i(0, 0, w.W, w.H)
	_base_biomes = w.biome
	_base_lakes = w.lake
	_base_heights = w.h
	if source != null:
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


## Вызывать и на месте: соседние области могут приехать из потока после остановки.
func update(view: Rect2, tile_budget := 0) -> bool:
	var padded_view := view.grow(8.0)
	var visible_bins := _bin_rect(padded_view)
	var features_changed := visible_bins != _visible_bins
	var uses_outer := world.outer != null and not Rect2(Vector2.ZERO, Vector2(_plan_rect.size) * TILE).encloses(padded_view)
	if not uses_outer and not _was_using_outer and not pending and not features_changed:
		return false
	_was_using_outer = uses_outer
	var tiles_changed := false
	var work := 0
	pending = false
	var regions: Dictionary = {}
	var chunks: Dictionary = {}
	if uses_outer:
		var ledger := world.outer.get_ledger()
		regions = ledger.get("regions", {})
		chunks = world.outer.chunks
		features_changed = _update_outer_features(ledger, regions) or features_changed
	for key: Vector2i in tiles.keys():
		if not visible_bins.has_point(key):
			tiles.erase(key)
			tiles_changed = true
	for y in range(visible_bins.position.y, visible_bins.end.y):
		for x in range(visible_bins.position.x, visible_bins.end.x):
			var key := Vector2i(x, y)
			if tile_budget > 0 and work >= tile_budget:
				pending = pending or uses_outer or not tiles.has(key)
			elif _update_tile(key, chunks, regions):
				work += 1
				tiles_changed = true
	if features_changed:
		_visible_bins = visible_bins
		_collect_features(visible_bins)
	return tiles_changed or features_changed


func release_view() -> void:
	tiles.clear()
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


func _update_tile(key: Vector2i, chunks: Dictionary, regions: Dictionary) -> bool:
	var origin := key * CELLS
	var rect := Rect2i(origin, Vector2i(CELLS, CELLS))
	var inside := rect.intersects(_plan_rect)
	var plan_tile := _plan_rect.encloses(rect)
	var style_key := Vector3i(key.x, key.y, int(park))
	if plan_tile:
		if tiles.has(key):
			return false
		if _base_textures.has(style_key):
			tiles[key] = {texture = _base_textures[style_key], fields = null, chunk = null}
			return true
	var region_key := world.region_at(origin)
	var entry: Dictionary = regions.get(region_key, {})
	var fields: Variant = entry.get("fields")
	var chunk: Variant = chunks.get(key) if fields == null else null
	var old: Dictionary = tiles.get(key, {})
	var png: PackedByteArray = entry.get("map", PackedByteArray())
	var archived := fields == null and not png.is_empty()
	if (not old.is_empty() and is_same(fields, old.fields)
			and (old.get("used_archive", false) or is_same(chunk, old.chunk)) and archived == old.get("archived", false)):
		return false
	var archive := _region_image(region_key, png) if archived else null
	if not inside and fields == null and chunk == null and archive == null:
		return tiles.erase(key)
	var img := Image.create(CELLS, CELLS, false, Image.FORMAT_RGB8)
	var region_rect: Rect2i = entry.get("rect", Rect2i())
	var archive_rect := Rect2i(region_rect.position, archive.get_size()).intersection(region_rect) if archive != null else Rect2i()
	var archive_covers_tile := archive_rect.encloses(rect)
	var regional_biomes: PackedByteArray = fields.biome if fields != null else PackedByteArray()
	var regional_lakes: PackedByteArray = fields.lake if fields != null else PackedByteArray()
	var regional_rivers: PackedByteArray = fields.river if fields != null else PackedByteArray()
	var chunk_biomes: PackedByteArray = chunk.biome if chunk != null else PackedByteArray()
	for y in CELLS:
		for x in CELLS:
			var cell := origin + Vector2i(x, y)
			var color := EMPTY
			if _plan_rect.has_point(cell):
				var i := cell.y * world.W + cell.x
				if i < _base_biomes.size():
					color = PALETTE[_base_biomes[i]]
				if i < _base_lakes.size() and _base_lakes[i] != 0:
					color = WATER
				elif park and i < _base_biomes.size() and _base_biomes[i] >= Biomes.BEACH and _base_heights.size() == world.N:
					color = _paper_relief(cell, i, color)
			elif fields != null and region_rect.has_point(cell):
				var local := cell - region_rect.position
				var i := local.y * region_rect.size.x + local.x
				color = WATER if regional_lakes[i] != 0 or regional_rivers[i] != 0 else PALETTE[regional_biomes[i]]
			elif archive_rect.has_point(cell):
				color = archive.get_pixelv(cell - region_rect.position).lerp(EMPTY, 0.42)
			elif chunk != null:
				# У сырых кусков OuterLand по краям есть запас для меша.
				color = PALETTE[chunk_biomes[(y + 1) * (CELLS + 3) + x + 1]]
			img.set_pixel(x, y, color)
	var texture := ImageTexture.create_from_image(img)
	if plan_tile:
		_base_textures[style_key] = texture
	tiles[key] = {texture = texture, fields = fields, chunk = null if archive_covers_tile else chunk,
		archived = archived, used_archive = archive_covers_tile}
	return true


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
