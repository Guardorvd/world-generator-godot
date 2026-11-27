extends SceneTree
## Verifies Organic Tactile Audio v1.1 across BOTH real world generation types:
## - Type 1: mountain_valley (calm water, surfaces, night crickets)
## - Type 2: river_expedition (river water, overcast mist air, day birds)
## 27.11.2026: surf, meadow breeze, alpine/forest wind and rapids were deleted at the user's request.
## Run: godot --headless --path . --script res://tools/audio_world_types_check.gd


func _init() -> void:
	preload("res://tools/watchdog.gd").arm(self, 240)
	_run.call_deferred()


func _run() -> void:
	var ok := true
	ok = await _verify_type1() and ok
	ok = await _verify_type2() and ok
	print("AUDIO_WORLD_TYPES ", "OK" if ok else "FAIL")
	quit(0 if ok else 1)


func _verify_type1() -> bool:
	var t0 := Time.get_ticks_msec()
	var w := WorldGenerator.generate("Север-1234", 128)
	var h := Heightfield.new(w)
	var audio := WorldAudio.new()
	root.add_child(audio)
	audio.setup(w, h)

	var al := audio.ambience_layer
	var surf_seen := {}
	var max_crickets := -80.0

	var p := PlayerState.spawn(w, h)
	var spawn_pos := Vector3(p.x, h.ground_at(p.x, p.z) + 1.0, p.z)

	# Scan diverse real Type 1 tiles (meadow, peak/ridge, coast, forest)
	for step_y in range(4, w.H - 4, 8):
		for step_x in range(4, w.W - 4, 8):
			var px := (step_x + 0.5) * GameConfig.TILE
			var pz := (step_y + 0.5) * GameConfig.TILE
			var py := h.ground_at(px, pz)
			var pos := Vector3(px, py, pz)
			audio._sample_t = 0.0
			audio.update(pos, 7.0, true, 0.25, 0.0, 0.0, 0.0, true, false, 0.0, 0.0, 0.5, 1.0)
			surf_seen[audio._surface_id] = true
		await process_frame

	# Check nocturnal crickets at spawn in Type 1
	audio._sample_t = 0.0
	for _i in 30:
		audio.update(spawn_pos, 0.0, false, 0.1, 0.0, 0.0, 0.0, false, false, 0.0, 0.0, 0.0, 0.05)
		max_crickets = maxf(max_crickets, al.crickets_player.volume_db)

	audio.ambience_layer.stop()
	audio.bike_layer.stop()
	audio.foley_layer.stop()
	audio.free()
	await process_frame

	var pass_ok := surf_seen.size() >= 3 and max_crickets > -60.0
	print("Type 1 (mountain_valley) [%d ms]: surfaces=%s crickets=%.1f -> %s" % [
		Time.get_ticks_msec() - t0, str(surf_seen.keys()), max_crickets, "OK" if pass_ok else "FAIL"])
	return pass_ok


func _verify_type2() -> bool:
	var t0 := Time.get_ticks_msec()
	var w := WorldGenerator.generate("Тест-Эксп", WorldGenerator.START_SIZE, Callable(), Callable(), Callable(),
		WorldTemplate.EXPEDITION_ID, true)
	if w == null:
		print("Type 2 (river_expedition): FAIL WorldGenerator returned null")
		return false
	var h := Heightfield.new(w)
	var audio := WorldAudio.new()
	root.add_child(audio)
	audio.setup(w, h)

	var al := audio.ambience_layer
	var surf_seen := {}
	var max_water := -80.0
	var max_mist := -80.0
	var saw_birds_day := false

	for step_y in range(4, w.H - 4, 8):
		for step_x in range(4, w.W - 4, 6):
			var px := (step_x + 0.5) * GameConfig.TILE
			var pz := (step_y + 0.5) * GameConfig.TILE
			var py := h.ground_at(px, pz)
			var pos := Vector3(px, py, pz)
			audio._sample_t = 0.0
			audio.update(pos, 8.0, true, 0.25, 0.0, 0.0, 0.0, true, false, 0.0, 0.0, 0.5, 1.0)
			surf_seen[audio._surface_id] = true
			max_water = maxf(max_water, al.water_player.volume_db)
			max_mist = maxf(max_mist, al.wind_mist_player.volume_db)
			if al.bird_ok:
				saw_birds_day = true
		await process_frame

	audio.ambience_layer.stop()
	audio.bike_layer.stop()
	audio.foley_layer.stop()
	audio.free()
	await process_frame

	var pass_ok := max_water > -55.0 and max_mist > -50.0 and saw_birds_day and surf_seen.size() >= 2
	print("Type 2 (river_expedition) [%d ms]: surfaces=%s water=%.1f mist=%.1f birds=%s -> %s" % [
		Time.get_ticks_msec() - t0, str(surf_seen.keys()), max_water, max_mist, str(saw_birds_day), "OK" if pass_ok else "FAIL"])
	return pass_ok
