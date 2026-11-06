extends SceneTree
const DIR := "res://.godot/plain_review"
var data: Dictionary
var mesh_node: MeshInstance3D
var camera: Camera3D
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self,120)
	call_deferred("run")
func ground(h: PackedFloat32Array, x: float, z: float) -> float:
	return h[clampi(roundi(z/4-.5),0,767)*768+clampi(roundi(x/4-.5),0,767)]*GameConfig.HS
func terrain(h: PackedFloat32Array, bi: PackedByteArray) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var ns := PackedVector3Array()
	ns.resize(768*768)
	for z in range(0,768):
		for x in range(0,768):
			var i:=z*768+x
			ns[i]=Vector3((h[z*768+maxi(0,x-1)]-h[z*768+mini(767,x+1)])*GameConfig.HS,8,(h[maxi(0,z-1)*768+x]-h[mini(767,z+1)*768+x])*GameConfig.HS).normalized()
	for z in range(0,767):
		for x in range(0,767):
			for p: Vector2i in [Vector2i(x,z),Vector2i(x,z+1),Vector2i(x+1,z),Vector2i(x+1,z),Vector2i(x,z+1),Vector2i(x+1,z+1)]:
				var i:=p.y*768+p.x
				vertices.append(Vector3(p.x*4+2,h[i]*GameConfig.HS,p.y*4+2))
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
	env.environment.ambient_light_energy=0.65
	scene.add_child(env)
	var sun:=DirectionalLight3D.new()
	sun.rotation_degrees=Vector3(-55,140,0)
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
	var target:Vector3=data.target
	var forward:=Vector3(1,0,0)
	var best:=INF
	for line:PackedVector3Array in data.roads_before:
		for k in range(line.size()-1):
			if line[k].distance_to(target)<best:
				best=line[k].distance_to(target)
				forward=(line[mini(k+6,line.size()-1)]-line[k]).normalized()
	var pos:=target-forward*12+Vector3(-forward.z,0,forward.x)*5
	pos.y=maxf(ground(h,pos.x,pos.z),ground(old,pos.x,pos.z))+1.8
	var views:=[{name="road_player",pos=pos,target=target+forward*55+Vector3(0,2,0)}, {name="plain",pos=target+Vector3(-140,24,100),target=target}]
	var camera_file:=FileAccess.open(DIR.path_join("cameras.json"),FileAccess.WRITE)
	camera_file.store_string(JSON.stringify({target=target,views=views},"\t"))
	var roads:=MeshInstance3D.new();scene.add_child(roads)
	for version: String in ["before","after"]:
		mesh_node.mesh=terrain(data[version],data["biome_"+version])
		roads.mesh=road_mesh(data["roads_"+version])
		for v:Dictionary in views:
			camera.look_at_from_position(v.pos,v.target,Vector3.UP)
			for frame in 4:await process_frame
			await RenderingServer.frame_post_draw
			var path:=DIR.path_join(version+"_"+v.name+".png")
			root.get_texture().get_image().save_png(path)
			print("SHOT ",path)
	quit()


func road_mesh(lines:Array)->ArrayMesh:
	var vertices:=PackedVector3Array()
	for line:PackedVector3Array in lines:
		for k in range(1,line.size()):
			var a:=line[k-1]+Vector3.UP*.1
			var b:=line[k]+Vector3.UP*.1
			var side:=Vector3(-(b-a).z,0,(b-a).x).normalized()*1.8
			for p:Vector3 in [a-side,b-side,a+side,a+side,b-side,b+side]:vertices.append(p)
	var arrays:=[];arrays.resize(Mesh.ARRAY_MAX);arrays[Mesh.ARRAY_VERTEX]=vertices
	var mesh:=ArrayMesh.new();mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	var mat:=StandardMaterial3D.new();mat.albedo_color=Color(.35,.24,.12);mat.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED;mat.cull_mode=BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0,mat)
	return mesh

