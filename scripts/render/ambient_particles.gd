class_name AmbientParticles
extends Node3D
## 11.11.2026: частицы окружения — живость воздуха без затрат на кадр. Слои описаны таблицей LAYERS:
## чтобы добавить новый вид частиц, достаточно дописать запись и правило в _target (где и когда он виден).
##
## Как устроено:
## - слой — один меш четырёхугольников с шейдером resources/ambient_particles.gdshader: место каждой частицы
##   считается на видеокарте из зерна и времени и заворачивается в объём вокруг камеры. Один вызов отрисовки
##   на слой, процессор на кадр не считает ничего; слой с нулевой плотностью скрыт целиком;
## - дважды в секунду система читает окружение у камеры (биом, температура, влажность, лес, вода, ночь)
##   и плавно ведёт плотность каждого слоя к правилу из _target — на границе биомов частицы меняются постепенно;
## - листья, которые ветер гонит по земле (GROUND), — маленький набор экземпляров MultiMesh на процессоре:
##   им нужна высота земли. Три десятка штук, по одному запросу высоты на лист за кадр.
##
## density — общий множитель плотности (0 выключает всё), для настроек качества.
## Физику, управление и генерацию система не читает и не меняет; ей нужны только WorldData и Heightfield.

const SHADER := preload("res://resources/ambient_particles.gdshader")
const WIND := Vector3(0.82, 0.0, 0.57) # то же направление, что у ветра растительности
const WIND_SPEED := 1.2                # м/с при обычном ветре
const SAMPLE_EVERY := 0.5              # с: как часто перечитывать окружение
const GROUND := 40                     # листьев на земле

## count — частиц в слое; box — объём вокруг камеры (м); lift — его середина над камерой; size — половина стороны (м);
## shape — 0 мягкая точка, 1 лист, 2 плотная точка; fall — вертикальная скорость (м/с, вниз отрицательная);
## wind — доля скорости ветра; sway/sway_speed — покачивание; wander — беспорядочное движение; tumble — кувыркание;
## glow/blink — свечение и мерцание; a, b — цвета (альфа — непрозрачность), частица берёт смесь по своему зерну.
const LAYERS: Array[Dictionary] = [
	{id = "dust", count = 1400, box = Vector3(24, 8, 24), lift = 1.2, size = 0.02, shape = 0, fall = -0.03, wind = 0.3,
		sway = 0.25, sway_speed = 0.5, a = Color(1.0, 0.96, 0.84, 0.65), b = Color(1.0, 1.0, 1.0, 0.4)},
	{id = "fluff", count = 400, box = Vector3(36, 10, 36), lift = 2.0, size = 0.035, shape = 0, fall = 0.05, wind = 0.9,
		sway = 0.5, sway_speed = 0.7, a = Color(1.0, 1.0, 0.97, 0.8), b = Color(1.0, 1.0, 1.0, 0.5)},
	{id = "leaves", count = 260, box = Vector3(34, 12, 34), lift = 3.5, size = 0.07, shape = 1, fall = -0.75, wind = 0.8,
		sway = 0.7, sway_speed = 1.3, tumble = 2.6, a = Color(0.62, 0.50, 0.14, 1.0), b = Color(0.36, 0.46, 0.14, 1.0)},
	{id = "gnats", count = 300, box = Vector3(12, 4, 12), lift = 0.2, size = 0.012, shape = 2, fall = 0.0, wind = 0.0,
		wander = 0.35, a = Color(0.10, 0.09, 0.07, 0.8), b = Color(0.22, 0.2, 0.16, 0.6)},
	{id = "fireflies", count = 320, box = Vector3(30, 5, 30), lift = 0.0, size = 0.05, shape = 0, fall = 0.0, wind = 0.05,
		wander = 0.5, sway = 0.8, sway_speed = 0.4, glow = 1.0, blink = 1.6, a = Color(0.85, 1.0, 0.35, 1.0), b = Color(1.0, 0.9, 0.4, 1.0)},
	{id = "snow", count = 2600, box = Vector3(26, 12, 26), lift = 2.5, size = 0.022, shape = 2, fall = -1.1, wind = 1.4,
		sway = 0.35, sway_speed = 0.9, a = Color(1.0, 1.0, 1.0, 0.9), b = Color(0.92, 0.96, 1.0, 0.7)},
	{id = "sand", count = 900, box = Vector3(30, 3, 30), lift = -1.3, size = 0.008, shape = 2, fall = 0.0, wind = 3.2,
		sway = 0.2, sway_speed = 2.0, a = Color(0.86, 0.76, 0.52, 0.6), b = Color(0.93, 0.86, 0.66, 0.4)},
]
## Цвет листвы по биому: [сухой, живой]; у тайги — хвоя.
const LEAF_TINT := {
	Biomes.FOREST: [Color(0.66, 0.50, 0.13), Color(0.36, 0.47, 0.14)],
	Biomes.GRASS: [Color(0.62, 0.52, 0.16), Color(0.40, 0.50, 0.16)],
	Biomes.JUNGLE: [Color(0.42, 0.44, 0.12), Color(0.20, 0.42, 0.14)],
	Biomes.TAIGA: [Color(0.42, 0.30, 0.14), Color(0.33, 0.27, 0.13)],
	Biomes.SWAMP: [Color(0.40, 0.34, 0.14), Color(0.30, 0.36, 0.15)],
	Biomes.SAVANNA: [Color(0.66, 0.56, 0.22), Color(0.55, 0.52, 0.2)],
}

var density := 1.0
var world: WorldData
var heights: Heightfield
var _mats: Dictionary = {}      # id → ShaderMaterial
var _nodes: Dictionary = {}     # id → MeshInstance3D
var _amounts: Dictionary = {}   # id → нынешняя плотность 0..1
var _targets: Dictionary = {}
var _context := {}
var _forced := false
var _sample_in := 0.0
var _ground: MultiMeshInstance3D
var _ground_items: Array[Dictionary] = []
var _ground_amount := 0.0
var _clock := 0.0


func _ready() -> void:
	for def: Dictionary in LAYERS:
		var mat := ShaderMaterial.new()
		mat.shader = SHADER
		mat.set_shader_parameter("box", def.box)
		mat.set_shader_parameter("lift", def.lift)
		mat.set_shader_parameter("size", def.size)
		mat.set_shader_parameter("shape", def.shape)
		mat.set_shader_parameter("drift", WIND * WIND_SPEED * float(def.wind) + Vector3(0.0, def.fall, 0.0))
		mat.set_shader_parameter("sway", def.get("sway", 0.0))
		mat.set_shader_parameter("sway_speed", def.get("sway_speed", 1.0))
		mat.set_shader_parameter("wander", def.get("wander", 0.0))
		mat.set_shader_parameter("tumble", def.get("tumble", 0.0))
		mat.set_shader_parameter("glow", def.get("glow", 0.0))
		mat.set_shader_parameter("blink", def.get("blink", 0.0))
		mat.set_shader_parameter("color_a", def.a)
		mat.set_shader_parameter("color_b", def.b)
		var node := MeshInstance3D.new()
		node.name = String(def.id).capitalize()
		node.mesh = _quads(def.count, hash(def.id))
		node.material_override = mat
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.custom_aabb = AABB(Vector3.ONE * -1.0e6, Vector3.ONE * 2.0e6) # место считает шейдер
		node.visible = false
		add_child(node)
		_mats[def.id] = mat
		_nodes[def.id] = node
		_amounts[def.id] = 0.0
		_targets[def.id] = 0.0
	_build_ground()


func setup(world_data: WorldData, heightfield: Heightfield) -> void:
	world = world_data
	heights = heightfield


## Меш слоя: count четырёхугольников в начале координат, у каждого своё зерно.
static func _quads(count: int, salt: int) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = salt
	var pos := PackedVector3Array()
	var uv := PackedVector2Array()
	var colors := PackedColorArray()
	var custom := PackedFloat32Array()
	var idx := PackedInt32Array()
	for i in count:
		var seed := [rng.randf(), rng.randf(), rng.randf(), (float(i) + 0.5) / count]
		var c := Color(rng.randf(), rng.randf(), rng.randf(), rng.randf())
		for corner: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
			pos.append(Vector3(corner.x, corner.y, 0.0))
			uv.append(corner * 0.5 + Vector2(0.5, 0.5))
			colors.append(c)
			custom.append_array(seed)
		idx.append_array([i * 4, i * 4 + 1, i * 4 + 2, i * 4, i * 4 + 2, i * 4 + 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_CUSTOM0] = custom
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
	return mesh


## Окружение в точке: всё, от чего зависят правила слоёв.
func read_context(at: Vector3, sunlight: float) -> Dictionary:
	var info: Dictionary = world.tile_info(at.x / GameConfig.TILE, at.z / GameConfig.TILE) if world != null else {}
	var biome: int = info.get("biome", -1)
	var entry: Dictionary = Biomes.LIST[biome] if biome >= 0 and biome < Biomes.LIST.size() else {}
	return {
		biome = biome, water = entry.get("water", false), trees = float(entry.get("trees", 0.0)),
		temp = float(info.get("temp", 0.5)), moist = float(info.get("moist", 0.5)), river = bool(info.get("river", false)),
		sun = clampf(sunlight, 0.0, 1.0), night = 1.0 - clampf(sunlight, 0.0, 1.0),
	}


## Правила: плотность слоя 0..1 в данном окружении. Новый слой — новая ветка.
static func _target(id: String, c: Dictionary) -> float:
	var biome: int = c.biome
	if biome < 0:
		return 0.0
	var cold: bool = biome in [Biomes.SNOW, Biomes.PEAK]
	var dry_sand: bool = biome in [Biomes.DESERT, Biomes.BEACH]
	var green: bool = biome in [Biomes.GRASS, Biomes.FOREST, Biomes.JUNGLE, Biomes.SWAMP, Biomes.TAIGA, Biomes.SAVANNA, Biomes.STEPPE]
	var wet: bool = biome == Biomes.SWAMP or c.river or c.water or float(c.moist) > 0.7
	match id:
		"dust": # пылинки и пыльца в солнечном воздухе
			return (0.0 if cold or c.water else (0.75 if green else 0.4)) * float(c.sun)
		"fluff": # семена-пушинки над открытой травой
			return (0.8 if biome in [Biomes.GRASS, Biomes.STEPPE, Biomes.SAVANNA] else (0.25 if biome == Biomes.FOREST else 0.0)) * float(c.sun)
		"leaves": # листья и хвоя падают там, где есть деревья
			return clampf(float(c.trees) * 1.1, 0.0, 0.9) if LEAF_TINT.has(biome) else 0.0
		"gnats": # мошкара у воды и в сыром лесу, днём и в сумерках
			return (0.9 if wet and green else (0.25 if biome in [Biomes.FOREST, Biomes.JUNGLE] else 0.0)) * smoothstep(0.05, 0.4, float(c.sun))
		"fireflies": # светлячки тёплой ночью в траве и у леса
			return (0.9 if biome in [Biomes.FOREST, Biomes.GRASS, Biomes.SWAMP, Biomes.JUNGLE] else 0.0) * smoothstep(0.75, 0.95, float(c.night))
		"snow":
			return 1.0 if cold else (0.35 if biome == Biomes.TUNDRA and float(c.temp) < 0.3 else 0.0)
		"sand": # позёмка песка у земли
			return 0.8 if dry_sand else 0.0
	return 0.0


## Для изолированных сцен и снимков: задать окружение вручную и сразу выставить плотности.
func force_context(c: Dictionary) -> void:
	_forced = true
	_context = c
	_retarget()
	for id: String in _amounts:
		_amounts[id] = _targets[id]
	_ground_amount = _targets.get("leaves", 0.0)
	_apply(c.get("sun", 1.0))


func _retarget() -> void:
	for id: String in _targets:
		_targets[id] = _target(id, _context) * density
	var tint: Array = LEAF_TINT.get(_context.get("biome", -1), [])
	if not tint.is_empty():
		(_mats["leaves"] as ShaderMaterial).set_shader_parameter("color_a", tint[0])
		(_mats["leaves"] as ShaderMaterial).set_shader_parameter("color_b", tint[1])


func _apply(sunlight: float) -> void:
	var light := Color(0.22, 0.27, 0.42).lerp(Color(1.0, 0.97, 0.9), clampf(sunlight, 0.0, 1.0))
	for id: String in _amounts:
		var node: MeshInstance3D = _nodes[id]
		var on: bool = _amounts[id] > 0.004
		node.visible = on
		if on:
			var mat: ShaderMaterial = _mats[id]
			mat.set_shader_parameter("amount", _amounts[id])
			mat.set_shader_parameter("light", light)


## Раз в кадр из игры: eye — место камеры, sunlight — DayCycle.sunlight.
func update(dt: float, eye: Vector3, sunlight: float) -> void:
	_clock += dt
	_sample_in -= dt
	if _sample_in <= 0.0 and not _forced:
		_sample_in = SAMPLE_EVERY
		_context = read_context(eye, sunlight)
		_retarget()
	var blend := 1.0 - exp(-dt * 0.6)
	for id: String in _amounts:
		_amounts[id] = lerpf(_amounts[id], _targets[id], blend)
	_ground_amount = lerpf(_ground_amount, _targets.get("leaves", 0.0), blend)
	_apply(sunlight)
	_update_ground(dt, eye)


func _build_ground() -> void:
	var leaf := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(-0.05, 0, 0), Vector3(0, 0, -0.022), Vector3(0.05, 0, 0), Vector3(0, 0, 0.022)])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	leaf.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.roughness = 0.9
	leaf.surface_set_material(0, mat)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = leaf
	mm.instance_count = GROUND
	mm.visible_instance_count = 0
	_ground = MultiMeshInstance3D.new()
	_ground.name = "GroundLeaves"
	_ground.multimesh = mm
	_ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ground.custom_aabb = AABB(Vector3.ONE * -1.0e6, Vector3.ONE * 2.0e6)
	add_child(_ground)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4471
	for i in GROUND:
		_ground_items.append({at = Vector2.INF, phase = rng.randf() * TAU, pace = rng.randf_range(0.5, 1.4), tone = rng.randf()})


## Листья по земле: ветер порывами гонит их вдоль WIND, с подскоками; ушедший далеко лист появляется с наветренной стороны.
func _update_ground(dt: float, eye: Vector3) -> void:
	var shown := int(round(GROUND * clampf(_ground_amount, 0.0, 1.0)))
	var mm := _ground.multimesh
	mm.visible_instance_count = shown
	if shown == 0 or heights == null:
		return
	var tint: Array = LEAF_TINT.get(_context.get("biome", -1), LEAF_TINT[Biomes.FOREST])
	var centre := Vector2(eye.x, eye.z)
	var wind := Vector2(WIND.x, WIND.z)
	for i in shown:
		var item: Dictionary = _ground_items[i]
		var at: Vector2 = item.at
		if not at.is_finite() or at.distance_to(centre) > 24.0:
			var first := not at.is_finite()
			var ring := 6.0 + fposmod(item.phase * 7.3 + _clock, 14.0)
			var angle: float = item.phase * 3.1 + _clock * 0.37
			# первый раз — вокруг камеры, дальше — с наветренной стороны
			at = centre + (Vector2(cos(angle), sin(angle)) * ring if first else -wind * ring + Vector2(-wind.y, wind.x) * (fposmod(angle, 2.0) - 1.0) * 14.0)
		var gust := maxf(0.0, sin(_clock * 0.7 * item.pace + item.phase) + 0.25 * sin(_clock * 2.3 + item.phase * 2.0))
		var speed: float = WIND_SPEED * 1.6 * gust * item.pace
		at += wind * speed * dt + Vector2(-wind.y, wind.x) * sin(_clock * 1.9 + item.phase) * speed * 0.25 * dt
		item.at = at
		var hop := absf(sin(_clock * 5.0 * item.pace + item.phase)) * 0.12 * minf(speed, 1.5)
		var y := heights.ground_at(at.x, at.y) + 0.02 + hop
		var roll: float = item.phase + _clock * speed * 4.0
		var basis := Basis(Vector3.UP, item.phase * 2.0 + _clock * speed) * Basis(Vector3.RIGHT, roll if speed > 0.05 else 0.0)
		mm.set_instance_transform(i, Transform3D(basis.scaled(Vector3.ONE * (0.7 + item.tone * 0.6)), Vector3(at.x, y, at.y)))
		mm.set_instance_color(i, (tint[0] as Color).lerp(tint[1], item.tone * 0.6))
