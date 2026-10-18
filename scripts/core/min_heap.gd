class_name MinHeap
extends RefCounted
## Двоичная куча (min-heap) для заполнения впадин (StageHydrology: там цикл развёрнут и читает ids/keys/n напрямую).
## Для поиска путей куча развёрнута в Pathfinder.find_path. Копия js/core/heap.js.

var ids := PackedInt32Array()
var keys := PackedFloat64Array()
var n := 0


func _init(cap: int) -> void:
	ids.resize(cap)
	keys.resize(cap)


func push(id: int, k: float) -> void:
	if n >= ids.size():
		var grow := maxi(ids.size() * 2, 16)
		ids.resize(grow)
		keys.resize(grow)
	var i := n
	n += 1
	while i > 0:
		var p := (i - 1) >> 1
		if keys[p] <= k:
			break
		ids[i] = ids[p]
		keys[i] = keys[p]
		i = p
	ids[i] = id
	keys[i] = k
