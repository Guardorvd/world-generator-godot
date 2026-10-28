extends SceneTree
## Один изолированный пакет: навигация, Y, безопасность размещения, посадка и UI.
const Roads = preload("res://scripts/game/road_navigation.gd")
const Line = preload("res://scripts/render/navigation_line.gd")
const Placement = preload("res://scripts/render/bike_placement.gd")
class TestWorld extends WorldData:
	func tile_info(_x: float, _z: float) -> Dictionary:
		return {biome = Biomes.GRASS, path = 0, surface = RoadSurface.NONE}
class TestGround extends Heightfield:
	var flooded := false
	var cliff := false
	var gap := false
	var roof := INF
	var wall := Rect2()
	var river := false
	var bridge := false
	func _init(w: WorldData) -> void:
		super()
		world = w
	func ground_at(x: float, _z: float, _raw := false) -> float:
		return 80.0 if (cliff and x >= 40) or (gap and absf(x - 40) < 0.3) else 100.0
	func surface_at(x: float, z: float, feet := -INF) -> float:
		return maxf(ground_at(x, z), deck_at(x, z, feet))
	func depth_at(x: float, z: float, feet := -INF) -> float:
		if deck_at(x,z,feet) > -INF: return 0.0
		return 0.0 if bridge and z > 29 and z < 35 else (2.0 if flooded or (river and x > 36 and x < 44) else 0.0)
	func known(x: float, z: float) -> bool:
		return x >= 4 and z >= 4 and x < 252 and z < 252
	func wall_at(x: float, z: float, feet: float, radius := 0.0) -> bool:
		return wall.grow(radius).has_point(Vector2(x, z)) if wall.has_area() else super.wall_at(x, z, feet, radius)
	func ceiling_at(x: float, z: float, feet: float) -> float:
		return minf(roof, super.ceiling_at(x, z, feet))
var fails := 0
var checks := 0
var w := TestWorld.new()
var h: TestGround

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 180)
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	print(("OK " if ok else "FAIL ") + label)
	if not ok: fails += 1

func trail(points: Array[Vector2]) -> Dictionary:
	var pts: Array = []
	for p in points: pts.append({x = p.x / 4.0, y = p.y / 4.0})
	return {kind = "road", pts = pts}

func run() -> void:
	w.W = 64
	w.H = 64
	w.N = 4096
	w.available_rect = Rect2i(0, 0, 64, 64)
	h = TestGround.new(w)
	h.obstacles = ForestObstacles.new(w, h)
	_check_mount()
	_check_dismount()
	check_navigation()
	await check_placement()
	print("Navigation + placement: %d checks, %d failures" % [checks, fails])
	quit(1 if fails else 0)

func check_navigation() -> void:
	h.obstacles = ForestObstacles.new(w, h)
	h.wall = Rect2(36, 30, 8, 20)
	var short: Array[Vector2] = [Vector2(20,40)]
	for x in range(20, 61, 4): short.append(Vector2(x,54))
	short.append(Vector2(60,40))
	w.trails = [trail(short), trail([Vector2(20,40),Vector2(20,15),Vector2(60,15),Vector2(60,40)])]
	var roads := Roads.new()
	roads.build(w, h)
	var route := roads.route_to(Vector2(20,40), Vector2(60,40), 100)
	check(roads.complete and roads._length(route) < 80 and route.has(Vector2(40,54)), "Route uses shorter road with more vertices rather than fewer hops")
	check(not route.has(Vector2(20,15)), "Long detour loses to the shorter branch")
	var count := roads.points.size()
	roads.build(w, h)
	check(roads.points.size() == count, "Rebuilding graph clears stale nodes")
	w.trails = []
	roads.build(w,h)
	route = roads.route_to(Vector2(20,40), Vector2(60,40),100)
	var clear := not route.is_empty()
	for i in range(1, route.size()): clear = clear and roads._segment(route[i-1],route[i],100) < INF
	check(clear and route.size() > 2, "Offroad approach detours around a wall instead of drawing through it")
	h.wall = Rect2()
	h.river = true
	roads.build(w,h)
	check(roads.route_to(Vector2(20,32),Vector2(60,32),100).is_empty(), "Unfordable river without a crossing yields no invented path")
	h.bridge = true
	roads.build(w,h)
	check(not roads.route_to(Vector2(20,32),Vector2(60,32),100).is_empty(), "Same river uses a passable bridge corridor")
	h.bridge = false
	h.river = false
	h.cliff = true
	roads.build(w,h)
	check(roads.route_to(Vector2(20,32),Vector2(60,32),100).is_empty(), "Cliff is not a walkable navigation shortcut")
	h.cliff = false
	h.roof = 101
	roads.build(w,h)
	check(roads.route_to(Vector2(20,32),Vector2(60,32),100).is_empty(), "Low ceiling is not treated as a passage")
	h.roof = INF
	# Эти координаты имели одинаковый линейный id при W=64.
	w.trails = [trail([Vector2(2,6)*4,Vector2(3,6)*4]),trail([Vector2(66,5)*4,Vector2(67,5)*4])]
	roads.build(w)
	check(roads.points.size() == 4, "Outer and negative-world cells cannot alias inner graph nodes")
	w.trails = [{kind="animal",pts=[{x=5,y=5},{x=15,y=15}]}]
	roads.build(w)
	check(roads.points.is_empty(), "Animal tracks do not become roads in the graph")
	w.trails = [trail([Vector2(20,120),Vector2(20,20)])]
	var line := Line.new()
	root.add_child(line)
	line.setup(w,h)
	line.set_goal({kind="marker",x=5.0,y=5.0},Vector2(20,120))
	line.update_line(Vector3(20,100,120),0.3,true)
	check(line.mesh.get_surface_count() == 1, "Selected goal renders near the player")
	var searches: int = line.roads.searches
	for i in 20: line.update_line(Vector3(20,100,120),0.25,true)
	check(line.roads.searches == searches, "Following a route does not search every frame")
	line.update_line(Vector3(20,100,130),0.3,true)
	check(line._wrong > 0.9, "Wrong-way movement gives a warning")
	line.update_line(Vector3(20,100,100),0.5,true)
	line.update_line(Vector3(20,100,90),0.5,true)
	check(line._wrong == 0, "Correct direction clears the warning")
	check(not line.can_arrive(Vector3(20,90,20)), "Marker cannot be completed from the wrong bridge/terrain level")
	line.update_line(Vector3(100,100,90),2.5,true)
	check(line.path[0].distance_to(Vector2(100,90)) < 0.1, "Off-route movement rebuilds from the current position")
	w.territory_revision += 1
	line.update_line(Vector3(100,100,90),0.3,true)
	check(line.roads.searches > searches + 1, "Territory revision refreshes the road graph")
	line.update_line(Vector3(100,100,90),0.3,false)
	check(not line.visible, "Map/photo/placement can hide navigation")
	line.set_goal({},Vector2.ZERO)
	check(line.path.is_empty() and line.mesh.get_surface_count()==0, "Clearing a goal immediately clears its geometry")
	line.set_goal({kind="lake",x=12.0,y=12.0,src={sx=5.0,sy=5.0}},Vector2(20,120))
	check(line._target == Vector2(20,20), "Lake goal targets its bank")
	line.free()
	w.trails = []

func check_placement() -> void:
	var shell: Node = load("res://scenes/main.tscn").instantiate()
	shell.set_script(null)
	root.add_child(shell)
	var hud: Hud = shell.get_node("%Hud")
	for child in hud.get_parent().get_children():
		if child is Control and child != hud: child.hide()
	hud.show()
	hud.lock_hint.hide()
	var map := Image.create(64,64,false,Image.FORMAT_RGB8)
	map.fill(Color("4a6650"))
	hud.set_world(w,map)
	var game: GameWorld = load("res://scenes/game_world.tscn").instantiate()
	game.set_process(false)
	game.set_physics_process(false)
	root.add_child(game)
	game.set_process(false)
	game.set_physics_process(false)
	game.world = w
	game.heights = h
	game.hud = hud
	game.player = PlayerState.new()
	game.player.x=32
	game.player.z=40
	game.player.feet=100
	game.bike = BikeRide.new()
	game.bike.x=180
	game.bike.z=180
	game.bike.y=90
	game.bike.fallen=true
	game.bike_view = load("res://scenes/bike.tscn").instantiate()
	game.add_child(game.bike_view)
	game.bike_view.snap(game.bike)
	game.bike_view.draw(1)
	game.bike_view.set_lamp(true)
	game.photo = preload("res://scripts/render/photo_camera.gd").new()
	game.add_child(game.photo)
	game.crash = BikeCrash.new()
	game.add_child(game.crash)
	game.camera.position=Vector3(32,101.7,40)
	game.camera.look_at(Vector3(32,100,36))
	game.yaw=0
	game.pitch=-0.35
	var same_bike := game.bike
	var player_at := Vector3(game.player.x,game.player.feet,game.player.z)
	check(game.toggle_bike_placement(), "Y enters placement even if the old bike is far away and fallen")
	check(game.bike.x==180 and game.bike.fallen, "Preview does not alter or duplicate the stored bike")
	game._update_hints()
	var preview: Placement = game.bike_placement
	check(preview.valid and preview.visible and preview._ghost.get_node_or_null("Rider")==null, "Green preview is a bike without rider or physics bodies")
	var initial_heading: float = preview.heading
	preview.rotate_by(PI/2)
	game._update_bike_placement(0)
	check(absf(angle_difference(initial_heading,preview.heading)-PI/2)<0.01, "Preview heading can be rotated")
	var initial_distance: float = Vector2(preview.candidate.position.x-32,preview.candidate.position.z-40).length()
	Input.action_press("move_back")
	game._update_bike_placement(0.25)
	Input.action_release("move_back")
	check(Vector2(preview.candidate.position.x-32,preview.candidate.position.z-40).length() < initial_distance-0.3,"W/S changes actual preview distance")
	game._cancel_bike_placement()
	check(game.bike.x==180 and not preview.active, "Cancel leaves the bike untouched")
	game.toggle_bike_placement()
	h.flooded=true
	game._update_bike_placement(0)
	check(not preview.valid and not game.confirm_bike_placement() and game.bike.x==180, "Deep water rejects preview and confirmation without losing the bike")
	if "--capture" in OS.get_cmdline_user_args(): await capture(game,"blocked")
	h.flooded=false
	h.roof=101
	game._update_bike_placement(0)
	check(not preview.valid,"Low ceiling rejects placement")
	h.roof=INF
	h.wall=Rect2(29,37,6,0.2)
	game._update_bike_placement(0)
	check(not preview.valid,"Visible space across a thin wall cannot receive a bike")
	h.wall=Rect2()
	game._update_bike_placement(0)
	if "--capture" in OS.get_cmdline_user_args(): await capture(game,"valid")
	check(game.confirm_bike_placement(),"Confirmation places the chosen preview")
	check(game.bike==same_bike and not game.bike.fallen and not game.bike.riding and game.bike_view.lamp_on(),"Same bike and lamp survive placement with motion/fallen state cleared")
	check(Vector3(game.player.x,game.player.feet,game.player.z)==player_at,"Placement never teleports the player")
	game.player.x=game.bike.x+0.9
	game.player.z=game.bike.z
	check(game.bike.prepare_mount(game.player,w,h),"Placed bike can actually be mounted from its free side")
	game.toggle_bike_placement()
	var escape := InputEventKey.new()
	escape.physical_keycode=KEY_ESCAPE
	escape.pressed=true
	game._unhandled_input(escape)
	check(not game._placing_bike(),"Esc cancels placement before requesting pause")
	game.paused=true
	check(not game.toggle_bike_placement(),"Pause cannot start placement")
	game.paused=false
	game.bike.airborne=true
	check(not game.toggle_bike_placement(),"Airborne bike cannot be frozen and placed mid-flight")
	game.bike.airborne=false
	game.crash.phase=BikeCrash.Phase.BALANCE
	check(not game.toggle_bike_placement(),"Placement waits for active fall recovery")
	game.crash.phase=BikeCrash.Phase.NONE
	game.show_map=true
	check(not game.toggle_bike_placement(),"Map input cannot accidentally open placement")
	game.show_map=false
	var key := InputEventKey.new()
	key.physical_keycode=KEY_Y
	key.pressed=true
	game._unhandled_input(key)
	check(game._placing_bike(),"Physical Y action opens preview through game input")
	game._unhandled_input(key)
	check(not game._placing_bike(),"Second Y cancels without committing")
	# Верх моста и поверхность под ним выбираются по уровню игрока, без прыжка между этажами.
	h.structures=[{tunnel=false,ax=32.0,az=20.0,ay=104.0,bx=32.0,bz=60.0,by=104.0,len=40.0,ux=0.0,uz=1.0,half=2.2,arch=0.0,style="wood",rails=true}]
	for z in range(4,17):
		for x in range(6,11): h._cells[z*w.W+x]=[0]
	preview.begin(w,h,Vector3(32,104,40),0)
	preview.update_preview(Vector3(32,105.7,40),Vector3(0,-0.4,-1).normalized(),0)
	check(preview.valid and absf(preview.candidate.position.y-104)<0.01,"Bridge preview stays on its deck")
	preview.begin(w,h,Vector3(32,100,40),0)
	preview.update_preview(Vector3(32,101.7,40),Vector3(0,-0.4,-1).normalized(),0)
	check(absf(preview.candidate.position.y-100)<0.01,"Preview under bridge does not jump to the upper deck")
	preview.cancel()
	h.structures.clear()
	h._cells.clear()
	hud.set_goal({kind="marker",key="test",name="Метка",x=8.0,y=10.0})
	check(not hud.at_place(hud.goal,40,40) and hud.at_place(hud.goal,34,40),"Free marker requires getting close rather than passing ten meters away")
	game.free()
	shell.free()

func capture(game: GameWorld, mode: String) -> void:
	var plane := MeshInstance3D.new()
	var shape := PlaneMesh.new()
	shape.size=Vector2(40,40)
	plane.mesh=shape
	plane.position=Vector3(32,99.99,36)
	var mat := StandardMaterial3D.new()
	mat.albedo_color=Color("7b8664")
	plane.material_override=mat
	game.add_child(plane)
	game._update_hints()
	game.hud.lock_hint.hide() # изолированная сцена не запускает обычный GameWorld._process
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://tools/control/runs/placement_"+mode+".png")
	plane.free()

func _check_mount() -> void:
	var p := PlayerState.new()
	p.x = 39.0
	p.z = 40.0
	p.feet = 100.0
	var b := BikeRide.new()
	b.x = 41.0
	b.z = 40.0
	b.y = 100.0
	h.obstacles._add(40, 20, 40, 60, 0.1, 100, INF)
	check(not b.prepare_mount(p, w, h), "стоячий велосипед тоже нельзя оседлать через стену")
	h.obstacles = ForestObstacles.new(w, h)
	h.gap = true
	check(not b.prepare_mount(p, w, h), "стоячий велосипед нельзя оседлать через провал")
	h.gap = false
	check(b.prepare_mount(p, w, h), "обычная посадка на свободном месте работает")


func _check_dismount() -> void:
	var b := BikeRide.new()
	b.x = 40.4
	b.z = 40.0
	b.y = 100.0
	var p := PlayerState.new()
	h.obstacles = ForestObstacles.new(w, h)
	# Тонкая стена между рамой и свободной точкой слева.
	h.obstacles._add(39.95, 20, 39.95, 60, 0.05, 100, INF)
	b.mount(p)
	b.bottom_out = 2.0
	b.dismount(p, w, h)
	check(p.x > 40.0 and not b.riding, "сход не переносит пешехода сквозь тонкую стену")
	check(b.bottom_out == 0.0, "сход очищает отложенный стук подвески")
	h.obstacles = ForestObstacles.new(w, h)
	h.cliff = true
	b.x = 39.6
	b.heading = PI
	b.mount(p)
	b.dismount(p, w, h)
	check(p.x < 40.0 and p.feet == 100.0, "сход у обрыва выбирает опору на прежнем уровне")
	h.cliff = false
	h.gap = true
	b.x = 40.4
	b.heading = 0.0
	b.mount(p)
	b.dismount(p, w, h)
	check(p.x > 40.0, "сход не перескакивает узкий провал")
	h.gap = false
	b.mount(p)
	b.dismount(p, w, h)
	check(is_equal_approx(p.x, b.x - 0.9), "на свободной земле сохраняется обычный сход слева")
