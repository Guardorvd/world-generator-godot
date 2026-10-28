class_name TrailLabProps
extends RefCounted
## Picture of technical features (TrailTechnical.props): plain meshes, no collision of their own.
## Colours separate the three roles at a glance: grey rock is solid, brown wood is hoppable or ridable.

static func populate(parent: Node3D, props: Array) -> void:
	var rocks := {}
	var stone := _material(Color(0.5, 0.5, 0.48))
	var boulder := _material(Color(0.36, 0.37, 0.38))
	var root := _material(Color(0.36, 0.23, 0.12))
	var log := _material(Color(0.5, 0.36, 0.2))
	for p: Dictionary in props:
		var node := MeshInstance3D.new()
		match p.kind:
			"stone", "boulder":
				var variant: int = posmod(p.seed, RockModels.VARIANTS)
				if not rocks.has(variant): rocks[variant] = RockModels.mesh(Vector3.ONE, variant, 0.15)
				node.mesh = rocks[variant]
				node.material_override = stone if p.kind == "stone" else boulder
				node.position = p.pos
				node.scale = p.size
				node.rotation.y = p.rot
			"root", "log":
				var span: Vector2 = p.b - p.a
				var cylinder := CylinderMesh.new()
				cylinder.top_radius = p.radius
				cylinder.bottom_radius = p.radius
				cylinder.height = span.length()
				cylinder.radial_segments = 8
				cylinder.rings = 1
				node.mesh = cylinder
				node.material_override = root if p.kind == "root" else log
				var lift: float = p.radius * (0.2 if p.kind == "root" else 1.0)
				node.position = p.pos + Vector3(0, lift, 0)
				node.basis = Basis(Quaternion(Vector3.UP, Vector3(span.x, 0, span.y).normalized()))
		parent.add_child(node)

static func _material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.vertex_color_use_as_albedo = true
	m.roughness = 0.95
	return m
