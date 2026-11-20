extends SceneTree
## Регрессии полевых эффектов. Генерация мира и файлов сохранения не нужна.

const BeaconLayer = preload("res://scripts/render/beacon_layer.gd")
const PaintLayer = preload("res://scripts/render/paint_layer.gd")
const CargoBag = preload("res://scripts/render/cargo_bag.gd")
const Quests = preload("res://scripts/game/quests.gd")

class Flat extends Heightfield:
	var samples := 0

	func ground_at(_x: float, _z: float, _raw: bool = false) -> float:
		samples += 1
		return 0.0

class PaintVegetation extends VegetationLayer:
	var builds := 0

	func paint_surface(_id: int) -> Dictionary:
		builds += 1
		return {mesh = BoxMesh.new(), transform = Transform3D(Basis.IDENTITY, Vector3(2, 0.5, 0))}

var _failures := 0


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 20)
	_run.call_deferred()


func _check(ok: bool, description: String) -> void:
	print(("PASS " if ok else "FAIL ") + description)
	_failures += int(not ok)


func _run() -> void:
	var heights := Flat.new()
	var beacon := BeaconLayer.new()
	root.add_child(beacon)
	var goal := {kind = "beacon", x = 3.5, y = 2.5}
	var installed := {"beacon:1:1": true, "beacon:2:2": true}
	beacon.sync(installed, goal, heights)
	var first: Node3D = beacon._installed["beacon:1:1"]
	var second: Node3D = beacon._installed["beacon:2:2"]
	_check(first.get_child(3).mesh == second.get_child(3).mesh and first.scale == Vector3.ONE,
		"восстановленные маяки используют общий меш кольца и сразу видны в полном размере")
	beacon.sync(installed, goal, heights)
	_check(heights.samples == 3, "повторная синхронизация не переснимает высоты")
	beacon.animate_install("beacon:1:1")
	_check(is_equal_approx(first.scale.y, 0.1) and second.scale == Vector3.ONE, "растёт только новый маяк")

	var vegetation := PaintVegetation.new()
	var paint := PaintLayer.new()
	root.add_child(paint)
	paint.vegetation = vegetation
	var target := {kind = "paint", key = "tree", rock = false, radius = 0.5, object = 0}
	paint.sync({}, target)
	var highlight := paint._highlight
	var marker := highlight.get_child(0) as Label3D
	paint.sync({"tree": true}, {})
	_check(vegetation.builds == 1 and paint._painted["tree"] == highlight and not marker.visible
		and paint.item(Vector3(2, 1, 0), 3.0).is_empty(), "подсветка превращается в метку без второго построения меша")
	var material := highlight.material_override as ShaderMaterial
	_check(paint.reveal("tree", Vector3(2, 1.4, 2)).is_finite()
		and is_zero_approx(float(material.get_shader_parameter("fade"))), "свежая краска проявляется с нуля")

	var layer := RepairLayer.new()
	root.add_child(layer)
	var state := Repairables.new()
	var id := "bench"
	while not state.is_broken(id):
		id += "1"
	var at := Transform3D(Basis.IDENTITY, Vector3(1200, 5, -900))
	var lods := [BoxMesh.new(), BoxMesh.new(), BoxMesh.new()]
	layer.setup([{id = id, kind = "bench", dynamic = true, at = at, ok = lods, broken = lods,
		tints = {}, box = {at = at, half = Vector3.ONE}}], StandardMaterial3D.new(), state)
	var previous: Node3D = layer._nodes[id]
	layer.repair(id)
	var fixed: Node3D = layer._nodes[id]
	layer.repair(id)
	_check(not previous.visible and not state.is_broken(id) and fixed == layer._nodes[id]
		and fixed.position == at.origin and is_equal_approx(fixed.scale.x, 0.92),
		"ремонт масштабируется вокруг объекта и при повторном вызове не пересобирается")

	var scope := GameWorld.new()
	scope._bag = CargoBag.build()
	root.add_child(scope._bag)
	scope._bag_label = Label3D.new()
	scope._bag.add_child(scope._bag_label)
	scope.quests = Quests.new()
	scope._animate_bag_pickup()
	scope._sync_delivery_bag()
	_check(scope._bag.visible and not scope._bag_label.visible, "сумка видна в момент подбора, её подсказка скрыта")

	var effects := BrakeEffects.new()
	root.add_child(effects)
	effects.emit_paint(Vector3(2, 0.8, 0), Vector3(2, 1.4, 2), 0.0)
	effects.emit_repair(Vector3.ZERO, false, false)
	effects.emit_repair(Vector3.ZERO, true, true)
	var bike := BikeRide.new()
	var world := WorldData.new()
	effects.tick(1.0 / 60.0, bike, world, heights)
	_check(effects._d_cursor == 21 and effects._p_cursor == 3 and effects._debris_mm.visible
		and effects._plume_mm.visible, "8 капель, 4 щепки и финальный выброс используют один пул")
	for frame in 90:
		effects.tick(1.0 / 60.0, bike, world, heights)
	_check(not effects._debris_mm.visible and not effects._plume_mm.visible, "пустые пулы отключаются после выброса")

	await create_timer(0.35).timeout
	_check(first.scale == Vector3.ONE and fixed.scale == Vector3.ONE
		and is_equal_approx(float(material.get_shader_parameter("fade")), 1.0), "анимации доходят до конечного значения")
	_check(not scope._bag.visible and scope._bag_pickup == null, "после подбора сумка скрывается")
	scope.free()
	vegetation.free()
	print("field_feedback_test failures: ", _failures)
	quit(1 if _failures else 0)
