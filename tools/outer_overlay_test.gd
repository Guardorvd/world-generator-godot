extends SceneTree
## Побайтовый оракул прежнего наложения: прямоугольники внутри плана, снаружи и на каждом краю.
var fails := 0


func _initialize() -> void:
	var w := WorldData.new()
	w.W = 73
	w.H = 69
	w.N = w.W * w.H
	for name in ["h", "temp", "moist", "elev", "slope", "dist_ocean", "dist_water"]:
		var field := PackedFloat32Array()
		field.resize(w.N)
		for i in w.N:
			field[i] = sin(i * 0.17) * 0.2 + i * 0.001
		w.set(name, field)
	w.biome.resize(w.N)
	w.river.resize(w.N)
	w.river_area.resize(w.N)
	for i in w.N:
		w.biome[i] = i % 12
		w.river[i] = int(i % 11 == 0)
		w.river_area[i] = int(i % 7 == 0)
	for rect: Rect2i in [Rect2i(4, 3, 64, 64), Rect2i(-7, -9, 64, 64), Rect2i(66, 62, 64, 64),
			Rect2i(-100, 4, 64, 64), Rect2i(73, 69, 1, 1), Rect2i(0, 0, 73, 69)]:
		compare(w, rect)
	w.river_area = PackedByteArray() # fallback river_cells
	compare(w, Rect2i(0, 0, 64, 64))
	w.dist_water = PackedFloat32Array() # неполная тестовая география
	compare(w, Rect2i(-1, -1, 64, 64))
	print("outer_overlay_test: %d failures" % fails)
	quit(1 if fails else 0)


func compare(w: WorldData, rect: Rect2i) -> void:
	var before := {}
	for name in ["h", "temp", "moist", "elev", "slope", "dist", "light"]:
		var values := PackedFloat32Array()
		values.resize(rect.get_area())
		values.fill(-123.25)
		before[name] = values
	var biome := PackedByteArray()
	biome.resize(rect.get_area())
	biome.fill(255)
	before.biome = biome
	var expected := before.duplicate(true)
	legacy_overlay(w, rect, expected)
	OuterLand._overlay(w, rect, before)
	var same := var_to_bytes(expected) == var_to_bytes(before)
	fails += int(not same)
	print(("OK " if same else "FAIL ") + "побайтовое наложение %s" % rect)


func legacy_overlay(w: WorldData, rect: Rect2i, out: Dictionary) -> void:
	out.dw = out.dist.duplicate()
	out.river = PackedByteArray()
	out.river.resize(rect.get_area())
	if w.N <= 0 or w.biome.size() != w.N or w.dist_water.size() != w.N:
		return
	var overlap := rect.intersection(Rect2i(0, 0, w.W, w.H))
	var river := w.river_cells()
	for y in range(overlap.position.y, overlap.end.y):
		for x in range(overlap.position.x, overlap.end.x):
			var dst := (y - rect.position.y) * rect.size.x + x - rect.position.x
			var src := y * w.W + x
			for name: String in ["h", "biome", "temp", "moist", "elev", "slope"]:
				out[name][dst] = w.get(name)[src]
			out.dist[dst] = w.dist_ocean[src]
			out.dw[dst] = w.dist_water[src]
			out.river[dst] = river[src]
			out.light[dst] = StageClimate.natural_conditions(w, x, y).x
