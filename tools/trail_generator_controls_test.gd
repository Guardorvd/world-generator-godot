extends SceneTree
const Editor := preload("res://scripts/lab/trail_lab_editor.gd")
var failures := 0
var emitted := {}
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 30)
	run.call_deferred()
func check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok: failures += 1
func run() -> void:
	var editor := Editor.new()
	root.add_child(editor)
	await process_frame
	check(editor.numbers.gen_difficulty.value == 50 and editor.numbers.gen_modification.value == 50, "separate generator settings have explicit defaults")
	editor.set_generator_site(["enduro", "tech"], "tech", {difficulty = 0.35, modification = 0.8, mandatory_gaps = false, park_layout = "horseshoe"})
	check(editor.generator_style.selected == 3 and editor.generator_style.is_item_disabled(4) and not editor.generator_style.is_item_disabled(2), "site suggests supported styles and disables unsupported ones")
	check(editor.numbers.gen_difficulty.value == 35 and editor.numbers.gen_modification.value == 80 and editor.generator_layout.selected == 2, "site restores independent settings")
	editor.generator_requested.connect(func(settings: Dictionary) -> void: emitted = settings)
	for node in editor.find_children("*", "Button", true, false):
		if node.text == "Построить с этими настройками": node.pressed.emit()
	check(emitted.get("style") == "tech" and is_equal_approx(emitted.get("difficulty", 0.0), 0.35) and is_equal_approx(emitted.get("modification", 0.0), 0.8) and emitted.get("park_layout") == "horseshoe", "build action emits style, difficulty, modification and layout independently")
	editor.queue_free()
	await process_frame
	print("RESULT: %s" % ("PASS" if failures == 0 else "FAIL (%d)" % failures))
	quit(0 if failures == 0 else 1)
