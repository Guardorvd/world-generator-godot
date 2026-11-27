extends SubViewportContainer
## Изолированная сцена примерки. Профиль сюда не передаётся и не изменяется.

var _viewport: SubViewport
var _bike: BikeView
var _camera: Camera3D
var _look := 0
var _closeup := false
var _category := 0
var _freeze_pending := false

func _ready() -> void:
	stretch = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(960, 560)
	_viewport.transparent_bg = true
	_viewport.own_world_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)
	var world := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("d8e5d9")
	environment.ambient_light_energy = 0.8
	world.environment = environment
	_viewport.add_child(world)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-48, -38, 0)
	_viewport.add_child(light)
	_bike = preload("res://scenes/bike.tscn").instantiate()
	_viewport.add_child(_bike)
	_bike.idle_life = false
	var state := BikeRide.new()
	state.riding = true
	state.speed = 6.0
	state.crank = 0.9
	_bike.snap(state)
	for i in 40:
		state.crank += 5.0 / 60.0
		state.wheel += state.speed / 0.34 / 60.0
		state._step_effort(1.0, 1.0 / 60.0)
		_bike.tick(state, 1.0 / 60.0, 1.0, false)
	_bike.draw(1.0)
	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_viewport.add_child(_camera)
	_camera.make_current()
	_update_camera()

func apply_items(items: Array) -> void:
	if _bike == null or items.size() < 5:
		return
	_bike.set_scheme(items[0])
	_bike.set_tires(items[1])
	_bike.set_grips(items[2])
	_bike.set_pedals(items[3])
	_bike.set_helmet(items[4])
	_redraw()

func set_view(look: int, closeup: bool, category: int) -> void:
	_look = look
	_closeup = closeup
	_category = category
	if _camera != null:
		_update_camera()

func _update_camera() -> void:
	var target := Vector3(0, 0.9, 0)
	_camera.size = 2.1
	if _closeup:
		match _category:
			1:
				target = Vector3(0, 0.56, 0)
				_camera.size = 1.45
			2:
				target = Vector3(0, 0.97, -0.405)
				_camera.size = 0.52
			3:
				target = Vector3(0, 0.30, 0)
				_camera.size = 0.6
			4:
				var skeleton := _bike.rider.skeleton
				target = skeleton.global_transform * skeleton.get_bone_global_pose(skeleton.find_bone("Head")).origin
				_camera.size = 0.6
	_camera.position = target + (Vector3(3.2, 0.45, 0.0) if _look == 0 else Vector3(-2.8, 0.9, -2.7))
	_camera.look_at(target)
	_redraw()

func _redraw() -> void:
	if _viewport != null:
		_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		if not _freeze_pending:
			_freeze_pending = true
			RenderingServer.frame_post_draw.connect(_freeze_after_draw, CONNECT_ONE_SHOT)


func _freeze_after_draw() -> void:
	_freeze_pending = false
	if is_instance_valid(_viewport):
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
