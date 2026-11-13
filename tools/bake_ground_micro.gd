extends SceneTree
## 13.11.2026: микроструктура земли для terrain.gdshader. Раньше вся мелкая деталь была одной гладкой шумовой текстурой
## (4 октавы симплекса), поэтому трава, почва, песок и галька различались только цветом. Здесь печётся бесшовная
## текстура 512 × 512, четыре канала высот, и карта нормалей к ним:
##   micro.res   R — пряди и пучки травы (вытянутый шум × ячейки), G — галька и комки (ячейки, округлые), B — зерно, A — трещины высохшей земли
##   micro_n.res RG — нормаль пряди травы (x, y), BA — нормаль гальки и комков (x, y); z восстанавливается в шейдере
## Бесшовность: FastNoiseLite.get_seamless_image, нормали считаются с оборачиванием краёв. Только авторство, мир не нужен.
##   godot --headless --path . --script res://tools/bake_ground_micro.gd [-- --preview <папка>]
const SIZE := 512
const OUT := "res://resources/ground/"


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var strands := _strands()
	var pebbles := _cells(FastNoiseLite.TYPE_CELLULAR, 0.026, FastNoiseLite.CellularReturnType.RETURN_DISTANCE, 11, false)
	var grain := _grain()
	var cracks := _cells(FastNoiseLite.TYPE_CELLULAR, 0.013, FastNoiseLite.CellularReturnType.RETURN_DISTANCE2_SUB, 29, false)
	var height := PackedByteArray()
	height.resize(SIZE * SIZE * 4)
	var pebble_h := PackedFloat32Array()
	pebble_h.resize(SIZE * SIZE)
	var strand_h := PackedFloat32Array()
	strand_h.resize(SIZE * SIZE)
	for i in SIZE * SIZE:
		var s := strands[i]
		var p := pebbles[i]
		# галька: округлые бугры, у центра ячейки выше всего, между ячейками щель
		var stone := 1.0 - smoothstep(0.1, 0.62, p)
		var crack := 1.0 - smoothstep(0.0, 0.16, cracks[i])
		strand_h[i] = s
		pebble_h[i] = stone
		height[i * 4] = roundi(clampf(s, 0.0, 1.0) * 255.0)
		height[i * 4 + 1] = roundi(clampf(stone, 0.0, 1.0) * 255.0)
		height[i * 4 + 2] = roundi(clampf(grain[i], 0.0, 1.0) * 255.0)
		height[i * 4 + 3] = roundi(clampf(crack, 0.0, 1.0) * 255.0)
	var normals := PackedByteArray()
	normals.resize(SIZE * SIZE * 4)
	_normals(strand_h, 3.2, normals, 0)
	_normals(pebble_h, 4.0, normals, 2)
	var micro := Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_RGBA8, height)
	var micro_n := Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_RGBA8, normals)
	micro.generate_mipmaps()
	micro_n.generate_mipmaps()
	var args := OS.get_cmdline_user_args()
	var at := args.find("--preview")
	if at >= 0 and at + 1 < args.size():
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(args[at + 1]))
		var flat := Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_RGBA8, height)
		flat.save_png(ProjectSettings.globalize_path(args[at + 1]).path_join("micro.png"))
		Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_RGBA8, normals).save_png(ProjectSettings.globalize_path(args[at + 1]).path_join("micro_n.png"))
	var failed := false
	for pair: Array in [["micro.res", micro], ["micro_n.res", micro_n]]:
		var err := ResourceSaver.save(ImageTexture.create_from_image(pair[1]), OUT + pair[0], ResourceSaver.FLAG_COMPRESS)
		if err != OK:
			push_error("ground micro: " + error_string(err))
			failed = true
	print("ground micro baked: ", OUT, " ", SIZE, "x", SIZE)
	quit(1 if failed else 0)


## Пряди: вытянутые вдоль y полосы двух масштабов, поверх крупные пучки. Узкий шум растягивается по вертикали.
func _strands() -> PackedFloat32Array:
	var thin := _noise_image(FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 0.16, 2, 5, SIZE, SIZE / 8)
	var wide := _noise_image(FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 0.06, 2, 17, SIZE, SIZE / 6)
	thin.resize(SIZE, SIZE, Image.INTERPOLATE_BILINEAR)
	wide.resize(SIZE, SIZE, Image.INTERPOLATE_BILINEAR)
	var clump := _cells(FastNoiseLite.TYPE_CELLULAR, 0.018, FastNoiseLite.CellularReturnType.RETURN_DISTANCE, 41, false)
	var out := PackedFloat32Array()
	out.resize(SIZE * SIZE)
	for y in SIZE:
		for x in SIZE:
			var a := thin.get_pixel(x, y).r
			var b := wide.get_pixel(x, y).r
			var c := clump[y * SIZE + x]
			var tuft := 0.35 + 0.65 * smoothstep(0.0, 0.55, c)   # у центра пучка выше, между пучками щель
			out[y * SIZE + x] = clampf((a * 0.62 + b * 0.38 - 0.5) * 1.5 + 0.5, 0.0, 1.0) * tuft
	return out


## Зерно: тонкий шум и белый шум; для песка и почвы.
func _grain() -> PackedFloat32Array:
	var fine := _noise_image(FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 0.42, 1, 3, SIZE, SIZE)
	var rng := RandomNumberGenerator.new()
	rng.seed = 9917
	var out := PackedFloat32Array()
	out.resize(SIZE * SIZE)
	for i in SIZE * SIZE:
		out[i] = fine.get_pixel(i % SIZE, i / SIZE).r * 0.6 + rng.randf() * 0.4
	return out


## Ячеистый шум в 0..1 (бесшовный)
func _cells(type: int, frequency: float, ret: int, seed_value: int, invert: bool) -> PackedFloat32Array:
	var noise := FastNoiseLite.new()
	noise.noise_type = type
	noise.frequency = frequency
	noise.seed = seed_value
	noise.cellular_return_type = ret
	noise.cellular_jitter = 1.0
	noise.fractal_type = FastNoiseLite.FRACTAL_NONE # иначе ячейки превращаются в «цветную капусту»
	var img := noise.get_seamless_image(SIZE, SIZE, false, true, 0.1, true)
	var out := PackedFloat32Array()
	out.resize(SIZE * SIZE)
	for i in SIZE * SIZE:
		var v := img.get_pixel(i % SIZE, i / SIZE).r
		out[i] = (1.0 - v) if invert else v
	return out


func _noise_image(type: int, frequency: float, octaves: int, seed_value: int, w: int, h: int) -> Image:
	var noise := FastNoiseLite.new()
	noise.noise_type = type
	noise.frequency = frequency
	noise.fractal_octaves = octaves
	noise.seed = seed_value
	return noise.get_seamless_image(w, h, false, false, 0.1, true)


## Нормаль по высоте с оборачиванием краёв: в канал channel и channel + 1 пишутся x и y нормали (0..1 = −1..1)
func _normals(h: PackedFloat32Array, strength: float, out: PackedByteArray, channel: int) -> void:
	# Тем же Image.bump_map_to_normal_map, что у detail_normal, чтобы ориентация нормалей в шейдере совпала.
	# Край высоты оборачивается: изображение берётся 3 × 3 и вырезается середина, шва нет.
	var tiled := Image.create(SIZE * 3, SIZE * 3, false, Image.FORMAT_RGBA8)
	var gray := PackedByteArray()
	gray.resize(SIZE * SIZE * 4)
	for i in SIZE * SIZE:
		var v := roundi(clampf(h[i], 0.0, 1.0) * 255.0)
		gray[i * 4] = v
		gray[i * 4 + 1] = v
		gray[i * 4 + 2] = v
		gray[i * 4 + 3] = 255
	var tile := Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_RGBA8, gray)
	for ty in 3:
		for tx in 3:
			tiled.blit_rect(tile, Rect2i(0, 0, SIZE, SIZE), Vector2i(tx * SIZE, ty * SIZE))
	tiled.bump_map_to_normal_map(strength)
	var middle := tiled.get_region(Rect2i(SIZE, SIZE, SIZE, SIZE))
	var data := middle.get_data()
	for i in SIZE * SIZE:
		out[i * 4 + channel] = data[i * 4]
		out[i * 4 + channel + 1] = data[i * 4 + 1]
