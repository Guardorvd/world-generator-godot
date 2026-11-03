extends SceneTree
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 90)
	var project = load("res://resources/trails/lab/braking_case_111_0.tres").detached()
	var original: String = project.source.fingerprint()
	var result := preload("res://scripts/lab/trail_lab_builder.gd").build_project(project.source, project.seed, project.style, project.settings)
	var ok: bool = result.stats.base_fit_calls <= 3 and project.source.fingerprint() == original
	print("PASS " if ok else "FAIL ", "shared construction budget and immutable input: ", result.stats.base_fit_calls)
	quit(0 if ok else 1)
