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
var failures := 0


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 150)
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
	return {cells=count, max_m=snappedf(max_h, 0.01), slope_p50=snappedf(slopes[slopes.size()/2], 0.001),
		slope_p90=snappedf(slopes[int(slopes.size()*0.9)], 0.001), slope_p99=snappedf(slopes[int(slopes.size()*0.99)], 0.001),
		over30_pct=snappedf(100.0*buckets[0]/n, 0.01), over60_pct=snappedf(100.0*buckets[1]/n, 0.01),
		over100_pct=snappedf(100.0*buckets[2]/n, 0.01), over150_pct=snappedf(100.0*buckets[3]/n, 0.01),
		bend8_m=snappedf(bends[0]/n, 0.001), bend16_m=snappedf(bends[1]/n, 0.001), bend32_m=snappedf(bends[2]/n, 0.001)}


func relief(w: WorldData, on: bool) -> Dictionary:
	StageRelief.mountain_detail = on
	var start := Time.get_ticks_usec()
	StageRelief.run(w)
	return {h=w.h, macro=Vector2(w.macro_x, w.macro_y), ms=(Time.get_ticks_usec()-start)/1000.0}


func run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
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
		var delta := 0.0; var mean := 0.0; var coast := 0; var changed := 0
		for i in w.N:
			var d: float = (on.h[i] - off.h[i]) * GameConfig.HS
			delta = maxf(delta, absf(d)); mean += d
			coast += int((on.h[i] > 0) != (off.h[i] > 0))
			changed += int(on.h[i] != off.h[i])
		check(coast == 0, "sea mask unchanged " + seed_text)
		# C#/GDScript, параллельность, отрицательные координаты, независимость от размера запроса
		for p: Vector2i in [Vector2i(-37, 701), Vector2i(740, 740), Vector2i(190, 290), Vector2i(400, 120)]:
			var native := StageRelief.raw_rect(w, p.x, p.y, 24, 16, false)
			check(native == StageRelief._rows(w, p.x, p.y, 24, 0, 16), "C#/GDScript " + seed_text + str(p))
			check(native == StageRelief.raw_rect(w, p.x, p.y, 24, 16, true), "parallel " + str(p))
			var padded := StageRelief.raw_rect(w, p.x - 5, p.y - 3, 31, 21, false)
			var same := true
			for y in 16:
				for x in 24: same = same and native[y*24+x] == padded[(y+3)*31+x+5]
			check(same, "neighbour overlap " + str(p))
		for v: String in ["off", "on"]:
			var data: Dictionary = off if v == "off" else on
			FileAccess.open(OUT.path_join(seed_text + "_" + v + ".bin"), FileAccess.WRITE).store_var({h=data.h, macro=data.macro})
		var row := {seed=seed_text, off=measure(off.h), on=measure(on.h), off_ms=snappedf(off.ms, 1), on_ms=snappedf(on.ms, 1),
			max_delta_m=snappedf(delta, 0.01), mean_delta_m=snappedf(mean / w.N, 0.001), changed_pct=snappedf(100.0*changed/w.N, 0.1)}
		rows.append(row)
		print("RESULT ", JSON.stringify(row))
	StageRelief.mountain_detail = true
	FileAccess.open(OUT.path_join("results.json"), FileAccess.WRITE).store_string(JSON.stringify(rows, "\t"))
	print("MOUNTAIN DETAIL ", failures, " failures")
	quit(1 if failures else 0)
