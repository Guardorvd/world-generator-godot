extends SceneTree
## Эксперимент 6.5+: восемь ракурсов исходной модели, albedo + object-space normal.
const Dev := preload("res://tools/control/control.gd")
const VIEWS := 8


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("Для запекания нужен графический рендерер")
		quit(1)
		return
	var out := Dev.abs_dir(Dev.arg("out", "tools/control/runs/impostors65"))
	var pixels := clampi(int(Dev.arg("resolution", "256")), 64, 512)
	DirAccess.make_dir_recursive_absolute(out)
	FileAccess.open(out.path_join(".gdignore"), FileAccess.WRITE)
	var vp := SubViewport.new()
	vp.size = Vector2i(pixels, pixels)
	vp.transparent_bg = true
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	vp.add_child(camera)
	camera.current = true
	var capture := Shader.new()
	capture.code = """shader_type spatial;
render_mode unshaded, cull_disabled;
uniform sampler2D tex : source_color, filter_linear_mipmap;
uniform vec4 tint : source_color = vec4(1.0);
uniform bool cutout = false;
uniform bool normals = false;
void fragment() {
 vec4 t = texture(tex, UV);
 if(cutout && t.a < 0.4) discard;
 vec3 vertex_color = mix(COLOR.rgb / 12.92, pow((COLOR.rgb + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), COLOR.rgb));
 ALBEDO = normals ? normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz) * 0.5 + 0.5 : t.rgb * vertex_color * tint.rgb;
}
"""
	var defs := Models.tree_defs()
	var metadata := {}
	for kind in [Biomes.T_OAK, Biomes.T_BIRCH, Biomes.T_PINE]:
		for variant in ForestModels.VARIANTS:
			var key: int = kind + variant * ForestModels.MODEL_STRIDE
			var def: Dictionary = defs[key]
			var box: AABB = def.trunk.get_aabb().merge(def.crown.get_aabb())
			var span := maxf(box.size.y, maxf(box.size.x, box.size.z)) * 1.12
			var center := Vector3(0, box.get_center().y, 0)
			camera.size = span
			var parts: Array[MeshInstance3D] = []
			for part in ["trunk", "crown"]:
				var node := MeshInstance3D.new()
				node.mesh = def[part]
				node.lod_bias = 100.0
				var mat := ShaderMaterial.new()
				mat.shader = capture
				mat.set_shader_parameter("tex", def[part + "_texture"])
				mat.set_shader_parameter("cutout", part == "crown")
				mat.set_shader_parameter("tint", def.leaves[0] if part == "crown" else Color.WHITE)
				node.material_override = mat
				vp.add_child(node)
				parts.append(node)
			for normal_pass in [false, true]:
				var atlas := Image.create(pixels * VIEWS, pixels, false, Image.FORMAT_RGBA8)
				for node in parts:
					node.material_override.set_shader_parameter("normals", normal_pass)
				for view in VIEWS:
					var angle := view * TAU / VIEWS
					camera.look_at_from_position(center + Vector3(sin(angle), 0, cos(angle)) * 25.0, center)
					await process_frame
					await RenderingServer.frame_post_draw
					var frame := vp.get_texture().get_image()
					frame.convert(Image.FORMAT_RGBA8)
					atlas.blit_rect(frame, Rect2i(0, 0, pixels, pixels), Vector2i(view * pixels, 0))
				atlas.fix_alpha_edges()
				var err := atlas.save_png(out.path_join("%d_%s.png" % [key, "normal" if normal_pass else "color"]))
				if err != OK:
					quit(1)
					return
			metadata[str(key)] = {span = span, center = center.y, reference = [def.leaves[0].r, def.leaves[0].g, def.leaves[0].b]}
			for node in parts:
				node.free()
			print("impostor baked: ", key)
	Dev.save_json(out.path_join("metadata.json"), metadata)
	Dev.save_json(out.path_join("manifest.json"), {views = VIEWS, pixels = pixels,
		models_hash = FileAccess.get_file_as_string("res://scripts/render/forest_models.gd").sha256_text(),
		texture_bytes_with_mips = VIEWS * pixels * pixels * 4 * 2 * metadata.size() * 4 / 3})
	print("Атласы: ", out)
	quit()
