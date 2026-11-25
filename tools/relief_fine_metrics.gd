extends RefCounted
## Два независимых измерения: спектр непрерывной опоры и изломы на рёбрах отрисованных треугольников.

const SIDE := 128 # отсчёты через метр; измеряем волны от 2 м до ширины окна
const BANDS := [2, 4, 8, 16, 32, 64, SIDE]
const CREASES := [1.0, 2.0, 5.0, 10.0, 20.0]
const TOLERANCE_M := 0.001


static func spectrum(h: Heightfield, focus: Vector2) -> Dictionary:
	var centre := (SIDE - 1) * 0.5
	return _spectrum(func(x: int, z: int) -> float:
		return _surface(h, focus.x + x - centre, focus.y + z - centre), 1.0, BANDS)


## Опора без полотна дорог: поле 2 м у опубликованных плиток, иначе сетка 4 м.
static func _surface(h: Heightfield, x: float, z: float) -> float:
	if h.fine_relief != null:
		var detailed: float = h.fine_relief.Sample(x, z, false)
		if not is_nan(detailed):
			return detailed
	return h.base_ground_at(x, z)


static func _spectrum(sample: Callable, spacing: float, bands: Array) -> Dictionary:
	# Окно Ханна после вычитания плоскости МНК: общий уклон и границы окна не дают ложную мелкую энергию.
	var data := PackedVector2Array()
	data.resize(SIDE * SIDE)
	var centre := (SIDE - 1) * 0.5
	var mean := 0.0
	var gradient := Vector2.ZERO
	var spread := 0.0
	var window := PackedFloat64Array()
	for x in SIDE:
		window.append(0.5 - 0.5 * cos(TAU * x / (SIDE - 1)))
		spread += (x - centre) ** 2
	for z in SIDE:
		for x in SIDE:
			var offset := Vector2(x - centre, z - centre)
			var y: float = sample.call(x, z)
			data[z * SIDE + x] = Vector2(y, 0.0)
			mean += y
			gradient += y * offset
	mean /= data.size()
	gradient /= spread * SIDE
	for z in SIDE:
		for x in SIDE:
			var i := z * SIDE + x
			var plane := mean + gradient.dot(Vector2(x - centre, z - centre))
			data[i].x = (data[i].x - plane) * window[x] * window[z]
	var reverse := PackedInt32Array()
	reverse.resize(SIDE)
	var twiddle := PackedVector2Array()
	for i in SIDE:
		reverse[i] = (reverse[i >> 1] >> 1) | ((i & 1) * (SIDE >> 1))
		twiddle.append(Vector2.from_angle(-TAU * i / SIDE))
	for i in SIDE:
		_fft(data, i * SIDE, 1, reverse, twiddle)
	for i in SIDE:
		_fft(data, i, SIDE, reverse, twiddle)
	var power := PackedFloat64Array()
	power.resize(bands.size() - 1)
	var total := 0.0
	for z in SIDE:
		for x in SIDE:
			var frequency := Vector2(mini(x, SIDE - x), mini(z, SIDE - z)).length()
			if frequency < 1.0 or frequency > SIDE * 0.5:
				continue
			var length_m := SIDE * spacing / frequency
			var energy := data[z * SIDE + x].length_squared()
			total += energy
			for band in power.size():
				if length_m <= bands[band + 1]:
					power[band] += energy
					break
	var share := {}
	for band in power.size():
		share["%d-%d" % [bands[band], bands[band + 1]]] = 100.0 * power[band] / total if total > 0.0 else 0.0
	return share


static func _fft(data: PackedVector2Array, start: int, stride: int, reverse: PackedInt32Array, twiddle: PackedVector2Array) -> void:
	for i in SIDE:
		var j := reverse[i]
		if j > i:
			var a := start + i * stride
			var b := start + j * stride
			var saved := data[a]
			data[a] = data[b]
			data[b] = saved
	var size := 2
	while size <= SIDE:
		var half := size >> 1
		for block in range(0, SIDE, size):
			for i in half:
				var a := start + (block + i) * stride
				var b := a + half * stride
				var w := twiddle[i * (SIDE / size)]
				var v := data[b]
				var product := Vector2(v.x * w.x - v.y * w.y, v.x * w.y + v.y * w.x)
				data[b] = data[a] - product
				data[a] += product
		size <<= 1


static func mesh_stats(pieces: Array, h: Heightfield, eye: Vector3, focus: Vector2, parity: bool) -> Dictionary:
	var rect := Rect2(focus - Vector2.ONE * SIDE * 0.5, Vector2.ONE * SIDE)
	var eye_xz := Vector2(eye.x, eye.z)
	var edges := {}
	var lengths := PackedFloat64Array()
	lengths.resize(CREASES.size())
	var natural_lengths := lengths.duplicate()
	var shared_m := 0.0
	var natural_shared_m := 0.0
	var peak_angle := 0.0
	var checked := 0
	var failed := 0
	var patch_samples := 0
	var max_error := 0.0
	var max_grade_gain := 0.0
	var ride := h.ride_snapshot() if parity else null
	for arrays: Array in pieces:
		var xyz: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var ids: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var custom: Variant = arrays[Mesh.ARRAY_CUSTOM0]
		var morph: PackedFloat32Array
		if custom is PackedFloat32Array:
			morph = custom
		elif custom is PackedByteArray:
			morph = custom.to_float32_array()
		for i in range(0, ids.size(), 3):
			var a := xyz[ids[i]]
			var b := xyz[ids[i + 1]]
			var c := xyz[ids[i + 2]]
			var normal := (c - a).cross(b - a).normalized()
			if normal.y <= 0.0:
				continue # вертикальная юбка LOD не является опорой
			var mid := (a + b + c) / 3.0
			var cell := Vector2i(floori(mid.x / GameConfig.TILE - 0.5), floori(mid.z / GameConfig.TILE - 0.5))
			var cell_id := cell.y * h.world.W + cell.x
			var patch := h.road_refinement.patches.has(cell_id)
			if rect.has_point(Vector2(mid.x, mid.z)):
				if not morph.is_empty():
					var coarse_normal := Vector3(c.x - a.x, morph[ids[i + 2] * 4] - morph[ids[i] * 4], c.z - a.z).cross(
						Vector3(b.x - a.x, morph[ids[i + 1] * 4] - morph[ids[i] * 4], b.z - a.z))
					max_grade_gain = maxf(max_grade_gain, grade(normal) - grade(coarse_normal))
				var natural := not patch and h.world.river_area[cell_id] == 0 and h.world.lake[cell_id] == 0
				for edge: Vector2i in [Vector2i(0, 1), Vector2i(1, 2), Vector2i(2, 0)]:
					var u := xyz[ids[i + edge.x]]
					var v := xyz[ids[i + edge.y]]
					# Ключи метровых отрезков соединяют также Т-стыки патчей с сеткой 4 м.
					var steps := roundi(maxf(absf(v.x - u.x), absf(v.z - u.z)))
					var weight := u.distance_to(v) / steps
					for j in steps:
						var p := u.lerp(v, float(j) / steps)
						var q := u.lerp(v, float(j + 1) / steps)
						var code := Vector4i(roundi(p.x), roundi(p.z), roundi(q.x), roundi(q.z))
						if code.x > code.z or (code.x == code.z and code.y > code.w):
							code = Vector4i(code.z, code.w, code.x, code.y)
						if not edges.has(code):
							edges[code] = Vector4(normal.x, normal.y, normal.z, float(natural))
							continue
						var prior: Vector4 = edges[code]
						var other := Vector3(prior.x, prior.y, prior.z)
						var natural_edge := natural and prior.w == 1.0
						edges.erase(code)
						var angle := rad_to_deg(atan2(other.cross(normal).length(), other.dot(normal)))
						shared_m += weight
						if natural_edge:
							natural_shared_m += weight
						peak_angle = maxf(peak_angle, angle)
						for bin in CREASES.size():
							if angle >= CREASES[bin]:
								lengths[bin] += weight
								if natural_edge:
									natural_lengths[bin] += weight
			if ride != null and eye_xz.distance_to(Vector2(mid.x, mid.z)) < 50.0:
				# Смещённые барицентрические точки ловят неверную диагональ даже при верных вершинах.
				for sample: Array in [[1.0 / 3.0, 1.0 / 3.0], [0.3, 0.1]]:
					var u: float = sample[0]
					var v: float = sample[1]
					var x := a.x + (b.x - a.x) * u + (c.x - a.x) * v
					var y := a.y + (b.y - a.y) * u + (c.y - a.y) * v
					var z := a.z + (b.z - a.z) * u + (c.z - a.z) * v
					var error := maxf(absf(ride.Ground(x, z) - y), absf(h._ground_script(x, z) - y))
					if not is_finite(error):
						error = INF
					max_error = maxf(max_error, error)
					failed += int(error > TOLERANCE_M)
					checked += 1
					patch_samples += int(patch)
	var shares := {}
	var natural_shares := {}
	for bin in CREASES.size():
		shares[str(CREASES[bin])] = 100.0 * lengths[bin] / shared_m if shared_m > 0.0 else 0.0
		natural_shares[str(CREASES[bin])] = 100.0 * natural_lengths[bin] / natural_shared_m if natural_shared_m > 0.0 else 0.0
	return {shared_edge_m = shared_m, edge_pct_above_deg = shares, max_angle_deg = peak_angle,
		max_grade_gain_over_coarse = max_grade_gain,
		natural_edge_m = natural_shared_m, natural_edge_pct_above_deg = natural_shares,
		parity_samples = checked, parity_patch_samples = patch_samples, parity_failed = failed, max_error_mm = max_error * 1000.0}


static func grade(normal: Vector3) -> float:
	return Vector2(normal.x, normal.z).length() / absf(normal.y) if normal.y != 0.0 else INF


static func near_view(key: Vector2i, eye: Vector2, focus: Vector2) -> bool:
	var corner := Vector2(key) * PlanTerrain.SIDE + Vector2.ONE * GameConfig.TILE * 0.5
	var opposite := corner + Vector2.ONE * PlanTerrain.SIDE
	return focus.distance_to(focus.clamp(corner, opposite)) <= SIDE * 0.8 or eye.distance_to(eye.clamp(corner, opposite)) <= 50.0
