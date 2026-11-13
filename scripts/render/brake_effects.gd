class_name BrakeEffects
extends Node3D
## Визуальные эффекты торможения, блокировки колёс и бокового сноса для переднего и заднего колеса.
## Работает по физическому состоянию BikeRide и рельефу Heightfield/WorldData без выделения памяти в кадре:
##   1) Следы и борозды на земле/настилах (ImmediateMesh + brake_track.gdshader), отдельно для каждого колеса;
##   2) Выброс твёрдых частиц из пятна контакта и калипера (MultiMesh + brake_debris.gdshader):
##      гравий, комья грунта, песок, хвоя/листья, травинки, комочки снега, капли воды, искры на камне и перегретом роторе;
##   3) Клубы пыли, дыма стёртой резины, снежной пудры и водяного тумана (MultiMesh + brake_plume.gdshader);
##   4) Нагрев и остывание переднего и заднего тормозных дисков (heat_f, heat_r) для BikeView.

# Виды поверхностей для шейдера следов и палитры частиц
const SURF_GRAVEL := 1
const SURF_DIRT := 2
const SURF_PACKED := 3
const SURF_STONE := 4
const SURF_SAND := 5
const SURF_FOREST := 6
const SURF_MEADOW := 7
const SURF_SNOW := 8
const SURF_WOOD := 9
const SURF_WATER := 10

const DEBRIS_COUNT := 192
const PLUME_COUNT := 96
const TRACK_POINTS := 96     # кольцевой буфер точек следа на каждое колесо (2 колеса = до 192 точек)
const TRACK_LIFETIME := 4.5  # секунд до полного исчезновения следа
const TRACK_FADE := 0.6      # общая прозрачность следов (1 = как раньше)
const MESH_STEP := 1.0 / 30.0 # ленту следа пересобираем не чаще: сотни вершин через GDScript на каждом такте дороги
const EFFECT_SCALE := 0.6    # общая сила частиц и пыли торможения (1 = как раньше)
const TRACK_STEP := 0.20     # шаг записи новых точек следа, м

# Палитра следов, пыли и частиц по видам покрытия:
#   track  — цвет следа/борозды на земле (и базовая непрозрачность),
#   plume  — цвет и прозрачность клуба пыли/дыма/пудры/брызг,
#   debris1, debris2 — два оттенка твёрдых частиц (камешки, комья, листья, трава, снег),
#   width  — базовая ширина следа колеса, м,
#   plume_kind — код для brake_plume.gdshader (0: пыль, 1: дым, 2: снег, 3: вода),
#   debris_kind — код для brake_debris.gdshader (0: камень/ком, 1: органика/трава, 2: снег/вода, 3: искра).
const PALETTES := {
	SURF_GRAVEL: {
		track = Color(0.36, 0.33, 0.27, 0.80),
		plume = Color(0.76, 0.71, 0.61, 0.56),
		debris1 = Color(0.66, 0.62, 0.54),
		debris2 = Color(0.46, 0.43, 0.38),
		width = 0.088, plume_kind = 0.0, debris_kind = 0.0,
		debris_scale = Vector3(1.0, 0.85, 1.15), bounce = 0.38
	},
	SURF_DIRT: {
		track = Color(0.24, 0.18, 0.12, 0.84),
		plume = Color(0.64, 0.51, 0.37, 0.54),
		debris1 = Color(0.42, 0.31, 0.20),
		debris2 = Color(0.30, 0.22, 0.14),
		width = 0.092, plume_kind = 0.0, debris_kind = 0.0,
		debris_scale = Vector3(1.15, 0.90, 1.10), bounce = 0.22
	},
	SURF_PACKED: {
		track = Color(0.26, 0.21, 0.16, 0.76),
		plume = Color(0.68, 0.58, 0.45, 0.46),
		debris1 = Color(0.48, 0.38, 0.28),
		debris2 = Color(0.35, 0.28, 0.20),
		width = 0.082, plume_kind = 0.0, debris_kind = 0.0,
		debris_scale = Vector3(0.95, 0.80, 1.0), bounce = 0.28
	},
	SURF_STONE: {
		track = Color(0.14, 0.14, 0.15, 0.82),
		plume = Color(0.78, 0.80, 0.82, 0.42),
		debris1 = Color(0.58, 0.57, 0.54),
		debris2 = Color(0.40, 0.39, 0.37),
		width = 0.072, plume_kind = 1.0, debris_kind = 0.0,
		debris_scale = Vector3(0.85, 0.65, 1.15), bounce = 0.52
	},
	SURF_SAND: {
		track = Color(0.56, 0.48, 0.32, 0.86),
		plume = Color(0.88, 0.79, 0.58, 0.64),
		debris1 = Color(0.84, 0.75, 0.52),
		debris2 = Color(0.72, 0.62, 0.42),
		width = 0.112, plume_kind = 0.0, debris_kind = 0.0,
		debris_scale = Vector3(0.85, 0.85, 0.95), bounce = 0.12
	},
	SURF_FOREST: {
		track = Color(0.20, 0.15, 0.10, 0.84),
		plume = Color(0.52, 0.43, 0.32, 0.45),
		debris1 = Color(0.48, 0.34, 0.18),
		debris2 = Color(0.28, 0.38, 0.18),
		width = 0.090, plume_kind = 0.0, debris_kind = 1.0,
		debris_scale = Vector3(0.55, 0.32, 1.85), bounce = 0.18
	},
	SURF_MEADOW: {
		track = Color(0.22, 0.24, 0.13, 0.80),
		plume = Color(0.56, 0.54, 0.38, 0.38),
		debris1 = Color(0.32, 0.52, 0.20),
		debris2 = Color(0.36, 0.27, 0.18),
		width = 0.088, plume_kind = 0.0, debris_kind = 1.0,
		debris_scale = Vector3(0.45, 0.30, 2.10), bounce = 0.16
	},
	SURF_SNOW: {
		track = Color(0.68, 0.76, 0.86, 0.82),
		plume = Color(0.92, 0.96, 1.00, 0.66),
		debris1 = Color(0.94, 0.97, 1.00),
		debris2 = Color(0.78, 0.86, 0.95),
		width = 0.106, plume_kind = 2.0, debris_kind = 2.0,
		debris_scale = Vector3(1.10, 1.00, 1.10), bounce = 0.15
	},
	SURF_WOOD: {
		track = Color(0.16, 0.13, 0.10, 0.74),
		plume = Color(0.72, 0.66, 0.56, 0.34),
		debris1 = Color(0.58, 0.45, 0.30),
		debris2 = Color(0.42, 0.32, 0.22),
		width = 0.070, plume_kind = 1.0, debris_kind = 1.0,
		debris_scale = Vector3(0.45, 0.25, 1.60), bounce = 0.35
	},
	SURF_WATER: {
		track = Color(0.22, 0.30, 0.34, 0.45),
		plume = Color(0.80, 0.90, 0.94, 0.58),
		debris1 = Color(0.76, 0.89, 0.95),
		debris2 = Color(0.62, 0.80, 0.88),
		width = 0.084, plume_kind = 3.0, debris_kind = 2.0,
		debris_scale = Vector3(0.75, 0.75, 1.25), bounce = 0.05
	}
}

## Нагрев переднего и заднего тормозного диска (0..1), передаётся в BikeView.
var heat_f := 0.0
var heat_r := 0.0
var last_surface_f := SURF_GRAVEL
var last_surface_r := SURF_GRAVEL

var _debris_mm: MultiMeshInstance3D
var _plume_mm: MultiMeshInstance3D
var _track_node: MeshInstance3D
var _track_mesh: ImmediateMesh

# Кольцевой пул твёрдых частиц (камни, комья, хвоя, травинки, снег, искры)
var _d_pos := PackedVector3Array()
var _d_vel := PackedVector3Array()
var _d_rot := PackedVector3Array()
var _d_spin := PackedVector3Array()
var _d_scale := PackedVector3Array()
var _d_color := PackedColorArray()
var _d_custom := PackedColorArray() # r = age, g = kind, b = seed, a = glow
var _d_life := PackedFloat32Array()
var _d_max_life := PackedFloat32Array()
var _d_ground := PackedFloat32Array()
var _d_bounce := PackedFloat32Array()
var _d_cursor := 0

# Кольцевой пул клубов пыли, дыма и снежной/водяной взвеси
var _p_pos := PackedVector3Array()
var _p_vel := PackedVector3Array()
var _p_size0 := PackedFloat32Array()
var _p_size1 := PackedFloat32Array()
var _p_color := PackedColorArray()
var _p_custom := PackedColorArray() # r = age, g = kind, b = seed, a = density
var _p_life := PackedFloat32Array()
var _p_max_life := PackedFloat32Array()
var _p_cursor := 0

# Кольцевой буфер сегментов следа для каждого из двух колёс (0 — переднее, 1 — заднее)
var _t_pos: Array[PackedVector3Array] = [PackedVector3Array(), PackedVector3Array()]
var _t_right: Array[PackedVector3Array] = [PackedVector3Array(), PackedVector3Array()]
var _t_dist: Array[PackedFloat32Array] = [PackedFloat32Array(), PackedFloat32Array()]
var _t_age: Array[PackedFloat32Array] = [PackedFloat32Array(), PackedFloat32Array()]
var _t_width: Array[PackedFloat32Array] = [PackedFloat32Array(), PackedFloat32Array()]
var _t_power: Array[PackedFloat32Array] = [PackedFloat32Array(), PackedFloat32Array()]
var _t_kind: Array[PackedInt32Array] = [PackedInt32Array(), PackedInt32Array()]
var _t_color: Array[PackedColorArray] = [PackedColorArray(), PackedColorArray()]
var _t_link: Array[PackedByteArray] = [PackedByteArray(), PackedByteArray()]
var _t_head := [0, 0]
var _t_count := [0, 0]
var _t_WasActive := [false, false]
var _t_last_pos := [Vector3.ZERO, Vector3.ZERO]
var _t_total_dist := [0.0, 0.0]

var _emit_accum_d := [0.0, 0.0]
var _emit_accum_p := [0.0, 0.0]
var _spark_accum := [0.0, 0.0]
var _mesh_wait := 0.0
var _prev_bike_pos := Vector3.INF
var _rng := RandomNumberGenerator.new()
var _ready_done := false


func _ready() -> void:
	setup()


func setup() -> void:
	if _ready_done:
		return
	_ready_done = true
	_rng.seed = 94821

	# 1. Сетка следов на земле
	_track_mesh = ImmediateMesh.new()
	_track_node = MeshInstance3D.new()
	_track_node.name = "BrakeTracks"
	_track_node.mesh = _track_mesh
	_track_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var track_mat := ShaderMaterial.new()
	track_mat.shader = preload("res://resources/brake_track.gdshader")
	_track_node.material_override = track_mat
	add_child(_track_node)

	# 2. Пул твёрдых частиц (гранёный осколок/комочек)
	var d_mesh := SphereMesh.new()
	d_mesh.radius = 0.018
	d_mesh.height = 0.032
	d_mesh.radial_segments = 5
	d_mesh.rings = 2
	var d_mat := ShaderMaterial.new()
	d_mat.shader = preload("res://resources/brake_debris.gdshader")
	d_mesh.material = d_mat

	_debris_mm = MultiMeshInstance3D.new()
	_debris_mm.name = "BrakeDebris"
	_debris_mm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mm_d := MultiMesh.new()
	mm_d.transform_format = MultiMesh.TRANSFORM_3D
	mm_d.use_colors = true
	mm_d.use_custom_data = true
	mm_d.mesh = d_mesh
	mm_d.instance_count = DEBRIS_COUNT
	_debris_mm.multimesh = mm_d
	add_child(_debris_mm)

	# 3. Пул клубов пыли, дыма и снежной пудры
	var p_mesh := QuadMesh.new()
	p_mesh.size = Vector2(1.0, 1.0)
	var p_mat := ShaderMaterial.new()
	p_mat.shader = preload("res://resources/brake_plume.gdshader")
	p_mesh.material = p_mat

	_plume_mm = MultiMeshInstance3D.new()
	_plume_mm.name = "BrakePlumes"
	_plume_mm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mm_p := MultiMesh.new()
	mm_p.transform_format = MultiMesh.TRANSFORM_3D
	mm_p.use_colors = true
	mm_p.use_custom_data = true
	mm_p.mesh = p_mesh
	mm_p.instance_count = PLUME_COUNT
	_plume_mm.multimesh = mm_p
	add_child(_plume_mm)

	_d_pos.resize(DEBRIS_COUNT)
	_d_vel.resize(DEBRIS_COUNT)
	_d_rot.resize(DEBRIS_COUNT)
	_d_spin.resize(DEBRIS_COUNT)
	_d_scale.resize(DEBRIS_COUNT)
	_d_color.resize(DEBRIS_COUNT)
	_d_custom.resize(DEBRIS_COUNT)
	_d_life.resize(DEBRIS_COUNT)
	_d_max_life.resize(DEBRIS_COUNT)
	_d_ground.resize(DEBRIS_COUNT)
	_d_bounce.resize(DEBRIS_COUNT)

	_p_pos.resize(PLUME_COUNT)
	_p_vel.resize(PLUME_COUNT)
	_p_size0.resize(PLUME_COUNT)
	_p_size1.resize(PLUME_COUNT)
	_p_color.resize(PLUME_COUNT)
	_p_custom.resize(PLUME_COUNT)
	_p_life.resize(PLUME_COUNT)
	_p_max_life.resize(PLUME_COUNT)

	for w in 2:
		_t_pos[w].resize(TRACK_POINTS)
		_t_right[w].resize(TRACK_POINTS)
		_t_dist[w].resize(TRACK_POINTS)
		_t_age[w].resize(TRACK_POINTS)
		_t_width[w].resize(TRACK_POINTS)
		_t_power[w].resize(TRACK_POINTS)
		_t_kind[w].resize(TRACK_POINTS)
		_t_color[w].resize(TRACK_POINTS)
		_t_link[w].resize(TRACK_POINTS)

	clear()


func clear() -> void:
	if not _ready_done:
		setup()
	heat_f = 0.0
	heat_r = 0.0
	_prev_bike_pos = Vector3.INF
	_d_life.fill(0.0)
	_p_life.fill(0.0)
	var zero_xf := Transform3D(Basis.IDENTITY.scaled(Vector3.ZERO), Vector3.ZERO)
	for i in DEBRIS_COUNT:
		_debris_mm.multimesh.set_instance_transform(i, zero_xf)
	for i in PLUME_COUNT:
		_plume_mm.multimesh.set_instance_transform(i, zero_xf)
	_debris_mm.visible = false
	_plume_mm.visible = false
	_track_mesh.clear_surfaces()
	_track_node.visible = false
	for w in 2:
		_t_head[w] = 0
		_t_count[w] = 0
		_t_WasActive[w] = false
		_t_total_dist[w] = 0.0
		_emit_accum_d[w] = 0.0
		_emit_accum_p[w] = 0.0
		_spark_accum[w] = 0.0


## Единая модель нагрева и охлаждения тормозных дисков (для BrakeEffects и BikeView).
static func step_rotor_heat(b: BikeRide, dt: float, prev_f: float, prev_r: float) -> Vector2:
	var spd := absf(b.speed)
	var cool := (0.22 + 0.032 * spd) * dt
	var wf := maxf(b.brake_force.x, b.brakes.front_force) * spd if (b.riding and not b.airborne and b.contact_f()) else 0.0
	var wr := maxf(b.brake_force.y, b.brakes.rear_force) * spd if (b.riding and not b.airborne and b.contact_r()) else 0.0
	var hf := clampf(prev_f + (wf * 0.0085 + b.brakes.risk * 0.16) * dt - cool * (0.40 + 0.60 * prev_f), 0.0, 1.0)
	var hr := clampf(prev_r + (wr * 0.0075 + b.brakes.risk * 0.12) * dt - cool * (0.40 + 0.60 * prev_r), 0.0, 1.0)
	return Vector2(hf, hr)


## Шаг симуляции эффектов торможения (вызывается в _physics_process из GameWorld или TrailLab).
func tick(dt: float, b: BikeRide, w: WorldData, h: Heightfield) -> void:
	if not _ready_done:
		setup()
	dt = clampf(dt, 0.0, 0.1) if is_finite(dt) else 0.0
	if dt <= 0.0 or b == null or h == null:
		return

	var bike_pos := Vector3(b.x, b.y, b.z)
	if _prev_bike_pos.is_finite() and bike_pos.distance_to(_prev_bike_pos) > 3.5:
		clear()
	_prev_bike_pos = bike_pos

	var speed := absf(b.speed)
	var next_heat := step_rotor_heat(b, dt, heat_f, heat_r)
	heat_f = next_heat.x
	heat_r = next_heat.y

	if b.riding and not b.fallen and speed > 0.35:
		_emit_wheels(dt, b, w, h)
	else:
		_t_WasActive[0] = false
		_t_WasActive[1] = false

	_step_debris(dt)
	_step_plumes(dt)
	_step_tracks(dt)


func _emit_wheels(dt: float, b: BikeRide, w: WorldData, h: Heightfield) -> void:
	var forward := Vector3(-sin(b.heading), 0.0, -cos(b.heading))
	var right := Vector3(cos(b.heading), 0.0, -sin(b.heading))
	var speed := absf(b.speed)
	var move_sign := -1.0 if b.speed < -0.05 else 1.0
	var move_dir := forward * move_sign

	for wheel_idx in 2:
		var is_front := wheel_idx == 0
		var in_contact := (b.contact_f() if is_front else b.contact_r()) and not b.airborne
		if not in_contact:
			_t_WasActive[wheel_idx] = false
			continue

		var hub_sign := 1.0 if is_front else -1.0
		var wx := b.x + forward.x * BikeRide.HUB * hub_sign
		var wz := b.z + forward.z * BikeRide.HUB * hub_sign
		var wy := b.y + (b.ground_f if is_front else b.ground_r)

		# Определяем вид покрытия и ситуацию под конкретным колесом
		var surf_kind := _classify_surface(w, h, wx, wz, wy)
		if is_front:
			last_surface_f = surf_kind
		else:
			last_surface_r = surf_kind
		var pal: Dictionary = PALETTES.get(surf_kind, PALETTES[SURF_GRAVEL])

		# Продольное тормозное усилие, насыщение сцепления, боковой снос и скольжение на корнях/мокром
		var b_force := maxf(b.brake_force.x if is_front else b.brake_force.y,
			b.brakes.front_force if is_front else b.brakes.rear_force)
		var grip_use := b.use_f if is_front else b.use_r
		var slick := b.slick_f if is_front else b.slick_r
		var lat_force := absf(b.force_f.y if is_front else b.force_r.y)

		var brake_ratio := clampf(b_force / (GameConfig.BIKE_BRAKE * (0.62 if is_front else 0.42)), 0.0, 1.4)
		var skid_ratio := clampf(b.brakes.skid * (0.85 if is_front else 1.15) + maxf(0.0, grip_use - 0.72) * 2.2, 0.0, 1.2)
		var drift_ratio := clampf(smoothstep(0.04, 0.24, absf(b.slip)) * (0.75 if is_front else 1.15) + lat_force / 7.5, 0.0, 1.2)
		var root_slip := clampf((1.0 - slick) * 1.8, 0.0, 1.0) * clampf(brake_ratio + drift_ratio, 0.0, 1.0)

		# На рыхлых покрытиях (песок, снег, гравий, вода) следы и брызги начинаются при меньшем усилии
		var loose_bonus := 0.22 if surf_kind in [SURF_SAND, SURF_SNOW, SURF_GRAVEL, SURF_WATER] else 0.0
		var intensity := clampf(
			maxf(brake_ratio * (0.55 + 0.65 * skid_ratio + loose_bonus), drift_ratio * 0.80) + root_slip * 0.35,
			0.0, 1.0
		) * smoothstep(0.45, 2.2, speed)

		if intensity < 0.12:
			_t_WasActive[wheel_idx] = false
			continue

		# Направление колеса (переднее повёрнуто на угол руля)
		var wheel_yaw := b.heading - (b.steer_shown() * BikeView.STEER_VIEW if is_front else 0.0)
		var w_fwd := Vector3(-sin(wheel_yaw), 0.0, -cos(wheel_yaw))
		var w_right := Vector3(cos(wheel_yaw), 0.0, -sin(wheel_yaw))

		var ground_y := h.surface_at(wx, wz, wy + 0.25)
		var contact_pos := Vector3(wx, ground_y, wz)
		var n_up := _ground_normal(h, wx, wz, ground_y)
		var side_vec := w_right - n_up * w_right.dot(n_up)
		if side_vec.length_squared() > 0.0001:
			side_vec = side_vec.normalized()
		else:
			side_vec = w_right
		# 1. Запись ленты следа / борозды на земле (на воде след не остаётся, кроме мокрого берега)
		if surf_kind != SURF_WATER and intensity > 0.2:
			# В заносе след расширяется поперечным скольжением протектора
			var track_w: float = float(pal.width) * (1.0 + 0.45 * clampf(drift_ratio + skid_ratio * 0.5, 0.0, 1.0))
			var track_col: Color = pal.track
			track_col.a *= TRACK_FADE
			_record_track(wheel_idx, contact_pos + n_up * 0.022, side_vec, track_w * 0.85, intensity, surf_kind, track_col)
		else:
			_t_WasActive[wheel_idx] = false

		# Вектор выброса из-под колеса вдоль поверхности склона: назад против хода + вбок от заноса
		var side_throw := clampf(b.lateral_speed * 0.45 + sin(b.slip) * speed * 0.55, -4.0, 4.0)
		var tangent_fwd := (w_fwd - n_up * w_fwd.dot(n_up)).normalized()
		var spray_dir := (-tangent_fwd * move_sign * (1.2 + speed * 0.32 * (0.5 + 0.7 * brake_ratio)) + side_vec * side_throw)

		# 2. Выброс твёрдых частиц (гравий, комья, песок, хвоя/листья, трава, снег, капли)
		var debris_rate := EFFECT_SCALE * intensity * (28.0 + 62.0 * clampf(skid_ratio + drift_ratio * 0.7 + loose_bonus, 0.0, 1.2))
		if surf_kind == SURF_WOOD:
			debris_rate *= 0.25 # на деревянном настиле почти нет камней, только мелкая щепа/пыль
		_emit_accum_d[wheel_idx] += debris_rate * dt
		var d_spawns := mini(6, int(_emit_accum_d[wheel_idx]))
		_emit_accum_d[wheel_idx] -= float(d_spawns)
		for k in d_spawns:
			_spawn_debris(contact_pos, n_up, spray_dir, side_vec, speed, intensity, pal, false)

		# 3. Искры: при жёстком торможении на камне или при раскалённом тормозном диске у калипера
		var rotor_heat := heat_f if is_front else heat_r
		var spark_rate := 0.0
		if surf_kind == SURF_STONE and intensity > 0.42 and speed > 3.5:
			spark_rate += (intensity - 0.35) * 26.0
		if rotor_heat > 0.38 and b_force > 1.5 and speed > 2.0:
			spark_rate += (rotor_heat - 0.35) * 38.0
		_spark_accum[wheel_idx] += spark_rate * dt
		var s_spawns := mini(5, int(_spark_accum[wheel_idx]))
		_spark_accum[wheel_idx] -= float(s_spawns)
		for k in s_spawns:
			var spark_origin := contact_pos + n_up * 0.04
			if rotor_heat > 0.40 and _rng.randf() < 0.72:
				# Искры прямо из тормозного калипера у диска (слева от колеса, -0.068 по X)
				spark_origin = contact_pos - side_vec * 0.068 + n_up * 0.36
			_spawn_debris(spark_origin, n_up, spray_dir * 1.15, side_vec, speed, clampf(intensity + rotor_heat * 0.5, 0.4, 1.0), pal, true)

		# 4. Клубы пыли, дыма резины, снежной пудры или водяного тумана
		var plume_rate := EFFECT_SCALE * intensity * (12.0 + 26.0 * clampf(skid_ratio + drift_ratio * 0.6 + loose_bonus, 0.0, 1.2))
		_emit_accum_p[wheel_idx] += plume_rate * dt
		var p_spawns := mini(3, int(_emit_accum_p[wheel_idx]))
		_emit_accum_p[wheel_idx] -= float(p_spawns)
		for k in p_spawns:
			_spawn_plume(contact_pos, n_up, tangent_fwd * move_sign, side_vec, side_throw, speed, intensity, pal)


## Определяет тип поверхности под колесом с учётом брода, настила моста, дорожного полотна и биома.
static func _classify_surface(w: WorldData, h: Heightfield, x: float, z: float, y: float) -> int:
	var deck := h.deck_at(x, z, y + 0.35)
	var ground := h.ground_at(x, z)
	if deck > ground + 0.05:
		return SURF_WOOD
	if h.depth_at(x, z, y) > 0.025:
		return SURF_WATER
	if w == null:
		return SURF_GRAVEL
	var sample := RideSurface.sample(w, h, x, z)
	var road_surf: int = sample.get("surface", RoadSurface.NONE)
	var weight: float = sample.get("weight", 0.0)
	if road_surf != RoadSurface.NONE and weight >= 0.35:
		match road_surf:
			RoadSurface.GRAVEL: return SURF_GRAVEL
			RoadSurface.DIRT: return SURF_DIRT
			RoadSurface.PACKED: return SURF_PACKED
			RoadSurface.STONE: return SURF_STONE
			RoadSurface.SAND: return SURF_SAND
			RoadSurface.FOREST: return SURF_FOREST
			RoadSurface.MEADOW: return SURF_MEADOW

	var cx := floori(x / GameConfig.TILE)
	var cz := floori(z / GameConfig.TILE)
	if cx >= 0 and cz >= 0 and cx < w.W and cz < w.H and w.biome.size() > 0:
		var idx := cz * w.W + cx
		var biome: int = w.biome[idx] if idx >= 0 and idx < w.biome.size() else Biomes.GRASS
		match biome:
			Biomes.SNOW, Biomes.PEAK:
				return SURF_SNOW
			Biomes.ROCK, Biomes.STONESHORE:
				return SURF_STONE
			Biomes.BEACH, Biomes.DESERT:
				return SURF_SAND
			Biomes.FOREST, Biomes.TAIGA, Biomes.JUNGLE, Biomes.SWAMP:
				return SURF_FOREST
			Biomes.GRASS, Biomes.SAVANNA, Biomes.STEPPE, Biomes.TUNDRA:
				return SURF_MEADOW
			_:
				return SURF_DIRT
	var info := w.tile_info(x / GameConfig.TILE, z / GameConfig.TILE)
	var b_fallback: int = info.get("biome", Biomes.GRASS)
	if b_fallback == Biomes.SNOW or b_fallback == Biomes.PEAK:
		return SURF_SNOW
	if b_fallback == Biomes.ROCK or b_fallback == Biomes.STONESHORE:
		return SURF_STONE
	if b_fallback == Biomes.BEACH or b_fallback == Biomes.DESERT:
		return SURF_SAND
	if b_fallback in [Biomes.FOREST, Biomes.TAIGA, Biomes.JUNGLE, Biomes.SWAMP]:
		return SURF_FOREST
	return SURF_DIRT


static func _ground_normal(h: Heightfield, x: float, z: float, center_y: float) -> Vector3:
	var eps := 0.25
	var hx := h.surface_at(x + eps, z, center_y + 0.4) - h.surface_at(x - eps, z, center_y + 0.4)
	var hz := h.surface_at(x, z + eps, center_y + 0.4) - h.surface_at(x, z - eps, center_y + 0.4)
	return Vector3(-hx, 2.0 * eps, -hz).normalized()


func _spawn_debris(origin: Vector3, n_up: Vector3, spray_dir: Vector3, w_right: Vector3, speed: float, intensity: float, pal: Dictionary, is_spark: bool) -> void:
	var i := _d_cursor
	_d_cursor = (_d_cursor + 1) % DEBRIS_COUNT

	var spread_side := w_right * _rng.randf_range(-0.85, 0.85) * (0.4 + intensity * 0.9)
	_d_pos[i] = origin + w_right * _rng.randf_range(-0.04, 0.04) + n_up * 0.025
	var up_kick := _rng.randf_range(0.85, 2.35) * (0.45 + 0.65 * intensity) * clampf(speed * 0.18, 0.4, 1.5)
	_d_vel[i] = spray_dir * _rng.randf_range(0.35, 0.85) + spread_side + n_up * up_kick
	_d_rot[i] = Vector3(_rng.randf() * TAU, _rng.randf() * TAU, _rng.randf() * TAU)
	_d_spin[i] = Vector3(_rng.randf_range(-14.0, 14.0), _rng.randf_range(-14.0, 14.0), _rng.randf_range(-14.0, 14.0))

	if is_spark:
		_d_scale[i] = Vector3(0.32, 0.32, 2.6) * _rng.randf_range(0.65, 1.25)
		_d_color[i] = Color(1.0, 0.78, 0.32, 1.0)
		_d_custom[i] = Color(0.0, 3.0, _rng.randf(), _rng.randf_range(0.85, 1.4))
		_d_max_life[i] = _rng.randf_range(0.18, 0.38)
		_d_bounce[i] = 0.62
	else:
		var base_sc: Vector3 = pal.debris_scale
		_d_scale[i] = base_sc * _rng.randf_range(0.55, 1.35) * (0.65 + 0.50 * intensity)
		var c1: Color = pal.debris1
		var c2: Color = pal.debris2
		_d_color[i] = c1.lerp(c2, _rng.randf())
		_d_custom[i] = Color(0.0, float(pal.debris_kind), _rng.randf(), 0.0)
		_d_max_life[i] = _rng.randf_range(0.32, 0.68) * (0.75 + 0.35 * intensity)
		_d_bounce[i] = float(pal.bounce)

	_d_life[i] = _d_max_life[i]
	_d_ground[i] = origin.y + 0.012
	_debris_mm.visible = true


func _spawn_plume(origin: Vector3, n_up: Vector3, move_dir: Vector3, w_right: Vector3, side_throw: float, speed: float, intensity: float, pal: Dictionary) -> void:
	var i := _p_cursor
	_p_cursor = (_p_cursor + 1) % PLUME_COUNT

	var side_offset := clampf(side_throw * 0.04, -0.14, 0.14) + _rng.randf_range(-0.07, 0.07)
	_p_pos[i] = origin - move_dir * _rng.randf_range(0.05, 0.22) + w_right * side_offset + n_up * (0.14 + 0.06 * intensity)
	_p_vel[i] = -move_dir * _rng.randf_range(0.25, 0.95) * (0.4 + 0.6 * intensity) \
		+ w_right * (side_throw * _rng.randf_range(0.12, 0.28) + _rng.randf_range(-0.28, 0.28)) \
		+ n_up * (_rng.randf_range(0.36, 0.92) * (0.5 + 0.6 * intensity))

	var base_s := (0.20 + 0.16 * intensity) * _rng.randf_range(0.85, 1.2)
	_p_size0[i] = base_s
	_p_size1[i] = base_s * _rng.randf_range(2.2, 3.5) * (1.0 + clampf(speed * 0.04, 0.0, 0.5))
	var col: Color = pal.plume
	_p_color[i] = Color(col.r * _rng.randf_range(0.92, 1.08), col.g * _rng.randf_range(0.92, 1.08), col.b * _rng.randf_range(0.92, 1.08), col.a)
	_p_custom[i] = Color(0.0, float(pal.plume_kind), _rng.randf(), clampf(0.55 + 0.75 * intensity, 0.30, 1.35))
	_p_max_life[i] = _rng.randf_range(0.48, 0.95) * (0.75 + 0.45 * intensity)
	_p_life[i] = _p_max_life[i]
	_plume_mm.visible = true


func _step_debris(dt: float) -> void:
	var any_alive := false
	var zero_xf := Transform3D(Basis.IDENTITY.scaled(Vector3.ZERO), Vector3.ZERO)
	for i in DEBRIS_COUNT:
		var rem := _d_life[i]
		if rem <= 0.0:
			continue
		rem -= dt
		if rem <= 0.0:
			_d_life[i] = 0.0
			_debris_mm.multimesh.set_instance_transform(i, zero_xf)
			continue
		any_alive = true
		_d_life[i] = rem
		var max_l := maxf(_d_max_life[i], 0.001)
		var age := clampf(1.0 - rem / max_l, 0.0, 1.0)

		_d_vel[i].y -= 12.5 * dt
		_d_vel[i] *= (1.0 - minf(0.9, 1.4 * dt))
		_d_pos[i] += _d_vel[i] * dt
		if _d_pos[i].y < _d_ground[i] and _d_vel[i].y < 0.0:
			_d_pos[i].y = _d_ground[i]
			_d_vel[i].y = -_d_vel[i].y * _d_bounce[i]
			_d_vel[i].x *= 0.65
			_d_vel[i].z *= 0.65

		_d_rot[i] += _d_spin[i] * dt
		var shrink := 1.0 - smoothstep(0.65, 1.0, age)
		var sc := _d_scale[i] * shrink
		var basis := Basis.from_euler(_d_rot[i]).scaled(sc)
		_debris_mm.multimesh.set_instance_transform(i, Transform3D(basis, _d_pos[i]))
		var c := _d_custom[i]
		c.r = age
		_d_custom[i] = c
		_debris_mm.multimesh.set_instance_color(i, _d_color[i])
		_debris_mm.multimesh.set_instance_custom_data(i, c)
	_debris_mm.visible = any_alive


func _step_plumes(dt: float) -> void:
	var any_alive := false
	var zero_xf := Transform3D(Basis.IDENTITY.scaled(Vector3.ZERO), Vector3.ZERO)
	for i in PLUME_COUNT:
		var rem := _p_life[i]
		if rem <= 0.0:
			continue
		rem -= dt
		if rem <= 0.0:
			_p_life[i] = 0.0
			_plume_mm.multimesh.set_instance_transform(i, zero_xf)
			continue
		any_alive = true
		_p_life[i] = rem
		var max_l := maxf(_p_max_life[i], 0.001)
		var age := clampf(1.0 - rem / max_l, 0.0, 1.0)

		# Клуб быстро тормозится в воздухе и медленно всплывает
		_p_vel[i] *= exp(-dt * 2.8)
		_p_vel[i].y += 0.18 * dt * (1.0 - age)
		_p_pos[i] += _p_vel[i] * dt

		var sz := lerpf(_p_size0[i], _p_size1[i], 1.0 - (1.0 - age) * (1.0 - age))
		_plume_mm.multimesh.set_instance_transform(i, Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * sz), _p_pos[i]))
		var c := _p_custom[i]
		c.r = age
		_p_custom[i] = c
		_plume_mm.multimesh.set_instance_color(i, _p_color[i])
		_plume_mm.multimesh.set_instance_custom_data(i, c)
	_plume_mm.visible = any_alive


func _record_track(w: int, pos: Vector3, right: Vector3, width: float, power: float, kind: int, color: Color) -> void:
	if _t_WasActive[w]:
		var step_d := pos.distance_to(_t_last_pos[w])
		if step_d < TRACK_STEP:
			return
		_t_total_dist[w] += step_d
	else:
		_t_total_dist[w] += TRACK_STEP

	var slot: int = (_t_head[w] + _t_count[w]) % TRACK_POINTS
	if _t_count[w] == TRACK_POINTS:
		_t_head[w] = (_t_head[w] + 1) % TRACK_POINTS
		# Новая голова цепочки не должна соединяться с исчезнувшей точкой перед ней
		_t_link[w][_t_head[w]] = 0
	else:
		_t_count[w] += 1

	_t_pos[w][slot] = pos
	_t_right[w][slot] = right
	_t_dist[w][slot] = _t_total_dist[w]
	_t_age[w][slot] = 0.0
	_t_width[w][slot] = width
	_t_power[w][slot] = clampf(power, 0.05, 0.99)
	_t_kind[w][slot] = kind
	_t_color[w][slot] = color
	_t_link[w][slot] = 1 if _t_WasActive[w] else 0

	_t_last_pos[w] = pos
	_t_WasActive[w] = true


func _step_tracks(dt: float) -> void:
	var has_segments := false
	for w in 2:
		var cnt: int = _t_count[w]
		var head: int = _t_head[w]
		for k in cnt:
			var idx := (head + k) % TRACK_POINTS
			_t_age[w][idx] += dt
		while _t_count[w] > 0 and _t_age[w][_t_head[w]] >= TRACK_LIFETIME:
			_t_head[w] = (_t_head[w] + 1) % TRACK_POINTS
			_t_count[w] -= 1
			if _t_count[w] > 0:
				_t_link[w][_t_head[w]] = 0
		if _t_count[w] >= 2:
			has_segments = true

	if not has_segments:
		_track_mesh.clear_surfaces()
		_track_node.visible = false
		_mesh_wait = 0.0
		return
	_mesh_wait += dt
	if _mesh_wait < MESH_STEP and _track_node.visible:
		return
	_mesh_wait = 0.0
	_track_mesh.clear_surfaces()
	_track_node.visible = true
	_track_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for w in 2:
		var cnt: int = _t_count[w]
		if cnt < 2:
			continue
		var head: int = _t_head[w]
		for k in range(1, cnt):
			var i1 := (head + k) % TRACK_POINTS
			if _t_link[w][i1] == 0:
				continue
			var i0 := (head + k - 1) % TRACK_POINTS
			var p0 := _t_pos[w][i0]
			var p1 := _t_pos[w][i1]
			var r0 := _t_right[w][i0] * (_t_width[w][i0] * 0.5)
			var r1 := _t_right[w][i1] * (_t_width[w][i1] * 0.5)

			var a0 := clampf(_t_age[w][i0] / TRACK_LIFETIME, 0.0, 1.0)
			var a1 := clampf(_t_age[w][i1] / TRACK_LIFETIME, 0.0, 1.0)
			# На концах разрыва ленты плавно сводим прозрачность к нулю
			var next_linked := (k + 1 < cnt) and (_t_link[w][(head + k + 1) % TRACK_POINTS] != 0)
			var prev_linked := _t_link[w][i0] != 0
			var c0 := _t_color[w][i0]
			var c1 := _t_color[w][i1]
			if not prev_linked:
				c0.a *= 0.25
			if not next_linked:
				c1.a *= 0.35

			var uv2_0 := Vector2(a0, float(_t_kind[w][i0]) + clampf(_t_power[w][i0], 0.02, 0.98))
			var uv2_1 := Vector2(a1, float(_t_kind[w][i1]) + clampf(_t_power[w][i1], 0.02, 0.98))
			var d0 := _t_dist[w][i0]
			var d1 := _t_dist[w][i1]

			var v00 := p0 - r0
			var v01 := p0 + r0
			var v10 := p1 - r1
			var v11 := p1 + r1

			# Два треугольника сегмента ленты
			_add_track_vertex(v00, Vector2(0.0, d0), uv2_0, c0)
			_add_track_vertex(v01, Vector2(1.0, d0), uv2_0, c0)
			_add_track_vertex(v10, Vector2(0.0, d1), uv2_1, c1)

			_add_track_vertex(v01, Vector2(1.0, d0), uv2_0, c0)
			_add_track_vertex(v11, Vector2(1.0, d1), uv2_1, c1)
			_add_track_vertex(v10, Vector2(0.0, d1), uv2_1, c1)
	_track_mesh.surface_end()


func _add_track_vertex(pos: Vector3, uv: Vector2, uv2: Vector2, col: Color) -> void:
	_track_mesh.surface_set_normal(Vector3.UP)
	_track_mesh.surface_set_color(col)
	_track_mesh.surface_set_uv(uv)
	_track_mesh.surface_set_uv2(uv2)
	_track_mesh.surface_add_vertex(pos)
