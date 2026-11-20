extends Node
## Тактильные звуки интерфейса и микро-отклик элементов управления (без зависимостей от игровых скриптов).

const POOL_SIZE := 4
const HOVER_COOLDOWN_MS := 35
const SOUNDS := {
	&"hover": {path = "res://resources/sounds/ui_hover.wav", db = -22.0},
	&"click": {path = "res://resources/sounds/ui_click.wav", db = -14.0},
	&"carousel_step": {path = "res://resources/sounds/ui_carousel_step.wav", db = -15.0},
	&"panel_open": {path = "res://resources/sounds/ui_panel_open.wav", db = -16.0},
	&"panel_close": {path = "res://resources/sounds/ui_panel_close.wav", db = -18.0},
	&"confirm": {path = "res://resources/sounds/ui_confirm.wav", db = -12.0},
	&"error_deny": {path = "res://resources/sounds/ui_error_deny.wav", db = -12.0},
	&"volume_tick": {path = "res://resources/sounds/ui_volume_tick.wav", db = -10.0},
	&"reticle_target_lock": {path = "res://resources/sounds/ui_hover.wav", db = -22.0},
	&"photo_focus_lock": {path = "res://resources/sounds/ui_volume_tick.wav", db = -18.0},
	&"repair_work": {path = "res://resources/sounds/step_wood_1.wav", db = -19.0},
	&"repair_reset": {path = "res://resources/sounds/ui_panel_close.wav", db = -16.0},
	&"repair_done": {path = "res://resources/sounds/step_wood_3.wav", db = -8.0},
	# 20.11: тихие отклики путешествия (тосты HUD) и тумблер фары
	&"discovery_chime": {path = "res://resources/sounds/discovery_chime.wav", db = -19.0},
	&"quest_complete": {path = "res://resources/sounds/quest_complete.wav", db = -16.0},
	&"lamp_switch": {path = "res://resources/sounds/lamp_switch.wav", db = -17.0},
	&"glass_clink": {path = "res://resources/sounds/glass_clink.wav", db = -15.0},
}

var suppress_focus_sound := false
var last_sound: StringName = &""
var play_counts := {}

var _players: Array[AudioStreamPlayer] = []
var _cursor := 0
var _streams := {}
var _last_hover_ms := -1000


func _ready() -> void:
	# 20.11: все звуки — сразу при создании (это загрузка экрана или меню): первый звон груза, тумблер фары или
	# отклик открытия в игре не читают файл с диска посреди кадра. Файлы короткие, повторная загрузка — из кэша.
	for kind: StringName in SOUNDS:
		_stream_for(SOUNDS[kind].path)
	for i in POOL_SIZE:
		var player := AudioStreamPlayer.new()
		player.bus = &"Master"
		add_child(player)
		_players.append(player)


func play(kind: StringName, pitch := 1.0) -> void:
	if not SOUNDS.has(kind):
		return
	var now := Time.get_ticks_msec()
	if kind == &"hover":
		if now - _last_hover_ms < HOVER_COOLDOWN_MS:
			return
		_last_hover_ms = now
	last_sound = kind
	play_counts[kind] = int(play_counts.get(kind, 0)) + 1
	if DisplayServer.get_name() == "headless" or AudioServer.get_driver_name() == "Dummy":
		return
	var spec: Dictionary = SOUNDS[kind]
	var stream := _stream_for(spec.path)
	if stream == null or _players.is_empty():
		return
	var player := _next_player()
	player.stream = stream
	player.volume_db = float(spec.db)
	player.pitch_scale = pitch
	player.play()


func bind_tree(root: Node) -> void:
	if root == null:
		return
	if root is Control:
		bind_control(root as Control)
	for child: Node in root.get_children():
		bind_tree(child)


func bind_control(control: Control) -> void:
	if control == null or control.has_meta(&"_ui_audio_bound"):
		return
	control.set_meta(&"_ui_audio_bound", true)
	if control is BaseButton:
		var btn := control as BaseButton
		btn.mouse_entered.connect(func() -> void:
			if not btn.disabled:
				play(&"hover"))
		btn.focus_entered.connect(func() -> void:
			if not btn.disabled and not suppress_focus_sound:
				play(&"hover"))
		btn.pressed.connect(func() -> void:
			if not btn.has_meta(&"ui_sound_custom"):
				play(&"click"))
	elif control is HSlider:
		var slider := control as HSlider
		slider.focus_entered.connect(func() -> void:
			if slider.editable and not suppress_focus_sound:
				play(&"hover"))
	elif control is TabContainer:
		var tabs := control as TabContainer
		tabs.tab_changed.connect(func(_idx: int) -> void:
			if not suppress_focus_sound:
				play(&"carousel_step"))


static func shake(control: Control, amplitude := 4.0) -> void:
	if not is_instance_valid(control) or not control.is_inside_tree():
		return
	var old_tween: Variant = control.get_meta(&"_shake_tween") if control.has_meta(&"_shake_tween") else null
	if old_tween is Tween and (old_tween as Tween).is_valid():
		(old_tween as Tween).kill()
	if not control.has_meta(&"_shake_base_x"):
		control.set_meta(&"_shake_base_x", control.position.x)
	var base_x := float(control.get_meta(&"_shake_base_x"))
	control.position.x = base_x
	if DisplayServer.get_name() == "headless":
		control.remove_meta(&"_shake_base_x")
		return
	var tween := control.create_tween()
	control.set_meta(&"_shake_tween", tween)
	tween_shake(tween, func(offset: float) -> void: control.position.x = base_x + offset, amplitude)
	tween.tween_callback(func() -> void:
		if is_instance_valid(control):
			control.remove_meta(&"_shake_base_x")
			control.remove_meta(&"_shake_tween"))


## Один рисунок тряски для Control и подсказок, которые рисуются вручную.
static func tween_shake(tween: Tween, apply: Callable, amplitude: float) -> void:
	tween.tween_method(apply, 0.0, amplitude, 0.03).set_trans(Tween.TRANS_SINE)
	tween.tween_method(apply, amplitude, -amplitude, 0.04).set_trans(Tween.TRANS_SINE)
	tween.tween_method(apply, -amplitude, amplitude * 0.75, 0.04).set_trans(Tween.TRANS_SINE)
	tween.tween_method(apply, amplitude * 0.75, -amplitude * 0.5, 0.035).set_trans(Tween.TRANS_SINE)
	tween.tween_method(apply, -amplitude * 0.5, 0.0, 0.035).set_trans(Tween.TRANS_SINE)


static func pulse_confirm(button: Control) -> void:
	if not is_instance_valid(button) or not button.is_inside_tree():
		return
	if DisplayServer.get_name() == "headless":
		return
	var old_tween: Variant = button.get_meta(&"_pulse_tween") if button.has_meta(&"_pulse_tween") else null
	if old_tween is Tween and (old_tween as Tween).is_valid():
		(old_tween as Tween).kill()
	button.pivot_offset = button.size * 0.5
	button.scale = Vector2(0.96, 0.96)
	button.self_modulate = Color(1.22, 1.18, 1.05, 1.0)
	var tween := button.create_tween()
	button.set_meta(&"_pulse_tween", tween)
	tween.set_parallel(true)
	tween.tween_property(button, "scale", Vector2.ONE, 0.14).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(button, "self_modulate", Color.WHITE, 0.14).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.set_parallel(false)
	tween.tween_callback(func() -> void:
		if is_instance_valid(button):
			button.remove_meta(&"_pulse_tween"))


func _stream_for(path: String) -> AudioStream:
	if _streams.has(path):
		return _streams[path]
	var stream: AudioStream = load(path) if ResourceLoader.exists(path) else null
	_streams[path] = stream
	return stream


func _next_player() -> AudioStreamPlayer:
	for player: AudioStreamPlayer in _players:
		if not player.playing:
			return player
	var chosen := _players[_cursor % _players.size()]
	_cursor = (_cursor + 1) % _players.size()
	return chosen
