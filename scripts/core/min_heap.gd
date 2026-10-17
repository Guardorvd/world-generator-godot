class_name MinHeap
extends RefCounted
## Двоичная куча (min-heap) для поиска путей и заполнения впадин. Копия js/core/heap.js.

var ids := PackedInt32Array()
var keys := PackedFloat64Array()
var n := 0


func _init(cap: int) -> void:
	ids.resize(cap)
	keys.resize(cap)


func push(id: int, k: float) -> void:
	if n >= ids.size():
		ids.resize(ids.size() * 2)
		keys.resize(keys.size() * 2)
	var ia := ids
	var ka := keys
	var i := n
	n += 1
	while i > 0:
		var p := (i - 1) >> 1
		if ka[p] <= k:
			break
		ia[i] = ia[p]
		ka[i] = ka[p]
		i = p
	ia[i] = id
	ka[i] = k


func pop() -> int:
	var ia := ids
	var ka := keys
	var top := ia[0]
	n -= 1
	var m := n
	if m > 0:
		var id := ia[m]
		var k := ka[m]
		var i := 0
		while true:
			var l := 2 * i + 1
			if l >= m:
				break
			var r := l + 1
			if r < m and ka[r] < ka[l]:
				l = r
			if ka[l] >= k:
				break
			ia[i] = ia[l]
			ka[i] = ka[l]
			i = l
		ia[i] = id
		ka[i] = k
	return top
