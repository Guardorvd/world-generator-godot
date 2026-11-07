extends SceneTree
## Слой детализации гор (GEO 9) без генерации мира: рельеф трёх сидов с выключенным слоем
## (= GEO 7) и включённым в одном процессе. Сверка: выключенный слой бит в бит равен снимку GEO 7
## (.godot/structural_relief/<сид>_before.bin, если он есть), C#/GDScript, параллельный расчёт,
## отрицательные координаты, перекрытие запросов соседних кусков (швы). Метрики склонов,
## кривизны, высоты, береговой маски и времени. Поля для mountain_detail_look — в OUT.
## godot --headless --path . --script res://tools/mountain_detail_test.gd [-- --seeds "Ущелье"]
const OUT := "res://.godot/mountain_detail"
const GEO7 := "res://.godot/structural_relief"
const SEEDS := ["Вальхейм 3", "Север-1234", "Ущелье"]
const SIDE := 768
const Detail := preload("res://scripts/world/mountain_detail.gd")
var failures := 0

class CountingNoise extends Simplex:
	var calls := 0
	func noise(_x: float, _y: float) -> float:
		calls += 1
		return 0.2


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 150)
	if "--contracts-only" in OS.get_cmdline_user_args():
		contracts()
		quit(1 if failures else 0)
		return
	call_deferred("run")


func check(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ", label)
	failures += int(not ok)


## Analytic profiles in metres, converted back to raw heights before the stencil.
func profile(height: float, grade: float, convexity: float = 0.0) -> PackedFloat32Array:
	var b := PackedFloat32Array()
	var raw := StageRelief.SEA_RAW + (StageRelief.TOP_RAW-StageRelief.SEA_RAW)*pow(height/GameConfig.HS,0.8)
	var per_raw := 1.25 * pow((raw-StageRelief.SEA_RAW)/(StageRelief.TOP_RAW-StageRelief.SEA_RAW),0.25)/(StageRelief.TOP_RAW-StageRelief.SEA_RAW)*GameConfig.HS
	for y in range(-2, 3):
		for x in range(-2, 3):
			var dx := x * GameConfig.TILE; var dy := y * GameConfig.TILE
			b.append(raw + (grade * dx - convexity * (dx * dx + dy * dy))/per_raw)
	return b


func contracts() -> void:
	var ridge := CountingNoise.new(); var hill := CountingNoise.new()
	for spec: Array in [[20.0,0.35],[100.0,0.0],[100.0,0.9]]:
		var b := profile(spec[0],spec[1])
		ridge.calls=0; hill.calls=0
		var v := Detail.apply(ridge,hill,b,5,12,313.0,-127.0,StageRelief.SEA_RAW,StageRelief.TOP_RAW,GameConfig.HS,GameConfig.TILE)
		check(v==b[12],"no detail on low, flat or steep ground "+str(spec))
		check(ridge.calls==0 and hill.calls==0,"no noise calls for inactive layer "+str(spec))
	var convex := profile(100.0,0.35,0.04)
	check(Detail.apply(ridge,hill,convex,5,12,313.0,-127.0,StageRelief.SEA_RAW,StageRelief.TOP_RAW,GameConfig.HS,GameConfig.TILE)==convex[12],"detail protects convex crests")
	# At the steep cutoff, sqrt(limit²-s²) alone has an infinite derivative.
	# A smooth fade must remove the ridge well before its amplitude reaches zero.
	var edge := profile(100.0,Detail.DETAIL_LIMIT-0.0001)
	var shift := absf(StageRelief.normalize(Detail.apply(ridge,hill,edge,5,12,313.0,-127.0,StageRelief.SEA_RAW,StageRelief.TOP_RAW,GameConfig.HS,GameConfig.TILE))-StageRelief.normalize(edge[12]))*GameConfig.HS
	check(shift<0.0001,"smooth steep cutoff, metres="+str(shift))
	var plane := profile(100.0,0.15)
	var original := plane.duplicate()
	var a := Detail.apply(ridge,hill,plane,5,12,313.0,-127.0,StageRelief.SEA_RAW,StageRelief.TOP_RAW,GameConfig.HS,GameConfig.TILE)
	var scaled := Detail.apply(ridge,hill,plane,5,12,313.0,-127.0,StageRelief.SEA_RAW,StageRelief.TOP_RAW,GameConfig.HS*2,GameConfig.TILE*2)
	check(absf((a-plane[12])*0.5-(scaled-plane[12]))<1e-10,"detail uses explicit world units")
	check(plane==original,"detail does not mutate its base field")
	# The result for attempt k must not depend on which earlier basins were rejected.
	var proposals := []
	for k in 32: proposals.append(StageHydrology.lake_candidate(1234,128,96,k))
	var independent := true
	for k in range(31,-1,-1):
		StageHydrology.lake_candidate(1234,128,96,100+k)
		independent = independent and proposals[k]==StageHydrology.lake_candidate(1234,128,96,k)
		var p: Dictionary=proposals[k]
		independent = independent and p.x>=24 and p.x<104 and p.y>=24 and p.y<72 and p.depth>=0.006 and p.depth<0.016
	check(independent,"lake proposals are independent of rejection and request order")


static func world(seed_text: String) -> WorldData:
	var w := WorldData.new()
	w.W = SIDE; w.H = SIDE; w.N = SIDE * SIDE
	w.seed_text = seed_text; w.seed_num = WGRandom.hash_string(seed_text)
	for key: String in WorldGenerator.NOISE_SLOTS:
		w.noise[key] = Simplex.new(WorldGenerator.noise_rng(w.seed_num, key))
	return w


## Склоны и формы на суше выше 52 м (горы и предгорья), выборка через клетку
func measure(h: PackedFloat32Array) -> Dictionary:
	var slopes := PackedFloat32Array()
	var bends := [0.0, 0.0, 0.0]
	var buckets := [0, 0, 0, 0] # >0.3, >0.6, >1.0, >1.5
	var max_h := -INF
	var count := 0
	for y in range(16, SIDE - 16, 2):
		for x in range(16, SIDE - 16, 2):
			var i := y * SIDE + x
			max_h = maxf(max_h, h[i] * GameConfig.HS)
			if h[i] * GameConfig.HS < 52.0: continue
			count += 1
			var g := Vector2(h[i+1]-h[i-1], h[i+SIDE]-h[i-SIDE]).length()*GameConfig.HS/(2*GameConfig.TILE)
			slopes.append(g)
			for k in 4: buckets[k] += int(g > [0.3, 0.6, 1.0, 1.5][k])
			for k in 3:
				var d: int = [2, 4, 8][k]
				bends[k] += absf((h[i-d]+h[i+d]+h[i-d*SIDE]+h[i+d*SIDE])*0.25-h[i])*GameConfig.HS
	slopes.sort()
	var n := maxi(count, 1)
	if slopes.is_empty(): slopes.append(0.0)
	return {cells=count, max_m=snappedf(max_h, 0.01), slope_p50=snappedf(slopes[slopes.size()/2], 0.001),
		slope_p90=snappedf(slopes[int(slopes.size()*0.9)], 0.001), slope_p99=snappedf(slopes[int(slopes.size()*0.99)], 0.001),
		over30_pct=snappedf(100.0*buckets[0]/n, 0.01), over60_pct=snappedf(100.0*buckets[1]/n, 0.01),
		over100_pct=snappedf(100.0*buckets[2]/n, 0.01), over150_pct=snappedf(100.0*buckets[3]/n, 0.01),
		bend8_m=snappedf(bends[0]/n, 0.001), bend16_m=snappedf(bends[1]/n, 0.001), bend32_m=snappedf(bends[2]/n, 0.001)}


func relief(w: WorldData, on: bool) -> Dictionary:
	var start := Time.get_ticks_usec()
	StageRelief.run(w,on)
	return {h=w.h, macro=Vector2(w.macro_x, w.macro_y), ms=(Time.get_ticks_usec()-start)/1000.0}


func run() -> void:
	var backend := Grid.fast_grid()
	check(backend!=null,"native backend available for C#/GDScript comparison")
	if backend==null:
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(OUT)
	contracts()
	var seeds: Array = SEEDS
	var a := OS.get_cmdline_user_args()
	if a.has("--seeds"): seeds = a[a.find("--seeds") + 1].split(",", false)
	var rows := []
	for seed_text: String in seeds:
		var w := world(seed_text)
		relief(w, true) # прогрев: первый проход платит за загрузку и JIT
		var off := relief(w, false)
		var on := relief(w, true)
		check(off.macro == on.macro, "same world window " + seed_text)
		var geo7 := GEO7.path_join(seed_text + "_before.bin")
		if FileAccess.file_exists(geo7):
			var old: Dictionary = FileAccess.open(geo7, FileAccess.READ).get_var()
			check(old.h == off.h, "layer off == GEO 7 bit for bit " + seed_text)
		var delta := 0.0; var mean := 0.0; var coast := 0; var changed := 0; var detail_cell := 0
		for i in w.N:
			var d: float = (on.h[i] - off.h[i]) * GameConfig.HS
			if absf(d)>delta: delta=absf(d); detail_cell=i
			mean += d
			coast += int((on.h[i] > 0) != (off.h[i] > 0))
			changed += int(on.h[i] != off.h[i])
		check(coast == 0, "sea mask unchanged " + seed_text)
		# C#/GDScript, параллельность, отрицательные координаты, независимость от размера запроса
		for enabled: bool in [false,true]:
			for p: Vector2i in [Vector2i(-37,701),Vector2i(740,740),Vector2i(detail_cell%SIDE-12,detail_cell/SIDE-8)]:
				var native := StageRelief.raw_rect(w,p.x,p.y,24,16,false,enabled)
				check(native==StageRelief._rows(w,p.x,p.y,24,0,16,enabled),"C#/GDScript "+seed_text+str(p)+str(enabled))
				check(native==StageRelief.raw_rect(w,p.x,p.y,24,16,true,enabled),"parallel "+str(p)+str(enabled))
				var bands := StageRelief._rows(w,p.x,p.y,24,0,7,enabled)
				bands.append_array(StageRelief._rows(w,p.x,p.y,24,7,16,enabled))
				check(native==bands,"GDScript band halo "+str(p)+str(enabled))
				var padded := StageRelief.raw_rect(w,p.x-5,p.y-3,31,21,false,enabled)
				var same := true
				for y in 16:
					for x in 24: same = same and native[y*24+x]==padded[(y+3)*31+x+5]
				check(same,"neighbour overlap "+str(p)+str(enabled))
		var requests := Parallel.bands(2,func(j0:int,_j1:int)->PackedFloat32Array:return StageRelief.raw_rect(w,190,290,24,16,false,j0==1),1)
		check(requests[0]==StageRelief.raw_rect(w,190,290,24,16,false,false) and requests[1]==StageRelief.raw_rect(w,190,290,24,16,false,true),"concurrent modes remain independent")
		check(StageRelief.raw_rect(w,0,0,0,16,false).is_empty(),"empty rectangle")
		for v: String in ["off", "on"]:
			var data: Dictionary = off if v == "off" else on
			FileAccess.open(OUT.path_join(seed_text + "_" + v + ".bin"), FileAccess.WRITE).store_var({h=data.h, macro=data.macro})
		var row := {seed=seed_text, off=measure(off.h), on=measure(on.h), off_ms=snappedf(off.ms, 1), on_ms=snappedf(on.ms, 1),
			max_delta_m=snappedf(delta, 0.01), mean_delta_m=snappedf(mean / w.N, 0.001), changed_pct=snappedf(100.0*changed/w.N, 0.1)}
		rows.append(row)
		print("RESULT ", JSON.stringify(row))
	FileAccess.open(OUT.path_join("results.json"), FileAccess.WRITE).store_string(JSON.stringify(rows, "\t"))
	print("MOUNTAIN DETAIL ", failures, " failures")
	quit(1 if failures else 0)
