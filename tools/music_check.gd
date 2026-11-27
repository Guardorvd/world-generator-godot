extends SceneTree
## Isolated check of the soundtrack director (MusicDirector) and the music volume setting, no world, seconds.
## Uses three short generated test tracks in user:// with shortened timings, so the whole cycle fits in seconds:
## silence -> load (worker thread) -> fade in -> play -> fade out -> silence -> next track (shuffled, no repeat),
## level never above db_music, smooth fades, pause duck, Music bus = music_volume (30 % by default),
## and the real folder resources/sounds/soundtrack is scanned (prints how many tracks it holds).
## Run: godot --headless --path . --script res://tools/music_check.gd

const AudioCfg := preload("res://scripts/audio/game_audio_config.gd")
const MusicDirector := preload("res://scripts/audio/music_director.gd")
const AudioBuses := preload("res://scripts/audio/game_audio_buses.gd")
const DIR := "user://music_check"


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	_run.call_deferred()


func _run() -> void:
	var ok := true
	DirAccess.make_dir_recursive_absolute(DIR)
	for i in 3:
		_write_tone(DIR.path_join("track_%d.wav" % i), 220.0 * (i + 1), 3.0)

	var cfg = AudioCfg.load_or_default().duplicate()
	cfg.music_first_delay_range = Vector2(0.4, 0.4)
	cfg.music_gap_range = Vector2(0.6, 0.6)
	cfg.music_fade_in_s = 0.5
	cfg.music_fade_out_s = 0.5
	cfg.music_max_play_s = 2.0
	AudioBuses.ensure_layout(cfg)

	var real := MusicDirector.scan(String(cfg.music_dir))
	print("папка %s: треков %d" % [cfg.music_dir, real.size()])
	if not real.is_empty():
		var first := MusicDirector.load_track(real[0])
		ok = _check(ok, first != null and first.get_length() > 10.0, "настоящий трек грузится: %s, %.0f с" % [real[0].get_file(), first.get_length() if first != null else 0.0])

	var m := MusicDirector.new()
	root.add_child(m)
	m.set_process(false)   # шагаем сами
	m.setup(cfg, DIR)
	ok = _check(ok, m.track_count() == 3, "найдено 3 тестовых трека")

	var dt := 0.02
	var started: Array[String] = []
	var max_db := -80.0
	var max_jump := 0.0
	var prev_db := -80.0
	var phases := {}
	var t := 0.0
	while t < 12.0 and started.size() < 4:
		m.step(dt)
		if m.phase_name() == "LOADING":
			OS.delay_msec(2)
		phases[m.phase_name()] = true
		var db: float = m._player.volume_db
		if db > -79.0:
			max_db = maxf(max_db, db)
			if prev_db > -79.0:
				max_jump = maxf(max_jump, absf(db_to_linear(db) - db_to_linear(prev_db)) / db_to_linear(float(cfg.db_music)))
		prev_db = db
		if m.current_track != "" and (started.is_empty() or started[-1] != m.current_track):
			started.append(m.current_track)
		t += dt
	ok = _check(ok, phases.has_all(["WAIT", "LOADING", "FADE_IN", "PLAY", "FADE_OUT"]), "все фазы пройдены: %s" % str(phases.keys()))
	ok = _check(ok, started.size() >= 3, "сыграно треков подряд с паузами: %d" % started.size())
	var repeat := false
	for i in range(1, started.size()):
		repeat = repeat or started[i] == started[i - 1]
	var first_three := {}
	for i in mini(3, started.size()):
		first_three[started[i]] = true
	ok = _check(ok, not repeat and first_three.size() == mini(3, started.size()), "без повторов, все по разу: %s" % str(started.map(func(p: String) -> String: return p.get_file())))
	ok = _check(ok, max_db <= float(cfg.db_music) + 0.05, "не громче db_music (%.1f): максимум %.1f дБ" % [cfg.db_music, max_db])
	ok = _check(ok, max_jump < 0.1, "затухания плавные: наибольший шаг громкости за кадр %.1f %% от полной" % (max_jump * 100.0))

	# пауза приглушает, но не обрывает
	m._phase = MusicDirector.Phase.PLAY
	m._t = 0.0
	m._play_for = 10.0
	m._gain = 1.0
	m.set_ducked(true)
	for i in 60:
		m.step(dt)
	var ducked: float = m._player.volume_db
	ok = _check(ok, absf(ducked - (float(cfg.db_music) + float(cfg.music_pause_duck_db))) < 0.3,
		"пауза: %.1f дБ (ожидалось %.1f)" % [ducked, cfg.db_music + cfg.music_pause_duck_db])
	m.set_ducked(false)
	for i in 60:
		m.step(dt)
	ok = _check(ok, absf(m._player.volume_db - float(cfg.db_music)) < 0.3, "после паузы обратно %.1f дБ" % m._player.volume_db)

	# настройка громкости музыки
	var s := GameSettings.new()
	ok = _check(ok, is_equal_approx(s.music_volume, 0.3), "громкость музыки по умолчанию 30 %")
	s.apply_volume()
	var idx := AudioServer.get_bus_index(cfg.music_bus)
	ok = _check(ok, idx != -1 and absf(AudioServer.get_bus_volume_db(idx) - linear_to_db(0.3)) < 0.05,
		"шина Music: %.1f дБ при 30 %%" % (AudioServer.get_bus_volume_db(idx) if idx != -1 else 0.0))
	s.music_volume = 0.0
	s.apply_volume()
	ok = _check(ok, AudioServer.is_bus_mute(idx), "0 % выключает музыку")
	s.music_volume = 0.3
	s.apply_volume()

	m.queue_free()
	await process_frame
	for i in 3:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR.path_join("track_%d.wav" % i)))
	print("MUSIC_CHECK ", "OK" if ok else "FAIL")
	quit(0 if ok else 1)


func _check(ok: bool, cond: bool, msg: String) -> bool:
	print(("OK   " if cond else "FAIL ") + msg)
	return ok and cond


func _write_tone(path: String, hz: float, sec: float) -> void:
	var n := int(sec * 22050)
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		data.encode_s16(i * 2, int(sin(TAU * hz * i / 22050.0) * 8000.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = 22050
	wav.data = data
	wav.save_to_wav(ProjectSettings.globalize_path(path))
