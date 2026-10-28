extends SceneTree
## Real menu/scene transition, with only the decorative menu generation disabled.
class MenuWithoutBackground extends "res://scripts/ui/main.gd":
	func _menu_background_job(_seed_text: String) -> void:
		pass

var failures := 0

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	run.call_deferred()

func check(ok: bool, message: String) -> void:
	print("trail_lab_menu: ", "PASS " if ok else "FAIL ", message)
	if not ok: failures += 1

func run() -> void:
	root.size = Vector2i(1280, 720)
	var main := preload("res://scenes/main.tscn").instantiate()
	main.set_script(MenuWithoutBackground)
	root.add_child(main)
	await process_frame
	await process_frame
	var button: Button = main.get_node("%TrailLab")
	var panel: Control = main.get_node("UI/Root/Menu/Panel")
	var viewport_rect := Rect2(Vector2.ZERO, Vector2(root.size))
	check(button.is_visible_in_tree() and not button.disabled and viewport_rect.encloses(button.get_global_rect()), "menu entry is visible and clickable")
	check(viewport_rect.encloses(panel.get_global_rect()), "menu fits at 1280x720")
	main.get_node("%InfiniteWarning").show()
	main.get_node("%WorldStatus").text = "Сохранение не читается. Можно создать мир заново; старые файлы сохранятся в архиве."
	await process_frame
	check(viewport_rect.encloses(panel.get_global_rect()), "menu fits with long warning and status")
	if "--capture" in OS.get_cmdline_user_args():
		await RenderingServer.frame_post_draw
		var out := "res://tools/control/runs/trail_lab"
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out))
		root.get_texture().get_image().save_png(out + "/menu.png")
	var seed: String = main.seed_edit.text
	button.pressed.emit()
	await process_frame
	var lab: Node = main.trail_lab
	check(lab != null and lab.heights != null and not main.screens.menu.visible and not main.screens.back.visible, "button opens working lab and hides menu")
	check(main.game == null and not main.busy and main.seed_edit.text == seed, "lab does not load or change the selected world")
	var cancel := InputEventAction.new()
	cancel.action = "ui_cancel"
	cancel.pressed = true
	lab.editor.show()
	lab._unhandled_input(cancel)
	check(not lab.editor.visible and main.trail_lab == lab, "cancel closes the editor before leaving lab")
	lab._unhandled_input(cancel)
	check(main.trail_lab == null and main.screens.menu.visible and main.screens.back.visible, "cancel returns to the same menu")
	await process_frame
	check(main.seed_edit.text == seed and main.get_node("%Start").has_focus(), "world selection and menu focus are preserved")
	button.pressed.emit()
	await process_frame
	lab = main.trail_lab
	check(lab != null and lab.heights != null, "lab can be opened again")
	# Exit while physical ragdoll exists: shutdown must restore/free all lab nodes.
	lab.bike.crash_velocity = Vector3(0, -15, -10)
	lab.controller.begin_crash(lab.view, lab.bike, lab.crash, lab.heights)
	lab.crash.tick(1.0, lab.bike, lab.heights.world, lab.heights)
	check(lab.crash.phase == BikeCrash.Phase.RAGDOLL, "ragdoll is active before leaving")
	var old_lab: WeakRef = weakref(lab)
	lab._unhandled_input(cancel)
	check(not lab.crash.active() and main.trail_lab == null, "leaving stops active ragdoll")
	lab = null
	await process_frame
	await process_frame
	check(old_lab.get_ref() == null, "lab and its simulation are released after exit")
	main.queue_free()
	await process_frame
	print("trail_lab_menu: %d failures" % failures)
	quit(1 if failures else 0)
