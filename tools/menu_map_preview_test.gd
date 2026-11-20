extends SceneTree
const Preview := preload("res://scripts/ui/menu_map_preview.gd")
func _initialize() -> void:
	var w := WorldData.new()
	w.W = 4
	w.H = 4
	w.N = 16
	var heights := PackedFloat32Array()
	var ocean := PackedByteArray()
	var lake := PackedByteArray()
	var biome := PackedByteArray()
	heights.resize(16)
	ocean.resize(16)
	lake.resize(16)
	biome.resize(16)
	for i in 16:
		heights[i] = float(i) / 40.0
		biome[i] = Biomes.BEACH
	ocean[0] = 1
	w.h = heights
	w.ocean = ocean
	w.lake = lake
	w.biome = biome
	w.rivers = [[{x = 0, y = 1}, {x = 3, y = 1}]]
	var maps := Preview.render(w)
	var ok := maps.size() == 2
	if ok:
		var atlas: Image = maps[0]
		var altitude: Image = maps[1]
		ok = atlas.get_width() == 256 and atlas.get_height() == 256
		ok = ok and altitude.get_pixel(0, 0).is_equal_approx(Color("#396f8b"))
		ok = ok and not altitude.get_pixel(80, 80).is_equal_approx(altitude.get_pixel(240, 240))
		ok = ok and atlas.get_pixel(128, 64).is_equal_approx(Color("#719da8"))
	print("Map preview fixture: ", "OK" if ok else "FAIL")
	quit(0 if ok else 1)
