extends Node3D
## Корпус, стекло и свет фары. Не зависит от физики велосипеда.
const LAMP_TILT := 0.045
const BEAM_LENGTH := 9.0 # длина видимого луча (м)
const BEAM_RADIUS := 2.0 # его радиус на дальнем конце (м)
var _enabled := false
var _lens_on: StandardMaterial3D
var _lens_off: StandardMaterial3D
var _lens: MeshInstance3D
var _lights: Array[Light3D] = []
var _beam_mesh: MeshInstance3D


func _ready() -> void:
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(0.12, 0.12, 0.13)
	body_mat.roughness = 0.45
	body_mat.metallic = 0.3
	var bracket := MeshInstance3D.new()
	var bracket_mesh := BoxMesh.new()
	bracket_mesh.size = Vector3(0.025, 0.06, 0.05)
	bracket.mesh = bracket_mesh
	bracket.material_override = body_mat
	bracket.position = Vector3(0.0, 0.035, 0.035)
	add_child(bracket)
	var body := MeshInstance3D.new()
	var body_mesh := CylinderMesh.new()
	body_mesh.top_radius = 0.034
	body_mesh.bottom_radius = 0.03
	body_mesh.height = 0.085
	body_mesh.radial_segments = 12
	body_mesh.rings = 1
	body.mesh = body_mesh
	body.material_override = body_mat
	body.rotation = Vector3(-PI * 0.5, 0.0, 0.0) # ось цилиндра вдоль -Z, широкий край — вперёд
	add_child(body)
	_lens_off = StandardMaterial3D.new()
	_lens_off.albedo_color = Color(0.75, 0.78, 0.8)
	_lens_off.roughness = 0.1
	_lens_off.metallic = 0.6
	_lens_on = StandardMaterial3D.new()
	_lens_on.albedo_color = Color(1.0, 0.95, 0.85)
	_lens_on.emission_enabled = true
	_lens_on.emission = Color(1.0, 0.9, 0.72)
	_lens_on.emission_energy_multiplier = 6.0
	_lens = MeshInstance3D.new()
	var lens_mesh := CylinderMesh.new()
	lens_mesh.top_radius = 0.029
	lens_mesh.bottom_radius = 0.029
	lens_mesh.height = 0.006
	lens_mesh.radial_segments = 12
	lens_mesh.rings = 1
	_lens.mesh = lens_mesh
	_lens.material_override = _lens_off
	_lens.rotation = Vector3(-PI * 0.5, 0.0, 0.0)
	_lens.position = Vector3(0.0, 0.0, -0.044)
	add_child(_lens)
	# 12.4: свет рассеянный, без чётких краёв: большое spot_angle_attenuation (4) — яркость плавно падает
	# от середины пятна и у края конуса уже почти нулевая, граница не видна. Конусы шире, чтобы пятно не сжалось
	var beam := SpotLight3D.new()
	beam.name = "Beam"
	beam.light_color = Color(1.0, 0.93, 0.8)
	beam.light_energy = 18.0
	beam.light_specular = 0.2
	beam.spot_range = 55.0
	beam.spot_attenuation = 0.45
	beam.spot_angle = 40.0
	beam.spot_angle_attenuation = 4.0
	beam.shadow_enabled = false
	beam.position = Vector3(0.0, 0.0, -0.05)
	beam.rotation = Vector3(-LAMP_TILT, 0.0, 0.0)
	add_child(beam)
	_lights.append(beam)
	# Ближняя заливка: рассеивает пятно под колесом и переход к темноте по бокам
	var flood := SpotLight3D.new()
	flood.name = "Flood"
	flood.light_color = Color(1.0, 0.9, 0.76)
	flood.light_energy = 2.6
	flood.light_specular = 0.08
	flood.spot_range = 18.0
	flood.spot_attenuation = 0.9
	flood.spot_angle = 75.0
	flood.spot_angle_attenuation = 4.0
	flood.shadow_enabled = false
	flood.position = Vector3(0.0, 0.0, -0.05)
	flood.rotation = Vector3(-0.22, 0.0, 0.0)
	add_child(flood)
	_lights.append(flood)
	# Ореол вокруг фары: слабый свет на руль, колесо и землю рядом — свет не только впереди
	var halo := OmniLight3D.new()
	halo.name = "Halo"
	halo.light_color = Color(1.0, 0.9, 0.76)
	halo.light_energy = 0.35
	halo.light_specular = 0.0
	halo.omni_range = 3.0
	halo.omni_attenuation = 1.6
	halo.shadow_enabled = false
	halo.position = Vector3(0.0, 0.0, -0.12)
	add_child(halo)
	_lights.append(halo)
	# Видимый луч в воздухе: мягкий конус дымки (resources/lamp_beam.gdshader)
	var cone := CylinderMesh.new()
	cone.top_radius = BEAM_RADIUS
	cone.bottom_radius = 0.03
	cone.height = BEAM_LENGTH
	cone.radial_segments = 16
	cone.rings = 1
	cone.cap_top = false
	cone.cap_bottom = false
	var haze := ShaderMaterial.new()
	haze.shader = preload("res://resources/lamp_beam.gdshader")
	haze.set_shader_parameter("length_m", BEAM_LENGTH)
	_beam_mesh = MeshInstance3D.new()
	_beam_mesh.name = "BeamHaze"
	_beam_mesh.mesh = cone
	_beam_mesh.material_override = haze
	_beam_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# ось цилиндра +Y (широкий край) — вперёд по -Z, узкий край у стекла
	_beam_mesh.rotation = Vector3(-PI * 0.5 - LAMP_TILT, 0.0, 0.0)
	_beam_mesh.position = Vector3(0.0, -sin(LAMP_TILT) * BEAM_LENGTH * 0.5, -0.05 - BEAM_LENGTH * 0.5)
	add_child(_beam_mesh)
	set_enabled(_enabled)


func set_enabled(on: bool) -> void:
	_enabled = on
	for light in _lights:
		light.visible = on
	if is_instance_valid(_beam_mesh):
		_beam_mesh.visible = on
	if is_instance_valid(_lens):
		_lens.material_override = _lens_on if on else _lens_off


func is_enabled() -> bool:
	return _enabled
