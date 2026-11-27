class_name FoleyAudioLayer
extends Node
## Handles on-foot footsteps (11 surface banks), subtle clothing/gear rustle,
## foliage/grass brush contact, and water-entry splashes.

const AudioCfg := preload("res://scripts/audio/game_audio_config.gd")
const BikeLayer := preload("res://scripts/audio/bike_audio_layer.gd")

var _cfg
var _bus: StringName = &"Foley"

var _step_players := {}       # StringName surface -> AudioStreamPlayer
var _cloth_player: AudioStreamPlayer
var _brush_player: AudioStreamPlayer
var _water_entry_player: AudioStreamPlayer

var _step_phase := 0
var _was_in_water := false
var _splash_cd := 0.0
var _brush_dist := 0.0
var _brush_next := 1.4


func setup(cfg) -> void:
	_cfg = cfg
	_bus = cfg.foley_bus
	var root := String(AudioCfg.SOUNDS_ROOT)
	for surf: StringName in AudioCfg.SURFACES:
		var files := BikeLayer._series(root + "foley/steps/step_%s_%%d.wav" % surf, 4)
		_step_players[surf] = _make_rand(files, 1.07, 1.8, 2)
	_cloth_player = _make_rand(BikeLayer._series(root + "foley/cloth_%d.wav", 4), 1.08, 2.0, 2)
	_brush_player = _make_rand(BikeLayer._series(root + "foley/brush_%d.wav", 4), 1.10, 2.0, 2)
	_water_entry_player = _make_rand(BikeLayer._series(root + "foley/water_entry_%d.wav", 3), 1.08, 1.5, 2)


func set_paused(paused: bool) -> void:
	for p: Node in get_children():
		if p is AudioStreamPlayer:
			p.stream_paused = paused


func stop() -> void:
	for p: Node in get_children():
		if p is AudioStreamPlayer:
			(p as AudioStreamPlayer).stop()


func tick_footsteps(player: PlayerState, riding: bool, surface_id: StringName) -> void:
	if _cfg == null or player == null:
		return
	var phase := floori(player.bob / PI + 0.5)
	if riding or not player.on_ground or player.ground_speed() < 0.8:
		_step_phase = phase
		return
	if phase != _step_phase:
		_step_phase = phase
		var run := clampf((player.ground_speed() - GameConfig.WALK) / GameConfig.WALK, 0.0, 1.0)
		play_step(surface_id, _cfg.db_step + run * 2.8, run)


func update_environment_foley(dt: float, speed: float, on_ground: bool, depth: float, brush: float, riding: bool) -> void:
	if _cfg == null:
		return
	_splash_cd = maxf(0.0, _splash_cd - dt)
	var in_water := on_ground and depth > 0.03
	if in_water and not _was_in_water and speed > 1.2 and _splash_cd <= 0.0:
		_splash_cd = _cfg.splash_cooldown_s
		var k := clampf((speed - 1.2) / 10.0, 0.0, 1.0)
		_water_entry_player.volume_db = _cfg.db_water_splash - 6.0 + k * 6.0
		_water_entry_player.play()
	_was_in_water = in_water

	if on_ground and brush > 0.15 and speed > 1.8:
		_brush_dist += speed * dt
		if _brush_dist >= _brush_next:
			_brush_dist = 0.0
			_brush_next = randf_range(0.75, 2.1) / maxf(brush, 0.3)
			var pace := clampf(speed / (12.0 if riding else 6.0), 0.0, 1.0)
			_brush_player.volume_db = _cfg.db_brush - 7.0 + pace * 5.0 + linear_to_db(brush) * 0.5
			_brush_player.play()
	else:
		_brush_dist = 0.0


func play_step(surface_id: StringName, db: float, run_factor := 0.0) -> void:
	if _cfg == null:
		return
	var bank := StringName(_cfg.profile(surface_id).get("step_bank", &"dirt"))
	var p: AudioStreamPlayer = _step_players.get(bank, _step_players.get(&"dirt"))
	if p == null:
		return
	var db_off := float(_cfg.profile(surface_id).get("step_db", 0.0))
	p.volume_db = db + db_off
	p.pitch_scale = 1.0 + run_factor * 0.04
	p.play()
	if run_factor > 0.25:
		_cloth_player.volume_db = _cfg.db_cloth - 5.0 + run_factor * 4.0
		_cloth_player.play()


func play_cloth(db_offset := 0.0) -> void:
	if _cfg == null or _cloth_player == null:
		return
	_cloth_player.volume_db = _cfg.db_cloth + db_offset
	_cloth_player.play()


func _make_rand(paths: Array[String], pitch_var: float, vol_var_db: float, poly: int) -> AudioStreamPlayer:
	var r := AudioStreamRandomizer.new()
	for path: String in paths:
		var wav := AudioCfg.load_wav(path, false)
		if wav != null:
			r.add_stream(-1, wav)
	r.random_pitch = pitch_var
	r.random_volume_offset_db = vol_var_db
	var p := AudioStreamPlayer.new()
	p.bus = _bus
	p.stream = r
	p.max_polyphony = poly
	add_child(p)
	return p
