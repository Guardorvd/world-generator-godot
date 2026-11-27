class_name GameAudioConfig
extends Resource
## Unified configuration for the Organic Tactile Audio v1.1 system.
## Single source of truth for bus routing, volume hierarchy, surface acoustics,
## world atmosphere (Type 1 & Type 2), speed/load curves, transitions, and voice cooldowns.

const AUDIO_VERSION := "1.1"
const DEFAULT_PATH := "res://resources/audio/game_audio_config.tres"
const SOUNDS_ROOT := "res://resources/sounds/"

const SURFACES := [
	&"packed",
	&"dirt",
	&"forest",
	&"gravel",
	&"grass",
	&"sand",
	&"stone",
	&"wet",
	&"wood",
	&"snow",
	&"water",
]

@export_group("Bus & Ducking")
@export var world_bus := &"World"
@export var ambience_bus := &"Ambience"
@export var bike_bus := &"Bike"
@export var foley_bus := &"Foley"
@export var ui_bus := &"UI"
@export var duck_db := -18.0
@export var duck_cutoff_hz := 900.0
@export var full_cutoff_hz := 16000.0
@export var silent_db := -80.0

@export_group("Mix Hierarchy (Max dB)")
@export var db_water := -21.0
@export var db_rapids := -18.5
@export var db_surf := -22.0
@export var db_wind_forest := -29.0
@export var db_wind_alpine := -27.5
@export var db_wind_valley_mist := -28.0
@export var db_meadow_breeze := -31.5
@export var db_night_crickets := -28.5
@export var db_tunnel_hum := -31.0
@export var db_fire := -9.0
@export var db_bird := -7.5
@export var db_owl := -17.0
@export var db_canopy_gust := -19.5
@export var db_wind := -28.0
@export var db_roll := -19.0
@export var db_surface_texture := -17.0
@export var db_tire_rush := -25.0
@export var db_freewheel := -23.0
@export var db_chain := -24.0
@export var db_brake_pad := -25.0
@export var db_brake_skid := -17.0
@export var db_suspension := -22.0
@export var db_land := -10.0
@export var db_wheel_knock := -14.0
@export var db_fork_bottom := -12.0
@export var db_crash := -10.0
@export var db_takeoff := -16.0
@export var db_gear_shift := -22.0
@export var db_mount := -17.0
@export var db_step := -15.0
@export var db_cloth := -26.0
@export var db_brush := -23.0
@export var db_plank := -19.0
@export var db_water_splash := -14.0

@export_group("Dynamics, Curves & Timing")
@export var environment_sample_s := 0.20
@export var ambience_smooth_rate := 1.6
@export var bike_smooth_rate := 10.0
@export var surface_blend_rate := 7.5
@export var air_fade_rate := 24.0
@export var water_radius_m := 45.0
@export var sea_radius_m := 140.0
@export var fire_radius_m := 30.0
@export var bird_delay_range := Vector2(6.5, 16.0)
@export var owl_delay_range := Vector2(18.0, 42.0)
@export var canopy_gust_delay_range := Vector2(9.0, 22.0)
@export var rapids_min_speed := 0.25
@export var rapids_speed_ref := 1.85
@export var altitude_wind_low_m := 12.0
@export var altitude_wind_high_m := 95.0
@export var daylight_bird_cutoff := 0.25
@export var night_cricket_start := 0.45
@export var tunnel_cutoff_hz := 3200.0
@export var tunnel_volume_db := -1.5
@export var expedition_rapids_boost := 1.28
@export var expedition_mist_wind_base := 0.45
@export var expedition_bird_density := 0.72
@export var freewheel_ref_speed := 7.0
@export var pedal_hold_s := 0.28
@export var wind_start_speed := 6.5
@export var wind_full_speed := 21.0
@export var wet_moisture_threshold := 0.62

@export_group("Cooldowns & Thresholds")
@export var suspension_speed_threshold := 0.48
@export var suspension_cooldown_s := 0.19
@export var knock_min_impact := 0.35
@export var knock_cooldown_s := 0.09
@export var gear_shift_cooldown_s := 0.65
@export var splash_cooldown_s := 0.24
@export var grain_cooldown_s := 0.14
@export var land_min_impact := 1.4
@export var land_soft_max := 4.5
@export var land_med_max := 8.5

## Per-surface tactile acoustic profile.
## - roll_gain / roll_pitch: tire carcass rumble weight and subtle pitch warmth
## - texture_file: seamless loop under surfaces/ (empty if purely subtle roll + impacts)
## - texture_db: relative texture level offset (dB)
## - texture_pitch_base / texture_pitch_speed: gentle pitch scaling (kept narrow for natural tone)
## - rush_gain: high-mid tire tread air hiss at speed
## - brake_scrub_gain / brake_skid_gain / brake_pitch: braking & slip character
## - skid_kind: "loose" (pebbles/earth/snow) or "firm" (rubber shear on packed/stone/wood)
## - grain_step_m: average distance between subtle organic micro-grains (0 = none)
## - step_bank: directory/prefix under foley/steps/
## - step_db: footstep dB offset
@export var surface_profiles: Dictionary = {
	&"packed": {
		"roll_gain": 0.85,
		"roll_pitch": 0.96,
		"texture_file": "surfaces/tex_packed.wav",
		"texture_db": -3.5,
		"texture_pitch_base": 0.94,
		"texture_pitch_speed": 0.14,
		"rush_gain": 0.85,
		"brake_scrub_gain": 0.75,
		"brake_skid_gain": 0.65,
		"brake_pitch": 1.05,
		"skid_kind": &"firm",
		"grain_step_m": 0.0,
		"step_bank": &"packed",
		"step_db": -0.5,
	},
	&"dirt": {
		"roll_gain": 0.92,
		"roll_pitch": 0.94,
		"texture_file": "surfaces/tex_dirt.wav",
		"texture_db": -1.0,
		"texture_pitch_base": 0.92,
		"texture_pitch_speed": 0.16,
		"rush_gain": 0.65,
		"brake_scrub_gain": 0.90,
		"brake_skid_gain": 0.95,
		"brake_pitch": 0.98,
		"skid_kind": &"loose",
		"grain_step_m": 2.4,
		"step_bank": &"dirt",
		"step_db": 0.0,
	},
	&"forest": {
		"roll_gain": 0.82,
		"roll_pitch": 0.86,
		"texture_file": "surfaces/tex_forest.wav",
		"texture_db": -0.5,
		"texture_pitch_base": 0.92,
		"texture_pitch_speed": 0.15,
		"rush_gain": 0.35,
		"brake_scrub_gain": 0.80,
		"brake_skid_gain": 0.85,
		"brake_pitch": 0.92,
		"skid_kind": &"loose",
		"grain_step_m": 1.8,
		"step_bank": &"forest",
		"step_db": -0.5,
	},
	&"gravel": {
		"roll_gain": 1.00,
		"roll_pitch": 1.02,
		"texture_file": "surfaces/tex_gravel.wav",
		"texture_db": 1.5,
		"texture_pitch_base": 0.92,
		"texture_pitch_speed": 0.18,
		"rush_gain": 0.60,
		"brake_scrub_gain": 1.00,
		"brake_skid_gain": 1.25,
		"brake_pitch": 1.02,
		"skid_kind": &"loose",
		"grain_step_m": 0.85,
		"step_bank": &"gravel",
		"step_db": 0.5,
	},
	&"grass": {
		"roll_gain": 0.68,
		"roll_pitch": 0.84,
		"texture_file": "surfaces/tex_grass.wav",
		"texture_db": -0.5,
		"texture_pitch_base": 0.94,
		"texture_pitch_speed": 0.14,
		"rush_gain": 0.25,
		"brake_scrub_gain": 0.65,
		"brake_skid_gain": 0.70,
		"brake_pitch": 0.90,
		"skid_kind": &"loose",
		"grain_step_m": 0.0,
		"step_bank": &"grass",
		"step_db": -1.5,
	},
	&"sand": {
		"roll_gain": 0.75,
		"roll_pitch": 0.82,
		"texture_file": "surfaces/tex_sand.wav",
		"texture_db": 0.5,
		"texture_pitch_base": 0.94,
		"texture_pitch_speed": 0.12,
		"rush_gain": 0.30,
		"brake_scrub_gain": 0.95,
		"brake_skid_gain": 1.15,
		"brake_pitch": 0.94,
		"skid_kind": &"loose",
		"grain_step_m": 0.0,
		"step_bank": &"sand",
		"step_db": -0.5,
	},
	&"stone": {
		"roll_gain": 1.05,
		"roll_pitch": 1.08,
		"texture_file": "surfaces/tex_stone.wav",
		"texture_db": -0.5,
		"texture_pitch_base": 0.95,
		"texture_pitch_speed": 0.15,
		"rush_gain": 0.95,
		"brake_scrub_gain": 0.85,
		"brake_skid_gain": 0.85,
		"brake_pitch": 1.10,
		"skid_kind": &"firm",
		"grain_step_m": 1.2,
		"step_bank": &"stone",
		"step_db": 0.0,
	},
	&"wet": {
		"roll_gain": 0.78,
		"roll_pitch": 0.86,
		"texture_file": "surfaces/tex_wet.wav",
		"texture_db": 0.0,
		"texture_pitch_base": 0.92,
		"texture_pitch_speed": 0.14,
		"rush_gain": 0.45,
		"brake_scrub_gain": 0.85,
		"brake_skid_gain": 0.95,
		"brake_pitch": 0.88,
		"skid_kind": &"loose",
		"grain_step_m": 2.2,
		"step_bank": &"wet",
		"step_db": 0.0,
	},
	&"wood": {
		"roll_gain": 0.72,
		"roll_pitch": 0.90,
		"texture_file": "surfaces/tex_wood.wav",
		"texture_db": -2.5,
		"texture_pitch_base": 0.95,
		"texture_pitch_speed": 0.12,
		"rush_gain": 0.55,
		"brake_scrub_gain": 0.70,
		"brake_skid_gain": 0.70,
		"brake_pitch": 0.96,
		"skid_kind": &"firm",
		"grain_step_m": 0.0,
		"step_bank": &"wood",
		"step_db": 0.5,
	},
	&"snow": {
		"roll_gain": 0.62,
		"roll_pitch": 0.80,
		"texture_file": "surfaces/tex_snow.wav",
		"texture_db": 1.0,
		"texture_pitch_base": 0.94,
		"texture_pitch_speed": 0.12,
		"rush_gain": 0.20,
		"brake_scrub_gain": 0.90,
		"brake_skid_gain": 1.05,
		"brake_pitch": 0.95,
		"skid_kind": &"loose",
		"grain_step_m": 0.0,
		"step_bank": &"snow",
		"step_db": -0.5,
	},
	&"water": {
		"roll_gain": 0.50,
		"roll_pitch": 0.82,
		"texture_file": "surfaces/tex_water.wav",
		"texture_db": 2.0,
		"texture_pitch_base": 0.92,
		"texture_pitch_speed": 0.18,
		"rush_gain": 0.25,
		"brake_scrub_gain": 0.75,
		"brake_skid_gain": 1.00,
		"brake_pitch": 0.95,
		"skid_kind": &"loose",
		"grain_step_m": 0.0,
		"step_bank": &"water",
		"step_db": 1.0,
	},
}


func profile(surface_id: StringName) -> Dictionary:
	return surface_profiles.get(surface_id, surface_profiles[&"dirt"])


static func load_or_default():
	if ResourceLoader.exists(DEFAULT_PATH):
		var cfg := load(DEFAULT_PATH)
		if cfg != null and cfg.has_method("profile"):
			return cfg
	return load("res://scripts/audio/game_audio_config.gd").new()


static func load_wav(path: String, looped := false) -> AudioStreamWAV:
	var stream: AudioStreamWAV = null
	if not OS.has_feature("template") and FileAccess.file_exists(path):
		stream = AudioStreamWAV.load_from_file(path)
	if stream == null and ResourceLoader.exists(path):
		stream = load(path) as AudioStreamWAV
	if stream != null and looped and stream.loop_mode == AudioStreamWAV.LOOP_DISABLED:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		stream.loop_begin = 0
		stream.loop_end = roundi(stream.get_length() * stream.mix_rate)
	return stream
