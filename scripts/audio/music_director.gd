extends Node
## In-game soundtrack (27.11.2026). Plays the user's tracks from resources/sounds/soundtrack/ the way games do,
## not like a playlist:
## - the world starts in silence (nature only); the first piece comes in after a pause;
## - each piece fades in and out smoothly; long pieces are faded out after a while instead of played to the end;
## - between pieces there is a random stretch of silence; order is shuffled, no piece repeats until all have played;
## - the pause menu lowers music a little instead of cutting it.
## Volume: Music bus (GameSettings.music_volume, 50 % by default), and GameAudioConfig.db_music keeps
## "100 %" quieter than the files themselves. Every number is in GameAudioConfig (group "Music").
## Files are found at runtime: drop .mp3 / .ogg / .wav into the folder, no code or list to edit.
## Loading happens on a worker thread during the silence before a piece, so starting one never stalls a frame.

const AudioCfg := preload("res://scripts/audio/game_audio_config.gd")
const EXTENSIONS := ["mp3", "ogg", "wav"]
const SILENT_LINEAR := 0.0

enum Phase { WAIT, LOADING, FADE_IN, PLAY, FADE_OUT }

var _cfg
var _player: AudioStreamPlayer
var _tracks: PackedStringArray = []
var _bag: PackedStringArray = []      # shuffled order still to play
var _last := ""
var _phase := Phase.WAIT
var _wait := 0.0                      # seconds of silence left (WAIT)
var _t := 0.0                         # seconds into the current phase
var _play_for := 0.0                  # how long the current piece plays at full level before fading out
var _fade_in := 6.0
var _fade_out := 8.0
var _gain := 0.0                      # 0..1 envelope of the current piece
var _duck := 0.0                      # 0..1 current pause duck
var _duck_goal := 0.0
var _task := -1
var _loading_path := ""
var _loaded: AudioStream
var _mutex := Mutex.new()

var current_track := ""               # for tests and the audition panel
var rng := RandomNumberGenerator.new()


func setup(cfg, folder := "") -> void:
	_cfg = cfg
	process_mode = Node.PROCESS_MODE_ALWAYS   # keeps fading in the pause menu
	_player = AudioStreamPlayer.new()
	_player.bus = cfg.music_bus
	_player.volume_db = cfg.silent_db
	add_child(_player)
	rng.randomize()
	_tracks = scan(folder if not folder.is_empty() else String(cfg.music_dir))
	_wait = rng.randf_range(cfg.music_first_delay_range.x, cfg.music_first_delay_range.y)


## Track paths in the folder (exported builds list imported files, so .import / .remap suffixes are stripped).
static func scan(folder: String) -> PackedStringArray:
	var out: PackedStringArray = []
	if not DirAccess.dir_exists_absolute(folder):
		return out
	for f: String in DirAccess.get_files_at(folder):
		var name := f.trim_suffix(".remap").trim_suffix(".import")
		if name.get_extension().to_lower() in EXTENSIONS:
			var path := folder.path_join(name)
			if not out.has(path):
				out.append(path)
	out.sort()
	return out


func track_count() -> int:
	return _tracks.size()


func phase_name() -> String:
	return Phase.keys()[_phase]


func set_ducked(on: bool) -> void:
	_duck_goal = 1.0 if on else 0.0


## Starts the next piece now (audition panel / tests); in the game the director decides by itself.
func skip_wait() -> void:
	if _phase == Phase.WAIT:
		_wait = 0.0


func _exit_tree() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


func _process(dt: float) -> void:
	step(dt)


func step(dt: float) -> void:
	if _cfg == null or _tracks.is_empty():
		return
	_duck = move_toward(_duck, _duck_goal, dt / maxf(_cfg.music_duck_time_s, 0.01))
	_t += dt
	match _phase:
		Phase.WAIT:
			_wait -= dt
			if _wait <= 0.0:
				_begin_loading()
		Phase.LOADING:
			if _task >= 0 and WorkerThreadPool.is_task_completed(_task):
				WorkerThreadPool.wait_for_task_completion(_task)
				_task = -1
				_mutex.lock()
				var stream := _loaded
				_loaded = null
				_mutex.unlock()
				if stream == null:
					push_warning("Музыка: не удалось загрузить %s" % _loading_path)
					var bad := _tracks.find(_loading_path)
					if bad >= 0:
						_tracks.remove_at(bad)
					_rest()
				else:
					_start(stream)
		Phase.FADE_IN:
			_gain = _ease(_t / _fade_in)
			if _t >= _fade_in:
				_set_phase(Phase.PLAY)
		Phase.PLAY:
			_gain = 1.0
			if _t >= _play_for or not _player.playing:
				_set_phase(Phase.FADE_OUT)
		Phase.FADE_OUT:
			_gain = _ease(1.0 - _t / _fade_out)
			if _t >= _fade_out or not _player.playing:
				_player.stop()
				_gain = 0.0
				current_track = ""
				_rest()
	_apply_volume()


func _begin_loading() -> void:
	if _bag.is_empty():
		_bag = _tracks.duplicate()
		for i in range(_bag.size() - 1, 0, -1):   # Fisher–Yates
			var j := rng.randi_range(0, i)
			var tmp := _bag[i]
			_bag[i] = _bag[j]
			_bag[j] = tmp
		if _bag.size() > 1 and _bag[0] == _last:
			_bag.append(_bag[0])
			_bag.remove_at(0)
	_loading_path = _bag[0]
	_bag.remove_at(0)
	_set_phase(Phase.LOADING)
	_task = WorkerThreadPool.add_task(_load_job.bind(_loading_path), false, "music load")


func _load_job(path: String) -> void:
	var stream := load_track(path)
	_mutex.lock()
	_loaded = stream
	_mutex.unlock()


## Raw file in development (no import needed after dropping a file in), imported resource in an export.
static func load_track(path: String) -> AudioStream:
	var stream: AudioStream = null
	var ext := path.get_extension().to_lower()
	if not OS.has_feature("template") and FileAccess.file_exists(path):
		match ext:
			"mp3":
				stream = AudioStreamMP3.load_from_file(path)
			"ogg":
				stream = AudioStreamOggVorbis.load_from_file(path)
			"wav":
				stream = AudioStreamWAV.load_from_file(path)
	if stream == null and ResourceLoader.exists(path):
		stream = load(path) as AudioStream
	if stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = false
	elif stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = false
	elif stream is AudioStreamWAV:
		(stream as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_DISABLED
	return stream


func _start(stream: AudioStream) -> void:
	var length := stream.get_length()
	_fade_in = minf(_cfg.music_fade_in_s, length * 0.25)
	_fade_out = minf(_cfg.music_fade_out_s, length * 0.25)
	# долгие эмбиент-треки не доигрываются до конца: уходят плавно после music_max_play_s
	var whole := length - _fade_in - _fade_out
	_play_for = clampf(minf(whole, _cfg.music_max_play_s - _fade_in - _fade_out), 0.0, maxf(whole, 0.0))
	_player.stream = stream
	_player.volume_db = _cfg.silent_db
	_player.play()
	_last = _loading_path
	current_track = _loading_path
	_gain = 0.0
	_set_phase(Phase.FADE_IN)


func _rest() -> void:
	_wait = rng.randf_range(_cfg.music_gap_range.x, _cfg.music_gap_range.y)
	_set_phase(Phase.WAIT)


func _set_phase(p: Phase) -> void:
	_phase = p
	_t = 0.0


func _apply_volume() -> void:
	var level := _gain * db_to_linear(_cfg.music_pause_duck_db * _duck)
	var target: float = _cfg.silent_db if level <= 0.0005 else maxf(_cfg.db_music + linear_to_db(level), _cfg.silent_db)
	if absf(target - _player.volume_db) > 0.02:
		_player.volume_db = target


## Equal-power curve: no dip or bump in loudness during fades.
static func _ease(x: float) -> float:
	return sin(clampf(x, 0.0, 1.0) * PI * 0.5)
