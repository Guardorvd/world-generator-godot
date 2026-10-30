extends SceneTree

class LabUI extends "res://scripts/lab/trail_lab.gd":
	func rebuild(_candidate: Array[TrailDefinition], _compose_ms := -1.0, _ready := {}) -> bool:
		return true

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	run.call_deferred()

func run() -> void:
	root.size = Vector2i(1280, 720)
	var lab := LabUI.new()
	root.add_child(lab)
	lab.telemetry.text = "TRAIL LAB  /  Большой спуск"
	lab.route_hint.text = "Space прыжок  ·  ЛКМ памп  ·  Q→E хоп"
	lab.speed_label.text = "38 км/ч  "
	lab.surface_label.text = "плотный грунт"
	lab.stamina_label.text = "Выносливость  100%"
	await process_frame
	await process_frame
	var screen := Rect2(Vector2.ZERO, Vector2(root.size))
	var hud := lab.hud_panel.get_global_rect()
	var presets := lab.preset_panel.get_global_rect()
	var ok := screen.encloses(hud) and screen.encloses(presets) and not hud.intersects(presets)
	ok = ok and hud.size.x < 400 and presets.size.x < 400 and presets.size.y < 130
	ok = ok and lab.preset_select.item_count == TrailLabCatalog.LIST.size()
	lab.preset = 17
	lab._mark_preset()
	ok = ok and lab.preset_select.selected == 17 and lab.preset_label.text.contains("18 / 18")
	print("lab_layout: ", "PASS" if ok else "FAIL", " hud=", hud, " presets=", presets, " choices=", lab.preset_select.item_count)
	if "--capture" in OS.get_cmdline_user_args():
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://tools/control/runs/lab_compact.png")
	lab.diagnostics.text = ("Данные трассы и управления\n").repeat(40)
	lab.set_diagnostics_visible(true)
	await process_frame
	await process_frame
	var expanded := lab.hud_panel.get_global_rect()
	ok = ok and screen.encloses(expanded) and not expanded.intersects(lab.preset_panel.get_global_rect())
	print("lab_layout expanded: ", "PASS" if ok else "FAIL", " hud=", expanded)
	lab.queue_free()
	await process_frame
	quit(0 if ok else 1)
