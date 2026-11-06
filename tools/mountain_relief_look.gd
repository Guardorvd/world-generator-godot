extends SceneTree
const DIR := "res://.godot/mountain_review"
var data: Dictionary
var mesh_node: MeshInstance3D
var camera: Camera3D
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self,120)
	call_deferred("run")
func ground(h: PackedFloat32Array, x: float, z: float) -> float:
	return h[clampi(roundi(z/4),0,767)*768+clampi(roundi(x/4),0,767)]*GameConfig.HS
func terrain(h: PackedFloat32Array, bi: PackedByteArray) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var ns := PackedVector3Array()
	ns.resize(768*768)
	for z in range(0,768,2):
		for x in range(0,768,2):
			var i:=z*768+x
			ns[i]=Vector3((h[z*768+maxi(0,x-2)]-h[z*768+mini(767,x+2)])*GameConfig.HS,16,(h[maxi(0,z-2)*768+x]-h[mini(767,z+2)*768+x])*GameConfig.HS).normalized()
	for z in range(0,766,2):
		for x in range(0,766,2):
			for p: Vector2i in [Vector2i(x,z),Vector2i(x,z+2),Vector2i(x+2,z),Vector2i(x+2,z),Vector2i(x,z+2),Vector2i(x+2,z+2)]:
				var i:=p.y*768+p.x
				vertices.append(Vector3(p.x*4,h[i]*GameConfig.HS,p.y*4))
				normals.append(ns[i])
				var c: Array=Biomes.LIST[bi[i]].color
				colors.append(Color(0.53,0.57,0.50) if h[i]>0 else Color(0.15,0.3,0.4))
	var arrays:=[]
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX]=vertices;arrays[Mesh.ARRAY_NORMAL]=normals;arrays[Mesh.ARRAY_COLOR]=colors
	var mesh:=ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	return mesh
func run() -> void:
	root.size=Vector2i(1280,720)
	data=FileAccess.open(DIR.path_join("fields.bin"),FileAccess.READ).get_var()
	var scene:=Node3D.new()
	root.add_child(scene)
	var env:=WorldEnvironment.new()
	env.environment=Environment.new()
	env.environment.background_mode=Environment.BG_COLOR
	env.environment.background_color=Color(0.52,0.69,0.82)
	env.environment.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color=Color.WHITE
	env.environment.ambient_light_energy=0.25
	scene.add_child(env)
	var sun:=DirectionalLight3D.new()
	sun.rotation_degrees=Vector3(-35,-40,0)
	sun.light_energy=1.4
	scene.add_child(sun)
	camera=Camera3D.new();camera.fov=65;camera.far=12000
	scene.add_child(camera)
	mesh_node=MeshInstance3D.new()
	var mat:=StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo=true;mat.roughness=1;mat.cull_mode=BaseMaterial3D.CULL_DISABLED
	mesh_node.material_override=mat
	scene.add_child(mesh_node)
	var h:PackedFloat32Array=data.after
	var old:PackedFloat32Array=data.before
	var top:int=data.top_after
	var target:=Vector3((top%768)*4,h[top]*GameConfig.HS,(top/768)*4)
	var eye:=target+Vector3(-650,160,560)
	eye.y=maxf(eye.y,maxf(ground(h,eye.x,eye.z),ground(old,eye.x,eye.z))+80)
	var player:=eye
	var best:=-INF
	for angle in 48:
		var p:=Vector2(target.x,target.z)+Vector2.from_angle(angle*TAU/48)*700
		if p.x<16 or p.y<16 or p.x>3050 or p.y>3050:continue
		var a:=ground(h,p.x,p.y)
		var b:=ground(old,p.x,p.y)
		var score:=target.y-maxf(a,b)-absf(a-b)*30
		if score>best:best=score;player=Vector3(p.x,maxf(a,b)+1.8,p.y)
	var shoulder:=target+Vector3(200,45,-220)
	shoulder.y=maxf(ground(h,shoulder.x,shoulder.z),ground(old,shoulder.x,shoulder.z))+30
	var views:=[{name="silhouette",pos=eye},{name="player",pos=player},{name="slope",pos=shoulder}]
	var camera_file:=FileAccess.open(DIR.path_join("cameras.json"),FileAccess.WRITE)
	camera_file.store_string(JSON.stringify({target=target,views=views},"\t"))
	for version: String in ["before","after"]:
		mesh_node.mesh=terrain(data[version],data["biome_"+version])
		for v:Dictionary in views:
			camera.look_at_from_position(v.pos,target,Vector3.UP)
			for frame in 4:await process_frame
			await RenderingServer.frame_post_draw
			var path:=DIR.path_join(version+"_"+v.name+".png")
			root.get_texture().get_image().save_png(path)
			print("SHOT ",path)
	quit()

