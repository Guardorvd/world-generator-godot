class_name MapBaker
extends RefCounted
## Запекание карты местности в 2D-изображение: текстура рельефа для 3D, карта для меню и мини-карты.
## Копия js/map/bake.js: попиксельная заливка (вода с глубиной и волнами, цвет биома с размытой границей,
## скалы, текстура, цветы и галька) и векторный слой (поляны поселений, реки, тропы).
## PX пикселей на клетку, центр клетки x — в пикселе (x + 0.5) * PX. За один проход получаются две картинки:
## без отмывки склонов (flat, для текстуры 3D-рельефа, где свет считает движок) и с отмывкой (для карты).
## Строки заливки считаются параллельно полосами.

const ROCKC := [150.0, 144.0, 138.0]
const FLOWERS := [[230, 220, 80], [230, 110, 140], [240, 240, 240], [150, 120, 220], [235, 140, 60]]
const BAND := 32
# Множители и сиды пиксельного хеша (как в WGRandom.hash2) и сид шумов заливки
const HASH_X := 374761393
const HASH_Y := 668265263
const HASH_MIX := 1274126177
const SEED_PAINT := 0xa5a5a5
const SEED_DETAIL := 0x5bd1e995


## Одна картинка: flat — без отмывки склонов
static func bake(w: WorldData, px: int, flat: bool) -> Image:
	var painted := paint(w, px, flat, not flat)
	return finish(w, px, [painted[0 if flat else 1]])[0]


## Две картинки за один проход: [без отмывки, с отмывкой]
static func bake_both(w: WorldData, px: int) -> Array[Image]:
	return finish(w, px, paint(w, px))


## Попиксельная заливка: [без отмывки, с отмывкой] в байтах RGB8. Читает только рельеф, воду и биомы,
## поэтому её можно считать сразу после этапа климата, параллельно с тропами и растительностью
## Ненужный вариант можно не выделять и не записывать; его место в паре остаётся пустым.
static func paint(w: WorldData, px: int, want_flat := true, want_shaded := true) -> Array[PackedByteArray]:
	var fields := _cell_fields(w)
	var rng := WGRandom.new(w.seed_num ^ SEED_PAINT)
	var noises := [Simplex.new(rng), Simplex.new(rng), Simplex.new(rng), Simplex.new(rng)]
	var flat := PackedByteArray()
	var shaded := PackedByteArray()
	for b in Parallel.bands(w.H * px, func(y0: int, y1: int) -> Array: return _paint_rows(w, px, fields, noises, y0, y1, want_flat, want_shaded), BAND):
		flat.append_array(b[0])
		shaded.append_array(b[1])
	return [flat, shaded]


## Векторный слой (поселения, реки, тропы) поверх заливки из paint, когда мир готов целиком
static func finish(w: WorldData, px: int, painted: Array[PackedByteArray], human_paths := true) -> Array[Image]:
	var iw := w.W * px
	var ih := w.H * px
	var out: Array[Image] = []
	for data in painted:
		var canvas := Canvas.new(data, iw, ih)
		_draw_overlays(w, px, canvas, human_paths)
		out.append(Image.create_from_data(iw, ih, false, Image.FORMAT_RGB8, canvas.data))
	return out


## Поля по клеткам: отмывка склонов, «водность» (больше 0 — вода) и глубина
static func _cell_fields(w: WorldData) -> Array:
	var W := w.W
	var H := w.H
	var elev := w.elev
	var shade := PackedFloat32Array()
	var wf := PackedFloat32Array()
	var depth := PackedFloat32Array()
	shade.resize(w.N)
	wf.resize(w.N)
	depth.resize(w.N)
	var L := [-0.55, -0.55, 0.63]
	for y in H:
		for x in W:
			var i := y * W + x
			var l := elev[y * W + maxi(0, x - 1)]
			var r := elev[y * W + mini(W - 1, x + 1)]
			var u := elev[maxi(0, y - 1) * W + x]
			var d := elev[mini(H - 1, y + 1) * W + x]
			var ex := 45.0
			var nx := -(r - l) * 0.5 * ex
			var ny := -(d - u) * 0.5 * ex
			var ln := sqrt(nx * nx + ny * ny + 1.0)
			var dot: float = (nx * L[0] + ny * L[1] + L[2]) / ln
			shade[i] = clampf(dot / 0.63, 0.45, 1.4)
			var dep := 0.0
			if w.ocean[i] != 0:
				dep = -w.h[i]
			elif w.lake[i] != 0:
				dep = w.filled[i] - w.h[i]
			depth[i] = dep
			wf[i] = 0.004 + minf(dep, 0.02) if (w.ocean[i] != 0 or w.lake[i] != 0) else -0.012
	return [shade, wf, depth]


static func _paint_rows(w: WorldData, PX: int, fields: Array, noises: Array, py0: int, py1: int, want_flat: bool, want_shaded: bool) -> Array:
	var W := w.W
	var H := w.H
	var biome := w.biome
	var lake := w.lake
	var elev := w.elev
	var temp := w.temp
	var shade: PackedFloat32Array = fields[0]
	var wf: PackedFloat32Array = fields[1]
	var depth: PackedFloat32Array = fields[2]
	# свои копии шумов и таблицы биомов для потока (общие объекты замедляют потоки GDScript)
	var n_jx: Simplex = noises[0].clone()
	var n_jy: Simplex = noises[1].clone()
	var n_tex: Simplex = noises[2].clone()
	var n_wave: Simplex = noises[3].clone()
	var nb := Biomes.LIST.size()
	var b_water := PackedByteArray()
	var b_flowers := PackedByteArray()
	var b_pebbles := PackedByteArray()
	var b_col := PackedFloat64Array()
	for bi in nb:
		var bd: Dictionary = Biomes.LIST[bi]
		b_water.append(1 if bd.get("water", false) else 0)
		b_flowers.append(1 if bd.get("flowers", false) else 0)
		b_pebbles.append(1 if bd.get("pebbles", false) else 0)
		for c in bd.color:
			b_col.append(c)
	var flowers := PackedFloat64Array()
	for fc in FLOWERS:
		for c in fc:
			flowers.append(c)
	var nfl := FLOWERS.size()
	var rock_r: float = ROCKC[0]
	var rock_g: float = ROCKC[1]
	var rock_b: float = ROCKC[2]
	var pix_seed := w.seed_num
	var seed2 := (w.seed_num ^ SEED_DETAIL) & 0xFFFFFFFF
	var IW := W * PX
	var out := PackedByteArray()
	if want_flat:
		out.resize((py1 - py0) * IW * 3)
	var out_s := PackedByteArray()
	if want_shaded:
		out_s.resize((py1 - py0) * IW * 3)
	var o := 0
	for py in range(py0, py1):
		var fy := (py + 0.5) / PX - 0.5
		var y0 := floori(fy)
		var ty := fy - y0
		var y1 := mini(H - 1, maxi(0, y0 + 1))
		y0 = mini(H - 1, maxi(0, y0))
		var ny_t := mini(H - 1, maxi(0, roundi(fy)))
		for px in IW:
			var fx := (px + 0.5) / PX - 0.5
			var x0 := floori(fx)
			var tx := fx - x0
			var x1 := mini(W - 1, maxi(0, x0 + 1))
			x0 = mini(W - 1, maxi(0, x0))
			var a := y0 * W + x0
			var b := y0 * W + x1
			var c := y1 * W + x0
			var d := y1 * W + x1
			var w00 := (1.0 - tx) * (1.0 - ty)
			var w10 := tx * (1.0 - ty)
			var w01 := (1.0 - tx) * ty
			var w11 := tx * ty
			# WGRandom.hash2(px, py, pix_seed), развёрнут на месте (см. Parallel)
			var hh := ((((px & 0xFFFF) * HASH_X + ((((px >> 16) * HASH_X) & 0xFFFF) << 16)) + ((py & 0xFFFF) * HASH_Y + ((((py >> 16) * HASH_Y) & 0xFFFF) << 16))) & 0xFFFFFFFF) ^ pix_seed
			hh ^= hh >> 13
			hh = ((hh & 0xFFFF) * HASH_MIX + ((((hh >> 16) * HASH_MIX) & 0xFFFF) << 16)) & 0xFFFFFFFF
			var hs := float((hh ^ (hh >> 16)) & 0xFFFFFFFF) / 4294967296.0
			var wv := wf[a] * w00 + wf[b] * w10 + wf[c] * w01 + wf[d] * w11 + n_jx.noise(fx * 0.25, fy * 0.25) * 0.006 + n_jy.noise(fx * 0.9 + 31.0, fy * 0.9) * 0.004
			var near := ny_t * W + mini(W - 1, maxi(0, roundi(fx)))
			var R: float
			var G: float
			var Bc: float
			# цвет с отмывкой (у воды совпадает с цветом без отмывки)
			var Rs: float
			var Gs: float
			var Bs: float
			if wv > 0.0:
				var dep := depth[a] * w00 + depth[b] * w10 + depth[c] * w01 + depth[d] * w11
				var is_lake := lake[near] == 1
				var t := sqrt(minf(1.0, dep / (0.09 if is_lake else 0.5)))
				if is_lake:
					R = 70.0 + (28.0 - 70.0) * t
					G = 138.0 + (66.0 - 138.0) * t
					Bc = 170.0 + (118.0 - 170.0) * t
				else:
					R = 72.0 + (14.0 - 72.0) * t
					G = 150.0 + (38.0 - 150.0) * t
					Bc = 190.0 + (84.0 - 190.0) * t
				var wave := n_wave.noise(fx * 0.7, fy * 2.2) * 0.5 + 0.5
				var k := 1.0 + (wave - 0.5) * 0.08 * (1.0 - t * 0.5) + (hs - 0.5) * 0.02
				R *= k
				G *= k
				Bc *= k
				if wv < 0.0035:
					var f := 0.45 * (1.0 - wv / 0.0035)
					R += (235.0 - R) * f
					G += (242.0 - G) * f
					Bc += (245.0 - Bc) * f
				Rs = R
				Gs = G
				Bs = Bc
			else:
				# WGRandom.hash2(py, px, pix_seed ^ SEED_DETAIL)
				hh = ((((py & 0xFFFF) * HASH_X + ((((py >> 16) * HASH_X) & 0xFFFF) << 16)) + ((px & 0xFFFF) * HASH_Y + ((((px >> 16) * HASH_Y) & 0xFFFF) << 16))) & 0xFFFFFFFF) ^ seed2
				hh ^= hh >> 13
				hh = ((hh & 0xFFFF) * HASH_MIX + ((((hh >> 16) * HASH_MIX) & 0xFFFF) << 16)) & 0xFFFFFFFF
				var hs2 := float((hh ^ (hh >> 16)) & 0xFFFFFFFF) / 4294967296.0
				var jx := n_jx.noise(fx * 0.3, fy * 0.3) * 1.0 + n_jx.noise(fx * 1.1 + 50.0, fy * 1.1) * 0.5 + (hs - 0.5) * 0.6
				var jy := n_jy.noise(fx * 0.3, fy * 0.3) * 1.0 + n_jy.noise(fx * 1.1, fy * 1.1 - 50.0) * 0.5 + (hs2 - 0.5) * 0.6
				var bx := mini(W - 1, maxi(0, roundi(fx + jx)))
				var by := mini(H - 1, maxi(0, roundi(fy + jy)))
				var bi: int = biome[by * W + bx]
				if b_water[bi] != 0:
					bi = biome[near]
				if b_water[bi] != 0:
					bi = Biomes.STONESHORE if temp[near] < 0.3 else Biomes.BEACH
				R = b_col[bi * 3]
				G = b_col[bi * 3 + 1]
				Bc = b_col[bi * 3 + 2]
				var e := elev[a] * w00 + elev[b] * w10 + elev[c] * w01 + elev[d] * w11
				if bi != Biomes.SNOW and bi != Biomes.PEAK:
					var st := clampf((e - 0.3) / (0.6 - 0.3), 0.0, 1.0)
					var m := st * st * (3.0 - 2.0 * st) * 0.45
					R += (rock_r - R) * m
					G += (rock_g - G) * m
					Bc += (rock_b - Bc) * m
				if bi == Biomes.BEACH and wv > -0.0045:
					R *= 0.86
					G *= 0.86
					Bc *= 0.86
				# без отмывки поле shade равно 1 во всех клетках, как в JS-версии с opts.flat
				var sh_flat := w00 + w10 + w01 + w11
				var sh := shade[a] * w00 + shade[b] * w10 + shade[c] * w01 + shade[d] * w11
				var tex := n_tex.noise(fx * 0.9, fy * 0.9) * 0.07 + n_tex.noise(fx * 3.1, fy * 3.1) * 0.04 + (hs - 0.5) * 0.07
				var k := sh * (1.0 + tex)
				var kf := sh_flat * (1.0 + tex)
				Rs = R * k
				Gs = G * k
				Bs = Bc * k
				R *= kf
				G *= kf
				Bc *= kf
				# Микродетали: цветы, галька, травинки
				if b_flowers[bi] != 0 and hs2 < 0.006:
					var fi := (floori(hs * 997) % nfl) * 3
					R = flowers[fi]
					G = flowers[fi + 1]
					Bc = flowers[fi + 2]
					Rs = R
					Gs = G
					Bs = Bc
				elif b_pebbles[bi] != 0 and hs2 < 0.012:
					var g := 0.75 + hs * 0.5
					R = 150.0 * g
					G = 146.0 * g
					Bc = 140.0 * g
					Rs = R
					Gs = G
					Bs = Bc
				elif hs2 > 0.985:
					R *= 0.85
					G *= 0.9
					Bc *= 0.85
					Rs *= 0.85
					Gs *= 0.9
					Bs *= 0.85
			if want_flat:
				out[o] = clampi(roundi(R), 0, 255)
				out[o + 1] = clampi(roundi(G), 0, 255)
				out[o + 2] = clampi(roundi(Bc), 0, 255)
			if want_shaded:
				out_s[o] = clampi(roundi(Rs), 0, 255)
				out_s[o + 1] = clampi(roundi(Gs), 0, 255)
				out_s[o + 2] = clampi(roundi(Bs), 0, 255)
			o += 3
	return [out, out_s]


## Векторный слой поверх заливки: поляны поселений, реки, тропы
static func _draw_overlays(w: WorldData, PX: int, cv: Canvas, human_paths := true) -> void:
	# Поляны вокруг поселений
	for s in w.settlements:
		cv.radial_glade(s.x * PX, s.y * PX, 6.5 * PX)
	# Реки: берег, затем вода
	for r in w.rivers:
		cv.stroke_poly(r, Color8(70, 80, 50), 0.35, 1.0, 0.35, PX)
	for r in w.rivers:
		cv.stroke_poly(r, Color8(62, 128, 176), 1.0, 1.0, 0.0, PX)
	for r in w.rivers:
		cv.stroke_poly(r, Color8(140, 200, 230), 0.35, 0.35, 0.0, PX)
	# Тропы: звериные бледные и узкие, людские — утоптанная земля, дороги шире и посыпаны гравием
	for t in w.trails:
		if t.kind == "animal":
			cv.stroke_poly(t.pts, Color8(120, 100, 70), 0.45, 1.0, 0.0, PX)
	# В 3D пути смешивает шейдер метровой сетки; на карте остаются прежние линии.
	if not human_paths:
		return
	for t in w.trails:
		if t.kind != "animal":
			cv.stroke_poly(t.pts, Color8(80, 60, 40), 0.35, 1.0, 0.18, PX)
	for t in w.trails:
		if t.kind != "animal" and t.kind != "road":
			_stroke_surface(cv, t, Color8(150, 136, 112) if t.kind == "mountain" else Color8(156, 124, 84), PX)
	# дороги поверх троп: где тропа слилась с дорогой, видна дорога
	for t in w.trails:
		if t.kind == "road":
			_stroke_surface(cv, t, Color8(172, 162, 142), PX)
	for t in w.trails:
		if t.kind == "trail":
			cv.stroke_poly(t.pts, Color8(190, 160, 115), 0.5, 0.35, 0.0, PX)


## Полоса пути цветом покрытия (RoadSurface, с 4.3): ломаная режется на куски с одним покрытием,
## соседние куски делят общую точку. Без покрытия — цвет fallback, как до 4.3
static func _stroke_surface(cv: Canvas, t: Dictionary, fallback: Color, PX: int) -> void:
	var surf: PackedByteArray = t.get("surf", PackedByteArray())
	if surf.size() != t.pts.size():
		cv.stroke_poly(t.pts, fallback, 1.0, 1.0, 0.0, PX)
		return
	var start := 0
	for n: int in range(1, t.pts.size() + 1):
		if n < t.pts.size() and surf[n] == surf[start]:
			continue
		var c: Array = RoadSurface.LIST[surf[start]].get("color", [])
		cv.stroke_poly(t.pts.slice(start, mini(n + 1, t.pts.size())), fallback if c.is_empty() else Color8(c[0], c[1], c[2]), 1.0, 1.0, 0.0, PX)
		start = n


## Простая растровая «кисть» поверх массива RGB8: круглые концы и стыки, без сглаживания
class Canvas:
	var data: PackedByteArray
	var iw: int
	var ih: int
	var stamp := PackedInt32Array()
	var stamp_id := 0

	func _init(d: PackedByteArray, w: int, h: int) -> void:
		data = d
		iw = w
		ih = h
		stamp.resize(w * h)

	func _blend(i: int, r: float, g: float, b: float, a: float) -> void:
		var o := i * 3
		data[o] = roundi(data[o] + (r - data[o]) * a)
		data[o + 1] = roundi(data[o + 1] + (g - data[o + 1]) * a)
		data[o + 2] = roundi(data[o + 2] + (b - data[o + 2]) * a)

	## Поляна поселения: радиальный градиент от центра к краю
	func radial_glade(cx: float, cy: float, rad: float) -> void:
		for py in range(maxi(0, floori(cy - rad)), mini(ih, ceili(cy + rad) + 1)):
			for px in range(maxi(0, floori(cx - rad)), mini(iw, ceili(cx + rad) + 1)):
				var t := Grid.hypot(px + 0.5 - cx, py + 0.5 - cy) / rad
				if t >= 1.0:
					continue
				var g: float
				var a: float
				if t < 0.6:
					var k := t / 0.6
					g = lerpf(130.0, 140.0, k)
					a = lerpf(0.55, 0.25, k)
				else:
					g = 140.0
					a = lerpf(0.25, 0.0, (t - 0.6) / 0.4)
				_blend(py * iw + px, 150.0, g, 90.0, a)

	## Ломаная из точек {x, y, w} в клетках. Полупрозрачная рисуется одним контуром средней ширины,
	## чтобы стыки сегментов не темнели; непрозрачная — сегментами своей ширины
	func stroke_poly(pts: Array, col: Color, alpha: float, w_mul: float, w_add: float, PX: int) -> void:
		if pts.size() < 2:
			return
		stamp_id += 1
		var r := col.r * 255.0
		var g := col.g * 255.0
		var b := col.b * 255.0
		var avg := 0.0
		var translucent := alpha < 1.0
		if translucent:
			for p in pts:
				avg += p.w
			avg /= pts.size()
		for k in pts.size() - 1:
			var p: Dictionary = pts[k]
			var q: Dictionary = pts[k + 1]
			var width: float
			if translucent:
				width = maxf(1.0, (avg * w_mul + w_add) * PX)
			else:
				width = maxf(1.0, ((p.w + q.w) * 0.5 * w_mul + w_add) * PX)
			_segment(p.x * PX, p.y * PX, q.x * PX, q.y * PX, width * 0.5, r, g, b, alpha)

	func _segment(ax: float, ay: float, bx: float, by: float, rad: float, r: float, g: float, b: float, a: float) -> void:
		var dx := bx - ax
		var dy := by - ay
		var len2 := dx * dx + dy * dy
		var r2 := rad * rad
		for py in range(maxi(0, floori(minf(ay, by) - rad)), mini(ih, ceili(maxf(ay, by) + rad) + 1)):
			for px in range(maxi(0, floori(minf(ax, bx) - rad)), mini(iw, ceili(maxf(ax, bx) + rad) + 1)):
				var cx := px + 0.5 - ax
				var cy := py + 0.5 - ay
				var t := 0.0
				if len2 > 0.0:
					t = clampf((cx * dx + cy * dy) / len2, 0.0, 1.0)
				var ex := cx - dx * t
				var ey := cy - dy * t
				if ex * ex + ey * ey > r2:
					continue
				var i := py * iw + px
				if stamp[i] == stamp_id:
					continue
				stamp[i] = stamp_id
				_blend(i, r, g, b, a)
