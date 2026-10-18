extends SceneTree
## География на разных сидах: сток, поселения, стыки кусков и совпадение C#/GDScript.
## Печатает высоты и крутизну гор для сравнения версий. Полный прогон — 12 миров по 512 клеток;
## -- --quick — четыре мира самопроверки; -- --out <файл.json> — сохранить сводку.

const SelfTest := preload("res://tools/selftest.gd")
const Dev := preload("res://tools/control/control.gd")
const SEEDS := ["Север-1234", "Туман-4821", "Ущелье", "Янтарь-5150", "a1", "b2", "c3", "d4", "e5", "f6", "g7", "h8"]

var _fails := 0


func _check(ok: bool, what: String) -> void:
	if not ok:
		printerr("✗ " + what)
		_fails += 1


## Прямоугольник пересекает край карты или границу внешних кусков, включая отрицательные координаты.
## Высота в клетке не должна зависеть от размера и порядка расчёта прямоугольников.
func _relief_check(w: WorldData) -> void:
	var fast := Grid.fast_grid()
	# В начале координат noise = 0. При подходе с обеих сторон высота гребня одна:
	# асимметрия после скругления раньше давала здесь скачок даже при бесконечно малом шаге
	for d: Vector2 in [Vector2(0.0001, 0.0001), Vector2(0.0001, -0.0001)]:
		var a := StageRelief._crest(w.noise.ridge, d.x, d.y, 1.0, 0.0, StageRelief.ASYM, 0.0)
		var b := StageRelief._crest(w.noise.ridge, -d.x, -d.y, 1.0, 0.0, StageRelief.ASYM, 0.0)
		_check(absf(a - b) < 1e-5, "%s: непрерывность асимметричного гребня" % w.seed_text)
	var top := 0
	for i in w.N:
		if w.h[i] > w.h[top]:
			top = i
	for p: Vector2i in [Vector2i(-65, -2), Vector2i(w.W - 2, w.H - 2), Vector2i(top % w.W - 2, top / w.W - 2)]:
		var whole := StageRelief.raw_rect(w, p.x, p.y, 6, 4, false)
		var left := StageRelief.raw_rect(w, p.x, p.y, 3, 4, false)
		var right := StageRelief.raw_rect(w, p.x + 3, p.y, 3, 4, false)
		var gd := StageRelief._rows(w, p.x, p.y, 6, 0, 4)
		for y in 4:
			for x in 6:
				var i := y * 6 + x
				var part := left[y * 3 + x] if x < 3 else right[y * 3 + x - 3]
				_check(whole[i] == part, "%s: стык рельефа %s" % [w.seed_text, p])
				_check(whole[i] == gd[i], "%s: C#/GDScript %s" % [w.seed_text, p])
	_check(fast != null, "для сравнения C#/GDScript нужна сборка Godot .NET")


func _world_check(w: WorldData) -> void:
	var bad_height := 0
	var uphill := 0
	var wet_huts := 0
	for i in w.N:
		if not is_finite(w.h[i]):
			bad_height += 1
		var d := w.down[i]
		if w.river[i] != 0 and d >= 0 and w.ocean[d] == 0 and w.lake[d] == 0 and w.h[d] > w.h[i] + 1e-6:
			uphill += 1
	for s: Dictionary in w.settlements:
		_check(w.ocean[s.i] == 0 and w.lake[s.i] == 0 and w.river[s.i] == 0, "%s: поселение на суше" % w.seed_text)
		for h: Dictionary in s.huts:
			var i := floori(h.y) * w.W + floori(h.x)
			if w.ocean[i] != 0 or w.lake[i] != 0 or w.river[i] != 0:
				wet_huts += 1
	_check(bad_height == 0, "%s: конечные высоты (%d)" % [w.seed_text, bad_height])
	_check(uphill == 0, "%s: сток рек вниз (%d)" % [w.seed_text, uphill])
	_check(wet_huts == 0, "%s: дома на суше (%d)" % [w.seed_text, wet_huts])
	_check(SelfTest.settlements_connected(w), "%s: поселения связаны" % w.seed_text)


func _stats(w: WorldData) -> Dictionary:
	var land := 0
	var mountains := 0
	var steep := 0
	var curvature := 0.0
	var max_height := 0.0
	for y in range(1, w.H - 1):
		for x in range(1, w.W - 1):
			var i := y * w.W + x
			if w.ocean[i] != 0 or w.lake[i] != 0:
				continue
			land += 1
			var h := w.h[i] * GameConfig.HS
			max_height = maxf(max_height, h)
			if h < 80.0 or w.river[i] != 0:
				continue
			mountains += 1
			var l := w.h[i - 1] * GameConfig.HS
			var r := w.h[i + 1] * GameConfig.HS
			var u := w.h[i - w.W] * GameConfig.HS
			var d := w.h[i + w.W] * GameConfig.HS
			var slope := Vector2(r - l, d - u).length() / (2.0 * GameConfig.TILE)
			if slope > tan(deg_to_rad(45.0)):
				steep += 1
			curvature += (absf(l + r - 2.0 * h) + absf(u + d - 2.0 * h)) * 0.5
	var lake_cells := 0
	for i in w.N:
		if w.lake[i] != 0:
			lake_cells += 1
	var out := {seed = w.seed_text, size = w.W, land_share = 0.0,
		lake_cells = lake_cells, rivers = w.rivers.size(), settlements = w.settlements.size(),
		bridges = w.bridges.size(), tunnels = w.tunnels.size(), connected = SelfTest.settlements_connected(w)}
	var dry := 0
	for i in w.N:
		if w.ocean[i] == 0:
			dry += 1
	out.land_share = float(dry) / w.N
	out.mountain_share = 100.0 * mountains / maxi(1, land)
	out.mountain_steep_share = 100.0 * steep / maxi(1, mountains)
	out.mountain_curvature_m = curvature / maxi(1, mountains)
	out.max_height_m = max_height
	return out


func _init() -> void:
	var cases: Array = SelfTest.CASES if OS.get_cmdline_user_args().has("--quick") else []
	if cases.is_empty():
		for s in SEEDS:
			cases.append([s, 512])
	var results: Array = []
	for c: Array in cases:
		var t0 := Time.get_ticks_msec()
		var w := WorldGenerator.generate(c[0], c[1])
		var ms := Time.get_ticks_msec() - t0
		_world_check(w)
		_relief_check(w)
		var s := _stats(w)
		s.generation_ms = ms
		results.append(s)
		print("%s@%d: %d мс; горы %.1f%%; на них >45° %.1f%%; излом %.2f м; рек %d; поселений %d; связь %s" % [w.seed_text, w.W, ms, s.mountain_share, s.mountain_steep_share, s.mountain_curvature_m, w.rivers.size(), w.settlements.size(), s.connected])
	var path := Dev.arg("out")
	if path != "":
		Dev.save_json(Dev.abs_dir(path), results)
	print("Ошибок географии: %d" % _fails)
	quit(1 if _fails > 0 else 0)
