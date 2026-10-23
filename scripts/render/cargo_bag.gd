extends RefCounted
## 11.9: сумка-рюкзак для заданий доставки — у доски поселения и за спиной седока (BikeView.set_pack).
## Несколько коробок, как остальные постройки: тканевый мешок, клапан, карман, ремни и скатка сверху.
## Начало координат — середина спинки (та сторона, что прилегает к спине), лицевая сторона смотрит в +Z.

const SIZE := Vector3(0.36, 0.46, 0.2)


static func build() -> Node3D:
	var root := Node3D.new()
	root.name = "CargoBag"
	var canvas := _mat(Color(0.42, 0.40, 0.26))
	var flap_m := _mat(Color(0.36, 0.33, 0.21))
	var leather := _mat(Color(0.30, 0.19, 0.11))
	var roll_m := _mat(Color(0.55, 0.22, 0.16))
	var buckle := _mat(Color(0.75, 0.68, 0.45))
	var h := SIZE.y
	_box(root, Vector3(SIZE.x, h, SIZE.z), Vector3(0, 0, SIZE.z * 0.5), canvas)
	_box(root, Vector3(SIZE.x + 0.02, 0.17, SIZE.z + 0.03), Vector3(0, h * 0.5 - 0.07, SIZE.z * 0.5 + 0.005), flap_m)
	_box(root, Vector3(0.24, 0.15, 0.07), Vector3(0, -h * 0.18, SIZE.z + 0.03), flap_m)
	for side: float in [-1.0, 1.0]:
		# ремни клапана спереди и лямки по спинке
		_box(root, Vector3(0.035, 0.26, 0.012), Vector3(side * 0.09, h * 0.12, SIZE.z + 0.022), leather)
		_box(root, Vector3(0.03, 0.022, 0.016), Vector3(side * 0.09, -0.01, SIZE.z + 0.026), buckle)
		_box(root, Vector3(0.05, h * 0.95, 0.02), Vector3(side * 0.11, 0.0, -0.008), leather)
	var roll := CylinderMesh.new()
	roll.top_radius = 0.065
	roll.bottom_radius = 0.065
	roll.height = SIZE.x + 0.06
	roll.radial_segments = 8
	roll.rings = 1
	var r := MeshInstance3D.new()
	r.mesh = roll
	r.material_override = roll_m
	r.rotation.z = PI / 2.0
	r.position = Vector3(0, h * 0.5 + 0.06, SIZE.z * 0.5)
	root.add_child(r)
	return root


static func _box(parent: Node3D, size: Vector3, at: Vector3, m: Material) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = m
	node.position = at
	parent.add_child(node)


static func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.9
	return m
