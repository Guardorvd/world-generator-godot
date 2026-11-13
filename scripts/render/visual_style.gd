class_name VisualStyle
extends RefCounted
## Цельный визуальный стиль (13.11.2026): спокойная, чуть живописная картинка, а не фотореализм.
## Четыре независимых эффекта, у каждого выключатель и сила 0..1; при выключении или нуле эффект исчезает полностью:
##  grade      — цветокоррекция: процедурный 3D LUT в Environment.adjustment_color_correction (после тонмаппинга);
##               золотистые света, слегка прохладные тени, спокойная многотональная зелень. Серая ось и небо не красятся.
##  depth      — разделение планов: общая функция resources/depth_tone.gdshaderinc в шейдерах рельефа, растительности
##               и дальнего леса (по расстоянию от камеры, поэтому швов LOD нет); цвет дымки берёт у DayCycle.
##  highlights — мягкое сжатие светов: тонмаппер AgX вместо ACES с подобранной выдержкой, насыщенностью и контрастом.
##               ACES красит яркий свет в жёлто-оранжевый и срезает его; AgX уводит свет в белый плавно.
##  grain      — лёгкое неподвижное зерно (StyleGrain), без мерцания.
## Цвета неба, света и тумана остаются в DayCycle: здесь только пост-обработка поверх него (DayCycle спрашивает
## exposure_scale() и saturation_scale()), своей палитры нет. Эффекты действуют на 3D-мир; HUD и меню — отдельный слой.
## Состояние статическое: настройки меняются в меню на паузе и применяются сразу, мир подписывается через bind().

const EFFECTS := ["grade", "depth", "highlights", "grain"]
const TITLES := {grade = "Цветокоррекция", depth = "Планы", highlights = "Мягкие света", grain = "Зерно"}
const HINTS := {
	grade = "Золотистые света, прохладные тени и спокойная зелень. Небо, свет и биомы остаются своими.",
	depth = "Ближние предметы чуть контрастнее, дальние мягче и прохладнее; горы и дороги читаются.",
	highlights = "Яркий свет уходит в белый плавно, без жёлтой пересветки и срезанных пятен.",
	grain = "Едва заметное неподвижное зерно: сглаживает полосы в небе, не мерцает.",
}
const DEFAULT_ON := {grade = true, depth = true, highlights = true, grain = true}
const DEFAULT_AMOUNT := {grade = 0.7, depth = 0.65, highlights = 0.7, grain = 0.4}

const LUT_SIZE := 32
const LUT_STEPS := 24          # сила LUT округляется до 1/24: кэш из 25 текстур, а не пересчёт на каждый шаг ползунка
const ACES_WHITE := 6.0        # как в scenes/game_world.tscn
const TONEMAP_ACES := 3

static var on: Dictionary = DEFAULT_ON.duplicate()
static var amount: Dictionary = DEFAULT_AMOUNT.duplicate()

static var _env: Environment
static var _graded: PackedFloat32Array  # LUT на полной силе (r, g, b подряд)
static var _lut_cache: Dictionary = {}
static var _lut_step := -1
static var _day_exposure := -1.0   # выдержка и насыщенность DayCycle без стиля (для привязанного окружения):
static var _day_saturation := 1.0  # на паузе DayCycle стоит, и refresh() пересчитывает их сам


## Сила эффекта, 0 если выключен
static func strength(id: String) -> float:
	return clampf(float(amount.get(id, 0.0)), 0.0, 1.0) if bool(on.get(id, false)) else 0.0


## Принять настройки (словари с ключами EFFECTS) и применить к привязанному окружению и глобальным параметрам
static func configure(new_on: Dictionary, new_amount: Dictionary) -> void:
	for id: String in EFFECTS:
		on[id] = bool(new_on.get(id, DEFAULT_ON[id]))
		amount[id] = clampf(float(new_amount.get(id, DEFAULT_AMOUNT[id])), 0.0, 1.0)
	refresh()


## Окружение мира: привязывается при запуске игры и применяется при каждой смене настроек
static func bind(env: Environment) -> void:
	if env != _env:
		_day_exposure = -1.0
	_env = env
	refresh()


## Мир закрыт: всё возвращается в нейтральное состояние (глобальные параметры шейдеров, окружение)
static func release() -> void:
	_reset_environment()
	_env = null
	_day_exposure = -1.0
	RenderingServer.global_shader_parameter_set("style_depth", Vector4.ZERO)


## Множитель выдержки поверх DayCycle: AgX темнее/светлее ACES в средних тонах, поэтому нужна поправка
static func exposure_scale() -> float:
	if _env == null:
		return 1.0 # мир не привязан: DayCycle в инструментах со своим окружением (ACES) не трогаем
	# зерно в среднем темнит на половину своей амплитуды (StyleGrain): яркость сохраняется
	var grain_mean := 1.0 - 0.0175 * strength("grain")
	return _agx_exposure(strength("highlights")) / grain_mean


## Множитель насыщенности поверх DayCycle: AgX сам обесцвечивает света, часть краски возвращается
static func saturation_scale() -> float:
	var k := strength("highlights") if _env != null else 0.0
	return 1.0 if k <= 0.0 else lerpf(1.1, 1.28, k)


## Параметры AgX подобраны в tools/style_look.gd --tonemap так, чтобы средняя яркость совпадала с ACES (по четырём состояниям
## в пределах 2 %), а света уходили в белый плавно. Сила 0,7 (по умолчанию): контраст 1,4, белая точка 13, выдержка ×1,25.
static func _agx_exposure(k: float) -> float:
	return 1.0 if k <= 0.0 else lerpf(1.12, 1.3, k)


## Выдержка и насыщенность от DayCycle (каждый кадр) с множителями стиля
static func apply_day(env: Environment, exposure: float, saturation: float) -> void:
	if env == _env:
		_day_exposure = exposure
		_day_saturation = saturation
	env.tonemap_exposure = exposure * exposure_scale()
	env.adjustment_saturation = saturation * saturation_scale()


## Дымка дальнего плана: цвет горизонта из DayCycle
static func set_haze(color: Color) -> void:
	RenderingServer.global_shader_parameter_set("style_haze", Vector3(color.r, color.g, color.b))


## Применить текущие настройки: LUT, тонмаппер, параметры шейдеров
static func refresh() -> void:
	var depth := strength("depth") if _env != null else 0.0 # без мира (меню, Trail Lab) шейдеры остаются нейтральными
	RenderingServer.global_shader_parameter_set("style_depth",
		Vector4(depth, depth, depth, 1.0) if depth > 0.0 else Vector4.ZERO)
	if _env == null:
		return
	_apply_grade(strength("grade"))
	_apply_highlights(strength("highlights"))
	# 13.11.2026: тонмаппер меняется сразу, а выдержку раньше ставил только следующий DayCycle.apply —
	# на паузе (меню графики) картинка была то темнее, то светлее, пока игра не продолжится.
	if _day_exposure >= 0.0:
		_env.tonemap_exposure = _day_exposure * exposure_scale()
		_env.adjustment_saturation = _day_saturation * saturation_scale()


static func _reset_environment() -> void:
	if _env == null:
		return
	_env.adjustment_color_correction = null
	_apply_highlights(0.0)


static func _apply_grade(k: float) -> void:
	_env.adjustment_enabled = true
	if k <= 0.0:
		_env.adjustment_color_correction = null
		return
	var step := clampi(roundi(k * LUT_STEPS), 1, LUT_STEPS)
	if step == _lut_step and _env.adjustment_color_correction != null:
		return
	_lut_step = step
	if not _lut_cache.has(step):
		_lut_cache[step] = _build_lut(float(step) / LUT_STEPS)
	_env.adjustment_color_correction = _lut_cache[step]


static func _apply_highlights(k: float) -> void:
	if k <= 0.0:
		_env.tonemap_mode = TONEMAP_ACES
		_env.tonemap_white = ACES_WHITE
		return
	_env.tonemap_mode = Environment.TONE_MAPPER_AGX
	_env.tonemap_agx_white = lerpf(20.0, 10.0, k)
	_env.tonemap_agx_contrast = lerpf(1.15, 1.5, k)


# ---------- 3D LUT ----------

## Цветокоррекция одного цвета (sRGB после тонмаппинга) на полной силе
static func grade_color(c: Color) -> Color:
	var luma := c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722
	var hi := maxf(c.r, maxf(c.g, c.b))
	var lo := minf(c.r, minf(c.g, c.b))
	var chroma := (hi - lo) / maxf(hi, 0.0001)
	# 1. Прохладные тени: тёмные участки чуть уходят в сине-зелёный; нейтральный серый середины не трогается.
	var shadow := pow(1.0 - smoothstep(0.0, 0.5, luma), 1.4)
	var rgb := Vector3(c.r, c.g, c.b) * Vector3.ONE.lerp(Vector3(0.93, 0.99, 1.065), shadow)
	# 2. Золотистые света, только у окрашенных поверхностей: белые облака, снег и небо остаются нейтральными.
	var gold := smoothstep(0.35, 0.85, luma) * smoothstep(0.05, 0.3, chroma)
	rgb *= Vector3.ONE.lerp(Vector3(1.055, 1.016, 0.915), gold)
	var out := Color(rgb.x, rgb.y, rgb.z)
	# 3. Зелень: на свету к жёлто-оливковому, в тени к сине-зелёному, самая кричащая приглушается.
	var h := out.h * 360.0
	var green := smoothstep(62.0, 92.0, h) * (1.0 - smoothstep(150.0, 180.0, h))
	if green > 0.0 and out.s > 0.0:
		var warm := smoothstep(0.12, 0.7, luma)
		var shift := lerpf(10.0, -8.0, warm) * green
		var sat := out.s * (1.0 - 0.24 * smoothstep(0.5, 0.95, out.s) * green)
		out = Color.from_hsv(fposmod(h + shift, 360.0) / 360.0, sat, out.v)
	# 4. Светлота остаётся прежней: оттенок и насыщенность меняются, яркость нет.
	var new_luma := out.r * 0.2126 + out.g * 0.7152 + out.b * 0.0722
	if new_luma > 0.0001:
		var k := luma / new_luma
		out = Color(out.r * k, out.g * k, out.b * k)
	return Color(clampf(out.r, 0.0, 1.0), clampf(out.g, 0.0, 1.0), clampf(out.b, 0.0, 1.0))


## Godot берёт цвет кадра как координату текстуры LUT без сдвига на полтекселя: тексель i лежит в (i + 0,5) / N.
## Поэтому тексель хранит результат для центра своей ячейки, и тождественный LUT остаётся тождественным в средних тонах
## (tools/style_look.gd --checks). Крайние тексели хранят чистые чёрный и белый: иначе все цвета темнее 0,5/N (4/255)
## стали бы одним серым — ночь «поседела» бы. Цена: самые тёмные тона (4–12/255) чуть темнее, света у 252–255 чуть раньше белеют.
static func _lut_input(i: int) -> float:
	if i <= 0:
		return 0.0
	if i >= LUT_SIZE - 1:
		return 1.0
	return (float(i) + 0.5) / float(LUT_SIZE)


static func _build_lut(k: float) -> ImageTexture3D:
	if _graded.is_empty():
		_graded.resize(LUT_SIZE * LUT_SIZE * LUT_SIZE * 3)
		var at := 0
		for b in LUT_SIZE:
			for g in LUT_SIZE:
				for r in LUT_SIZE:
					var out := grade_color(Color(_lut_input(r), _lut_input(g), _lut_input(b)))
					_graded[at] = out.r
					_graded[at + 1] = out.g
					_graded[at + 2] = out.b
					at += 3
	var slices: Array[Image] = []
	var bytes_per_slice := LUT_SIZE * LUT_SIZE * 3
	for b in LUT_SIZE:
		var data := PackedByteArray()
		data.resize(bytes_per_slice)
		var at := b * bytes_per_slice
		var write := 0
		for g in LUT_SIZE:
			for r in LUT_SIZE:
				var src := Vector3(_lut_input(r), _lut_input(g), _lut_input(b))
				for ch in 3:
					var v := lerpf(src[ch], _graded[at], k)
					data[write] = clampi(roundi(v * 255.0), 0, 255)
					write += 1
					at += 1
		slices.append(Image.create_from_data(LUT_SIZE, LUT_SIZE, false, Image.FORMAT_RGB8, data))
	var texture := ImageTexture3D.new()
	texture.create(Image.FORMAT_RGB8, LUT_SIZE, LUT_SIZE, LUT_SIZE, false, slices)
	return texture
