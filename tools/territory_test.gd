extends SceneTree
## 8.4: участки мира воспроизводятся сами по себе. Один и тот же кусок местности за краем (рельеф, климат,
## лес) совпадает по хешу при любом порядке и направлении расчёта и в любом прямоугольнике; чанк леса
## стартовой области, разложенный отдельно, совпадает с разложенным при генерации; на границе стартовой
## области и местности за краем климат меняется не резче, чем между соседними клетками внутри карты.
##   godot --headless --path . --script res://tools/territory_test.gd
const SelfTest := preload("res://tools/selftest.gd")
var fails := 0


func check(ok: bool, label: String) -> void:
	if not ok:
		fails += 1
		printerr(label)


static func terrain_hash(f: Dictionary) -> int:
	var bytes := PackedByteArray()
	for key in ["h", "temp", "moist", "elev", "slope", "dist", "light"]:
		bytes.append_array((f[key] as PackedFloat32Array).to_byte_array())
	bytes.append_array(f.biome)
	return SelfTest.fnv(bytes)


static func veg_hash(f: Dictionary) -> int:
	var bytes := PackedByteArray()
	bytes.append_array((f.x as PackedFloat64Array).to_byte_array())
	bytes.append_array((f.y as PackedFloat64Array).to_byte_array())
	bytes.append_array((f.k as PackedInt32Array).to_byte_array())
	bytes.append_array((f.s as PackedFloat64Array).to_byte_array())
	return SelfTest.fnv(bytes)


## Поля прямоугольника big (угол bx, by, ширина bw) на клетках cw × ch с углом (x0, y0)
static func sub(big: Dictionary, bx: int, by: int, bw: int, x0: int, y0: int, cw: int, ch: int) -> Dictionary:
	var out := {}
	for key: String in big:
		var src: Variant = big[key]
		var dst: Variant = src.duplicate()
		dst.resize(cw * ch)
		for j in ch:
			for i in cw:
				dst[j * cw + i] = src[(y0 - by + j) * bw + x0 - bx + i]
		out[key] = dst
	return out


func _init() -> void:
	var w := WorldGenerator.generate("Север-1234", 256)
	w.outer = OuterLand.new(w)
	var C := OuterLand.C
	# Куски слева от карты, над ней и в дальнем углу; вперёд, назад и вразброс
	var keys: Array[Vector2i] = [Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(-2, 1), Vector2i(1, -1), Vector2i(2, -2),
		Vector2i(4, 4), Vector2i(-3, 5), Vector2i(5, -3)]
	var forward := {}
	for key in keys:
		forward[key] = terrain_hash(OuterLand.compute_chunk(w, key))
	var backward := {}
	for n in range(keys.size() - 1, -1, -1):
		backward[keys[n]] = terrain_hash(OuterLand.compute_chunk(w, keys[n]))
	var land := 0
	for key in keys:
		check(forward[key] == backward[key], "Кусок %s зависит от порядка расчёта" % key)
	# Тот же кусок внутри большого прямоугольника с другим углом
	var key := Vector2i(-2, 1)
	var x0 := key.x * C - 1
	var y0 := key.y * C - 1
	var big := OuterLand.compute(w, x0 - 37, y0 - 11, C + 3 + 60, C + 3 + 20)
	var part := sub(big, x0 - 37, y0 - 11, C + 3 + 60, x0, y0, C + 3, C + 3)
	check(terrain_hash(part) == forward[key], "Кусок %s зависит от прямоугольника, в котором его считали" % key)
	# Лес за краем: блок чанков вперёд и назад
	var vkeys: Array[Vector2i] = []
	for cy in range(-3, 1):
		for cx in range(-3, 1):
			vkeys.append(Vector2i(cx, cy))
	var trees := 0
	var vf := {}
	for k in vkeys:
		var f := OuterLand.vegetation(w, k)
		vf[k] = veg_hash(f)
		trees += f.x.size()
	for n in range(vkeys.size() - 1, -1, -1):
		check(veg_hash(OuterLand.vegetation(w, vkeys[n])) == vf[vkeys[n]], "Лес чанка %s зависит от порядка" % vkeys[n])
	check(trees > 0, "За краем карты нет ни одного объекта")
	var other := WorldGenerator.generate("Туман-4821", 128)
	check(veg_hash(OuterLand.vegetation(other, vkeys[0])) != vf[vkeys[0]] or OuterLand.vegetation(other, vkeys[0]).x.is_empty(),
		"Лес другого мира не должен повторять этот")
	# Чанк стартовой области, разложенный отдельно, — тот же, что при генерации
	var fields := StageVegetation.fields(w)
	for c: Vector2i in [Vector2i(5, 5), Vector2i(0, 0), Vector2i(w.CW - 1, 3)]:
		var store := StageVegetation.ObjStore.new(w)
		var cx0 := c.x * w.CS
		var cy0 := c.y * w.CS
		StageVegetation.place_chunk(w.seed_num, cx0, cy0, cx0 + w.CS, cy0 + w.CS, fields, 0, 0, w.W, w, store)
		var mine := PackedStringArray()
		for o in store.x.size():
			mine.append("%.5f %.5f %d %.4f" % [store.x[o], store.y[o], store.k[o], store.s[o]])
		var theirs := PackedStringArray()
		for o in w.chunks[c.y * w.CW + c.x]:
			theirs.append("%.5f %.5f %d %.4f" % [w.obj_x[o], w.obj_y[o], w.obj_k[o], w.obj_s[o]])
		mine.sort()
		theirs.sort()
		check(mine == theirs, "Чанк леса %s стартовой области зависит от соседей (%d против %d)" % [c, mine.size(), theirs.size()])
	# Граница: перепад влажности и температуры через край против перепада между соседними клетками на карте
	var edge := 0.0
	var inner := 0.0
	var biome_edge := 0
	var biome_inner := 0
	var n_edge := 0
	for j in w.H:
		for side in 2:
			var i := 0 if side == 0 else w.W - 1
			var o := -1 if side == 0 else w.W
			var into := 1 if side == 0 else w.W - 2
			var info := w.outer.info(o, j)
			var k := j * w.W + i
			if w.ocean[k] != 0 or info.elev <= 0.0:
				continue
			land += 1
			edge += absf(info.moist - w.moist[k]) + absf(info.temp - w.temp[k])
			inner += absf(w.moist[j * w.W + into] - w.moist[k]) + absf(w.temp[j * w.W + into] - w.temp[k])
			biome_edge += 1 if info.biome != w.biome[k] else 0
			biome_inner += 1 if w.biome[j * w.W + into] != w.biome[k] else 0
			n_edge += 1
	if n_edge > 0:
		print("Граница (%d клеток суши): перепад влажности+температуры %.4f, внутри %.4f; смена биома %.1f %%, внутри %.1f %%" % [
			n_edge, edge / n_edge, inner / n_edge, 100.0 * biome_edge / n_edge, 100.0 * biome_inner / n_edge])
		check(edge / n_edge < 4.0 * inner / n_edge + 0.02, "На границе стартовой области климат меняется скачком")
	print("Кусков %d, чанков леса %d (объектов %d), суши на границе %d" % [keys.size(), vkeys.size(), trees, land])
	print("territory_test: " + ("OK" if fails == 0 else "ошибок %d" % fails))
	quit(1 if fails > 0 else 0)
