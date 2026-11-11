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
const NOMINAL := {Biomes.T_PINE: 19.0, Biomes.T_BIRCH: 16.0, Biomes.T_OAK: 14.5, Biomes.T_SNOWPINE: 12.0}
static var _leaf_texture: Texture2D
static var _bark_texture: Texture2D
static var _needle_texture: Texture2D
static var baking := false # authoring tool only


## Есть ли у вида молодые и старые формы.
static func has_ages(kind: int) -> bool:
	return kind == Biomes.T_PINE or kind == Biomes.T_BIRCH or kind == Biomes.T_OAK


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
	return _conifer(kind, variant)


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
		tiers = [10, 9, 11, 10][form]
		max_span = 2.05
		pad_y = 0.72
		lift = Vector2(-0.14, 0.17)
	elif age == YOUNG_AGE:
		height = [6.2, 7.4][form]
		radius = [0.10, 0.12][form]
		bend_amount = [0.06, 0.14][form]
		base = [0.28, 0.45][form]
		tiers = [9, 10][form]
		max_span = [1.30, 1.42][form]
		pad_y = 0.46
		lift = Vector2(0.10, 0.30)
	elif age == OLD_AGE:
		height = [25.0, 23.5][form]
		radius = [0.42, 0.40][form]
		bend_amount = [0.55, 1.10][form]
		base = height * [0.62, 0.58][form]
		snags = 7
	else:
		height = [18.0, 20.5, 17.0, 19.5][form]
		radius = [0.29, 0.30, 0.28, 0.29][form]
		bend_amount = [0.24, 0.42, 0.28, 1.05][form]
		base = height * [0.45, 0.52, 0.41, 0.48][form]
		tiers = [10, 10, 11, 8][form]
		max_span = 2.25
		pad_y = 0.80
		lift = Vector2(0.16, 0.55)
		snags = 4
	var angle := rng.randf() * TAU
	var bend_dir := Vector3(cos(angle), 0, sin(angle))
	var bend := bend_dir * bend_amount
	var sway_dir := Vector3(-bend_dir.z, 0, bend_dir.x) * (0.08 if snow else 0.15) * (0.55 + form * 0.2) * height / 7.5
	var bark := Color("6e5644") if snow else Color("7c5a43")
	var path: Array[Vector3] = []
	var rings := 9 if height > 12.0 else 7
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
				var branch_path := [start, elbow, end] if t < 0.4 else [start, end]
				var thick := 0.064 * (1.0 - t * 0.72) + 0.012
				if age == ADULT_AGE or snow:
					thick *= 1.25
				elif age == YOUNG_AGE:
					thick *= 0.6
				branches.append([branch_path, thick, 0.009, bark, false, true])
				var pad_pos := elbow.lerp(end, 0.50) + Vector3(0, 0.08 if snow else 0.14, 0)
				var pad_size := Vector3(span * (0.78 if age == YOUNG_AGE else 0.72), pad_y * (1.0 - t * 0.18), span * 0.58)
				foliage.append([pad_pos, pad_size, a, rng.randf() * 10.0])
				# Длинная лапа взрослого дерева — двумя пучками, а не одной растянутой пластиной.
				if span > 1.55 and not snow:
					foliage.append([start.lerp(elbow, 0.62) + Vector3(0, 0.12, 0), Vector3(span * 0.42, pad_y * 0.8, span * 0.38), a + 0.4, rng.randf() * 10.0])
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
	var rings := 5 if age == YOUNG_AGE else 7
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
		if i % 2 == 0 or i >= count - 2 or pad > 1.0:
			foliage.append([elbow.lerp(tip, 0.32) + Vector3.UP * 0.14, Vector3(0.78, 0.62, 0.72) * pad, a + 0.5, rng.randf() * 10.0])
		if p.hang and u < 0.85:
			# Плеть старой берёзы: тонкие ветви свисают завесой ниже конца сука.
			var fall := rng.randf_range(1.3, 2.3) * (1.0 - u * 0.5)
			var low := tip + dir * reach * 0.12 + Vector3(0, -fall, 0)
			branches.append([[tip, low], 0.016, 0.006, bark, false, true])
			foliage.append([tip.lerp(low, 0.5), Vector3(0.62, 0.95, 0.52) * pad * 0.8, a + 0.9, rng.randf() * 10.0])
			foliage.append([low + Vector3.UP * 0.1, Vector3(0.58, 0.82, 0.5) * pad * 0.75, a - 0.6, rng.randf() * 10.0])
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
		var sub_count := 7 if old else 6
		for j in sub_count:
			var t := 0.22 + j * (0.72 / maxf(1, sub_count - 1))
			var origin := _path_at(leader, t)
			var side_angle := (-0.78 if j % 2 == 0 else 0.78) + rng.randf_range(-0.18, 0.18)
			var reach_dir := outward.rotated(Vector3.UP, side_angle)
			var sub_len := rng.randf_range(0.78, 1.24) * (1.05 - t * 0.22) * sub_k
			var lift := (rng.randf_range(0.28, 0.54) if is_apex_leader else rng.randf_range(0.18, 0.46)) * sub_k
			var tip := origin + reach_dir * sub_len + Vector3(0, lift, 0)
			branches.append([[origin, origin.lerp(tip, 0.52) + Vector3.UP * 0.2, tip], 0.10 * (1.0 - t * 0.48), 0.016, bark, false, true])
			var lobe_scale := Vector3(1.24, 0.84, 1.16) * lobe_k * rng.randf_range(0.90, 1.12)
			foliage.append([tip, lobe_scale, a + side_angle * 0.5, rng.randf() * 10.0])
		var cap_scale := (Vector3(1.42, 0.96, 1.36) if is_apex_leader else Vector3(1.28, 0.86, 1.20)) * lobe_k
		foliage.append([end, cap_scale, a, rng.randf() * 10.0, true])
	# Внутренний связующий купол в сердцевине кроны.
	var heart_tip := fork_origin + dir * 0.24 + Vector3(0, (height - fork_origin.y) * (0.5 if old else 0.66), 0)
	branches.append([[fork_origin, heart_tip], radius * 0.40, 0.04, bark, false, true])
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


static func _leafy(branches: Array, foliage: Array, colors: Array, needles: bool, ref := 1.0) -> Dictionary:
	return {trunk = _mesh(branches, [], false), crown = _mesh([], foliage, false), bark = Color.WHITE, leaves = colors, colored_bark = true, cutout = true, trunk_texture = _texture(false), crown_texture = _texture(true, needles), ref = ref}


## Компактные корневые лапы у самого комля: плавно уходят в землю без торчащих в воздухе распорок.
static func _roots(branches: Array, rng: RandomNumberGenerator, count: int, reach: Vector2, top: float, r0: float, r1: float, bark: Color) -> void:
	for i in count:
		var a := i * TAU / count + rng.randf_range(-0.25, 0.25)
		var foot := Vector3(cos(a), 0, sin(a)) * rng.randf_range(reach.x, reach.y)
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
static func _texture(leaves: bool, needles: bool = false) -> Texture2D:
	if not baking:
		return preload("res://scripts/render/asset_catalog.gd").get_catalog().textures[2 if needles else (1 if leaves else 0)]
	var cached := _needle_texture if needles else (_leaf_texture if leaves else _bark_texture)
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
	if leaves:
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
	if needles:
		_needle_texture = cached
	elif leaves:
		_leaf_texture = cached
	else:
		_bark_texture = cached
	return cached


## Явные LOD для растворения в VegetationLayer. Каждый уровень хранится только один раз.
## Ближний меш владеет двумя дальними, обратных ссылок и циклов ресурсов нет.
static func _mesh(branches: Array, foliage: Array, conifer: bool) -> ArrayMesh:
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
			if level == 2 and branch[1] < 0.11 and branch != branches[0]:
				continue
			if level == 1 and branch[1] < 0.085 and branch != branches[0]:
				continue
			var segments: int = ([8, 5, 3] if branch[1] > 0.4 else [6, 4, 3])[level] if branch[1] > 0.12 else 3
			vertex_count += _tube(st, branch, segments, level, vertex_count)
		for spray: Array in (_far_foliage(_far_foliage(foliage, conifer), conifer) if level == 2 else (_far_foliage(foliage, conifer) if level == 1 else foliage)):
			_spray(st, spray, level, conifer, crown)
		st.index()
		levels.append(st.commit())
	var mesh: ArrayMesh = levels[0]
	mesh.set_meta("lod_meshes", [levels[1], levels[2]])
	return mesh


static func lod_meshes(mesh: Mesh) -> Array[Mesh]:
	var result: Array[Mesh] = [mesh]
	if mesh.has_meta("levels"):
		result.assign(mesh.get_meta("levels"))
	else:
		result.append_array(mesh.get_meta("lod_meshes", []))
	return result


## Дальняя крона объединяет ближайшие объёмы с сохранением радиальной ориентации лап.
static func _far_foliage(foliage: Array, conifer: bool = false) -> Array:
	var result: Array = []
	var used := PackedByteArray()
	used.resize(foliage.size())
	for i in foliage.size():
		if used[i]:
			continue
		var spray: Array = foliage[i]
		used[i] = 1
		if spray.size() > 4:
			if spray[4] is Basis:
				if i % 2 == 0:
					result.append(spray)
				continue
			if spray[4] is bool and spray[4]:
				result.append(spray)
				continue
		var nearest := -1
		var distance := INF
		for j in range(i + 1, foliage.size()):
			if used[j] or foliage[j].size() > 4:
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
	if level == 2 and path.size() > 4:
		var coarse: Array = []
		for i in range(0, path.size(), 2):
			coarse.append(path[i])
		if (path.size() - 1) % 2 != 0:
			coarse.append(path[-1])
		path = coarse
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


static func _spray(st: SurfaceTool, data: Array, level: int, conifer: bool, crown: Array) -> void:
	var center: Vector3 = data[0]
	var size: Vector3 = data[1]
	var rotation := Basis(Vector3.UP, data[2])
	var phase: float = data[3]
	var is_apex: bool = data.size() > 4 and data[4] is bool and data[4]
	var planes := (3 if is_apex else 2) if conifer else (3 if level == 0 else 2)
	if data.size() > 4 and data[4] is Basis:
		_flat_spray(st, data, 3 if level == 0 else 2, crown)
		return
	var uv := [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]
	if conifer and not is_apex:
		var radial := Vector3(cos(data[2]), 0, sin(data[2]))
		var tangent := Vector3(-radial.z, 0, radial.x)
		for i in planes:
			var side: Vector3
			var up: Vector3
			var w: float
			var h: float
			if i == 0:
				# Горизонтальная веерная плоскость лапы: создаёт широкие ярусы и зубчатый контур.
				side = (tangent * 0.94 + radial * 0.22).normalized()
				up = (radial * 0.92 - Vector3.UP * 0.28 + tangent * 0.16).normalized()
				w = maxf(size.x, size.z) * 1.16
				h = size.x * 1.08
			else:
				# Продольно-вертикальная плоскость лапы вдоль ветви без диагонального перекрещивания ствола.
				side = (radial * 0.95 - Vector3.UP * 0.22).normalized()
				up = (Vector3.UP * 0.92 + tangent * 0.34).normalized()
				w = size.x * 1.14
				h = minf(size.y, size.x * 0.72) * 1.08
			var c := center + Vector3(0, (i - 0.5) * size.y * 0.14, 0)
			var points := [c - side * w - up * h, c + side * w - up * h, c + side * w + up * h, c - side * w + up * h]
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
		var w := sqrt(pow(cos(a) * size.x, 2.0) + pow(sin(a) * size.z, 2.0)) * 1.16
		var h := size.y * 1.18
		var points := [c - side * w - up * h, c + side * w - up * h, c + side * w + up * h, c - side * w + up * h]
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
		var normal := b.y if b.y.y >= 0.0 else -b.y
		normal = (normal * 0.6 + Vector3.UP * 0.4).normalized()
		for index in [0, 1, 2, 0, 2, 3]:
			st.set_uv(uv[index])
			var lit := _crown_light(points[index], crown)
			_vertex(st, points[index], (normal + lit[0]).normalized(), lit[1])
