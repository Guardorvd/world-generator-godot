class_name AmbienceAudioLayer
extends Node
## Manages spatial & atmospheric ambience (v1.1) across both mountain_valley (Type 1)
## and river_expedition (Type 2): calm water & roaring river rapids, ocean surf,
## forest/alpine/valley-mist wind, meadow breeze, day birds vs night crickets/owls,
## 3D tree canopy gusts, 3D campfire, and tunnel acoustic enclosure.

const AudioCfg := preload("res://scripts/audio/game_audio_config.gd")

var _cfg
var _bus: StringName = &"Ambience"

var water_player: AudioStreamPlayer
var rapids_player: AudioStreamPlayer
var surf_player: AudioStreamPlayer
var wind_forest_player: AudioStreamPlayer
var wind_alpine_player: AudioStreamPlayer
var wind_mist_player: AudioStreamPlayer
var meadow_player: AudioStreamPlayer
var crickets_player: AudioStreamPlayer
var tunnel_player: AudioStreamPlayer

var fire_player: AudioStreamPlayer3D
var bird_player: AudioStreamPlayer3D
var owl_player: AudioStreamPlayer3D
var gust_player: AudioStreamPlayer3D

var _loop_players: Array[AudioStreamPlayer] = []
var _goal := {}
var _level := {}

var _bird_t := 4.0
var _owl_t := 14.0
var _gust_t := 8.0
var _bird_rate_mul := 1.0
var _tunnel_goal := 0.0
var _tunnel_level := 0.0

var bird_ok := false
var _owl_ok := false
var _gust_ok := false


func setup(cfg, legacy_world_bus := false) -> void:
	_cfg = cfg
	_bus = cfg.world_bus if legacy_world_bus else cfg.ambience_bus
	var root := String(AudioCfg.SOUNDS_ROOT)
	var spatial_bus: StringName = cfg.world_bus if legacy_world_bus else _bus

	water_player = _add_loop(root + "water.wav", cfg.db_water)
	rapids_player = _add_loop(root + "ambience/river_rapids.wav", cfg.db_rapids)
	surf_player = _add_loop(root + "surf.wav", cfg.db_surf)
	wind_forest_player = _add_loop(root + "ambience/wind_forest.wav", cfg.db_wind_forest)
	wind_alpine_player = _add_loop(root + "ambience/wind_alpine.wav", cfg.db_wind_alpine)
	wind_mist_player = _add_loop(root + "ambience/wind_valley_mist.wav", cfg.db_wind_valley_mist)
	meadow_player = _add_loop(root + "ambience/meadow_breeze.wav", cfg.db_meadow_breeze)
	crickets_player = _add_loop(root + "ambience/night_crickets.wav", cfg.db_night_crickets)
	tunnel_player = _add_loop(root + "ambience/tunnel_hum.wav", cfg.db_tunnel_hum)

	fire_player = AudioStreamPlayer3D.new()
	fire_player.bus = spatial_bus
	fire_player.stream = AudioCfg.load_wav(root + "fire.wav", true)
	fire_player.unit_size = 4.0
	fire_player.max_distance = cfg.fire_radius_m
	fire_player.volume_db = cfg.db_fire
	add_child(fire_player)

	bird_player = _make_3d_randomizer(spatial_bus, [
		root + "bird_1.wav", root + "bird_2.wav", root + "bird_3.wav",
		root + "ambience/bird_4.wav", root + "ambience/bird_5.wav", root + "ambience/bird_6.wav",
	], 1.07, 3.0, 12.0, cfg.db_bird)

	owl_player = _make_3d_randomizer(spatial_bus, [
		root + "ambience/owl_1.wav", root + "ambience/owl_2.wav",
	], 1.04, 2.5, 16.0, cfg.db_owl)

	gust_player = _make_3d_randomizer(spatial_bus, [
		root + "ambience/gust_trees_1.wav",
		root + "ambience/gust_trees_2.wav",
		root + "ambience/gust_trees_3.wav",
	], 1.08, 3.0, 14.0, cfg.db_canopy_gust)


func start_loops() -> void:
	for p: AudioStreamPlayer in _loop_players:
		if p != null and p.stream != null:
			p.play(randf() * maxf(p.stream.get_length(), 0.1))


func set_paused(paused: bool) -> void:
	for p: Node in get_children():
		p.stream_paused = paused


func stop() -> void:
	for p: Node in get_children():
		if p.has_method("stop"):
			p.stop()


func tunnel_mix() -> float:
	return _tunnel_level


func sample_environment(pos: Vector3, world: WorldData, fires: Array, regional_fires: Array,
		heights: Heightfield = null, sunlight := 1.0) -> void:
	if _cfg == null or world == null:
		return
	var tile := GameConfig.TILE
	var tx := floori(pos.x / tile)
	var tz := floori(pos.z / tile)
	var water_d := INF
	var sea_d := INF
	if tx >= 0 and tz >= 0 and tx < world.W and tz < world.H:
		var i := tz * world.W + tx
		sea_d = world.dist_ocean[i] * tile
		if world.dist_water[i] < world.dist_ocean[i] - 0.5:
			water_d = world.dist_water[i] * tile
	elif world.outer != null:
		sea_d = _outer_sea(world, tx, tz)

	var info := world.tile_info(pos.x / tile, pos.z / tile)
	var biome: int = info.biome if not info.is_empty() else Biomes.OCEAN
	var b: Dictionary = Biomes.LIST[biome] if biome >= 0 and biome < Biomes.LIST.size() else Biomes.LIST[Biomes.OCEAN]
	var trees := float(b.get("trees", 0.0))
	var wet_water: bool = bool(b.get("water", false))
	var moist := float(info.get("moist", 0.5))
	var sun := clampf(sunlight, 0.0, 1.0)
	var is_expedition := WorldTemplate.has_valley_river(world.template_id) or WorldTemplate.atmosphere_config(world.template_id) != null

	# River proximity & current-driven rapids (smoothly blends calm brook -> fast canyon rapids)
	var water_prox := pow(clampf(1.0 - water_d / float(_cfg.water_radius_m), 0.0, 1.0), 1.5)
	var flow_speed := _sample_river_flow(pos, water_d, heights, is_expedition, bool(info.get("river", false)))
	var rapids_frac := smoothstep(float(_cfg.rapids_min_speed), float(_cfg.rapids_speed_ref), flow_speed)
	_goal[water_player] = water_prox * (1.0 - 0.42 * rapids_frac)
	_goal[rapids_player] = water_prox * rapids_frac
	_goal[surf_player] = pow(clampf(1.0 - sea_d / float(_cfg.sea_radius_m), 0.0, 1.0), 2.0)

	# Tunnel acoustic dampening & room presence
	var in_tunnel := heights != null and is_finite(heights.ceiling_at(pos.x, pos.z, pos.y))
	_tunnel_goal = 1.0 if in_tunnel else 0.0
	_goal[tunnel_player] = _tunnel_goal
	var open_sky := 1.0 - 0.72 * _tunnel_goal

	# Biome & altitude atmospheric air beds (Type 1 sunlit/alpine/open vs Type 2 overcast misty valley)
	var elev_frac := smoothstep(float(_cfg.altitude_wind_low_m), float(_cfg.altitude_wind_high_m), pos.y)
	var alpine_biome := 1.0 if biome in [Biomes.PEAK, Biomes.SNOW, Biomes.TUNDRA] else 0.0
	var dry_or_open := clampf(1.0 - trees * 0.70, 0.15, 1.0)

	_goal[wind_forest_player] = clampf(trees * (0.28 + 0.55 * elev_frac + (0.22 if is_expedition else 0.0)), 0.0, 1.0) \
		* (0.0 if wet_water else 1.0) * open_sky
	_goal[wind_alpine_player] = clampf(maxf(elev_frac * dry_or_open, alpine_biome * 0.72), 0.0, 1.0) \
		* (0.0 if wet_water else 1.0) * (1.0 - 0.80 * _tunnel_goal)

	var mist_base := float(_cfg.expedition_mist_wind_base) * (1.0 - 0.55 * elev_frac) if is_expedition else 0.0
	var mist_damp := clampf(water_prox * 0.45 + smoothstep(0.55, 0.90, moist) * 0.35 + smoothstep(0.65, 0.25, sun) * 0.35, 0.0, 0.85)
	var mist_target := maxf(mist_base, mist_damp)
	if alpine_biome > 0.5 or wet_water:
		mist_target *= 0.25
	_goal[wind_mist_player] = clampf(mist_target, 0.0, 1.0) * open_sky

	var grass_biome := 1.0 if biome in [Biomes.GRASS, Biomes.STEPPE, Biomes.SAVANNA] else 0.0
	_goal[meadow_player] = grass_biome * smoothstep(0.25, 0.75, sun) * clampf(1.0 - trees * 1.2, 0.0, 1.0) \
		* (1.0 - 0.45 * mist_target) * open_sky

	# Day vs night ecology
	var day_bio := smoothstep(float(_cfg.daylight_bird_cutoff), 0.62, sun)
	var night_bio := 1.0 - smoothstep(0.10, float(_cfg.night_cricket_start), sun)
	bird_ok = trees > 0.05 and not wet_water and biome != Biomes.SNOW and day_bio > 0.15 and not in_tunnel
	_bird_rate_mul = float(_cfg.expedition_bird_density) if is_expedition else 1.0
	var temperate_veg := biome in [Biomes.FOREST, Biomes.GRASS, Biomes.SWAMP, Biomes.JUNGLE, Biomes.STEPPE, Biomes.SAVANNA]
	_goal[crickets_player] = (0.78 if is_expedition else 1.0) * (1.0 if temperate_veg else 0.0) * night_bio * open_sky
	_owl_ok = trees > 0.15 and not wet_water and biome != Biomes.SNOW and night_bio > 0.55 and not in_tunnel
	_gust_ok = trees > 0.28 and not wet_water and not in_tunnel

	_update_campfire(pos, fires, regional_fires)


func update_frame(dt: float, pos: Vector3) -> void:
	if _cfg == null:
		return
	var a := Util.damp(_cfg.ambience_smooth_rate, dt)
	_tunnel_level = lerpf(_tunnel_level, _tunnel_goal, a)
	for p: AudioStreamPlayer in _loop_players:
		var cur := lerpf(float(_level.get(p, 0.0)), float(_goal.get(p, 0.0)), a)
		_level[p] = cur
		var max_db := float(p.get_meta(&"max_db", -24.0))
		var target_db := maxf(max_db + linear_to_db(maxf(cur, 1e-4)), float(_cfg.silent_db))
		if absf(target_db - p.volume_db) > 0.05:
			p.volume_db = target_db

	_bird_t -= dt * _bird_rate_mul
	if _bird_t <= 0.0:
		_bird_t = randf_range(_cfg.bird_delay_range.x, _cfg.bird_delay_range.y)
		if bird_ok and not bird_player.playing:
			var ang := randf() * TAU
			var d := randf_range(10.0, 30.0)
			bird_player.position = pos + Vector3(sin(ang) * d, randf_range(4.0, 9.0), cos(ang) * d)
			bird_player.play()

	_owl_t -= dt
	if _owl_t <= 0.0:
		_owl_t = randf_range(_cfg.owl_delay_range.x, _cfg.owl_delay_range.y)
		if _owl_ok and not owl_player.playing:
			var ang := randf() * TAU
			var d := randf_range(16.0, 36.0)
			owl_player.position = pos + Vector3(sin(ang) * d, randf_range(6.0, 12.0), cos(ang) * d)
			owl_player.play()

	_gust_t -= dt
	if _gust_t <= 0.0:
		_gust_t = randf_range(_cfg.canopy_gust_delay_range.x, _cfg.canopy_gust_delay_range.y)
		if _gust_ok and not gust_player.playing:
			var ang := randf() * TAU
			var d := randf_range(8.0, 20.0)
			gust_player.position = pos + Vector3(sin(ang) * d, randf_range(5.0, 11.0), cos(ang) * d)
			gust_player.play()


func goal_of(p: AudioStreamPlayer) -> float:
	return float(_goal.get(p, 0.0))


func level_of(p: AudioStreamPlayer) -> float:
	return float(_level.get(p, 0.0))


func _sample_river_flow(pos: Vector3, water_d: float, heights: Heightfield, is_expedition: bool, on_river_tile: bool) -> float:
	if heights == null or water_d > float(_cfg.water_radius_m):
		return 0.0
	var speed := 0.0
	if heights.has_method("mock_current_speed"):
		speed = float(heights.call("mock_current_speed"))
	else:
		if heights.world == null or heights.world.lake.size() < heights.world.W * heights.world.H:
			return 0.0
		speed = heights.current_at(pos.x, pos.z).length()
		if speed < 0.15 and water_d < float(_cfg.water_radius_m):
			var probe := clampf(water_d + 4.0, 5.0, 18.0)
			for ofs: Vector2 in [Vector2(probe, 0.0), Vector2(-probe, 0.0), Vector2(0.0, probe), Vector2(0.0, -probe)]:
				speed = maxf(speed, heights.current_at(pos.x + ofs.x, pos.z + ofs.y).length())
	if is_expedition and (speed > 0.05 or on_river_tile):
		speed = maxf(speed * float(_cfg.expedition_rapids_boost), 0.35)
	return speed


func _update_campfire(pos: Vector3, fires: Array, regional_fires: Array) -> void:
	var fire_r := float(_cfg.fire_radius_m)
	var best := fire_r * fire_r
	var at := Vector3()
	for list: Array in [fires, regional_fires]:
		for fire: Dictionary in list:
			var point: Vector3 = fire.pos
			var distance := Vector2(point.x - pos.x, point.z - pos.z).length_squared()
			if distance < best:
				best = distance
				at = point + Vector3.UP * 0.5
	if best < fire_r * fire_r:
		fire_player.position = at
		if not fire_player.playing:
			fire_player.play(randf() * maxf(fire_player.stream.get_length(), 0.1))
	elif fire_player.playing:
		fire_player.stop()


func _add_loop(path: String, max_db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.bus = _bus
	p.stream = AudioCfg.load_wav(path, true)
	p.volume_db = _cfg.silent_db
	p.set_meta(&"max_db", max_db)
	add_child(p)
	_loop_players.append(p)
	_goal[p] = 0.0
	return p


func _make_3d_randomizer(bus_name: StringName, paths: Array, pitch: float, vol_var_db: float, unit_m: float, base_db: float) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.bus = bus_name
	var rnd := AudioStreamRandomizer.new()
	for path: String in paths:
		var w := AudioCfg.load_wav(path, false)
		if w != null:
			rnd.add_stream(-1, w)
	rnd.random_pitch = pitch
	rnd.random_volume_offset_db = vol_var_db
	p.stream = rnd
	p.unit_size = unit_m
	p.volume_db = base_db
	add_child(p)
	return p


static func _outer_sea(world: WorldData, tx: int, tz: int) -> float:
	var tile := GameConfig.TILE
	if world.outer.height(tx, tz) < 0.0:
		return 0.0
	for r: float in [3.0, 10.0, 25.0]:
		for k in 12:
			var ang := k * TAU / 12.0
			var i := tx + roundi(cos(ang) * r)
			var j := tz + roundi(sin(ang) * r)
			var sea: bool
			if i >= 0 and j >= 0 and i < world.W and j < world.H:
				sea = world.dist_ocean[j * world.W + i] < 0.5
			else:
				sea = world.outer.has(i, j) and world.outer.height(i, j) < 0.0
			if sea:
				return r * tile
	return INF
