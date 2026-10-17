class_name EnvironmentBuilder
extends RefCounted
## Окружение сцены: небо, туман, солнце, рассеянный свет. Копия js/render3d/environment.js.

const HORIZON := Color(0.72, 0.82, 0.92)
const ZENITH := Color(0.32, 0.52, 0.82)


static func build(parent: Node3D) -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = ZENITH
	sky_mat.sky_horizon_color = HORIZON
	sky_mat.ground_horizon_color = HORIZON
	sky_mat.ground_bottom_color = Color(0.45, 0.5, 0.52)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.6
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_light_color = HORIZON
	env.fog_density = 0.0021
	env.fog_sky_affect = 0.0
	var we := WorldEnvironment.new()
	we.environment = env
	parent.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_color = Color8(0xff, 0xf2, 0xd8)
	sun.light_energy = 0.85
	parent.add_child(sun)
	# свет падает от солнца: ось -Z светильника смотрит против направления на солнце
	sun.basis = Basis.looking_at(-GameConfig.SUN_DIR.normalized(), Vector3.UP)
