class_name WorldAudio
extends Node
## Звуки путешествия (с 2.7): вода, прибой, костёр в поселении, птицы, шаги, звуки велосипеда,
## приземление. Звуки — короткие WAV в resources/sounds, синтезированы tools/make_sounds.py.
## Фон — петли AudioStreamPlayer, громкость которых плавно следует за местом:
## расстояние до реки или озера и до моря (по полям WorldData.dist_water и dist_ocean), до
## ближайшего костра. Костёр и птицы — AudioStreamPlayer3D, их слышно с нужной стороны. Шаги и
## удары — AudioStreamRandomizer: случайный вариант, высота и громкость, без повтора подряд.
## Местность проверяется не каждый кадр, а раз в SAMPLE секунд. Общая громкость — шина Master
## (GameContext.scope.settings.volume).
##
## Езда (с 10.3) собрана слоями, как у звукорежиссёра: шины (основа, громкость и высота от скорости),
## покрытие (россыпь песчинок, плотность и тембр по поверхности), трещотка втулки накатом и мягкая цепь,
## пока крутят педали. Трещотка и цепь сменяют друг друга, слои плавно перетекают, без ритмичных щелчков.

const TILE := GameConfig.TILE
const SAMPLE := 0.25        # раз в столько секунд проверяется местность вокруг
const SMOOTH := 1.5         # 1/с: как быстро фон догоняет нужную громкость
const SILENT := -80.0       # дБ: тише этого петля не слышна (11.7: было -60 — шесть петель вместе давали шорох)
const WATER_R := 45.0       # м: дальше реки и озера не слышно
const SEA_R := 140.0        # м: дальше моря не слышно
const FIRE_R := 30.0        # м: костёр слышно ближе этого
const BIRD_DELAY := Vector2(5.0, 14.0)  # с: пауза между голосами птиц (с 10.3 реже, чтобы не надоедали)
const TICK_SPEED := 6.0     # м/с: при этой скорости трещотка щёлкает как записано (20 раз в секунду)
const PEDAL_HOLD := 0.3     # с: столько после последнего поворота педалей ещё слышна цепь

# наибольшая громкость каждого звука, дБ: всё негромкое, фон под шагами
const DB_WATER := -21.0
const DB_SURF := -22.0
const DB_FIRE := -9.0
const DB_ROLL := -22.0
const DB_GRIT := -19.0
const DB_TICK := -24.0
const DB_CHAIN := -25.0
const DB_STEP := -15.0
const DB_LAND := -10.0
const DB_BIRD := -6.0

const WORLD_BUS := &"World"
const DUCK_DB := -18.0
const DUCK_CUTOFF_HZ := 900.0
const FULL_CUTOFF_HZ := 16000.0

const S := "res://resources/sounds/"

# Биомы с хрустом под ногами.
const HARD := [Biomes.BEACH, Biomes.DESERT, Biomes.ROCK, Biomes.PEAK, Biomes.STONESHORE]

var world: WorldData
var heights: Heightfield
var fires: Array = []
var regional_fires: Array = []
var _water: AudioStreamPlayer
var _surf: AudioStreamPlayer
var _roll: AudioStreamPlayer
var _grit: AudioStreamPlayer
var _tick: AudioStreamPlayer
var _chain: AudioStreamPlayer
var _db := {}               # петля -> наибольшая громкость, дБ
var _fire: AudioStreamPlayer3D
var _bird: AudioStreamPlayer3D
var _land: AudioStreamPlayer
var _crash: AudioStreamPlayer  # 20.11: падение седока — удар, звяк рамы и шорох скольжения
var _bottom: AudioStreamPlayer # пробой подвески — свой голос: приземление его не глушит
var _knock: AudioStreamPlayer  # удар колеса о кромку
var _pump: AudioStreamPlayer
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
var _contact_next := 2.0    # м до следующего касания досок или брызг (случайно, без ритма)
var _grit_level := 0.0      # сколько песчинок на этой поверхности, 0..1
var _grit_pitch := 1.0
var _crank := 0.0
var _pedal_t := 0.0
var _ducked := false
var _duck_tween: Tween


static func ensure_world_bus() -> int:
	var idx := AudioServer.get_bus_index(WORLD_BUS)
	if idx != -1:
		return idx
	idx = AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, WORLD_BUS)
	AudioServer.set_bus_send(idx, &"Master")
	var lpf := AudioEffectLowPassFilter.new()
	lpf.cutoff_hz = FULL_CUTOFF_HZ
	lpf.resonance = 0.5
	AudioServer.add_bus_effect(idx, lpf, 0)
	AudioServer.set_bus_effect_enabled(idx, 0, false)
	return idx


func _ready() -> void:
	ensure_world_bus()
	_water = _loop("water", DB_WATER)
	_surf = _loop("surf", DB_SURF)
	_roll = _loop("roll", DB_ROLL)
	_grit = _loop("grit", DB_GRIT)
	_tick = _loop("freewheel", DB_TICK)
	_chain = _loop("chain", DB_CHAIN)
	_fire = AudioStreamPlayer3D.new()
	_fire.bus = WORLD_BUS
	_fire.stream = load(S + "fire.wav")
	_fire.unit_size = 4.0
	_fire.max_distance = FIRE_R
	_fire.volume_db = DB_FIRE
	add_child(_fire)
	_bird = AudioStreamPlayer3D.new()
	_bird.bus = WORLD_BUS
	_bird.stream = _random(["bird_1", "bird_2", "bird_3"], 1.12, 3.0)
	_bird.unit_size = 12.0
	_bird.volume_db = DB_BIRD
	add_child(_bird)
	for kind: String in ["soft", "gravel", "wood", "splash"]:
		var names: Array[String] = []
		for k in (3 if kind == "wood" or kind == "splash" else 4):
			names.append("step_%s_%d" % [kind, k + 1])
		var p := AudioStreamPlayer.new()
		p.bus = WORLD_BUS
		p.stream = _random(names, 1.1, 2.0)
		p.max_polyphony = 2
		add_child(p)
		_steps[kind] = p
	_land = AudioStreamPlayer.new()
	_land.bus = WORLD_BUS
	_land.stream = _random(["land"], 1.1, 1.0)
	add_child(_land)
	_bottom = AudioStreamPlayer.new()
	_bottom.bus = WORLD_BUS
	_bottom.stream = _random(["fork_bottom"], 1.08, 1.0) # 20.11: свой звук вместо приземления на высокой ноте
	add_child(_bottom)
	_knock = AudioStreamPlayer.new()
	_knock.bus = WORLD_BUS
	_knock.stream = _random(["rim_knock"], 1.12, 2.0)
	_knock.max_polyphony = 2
	add_child(_knock)
	_crash = AudioStreamPlayer.new()
	_crash.bus = WORLD_BUS
	_crash.stream = _random(["crash_impact"], 1.06, 1.0)
	add_child(_crash)
	_pump = AudioStreamPlayer.new()
	_pump.bus = WORLD_BUS
	_pump.stream = _random(["pump_suspension"], 1.06, 0.0)
	add_child(_pump)


func _exit_tree() -> void:
	if _duck_tween != null and _duck_tween.is_valid():
		_duck_tween.kill()
		_duck_tween = null
	var idx := AudioServer.get_bus_index(WORLD_BUS)
	if idx != -1:
		AudioServer.set_bus_volume_db(idx, 0.0)
		if AudioServer.get_bus_effect_count(idx) > 0:
			var lpf := AudioServer.get_bus_effect(idx, 0) as AudioEffectLowPassFilter
			if lpf != null:
				lpf.cutoff_hz = FULL_CUTOFF_HZ
			AudioServer.set_bus_effect_enabled(idx, 0, false)


func _loop(file: String, db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.bus = WORLD_BUS
	p.stream = load(S + file + ".wav")
	p.volume_db = SILENT
	add_child(p)
	_goal[p] = 0.0
	_db[p] = db
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


## На паузе окружение приглушается (-18 дБ и Low-Pass), звуки езды замолкают, чтобы в меню настроек
## оставался живой фон мира и было слышно ползунок громкости
func set_ducked(on: bool, duration := 0.18) -> void:
	var idx := ensure_world_bus()
	_ducked = on
	if _duck_tween != null and _duck_tween.is_valid():
		_duck_tween.kill()
		_duck_tween = null
	for p: AudioStreamPlayer in [_roll, _grit, _tick, _chain, _pump]:
		if p != null:
			p.stream_paused = on
	var lpf := AudioServer.get_bus_effect(idx, 0) as AudioEffectLowPassFilter if AudioServer.get_bus_effect_count(idx) > 0 else null
	var target_db := DUCK_DB if on else 0.0
	var target_hz := DUCK_CUTOFF_HZ if on else FULL_CUTOFF_HZ
	if duration <= 0.0 or not is_inside_tree() or DisplayServer.get_name() == "headless" or AudioServer.get_driver_name() == "Dummy":
		AudioServer.set_bus_volume_db(idx, target_db)
		if lpf != null:
			lpf.cutoff_hz = target_hz
			AudioServer.set_bus_effect_enabled(idx, 0, on)
		return
	if on and lpf != null:
		AudioServer.set_bus_effect_enabled(idx, 0, true)
	var start_db := AudioServer.get_bus_volume_db(idx)
	var start_hz := lpf.cutoff_hz if lpf != null else FULL_CUTOFF_HZ
	_duck_tween = create_tween()
	_duck_tween.set_parallel(true)
	_duck_tween.tween_method(func(v: float) -> void: AudioServer.set_bus_volume_db(idx, v),
		start_db, target_db, duration).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	if lpf != null:
		_duck_tween.tween_method(func(hz: float) -> void: lpf.cutoff_hz = hz,
			start_hz, target_hz, duration).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_duck_tween.set_parallel(false)
	_duck_tween.tween_callback(func() -> void:
		_duck_tween = null
		if not _ducked and lpf != null:
			AudioServer.set_bus_effect_enabled(idx, 0, false))


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


## 12.7: пробой вилки (удар в упор со скоростью impact, м/с) — глухой стук отбойника с коротким металлическим
## отзвуком, тише приземления (20.11: свой звук fork_bottom вместо приземления на высокой ноте)
func bottom_out(impact: float) -> void:
	_bottom.volume_db = DB_LAND - 12.0 + clampf((impact - 0.8) / 2.0, 0.0, 1.0) * 6.0
	_bottom.pitch_scale = 1.0
	_bottom.play()


## 20.11: падение седока — один удар с шорохом скольжения; impact (м/с) — сила удара
func crash(impact: float) -> void:
	_crash.volume_db = DB_LAND - 6.0 + clampf((impact - 4.0) / 8.0, 0.0, 1.0) * 5.0
	_crash.play()


func pump_compression(accel: float) -> void:
	_pump.volume_db = lerpf(-27.0, -23.0, smoothstep(0.6, 1.8, accel))
	_pump.play()


## Удар колеса о кромку (корень, камень, бревно) со скоростью impact, м/с: короткий стук обода и шины, звонче
## у переднего колеса, глуше у заднего (под ним рама и седок); тихие касания не звучат.
func wheel_knock(impact: float, front: bool) -> void:
	if impact < 0.4:
		return
	_knock.volume_db = DB_LAND - 18.0 + clampf(impact / 5.0, 0.0, 1.0) * 12.0
	_knock.pitch_scale = 1.1 if front else 0.88
	_knock.play()


## Приземление с ударом impact (м/с): мягкий удар и шаг по той поверхности, куда пришли ноги
func land(x: float, z: float, feet: float, impact: float) -> void:
	if impact < 2.5:
		return
	var k := clampf((impact - 2.5) / 10.0, 0.0, 1.0)
	_play_step(x, z, feet, DB_STEP + 2.0)
	_land.volume_db = DB_LAND - 12.0 + k * 12.0
	_land.pitch_scale = 1.0
	_land.play()


func bike_placed() -> void:
	_land.volume_db = -14.0
	_land.pitch_scale = 1.0
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
## rolling — колёса на земле, crank — угол педалей (меняется, пока крутят педали),
## braking — резкое торможение на скорости 0..1 (12.7: покрытие хрустит громче и ниже — юз)
func update(pos: Vector3, bike_speed: float, rolling: bool, dt: float, bike_lean := 0.0, crank := 0.0, braking := 0.0) -> void:
	_sample_t -= dt
	if _sample_t <= 0.0:
		_sample_t = SAMPLE
		_sample(pos)
		_sample_rolling(pos)
	var v := absf(bike_speed)
	# Скорость передаётся шинами и касаниями покрытия, без постоянного шума ветра.
	var rush := clampf(v / BikePhysicsConfig.current().cruise_speed, 0.0, 1.3)
	# Покрытие меняет плотность и тембр шин, поворот чуть усиливает их шорох.
	var corner := clampf(absf(bike_lean) / 0.28, 0.0, 1.0)
	var near := Util.damp(8.0, dt)
	_goal[_roll] = clampf(rush * (0.55 + _roll_rough * 0.45 + corner * 0.12), 0.0, 1.0) if rolling else 0.0
	_roll.pitch_scale = lerpf(_roll.pitch_scale, (0.7 + 0.45 * rush) * _roll_pitch, near)
	# Покрытие: песчинки гуще на гравии и камне, реже на земле; на скорости гуще и выше.
	var skid := braking * maxf(_grit_level, 0.5)
	_goal[_grit] = clampf(_grit_level * smoothstep(0.5, 4.0, v) * (0.6 + 0.4 * minf(rush, 1.0)) + skid * 1.6, 0.0, 1.6) if rolling else 0.0
	_grit.pitch_scale = lerpf(_grit.pitch_scale, _grit_pitch * (0.85 + 0.25 * minf(rush, 1.0)) * (1.0 - 0.25 * skid), near)
	# Педали крутят — тихая цепь; накатом — трещотка втулки, её щелчки идут за скоростью колеса.
	if crank != _crank:
		_crank = crank
		_pedal_t = PEDAL_HOLD
	_pedal_t = maxf(0.0, _pedal_t - dt)
	var wheel := smoothstep(0.6, 2.5, v) if bike_speed > 0.0 else 0.0   # назад трещотка молчит
	_goal[_tick] = wheel * (0.0 if _pedal_t > 0.0 else 1.0)
	_tick.pitch_scale = lerpf(_tick.pitch_scale, clampf(v / TICK_SPEED, 0.3, 2.0), near)
	_goal[_chain] = (0.5 + 0.5 * minf(rush, 1.0)) * wheel if _pedal_t > 0.0 else 0.0
	_chain.pitch_scale = lerpf(_chain.pitch_scale, 0.85 + 0.3 * minf(rush, 1.0), near)
	_contact_wait = maxf(0.0, _contact_wait - dt)
	if rolling and v > 1.0:
		_contact_dist += v * dt
		# Доски и брызги — редкие тихие касания на случайном расстоянии; гравий звучит слоем песчинок.
		if _contact_dist >= _contact_next and _contact_wait <= 0.0:
			_contact_dist = 0.0
			_contact_next = randf_range(1.5, 4.0)
			_contact_wait = 0.16
			if _roll_surface == "wood" or _roll_surface == "splash":
				var contact_player: AudioStreamPlayer = _steps[_roll_surface]
				contact_player.volume_db = DB_STEP - 12.0 + minf(rush, 1.0) * 4.0
				contact_player.play()
	else:
		_contact_dist = 0.0
	var a := Util.damp(SMOOTH, dt)
	for p: AudioStreamPlayer in _goal:
		# уровень хранится отдельно: из volume_db тихий звук читался как «молчит» и не мог разгореться.
		# Звуки велосипеда идут за ним сразу (затихают, как только колёса оторвались), фон — плавно.
		var cur := lerpf(_level.get(p, 0.0), _goal[p], a if p == _water or p == _surf else near)
		_level[p] = cur
		# затухание доходит до тишины без скачка громкости вверх в конце
		p.volume_db = maxf(_db[p] + linear_to_db(maxf(cur, 1e-4)), SILENT)
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
	_grit_level = 0.3 if _roll_surface == "soft" else 1.0
	_grit_pitch = 0.7 if _roll_surface == "soft" else 1.0
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
		_grit_level = 0.15
	elif _roll_surface == "splash":
		_roll_rough = 0.8
		_roll_pitch = 0.8
		_grit_level = 0.0


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
	for list: Array in [fires, regional_fires]:
		for fire: Dictionary in list:
			var point: Vector3 = fire.pos
			var distance := Vector2(point.x - pos.x, point.z - pos.z).length_squared()
			if distance < best:
				best = distance
				at = point + Vector3.UP * 0.5
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
