extends Control
## Isolated Organic Tactile Audio audition studio & automated scenario verifier.
## Works both interactively (scenes/audio_audition.tscn) and headless (tools/audio_audition.gd).

const AudioCfg := preload("res://scripts/audio/game_audio_config.gd")
const SurfaceClassifier := preload("res://scripts/audio/surface_classifier.gd")

class MockWorld extends WorldData:
	var test_biome := Biomes.FOREST
	var test_surface := RoadSurface.NONE
	var test_moist := 0.25
	var test_river := false

	func tile_info(_x: float, _z: float) -> Dictionary:
		return {
			biome = test_biome,
			path = 3 if test_surface != RoadSurface.NONE else 0,
			surface = test_surface,
			moist = test_moist,
			river = test_river,
		}

class MockHeightfield extends Heightfield:
	var test_depth := 0.0
	var test_deck := -INF
	var test_current := Vector2.ZERO
	var test_ceiling := INF

	func _init(w: WorldData) -> void:
		super()
		world = w

	func ground_at(_x: float, _z: float, _raw := false) -> float:
		return 0.0

	func surface_at(_x: float, _z: float, _feet := -INF) -> float:
		return 0.0

	func depth_at(_x: float, _z: float, _feet := -INF) -> float:
		return test_depth

	func deck_at(_x: float, _z: float, _feet := -INF) -> float:
		return test_deck

	func current_at(_x: float, _z: float) -> Vector2:
		return test_current

	func mock_current_speed() -> float:
		return test_current.length()

	func ceiling_at(_x: float, _z: float, _feet: float) -> float:
		return test_ceiling


var audio: WorldAudio
var mock_world: MockWorld
var mock_heights: MockHeightfield
var cfg

# Live interactive controls state
var current_surface: StringName = &"forest"
var mode := "ride" # "ride" | "walk" | "scenario"
var sim_speed := 8.0
var sim_pedaling := true
var sim_brake := 0.0
var sim_skid := 0.0
var sim_lean := 0.0
var sim_airborne := false
var sim_crank := 0.0
var sim_sunlight := 1.0
var sim_elevation := 4.0
var sim_water_dist := 100.0
var sim_river_flow := 0.0
var sim_tunnel := false
var sim_player: PlayerState
var sim_bike: BikeRide
var scenario_name := ""
var scenario_t := 0.0

var _status_label: Label
var _meter_label: Label
var _speed_slider: HSlider
var _brake_slider: HSlider
var _pedal_check: CheckBox


func _ready() -> void:
	cfg = AudioCfg.load_or_default()
	mock_world = MockWorld.new()
	mock_world.template_id = "mountain_valley"
	mock_world.W = 8
	mock_world.H = 8
	mock_world.N = 64
	mock_world.dist_water.resize(64)
	mock_world.dist_ocean.resize(64)
	mock_world.dist_water.fill(100.0)
	mock_world.dist_ocean.fill(100.0)
	mock_heights = MockHeightfield.new(mock_world)

	audio = WorldAudio.new()
	add_child(audio)
	audio.setup(mock_world, mock_heights)

	sim_player = PlayerState.new()
	sim_bike = BikeRide.new()
	sim_bike.riding = true
	set_surface(&"forest")

	if DisplayServer.get_name() != "headless":
		_build_ui()


func set_surface(surf_id: StringName) -> void:
	current_surface = surf_id
	mock_heights.test_depth = 0.0
	mock_heights.test_deck = -INF
	mock_world.test_moist = 0.25
	mock_world.test_surface = RoadSurface.NONE
	mock_world.test_biome = Biomes.GRASS
	match surf_id:
		&"packed":
			mock_world.test_surface = RoadSurface.PACKED
		&"dirt":
			mock_world.test_surface = RoadSurface.DIRT
		&"forest":
			mock_world.test_surface = RoadSurface.FOREST
			mock_world.test_biome = Biomes.FOREST
		&"gravel":
			mock_world.test_surface = RoadSurface.GRAVEL
		&"grass":
			mock_world.test_biome = Biomes.GRASS
		&"sand":
			mock_world.test_surface = RoadSurface.SAND
			mock_world.test_biome = Biomes.BEACH
		&"stone":
			mock_world.test_surface = RoadSurface.STONE
			mock_world.test_biome = Biomes.ROCK
		&"wet":
			mock_world.test_biome = Biomes.SWAMP
			mock_world.test_moist = 0.85
		&"wood":
			mock_heights.test_deck = 0.5
		&"snow":
			mock_world.test_biome = Biomes.SNOW
		&"water":
			mock_heights.test_depth = 0.15
	audio._sample_t = 0.0
	audio._sample_surface(Vector3(16.0, 0.0, 16.0))


func _process(delta: float) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var dt := clampf(delta, 0.001, 0.05)
	_step_simulation(dt)
	_update_meters()


func _step_simulation(dt: float) -> void:
	if mode == "scenario":
		_step_scenario(dt)
	var rolling := (mode == "ride" or mode == "scenario") and not sim_airborne
	if sim_pedaling and rolling:
		sim_crank = fmod(sim_crank + _crank_rate(sim_speed) * dt, TAU)
	var pos := Vector3(16.0, sim_elevation, 16.0)
	mock_heights.test_current = Vector2(sim_river_flow, 0.0)
	mock_heights.test_ceiling = 3.5 if sim_tunnel else INF
	mock_world.dist_water.fill(sim_water_dist / GameConfig.TILE)
	if mode == "walk":
		sim_player.on_ground = true
		sim_player.vx = sim_speed
		sim_player.vz = 0.0
		sim_player.bob += dt * sim_speed * 1.6
		audio.tick(sim_player, false)
		audio.update(pos, 0.0, false, dt, 0.0, 0.0, 0.0, false, false, 0.0, 0.0, 0.0, sim_sunlight)
	else:
		sim_bike.riding = true
		sim_bike.speed = sim_speed
		sim_bike.air_time = sim_bike.air_time + dt if sim_airborne else 0.0
		sim_bike.air_clearance = 0.3 if sim_airborne else 0.0
		sim_bike.airborne = sim_airborne
		sim_bike.crank = sim_crank
		sim_bike.braking = sim_brake
		sim_bike.brakes.skid = sim_skid
		sim_bike.lean = sim_lean
		audio.tick_bike(sim_bike, dt)
		audio.update(pos, sim_speed, rolling, dt,
			sim_lean, sim_crank, sim_brake, true, sim_airborne, sim_skid, sim_lean * 0.3, 0.8 if sim_pedaling else 0.0, sim_sunlight)


## Темп педалей как в BikeRide: обороты колеса через передачу, на старте — медленный нажим (start_crank).
static func _crank_rate(speed: float) -> float:
	return maxf((speed / 0.34) * 0.4, 2.5)


func _step_scenario(dt: float) -> void:
	scenario_t += dt
	match scenario_name:
		"start_ride":
			# трогание с места и разгон по грунту: тут раньше появлялся гул
			if current_surface != &"dirt":
				set_surface(&"dirt")
			var ph := fmod(scenario_t, 7.0)
			sim_speed = clampf((ph - 1.0) * 2.0, 0.0, 9.0)
			sim_pedaling = ph > 0.8 and ph < 5.5
			sim_brake = 0.0
			sim_skid = 0.0
			sim_airborne = false
		"slow_forest":
			set_surface(&"forest")
			sim_speed = 3.8
			sim_pedaling = true
			sim_brake = 0.0
			sim_skid = 0.0
			sim_airborne = false
		"fast_forest":
			set_surface(&"forest")
			sim_speed = 16.5 + sin(scenario_t * 1.7) * 1.5
			sim_pedaling = false
			sim_brake = 0.0
			sim_lean = sin(scenario_t * 2.1) * 0.22
			sim_airborne = false
			if fmod(scenario_t, 1.4) < dt:
				audio.wheel_knock(1.1, randf() > 0.5)
		"gravel_road":
			set_surface(&"gravel")
			sim_speed = 11.5
			sim_pedaling = true
			sim_brake = 0.0
			sim_skid = 0.0
			sim_airborne = false
		"surface_chain":
			var surfs := AudioCfg.SURFACES
			var idx := int(floor(scenario_t / 2.5)) % surfs.size()
			if surfs[idx] != current_surface:
				set_surface(surfs[idx])
			sim_speed = 9.5
			sim_pedaling = true
			sim_brake = 0.0
			sim_airborne = false
		"hop_series":
			set_surface(&"dirt")
			sim_speed = 11.0
			sim_pedaling = false
			var cyc := fmod(scenario_t, 2.2)
			if cyc < 0.15:
				sim_bike.hop_preparing = true
				sim_airborne = false
			elif cyc < 0.75:
				sim_bike.hop_preparing = false
				sim_bike._hop_used = true
				sim_airborne = true
			else:
				if sim_airborne:
					audio.land(16.0, 16.0, 0.0, 4.8, true)
				sim_airborne = false
				sim_bike._hop_used = false
		"long_brake":
			set_surface(&"gravel")
			var phase := fmod(scenario_t, 4.0)
			if phase < 1.2:
				sim_speed = 15.0
				sim_brake = 0.0
				sim_skid = 0.0
			else:
				sim_speed = maxf(0.0, 15.0 - (phase - 1.2) * 5.2)
				sim_brake = 0.85 if sim_speed > 0.3 else 0.0
				sim_skid = 0.65 if sim_speed > 0.5 else 0.0


func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.10, 0.11, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(scroll)

	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 18)
	scroll.add_child(margin)

	var root_box := VBoxContainer.new()
	root_box.add_theme_constant_override("separation", 12)
	margin.add_child(root_box)

	var title := Label.new()
	title.text = "Organic Tactile Audio — Audition Studio"
	title.add_theme_font_size_override("font_size", 22)
	root_box.add_child(title)

	_status_label = Label.new()
	_status_label.text = "Mode: ride | Surface: forest"
	root_box.add_child(_status_label)

	_meter_label = Label.new()
	_meter_label.add_theme_font_size_override("font_size", 13)
	root_box.add_child(_meter_label)

	var surf_title := Label.new()
	surf_title.text = "Surfaces (11 real materials)"
	root_box.add_child(surf_title)
	var surf_grid := GridContainer.new()
	surf_grid.columns = 6
	root_box.add_child(surf_grid)
	for s: StringName in AudioCfg.SURFACES:
		var b := Button.new()
		b.text = String(s).capitalize()
		b.pressed.connect(func() -> void:
			if mode == "scenario":
				mode = "ride"
			set_surface(s))
		surf_grid.add_child(b)

	var ctrl_box := HBoxContainer.new()
	ctrl_box.add_theme_constant_override("separation", 16)
	root_box.add_child(ctrl_box)

	var ride_btn := Button.new()
	ride_btn.text = "Mode: Bike Ride"
	ride_btn.pressed.connect(func() -> void:
		mode = "ride"
		sim_airborne = false)
	ctrl_box.add_child(ride_btn)

	var walk_btn := Button.new()
	walk_btn.text = "Mode: Footsteps"
	walk_btn.pressed.connect(func() -> void:
		mode = "walk"
		sim_airborne = false
		sim_speed = 4.6)
	ctrl_box.add_child(walk_btn)

	_pedal_check = CheckBox.new()
	_pedal_check.text = "Pedaling (uncheck = Freewheel)"
	_pedal_check.button_pressed = sim_pedaling
	_pedal_check.toggled.connect(func(v: bool) -> void: sim_pedaling = v)
	ctrl_box.add_child(_pedal_check)

	var sp_row := HBoxContainer.new()
	root_box.add_child(sp_row)
	var sp_lbl := Label.new()
	sp_lbl.text = "Speed (m/s): "
	sp_row.add_child(sp_lbl)
	_speed_slider = HSlider.new()
	_speed_slider.min_value = 0.0
	_speed_slider.max_value = 24.0
	_speed_slider.step = 0.5
	_speed_slider.value = sim_speed
	_speed_slider.custom_minimum_size.x = 320
	_speed_slider.value_changed.connect(func(v: float) -> void:
		mode = "ride" if mode == "scenario" else mode
		sim_speed = v)
	sp_row.add_child(_speed_slider)

	var br_row := HBoxContainer.new()
	root_box.add_child(br_row)
	var br_lbl := Label.new()
	br_lbl.text = "Brake / Skid: "
	br_row.add_child(br_lbl)
	_brake_slider = HSlider.new()
	_brake_slider.min_value = 0.0
	_brake_slider.max_value = 1.0
	_brake_slider.step = 0.05
	_brake_slider.value = 0.0
	_brake_slider.custom_minimum_size.x = 320
	_brake_slider.value_changed.connect(func(v: float) -> void:
		sim_brake = v
		sim_skid = maxf(0.0, (v - 0.35) / 0.65))
	br_row.add_child(_brake_slider)

	var sfx_title := Label.new()
	sfx_title.text = "One-Shot Tactile Events"
	root_box.add_child(sfx_title)
	var sfx_grid := GridContainer.new()
	sfx_grid.columns = 5
	root_box.add_child(sfx_grid)
	var triggers := [
		["Bunny Hop Takeoff", func() -> void: audio.bike_layer._takeoff_hop_player.play()],
		["Soft Land (3 m/s)", func() -> void: audio.land(16.0, 16.0, 0.0, 3.0, true)],
		["Med Land (6.5 m/s)", func() -> void: audio.land(16.0, 16.0, 0.0, 6.5, true)],
		["Hard Land (10.5 m/s)", func() -> void: audio.land(16.0, 16.0, 0.0, 10.5, true)],
		["Front Knock", func() -> void: audio.wheel_knock(1.5, true)],
		["Rear Knock", func() -> void: audio.wheel_knock(1.5, false)],
		["Heavy Rim Knock", func() -> void: audio.wheel_knock(3.2, true)],
		["Fork Bottom-Out", func() -> void: audio.bottom_out(2.2)],
		["Pump Compression", func() -> void: audio.pump_compression(1.4)],
		["Gear Shift", func() -> void: audio.bike_layer._gear_player.play()],
		["Mount Bike", func() -> void: audio.mount_changed(true)],
		["Dismount Bike", func() -> void: audio.mount_changed(false)],
		["Crash Impact", func() -> void: audio.crash(9.0)],
		["Footstep (Current)", func() -> void: audio.foley_layer.play_step(current_surface, cfg.db_step, 0.0)],
		["Water Entry", func() -> void: audio.foley_layer._water_entry_player.play()],
	]
	for pair in triggers:
		var b := Button.new()
		b.text = pair[0]
		b.pressed.connect(pair[1])
		sfx_grid.add_child(b)

	var scen_title := Label.new()
	scen_title.text = "Live Scenarios (Section 11)"
	root_box.add_child(scen_title)
	var scen_grid := GridContainer.new()
	scen_grid.columns = 3
	root_box.add_child(scen_grid)
	for pair in [
		["0. Start From Standstill", "start_ride"],
		["1. Slow Forest Ride", "slow_forest"],
		["2. Fast Forest Descent", "fast_forest"],
		["3. Gravel Road", "gravel_road"],
		["4. Sequential Surfaces", "surface_chain"],
		["5. Hop Series", "hop_series"],
		["6. Prolonged Braking", "long_brake"],
	]:
		var b := Button.new()
		b.text = pair[0]
		b.pressed.connect(func() -> void:
			mode = "scenario"
			scenario_name = pair[1]
			scenario_t = 0.0)
		scen_grid.add_child(b)

	var atm_title := Label.new()
	atm_title.text = "Atmosphere & Ecology (v1.1: Type 1 vs Type 2, Day/Night, Rapids, Altitude, Tunnel)"
	root_box.add_child(atm_title)

	var wt_row := HBoxContainer.new()
	wt_row.add_theme_constant_override("separation", 12)
	root_box.add_child(wt_row)
	for pair in [["Type 1: mountain_valley", "mountain_valley"], ["Type 2: river_expedition", "river_expedition"]]:
		var wb := Button.new()
		wb.text = pair[0]
		wb.pressed.connect(func() -> void:
			mock_world.template_id = pair[1]
			mock_world.test_river = (pair[1] == "river_expedition")
			if pair[1] == "river_expedition":
				sim_water_dist = 14.0
				sim_river_flow = 1.7
				set_surface(&"forest")
			else:
				sim_water_dist = 100.0
				sim_river_flow = 0.0
			audio._sample_t = 0.0)
		wt_row.add_child(wb)
	var tun_chk := CheckBox.new()
	tun_chk.text = "Tunnel Enclosed"
	tun_chk.toggled.connect(func(v: bool) -> void:
		sim_tunnel = v
		audio._sample_t = 0.0)
	wt_row.add_child(tun_chk)

	for slider_def in [
		["Sunlight (0=Night .. 1=Day)", 0.0, 1.0, 0.05, sim_sunlight, func(v: float) -> void: sim_sunlight = v; audio._sample_t = 0.0],
		["Elevation (m)", 0.0, 130.0, 2.0, sim_elevation, func(v: float) -> void: sim_elevation = v; audio._sample_t = 0.0],
		["River Flow Speed (m/s)", 0.0, 2.6, 0.1, sim_river_flow, func(v: float) -> void:
			sim_river_flow = v
			sim_water_dist = 12.0 if v > 0.05 else 100.0
			audio._sample_t = 0.0],
	]:
		var row := HBoxContainer.new()
		root_box.add_child(row)
		var lbl := Label.new()
		lbl.text = String(slider_def[0]) + ": "
		row.add_child(lbl)
		var sl := HSlider.new()
		sl.min_value = slider_def[1]
		sl.max_value = slider_def[2]
		sl.step = slider_def[3]
		sl.value = slider_def[4]
		sl.custom_minimum_size.x = 280
		sl.value_changed.connect(slider_def[5])
		row.add_child(sl)


func _update_meters() -> void:
	_status_label.text = "World: %s | Mode: %s (%s) | Surface: %s | Speed: %.1f | Sun: %.2f | Elev: %.0fm | Tunnel: %s" % [
		mock_world.template_id, mode, scenario_name if mode == "scenario" else "-", String(current_surface),
		sim_speed, sim_sunlight, sim_elevation, str(sim_tunnel)]
	var bl := audio.bike_layer
	var al := audio.ambience_layer
	var active_tex := []
	for s: StringName in bl._tex_players:
		var p: AudioStreamPlayer = bl._tex_players[s]
		if not p.stream_paused and p.volume_db > -75.0:
			active_tex.append("%s(%.1fdB)" % [String(s), p.volume_db])
	_meter_label.text = "Roll %.1f | Chain %.1f (x%.2f) | Freewheel %.1f | Tex: %s\nAmbience: Water %.1f | Rapids %.1f | WindF %.1f | WindA %.1f | Mist %.1f | Meadow %.1f | Crickets %.1f | Tunnel %.1f" % [
		bl.roll_player.volume_db, bl.chain_player.volume_db, bl.chain_player.pitch_scale, bl.freewheel_player.volume_db, ", ".join(active_tex),
		al.water_player.volume_db, al.rapids_player.volume_db, al.wind_forest_player.volume_db,
		al.wind_alpine_player.volume_db, al.wind_mist_player.volume_db, al.meadow_player.volume_db,
		al.crickets_player.volume_db, al.tunnel_player.volume_db]


## Headless automated verification of all 9 scenarios from Section 11.
func run_headless_suite() -> bool:
	# Лямбда захватывает локальные переменные по значению: прежний «ok = false» внутри неё не доходил
	# до итога, и сводка всегда печатала OK. Итог держим в словаре (он передаётся по ссылке).
	var result := {ok = true}
	var check := func(cond: bool, msg: String) -> void:
		print(("OK   " if cond else "FAIL ") + msg)
		if not cond:
			result.ok = false

	var bl := audio.bike_layer
	var fl := audio.foley_layer

	# 0. Start from standstill (27.11.2026: the hum on start). The first second rolls under 1.4 m/s:
	#    roll must stay near silent and roll/texture loops must not be pitched down (that is what hummed).
	set_surface(&"dirt")
	var start_roll_max := -80.0
	var start_low_pitch := 9.0
	for i in 60:
		_step_frame_headless(i / 60.0 * 1.4, true, false, 0.0, 0.0, 0.0, 1.0 / 60.0)
		start_roll_max = maxf(start_roll_max, bl.roll_player.volume_db)
		for p: AudioStreamPlayer in [bl.roll_player, bl._tex_players[&"dirt"]]:
			if not p.stream_paused:
				start_low_pitch = minf(start_low_pitch, p.pitch_scale)
	check.call(start_roll_max < -42.0 and start_low_pitch >= 0.95,
		"Scenario 0 (Start from standstill): roll %.1f dB max under 1.4 m/s, lowest roll/texture pitch %.2f" % [start_roll_max, start_low_pitch])
	for i in 180:
		_step_frame_headless(1.4 + i / 180.0 * 6.0, true, false, 0.0, 0.0, 0.0, 1.0 / 60.0)
	var cadence_pitch := clampf(_crank_rate(7.4) / cfg.chain_ref_crank, cfg.chain_pitch_range.x, cfg.chain_pitch_range.y)
	check.call(bl.chain_player.volume_db > -40.0 and absf(bl.chain_player.pitch_scale - cadence_pitch) < 0.08,
		"Scenario 0b (Pedaling at 7.4 m/s): chain %.1f dB, pitch %.2f follows cadence %.2f" % [bl.chain_player.volume_db, bl.chain_player.pitch_scale, cadence_pitch])

	# 1. Slow forest ride
	set_surface(&"forest")
	for i in 120:
		_step_frame_headless(3.8, true, false, 0.0, 0.0, 0.0, 1.0 / 60.0)
	check.call(bl.roll_player.volume_db > -45.0 and bl.roll_player.volume_db < -12.0,
		"Scenario 1 (Slow forest): roll audible and bounded (%.1f dB)" % bl.roll_player.volume_db)
	check.call((bl._tex_players[&"forest"] as AudioStreamPlayer).volume_db > -45.0,
		"Scenario 1 (Slow forest): forest texture active (%.1f dB)" % (bl._tex_players[&"forest"] as AudioStreamPlayer).volume_db)

	# 2. Fast forest descent with bumps & knocks
	for i in 120:
		sim_bike.squash_fv = 1.3 if i % 25 == 0 else 0.1
		if i % 40 == 10:
			audio.wheel_knock(1.4, true)
		_step_frame_headless(17.0, false, false, 0.0, 0.0, 0.18, 1.0 / 60.0)
	sim_bike.squash_fv = 0.0
	check.call(bl.roll_player.volume_db > -30.0 and bl.freewheel_player.volume_db > -40.0 and bl.chain_player.volume_db <= -75.0,
		"Scenario 2 (Fast forest descent): roll (%.1f dB) and freewheel (%.1f dB) active, chain silent (%.1f dB)" % [bl.roll_player.volume_db, bl.freewheel_player.volume_db, bl.chain_player.volume_db])

	# 3. Gravel road
	set_surface(&"gravel")
	for i in 120:
		_step_frame_headless(12.5, true, false, 0.0, 0.0, 0.0, 1.0 / 60.0)
	var gravel_db: float = (bl._tex_players[&"gravel"] as AudioStreamPlayer).volume_db
	check.call(gravel_db > -30.0 and bl.roll_player.pitch_scale >= 0.95 and bl.roll_player.pitch_scale <= 1.1,
		"Scenario 3 (Gravel road): gravel texture %.1f dB, natural pitch %.2f" % [gravel_db, bl.roll_player.pitch_scale])

	# 4. Sequential surface transition continuity (all 11 surfaces)
	var max_jump := 0.0
	var max_unpaused := 0
	var prev_roll := bl.roll_player.volume_db
	for s: StringName in AudioCfg.SURFACES:
		set_surface(s)
		for i in 60:
			_step_frame_headless(9.5, true, false, 0.0, 0.0, 0.0, 1.0 / 60.0)
			var jump := absf(bl.roll_player.volume_db - prev_roll)
			max_jump = maxf(max_jump, jump)
			prev_roll = bl.roll_player.volume_db
			var unpaused := 0
			for sid: StringName in bl._tex_players:
				if not (bl._tex_players[sid] as AudioStreamPlayer).stream_paused:
					unpaused += 1
			max_unpaused = maxi(max_unpaused, unpaused)
	check.call(max_jump < 4.5 and max_unpaused <= 3,
		"Scenario 4 (11-surface transitions): smooth roll (max step %.2f dB), bounded active textures (%d)" % [max_jump, max_unpaused])

	# 5. Series of hops (takeoff -> air -> landing)
	set_surface(&"dirt")
	sim_bike.hop_preparing = true
	_step_frame_headless(11.0, false, false, 0.0, 0.0, 0.0, 1.0 / 60.0)
	sim_bike.hop_preparing = false
	sim_bike._hop_used = true
	for i in 45:
		_step_frame_headless(11.0, false, true, 0.0, 0.0, 0.0, 1.0 / 60.0)
	var air_loud := -80.0
	for p: AudioStreamPlayer in bl._loop_players:
		if p != bl.freewheel_player:
			air_loud = maxf(air_loud, p.volume_db)
	check.call(bl.roll_player.volume_db <= -65.0 and air_loud <= -60.0,
		"Scenario 5 (Hop air phase): roll silenced (%.1f dB), no wind or ground loop in the air (loudest %.1f dB)" % [bl.roll_player.volume_db, air_loud])
	sim_bike._hop_used = false
	_step_frame_headless(11.0, false, false, 0.0, 0.0, 0.0, 1.0 / 60.0)

	# 6. Soft, medium, and hard landings
	audio.land(16.0, 16.0, 0.0, 2.6, true)
	var db_soft := bl._land_soft_player.volume_db
	audio.land(16.0, 16.0, 0.0, 6.2, true)
	var db_med := bl._land_med_player.volume_db
	audio.land(16.0, 16.0, 0.0, 10.8, true)
	var db_hard := bl._land_hard_player.volume_db
	check.call(db_soft < db_med and db_med < db_hard and db_hard <= -2.0,
		"Scenario 6 (3-tier landings): soft %.1f < med %.1f < hard %.1f dB" % [db_soft, db_med, db_hard])

	# 7. Prolonged braking & skid (loose vs firm)
	set_surface(&"gravel")
	for i in 60:
		_step_frame_headless(10.0, false, false, 0.85, 0.70, 0.0, 1.0 / 60.0)
	check.call(bl.brake_pad_player.volume_db > -45.0 and bl.skid_loose_player.volume_db > -35.0 and bl.skid_firm_player.volume_db <= -75.0,
		"Scenario 7a (Gravel braking): pad %.1f, loose skid %.1f, firm %.1f dB" % [bl.brake_pad_player.volume_db, bl.skid_loose_player.volume_db, bl.skid_firm_player.volume_db])
	set_surface(&"packed")
	for i in 60:
		_step_frame_headless(10.0, false, false, 0.85, 0.70, 0.0, 1.0 / 60.0)
	check.call(bl.skid_firm_player.volume_db > -35.0 and bl.skid_loose_player.volume_db <= -75.0,
		"Scenario 7b (Packed braking): firm skid %.1f, loose %.1f dB" % [bl.skid_firm_player.volume_db, bl.skid_loose_player.volume_db])

	# 8. On-foot movement across all 11 surfaces
	var steps_ok := true
	for s: StringName in AudioCfg.SURFACES:
		set_surface(s)
		fl.play_step(s, cfg.db_step, 0.5)
		var sp: AudioStreamPlayer = fl._step_players[s]
		if sp.volume_db > -2.0 or sp.volume_db < -30.0:
			steps_ok = false
	check.call(steps_ok, "Scenario 8 (On-foot steps): all 11 surface step banks valid and level-bounded")

	# 9. Long 60s continuous ride stability & zero node leaks
	var children_before := audio.get_child_count()
	var nan_found := false
	for frame in 3600:
		if frame % 300 == 0:
			set_surface(AudioCfg.SURFACES[(frame / 300) % AudioCfg.SURFACES.size()])
		var sp := 8.0 + 7.0 * sin(frame * 0.015)
		_step_frame_headless(sp, sin(frame * 0.02) > 0.0, false, 0.4 if sp < 4.0 else 0.0, 0.1, 0.1 * sin(frame * 0.03), 1.0 / 60.0)
		if is_nan(bl.roll_player.volume_db) or is_nan(audio.ambience_layer.water_player.volume_db):
			nan_found = true
			break
		if frame % 60 == 59:
			await get_tree().process_frame
	check.call(not nan_found and audio.get_child_count() == children_before,
		"Scenario 9 (60s continuous ride): 0 NaNs, 0 node allocations (children=%d)" % audio.get_child_count())

	# Bonus: Mount / Dismount / Bottom-out / Crash / Bus check
	audio.mount_changed(true)
	audio.mount_changed(false)
	audio.bottom_out(2.0)
	audio.crash(9.0)
	check.call(AudioServer.get_bus_index(cfg.bike_bus) != -1 and AudioServer.get_bus_index(cfg.foley_bus) != -1 and AudioServer.get_bus_index(cfg.world_bus) != -1,
		"Bus hierarchy verified: World, Bike, Foley present")

	# 10. v1.1 Type 1 vs Type 2 Atmosphere & River Rapids
	var al := audio.ambience_layer
	mock_world.template_id = "mountain_valley"
	mock_world.test_river = false
	sim_water_dist = 100.0
	sim_river_flow = 0.0
	sim_elevation = 8.0
	sim_sunlight = 1.0
	sim_tunnel = false
	set_surface(&"grass")
	for i in 120:
		_step_frame_headless(7.5, true, false, 0.0, 0.0, 0.0, 1.0 / 60.0)
	check.call(al.meadow_player.volume_db > -45.0 and al.rapids_player.volume_db <= -75.0,
		"Scenario 10a (Type 1 sunlit meadow): meadow breeze %.1f dB, rapids silent %.1f dB" % [al.meadow_player.volume_db, al.rapids_player.volume_db])

	mock_world.template_id = "river_expedition"
	mock_world.test_river = true
	sim_water_dist = 10.0
	sim_river_flow = 1.85
	sim_elevation = 14.0
	set_surface(&"forest")
	for i in 120:
		_step_frame_headless(7.5, true, false, 0.0, 0.0, 0.0, 1.0 / 60.0)
	check.call(al.rapids_player.volume_db > -35.0 and al.wind_mist_player.volume_db > -46.0 and al.wind_forest_player.volume_db > -52.0,
		"Scenario 10b (Type 2 river_expedition): rapids %.1f dB, mist %.1f dB, forest wind %.1f dB" % [al.rapids_player.volume_db, al.wind_mist_player.volume_db, al.wind_forest_player.volume_db])

	# 11. v1.1 Day vs Night ecology
	check.call(al.bird_ok and al.crickets_player.volume_db <= -70.0,
		"Scenario 11a (Daytime forest): birds allowed (%s), night crickets silent %.1f dB" % [str(al.bird_ok), al.crickets_player.volume_db])
	sim_sunlight = 0.04
	audio._sample_t = 0.0
	for i in 150:
		_step_frame_headless(5.0, false, false, 0.0, 0.0, 0.0, 1.0 / 60.0)
	check.call(not al.bird_ok and al.crickets_player.volume_db > -46.0,
		"Scenario 11b (Nighttime forest): birds silent (%s), night crickets %.1f dB" % [str(not al.bird_ok), al.crickets_player.volume_db])

	# 12. v1.1 Alpine elevation & Tunnel acoustic dampening
	sim_sunlight = 1.0
	mock_world.template_id = "mountain_valley"
	mock_world.test_biome = Biomes.PEAK
	mock_world.test_surface = RoadSurface.NONE
	mock_world.test_river = false
	sim_water_dist = 100.0
	sim_river_flow = 0.0
	sim_elevation = 110.0
	audio._sample_t = 0.0
	for i in 150:
		_step_frame_headless(6.0, true, false, 0.0, 0.0, 0.0, 1.0 / 60.0)
	var ridge_wind := al.wind_alpine_player.volume_db
	sim_tunnel = true
	audio._sample_t = 0.0
	for i in 150:
		_step_frame_headless(6.0, true, false, 0.0, 0.0, 0.0, 1.0 / 60.0)
	var world_idx := AudioServer.get_bus_index(cfg.world_bus)
	var lpf := AudioServer.get_bus_effect(world_idx, 0) as AudioEffectLowPassFilter
	check.call(ridge_wind > -42.0 and al.tunnel_player.volume_db > -48.0 and al.wind_alpine_player.volume_db < ridge_wind - 6.0 and lpf != null and lpf.cutoff_hz < 5000.0,
		"Scenario 12 (Alpine ridge -> Tunnel): ridge %.1f dB -> tunnel hum %.1f dB (wind attenuated to %.1f dB, LPF %.0f Hz)" % [
			ridge_wind, al.tunnel_player.volume_db, al.wind_alpine_player.volume_db, lpf.cutoff_hz if lpf != null else -1.0])

	# Restore & verify tunnel exit acoustics
	sim_tunnel = false
	sim_elevation = 4.0
	sim_sunlight = 1.0
	mock_world.template_id = "mountain_valley"
	audio._sample_t = 0.0
	for i in 180:
		_step_frame_headless(6.0, true, false, 0.0, 0.0, 0.0, 1.0 / 60.0)
	check.call(al.tunnel_player.volume_db <= -60.0 and (lpf == null or lpf.cutoff_hz >= 14500.0),
		"Scenario 12b (Tunnel exit): tunnel hum faded (%.1f dB), LPF restored (%.0f Hz)" % [
			al.tunnel_player.volume_db, lpf.cutoff_hz if lpf != null else -1.0])
	return result.ok


func _step_frame_headless(speed: float, pedaling: bool, airborne: bool, brake: float, skid: float, lean: float, dt: float) -> void:
	if pedaling and not airborne:
		sim_crank = fmod(sim_crank + _crank_rate(speed) * dt, TAU)
	sim_bike.riding = true
	sim_bike.speed = speed
	sim_bike.air_time = sim_bike.air_time + dt if airborne else 0.0
	sim_bike.air_clearance = 0.3 if airborne else 0.0
	sim_bike.airborne = airborne
	sim_bike.crank = sim_crank
	sim_bike.braking = brake
	sim_bike.brakes.skid = skid
	sim_bike.lean = lean
	mock_heights.test_current = Vector2(sim_river_flow, 0.0)
	mock_heights.test_ceiling = 3.5 if sim_tunnel else INF
	mock_world.dist_water.fill(sim_water_dist / GameConfig.TILE)
	audio.tick_bike(sim_bike, dt)
	audio.update(Vector3(16.0, sim_elevation, 16.0), speed, not airborne, dt, lean, sim_crank, brake, true, airborne, skid, lean * 0.3, 0.8 if pedaling else 0.0, sim_sunlight)
