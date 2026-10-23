extends RefCounted
## Локальные контакты рэгдолла: та же геометрия сооружений и те же габариты построек, что в мире.

class Contacts extends MeshBatch:
	var body: StaticBody3D
	var radius: float

	func add(mesh: Mesh, xform: Transform3D, _mat: Material) -> void:
		if not mesh is BoxMesh:
			return
		var half := (mesh as BoxMesh).size * 0.5
		if Vector2(xform.origin.x - body.global_position.x, xform.origin.z - body.global_position.z).length() > radius + half.length():
			return
		# Запекаем поворот и сдвиг базиса в вершины: наклонный настил не становится лестницей.
		var points := PackedVector3Array()
		for x in [-1.0, 1.0]:
			for y in [-1.0, 1.0]:
				for z in [-1.0, 1.0]:
					points.append(xform.basis * (half * Vector3(x, y, z)))
		var shape := ConvexPolygonShape3D.new()
		shape.points = points
		shape.margin = 0.005
		var col := CollisionShape3D.new()
		col.shape = shape
		col.position = xform.origin - body.global_position
		body.add_child(col)


static func build(body: StaticBody3D, heights: Heightfield, radius: float) -> void:
	var batch := Contacts.new()
	batch.body = body
	batch.radius = radius
	for s: Dictionary in heights.structures:
		var along := clampf((body.global_position.x - s.ax) * s.ux + (body.global_position.z - s.az) * s.uz, 0.0, s.len)
		var nearest := Vector2(s.ax + s.ux * along, s.az + s.uz * along)
		if nearest.distance_to(Vector2(body.global_position.x, body.global_position.z)) > radius + s.half + 2.0:
			continue
		# Используем сборщики видимой модели: настил, перила, парапет, сваи, стены и свод.
		if s.tunnel:
			var a := Vector3(s.ax, s.ay, s.az)
			var b := Vector3(s.bx, s.by, s.bz)
			if a.distance_to(b) < 0.01:
				continue
			var up := Vector3.UP if absf((b - a).normalized().y) < 0.99 else Vector3.BACK
			StructuresBuilder._tunnel(batch, Transform3D(Basis.looking_at(b - a, up), a), s.half, a.distance_to(b), -a.distance_to(b) * 0.5, null, null)
		elif s.style == "stone":
			StructuresBuilder._stone_bridge(batch, heights, s, null, null, null)
		elif s.style == "planks":
			StructuresBuilder._planks(batch, heights, s, null, null, null)
		else:
			StructuresBuilder._bridge(batch, heights, s, null, null, null)
	for settlement: Dictionary in heights.world.settlements:
		for hut: Dictionary in settlement.huts:
			_hut(batch, heights, hut, PlayerState.hut_angle(settlement, hut))
	for site: Dictionary in heights.world.sites:
		for hut: Dictionary in site.huts:
			_hut(batch, heights, hut, hut.a)


static func _hut(batch: Contacts, heights: Heightfield, hut: Dictionary, angle: float) -> void:
	var kind: String = hut.get("t", "house")
	var half := PlayerState.hut_half(hut)
	var at := Transform3D(Basis(Vector3.UP, angle), Vector3(hut.x * GameConfig.TILE, 0, hut.y * GameConfig.TILE))
	if Vector2(at.origin.x - batch.body.global_position.x, at.origin.z - batch.body.global_position.z).length() > batch.radius + half.length():
		return
	var foot := SettlementsBuilder._footing(heights, at, half)
	at.origin.y = foot.y
	var height := 2.0
	if SettlementsBuilder.HOUSE_FORM.has(kind):
		height = 0.0
		for floor_spec: Array in SettlementsBuilder.HOUSE_FORM[kind].floors:
			height += floor_spec[0]
	elif kind == "barn":
		height = 2.8
	else:
		height = {hay = 2.0, shed = 2.2, fountain = 1.0, stone = 2.0, obelisk = 5.5, tower = 8.5, keep = 5.0 + hut.get("v", 0) * 1.5, ruin = 2.4}.get(kind, 2.0)
	# Как в PlayerState: постройки — замкнутый объём по их габаритам, без входа внутрь.
	var mesh := BoxMesh.new()
	mesh.size = Vector3(half.x * 2.0, height + foot.y - foot.x + 0.15, half.y * 2.0)
	batch.add(mesh, at.translated_local(Vector3(0, height - mesh.size.y * 0.5, 0)), null)
