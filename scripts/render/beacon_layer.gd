extends Node3D
## Метка текущей площадки и модели уже установленных маяков.

const Sites = preload("res://scripts/game/beacon_sites.gd")
const SIGNAL_SHADER := preload("res://resources/beacon_signal.gdshader")
const SIGNAL := Color("#5cddd1")
const POSITION := Color("#ffce63")
const PARTS := [
	{radius = 0.28, height = 0.12, y = 0.06, color = Color("#434b4d")},
	{radius = 0.055, height = 1.22, y = 0.64, color = Color("#777e7e")},
	{radius = 0.18, height = 0.33, y = 0.88, color = Color("#31535a")},
	{radius = 0.16, height = 0.07, y = 1.08, color = SIGNAL},
	{radius = 0.022, height = 0.35, y = 1.40, color = Color("#777e7e")},
]
var _installed := {}
var _marker: Node3D
var _marker_at := Vector2.INF
var _meshes: Array[CylinderMesh] = []


func sync(installed: Dictionary, goal: Dictionary, heights: Heightfield) -> void:
	for id: String in _installed.keys():
		if not installed.has(id):
			_installed[id].queue_free()
			_installed.erase(id)
	for id: String in installed:
		if _installed.has(id):
			continue
		if _meshes.is_empty():
			_prepare_meshes()
		var cell := Sites.cell_of(id)
		var beacon := Node3D.new()
		for i in _meshes.size():
			_add_part(beacon, _meshes[i], PARTS[i].y)
		beacon.position = _position(Vector2(cell) + Vector2(0.5, 0.5), heights)
		add_child(beacon)
		_installed[id] = beacon
	if goal.get("kind") != "beacon":
		if _marker != null:
			_marker.hide()
		return
	if _marker == null:
		_marker = Node3D.new()
		var ring := MeshInstance3D.new()
		var mesh := TorusMesh.new()
		mesh.inner_radius = 0.48
		mesh.outer_radius = 0.56
		mesh.rings = 24
		mesh.ring_segments = 8
		ring.mesh = mesh
		ring.position.y = 0.17
		ring.material_override = _material(POSITION, true)
		_marker.add_child(ring)
		_add_part(_marker, _cylinder(0.045, 0.75, ring.material_override), 0.38)
		add_child(_marker)
	var at := Vector2(goal.x, goal.y)
	if at != _marker_at or not _marker.visible:
		_marker_at = at
		_marker.position = _position(at, heights)
	_marker.show()


func _prepare_meshes() -> void:
	var signal_material := ShaderMaterial.new()
	signal_material.shader = SIGNAL_SHADER
	signal_material.set_shader_parameter("signal_color", SIGNAL)
	for part: Dictionary in PARTS:
		var material: Material = signal_material if part.color == SIGNAL else _material(part.color, false)
		_meshes.append(_cylinder(part.radius, part.height, material))


func animate_install(id: String) -> void:
	var beacon: Node3D = _installed.get(id)
	if beacon == null:
		return
	beacon.scale.y = 0.1
	beacon.create_tween().tween_property(beacon, "scale:y", 1.0, 0.26) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


static func _position(at: Vector2, heights: Heightfield) -> Vector3:
	var xz := at * GameConfig.TILE
	return Vector3(xz.x, heights.ground_at(xz.x, xz.y), xz.y)


static func _cylinder(radius: float, length: float, material: Material) -> CylinderMesh:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = length
	mesh.radial_segments = 12
	mesh.rings = 1
	mesh.material = material
	return mesh


static func _add_part(parent: Node3D, mesh: Mesh, y: float) -> void:
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.position.y = y
	parent.add_child(node)


static func _material(color: Color, lit: bool) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.emission_enabled = lit
	if lit:
		material.emission = color
	return material
