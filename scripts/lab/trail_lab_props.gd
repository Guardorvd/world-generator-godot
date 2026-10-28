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
	var planks := [_material(Color(0.58, 0.42, 0.24)), _material(Color(0.52, 0.37, 0.2))]
	for p: Dictionary in props:
		if p.kind == "deck":
			_deck(parent, p, planks[1 if p.odd else 0], log)
			continue
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

## One straight piece of a northshore deck: a slab whose top is the support level of the bike, and a pair of
## posts under its start down to the ground (none where the ramp is almost on the ground).
static func _deck(parent: Node3D, p: Dictionary, planks: Material, post: Material) -> void:
	var span: Vector3 = p.b - p.a
	var length := span.length()
	if length < 0.01:
		return
	var forward := span / length
	var side := forward.cross(Vector3.UP).normalized()
	var slab := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(p.half * 2.0, 0.14, length + 0.02)
	slab.mesh = box
	slab.material_override = planks
	slab.transform = Transform3D(Basis(side, side.cross(forward).normalized(), -forward), (p.a + p.b) * 0.5 - Vector3(0, 0.07, 0))
	parent.add_child(slab)
	var top: float = p.a.y - 0.14
	var bottom: float = p.ground_a - 0.15
	if top - bottom < 0.3:
		return
	for lateral: float in [-1.0, 1.0]:
		var leg := MeshInstance3D.new()
		var column := BoxMesh.new()
		column.size = Vector3(0.14, top - bottom, 0.14)
		leg.mesh = column
		leg.material_override = post
		leg.position = Vector3(p.a.x, (top + bottom) * 0.5, p.a.z) + side * lateral * (p.half - 0.1)
		parent.add_child(leg)

static func _material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.vertex_color_use_as_albedo = true
	m.roughness = 0.95
	return m
