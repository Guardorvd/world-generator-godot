class_name BikeAudioLayer
extends Node
## Handles all bicycle sound layers:
## - 11-surface texture crossfader (the rolling sound itself)
## - Distance-driven wood plank seams and surface micro-grains (density follows speed by itself)
## - Virtual gear shifts
## - Tactile braking (pad friction + loose/firm surface tire scrub/skid)
## - Suspension breathing, pump compression, fork bottom-out, hops, tiered landings, wheel knocks, mount/dismount
## Riding wind and the tread "rush" hiss were removed on 27.11.2026 (they read as wind, the user asked to drop it).
## The shared roll, chain and freewheel loops were removed the same day at the user's request (did not sound good);
## until new recordings exist, rolling is carried by the surface textures and pedaling is silent.

const AudioCfg := preload("res://scripts/audio/game_audio_config.gd")

var _cfg
var _bus: StringName = &"Bike"

var brake_pad_player: AudioStreamPlayer
var skid_loose_player: AudioStreamPlayer
var skid_firm_player: AudioStreamPlayer

var _tex_players := {}        # StringName surface -> AudioStreamPlayer
var _tex_levels := {}         # StringName surface -> float (0..1)
var _grain_players := {}      # StringName kind -> AudioStreamPlayer

var _plank_player: AudioStreamPlayer
var _hop_prep_player: AudioStreamPlayer
var _takeoff_hop_player: AudioStreamPlayer
var _takeoff_crest_player: AudioStreamPlayer
var _land_soft_player: AudioStreamPlayer
var _land_med_player: AudioStreamPlayer
var _land_hard_player: AudioStreamPlayer
var _bump_hit_player: AudioStreamPlayer
var _rim_knock_player: AudioStreamPlayer
var _fork_bottom_player: AudioStreamPlayer
var _susp_player: AudioStreamPlayer
var _pump_player: AudioStreamPlayer
var _gear_player: AudioStreamPlayer
var _mount_player: AudioStreamPlayer
var _dismount_player: AudioStreamPlayer
var _stop_foot_player: AudioStreamPlayer
var _crash_player: AudioStreamPlayer

var _loop_players: Array[AudioStreamPlayer] = []
var _loop_levels := {}        # AudioStreamPlayer -> float

var _crank := 0.0
var _pedal_t := 0.0
var _last_gear_step := -1
var _was_airborne := false
var _physics_driven := false
var _physics_airborne := false
var _debounced_air := false
var _was_hop_prep := false
var _was_stance := BikeRide.Stance.RIDING

var _plank_dist := 0.0
var _plank_next := 0.55
var _grain_dist := 0.0
var _grain_next := 1.4

var _knock_cd := 0.0
var _susp_cd := 0.0
var _gear_cd := 0.0
var _grain_cd := 0.0
var _land_susp_mute := 0.0


func setup(cfg) -> void:
	_cfg = cfg
	_bus = cfg.bike_bus
	var root := String(AudioCfg.SOUNDS_ROOT)

	brake_pad_player = _make_loop(root + "bike/brake_pad.wav")
	skid_loose_player = _make_loop(root + "bike/skid_loose.wav")
	skid_firm_player = _make_loop(root + "bike/skid_firm.wav")

	for surf: StringName in AudioCfg.SURFACES:
		var prof: Dictionary = cfg.profile(surf)
		var rel: String = str(prof.get("texture_file", ""))
		if not rel.is_empty():
			var p := _make_loop(root + rel)
			_tex_players[surf] = p
			_tex_levels[surf] = 0.0

	for gkind: StringName in AudioCfg.GRAIN_KINDS:
		var files := _series(root + "surfaces/grain_%s_%%d.wav" % gkind, 4)
		_grain_players[gkind] = _make_rand(files, 1.08, 2.0, 2)

	_plank_player = _make_rand(_series(root + "surfaces/plank_%d.wav", 4), 1.07, 1.8, 2)
	_hop_prep_player = _make_rand(_series(root + "bike/hop_prep_%d.wav", 2), 1.06, 1.0, 1)
	_takeoff_hop_player = _make_rand(_series(root + "bike/takeoff_hop_%d.wav", 3), 1.06, 1.0, 1)
	_takeoff_crest_player = _make_rand(_series(root + "bike/takeoff_crest_%d.wav", 2), 1.06, 1.0, 1)
	_land_soft_player = _make_rand(_series(root + "impacts/land_soft_%d.wav", 3), 1.06, 1.0, 1)
	_land_med_player = _make_rand(_series(root + "impacts/land_med_%d.wav", 3), 1.05, 1.0, 1)
	_land_hard_player = _make_rand(_series(root + "impacts/land_hard_%d.wav", 3), 1.05, 1.0, 1)
	_bump_hit_player = _make_rand(_series(root + "impacts/bump_hit_%d.wav", 4), 1.08, 1.5, 2)
	_rim_knock_player = _make_rand(_series(root + "impacts/rim_knock_%d.wav", 3), 1.07, 1.2, 2)
	_fork_bottom_player = _make_rand(_series(root + "impacts/fork_bottom_%d.wav", 3), 1.05, 1.0, 1)
	_susp_player = _make_rand(_series(root + "bike/susp_stroke_%d.wav", 4), 1.07, 1.5, 2)
	_pump_player = _make_rand([root + "pump_suspension.wav"], 1.06, 0.8, 1)
	_gear_player = _make_rand(_series(root + "bike/gear_shift_%d.wav", 3), 1.05, 1.0, 1)
	_mount_player = _make_rand(_series(root + "bike/bike_mount_%d.wav", 2), 1.04, 0.8, 1)
	_dismount_player = _make_rand(_series(root + "bike/bike_dismount_%d.wav", 2), 1.04, 0.8, 1)
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
				var lvl: float = float(_loop_levels.get(p, 0.0))
				p.stream_paused = lvl <= 0.0005


func stop() -> void:
	_physics_driven = false
	_physics_airborne = false
	_debounced_air = false
	for p: Node in get_children():
		if p is AudioStreamPlayer:
			(p as AudioStreamPlayer).stop()


## Called at 60 Hz from physics tick before BikeRide clears tick events.
func tick_physics(bike: BikeRide, dt: float) -> void:
	if _cfg == null or bike == null:
		return
	_knock_cd = maxf(0.0, _knock_cd - dt)
	_susp_cd = maxf(0.0, _susp_cd - dt)
	_gear_cd = maxf(0.0, _gear_cd - dt)
	_grain_cd = maxf(0.0, _grain_cd - dt)
	_land_susp_mute = maxf(0.0, _land_susp_mute - dt)

	_physics_driven = true
	if not bike.riding:
		_was_airborne = false
		_physics_airborne = false
		_debounced_air = false
		_was_hop_prep = false
		_was_stance = BikeRide.Stance.RIDING
		_last_gear_step = -1
		return

	# 1. Hop preparation preload
	var prep := bike.hop_preparing and not bike.airborne
	if prep and not _was_hop_prep:
		_hop_prep_player.volume_db = _cfg.db_suspension - 2.0
		_hop_prep_player.play()
	_was_hop_prep = prep

	# 2. Takeoff (bunny hop or confirmed crest launch, debouncing brief micro-detaches)
	var confirmed_air := bike.airborne and (bike.hop_used or (bike.air_time >= 0.06 and bike.air_clearance >= 0.04))
	_physics_airborne = confirmed_air
	_debounced_air = bike.airborne and not confirmed_air
	if confirmed_air and not _was_airborne:
		if bike.hop_used:
			_takeoff_hop_player.volume_db = _cfg.db_takeoff
			_takeoff_hop_player.play()
		elif absf(bike.speed) > 2.5:
			_takeoff_crest_player.volume_db = _cfg.db_takeoff - 3.0
			_takeoff_crest_player.play()
	_was_airborne = confirmed_air

	# 3. Stance: planting foot at stop
	if bike.stance == BikeRide.Stance.FOOT_DOWN and _was_stance != BikeRide.Stance.FOOT_DOWN:
		_stop_foot_player.volume_db = _cfg.db_mount - 3.0
		_stop_foot_player.play()
	_was_stance = bike.stance

	# 4. Virtual gear shift click when pedaling
	var gear_step := roundi(bike.gear * 1.4)
	if _last_gear_step >= 0 and gear_step != _last_gear_step and _pedal_t > 0.0 and not bike.airborne and _gear_cd <= 0.0 and bike.speed > 1.5:
		_gear_cd = _cfg.gear_shift_cooldown_s
		_gear_player.volume_db = _cfg.db_gear_shift
		_gear_player.pitch_scale = 1.04 if gear_step > _last_gear_step else 0.94
		_gear_player.play()
	_last_gear_step = gear_step

	# 5. Soft suspension breathing over terrain undulations/roots (outside landing window)
	if not bike.airborne and _land_susp_mute <= 0.0 and _susp_cd <= 0.0:
		var fv := bike.squash_fv_avg if bike.tick_time > 0.0 else bike.squash_fv
		var rv := bike.squash_rv_avg if bike.tick_time > 0.0 else bike.squash_rv
		var max_sv := maxf(absf(fv), absf(rv))
		var susp_thresh := maxf(_cfg.suspension_speed_threshold, 0.85)
		if max_sv >= susp_thresh:
			_susp_cd = _cfg.suspension_cooldown_s
			var k := clampf((max_sv - susp_thresh) / 2.2, 0.0, 1.0)
			_susp_player.volume_db = _cfg.db_suspension - 6.0 + k * 6.0
			_susp_player.play()


func update_frame(dt: float, speed: float, rolling: bool, riding: bool, airborne: bool,
		surface_id: StringName, rough: float, _lean: float, crank: float,
		brake_pressure: float, skid: float, slip: float, _effort: float) -> void:
	if _cfg == null:
		return
	if _physics_driven and _debounced_air:
		airborne = false
		rolling = riding
	var v := absf(speed)
	var cruise := maxf(BikePhysicsConfig.current().cruise_speed, 1.0)
	var pace := clampf(v / cruise, 0.0, 1.4)
	var prof: Dictionary = _cfg.profile(surface_id)

	var near := Util.damp(_cfg.bike_smooth_rate, dt)
	var air_k := Util.damp(_cfg.air_fade_rate, dt)
	var blend_k := Util.damp(_cfg.surface_blend_rate, dt)
	var ground_rate := near if rolling else air_k

	# 1. Multi-surface texture crossfader (only active textures stay unpaused). Speed shapes level and,
	#    through distance-driven grains below, density; pitch moves only a few percent.
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
		var rate := air_k if not rolling else blend_k
		var cur := lerpf(float(_tex_levels.get(s_id, 0.0)), target, rate)
		if target == 0.0 and cur < 0.01:
			cur = 0.0   # хвост ниже −40 дБ от полной не тянем: при частой смене покрытий не копятся голоса
		_tex_levels[s_id] = cur
		_apply_db(tp, _cfg.db_surface_texture + float(_cfg.profile(s_id).get("texture_db", 0.0)), cur)

	# 2. Distance-driven wood plank seams & surface micro-grains (more metres per second = denser grains)
	if rolling and v > 0.9:
		var ds := v * dt
		if surface_id == &"wood":
			_plank_dist += ds
			if _plank_dist >= _plank_next:
				_plank_dist = 0.0
				_plank_next = randf_range(0.45, 0.82)
				_plank_player.volume_db = _cfg.db_plank - 5.0 + minf(pace, 1.1) * 5.0
				_plank_player.play()
		else:
			_plank_dist = 0.0
		var g_step := float(prof.get("grain_step_m", 0.0))
		if g_step > 0.0 and _grain_players.has(surface_id):
			_grain_dist += ds
			if _grain_dist >= _grain_next and _grain_cd <= 0.0:
				_grain_dist = 0.0
				_grain_next = g_step * randf_range(0.55, 1.65)
				_grain_cd = _cfg.grain_cooldown_s
				var gp: AudioStreamPlayer = _grain_players[surface_id]
				gp.volume_db = _cfg.db_surface_texture - 8.0 + minf(pace, 1.0) * 4.5 + 2.0 * rough
				gp.play()
	else:
		_plank_dist = 0.0
		_grain_dist = 0.0

	# 3. Pedal tracking: no drivetrain loop for now, but gear-shift clicks need to know the rider is pedaling.
	var d_crank := wrapf(crank - _crank, -PI, PI)
	if absf(d_crank) > 0.0005:
		_crank = crank
		_pedal_t = _cfg.pedal_hold_s
	_pedal_t = maxf(0.0, _pedal_t - dt)

	# 4. Braking: velvety caliper pad whisper + loose/firm surface tire shear/skid
	var brake_amt := clampf(brake_pressure, 0.0, 1.0) * smoothstep(0.45, 3.0, v) if rolling else 0.0
	var pad_goal := brake_amt * 0.90
	_set_loop_level(brake_pad_player, pad_goal, near, _cfg.db_brake_pad)
	_set_pitch(brake_pad_player, 0.88 + 0.18 * minf(pace, 1.0), near)

	var corner_slip := smoothstep(0.04, 0.20, absf(slip)) * smoothstep(1.5, 6.0, v) if rolling else 0.0
	var scrub := maxf(brake_amt * float(prof.get("brake_scrub_gain", 0.8)) * (0.35 + 0.75 * skid), corner_slip * 0.78)
	var is_loose := StringName(prof.get("skid_kind", &"loose")) == &"loose"
	var skid_scale := float(prof.get("brake_skid_gain", 0.9))
	var loose_goal := clampf(scrub * skid_scale, 0.0, 1.25) if is_loose else 0.0
	var firm_goal := clampf(scrub * skid_scale, 0.0, 1.15) if not is_loose else 0.0
	var brake_pitch := float(prof.get("brake_pitch", 1.0)) * (0.90 + 0.16 * minf(pace, 1.0))
	_set_loop_level(skid_loose_player, loose_goal, ground_rate, _cfg.db_brake_skid)
	_set_pitch(skid_loose_player, clampf(brake_pitch, 0.80, 1.18), near)
	_set_loop_level(skid_firm_player, firm_goal, ground_rate, _cfg.db_brake_skid - 1.5)
	_set_pitch(skid_firm_player, clampf(brake_pitch, 0.80, 1.18), near)


func play_landing(impact: float, riding: bool) -> void:
	if _cfg == null or impact < _cfg.land_min_impact:
		return
	_land_susp_mute = 0.22
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
	_land_susp_mute = 0.18
	var k := clampf((impact - 0.8) / 2.2, 0.0, 1.0)
	_fork_bottom_player.volume_db = _cfg.db_fork_bottom - 4.0 + k * 5.0
	_fork_bottom_player.play()


func play_pump(accel: float) -> void:
	if _cfg == null:
		return
	_pump_player.volume_db = _cfg.db_suspension - 4.0 + smoothstep(0.6, 1.8, accel) * 4.0
	_pump_player.play()


func play_crash(impact: float) -> void:
	if _cfg == null:
		return
	var k := clampf((impact - 4.0) / 8.0, 0.0, 1.0)
	_crash_player.volume_db = _cfg.db_crash - 4.0 + k * 4.5
	_crash_player.play()


func play_mount(riding: bool) -> void:
	if _cfg == null:
		return
	if riding:
		_mount_player.volume_db = _cfg.db_mount
		_mount_player.play()
	else:
		_dismount_player.volume_db = _cfg.db_mount
		_dismount_player.play()


func play_placed() -> void:
	if _cfg == null:
		return
	_land_soft_player.volume_db = _cfg.db_land - 5.0
	_land_soft_player.play()


func _set_loop_level(player: AudioStreamPlayer, goal: float, rate: float, max_db: float) -> void:
	var cur := lerpf(float(_loop_levels.get(player, 0.0)), goal, rate)
	_loop_levels[player] = cur
	_apply_db(player, max_db, cur)


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
	_loop_levels[p] = 0.0
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
