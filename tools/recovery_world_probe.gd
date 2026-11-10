extends SceneTree
## One cold, cache-free comparison scene. No bike-park network or saves.
var camera: Camera3D
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 180)
	run.call_deferred()
func run() -> void:
	var args := OS.get_cmdline_user_args()
	var out := args[0] if not args.is_empty() else "res://.godot/recovery_world"
	var side := int(args[1]) if args.size() > 1 else 256
	DirAccess.make_dir_recursive_absolute(out)
	var started := Time.get_ticks_msec()
	var w := WorldGenerator._geography("Ущелье", side)
	w.start_noise_fields()
	StageLandmarks.run(w)
	StageTrails.run(w, func(_p: float, _label: String) -> void: pass)
	RoadSurface.run(w)
	var h := Heightfield.new(w)
	w.clear_noise_fields()
	var huts := 0
	var bad := 0
	var records: Array = []
	for s: SettlementData in w.settlements:
		for hut: HutData in s.huts:
			huts += 1
			var fits := StageLandmarks._fits(w, h, w.river_cells(), Vector2(hut.x, hut.y), hut.a, hut.t)
			bad += int(not fits)
			records.append({x=hut.x,y=hut.y,a=hut.a,kind=hut.t,fits=fits})
	var report := {seed="Ущелье", side=side, cache=false, elapsed_ms=Time.get_ticks_msec()-started,
		settlements=w.settlements.size(), huts=huts, invalid_huts=bad, roads=w.trails.size(), bridges=w.bridges.size(), tunnels=w.tunnels.size(),
		h_geo=hash(w.h), h_paths=hash(w.trails), profile=w.generation_profile, buildings=records}
	FileAccess.open(out.path_join("report.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	print("WORLD ", JSON.stringify({settlements=report.settlements,huts=huts,invalid_huts=bad,roads=report.roads,bridges=report.bridges,tunnels=report.tunnels,elapsed_ms=report.elapsed_ms,h_geo=report.h_geo,h_paths=report.h_paths}))
	if DisplayServer.get_name() == "headless":
		quit()
		return
	DisplayServer.window_set_size(Vector2i(1280,720))
	root.size = Vector2i(1280,720)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.5,0.65,0.8)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color.WHITE
	env.environment.ambient_light_energy = 0.6
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55,35,0)
	root.add_child(sun)
	var scene := Node3D.new()
	root.add_child(scene)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, TerrainBuilder.build_arrays(w,h))
	var terrain := MeshInstance3D.new()
	terrain.mesh = mesh
	var image := Image.create(w.W,w.H,false,Image.FORMAT_RGB8)
	for y in w.H:
		for x in w.W:
			image.set_pixel(x,y,Color(0.35,0.44,0.26) if w.ocean[y*w.W+x] == 0 else Color(0.25,0.4,0.6))
	terrain.material_override = GameContext.scope.terrain.material(image)
	scene.add_child(terrain)
	SettlementsBuilder.build(scene,w,h)
	StructuresBuilder.build(scene,h)
	camera = Camera3D.new()
	camera.far = maxf(3000, side * 8.0)
	scene.add_child(camera)
	camera.make_current()
	var s: SettlementData = w.settlements[0]
	var at := Vector3(s.x*GameConfig.TILE,h.ground_at(s.x*GameConfig.TILE,s.y*GameConfig.TILE),s.y*GameConfig.TILE)
	for view: String in ["settlement", "road", "network"]:
		camera.projection = Camera3D.PROJECTION_PERSPECTIVE
		if view == "settlement": camera.look_at_from_position(at+Vector3(42,34,48),at)
		elif view == "road": camera.look_at_from_position(at+Vector3(8,2.0,16),at+Vector3(0,1.5,-20))
		else:
			camera.projection = Camera3D.PROJECTION_ORTHOGONAL
			camera.size = side * GameConfig.TILE * 1.1
			var center := side * GameConfig.TILE * 0.5
			camera.look_at_from_position(Vector3(center,side*6,center+1),Vector3(center,0,center))
		for frame in 8: await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(out.path_join(view+".png"))
	print("CAPTURES ",out)
	quit()
