extends SceneTree
## Авторская сборка поселенческих моделей в resources/models/settlements/*.glb.
## Экспортирует каждую модель из SettlementSets.MODELS с тремя явными уровнями (LOD0, LOD1, LOD2)
## и сразу проверяет записанный .glb валидатором SettlementModels.validate_glb_file.

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	var opaque := StandardMaterial3D.new()
	opaque.resource_name = "settlement_opaque"
	opaque.roughness = 0.92
	opaque.vertex_color_use_as_albedo = true
	var cutout := StandardMaterial3D.new()
	cutout.resource_name = "settlement_cutout"
	cutout.roughness = 0.95
	cutout.vertex_color_use_as_albedo = true
	cutout.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	var mats := {opaque = opaque, cutout = cutout}

	var failures := 0
	for id: String in SettlementSets.MODELS:
		var spec: Dictionary = SettlementSets.MODELS[id]
		var path: String = spec.glb
		var abs_path := ProjectSettings.globalize_path(path)
		DirAccess.make_dir_recursive_absolute(abs_path.get_base_dir())
		var scene := SettlementModels.build_glb_scene(id, mats)
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		var err := doc.append_from_scene(scene, state)
		if err == OK:
			err = doc.write_to_filesystem(state, abs_path)
		scene.free()
		if err != OK:
			printerr("Не удалось записать %s: %s" % [path, error_string(err)])
			failures += 1
			continue
		var half := SettlementSets.half_of(id)
		var reason := SettlementModels.validate_glb_file(id, path, half, spec.category)
		if not reason.is_empty():
			printerr("Отказ валидации %s: %s" % [path, reason])
			failures += 1
		else:
			print("GLB OK: %-14s -> %s (%d байт)" % [id, path, FileAccess.get_size(abs_path)])
	quit(1 if failures > 0 else 0)
