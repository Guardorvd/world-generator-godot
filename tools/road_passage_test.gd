extends SceneTree
const Fixture := preload("res://tools/road_relief_fixture.gd")
var fails := 0
var h: Heightfield
var node: MeshInstance3D
var camera: Camera3D
var out := "res://tools/control/runs/road_passage"

func check(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ", label)
	fails += int(not ok)

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 90)
	run.call_deferred()

func run() -> void:
	var w := Fixture.world()
	w.trails = [w.trails[1]]
	h = Heightfield.new(w, false)
	var line: Array = w.trails[0].pts.duplicate(true)
	for p: Dictionary in line: p.y += 1.0
	var original := line.duplicate(true)
	var merged := StageTrails._shared_passage(w, line, "road", h, PackedByteArray())
	var loops: Array = []
	for j in 81:
		loops.append({x = 8.0 + j, y = 48.5 + 1.5 * sin(j * PI / 10.0), w = 0.9})
	var closed := StageTrails._shared_passage(w, loops, "road", h, PackedByteArray())
	var deviation := 0.0
	for p: Dictionary in closed: deviation = maxf(deviation, absf(p.y - 48.5))
	check(deviation < 0.001, "repeated divergence and rejoining uses one network subpath, without grassy islands")
	var mixed := StageTrails._shared_passage(w, loops, "trail", h, PackedByteArray())
	check(mixed == closed, "road and trail travelling through the same corridor share the same geometry")
	var stable := StageTrails._shared_passage(w, closed, "road", h, PackedByteArray())
	check(stable == closed, "normalising an already shared edge is idempotent")
	var rival: Dictionary = w.trails[0].duplicate(true)
	for p: Dictionary in rival.pts: p.y += 1.3
	w.trails.append(rival)
	check(StageTrails._shared_passage(w, loops, "road", h, PackedByteArray()) == closed,
		"a nearer competing axis cannot make the shared passage switch ownership point by point")
	w.trails.pop_back()
	var reverse := loops.duplicate(true); reverse.reverse()
	var reverse_result := StageTrails._shared_passage(w, reverse, "road", h, PackedByteArray())
	reverse_result.reverse()
	check(reverse_result == closed, "the common edge is independent of route traversal direction")
	check(merged[merged.size() / 2].y == w.trails[0].pts[0].y, "adjacent parallel passage reuses the existing axis")
	check(merged[0] == line[0] and merged[-1] == line[-1], "route endpoints preserved")
	check(line == original, "source route remains immutable")
	var repeated := StageTrails._shared_passage(w, line, "road", h, PackedByteArray())
	check(repeated == merged, "deterministic passage consolidation")
	var crossing := [{x = 40.0, y = 30.0, w = 0.9}, {x = 40.0, y = 48.5, w = 0.9}, {x = 40.0, y = 65.0, w = 0.9}]
	check(StageTrails._shared_passage(w, crossing, "road", h, PackedByteArray()) == crossing, "crossing is not snapped to a parallel passage")
	var ending := [{x = 40.0, y = 35.0, w = 0.9}, {x = 40.0, y = 45.0, w = 0.9}, {x = 40.0, y = 49.0, w = 0.9}]
	var joined := StageTrails._shared_passage(w, ending, "road", h, PackedByteArray())
	check(joined[-1].y == 48.5, "terminating branch joins the host axis without an overhanging cap")
	var separate := line.duplicate(true)
	for p: Dictionary in separate: p.y += 3.0
	check(StageTrails._shared_passage(w, separate, "road", h, PackedByteArray()) == separate, "separate alternative route survives")
	var protected := PackedByteArray()
	protected.resize(w.N); protected.fill(1)
	check(StageTrails._shared_passage(w, line, "road", h, protected) == line, "structure axes remain fixed")
	w.cost.resize(w.N); w.cost.fill(1.0)
	Grid.stamp_path(w.path_mask, w.W, w.H, w.trails[0].pts, 3, 0.9 * 0.5 - Grid.PATH_IN)
	var search_path := PackedInt32Array()
	for x in range(8, 89): search_path.append(49 * w.W + x)
	StageTrails._add_trail(w, search_path, "road", PackedFloat32Array(), PackedByteArray(), h)
	check(w.path_mask[49 * w.W + 40] == 0, "search cells do not leave a ghost road beside the consolidated passage")
	w.trails.resize(1)
	if DisplayServer.get_name() == "headless":
		quit(1 if fails else 0)
		return
	DirAccess.make_dir_recursive_absolute(out)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.5, 0.6, 0.7)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color.WHITE
	env.environment.ambient_light_energy = 0.5
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, 25, 0)
	root.add_child(sun)
	node = MeshInstance3D.new(); root.add_child(node)
	camera = Camera3D.new(); root.add_child(camera); camera.make_current()
	DisplayServer.window_set_size(Vector2i(1000, 650))
	for version: String in ["before", "after"]:
		var route := {kind = "road", pts = loops if version == "before" else closed}
		RoadSurface.assign_route(w, route)
		w.trails.resize(1); w.trails.append(route)
		h = Heightfield.new(w)
		var arrays := TerrainBuilder.build_arrays(w, h, Rect2i(8, 35, 80, 28))
		var mesh := ArrayMesh.new(); mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var base := Image.create(32, 32, false, Image.FORMAT_RGB8); base.fill(Color(0.32, 0.48, 0.20))
		mesh.surface_set_material(0, GameContext.scope.terrain.material(base)); node.mesh = mesh
		for view: String in ["side", "ride"]:
			var p := Vector3(190, h.ground_at(190, 190), 190)
			var from := p + Vector3(-15, 20, 28) if view == "side" else p + Vector3(-13, 1.5, 6)
			camera.look_at_from_position(from, p + Vector3(12, 0, 6), Vector3.UP)
			for frame in 8: await process_frame
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(out.path_join(version + "_" + view + ".png"))
	quit(1 if fails else 0)
