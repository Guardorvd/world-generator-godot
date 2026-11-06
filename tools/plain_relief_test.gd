extends SceneTree
const DIR := "res://.godot/plain_review"
var Old: Script
var rows: Array=[]
var fields := {}
var failures := 0
func _initialize()->void:
	preload("res://tools/watchdog.gd").arm(self,180)
	call_deferred("run")
func run()->void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var baseline:=FileAccess.get_file_as_string("res://scripts/world/stages/stage_relief.gd")
	var lo:=baseline.find("\t# Reuse the existing 20–160 m")
	var hi:=baseline.find("\t# То же поле понижений",lo)
	assert(lo>=0 and hi>lo,"Plain relief baseline markers missing")
	baseline=baseline.left(lo)+baseline.substr(hi)
	var text:=baseline.replace("class_name StageRelief","").replace("var fast := Grid.fast_grid()","var fast: Object = null")
	FileAccess.open(DIR.path_join("baseline.gd"),FileAccess.WRITE).store_string(text)
	Old=load(DIR.path_join("baseline.gd"))
	for seed_text:String in ["Ущелье","Север-1234"]:
		var old_ocean:=PackedByteArray()
		var old_macro:=Vector2.ZERO
		var sample_cells:=PackedInt32Array()
		for version:String in ["before","after"]:
			print("BEGIN ",seed_text," ",version)
			var w:WorldData
			if version=="after":w=WorldGenerator._geography(seed_text,768)
			else:
				w=WorldData.new();w.W=768;w.H=768;w.N=768*768;w.scale=2.25;w.seed_text=seed_text;w.seed_num=WGRandom.hash_string(seed_text)
				for key:String in WorldGenerator.NOISE_SLOTS:w.noise[key]=Simplex.new(WorldGenerator.noise_rng(w.seed_num,key))
				Old.run(w);w.start_noise_fields();StageOcean.run(w);StageHydrology.run(w);StageRivers.run(w);StageGeography.run(w);StageClimate.run(w)
			if version=="before":
				old_ocean=w.ocean.duplicate();old_macro=Vector2(w.macro_x,w.macro_y)
				for y in range(8,760,4):
					for x in range(8,760,4):
						var i:=y*768+x
						if w.h[i]>.03 and w.h[i]<.16 and w.slope[i]<.2 and w.lake[i]==0:sample_cells.append(i)
			var grades:=PackedFloat32Array();var bends:=PackedFloat32Array()
			for i in sample_cells:
				grades.append(w.slope[i])
				bends.append(absf((w.h[i-8]+w.h[i+8]+w.h[i-6144]+w.h[i+6144])*.25-w.h[i])*GameConfig.HS)
			grades.sort();bends.sort()
			var row:Dictionary={seed=seed_text,version=version,macro=[w.macro_x,w.macro_y],sample_count=sample_cells.size(),grade_p95=grades[int(grades.size()*.95)],bend32_p95=bends[int(bends.size()*.95)],lakes=w.generation_profile.freshwater_lakes,relief_ms=w.generation_profile.get("stages_ms",{}).get("relief",null)}
			if version=="after":row.same_coast=old_ocean==w.ocean;row.same_window=old_macro==Vector2(w.macro_x,w.macro_y)
			StageLandmarks.run(w);row.sites=w.settlements.size()
			StageTrails.run(w,func(_p:float,_s:String)->void:pass);row.towns=w.settlements.size()
			row.connected=preload("res://tools/selftest.gd").settlement_network_valid(w)
			failures += int(not row.connected)
			if version=="after":
				failures += int(not row.same_coast or not row.same_window or row.grade_p95>0.35)
			RoadSurface.run(w)
			var h:=w.base_heights.copy();h.finish_paths()
			var lines:Array=[];var road_metres:=0.0;var road_grade:=PackedFloat32Array()
			for route:Dictionary in w.trails:
				if route.kind!="road":continue
				var line:=PackedVector3Array()
				for p:Dictionary in route.pts:
					var x:float=p.x*4;var z:float=p.y*4
					line.append(Vector3(x,h.surface_at(x,z,-INF)+.06,z))
				for k in range(1,line.size()):
					var distance:=Vector2(line[k].x-line[k-1].x,line[k].z-line[k-1].z).length()
					road_metres+=distance
					if distance>.01:road_grade.append(absf(line[k].y-line[k-1].y)/distance)
				lines.append(line)
			road_grade.sort();row.road_m=road_metres;row.road_grade_p95=road_grade[int(road_grade.size()*.95)]
			if seed_text=="Ущелье":
				fields[version]=h.hv.duplicate();for i in fields[version].size():fields[version][i]/=GameConfig.HS
				fields["biome_"+version]=w.biome;fields["roads_"+version]=lines
				if version=="before":
					var best:=-INF;var target:=Vector3.ZERO
					for line:PackedVector3Array in lines:
						for k in range(4,line.size()-4):
							var p:=line[k];var i:=clampi(int(p.z/4),8,759)*768+clampi(int(p.x/4),8,759)
							var score:=minf(k,line.size()-k)-w.slope[i]*300-w.h[i]*50
							if w.h[i]<.18 and score>best:best=score;target=p
					fields.target=target
			rows.append(row);print("RESULT ",JSON.stringify(row))
			w.base_heights=null;h.weaken_world()
			FileAccess.open(DIR.path_join("results.json"),FileAccess.WRITE).store_string(JSON.stringify(rows,"\t"))
	FileAccess.open(DIR.path_join("fields.bin"),FileAccess.WRITE).store_var(fields)
	print("PLAIN REVIEW ",failures," failures")
	quit(1 if failures else 0)
