class_name PlanTerrain
extends Node3D
## Готовый рельеф общего плана: CPU-геометрия сохраняется, дальние GPU-меши выгружаются.
## Все атрибуты копируются из одного окончательного меша, включая метровое полотно дорог.
## С 9.0 при старте и переносе сразу передаются только ближние части (near), дальние — по одной за кадр,
## сначала те, что впереди по ходу движения.
const CELLS := 64
const SIDE := CELLS * GameConfig.TILE
const RADIUS := 1800.0 # за плотным туманом; дальний силуэт не обрывается у стартового окна
const DROP := RADIUS + SIDE
const RECHECK := 32.0
const AHEAD := 600.0   # точка впереди по ходу, к которой тянется очередь

var chunks := {}
var nodes := {}
var pending: Array[Vector2i] = []
var material: Material
var checked_at := Vector2.INF


## Один проход по готовым треугольникам в потоке WorldLoader. Никакой новой триангуляции:
## общие высоты, нормали, UV, цвета и дорожные атрибуты остаются побайтно теми же.
static func partition(arrays: Array) -> Dictionary:
	var fast := Grid.fast_grid()
	if fast != null and not arrays.is_empty():
		return fast.PartitionTerrain(arrays, GameConfig.TILE, CELLS)
	return partition_reference(arrays)


## Эталон и путь для сборки без .NET.
static func partition_reference(arrays: Array) -> Dictionary:
	var out := {}
	if arrays.is_empty():
		return out
	var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var slots: Array[int] = []
	for slot: int in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2, Mesh.ARRAY_COLOR]:
		if arrays[slot] != null and arrays[slot].size() > 0:
			slots.append(slot)
	for at in range(0, indices.size(), 3):
		var a := pos[indices[at]]
		var b := pos[indices[at + 1]]
		var c := pos[indices[at + 2]]
		var key := Vector2i(floori((minf(a.x, minf(b.x, c.x)) / GameConfig.TILE - 0.5) / CELLS),
			floori((minf(a.z, minf(b.z, c.z)) / GameConfig.TILE - 0.5) / CELLS))
		if not out.has(key):
			var piece: Array = []
			piece.resize(Mesh.ARRAY_MAX)
			for slot in slots: piece[slot] = arrays[slot].slice(0, 0)
			piece[Mesh.ARRAY_INDEX] = PackedInt32Array()
			out[key] = {arrays = piece, ids = {}}
		var entry: Dictionary = out[key]
		for corner in 3:
			var id := indices[at + corner]
			if not entry.ids.has(id):
				entry.ids[id] = entry.ids.size()
				for slot in slots: entry.arrays[slot].append(arrays[slot][id])
			entry.arrays[Mesh.ARRAY_INDEX].append(entry.ids[id])
	for key: Vector2i in out.keys():
		out[key] = out[key].arrays # временная таблица перенумерации больше не нужна
	return out


func setup(prepared: Dictionary, mat: Material) -> void:
	chunks = prepared
	material = mat


func distance_to_chunk(key: Vector2i, p: Vector2) -> float:
	var corner := Vector2(key) * SIDE + Vector2.ONE * GameConfig.TILE * 0.5
	return p.distance_to(p.clamp(corner, corner + Vector2.ONE * SIDE))


## force — старт/быстрое перемещение: части ближе near передаются сразу, остальные ждут очереди.
## Иначе не больше одной передачи на GPU за кадр. true означает, что этот кадр уже занят передачей геометрии.
func update(x: float, z: float, force := false, allow_apply := true, near := RADIUS) -> bool:
	var p := Vector2(x, z)
	if force or p.distance_to(checked_at) >= RECHECK:
		# последние RECHECK метров пути задают направление: очередь берёт сначала части впереди
		var ahead := p if force or checked_at == Vector2.INF else p + (p - checked_at).normalized() * AHEAD
		checked_at = p
		for key: Vector2i in nodes.keys():
			if distance_to_chunk(key, p) > DROP:
				nodes[key].visible = false
				nodes[key].queue_free()
				nodes.erase(key)
		pending.clear()
		for key: Vector2i in chunks:
			if not nodes.has(key) and distance_to_chunk(key, p) <= RADIUS:
				pending.append(key)
		pending.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			return distance_to_chunk(a, p) + distance_to_chunk(a, ahead) > distance_to_chunk(b, p) + distance_to_chunk(b, ahead))
	var uploaded := false
	while not pending.is_empty() and (force and distance_to_chunk(pending.back(), p) <= near or allow_apply and not uploaded):
		var key: Vector2i = pending.pop_back()
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, chunks[key])
		var node := MeshInstance3D.new()
		node.mesh = mesh
		node.material_override = material
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
		add_child(node)
		nodes[key] = node
		uploaded = true
	return uploaded
