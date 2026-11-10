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
	if "--analyze-snapshots" in OS.get_cmdline_user_args():
		call_deferred("analyze_snapshots")
		return
	if "--snapshot" in OS.get_cmdline_user_args():
		call_deferred("snapshot")
		return
	if "--contracts-only" in OS.get_cmdline_user_args():
		contracts()
		return
	call_deferred("run")

## Geography actually crossed by the published road network, independent of
## route naming and of whether a settlement graph happens to stay connected.
func analyze_snapshots() -> void:
	var dir := "res://.godot/mountain_structure"
	var rows := []
	for seed_text: String in ["Север-1234", "Вальхейм 3", "Ущелье", "Туман-4821", "Каменный берег"]:
		for version: String in ["before", "after"]:
			var data: Dictionary = FileAccess.open(dir.path_join(seed_text + "_" + version + ".bin"), FileAccess.READ).get_var()
			var w := WorldData.new()
			for key: String in ["W", "H", "N", "elev", "trails"]: w.set(key, data.world[key])
			var row := {seed = seed_text, version = version, mountain_km = 0.0, ridge_km = 0.0,
				hollow_km = 0.0, ascent_m = 0.0, descent_m = 0.0, highest_route_m = 0.0, longest_drop_m = 0.0}
			for route: Dictionary in w.trails:
				if route.kind == "animal": continue
				var descent_peak := 0.0; var descent_low := 0.0
				for k in range(1, route.pts.size()):
					var a := Vector2(route.pts[k-1].x, route.pts[k-1].y)
					var b := Vector2(route.pts[k].x, route.pts[k].y)
					var x := clampi(int(b.x), 0, w.W-1); var y := clampi(int(b.y), 0, w.H-1)
					var i := y*w.W+x
					var previous := w.elev[clampi(int(a.y), 0, w.H-1)*w.W+clampi(int(a.x), 0, w.W-1)]
					var dh := (w.elev[i]-previous)*GameConfig.HS
					row.ascent_m += maxf(0, dh); row.descent_m += maxf(0, -dh)
					if k == 1:
						descent_peak = previous * GameConfig.HS; descent_low = descent_peak
					var height := w.elev[i]*GameConfig.HS
					# Reset on an accumulated 2 m rise from the lowest point,
					# not on each individual step: tiny uphill steps must not
					# silently accumulate into a supposedly continuous descent.
					if height > descent_low + 2.0:
						descent_peak = height; descent_low = height
					else:
						descent_low = minf(descent_low, height)
						descent_peak = maxf(descent_peak, height)
					row.longest_drop_m = maxf(row.longest_drop_m, descent_peak - descent_low)
					row.highest_route_m = maxf(row.highest_route_m, w.elev[i]*GameConfig.HS)
					if w.elev[i] <= 0.2: continue
					var km := a.distance_to(b)*GameConfig.TILE/1000.0
					row.mountain_km += km
					if x < 8 or y < 8 or x >= w.W-8 or y >= w.H-8: continue
					var form := ((w.elev[i-8]+w.elev[i+8]+w.elev[i-w.W*8]+w.elev[i+w.W*8])*0.25-w.elev[i])*GameConfig.HS
					if form < -1: row.ridge_km += km
					elif form > 1: row.hollow_km += km
			rows.append(row)
	FileAccess.open(dir.path_join("route_geography.json"), FileAccess.WRITE).store_string(JSON.stringify(rows, "\t"))
	print("ROUTE GEOGRAPHY ", JSON.stringify(rows))
	quit()

## Capture the actual native pipeline before editing it, rather than loading old
## StageRelief with today's detail dependencies. Used by mountain_compare_look.
func snapshot() -> void:
	var args := OS.get_cmdline_user_args()
	var version: String = args[args.find("--snapshot") + 1]
	var seeds := ["Север-1234", "Вальхейм 3", "Ущелье", "Туман-4821", "Каменный берег"]
	if "--seeds" in args: seeds.assign(args[args.find("--seeds") + 1].split(",", false))
	var dir := "res://.godot/mountain_structure"
	DirAccess.make_dir_recursive_absolute(dir)
	var rows := []
	for seed_text: String in seeds:
		print("BEGIN SNAPSHOT ", seed_text, " ", version)
		var started := Time.get_ticks_usec()
		var w := WorldGenerator._geography(seed_text, 768)
		var invalid := 0; var uphill := 0; var forest := 0; var dry := 0
		for i in w.N:
			invalid += int(not is_finite(w.h[i]) or not is_finite(w.slope[i]))
			if w.river[i] != 0 and w.down[i] >= 0:
				var next := w.down[i]
				uphill += int(w.ocean[next] == 0 and w.lake[next] == 0 and w.h[next] > w.h[i] + 1e-6)
			forest += int(w.biome[i] in [Biomes.FOREST, Biomes.TAIGA])
			dry += int(not Biomes.LIST[w.biome[i]].get("water", false))
		check(invalid == 0 and uphill == 0, "finite relief and downhill rivers " + seed_text)
		var row := metrics(w)
		row.forest_share = 100.0 * forest / maxi(1, dry)
		row.seed = seed_text
		row.relief_source = FileAccess.get_sha256("res://scripts/world/stages/stage_relief.gd")
		row.geography_ms = (Time.get_ticks_usec() - started) / 1000.0
		var raw := StageRelief.raw_rect(w, 0, 0, 768, 768, true)
		for i in raw.size(): raw[i] = StageRelief.normalize(raw[i])
		var timings := []
		for repeat in 3:
			started = Time.get_ticks_usec()
			StageRelief.raw_rect(w, 0, 0, 768, 768, true)
			timings.append((Time.get_ticks_usec() - started) / 1000.0)
		row.relief_ms = timings
		started = Time.get_ticks_usec()
		StageLandmarks.run(w)
		row.proposed = w.settlements.size()
		StageTrails.run(w, func(_p: float, _s: String) -> void: pass)
		row.connected = preload("res://tools/selftest.gd").settlement_network_valid(w)
		check(row.connected, "settlement connectivity " + seed_text)
		row.settlements = w.settlements.size()
		row.roads = w.trails.size()
		row.road_metres = {}
		for route: Dictionary in w.trails:
			var length := preload("res://tools/control/control.gd").path_length(route.pts) * GameConfig.TILE
			row.road_metres[route.kind] = row.road_metres.get(route.kind, 0.0) + length
		StageSites.run(w)
		StageLakes.run(w)
		RoadSurface.run(w)
		var surface := Heightfield.base_of(w).copy()
		surface.finish_paths()
		row.places_ms = (Time.get_ticks_usec() - started) / 1000.0
		StageVegetation.run(w, surface)
		row.objects = w.obj_count
		row.bridges = w.bridges.size()
		row.lakes = w.lakes.size()
		row.profile = w.generation_profile.duplicate(true)
		var wet_huts := 0
		for settlement: SettlementData in w.settlements:
			for hut: HutData in settlement.huts:
				var i := int(hut.y) * w.W + int(hut.x)
				wet_huts += int(w.ocean[i] != 0 or w.lake[i] != 0 or w.river[i] != 0)
		check(wet_huts == 0, "homes remain on dry ground " + seed_text)
		var fields := {}
		for key: String in WorldData.CACHE_FIELDS: fields[key] = EntityCodec.encode(w.get(key))
		FileAccess.open(dir.path_join(seed_text + "_" + version + ".bin"), FileAccess.WRITE).store_var({
			world = fields, raw = raw, surface = preload("res://scripts/game/surface_snapshot.gd").capture(surface, "final"), metrics = row})
		rows.append(row)
		print("SNAPSHOT ", JSON.stringify(row))
		surface.weaken_world(); w.base_heights = null; w.clear_noise_fields()
	FileAccess.open(dir.path_join(version + ".json"), FileAccess.WRITE).store_string(JSON.stringify(rows, "\t"))
	quit(1 if failures else 0)

func contracts() -> void:
	check(Grid.fast_grid() != null, "native backend available")
	check(StageClimate.land_biome(0.5, 0.3, 0.8, 0.15, 30) == Biomes.TUNDRA,
		"wet alpine shoulder retains soil")
	check(StageClimate.land_biome(0.5, 0.3, 0.4, 0.9, 30) == Biomes.ROCK,
		"steep alpine face exposes bedrock at the same height")
	check(preload("res://tools/generation_field_checks.gd").synthetic().ok,
		"native/reference climate including alpine transitions")
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
		# The integer candidate windows must not leave seams where a knot or
		# range enters/leaves the finite-support query, including negatives.
		var continuous := true
		for x in [-390.0, -260.0, -130.0, 0.0, 130.0, 260.0, 390.0]:
			for y in [-520.0, -260.0, 0.0, 260.0, 520.0]:
				var p := Vector2(x, y)
				for delta: Vector2 in [Vector2(0.0001, 0), Vector2(0, 0.0001)]:
					var left := StageRelief._crest(w.noise.ridge, p.x-delta.x, p.y-delta.y, 1, 0, 1.8, 0.8, 1, 1)
					var right := StageRelief._crest(w.noise.ridge, p.x+delta.x, p.y+delta.y, 1, 0, 1.8, 0.8, 1, 1)
					continuous = continuous and absf(left-right) < 0.0001
		check(continuous, "skeleton knot/range window continuity " + seed_text)
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




