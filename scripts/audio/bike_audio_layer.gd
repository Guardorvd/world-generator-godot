class_name BikeAudioLayer
extends Node
## Bicycle sounds that remain after the 27.11.2026 clean-up (the user deleted the sounds they did not like):
## - surface loops (only those whose file exists; now just shallow water)
## - tiered landings, wheel knocks over bumps, fork bottom-out, crash, foot planted at a stop
## Removed on request: riding wind, tread rush, roll, chain, freewheel, dry-surface loops, grains, deck planks,
## brake pad and skid, gear shift, hop preparation and takeoff, suspension strokes, pump, mount/dismount.
## Surface loops are created from GameAudioConfig.surface_profiles "texture_file" only when the file is present,
## so adding a new recording there brings that surface back without code changes.

const AudioCfg := preload("res://scripts/audio/game_audio_config.gd")

var _cfg
var _bus: StringName = &"Bike"

var _tex_players := {}        # StringName surface -> AudioStreamPlayer
var _tex_levels := {}         # StringName surface -> float (0..1)

var _land_soft_player: AudioStreamPlayer
var _land_med_player: AudioStreamPlayer
var _land_hard_player: AudioStreamPlayer
var _bump_hit_player: AudioStreamPlayer
var _rim_knock_player: AudioStreamPlayer
var _fork_bottom_player: AudioStreamPlayer
var _stop_foot_player: AudioStreamPlayer
var _crash_player: AudioStreamPlayer

var _loop_players: Array[AudioStreamPlayer] = []

var _physics_driven := false
var _debounced_air := false
var _was_stance := BikeRide.Stance.RIDING
var _knock_cd := 0.0


func setup(cfg) -> void:
	_cfg = cfg
	_bus = cfg.bike_bus
	var root := String(AudioCfg.SOUNDS_ROOT)

	for surf: StringName in AudioCfg.SURFACES:
		var rel: String = str(cfg.profile(surf).get("texture_file", ""))
		if not rel.is_empty() and AudioCfg.sound_exists(root + rel):
			var p := _make_loop(root + rel)
			_tex_players[surf] = p
			_tex_levels[surf] = 0.0

	_land_soft_player = _make_rand(_series(root + "impacts/land_soft_%d.wav", 3), 1.06, 1.0, 1)
	_land_med_player = _make_rand(_series(root + "impacts/land_med_%d.wav", 3), 1.05, 1.0, 1)
	_land_hard_player = _make_rand(_series(root + "impacts/land_hard_%d.wav", 3), 1.05, 1.0, 1)
	_bump_hit_player = _make_rand(_series(root + "impacts/bump_hit_%d.wav", 4), 1.08, 1.5, 2)
	_rim_knock_player = _make_rand(_series(root + "impacts/rim_knock_%d.wav", 3), 1.07, 1.2, 2)
	_fork_bottom_player = _make_rand(_series(root + "impacts/fork_bottom_%d.wav", 3), 1.05, 1.0, 1)
	_stop_foot_player = _make_rand(_series(root + "bike/stop_foot_%d.wav", 2), 1.06, 1.0, 1)
	_crash_player = _make_rand(_series(root + "impacts/crash_%d.wav", 2), 1.05, 1.0, 1)


func start_loops() -> void:
	for p: AudioStreamPlayer in _loop_players:
		if p.stream != null and not p.playing:
			p.play(randf() * maxf(p.stream.get_length(), 0.1))
		p.stream_paused = true


func set_paused(paused: bool) -> void:
	for p: Node in get_children():
		if p is AudioStreamPlayer:
			if paused:
				p.stream_paused = true
			elif not (p in _loop_players):
				p.stream_paused = false
			else:
				p.stream_paused = _level_of(p) <= 0.0005


func stop() -> void:
	_physics_driven = false
	_debounced_air = false
	for p: Node in get_children():
		if p is AudioStreamPlayer:
			(p as AudioStreamPlayer).stop()


## Called at 60 Hz from physics tick before BikeRide clears tick events.
func tick_physics(bike: BikeRide, dt: float) -> void:
	if _cfg == null or bike == null:
		return
	_knock_cd = maxf(0.0, _knock_cd - dt)
	_physics_driven = true
	if not bike.riding:
		_debounced_air = false
		_was_stance = BikeRide.Stance.RIDING
		return
	# Brief micro-detaches over bumps are not real flights: keep the ground loop rolling through them.
	var confirmed_air := bike.airborne and (bike.hop_used or (bike.air_time >= 0.06 and bike.air_clearance >= 0.04))
	_debounced_air = bike.airborne and not confirmed_air
	# Planting a foot at a stop
	if bike.stance == BikeRide.Stance.FOOT_DOWN and _was_stance != BikeRide.Stance.FOOT_DOWN:
		_stop_foot_player.volume_db = _cfg.db_mount - 3.0
		_stop_foot_player.play()
	_was_stance = bike.stance


## The argument list stays as the game calls it; values for removed layers are ignored.
func update_frame(dt: float, speed: float, rolling: bool, riding: bool, _airborne: bool,
		surface_id: StringName, _rough: float, _lean: float, _crank: float,
		brake_pressure: float, skid: float, _slip: float, _effort: float) -> void:
	if _cfg == null:
		return
	if _physics_driven and _debounced_air:
		rolling = riding
	var v := absf(speed)
	var cruise := maxf(BikePhysicsConfig.current().cruise_speed, 1.0)
	var pace := clampf(v / cruise, 0.0, 1.4)
	var near := Util.damp(_cfg.bike_smooth_rate, dt)
	var air_k := Util.damp(_cfg.air_fade_rate, dt)
	var blend_k := Util.damp(_cfg.surface_blend_rate, dt)

	# Surface loop crossfader (only the active one stays unpaused). Speed shapes level; pitch moves a few percent.
	var tex_pitch := lerpf(_cfg.texture_pitch_range.x, _cfg.texture_pitch_range.y, clampf(pace, 0.0, 1.15) / 1.15)
	var brake_boost := clampf(brake_pressure * 0.35 + skid * 0.65, 0.0, 1.0)
	var tex_k := smoothstep(_cfg.texture_speed_range.x, _cfg.texture_speed_range.y, v)
	for s_id: StringName in _tex_players:
		var tp: AudioStreamPlayer = _tex_players[s_id]
		var target := 0.0
		if rolling and s_id == surface_id:
			target = clampf(tex_k * (0.55 + 0.45 * minf(pace, 1.15)) + brake_boost * 0.3, 0.0, 1.2)
		if float(_tex_levels.get(s_id, 0.0)) > 0.0005:
			_set_pitch(tp, tex_pitch, near)
		var cur := lerpf(float(_tex_levels.get(s_id, 0.0)), target, blend_k if rolling else air_k)
		if target == 0.0 and cur < 0.01:
			cur = 0.0   # хвост ниже −40 дБ от полной не тянем: при частой смене покрытий не копятся голоса
		_tex_levels[s_id] = cur
		_apply_db(tp, _cfg.db_surface_texture + float(_cfg.profile(s_id).get("texture_db", 0.0)), cur)


func play_landing(impact: float, riding: bool) -> void:
	if _cfg == null or impact < _cfg.land_min_impact:
		return
	if impact < _cfg.land_soft_max:
		var k := clampf((impact - _cfg.land_min_impact) / maxf(_cfg.land_soft_max - _cfg.land_min_impact, 0.1), 0.0, 1.0)
		_land_soft_player.volume_db = _cfg.db_land - 9.0 + k * 5.0 - (0.0 if riding else 3.0)
		_land_soft_player.play()
	elif impact < _cfg.land_med_max:
		var k := clampf((impact - _cfg.land_soft_max) / maxf(_cfg.land_med_max - _cfg.land_soft_max, 0.1), 0.0, 1.0)
		_land_med_player.volume_db = _cfg.db_land - 4.0 + k * 4.0 - (0.0 if riding else 2.5)
		_land_med_player.play()
	else:
		var k := clampf((impact - _cfg.land_med_max) / 4.5, 0.0, 1.0)
		_land_hard_player.volume_db = _cfg.db_land - 0.5 + k * 1.5
		_land_hard_player.play()


func play_wheel_knock(impact: float, front: bool) -> void:
	if _cfg == null or impact < _cfg.knock_min_impact or _knock_cd > 0.0:
		return
	_knock_cd = _cfg.knock_cooldown_s
	var heavy := impact >= 1.4
	var player := _rim_knock_player if heavy else _bump_hit_player
	var k := clampf((impact - _cfg.knock_min_impact) / 4.2, 0.0, 1.0)
	player.volume_db = _cfg.db_wheel_knock - 8.0 + k * 9.0
	player.pitch_scale = (1.06 if front else 0.90) * randf_range(0.96, 1.04)
	player.play()


func play_bottom_out(impact: float) -> void:
	if _cfg == null:
		return
	var k := clampf((impact - 0.8) / 2.2, 0.0, 1.0)
	_fork_bottom_player.volume_db = _cfg.db_fork_bottom - 4.0 + k * 5.0
	_fork_bottom_player.play()


func play_crash(impact: float) -> void:
	if _cfg == null:
		return
	var k := clampf((impact - 4.0) / 8.0, 0.0, 1.0)
	_crash_player.volume_db = _cfg.db_crash - 4.0 + k * 4.5
	_crash_player.play()


func play_placed() -> void:
	if _cfg == null:
		return
	_land_soft_player.volume_db = _cfg.db_land - 5.0
	_land_soft_player.play()


func _level_of(p: AudioStreamPlayer) -> float:
	for s_id: StringName in _tex_players:
		if _tex_players[s_id] == p:
			return float(_tex_levels.get(s_id, 0.0))
	return 0.0


func _set_pitch(player: AudioStreamPlayer, target: float, rate: float) -> void:
	if player.stream_paused:
		return
	var next := lerpf(player.pitch_scale, target, rate)
	if absf(next - player.pitch_scale) > 0.002:
		player.pitch_scale = next


func _apply_db(player: AudioStreamPlayer, max_db: float, level: float) -> void:
	if level <= 0.0005:
		if absf(player.volume_db - _cfg.silent_db) > 0.05:
			player.volume_db = _cfg.silent_db
		if player.playing and not player.stream_paused:
			player.stream_paused = true
		return
	if player.stream != null:
		if not player.playing:
			player.play(randf() * maxf(player.stream.get_length(), 0.1))
		if player.stream_paused:
			player.stream_paused = false
	var target_db := maxf(max_db + linear_to_db(level), _cfg.silent_db)
	if absf(target_db - player.volume_db) > 0.05:
		player.volume_db = target_db


func _make_loop(path: String) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.bus = _bus
	p.stream = AudioCfg.load_wav(path, true)
	p.volume_db = _cfg.silent_db
	add_child(p)
	_loop_players.append(p)
	return p


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


static func _series(pattern: String, count: int) -> Array[String]:
	var out: Array[String] = []
	for i in count:
		out.append(pattern % (i + 1))
	return out
