extends Node3D
## Корпус, стекло и свет фары. Не зависит от физики велосипеда.
const LAMP_TILT := 0.045
var _enabled := false
var _lens_on: StandardMaterial3D
var _lens_off: StandardMaterial3D
var _lens: MeshInstance3D
var _lights: Array[SpotLight3D] = []


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
	# Дальний луч: узкий, далеко, медленно слабеет; мягкий край без резкой границы
	var beam := SpotLight3D.new()
	beam.name = "Beam"
	beam.light_color = Color(1.0, 0.93, 0.8)
	beam.light_energy = 14.0
	beam.light_specular = 0.25
	beam.spot_range = 60.0
	beam.spot_attenuation = 0.35
	beam.spot_angle = 16.0
	beam.spot_angle_attenuation = 1.4
	beam.shadow_enabled = false
	beam.position = Vector3(0.0, 0.0, -0.05)
	beam.rotation = Vector3(-LAMP_TILT, 0.0, 0.0)
	add_child(beam)
	_lights.append(beam)
	# Ближняя заливка: широкая и слабая, рассеивает пятно под колесом и края луча
	var flood := SpotLight3D.new()
	flood.name = "Flood"
	flood.light_color = Color(1.0, 0.9, 0.76)
	flood.light_energy = 1.6
	flood.light_specular = 0.1
	flood.spot_range = 16.0
	flood.spot_attenuation = 0.8
	flood.spot_angle = 48.0
	flood.spot_angle_attenuation = 2.2
	flood.shadow_enabled = false
	flood.position = Vector3(0.0, 0.0, -0.05)
	flood.rotation = Vector3(-0.2, 0.0, 0.0)
	add_child(flood)
	_lights.append(flood)
	set_enabled(_enabled)


func set_enabled(on: bool) -> void:
	_enabled = on
	for light in _lights:
		light.visible = on
	if is_instance_valid(_lens):
		_lens.material_override = _lens_on if on else _lens_off


func is_enabled() -> bool:
	return _enabled
