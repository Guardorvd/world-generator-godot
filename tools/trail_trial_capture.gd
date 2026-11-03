extends SceneTree
func _initialize() -> void:
 root.size = Vector2i(1280, 720)
 run.call_deferred()
func run() -> void:
 var lab = load("res://scenes/trail_lab.tscn").instantiate()
 root.add_child(lab)
 await process_frame
 if not lab.open_game_example(): quit(1); return
 lab.set_physics_process(false)
 Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
 for i in 12: await process_frame
 RenderingServer.force_draw()
 await RenderingServer.frame_post_draw
 DirAccess.make_dir_recursive_absolute("res://docs/images")
 root.get_texture().get_image().save_png("res://docs/images/trial_start_2026_11_03.png")
 lab.set_overview(true)
 for i in 25: await process_frame
 RenderingServer.force_draw()
 await RenderingServer.frame_post_draw
 root.get_texture().get_image().save_png("res://docs/images/trial_overview_2026_11_03.png")
 lab.set_overview(false)
 var pilot = preload("res://scripts/lab/trail_autopilot.gd").new()
 pilot.style = "careful"
 pilot.reset(lab.routes[0], lab.heights, 0)
 lab.trial.assisted = true
 for tick in 14400:
  var control = pilot.drive(lab.bike, lab.routes[0])
  lab.step_simulation(1.0 / 60, control.throttle, control.turn, control.run, control.jump)
  if lab.trial.phase in [lab.Trial.Phase.FINISHED, lab.Trial.Phase.FAILED]: break
 for i in 12: await process_frame
 RenderingServer.force_draw()
 await RenderingServer.frame_post_draw
 root.get_texture().get_image().save_png("res://docs/images/trial_finish_2026_11_03.png")
 print("CAPTURE result: ",lab.trial.result)
 lab.shutdown()
 quit()
