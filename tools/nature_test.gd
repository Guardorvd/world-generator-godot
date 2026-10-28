extends SceneTree
## 6.2: направленность природных зависимостей и повторяемость готовой растительности.

var fails := 0


func check(ok: bool, label: String) -> void:
	if not ok:
		printerr(label)
		fails += 1


func _init() -> void:
	preload("res://tools/watchdog.gd").arm(self, 300)
	Grid.allow_fast = false
	var w := WorldData.new()
	w.W = 9
	w.H = 9
	w.N = 81
	w.elev.resize(w.N)
	w.elev.fill(0.1)
	var flat := StageClimate.natural_conditions(w, 4, 4)
	w.elev[40] = 0.095
	var hollow := StageClimate.natural_conditions(w, 4, 4)
	w.elev[40] = 0.105
	var ridge := StageClimate.natural_conditions(w, 4, 4)
	check(hollow.y > flat.y and ridge.y < flat.y, "Ложбина должна удерживать больше влаги, чем гребень")
	for y in w.H:
		for x in w.W:
			w.elev[y * w.W + x] = 0.1 - y * 0.004
	var sunny := StageClimate.natural_conditions(w, 4, 4)
	for y in w.H:
		for x in w.W:
			w.elev[y * w.W + x] = 0.1 + y * 0.004
	var shaded := StageClimate.natural_conditions(w, 4, 4)
	check(sunny.x > flat.x and shaded.x < flat.x, "Южный склон должен быть светлее северного")
	var dry := StageClimate.soil_moisture(0.5, 20.0, 0.3, 0.6, sunny)
	var cool := StageClimate.soil_moisture(0.5, 20.0, 0.3, 0.6, shaded)
	check(dry < cool, "Прогрев должен подсушивать склон")
	check(StageClimate.soil_moisture(0.5, 1.0, 0.3, 0.6, sunny) > dry, "У воды почва должна быть влажнее")
	check(StageClimate.soil_moisture(0.5, 20.0, 1.0, 0.6, sunny) < dry, "Крутой склон должен лучше дренироваться")
	var kinds: Array = Biomes.LIST[Biomes.FOREST].kinds
	var dry_pines := 0
	var wet_pines := 0
	var dry_birches := 0
	var wet_birches := 0
	for n in 1000:
		var r := (n + 0.5) / 1000.0
		var a := StageVegetation._kind(Biomes.FOREST, kinds, r, 0.08, 0.25, 0.2, 8.0, 0.55, 0.8, 0.8)
		var b := StageVegetation._kind(Biomes.FOREST, kinds, r, 0.08, 0.8, 0.2, 1.0, 0.55, 0.3, 0.8)
		dry_pines += int(a == Biomes.T_PINE)
		wet_pines += int(b == Biomes.T_PINE)
		dry_birches += int(a == Biomes.T_BIRCH)
		wet_birches += int(b == Biomes.T_BIRCH)
		check(StageVegetation._kind(Biomes.TUNDRA, [Biomes.T_BUSH], r, 0.0, 0.5, 0.0, 1.0, 0.18, 0.5, 0.0) != Biomes.T_BIRCH, "Холодный берег тундры не должен давать берёзовую рощу")
	check(dry_pines > wet_pines and wet_birches > dry_birches, "Состав сообщества должен меняться с условиями")
	var a := WorldGenerator.generate("Природа-62", 128)
	var b := WorldGenerator.generate("Природа-62", 128)
	check(a.biome == b.biome and a.moist == b.moist and a.obj_x == b.obj_x and a.obj_y == b.obj_y and a.obj_k == b.obj_k and a.obj_s == b.obj_s, "Один сид должен давать ту же растительность")
	check(a.obj_count > 0, "Контрольный мир должен содержать растительность")
	print("Природные условия: %d ошибок; объектов %d" % [fails, a.obj_count])
	quit(1 if fails else 0)
