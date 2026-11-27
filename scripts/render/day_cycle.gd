class_name DayCycle
extends RefCounted
## Смена суток (с 7.8). Одна таблица ключевых состояний KEYS (ночь, сумерки, утро, день, вечер):
## цвета неба, света, окружения и выдержка; между ключами всё плавно смешивается по часу.
## Солнце ходит по кругу (в полдень 55° над югом), луна — напротив. Часы идут ровно, а круг растянут под них (с 18.11):
## первый свет около 4:00, восход в 4:48, закат в 22:30, ночь настаёт к 23:40 (SOLAR_AT; таблица KEYS записана в «часах солнца»).
## Свет в сцене один (узел Sun): днём он светит от солнца, ночью от луны, переключается у горизонта,
## где сила обоих ноль, поэтому скачка не видно. Небо рисует resources/sky.gdshader, туман берёт цвет горизонта.
## С 7.9 сутки задают и атмосферу земли: густоту тумана и рассеяние света в нём, насыщенность, плотность теней,
## а облака отбрасывают на землю бегущие тени (resources/cloud_shadow.gdshaderinc, общий параметр cloud_shadow).
## С 8.3: дымка в низинах (столбец mist), звёздное небо вращается с часом,
## луна меняет фазу от ночи к ночи, а редкие явления (сияние, комета, звездопад) каждую ночь выбираются по сиду мира.

const SKY_SHADER := preload("res://resources/sky.gdshader")
const TILT := deg_to_rad(35.0)   # наклон пути солнца к югу: высота в полдень 90° − 35° = 55°
const DUSK := 0.08               # свет солнца и луны нарастает от горизонта до этой высоты (синус угла)
const SHADOW_NORMAL_BIAS := 1.2  # фиксированное смещение нормали: тень сохраняет контакт со стволами и камнями
const MOON_COLOR := Color(0.62, 0.72, 1.0)
const MOON_ENERGY := 0.22        # лунный свет ночью; в сумерках слабее (доля «ночи» в таблице)
const FOG := 0.00135              # дневная густота тумана, как в game_world.tscn (окружение общее для всех миров)
const CLOUD_SHADOW := 0.44      # насколько тень облака темнит землю днём
const CLOUD_WIND := Vector2(-1.92, -0.64)  # м/с: тени облаков бегут туда же, куда облака на небе
const MIST_TOP := 45.0           # высота фоновой дымки низин, м
const MIST_DENSITY := 0.0015     # фоновая густота при mist = 1
const MIST_OFF := Vector4(0.0, 0.0, 0.0, 1.0)   # глобальный mist_weather при выключенном тумане (w = 1)
const POLE := Vector3(0.0, 0.5736, -0.8192)   # ось вращения звёзд: 35° над севером, как в sky.gdshader
const MOON_DAYS := 8.0           # ночей от полнолуния до полнолуния
## Вероятности редких явлений на одну ночь
const AURORA_CHANCE := 0.16
const COMET_CHANCE := 0.07
const SHOWER_CHANCE := 0.15
const METEOR_SPORADIC := 0.05    # доля слотов по 2,5 с с метеором в обычную ночь (около одного в минуту)
const METEOR_SHOWER := 0.35
## Часы на циферблате, в которые солнце проходит «солнечные» 0, 6 (восход), 12, 18 (закат) и 24 часа круга. Между ними гладкая
## кубическая кривая: скорость солнца непрерывна, на стыках касательная — среднее гармоническое соседних отрезков.
const SOLAR_AT := [1.65, 4.8, 13.65, 22.5, 25.65]
const NIGHT_RATE := 6.0 / 3.15   # солнечных часов за час циферблата ночью
const DAY_RATE := 6.0 / 8.85     # и днём
const EDGE_RATE := 2.0 * NIGHT_RATE * DAY_RATE / (NIGHT_RATE + DAY_RATE)
const SOLAR_RATES := [NIGHT_RATE, EDGE_RATE, DAY_RATE, EDGE_RATE, NIGHT_RATE]
const CLOUD_SHADOW_TEX_SIZE := 256

static var use_cloud_shadow_texture := true
static var _cloud_shadow_tex: ImageTexture

## час, зенит, горизонт (= туман), цвет и сила солнца, цвет и сила окружения, выдержка, гало солнца, ночь (звёзды),
## цвет облаков; с 7.9 ещё покрытие неба кучевыми облаками, множитель тумана (утренняя дымка), насыщенность
## красок мира и плотность теней (при низком солнце и ночью тени мягче, днём глубже); с 8.3 — дымка в низинах.
## Последний ключ повторяет первый через сутки.
const KEYS := [
	[0.0, Color(0.05, 0.08, 0.19), Color(0.13, 0.18, 0.31), Color(0.62, 0.72, 1.0), 0.32, Color(0.36, 0.46, 0.78), 0.39, 0.87, 0.0, 1.0, Color(0.17, 0.21, 0.32), 0.28, 0.95, 0.74, 0.68, 0.5],
	[4.5, Color(0.07, 0.1, 0.23), Color(0.2, 0.22, 0.36), Color(0.62, 0.72, 1.0), 0.28, Color(0.38, 0.46, 0.76), 0.40, 0.88, 0.2, 0.9, Color(0.22, 0.24, 0.36), 0.28, 1.04, 0.78, 0.66, 0.7],
	[5.6, Color(0.17, 0.23, 0.42), Color(0.62, 0.48, 0.5), Color(1.0, 0.63, 0.44), 0.6, Color(0.52, 0.52, 0.72), 0.43, 0.94, 0.9, 0.35, Color(0.7, 0.5, 0.52), 0.22, 1.20, 1.0, 0.7, 0.8],
	[7.5, Color(0.3, 0.47, 0.76), Color(0.78, 0.7, 0.64), Color(1.0, 0.79, 0.60), 1.15, Color(0.64, 0.67, 0.82), 0.5, 1.0, 0.78, 0.0, Color(1.0, 0.88, 0.78), 0.24, 1.08, 1.10, 0.8, 0.65],
	[10.5, Color(0.32, 0.52, 0.82), Color(0.62, 0.74, 0.88), Color(1.0, 0.93, 0.8), 1.5, Color(0.62, 0.72, 0.9), 0.52, 0.92, 0.3, 0.0, Color(1.0, 1.0, 1.0), 0.28, 1.0, 1.08, 0.94, 0.0],
	[15.0, Color(0.32, 0.52, 0.82), Color(0.62, 0.74, 0.88), Color(1.0, 0.93, 0.8), 1.5, Color(0.62, 0.72, 0.9), 0.52, 0.92, 0.3, 0.0, Color(1.0, 1.0, 1.0), 0.36, 1.0, 1.08, 0.94, 0.0],
	[17.3, Color(0.3, 0.42, 0.7), Color(0.93, 0.68, 0.47), Color(1.0, 0.67, 0.42), 1.25, Color(0.7, 0.64, 0.72), 0.5, 0.98, 0.92, 0.0, Color(1.0, 0.78, 0.63), 0.32, 1.1, 1.16, 0.88, 0.1],
	[18.6, Color(0.16, 0.19, 0.38), Color(0.65, 0.43, 0.44), Color(1.0, 0.56, 0.42), 0.6, Color(0.52, 0.5, 0.7), 0.43, 0.94, 0.9, 0.3, Color(0.6, 0.4, 0.45), 0.28, 1.2, 1.06, 0.7, 0.35],
	[20.0, Color(0.07, 0.1, 0.23), Color(0.2, 0.22, 0.36), Color(0.62, 0.72, 1.0), 0.28, Color(0.38, 0.46, 0.76), 0.40, 0.88, 0.2, 0.9, Color(0.22, 0.24, 0.36), 0.26, 1.02, 0.78, 0.66, 0.45],
	[24.0, Color(0.05, 0.08, 0.19), Color(0.13, 0.18, 0.31), Color(0.62, 0.72, 1.0), 0.32, Color(0.36, 0.46, 0.78), 0.39, 0.87, 0.0, 1.0, Color(0.17, 0.21, 0.32), 0.28, 0.95, 0.74, 0.68, 0.5],
]

var env: Environment
var light: DirectionalLight3D
var sky_mat: ShaderMaterial
var atmosphere: WorldAtmosphereConfig = null # профиль пасмурности, тумана и света типа мира (null — прежний Тип 1)
var sunlight := 1.0            # 0..1: насколько сейчас светит именно солнце
var camera: Camera3D           # совместимость с игровыми и съёмочными инструментами
var world_seed := 0            # сид мира: какие ночи с сиянием, кометой, звездопадом
var events := {}               # явления текущей ночи (см. _night_events); можно подменить для снимков
## -1 uses seeded weather; captures can fix coverage without changing time.
var cloud_cover_override := -1.0
var local_mist := 0.0 # Shared, smoothed weather strength for geographic fog patches.
var _fog_time := NAN
var _air_density := 0.0
var _clock := NAN              # часы без сброса в полночь: по ним вращаются звёзды и считаются ночи
var _night := 0x7fffffff
var _shader_globals := {}
var _dark_active := true       # были ли включены ночные параметры шейдера неба на прошлом кадре


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
	env.fog_height = MIST_TOP


## 16.11: купол облаков для этого неба (scripts/render/sky_cloud_dome.gd) — узел, который надо добавить в дерево
func make_cloud_dome() -> Node:
	return preload("res://scripts/render/sky_cloud_dome.gd").new(sky_mat)


## Час круга солнца (0..24; 6 — восход, 18 — закат) для часа циферблата hour
static func solar_hour(hour: float) -> float:
	var h := fposmod(hour - SOLAR_AT[0], 24.0) + SOLAR_AT[0]
	var i := 0
	while i < 3 and SOLAR_AT[i + 1] <= h:
		i += 1
	var w: float = SOLAR_AT[i + 1] - SOLAR_AT[i]
	var u: float = (h - SOLAR_AT[i]) / w
	var u2: float = u * u
	var u3: float = u2 * u
	return 6.0 * i * (2.0 * u3 - 3.0 * u2 + 1.0) + SOLAR_RATES[i] * w * (u3 - 2.0 * u2 + u) \
		+ 6.0 * (i + 1) * (-2.0 * u3 + 3.0 * u2) + SOLAR_RATES[i + 1] * w * (u3 - u2)


## Направление на солнце в час циферблата hour (0..24)
static func sun_direction(hour: float) -> Vector3:
	var a := (solar_hour(hour) - 6.0) / 24.0 * TAU
	var east := Vector3(1.0, 0.0, 0.0)
	var arc := Vector3(0.0, cos(TILT), sin(TILT))   # вверх и к югу (юг — +z)
	return (east * cos(a) + arc * sin(a)).normalized()


## Часы:минуты для подсказок, «07:30»
static func clock(hour: float) -> String:
	var m := clock_minute(hour)
	return "%02d:%02d" % [m / 60, m % 60]


static func clock_minute(hour: float) -> int:
	# A step can land infinitesimally short of an exact minute.
	return posmod(floori(fposmod(hour, 24.0) * 60.0 + 1.0e-8), 1440)


## Ключевое состояние в час циферблата hour: гладкая кубическая интерполяция (C¹) между ключами без остановок на узлах
static func state(hour: float) -> Array:
	hour = fposmod(hour, 24.0)
	var sun_hour := solar_hour(hour)   # ключи KEYS записаны по кругу солнца
	var n := KEYS.size()
	var i := 0
	while i < n - 2 and KEYS[i + 1][0] <= sun_hour:
		i += 1
	var a: Array = KEYS[i]
	var b: Array = KEYS[i + 1]
	var prev: Array = KEYS[i - 1 if i > 0 else n - 2]
	var next: Array = KEYS[i + 2 if i + 2 < n else 1]
	var dt := float(b[0] - a[0])
	var dt_prev := float(a[0] - prev[0]) if i > 0 else float(24.0 - prev[0])
	var dt_next := float(next[0] - b[0]) if i + 2 < n else float(next[0])
	var u := clampf((sun_hour - float(a[0])) / dt, 0.0, 1.0)
	var u2 := u * u
	var u3 := u2 * u
	var h00 := 2.0 * u3 - 3.0 * u2 + 1.0
	var h10 := u3 - 2.0 * u2 + u
	var h01 := -2.0 * u3 + 3.0 * u2
	var h11 := u3 - u2
	var w_a := dt / (dt_prev + dt)
	var w_b := dt / (dt + dt_next)
	var out := [hour]
	for k in range(1, a.size()):
		var vp: Variant = prev[k]
		var va: Variant = a[k]
		var vb: Variant = b[k]
		var vn: Variant = next[k]
		if va is Color:
			var cp: Color = vp
			var ca: Color = va
			var cb: Color = vb
			var cn: Color = vn
			var ma := (cb - cp) * w_a
			var mb := (cn - ca) * w_b
			var c := ca * h00 + ma * h10 + cb * h01 + mb * h11
			var min_r := minf(ca.r, cb.r)
			var max_r := maxf(ca.r, cb.r)
			var min_g := minf(ca.g, cb.g)
			var max_g := maxf(ca.g, cb.g)
			var min_b := minf(ca.b, cb.b)
			var max_b := maxf(ca.b, cb.b)
			out.append(Color(clampf(c.r, min_r, max_r), clampf(c.g, min_g, max_g), clampf(c.b, min_b, max_b), 1.0))
		else:
			var fp := float(vp)
			var fa := float(va)
			var fb := float(vb)
			var fn := float(vn)
			var ma := (fb - fp) * w_a
			var mb := (fn - fa) * w_b
			var v := fa * h00 + ma * h10 + fb * h01 + mb * h11
			out.append(clampf(v, minf(fa, fb), maxf(fa, fb)))
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
		var rot := -22.0 / 24.0 * TAU
		e.comet_dir = head.rotated(POLE, rot)
		e.comet_tail = tail.rotated(POLE, rot)
	if rng.randf() < SHOWER_CHANCE:
		e.meteor = METEOR_SHOWER
	return e


func _publish_global(parameter: StringName, value: Variant) -> void:
	if _shader_globals.get(parameter) == value:
		return
	_shader_globals[parameter] = value
	RenderingServer.global_shader_parameter_set(parameter, value)


static func ensure_cloud_shadow_texture() -> ImageTexture:
	if not use_cloud_shadow_texture:
		return null
	if _cloud_shadow_tex != null:
		return _cloud_shadow_tex
	var fast := Grid.fast_grid()
	if fast == null:
		return null
	var bytes: PackedByteArray = fast.BakeCloudShadowNoise(CLOUD_SHADOW_TEX_SIZE)
	if bytes.size() != CLOUD_SHADOW_TEX_SIZE * CLOUD_SHADOW_TEX_SIZE * 2:
		return null
	var img := Image.create_from_data(CLOUD_SHADOW_TEX_SIZE, CLOUD_SHADOW_TEX_SIZE, false, Image.FORMAT_RG8, bytes)
	_cloud_shadow_tex = ImageTexture.create_from_image(img)
	RenderingServer.global_shader_parameter_set(&"cloud_shadow_tex", _cloud_shadow_tex)
	return _cloud_shadow_tex


## В игре передаётся полный ход часов для выбора ночи. Инструменты могут задавать только час суток.
func apply(hour: float, time: float, full_clock := false) -> void:
	var s := state(hour)
	if full_clock or is_nan(_clock):
		_clock = hour
	else:
		_clock += wrapf(hour - fposmod(_clock, 24.0), -12.0, 12.0)
	hour = s[0]
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
	var atm := atmosphere
	var day_mask := (1.0 - smoothstep(0.15, 0.75, float(s[9]))) if atm != null else 0.0
	var seed_phase := float(posmod(world_seed, 997)) * 0.13
	var cover: float = s[11] + 0.12 * sin(time / 67.0 + seed_phase) + 0.06 * sin(time / 23.0 + 1.0 + seed_phase * 1.7)
	if atm != null:
		var wave := 0.5 + 0.5 * (0.65 * sin(time / 67.0 + seed_phase) + 0.35 * sin(time / 23.0 + 1.0 + seed_phase * 1.7))
		var raw_cover := lerpf(atm.cloud_cover_min, atm.cloud_cover_max, clampf(wave, 0.0, 1.0))
		cover = lerpf(clampf(cover, 0.05, 0.85), raw_cover, day_mask)
	if cloud_cover_override >= 0.0:
		cover = cloud_cover_override
	cover = clampf(cover, 0.05, 0.98 if atm != null else 0.85)
	var overcast := smoothstep(0.30, 0.65, cover) * sunlight
	var atm_blend := (atm.sky_overcast_blend * day_mask) if atm != null else 0.0
	var horizon_use: Color = Color(s[2]).lerp(atm.overcast_horizon, atm_blend) if atm != null else s[2]
	var zenith_use: Color = Color(s[1]).lerp(atm.overcast_zenith, atm_blend) if atm != null else s[1]
	var cloud_col_use: Color = Color(s[10]).lerp(atm.overcast_cloud_color, atm_blend) if atm != null else s[10]
	var sun_col_use: Color = Color(s[3]).lerp(atm.overcast_sun_color, atm_blend * 0.75) if atm != null else s[3]
	env.fog_light_color = horizon_use
	var haze: Color = horizon_use
	_publish_global(&"style_haze", Vector3(haze.r, haze.g, haze.b))
	_publish_global(&"sun_dir", src) # направление на светило: микротень пучков травы в terrain.gdshader
	var break_pulse := 0.78 if cloud_cover_override >= 0.0 else (0.5 + 0.5 * sin(time / 41.0 + seed_phase * 2.1))
	env.fog_sun_scatter = 0.06 + float(s[8]) * 0.22 * (lerpf(1.0, atm.sun_halo_mul, day_mask) if atm != null else 1.0) \
		+ (atm.volumetric_shaft_energy * day_mask * (0.14 + 0.14 * break_pulse) if atm != null else 0.0)
	var mist: float = s[15]
	light.shadow_normal_bias = SHADOW_NORMAL_BIAS
	# свет через облака: чем гуще облачность, тем мягче и слабее прямое солнце, тем больше рассеянного света неба
	if sun.y > 0.0:
		light.light_energy *= lerpf(1.12, 0.38, overcast)
		light.light_color = light.light_color.lerp(Color(0.90, 0.94, 1.0), overcast * 0.7)
		if atm != null:
			light.light_energy *= lerpf(1.0, atm.sun_energy_mul, day_mask)
			light.light_color = light.light_color.lerp(atm.overcast_sun_color, atm_blend * 0.75)
	env.ambient_light_energy = float(s[6]) * lerpf(0.86, 1.15, overcast) * (lerpf(1.0, atm.ambient_energy_mul, day_mask) if atm != null else 1.0)
	var ambient: Color = s[5]
	var ambient_col := ambient.lerp(Color(0.72, 0.77, 0.85), overcast * 0.45)
	if atm != null:
		ambient_col = ambient_col.lerp(atm.overcast_ambient, atm_blend * 0.70)
	env.ambient_light_color = ambient_col
	env.ambient_light_sky_contribution = lerpf(0.6, atm.ambient_sky_contribution, day_mask) if atm != null else 0.6
	env.fog_density = FOG * float(s[12]) * lerpf(1.0, 1.45, overcast) * (lerpf(1.0, atm.fog_density_mul, 0.45 + 0.55 * day_mask) if atm != null else 1.0)
	# Seconds of game time: pause freezes the atmosphere; time skips ease over 12 s.
	var fog_blend := 1.0 if is_nan(_fog_time) else 1.0 - exp(-clampf(time - _fog_time, 0.0, 1.0) / 12.0)
	_fog_time = time
	var mist_target := clampf(mist + overcast * 0.15, 0.0, 1.0)
	if atm != null:
		mist_target = clampf(maxf(mist_target, atm.local_mist_floor * (0.65 + 0.35 * day_mask)), 0.0, 1.0)
	local_mist = lerpf(local_mist, mist_target, fog_blend)
	if atm != null:
		env.fog_height = (camera.global_position.y if camera != null else MIST_TOP) + atm.fog_height_offset
		env.fog_height_density = MIST_DENSITY * atm.fog_height_density_mul * local_mist
	else:
		env.fog_height = MIST_TOP
		env.fog_height_density = MIST_DENSITY * local_mist
	var air_target := (0.00015 + 0.0004 * float(s[8]) + 0.00015 * overcast) * (lerpf(1.0, atm.volumetric_density_mul, 0.45 + 0.55 * day_mask) if atm != null else 1.0)
	_air_density = lerpf(_air_density, air_target, fog_blend)
	var mist_tint: Color = horizon_use
	if env.volumetric_fog_enabled:
		mist_tint = Color(0.86, 0.90, 0.95).lerp(mist_tint, 0.12 if atm == null else atm.volumetric_horizon_tint)
		env.volumetric_fog_density = _air_density
		env.volumetric_fog_albedo = mist_tint
		light.light_volumetric_fog_energy = lerpf(1.0, 0.35, overcast) \
			+ (atm.volumetric_shaft_energy * day_mask * (0.45 + 0.55 * break_pulse) if atm != null else 0.0)
	if env.fog_enabled:
		var mist_wind := CLOUD_WIND * time * 0.08
		_publish_global(&"mist_weather", Vector4(mist_wind.x, mist_wind.y, local_mist, 0.0))
		_publish_global(&"mist_tint", mist_tint)
	else:
		# w = 1: туман выключен в настройках; шейдеры с fog_disabled (ореол гирлянд) не гасят себя «своей дымкой»
		_publish_global(&"mist_weather", MIST_OFF)
	# 13.11: визуальный стиль подстраивает выдержку тонмаппера и насыщенность; база запоминается для смены стиля на паузе
	var day_exp := float(s[7]) * (lerpf(1.0, atm.exposure_mul, day_mask) if atm != null else 1.0)
	var day_sat := lerpf(float(s[13]), 0.96, overcast) * (lerpf(1.0, atm.day_saturation_mul, day_mask) if atm != null else 1.0)
	VisualStyle.apply_day(env, day_exp, day_sat)
	light.shadow_opacity = lerpf(float(s[14]), 0.95, sunlight)
	# Soften contrast through direct/sky balance, not translucent shadows.
	light.shadow_blur = lerpf(1.25, 2.0, overcast) + (atm.shadow_blur_add * day_mask if atm != null else 0.0)
	env.fog_aerial_perspective = clampf(lerpf(0.24, 0.40, maxf(overcast, float(s[8]) * 0.6)) * (atm.aerial_perspective_mul if atm != null else 1.0), 0.0, 0.85)
	# Облегчённая проекция: общие ветер, покрытие и сид; силуэты облаков приближённые.
	var shadow_ofs := Vector2(seed_phase * 0.37, seed_phase * 0.61) * 160.0
	var shadow_strength := CLOUD_SHADOW * sunlight * (1.0 - overcast * 0.75) * (1.0 - (atm.overcast_deck * atm.overcast_shadow_damp * day_mask if atm != null else 0.0))
	if shadow_strength > 0.0:
		ensure_cloud_shadow_texture()
	_publish_global(&"cloud_shadow", Vector4.ZERO if shadow_strength == 0.0 else
		Vector4(CLOUD_WIND.x * time - shadow_ofs.x, CLOUD_WIND.y * time - shadow_ofs.y, shadow_strength, cover))
	var zenith: Color = zenith_use
	sky_mat.set_shader_parameter("zenith_color", zenith.lerp(horizon_use, overcast * (0.45 if atm == null else 0.32)))
	sky_mat.set_shader_parameter("horizon_color", horizon_use)
	sky_mat.set_shader_parameter("sun_dir", sun)
	sky_mat.set_shader_parameter("sun_color", sun_col_use)
	sky_mat.set_shader_parameter("halo", float(s[8]) * (lerpf(1.0, atm.sun_halo_mul, day_mask) if atm != null else 1.0))
	sky_mat.set_shader_parameter("moon_dir", moon)
	sky_mat.set_shader_parameter("night", s[9])
	sky_mat.set_shader_parameter("cloud_color", cloud_col_use)
	sky_mat.set_shader_parameter("cloud_time", time)
	sky_mat.set_shader_parameter("cloud_cover", cover)
	sky_mat.set_shader_parameter("overcast_deck", atm.overcast_deck * day_mask if atm != null else 0.0)
	sky_mat.set_shader_parameter("cloud_break_strength", atm.cloud_break_strength * day_mask * (0.45 + 0.55 * break_pulse) if atm != null else 0.0)
	sky_mat.set_shader_parameter("cloud_break_shafts", atm.cloud_break_shafts * day_mask * (0.40 + 0.60 * break_pulse) if atm != null else 0.0)
	sky_mat.set_shader_parameter("cubemap_ground_darken", atm.cubemap_ground_darken * day_mask if atm != null else 0.0)
	sky_mat.set_shader_parameter("cubemap_overcast_cie", atm.cubemap_overcast_cie * day_mask if atm != null else 0.0)
	sky_mat.set_shader_parameter("cloud_seed", seed_phase)
	# редкие ночные явления, звёзды и фаза луны передаются только в сумерках и ночью
	var dark := smoothstep(0.25, 0.85, s[9])
	_publish_global(&"vegetation_night", dark)
	if s[9] > 0.001 or _dark_active:
		sky_mat.set_shader_parameter("star_rot", hour / 24.0 * TAU)
		sky_mat.set_shader_parameter("moon_phase", events.phase)
		sky_mat.set_shader_parameter("aurora", events.aurora * dark * (0.75 + 0.25 * sin(time / 9.0)))
		sky_mat.set_shader_parameter("aurora_seed", events.aurora_seed)
		sky_mat.set_shader_parameter("comet", events.comet * dark)
		sky_mat.set_shader_parameter("comet_dir", events.comet_dir)
		sky_mat.set_shader_parameter("comet_tail", events.comet_tail)
		sky_mat.set_shader_parameter("meteor_rate", events.meteor * dark)
		_dark_active = s[9] > 0.001
