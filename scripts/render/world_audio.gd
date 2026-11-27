class_name WorldAudio
extends Node
## Central GameAudioController (Organic Tactile Audio).
## Coordinates GameAudioConfig, GameAudioBuses, AudioSurfaceClassifier,
## BikeAudioLayer, FoleyAudioLayer, and AmbienceAudioLayer without allocating per frame.

const TILE := GameConfig.TILE
const SAMPLE := 0.20
const SMOOTH := 1.6
const SILENT := -80.0
const WATER_R := 45.0
const SEA_R := 140.0
const FIRE_R := 30.0
const DB_STEP := -15.0
const DB_LAND := -10.0

const WORLD_BUS := &"World"
const DUCK_DB := -18.0
const DUCK_CUTOFF_HZ := 900.0
const FULL_CUTOFF_HZ := 16000.0

const AudioCfg := preload("res://scripts/audio/game_audio_config.gd")
const AudioBuses := preload("res://scripts/audio/game_audio_buses.gd")
const SurfaceClassifier := preload("res://scripts/audio/surface_classifier.gd")
const BikeLayer := preload("res://scripts/audio/bike_audio_layer.gd")
const FoleyLayer := preload("res://scripts/audio/foley_audio_layer.gd")
const AmbienceLayer := preload("res://scripts/audio/ambience_audio_layer.gd")
const MusicDirector := preload("res://scripts/audio/music_director.gd")

@export var config: Resource

var world: WorldData
var heights: Heightfield
var fires: Array = []
var regional_fires: Array = []

var bike_layer: BikeLayer
var foley_layer: FoleyLayer
var ambience_layer: AmbienceLayer
var music: MusicDirector   # саундтрек (27.11.2026), появляется с миром в setup

# Compatibility references for tools/sound_check.gd and tools/ui_choreography_test.gd
var _water: AudioStreamPlayer
var _roll: AudioStreamPlayer
var _fire: AudioStreamPlayer3D
var _bird: AudioStreamPlayer3D
var _bottom: AudioStreamPlayer
var _knock: AudioStreamPlayer
var _crash: AudioStreamPlayer
var _goal := {}
var _bird_ok := false
var _sample_t := 0.0

var _surface_id: StringName = &"dirt"
var _legacy_surface := "soft"
var _roll_rough := 0.25
var _brush := 0.0
var _water_depth := 0.0
var _ducked := false
var _duck_tween: Tween
var _world_bus_idx := -1
var _last_tunnel_lpf := -1.0
var _sunlight := 1.0


static func ensure_world_bus() -> int:
	return AudioBuses.ensure_layout(AudioCfg.load_or_default())


func _ready() -> void:
	if config == null:
		config = AudioCfg.load_or_default()
	AudioBuses.ensure_layout(config)

	ambience_layer = AmbienceLayer.new()
	ambience_layer.name = "AmbienceLayer"
	add_child(ambience_layer)
	ambience_layer.setup(config, true)

	bike_layer = BikeLayer.new()
	bike_layer.name = "BikeLayer"
	add_child(bike_layer)
	bike_layer.setup(config)

	foley_layer = FoleyLayer.new()
	foley_layer.name = "FoleyLayer"
	add_child(foley_layer)
	foley_layer.setup(config)

	_water = ambience_layer.water_player
	_fire = ambience_layer.fire_player
	_bird = ambience_layer.bird_player
	# с 27.11.2026 отдельной петли качения нет: звук движения для старых тестов — петля мелкой воды
	_roll = bike_layer._tex_players.get(&"water")
	_bottom = bike_layer._fork_bottom_player
	_knock = bike_layer._rim_knock_player
	_crash = bike_layer._crash_player
	_goal = ambience_layer._goal


func _exit_tree() -> void:
	if _duck_tween != null and _duck_tween.is_valid():
		_duck_tween.kill()
		_duck_tween = null
	if config != null:
		AudioBuses.reset_world_bus(config)


func setup(w: WorldData, h: Heightfield) -> void:
	world = w
	heights = h
	_world_bus_idx = AudioServer.get_bus_index(config.world_bus)
	_last_tunnel_lpf = -1.0
	ambience_layer.start_loops()
	bike_layer.start_loops()
	if music == null:
		music = MusicDirector.new()
		music.name = "Music"
		add_child(music)
		music.setup(config)


func set_paused(on: bool) -> void:
	ambience_layer.set_paused(on)
	bike_layer.set_paused(on)
	foley_layer.set_paused(on)


func set_ducked(on: bool, duration := 0.18) -> void:
	var idx := AudioBuses.ensure_layout(config)
	_ducked = on
	if music != null:
		music.set_ducked(on)
	if _duck_tween != null and _duck_tween.is_valid():
		_duck_tween.kill()
		_duck_tween = null
	bike_layer.set_paused(on)
	foley_layer.set_paused(on)
	var lpf := AudioServer.get_bus_effect(idx, 0) as AudioEffectLowPassFilter if AudioServer.get_bus_effect_count(idx) > 0 else null
	var target_db: float = float(config.duck_db) if on else 0.0
	var target_hz: float = float(config.duck_cutoff_hz) if on else float(config.full_cutoff_hz)
	if duration <= 0.0 or not is_inside_tree() or DisplayServer.get_name() == "headless" or AudioServer.get_driver_name() == "Dummy":
		AudioServer.set_bus_volume_db(idx, target_db)
		if lpf != null:
			lpf.cutoff_hz = target_hz
			AudioServer.set_bus_effect_enabled(idx, 0, on)
		if not on:
			_last_tunnel_lpf = -1.0
		return
	if on and lpf != null:
		AudioServer.set_bus_effect_enabled(idx, 0, true)
	var start_db := AudioServer.get_bus_volume_db(idx)
	var start_hz: float = lpf.cutoff_hz if lpf != null else float(config.full_cutoff_hz)
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
		if not _ducked:
			_last_tunnel_lpf = -1.0
			if lpf != null:
				AudioServer.set_bus_effect_enabled(idx, 0, false))


func tick(player: PlayerState, riding: bool) -> void:
	foley_layer.tick_footsteps(player, riding, _surface_id)


func tick_bike(bike: BikeRide, dt: float) -> void:
	bike_layer.tick_physics(bike, dt)


## 27.11.2026: звуки посадки, спешивания и ткани удалены по просьбе пользователя; вызов оставлен для игры.
func mount_changed(_riding: bool) -> void:
	pass


func bottom_out(impact: float) -> void:
	bike_layer.play_bottom_out(impact)


func crash(impact: float) -> void:
	bike_layer.play_crash(impact)


## 27.11.2026: звук прокачки подвески удалён по просьбе пользователя; вызов оставлен для игры.
func pump_compression(_accel: float) -> void:
	pass


func wheel_knock(impact: float, front: bool) -> void:
	bike_layer.play_wheel_knock(impact, front)


func land(x: float, z: float, feet: float, impact: float, riding := true) -> void:
	if impact < config.land_min_impact:
		return
	var cls: Dictionary = SurfaceClassifier.classify(world, heights, x, z, feet, config)
	if not riding:
		foley_layer.play_step(cls.surface, config.db_step + 1.5, 0.5)
	if cls.surface == &"water":
		foley_layer.update_environment_foley(0.016, maxf(impact, 3.0), true, cls.depth, 0.0, riding)
	bike_layer.play_landing(impact, riding)


func bike_placed() -> void:
	bike_layer.play_placed()


func _surface(x: float, z: float, feet: float) -> String:
	return String(SurfaceClassifier.classify(world, heights, x, z, feet, config).legacy)


func _sample(pos: Vector3) -> void:
	ambience_layer.sample_environment(pos, world, fires, regional_fires, heights, _sunlight)
	_bird_ok = ambience_layer.bird_ok


func _sample_surface(pos: Vector3) -> void:
	var cls: Dictionary = SurfaceClassifier.classify(world, heights, pos.x, pos.z, pos.y, config)
	_surface_id = cls.surface
	_legacy_surface = String(cls.legacy)
	_roll_rough = float(cls.rough)
	_brush = float(cls.brush)
	_water_depth = float(cls.depth)


func update(pos: Vector3, bike_speed: float, rolling: bool, dt: float,
		bike_lean := 0.0, crank := 0.0, braking := 0.0,
		riding := false, airborne := false, skid := 0.0, slip := 0.0, effort := 0.0,
		sunlight := 1.0) -> void:
	if dt <= 0.0:
		return
	_sunlight = clampf(sunlight, 0.0, 1.0)
	var is_riding := riding or rolling or absf(bike_speed) > 0.01
	_sample_t -= dt
	if _sample_t <= 0.0:
		_sample_t = config.environment_sample_s
		_sample(pos)
		_sample_surface(pos)

	var effective_skid := maxf(skid, braking * 0.65)
	bike_layer.update_frame(dt, bike_speed, rolling, is_riding, airborne,
		_surface_id, _roll_rough, bike_lean, crank, braking, effective_skid, slip, effort)

	var move_speed := absf(bike_speed) if is_riding else 0.0
	var on_ground := rolling if is_riding else true
	foley_layer.update_environment_foley(dt, move_speed, on_ground, _water_depth, _brush, is_riding)
	ambience_layer.update_frame(dt, pos)
	_apply_tunnel_acoustics()


func _apply_tunnel_acoustics() -> void:
	if _ducked or _duck_tween != null or config == null:
		return
	if _world_bus_idx < 0:
		_world_bus_idx = AudioServer.get_bus_index(config.world_bus)
	if _world_bus_idx < 0:
		return
	var tunnel := float(ambience_layer.tunnel_mix())
	if absf(tunnel - _last_tunnel_lpf) < 0.015:
		return
	_last_tunnel_lpf = tunnel
	if AudioServer.get_bus_effect_count(_world_bus_idx) > 0:
		var lpf := AudioServer.get_bus_effect(_world_bus_idx, 0) as AudioEffectLowPassFilter
		if lpf != null:
			lpf.cutoff_hz = lerpf(float(config.full_cutoff_hz), float(config.tunnel_cutoff_hz), tunnel)
		AudioServer.set_bus_effect_enabled(_world_bus_idx, 0, tunnel > 0.02)
	AudioServer.set_bus_volume_db(_world_bus_idx, lerpf(0.0, float(config.tunnel_volume_db), tunnel))
