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
	for group: String in ["understory", "floor_meshes"]:
		for k in catalog.get(group).size():
			ok = ok and same_mesh(catalog.get(group)[k], restored.get(group)[k])
	for k in catalog.textures.size():
		var a: Image = catalog.textures[k].get_image()
		var b: Image = restored.textures[k].get_image()
		ok = ok and a.get_format() == b.get_format() and a.has_mipmaps() == b.has_mipmaps() and a.get_data() == b.get_data()
	ForestModels.baking = false
	print("Asset catalog: trees=", catalog.trees.size(), " LOD groups=", catalog.levels.size(), " bytes=", FileAccess.get_size(catalog.PATH), " exact roundtrip=", ok)
	quit(0 if ok else 1)

func same_mesh(a: Mesh, b: Mesh) -> bool:
	if a.get_aabb() != b.get_aabb() or a.get_surface_count() != b.get_surface_count(): return false
	for s in a.get_surface_count():
		if a.surface_get_arrays(s) != b.surface_get_arrays(s): return false
		if a is ArrayMesh and b is ArrayMesh:
			if a.get("_surfaces")[s].get("lods", {}) != b.get("_surfaces")[s].get("lods", {}): return false
	return true
