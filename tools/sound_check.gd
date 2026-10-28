extends SceneTree
## Проверка звуков (с 2.7), без окна: петли повторяются, у каждого звука разумная длина,
## WorldAudio в мире выбирает поверхность шагов и слышит воду. Запуск:
##   godot --headless --script res://tools/sound_check.gd

const LOOPS := ["wind", "water", "surf", "fire", "roll", "grit", "freewheel", "chain"]

class AudioWorld extends WorldData:
	func tile_info(_x: float, _z: float) -> Dictionary:
		return {biome = Biomes.GRASS, path = 0, surface = RoadSurface.NONE}

class AudioGround extends Heightfield:
	func _init(w: WorldData) -> void:
		super()
		world = w
	func ground_at(_x: float, _z: float, _raw := false) -> float:
		return 0.0
	func surface_at(_x: float, _z: float, _feet := -INF) -> float:
		return 0.0
	func depth_at(_x: float, _z: float, _feet := -INF) -> float:
		return 0.0


func _init() -> void:
	preload("res://tools/watchdog.gd").arm(self, 240)
	_run.call_deferred()


func _run() -> void:
	var ok := true
	for n: String in LOOPS:
		var s: AudioStreamWAV = load("res://resources/sounds/%s.wav" % n)
		if s.loop_mode != AudioStreamWAV.LOOP_FORWARD:
			push_error("%s: не петля" % n)
			ok = false
		print("%-6s %.1f с, петля %d" % [n, s.get_length(), s.loop_mode])
	if "--isolated" in OS.get_cmdline_user_args():
		_isolated(ok)
		return
	var w := WorldGenerator.generate("Север-1234", 256)
	var h := Heightfield.new(w)
	var a := WorldAudio.new()
	root.add_child(a)   # _ready создаёт проигрыватели
	a.setup(w, h)
	var kinds := {}
	for y in range(2, w.H - 2, 3):
		for x in range(2, w.W - 2, 3):
			var px := (x + 0.5) * GameConfig.TILE
			var pz := (y + 0.5) * GameConfig.TILE
			kinds[a._surface(px, pz, h.surface_at(px, pz, -INF))] = true
	print("поверхности шагов: ", kinds.keys())
	for k: String in ["soft", "gravel", "splash"]:
		if not kinds.has(k):
			push_error("нет шагов «%s»" % k)
			ok = false
	var p := PlayerState.spawn(w, h)
	a._sample(Vector3(p.x, p.feet, p.z))
	if a._fire.playing != (Vector2(p.x, p.z).distance_to(Vector2(PlayerState.home(w).x, PlayerState.home(w).y) * GameConfig.TILE) < WorldAudio.FIRE_R):
		push_error("костёр")
		ok = false
	print("у точки появления: вода %.2f, море %.2f, птицы %s" % [a._goal[a._water], a._goal[a._surf], a._bird_ok], ", костёр ", a._fire.playing)
	# без окна звук не выводится, и при выходе Godot пишет про 4 «неосвобождённых» петли: это
	# воспроизведения, которые снимает только звуковой поток; в игре (lifecycle_test) ничего не копится
	a.free()
	print("ЗВУКИ ", "OK" if ok else "ОШИБКА")
	quit(0 if ok else 1)


## 12.9: микс без генерации. На суше в покое нет гула; при езде и у воды шум ограничен.
func _isolated(ok: bool) -> void:
	var w := AudioWorld.new()
	w.W = 8
	w.H = 8
	w.N = 64
	w.dist_water.resize(w.N)
	w.dist_ocean.resize(w.N)
	w.dist_water.fill(100.0)
	w.dist_ocean.fill(100.0)
	var a := WorldAudio.new()
	root.add_child(a)
	a.setup(w, AudioGround.new(w))
	for speed: float in [0.0, 6.0, 11.0, 23.0]:
		for frame in 120:
			a.update(Vector3(16, 0, 16), speed, true, 1.0 / 60.0)
		var valid := a._roll.volume_db <= -21.9
		if speed == 0.0:
			valid = valid and a._roll.volume_db <= -79.0 and a._water.volume_db <= -79.0 and a._surf.volume_db <= -79.0
		print("speed %.0f: roll %.1f dB, water %.1f, surf %.1f" % [speed, a._roll.volume_db, a._water.volume_db, a._surf.volume_db])
		ok = ok and valid
	w.dist_ocean.fill(0.0)
	w.dist_water.fill(0.0)
	a._sample_t = 0.0
	for frame in 240:
		a.update(Vector3(16, 0, 16), 0.0, false, 1.0 / 60.0)
	print("shore: surf %.1f dB" % a._surf.volume_db)
	ok = ok and a._surf.volume_db <= -21.9 and a._surf.volume_db > -24.0
	w.dist_ocean.fill(100.0)
	a._sample_t = 0.0
	for frame in 240:
		a.update(Vector3(16, 0, 16), 0.0, false, 1.0 / 60.0)
	print("river: water %.1f dB" % a._water.volume_db)
	ok = ok and a._water.volume_db <= -20.9 and a._water.volume_db > -23.0
	a.set_paused(true)
	for p: Node in a.get_children():
		if p in a._goal:
			ok = ok and p.stream_paused
		p.stop()
	a.free()
	print("ИЗОЛИРОВАННЫЙ МИКС ", "OK" if ok else "ОШИБКА")
	quit(0 if ok else 1)
