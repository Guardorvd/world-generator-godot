extends Node3D
## Корпус, стекло и свет фары. Не зависит от физики велосипеда.
const LAMP_TILT := 0.09
const BEAM_LENGTH := 9.0 # длина видимого луча (м)
const BEAM_RADIUS := 2.0 # его радиус на дальнем конце (м)
var _enabled := false
var _lens_material: StandardMaterial3D
var _beam: SpotLight3D
var _beam_mesh: MeshInstance3D
var _halo: MeshInstance3D


func _ready() -> void:
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(0.12, 0.12, 0.13)
	body_mat.roughness = 0.45
	body_mat.metallic = 0.3
	# 17.11: корпус и кронштейн — один меш (одна отрисовка); фара мала и тени не отбрасывает
	var bracket_mesh := BoxMesh.new()
	bracket_mesh.size = Vector3(0.025, 0.06, 0.05)
	var body_mesh := CylinderMesh.new()
	body_mesh.top_radius = 0.034
	body_mesh.bottom_radius = 0.03
	body_mesh.height = 0.085
	body_mesh.radial_segments = 12
	body_mesh.rings = 1
	var merged := SurfaceTool.new()
	merged.begin(Mesh.PRIMITIVE_TRIANGLES)
	merged.append_from(bracket_mesh, 0, Transform3D(Basis.IDENTITY, Vector3(0.0, 0.035, 0.035)))
	merged.append_from(body_mesh, 0, Transform3D(Basis.from_euler(Vector3(-PI * 0.5, 0.0, 0.0)), Vector3.ZERO)) # ось вдоль -Z, широкий край — вперёд
	var body := MeshInstance3D.new()
	body.mesh = merged.commit()
	body.material_override = body_mat
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(body)
	# Один вариант материала для обоих состояний. Переключение меняет только параметры.
	_lens_material = StandardMaterial3D.new()
	_lens_material.emission_enabled = true
	_lens_material.emission = Color(1.0, 0.9, 0.72)
	var lens := MeshInstance3D.new()
	var lens_mesh := CylinderMesh.new()
	lens_mesh.top_radius = 0.029
	lens_mesh.bottom_radius = 0.029
	lens_mesh.height = 0.006
	lens_mesh.radial_segments = 12
	lens_mesh.rings = 1
	lens.mesh = lens_mesh
	lens.material_override = _lens_material
	lens.rotation = Vector3(-PI * 0.5, 0.0, 0.0)
	lens.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	lens.position = Vector3(0.0, 0.0, -0.044)
	add_child(lens)
	# Один конус освещает дорогу и ближнюю обочину. Рассеяние у стекла рисуется отдельно.
	_beam = SpotLight3D.new()
	_beam.name = "Beam"
	_beam.light_volumetric_fog_energy = 0.0
	_beam.light_color = Color(1.0, 0.93, 0.8)
	_beam.light_energy = 19.0
	_beam.light_specular = 0.2
	_beam.spot_range = 55.0
	_beam.spot_attenuation = 0.45
	_beam.spot_angle = 47.0
	_beam.spot_angle_attenuation = 5.0
	_beam.shadow_enabled = false
	_beam.position = Vector3(0.0, 0.0, -0.05)
	_beam.rotation = Vector3(-LAMP_TILT, 0.0, 0.0)
	add_child(_beam)

	_halo = MeshInstance3D.new()
	_halo.name = "LensHalo"
	var halo_quad := QuadMesh.new()
	halo_quad.size = Vector2(0.36, 0.36)
	var halo_mat := ShaderMaterial.new()
	halo_mat.shader = preload("res://resources/lamp_lens_halo.gdshader")
	_halo.mesh = halo_quad
	_halo.material_override = halo_mat
	_halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_halo.extra_cull_margin = 0.2 # шейдер поворачивает квад к камере
	_halo.position = Vector3(0.0, 0.0, -0.052)
	add_child(_halo)
	# Видимый луч в воздухе: мягкий конус дымки (resources/lamp_beam.gdshader)
	var cone := CylinderMesh.new()
	cone.top_radius = BEAM_RADIUS
	cone.bottom_radius = 0.03
	cone.height = BEAM_LENGTH
	cone.radial_segments = 32
	cone.rings = 4
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
	if is_instance_valid(_beam):
		_beam.visible = on
		_halo.visible = on
	if is_instance_valid(_beam_mesh):
		_beam_mesh.visible = on
	if _lens_material != null:
		_lens_material.albedo_color = Color(1.0, 0.95, 0.85) if on else Color(0.75, 0.78, 0.8)
		_lens_material.roughness = 1.0 if on else 0.1
		_lens_material.metallic = 0.0 if on else 0.6
		_lens_material.emission_energy_multiplier = 6.0 if on else 0.0


func is_enabled() -> bool:
	return _enabled
