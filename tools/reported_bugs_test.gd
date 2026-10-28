extends SceneTree
## Isolated regressions for the screenshot bug report; no world generation.
const Wind = preload("res://scripts/render/speed_wind.gd")

class RiverGround extends Heightfield:
	func _init(w: WorldData) -> void:
		super()
		world = w
	func ground_at(x: float, _z: float, _raw := false) -> float:
		return 98.0 if x > 118.0 and x < 138.0 else 100.0
	func depth_at(x: float, z: float, _feet := -INF) -> float:
		return maxf(0.0, 99.0 - ground_at(x, z))
	func surface_at(x: float, z: float, _feet := -INF) -> float:
		return ground_at(x, z)
	func deck_at(_x: float, _z: float, _feet: float) -> float:
		return -INF
	func wall_at(_x: float, _z: float, _feet: float, _r := 0.0) -> bool:
		return false

class OpenCamera extends PlayerCameraController:
	func _cam_blocked(_p: Vector3, _feet: float) -> bool:
		return false

var fails := 0

func check(ok: bool, label: String) -> void:
	print(("OK " if ok else "FAIL ") + label)
	fails += int(not ok)

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	run.call_deferred()

func run() -> void:
	check_bridge()
	check_rocks()
	check_speed()
	var scene: GameWorld = load("res://scenes/game_world.tscn").instantiate()
	var sun := scene.get_node("Sun") as DirectionalLight3D
	check(is_equal_approx(sun.directional_shadow_max_distance, 220.0), "sun shadows stay within the measured frame budget")
	check(sun.directional_shadow_split_1 * sun.directional_shadow_max_distance <= 40.0, "first shadow cascade retains contact detail")
	scene.free()
	if "--capture" in OS.get_cmdline_user_args():
		await capture()
	for child in root.get_children(): child.free()
	GameContext.scope.terrain.reset()
	await process_frame
	print("reported_bugs_test: %d failures" % fails)
	quit(1 if fails else 0)

func check_bridge() -> void:
	var w := WorldData.new()
	w.W = 64
	w.H = 64
	w.N = w.W * w.H
	var h := RiverGround.new(w)
	var path := PackedInt32Array()
	for y in range(8, 25): path.append(y * w.W + 28)
	var start := path.size() - 1
	path.append_array(Grid.line_cells(29, 24, 34, 10, w.W))
	var shore := path.size()
	for y in range(10, 27): path.append(y * w.W + 35)
	var wet := PackedByteArray()
	for cell in path:
		wet.append(int(h.depth_at((cell % w.W + 0.5) * 4, (cell / w.W + 0.5) * 4) > 0.3))
	var on_axis := PackedByteArray()
	on_axis.resize(w.N)
	var site := StageTrails._bridge_site(h, path, wet, start, shore, path.slice(0, start + 1), on_axis)
	check(site.x >= 0 and site.y >= 0, "winding river approach finds a safe crossing")
	if site.x >= 0:
		var axis := h._axis(path[site.x], path[site.y], false)
		check(axis.len <= 28.1, "bridge cuts across the river instead of following its bend")
		check(start - site.x > 3 or site.y - shore > 6, "crossing uses the expanded approach search")
		check(StageTrails._bridge_clear(h, path[site.x], path[site.y]), "shorter bridge retains dry full-width landings")
		on_axis[path[start - 1]] = 1
		var locked := StageTrails._bridge_site(h, path, wet, start, shore, path.slice(0, start + 1), on_axis)
		check(locked.x >= start - 1, "approach does not rewrite an existing structure axis")

func check_rocks() -> void:
	var layer := VegetationLayer.new()
	var mesh := Models.boulder(Vector3(1.3, 0.78, 1.05), 71, 0.7)
	layer._defs = {Biomes.T_ROCK: {box = mesh.get_aabb(), crown = mesh, leaves = [Color.WHITE]}}
	var normal := Vector3(-0.8, 1.0, 0.3).normalized()
	var items := {x = PackedFloat64Array([2.5]), y = PackedFloat64Array([3.5]),
		k = PackedInt32Array([Biomes.T_ROCK]), v = PackedInt32Array([0]),
		s = PackedFloat64Array([1.0]), ground = PackedFloat32Array([10.0]), normals = PackedVector3Array([normal])}
	var built := layer._build_entries(items)
	var entry: Dictionary = built.entries[0]
	var b: PackedFloat32Array = entry.cbuf
	var xf := Transform3D(Basis(Vector3(b[0], b[4], b[8]), Vector3(b[1], b[5], b[9]), Vector3(b[2], b[6], b[10])), Vector3(b[3], b[7], b[11]))
	check(xf.basis.y.normalized().dot(normal) > 0.999, "rock base follows the terrain normal")
	check(xf.origin.y < items.ground[0], "rock is embedded in the ground")
	check(entry.bounds.is_equal_approx(xf * mesh.get_aabb()), "rock render buffer and culling bounds agree")
	check(b == layer._build_entries(items).entries[0].cbuf, "rock placement is deterministic")
	layer.free()

func check_speed() -> void:
	var controller := OpenCamera.new()
	controller.settings = GameSettings.new()
	controller.heights = RiverGround.new(WorldData.new())
	var player := PlayerState.new()
	var bike := BikeRide.new()
	var camera := Camera3D.new()
	root.add_child(camera)
	bike.riding = true
	bike.speed = GameConfig.BIKE_SPEED
	for i in 120: controller.update(1.0, 1.0 / 60, player, bike, camera, i / 60.0, false, false, false, false, 70, 0)
	check(controller._speed_rush > 0.2, "wind is visible at normal cruising speed")
	bike.riding = false
	for i in 180: controller.update(1.0, 1.0 / 60, player, bike, camera, 3, false, false, false, false, 70, 0)
	check(controller._speed_rush < 0.01, "wind fades away on foot")
	camera.free()

func capture() -> void:
	root.size = Vector2i(1280, 720)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color("809eae")
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_energy = 0.35
	root.add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-22, -35, 0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 220
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 1.2
	root.add_child(sun)
	var floor_node := MeshInstance3D.new()
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(100, 100)
	floor_node.mesh = floor_mesh
	root.add_child(floor_node)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for tri in [[Vector3(-20, 0, -20), Vector3(0, 15, -15), Vector3(20, 0, -20)],
		[Vector3(-20, 0, -20), Vector3(0, 0, 12), Vector3(0, 15, -15)],
		[Vector3(0, 15, -15), Vector3(0, 0, 12), Vector3(20, 0, -20)]]:
		for vertex: Vector3 in tri: st.add_vertex(vertex)
	st.generate_normals()
	var terrain := PlanTerrain.new()
	root.add_child(terrain)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("849573")
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	terrain.setup({Vector2i.ZERO: st.commit().surface_get_arrays(0)}, material)
	terrain.update(0, 0, true)
	check(terrain.nodes[Vector2i.ZERO].cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED, "terrain chunks cast two-sided shadows")
	for i in 9:
		var rock := MeshInstance3D.new()
		rock.mesh = Models.boulder(Vector3(1.3, 0.78, 1.05), 71 + i * 13, 0.4)
		rock.position = Vector3(-14 + i * 3.3, 0, 6)
		root.add_child(rock)
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.look_at_from_position(Vector3(35, 22, 45), Vector3(0, 4, -5))
	var canvas := CanvasLayer.new()
	root.add_child(canvas)
	var wind := Wind.new()
	canvas.add_child(wind)
	wind.update_effect(0.8, 0.3)
	for i in 8: await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	check(image.save_png("res://.godot/reported_bugs.png") == OK, "visual fixture captured")
