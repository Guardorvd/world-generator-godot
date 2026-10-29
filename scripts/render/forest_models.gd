class_name ForestModels
extends RefCounted
## Художественные модели умеренного леса. Общие меши, без узлов на каждую ветку.
## Заранее построенные силуэты; RNG локальный, генерацию мира не затрагивает.

const VARIANTS := 4
const MODEL_STRIDE := 256
static var _leaf_texture: Texture2D
static var _bark_texture: Texture2D
static var _needle_texture: Texture2D
static var baking := false # authoring tool only


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
	var birch := kind == Biomes.T_BIRCH
	var conifer := kind == Biomes.T_PINE or kind == Biomes.T_SNOWPINE
	if not conifer:
		return _deciduous(variant, birch)
	var rng := RandomNumberGenerator.new()
	rng.seed = 6694 + variant * 331
	var branches: Array = []
	var foliage: Array = []
	var snow := kind == Biomes.T_SNOWPINE
	var height: float = ([7.6, 6.5, 8.4, 7.1] if snow else [7.2, 8.6, 6.8, 8.0])[variant]
	var radius := 0.23
	# Основание остаётся около коллизии; выше появляется индивидуальный изгиб.
	var angle := rng.randf() * TAU
	var bend_dir := Vector3(cos(angle), 0, sin(angle))
	var bend_amount: float = [0.10, 0.22, 0.38, 0.52][variant]
	var bend := bend_dir * bend_amount
	var sway_dir := Vector3(-bend_dir.z, 0, bend_dir.x) * 0.18 * (0.5 + variant * 0.22)
	var bark := Color("78604b")
	# Непрерывный сужающийся ствол, раструб у земли и неровные корневые лапы.
	var path: Array[Vector3] = []
	for i in 7:
		var t := i / 6.0
		path.append(bend * (0.4 * t + 0.8 * t * t) + sway_dir * sin(t * PI) * t + Vector3(0, t * height, 0))
	branches.append([path, radius, radius * 0.07, bark, false])
	var root_count := 5
	for i in root_count:
		var a := i * TAU / root_count + rng.randf()
		var foot := Vector3(cos(a), 0, sin(a)) * radius * rng.randf_range(2.4, 3.8)
		branches.append([[foot + Vector3(0, -0.04, 0), Vector3(0, radius * 1.9, 0)], radius * 0.22, radius * 0.65, bark, false])
	# Не конусы: отдельные неравные лапы с просветами и приподнятыми концами.
	var base: float = ([0.65, 1.15, 0.45, 1.8] if snow else [2.4, 4.3, 1.35, 3.5])[variant]
	var tiers := 8 if snow else 6
	for tier in tiers:
		var t := tier / float(tiers)
		var y := base + t * (height - base - 0.15)
		var span := (2.1 * pow(1.0 - t, 0.9 if snow else 0.45) + 0.12) * rng.randf_range(0.85, 1.1)
		var branch_count := 4 if tier < tiers - 2 else 3
		for j in branch_count:
			var a := j * TAU / branch_count + tier * 2.399 + rng.randf_range(-0.25, 0.25)
			var dir := Vector3(cos(a), 0, sin(a))
			var start := _path_at(path, (y + rng.randf_range(-0.18, 0.18)) / height)
			var elbow := start + dir * span * 0.48 + Vector3(0, -0.22 if snow else 0.12, 0)
			var end := start + dir * span + Vector3(0, rng.randf_range(-0.08, 0.35) if snow else rng.randf_range(0.2, 0.65), 0)
			var branch_path := [start, elbow, end] if tier < 3 else [start, end]
			branches.append([branch_path, 0.065 * (1.0 - t) + 0.012, 0.009, bark, false, true])
			foliage.append([elbow.lerp(end, 0.48) + Vector3(0, 0.14, 0), Vector3(span * 0.70, 0.58 if snow else 0.65, span * 0.40), -a, rng.randf() * 10.0])
	# Живой верх закрывает тонкий конец центральной оси и не выглядит обломанным.
	foliage.append([path[-1] - Vector3.UP * 0.18, Vector3(0.48, 0.7, 0.45), angle, 2.0, true])
	var colors := [Color("5e8d60"), Color("6a9962"), Color("57855c")]
	if kind == Biomes.T_SNOWPINE:
		colors = [Color("b3c7bd"), Color("a1b6aa"), Color("c3d3ca")]
	return {trunk = _mesh(branches, [], false), crown = _mesh([], foliage, conifer), bark = Color.WHITE, leaves = colors, colored_bark = true, cutout = true, trunk_texture = _texture(false), crown_texture = _texture(true, conifer)}


## Та же ломаная ось, что у меша: ветви не отделяются от изогнутого ствола.
static func _path_at(path: Array[Vector3], t: float) -> Vector3:
	var at := clampf(t, 0.0, 1.0) * (path.size() - 1)
	var i := mini(floori(at), path.size() - 2)
	return path[i].lerp(path[i + 1], at - i)


## Дубы растут от несущей развилки, берёзы — от одного или двух тонких лидеров.
## Крона следует настоящим концам ветвей, а не заполняет общий шар вокруг прямой оси.
static func _deciduous(variant: int, birch: bool) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7100 + variant * 331 + (97 if birch else 0)
	var branches: Array = []
	var foliage: Array = []
	var height: float = ([7.4, 6.8, 8.2, 7.0] if birch else [5.8, 7.0, 5.2, 6.6])[variant]
	var radius: float = (0.14 if birch else 0.32) * (1.15 if variant == 2 else 1.0)
	var bark := Color("d5d0bd") if birch else Color("655441")
	var angle := rng.randf() * TAU
	var dir := Vector3(cos(angle), 0, sin(angle))
	var fork_t: float = ([0.4, 0.28, 0.57, 0.36] if birch else [0.28, 0.48, 0.22, 0.38])[variant]
	var trunk_top := height if birch else height * fork_t
	var path: Array[Vector3] = []
	for i in 5:
		var t := i / 4.0
		path.append(dir * (0.12 * t + (0.25 + variant * 0.12) * t * t) + Vector3(0, trunk_top * t, 0))
	branches.append([path, radius, 0.022 if birch else radius * 0.72, bark, birch])
	_roots(branches, rng, 3 if birch else 4, Vector2(radius * 1.6, radius * 3.0), radius * 1.7, radius * 0.18, radius * 0.6, bark)
	if birch:
		_birch_crown(branches, foliage, path, fork_t, 9 if variant in [1, 3] else 11, rng, bark)
		if variant in [1, 3]:
			var start := _path_at(path, fork_t)
			var end := path[-1] + dir.rotated(Vector3.UP, 1.4) * (1.4 if variant == 1 else 1.0) - Vector3.UP * 0.6
			var second: Array[Vector3] = [start, start.lerp(end, 0.45) + dir * 0.2, end]
			branches.append([second, radius * 0.68, 0.018, bark, true])
			_birch_crown(branches, foliage, second, 0.22, 7, rng, bark)
	else:
		var count: int = [3, 2, 4, 3][variant]
		for i in count:
			var a := angle + i * TAU / count + rng.randf_range(-0.22, 0.22)
			var outward := Vector3(cos(a), 0, sin(a))
			var start := path[-1]
			var end := start + outward * rng.randf_range(1.35, 2.2) + Vector3(0, height * rng.randf_range(0.85, 1.05) - start.y, 0)
			var elbow := start.lerp(end, 0.48) + outward * 0.35
			var leader: Array[Vector3] = [start, elbow, end]
			branches.append([leader, radius * 0.68, 0.055, bark, false])
			for j in 5:
				var t := 0.22 + j * 0.17
				var origin := _path_at(leader, t)
				var reach := outward.rotated(Vector3.UP, (-0.9 if j % 2 == 0 else 0.9) + rng.randf_range(-0.25, 0.25))
				var tip := origin + reach * rng.randf_range(0.75, 1.35) + Vector3(0, rng.randf_range(0.3, 0.65), 0)
				branches.append([[origin, origin.lerp(tip, 0.55) + Vector3.UP * 0.18, tip], 0.09 * (1.0 - t * 0.5), 0.012, bark, false, true])
				foliage.append([tip, Vector3(1.15, 0.8, 1.0) * rng.randf_range(0.85, 1.1), a + j, rng.randf() * 10.0])
			# Верх каждого лидера имеет свой купол; развилки остаются видимыми снизу.
			foliage.append([end, Vector3(1.1, 0.85, 1.0), a, rng.randf() * 10.0, true])
	var colors := [Color("94b85e"), Color("a2bf63"), Color("88ae5a")] if birch else [Color("80ad52"), Color("90b657"), Color("74a350")]
	return _leafy(branches, foliage, colors, false)


static func _birch_crown(branches: Array, foliage: Array, path: Array[Vector3], base: float, count: int, rng: RandomNumberGenerator, bark: Color) -> void:
	for i in count:
		var t := lerpf(base, 0.96, float(i) / (count - 1))
		var origin := _path_at(path, t)
		var a := i * 2.399 + rng.randf_range(-0.25, 0.25)
		var dir := Vector3(cos(a), 0, sin(a))
		var reach := rng.randf_range(1.0, 1.8) * (1.0 - t * 0.45)
		var elbow := origin + dir * reach * 0.55 + Vector3.UP * 0.28
		var tip := origin + dir * reach + Vector3(0, -rng.randf_range(0.15, 0.5), 0)
		branches.append([[origin, elbow, tip], 0.045 * (1.0 - t * 0.4), 0.006, bark, true, true])
		# Пары соседних побегов: дальний уровень оставляет один укрупнённый объём.
		foliage.append([tip - Vector3.UP * 0.18, Vector3(0.5, 0.85, 0.48), a + 0.7, rng.randf() * 10.0])
		foliage.append([elbow, Vector3(0.66, 0.65, 0.6), a, rng.randf() * 10.0])


static func _leafy(branches: Array, foliage: Array, colors: Array, needles: bool) -> Dictionary:
	return {trunk = _mesh(branches, [], false), crown = _mesh([], foliage, false), bark = Color.WHITE, leaves = colors, colored_bark = true, cutout = true, trunk_texture = _texture(false), crown_texture = _texture(true, needles)}


## Корневые лапы вокруг основания: короткие трубки от земли к стволу.
static func _roots(branches: Array, rng: RandomNumberGenerator, count: int, reach: Vector2, top: float, r0: float, r1: float, bark: Color) -> void:
	for i in count:
		var a := i * TAU / count + rng.randf_range(0.0, 0.9)
		var foot := Vector3(cos(a), 0, sin(a)) * rng.randf_range(reach.x, reach.y)
		branches.append([[foot + Vector3(0, -0.04, 0), Vector3(0, top, 0)], r0, r1, bark, false])


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
	var rib := Color("77733f")
	var height: float = [6.4, 8.0, 5.3, 7.1][variant]
	var lean_angle := rng.randf() * TAU
	var lean: Vector3 = Vector3(cos(lean_angle), 0, sin(lean_angle)) * [0.4, 0.85, 1.45, 1.0][variant]
	var wobble := Vector3(-lean.z, 0, lean.x) * 0.12
	var branches: Array = []
	var foliage: Array = []
	var path: Array[Vector3] = []
	for i in 6:
		var t := i / 5.0
		path.append(lean * pow(t, 1.7) + wobble * sin(t * PI * 1.5) + Vector3(0, t * height, 0))
	branches.append([path, 0.25, 0.15, bark, false])
	_roots(branches, rng, 6, Vector2(0.38, 0.55), 0.42, 0.05, 0.13, bark)
	var top := path[-1]
	var axis := (path[-1] - path[-2]).normalized()
	branches.append([[top - axis * 0.1, top + axis * 0.45], 0.17, 0.08, Color("6f7a42"), false])
	# Вайи парами: на дальнем LOD пропадают целые листья, а не их концы.
	var count: int = [10, 10, 12, 8][variant]
	var inner: Array = []
	var outer: Array = []
	for k in count:
		var young := k < 2
		var a := k * 2.399 + rng.randf_range(-0.25, 0.25)
		var dir := Vector3(cos(a), 0, sin(a))
		var rise := rng.randf_range(0.85, 1.1) if young else rng.randf_range(-0.1, 0.5)
		var length := rng.randf_range(1.4, 1.8) if young else rng.randf_range(2.4, 2.95)
		var droop := 0.15 if young else rng.randf_range(0.95, 1.4) - rise * 0.6
		var p0 := top + axis * 0.3
		var p1 := p0 + (dir * cos(rise) + Vector3.UP * sin(rise)) * length * 0.5
		var p2 := p1 + dir * length * (0.3 if young else 0.42) + Vector3(0, sin(rise) * length * 0.25 - droop, 0)
		branches.append([[p0, p1, p2], 0.04, 0.01, rib, false])
		var width := rng.randf_range(0.46, 0.56) * (0.75 if young else 1.0)
		inner.append([p0.lerp(p1, 0.55), Vector3(p0.distance_to(p1) * 0.5, 0.1, width), a, rng.randf() * 10.0, _frame(p1 - p0), 0.38])
		outer.append([p1.lerp(p2, 0.5), Vector3(p1.distance_to(p2) * 0.55, 0.1, width * 0.72), a, rng.randf() * 10.0, _frame(p2 - p1), 0.45])
	for k in range(0, count, 2):
		foliage.append_array([inner[k], inner[k + 1], outer[k], outer[k + 1]])
	return _leafy(branches, foliage, [Color8(84, 158, 70), Color8(104, 168, 66), Color8(74, 148, 80)], true)


## Тропическое дерево: высокий ствол с досковидными корнями и ярусная неровная крона.
static func _jungle(variant: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 6910 + variant * 331
	var bark := Color("5a4026")
	var height := 7.1 * (0.95 + variant * 0.05)
	var radius := 0.4
	var angle := rng.randf() * TAU
	var bend: Vector3 = Vector3(cos(angle), 0, sin(angle)) * [0.2, 0.45, 0.7, 0.95][variant]
	var branches: Array = []
	var foliage: Array = []
	var path: Array[Vector3] = []
	var fork_t: float = [0.46, 0.60, 0.42, 0.70][variant]
	for i in 8:
		var t := i / 7.0
		path.append(bend * (0.4 * t + 0.8 * t * t) + Vector3(sin(t * 4.0) * 0.06, t * height * fork_t, 0))
	branches.append([path, radius, 0.23, bark, false])
	# Досковидные корни: длинные, низкие, поднимаются по стволу.
	for i in 6:
		var a := i * TAU / 6.0 + rng.randf_range(-0.3, 0.3)
		var dir := Vector3(cos(a), 0, sin(a))
		var reach := rng.randf_range(1.3, 1.9)
		branches.append([[dir * reach + Vector3(0, -0.05, 0), dir * reach * 0.45 + Vector3(0, 0.5, 0), dir * 0.2 + Vector3(0, rng.randf_range(1.5, 2.0), 0)], 0.07, 0.2, bark, false])
	# Несущие ветви выходят из одной развилки; крона разбита на несколько куполов.
	var leaders := 4 if variant == 2 else 3
	for i in leaders:
		var a := angle + i * TAU / leaders
		var dir := Vector3(cos(a), 0, sin(a))
		var fork := path[-1]
		var end := fork + dir * rng.randf_range(1.4, 2.2) + Vector3(0, height * rng.randf_range(0.9, 1.08) - fork.y, 0)
		var leader: Array[Vector3] = [fork, fork.lerp(end, 0.45) + dir * 0.3, end]
		branches.append([leader, 0.19, 0.045, bark, false])
		for j in 4:
			var t := 0.24 + j * 0.22
			var b := a + (-0.9 if j % 2 == 0 else 0.9)
			var reach := Vector3(cos(b), 0, sin(b))
			var start := _path_at(leader, t)
			var tip := start + reach * rng.randf_range(0.7, 1.4) + Vector3.UP * 0.3
			branches.append([[start, tip], 0.07, 0.012, bark, false, true])
			foliage.append([tip, Vector3(1.25, 0.65, 1.1), b, rng.randf() * 10.0])
		foliage.append([end, Vector3(1.3, 0.75, 1.15), a, rng.randf() * 10.0, true])
	return _leafy(branches, foliage, [Color8(52, 128, 58), Color8(66, 140, 54), Color8(46, 118, 66)], false)


## Акация: развилка у земли, восходящие ветви и плоский широкий зонтик.
static func _acacia(variant: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 6920 + variant * 331
	var bark := Color("6b4a2b")
	var height: float = [3.8, 4.5, 3.3, 4.2][variant]
	var fork_height: float = [0.9, 1.9, 1.25, 1.55][variant]
	var lean := Vector3(rng.randf_range(-0.2, 0.2), 0, rng.randf_range(-0.2, 0.2))
	var branches: Array = []
	var foliage: Array = []
	var path: Array[Vector3] = []
	for i in 4:
		var t := i / 3.0
		path.append(lean * t + Vector3(0, t * fork_height, 0))
	branches.append([path, 0.22, 0.15, bark, false])
	_roots(branches, rng, 4, Vector2(0.4, 0.6), 0.38, 0.05, 0.13, bark)
	var fork := path[3]
	var limbs := 3 if variant != 1 else 4
	for i in limbs:
		var a := i * TAU / limbs + rng.randf_range(-0.4, 0.4)
		var dir := Vector3(cos(a), 0, sin(a))
		var end := fork + dir * rng.randf_range(0.8, 1.25) + Vector3(0, height - 0.6 - fork.y - rng.randf_range(0.0, 0.25), 0)
		branches.append([[fork, fork.lerp(end, 0.5) + dir * 0.15, end], 0.13, 0.07, bark, false])
		for side: float in [-1.0, 1.0]:
			var sdir := dir.rotated(Vector3.UP, side * rng.randf_range(0.45, 0.75))
			var tip := end + sdir * rng.randf_range(0.55, 0.85) + Vector3(0, rng.randf_range(0.15, 0.3), 0)
			branches.append([[end, tip], 0.07, 0.035, bark, false])
			foliage.append([tip + Vector3(0, 0.14, 0), Vector3(0.95, 0.5, 0.8) * rng.randf_range(0.9, 1.1), a, rng.randf() * 10.0, Basis(Vector3.UP, -a), 0.25])
			for twig: float in [-0.5, 0.5]:
				var tdir := sdir.rotated(Vector3.UP, twig + rng.randf_range(-0.2, 0.2))
				var leaf := tip + tdir * rng.randf_range(0.4, 0.7) + Vector3(0, 0.08, 0)
				branches.append([[tip, leaf], 0.03, 0.008, bark, false])
				var tilt := Basis(tdir.cross(Vector3.UP).normalized(), rng.randf_range(0.04, 0.12))
				foliage.append([leaf + Vector3(0, 0.06, 0), Vector3(0.85, 0.42, 0.7) * rng.randf_range(0.85, 1.1), a, rng.randf() * 10.0, tilt * Basis(Vector3.UP, -a - twig), 0.25])
	return _leafy(branches, foliage, [Color8(134, 160, 70), Color8(150, 166, 76), Color8(122, 152, 68)], false)


## 9.4: куст вместо двух шаров: несколько стеблей от земли и купол из побегов с вырезанными листьями.
static func _bush(variant: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 6940 + variant * 331
	var bark := Color("6a5640")
	var branches: Array = []
	var foliage: Array = []
	for i in 5:
		var a := i * TAU / 5.0 + rng.randf_range(-0.4, 0.4)
		var dir := Vector3(cos(a), 0, sin(a))
		var end := dir * rng.randf_range(0.35, 0.6) + Vector3(0, rng.randf_range(0.55, 0.9), 0)
		branches.append([[dir * 0.05, dir * 0.2 + Vector3(0, 0.3, 0), end], 0.03, 0.01, bark, false])
	for i in 10 + variant * 2:
		var a := i * 2.399 + rng.randf_range(-0.3, 0.3)
		var r := rng.randf_range(0.15, 0.75)
		var p := Vector3(cos(a) * r, 0.5 + (0.75 - r) * 0.55 + rng.randf_range(0.0, 0.2), sin(a) * r)
		foliage.append([p, Vector3(0.6, 0.42, 0.52) * rng.randf_range(0.85, 1.15), a, rng.randf() * 10.0])
	return _leafy(branches, foliage, [Color("7fa94f"), Color("8fb255"), Color("749f52")], false)


## Сухое дерево: голый кривой ствол с обломанной вершиной и сучьями. Кроны нет.
static func _dead(variant: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 6930 + variant * 331
	var bark := Color("6e6052")
	var height := 3.5 * (0.95 + variant * 0.05)
	var branches: Array = []
	var path: Array[Vector3] = []
	var drift := Vector3.ZERO
	for i in 6:
		var t := i / 5.0
		if i > 0:
			drift += Vector3(rng.randf_range(-0.13, 0.13), 0, rng.randf_range(-0.13, 0.13))
		path.append(drift + Vector3(0, t * height, 0))
	branches.append([path, 0.2, 0.06, bark, false])
	_roots(branches, rng, 4, Vector2(0.45, 0.7), 0.38, 0.06, 0.13, bark)
	for i in 5 + variant:
		var t := rng.randf_range(0.32, 0.86)
		var at := t * 5.0
		var start := path[int(at)].lerp(path[mini(int(at) + 1, 5)], at - int(at))
		var a := i * 2.399 + rng.randf_range(-0.4, 0.4)
		var dir := Vector3(cos(a), 0, sin(a))
		var length := rng.randf_range(0.5, 1.5) * (1.0 - t * 0.35)
		# Каждый третий сук обломан и свисает, остальные — с изломом посередине.
		var lift := -0.25 if i % 3 == 2 else rng.randf_range(0.3, 0.6)
		var kink := start + dir * length * 0.5 + Vector3(0, length * lift * 0.6, 0)
		var turn := dir.rotated(Vector3.UP, rng.randf_range(-0.7, 0.7))
		var end := kink + turn * length * 0.5 + Vector3(0, length * lift, 0)
		branches.append([[start, kink, end], 0.08 * (1.0 - t * 0.35), 0.025, bark, false])
		if i % 2 == 0:
			var twig := kink + turn.rotated(Vector3.UP, 1.2) * 0.35 + Vector3(0, 0.25, 0)
			branches.append([[kink, twig], 0.03, 0.01, bark, false])
	return {trunk = _mesh(branches, [], false), bark = Color.WHITE, colored_bark = true, trunk_texture = _texture(false)}


## Маленькие общие бесшовные текстуры: прожилки листьев и продольная кора.
## Создаются один раз; в кадре работают штатные материалы без процедурного шейдера.
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
			var value := 0.77 + grain * 0.12 if leaves else 0.86 + 0.06 * sin(x * 0.9 + sin(y * TAU / 128.0) * 1.5) + grain * 0.04
			image.set_pixel(x, y, Color(value, value, value, 0.0 if leaves else 1.0))
	if leaves:
		var rng := RandomNumberGenerator.new()
		rng.seed = 651
		for i in (240 if needles else 150):
			var a := rng.randf() * TAU
			var r := sqrt(rng.randf()) * 50.0
			var center := Vector2(64, 64) + Vector2(cos(a), sin(a)) * r
			var angle := rng.randf() * TAU
			var length := rng.randf_range(5, 11) if needles else rng.randf_range(6, 12)
			var width := length * (0.15 if needles else 0.5) # 9.4: круглее и мягче
			for dy in range(-12, 13):
				for dx in range(-12, 13):
					var p := Vector2(dx, dy).rotated(angle)
					if absf(p.y) / length + pow(absf(p.x) / width, 1.5) > 1.0:
						continue
					var shade := 0.82 + 0.16 * (1.0 - absf(p.x) / width) + (0.04 if p.x < 0 else -0.04)
					if absf(p.x) < 0.45:
						shade *= 0.85
					image.set_pixel(posmod(int(center.x) + dx, 128), posmod(int(center.y) + dy, 128), Color(shade, shade, shade * 0.97, 1))
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
	# 9.4: эллипсоид кроны. Нормали листвы смотрят от его центра: крона освещается как мягкий
	# цельный объём (приём стилизованных деревьев), а не как стопка плоских веток.
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
			# Первая ветвь (ствол, у куста главный стебель) остаётся на всех уровнях: поверхность не пустеет.
			if level == 2 and branch[1] < 0.06 and branch != branches[0]:
				continue # Тонкие веточки уже меньше пикселя; силуэт остаётся в листве.
			if level == 1 and branch[1] < 0.035 and branch != branches[0]:
				continue
			vertex_count += _tube(st, branch, (6 - level) if branch[1] > 0.12 else 3, level, vertex_count)
		for spray: Array in (_far_foliage(foliage) if level == 2 else foliage):
			_spray(st, spray, level, conifer, crown)
		st.index()
		levels.append(st.commit())
	var mesh: ArrayMesh = levels[0]
	mesh.set_meta("lod_meshes", [levels[1], levels[2]])
	return mesh


static func lod_meshes(mesh: Mesh) -> Array[Mesh]:
	var result: Array[Mesh] = [mesh]
	# Старый контракт поддержан для изолированных сравнений и сторонних моделей.
	if mesh.has_meta("levels"):
		result.assign(mesh.get_meta("levels"))
	else:
		result.append_array(mesh.get_meta("lod_meshes", []))
	return result


## Дальняя крона объединяет ближайшие объёмы, а не выбрасывает каждый второй побег.
## Так сохраняются низ кроны, поникающие ветви и отдельные верхушки развилок.
static func _far_foliage(foliage: Array) -> Array:
	var result: Array = []
	var used := PackedByteArray()
	used.resize(foliage.size())
	for i in foliage.size():
		if used[i]:
			continue
		var spray: Array = foliage[i]
		used[i] = 1
		if spray.size() > 4:
			# Рамки пальм идут парами целых вай, вершины кроны сохраняются отдельно.
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
			var d: float = spray[0].distance_squared_to(foliage[j][0])
			if d < distance:
				distance = d
				nearest = j
		if nearest < 0:
			result.append(spray)
			continue
		used[nearest] = 1
		var other: Array = foliage[nearest]
		var center: Vector3 = (spray[0] + other[0]) * 0.5
		var extent: Vector3 = (spray[0] - center).abs() + spray[1]
		extent = extent.max((other[0] - center).abs() + other[1])
		result.append([center, extent, spray[2], spray[3]])
	return result


static func _vertex(st: SurfaceTool, p: Vector3, normal: Vector3, color: Color) -> void:
	st.set_normal(normal)
	st.set_color(color)
	st.add_vertex(p)


static func _tube(st: SurfaceTool, data: Array, segments: int, level: int, first: int) -> int:
	var path: Array = data[0]
	# Только конечные веточки можно выпрямлять: несущие развилки сохраняют точки крепления.
	if level > 0 and data.size() > 5 and data[5]:
		path = [path[0], path[-1]]
	# Каждое сечение вычисляется один раз, а соседние грани используют общие индексы.
	for ring in path.size():
		var direction: Vector3 = (path[mini(ring + 1, path.size() - 1)] - path[maxi(ring - 1, 0)]).normalized()
		var reference := Vector3.RIGHT if absf(direction.dot(Vector3.FORWARD)) > 0.95 else Vector3.FORWARD
		var side := direction.cross(reference).normalized()
		var front := side.cross(direction).normalized()
		var t := ring / float(path.size() - 1)
		var radius: float = lerpf(data[1], data[2], t)
		if ring == 0 and path.size() > 3:
			radius *= 1.3
		for j in segments + 1:
			var a := j * TAU / segments
			var normal := side * cos(a) + front * sin(a)
			var p: Vector3 = path[ring] + normal * radius * (1.0 + 0.08 * sin(a * 3.0 + ring))
			var color: Color = data[3] * (0.88 + 0.12 * sin(a * 3.0 + ring * 0.8))
			if data[4] and sin(p.y * 21.0 + (j % segments) * 4.7) > 0.72:
				color = Color("514d45")
			color.a = 1.0
			st.set_uv(Vector2(a / TAU * 2.0, p.y * 0.65))
			_vertex(st, p, normal, color)
	for k in path.size() - 1:
		for j in segments:
			var a := first + k * (segments + 1) + j
			var b := a + segments + 1
			for index: int in [a, a + 1, b + 1, a, b + 1, b]:
				st.add_index(index)
	return path.size() * (segments + 1)


## Нормаль и яркость точки листвы по эллипсоиду кроны crown = [центр, полуоси]: снаружи светлее,
## в глубине темнее — объём без лишней геометрии.
static func _crown_light(p: Vector3, crown: Array) -> Array:
	var d: Vector3 = (p - crown[0]) / crown[1]
	var normal := (d + Vector3.UP * 0.6).normalized() if d.length() > 0.05 else Vector3.UP
	var shade := 0.8 + 0.24 * clampf(d.length(), 0.0, 1.0)
	return [normal, Color(shade, shade, shade, 1)]


static func _spray(st: SurfaceTool, data: Array, level: int, conifer: bool, crown: Array) -> void:
	var center: Vector3 = data[0]
	var size: Vector3 = data[1]
	var rotation := Basis(Vector3.UP, data[2])
	var phase: float = data[3]
	# Пространственные веера с вырезанными листьями вместо гладких оболочек.
	var planes := 3 if level == 0 else 2
	# Пятый элемент — рамка плоского листа либо признак важной вершины кроны для LOD.
	if data.size() > 4 and data[4] is Basis:
		_flat_spray(st, data, planes, crown)
		return
	for i in planes:
		var a := phase + i * 2.399
		var axis := rotation * Vector3(cos(a), 0, sin(a))
		var up := Vector3.UP if not conifer else (Vector3.UP * 0.45 + axis * 0.55).normalized()
		var side := up.cross(axis).normalized()
		var c := center + Vector3(0, (i - (planes - 1) * 0.5) * size.y * 0.25, 0)
		# Эллиптический побег вместо одинаково круглого силуэта с любого ракурса.
		var w := sqrt(pow(cos(a) * size.x, 2.0) + pow(sin(a) * size.z, 2.0)) * 1.18
		var h := size.y * 1.2
		var points := [c - side * w - up * h, c + side * w - up * h, c + side * w + up * h, c - side * w + up * h]
		var uv := [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]
		for index in [0, 1, 2, 0, 2, 3]:
			st.set_uv(uv[index])
			var lit := _crown_light(points[index], crown)
			# Разные ветви слегка различаются по тону, сохраняя объёмное освещение кроны.
			var shade := 0.94 + 0.09 * (0.5 + 0.5 * sin(phase * 2.1))
			var color: Color = lit[1] * shade
			color.a = 1.0
			var local: Vector3 = (points[index] - center) / size
			var lobe_normal := (local + Vector3.UP * 0.7).normalized()
			_vertex(st, points[index], (lit[0] * 0.7 + lobe_normal * 0.3).normalized(), color)


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
