class_name GameAudioBuses
extends RefCounted
## Creates and manages the structured audio bus hierarchy:
## Master -> World (LPF ducking + safety soft limiter) -> Ambience / Bike / Foley
## Master -> UI (unaffected by pause ducking)
## Master -> Music (soundtrack; volume from the music setting)

const LIM_THRESHOLD_DB := -1.5
const LIM_CEILING_DB := -0.3


static func ensure_layout(cfg) -> int:
	var world_idx := _ensure_bus(cfg.world_bus, &"Master")
	if AudioServer.get_bus_effect_count(world_idx) == 0:
		var lpf := AudioEffectLowPassFilter.new()
		lpf.cutoff_hz = cfg.full_cutoff_hz
		lpf.resonance = 0.5
		AudioServer.add_bus_effect(world_idx, lpf, 0)
		AudioServer.set_bus_effect_enabled(world_idx, 0, false)
	if AudioServer.get_bus_effect_count(world_idx) < 2:
		var limiter := AudioEffectLimiter.new()
		limiter.threshold_db = LIM_THRESHOLD_DB
		limiter.ceiling_db = LIM_CEILING_DB
		limiter.soft_clip_db = 2.0
		limiter.soft_clip_ratio = 8.0
		AudioServer.add_bus_effect(world_idx, limiter, 1)
		AudioServer.set_bus_effect_enabled(world_idx, 1, true)
	_ensure_bus(cfg.ambience_bus, cfg.world_bus)
	var bike_idx := _ensure_bus(cfg.bike_bus, cfg.world_bus)
	if AudioServer.get_bus_effect_count(bike_idx) == 0:
		# Gentle glue compressor on Bike bus prevents harsh stacking during simultaneous bumps/braking.
		var comp := AudioEffectCompressor.new()
		comp.threshold = -14.0
		comp.ratio = 2.5
		comp.attack_us = 12000.0
		comp.release_ms = 140.0
		comp.gain = 0.0
		AudioServer.add_bus_effect(bike_idx, comp, 0)
		AudioServer.set_bus_effect_enabled(bike_idx, 0, true)
	_ensure_bus(cfg.foley_bus, cfg.world_bus)
	_ensure_bus(cfg.ui_bus, &"Master")
	ensure_music_bus(cfg.music_bus)
	return world_idx


## Music goes straight to Master: pause ducking and tunnel filters of World do not touch it.
## Its volume is the player's music setting (GameSettings.apply_volume).
static func ensure_music_bus(bus_name: StringName = &"Music") -> int:
	return _ensure_bus(bus_name, &"Master")


static func _ensure_bus(bus_name: StringName, send_to: StringName) -> int:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx == -1:
		idx = AudioServer.bus_count
		AudioServer.add_bus(idx)
		AudioServer.set_bus_name(idx, bus_name)
	var send_idx := AudioServer.get_bus_index(send_to)
	if send_idx != -1 and idx != 0:
		AudioServer.set_bus_send(idx, send_to)
	return idx


static func reset_world_bus(cfg) -> void:
	var idx := AudioServer.get_bus_index(cfg.world_bus)
	if idx == -1:
		return
	AudioServer.set_bus_volume_db(idx, 0.0)
	if AudioServer.get_bus_effect_count(idx) > 0:
		var lpf := AudioServer.get_bus_effect(idx, 0) as AudioEffectLowPassFilter
		if lpf != null:
			lpf.cutoff_hz = cfg.full_cutoff_hz
		AudioServer.set_bus_effect_enabled(idx, 0, false)
