extends SceneTree
## Источник scenes/bike.tscn. Размеры и имена контактов — контракт BikeView/IK/ragdoll.
var bike := BikeView.new()
var paint := mat(Color("c95c32"), 0.4, 0.15)
var rubber := mat(Color("20272b"), 0.95)
var alloy := mat(Color("adb8b7"), 0.32, 0.7)
var black := mat(Color("303c43"), 0.55, 0.25)
var trim := mat(Color("e9d6a5"), 0.75)

func mat(color: Color, roughness: float, metal := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	m.metallic = metal
	return m

func node(parent: Node3D, label: String, at := Vector3.ZERO) -> Node3D:
	var n := Node3D.new()
	n.name = label
	n.position = at
	parent.add_child(n)
	n.owner = bike
	return n

func mesh(parent: Node3D, label: String, shape: Mesh, material: Material, at := Vector3.ZERO, basis := Basis.IDENTITY) -> MeshInstance3D:
	var n := MeshInstance3D.new()
	n.name = label
	n.mesh = shape
	n.material_override = material
	n.transform = Transform3D(basis, at)
	parent.add_child(n)
	n.owner = bike
	return n

func box_shape(size: Vector3) -> BoxMesh:
	var shape := BoxMesh.new()
	shape.size = size
	return shape

func tube_shape(radius: float, length: float, sides := 10) -> CylinderMesh:
	var shape := CylinderMesh.new()
	shape.top_radius = radius
	shape.bottom_radius = radius
	shape.height = length
	shape.radial_segments = sides
	shape.rings = 0
	return shape

func tube(parent: Node3D, label: String, a: Vector3, b: Vector3, radius: float, material: Material) -> MeshInstance3D:
	return mesh(parent, label, tube_shape(radius, a.distance_to(b)), material, (a + b) * 0.5, Basis(Quaternion(Vector3.UP, (b - a).normalized())))

func torus(inner: float, outer: float) -> TorusMesh:
	var shape := TorusMesh.new()
	shape.inner_radius = inner
	shape.outer_radius = outer
	shape.rings = 32
	shape.ring_segments = 8
	return shape

func wheel(label: String, z: float) -> void:
	var w := node(bike, label, Vector3(0, 0.34, z))
	var sideways := Basis(Vector3.FORWARD, PI * 0.5)
	mesh(w, "Tire", torus(0.29, 0.35), rubber, Vector3.ZERO, sideways)
	mesh(w, "Sidewall", torus(0.292, 0.305), black, Vector3.ZERO, sideways)
	mesh(w, "Rim", torus(0.278, 0.291), alloy, Vector3.ZERO, sideways)
	mesh(w, "Hub", tube_shape(0.027, 0.13), alloy, Vector3.ZERO, sideways)
	mesh(w, "BrakeRotor", torus(0.047, 0.083), alloy, Vector3(-0.066, 0, 0), sideways)
	var spokes := SurfaceTool.new()
	spokes.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in 12:
		var angle := TAU * i / 12.0
		var a := Vector3(0.045 * (-1 if i % 2 else 1), 0, 0)
		var b := Vector3(0, cos(angle) * 0.282, sin(angle) * 0.282)
		spokes.append_from(tube_shape(0.0022, a.distance_to(b), 4), 0, Transform3D(Basis(Quaternion(Vector3.UP, (b - a).normalized())), (a + b) * 0.5))
	mesh(w, "Spokes", spokes.commit(), alloy)
	# Два ряда крупных невысоких шашек: профиль читается, мелкого невидимого протектора нет.
	var tread := SurfaceTool.new()
	tread.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in 24:
		var angle := TAU * i / 24.0
		for side in [-1.0, 1.0]:
			var at := Vector3(side * 0.021, cos(angle) * 0.341, sin(angle) * 0.341)
			tread.append_from(box_shape(Vector3(0.019, 0.011, 0.026)), 0, Transform3D(Basis(Vector3.RIGHT, angle), at))
	mesh(w, "Tread", tread.commit(), rubber)

func saddle() -> void:
	var shape := SurfaceTool.new()
	shape.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rings: Array[PackedVector3Array] = []
	for spec: Vector3 in [Vector3(-0.12, 0.028, 0.012), Vector3(-0.015, 0.077, 0.025), Vector3(0.105, 0.071, 0.018)]:
		var ring := PackedVector3Array()
		for cross: Vector2 in [Vector2(-0.8, 0), Vector2(0.8, 0), Vector2(1, -0.012), Vector2(0.75, -0.035), Vector2(-0.75, -0.035), Vector2(-1, -0.012)]:
			ring.append(Vector3(cross.x * spec.y, cross.y + spec.z, spec.x))
		rings.append(ring)
	for i in 2:
		for j in 6:
			for at in [rings[i][j], rings[i + 1][j], rings[i][(j + 1) % 6], rings[i][(j + 1) % 6], rings[i + 1][j], rings[i + 1][(j + 1) % 6]]:
				shape.add_vertex(at)
	for end in [0, 2]:
		for j in range(1, 5):
			for at in [rings[end][0], rings[end][j if end == 0 else j + 1], rings[end][j + 1 if end == 0 else j]]:
				shape.add_vertex(at)
	shape.generate_normals()
	mesh(bike, "Saddle", shape.commit(), rubber, Vector3(0, 0.915, 0.2))
	for side in [-1.0, 1.0]:
		tube(bike, "SaddleRail", Vector3(side * 0.035, 0.88, 0.12), Vector3(side * 0.035, 0.89, 0.28), 0.007, alloy)

func _init() -> void:
	bike.name = "Bike"
	wheel("RearWheel", 0.53)
	wheel("FrontWheel", -0.53)
	tube(bike, "SeatTube", Vector3(0, 0.3, 0), Vector3(0, 0.84, 0.17), 0.027, paint)
	tube(bike, "SeatPost", Vector3(0, 0.8, 0.16), Vector3(0, 0.91, 0.2), 0.019, black)
	tube(bike, "TopTube", Vector3(0, 0.82, 0.17), Vector3(0, 0.79, -0.4), 0.025, paint)
	var down := tube(bike, "DownTube", Vector3(0, 0.3, 0), Vector3(0, 0.71, -0.43), 0.033, paint)
	down.scale.x = 0.85
	tube(bike, "HeadTube", Vector3(0, 0.68, -0.43), Vector3(0, 0.84, -0.4), 0.034, paint)
	tube(bike, "Stem", Vector3(0, 0.82, -0.4), Vector3(0, 0.98, -0.43), 0.019, black)
	tube(bike, "Handlebar", Vector3(-0.28, 0.98, -0.43), Vector3(0.28, 0.98, -0.43), 0.014, black)
	saddle()
	for side in [-1.0, 1.0]:
		var s := "L" if side < 0 else "R"
		tube(bike, "ChainStay" + s, Vector3(side * 0.05, 0.3, 0), Vector3(side * 0.05, 0.34, 0.53), 0.013, paint)
		tube(bike, "SeatStay" + s, Vector3(side * 0.05, 0.8, 0.17), Vector3(side * 0.05, 0.34, 0.53), 0.011, paint)
		# Неподвижная верхняя труба и вложенные штаны с пыльником двигаются без масштабирования.
		var fork := node(bike, "Fork" + s)
		tube(fork, "Stanchion", Vector3(side * 0.055, 0.40, -0.53), Vector3(side * 0.055, 0.72, -0.53), 0.014, alloy)
		var lower := node(fork, "Lower")
		tube(lower, "Slider", Vector3(side * 0.055, 0.34, -0.53), Vector3(side * 0.055, 0.55, -0.53), 0.023, black)
		tube(lower, "Seal", Vector3(side * 0.055, 0.539, -0.53), Vector3(side * 0.055, 0.556, -0.53), 0.026, rubber)
		mesh(lower, "AxleBolt", tube_shape(0.022, 0.018), alloy, Vector3(side * 0.07, 0.34, -0.53), Basis(Vector3.FORWARD, PI / 2))
		tube(bike, "Grip" + s, Vector3(side * 0.19, 0.98, -0.43), Vector3(side * 0.285, 0.98, -0.43), 0.023, rubber)
		tube(bike, "Lever" + s, Vector3(side * 0.18, 0.97, -0.445), Vector3(side * 0.26, 0.954, -0.484), 0.008, alloy)
		mesh(bike, "BrakeClamp" + s, box_shape(Vector3(0.025, 0.031, 0.035)), black, Vector3(side * 0.178, 0.98, -0.43))
		tube(bike, "Cable" + s, Vector3(side * 0.17, 0.974, -0.45), Vector3(side * 0.12, 0.88, -0.56), 0.0035, rubber)
		tube(bike, "CableReturn" + s, Vector3(side * 0.12, 0.88, -0.56), Vector3(side * 0.045, 0.73, -0.43), 0.0035, rubber)
	tube(bike, "ForkCrown", Vector3(-0.067, 0.70, -0.53), Vector3(0.067, 0.70, -0.53), 0.025, black)
	tube(bike, "ForkCrownStem", Vector3(0, 0.70, -0.53), Vector3(0, 0.76, -0.415), 0.021, black)
	var arch := node(bike, "ForkArch")
	tube(arch, "Brace", Vector3(-0.055, 0.58, -0.53), Vector3(0.055, 0.58, -0.53), 0.014, black)
	mesh(arch, "FrontCaliper", box_shape(Vector3(0.026, 0.052, 0.035)), black, Vector3(-0.068, 0.39, -0.57))
	var rear := node(bike, "RearMechanics")
	mesh(rear, "Caliper", box_shape(Vector3(0.028, 0.045, 0.035)), black, Vector3(-0.07, 0.39, 0.58))
	for i in 4:
		mesh(rear, "Sprocket", tube_shape(0.075 - i * 0.011, 0.008, 16), alloy, Vector3(0.062 + i * 0.009, 0.34, 0.53), Basis(Vector3.FORWARD, PI / 2))
	tube(rear, "Derailleur", Vector3(0.094, 0.34, 0.53), Vector3(0.094, 0.21, 0.57), 0.011, black)
	mesh(rear, "Jockey", tube_shape(0.025, 0.016, 10), rubber, Vector3(0.094, 0.21, 0.57), Basis(Vector3.FORWARD, PI / 2))
	tube(bike, "ChainTop", Vector3(0.085, 0.397, 0), Vector3(0.085, 0.409, 0.53), 0.0035, black)
	tube(bike, "ChainBottom", Vector3(0.085, 0.202, 0), Vector3(0.085, 0.21, 0.57), 0.0035, black)
	var crank := node(bike, "Crank", Vector3(0, 0.3, 0))
	mesh(crank, "Ring", torus(0.076, 0.101), black, Vector3(0.085, 0, 0), Basis(Vector3.FORWARD, PI / 2))
	for side in [-1.0, 1.0]:
		var s := "L" if side < 0 else "R"
		tube(crank, "Arm" + s, Vector3(side * 0.09, 0, 0), Vector3(side * 0.14, -side * 0.17, 0), 0.014, alloy)
		var pedal := mesh(crank, "Pedal" + s, box_shape(Vector3(0.1, 0.025, 0.07)), black, Vector3(side * 0.14, -side * 0.17, 0))
		mesh(pedal, "Reflector", box_shape(Vector3(0.06, 0.012, 0.004)), trim, Vector3(0, 0, 0.036))
	for i in 4:
		var a := TAU * i / 4
		tube(crank, "Spider", Vector3(0.085, 0, 0), Vector3(0.085, cos(a) * 0.081, sin(a) * 0.081), 0.008, alloy)
	# Контрастная вставка на нижней трубе видна сбоку, без букв и текстур.
	tube(bike, "FramePanel", Vector3(0.001, 0.46, -0.17), Vector3(0.001, 0.59, -0.30), 0.034, trim)
	var rider := ResourceLoader.load("res://scenes/cyclist.tscn", "PackedScene", ResourceLoader.CACHE_MODE_IGNORE).instantiate() as Node3D
	rider.name = "Rider"
	bike.add_child(rider)
	rider.owner = bike
	var scene := PackedScene.new()
	var error := scene.pack(bike)
	if error == OK:
		error = ResourceSaver.save(scene, "res://scenes/bike.tscn")
	print("Bike model: ", error_string(error))
	bike.free()
	quit(error)
