class_name TrailLabProps
extends RefCounted
## Picture of technical features (TrailTechnical.props): plain meshes, no collision of their own.
## Colours separate the three roles at a glance: grey rock is solid, brown wood is hoppable or ridable.
const PROP_CHUNK := 64.0

static func populate(parent: Node3D, props: Array) -> void:
	var floor_script := preload("res://scripts/render/forest_floor.gd")
	var rocks := {}
	var woods := {}
	var groups := {}
	var stone := _material(Color(0.5, 0.5, 0.48))
	var boulder := _material(Color(0.36, 0.37, 0.38))
	var log := _material(Color(0.5, 0.36, 0.2))
	var wood := _material(Color.WHITE)
	var planks := [_material(Color(0.58, 0.42, 0.24)), _material(Color(0.52, 0.37, 0.2))]
	for p: Dictionary in props:
		if p.kind == "deck":
			_deck(parent, p, planks[1 if p.odd else 0], log)
			continue
		if p.kind == "gate":
			_gate(parent, p)
			continue
		var chunk := Vector2i(floori(p.pos.x / PROP_CHUNK), floori(p.pos.z / PROP_CHUNK))
		match p.kind:
			"stone", "boulder":
				var variant: int = posmod(p.seed, RockModels.VARIANTS)
				if not rocks.has(variant): rocks[variant] = RockModels.mesh(Vector3.ONE, variant, 0.15)
				var group: String = p.kind + str(variant) + str(chunk)
				if not groups.has(group): groups[group] = {mesh = rocks[variant], material = stone if p.kind == "stone" else boulder, transforms = []}
				groups[group].transforms.append(Transform3D(Basis(Vector3.UP, p.rot).scaled(p.size), p.pos))
				continue
			"root", "log":
				var span: Vector2 = p.b - p.a
				if span.length_squared() < 0.0001: continue
				var variant := posmod(int(p.seed), 2)
				var form: String = p.kind + str(variant)
				if not woods.has(form): woods[form] = floor_script.technical_wood(p.kind == "root", variant)
				var group := form + str(chunk)
				if not groups.has(group): groups[group] = {mesh = woods[form], material = wood, transforms = []}
				var bounds: AABB = woods[form].get_aabb()
				var top: float = p.radius / 0.8 if p.kind == "root" else p.radius * 2.0
				var width := maxf(absf(bounds.position.z), absf(bounds.end.z))
				var xf := Transform3D(Basis(Vector3.UP, atan2(-span.y, span.x)).scaled(Vector3(span.length(), top / bounds.end.y, p.radius / width)), p.pos)
				groups[group].transforms.append(xf)
				continue
	for group: Dictionary in groups.values():
		var node := MultiMeshInstance3D.new()
		node.visibility_range_end = 180.0
		node.visibility_range_end_margin = 20.0
		node.material_override = group.material
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = group.mesh
		mm.instance_count = group.transforms.size()
		for i in mm.instance_count: mm.set_instance_transform(i, group.transforms[i])
		node.multimesh = mm
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

## Ворота старта (зелёные, «СТАРТ») и финиша (в шашку, «ФИНИШ»): две стойки по краям полотна и перекладина над ним. Только картинка.
static func _gate(parent: Node3D, p: Dictionary) -> void:
	var finish: bool = p.finish
	var half: float = p.half
	var root := Node3D.new()
	root.position = p.pos
	root.rotation.y = p.yaw
	var post := _material(Color(0.82, 0.82, 0.8) if finish else Color(0.2, 0.6, 0.3))
	for side: float in [-1.0, 1.0]:
		var mesh := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.2, 3.4, 0.2)
		mesh.mesh = box
		mesh.material_override = post
		mesh.position = Vector3(side * half, 1.7, 0)
		root.add_child(mesh)
	var cells := maxi(4, roundi(half * 2.0 / 0.5))
	var cell := half * 2.0 / cells
	var a := _material(Color(0.1, 0.1, 0.1) if finish else Color(0.2, 0.6, 0.3))
	var b := _material(Color(0.95, 0.95, 0.95) if finish else Color(0.9, 0.85, 0.35))
	for k in cells:
		var bar := MeshInstance3D.new()
		var plank := BoxMesh.new()
		plank.size = Vector3(cell, 0.7, 0.08)
		bar.mesh = plank
		bar.material_override = a if (k + (1 if finish and k % 2 == 0 else 0)) % 2 == 0 else b
		bar.position = Vector3(-half + cell * (k + 0.5), 3.1, 0)
		root.add_child(bar)
	for facing: float in [0.0, PI]:
		var label := Label3D.new()
		label.text = "ФИНИШ" if finish else "СТАРТ"
		label.pixel_size = 0.01
		label.font_size = 64
		label.outline_size = 12
		label.modulate = Color(1, 1, 1)
		label.position = Vector3(0, 3.1, 0.06 if facing == 0.0 else -0.06)
		label.rotation.y = facing
		root.add_child(label)
	parent.add_child(root)

static func _material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.vertex_color_use_as_albedo = true
	m.roughness = 0.95
	return m
