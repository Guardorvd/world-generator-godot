extends Node3D
## Разреженный слой краски. Модели деревьев и камней берутся из обычного слоя растительности.

const PaintTargets = preload("res://scripts/game/paint_targets.gd")
const PAINT := preload("res://resources/quest_paint.gdshader")
const RANGE := 36.0
var vegetation: VegetationLayer
var _painted := {}
var _active_key := ""
var _highlight: MeshInstance3D
var _item := {}


func sync(painted: Dictionary, goal: Dictionary) -> void:
	for id: String in painted:
		if _painted.has(id):
			continue
		var place := PaintTargets.resolve(vegetation.world, id)
		_painted[id] = _overlay(place, false) if not place.is_empty() else null
	var key: String = goal.key if goal.get("kind") == "paint" else ""
	if key == _active_key:
		return
	_active_key = key
	if _highlight != null:
		_highlight.hide()
		_highlight.queue_free()
		_highlight = null
	_item = {}
	if key.is_empty():
		return
	_highlight = _overlay(goal, true)
	if _highlight == null:
		return
	var box: AABB = _highlight.transform * _highlight.mesh.get_aabb()
	if not goal.rock:
		var radius := float(goal.radius) + 0.12
		var height := minf(2.05, box.end.y - _highlight.position.y)
		box = AABB(_highlight.position - Vector3(radius, 0.0, radius), Vector3(radius * 2.0, height, radius * 2.0))
	var at := box.get_center()
	_item = {kind = "paint", id = key, at = Transform3D(Basis.IDENTITY, at), half = box.size * 0.5}
	var marker := Label3D.new()
	marker.text = "▼"
	marker.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	marker.font_size = 36
	marker.outline_size = 8
	marker.pixel_size = 0.012
	marker.modulate = Color("#ffd36b")
	marker.visibility_range_end = RANGE + 12.0
	var marker_at := Vector3(at.x, box.end.y + 0.46, at.z)
	marker.transform = _highlight.transform.affine_inverse() * Transform3D(Basis.IDENTITY, marker_at)
	# Следующая цель заменяет подсветку вместе с её указателем.
	_highlight.add_child(marker)


func item(eye: Vector3, reach: float) -> Dictionary:
	if _item.is_empty():
		return {}
	var offset: Vector3 = (eye - _item.at.origin).abs() - _item.half
	return _item if offset.max(Vector3.ZERO).length_squared() <= reach * reach else {}


func _overlay(place: Dictionary, highlight: bool) -> MeshInstance3D:
	var surface := vegetation.paint_surface(place.object)
	if surface.is_empty():
		return null
	var node := MeshInstance3D.new()
	node.mesh = surface.mesh
	node.transform = surface.transform
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.visibility_range_end = RANGE
	# MultiMesh использует ближайший LOD. Та же геометрия нужна и тонкой накладке.
	node.lod_bias = 8.0
	var material := ShaderMaterial.new()
	material.shader = PAINT
	var height: float = (node.transform * node.mesh.get_aabb()).size.y
	if place.rock:
		material.set_shader_parameter("rock", true)
		material.set_shader_parameter("stripe_height", height * 0.29)
		material.set_shader_parameter("stripe_width", minf(0.13, height * 0.16))
	else:
		material.set_shader_parameter("stripe_height", minf(1.22, height * 0.6))
	material.set_shader_parameter("highlight", highlight)
	if highlight:
		material.set_shader_parameter("offset_m", 0.027)
	node.material_override = material
	add_child(node)
	return node
