extends SceneTree
## Authoring only; no world generation. Save exact meshes including native/explicit LOD and metadata.
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 180)
	var catalog := preload("res://scripts/render/asset_catalog.gd").new()
	ForestModels.baking = true
	catalog.trees = Models.build_tree_defs()
	catalog.grass = Models.build_grass_mesh()
	catalog.understory = preload("res://scripts/render/understory_models.gd").build_meshes()
	catalog.floor_meshes = preload("res://scripts/render/forest_floor.gd").build_meshes()
	var Plants := preload("res://scripts/render/understory_models.gd")
	var Floor := preload("res://scripts/render/forest_floor.gd")
	var plant_far: Dictionary = Plants.build_far_meshes()
	var floor_far: Dictionary = Floor.build_far_meshes()
	for k: int in plant_far:
		catalog.far_forms[k] = plant_far[k]
	for k: int in floor_far:
		catalog.far_forms[Floor.FIRST + k] = floor_far[k]
	for id: int in catalog.trees:
		for part: String in ["trunk", "crown"]:
			if catalog.trees[id].has(part):
				catalog.levels["%d/%s" % [id, part]] = ForestModels.lod_meshes(catalog.trees[id][part])
	catalog.textures.assign([ForestModels._texture(false), ForestModels._texture(true), ForestModels._texture(true, true)])
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.035
	noise.fractal_octaves = 4
	noise.seed = 2025
	var img := noise.get_seamless_image(TerrainBuilder.DETAIL_SIZE, TerrainBuilder.DETAIL_SIZE)
	var nrm := img.duplicate() as Image
	nrm.convert(Image.FORMAT_RGBA8)
	nrm.bump_map_to_normal_map(6.0)
	img.generate_mipmaps()
	nrm.generate_mipmaps()
	catalog.textures.append(ImageTexture.create_from_image(img))
	catalog.textures.append(ImageTexture.create_from_image(nrm))
	catalog.textures.append(ForestModels._texture(true, false, true))

	# Проверка и сборка моделей поселений из .glb + общий атлас и мелкие детали.
	if not _check_bad_glb_rejection():
		ForestModels.baking = false
		quit(1)
		return
	var atlas := SettlementModels.build_atlas()
	catalog.settlement_textures.assign([
		ImageTexture.create_from_image(atlas[0]),
		ImageTexture.create_from_image(atlas[1]),
	])
	catalog.settlement_details = SettlementModels.build_detail_meshes()
	catalog.site_lods = SettlementModels.build_site_lods()
	catalog.settlements = _load_and_validate_settlements()
	if catalog.settlements.is_empty():
		ForestModels.baking = false
		quit(1)
		return

	DirAccess.make_dir_recursive_absolute(catalog.PATH.get_base_dir())
	var err := ResourceSaver.save(catalog, catalog.PATH, ResourceSaver.FLAG_COMPRESS)
	if err != OK:
		push_error("Asset catalog: " + error_string(err))
		quit(1)
		return
	# Reload uncached and compare serialized attributes, LOD, bounds and texture mipmaps.
	var restored := ResourceLoader.load(catalog.PATH, "", ResourceLoader.CACHE_MODE_IGNORE)
	var ok: bool = restored.trees.keys() == catalog.trees.keys() and restored.levels.keys() == catalog.levels.keys()
	for key: String in catalog.levels:
		var before: Array = catalog.levels[key]
		var after: Array = restored.levels[key]
		ok = ok and before.size() == after.size()
		for k in before.size():
			ok = ok and same_mesh(before[k], after[k])
	for pair: Array in [[catalog.grass, restored.grass]]:
		ok = ok and same_mesh(pair[0], pair[1])
	for k: int in catalog.far_forms:
		ok = ok and same_mesh(catalog.far_forms[k], restored.far_forms[k])
	for group: String in ["understory", "floor_meshes"]:
		for k in catalog.get(group).size():
			ok = ok and same_mesh(catalog.get(group)[k], restored.get(group)[k])
	for k in catalog.textures.size():
		var a: Image = catalog.textures[k].get_image()
		var b: Image = restored.textures[k].get_image()
		ok = ok and a.get_format() == b.get_format() and a.has_mipmaps() == b.has_mipmaps() and a.get_data() == b.get_data()
	ok = ok and restored.settlements.keys() == catalog.settlements.keys()
	for sid: String in catalog.settlements:
		var bs: Dictionary = catalog.settlements[sid]
		var as_: Dictionary = restored.settlements[sid]
		ok = ok and bs.size == as_.size and bs.category == as_.category and bs.half == as_.half and is_equal_approx(bs.flat, as_.flat) and is_equal_approx(bs.height, as_.height)
		ok = ok and bs.lods.size() == as_.lods.size()
		for k in bs.lods.size():
			ok = ok and same_mesh(bs.lods[k], as_.lods[k])
	ok = ok and restored.settlement_details.keys() == catalog.settlement_details.keys()
	for did: String in catalog.settlement_details:
		ok = ok and same_mesh(catalog.settlement_details[did], restored.settlement_details[did])
	ok = ok and restored.site_lods.keys() == catalog.site_lods.keys()
	for sid: String in catalog.site_lods:
		var bl: Array = catalog.site_lods[sid]
		var al: Array = restored.site_lods[sid]
		ok = ok and bl.size() == al.size()
		for k in bl.size():
			ok = ok and same_mesh(bl[k], al[k])
	ok = ok and restored.settlement_textures.size() == catalog.settlement_textures.size()
	for k in catalog.settlement_textures.size():
		var a: Image = catalog.settlement_textures[k].get_image()
		var b: Image = restored.settlement_textures[k].get_image()
		ok = ok and a.get_format() == b.get_format() and a.has_mipmaps() == b.has_mipmaps() and a.get_data() == b.get_data()
	ForestModels.baking = false
	print("Asset catalog: trees=", catalog.trees.size(), " settlements=", catalog.settlements.size(), " LOD groups=", catalog.levels.size(), " bytes=", FileAccess.get_size(catalog.PATH), " exact roundtrip=", ok)
	quit(0 if ok else 1)


func _load_and_validate_settlements() -> Dictionary:
	var out := {}
	for id: String in SettlementSets.MODELS:
		var spec: Dictionary = SettlementSets.MODELS[id]
		var path: String = spec.glb
		var abs_path := ProjectSettings.globalize_path(path)
		if not FileAccess.file_exists(abs_path):
			printerr("Отсутствует модель поселения: %s (%s)" % [id, path])
			return {}
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		var err := doc.append_from_file(abs_path, state)
		if err != OK:
			printerr("Ошибка чтения %s (%s): %s" % [id, path, error_string(err)])
			return {}
		var scene := doc.generate_scene(state)
		if scene == null:
			printerr("Пустая сцена GLB в %s (%s)" % [id, path])
			return {}
		var sc: Dictionary = SettlementSets.SIZE_CLASSES[spec.size]
		var reason := SettlementModels.validate_glb_scene(id, scene, sc.half, spec.category)
		if not reason.is_empty():
			scene.free()
			printerr("Модель отклонена: ", reason)
			return {}
		var lods := SettlementModels.extract_lods(scene)
		var clean_lods: Array[Mesh] = []
		for m: Mesh in lods:
			var dup := m.duplicate() as Mesh
			for s in dup.get_surface_count():
				dup.surface_set_material(s, null)
			clean_lods.append(dup)
		scene.free()
		out[id] = {
			lods = clean_lods,
			size = spec.size,
			category = spec.category,
			half = sc.half,
			flat = sc.flat,
			height = float(spec.get("height", sc.height)),
		}
	return out


func _check_bad_glb_rejection() -> bool:
	var dir := "res://.godot/bad_glb_test"
	var bad_path := dir.path_join("bad_house.glb")
	var abs_dir := ProjectSettings.globalize_path(dir)
	var abs_path := ProjectSettings.globalize_path(bad_path)
	DirAccess.make_dir_recursive_absolute(abs_dir)
	var bad_root := Node3D.new()
	bad_root.name = "bad_house"
	for level in 3:
		var mi := MeshInstance3D.new()
		mi.name = "LOD%d" % level
		var box := BoxMesh.new()
		box.size = Vector3(6.0, 3.0, 6.0)
		var st := SurfaceTool.new()
		st.create_from(box, 0)
		var m := st.commit()
		var xf := Transform3D(Basis(), Vector3(2.5, 1.5, 0.0))
		var arr := m.surface_get_arrays(0)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		for i in verts.size():
			verts[i] = xf * verts[i]
		arr[Mesh.ARRAY_VERTEX] = verts
		var shifted := ArrayMesh.new()
		shifted.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		mi.mesh = shifted
		bad_root.add_child(mi)
		mi.owner = bad_root
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_scene(bad_root, state)
	if err == OK:
		err = doc.write_to_filesystem(state, abs_path)
	bad_root.free()
	if err != OK:
		printerr("Не удалось создать тестовый плохой GLB: ", error_string(err))
		return false
	var reason := SettlementModels.validate_glb_file("bad_house", bad_path, Vector2(1.6, 1.6), "home")
	DirAccess.remove_absolute(abs_path)
	DirAccess.remove_absolute(abs_dir)
	if reason.is_empty() or not reason.contains("bad_house"):
		printerr("Валидатор не отклонил заведомо плохой GLB! Ответ: ", reason)
		return false
	print("Bad GLB check: OK (%s)" % reason)
	return true

func same_mesh(a: Mesh, b: Mesh) -> bool:
	if a.get_aabb() != b.get_aabb() or a.get_surface_count() != b.get_surface_count(): return false
	for s in a.get_surface_count():
		if a.surface_get_arrays(s) != b.surface_get_arrays(s): return false
		if a is ArrayMesh and b is ArrayMesh:
			if a.get("_surfaces")[s].get("lods", {}) != b.get("_surfaces")[s].get("lods", {}): return false
	return true
