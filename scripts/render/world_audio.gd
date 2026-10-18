class_name WorldAudio
extends Node
## Звуки путешествия (с 2.7): ветер, вода, прибой, костёр в поселении, птицы, шаги, шины велосипеда,
## приземление. Звуки — короткие WAV в resources/sounds, синтезированы tools/make_sounds.py.
## Фон — петли AudioStreamPlayer, громкость которых плавно следует за местом: высота и открытость
## (ветер), расстояние до реки или озера и до моря (по полям WorldData.dist_water и dist_ocean), до
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
const DB_WIND := -17.0
const DB_WATER := -15.0
const DB_SURF := -14.0
const DB_FIRE := -9.0
const DB_ROLL := -13.0
const DB_STEP := -15.0
const DB_LAND := -10.0
const DB_BIRD := -6.0

const S := "res://resources/sounds/"

# биомы без звонкого ветра (лес гасит его) и с хрустом под ногами
const SHELTERED := [Biomes.FOREST, Biomes.JUNGLE, Biomes.TAIGA, Biomes.SWAMP]
const HARD := [Biomes.BEACH, Biomes.DESERT, Biomes.ROCK, Biomes.PEAK, Biomes.STONESHORE]

var world: WorldData
var heights: Heightfield
var _wind: AudioStreamPlayer
var _water: AudioStreamPlayer
var _surf: AudioStreamPlayer
var _roll: AudioStreamPlayer
var _fire: AudioStreamPlayer3D
var _bird: AudioStreamPlayer3D
var _land: AudioStreamPlayer
var _steps := {}            # поверхность -> AudioStreamPlayer
var _goal := {}             # петля -> громкость, к которой она стремится, 0..1
var _sample_t := 0.0
var _bird_t := 4.0
var _bird_ok := false       # вокруг есть где жить птицам
var _open := 1.0            # 0..1: насколько место открыто ветру
var _step_phase := 0


func _ready() -> void:
	_wind = _loop("wind")
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
	if info.path == 3 or HARD.has(info.biome):
		return "gravel"
	return "soft"


## Кадр: фон по месту (pos — ноги игрока); bike_speed — скорость велосипеда (м/с, 0 — пешком),
## rolling — колёса на земле
func update(pos: Vector3, bike_speed: float, rolling: bool, dt: float) -> void:
	_sample_t -= dt
	if _sample_t <= 0.0:
		_sample_t = SAMPLE
		_sample(pos)
	# ветер сильнее высоко и на открытом месте, на велосипеде добавляется встречный поток
	var rush := clampf(absf(bike_speed) / GameConfig.BIKE_SPEED, 0.0, 1.3)
	var high := clampf(pos.y / (GameConfig.HS * 0.5), 0.0, 1.0)
	_goal[_wind] = clampf((0.35 + 0.45 * high) * _open + 0.35 * rush, 0.0, 1.0)
	_wind.pitch_scale = 1.0 + 0.15 * rush
	_goal[_roll] = clampf(rush, 0.0, 1.0) if rolling else 0.0
	_roll.pitch_scale = 0.7 + 0.45 * rush
	var a := 1.0 - exp(-SMOOTH * dt)
	var fast := 1.0 - exp(-8.0 * dt)   # шины затихают сразу, как велосипед оторвался от земли
	for p: AudioStreamPlayer in _goal:
		var cur := db_to_linear(p.volume_db - _max_db(p)) if p.volume_db > SILENT else 0.0
		cur = lerpf(cur, _goal[p], fast if p == _roll else a)
		p.volume_db = _max_db(p) + linear_to_db(cur) if cur > 0.001 else SILENT
	_bird_t -= dt
	if _bird_t <= 0.0:
		_bird_t = randf_range(BIRD_DELAY.x, BIRD_DELAY.y)
		if _bird_ok and not _bird.playing:
			var ang := randf() * TAU
			var d := randf_range(10.0, 30.0)
			_bird.position = pos + Vector3(sin(ang) * d, randf_range(4.0, 9.0), cos(ang) * d)
			_bird.play()


func _max_db(p: AudioStreamPlayer) -> float:
	if p == _wind:
		return DB_WIND
	if p == _water:
		return DB_WATER
	if p == _surf:
		return DB_SURF
	return DB_ROLL


## Что слышно вокруг: вода, море, открытость ветру, птицы, ближайший костёр
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
	_open = 0.55 if SHELTERED.has(biome) else 1.0
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
			if world.outer.has(i, j) and world.outer.height(i, j) < 0.0:
				return r * TILE
	return INF
