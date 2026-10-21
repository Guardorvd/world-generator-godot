class_name DayCycle
extends RefCounted
## Смена суток (с 7.8). Одна таблица ключевых состояний KEYS (ночь, сумерки, утро, день, вечер):
## цвета неба, света, окружения и выдержка; между ключами всё плавно смешивается по часу.
## Солнце ходит по кругу (восход в 6:00, закат в 18:00, в полдень 55° над югом), луна — напротив.
## Свет в сцене один (узел Sun): днём он светит от солнца, ночью от луны, переключается у горизонта,
## где сила обоих ноль, поэтому скачка не видно. Небо рисует resources/sky.gdshader, туман берёт цвет горизонта.
## С 7.9 сутки задают и атмосферу земли: густоту тумана и рассеяние света в нём, насыщенность, плотность теней,
## а облака отбрасывают на землю бегущие тени (resources/cloud_shadow.gdshaderinc, общий параметр cloud_shadow).

const SKY_SHADER := preload("res://resources/sky.gdshader")
const TILT := deg_to_rad(35.0)   # наклон пути солнца к югу: высота в полдень 90° − 35° = 55°
const DUSK := 0.08               # свет солнца и луны нарастает от горизонта до этой высоты (синус угла)
const MOON_COLOR := Color(0.62, 0.72, 1.0)
const MOON_ENERGY := 0.32        # лунный свет ночью; в сумерках слабее (доля «ночи» в таблице)
const FOG := 0.0021              # дневная густота тумана, как в game_world.tscn (окружение общее для всех миров)
const CLOUD_SHADOW := 0.45      # насколько тень облака темнит землю днём
const CLOUD_WIND := Vector2(-8.0, -2.7)  # м/с: тени облаков бегут туда же, куда облака на небе

## час, зенит, горизонт (= туман), цвет и сила солнца, цвет и сила окружения, выдержка, гало солнца, ночь (звёзды),
## цвет облаков; с 7.9 ещё покрытие неба кучевыми облаками, множитель тумана (утренняя дымка), насыщенность
## красок мира и плотность теней (при низком солнце и ночью тени мягче, днём глубже).
## Последний ключ повторяет первый через сутки.
const KEYS := [
	[0.0, Color(0.05, 0.08, 0.19), Color(0.13, 0.18, 0.31), Color(0.62, 0.72, 1.0), 0.32, Color(0.36, 0.46, 0.78), 0.62, 1.3, 0.0, 1.0, Color(0.17, 0.21, 0.32), 0.28, 1.0, 0.85, 0.55],
	[4.5, Color(0.07, 0.1, 0.23), Color(0.2, 0.22, 0.36), Color(0.62, 0.72, 1.0), 0.28, Color(0.38, 0.46, 0.76), 0.6, 1.3, 0.2, 0.9, Color(0.22, 0.24, 0.36), 0.28, 1.2, 0.9, 0.55],
	[5.6, Color(0.17, 0.23, 0.42), Color(0.62, 0.48, 0.5), Color(1.0, 0.62, 0.42), 0.6, Color(0.52, 0.52, 0.72), 0.5, 1.15, 0.9, 0.35, Color(0.7, 0.5, 0.52), 0.22, 1.5, 1.0, 0.7],
	[7.5, Color(0.3, 0.47, 0.76), Color(0.78, 0.7, 0.64), Color(1.0, 0.78, 0.58), 1.15, Color(0.64, 0.67, 0.82), 0.48, 1.0, 0.8, 0.0, Color(1.0, 0.88, 0.78), 0.24, 1.25, 1.12, 0.8],
	[10.5, Color(0.32, 0.52, 0.82), Color(0.62, 0.74, 0.88), Color(1.0, 0.93, 0.8), 1.5, Color(0.62, 0.72, 0.9), 0.5, 0.92, 0.3, 0.0, Color(1.0, 1.0, 1.0), 0.28, 1.0, 1.1, 0.95],
	[15.0, Color(0.32, 0.52, 0.82), Color(0.62, 0.74, 0.88), Color(1.0, 0.93, 0.8), 1.5, Color(0.62, 0.72, 0.9), 0.5, 0.92, 0.3, 0.0, Color(1.0, 1.0, 1.0), 0.36, 1.0, 1.1, 0.95],
	[17.3, Color(0.3, 0.42, 0.7), Color(0.96, 0.68, 0.45), Color(1.0, 0.64, 0.38), 1.25, Color(0.7, 0.63, 0.72), 0.48, 1.0, 1.0, 0.0, Color(1.0, 0.76, 0.6), 0.32, 1.1, 1.25, 0.9],
	[18.6, Color(0.16, 0.19, 0.38), Color(0.66, 0.42, 0.42), Color(1.0, 0.55, 0.4), 0.6, Color(0.52, 0.5, 0.7), 0.5, 1.15, 0.9, 0.3, Color(0.6, 0.4, 0.45), 0.28, 1.2, 1.1, 0.7],
	[20.0, Color(0.07, 0.1, 0.23), Color(0.2, 0.22, 0.36), Color(0.62, 0.72, 1.0), 0.28, Color(0.38, 0.46, 0.76), 0.6, 1.3, 0.2, 0.9, Color(0.22, 0.24, 0.36), 0.26, 1.1, 0.9, 0.55],
	[24.0, Color(0.05, 0.08, 0.19), Color(0.13, 0.18, 0.31), Color(0.62, 0.72, 1.0), 0.32, Color(0.36, 0.46, 0.78), 0.62, 1.3, 0.0, 1.0, Color(0.17, 0.21, 0.32), 0.28, 1.0, 0.85, 0.55],
]

var env: Environment
var light: DirectionalLight3D
var sky_mat: ShaderMaterial
var terrain_mats: Array = []   # материалы рельефа: солнечные пятна под пологом гаснут вместе с солнцем
var sunlight := 1.0            # 0..1: насколько сейчас светит именно солнце


func _init(environment: Environment, sun: DirectionalLight3D) -> void:
	env = environment
	light = sun
	sky_mat = ShaderMaterial.new()
	sky_mat.shader = SKY_SHADER
	var sky := Sky.new()
	sky.sky_material = sky_mat
	# цвета меняются каждый кадр: карта отражений обновляется по частям, маленькая
	sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
	sky.radiance_size = Sky.RADIANCE_SIZE_64
	env.sky = sky


## Направление на солнце в час hour (0..24)
static func sun_direction(hour: float) -> Vector3:
	var a := (hour - 6.0) / 24.0 * TAU
	var east := Vector3(1.0, 0.0, 0.0)
	var arc := Vector3(0.0, cos(TILT), sin(TILT))   # вверх и к югу (юг — +z)
	return (east * cos(a) + arc * sin(a)).normalized()


## Часы:минуты для подсказок, «07:30»
static func clock(hour: float) -> String:
	var m := int(fposmod(hour, 24.0) * 60.0)
	return "%02d:%02d" % [m / 60, m % 60]


## Ключевое состояние в час hour: смесь двух соседних ключей
static func state(hour: float) -> Array:
	hour = fposmod(hour, 24.0)
	var i := 0
	while i < KEYS.size() - 2 and KEYS[i + 1][0] <= hour:
		i += 1
	var a: Array = KEYS[i]
	var b: Array = KEYS[i + 1]
	var t := smoothstep(0.0, 1.0, (hour - a[0]) / (b[0] - a[0]))
	var out := []
	for k: int in a.size():
		var va: Variant = a[k]
		var vb: Variant = b[k]
		out.append(lerp(va, vb, t))
	return out


## Поставить небо, свет и туман на час hour; time — секунды игры, по ним плывут облака
func apply(hour: float, time: float) -> void:
	var s := state(hour)
	var sun := sun_direction(hour)
	var moon := -sun
	var src := sun if sun.y > 0.0 else moon
	sunlight = smoothstep(0.0, DUSK, sun.y)
	var fade := smoothstep(0.0, DUSK, src.y)
	light.light_color = s[3] if sun.y > 0.0 else MOON_COLOR
	light.light_energy = (s[4] if sun.y > 0.0 else MOON_ENERGY * s[9]) * fade
	light.visible = fade > 0.001
	if light.visible:
		# свет летит от светила к земле: -Z узла смотрит туда же
		light.basis = Basis.looking_at(-src, Vector3.UP if absf(src.y) < 0.99 else Vector3.FORWARD)
	env.fog_light_color = s[2]
	env.ambient_light_color = s[5]
	env.ambient_light_energy = s[6]
	env.tonemap_exposure = s[7]
	env.fog_density = FOG * s[12]
	env.fog_sun_scatter = 0.08 + s[8] * 0.25   # низкое солнце светит сквозь дымку
	env.adjustment_saturation = s[13]
	light.shadow_opacity = s[14]
	# низкое солнце ложится на склоны вскользь: больше смещение, чтобы тени не рябили
	light.shadow_normal_bias = lerpf(2.2, 1.2, smoothstep(0.1, 0.45, src.y))
	# облачность медленно меняется сама: то ясно, то гряда облаков (период около 7 минут)
	var cover: float = s[11] + 0.12 * sin(time / 67.0) + 0.06 * sin(time / 23.0 + 1.0)
	RenderingServer.global_shader_parameter_set("cloud_shadow",
		Vector4(CLOUD_WIND.x * time, CLOUD_WIND.y * time, CLOUD_SHADOW * sunlight, cover))
	sky_mat.set_shader_parameter("zenith_color", s[1])
	sky_mat.set_shader_parameter("horizon_color", s[2])
	sky_mat.set_shader_parameter("sun_dir", sun)
	sky_mat.set_shader_parameter("sun_color", s[3])
	sky_mat.set_shader_parameter("halo", s[8])
	sky_mat.set_shader_parameter("moon_dir", moon)
	sky_mat.set_shader_parameter("night", s[9])
	sky_mat.set_shader_parameter("cloud_color", s[10])
	sky_mat.set_shader_parameter("cloud_time", time)
	sky_mat.set_shader_parameter("cloud_cover", cover)
	for m: ShaderMaterial in terrain_mats:
		m.set_shader_parameter("sunlight", sunlight)
