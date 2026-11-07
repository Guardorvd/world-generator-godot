extends SceneTree
## Paired relief-only captures from structural_relief_test, no world generation.
## Baseline chooses the summit and a moderate flank; camera x/z, direction, light
## and material stay fixed. Rider eye follows each version's ground at +1.8 m.
const OUT := "res://.godot/structural_relief"
const N := 768
const SIZE := 256
var cam: Camera3D
var terrain: MeshInstance3D

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	call_deferred("run")

func ground(h: PackedFloat32Array, p: Vector2) -> float:
	var q := (p/4.0).clamp(Vector2.ZERO,Vector2.ONE*(N-2))
	var x := int(q.x); var y := int(q.y)
	return lerpf(lerpf(h[y*N+x],h[y*N+x+1],q.x-x),lerpf(h[(y+1)*N+x],h[(y+1)*N+x+1],q.x-x),q.y-y)*GameConfig.HS

func mesh(h: PackedFloat32Array, origin: Vector2i) -> ArrayMesh:
	var vertices := PackedVector3Array(); var normals := PackedVector3Array()
	var colors := PackedColorArray(); var indices := PackedInt32Array()
	for y in SIZE:
		for x in SIZE:
			var i := (origin.y+y)*N+origin.x+x
			var v := h[i]*GameConfig.HS
			vertices.append(Vector3((origin.x+x)*4.0,v,(origin.y+y)*4.0))
			var dx := (h[i+1]-h[i-1])*GameConfig.HS/8.0
			var dz := (h[i+N]-h[i-N])*GameConfig.HS/8.0
			normals.append(Vector3(-dx,1,-dz).normalized())
			colors.append(Color(0.44,0.49,0.36) if v<120 else Color(0.58,0.56,0.50))
	for y in SIZE-1:
		for x in SIZE-1:
			var i := y*SIZE+x
			indices.append_array(PackedInt32Array([i,i+1,i+SIZE,i+1,i+SIZE+1,i+SIZE]))
	var arrays := []; arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX]=vertices; arrays[Mesh.ARRAY_NORMAL]=normals
	arrays[Mesh.ARRAY_COLOR]=colors; arrays[Mesh.ARRAY_INDEX]=indices
	var result := ArrayMesh.new(); result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	return result

func run() -> void:
	root.size=Vector2i(1280,720)
	var scene := Node3D.new(); root.add_child(scene)
	var env := WorldEnvironment.new(); env.environment=Environment.new()
	env.environment.background_mode=Environment.BG_COLOR
	env.environment.background_color=Color(0.62,0.75,0.88)
	env.environment.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color=Color(0.7,0.75,0.85)
	env.environment.ambient_light_energy=0.4; scene.add_child(env)
	var sun := DirectionalLight3D.new(); sun.rotation_degrees=Vector3(-22,-70,0)
	sun.light_energy=1.6; sun.shadow_enabled=false; scene.add_child(sun)
	cam=Camera3D.new(); cam.fov=68; cam.far=8000; scene.add_child(cam)
	terrain=MeshInstance3D.new(); scene.add_child(terrain)
	var mat := StandardMaterial3D.new(); mat.vertex_color_use_as_albedo=true
	mat.roughness=1.0; terrain.material_override=mat
	var cameras := {}
	for seed_text: String in ["Вальхейм 3","Север-1234","Ущелье"]:
		var before: Dictionary=FileAccess.open(OUT.path_join(seed_text+"_before.bin"),FileAccess.READ).get_var()
		var after: Dictionary=FileAccess.open(OUT.path_join(seed_text+"_after.bin"),FileAccess.READ).get_var()
		var h: PackedFloat32Array=before.h
		var game := "--game" in OS.get_cmdline_user_args()
		var tag := "_game" if game else ""
		# Choose all cameras from GEO 7 even when viewing the finished game surface.
		var top := 0
		for i in h.size():
			if h[i]>h[top]: top=i
		var origin := Vector2i(clampi(top%N-SIZE/2,1,N-SIZE-2),clampi(top/N-SIZE/2,1,N-SIZE-2))
		var peak := Vector3((top%N)*4.0,h[top]*GameConfig.HS,(top/N)*4.0)
		# A camera on a 12–45% baseline flank, away from mesh edges, chosen entirely
		# from the old relief: closest such point to 180 m southwest of the summit.
		var wanted := Vector2(peak.x,peak.z)+Vector2(-180,180)
		var best := INF; var flank := Vector2.ZERO
		for y in range(origin.y+24,origin.y+SIZE-24):
			for x in range(origin.x+24,origin.x+SIZE-24):
				var i := y*N+x
				var g := Vector2(h[i+1]-h[i-1],h[i+N]-h[i-N])*GameConfig.HS/8.0
				if g.length()<0.12 or g.length()>0.45 or h[i]<0.2: continue
				var p := Vector2(x,y)*4.0; var d := p.distance_squared_to(wanted)
				if d<best: best=d; flank=p
		var fi := int(flank.y/4)*N+int(flank.x/4)
		var downhill := Vector2(h[fi-1]-h[fi+1],h[fi-N]-h[fi+N]).normalized()
		cameras[seed_text]={origin=origin,peak=peak,flank=flank,downhill=downhill}
		for version: String in ["before","after"]:
			var field: PackedFloat32Array=before.h if version=="before" else after.h
			if game:
				var data: Dictionary=FileAccess.open(OUT.path_join(seed_text+"_game_"+version+".bin"),FileAccess.READ).get_var()
				field=data.h
			terrain.mesh=mesh(field,origin)
			var rider := Vector3(flank.x,ground(field,flank)+1.8,flank.y)
			var contour := Vector2(-downhill.y,downhill.x)
			var across := (contour+downhill*0.6).normalized()
			var views := {
				overview=[peak+Vector3(-500,300,500),peak*Vector3(1,0.65,1)],
				player=[rider,rider+Vector3(across.x,-0.10,across.y)*120],
				downhill=[rider,rider+Vector3(downhill.x,-0.18,downhill.y)*120],
				close=[rider+Vector3(0,15,0),rider+Vector3(downhill.x,-0.1,downhill.y)*100],
			}
			for view: String in views:
				cam.look_at_from_position(views[view][0],views[view][1],Vector3.UP)
				for k in 4: await process_frame
				await RenderingServer.frame_post_draw
				var file := OUT.path_join(seed_text+"_"+view+tag+"_"+version+".png")
				root.get_texture().get_image().save_png(file); print("SHOT ",file)
	FileAccess.open(OUT.path_join("cameras.json"),FileAccess.WRITE).store_string(JSON.stringify(cameras,"\t"))
	quit()
