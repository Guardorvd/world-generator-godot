extends RefCounted
## Штатные Window/Viewport: монитор не переключает видеорежим, UI масштабируется отдельно от 3D.
const BASE := Vector2i(1280, 720)
const MIN_WINDOW := Vector2i(640, 360)
const PRESETS := [Vector2i(800, 600), Vector2i(1024, 768), Vector2i(1280, 720),
	Vector2i(1280, 800), Vector2i(1366, 768), Vector2i(1600, 900), Vector2i(1920, 1080),
	Vector2i(1920, 1200), Vector2i(2560, 1080), Vector2i(2560, 1440), Vector2i(3440, 1440), Vector2i(3840, 2160)]

static func valid_resolution(value: Variant) -> bool:
	return value is Vector2i and (value == Vector2i.ZERO or
		(value.x >= MIN_WINDOW.x and value.y >= MIN_WINDOW.y and value.x <= 16384 and value.y <= 16384))

static func fit_window(requested: Vector2i, usable: Vector2i) -> Vector2i:
	var target := BASE if requested == Vector2i.ZERO else requested
	var available := Vector2i(maxi(1, usable.x - 32), maxi(1, usable.y - 64))
	var factor := minf(1.0, minf(float(available.x) / target.x, float(available.y) / target.y))
	return Vector2i(maxi(1, floori(target.x * factor)), maxi(1, floori(target.y * factor)))

static func resolutions(screen_size: Vector2i, saved: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = [Vector2i.ZERO]
	for size: Vector2i in PRESETS:
		if size.x <= screen_size.x and size.y <= screen_size.y:
			out.append(size)
	for size: Vector2i in [screen_size, saved]:
		if valid_resolution(size) and not size in out:
			out.append(size)
	return out

static func render_factor(state: Dictionary, actual: Vector2i) -> float:
	var factor: float = state.render_scale
	var resolution: Vector2i = state.resolution
	if state.fullscreen and resolution != Vector2i.ZERO and actual.x > 0 and actual.y > 0:
		factor *= minf(1.0, minf(float(resolution.x) / actual.x, float(resolution.y) / actual.y))
	return clampf(factor, 0.1, 1.0)

static func usable_rect(window: Window) -> Rect2i:
	var rect := DisplayServer.screen_get_usable_rect(window.current_screen)
	return rect if rect.has_area() else Rect2i(Vector2i.ZERO, BASE)

static func apply(window: Window, state: Dictionary) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var usable := usable_rect(window)
	window.min_size = Vector2i(mini(MIN_WINDOW.x, maxi(1, usable.size.x - 32)),
		mini(MIN_WINDOW.y, maxi(1, usable.size.y - 64)))
	if state.fullscreen:
		window.mode = Window.MODE_FULLSCREEN
	else:
		window.mode = Window.MODE_WINDOWED
		window.borderless = false
		window.size = fit_window(state.resolution, usable.size)
		window.position = usable.position + (usable.size - window.size) / 2
	apply_quality(window, state)

static func apply_quality(window: Window, state: Dictionary) -> void:
	if window.scaling_3d_mode != Viewport.SCALING_3D_MODE_BILINEAR:
		window.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	var factor := render_factor(state, window.size)
	if not is_equal_approx(window.scaling_3d_scale, factor):
		window.scaling_3d_scale = factor
	if window.msaa_3d != state.msaa:
		window.msaa_3d = state.msaa
	if DisplayServer.get_name() != "headless":
		var desired := DisplayServer.VSYNC_ENABLED if state.vsync else DisplayServer.VSYNC_DISABLED
		if DisplayServer.window_get_vsync_mode() != desired:
			DisplayServer.window_set_vsync_mode(desired)
