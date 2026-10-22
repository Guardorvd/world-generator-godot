class_name WorldAudio
extends Node
## Звуки путешествия (с 2.7): вода, прибой, костёр в поселении, птицы, шаги, шины велосипеда,
## приземление. Звуки — короткие WAV в resources/sounds, синтезированы tools/make_sounds.py.
## Фон — петли AudioStreamPlayer, громкость которых плавно следует за местом:
## расстояние до реки или озера и до моря (по полям WorldData.dist_water и dist_ocean), до
## ближайшего костра. Костёр и птицы — AudioStreamPlayer3D, их слышно с нужной стороны. Шаги и
## удары — AudioStreamRandomizer: случайный вариант, высота и громкость, без повтора подряд.
## Местность проверяется не каждый кадр, а раз в SAMPLE секунд. Общая громкость — шина Master
## (GameSettings.volume).

const TILE := GameConfig.TILE
const SAMPLE := 0.25        # раз в столько секунд проверяется местность вокруг
const SMOOTH := 1.5         # 1/с: как быстро фон догоняет нужную громкость
const SILENT := -60.0       # дБ: тише этого петля не слышна
const WATER_R := 45.0       # м: дальше реки и озера не слышно
const SEA_R := 140.0        # м: дальше моря не слышно
const FIRE_R := 30.0        # м: костёр слышно ближе этого
const BIRD_DELAY := Vector2(3.0, 9.0)   # с: пауза между голосами птиц

# наибольшая громкость каждого звука, дБ: всё негромкое, фон под шагами
const DB_WATER := -15.0
const DB_SURF := -14.0
const DB_FIRE := -9.0
const DB_ROLL := -13.0
const DB_STEP := -15.0
const DB_LAND := -10.0
const DB_BIRD := -6.0

const S := "res://resources/sounds/"

# Биомы с хрустом под ногами.
const HARD := [Biomes.BEACH, Biomes.DESERT, Biomes.ROCK, Biomes.PEAK, Biomes.STONESHORE]

var world: WorldData
var heights: Heightfield
var _water: AudioStreamPlayer
var _surf: AudioStreamPlayer
var _roll: AudioStreamPlayer
var _fire: AudioStreamPlayer3D
var _bird: AudioStreamPlayer3D
var _land: AudioStreamPlayer
var _steps := {}            # поверхность -> AudioStreamPlayer
var _goal := {}             # петля -> громкость, к которой она стремится, 0..1
var _level := {}            # петля -> текущая громкость 0..1
var _sample_t := 0.0
var _bird_t := 4.0
var _bird_ok := false       # вокруг есть где жить птицам
var _step_phase := 0
var _roll_surface := "soft"
var _roll_rough := 0.3
var _roll_pitch := 1.0
var _contact_dist := 0.0
var _contact_wait := 0.0


func _ready() -> void:
	_water = _loop("water")
	_surf = _loop("surf")
	_roll = _loop("roll")
	_fire = AudioStreamPlayer3D.new()
	_fire.stream = load(S + "fire.wav")
	_fire.unit_size = 4.0
	_fire.max_distance = FIRE_R
	_fire.volume_db = DB_FIRE
	add_child(_fire)
	_bird = AudioStreamPlayer3D.new()
	_bird.stream = _random(["bird_1", "bird_2", "bird_3"], 1.12, 3.0)
	_bird.unit_size = 12.0
	_bird.volume_db = DB_BIRD
	add_child(_bird)
	for kind: String in ["soft", "gravel", "wood", "splash"]:
		var names: Array[String] = []
		for k in (3 if kind == "wood" or kind == "splash" else 4):
			names.append("step_%s_%d" % [kind, k + 1])
		var p := AudioStreamPlayer.new()
		p.stream = _random(names, 1.1, 2.0)
		p.max_polyphony = 2
		add_child(p)
		_steps[kind] = p
	_land = AudioStreamPlayer.new()
	_land.stream = _random(["land"], 1.1, 1.0)
	add_child(_land)


func _loop(file: String) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = load(S + file + ".wav")
	p.volume_db = SILENT
	add_child(p)
	_goal[p] = 0.0
	return p


## Случайный выбор из звуков names с разбросом высоты pitch (множитель) и громкости vol (дБ)
func _random(names: Array, pitch: float, vol: float) -> AudioStreamRandomizer:
	var r := AudioStreamRandomizer.new()
	for n: String in names:
		r.add_stream(-1, load(S + n + ".wav"))
	r.random_pitch = pitch
	r.random_volume_offset_db = vol
	return r


func setup(w: WorldData, h: Heightfield) -> void:
	world = w
	heights = h
	for p: AudioStreamPlayer in _goal:
		p.play(randf() * p.stream.get_length())


## На паузе звук замирает, после паузы продолжается с того же места
func set_paused(on: bool) -> void:
	for p: Node in get_children():
		p.stream_paused = on


## Такт физики: шаги по фазе покачивания (два шага на её оборот: внизу и вверху), как идёт игрок
func tick(player: PlayerState, riding: bool) -> void:
	var phase := floori(player.bob / PI + 0.5)
	if riding or not player.on_ground or player.ground_speed() < 0.8:
		_step_phase = phase
		return
	if phase != _step_phase:
		_step_phase = phase
		var run := clampf((player.ground_speed() - GameConfig.WALK) / GameConfig.WALK, 0.0, 1.0)
		_play_step(player.x, player.z, player.feet, DB_STEP + run * 3.0)


## Приземление с ударом impact (м/с): мягкий удар и шаг по той поверхности, куда пришли ноги
func land(x: float, z: float, feet: float, impact: float) -> void:
	if impact < 2.5:
		return
	var k := clampf((impact - 2.5) / 10.0, 0.0, 1.0)
	_play_step(x, z, feet, DB_STEP + 2.0)
	_land.volume_db = DB_LAND - 12.0 + k * 12.0
	_land.play()


func _play_step(x: float, z: float, feet: float, db: float) -> void:
	var p: AudioStreamPlayer = _steps[_surface(x, z, feet)]
	p.volume_db = db
	p.play()


## Под ногами: вода, доски моста, гравий (дорога, камень, песок) или мягкая земля
func _surface(x: float, z: float, feet: float) -> String:
	if heights.depth_at(x, z, feet) > 0.05:
		return "splash"
	if heights.deck_at(x, z, feet) > heights.ground_at(x, z) + 0.05:
		return "wood"
	var info := world.tile_info(x / TILE, z / TILE)
	if info.is_empty():
		return "soft"
	var surf := PlayerState.surface(info)
	if heights.road_refinement != null:
		var contact := heights.road_refinement.sample(x, z, world.W)
		surf = contact.surface if not contact.is_empty() and contact.weight > 0.25 else RoadSurface.NONE
	if surf != RoadSurface.NONE:
		return "gravel" if RoadSurface.LIST[surf].hard else "soft"
	if HARD.has(info.biome):
		return "gravel"
	return "soft"


## Кадр: фон по месту (pos — ноги игрока); bike_speed — скорость велосипеда (м/с, 0 — пешком),
## rolling — колёса на земле
func update(pos: Vector3, bike_speed: float, rolling: bool, dt: float, bike_lean := 0.0) -> void:
	_sample_t -= dt
	if _sample_t <= 0.0:
		_sample_t = SAMPLE
		_sample(pos)
		_sample_rolling(pos)
	# Скорость передаётся шинами и касаниями покрытия, без постоянного шума ветра.
	var rush := clampf(absf(bike_speed) / GameConfig.BIKE_SPEED, 0.0, 1.3)
	# Покрытие меняет плотность и тембр шин, поворот чуть усиливает их шорох.
	var corner := clampf(absf(bike_lean) / 0.28, 0.0, 1.0)
	_goal[_roll] = clampf(rush * (0.55 + _roll_rough * 0.45 + corner * 0.12), 0.0, 1.0) if rolling else 0.0
	_roll.pitch_scale = lerpf(_roll.pitch_scale, (0.7 + 0.45 * rush) * _roll_pitch, 1.0 - exp(-8.0 * dt))
	_contact_wait = maxf(0.0, _contact_wait - dt)
	if rolling and absf(bike_speed) > 1.0:
		_contact_dist += absf(bike_speed) * dt
		# Короткие тихие касания из имеющихся звуков: камешки, доски, брызги.
		if _contact_dist >= 2.0 and _contact_wait <= 0.0:
			_contact_dist = fmod(_contact_dist, 2.0)
			_contact_wait = 0.16
			if _roll_surface != "soft":
				var contact_player: AudioStreamPlayer = _steps[_roll_surface]
				contact_player.volume_db = DB_STEP - 12.0 + minf(rush, 1.0) * 4.0
				contact_player.play()
	else:
		_contact_dist = 0.0
	var a := 1.0 - exp(-SMOOTH * dt)
	var fast := 1.0 - exp(-8.0 * dt)   # шины затихают сразу, как велосипед оторвался от земли
	for p: AudioStreamPlayer in _goal:
		# уровень хранится отдельно: из volume_db тихий звук читался как «молчит» и не мог разгореться
		var cur := lerpf(_level.get(p, 0.0), _goal[p], fast if p == _roll else a)
		_level[p] = cur
		p.volume_db = _max_db(p) + linear_to_db(cur) if cur > 0.001 else SILENT
	_bird_t -= dt
	if _bird_t <= 0.0:
		_bird_t = randf_range(BIRD_DELAY.x, BIRD_DELAY.y)
		if _bird_ok and not _bird.playing:
			var ang := randf() * TAU
			var d := randf_range(10.0, 30.0)
			_bird.position = pos + Vector3(sin(ang) * d, randf_range(4.0, 9.0), cos(ang) * d)
			_bird.play()


## Дешёвая выборка вместе с фоном, без новых звуков и проигрывателей.
func _sample_rolling(pos: Vector3) -> void:
	_roll_surface = _surface(pos.x, pos.z, pos.y)
	_roll_rough = 0.65
	_roll_pitch = 0.9
	var info := world.tile_info(pos.x / TILE, pos.z / TILE)
	var surf := PlayerState.surface(info) if not info.is_empty() else RoadSurface.NONE
	if heights.road_refinement != null:
		var contact := heights.road_refinement.sample(pos.x, pos.z, world.W)
		surf = contact.surface if not contact.is_empty() and contact.weight > 0.25 else RoadSurface.NONE
	if surf != RoadSurface.NONE:
		_roll_rough = RoadSurface.LIST[surf].rough
		_roll_pitch = 1.12 if RoadSurface.LIST[surf].hard else 0.85
	if _roll_surface == "wood":
		_roll_rough = 0.4
		_roll_pitch = 0.75
	elif _roll_surface == "splash":
		_roll_rough = 0.8
		_roll_pitch = 0.8


func _max_db(p: AudioStreamPlayer) -> float:
	if p == _water:
		return DB_WATER
	if p == _surf:
		return DB_SURF
	return DB_ROLL


## Что слышно вокруг: вода, море, птицы, ближайший костёр
func _sample(pos: Vector3) -> void:
	var tx := floori(pos.x / TILE)
	var tz := floori(pos.z / TILE)
	var water_d := INF
	var sea_d := INF
	if tx >= 0 and tz >= 0 and tx < world.W and tz < world.H:
		var i := tz * world.W + tx
		sea_d = world.dist_ocean[i] * TILE
		# ближайшая вода — не море: значит, река или озеро
		if world.dist_water[i] < world.dist_ocean[i] - 0.5:
			water_d = world.dist_water[i] * TILE
	elif world.outer != null:
		sea_d = _outer_sea(tx, tz)
	_goal[_water] = pow(clampf(1.0 - water_d / WATER_R, 0.0, 1.0), 1.5)
	_goal[_surf] = pow(clampf(1.0 - sea_d / SEA_R, 0.0, 1.0), 2.0)
	var info := world.tile_info(pos.x / TILE, pos.z / TILE)
	var biome: int = info.biome if not info.is_empty() else Biomes.OCEAN
	var b: Dictionary = Biomes.LIST[biome]
	_bird_ok = b.get("trees", 0.0) > 0.05 and not b.get("water", false) and biome != Biomes.SNOW
	# костёр: звук стоит у ближайшего, если он ближе FIRE_R
	var best := FIRE_R * FIRE_R
	var at := Vector3()
	for s in world.settlements:
		var dx: float = s.x * TILE - pos.x
		var dz: float = s.y * TILE - pos.z
		if dx * dx + dz * dz < best:
			best = dx * dx + dz * dz
			at = Vector3(s.x * TILE, heights.ground_at(s.x * TILE, s.y * TILE) + 0.5, s.y * TILE)
	if best < FIRE_R * FIRE_R:
		_fire.position = at
		if not _fire.playing:
			_fire.play(randf() * _fire.stream.get_length())
	elif _fire.playing:
		_fire.stop()


## Расстояние до моря за краем карты, м: ближайшая клетка ниже уровня моря на трёх кругах вокруг
func _outer_sea(tx: int, tz: int) -> float:
	if world.outer.height(tx, tz) < 0.0:
		return 0.0
	for r: float in [3.0, 10.0, 25.0]:
		for k in 12:
			var ang := k * TAU / 12.0
			var i := tx + roundi(cos(ang) * r)
			var j := tz + roundi(sin(ang) * r)
			var sea: bool
			if i >= 0 and j >= 0 and i < world.W and j < world.H:
				sea = world.dist_ocean[j * world.W + i] < 0.5 # точка круга попала на карту
			else:
				sea = world.outer.has(i, j) and world.outer.height(i, j) < 0.0
			if sea:
				return r * TILE
	return INF
