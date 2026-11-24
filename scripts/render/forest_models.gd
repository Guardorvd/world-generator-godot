class_name ForestModels
extends RefCounted
## Художественные модели умеренного леса. Общие меши, без узлов на каждую ветку.
## Заранее построенные силуэты; RNG локальный, генерацию мира не затрагивает.

## Взрослые силуэты 0..3 выбираются по координатам дерева; у сосны, берёзы и дуба за ними возрастные формы
## (с 11.11.2026): молодые YOUNG, YOUNG + 1 и старые OLD, OLD + 1. Модель — вид + форма * MODEL_STRIDE.
const VARIANTS := 4
const AGE_FORMS := 2
const YOUNG := 4
const OLD := 6
const MODEL_STRIDE := 256
## Возрастной класс дерева в obj_v: v = оттенок (0..2) + 3 * класс.
const ADULT_AGE := 0
const YOUNG_AGE := 1
const OLD_AGE := 2
## Номинальная высота взрослого дерева породы при масштабе 1, м. Поле ref формы — её высота в долях номинала:
## масштаб экземпляра = obj_s / ref, поэтому obj_s — линейный размер дерева независимо от возрастной формы.
const NOMINAL := {Biomes.T_PINE: 19.0, Biomes.T_BIRCH: 16.0, Biomes.T_OAK: 14.5, Biomes.T_SNOWPINE: 12.0, Biomes.T_ROWAN: 9.5, Biomes.T_MUGO: 2.2,
	Biomes.T_SPRUCE: 26.0, Biomes.T_LARCH: 22.0, Biomes.T_ALDER: 8.0,
	Biomes.T_WESTERN_REDCEDAR: 30.0, Biomes.T_SIBERIAN_CEDAR: 24.0, Biomes.T_MAPLE: 22.0,
	Biomes.T_HEMLOCK: 27.0, Biomes.T_DOUGLAS_FIR: 37.0}
const MAPLE_TEXTURE := 6
static var _leaf_texture: Texture2D
static var _pinnate_texture: Texture2D
static var _bark_texture: Texture2D
static var _needle_texture: Texture2D
static var _maple_leaf_texture: Texture2D
static var baking := false # authoring tool only


## Есть ли у вида молодые и старые формы.
static func has_ages(kind: int) -> bool:
	return kind == Biomes.T_PINE or kind == Biomes.T_BIRCH or kind == Biomes.T_OAK or kind == Biomes.T_ROWAN or kind in Biomes.EXPEDITION_TREES


## Сколько форм вида запекается.
static func form_count(kind: int) -> int:
	return VARIANTS + 2 * AGE_FORMS if has_ages(kind) else VARIANTS


## Возрастной класс формы variant: взрослая, молодая или старая.
static func age_of(variant: int) -> int:
	return OLD_AGE if variant >= OLD else (YOUNG_AGE if variant >= YOUNG else ADULT_AGE)


static func definition(kind: int, variant: int) -> Dictionary:
	if kind == Biomes.T_PALM:
		return _palm(variant)
	if kind == Biomes.T_JUNGLE:
		return _jungle(variant)
	if kind == Biomes.T_ACACIA:
		return _acacia(variant)
	if kind == Biomes.T_DEAD:
		return _dead(variant)
	if kind == Biomes.T_BUSH:
		return _bush(variant)
	if kind == Biomes.T_BIRCH:
		return _birch(variant)
	if kind == Biomes.T_OAK:
		return _oak(variant)
	if kind == Biomes.T_ROWAN:
		return _rowan(variant)
	if kind == Biomes.T_MUGO:
		return _mugo(variant)
	if kind == Biomes.T_ALDER:
		return _alder(variant)
	if kind == Biomes.T_MAPLE:
		return _maple(variant)
	if kind in Biomes.EXPEDITION_TREES:
		return _expedition_conifer(kind, variant)
	return _conifer(kind, variant)


## Породы экспедиции используют общие трубы, хвойный атлас, затенение крон и три LOD.
static func _expedition_conifer(kind: int, variant: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = kind * 1877 + variant * 397
	var age := age_of(variant)
	var form := variant % VARIANTS if age == ADULT_AGE else variant % AGE_FORMS
	var western := kind == Biomes.T_WESTERN_REDCEDAR
	var siberian := kind == Biomes.T_SIBERIAN_CEDAR
	var larch := kind == Biomes.T_LARCH
	var hemlock := kind == Biomes.T_HEMLOCK
	var douglas := kind == Biomes.T_DOUGLAS_FIR
	var spruce := kind == Biomes.T_SPRUCE
	var dense_spruce := spruce and form != 1 and (age != ADULT_AGE or form in [0, 2])
	var giant := age == OLD_AGE
	var nominal: float = NOMINAL[kind]
	var adult_shape := [0.94, 1.07, 0.93, 1.02]
	var height: float = nominal * ([0.32, 0.39][form] if age == YOUNG_AGE else ([1.25, 1.16][form] if age == OLD_AGE else adult_shape[form]))
	var radius := height * (0.023 if western else (0.017 if siberian else (0.012 if larch else 0.014)))
	if western and age != YOUNG_AGE:
		radius *= ([1.6, 1.42][form] if giant else [1.22, 1.0, 1.32, 1.10][form])
	if douglas:
		radius = height * ([0.037, 0.032][form] if giant else (0.020 if age == YOUNG_AGE else [0.027, 0.022, 0.030, 0.026][form]))
	if hemlock:
		radius *= 1.10 if age == YOUNG_AGE else 1.25
	var angle := rng.randf() * TAU
	var bend: Vector3 = Vector3(cos(angle), 0, sin(angle)) * height * [0.014, 0.024, 0.048, 0.031][form]
	var bark := Color("765043") if western else (Color("655449") if larch else Color("59483a"))
	if douglas:
		bark = Color("684839") if giant else Color("695244")
	elif hemlock:
		bark = Color("55483f")
	var path: Array[Vector3] = []
	for t: float in [0.0, 0.063, 0.18, 0.36, 0.55, 0.78, 1.0]:
		# _path_at интерполирует по индексу, поэтому ярусы привязываются к фактической высоте ниже.
		path.append(Vector3.UP * height * t + bend * t * t + bend.cross(Vector3.UP) * sin(t * TAU) * 0.22)
	if hemlock:
		var leader := Vector3(cos(angle + 0.7), 0, sin(angle + 0.7)) * height
		path.insert(path.size() - 1, Vector3.UP * height * 0.96 + bend * 0.92 + leader * 0.024)
		path[-1] = Vector3.UP * height * 0.943 + bend + leader * 0.067
	var moss := (0.72 if giant else 0.28) if western else (0.32 if douglas and giant else 0.0)
	var branches: Array = [[path, radius, radius * 0.07, bark, false, false, moss]]
	var root_width := radius * (2.9 if western else (2.0 if douglas else 1.65))
	_roots(branches, rng, 7 if western and giant else (6 if western or douglas else 4), Vector2(root_width, root_width * 1.35),
		radius * (2.2 if western else 1.15), radius * 0.20, radius * 0.46, bark, western or douglas)
	if moss > 0.0:
		for n in range(1, branches.size()):
			branches[n].append(moss * 0.80)
	var foliage: Array = []
	var spray_lods: Array = [[], []] if western or hemlock else []
	var base := 0.20 if not larch and not siberian else (0.30 if larch else 0.35)
	if age == YOUNG_AGE:
		base *= 0.62
	elif age == OLD_AGE:
		base += 0.10 if not siberian else 0.16
	base += [0.02, 0.08, -0.03, 0.04][form]
	if dense_spruce:
		base = 0.045 if age == YOUNG_AGE else base * 0.73
	if hemlock:
		base = 0.06 if age == YOUNG_AGE else ([0.19, 0.29, 0.14, 0.24][form] + (0.05 if giant else 0.0))
	if douglas:
		base = 0.16 if age == YOUNG_AGE else ([0.39, 0.50, 0.42, 0.46][form] + (0.10 if giant else 0.0))
	var span_max: float = height * (0.159 if siberian else (0.125 if western else (0.11 if larch else 0.106))) * [1.0, 0.86, 1.12, 1.05][form]
	if dense_spruce or (western and form != 1) or (siberian and (giant or form in [0, 2])):
		span_max *= 1.24
	if hemlock:
		span_max = height * [0.160, 0.145, 0.199, 0.170][form]
	if douglas:
		span_max = height * [0.150, 0.123, 0.166, 0.141][form]
	var tiers := 7 if siberian else (9 if larch or douglas else 11)
	var top := 0.925 if hemlock else 0.985
	for tier in tiers:
		var t := float(tier) / tiers
		var crown_y := lerpf(base, top, t)
		var profile := pow(1.0 - t, 0.51 if siberian else (0.58 if western else (0.72 if larch else 0.68)))
		if siberian:
			profile *= lerpf(0.76, 1.29, sin(t * PI))
		if hemlock:
			profile *= (0.87 + 0.17 * sin(tier * 1.48 + form)) * (0.96 + 0.22 * sin(t * PI))
		elif douglas:
			profile = lerpf(0.61, 1.16, sin(t * PI)) * pow(1.0 - t, 0.38 if giant else 0.64)
		var arms := 3 if larch or tier >= tiers - 2 else 4
		for arm in arms:
			var a := angle + tier * 2.399 + arm * TAU / arms + rng.randf_range(-0.26, 0.26)
			var dir := Vector3(cos(a), 0.0, sin(a))
			var y := height * crown_y + rng.randf_range(-0.022, 0.022) * height
			var start := path[0]
			for ring in range(1, path.size()):
				if path[ring].y >= y:
					start = path[ring - 1].lerp(path[ring], inverse_lerp(path[ring - 1].y, path[ring].y, y))
					break
			var span := span_max * profile * rng.randf_range(0.75, 1.18) * (1.0 + 0.24 * maxf(0.0, dir.dot(bend.normalized())) * float(form == 2))
			var tip_slope := -0.31 if western else (0.27 if siberian else (-0.17 if not larch and tier < 3 else 0.13))
			if hemlock or douglas:
				span *= 0.89 + 0.20 * sin(arm * 1.57 + tier * 0.74 + form)
				tip_slope = -0.36 - 0.11 * sin(a + tier) if hemlock else 0.12 + 0.17 * sin(a + tier * 0.6)
			var lift := 0.20 if western or siberian else (-0.17 if douglas else -0.085)
			var elbow := start + dir * span * 0.48 + Vector3.UP * span * lift
			var tip := start + dir * span + Vector3.UP * span * tip_slope
			if hemlock or dense_spruce:
				tip.y = maxf(tip.y, height * 0.025)
			if tier < tiers - 2:
				var thick := radius * (0.37 if douglas else (0.25 if siberian or western else 0.22)) * (1.0 - t * 0.74)
				branches.append([[start, elbow, tip], thick, thick * 0.16, bark, false, true])
			var center := elbow.lerp(tip, 0.36 if larch or western or hemlock else 0.26)
			if dense_spruce or hemlock:
				center.y = maxf(center.y, height * 0.055)
			if western or hemlock:
				var size := Vector3(span * (0.69 if hemlock else 0.62), span * (0.28 if hemlock else 0.24), span * 0.43)
				var phase := rng.randf() * TAU
				var frame := _frame(tip - elbow)
				foliage.append([center, size, a, phase, frame, 1.12])
				# Один веер на лапу даёт сплошной ярус в тех же пределах, что два сложенных веера вблизи.
				spray_lods[0].append([center, size * Vector3(1.0, 1.0, 1.12), a, phase, frame, 1.12])
				if arms == 3 or arm != (tier + form) % arms:
					# Пропуск поворачивается между ярусами. Сохраняем лапы с разных сторон ствола.
					var tilt := Basis(Vector3.RIGHT, 0.22 * sin(phase + tier))
					spray_lods[1].append([center, size * Vector3(1.06, 1.0, 1.24), a, phase, frame * tilt, 1.12])
			else:
				var depth := maxf(span * (0.39 if siberian else (0.23 if larch else 0.44)), height * (0.026 if larch else 0.027))
				if dense_spruce:
					depth *= 1.16
				foliage.append([center, Vector3(span * (0.57 if larch or siberian else 0.69), depth, span * 0.55), a, rng.randf() * TAU])
				if douglas and (arm + tier) % 3 == 0:
					var fork := dir.rotated(Vector3.UP, 0.58)
					foliage.append([elbow + fork * span * 0.49 + Vector3.UP * depth,
						Vector3(span * 0.38, depth * 0.86, span * 0.36), a + 0.58, rng.randf() * TAU])
				if siberian and tier < 5:
					var fork := dir.rotated(Vector3.UP, 0.48 if arm % 2 == 0 else -0.48)
					foliage.append([elbow + fork * span * 0.42 + Vector3.UP * depth * 0.7,
						Vector3(span * 0.43, depth * 0.8, span * 0.41), atan2(fork.z, fork.x), rng.randf() * TAU])
		# Внутренние пучки связывают верхние ярусы с осью, оставляя просветы у концов ветвей.
		if not siberian and (not larch or tier % 2 == 0 or t > 0.64):
			var core := path[5].lerp(path[6], clampf((crown_y - 0.78) / 0.22, 0.0, 1.0)) if crown_y > 0.78 else Vector3.UP * height * crown_y + bend * crown_y * crown_y
			var width := span_max * profile * (0.52 if larch else (0.57 if western else 0.65))
			var vertical := height * (0.045 if larch else 0.053)
			var inner := [core + Vector3.UP * vertical * 0.47, Vector3(width, vertical, width * 0.9),
				angle + tier * 2.399, rng.randf() * TAU, true]
			foliage.append(inner)
			if western or hemlock:
				spray_lods[0].append(inner)
				if tier % 2 == 0:
					var joined := inner.duplicate()
					joined[1] *= Vector3(1.10, 1.28, 1.10)
					spray_lods[1].append(joined)
	var apex := height * (0.055 if siberian else 0.047)
	var tip_spray := [path[-1] - Vector3.UP * apex * 0.90,
		Vector3(apex * (1.05 if siberian else 0.49), apex * 0.9, apex * 0.64), angle, 2.0, true]
	if hemlock:
		tip_spray = [path[-2].lerp(path[-1], 0.63), Vector3(apex * 0.86, apex * 0.43, apex * 0.52),
			angle + 0.7, 2.0, _frame(path[-1] - path[-2]), 0.92]
	if siberian and giant and form == 0:
		var fork_at := path[4]
		var fork_end := path[5] + Vector3(cos(angle), 0.08, sin(angle)) * height * 0.115
		branches.append([[fork_at, fork_at.lerp(fork_end, 0.48) + Vector3.UP * height * 0.046, fork_end],
			radius * 0.38, radius * 0.08, bark, false])
		foliage.append([fork_end, Vector3(apex * 1.6, apex * 1.3, apex * 1.3), angle, 1.1, true])
	foliage.append(tip_spray)
	for lod: Array in spray_lods:
		lod.append(tip_spray)
	if douglas:
		# Compact the merged cards on the last LOD; along-branch positions still carry the outline.
		var middle := _far_foliage(foliage, true)
		var distant := _far_foliage(middle, true, true)
		for spray: Array in distant:
			spray[1] *= Vector3(0.91, 0.84, 0.91)
		spray_lods = [middle, distant]
	return {trunk = _mesh(branches, [], false), crown = _mesh([], foliage, true, [], spray_lods), bark = Color.WHITE,
		leaves = _expedition_colors(kind), colored_bark = true, cutout = true, trunk_texture = _texture(false),
		crown_texture = _texture(true, true), ref = _ref(kind, age, height)}


static func _alder(variant: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 81379 + variant * 439
	var age := age_of(variant)
	var form := variant % VARIANTS if age == ADULT_AGE else variant % AGE_FORMS
	var height: float = NOMINAL[Biomes.T_ALDER] * ([0.43, 0.52][form] if age == YOUNG_AGE else ([1.12, 1.22][form] if age == OLD_AGE else [0.89, 1.04, 0.80, 0.97][form]))
	var stems: int = [3, 2, 4, 3][form]
	var branches: Array = []
	var foliage: Array = []
	var angle := rng.randf() * TAU
	var bark := Color("726b59")
	for n in stems:
		var a := angle + n * TAU / stems + rng.randf_range(-0.32, 0.32)
		var dir := Vector3(cos(a), 0, sin(a))
		var h := height * (0.98 if n == 0 else rng.randf_range(0.56, 0.87))
		var spread: float = h * ([0.29, 0.18, 0.39, 0.27][form] + n * 0.028)
		var path := _rowan_trunk(dir * h * 0.015, dir, h, spread, h * 0.035, a, 6)
		var r := h * (0.028 if n == 0 else 0.024)
		branches.append([path, r, r * 0.16, bark, false])
		for limb in 3:
			var phi := a + (limb - 1) * 0.92
			var forward := Vector3(cos(phi), 0, sin(phi))
			var origin := _path_at(path, 0.46 + limb * 0.19)
			var end := origin + forward * h * (0.24 - limb * 0.045) + Vector3.UP * h * (0.24 - limb * 0.07)
			branches.append([[origin, origin.lerp(end, 0.54) + Vector3.UP * h * 0.06, end], r * 0.46, r * 0.1, bark, false, true])
			foliage.append([end, Vector3(0.16, 0.106, 0.14) * h, phi, rng.randf() * TAU])
			foliage.append([origin.lerp(end, 0.63) + Vector3.UP * h * 0.085,
				Vector3(0.14, 0.122, 0.12) * h, phi + 0.8, rng.randf() * TAU])
		foliage.append([path[-1] - Vector3.UP * h * 0.09, Vector3(0.14, 0.115, 0.12) * h, a, rng.randf() * TAU, true])
	return _leafy(branches, foliage, _expedition_colors(Biomes.T_ALDER), false, _ref(Biomes.T_ALDER, age, height))


static func _expedition_colors(kind: int) -> Array:
	var color: Color = Biomes.EXPEDITION_CROWN[kind]
	return [color * 0.94, color, color * 1.06]


## Низкая неровная развилка и пологие рукава, вдоль которых лежат отдельные листовые веера.
static func _maple(variant: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 19179 + variant * 431
	var age := age_of(variant)
	var old := age == OLD_AGE
	var young := age == YOUNG_AGE
	var form := variant if age == ADULT_AGE else variant % AGE_FORMS
	var height: float = ([7.0, 8.8] if young else ([27.0, 25.2] if old else [19.2, 23.4, 20.5, 21.8]))[form]
	var fork: float = ([0.48, 0.40] if young else ([0.34, 0.43] if old else [0.36, 0.57, 0.41, 0.33]))[form]
	var reach: float = ([0.18, 0.22] if young else ([0.28, 0.31] if old else [0.31, 0.20, 0.29, 0.27]))[form]
	var radius: float = ([0.16, 0.20] if young else ([0.96, 0.87] if old else [0.64, 0.55, 0.67, 0.62]))[form]
	var angle := rng.randf() * TAU
	var lean := Vector3(cos(angle), 0, sin(angle))
	var bow: float = height * [0.052, 0.037, 0.142, 0.067][form] * (1.2 if old else 1.0)
	var bark := Color("746656") if not old else Color("625748")
	var trunk := _rowan_trunk(Vector3(0, -0.04, 0), lean, height * fork, bow, height * 0.037, angle, 7)
	var spine := trunk.duplicate()
	var moss := (0.80 if form == 0 else 0.58) if old else 0.0
	var branches: Array = [[spine, radius, radius * 0.12, bark, false, false, moss]]
	_roots(branches, rng, 6 if old else (3 if young else 5), Vector2(radius * 1.7, radius * 3.35),
		radius * (1.9 if old else 1.5), radius * 0.14, radius * 0.45, bark.lerp(Color("53603d"), moss * 0.43))
	var foliage: Array = []
	var arms := 4 if old or form == 3 else 3
	for arm in arms:
		var a := angle + arm * 2.18 + rng.randf_range(-0.22, 0.22)
		var outward := Vector3(cos(a), 0, sin(a))
		var side := outward.cross(Vector3.UP)
		var start: Vector3 = _path_at(trunk, 1.0 - 0.085 * arm)
		var lateral := rng.randf_range(0.89, 1.14)
		if form == 2:
			lateral *= 1.3 if arm % 2 == 0 else 0.68
		var span := reach * height * lateral * (0.48 if arm == 0 else 1.0)
		var finish_y := height * (0.92 if arm == 0 else rng.randf_range(0.65, 0.83))
		var rise := finish_y - start.y
		var elbow := start + outward * span * 0.48 + Vector3.UP * rise * (0.50 if arm == 0 else 0.18)
		var shoulder := start + outward * span * 0.78 + side * span * 0.14 + Vector3.UP * rise * 0.58
		var tip := start + outward * span + side * span * 0.06 + Vector3.UP * rise
		var path: Array[Vector3] = [start, elbow, shoulder, tip]
		if arm == 0:
			# One continuous trunk through the fork, with no open rings at the joint.
			spine.append_array([elbow, shoulder, tip])
		else:
			branches.append([path, radius * 0.39, radius * 0.12, bark, false, false, moss * 0.73])
		var forks := 3 if young else 5
		for j in forks:
			var t := lerpf(0.38, 0.92, float(j) / (forks - 1))
			var origin := _path_at(path, t)
			var lean_side := -1.0 if j % 2 == 0 else 1.0
			var branch_dir := (side * lean_side + outward * 0.48).normalized()
			var length := height * rng.randf_range(0.065, 0.126) * (1.12 if old else 1.0)
			var end := origin + branch_dir * length + Vector3.UP * length * (0.53 if arm == 0 else 0.28)
			var join := origin.lerp(end, 0.50) - Vector3.UP * length * 0.09
			var width := radius * (0.34 - t * 0.13)
			branches.append([[origin, join, end], width, radius * 0.041, bark, false, j > 1, moss * 0.58])
			var spray_size := Vector3(0.105, 0.050, 0.091) * height * rng.randf_range(0.82, 1.15)
			var offset := Vector3.UP * spray_size.y * 0.63
			foliage.append([end + offset, spray_size, atan2(branch_dir.z, branch_dir.x), rng.randf() * TAU])
			foliage.append([join + offset * 1.23 + outward * length * 0.24,
				spray_size * Vector3(0.78, 0.83, 0.73), a + lean_side * 0.67, rng.randf() * TAU])
		foliage.append([tip + Vector3.UP * height * 0.03, Vector3(0.106, 0.061, 0.092) * height, a, rng.randf() * TAU, true])
	return _leafy(branches, foliage, _expedition_colors(Biomes.T_MAPLE), false,
		_ref(Biomes.T_MAPLE, age, height), maple_texture())


## Хвойные. Взрослая сосна — четыре узнаваемых характера (высокий свод, строевая, густая коническая, ветровая)
## с чистым стволом на 40–55 % высоты; молодая — правильный конус с кроной почти до земли; старая — плоская
## раскидистая вершина на немногих толстых сучьях. Снежная ель — прежние силуэты в новом размере.
static func _conifer(kind: int, variant: int) -> Dictionary:
	var snow := kind == Biomes.T_SNOWPINE
	var age := ADULT_AGE if snow else age_of(variant)
	var form := variant if age == ADULT_AGE else variant % AGE_FORMS
	var rng := RandomNumberGenerator.new()
	rng.seed = 6694 + variant * 331 + (19 if snow else 0)
	var branches: Array = []
	var foliage: Array = []
	var height: float
	var radius: float
	var bend_amount: float
	var base: float
	var tiers: int
	var max_span: float
	var pad_y: float      # толщина хвойной лапы
	var lift := Vector2(0.12, 0.42)
	var snags := 0
	if snow:
		height = [7.7, 6.6, 8.5, 7.2][form] * 1.6
		radius = [0.29, 0.27, 0.31, 0.28][form]
		bend_amount = [0.08, 0.16, 0.22, 0.32][form] * 1.4
		base = [0.65, 1.10, 0.50, 1.35][form] * 1.3
		tiers = [8, 7, 9, 8][form]
		max_span = 2.05
		pad_y = 0.80
		lift = Vector2(-0.14, 0.17)
	elif age == YOUNG_AGE:
		height = [6.2, 7.4][form]
		radius = [0.10, 0.12][form]
		bend_amount = [0.06, 0.14][form]
		base = [0.28, 0.45][form]
		tiers = [7, 8][form]
		max_span = [1.30, 1.42][form]
		pad_y = 0.54
		lift = Vector2(0.10, 0.30)
	elif age == OLD_AGE:
		height = [25.0, 23.5][form]
		radius = [0.42, 0.40][form]
		bend_amount = [0.55, 1.10][form]
		base = height * [0.62, 0.58][form]
		snags = 5
	else:
		height = [18.0, 20.5, 17.0, 19.5][form]
		radius = [0.29, 0.30, 0.28, 0.29][form]
		bend_amount = [0.24, 0.42, 0.28, 1.05][form]
		base = height * [0.45, 0.52, 0.41, 0.48][form]
		tiers = [8, 8, 9, 7][form]
		max_span = 2.25
		pad_y = 0.88
		lift = Vector2(0.16, 0.55)
		snags = 3
	var angle := rng.randf() * TAU
	var bend_dir := Vector3(cos(angle), 0, sin(angle))
	var bend := bend_dir * bend_amount
	var sway_dir := Vector3(-bend_dir.z, 0, bend_dir.x) * (0.08 if snow else 0.15) * (0.55 + form * 0.2) * height / 7.5
	var bark := Color("6e5644") if snow else Color("7c5a43")
	var path: Array[Vector3] = []
	var rings := 7 if height > 12.0 else 5
	for i in rings:
		var t := i / float(rings - 1)
		var crook := Vector3.ZERO
		if age == OLD_AGE: # старая сосна: ствол с мягкими коленами
			crook = Vector3(sin(t * 7.0 + form), 0, cos(t * 5.0 + form * 2.0)) * 0.16 * t
		path.append(bend * (0.35 * t + 0.65 * t * t) + sway_dir * sin(t * PI) * t + crook + Vector3(0, t * height, 0))
	branches.append([path, radius, radius * 0.08, bark, false])
	_roots(branches, rng, 4 if age != OLD_AGE else 5, Vector2(radius * 1.3, radius * 1.9), radius * 1.15, radius * 0.18, radius * 0.46, bark)
	# Сухие сучки и обломки ниже кроны: у леса в пологе нижние ветви отмирают.
	for i in snags:
		var y := rng.randf_range(0.16, 0.94) * base
		var a := rng.randf() * TAU + i * 2.399
		var start := _path_at(path, y / height)
		var length := rng.randf_range(0.35, 0.95) * (1.4 if age == OLD_AGE and i < 2 else 1.0)
		var tip := start + Vector3(cos(a), 0, sin(a)) * length + Vector3(0, rng.randf_range(-0.25, 0.08) * length, 0)
		branches.append([[start, tip], 0.07 if age == OLD_AGE and i < 2 else 0.032, 0.012, Color("6a5546"), false, true])
	if age == OLD_AGE:
		_old_pine_crown(branches, foliage, path, height, base, angle, form, rng, bark)
	else:
		for tier in tiers:
			var t := tier / float(tiers)
			var y := base + t * (height - base - 0.22)
			# Естественный конус ярусов: не раздувается у земли и не превращается в голый шпиль наверху.
			var profile := pow(1.0 - t, 0.62 if snow else (0.95 if age == YOUNG_AGE else 0.46)) * (0.96 + 0.14 * sin(t * PI))
			var span := (max_span * profile + (0.14 if age == YOUNG_AGE else 0.24)) * rng.randf_range(0.88, 1.10)
			if not snow and age == ADULT_AGE and form == 3:
				span *= 1.10 if t < 0.35 else 0.94
			var branch_count := 4 if tier < tiers - 2 else 3
			if age == ADULT_AGE and t < 0.45:
				branch_count = 5
			var tier_twist := tier * 2.399
			for j in branch_count:
				var a := j * TAU / branch_count + tier_twist + rng.randf_range(-0.22, 0.22)
				var dir := Vector3(cos(a), 0, sin(a))
				var wind_bias := bend_dir * (0.18 * span if not snow and age == ADULT_AGE and form == 3 else 0.0)
				var start := _path_at(path, (y + rng.randf_range(-0.12, 0.12)) / height)
				var dip := -0.22 * span if snow else ((-0.03 if age == YOUNG_AGE else -0.08) + 0.16 * t) * span
				var tip_lift := rng.randf_range(lift.x, lift.y)
				var elbow := start + dir * span * 0.52 + wind_bias * 0.5 + Vector3(0, dip, 0)
				var end := start + dir * span + wind_bias + Vector3(0, tip_lift, 0)
				var branch_path := [start, elbow, end] if t < 0.28 else [start, end]
				var thick := 0.064 * (1.0 - t * 0.72) + 0.012
				if age == ADULT_AGE or snow:
					thick *= 1.25
				elif age == YOUNG_AGE:
					thick *= 0.6
				if (age != YOUNG_AGE or t < 0.55) and (t < 0.72 or j % 2 == 0):
					branches.append([branch_path, thick, 0.009, bark, false, true])
				var pad_pos := elbow.lerp(end, 0.44) + Vector3(0, 0.08 if snow else 0.14, 0)
				var pad_size := Vector3(span * (0.82 if age == YOUNG_AGE else 0.78), pad_y * (1.0 - t * 0.16), span * 0.64)
				foliage.append([pad_pos, pad_size, a, rng.randf() * 10.0])
				# Длинная лапа взрослого дерева — двумя пучками, а не одной растянутой пластиной.
				if span > 1.75 and not snow and j % 2 == 0:
					foliage.append([start.lerp(elbow, 0.62) + Vector3(0, 0.12, 0), Vector3(span * 0.44, pad_y * 0.84, span * 0.40), a + 0.4, rng.randf() * 10.0])
		# Верхушечная шапка хвои плавно замыкает силуэт.
		var cap := 1.0 if age == YOUNG_AGE else 1.3
		foliage.append([path[-1] - Vector3.UP * 0.14 * cap, Vector3(0.58, 0.76, 0.58) * cap * (0.75 if age == YOUNG_AGE else 1.0), angle, 2.0, true])
	var colors := [Color("568758"), Color("63945d"), Color("4e7d53")]
	if snow:
		colors = [Color("b3c7bd"), Color("a1b6aa"), Color("c3d3ca")]
	return {trunk = _mesh(branches, [], false), crown = _mesh([], foliage, true), bark = Color.WHITE, leaves = colors, colored_bark = true, cutout = true, trunk_texture = _texture(false), crown_texture = _texture(true, true), ref = _ref(kind, age, height)}


## Высота формы в долях номинала породы: у взрослых силуэтов 1 (разница характеров остаётся), у молодых и старых — своя.
static func _ref(kind: int, age: int, height: float) -> float:
	if age == ADULT_AGE or not NOMINAL.has(kind):
		return 1.0
	return height / NOMINAL[kind]


## Старая сосна: немногие толстые сучья несут плоские пучки хвои, вершина плоская и раскидистая.
static func _old_pine_crown(branches: Array, foliage: Array, path: Array[Vector3], height: float, base: float, angle: float, form: int, rng: RandomNumberGenerator, bark: Color) -> void:
	var limbs: int = [9, 8][form]
	for j in limbs:
		var u := j / float(limbs - 1)
		var y := lerpf(base, height * 0.9, u) + rng.randf_range(-0.3, 0.3)
		var a := angle + j * 2.399 + rng.randf_range(-0.3, 0.3)
		var d := Vector3(cos(a), 0, sin(a))
		var start := _path_at(path, y / height)
		var reach := rng.randf_range(2.9, 4.0) * (1.0 - u * 0.45)
		var rise := rng.randf_range(1.0, 1.8) * (1.0 - u * 0.35)
		var end := start + d * reach + Vector3(0, rise, 0)
		end.y = minf(end.y, height - 0.5 - rng.randf() * 0.7)
		var elbow := start + d * reach * 0.42 + Vector3(0, (end.y - start.y) * 0.72, 0)
		branches.append([[start, elbow, end], 0.14 * (1.0 - u * 0.4), 0.05, bark, false])
		# Плоский пучок хвои на конце сука и второй — на середине.
		for c in 4:
			var ca := a + (c - 1.5) * 0.8 + rng.randf_range(-0.2, 0.2)
			var cd := Vector3(cos(ca), 0, sin(ca))
			var spot := end + cd * rng.randf_range(0.55, 1.0) + Vector3(0, rng.randf_range(-0.1, 0.35), 0)
			foliage.append([spot, Vector3(1.85, 0.78, 1.45) * rng.randf_range(0.9, 1.12), ca, rng.randf() * 10.0])
		foliage.append([elbow.lerp(end, 0.45) + Vector3(0, 0.3, 0), Vector3(1.5, 0.7, 1.2), a + 0.5, rng.randf() * 10.0])
	# Плоская верхушка вместо острой шапки.
	foliage.append([path[-1] - Vector3.UP * 0.3, Vector3(2.2, 0.8, 2.2), angle, 2.0, true])


## Та же ломаная ось, что у меша: ветви не отделяются от изогнутого ствола.
static func _path_at(path: Array[Vector3], t: float) -> Vector3:
	var at := clampf(t, 0.0, 1.0) * (path.size() - 1)
	var i := mini(floori(at), path.size() - 2)
	return path[i].lerp(path[i + 1], at - i)


## Берёза поднимается стройным белым стволом сквозь лёгкие ажурные ярусы листвы. Взрослая — чистый ствол
## почти до середины; молодая — хлыст с узкой кроной и восходящими ветвями; старая — длинные поникающие
## ветви и тёмный растрескавшийся комель.
static func _birch(variant: int) -> Dictionary:
	var age := age_of(variant)
	var form := variant if age == ADULT_AGE else variant % AGE_FORMS
	var rng := RandomNumberGenerator.new()
	rng.seed = 7100 + variant * 331 + 97
	var branches: Array = []
	var foliage: Array = []
	var height: float
	var radius: float
	var fork_t: float
	var count: int
	var p: Dictionary # reach — вылет ветвей, rise — подъём конца, droop — провис, pad — размер пучков, hang — плети
	match age:
		YOUNG_AGE:
			height = [5.6, 7.0][form]
			radius = [0.07, 0.085][form]
			fork_t = [0.22, 0.30][form]
			count = [9, 11][form]
			p = {reach = 0.46, rise = 0.55, droop = 0.25, pad = 0.72, hang = false}
		OLD_AGE:
			height = [21.0, 19.5][form]
			radius = [0.31, 0.29][form]
			fork_t = [0.44, 0.40][form]
			count = [15, 13][form]
			p = {reach = 1.55, rise = 0.0, droop = 1.8, pad = 1.4, hang = true}
		_:
			height = [15.5, 16.5, 17.0, 15.0][form]
			radius = [0.19, 0.20, 0.21, 0.19][form]
			fork_t = [0.44, 0.40, 0.50, 0.42][form]
			count = [16, 13, 18, 13][form]
			p = {reach = 1.25, rise = 0.0, droop = 1.5, pad = 1.4, hang = false}
	var bark := Color("e4dfd2")
	var angle := rng.randf() * TAU
	var dir := Vector3(cos(angle), 0, sin(angle))
	var grow := height / 7.5
	var path: Array[Vector3] = []
	var sway := Vector3(-dir.z, 0, dir.x) * 0.14 * sqrt(grow) * (1.0 if form % 2 == 0 else -1.0)
	var rings := 5 if age == YOUNG_AGE else 6
	for i in rings:
		var t := i / float(rings - 1)
		var bend_scale := (0.10 * t + (0.18 + form * 0.09) * t * t) * sqrt(grow)
		path.append(dir * bend_scale + sway * sin(t * PI) + Vector3(0, height * t, 0))
	branches.append([path, radius, 0.024 * sqrt(grow), bark, true])
	_roots(branches, rng, 3, Vector2(radius * 1.25, radius * 1.9), radius * 1.15, radius * 0.16, radius * 0.44, bark)
	if age == OLD_AGE:
		# Тёмный растрескавшийся комель — рубашка поверх ствола, уходящая в него рваной границей.
		var sleeve: Array[Vector3] = []
		for i in 4:
			sleeve.append(_path_at(path, i * 1.0 / height))
		branches.append([sleeve, radius * 1.07, radius * 0.80, Color("57514a"), false])
	var second_leader := age == ADULT_AGE and form in [1, 3]
	_birch_crown(branches, foliage, path, fork_t, count - (4 if second_leader else 0), rng, bark, p)
	if second_leader:
		var start := _path_at(path, fork_t)
		var spread := (1.42 if form == 1 else 1.15) * 1.5
		var side_rot := 1.55 if form == 1 else -1.45
		var end := path[-1] + dir.rotated(Vector3.UP, side_rot) * spread - Vector3.UP * (0.48 if form == 1 else 0.72) * 2.1
		var mid := start.lerp(end, 0.48) + dir.rotated(Vector3.UP, side_rot) * 0.42
		var second: Array[Vector3] = [start, mid, end]
		branches.append([second, radius * 0.68, 0.024, bark, true])
		_birch_crown(branches, foliage, second, 0.24, 8, rng, bark, p)
	return _leafy(branches, foliage, [Color("94b85b"), Color("a3c262"), Color("86ae55")], false, _ref(Biomes.T_BIRCH, age, height))


static func _birch_crown(branches: Array, foliage: Array, path: Array[Vector3], base: float, count: int, rng: RandomNumberGenerator, bark: Color, p: Dictionary) -> void:
	var pad: float = p.pad
	for i in count:
		var t := lerpf(base, 0.94, float(i) / maxi(1, count - 1))
		var u := (t - base) / maxf(0.1, 1.0 - base)
		var origin := _path_at(path, t)
		var a := i * 2.399 + rng.randf_range(-0.22, 0.22)
		var dir := Vector3(cos(a), 0, sin(a))
		# Овально-каплевидный профиль берёзы: раскидистая середина и лёгкая сужающаяся верхушка.
		var envelope := sin(clampf(u * 0.86 + 0.14, 0.18, 0.98) * PI) * 0.88 + (1.0 - u) * 0.32
		var reach := rng.randf_range(1.20, 1.88) * envelope * float(p.reach)
		var elbow := origin + dir * reach * 0.54 + Vector3.UP * (0.34 - u * 0.12) * (1.0 + float(p.rise))
		var droop := rng.randf_range(0.16, 0.48) * (1.0 - u * 0.45) * float(p.droop)
		var tip := origin + dir * reach + Vector3(0, 0.14 - droop + float(p.rise) * reach, 0)
		branches.append([[origin, elbow, tip], 0.044 * (1.0 - u * 0.45) * sqrt(float(p.reach)), 0.007, bark, true, true])
		foliage.append([tip - Vector3.UP * 0.10, Vector3(0.74, 0.68, 0.68) * pad * rng.randf_range(0.9, 1.1), a, rng.randf() * 10.0])
		if i % 2 == 0 or i >= count - 2:
			foliage.append([elbow.lerp(tip, 0.32) + Vector3.UP * 0.14, Vector3(0.84, 0.66, 0.76) * pad, a + 0.5, rng.randf() * 10.0])
		if p.hang and u < 0.82 and i % 2 == 0:
			# Плеть старой берёзы: тонкие ветви свисают завесой ниже конца сука.
			var fall := rng.randf_range(1.3, 2.3) * (1.0 - u * 0.5)
			var low := tip + dir * reach * 0.12 + Vector3(0, -fall, 0)
			branches.append([[tip, low], 0.016, 0.006, bark, false, true])
			foliage.append([tip.lerp(low, 0.55), Vector3(0.68, 1.22, 0.58) * pad * 0.86, a + 0.9, rng.randf() * 10.0])
	foliage.append([path[-1] + Vector3.UP * 0.10, Vector3(0.70, 0.78, 0.68) * pad, rng.randf() * TAU, rng.randf() * 10.0, true])


## Дуб: ступенчатый свод с выраженной вершиной и широкими боковыми плечами. Взрослый — развилка на 40–50 %
## высоты над чистым стволом; молодой — один лидер без развилки и узкая яйцевидная крона; старый — очень
## толстый ствол и широкая низкая крона на мощных почти горизонтальных сучьях.
static func _oak(variant: int) -> Dictionary:
	var age := age_of(variant)
	var form := variant if age == ADULT_AGE else variant % AGE_FORMS
	var rng := RandomNumberGenerator.new()
	rng.seed = 7100 + variant * 331
	var branches: Array = []
	var foliage: Array = []
	var bark := Color("63503d") if age != OLD_AGE else Color("5b4a3a")
	var colors := [Color("7ca94e"), Color("8db555"), Color("709e4b")]
	if age == YOUNG_AGE:
		return _young_oak(form, rng, bark, colors)
	var old := age == OLD_AGE
	var height: float = ([19.0, 18.0] if old else [14.0, 15.5, 13.5, 15.0])[form]
	var radius: float = ([0.86, 0.80] if old else [0.50, 0.47, 0.55, 0.50])[form]
	var fork_t: float = ([0.30, 0.27] if old else [0.42, 0.48, 0.40, 0.45])[form]
	var angle := rng.randf() * TAU
	var dir := Vector3(cos(angle), 0, sin(angle))
	var trunk_top := height * fork_t
	var path: Array[Vector3] = []
	var sway := Vector3(-dir.z, 0, dir.x) * 0.08 * (1.0 if form % 2 == 0 else -1.0) * 2.0
	for i in 5:
		var t := i / 4.0
		var bend_scale := (0.10 * t + (0.18 + form * 0.07) * t * t) * 1.6
		path.append(dir * bend_scale + sway * sin(t * PI) + Vector3(0, trunk_top * t, 0))
	branches.append([path, radius, radius * 0.72, bark, false])
	_roots(branches, rng, 5 if old else 4, Vector2(radius * 1.25, radius * 1.9), radius * 1.15, radius * 0.16, radius * 0.44, bark)
	var count: int = ([5, 6] if old else [4, 4, 5, 4])[form]
	var reach_k := 3.1 if old else 1.65  # вылет главных сучьев
	var sub_k := 1.6 if old else 1.35     # длина боковых ветвей
	var lobe_k := 1.7 if old else 1.4     # размер листовых куполов
	var fork_origin := path[-1]
	for i in count:
		var a := angle + i * TAU / count + rng.randf_range(-0.18, 0.18)
		var outward := Vector3(cos(a), 0, sin(a))
		# Первый лидер образует верхний главный купол, боковые — широкие плечи кроны, плотно смыкающиеся с вершиной.
		var is_apex_leader := i == 0
		var limb_reach := rng.randf_range(0.65, 1.02) * 1.5 if is_apex_leader else rng.randf_range(1.32, 1.85) * reach_k * (1.08 if form == 2 and not old else 1.0)
		var side_y := rng.randf_range(0.56, 0.68) if old else rng.randf_range(0.78, 0.89)
		var end_y := height * ((rng.randf_range(0.84, 0.9) if old else rng.randf_range(0.95, 1.02)) if is_apex_leader else side_y)
		var start := fork_origin
		var end := start + outward * limb_reach + Vector3(0, end_y - start.y, 0)
		var elbow := start.lerp(end, 0.48) + outward * (0.18 if is_apex_leader else 0.36) * 1.5 - Vector3.UP * 0.06
		if old and not is_apex_leader:
			# Мощный сук старого дуба уходит в сторону почти горизонтально и лишь потом поднимается.
			elbow = start + outward * limb_reach * 0.55 + Vector3(0, (end.y - start.y) * 0.3, 0)
		var leader: Array[Vector3] = [start, elbow, end]
		branches.append([leader, radius * (0.62 if is_apex_leader else 0.52), 0.07, bark, false])
		var sub_count := 5 if old else 4
		for j in sub_count:
			var t := 0.22 + j * (0.72 / maxf(1, sub_count - 1))
			var origin := _path_at(leader, t)
			var side_angle := (-0.78 if j % 2 == 0 else 0.78) + rng.randf_range(-0.18, 0.18)
			var reach_dir := outward.rotated(Vector3.UP, side_angle)
			var sub_len := rng.randf_range(0.78, 1.24) * (1.05 - t * 0.22) * sub_k
			var lift := (rng.randf_range(0.28, 0.54) if is_apex_leader else rng.randf_range(0.18, 0.46)) * sub_k
			var tip := origin + reach_dir * sub_len + Vector3(0, lift, 0)
			branches.append([[origin, origin.lerp(tip, 0.82)], 0.10 * (1.0 - t * 0.48), 0.018, bark, false, true])
			var lobe_scale := Vector3(1.34, 0.90, 1.26) * lobe_k * rng.randf_range(0.92, 1.12)
			foliage.append([tip, lobe_scale, a + side_angle * 0.5, rng.randf() * 10.0])
		var cap_scale := (Vector3(1.42, 0.96, 1.36) if is_apex_leader else Vector3(1.28, 0.86, 1.20)) * lobe_k
		foliage.append([end, cap_scale, a, rng.randf() * 10.0, true])
	# Внутренний связующий купол в сердцевине кроны.
	var heart_tip := fork_origin + dir * 0.24 + Vector3(0, (height - fork_origin.y) * (0.5 if old else 0.66), 0)
	foliage.append([heart_tip, Vector3(1.48, 0.96, 1.42) * lobe_k * 1.15, angle + 0.5, rng.randf() * 10.0, true])
	return _leafy(branches, foliage, colors, false, _ref(Biomes.T_OAK, age, height))


## Молодой дуб: один прямой лидер без развилки, восходящие ветви и узкая яйцевидная крона.
static func _young_oak(form: int, rng: RandomNumberGenerator, bark: Color, colors: Array) -> Dictionary:
	var branches: Array = []
	var foliage: Array = []
	var height: float = [5.0, 6.3][form]
	var radius: float = [0.12, 0.14][form]
	var angle := rng.randf() * TAU
	var dir := Vector3(cos(angle), 0, sin(angle))
	var path: Array[Vector3] = []
	for i in 5:
		var t := i / 4.0
		path.append(dir * (0.08 * t + (0.12 + form * 0.08) * t * t) + Vector3(0, height * t, 0))
	branches.append([path, radius, 0.03, bark, false])
	_roots(branches, rng, 3, Vector2(radius * 1.25, radius * 1.8), radius * 1.1, radius * 0.16, radius * 0.42, bark)
	var count: int = [9, 11][form]
	var base := 0.3
	for i in count:
		var t := lerpf(base, 0.9, float(i) / (count - 1))
		var u := (t - base) / (0.9 - base)
		var origin := _path_at(path, t)
		var a := angle + i * 2.399 + rng.randf_range(-0.25, 0.25)
		var d := Vector3(cos(a), 0, sin(a))
		# Яйцо: шире всего в нижней трети кроны, к вершине сужается.
		var envelope := pow(sin(clampf(u * 0.9 + 0.1, 0.0, 1.0) * PI), 0.7) * (1.1 - u * 0.35)
		var reach := rng.randf_range(0.75, 1.15) * envelope + 0.25
		var tip := origin + d * reach + Vector3(0, reach * rng.randf_range(0.45, 0.8), 0)
		branches.append([[origin, origin.lerp(tip, 0.5) + Vector3.UP * 0.06, tip], 0.035, 0.008, bark, false, true])
		foliage.append([tip, Vector3(0.95, 0.72, 0.9) * rng.randf_range(0.88, 1.1), a, rng.randf() * 10.0])
	foliage.append([path[-1] + Vector3.UP * 0.2, Vector3(1.0, 0.95, 0.95), angle, rng.randf() * 10.0, true])
	foliage.append([_path_at(path, 0.62), Vector3(1.05, 1.1, 1.0), angle + 0.5, rng.randf() * 10.0, true])
	return _leafy(branches, foliage, colors, false, _ref(Biomes.T_OAK, YOUNG_AGE, height))


## Рябина (Sorbus aucuparia), 17.11.2026 (вторая версия): изогнутый, часто наклонный ствол (S-изгиб в двух
## плоскостях) и раскидистая округлая крона на 3–4 дугообразных сучьях: сук сначала круто идёт вверх, потом
## уходит в сторону, концы веток слегка поднимаются. Перистая листва — текстурой пластин, гроздья ягод на концах
## веток (LOD0). Взрослые: 0 — раскидистая на развилке, 1 — сильный наклон и однобокая крона, 2 — три изогнутых
## ствола от основания (ваза), 3 — выше развилка, широкий купол. Молодые — тонкий изогнутый ствол и редкие ветви,
## старые — толстый кривой ствол, низкая широкая крона и тяжёлый нижний сук.
static func _rowan(variant: int) -> Dictionary:
	var age := age_of(variant)
	var form := variant if age == ADULT_AGE else variant % AGE_FORMS
	var rng := RandomNumberGenerator.new()
	rng.seed = 7331 + variant * 359
	var bark := Color("6f655a") if age != OLD_AGE else Color("5e554b")
	var colors := [Color("518438"), Color("61933e"), Color("467732")]
	var branches: Array = []
	var foliage: Array = []
	var berries: Array = []
	var angle := rng.randf() * TAU
	var lean_dir := Vector3(cos(angle), 0, sin(angle))
	var height: float
	var radius: float
	if age == YOUNG_AGE:
		height = [4.9, 6.0][form]
		radius = [0.07, 0.085][form]
		var path := _rowan_trunk(Vector3.ZERO, lean_dir, height, 0.35 + form * 0.2, 0.22, form * 1.3, 6)
		branches.append([path, radius, 0.02, bark, false])
		_roots(branches, rng, 3, Vector2(radius * 1.2, radius * 1.7), radius * 1.0, radius * 0.18, radius * 0.42, bark)
		var count := 5 + form * 2
		for b in count:
			var t := lerpf(0.36, 0.86, float(b) / float(count - 1))
			var a := angle + b * 2.399 + rng.randf_range(-0.25, 0.25)
			_rowan_limb(branches, foliage, berries, rng, _path_at(path, t), a, rng.randf_range(0.8, 1.3) * (1.15 - 0.4 * t),
				_path_at(path, t).y + rng.randf_range(0.5, 0.9), 0.03 * (1.1 - t * 0.5), bark, 1, 0.82, 0.35 if form == 1 else 0.0)
		foliage.append([path[-1] + Vector3.UP * 0.18, Vector3(0.86, 0.74, 0.84), angle, rng.randf() * 10.0, true])
		return _leafy(branches, foliage, colors, false, _ref(Biomes.T_ROWAN, age, height), _texture(true, false, true), berries)

	var multi := age == ADULT_AGE and form == 2
	if age == OLD_AGE:
		height = [10.6, 11.4][form]
		radius = [0.21, 0.23][form]
	elif multi:
		height = 9.2
		radius = 0.15
	else:
		height = [9.4, 9.8, 9.0, 10.4][form]
		radius = [0.16, 0.15, 0.14, 0.17][form]
	var stems := 3 if multi else 1
	for st_idx in stems:
		var st_a := angle + (st_idx * 2.2 + rng.randf_range(-0.25, 0.25) if multi else 0.0)
		var st_dir := Vector3(cos(st_a), 0, sin(st_a))
		var st_h: float = height * ([0.96, 0.86, 0.76][st_idx] if multi else 1.0)
		var st_r: float = radius * ([0.88, 0.76, 0.66][st_idx] if multi else 1.0)
		# Высота развилки: у вазы стволы ветвятся выше, у старой — низко и широко
		var fork: float = st_h * (0.50 if multi else (0.30 if age == OLD_AGE else [0.34, 0.30, 0.0, 0.44][form]))
		var bow: float = (0.55 + st_idx * 0.3) if multi else (1.1 if age == OLD_AGE else [0.45, 1.25, 0.0, 0.35][form])
		var wave: float = 0.18 if multi else (0.30 if age == OLD_AGE else [0.22, 0.16, 0.0, 0.26][form])
		var trunk := _rowan_trunk(st_dir * (0.1 if multi and st_idx > 0 else 0.0), st_dir, fork, bow, wave, form * 1.7 + st_idx, 6)
		branches.append([trunk, st_r, st_r * 0.62, bark, false])
		if st_idx == 0:
			_roots(branches, rng, 4 if age == OLD_AGE else 3, Vector2(radius * 1.25, radius * 1.8), radius * 1.05, radius * 0.18, radius * 0.44, bark)
		var top := trunk[-1]
		var limbs := 2 if multi else (4 if age == OLD_AGE or form == 3 else 3)
		for i in limbs:
			# Сучья расходятся веером; у наклонной формы крона уходит в сторону наклона
			var a := st_a + i * TAU / limbs + rng.randf_range(-0.3, 0.3) + (0.0 if form != 1 or age != ADULT_AGE else -0.5)
			var reach: float = rng.randf_range(1.5, 2.2) * (1.18 if age == OLD_AGE else 1.0) * (0.8 if multi else 1.0)
			var top_y: float = st_h * (rng.randf_range(0.86, 0.98) if i == 0 else rng.randf_range(0.70, 0.86)) * (0.92 if age == OLD_AGE else 1.0)
			_rowan_limb(branches, foliage, berries, rng, top, a, reach, top_y, st_r * 0.66, bark,
				2 if multi else 4, 1.22 * (1.1 if age == OLD_AGE else 1.0), 0.45)
		if age == OLD_AGE and st_idx == 0:
			# Тяжёлый нижний сук старой рябины, почти горизонтальный
			var a := angle + 2.6
			_rowan_limb(branches, foliage, berries, rng, _path_at(trunk, 0.8), a, 2.4, top.y + 0.6, st_r * 0.5, bark, 3, 1.15, 0.4)
	return _leafy(branches, foliage, colors, false, _ref(Biomes.T_ROWAN, age, height), _texture(true, false, true), berries)


## Ствол рябины: наклон по dir с дугой (bow, м у вершины) и S-изгиб поперёк (wave, м), rings точек до высоты h
static func _rowan_trunk(base: Vector3, dir: Vector3, h: float, bow: float, wave: float, phase: float, rings: int) -> Array[Vector3]:
	var side := Vector3(-dir.z, 0, dir.x)
	var out: Array[Vector3] = []
	for i in rings:
		var t := i / float(rings - 1)
		out.append(base + dir * bow * (0.35 * t + 0.65 * t * t) + side * sin(t * PI * 1.6 + phase) * wave * t + Vector3(0, h * t, 0))
	return out


## Дугообразный сук рябины от origin в сторону a: сначала круто вверх, затем наружу; вдоль него twigs веток
## (с провисом посередине и приподнятым концом) с перистой листвой, гроздья ягод — с долей berry_k.
static func _rowan_limb(branches: Array, foliage: Array, berries: Array, rng: RandomNumberGenerator, origin: Vector3, a: float,
		reach: float, top_y: float, r0: float, bark: Color, twigs: int, pad: float, berry_k: float) -> void:
	var out := Vector3(cos(a), 0, sin(a))
	var side := Vector3(-out.z, 0, out.x)
	var curl := rng.randf_range(-0.4, 0.4) * reach
	var rise := maxf(0.6, top_y - origin.y)
	var p1 := origin + out * reach * 0.18 + side * curl * 0.2 + Vector3.UP * rise * 0.45
	var p2 := origin + out * reach * 0.60 + side * curl * 0.7 + Vector3.UP * rise * 0.82
	var p3 := origin + out * reach + side * curl + Vector3.UP * rise
	var limb: Array[Vector3] = [origin, p1, p2, p3]
	branches.append([limb, r0, maxf(0.012, r0 * 0.2), bark, false])
	for j in twigs:
		var u := lerpf(0.42, 0.95, float(j) / maxf(1, twigs - 1))
		var orig := _path_at(limb, u)
		var sa := a + (-1.0 if j % 2 == 0 else 1.0) * rng.randf_range(0.7, 1.15)
		var sdir := Vector3(cos(sa), 0, sin(sa))
		var slen := rng.randf_range(0.85, 1.35) * (1.15 - u * 0.35) * pad
		var mid := orig + sdir * slen * 0.5 + Vector3(0, slen * 0.04, 0)
		var tip := orig + sdir * slen + Vector3(0, slen * rng.randf_range(0.22, 0.42), 0)
		branches.append([[orig, mid, tip], r0 * 0.4, 0.008, bark, false, true])
		foliage.append([tip, Vector3(1.0, 0.6, 0.92) * pad * rng.randf_range(0.9, 1.12), sa, rng.randf() * 10.0])
		if j % 2 == 1:
			foliage.append([mid + Vector3.UP * 0.14, Vector3(0.82, 0.5, 0.78) * pad, sa + 0.6, rng.randf() * 10.0])
		if rng.randf() < berry_k:
			berries.append([tip + Vector3(0, -0.17, 0) + sdir * 0.1, rng.randf_range(0.24, 0.32), sa])
	foliage.append([p2 + out * 0.2 + Vector3.UP * 0.18, Vector3(0.95, 0.6, 0.9) * pad, a + 0.4, rng.randf() * 10.0])
	foliage.append([p3 + Vector3.UP * 0.1, Vector3(1.1, 0.7, 1.0) * pad, a, rng.randf() * 10.0, true])
	if rng.randf() < berry_k:
		berries.append([p3 + out * 0.2 - Vector3(0, 0.12, 0), rng.randf_range(0.26, 0.33), a + 0.5])


## Горная сосна (Pinus mugo): низкий многоствольный кустарник/стланик с искривлёнными толстыми
## ветвями и плотной тёмно-зелёной хвоей. Варианты: 0 — компактная подушка, 1 — широкая раскидистая,
## 2 — асимметричная ветровая, 3 — стелющаяся вдоль склона (ширина больше высоты).
static func _mugo(variant: int) -> Dictionary:
	var form := posmod(variant, VARIANTS)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7589 + form * 409
	var bark := Color("564538")
	var colors := [Color("376139"), Color("426e42"), Color("2f5734")]
	var branches: Array = []
	var foliage: Array = []
	var stem_count: int = [4, 5, 5, 6][form]
	var spread_k: float = [1.45, 1.92, 1.80, 2.05][form]
	var height_k: float = [1.85, 2.10, 2.25, 1.38][form]
	var wind_angle := rng.randf() * TAU
	var wind_dir := Vector3(cos(wind_angle), 0, sin(wind_angle))
	for s_idx in stem_count:
		var a: float = wind_angle + (s_idx * TAU / stem_count if form != 2 else lerpf(-1.05, 1.25, float(s_idx) / maxf(1, stem_count - 1)) + (PI if s_idx == 0 else 0.0))
		a += rng.randf_range(-0.22, 0.22)
		var dir := Vector3(cos(a), 0, sin(a))
		var wind_boost := 1.28 if form == 2 and s_idx > 0 else (0.58 if form == 2 and s_idx == 0 else 1.0)
		var reach: float = rng.randf_range(0.78, 1.12) * spread_k * wind_boost
		var top_y: float = rng.randf_range(0.76, 1.06) * height_k * (0.68 if form == 3 else (0.52 if form == 2 and s_idx == 0 else 1.0))
		var p0 := dir * 0.04 + Vector3(0, 0.0, 0)
		var low_y: float = top_y * float([0.28, 0.22, 0.26, 0.14][form])
		var p1: Vector3 = dir * (reach * 0.38) + Vector3(0, low_y, 0)
		var crook := Vector3(-dir.z, 0, dir.x) * rng.randf_range(-0.22, 0.22)
		var p2: Vector3 = dir * (reach * 0.76) + crook + Vector3(0, top_y * float([0.62, 0.50, 0.56, 0.36][form]), 0)
		var p3: Vector3 = dir * reach + crook * 0.6 + Vector3(0, top_y, 0)
		var stem: Array[Vector3] = [p0, p1, p2, p3]
		var r0 := rng.randf_range(0.088, 0.118) * (1.08 if form in [1, 3] else 0.96)
		branches.append([stem, r0, 0.022, bark, false])
		# Боковые побеги расходятся широкой лапой по краю куртины и поднимают хвойные «свечи».
		var shoots := 2 if form == 0 else 3
		for j in shoots:
			var t := 0.38 + j * 0.25
			var orig := _path_at(stem, t)
			var sa: float = a + (-0.68 if j % 2 == 0 else 0.68) + rng.randf_range(-0.18, 0.18)
			var sdir := Vector3(cos(sa), 0, sin(sa))
			var s_len := rng.randf_range(0.55, 0.92) * (1.12 if form in [1, 3] else 0.9)
			var s_end := orig + sdir * s_len + Vector3(0, rng.randf_range(0.22, 0.48) * (0.65 if form == 3 else 1.0), 0)
			branches.append([[orig, s_end], r0 * 0.45, 0.015, bark, false, true])
			var pad_sz := Vector3(0.84, 0.44, 0.78) * rng.randf_range(0.88, 1.12)
			foliage.append([s_end + Vector3(0, 0.08, 0), pad_sz, sa, rng.randf() * 10.0])
		var mid_pos: Vector3 = p1.lerp(p2, 0.55) + Vector3(0, 0.18, 0)
		foliage.append([mid_pos, Vector3(0.90, 0.46, 0.86) * rng.randf_range(0.90, 1.10), a, rng.randf() * 10.0])
		foliage.append([p3 + Vector3(0, 0.10, 0), Vector3(0.92, 0.50, 0.88) * rng.randf_range(0.90, 1.12), a, rng.randf() * 10.0, true])
	# Центральная связующая подушка, чтобы центр куста-стланика не проваливался в пустое кольцо.
	var hub_dir := wind_dir * (0.28 if form == 2 else 0.0)
	foliage.append([hub_dir + Vector3(0, height_k * 0.54, 0), Vector3(1.05, 0.52, 1.00), wind_angle, 1.7, true])
	return {trunk = _mesh(branches, [], false), crown = _mesh([], foliage, true), bark = Color.WHITE, leaves = colors,
		colored_bark = true, cutout = true, trunk_texture = _texture(false), crown_texture = _texture(true, true), ref = 1.0}


static func _leafy(branches: Array, foliage: Array, colors: Array, needles: bool, ref := 1.0, crown_tex: Texture2D = null, berries: Array = []) -> Dictionary:
	var tex: Texture2D = crown_tex if crown_tex != null else _texture(true, needles)
	return {trunk = _mesh(branches, [], false), crown = _mesh([], foliage, false, berries), bark = Color.WHITE, leaves = colors, colored_bark = true, cutout = true, trunk_texture = _texture(false), crown_texture = tex, ref = ref}


## Компактные корневые лапы у самого комля: плавно уходят в землю без торчащих в воздухе распорок.
static func _roots(branches: Array, rng: RandomNumberGenerator, count: int, reach: Vector2, top: float, r0: float, r1: float, bark: Color, curved := false) -> void:
	for i in count:
		var a := i * TAU / count + rng.randf_range(-0.25, 0.25)
		var foot := Vector3(cos(a), 0, sin(a)) * rng.randf_range(reach.x, reach.y)
		if curved:
			var shoulder := foot * 0.18 + Vector3.UP * top
			var path := [foot - Vector3.UP * (0.12 + foot.length() * 0.12),
				foot * 0.51 + Vector3.UP * top * 0.16, foot * 0.32 + Vector3.UP * top * 0.48, shoulder]
			branches.append([path, r0, r1, bark, false, true])
		else:
			branches.append([[foot + Vector3(0, -0.08, 0), Vector3(foot.x * 0.18, top, foot.z * 0.18)], r0, r1, bark, false, true])


## Рамка плоского побега: X вдоль оси, Z — поперёк по горизонтали, Y — лицевая сторона.
static func _frame(along: Vector3) -> Basis:
	var x := along.normalized()
	var z := x.cross(Vector3.UP).normalized()
	return Basis(x, z.cross(x), z)


## Пальма: тонкий изогнутый ствол и розетка длинных поникающих вай.
static func _palm(variant: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 6900 + variant * 331
	var bark := Color("8a6a40")
	var rib := Color("74783e")
	var height: float = [6.5, 8.1, 5.4, 7.2][variant]
	var lean_angle := rng.randf() * TAU
	var lean: Vector3 = Vector3(cos(lean_angle), 0, sin(lean_angle)) * [0.45, 0.9, 1.5, 1.05][variant]
	var wobble := Vector3(-lean.z, 0, lean.x) * 0.12
	var branches: Array = []
	var foliage: Array = []
	var path: Array[Vector3] = []
	for i in 6:
		var t := i / 5.0
		path.append(lean * pow(t, 1.65) + wobble * sin(t * PI * 1.5) + Vector3(0, t * height, 0))
	branches.append([path, 0.24, 0.145, bark, false])
	_roots(branches, rng, 5, Vector2(0.32, 0.48), 0.36, 0.05, 0.12, bark)
	var top := path[-1]
	var axis := (path[-1] - path[-2]).normalized()
	branches.append([[top - axis * 0.12, top + axis * 0.48], 0.18, 0.09, Color("6b7840"), false])
	# Вайи парами: на дальнем LOD пропадают целые листья, а не их концы.
	var count: int = [10, 10, 12, 8][variant]
	var inner: Array = []
	var outer: Array = []
	for k in count:
		var young := k < 2
		var a := k * 2.399 + rng.randf_range(-0.22, 0.22)
		var dir := Vector3(cos(a), 0, sin(a))
		var rise := rng.randf_range(0.78, 1.05) if young else rng.randf_range(-0.08, 0.48)
		var length := rng.randf_range(1.5, 1.9) if young else rng.randf_range(2.5, 3.05)
		var droop := 0.18 if young else rng.randf_range(1.0, 1.48) - rise * 0.55
		var p0 := top + axis * 0.32
		var p1 := p0 + (dir * cos(rise) + Vector3.UP * sin(rise)) * length * 0.52
		var p2 := p1 + dir * length * (0.34 if young else 0.45) + Vector3(0, sin(rise) * length * 0.22 - droop, 0)
		branches.append([[p0, p1, p2], 0.042, 0.01, rib, false, true])
		var width := rng.randf_range(0.52, 0.64) * (0.78 if young else 1.0)
		inner.append([p0.lerp(p1, 0.55), Vector3(p0.distance_to(p1) * 0.54, 0.12, width), a, rng.randf() * 10.0, _frame(p1 - p0), 0.42])
		outer.append([p1.lerp(p2, 0.5), Vector3(p1.distance_to(p2) * 0.58, 0.12, width * 0.78), a, rng.randf() * 10.0, _frame(p2 - p1), 0.48])
	for k in range(0, count, 2):
		foliage.append_array([inner[k], inner[k + 1], outer[k], outer[k + 1]])
	return _leafy(branches, foliage, [Color8(82, 156, 68), Color8(102, 168, 64), Color8(72, 146, 78)], true)


## Тропическое дерево: высокий ствол с досковидными корнями и ярусная многокупольная крона.
static func _jungle(variant: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 6910 + variant * 331
	var bark := Color("5a4026")
	var height := 7.2 * (0.94 + variant * 0.055)
	var radius := 0.39
	var angle := rng.randf() * TAU
	var bend: Vector3 = Vector3(cos(angle), 0, sin(angle)) * [0.22, 0.45, 0.68, 0.90][variant]
	var branches: Array = []
	var foliage: Array = []
	var path: Array[Vector3] = []
	var fork_t: float = [0.48, 0.58, 0.44, 0.64][variant]
	for i in 8:
		var t := i / 7.0
		path.append(bend * (0.4 * t + 0.8 * t * t) + Vector3(sin(t * 4.0) * 0.06, t * height * fork_t, 0))
	branches.append([path, radius, 0.22, bark, false])
	for i in 5:
		var a := i * TAU / 5.0 + rng.randf_range(-0.22, 0.22)
		var dir := Vector3(cos(a), 0, sin(a))
		var reach := rng.randf_range(0.72, 1.08)
		var top_y := rng.randf_range(0.95, 1.32)
		var trunk_anchor := _path_at(path, clampf(top_y / (height * fork_t), 0.0, 0.95))
		branches.append([[dir * reach + Vector3(0, -0.06, 0), trunk_anchor * 0.45 + dir * reach * 0.44 + Vector3(0, top_y * 0.36, 0), trunk_anchor + dir * 0.05], 0.065, 0.18, bark, false, true])
	var leaders := 4 if variant == 2 else 3
	var fork := path[-1]
	for i in leaders:
		var a := angle + i * TAU / leaders + rng.randf_range(-0.16, 0.16)
		var dir := Vector3(cos(a), 0, sin(a))
		var is_top := i == 0
		var end := fork + dir * (rng.randf_range(0.95, 1.45) if is_top else rng.randf_range(1.6, 2.35)) + Vector3(0, height * (rng.randf_range(0.96, 1.06) if is_top else rng.randf_range(0.78, 0.92)) - fork.y, 0)
		var leader: Array[Vector3] = [fork, fork.lerp(end, 0.46) + dir * 0.32, end]
		branches.append([leader, 0.18, 0.045, bark, false])
		for j in 4:
			var t := 0.24 + j * 0.22
			var b := a + (-0.85 if j % 2 == 0 else 0.85)
			var reach := Vector3(cos(b), 0, sin(b))
			var start := _path_at(leader, t)
			var tip := start + reach * rng.randf_range(0.75, 1.45) + Vector3.UP * 0.28
			branches.append([[start, tip], 0.068, 0.012, bark, false, true])
			foliage.append([tip, Vector3(1.28, 0.66, 1.16), b, rng.randf() * 10.0])
		foliage.append([end, Vector3(1.38, 0.78, 1.24), a, rng.randf() * 10.0, true])
	foliage.append([fork + Vector3(0, (height - fork.y) * 0.72, 0), Vector3(1.42, 0.78, 1.32), angle, rng.randf() * 10.0, true])
	return _leafy(branches, foliage, [Color8(50, 126, 56), Color8(64, 138, 52), Color8(44, 116, 64)], false)


## Акация: развилка у земли, восходящие ветви и плоский широкий зонтик.
static func _acacia(variant: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 6920 + variant * 331
	var bark := Color("6b4a2b")
	var height: float = [3.9, 4.6, 3.4, 4.3][variant]
	var fork_height: float = [0.95, 1.85, 1.2, 1.5][variant]
	var lean := Vector3(rng.randf_range(-0.22, 0.22), 0, rng.randf_range(-0.22, 0.22))
	var branches: Array = []
	var foliage: Array = []
	var path: Array[Vector3] = []
	for i in 4:
		var t := i / 3.0
		path.append(lean * t + Vector3(0, t * fork_height, 0))
	branches.append([path, 0.22, 0.15, bark, false])
	_roots(branches, rng, 4, Vector2(0.35, 0.52), 0.34, 0.05, 0.12, bark)
	var fork := path[3]
	var limbs := 3 if variant != 1 else 4
	for i in limbs:
		var a := i * TAU / limbs + rng.randf_range(-0.35, 0.35)
		var dir := Vector3(cos(a), 0, sin(a))
		var end := fork + dir * rng.randf_range(0.85, 1.32) + Vector3(0, height - 0.58 - fork.y - rng.randf_range(0.0, 0.22), 0)
		branches.append([[fork, fork.lerp(end, 0.5) + dir * 0.16, end], 0.13, 0.068, bark, false])
		for side: float in [-1.0, 1.0]:
			var sdir := dir.rotated(Vector3.UP, side * rng.randf_range(0.42, 0.72))
			var tip := end + sdir * rng.randf_range(0.58, 0.88) + Vector3(0, rng.randf_range(0.14, 0.28), 0)
			branches.append([[end, tip], 0.068, 0.032, bark, false, true])
			foliage.append([tip + Vector3(0, 0.14, 0), Vector3(1.02, 0.46, 0.88) * rng.randf_range(0.92, 1.1), a, rng.randf() * 10.0, Basis(Vector3.UP, -a), 0.24])
			for twig: float in [-0.5, 0.5]:
				var tdir := sdir.rotated(Vector3.UP, twig + rng.randf_range(-0.18, 0.18))
				var leaf := tip + tdir * rng.randf_range(0.42, 0.72) + Vector3(0, 0.08, 0)
				branches.append([[tip, leaf], 0.028, 0.008, bark, false, true])
				var tilt := Basis(tdir.cross(Vector3.UP).normalized(), rng.randf_range(0.04, 0.11))
				foliage.append([leaf + Vector3(0, 0.06, 0), Vector3(0.92, 0.40, 0.78) * rng.randf_range(0.88, 1.1), a, rng.randf() * 10.0, tilt * Basis(Vector3.UP, -a - twig), 0.24])
	return _leafy(branches, foliage, [Color8(134, 160, 70), Color8(150, 166, 76), Color8(122, 152, 68)], false)


## Куст: несимметричная группа из нескольких арочных куполов разной высоты вместо круглого шара.
static func _bush(variant: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 6940 + variant * 331
	var bark := Color("65503b")
	var branches: Array = []
	var foliage: Array = []
	var stems := 4 + (variant % 2)
	for i in stems:
		var a := i * TAU / stems + rng.randf_range(-0.35, 0.35)
		var dir := Vector3(cos(a), 0, sin(a))
		var reach := rng.randf_range(0.42, 0.72) * (1.15 if i == 0 else 0.92)
		var h := rng.randf_range(0.52, 0.95) * (1.12 if i == 1 else 0.95)
		var mid := dir * reach * 0.45 + Vector3(0, h * 0.52, 0)
		var end := dir * reach + Vector3(0, h, 0)
		branches.append([[dir * 0.04, mid, end], 0.034, 0.010, bark, false, i > 0])
		foliage.append([end + Vector3(0, 0.06, 0), Vector3(0.68, 0.46, 0.62) * rng.randf_range(0.9, 1.14), a, rng.randf() * 10.0, i < 2])
		var side_a := a + (0.65 if i % 2 == 0 else -0.65)
		var side_p := mid.lerp(end, 0.65) + Vector3(cos(side_a), -0.08, sin(side_a)) * rng.randf_range(0.22, 0.36)
		foliage.append([side_p, Vector3(0.58, 0.42, 0.54) * rng.randf_range(0.88, 1.12), side_a, rng.randf() * 10.0])
	return _leafy(branches, foliage, [Color("78a54a"), Color("8ab052"), Color("6c9948")], false)


## Сухое дерево: голый кривой ствол с обломанной вершиной и сучьями. Кроны нет.
static func _dead(variant: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 6930 + variant * 331
	var bark := Color("6e6052")
	var height := 3.6 * (0.94 + variant * 0.06)
	var branches: Array = []
	var path: Array[Vector3] = []
	var drift := Vector3.ZERO
	for i in 6:
		var t := i / 5.0
		if i > 0:
			drift += Vector3(rng.randf_range(-0.14, 0.14), 0, rng.randf_range(-0.14, 0.14))
		path.append(drift + Vector3(0, t * height, 0))
	branches.append([path, 0.21, 0.055, bark, false])
	_roots(branches, rng, 4, Vector2(0.32, 0.52), 0.32, 0.055, 0.12, bark)
	for i in 5 + variant:
		var t := rng.randf_range(0.32, 0.88)
		var at := t * 5.0
		var start := path[int(at)].lerp(path[mini(int(at) + 1, 5)], at - int(at))
		var a := i * 2.399 + rng.randf_range(-0.4, 0.4)
		var dir := Vector3(cos(a), 0, sin(a))
		var length := rng.randf_range(0.55, 1.55) * (1.0 - t * 0.35)
		var lift := -0.25 if i % 3 == 2 else rng.randf_range(0.28, 0.58)
		var kink := start + dir * length * 0.5 + Vector3(0, length * lift * 0.6, 0)
		var turn := dir.rotated(Vector3.UP, rng.randf_range(-0.7, 0.7))
		var end := kink + turn * length * 0.5 + Vector3(0, length * lift, 0)
		branches.append([[start, kink, end], 0.08 * (1.0 - t * 0.35), 0.022, bark, false])
		if i % 2 == 0:
			var twig := kink + turn.rotated(Vector3.UP, 1.2) * 0.35 + Vector3(0, 0.22, 0)
			branches.append([[kink, twig], 0.03, 0.01, bark, false, true])
	return {trunk = _mesh(branches, [], false), bark = Color.WHITE, colored_bark = true, trunk_texture = _texture(false)}


## Общие текстуры 128x128: фактурная кора и мягкие стилизованные букеты листьев / хвои
## с естественными просветами между листовыми группами и плавным объёмным градиентом.
static func _texture(leaves: bool, needles: bool = false, pinnate: bool = false) -> Texture2D:
	if not baking:
		var idx := 5 if pinnate else (2 if needles else (1 if leaves else 0))
		return preload("res://scripts/render/asset_catalog.gd").get_catalog().textures[idx]
	var cached := _pinnate_texture if pinnate else (_needle_texture if needles else (_leaf_texture if leaves else _bark_texture))
	if cached != null:
		return cached
	var image := Image.create(128, 128, false, Image.FORMAT_RGBA8)
	for y in 128:
		for x in 128:
			var grain := WGRandom.hash2(x, y, 65)
			if leaves:
				var base_val := 0.77 + grain * 0.10
				image.set_pixel(x, y, Color(base_val, base_val, base_val, 0.0))
			else:
				var ridge := sin(x * 0.75 + sin(y * TAU / 128.0) * 1.8) * 0.075 + sin(x * 2.1 + y * 0.15) * 0.035
				var bark_val := clampf(0.84 + ridge + grain * 0.05, 0.65, 1.0)
				image.set_pixel(x, y, Color(bark_val, bark_val * 0.99, bark_val * 0.96, 1.0))
	if pinnate:
		# Сложный непарноперистый лист рябины: несколько веточек-черешков с узкими парными листочками и ажурными просветами.
		var rng := RandomNumberGenerator.new()
		rng.seed = 673
		for branch_idx in 9:
			var ba := branch_idx * TAU / 9.0 + rng.randf_range(-0.22, 0.22)
			var base := Vector2(64, 64) + Vector2(cos(ba + 2.4), sin(ba + 2.4)) * rng.randf_range(4.0, 22.0)
			var bdir := Vector2(cos(ba), sin(ba))
			var bperp := Vector2(-bdir.y, bdir.x)
			var rachis_len := rng.randf_range(26.0, 36.0)
			var layer_shade := lerpf(0.76, 0.96, branch_idx / 8.0)
			# Листочки: 4 пары боковых + непарный верхушечный
			for step in 5:
				var u := 0.22 + step * 0.18
				var hub := (base + bdir * (rachis_len * u) - Vector2(64, 64)).limit_length(46.0) + Vector2(64, 64)
				var sides := [0.0] if step == 4 else [-1.0, 1.0]
				for s_sign: float in sides:
					var la := ba + s_sign * (0.95 - step * 0.08) + rng.randf_range(-0.14, 0.14)
					var ldir := Vector2(cos(la), sin(la))
					var length := 9.2 if step == 4 else rng.randf_range(7.2, 9.6) * (1.05 - step * 0.08)
					var width := length * 0.34
					var c := hub + ldir * (length * 0.65)
					var bound := ceili(length) + 1
					for dy in range(-bound, bound + 1):
						for dx in range(-bound, bound + 1):
							var px := posmod(int(c.x) + dx, 128)
							var py := posmod(int(c.y) + dy, 128)
							var p := Vector2(dx, dy).rotated(-la)
							if absf(p.x) / length + pow(absf(p.y) / width, 1.45) > 1.0:
								continue
							var shade := layer_shade * (0.86 + 0.16 * (1.0 - absf(p.y) / width))
							if absf(p.y) < 0.45:
								shade *= 0.85
							shade = clampf(shade, 0.64, 1.0)
							image.set_pixel(px, py, Color(shade, shade, shade * 0.96, 1.0))
			# Черешок по оси ветки
			for rstep in 24:
				var rp := (base + bdir * (rachis_len * float(rstep) / 23.0) - Vector2(64, 64)).limit_length(48.0) + Vector2(64, 64)
				for w: int in [-1, 0]:
					var q: Vector2 = rp + bperp * (w * 0.5)
					image.set_pixel(posmod(int(q.x), 128), posmod(int(q.y), 128), Color(0.72, 0.72, 0.66, 1.0))
	elif leaves:
		var rng := RandomNumberGenerator.new()
		rng.seed = 651
		# Семейство мягких под-куполов (букетов) внутри карточки: создаёт живой кружевной контур
		# с естественными воздушными просветами, не превращая карточку в гигантский одиночный лист.
		var lobes := 7
		var lobe_centers: Array[Vector2] = [Vector2(64, 64)]
		for l in range(1, lobes):
			var la := (l - 1) * TAU / (lobes - 1) + (0.28 if l % 2 == 0 else -0.18)
			var lr := 21.0 + (l % 3) * 4.5
			lobe_centers.append(Vector2(64, 64) + Vector2(cos(la), sin(la)) * lr)
		var count := 250 if needles else 190
		for i in count:
			var t := float(i) / float(count - 1)
			var lobe_idx := i % lobes
			var lobe := lobe_centers[lobe_idx]
			var a := rng.randf() * TAU
			var spread := (19.0 if lobe_idx == 0 else 17.5) * sqrt(rng.randf())
			var center := (lobe + Vector2(cos(a), sin(a)) * spread - Vector2(64, 64)).limit_length(50.0) + Vector2(64, 64)
			var out_dir := center - lobe
			var out_angle := out_dir.angle() if out_dir.length_squared() > 2.0 else a
			var angle := (out_angle - PI * 0.5 + rng.randf_range(-0.65, 0.65)) if needles else rng.randf() * TAU
			var length := rng.randf_range(5.5, 10.5) if needles else rng.randf_range(5.5, 10.0)
			var width := length * (0.17 if needles else 0.62)
			var radial_norm := clampf((center - Vector2(64, 64)).length() / 50.0, 0.0, 1.0)
			var layer_shade := lerpf(0.76, 0.97, t * 0.6 + radial_norm * 0.4)
			var bound := ceili(length) + 1
			for dy in range(-bound, bound + 1):
				for dx in range(-bound, bound + 1):
					var px := posmod(int(center.x) + dx, 128)
					var py := posmod(int(center.y) + dy, 128)
					var p := Vector2(dx, dy).rotated(angle)
					if absf(p.y) / length + pow(absf(p.x) / width, 1.55) > 1.0:
						continue
					var shade := layer_shade * (0.86 + 0.16 * (1.0 - absf(p.x) / width) + (0.04 if p.y < 0 else -0.03))
					if absf(p.x) < 0.42:
						shade *= 0.88
					shade = clampf(shade, 0.64, 1.0)
					image.set_pixel(px, py, Color(shade, shade, shade * 0.97, 1.0))
	image.generate_mipmaps()
	cached = ImageTexture.create_from_image(image)
	if pinnate:
		_pinnate_texture = cached
	elif needles:
		_needle_texture = cached
	elif leaves:
		_leaf_texture = cached
	else:
		_bark_texture = cached
	return cached


## Один атлас групп пятилопастных листьев для всех форм и уровней клёна.
static func maple_texture() -> Texture2D:
	if not baking:
		return preload("res://scripts/render/asset_catalog.gd").get_catalog().textures[MAPLE_TEXTURE]
	if _maple_leaf_texture != null:
		return _maple_leaf_texture
	var outline := PackedVector2Array([
		Vector2(0, 0.68), Vector2(-0.24, 0.49), Vector2(-0.65, 0.54), Vector2(-0.79, 0.27),
		Vector2(-0.58, 0.15), Vector2(-0.91, -0.01), Vector2(-1.03, -0.44), Vector2(-0.62, -0.39),
		Vector2(-0.38, -0.22), Vector2(-0.45, -0.52), Vector2(-0.20, -0.68), Vector2(0, -1.0),
		Vector2(0.22, -0.70), Vector2(0.41, -0.50), Vector2(0.36, -0.21), Vector2(0.63, -0.40),
		Vector2(0.99, -0.46), Vector2(0.82, -0.03), Vector2(0.56, 0.18), Vector2(0.78, 0.28),
		Vector2(0.61, 0.51), Vector2(0.22, 0.48)])
	var image := Image.create(128, 128, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.84, 0.84, 0.81, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 71143
	for leaf in 48:
		var theta := float(leaf % 7) * TAU / 7.0
		var orbit := 26.0 + (leaf % 4) * 3.0
		var center := Vector2(64, 64) + Vector2.from_angle(theta) * orbit
		center += Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(1.0, 18.0)
		if leaf % 7 == 0:
			center = Vector2(64, 64).lerp(center, 0.32)
		var angle := rng.randf() * TAU
		var size := rng.randf_range(11.3, 17.3)
		var radius := ceili(size * 1.08)
		var tone := rng.randf_range(0.69, 0.93)
		for y in range(maxi(0, floori(center.y) - radius), mini(128, ceili(center.y) + radius)):
			for x in range(maxi(0, floori(center.x) - radius), mini(128, ceili(center.x) + radius)):
				var p := (Vector2(x + 0.5, y + 0.5) - center).rotated(angle) / size
				if not Geometry2D.is_point_in_polygon(p, outline):
					continue
				var vein := (Vector2(0, 0.53) - p).angle()
				var rib := pow(absf(cos((vein + PI * 0.5) * 5.0)), 17.0)
				var shade := clampf(tone + 0.10 * rib - 0.10 * p.y + 0.045 * WGRandom.hash2(x, y, 931), 0.63, 1.0)
				image.set_pixel(x, y, Color(shade, shade, shade * 0.97, 1.0))
	image.generate_mipmaps()
	_maple_leaf_texture = ImageTexture.create_from_image(image)
	return _maple_leaf_texture


## Явные LOD для растворения в VegetationLayer. Каждый уровень хранится только один раз.
## Ближний меш владеет двумя дальними, обратных ссылок и циклов ресурсов нет.
static func _mesh(branches: Array, foliage: Array, conifer: bool, berries: Array = [], crown_lods: Array = []) -> ArrayMesh:
	var levels: Array[Mesh] = []
	var crown := [Vector3.ZERO, Vector3.ONE]
	if not foliage.is_empty():
		var center := Vector3.ZERO
		for spray: Array in foliage:
			center += spray[0]
		center /= foliage.size()
		var extent := Vector3.ONE * 0.5
		for spray: Array in foliage:
			extent = extent.max((spray[0] - center).abs() + Vector3.ONE * 0.4)
		crown = [center, extent]
	for level in 3:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var vertex_count := 0
		for branch: Array in branches:
			var is_minor: bool = branch.size() > 5 and branch[5]
			var is_root: bool = is_minor and branch[2] > branch[1]
			if level == 2 and ((is_minor and branch != branches[0]) or (branch[1] < 0.13 and branch != branches[0])):
				continue
			if level == 1 and (is_root or (is_minor and branch[1] < 0.095 and branch != branches[0]) or (branch[1] < 0.085 and branch != branches[0])):
				continue
			var segments: int = ([7, 4, 3] if branch[1] > 0.4 else [6, 4, 3])[level] if branch == branches[0] else (([5, 3, 3] if branch[1] > 0.16 else [4, 3, 3])[level] if not is_minor else 3)
			vertex_count += _tube(st, branch, segments, level, vertex_count)
		var lod_foliage := foliage
		var flat_planes := 2
		if level > 0:
			if not crown_lods.is_empty():
				lod_foliage = crown_lods[level - 1]
				flat_planes = 1
			else:
				lod_foliage = _far_foliage(foliage, conifer)
				if level == 2:
					lod_foliage = _far_foliage(lod_foliage, conifer, true)
		for spray: Array in lod_foliage:
			_spray(st, spray, level, conifer, crown, flat_planes)
		if level == 0 and not berries.is_empty():
			for berry: Array in berries:
				_berry_cluster(st, berry[0], berry[1], berry[2], crown)
		st.index()
		levels.append(st.commit())
	var mesh: ArrayMesh = levels[0]
	mesh.set_meta("lod_meshes", [levels[1], levels[2]])
	return mesh


## Гроздь ягод рябины (только LOD0): пара перекрещённых карточек с UV.x + 2.0 для выреза в шейдере.
static func _berry_cluster(st: SurfaceTool, center: Vector3, radius: float, rot: float, crown: Array) -> void:
	var uv := [Vector2(2.0, 1.0), Vector2(3.0, 1.0), Vector2(3.0, 0.0), Vector2(2.0, 0.0)]
	for turn in 2:
		var a := rot + turn * PI * 0.5
		var side := Vector3(cos(a), 0, sin(a)) * radius
		var across := Vector3(-sin(a), 0, cos(a))
		var up := (Vector3.UP * 0.92 + across * (0.38 if turn == 0 else -0.34)).normalized() * radius
		var pts := [center - side - up, center + side - up, center + side + up, center - side + up]
		var min_y := minf(minf(pts[0].y, pts[1].y), minf(pts[2].y, pts[3].y))
		if min_y < 0.05:
			for k in 4:
				pts[k] += Vector3(0.0, 0.05 - min_y, 0.0)
		for idx: int in [0, 1, 2, 0, 2, 3]:
			st.set_uv(uv[idx])
			var lit := _crown_light(pts[idx], crown)
			var col := Color(maxf(0.84, lit[1].r), maxf(0.84, lit[1].g), maxf(0.84, lit[1].b), 1.0)
			_vertex(st, pts[idx], (lit[0] * 0.65 + Vector3.UP * 0.35).normalized(), col)


static func lod_meshes(mesh: Mesh) -> Array[Mesh]:
	var result: Array[Mesh] = [mesh]
	if mesh.has_meta("levels"):
		result.assign(mesh.get_meta("levels"))
	else:
		result.append_array(mesh.get_meta("lod_meshes", []))
	return result


## Дальняя крона объединяет ближайшие объёмы с сохранением радиальной ориентации лап.
static func _far_foliage(foliage: Array, conifer: bool = false, merge_caps: bool = false) -> Array:
	var result: Array = []
	var used := PackedByteArray()
	used.resize(foliage.size())
	for i in foliage.size():
		if used[i]:
			continue
		var spray: Array = foliage[i]
		used[i] = 1
		var spray_is_cap: bool = spray.size() > 4 and spray[4] is bool and spray[4]
		if spray.size() > 4:
			if spray[4] is Basis:
				if i % 2 == 0 or foliage.size() <= 4:
					var wide: Array = spray.duplicate()
					wide[1] = spray[1] * Vector3(1.16, 1.0, 1.16)
					result.append(wide)
				continue
			if spray_is_cap and not merge_caps:
				result.append(spray)
				continue
		var nearest := -1
		var distance := INF
		for j in range(i + 1, foliage.size()):
			if used[j] or (foliage[j].size() > 4 and (foliage[j][4] is Basis or not merge_caps)):
				continue
			var delta: Vector3 = spray[0] - foliage[j][0]
			var d: float = delta.x * delta.x + delta.z * delta.z + delta.y * delta.y * (4.5 if conifer else 1.4)
			if d < distance:
				distance = d
				nearest = j
		if nearest < 0:
			result.append(spray)
			continue
		used[nearest] = 1
		var other: Array = foliage[nearest]
		var other_is_cap: bool = other.size() > 4 and other[4] is bool and other[4]
		var center: Vector3 = (spray[0] + other[0]) * 0.5
		var sep: Vector3 = (spray[0] - center).abs()
		var span_xz := Vector2(sep.x, sep.z).length()
		var base_size: Vector3 = spray[1].max(other[1])
		var extent := Vector3(
			base_size.x + span_xz * (0.42 if conifer else 0.58),
			base_size.y + sep.y * (0.38 if conifer else 0.55),
			base_size.z + span_xz * (0.48 if conifer else 0.58)
		)
		var out_angle: float = atan2(center.z, center.x) if Vector2(center.x, center.z).length_squared() > 0.02 else float(spray[2])
		if spray_is_cap or other_is_cap:
			result.append([center, extent, out_angle, spray[3], true])
		else:
			result.append([center, extent, out_angle, spray[3]])
	return result


static func _vertex(st: SurfaceTool, p: Vector3, normal: Vector3, color: Color) -> void:
	st.set_normal(normal)
	st.set_color(color)
	st.add_vertex(p)


static func _tube(st: SurfaceTool, data: Array, segments: int, level: int, first: int) -> int:
	var path: Array = data[0]
	if level > 0 and data.size() > 5 and data[5]:
		path = [path[0], path[-1]]
	elif level == 1 and path.size() > 4:
		var mid_path: Array = []
		for i in range(0, path.size(), 2):
			mid_path.append(path[i])
		if (path.size() - 1) % 2 != 0:
			mid_path.append(path[-1])
		path = mid_path
	elif level == 2 and first > 0 and path.size() > 2 and data.size() <= 6:
		path = [path[0], path[-1]]
	elif level == 2 and path.size() > 3:
		path = [path[0], path[path.size() / 2], path[-1]]
	for ring in path.size():
		var direction: Vector3 = (path[mini(ring + 1, path.size() - 1)] - path[maxi(ring - 1, 0)]).normalized()
		var reference := Vector3.RIGHT if absf(direction.dot(Vector3.FORWARD)) > 0.95 else Vector3.FORWARD
		var side := direction.cross(reference).normalized()
		var front := side.cross(direction).normalized()
		var t := ring / float(path.size() - 1)
		var radius: float = lerpf(data[1], data[2], t)
		if ring == 0 and path.size() > 3:
			radius *= 1.34
		for j in segments + 1:
			var a := j * TAU / segments
			var normal := side * cos(a) + front * sin(a)
			var flute := 0.12 * sin(a * 4.0 + ring) if ring == 0 and path.size() > 3 else 0.07 * sin(a * 3.0 + ring)
			var p: Vector3 = path[ring] + normal * radius * (1.0 + flute)
			var color: Color = data[3] * (0.86 + 0.14 * sin(a * 3.0 + ring * 0.8))
			if data[4]:
				if ring == 0 and path.size() > 3:
					color = Color("524d45")
				elif sin(p.y * 19.0 + (j % segments) * 4.3) > 0.68:
					color = Color("4d4942")
			if data.size() > 6 and float(data[6]) > 0.0:
				var patch := smoothstep(-0.45, 0.8, sin(p.y * 1.48 + p.x * 1.21) * cos(p.z * 1.8 - a * 2.0))
				var low := 1.0 - smoothstep(0.15, 3.1, p.y)
				var shoulder := smoothstep(0.1, 0.82, normal.y)
				var cover := float(data[6]) * patch * maxf(low, shoulder)
				color = color.lerp(Color("435a32"), cover)
			color.a = 1.0
			# Кора толстого ствола повторяется по окружности чаще, чтобы рисунок не растягивался.
			st.set_uv(Vector2(a / TAU * maxf(2.0, roundf(TAU * data[1] / 1.4)), p.y * 0.65))
			_vertex(st, p, normal, color)
	for k in path.size() - 1:
		for j in segments:
			var a := first + k * (segments + 1) + j
			var b := a + segments + 1
			for index: int in [a, a + 1, b + 1, a, b + 1, b]:
				st.add_index(index)
	return path.size() * (segments + 1)


## Нормаль и яркость точки листвы по эллипсоиду кроны crown = [центр, полуоси]:
## мягкое затенение снизу и в глубине кроны, тёплый свет на верхних куполах.
static func _crown_light(p: Vector3, crown: Array) -> Array:
	var d: Vector3 = (p - crown[0]) / crown[1]
	var normal := (d + Vector3.UP * 0.58).normalized() if d.length() > 0.05 else Vector3.UP
	var shell := clampf(d.length(), 0.0, 1.0)
	var height_t := clampf(d.y * 0.5 + 0.55, 0.0, 1.0)
	var shade := clampf(lerpf(0.72, 0.98, shell) * lerpf(0.86, 1.10, height_t), 0.64, 1.12)
	return [normal, Color(shade, shade, shade, 1)]


static func _spray(st: SurfaceTool, data: Array, level: int, conifer: bool, crown: Array, flat_planes: int) -> void:
	var center: Vector3 = data[0]
	var size: Vector3 = data[1]
	var rotation := Basis(Vector3.UP, data[2])
	var phase: float = data[3]
	var is_apex: bool = data.size() > 4 and data[4] is bool and data[4]
	var planes := 3 if (level == 0 and is_apex) else 2
	if data.size() > 4 and data[4] is Basis:
		_flat_spray(st, data, flat_planes, crown)
		return
	var uv := [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]
	if conifer and not is_apex:
		var radial := Vector3(cos(data[2]), 0, sin(data[2]))
		var tangent := Vector3(-radial.z, 0, radial.x)
		var conifer_k := 1.12 if level == 2 else 1.0
		for i in planes:
			var side: Vector3
			var up: Vector3
			var w: float
			var h: float
			if i == 0:
				# Горизонтальная веерная плоскость лапы: создаёт широкие ярусы и зубчатый контур.
				side = (tangent * 0.94 + radial * 0.22).normalized()
				up = (radial * 0.92 - Vector3.UP * 0.28 + tangent * 0.16).normalized()
				w = maxf(size.x, size.z) * 1.16 * conifer_k
				h = size.x * 1.08 * conifer_k
			else:
				# Продольно-вертикальная плоскость лапы вдоль ветви без диагонального перекрещивания ствола.
				side = (radial * 0.95 - Vector3.UP * 0.22).normalized()
				up = (Vector3.UP * 0.92 + tangent * 0.34).normalized()
				w = size.x * 1.14 * conifer_k
				h = minf(size.y, size.x * 0.72) * 1.08 * conifer_k
			var c := center + Vector3(0, (i - 0.5) * size.y * 0.14, 0)
			var points := [c - side * w - up * h, c + side * w - up * h, c + side * w + up * h, c - side * w + up * h]
			var min_py := minf(minf(points[0].y, points[1].y), minf(points[2].y, points[3].y))
			if min_py < 0.0:
				for pi in 4:
					points[pi] += Vector3(0.0, -min_py, 0.0)
			for index in [0, 1, 2, 0, 2, 3]:
				st.set_uv(uv[index])
				var lit := _crown_light(points[index], crown)
				var tip_boost := lerpf(0.92, 1.06, 1.0 - uv[index].y)
				var shade := (0.94 + 0.08 * (0.5 + 0.5 * sin(phase * 2.1))) * tip_boost
				var color: Color = lit[1] * shade
				color.a = 1.0
				var local: Vector3 = (points[index] - center) / size
				var lobe_normal := (local + Vector3.UP * 0.65 + radial * 0.35).normalized()
				_vertex(st, points[index], (lit[0] * 0.65 + lobe_normal * 0.35).normalized(), color)
		return
	var step := PI / float(planes)
	for i in planes:
		var a := phase + i * step + sin(phase + i * 1.9) * 0.12
		var axis := rotation * Vector3(cos(a), 0, sin(a))
		var tilt_dir := rotation * Vector3(-sin(a), 0, cos(a))
		var up := (Vector3.UP * 0.84 + tilt_dir * (0.52 if i % 2 == 0 else -0.46)).normalized()
		var side := up.cross(axis).normalized()
		var c := center + Vector3(0, (i - (planes - 1) * 0.5) * size.y * 0.22, 0)
		var spread_k := 1.12 if level == 2 else (1.05 if level == 0 and planes == 2 else 1.0)
		var w := sqrt(pow(cos(a) * size.x, 2.0) + pow(sin(a) * size.z, 2.0)) * 1.16 * spread_k
		var h := size.y * 1.18 * spread_k
		var points := [c - side * w - up * h, c + side * w - up * h, c + side * w + up * h, c - side * w + up * h]
		var min_py := minf(minf(points[0].y, points[1].y), minf(points[2].y, points[3].y))
		if min_py < 0.0:
			for pi in 4:
				points[pi] += Vector3(0.0, -min_py, 0.0)
		for index in [0, 1, 2, 0, 2, 3]:
			st.set_uv(uv[index])
			var lit := _crown_light(points[index], crown)
			var lobe_grad := lerpf(0.92, 1.06, 1.0 - uv[index].y)
			var shade := (0.94 + 0.09 * (0.5 + 0.5 * sin(phase * 2.1))) * lobe_grad
			var color: Color = lit[1] * shade
			color.a = 1.0
			var local: Vector3 = (points[index] - center) / size
			var lobe_normal := (local + Vector3.UP * 0.68).normalized()
			_vertex(st, points[index], (lit[0] * 0.68 + lobe_normal * 0.32).normalized(), color)


## Побег в собственной рамке data[4]: плоскости вдоль оси X, сложенные веером
## вокруг неё на угол data[5]. Так строятся вайи пальмы и плоский зонтик акации.
static func _flat_spray(st: SurfaceTool, data: Array, planes: int, crown: Array) -> void:
	var center: Vector3 = data[0]
	var size: Vector3 = data[1]
	var phase: float = data[3]
	var frame: Basis = data[4]
	var fold: float = data[5] if data.size() > 5 else 0.4
	var uv := [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]
	for i in planes:
		var k := i - (planes - 1) * 0.5
		var b := frame * Basis(Vector3.RIGHT, k * fold + sin(phase + i * 1.7) * fold * 0.3)
		var x := b.x * size.x * 1.12
		var z := b.z * size.z * 1.12
		var c := center + frame.y * k * size.y * 0.25
		var points := [c - x - z, c + x - z, c + x + z, c - x + z]
		var min_py := minf(minf(points[0].y, points[1].y), minf(points[2].y, points[3].y))
		if min_py < 0.0:
			for pi in 4:
				points[pi] += Vector3(0.0, -min_py, 0.0)
		var normal := b.y if b.y.y >= 0.0 else -b.y
		normal = (normal * 0.6 + Vector3.UP * 0.4).normalized()
		for index in [0, 1, 2, 0, 2, 3]:
			st.set_uv(uv[index])
			var lit := _crown_light(points[index], crown)
			_vertex(st, points[index], (normal + lit[0]).normalized(), lit[1])
