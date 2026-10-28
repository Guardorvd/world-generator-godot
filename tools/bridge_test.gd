extends SceneTree
## 8.1: вода под мостом, совпадение меша и опоры, проезд в обе стороны.
const DT := 1.0 / 60.0
const SelfTest := preload("res://tools/selftest.gd")
var fails := 0

func check(ok: bool, label: String) -> void:
	if not ok:
		fails += 1
		printerr(label)

func _init() -> void:
	preload("res://tools/watchdog.gd").arm(self, 300)
	var w := WorldGenerator.generate("Ущелье", 512)
	var h := Heightfield.new(w)
	w.outer = OuterLand.new(w)
	check(SelfTest.settlements_connected(w), "Поселения потеряли связь")
	var passed := 0
	var seen := {}
	for b: BridgeData in w.bridges:
		check(StageTrails._crosses_water(h, b.a, b.b), "Мост без воды: %s" % b)
		var key := Vector2i(mini(b.a, b.b), maxi(b.a, b.b))
		check(not seen.has(key), "Дубликат моста: %s" % b)
		seen[key] = true
	for s: Dictionary in h.structures:
		if s.tunnel: continue
		var batch := MeshBatch.new()
		var n := maxi(1, ceili(s.len / Heightfield.BRIDGE_SECTION))
		for k in n:
			var t0: float = s.len * k / n
			var t1: float = s.len * (k + 1) / n
			var a := Vector3(s.ax + s.ux * t0, h.level(s, t0), s.az + s.uz * t0)
			var b := Vector3(s.ax + s.ux * t1, h.level(s, t1), s.az + s.uz * t1)
			StructuresBuilder._deck(batch, a, b, s.half, null)
		# С 9.8 сборка делится на квадраты мира: проверяются все части
		var built := batch.build("DeckTest")
		for part: MeshInstance3D in built.get_children():
			var arrays := part.mesh.surface_get_arrays(0)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			for k in vertices.size():
				if normals[k].y < 0.9: continue
				var v := vertices[k]
				var t: float = (v.x - s.ax) * s.ux + (v.z - s.az) * s.uz
				check(absf(v.y - h.level(s, t)) < 0.001, "Меш и опора расходятся")
		built.free()
		for reverse in [false, true]:
			var span: Dictionary = s.duplicate()
			if reverse:
				span.ax = s.bx; span.az = s.bz; span.ay = s.by
				span.bx = s.ax; span.bz = s.az; span.by = s.ay
				span.ux = -s.ux; span.uz = -s.uz
			for ride in [false, true]:
				var ok := _cross(w, h, span, ride)
				check(ok, "Мост (%s,%s), reverse=%s bike=%s" % [s.ax, s.az, reverse, ride])
				if ok: passed += 1
	check(w.bridges.size() > 0, "Контрольный мир без мостов")
	print("Мостов: %d; проездов: %d/%d; ошибок: %d" % [w.bridges.size(), passed, w.bridges.size() * 4, fails])
	quit(1 if fails else 0)


func _cross(w: WorldData, heights: Heightfield, s: Dictionary, ride: bool) -> bool:
	# 1 м больше вылета колеса WHEEL_REACH: велосипед целиком вышел на берег.
	# Дальше оси дорога может повернуть: прямой выезд на 2 м иногда упирается в перила соседнего моста.
	const EXIT := 1.0
	var yaw := atan2(-s.ux, -s.uz)
	var p := PlayerState.new()
	p.x = s.ax - s.ux * 2.0
	p.z = s.az - s.uz * 2.0
	p.feet = heights.surface_at(p.x, p.z, s.ay)
	var b := _bike_for(p, yaw, ride)
	for k in 60 * 120:
		if ride:
			b.step(p, 0.5, 0.0, false, false, DT, w, heights)
		else:
			p.step(1.0, 0.0, false, false, yaw, DT, w, heights)
		var t: float = (p.x - s.ax) * s.ux + (p.z - s.az) * s.uz
		if t > s.len + EXIT:
			return true
		# у концов настил может уходить под берег, а пол туннеля — под землю у входа
		if t > 3.0 and t < s.len - 3.0:
			var level := heights.level(s, t)
			if p.feet < level - 0.6 or (s.tunnel and p.feet > level + 0.6):
				print("  на %.0f м из %.0f: ноги на %.1f м, настил или пол на %.1f м" % [t, s.len, p.feet, level])
				return false
	var t: float = (p.x - s.ax) * s.ux + (p.z - s.az) * s.uz
	print("  не дошли: застряли на %.1f м из %.0f, ноги на %.1f м, вода %.1f м, стена %s" % [t, s.len, p.feet, heights.depth_at(p.x, p.z, p.feet), heights.wall_at(p.x, p.z, p.feet)])
	return false


func _bike_for(p: PlayerState, yaw: float, ride: bool) -> BikeRide:
	var b := BikeRide.new()
	if ride:
		b.x = p.x
		b.z = p.z
		b.y = p.feet
		b.heading = yaw
		b.mount(p)
	return b


