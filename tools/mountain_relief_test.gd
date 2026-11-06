extends SceneTree
var Old: Script
const Coarse := preload("res://scripts/trails/trail_coarse_map.gd")

var failures := 0
var results: Array = []
const OUT := "res://.godot/mountain_review"
func check(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ", label)
	failures += int(not ok)
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 240)
	if "--contracts-only" in OS.get_cmdline_user_args():
		contracts()
		return
	call_deferred("run")

func contracts() -> void:
	var wet := PackedByteArray()
	wet.resize(96*96)
	for wavelength in [32.0,128.0]:
		var map := Coarse.new()
		map.prepare(96,func(p:Vector2)->float:return sin(p.x*TAU/wavelength)*2.0,wet,null)
		var samples := map.heights.duplicate(); samples.sort()
		var spread: float = samples[-1]-samples[0]
		check(spread<0.0001 if wavelength==32.0 else spread>2.0,"32 m overview aliasing, wavelength "+str(wavelength))
	for seed_text: String in ["Север-1234","Ущелье","Туман-4821"]:
		var w := WorldData.new()
		w.seed_num = WGRandom.hash_string(seed_text)
		for key: String in WorldGenerator.NOISE_SLOTS:
			w.noise[key] = Simplex.new(WorldGenerator.noise_rng(w.seed_num,key))
		var a := StageRelief.raw_rect(w,-37,701,96,96,false)
		check(a == StageRelief._rows(w,-37,701,96,0,96),"9216 float32 cells C#/GDScript "+seed_text)
		check(a == StageRelief.raw_rect(w,-37,701,96,96,true),"parallel determinism "+seed_text)
	print("MOUNTAIN CONTRACTS ",failures," failures")
	quit(1 if failures else 0)
func metrics(w: WorldData) -> Dictionary:
	var n := w.W
	var h := w.h
	var land := 0
	var mountain := 0
	var gentle := 0
	var wall := 0
	var bend := 0.0
	var top := 0
	for y in range(2, n - 2):
		for x in range(2, n - 2):
			var i := y*n+x
			if h[i] > h[top]: top = i
			if h[i] <= 0: continue
			land += 1
			var g := Vector2(h[i+1]-h[i-1],h[i+n]-h[i-n])*GameConfig.HS/(2*GameConfig.TILE)
			if g.length() <= 0.35: gentle += 1
			if h[i] > 0.20:
				mountain += 1
				wall += int(g.length()>1.0)
				bend += absf((h[i-8 if x>=8 else i]+h[i+8 if x<n-8 else i]+h[i-n*8 if y>=8 else i]+h[i+n*8 if y<n-8 else i])*0.25-h[i])*GameConfig.HS
	var map := Coarse.new()
	var wet := w.ocean.duplicate()
	var surface := Heightfield.new(w, false)
	map.prepare(n, func(p: Vector2) -> float: return surface.ground_at(p.x,p.y), wet, null)
	var features := {}
	var rideable := 0
	for i in map.heights.size():
		if not map.free[i]: continue
		var name: String = map.feature(i)
		features[name] = features.get(name,0)+1
		var g: float = map.gradients[i].length()
		rideable += int(g>=0.06 and g<=0.20)
	var traces := 0
	var metres := 0.0
	for a in map.anchors(w.seed_num,true).slice(0,48):
		var trace: Dictionary = map.trace(a,w.seed_num,{two_way=true, box=768.0})
		var path: PackedVector2Array = trace.get("probe",{}).get("points",PackedVector2Array())
		var length := 0.0
		for k in range(1,path.size()): length += path[k].distance_to(path[k-1])
		if length>=160: traces += 1; metres += length
	surface.weaken_world()
	return {top_cell=top,max_m=h[top]*GameConfig.HS,land_cells=land,mountain_cells=mountain,
		gentle_share=100.0*gentle/maxi(land,1),wall_share=100.0*wall/maxi(mountain,1),curvature32_m=bend/maxi(mountain,1),features32=features,rideable32=rideable,overview_traces160=traces,overview_trace_m=metres}
func run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	var source: Array = []
	var status := OS.execute("git", ["show","064dd48:scripts/world/stages/stage_relief.gd"], source)
	if status != 0: push_error("Baseline commit 064dd48 unavailable"); quit(1); return
	var text := str(source[0]).replace("class_name StageRelief", "")
	text = text.replace("var fast := Grid.fast_grid()", "var fast: Object = null")
	var baseline_file := FileAccess.open(OUT.path_join("relief_before.gd"),FileAccess.WRITE)
	baseline_file.store_string(text); baseline_file.close()
	Old = load(OUT.path_join("relief_before.gd"))
	for seed_text: String in ["Север-1234","Ущелье","Туман-4821"]:
		print("BEGIN ",seed_text)
		var w := WorldGenerator._geography(seed_text,768)
		var before := WorldData.new()
		before.W=w.W; before.H=w.H; before.N=w.N; before.seed_num=w.seed_num; before.seed_text=seed_text
		before.noise=w.noise
		before.macro_x=w.macro_x; before.macro_y=w.macro_y
		before.mountain_scale=w.mountain_scale; before.mountain_bias=w.mountain_bias; before.mountain_height=w.mountain_height; before.foothill_spread=w.foothill_spread
		var started := Time.get_ticks_msec()
		var raw: PackedFloat32Array = Old.raw_rect(before,0,0,768,768,true)
		var micro := Parallel.fbm_field(768,768,w.noise.micro,9.0,2)
		for i in before.N: raw[i]=StageRelief.add_micro(StageRelief.normalize(raw[i]),micro[i])
		before.h=raw
		var before_reference_ms := Time.get_ticks_msec()-started
		StageOcean.run(before)
		StageHydrology.run(before)
		StageRivers.run(before)
		StageGeography.run(before)
		StageClimate.run(before)
		var a := metrics(before)
		var b := metrics(w)
		var forest := 0
		var dry_land := 0
		for bi in w.biome:
			forest += int(bi in [Biomes.FOREST,Biomes.TAIGA])
			dry_land += int(not Biomes.LIST[bi].get("water",false))
		check(float(forest)/maxi(dry_land,1)>0.5,"forest majority "+seed_text)
		check(w.generation_profile.freshwater_lakes<=2,"rare lakes "+seed_text)
		check(b.gentle_share>a.gentle_share-8 and b.wall_share<15,"terrain remains passable "+seed_text)
		# Existing geography test's edge/negative-coordinate and backend oracle.
		for p: Vector2i in [Vector2i(-65,-2),Vector2i(766,766),Vector2i(b.top_cell%768-3,b.top_cell/768-3)]:
			var full := StageRelief.raw_rect(w,p.x,p.y,6,4,false)
			check(full==StageRelief._rows(w,p.x,p.y,6,0,4),"C#/GDScript "+str(p))
			var left := StageRelief.raw_rect(w,p.x,p.y,3,4,false)
			var right := StageRelief.raw_rect(w,p.x+3,p.y,3,4,false)
			var same := true
			for y in 4:
				for x in 6: same = same and full[y*6+x]==(left[y*3+x] if x<3 else right[y*3+x-3])
			check(same,"rectangle seam "+str(p))
		var rect := Vector2i(b.top_cell%768-32,b.top_cell/768-32)
		started=Time.get_ticks_usec()
		Old.raw_rect(before,rect.x,rect.y,64,64,false)
		var old_us := Time.get_ticks_usec()-started
		started=Time.get_ticks_usec()
		StageRelief._rows(w,rect.x,rect.y,64,0,64)
		var new_us := Time.get_ticks_usec()-started
		var row := {seed=seed_text,before=a,after=b,forest_share=100.0*forest/maxi(dry_land,1),lakes=w.generation_profile.freshwater_lakes,relief_native_ms=w.generation_profile.stages_ms.relief,reference_before_ms=old_us/1000.0,reference_after_ms=new_us/1000.0,before_full_reference_ms=before_reference_ms}
		if seed_text=="Ущелье":
			StageLandmarks.run(w)
			StageTrails.run(w,func(_p:float,_s:String)->void:pass)
			check(not w.trails.is_empty() and preload("res://tools/selftest.gd").settlement_network_valid(w),"real road network")
			row.roads=w.trails.size(); row.settlements=w.settlements.size()
			var f := FileAccess.open(OUT.path_join("fields.bin"),FileAccess.WRITE)
			f.store_var({before=before.h,after=w.h,biome_before=before.biome,biome_after=w.biome,top_before=a.top_cell,top_after=b.top_cell})
		results.append(row)
		print("RESULT ",JSON.stringify(row))
		before.base_heights=null; w.base_heights=null
	var f := FileAccess.open(OUT.path_join("results.json"),FileAccess.WRITE)
	f.store_string(JSON.stringify({failures=failures,worlds=results},"\t"))
	print("MOUNTAIN REVIEW ",failures," failures")
	quit(1 if failures else 0)




