extends VegetationLayer
## Изолированный прототип: штатная игра использует прежний VegetationLayer.
const Dev := preload("res://tools/control/control.gd")
const SPRITE_SHADER := preload("res://tools/impostor.gdshader")
var switch_distance := 180.0
var sprites := {}
var shadow_proxies := true


func setup(w: WorldData, h: Heightfield, defs: Dictionary, grass_mesh: Mesh) -> void:
	super.setup(w, h, defs, grass_mesh)
	switch_distance = float(Dev.arg("impostor-distance", "180"))
	shadow_proxies = Dev.arg("impostor-shadows", "on") != "off"
	var out := Dev.abs_dir(Dev.arg("atlas", "tools/control/runs/impostors65"))
	if not FileAccess.file_exists(out.path_join("metadata.json")):
		push_error("Сначала запустите tools/impostor_bake.gd с графическим рендерером")
		get_tree().quit(1)
		return
	var metadata: Dictionary = Dev.load_json(out.path_join("metadata.json"))
	for id: String in metadata:
		var key := int(id)
		var info: Dictionary = metadata[id]
		var mesh := QuadMesh.new()
		mesh.size = Vector2.ONE * info.span
		mesh.center_offset = Vector3(0, info.center, 0)
		var mat := ShaderMaterial.new()
		mat.shader = SPRITE_SHADER
		for pass_name in ["color", "normal"]:
			var img := Image.load_from_file(out.path_join("%d_%s.png" % [key, pass_name]))
			img.generate_mipmaps()
			mat.set_shader_parameter("frame_texel", 1.0 / img.get_height())
			mat.set_shader_parameter(pass_name + "_atlas", ImageTexture.create_from_image(img))
		mat.set_shader_parameter("reference_color", Vector3(info.reference[0], info.reference[1], info.reference[2]))
		sprites[key] = {mesh = mesh, mat = mat}


func _apply_chunk(built: Dictionary) -> void:
	if _loaded.has(built.chunk):
		return
	super._apply_chunk(built)
	for entry: Dictionary in built.entries:
		if not sprites.has(entry.kind):
			continue
		var data: Dictionary = sprites[entry.kind]
		# Все представления используют неизменяемый исходный буфер экземпляров.
		var node := _multimesh(data.mesh, data.mat, entry.count, true, false)
		node.multimesh.buffer = entry.cbuf
		node.multimesh.visible_instance_count = entry.count
		# Поворот billboard выходит за AABB исходного асимметричного дерева.
		node.multimesh.custom_aabb = entry.bounds.grow(data.mesh.size.x * 1.7)
		node.visibility_range_end = GameConfig.TREE_R + world.CS * TILE * 0.7072
		entry.sprite = node
		entry.geometry = entry.nodes.duplicate()
		entry.proxies = []
		if shadow_proxies:
			# Контроль с сохранением тех же теней: дальние 3D-модели только в shadow pass.
			for part in ["trunk", "crown"]:
				var def: Dictionary = _defs[entry.kind]
				var proxy := _multimesh(def[part], def[part + "_mats"][0], entry.count, part == "crown")
				proxy.multimesh = entry[part]
				proxy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
				proxy.visibility_range_end = node.visibility_range_end
				entry.proxies.append(proxy)
		entry.nodes.append(node)
		entry.nodes.append_array(entry.proxies)
		_set_range(entry)


func set_distance(distance: float) -> void:
	switch_distance = distance
	for entry: Dictionary in veg.values():
		if entry.has("sprite"):
			_set_range(entry)


func _set_range(entry: Dictionary) -> void:
	for node: MultiMeshInstance3D in entry.geometry:
		node.visibility_range_end = minf(switch_distance, GameConfig.TREE_R + world.CS * TILE * 0.7072)
		node.visibility_range_end_margin = 0.0
	entry.sprite.visibility_range_begin = switch_distance
	entry.sprite.visibility_range_begin_margin = 0.0
	# У всех трёх представлений одинаковый pivot отсечения, иначе смена даёт пробелы.
	entry.sprite.multimesh.custom_aabb = entry.bounds
	entry.sprite.extra_cull_margin = float(sprites[entry.kind].mesh.size.x) * 1.7
	for node: MultiMeshInstance3D in entry.proxies:
		node.visibility_range_begin = switch_distance
		node.visibility_range_begin_margin = 0.0


static func install(game: GameWorld) -> Node:
	var old := game.vegetation
	old._finish()
	game.remove_child(old)
	old.free()
	var layer: VegetationLayer = load("res://tools/impostor_layer.gd").new()
	layer.name = "Vegetation"
	game.add_child(layer)
	layer.setup(game.world, game.heights, GameWorld._defs, GameWorld._grass_mesh)
	game.vegetation = layer
	layer.update(game.camera.position.x, game.camera.position.z, true)
	return layer
