class_name DayCycle
extends RefCounted
## Смена суток (с 7.8). Одна таблица ключевых состояний KEYS (ночь, сумерки, утро, день, вечер):
## цвета неба, света, окружения и выдержка; между ключами всё плавно смешивается по часу.
## Солнце ходит по кругу (восход в 6:00, закат в 18:00, в полдень 55° над югом), луна — напротив.
## Свет в сцене один (узел Sun): днём он светит от солнца, ночью от луны, переключается у горизонта,
## где сила обоих ноль, поэтому скачка не видно. Небо рисует resources/sky.gdshader, туман берёт цвет горизонта.
## С 7.9 сутки задают и атмосферу земли: густоту тумана и рассеяние света в нём, насыщенность, плотность теней,
## а облака отбрасывают на землю бегущие тени (resources/cloud_shadow.gdshaderinc, общий параметр cloud_shadow).
## С 8.3: дымка в низинах (высотный туман Godot ниже камеры, столбец mist), звёздное небо вращается с часом,
## луна меняет фазу от ночи к ночи, а редкие явления (сияние, комета, звездопад) каждую ночь выбираются по сиду мира.

const SKY_SHADER := preload("res://resources/sky.gdshader")
const TILT := deg_to_rad(35.0)   # наклон пути солнца к югу: высота в полдень 90° − 35° = 55°
const DUSK := 0.08               # свет солнца и луны нарастает от горизонта до этой высоты (синус угла)
const SHADOW_NORMAL_LOW := 1.2   # не увеличиваем normal bias при закате: тень сохраняет контакт
const SHADOW_NORMAL_HIGH := 1.2
const MOON_COLOR := Color(0.62, 0.72, 1.0)
const MOON_ENERGY := 0.32        # лунный свет ночью; в сумерках слабее (доля «ночи» в таблице)
const FOG := 0.0021              # дневная густота тумана, как в game_world.tscn (окружение общее для всех миров)
const CLOUD_SHADOW := 0.45      # насколько тень облака темнит землю днём
const CLOUD_WIND := Vector2(-8.0, -2.7)  # м/с: тени облаков бегут туда же, куда облака на небе
const MIST_TOP := 45.0           # дымка лежит ниже этой высоты, м (суша до 260 м)
const MIST_BELOW_EYE := 10.0     # и ниже камеры на столько: вблизи вокруг игрока земля чистая
const MIST_DENSITY := 0.014      # высотная густота при mist = 1: на 40 м ниже границы дымка закрывает около 40 %
const POLE := Vector3(0.0, 0.5736, -0.8192)   # ось вращения звёзд: 35° над севером, как в sky.gdshader
const MOON_DAYS := 8.0           # ночей от полнолуния до полнолуния
## Вероятности редких явлений на одну ночь
const AURORA_CHANCE := 0.16
const COMET_CHANCE := 0.07
const SHOWER_CHANCE := 0.15
const METEOR_SPORADIC := 0.05    # доля слотов по 2,5 с с метеором в обычную ночь (около одного в минуту)
const METEOR_SHOWER := 0.35

## час, зенит, горизонт (= туман), цвет и сила солнца, цвет и сила окружения, выдержка, гало солнца, ночь (звёзды),
## цвет облаков; с 7.9 ещё покрытие неба кучевыми облаками, множитель тумана (утренняя дымка), насыщенность
## красок мира и плотность теней (при низком солнце и ночью тени мягче, днём глубже); с 8.3 — дымка в низинах.
## Последний ключ повторяет первый через сутки.
const KEYS := [
	[0.0, Color(0.05, 0.08, 0.19), Color(0.13, 0.18, 0.31), Color(0.62, 0.72, 1.0), 0.32, Color(0.36, 0.46, 0.78), 0.62, 1.3, 0.0, 1.0, Color(0.17, 0.21, 0.32), 0.28, 1.0, 0.85, 0.55, 0.5],
	[4.5, Color(0.07, 0.1, 0.23), Color(0.2, 0.22, 0.36), Color(0.62, 0.72, 1.0), 0.28, Color(0.38, 0.46, 0.76), 0.6, 1.3, 0.2, 0.9, Color(0.22, 0.24, 0.36), 0.28, 1.2, 0.9, 0.55, 0.7],
	[5.6, Color(0.17, 0.23, 0.42), Color(0.62, 0.48, 0.5), Color(1.0, 0.62, 0.42), 0.6, Color(0.52, 0.52, 0.72), 0.5, 1.15, 0.9, 0.35, Color(0.7, 0.5, 0.52), 0.22, 1.5, 1.0, 0.7, 1.0],
	[7.5, Color(0.3, 0.47, 0.76), Color(0.78, 0.7, 0.64), Color(1.0, 0.78, 0.58), 1.15, Color(0.64, 0.67, 0.82), 0.48, 1.0, 0.8, 0.0, Color(1.0, 0.88, 0.78), 0.24, 1.25, 1.12, 0.8, 0.8],
	[10.5, Color(0.32, 0.52, 0.82), Color(0.62, 0.74, 0.88), Color(1.0, 0.93, 0.8), 1.5, Color(0.62, 0.72, 0.9), 0.5, 0.92, 0.3, 0.0, Color(1.0, 1.0, 1.0), 0.28, 1.0, 1.1, 0.95, 0.0],
	[15.0, Color(0.32, 0.52, 0.82), Color(0.62, 0.74, 0.88), Color(1.0, 0.93, 0.8), 1.5, Color(0.62, 0.72, 0.9), 0.5, 0.92, 0.3, 0.0, Color(1.0, 1.0, 1.0), 0.36, 1.0, 1.1, 0.95, 0.0],
	[17.3, Color(0.3, 0.42, 0.7), Color(0.96, 0.68, 0.45), Color(1.0, 0.64, 0.38), 1.25, Color(0.7, 0.63, 0.72), 0.48, 1.0, 1.0, 0.0, Color(1.0, 0.76, 0.6), 0.32, 1.1, 1.25, 0.9, 0.1],
	[18.6, Color(0.16, 0.19, 0.38), Color(0.66, 0.42, 0.42), Color(1.0, 0.55, 0.4), 0.6, Color(0.52, 0.5, 0.7), 0.5, 1.15, 0.9, 0.3, Color(0.6, 0.4, 0.45), 0.28, 1.2, 1.1, 0.7, 0.35],
	[20.0, Color(0.07, 0.1, 0.23), Color(0.2, 0.22, 0.36), Color(0.62, 0.72, 1.0), 0.28, Color(0.38, 0.46, 0.76), 0.6, 1.3, 0.2, 0.9, Color(0.22, 0.24, 0.36), 0.26, 1.1, 0.9, 0.55, 0.45],
	[24.0, Color(0.05, 0.08, 0.19), Color(0.13, 0.18, 0.31), Color(0.62, 0.72, 1.0), 0.32, Color(0.36, 0.46, 0.78), 0.62, 1.3, 0.0, 1.0, Color(0.17, 0.21, 0.32), 0.28, 1.0, 0.85, 0.55, 0.5],
]

var env: Environment
var light: DirectionalLight3D
var sky_mat: ShaderMaterial
var terrain_mats: Array = []   # материалы рельефа: солнечные пятна под пологом гаснут вместе с солнцем
var sunlight := 1.0            # 0..1: насколько сейчас светит именно солнце
var camera: Camera3D           # дымка в низинах ложится ниже камеры
var world_seed := 0            # сид мира: какие ночи с сиянием, кометой, звездопадом
var events := {}               # явления текущей ночи (см. _night_events); можно подменить для снимков
var _clock := NAN              # часы без сброса в полночь: по ним вращаются звёзды и считаются ночи
var _night := 0x7fffffff


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


## Явления ночи n (ночь n начинается вечером дня n): одинаковые для того же мира
func _night_events(n: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([world_seed, n, "sky"])
	var e := {aurora = 0.0, aurora_seed = rng.randf(), comet = 0.0, meteor = METEOR_SPORADIC,
		comet_dir = Vector3.UP, comet_tail = Vector3.RIGHT, phase = fposmod(0.5 + n / MOON_DAYS, 1.0)}
	if rng.randf() < AURORA_CHANCE:
		e.aurora = rng.randf_range(0.45, 1.0)
	if rng.randf() < COMET_CHANCE:
		e.comet = rng.randf_range(0.6, 1.0)
		# голова — в средней высоте неба в 22:00 этой ночи, хвост наискось вверх; потом комета плывёт со звёздами,
		# поэтому её место переводится в систему звёзд (как в sky.gdshader: поворот вокруг полюса на -star_rot)
		var head := Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(0.35, 0.8), rng.randf_range(-1.0, 1.0)).normalized()
		var side := head.cross(Vector3.UP).normalized()
		var tail := (side * rng.randf_range(-1.0, 1.0) + head.cross(side) * -0.8).normalized()
		var rot := -(n * 24.0 + 22.0) / 24.0 * TAU
		e.comet_dir = head.rotated(POLE, rot)
		e.comet_tail = tail.rotated(POLE, rot)
	if rng.randf() < SHOWER_CHANCE:
		e.meteor = METEOR_SHOWER
	return e


## Поставить небо, свет и туман на час hour; time — секунды игры, по ним плывут облака
func apply(hour: float, time: float) -> void:
	var s := state(hour)
	# часы без сброса: шаг больше полусуток считаем переходом через полночь назад или вперёд
	if is_nan(_clock):
		_clock = hour
	else:
		_clock += wrapf(hour - fposmod(_clock, 24.0), -12.0, 12.0)
	var night := floori((_clock - 12.0) / 24.0)
	if night != _night:
		_night = night
		events = _night_events(night)
	var sun := sun_direction(hour)
	var moon := -sun
	var src := sun if sun.y > 0.0 else moon
	sunlight = smoothstep(0.0, DUSK, sun.y)
	var fade := smoothstep(0.0, DUSK, src.y)
	light.light_color = s[3] if sun.y > 0.0 else MOON_COLOR
	var moon_light := lerpf(0.55, 1.0, 0.5 - 0.5 * cos(events.phase * TAU))   # молодая луна светит слабее
	light.light_energy = (s[4] if sun.y > 0.0 else MOON_ENERGY * s[9] * moon_light) * fade
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
	# дымка в низинах: высотный туман ниже MIST_TOP и ниже камеры (с гребня видно туманные долины)
	var mist: float = s[15]
	env.fog_height_density = MIST_DENSITY * mist
	if mist > 0.0:
		var eye := camera.global_position.y if camera != null else INF
		env.fog_height = minf(MIST_TOP, eye - MIST_BELOW_EYE)
	env.adjustment_saturation = s[13]
	light.shadow_opacity = s[14]
	# При скользящем свете завышенное смещение особенно заметно на земле:
	# деревья и камни кажутся парящими, особенно при низком разрешении карты теней.
	light.shadow_normal_bias = lerpf(SHADOW_NORMAL_LOW, SHADOW_NORMAL_HIGH, smoothstep(0.1, 0.45, src.y))
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
	sky_mat.set_shader_parameter("star_rot", _clock / 24.0 * TAU)
	sky_mat.set_shader_parameter("moon_phase", events.phase)
	# редкие явления видны только ночью и в глубоких сумерках
	var dark := smoothstep(0.25, 0.85, s[9])
	sky_mat.set_shader_parameter("aurora", events.aurora * dark * (0.75 + 0.25 * sin(time / 9.0)))
	sky_mat.set_shader_parameter("aurora_seed", events.aurora_seed)
	sky_mat.set_shader_parameter("comet", events.comet * dark)
	sky_mat.set_shader_parameter("comet_dir", events.comet_dir)
	sky_mat.set_shader_parameter("comet_tail", events.comet_tail)
	sky_mat.set_shader_parameter("meteor_rate", events.meteor * dark)
	for m: ShaderMaterial in terrain_mats:
		m.set_shader_parameter("sunlight", sunlight)
