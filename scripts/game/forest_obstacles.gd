class_name ForestObstacles
extends RefCounted
## С 7.7: крупные стволы, валуны и валежник рядом с игроком как препятствия для ходьбы и езды.
## Без узлов и физики движка: круги (стволы, валуны, сухостой) и капсулы (лежащие брёвна) в сетке
## по 2 м, только в радиусе REACH вокруг игрока; пересобирается при отходе на REBUILD или когда
## VegetationLayer разложил новый валежник. Кусты, трава, молодняк и мелкие камни проходимы.
## Низкое препятствие (бревно, небольшой валун) можно перепрыгнуть: оно не мешает, если ноги выше его верха.

const TILE := GameConfig.TILE
const CELL := 2.0       # сторона клетки сетки, м
const REACH := 24.0     # препятствия собираются в этом радиусе от игрока, м
const REBUILD := 6.0    # отошли дальше этого от места сборки — пересобрать, м
const MIN_SCALE := 0.6  # деревья мельче (молодняк) проходимы
const SNUG := 0.85      # круг ствола чуть уже видимого: задевание кроной и корой не держит
const STRIDE := 7       # ax, az, bx, bz, радиус, основание, верх
## радиус ствола у комля при масштабе 1, м (как в ForestModels и Models)
const TRUNK := {
	Biomes.T_BIRCH: 0.14, Biomes.T_PINE: 0.23, Biomes.T_SNOWPINE: 0.23, Biomes.T_OAK: 0.32,
	Biomes.T_JUNGLE: 0.32, Biomes.T_ACACIA: 0.3, Biomes.T_PALM: 0.25, Biomes.T_DEAD: 0.34, Biomes.T_CACTUS: 0.3,
}
const ROCK_R := 1.15    # валун: сфера 1,1 м, сплюснутая до 1,43 × 0,83 × 1,1, при масштабе 1
const ROCK_TOP := 1.07
## Модель двух контактов: препятствие не выше этого (бревно, невысокий валун) встречает колесо, а не раму —
## колесо накатывается на его скруглённую кромку (wheel_support); выше — стена, как прежде, м
const CLIMB_MAX := 0.45

var world: WorldData
## Хозяин — Heightfield.obstacles. Сильная ссылка замкнула бы цикл RefCounted, и мир не освобождался бы
## после выхода в меню (lifecycle_test). Поэтому только слабая.
var _heights: WeakRef
var data := PackedFloat32Array()  # препятствия подряд по STRIDE
var _grid := {}                   # Vector2i(клетка) -> PackedInt32Array номеров (начало записи в data)
var _center := Vector2.INF
var _version := -1
## 11.6: мелочь на полотне (ветки, россыпь камней) не держит, а поднимает колесо: отрезки a–b с радиусом
## и высотой (RoadObstacles.bump), подряд по BUMP_STRIDE. Кладёт VegetationLayer.bumps уже в радиусе столкновений.
const BUMP_STRIDE := 6
var bumps := PackedFloat32Array()
var _bump_grid := {}
var _bump_version := -1
## Объекты технических элементов трасс (TrailTechnical.build): постоянный слой, который обновления подлеска
## не заменяют, а дополняют. Препятствия — в формате STRIDE, кочки — BUMP_STRIDE.
var _trail_solids := PackedFloat32Array()
var _trail_bumps := PackedFloat32Array()
var _veg_bumps := PackedFloat32Array()


func _init(w: WorldData, h: Heightfield) -> void:
	world = w
	_heights = weakref(h)
	if not h.trail_technical.is_empty():
		set_trail(h.trail_technical.collide, h.trail_technical.bumps)


## Постоянный слой объектов трассы; следующий update пересоберёт препятствия с ним.
func set_trail(solids: PackedFloat32Array, trail_bumps: PackedFloat32Array) -> void:
	_trail_solids = solids
	_trail_bumps = trail_bumps
	_version = -2
	_index_bumps()


## Каждый такт: пересобрать, если игрок отошёл или подлесок обновился. details — валежник из
## VegetationLayer.obstacles (тот же формат), version — его счётчик обновлений.
func update(px: float, pz: float, details: PackedFloat32Array, version: int, force := false) -> void:
	if not force and version == _version and Vector2(px, pz).distance_to(_center) < REBUILD:
		return
	_center = Vector2(px, pz)
	_version = version
	data.clear()
	_grid.clear()
	_add_objects(px, pz)
	for n in range(0, details.size(), STRIDE):
		if Vector2(details[n], details[n + 1]).distance_to(_center) < REACH:
			_add(details[n], details[n + 1], details[n + 2], details[n + 3], details[n + 4], details[n + 5], details[n + 6])
	for n in range(0, _trail_solids.size(), STRIDE):
		if Vector2(_trail_solids[n], _trail_solids[n + 1]).distance_to(_center) < REACH:
			_add(_trail_solids[n], _trail_solids[n + 1], _trail_solids[n + 2], _trail_solids[n + 3], _trail_solids[n + 4], _trail_solids[n + 5], _trail_solids[n + 6])


## Деревья, валуны, сухие деревья и кактусы мира — те же, что рисует VegetationLayer
func _add_objects(px: float, pz: float) -> void:
	var heights: Heightfield = _heights.get_ref()
	if heights == null:
		return
	var side := world.CS * TILE
	for cy in range(maxi(0, floori((pz - REACH) / side)), mini(world.CH, floori((pz + REACH) / side) + 1)):
		for cx in range(maxi(0, floori((px - REACH) / side)), mini(world.CW, floori((px + REACH) / side) + 1)):
			for o in world.chunks[cy * world.CW + cx]:
				var kind := world.obj_k[o]
				var s := world.obj_s[o]
				if kind != Biomes.T_ROCK and (not TRUNK.has(kind) or s < MIN_SCALE):
					continue
				var x := world.obj_x[o] * TILE
				var z := world.obj_y[o] * TILE
				if absf(x - px) > REACH or absf(z - pz) > REACH:
					continue
				# на дорогах и в воде дерево не рисуется — не мешает и здесь
				if world.path_mask[floori(world.obj_y[o]) * world.W + floori(world.obj_x[o])] >= 2:
					continue
				var base := heights.ground_at(x, z)
				if kind == Biomes.T_ROCK:
					if s < 0.42 or not RockModels.has_seat(heights, x, z, s * 1.2):
						continue
					s *= 1.2
					_add(x, z, x, z, ROCK_R * s, base, base - 0.1 + ROCK_TOP * s)
				elif heights.depth_at(x, z) <= GameConfig.WATER_MARGIN:
					_add(x, z, x, z, TRUNK[kind] * s * SNUG, base, INF)
	if world.outer == null:
		return
	# 8.4: за краем карты — объекты, которые VegetationLayer уже разложил (OuterLand.veg, с высотой земли)
	for cy in range(floori((pz - REACH) / side), floori((pz + REACH) / side) + 1):
		for cx in range(floori((px - REACH) / side), floori((px + REACH) / side) + 1):
			var items: Variant = world.outer.veg.get(Vector2i(cx, cy))
			if items == null:
				continue
			var xs: PackedFloat64Array = items.x
			for o in xs.size():
				var kind: int = items.k[o]
				var s: float = items.s[o]
				if kind != Biomes.T_ROCK and (not TRUNK.has(kind) or s < MIN_SCALE):
					continue
				var x: float = xs[o] * TILE
				var z: float = items.y[o] * TILE
				if absf(x - px) > REACH or absf(z - pz) > REACH:
					continue
				var base: float = items.ground[o]
				if kind == Biomes.T_ROCK:
					if s < 0.42 or (items.has("normals") and not RockModels.supported(items.normals[o])):
						continue
					s *= 1.2
					_add(x, z, x, z, ROCK_R * s, base, base - 0.1 + ROCK_TOP * s)
				else:
					_add(x, z, x, z, TRUNK[kind] * s * SNUG, base, INF)


## Отрезок a–b толщиной r (у круга a = b), от основания base до верха top
func _add(ax: float, az: float, bx: float, bz: float, r: float, base: float, top: float) -> void:
	var at := data.size()
	data.append_array([ax, az, bx, bz, r, base, top])
	for cy in range(floori((minf(az, bz) - r) / CELL), floori((maxf(az, bz) + r) / CELL) + 1):
		for cx in range(floori((minf(ax, bx) - r) / CELL), floori((maxf(ax, bx) + r) / CELL) + 1):
			var key := Vector2i(cx, cy)
			var list: PackedInt32Array = _grid.get(key, PackedInt32Array())
			list.append(at)
			_grid[key] = list


## Задевает ли тело радиуса r в (x, z) с ногами на высоте feet какое-нибудь препятствие
## climb > 0: препятствия не выше climb (от основания до верха) не держат — их встречает колесо (wheel_support)
func hits(x: float, z: float, feet: float, r: float, climb := 0.0) -> bool:
	return _nearest(x, z, feet, r, climb) >= 0


## Нормаль от препятствия, которое задевает тело (наружу, длина 1), или ноль, если не задевает.
## По ней тело скользит вдоль ствола и бревна, а велосипед понимает, ударился ли в лоб.
func normal(x: float, z: float, feet: float, r: float, climb := 0.0) -> Vector2:
	var at := _nearest(x, z, feet, r, climb)
	if at < 0:
		return Vector2.ZERO
	var c := _closest(at, x, z)
	var d := Vector2(x, z) - c
	if d.length_squared() < 1e-8:
		return Vector2.ZERO
	return d.normalized()


## Номер самого глубоко задетого препятствия или -1
func _nearest(x: float, z: float, feet: float, r: float, climb := 0.0) -> int:
	if data.is_empty():
		return -1
	var best := -1
	var depth := 0.0
	for cy in range(floori((z - r) / CELL), floori((z + r) / CELL) + 1):
		for cx in range(floori((x - r) / CELL), floori((x + r) / CELL) + 1):
			var list: Variant = _grid.get(Vector2i(cx, cy))
			if list == null:
				continue
			for at: int in list:
				if feet >= data[at + 6] or data[at + 6] - data[at + 5] <= climb:
					continue
				var reach := data[at + 4] + r
				var gap := reach - Vector2(x, z).distance_to(_closest(at, x, z))
				if gap > depth:
					depth = gap
					best = at
	return best


## Высота нижней точки колеса радиуса wheel_r, стоящего над (x, z) на низких препятствиях (не выше climb), или -INF.
## Сечение препятствия — скруглённый брус: плоский верх и кромки радиусом ρ = половина высоты (у бревна — круг).
## Опора — точная огибающая круга колеса над кругом кромки: колесо встречает кромку раньше, чем стоит над ней,
## и поднимается по дуге; чем выше кромка относительно колеса, тем круче дуга в начале.
func wheel_support(x: float, z: float, wheel_r: float, climb: float) -> float:
	var best := -INF
	if data.is_empty():
		return best
	var seen := {}
	for cy in range(floori((z - wheel_r) / CELL), floori((z + wheel_r) / CELL) + 1):
		for cx in range(floori((x - wheel_r) / CELL), floori((x + wheel_r) / CELL) + 1):
			var list: Variant = _grid.get(Vector2i(cx, cy))
			if list == null:
				continue
			for at: int in list:
				if seen.has(at):
					continue
				seen[at] = true
				var top := data[at + 6]
				var tall := top - data[at + 5]
				if tall <= 0.0 or tall > climb:
					continue
				var rho := minf(tall * 0.5, data[at + 4])
				var edge := maxf(0.0, Vector2(x, z).distance_to(_closest(at, x, z)) - (data[at + 4] - rho))
				var reach := wheel_r + rho
				if edge >= reach:
					continue
				best = maxf(best, top - rho + sqrt(reach * reach - edge * edge) - wheel_r)
	return best


## Встреча колеса с низким препятствием под (x, z) — тем, что сейчас выше всех держит колесо:
## {id — постоянный номер препятствия (по его оси, не меняется при пересборке), angle — угол встречи, рад: наклон дуги
## колеса над кругом кромки в точке первого касания, когда колесо ещё стоит на высоте ground (10 см — около 42°,
## 40 см — около 75°), normal — направление от препятствия к колесу по горизонтали (ноль — колесо над осью)}.
## Пусто, если колесо не на препятствии.
func wheel_contact(x: float, z: float, wheel_r: float, climb: float, ground: float) -> Dictionary:
	var best := {}
	var top_support := -INF
	for cy in range(floori((z - wheel_r) / CELL), floori((z + wheel_r) / CELL) + 1):
		for cx in range(floori((x - wheel_r) / CELL), floori((x + wheel_r) / CELL) + 1):
			var list: Variant = _grid.get(Vector2i(cx, cy))
			if list == null:
				continue
			for at: int in list:
				var top := data[at + 6]
				var tall := top - data[at + 5]
				if tall <= 0.0 or tall > climb:
					continue
				var rho := minf(tall * 0.5, data[at + 4])
				var axis := _closest(at, x, z)
				var away := Vector2(x, z) - axis
				var edge := maxf(0.0, away.length() - (data[at + 4] - rho))
				var reach := wheel_r + rho
				if edge >= reach:
					continue
				var support := top - rho + sqrt(reach * reach - edge * edge) - wheel_r
				if support <= top_support:
					continue
				top_support = support
				# высота центра колеса над центром кромки в момент касания и горизонтальное расстояние до него
				var c := ground + wheel_r - (top - rho)
				best = {id = hash(Vector4i(roundi(data[at] * 100.0), roundi(data[at + 1] * 100.0), roundi(data[at + 2] * 100.0), roundi(data[at + 3] * 100.0))),
					angle = atan2(sqrt(maxf(0.0, reach * reach - c * c)), c) if c > 0.0 else PI * 0.5,
					normal = away.normalized() if away.length_squared() > 1e-8 else Vector2.ZERO}
	return best


## Ближайшая к (x, z) точка оси препятствия
func _closest(at: int, x: float, z: float) -> Vector2:
	return _on_axis(data, at, x, z)


static func _on_axis(list: PackedFloat32Array, at: int, x: float, z: float) -> Vector2:
	var a := Vector2(list[at], list[at + 1])
	var ab := Vector2(list[at + 2], list[at + 3]) - a
	var ln := ab.length_squared()
	if ln < 1e-8:
		return a
	return a + ab * clampf((Vector2(x, z) - a).dot(ab) / ln, 0.0, 1.0)


## Новые кочки, если подлесок обновился (version — его счётчик, как у update)
func set_bumps(list: PackedFloat32Array, version: int) -> void:
	if version == _bump_version:
		return
	_bump_version = version
	_veg_bumps = list
	_index_bumps()


## Кочки подлеска вместе с кочками трассы, в сетке
func _index_bumps() -> void:
	var list := _veg_bumps if _trail_bumps.is_empty() else _trail_bumps + _veg_bumps
	bumps = list
	_bump_grid.clear()
	for at in range(0, list.size(), BUMP_STRIDE):
		var r := list[at + 4]
		for cy in range(floori((minf(list[at + 1], list[at + 3]) - r) / CELL), floori((maxf(list[at + 1], list[at + 3]) + r) / CELL) + 1):
			for cx in range(floori((minf(list[at], list[at + 2]) - r) / CELL), floori((maxf(list[at], list[at + 2]) + r) / CELL) + 1):
				var key := Vector2i(cx, cy)
				var cell: PackedInt32Array = _bump_grid.get(key, PackedInt32Array())
				cell.append(at)
				_bump_grid[key] = cell


## Подъём точки касания колеса в (x, z) над землёй, м: купол от оси ветки или середины россыпи
func bump_at(x: float, z: float) -> float:
	var cell: Variant = _bump_grid.get(Vector2i(floori(x / CELL), floori(z / CELL)))
	if cell == null:
		return 0.0
	var top := 0.0
	for at: int in cell:
		var t := Vector2(x, z).distance_to(_on_axis(bumps, at, x, z)) / bumps[at + 4]
		if t < 1.0:
			# 11.7: край без излома (наклон у края ноль): подвеска не получает толчок на входе и выходе
			var s := 1.0 - t * t
			top = maxf(top, bumps[at + 5] * s * s)
	return top
