class_name GameAudioConfig
extends Resource
## Unified configuration for the game audio: bus routing, volume hierarchy, surface acoustics,
## world atmosphere (Type 1 & Type 2), speed curves, transitions, and voice cooldowns.
## 27.11.2026: the user deleted the sounds they did not like (riding loops, dry-surface loops, grains, planks,
## brakes, gear, hop/takeoff, suspension, pump, mount, cloth, brush, rapids, surf, forest/alpine wind, meadow,
## canopy gusts, menu wind, lamp click). Their settings are gone too; add a setting back together with a new sound.

const AUDIO_VERSION := "1.2"
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
@export var db_wind_valley_mist := -28.0
@export var db_night_crickets := -28.5
@export var db_tunnel_hum := -31.0
@export var db_fire := -9.0
@export var db_bird := -7.5
@export var db_owl := -17.0
@export var db_surface_texture := -17.0
@export var db_land := -10.0
@export var db_wheel_knock := -14.0
@export var db_fork_bottom := -12.0
@export var db_crash := -10.0
@export var db_mount := -17.0          # foot planted at a stop (bike/stop_foot_*) plays 3 dB under this
@export var db_step := -15.0
@export var db_water_splash := -14.0

@export_group("Dynamics, Curves & Timing")
@export var environment_sample_s := 0.20
@export var ambience_smooth_rate := 1.6
@export var bike_smooth_rate := 10.0
@export var surface_blend_rate := 3.5
@export var air_fade_rate := 24.0
@export var water_radius_m := 45.0
@export var fire_radius_m := 30.0
@export var bird_delay_range := Vector2(6.5, 16.0)
@export var owl_delay_range := Vector2(18.0, 42.0)
@export var altitude_wind_low_m := 12.0
@export var altitude_wind_high_m := 95.0
@export var daylight_bird_cutoff := 0.25
@export var night_cricket_start := 0.45
@export var tunnel_cutoff_hz := 3200.0
@export var tunnel_volume_db := -1.5
@export var expedition_mist_wind_base := 0.45
@export var expedition_bird_density := 0.72
## Surface loop from speed: level rises from zero, pitch moves only a few percent.
@export var texture_speed_range := Vector2(0.4, 4.5)
@export var texture_pitch_range := Vector2(0.97, 1.07)
@export var wet_moisture_threshold := 0.62

@export_group("Cooldowns & Thresholds")
@export var knock_min_impact := 0.35
@export var knock_cooldown_s := 0.09
@export var splash_cooldown_s := 0.24
@export var land_min_impact := 1.4
@export var land_soft_max := 4.5
@export var land_med_max := 8.5

@export_group("Music")
## Soundtrack (MusicDirector): the user's tracks from music_dir, played like game music, not a playlist.
@export var music_bus := &"Music"
@export var music_dir := "res://resources/sounds/soundtrack"
## Level of a piece at 100 % music volume, under the file's own level (the "100 %" is already softer).
@export var db_music := -7.0
## Seconds of nature-only silence before the first piece after loading a world.
@export var music_first_delay_range := Vector2(25.0, 55.0)
## Seconds of silence between pieces.
@export var music_gap_range := Vector2(90.0, 210.0)
@export var music_fade_in_s := 7.0
@export var music_fade_out_s := 9.0
## Longer pieces fade out after this many seconds instead of playing to the end.
@export var music_max_play_s := 300.0
## How much the pause menu lowers music (dB) and how fast (s).
@export var music_pause_duck_db := -8.0
@export var music_duck_time_s := 0.6

## Per-surface profile.
## - texture_file: riding loop under resources/sounds/ (optional; only shallow water has one now).
##   A surface gets its loop back by adding the file and this key, no code change needed.
## - texture_db: relative loop level offset (dB)
## - step_bank: footstep bank under foley/steps/ (step_<bank>_1..4.wav)
## - step_db: footstep dB offset
@export var surface_profiles: Dictionary = {
	&"packed": {"step_bank": &"packed", "step_db": -0.5},
	&"dirt": {"step_bank": &"dirt", "step_db": 0.0},
	&"forest": {"step_bank": &"forest", "step_db": -0.5},
	&"gravel": {"step_bank": &"gravel", "step_db": 0.5},
	&"grass": {"step_bank": &"grass", "step_db": -1.5},
	&"sand": {"step_bank": &"sand", "step_db": -0.5},
	&"stone": {"step_bank": &"stone", "step_db": 0.0},
	&"wet": {"step_bank": &"wet", "step_db": 0.0},
	&"wood": {"step_bank": &"wood", "step_db": 0.5},
	&"snow": {"step_bank": &"snow", "step_db": -0.5},
	&"water": {
		"texture_file": "surfaces/tex_water.wav",
		"texture_db": 2.0,
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


## True when the sound file is present (raw file in development, imported resource in an export).
static func sound_exists(path: String) -> bool:
	return FileAccess.file_exists(path) or ResourceLoader.exists(path)


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
