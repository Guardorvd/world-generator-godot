extends SceneTree
## Макрогеография без мира (14.11.2026): только географические этапы плана 768 (рельеф, вода, климат,
## биомы — WorldGenerator._geography), без мест, дорог, растительности и сцены. Окно не нужно.
## Печатает на сид: сдвиг стартовой области, долю океана (и сколько его не связано с краем — замкнутые
## понижения ниже нуля), высоты суши, долю высоких гор, группы биомов, озёра, время этапов.
## Пишет сводку tools/control/runs/macro_geo<tag>.json и лист карт macro_geo<tag>.png (по 4 в ряд,
## порядок как в сводке; карта — цвет биома с отмывкой рельефа, 1 пиксель = 3 клетки).
##   -- --seeds a,b,c   свои сиды (по умолчанию CONTROL)
##   -- --quick [N]     только оценка океана по сетке 48 × 48 без слоя склонов на N сидах (секунды)
##   -- --legacy        прежний выбор стартовой области (StageRelief.legacy_start, до 14.11.2026)
##   -- --tag <имя>     суффикс файлов, например _old
## Лимит 300 с: география одного сида на втором ПК — секунды.

const CONTROL := ["Север-1234", "Ущелье", "Туман-4821", "Янтарь-5150", "a1", "b2", "c3", "d4"]
const OUT := "res://tools/control/runs"
const GROUPS := {
	forest = [Biomes.FOREST, Biomes.TAIGA, Biomes.JUNGLE],
	open = [Biomes.GRASS, Biomes.STEPPE, Biomes.SAVANNA, Biomes.DESERT],
	tundra = [Biomes.TUNDRA],
	swamp = [Biomes.SWAMP],
	rock = [Biomes.ROCK, Biomes.PEAK, Biomes.SNOW],
	shore = [Biomes.BEACH, Biomes.STONESHORE],
}
## Высоты суши в метрах (нижние границы корзин)
const BANDS := [0.0, 20.0, 80.0, 150.0, 260.0]


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 300)
	call_deferred("_run")


func _arg(name: String, fallback: String = "") -> String:
	var args := OS.get_cmdline_user_args()
	var at := args.find(name)
	if at < 0:
		return fallback
	return args[at + 1] if at + 1 < args.size() and not args[at + 1].begins_with("--") else ""


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	StageRelief.legacy_start = args.has("--legacy")
	var tag := _arg("--tag", "")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	if args.has("--quick"):
		_quick(int(_arg("--quick", "40")) if _arg("--quick", "40") != "" else 40, tag)
		quit(0)
		return
	var seeds: PackedStringArray = _arg("--seeds", ",".join(CONTROL)).split(",", false)
	var rows := []
	var maps: Array[Image] = []
	for seed_text in seeds:
		var t := Time.get_ticks_usec()
		var w := WorldGenerator._geography(seed_text, WorldGenerator.PLAN_SIZE)
		var row := stats(w)
		row.total_ms = (Time.get_ticks_usec() - t) / 1000.0
		rows.append(row)
		maps.append(map_image(w))
		_print_row(row)
	var sheet := _sheet(maps)
	sheet.save_png(ProjectSettings.globalize_path(OUT.path_join("macro_geo%s.png" % tag)))
	var f := FileAccess.open(ProjectSettings.globalize_path(OUT.path_join("macro_geo%s.json" % tag)), FileAccess.WRITE)
	f.store_string(JSON.stringify({legacy = StageRelief.legacy_start, rows = rows}, "\t"))
	f.close()
	_print_mean(rows)
	print("Macro geo: ", ProjectSettings.globalize_path(OUT.path_join("macro_geo%s.json" % tag)))
	quit(0)


## Оценка океана на многих сидах: только выбор старта и макрорельеф без слоя склонов по сетке 48 × 48
func _quick(count: int, tag: String) -> void:
	var fracs := []
	var normal := []
	var t := Time.get_ticks_usec()
	for k in count:
		var seed_text: String = CONTROL[k] if k < CONTROL.size() else "s%d" % k
		var w := WorldData.new()
		w.W = WorldGenerator.PLAN_SIZE
		w.H = WorldGenerator.PLAN_SIZE
		w.N = w.W * w.H
		w.seed_text = seed_text
		w.seed_num = WGRandom.hash_string(seed_text)
		for name: String in WorldGenerator.NOISE_SLOTS:
			w.noise[name] = Simplex.new(WorldGenerator.noise_rng(w.seed_num, name))
		StageRelief.configure(w)
		StageRelief._pick_start(w)
		var n := w.noise
		var sea := 0
		var high := 0
		for sj in 48:
			for si in 48:
				var x := floorf((si + 0.5) * w.W / 48.0)
				var y := floorf((sj + 0.5) * w.H / 48.0)
				var raw := StageRelief.raw_at(n.warpX, n.warpY, n.cont, n.mask, n.ridge, n.hill, x, y, w.macro_x, w.macro_y,
					w.mountain_scale, w.mountain_bias, w.mountain_height, w.foothill_spread)
				if raw < StageRelief.SEA_RAW:
					sea += 1
				elif StageRelief.normalize(raw) * GameConfig.HS > 150.0:
					high += 1
		var frac := sea / 2304.0
		fracs.append(frac)
		if not (StageRelief.is_coastal(w.seed_num) and not StageRelief.legacy_start):
			normal.append(frac)
		var coastal := StageRelief.is_coastal(w.seed_num) and not StageRelief.legacy_start
		print("%-12s океан %5.1f %%  выше 150 м %5.1f %%  сдвиг (%d, %d)%s" % [seed_text, frac * 100.0, high / 23.04, w.macro_x, w.macro_y, "  прибрежный" if coastal else ""])
	fracs.sort()
	var over := fracs.filter(func(v: float) -> bool: return v > 0.10).size()
	var none := fracs.filter(func(v: float) -> bool: return v <= 0.0).size()
	print("Сидов %d: медиана океана %.1f %%, 90-й процентиль %.1f %%, больше 10 %% — %d, без океана — %d; %.1f с" % [
		count, fracs[count / 2] * 100.0, fracs[int(count * 0.9)] * 100.0, over, none, (Time.get_ticks_usec() - t) / 1e6])
	normal.sort()
	print("Без прибрежных (%d): медиана %.1f %%, 90-й процентиль %.1f %%, больше 10 %% — %d, больше 15 %% — %d" % [normal.size(),
		normal[normal.size() / 2] * 100.0, normal[int(normal.size() * 0.9)] * 100.0,
		normal.filter(func(v: float) -> bool: return v > 0.10).size(), normal.filter(func(v: float) -> bool: return v > 0.15).size()])
	var f := FileAccess.open(ProjectSettings.globalize_path(OUT.path_join("macro_geo_quick%s.json" % tag)), FileAccess.WRITE)
	f.store_string(JSON.stringify({legacy = StageRelief.legacy_start, ocean = fracs}))
	f.close()


static func stats(w: WorldData) -> Dictionary:
	var N := w.N
	var ocean := 0
	var land := 0
	var bands := [0, 0, 0, 0, 0]
	var groups := {}
	for g: String in GROUPS:
		groups[g] = 0
	var group_of := {}
	for g: String in GROUPS:
		for b: int in GROUPS[g]:
			group_of[b] = g
	for i in N:
		if w.ocean[i] != 0:
			ocean += 1
			continue
		if w.lake[i] != 0:
			continue
		land += 1
		var m := w.h[i] * GameConfig.HS
		var k := 0
		while k + 1 < BANDS.size() and m >= BANDS[k + 1]:
			k += 1
		bands[k] += 1
		var g: String = group_of.get(int(w.biome[i]), "")
		if g != "":
			groups[g] += 1
	var row := {seed = w.seed_text, macro = [w.macro_x, w.macro_y],
		mountain = [snappedf(w.mountain_scale, 0.01), snappedf(w.mountain_bias, 0.01), snappedf(w.mountain_height, 0.01), snappedf(w.foothill_spread, 0.01)],
		ocean = snappedf(100.0 * ocean / N, 0.1), ocean_closed = snappedf(100.0 * _closed_ocean(w) / N, 0.1),
		lakes = int(w.generation_profile.get("freshwater_lakes", 0)), stages_ms = w.generation_profile.get("stages_ms", {})}
	var bl := {}
	for k in BANDS.size():
		bl["%d" % int(BANDS[k])] = snappedf(100.0 * bands[k] / maxf(1, land), 0.1)
	row.heights = bl
	var gl := {}
	for g: String in groups:
		gl[g] = snappedf(100.0 * groups[g] / maxf(1, land), 0.1)
	row.biomes = gl
	return row


## Клетки «океана», не связанные с краем плана: замкнутые понижения ниже нуля
static func _closed_ocean(w: WorldData) -> int:
	var seen := PackedByteArray()
	seen.resize(w.N)
	var stack := PackedInt32Array()
	for x in w.W:
		for i in [x, (w.H - 1) * w.W + x]:
			if w.ocean[i] != 0 and seen[i] == 0:
				seen[i] = 1
				stack.append(i)
	for y in w.H:
		for i in [y * w.W, y * w.W + w.W - 1]:
			if w.ocean[i] != 0 and seen[i] == 0:
				seen[i] = 1
				stack.append(i)
	while not stack.is_empty():
		var c := stack[stack.size() - 1]
		stack.resize(stack.size() - 1)
		var cx := c % w.W
		for n in [c - 1 if cx > 0 else -1, c + 1 if cx < w.W - 1 else -1, c - w.W, c + w.W]:
			if n >= 0 and n < w.N and w.ocean[n] != 0 and seen[n] == 0:
				seen[n] = 1
				stack.append(n)
	var closed := 0
	for i in w.N:
		if w.ocean[i] != 0 and seen[i] == 0:
			closed += 1
	return closed


## Карта: цвет биома с отмывкой с северо-запада, 1 пиксель = 3 клетки
static func map_image(w: WorldData) -> Image:
	var s := 3
	var side := w.W / s
	var img := Image.create(side, side, false, Image.FORMAT_RGB8)
	for py in side:
		for px in side:
			var x := px * s + 1
			var y := py * s + 1
			var i := y * w.W + x
			var c: Array = Biomes.LIST[w.biome[i]].color
			var col := Color8(c[0], c[1], c[2])
			if w.ocean[i] == 0:
				var dx := w.elev[i + 1] - w.elev[i - 1]
				var dy := w.elev[i + w.W] - w.elev[i - w.W]
				var shade := clampf(1.0 - (dx + dy) * 9.0, 0.55, 1.35)
				col = Color(col.r * shade, col.g * shade, col.b * shade)
			img.set_pixel(px, py, col)
	return img


static func _sheet(maps: Array[Image]) -> Image:
	var side := maps[0].get_width()
	var cols := mini(4, maps.size())
	var rows := (maps.size() + cols - 1) / cols
	var gap := 4
	var sheet := Image.create(cols * (side + gap) - gap, rows * (side + gap) - gap, false, Image.FORMAT_RGB8)
	sheet.fill(Color(0.1, 0.1, 0.1))
	for k in maps.size():
		sheet.blit_rect(maps[k], Rect2i(0, 0, side, side), Vector2i((k % cols) * (side + gap), (k / cols) * (side + gap)))
	return sheet


func _print_row(r: Dictionary) -> void:
	var sm: Dictionary = r.stages_ms
	print("%-12s океан %5.1f %% (замкнутый %.1f)  озёр %d  сдвиг (%d, %d)  горы m=%s" % [r.seed, r.ocean, r.ocean_closed, r.lakes, r.macro[0], r.macro[1], r.mountain])
	print("    высоты суши %s" % r.heights)
	print("    биомы суши  %s" % r.biomes)
	print("    этапы мс: рельеф %.0f, океан %.0f, озёра %.0f, климат %.0f; всего %.0f" % [sm.get("relief", 0.0), sm.get("ocean", 0.0), sm.get("hydrology", 0.0), sm.get("climate", 0.0), r.total_ms])


func _print_mean(rows: Array) -> void:
	var ocean := 0.0
	var high := 0.0
	var relief := 0.0
	var g := {}
	for r: Dictionary in rows:
		ocean += r.ocean
		high += r.heights["150"] + r.heights["260"]
		relief += r.stages_ms.get("relief", 0.0)
		for k: String in r.biomes:
			g[k] = g.get(k, 0.0) + r.biomes[k]
	var n := float(rows.size())
	for k: String in g:
		g[k] = snappedf(g[k] / n, 0.1)
	print("Среднее по %d сидам: океан %.1f %%, суша выше 150 м %.1f %%, биомы %s, рельеф %.0f мс" % [n, ocean / n, high / n, g, relief / n])
