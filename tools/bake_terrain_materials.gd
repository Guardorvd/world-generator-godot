extends SceneTree
## Bakes 4 stylized seamless 512x512 PBR terrain layers packed into two 1024x1024 2x2 ImageTexture sheets:
##   (0,0)=Rock, (512,0)=Duff, (0,512)=Turf, (512,512)=Shingle
##   res://resources/ground/mat_albedo_h.res   RGBA8: RGB = albedo modulation centered at 0.5 (= 1.0x), A = sculpted height (0..1)
##   res://resources/ground/mat_norm_r_ao.res  RGBA8: RG = seamless world normal (x, y), B = roughness, A = micro AO
## TerrainBuilder.pbr_material_arrays() slices the quadrants and builds mipmapped Texture2DArray textures at runtime.
## Run: godot --headless --path . --script res://tools/bake_terrain_materials.gd [-- --preview <dir>]
const SIZE := 512
const SHEET := SIZE * 2
const OUT := "res://resources/ground/"
const NAMES := ["rock", "duff", "turf", "shingle"]
const QUADS := [Vector2i(0, 0), Vector2i(SIZE, 0), Vector2i(0, SIZE), Vector2i(SIZE, SIZE)]


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var layers := [
		_bake_rock(),
		_bake_duff(),
		_bake_turf(),
		_bake_shingle(),
	]

	var sheet_ah := Image.create(SHEET, SHEET, false, Image.FORMAT_RGBA8)
	var sheet_nr := Image.create(SHEET, SHEET, false, Image.FORMAT_RGBA8)
	for li in layers.size():
		var pair: Dictionary = layers[li]
		sheet_ah.blit_rect(pair.ah, Rect2i(0, 0, SIZE, SIZE), QUADS[li])
		sheet_nr.blit_rect(pair.nr, Rect2i(0, 0, SIZE, SIZE), QUADS[li])

	var args := OS.get_cmdline_user_args()
	var at := args.find("--preview")
	if at >= 0 and at + 1 < args.size():
		var dir := ProjectSettings.globalize_path(args[at + 1])
		DirAccess.make_dir_recursive_absolute(dir)
		for li in layers.size():
			var h_arr: PackedFloat32Array = layers[li].h
			var h_bytes := PackedByteArray(); h_bytes.resize(SIZE * SIZE * 4)
			var n_bytes: PackedByteArray = (layers[li].nr as Image).get_data()
			var n_opaque := PackedByteArray(); n_opaque.resize(SIZE * SIZE * 4)
			for i in SIZE * SIZE:
				var hv := roundi(clampf(h_arr[i], 0.0, 1.0) * 255.0)
				h_bytes[i * 4] = hv
				h_bytes[i * 4 + 1] = hv
				h_bytes[i * 4 + 2] = hv
				h_bytes[i * 4 + 3] = 255
				n_opaque[i * 4] = n_bytes[i * 4]
				n_opaque[i * 4 + 1] = n_bytes[i * 4 + 1]
				n_opaque[i * 4 + 2] = 230
				n_opaque[i * 4 + 3] = 255
			Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_RGBA8, h_bytes).save_png(dir.path_join("mat_%d_%s_h.png" % [li, NAMES[li]]))
			Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_RGBA8, n_opaque).save_png(dir.path_join("mat_%d_%s_n.png" % [li, NAMES[li]]))

	var failed := false
	for item: Array in [["mat_albedo_h.res", sheet_ah], ["mat_norm_r_ao.res", sheet_nr]]:
		var path: String = OUT + item[0]
		var err := ResourceSaver.save(ImageTexture.create_from_image(item[1]), path, ResourceSaver.FLAG_COMPRESS)
		if err != OK:
			push_error("save failed %s: %s" % [path, error_string(err)])
			failed = true
			continue
		var restored := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as Texture2D
		var rimg := restored.get_image() if restored != null else null
		if rimg == null or rimg.get_width() != SHEET or rimg.get_height() != SHEET or rimg.get_format() != Image.FORMAT_RGBA8:
			push_error("reload validation failed for %s" % path)
			failed = true
	print("terrain PBR layers baked: ", OUT, " sheet=", SHEET, "x", SHEET, " ok=", not failed)
	quit(1 if failed else 0)


func _bake_rock() -> Dictionary:
	var n_macro := _noise(FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 0.011, 3, 101)
	var n_mid := _noise(FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 0.028, 3, 102, SIZE, SIZE / 2)
	var n_fine := _noise(FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 0.065, 2, 103)
	var cracks_a := _cells(0.013, FastNoiseLite.CellularReturnType.RETURN_DISTANCE2_SUB, 107, 1.0, 32.0, 0.015)
	var facets := _cells(0.020, FastNoiseLite.CellularReturnType.RETURN_DISTANCE, 113, 0.85, 26.0, 0.016)

	var n := SIZE * SIZE
	var alb := PackedFloat32Array(); alb.resize(n)
	var h := PackedFloat32Array(); h.resize(n)
	var rough := PackedFloat32Array(); rough.resize(n)
	var ao := PackedFloat32Array(); ao.resize(n)
	for y in SIZE:
		for x in SIZE:
			var i := y * SIZE + x
			var phase := TAU * (1.0 * x + 6.0 * y) / float(SIZE) + (n_macro[i] - 0.5) * 4.5
			var wave := sin(phase)
			var strata := smoothstep(-0.68, 0.68, wave) * 0.65 + (0.5 + 0.5 * wave) * 0.35
			var ledge_edge := exp(-absf(wave) * 6.5)
			var crack := (1.0 - smoothstep(0.0, 0.095, cracks_a[i])) * 0.38
			var slab := 1.0 - smoothstep(0.14, 0.78, facets[i])
			var hv := clampf(strata * 0.56 + slab * 0.24 + n_mid[i] * 0.12 + n_fine[i] * 0.08 - crack, 0.0, 1.0)
			h[i] = hv
			alb[i] = clampf(0.95 + (strata - 0.5) * 0.18 + ledge_edge * 0.09 + (n_mid[i] - 0.5) * 0.10 - crack * 0.45, 0.72, 1.20)
			rough[i] = clampf(lerpf(0.71, 0.94, clampf(crack * 2.1 + (1.0 - slab) * 0.22, 0.0, 1.0)), 0.64, 0.96)
			ao[i] = clampf(1.0 - crack * 0.82 - (1.0 - hv) * 0.10, 0.64, 1.0)
	return _pack_layer(alb, h, rough, ao, 4.4)


func _bake_duff() -> Dictionary:
	var cushions := _cells(0.015, FastNoiseLite.CellularReturnType.RETURN_DISTANCE, 211, 1.0, 24.0, 0.015)
	var soft := _noise(FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 0.026, 3, 223, SIZE, SIZE, 12.0, 0.018)
	var mat_a := _noise(FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 0.048, 2, 227, SIZE, SIZE / 3)
	var mat_b := _noise(FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 0.048, 2, 229, SIZE / 3, SIZE)
	var clods := _noise(FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 0.085, 2, 233)

	var n := SIZE * SIZE
	var alb := PackedFloat32Array(); alb.resize(n)
	var h := PackedFloat32Array(); h.resize(n)
	var rough := PackedFloat32Array(); rough.resize(n)
	var ao := PackedFloat32Array(); ao.resize(n)
	for i in n:
		var dome := 1.0 - smoothstep(0.08, 0.72, cushions[i])
		var litter_mat := mat_a[i] * 0.55 + mat_b[i] * 0.45
		var hv := clampf(dome * 0.40 + soft[i] * 0.26 + litter_mat * 0.22 + clods[i] * 0.12, 0.0, 1.0)
		h[i] = hv
		alb[i] = clampf(0.92 + dome * 0.12 + (soft[i] - 0.5) * 0.14 + (litter_mat - 0.5) * 0.10 - (1.0 - hv) * 0.06, 0.76, 1.16)
		rough[i] = clampf(0.84 + (1.0 - dome) * 0.08 + clods[i] * 0.04, 0.80, 0.96)
		ao[i] = clampf(0.68 + 0.32 * smoothstep(0.14, 0.78, hv), 0.66, 1.0)
	return _pack_layer(alb, h, rough, ao, 3.4)


func _bake_turf() -> Dictionary:
	var tufts := _cells(0.018, FastNoiseLite.CellularReturnType.RETURN_DISTANCE, 307, 1.0, 22.0, 0.016)
	var clump_a := _noise(FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 0.042, 2, 311, SIZE, SIZE / 3, 8.0, 0.02)
	var clump_b := _noise(FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 0.042, 2, 313, SIZE / 3, SIZE, 8.0, 0.02)
	var macro_c := _noise(FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 0.022, 3, 317)
	var blades := _noise(FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 0.095, 2, 331)

	var n := SIZE * SIZE
	var alb := PackedFloat32Array(); alb.resize(n)
	var h := PackedFloat32Array(); h.resize(n)
	var rough := PackedFloat32Array(); rough.resize(n)
	var ao := PackedFloat32Array(); ao.resize(n)
	for i in n:
		var cushion := 1.0 - smoothstep(0.08, 0.74, tufts[i])
		var brush := clump_a[i] * 0.54 + clump_b[i] * 0.46
		var hv := clampf(cushion * 0.44 + brush * 0.30 + macro_c[i] * 0.16 + blades[i] * 0.10, 0.0, 1.0)
		h[i] = hv
		alb[i] = clampf(0.90 + hv * 0.18 + (macro_c[i] - 0.5) * 0.10, 0.78, 1.15)
		rough[i] = clampf(lerpf(0.96, 0.87, hv), 0.84, 0.97)
		ao[i] = clampf(0.68 + 0.32 * smoothstep(0.10, 0.74, hv), 0.66, 1.0)
	return _pack_layer(alb, h, rough, ao, 3.0)


func _bake_shingle() -> Dictionary:
	var c_big := _cells(0.019, FastNoiseLite.CellularReturnType.RETURN_DISTANCE, 401, 0.92, 7.0, 0.022)
	var c_small := _cells(0.040, FastNoiseLite.CellularReturnType.RETURN_DISTANCE, 409, 0.92, 5.0, 0.030)
	var stone_var := _noise(FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 0.032, 2, 419)
	var silt := _noise(FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 0.11, 2, 421)

	var n := SIZE * SIZE
	var alb := PackedFloat32Array(); alb.resize(n)
	var h := PackedFloat32Array(); h.resize(n)
	var rough := PackedFloat32Array(); rough.resize(n)
	var ao := PackedFloat32Array(); ao.resize(n)
	for i in n:
		var b_dome := 1.0 - smoothstep(0.10, 0.62, c_big[i])
		var s_dome := 1.0 - smoothstep(0.08, 0.58, c_small[i])
		var dome := maxf(b_dome, s_dome * 0.84)
		var gap := 1.0 - smoothstep(0.08, 0.42, dome)
		var hv := clampf(dome * 0.86 + silt[i] * 0.14 * gap, 0.0, 1.0)
		h[i] = hv
		var stone_tone := 0.90 + stone_var[i] * 0.24
		alb[i] = clampf(lerpf(stone_tone + (b_dome - 0.3) * 0.08, 0.78 + silt[i] * 0.10, gap), 0.72, 1.20)
		rough[i] = clampf(lerpf(0.62, 0.93, gap * 0.85 + silt[i] * 0.15), 0.60, 0.95)
		ao[i] = clampf(0.64 + 0.36 * smoothstep(0.06, 0.62, dome), 0.64, 1.0)
	return _pack_layer(alb, h, rough, ao, 4.2)


func _pack_layer(alb: PackedFloat32Array, h: PackedFloat32Array, rough: PackedFloat32Array, ao: PackedFloat32Array, strength: float) -> Dictionary:
	var n := SIZE * SIZE
	var sum := 0.0
	for i in n:
		sum += alb[i]
	var inv_mean := 1.0 / maxf(sum / float(n), 0.1)

	var ah_bytes := PackedByteArray(); ah_bytes.resize(n * 4)
	var nr_bytes := PackedByteArray(); nr_bytes.resize(n * 4)
	var gray := PackedByteArray(); gray.resize(n * 4)
	for i in n:
		var a_mod := clampf(alb[i] * inv_mean * 0.5, 0.0, 1.0)
		var ab := roundi(a_mod * 255.0)
		ah_bytes[i * 4] = ab
		ah_bytes[i * 4 + 1] = ab
		ah_bytes[i * 4 + 2] = ab
		var hv := roundi(clampf(h[i], 0.0, 1.0) * 255.0)
		ah_bytes[i * 4 + 3] = hv
		gray[i * 4] = hv
		gray[i * 4 + 1] = hv
		gray[i * 4 + 2] = hv
		gray[i * 4 + 3] = 255

	var tiled := Image.create(SIZE * 3, SIZE * 3, false, Image.FORMAT_RGBA8)
	var tile := Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_RGBA8, gray)
	for ty in 3:
		for tx in 3:
			tiled.blit_rect(tile, Rect2i(0, 0, SIZE, SIZE), Vector2i(tx * SIZE, ty * SIZE))
	tiled.bump_map_to_normal_map(strength)
	var mid := tiled.get_region(Rect2i(SIZE, SIZE, SIZE, SIZE)).get_data()
	for i in n:
		nr_bytes[i * 4] = mid[i * 4]
		nr_bytes[i * 4 + 1] = mid[i * 4 + 1]
		nr_bytes[i * 4 + 2] = roundi(clampf(rough[i], 0.0, 1.0) * 255.0)
		nr_bytes[i * 4 + 3] = roundi(clampf(ao[i], 0.0, 1.0) * 255.0)

	return {
		ah = Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_RGBA8, ah_bytes),
		nr = Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_RGBA8, nr_bytes),
		h = h,
	}


func _noise(type: int, freq: float, octaves: int, seed_val: int, w := SIZE, h_dim := SIZE, warp_amp := 0.0, warp_freq := 0.015) -> PackedFloat32Array:
	var n := FastNoiseLite.new()
	n.noise_type = type
	n.frequency = freq
	n.fractal_octaves = octaves
	n.seed = seed_val
	if warp_amp > 0.0:
		n.domain_warp_enabled = true
		n.domain_warp_type = FastNoiseLite.DOMAIN_WARP_SIMPLEX_REDUCED
		n.domain_warp_amplitude = warp_amp
		n.domain_warp_frequency = warp_freq
		n.domain_warp_fractal_octaves = 3
	var img := n.get_seamless_image(w, h_dim, false, false, 0.1, true)
	if w != SIZE or h_dim != SIZE:
		img.resize(SIZE, SIZE, Image.INTERPOLATE_BILINEAR)
	if img.get_format() != Image.FORMAT_L8:
		img.convert(Image.FORMAT_L8)
	var data := img.get_data()
	var out := PackedFloat32Array(); out.resize(SIZE * SIZE)
	var inv := 1.0 / 255.0
	for i in SIZE * SIZE:
		out[i] = float(data[i]) * inv
	return out


func _cells(freq: float, ret: int, seed_val: int, jitter: float, warp_amp := 0.0, warp_freq := 0.015) -> PackedFloat32Array:
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_CELLULAR
	n.frequency = freq
	n.cellular_return_type = ret
	n.cellular_jitter = jitter
	n.fractal_type = FastNoiseLite.FRACTAL_NONE
	n.seed = seed_val
	if warp_amp > 0.0:
		n.domain_warp_enabled = true
		n.domain_warp_type = FastNoiseLite.DOMAIN_WARP_SIMPLEX_REDUCED
		n.domain_warp_amplitude = warp_amp
		n.domain_warp_frequency = warp_freq
		n.domain_warp_fractal_octaves = 3
	var img := n.get_seamless_image(SIZE, SIZE, false, false, 0.1, true)
	if img.get_format() != Image.FORMAT_L8:
		img.convert(Image.FORMAT_L8)
	var data := img.get_data()
	var out := PackedFloat32Array(); out.resize(SIZE * SIZE)
	var inv := 1.0 / 255.0
	for i in SIZE * SIZE:
		out[i] = float(data[i]) * inv
	return out
