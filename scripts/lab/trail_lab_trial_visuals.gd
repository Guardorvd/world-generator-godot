extends RefCounted
## Lab-only presentation of the exact contact surface; no collision/height/route changes.
static func material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color; m.roughness = 0.95
	return m

static func point(h: Heightfield, at: Vector2, lift := 0.0) -> Vector3:
	return Vector3(at.x, h.ground_at(at.x, at.y) + lift, at.y)

static func box(parent: Node3D, position: Vector3, size: Vector3, m: Material) -> void:
	var node := MeshInstance3D.new()
	var mesh := BoxMesh.new(); mesh.size = size
	node.mesh = mesh; node.material_override = m; node.position = position
	parent.add_child(node)

static func label(parent: Node3D, text: String, at: Vector3, color: Color, distance := 60.0) -> void:
	var node := Label3D.new()
	node.text = text; node.position = at
	node.font_size = 48; node.pixel_size = 0.009
	node.modulate = color; node.outline_size = 9
	node.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	node.visibility_range_end = distance
	parent.add_child(node)

static func gate(parent: Node3D, h: Heightfield, d: TrailDefinition, station: float, text: String, color: Color) -> void:
	var at := d.point_at(station)
	var side := d.tangent_at(station).orthogonal()
	var timber := material(Color(0.30, 0.20, 0.13))
	var flag := material(color)
	for sign_value: float in [-1.0, 1.0]:
		var p := at + side * (d.width * 0.5 + 0.7) * sign_value
		var base := point(h, p)
		box(parent, base + Vector3.UP * 1.25, Vector3(0.16, 2.5, 0.16), timber)
		box(parent, base + Vector3.UP * 2.1, Vector3(0.42, 0.65, 0.07), flag)
	label(parent, text, point(h, at, 3.0), color)

static func build(parent: Node3D, h: Heightfield, d: TrailDefinition, spawn: Dictionary, source) -> void:
	for child in parent.get_children(): child.free()
	var mesh := ImmediateMesh.new()
	var shader := Shader.new()
	shader.code = """shader_type spatial;
render_mode blend_mix, depth_prepass_alpha, cull_disabled;
varying vec3 world_pos;
float hash(vec2 p) { return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453); }
void vertex() { world_pos = (MODEL_MATRIX * vec4(VERTEX,1.0)).xyz; }
void fragment() {
 float grit=hash(floor(world_pos.xz*14.0));
 float patches=hash(floor(world_pos.xz*0.8));
 float wheel=exp(-pow((UV.x-0.30)*22.0,2.0))+exp(-pow((UV.x-0.70)*22.0,2.0));
 ALBEDO=mix(vec3(0.24,0.15,0.075),vec3(0.48,0.34,0.19),0.42+grit*0.23+patches*0.15)-wheel*0.035;
 ROUGHNESS=0.97; SPECULAR=0.12;
 ALPHA=smoothstep(0.0,0.065+patches*0.02,UV.x)*(1.0-smoothstep(0.925-patches*0.02,1.0,UV.x))*smoothstep(0.0,0.7,UV.y);
}"""
	var mat := ShaderMaterial.new(); mat.shader = shader
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, mat)
	var draw := d.duplicate(true) as TrailDefinition
	var extended := PackedVector2Array([spawn.position]); extended.append_array(d.points)
	draw.points = extended
	var count := ceili(draw.route_length())
	var across_count := maxi(6, ceili(d.width / 0.5))
	for i in count:
		var a := float(i); var b := minf(i + 1.0, draw.route_length())
		for lane in across_count:
			var u0 := float(lane) / across_count
			var u1 := float(lane + 1) / across_count
			for uv: Vector2 in [Vector2(u0, a), Vector2(u0, b), Vector2(u1, a), Vector2(u1, a), Vector2(u0, b), Vector2(u1, b)]:
				var p := draw.point_at(uv.y) + draw.tangent_at(uv.y).orthogonal() * ((uv.x - 0.5) * d.width)
				var y := h.ground_at(p.x, p.y)
				var normal := Vector3(y - h.ground_at(p.x + 0.25, p.y), 0.25, y - h.ground_at(p.x, p.y + 0.25)).normalized()
				mesh.surface_set_normal(normal)
				mesh.surface_set_uv(Vector2(uv.x, uv.y / 4.0))
				mesh.surface_add_vertex(Vector3(p.x, y + 0.025, p.y))
	mesh.surface_end()
	var ribbon := MeshInstance3D.new()
	ribbon.mesh = mesh; ribbon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(ribbon)
	gate(parent, h, d, 0, "СТАРТ", Color(0.35, 0.90, 0.72))
	gate(parent, h, d, d.route_length(), "ФИНИШ", Color(0.96, 0.92, 0.72))
	var last := -100.0
	for e in d.elements:
		var station := maxf(4, e.station - e.length * 0.5 - 12)
		if station < last + 28: continue
		var at := d.point_at(station) + d.tangent_at(station).orthogonal() * (d.width * 0.5 + 0.7)
		if source.blocked(at): continue
		last = station
		box(parent, point(h, at, 0.65), Vector3(0.09, 1.3, 0.09), material(Color(0.30, 0.20, 0.13)))
		label(parent, TrailElementLibrary.title(e.profile), point(h, at, 1.55), Color(1.0, 0.79, 0.37), 38)
