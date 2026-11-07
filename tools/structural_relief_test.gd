extends SceneTree
## Isolated GEO 7 comparison. Save on the baseline, then compare the working tree.
## --save stores the native relief, coordinates, parameters and timings, without world generation.
const OUT := "res://.godot/structural_relief"
const SEEDS := ["Вальхейм 3", "Север-1234", "Ущелье"]
const SIDE := 768
const Coarse := preload("res://scripts/trails/trail_coarse_map.gd")
var failures := 0

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ", label)
	failures += int(not ok)

func world(seed_text: String) -> WorldData:
	var w := WorldData.new()
	w.W = SIDE; w.H = SIDE; w.N = SIDE * SIDE
	w.seed_text = seed_text; w.seed_num = WGRandom.hash_string(seed_text)
	for key: String in WorldGenerator.NOISE_SLOTS:
		w.noise[key] = Simplex.new(WorldGenerator.noise_rng(w.seed_num, key))
	return w

func measure(h: PackedFloat32Array) -> Dictionary:
	var slopes := PackedFloat32Array()
	var bends := [0.0, 0.0, 0.0]
	var walls := 0
	var max_h := -INF
	var mountain := 0
	for y in range(16, SIDE - 16, 2):
		for x in range(16, SIDE - 16, 2):
			var i := y * SIDE + x
			max_h = maxf(max_h, h[i] * GameConfig.HS)
			if h[i] < 0.2: continue
			mountain += 1
			var g := Vector2(h[i+1]-h[i-1], h[i+SIDE]-h[i-SIDE]).length()*GameConfig.HS/(2*GameConfig.TILE)
			slopes.append(g)
			walls += int(g > 1.0)
			for k in 3:
				var d: int = [2, 4, 8][k]
				bends[k] += absf((h[i-d]+h[i+d]+h[i-d*SIDE]+h[i+d*SIDE])*0.25-h[i])*GameConfig.HS
	slopes.sort()
	for k in 3: bends[k] /= maxi(mountain, 1)
	var wet := PackedByteArray(); wet.resize(h.size())
	for i in h.size(): wet[i] = int(h[i] <= 0)
	var ground := func(p: Vector2) -> float:
		var q := Vector2i((p/GameConfig.TILE).round()).clamp(Vector2i.ZERO,Vector2i.ONE*(SIDE-1))
		return h[q.y*SIDE+q.x]*GameConfig.HS
	var map := Coarse.new(); map.prepare(SIDE, ground, wet, null)
	var kinds := {}; var rideable := 0
	for i in map.heights.size():
		if not map.free[i] or map.heights[i] < 52: continue
		var kind: String = map.feature(i)
		kinds[kind] = kinds.get(kind, 0)+1
		var g: float = map.gradients[i].length()
		rideable += int(g >= 0.06 and g <= 0.2)
	var lengths := []; var total := 0.0; var long_runs := 0
	# Fixed candidate budget, same seed. These are exploratory sketches, not baked bike routes.
	for a in map.anchors(12345, true).slice(0,48):
		var trace: Dictionary = map.trace(a,12345,{two_way=true,box=768.0})
		var points: PackedVector2Array = trace.get("probe",{}).get("points",PackedVector2Array())
		var length := 0.0
		for k in range(1,points.size()): length += points[k].distance_to(points[k-1])
		lengths.append(length); total += length; long_runs += int(length >= 400)
	return {max_m=max_h,wall_pct=100.0*walls/maxi(mountain,1),slope_p50=slopes[slopes.size()/2],slope_p99=slopes[int(slopes.size()*0.99)],
		curvature8_m=bends[0],curvature16_m=bends[1],curvature32_m=bends[2],features=kinds,rideable_nodes=rideable,
		sketches=lengths.size(),sketches400=long_runs,sketch_total_m=total}

func run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	var save := "--save" in OS.get_cmdline_user_args()
	var results := []
	for seed_text: String in SEEDS:
		var w := world(seed_text)
		var start := Time.get_ticks_usec(); StageRelief.run(w)
		var elapsed := (Time.get_ticks_usec()-start)/1000.0
		var path := OUT.path_join(seed_text+"_before.bin")
		var data := {h=w.h,macro=Vector2(w.macro_x,w.macro_y),relief_ms=elapsed,metrics=measure(w.h)}
		if save:
			FileAccess.open(path,FileAccess.WRITE).store_var(data)
			print("BASELINE ",seed_text," ",JSON.stringify(data.metrics)," ms=",elapsed)
			continue
		var old: Dictionary = FileAccess.open(path,FileAccess.READ).get_var()
		check(old.macro==data.macro,"same world window "+seed_text)
		var delta := 0.0; var coast_changed := 0; var changed := 0
		for i in w.N:
			delta = maxf(delta,absf(w.h[i]-old.h[i])*GameConfig.HS)
			coast_changed += int((w.h[i]>0)!=(old.h[i]>0))
			changed += int(w.h[i]!=old.h[i])
		check(coast_changed==0,"dry links and sea mask preserved "+seed_text)
		check(data.metrics.wall_pct<=old.metrics.wall_pct+1.0,"no return of steep walls "+seed_text)
		check(absf(data.metrics.max_m-old.metrics.max_m)<8.0,"mountain scale preserved "+seed_text)
		# Float32 backend equality, parallelism, negative coordinates and request-size independence.
		for p: Vector2i in [Vector2i(-37,701),Vector2i(740,740),Vector2i(190,290)]:
			var native := StageRelief.raw_rect(w,p.x,p.y,24,16,false)
			check(native==StageRelief._rows(w,p.x,p.y,24,0,16),"C#/GDScript "+seed_text+str(p))
			check(native==StageRelief.raw_rect(w,p.x,p.y,24,16,true),"parallel equality "+str(p))
			var padded := StageRelief.raw_rect(w,p.x-2,p.y-2,28,20,false)
			var same := true
			for y in 16:
				for x in 24: same = same and native[y*24+x]==padded[(y+2)*28+x+2]
			check(same,"neighbour overlap "+str(p))
		FileAccess.open(OUT.path_join(seed_text+"_after.bin"),FileAccess.WRITE).store_var(data)
		var row := {seed=seed_text,before=old.metrics,after=data.metrics,before_ms=old.relief_ms,after_ms=elapsed,max_delta_m=delta,coast_changes=coast_changed,changed_cells=changed}
		results.append(row); print("RESULT ",JSON.stringify(row))
	if not save: FileAccess.open(OUT.path_join("results.json"),FileAccess.WRITE).store_string(JSON.stringify(results,"\t"))
	print("STRUCTURAL RELIEF ",failures," failures")
	quit(1 if failures else 0)
