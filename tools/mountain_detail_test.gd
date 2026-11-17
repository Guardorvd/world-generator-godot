extends SceneTree
## Слой детализации гор без генерации мира: рельеф трёх сидов с выключенным и включённым
## слоем в одном процессе. Сверка: C#/GDScript, параллельный расчёт,
## отрицательные координаты, перекрытие запросов соседних кусков (швы). Метрики склонов,
## кривизны, высоты, береговой маски и времени. Поля для mountain_detail_look — в OUT.
## godot --headless --path . --script res://tools/mountain_detail_test.gd [-- --seeds "Ущелье"]
## --same-heights --base <папка> проверяет оптимизацию побайтно по сохранённым полям off/on.
const OUT := "res://.godot/mountain_detail"
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
	for spec: Array in [[8.0,0.35],[20.0,0.03],[100.0,0.0],[100.0,0.9]]:
		var b := profile(spec[0],spec[1])
		ridge.calls=0; hill.calls=0
		var v := Detail.apply(ridge,hill,b,5,12,313.0,-127.0,StageRelief.SEA_RAW,StageRelief.TOP_RAW,GameConfig.HS,GameConfig.TILE)
		check(v==b[12],"no detail on low, flat or steep ground "+str(spec))
		check(ridge.calls==0 and hill.calls==0,"no noise calls for inactive layer "+str(spec))
	var low := profile(24.0, 0.5)
	ridge.calls = 0
	hill.calls = 0
	var low_rib := Detail.apply(ridge, hill, low, 5, 12, 313.0, -127.0, StageRelief.SEA_RAW, StageRelief.TOP_RAW, GameConfig.HS, GameConfig.TILE)
	check(low_rib != low[12] and ridge.calls == 1 and hill.calls == 1, "low steep slopes use broad ribs only")
	var convex := profile(100.0,0.35,0.04)
	var same_grade := profile(100.0,0.35)
	var rib := absf(Detail.apply(ridge,hill,same_grade,5,12,313.0,-127.0,StageRelief.SEA_RAW,StageRelief.TOP_RAW,GameConfig.HS,GameConfig.TILE)-same_grade[12])
	var crest_rib := absf(Detail.apply(ridge,hill,convex,5,12,313.0,-127.0,StageRelief.SEA_RAW,StageRelief.TOP_RAW,GameConfig.HS,GameConfig.TILE)-convex[12])
	check(crest_rib > 0.0 and crest_rib < rib, "convex slopes keep a smaller share of the ribs")
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
	var r := StageRelief.MICRO_PAD
	var width := 2 * r + 1
	var center := r * width + r
	var flat := PackedFloat32Array()
	flat.resize(width * width)
	flat.fill(0.12)
	var shoulder := flat.duplicate()
	var hollow := flat.duplicate()
	var flank := flat.duplicate()
	for z in range(-r, r + 1):
		for x in range(-r, r + 1):
			var i := center + z * width + x
			shoulder[i] -= (x*x + z*z) * 0.0002
			hollow[i] += (x*x + z*z) * 0.0002
			flank[i] += x * 0.004
	var flat_ripple := absf(StageRelief.add_micro(flat, center, width, hill, 20.0, 50.0) - flat[center])
	var hollow_ripple := absf(StageRelief.add_micro(hollow, center, width, hill, 20.0, 50.0) - hollow[center])
	var shoulder_ripple := absf(StageRelief.add_micro(shoulder, center, width, hill, 20.0, 50.0) - shoulder[center])
	var flank_ripple := absf(StageRelief.add_micro(flank, center, width, hill, 20.0, 50.0) - flank[center])
	check(flat_ripple > 0.0 and is_equal_approx(hollow_ripple, flat_ripple) and flat_ripple < minf(flank_ripple, shoulder_ripple) * 0.1,
		"flat and hollow ripple below 10% of slope and shoulder ripple")
	var micro_noise := Simplex.new(WGRandom.new(271))
	var calm := INF
	var lively := 0.0
	for x in range(-300, 301, 17):
		var carrier := micro_noise.fbm(x / 9.0, 50.0 / 9.0, 2)
		if absf(carrier) < 0.1: continue
		var strength := absf((StageRelief.add_micro(flank, center, width, micro_noise, x, 50.0) - flank[center]) / (carrier * 0.006))
		calm = minf(calm, strength)
		lively = maxf(lively, strength)
	check(calm > 0.0 and lively > calm * 2.0, "ripple strength varies along the same slope")
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


## Склоны и формы по диапазонам высоты, выборка через клетку.
func measure(h: PackedFloat32Array, min_m: float, max_m: float = INF) -> Dictionary:
	var slopes := PackedFloat32Array()
	var bends := [0.0, 0.0, 0.0]
	var buckets := [0, 0, 0, 0] # >0.3, >0.6, >1.0, >1.5
	var max_h := -INF
	var count := 0
	for y in range(16, SIDE - 16, 2):
		for x in range(16, SIDE - 16, 2):
			var i := y * SIDE + x
			var metres := h[i] * GameConfig.HS
			if metres < min_m or metres >= max_m: continue
			max_h = maxf(max_h, metres)
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
	return {cells=count, max_m=snappedf(max_h, 0.01) if count > 0 else 0.0, slope_p50=snappedf(slopes[slopes.size()/2], 0.001),
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
	var baseline := a[a.find("--base") + 1] if a.has("--base") else ""
	var same_heights := a.has("--same-heights")
	if same_heights and baseline.is_empty():
		push_error("--same-heights требует --base с ранее сохранёнными полями")
		quit(1)
		return
	var rows := []
	for seed_text: String in seeds:
		var w := world(seed_text)
		relief(w, true) # прогрев: первый проход платит за загрузку и JIT
		var off := relief(w, false)
		var on := relief(w, true)
		check(off.macro == on.macro, "same world window " + seed_text)
		var delta := 0.0; var mean := 0.0; var coast := 0; var changed := 0; var detail_cell := 0
		var low_delta := 0.0; var low_cell := 0
		for i in w.N:
			var d: float = (on.h[i] - off.h[i]) * GameConfig.HS
			if absf(d)>delta: delta=absf(d); detail_cell=i
			if off.h[i] * GameConfig.HS < 30.0 and absf(d) > low_delta:
				low_delta = absf(d)
				low_cell = i
			mean += d
			coast += int((on.h[i] > 0) != (off.h[i] > 0))
			changed += int(on.h[i] != off.h[i])
		check(coast == 0, "sea mask unchanged " + seed_text)
		# C#/GDScript, параллельность, отрицательные координаты, независимость от размера запроса
		for enabled: bool in [false,true]:
			for p: Vector2i in [Vector2i(-37,701),Vector2i(740,740),Vector2i(detail_cell%SIDE-12,detail_cell/SIDE-8),Vector2i(low_cell%SIDE-12,low_cell/SIDE-8)]:
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
		var p := Vector2i(-11, 701)
		var heights := StageRelief.height_rect(w, p.x, p.y, 24, 16, false)
		check(heights == StageRelief.height_rect(w, p.x, p.y, 24, 16, true), "parallel ripple " + seed_text)
		Grid.allow_fast = false
		var gd_heights := StageRelief.height_rect(w, p.x, p.y, 24, 16, true)
		Grid.allow_fast = true
		check(heights == gd_heights, "C#/GDScript ripple " + seed_text)
		check(heights == OuterLand.compute(w, p.x, p.y, 24, 16).h, "OuterLand ripple " + seed_text)
		var plan_match := true
		for y in 16:
			for x in range(-p.x, 24):
				plan_match = plan_match and heights[y * 24 + x] == w.h[(p.y + y) * w.W + p.x + x]
		check(plan_match, "ripple overlaps the plan edge " + seed_text)
		for cell: int in [detail_cell, low_cell]:
			var at := Vector2i(cell % SIDE - 8, cell / SIDE - 8)
			var native := StageRelief.height_rect(w, at.x, at.y, 16, 16, true)
			Grid.allow_fast = false
			var gd := StageRelief.height_rect(w, at.x, at.y, 16, 16, false)
			Grid.allow_fast = true
			check(native.to_byte_array() == gd.to_byte_array(), "C#/GDScript ground bytes " + seed_text + str(at))
		for v: String in ["off", "on"]:
			var data: Dictionary = off if v == "off" else on
			if same_heights:
				var ref := FileAccess.open(baseline.path_join(seed_text + "_" + v + ".bin"), FileAccess.READ)
				var previous: Variant = ref.get_var() if ref != null else null
				check(previous is Dictionary and previous.h.to_byte_array() == data.h.to_byte_array(),
					"ground bytes identical to baseline " + seed_text + " " + v)
			FileAccess.open(OUT.path_join(seed_text + "_" + v + ".bin"), FileAccess.WRITE).store_var({h=data.h, macro=data.macro})
		var row := {seed=seed_text, off=measure(off.h, 52.0), on=measure(on.h, 52.0), off_ms=snappedf(off.ms, 1), on_ms=snappedf(on.ms, 1),
			low_off=measure(off.h, 0.0001, 30.0), low_on=measure(on.h, 0.0001, 30.0), low_delta_m=snappedf(low_delta, 0.01),
			max_delta_m=snappedf(delta, 0.01), mean_delta_m=snappedf(mean / w.N, 0.001), changed_pct=snappedf(100.0*changed/w.N, 0.1)}
		if not baseline.is_empty():
			var previous: Dictionary = FileAccess.open(baseline.path_join(seed_text + "_on.bin"), FileAccess.READ).get_var()
			check(previous.macro == on.macro, "start window unchanged from baseline " + seed_text)
			var baseline_coast := 0
			for i in w.N:
				baseline_coast += int((previous.h[i] > 0.0) != (on.h[i] > 0.0))
			check(baseline_coast == 0, "sea mask unchanged from baseline " + seed_text)
			row.before = measure(previous.h, 0.0001)
			row.before_low = measure(previous.h, 0.0001, 30.0)
			row.after = measure(on.h, 0.0001)
			check(row.after.over100_pct <= row.before.over100_pct + 1.0, "100% slopes within one percentage point " + seed_text)
		rows.append(row)
		print("RESULT ", JSON.stringify(row))
	FileAccess.open(OUT.path_join("results.json"), FileAccess.WRITE).store_string(JSON.stringify(rows, "\t"))
	print("MOUNTAIN DETAIL ", failures, " failures")
	quit(1 if failures else 0)
