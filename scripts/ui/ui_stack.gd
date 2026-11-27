extends Node
## Стек экранов меню/паузы, затемняющий слой (dimmer) и плавные переходы с поддержкой прерываний.

var force_animate_in_headless := false

var _host: Node
var _screens := {}
var _dimmer: ColorRect
var _audio: Node
var _stack: Array[Dictionary] = []
var _screen_tweens := {}
var _dimmer_tween: Tween
var _dissolve_tween: Tween
var _peek_active := false
var _peek_alpha := 0.25
var _peek_until_ms := -1


func setup(host: Node, screens: Dictionary, dimmer: ColorRect, audio: Node) -> void:
	_host = host
	_screens = screens
	_dimmer = dimmer
	_audio = audio
	if _dimmer != null:
		_dimmer.visible = false
		_dimmer.color.a = 0.0
		_dimmer.mouse_filter = Control.MOUSE_FILTER_IGNORE


func _exit_tree() -> void:
	_kill_all_tweens()


func current() -> String:
	return "" if _stack.is_empty() else str(_stack[-1].screen)


func depth() -> int:
	return _stack.size()


func is_open(screen: String) -> bool:
	return current() == screen


func tick() -> void:
	if _peek_until_ms >= 0 and Time.get_ticks_msec() >= _peek_until_ms:
		set_dimmer_peek(false)


func set_dimmer_peek(active: bool, target_alpha := 0.25) -> void:
	_peek_until_ms = -1
	if _peek_active == active and (not active or is_equal_approx(_peek_alpha, target_alpha)):
		return
	_peek_active = active
	_peek_alpha = target_alpha
	_update_dimmer(0.14 if active else 0.18, false, false)


func pulse_dimmer_peek(hold_seconds := 0.75, target_alpha := 0.25) -> void:
	_peek_active = true
	_peek_alpha = target_alpha
	_peek_until_ms = Time.get_ticks_msec() + int(hold_seconds * 1000.0)
	_update_dimmer(0.14, false, false)


func push(screen: String, opts := {}) -> void:
	_clear_peek_state()
	if current() == screen:
		return
	var prev := current()
	_stack.append({
		screen = screen,
		return_focus = opts.get("return_focus", null),
		dimmer = float(opts.get("dimmer", 0.0)),
	})
	if not prev.is_empty():
		_animate_exit(prev, opts)
	_animate_enter(screen, opts)
	_update_dimmer(float(opts.get("dimmer_duration", 0.18)), not should_animate(opts), false)
	var sound: StringName = opts.get("sound", &"")
	if sound != &"" and _audio != null:
		_audio.play(sound)


func pop(opts := {}) -> Dictionary:
	_clear_peek_state()
	if _stack.is_empty():
		return {closed = "", active = "", return_focus = null}
	var popped: Dictionary = _stack.pop_back()
	var next := current()
	var exit_opts := opts.duplicate()
	if not exit_opts.has("exit_duration"):
		exit_opts["exit_duration"] = 0.14
	if not exit_opts.has("exit_offset_y"):
		exit_opts["exit_offset_y"] = 16.0
	_animate_exit(str(popped.screen), exit_opts)
	if not next.is_empty():
		_animate_enter(next, {
			enter_duration = float(opts.get("reveal_duration", 0.16)),
			offset_y = float(opts.get("reveal_offset_y", 8.0)),
			instant = opts.get("instant", false),
		})
	var next_dimmer := _effective_dimmer_alpha()
	_update_dimmer(float(opts.get("dimmer_duration", 0.14)), not should_animate(opts), next_dimmer <= 0.0)
	var sound: StringName = opts.get("sound", &"")
	if sound != &"" and _audio != null:
		_audio.play(sound)
	return {closed = str(popped.screen), active = next, return_focus = popped.get("return_focus", null)}


func replace(screen: String, opts := {}) -> void:
	_clear_peek_state()
	var prev := current()
	_stack.clear()
	if not screen.is_empty():
		_stack.append({
			screen = screen,
			return_focus = null,
			dimmer = float(opts.get("dimmer", 0.0)),
		})
	var animate := should_animate(opts)
	for s: String in _screens:
		if s == screen:
			continue
		if s == prev and animate:
			_animate_exit(s, opts)
		else:
			_reset_hidden(s)
	if not screen.is_empty():
		_animate_enter(screen, opts)
	var next_dimmer := _effective_dimmer_alpha()
	_update_dimmer(float(opts.get("dimmer_duration", 0.14)), not animate, next_dimmer <= 0.0)
	var sound: StringName = opts.get("sound", &"")
	if sound != &"" and _audio != null:
		_audio.play(sound)


func dissolve_to_world(back_node: Control, loading_node: Control, duration: float) -> Tween:
	_clear_peek_state()
	_stack.clear()
	_update_dimmer(0.0, true, true)
	_kill_dissolve()
	for s: String in _screens:
		if s != "loading":
			_reset_hidden(s)
	_kill_screen_tween("loading")
	if not should_animate():
		_hide_world_transition_nodes(back_node, loading_node)
		return null
	if loading_node != null:
		_set_interactive(loading_node, false)
	if back_node != null:
		back_node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dissolve_tween = create_tween()
	_dissolve_tween.set_parallel(true).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	if loading_node != null and loading_node.visible:
		_dissolve_tween.tween_property(loading_node, "modulate:a", 0.0, duration)
	if back_node != null and back_node.visible:
		_dissolve_tween.tween_property(back_node, "modulate:a", 0.0, duration)
	_dissolve_tween.chain().tween_callback(func() -> void:
		_dissolve_tween = null
		_hide_world_transition_nodes(back_node, loading_node))
	return _dissolve_tween


func cancel_dissolve(back_node: Control, loading_node: Control) -> void:
	if _dissolve_tween == null:
		return
	_kill_dissolve()
	if back_node != null:
		back_node.modulate.a = 1.0
		back_node.mouse_filter = Control.MOUSE_FILTER_STOP
	if loading_node != null:
		loading_node.modulate.a = 1.0
		_set_screen_offset_y(0.0, loading_node)
		_set_interactive(loading_node, true)


func _hide_world_transition_nodes(back_node: Control, loading_node: Control) -> void:
	if loading_node != null:
		loading_node.visible = false
		loading_node.modulate.a = 1.0
		_set_screen_offset_y(0.0, loading_node)
		_set_interactive(loading_node, true)
	if back_node != null:
		back_node.visible = false
		back_node.modulate.a = 1.0
		back_node.mouse_filter = Control.MOUSE_FILTER_STOP


func should_animate(opts := {}) -> bool:
	if bool(opts.get("instant", false)) or GameContext.scope.settings.reduce_ui_motion:
		return false
	if _host == null or not _host.is_inside_tree():
		return false
	if not _host.is_processing() and not force_animate_in_headless:
		return false
	if DisplayServer.get_name() == "headless" and not force_animate_in_headless:
		return false
	return true


func _safe_offset_y(node: Control, desired: float) -> float:
	if node == null or is_zero_approx(desired):
		return 0.0
	var panel := node.get_node_or_null("Panel") as Control
	if node is CenterContainer and panel != null:
		var vp_h := node.get_viewport_rect().size.y
		var ph := maxf(panel.size.y, panel.get_combined_minimum_size().y)
		var headroom := maxf(0.0, floorf((vp_h - ph) * 0.5) - 2.0)
		return minf(desired, headroom)
	return desired


func _set_screen_offset_y(y: float, node: Control) -> void:
	if is_instance_valid(node):
		node.offset_top = y
		node.offset_bottom = y


func _set_interactive(node: Control, interactive: bool) -> void:
	if is_instance_valid(node):
		node.mouse_behavior_recursive = Control.MOUSE_BEHAVIOR_INHERITED if interactive else Control.MOUSE_BEHAVIOR_DISABLED


static func set_panel_base_scale(panel: Control, base_scale: float) -> void:
	panel.set_meta(&"_ui_base_scale", base_scale)
	var factor := float(panel.get_meta(&"_ui_scale_factor")) if panel.has_meta(&"_ui_scale_factor") else 1.0
	_set_panel_scale_factor(factor, panel)


static func _set_panel_scale_factor(factor: float, panel: Control) -> void:
	if not is_instance_valid(panel):
		return
	panel.set_meta(&"_ui_scale_factor", factor)
	panel.pivot_offset = panel.size * 0.5
	var base := float(panel.get_meta(&"_ui_base_scale")) if panel.has_meta(&"_ui_base_scale") else 1.0
	panel.scale = Vector2.ONE * base * factor


func _kill_screen_tween(screen: String) -> void:
	if _screen_tweens.has(screen):
		var tw: Variant = _screen_tweens[screen]
		if tw is Tween and (tw as Tween).is_valid():
			(tw as Tween).kill()
		_screen_tweens.erase(screen)


func _kill_dissolve() -> void:
	if _dissolve_tween != null and _dissolve_tween.is_valid():
		_dissolve_tween.kill()
	_dissolve_tween = null


func _kill_all_tweens() -> void:
	for key: Variant in _screen_tweens.keys():
		var tw: Variant = _screen_tweens[key]
		if tw is Tween and (tw as Tween).is_valid():
			(tw as Tween).kill()
	_screen_tweens.clear()
	if _dimmer_tween != null and _dimmer_tween.is_valid():
		_dimmer_tween.kill()
	_dimmer_tween = null
	_kill_dissolve()


func _reset_hidden(screen: String) -> void:
	_kill_screen_tween(screen)
	var node: Control = _screens.get(screen)
	if node == null:
		return
	node.visible = false
	node.modulate.a = 1.0
	_set_screen_offset_y(0.0, node)
	var panel := node.get_node_or_null("Panel") as Control
	if panel != null and panel.has_meta(&"_ui_base_scale"):
		_set_panel_scale_factor(1.0, panel)
	_set_interactive(node, true)


func _animate_enter(screen: String, opts: Dictionary) -> void:
	var node: Control = _screens.get(screen)
	if node == null:
		return
	_kill_screen_tween(screen)
	var was_visible := node.visible
	node.visible = true
	_set_interactive(node, true)
	if not should_animate(opts):
		node.modulate.a = 1.0
		var instant_panel := node.get_node_or_null("Panel") as Control
		if instant_panel != null and instant_panel.has_meta(&"_ui_base_scale"):
			_set_panel_scale_factor(1.0, instant_panel)
		_set_screen_offset_y(0.0, node)
		return
	var dur := float(opts.get("enter_duration", 0.20))
	var panel := node.get_node_or_null("Panel") as Control
	if panel != null and opts.has("enter_scale"):
		if not was_visible:
			_set_panel_scale_factor(float(opts.enter_scale), panel)
	var dy := _safe_offset_y(node, float(opts.get("offset_y", 16.0)))
	var start_y := node.offset_top if was_visible else dy
	if not was_visible:
		node.modulate.a = 0.0
		_set_screen_offset_y(start_y, node)
	var tw := create_tween()
	_screen_tweens[screen] = tw
	tw.set_parallel(true)
	if panel != null and opts.has("enter_scale"):
		var factor := float(panel.get_meta(&"_ui_scale_factor")) if panel.has_meta(&"_ui_scale_factor") else 1.0
		tw.tween_method(_set_panel_scale_factor.bind(panel), factor, 1.0, dur).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(node, "modulate:a", 1.0, dur).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_method(_set_screen_offset_y.bind(node), start_y, 0.0, dur).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.set_parallel(false)
	tw.tween_callback(func() -> void:
		if _screen_tweens.get(screen) == tw:
			_screen_tweens.erase(screen))


func _animate_exit(screen: String, opts: Dictionary) -> void:
	var node: Control = _screens.get(screen)
	if node == null:
		return
	_kill_screen_tween(screen)
	if not node.visible:
		node.modulate.a = 1.0
		var hidden_panel := node.get_node_or_null("Panel") as Control
		if hidden_panel != null and hidden_panel.has_meta(&"_ui_base_scale"):
			_set_panel_scale_factor(1.0, hidden_panel)
		_set_screen_offset_y(0.0, node)
		_set_interactive(node, true)
		return
	if not should_animate(opts):
		node.visible = false
		node.modulate.a = 1.0
		var instant_panel := node.get_node_or_null("Panel") as Control
		if instant_panel != null and instant_panel.has_meta(&"_ui_base_scale"):
			_set_panel_scale_factor(1.0, instant_panel)
		_set_screen_offset_y(0.0, node)
		_set_interactive(node, true)
		return
	_set_interactive(node, false)
	var dur := float(opts.get("exit_duration", 0.14))
	var panel := node.get_node_or_null("Panel") as Control
	var dy := _safe_offset_y(node, float(opts.get("exit_offset_y", 12.0)))
	var cur_a := clampf(node.modulate.a, 0.0, 1.0)
	var eff_dur := maxf(0.05, dur * cur_a)
	var tw := create_tween()
	_screen_tweens[screen] = tw
	tw.set_parallel(true)
	if panel != null and opts.has("exit_scale"):
		var factor := float(panel.get_meta(&"_ui_scale_factor")) if panel.has_meta(&"_ui_scale_factor") else 1.0
		tw.tween_method(_set_panel_scale_factor.bind(panel), factor, float(opts.exit_scale), eff_dur).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_property(node, "modulate:a", 0.0, eff_dur).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_method(_set_screen_offset_y.bind(node), node.offset_top, dy, eff_dur).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.set_parallel(false)
	tw.tween_callback(func() -> void:
		if _screen_tweens.get(screen) == tw:
			_screen_tweens.erase(screen)
		node.visible = false
		node.modulate.a = 1.0
		if panel != null and panel.has_meta(&"_ui_scale_factor"):
			_set_panel_scale_factor(1.0, panel)
		_set_screen_offset_y(0.0, node)
		_set_interactive(node, true))


func _clear_peek_state() -> void:
	_peek_active = false
	_peek_until_ms = -1


func _base_dimmer_alpha() -> float:
	return 0.0 if _stack.is_empty() else float(_stack[-1].dimmer)


func _effective_dimmer_alpha() -> float:
	var base := _base_dimmer_alpha()
	return minf(base, _peek_alpha) if _peek_active else base


func _update_dimmer(duration: float, instant := false, ease_in := false) -> void:
	if _dimmer == null:
		return
	if _dimmer_tween != null and _dimmer_tween.is_valid():
		_dimmer_tween.kill()
		_dimmer_tween = null
	var target := _effective_dimmer_alpha()
	if target > 0.0:
		_dimmer.visible = true
		_dimmer.mouse_filter = Control.MOUSE_FILTER_STOP
	else:
		_dimmer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if instant or duration <= 0.0 or not should_animate():
		_dimmer.color.a = target
		_dimmer.visible = target > 0.0
		return
	_dimmer_tween = create_tween()
	_dimmer_tween.tween_property(_dimmer, "color:a", target, duration).set_trans(
		Tween.TRANS_QUAD if ease_in else Tween.TRANS_CUBIC
	).set_ease(Tween.EASE_IN if ease_in else Tween.EASE_OUT)
	_dimmer_tween.tween_callback(func() -> void:
		_dimmer_tween = null
		if _effective_dimmer_alpha() <= 0.0:
			_dimmer.visible = false)
