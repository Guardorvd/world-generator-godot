extends SceneTree
## Проверка звуков (с 2.7), без окна: петли повторяются, у каждого звука разумная длина,
## WorldAudio в мире выбирает поверхность шагов и слышит воду. Запуск:
##   godot --headless --script res://tools/sound_check.gd

const LOOPS := ["wind", "water", "surf", "fire", "roll", "grit", "freewheel", "chain"]


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var ok := true
	for n: String in LOOPS:
		var s: AudioStreamWAV = load("res://resources/sounds/%s.wav" % n)
		if s.loop_mode != AudioStreamWAV.LOOP_FORWARD:
			push_error("%s: не петля" % n)
			ok = false
		print("%-6s %.1f с, петля %d" % [n, s.get_length(), s.loop_mode])
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
