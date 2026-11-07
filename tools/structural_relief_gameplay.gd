extends SceneTree
## One integrated before/after pass: real water, settlements, roads and ground.
## Uses saved relief snapshots, not old water/cache or the full baked bike network.
const OUT := "res://.godot/structural_relief"
const Probe := preload("res://tools/structural_relief_test.gd")
const Coarse := preload("res://scripts/trails/trail_coarse_map.gd")
const SelfTest := preload("res://tools/selftest.gd")
var failures := 0

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 300)
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ",label)
	failures += int(not ok)

func run() -> void:
	var rows := []
	for seed_text: String in Probe.SEEDS:
		var pair := []
		for version: String in ["before","after"]:
			print("BEGIN ",seed_text," ",version)
			var started := Time.get_ticks_usec()
			var saved: Dictionary = FileAccess.open(OUT.path_join(seed_text+"_"+version+".bin"),FileAccess.READ).get_var()
			var w := WorldData.new()
			w.W=768; w.H=768; w.N=768*768; w.scale=float(w.N)/(512*512)
			w.seed_text=seed_text; w.seed_num=WGRandom.hash_string(seed_text)
			for key: String in WorldGenerator.NOISE_SLOTS:
				w.noise[key]=Simplex.new(WorldGenerator.noise_rng(w.seed_num,key))
			w.mountain_scale=0.8+0.8*WGRandom.hash2(31,7,w.seed_num)
			w.mountain_bias=0.05+0.4*WGRandom.hash2(17,19,w.seed_num)
			w.mountain_height=0.75+0.6*WGRandom.hash2(47,3,w.seed_num)
			w.foothill_spread=0.15+0.85*WGRandom.hash2(73,11,w.seed_num)
			w.macro_x=saved.macro.x; w.macro_y=saved.macro.y; w.h=saved.h
			w.start_noise_fields()
			StageOcean.run(w); StageHydrology.run(w); StageRivers.run(w)
			StageGeography.run(w); StageClimate.run(w)
			var geo_ms := (Time.get_ticks_usec()-started)/1000.0
			StageLandmarks.run(w)
			var proposed := w.settlements.size()
			started=Time.get_ticks_usec()
			StageTrails.run(w,func(_p:float,_s:String)->void:pass)
			var road_ms := (Time.get_ticks_usec()-started)/1000.0
			check(SelfTest.settlement_network_valid(w),"settlement connectivity "+seed_text+" "+version)
			RoadSurface.run(w)
			var surface := Heightfield.base_of(w).copy(); surface.finish_paths()
			var wet := w.ocean.duplicate()
			for i in w.N: wet[i] = int(wet[i]!=0 or w.lake[i]!=0 or w.river[i]!=0)
			var map := Coarse.new()
			map.prepare(w.W,func(p:Vector2)->float:return surface.ground_at(p.x,p.y),wet,null)
			var kinds := {}; var traces := []; var route_shapes := {}; var peak_grades := []; var drops := []
			for a in map.anchors(w.seed_num,true).slice(0,48):
				var trace := map.trace(a,w.seed_num,{two_way=true,box=768.0})
				if trace.is_empty(): continue
				var kind: String=trace.feature
				kinds[kind]=kinds.get(kind,0)+1
				traces.append(trace.probe.length); peak_grades.append(trace.probe.peak_grade); drops.append(trace.probe.drop)
				route_shapes[kind]=route_shapes.get(kind,0.0)+trace.probe.length
			var roads := {}; var road_lengths := {}
			for route: Dictionary in w.trails:
				roads[route.kind]=roads.get(route.kind,0)+1
				var length:=0.0
				for i in range(1,route.pts.size()):
					var a:Dictionary=route.pts[i-1]; var b:Dictionary=route.pts[i]
					length+=Vector2(b.x-a.x,b.y-a.y).length()*4.0
				road_lengths[route.kind]=road_lengths.get(route.kind,0.0)+length
			var row := {seed=seed_text,version=version,settlements_proposed=proposed,settlements=w.settlements.size(),roads=roads,road_lengths_m=road_lengths,
				bridges=w.bridges.size(),tunnels=w.tunnels.size(),lakes=w.generation_profile.get("freshwater_lakes",-1),geo_ms=geo_ms,roads_ms=road_ms,
				candidate_kinds=kinds,candidate_metres_by_kind=route_shapes,candidate_lengths=traces,candidate_peak_grades=peak_grades,candidate_drops=drops}
			# Keep actual game heights for optional inspection with the same visual stand.
			var game_h:=surface.hv.duplicate()
			for i in game_h.size(): game_h[i]/=GameConfig.HS
			FileAccess.open(OUT.path_join(seed_text+"_game_"+version+".bin"),FileAccess.WRITE).store_var({h=game_h})
			pair.append(row); rows.append(row); print("GAMEPLAY ",JSON.stringify(row))
			surface.weaken_world(); w.base_heights=null
		check(pair[1].settlements>=pair[0].settlements,"no loss of settlements "+seed_text)
	FileAccess.open(OUT.path_join("gameplay.json"),FileAccess.WRITE).store_string(JSON.stringify({failures=failures,worlds=rows},"\t"))
	print("STRUCTURAL GAMEPLAY ",failures," failures")
	quit(1 if failures else 0)
