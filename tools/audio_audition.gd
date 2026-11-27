extends SceneTree
## Isolated Organic Tactile Audio verification & interactive audition launcher.
## Headless check:   godot --headless --path . --script res://tools/audio_audition.gd
## Interactive UI:   godot --path . res://scenes/audio_audition.tscn

const PanelScript := preload("res://scripts/audio/audio_audition_panel.gd")


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	_run.call_deferred()


func _run() -> void:
	var panel := PanelScript.new()
	root.add_child(panel)
	await process_frame
	if DisplayServer.get_name() == "headless":
		var ok: bool = await panel.run_headless_suite()
		panel.audio.ambience_layer.stop()
		panel.audio.bike_layer.stop()
		panel.audio.foley_layer.stop()
		panel.queue_free()
		await process_frame
		print("AUDIO_AUDITION ", "OK" if ok else "FAIL")
		quit(0 if ok else 1)
