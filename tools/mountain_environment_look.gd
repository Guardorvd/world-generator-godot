extends SceneTree
## Paired production materials, objects, LOD and streaming over unchanged relief.
## Baseline scripts/shader are snapshots of HEAD in .godot/mountain_environment.
const OUT := "res://.godot/mountain_environment"
const Probe := preload("res://tools/mountain_detail_test.gd")
const Surface := preload("res://scripts/world/mountain_surface.gd")
const Floor := preload("res://scripts/render/forest_floor.gd")
const N := 768
const SIDE := 320
var base_rev := "cb4622c" # pass --base 3676c62 to review the original outcrop implementation
var failures := 0
var scene: Node3D
var camera: Camera3D

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self,480)
	var args := OS.get_cmdline_user_args()
	if "--base" in args: base_rev = args[args.find("--base") + 1]
	run.call_deferred()

func check(ok:bool,label:String) -> void:
	print("PASS " if ok else "FAIL ",label)
	failures+=int(not ok)

func rules() -> void:
	var e:=PackedFloat32Array();var s:=PackedFloat32Array();var m:=PackedFloat32Array()
	for i in N*N:
		e.append(float(i%997)/997.0);s.append(float(i%1237)/500.0);m.append(float(i%431)/431.0)
	var started:=Time.get_ticks_usec()
	var native:=Surface.field(e,s,m)
	var cold_ms:=(Time.get_ticks_usec()-started)/1000.0
	started=Time.get_ticks_usec()
	for repeat in 3: native=Surface.field(e,s,m)
	var native_ms:=(Time.get_ticks_usec()-started)/3000.0
	started=Time.get_ticks_usec()
	var reference:=Surface.reference_field(e,s,m)
	var reference_ms:=(Time.get_ticks_usec()-started)/1000.0
	check(native==reference,"native/reference exposure is byte-identical over 589824 varied cells")
	check(Surface.field(e,s,PackedFloat32Array())==Surface.reference_field(e,s,PackedFloat32Array()),"native/reference fallback moisture agrees")
	print("EXPOSURE native_ms=",native_ms," cold_ms=",cold_ms," reference_ms=",reference_ms)
	check(Surface.exposure(0.4,0.8,0.25)>Surface.exposure(0.4,0.8,0.85)*1.8,"dry exposed slope differs from sheltered wet slope at the same height")
	check(Surface.exposure(0.08,0.1,0.5)<0.001,"low gentle terrain keeps its existing communities")
	var f := {biome=PackedByteArray(),river=PackedByteArray(),village=PackedByteArray(),path=PackedByteArray(),
		elev=PackedFloat32Array(),slope=PackedFloat32Array(),moist=PackedFloat32Array(),dw=PackedFloat32Array(),dist_path=PackedFloat32Array(),forest=PackedFloat64Array(),stony=PackedFloat64Array()}
	for key:String in f: f[key].resize(32*32)
	f.biome.fill(Biomes.GRASS); f.elev.fill(0.4);f.slope.fill(0.3);f.moist.fill(0.5)
	f.dw.fill(100);f.dist_path.fill(100);f.stony.fill(0.5);f.forest.fill(0.1)
	f.rock=Surface.field(f.elev,f.slope,f.moist)
	for y in 32: f.path[y*32+16]=3
	var patterns := []
	var clear := true
	for pieces:Array in [[Rect2i(0,0,32,32)],[Rect2i(16,0,16,32),Rect2i(0,0,16,32)]]:
		var pattern:PackedStringArray=[]
		for rect:Rect2i in pieces:
			var store:=StageVegetation.ObjStore.new(null)
			store.begin_chunk(rect.position.x,rect.position.y,rect.end.x,rect.end.y)
			RockScatter.place_chunk(73,rect.position.x,rect.position.y,rect.end.x,rect.end.y,f,0,0,32,store)
			for i in store.x.size():
				var ok_clear:=RockScatter.clear_path(f.path,0,0,32,store.x[i],store.y[i],store.s[i])
				if not ok_clear:print("ON ROUTE x=",store.x[i]," y=",store.y[i]," s=",store.s[i]," v=",store.v[i])
				clear=clear and ok_clear
				pattern.append("%.12f %.12f %.12f"%[store.x[i],store.y[i],store.s[i]])
		pattern.sort();patterns.append(pattern)
	check(clear,"all rock footprints stay clear of a route")
	# ObjStore's spacing is intentionally chunk-local. Rock candidate ownership and
	# order are tested separately with repeat requests of the same chunks.
	var repeat := StageVegetation.ObjStore.new(null);repeat.begin_chunk(0,0,32,32)
	RockScatter.place_chunk(73,0,0,32,32,f,0,0,32,repeat)
	var same:PackedStringArray=[]
	for i in repeat.x.size():same.append("%.12f %.12f %.12f"%[repeat.x[i],repeat.y[i],repeat.s[i]])
	same.sort();check(same==patterns[0],"deterministic rock compositions")
	f.slope.fill(1.5);f.rock=Surface.field(f.elev,f.slope,f.moist)
	var cliff:=StageVegetation.ObjStore.new(null);cliff.begin_chunk(0,0,32,32)
	RockScatter.place_chunk(73,0,0,32,32,f,0,0,32,cliff)
	var boulders:=0
	for v in cliff.v: boulders+=int(not RockModels.is_outcrop(v))
	check(boulders==0 and cliff.x.size()>0,"cliffs get bedrock outcrops, not unsupported ordinary boulders")

func geography(seed_text:String) -> WorldData:
	var w:=Probe.world(seed_text);w.scale=float(w.N)/(512*512)
	StageRelief.run(w)
	w.start_noise_fields();StageOcean.run(w);StageHydrology.run(w);StageRivers.run(w);StageGeography.run(w);StageClimate.run(w)
	StageLandmarks.run(w);StageTrails.run(w,func(_p:float,_s:String)->void:pass);RoadSurface.run(w)
	return w

func baseline() -> bool:
	DirAccess.make_dir_recursive_absolute(OUT)
	for item:Array in [["rock_scatter.gd","scripts/world/rock_scatter.gd"],["rock_models.gd","scripts/render/rock_models.gd"],["stage_vegetation.gd","scripts/world/stages/stage_vegetation.gd"],["forest_floor.gd","scripts/render/forest_floor.gd"],["vegetation_layer.gd","scripts/render/vegetation_layer.gd"],["terrain.gdshader","resources/terrain.gdshader"]]:
		var output:Array=[]
		if OS.execute("git",["show",base_rev+":"+item[1]],output)!=0:return false
		var source:=str(output[0]).replace("class_name RockScatter","").replace("class_name RockModels","").replace("class_name StageVegetation","").replace("class_name VegetationLayer","")
		if item[0]=="rock_scatter.gd":source=source.replace("store: StageVegetation.ObjStore","store")
		if item[0]=="stage_vegetation.gd":source=source.replace("extends RefCounted","extends RefCounted\nconst PriorRocks := preload(\"res://.godot/mountain_environment/rock_scatter.gd\")").replace("RockScatter.place_chunk(","PriorRocks.place_chunk(")
		if item[0]=="vegetation_layer.gd":
			source=source.replace("res://scripts/render/forest_floor.gd","res://.godot/mountain_environment/forest_floor.gd")
			source=source.replace("extends Node3D", "extends Node3D\nconst PriorRockModels := preload(\"res://.godot/mountain_environment/rock_models.gd\")").replace("RockModels.", "PriorRockModels.")
		FileAccess.open(OUT.path_join(item[0]),FileAccess.WRITE).store_string(source)
	return true

func ground(h:Heightfield,p:Vector2,above:float) -> Vector3:
	return Vector3(p.x,h.ground_at(p.x,p.y)+above,p.y)

func views(w:WorldData,h:Heightfield,origin:Vector2i,peak:Vector3) -> Dictionary:
	var best:=-INF;var open:=Vector2(peak.x,peak.z)
	for y in range(origin.y+24,origin.y+SIDE-24,2):
		for x in range(origin.x+24,origin.x+SIDE-24,2):
			var i:=y*N+x
			if w.biome[i] not in [Biomes.ROCK, Biomes.STONESHORE]: continue
			if w.slope[i]<0.22 or w.slope[i]>0.65 or w.elev[i]<0.15:continue
			var score:=Surface.exposure(w.elev[i],w.slope[i],w.moist[i])-Vector2(x,y).distance_to(Vector2(peak.x,peak.z)/4)*0.001
			if score>best:best=score;open=Vector2(x,y)*4
	var road:=open;var along:=Vector2(1,0);best=-INF
	for route:Dictionary in w.trails:
		if route.kind=="animal":continue
		for i in range(2,route.pts.size()-3,5):
			var a:Dictionary=route.pts[i];var b:Dictionary=route.pts[i+3]
			if a.x<origin.x+16 or a.y<origin.y+16 or a.x>origin.x+SIDE-16 or a.y>origin.y+SIDE-16:continue
			var score:=w.elev[int(a.y)*N+int(a.x)]-Vector2(a.x,a.y).distance_to(Vector2(peak.x,peak.z)/4)*0.002
			if score>best:best=score;road=Vector2(a.x,a.y)*4;along=Vector2(b.x-a.x,b.y-a.y).normalized()
	# Самая крутая открытая клетка недалеко от вершины: скальный пояс и осыпь под ним.
	var cliff:=open;best=-INF
	for y in range(origin.y+24,origin.y+SIDE-24,2):
		for x in range(origin.x+24,origin.x+SIDE-24,2):
			var i:=y*N+x
			if w.biome[i] not in [Biomes.ROCK, Biomes.STONESHORE]: continue
			var score:=w.slope[i]*Surface.exposure(w.elev[i],w.slope[i],w.moist[i])-Vector2(x,y).distance_to(Vector2(peak.x,peak.z)/4)*0.002
			if score>best:best=score;cliff=Vector2(x,y)*4
	var normal := RockModels.normal_at(h, cliff.x, cliff.y)
	var downhill := Vector2(normal.x, normal.z).normalized()
	var sideways := Vector2(-downhill.y, downhill.x)
	# 09.11.2026: пологая серая вершина (была серым «плитным» материалом без формы).
	var gentle:=open;best=-INF
	for y in range(origin.y+24,origin.y+SIDE-24,2):
		for x in range(origin.x+24,origin.x+SIDE-24,2):
			var i:=y*N+x
			if w.biome[i] not in [Biomes.ROCK, Biomes.PEAK]: continue
			if w.slope[i]>0.22: continue
			var score:=w.elev[i]-Vector2(x,y).distance_to(Vector2(peak.x,peak.z)/4)*0.001
			if score>best:best=score;gentle=Vector2(x,y)*4
	return {panorama=[peak+Vector3(-235,145,235),peak-Vector3(0,35,0)],
		gentle_top=[ground(h,gentle+Vector2(38,-30),2.5),ground(h,gentle,2.0)],
		cliff=[ground(h,cliff+downhill*45+sideways*12,8.0),ground(h,cliff,3.0)],
		rocks=[ground(h,open+Vector2(-45,55),10),ground(h,open,1.0)],
		rider_road=[ground(h,road,1.8),ground(h,road+along*45,2.0)]}

func run() -> void:
	rules()
	if "--rules-only" in OS.get_cmdline_user_args():quit(1 if failures else 0);return
	if Grid.fast_grid()==null:push_error("Build C# first");quit(1);return
	if not baseline():push_error("Baseline commit unavailable");quit(1);return
	root.size=Vector2i(1280,720)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	RenderingServer.global_shader_parameter_set("cloud_shadow",Vector4.ZERO)
	scene=Node3D.new();root.add_child(scene)
	var env:=WorldEnvironment.new();env.environment=Environment.new()
	env.environment.background_mode=Environment.BG_COLOR;env.environment.background_color=Color("afc7d6")
	env.environment.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR;env.environment.ambient_light_color=Color("d4dfeb");env.environment.ambient_light_energy=0.6;scene.add_child(env)
	var sun:=DirectionalLight3D.new();sun.rotation_degrees=Vector3(-28,-62,0);sun.light_energy=1.25;scene.add_child(sun)
	camera=Camera3D.new();camera.fov=68;camera.far=6000;scene.add_child(camera)
	var old_veg:Script=load(OUT.path_join("stage_vegetation.gd"))
	var old_floor:Script=load(OUT.path_join("forest_floor.gd"))
	var old_layer:Script=load(OUT.path_join("vegetation_layer.gd"))
	var builder:=TerrainBuilder.new();var defs:=Models.tree_defs();var grass:=Models.grass_mesh()
	var results:=[]
	var seeds:Array=Probe.SEEDS
	var args:=OS.get_cmdline_user_args()
	if "--seeds" in args:seeds=args[args.find("--seeds")+1].split(",")
	for seed_text:String in seeds:
		print("BEGIN ENVIRONMENT ",seed_text)
		var w:=geography(seed_text)
		# «Было» — тот же мир без скального рельефа склонов (RockRelief), «стало» — с ним.
		Heightfield.allow_rock_relief=false
		var flat:=Heightfield.base_of(w).copy();flat.finish_paths()
		Heightfield.allow_rock_relief=true
		var surface:=Heightfield.base_of(w).copy();surface.finish_paths()
		var moved:=0;var max_shift:=0.0
		for i in w.N:
			var d:=absf(surface.hv[i]-flat.hv[i])
			if d>0.05:moved+=1
			max_shift=maxf(max_shift,d)
		print("RELIEF ",seed_text," cells=",surface.path_timings.get("rock_relief_cells",0)," moved=",moved," max_m=",snappedf(max_shift,0.01)," ms=",surface.path_timings.get("rock_relief_ms",0.0)," road_bed_ms=",surface.path_timings.get("road_bed_ms",0.0))
		var frozen:=var_to_bytes([w.h,w.filled,w.path_mask,w.ocean,w.lake])
		var top:=0
		for i in w.N:
			if w.h[i]>w.h[top]:top=i
		var origin:=Vector2i(clampi(top%N-SIDE/2,1,N-SIDE-2),clampi(top/N-SIDE/2,1,N-SIDE-2))
		var peak:=ground(surface,Vector2(top%N,top/N)*4,0)
		var cameras:=views(w,surface,origin,peak)
		# Скальные массивы этого мира: кандидаты, отказы, опора на готовой поверхности (до раскладки леса).
		var fields:=StageVegetation.fields(w)
		var mstats:={}
		var sites:=RockMassif.sites(w.seed_num,0,0,w.W,w.H,fields,0,0,w.W,w.path_mask,mstats)
		var seated:=[0,0,0,0];var placed:=[0,0,0,0];var pick:=Vector2.INF;var pick_d:=INF
		var cliff_at:=Vector2(cameras.cliff[1].x,cameras.cliff[1].z)
		for at in range(0,sites.size(),RockMassif.STRIDE):
			var v:=int(sites[at+2]);var form:=RockModels.massif_form(v)
			placed[form]+=1
			var mx:=sites[at]*4.0;var mz:=sites[at+1]*4.0
			var ms:=RockModels.seat(surface,mx,mz,sites[at+3]*1.2,v)
			if ms.x==INF:continue
			seated[form]+=1
			var d:=Vector2(mx,mz).distance_to(cliff_at)+(0.0 if form==RockModels.M_WALL else 60.0)
			if d<pick_d:pick_d=d;pick=Vector2(mx,mz)
		print("MASSIFS ",seed_text," candidates=",mstats.get("candidates",0)," rejected=",{path=mstats.get("path",0),village=mstats.get("village",0),water=mstats.get("water",0)},
			" decided wall/rib/tor/blocks=",placed," seated=",seated)
		if pick!=Vector2.INF:
			var mn:=RockModels.normal_at(surface,pick.x,pick.y);var md:=Vector2(mn.x,mn.z).normalized()
			cameras.massif_mid=[ground(surface,pick+md*60+Vector2(-md.y,md.x)*20,10.0),ground(surface,pick,4.0)]
			cameras.massif_near=[ground(surface,pick+md*18+Vector2(-md.y,md.x)*7,1.8),ground(surface,pick,5.0)]
		var mesh:=ArrayMesh.new();mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,TerrainBuilder.build_arrays(w,surface,Rect2i(origin,Vector2i.ONE*SIDE)))
		var mesh_flat:=ArrayMesh.new();mesh_flat.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,TerrainBuilder.build_arrays(w,flat,Rect2i(origin,Vector2i.ONE*SIDE)))
		var base:=Image.create(N,N,false,Image.FORMAT_RGB8)
		for y in N:
			for x in N:
				var rgb:Array=Biomes.LIST[w.biome[y*N+x]].color
				base.set_pixel(x,y,Color8(rgb[0],rgb[1],rgb[2]))
		var plain_mat:=StandardMaterial3D.new();plain_mat.albedo_color=Color(0.6,0.6,0.6);plain_mat.roughness=0.95
		for version:String in ["before","after"]:
			var started:=Time.get_ticks_usec()
			if version.begins_with("before"):old_veg.run(w)
			else:StageVegetation.run(w)
			var placement_ms:=(Time.get_ticks_usec()-started)/1000.0
			var floor_image:Image=old_floor.surface_image(w) if version.begins_with("before") else Floor.surface_image(w)
			var terrain:=MeshInstance3D.new();terrain.mesh=mesh_flat if version.begins_with("before") else mesh;terrain.material_override=builder.material(base.duplicate(),floor_image)
			if version.begins_with("before"):terrain.material_override.shader=load(OUT.path_join("terrain.gdshader"))
			scene.add_child(terrain)
			var layer:Node3D=old_layer.new() if version.begins_with("before") else VegetationLayer.new()
			scene.add_child(layer);layer.setup(w,flat if version.begins_with("before") else surface,defs,grass,floor_image)
			var row:Dictionary={seed=seed_text,version=version,objects=w.obj_count,placement_ms=placement_ms,views={}}
			var trees:=0;var rocks:=0
			for k in w.obj_k:trees+=int(Biomes.is_tree(k));rocks+=int(k==Biomes.T_ROCK)
			row.trees=trees;row.rocks=rocks
			for view:String in cameras:
				camera.look_at_from_position(cameras[view][0],cameras[view][1],Vector3.UP)
				started=Time.get_ticks_usec();layer.update(camera.position.x,camera.position.z,true)
				var stream_ms:=(Time.get_ticks_usec()-started)/1000.0
				for frame in 4:await process_frame
				started=Time.get_ticks_usec()
				var frames := 0
				var render_cpu := 0.0; var render_gpu := 0.0
				while Time.get_ticks_usec() - started < 1000000:
					await process_frame
					render_cpu += RenderingServer.viewport_get_measured_render_time_cpu(root.get_viewport_rid())
					render_gpu += RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid())
					frames += 1
				var frame_ms:=(Time.get_ticks_usec()-started)/(1000.0*frames)
				await RenderingServer.frame_post_draw
				root.get_texture().get_image().save_png(OUT.path_join(seed_text+"_"+view+"_"+version+".png"))
				row.views[view]={stream_ms=stream_ms,frame_ms=frame_ms,render_cpu_ms=render_cpu/frames,render_gpu_ms=render_gpu/frames,
					video_bytes=RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED),draw_calls=RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)}
				print("SHOT ",seed_text," ",view," ",version," draw_calls=",row.views[view].draw_calls," gpu_ms=",snappedf(row.views[view].render_gpu_ms,0.01)," frame_ms=",snappedf(frame_ms,0.1),
					" primitives=",RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME))
				# Нейтральный материал в том же проходе (без повторной раскладки и подгрузки): видна только форма.
				if view in ["panorama","cliff","massif_mid","gentle_top"]:
					var saved:={}
					for node:GeometryInstance3D in layer.find_children("*","GeometryInstance3D",true,false):
						saved[node]=node.material_override;node.material_override=plain_mat
					var terrain_mat:=terrain.material_override;terrain.material_override=plain_mat
					for frame in 3:await process_frame
					await RenderingServer.frame_post_draw
					root.get_texture().get_image().save_png(OUT.path_join(seed_text+"_"+view+"_"+version+"_neutral.png"))
					for node:GeometryInstance3D in saved:node.material_override=saved[node]
					terrain.material_override=terrain_mat
			check(frozen==var_to_bytes([w.h,w.filled,w.path_mask,w.ocean,w.lake]),"environment preserves relief, water and route masks")
			results.append(row);print("ENVIRONMENT ",JSON.stringify(row))
			layer.queue_free();terrain.queue_free();await process_frame
		# Листы было | стало (и нейтральный материал) по каждому виду, 1280 × 360.
		for view:String in cameras:
			for pair:Array in [["before","after",""],["before_neutral","after_neutral","_neutral"]]:
				var a_path:String=OUT.path_join(seed_text+"_"+view+"_"+pair[0]+".png");var b_path:String=OUT.path_join(seed_text+"_"+view+"_"+pair[1]+".png")
				if not FileAccess.file_exists(a_path) or not FileAccess.file_exists(b_path):continue
				var sheet:=Image.create(1280,360,false,Image.FORMAT_RGBA8)
				for k in 2:
					var img:=Image.load_from_file(ProjectSettings.globalize_path(a_path if k==0 else b_path));img.convert(Image.FORMAT_RGBA8);img.resize(640,360,Image.INTERPOLATE_LANCZOS)
					sheet.blit_rect(img,Rect2i(0,0,640,360),Vector2i(640*k,0))
				sheet.save_png(OUT.path_join("sheet_"+seed_text+"_"+view+pair[2]+".png"))
		surface.weaken_world();flat.weaken_world();w.base_heights=null;w.clear_noise_fields()
	FileAccess.open(OUT.path_join("results.json"),FileAccess.WRITE).store_string(JSON.stringify({failures=failures,worlds=results},"\t"))
	print("MOUNTAIN ENVIRONMENT ",failures," failures")
	quit(1 if failures else 0)
