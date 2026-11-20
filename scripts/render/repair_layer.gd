class_name RepairLayer
extends Node3D
## Слой починяемых объектов мира (Repairables): лавки, туры на вершинах, причалы. Объекты, что не меняются (целая
## лавка, целый тур), остались в общем батче SettlementsBuilder; здесь только то, что нужно менять или строить по месту:
## сломанные лавки и туры (после ремонта на их месте целая модель) и причалы (меши зависят от воды у домика).
## Каждый объект — свой маленький MeshBatch с теми же тремя уровнями детализации и материалом атласа: смена вида —
## пересборка одного объекта. Слой же отдаёт GameWorld коробки для наведения (items): сесть на лавку, починить.
## spec — запись SettlementsBuilder: {id, kind: bench|cairn|pier, at, dynamic, ok: [LOD], broken: [LOD], tints, box: {at, half}}.

var repairs: Repairables
var _specs := {}
var _nodes := {}
var _material: Material


func setup(specs: Array, opaque: Material, state: Repairables) -> void:
	repairs = state
	_material = opaque
	for spec: Dictionary in specs:
		_specs[spec.id] = spec
		if spec.dynamic:
			_show(spec.id)


func has(id: String) -> bool:
	return _specs.has(id)


func kind(id: String) -> String:
	return _specs[id].kind if _specs.has(id) else ""


## Мировое положение объекта (центр его модели) или Vector3.INF
func position_of(id: String) -> Vector3:
	return _specs[id].at.origin if _specs.has(id) else Vector3.INF


func work_position(id: String) -> Vector3:
	var box: Dictionary = _specs[id].box
	return box.at.origin - Vector3.UP * minf(box.half.y, 0.28)


func repair(id: String) -> void:
	if not _specs.has(id):
		return
	var was_broken := repairs.is_broken(id)
	repairs.repair(id)
	if was_broken and _specs[id].dynamic:
		_show(id)
		var node: Node3D = _nodes.get(id)
		if node != null:
			node.scale = Vector3.ONE * 0.92
			node.create_tween().tween_property(node, "scale", Vector3.ONE, 0.18) \
				.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _show(id: String) -> void:
	var spec: Dictionary = _specs[id]
	if _nodes.has(id):
		_nodes[id].hide()
		_nodes[id].queue_free()
		_nodes.erase(id)
	var lods: Array = spec.broken if repairs.is_broken(id) else spec.ok
	var batch := MeshBatch.new()
	var local_at := Transform3D(spec.at.basis, Vector3.ZERO)
	for level in lods.size():
		batch.add_lod(lods[level], local_at, [_material], level, spec.tints, level <= 1)
	var node := batch.build("Repair")
	if node != null:
		node.position = spec.at.origin
		add_child(node)
		_nodes[id] = node


## Коробки для наведения (InteractionService.select) у объектов не дальше reach м от глаз:
## {kind: "bench" — на целую лавку можно сесть, "repair" — сломанный объект, id, repair_kind, at, half}
func items(eye: Vector3, reach: float) -> Array:
	var out: Array = []
	for id: String in _specs:
		var spec: Dictionary = _specs[id]
		if eye.distance_squared_to(spec.box.at.origin) > (reach + 3.0) * (reach + 3.0):
			continue
		var broken := repairs.is_broken(id)
		if broken or spec.kind == "bench":
			out.append({kind = "repair" if broken else "bench", id = id, repair_kind = spec.kind, at = spec.box.at, half = spec.box.half})
	return out


## Позиция и поворот сиденья лавки id: центр сиденья и направление взгляда (вперёд по модели)
func seat(id: String) -> Dictionary:
	if not _specs.has(id) or _specs[id].kind != "bench":
		return {}
	var at: Transform3D = _specs[id].at
	return {position = at.origin, yaw = atan2(-(at.basis * Vector3.BACK).x, -(at.basis * Vector3.BACK).z)}
