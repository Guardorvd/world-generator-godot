extends SceneTree
const Network := preload("res://scripts/trails/trail_world_network.gd")
const Cost := preload("res://tools/trail_network_cost_test.gd")
var Old: Script
var failures := 0
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self,240)
	call_deferred("run")
func run() -> void:
	var source: Array=[]
	OS.execute("git",["show","064dd48:scripts/world/stages/stage_relief.gd"],source)
	var text:=str(source[0]).replace("class_name StageRelief","").replace("var fast := Grid.fast_grid()","var fast: Object = null")
	var f:=FileAccess.open("res://.godot/gameplay_old_relief.gd",FileAccess.WRITE)
	f.store_string(text);f.close();Old=load("res://.godot/gameplay_old_relief.gd")
	var rows: Array=[]
	var args:=OS.get_cmdline_user_args()
	var seeds:=["Ущелье","Север-1234"]
	if "--seed" in args:seeds=[args[args.find("--seed")+1]]
	for seed_text: String in seeds:
		for version: String in (["after"] if "--after-only" in OS.get_cmdline_user_args() else ["before","after"]):
			print("BEGIN ",seed_text," ",version)
			var w: WorldData
			if version=="after": w=WorldGenerator._geography(seed_text,768)
			else:
				w=WorldData.new();w.W=768;w.H=768;w.N=768*768;w.scale=float(w.N)/(512*512)
				w.seed_text=seed_text;w.seed_num=WGRandom.hash_string(seed_text)
				for key: String in WorldGenerator.NOISE_SLOTS:w.noise[key]=Simplex.new(WorldGenerator.noise_rng(w.seed_num,key))
				Old.run(w);w.start_noise_fields()
				StageOcean.run(w);StageHydrology.run(w);StageRivers.run(w);StageGeography.run(w);StageClimate.run(w)
			var row: Dictionary={seed=seed_text,version=version,scale=w.scale,macro=[w.macro_x,w.macro_y]}
			StageLandmarks.run(w);row.settlements_proposed=w.settlements.size()
			StageTrails.run(w,func(_p:float,_s:String)->void:pass)
			row.settlements_final=w.settlements.size()
			if seed_text=="Ущелье" and version=="after" and w.settlements.size()<7: failures += 1
			row.connected=preload("res://tools/selftest.gd").settlement_network_valid(w)
			row.roads={}
			for route:Dictionary in w.trails:
				var length:=preload("res://tools/control/control.gd").path_length(route.pts)*GameConfig.TILE
				row.roads[route.kind]=row.roads.get(route.kind,0.0)+length
			row.road_profile=w.generation_profile.duplicate(true)
			if "--roads-only" in args:
				rows.append(row);print("CASE ",JSON.stringify(row));w.base_heights=null;continue
			StageSites.run(w);RoadSurface.run(w)
			var h:=w.base_heights.copy();h.finish_paths()
			var plan:=Network.build(w,h,QuickTrails.area(Rect2i(0,0,768,768)),QuickTrails.options())
			row.network=plan.stats;row.state=plan.state;row.earth=Cost.earth_summary(plan)
			row.routes=[]
			for route:Dictionary in plan.routes:
				var d:=StageTrailPlan.unpack(route)
				var a:=d.point_at(0);var b:=d.point_at(d.route_length())
				row.routes.append({length=d.route_length(),drop=h.ground_at(a.x,a.y)-h.ground_at(b.x,b.y),sections=d.sections})
			rows.append(row)
			print("CASE ",JSON.stringify(row))
			FileAccess.open("res://.godot/mountain_gameplay.json",FileAccess.WRITE).store_string(JSON.stringify(rows,"\t"))
			h.weaken_world();w.base_heights=null
	print("GAMEPLAY DONE ",failures," failures")
	quit()


