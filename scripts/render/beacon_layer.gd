extends Node3D
## Метка текущей площадки и модели уже установленных маяков.

const Sites = preload("res://scripts/game/beacon_sites.gd")
const SIGNAL := Color("#5cddd1")
const POSITION := Color("#ffce63")
var _installed := {}
var _marker: Node3D


func sync(installed: Dictionary, goal: Dictionary, heights: Heightfield) -> void:
	for id: String in _installed.keys():
		if not installed.has(id):
			_installed[id].queue_free()
			_installed.erase(id)
	for id: String in installed:
		if _installed.has(id):
			continue
		var cell := Sites.cell_of(id)
		var beacon := Node3D.new()
		_cylinder(beacon, 0.28, 0.12, 0.06, Color("#434b4d"))
		_cylinder(beacon, 0.055, 1.22, 0.64, Color("#777e7e"))
		_cylinder(beacon, 0.18, 0.33, 0.88, Color("#31535a"))
		_cylinder(beacon, 0.16, 0.07, 1.08, SIGNAL, true)
		_cylinder(beacon, 0.022, 0.35, 1.40, Color("#777e7e"))
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
		_cylinder(_marker, 0.045, 0.75, 0.38, POSITION, true)
		add_child(_marker)
	_marker.position = _position(Vector2(goal.x, goal.y), heights)
	_marker.show()


static func _position(at: Vector2, heights: Heightfield) -> Vector3:
	var xz := at * GameConfig.TILE
	return Vector3(xz.x, heights.ground_at(xz.x, xz.y), xz.y)


static func _cylinder(parent: Node3D, radius: float, length: float, y: float, color: Color, lit := false) -> void:
	var node := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = length
	mesh.radial_segments = 12
	mesh.rings = 1
	node.mesh = mesh
	node.position.y = y
	node.material_override = _material(color, lit)
	parent.add_child(node)


static func _material(color: Color, lit: bool) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.emission_enabled = lit
	if lit:
		material.emission = color
	return material
