extends Node
## Купол облаков (16.11.2026) — замена прохода неба в половинном разрешении, которого нет в Compatibility.
## Облака неба зависят только от направления взгляда и параметров погоды, не от положения камеры, поэтому
## они считаются не для каждого пикселя экрана, а в текстуру развёртки верхней полусферы SIZE
## (resources/sky_cloud_dome.gdshader), по одной полосе из BANDS за кадр. Небо (resources/sky.gdshader)
## берёт из текстуры (C, T): col * T + C; солнце, луна, звёзды, градиент и сумерки остаются в полном разрешении.
## Цена облаков — примерно SIZE / BANDS пикселей за кадр, не зависит от разрешения экрана и ракурса.
## Облака за кадр сдвигаются меньше чем на тексель, поэтому обновление полосами незаметно; при скачке
## времени или солнца купол пересчитывается целиком. Включается низким качеством облаков (LightingQuality.apply_clouds:
## мета «cloud_dome» материала неба); без купола небо считает облака само для каждого пикселя.

const SHADER := preload("res://resources/sky_cloud_dome.gdshader")
const SIZE := Vector2i(2048, 512)
const BANDS := 8
const PARAMS := ["zenith_color", "horizon_color", "sun_dir", "sun_color", "halo", "moon_dir", "night",
	"cloud_color", "cloud_cover", "overcast_deck", "cumulus_steps", "cloud_time", "cloud_seed", "moon_phase"]

var sky_mat: ShaderMaterial
var _vp: SubViewport
var _rect: ColorRect
var _mat: ShaderMaterial
var _band := 0
var _on := false
var _full := true
var _last_time := NAN
var _last_sun := Vector3.ZERO
var _last_deck := -1.0


func _init(material: ShaderMaterial) -> void:
	sky_mat = material
	name = "SkyCloudDome"
	process_priority = 1000   # после DayCycle.apply: параметры погоды этого кадра


func _ready() -> void:
	_vp = SubViewport.new()
	_vp.size = SIZE
	_vp.disable_3d = true
	_vp.transparent_bg = true
	_vp.use_hdr_2d = true   # цвета облаков бывают ярче 1, а T нужна без полос
	_vp.render_target_clear_mode = SubViewport.CLEAR_MODE_NEVER
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_vp)
	_mat = ShaderMaterial.new()
	_mat.shader = SHADER
	_mat.set_shader_parameter("cloud_lite", true)   # облегчённый кучевой ярус, как на среднем качестве
	_rect = ColorRect.new()
	_rect.material = _mat
	_vp.add_child(_rect)
	sky_mat.set_shader_parameter("cloud_dome", _vp.get_texture())
	sky_mat.set_shader_parameter("cloud_dome_size", Vector2(SIZE))


func _exit_tree() -> void:
	sky_mat.set_shader_parameter("cloud_dome_on", false)


func _process(_delta: float) -> void:
	var want: bool = sky_mat.get_meta("cloud_dome", false)
	if want != _on:
		_on = want
		_full = true
		sky_mat.set_shader_parameter("cloud_dome_on", _on)
	if not _on:
		_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		return
	var t: float = sky_mat.get_shader_parameter("cloud_time")
	var sun: Vector3 = sky_mat.get_shader_parameter("sun_dir")
	var deck_v: Variant = sky_mat.get_shader_parameter("overcast_deck")
	var deck := float(deck_v) if deck_v != null else 0.0
	if is_nan(_last_time) or absf(t - _last_time) > 2.0 or sun.normalized().dot(_last_sun) < 0.9995 or absf(deck - _last_deck) > 0.001:
		_full = true
	# пауза: погода стоит — купол не пересчитывается
	if not _full and t == _last_time and sun.normalized() == _last_sun and absf(deck - _last_deck) <= 0.001:
		_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		return
	_last_time = t
	_last_sun = sun.normalized()
	_last_deck = deck
	for p: String in PARAMS:
		var v: Variant = sky_mat.get_shader_parameter(p)
		if v == null:
			continue
		_mat.set_shader_parameter(p, v)
	var rows := SIZE.y / BANDS
	if _full:
		_full = false
		_band = 0
		_rect.position = Vector2.ZERO
		_rect.size = Vector2(SIZE)
		_mat.set_shader_parameter("band_v0", 0.0)
		_mat.set_shader_parameter("band_vh", 1.0)
	else:
		_rect.position = Vector2(0.0, _band * rows)
		_rect.size = Vector2(SIZE.x, rows)
		_mat.set_shader_parameter("band_v0", float(_band * rows) / SIZE.y)
		_mat.set_shader_parameter("band_vh", float(rows) / SIZE.y)
		_band = (_band + 1) % BANDS
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
