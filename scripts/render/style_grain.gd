class_name StyleGrain
extends MeshInstance3D
## Эффект «Зерно» визуального стиля: один полноэкранный четырёхугольник перед камерой, умножающий картинку мира
## на шум 1 − k·n (n — interleaved gradient noise, как в сетке порогов растительности). Шум привязан к пикселям экрана
## и не меняется во времени, поэтому не мерцает; умножение работает до тонмаппинга, так что в светах зерна меньше, в
## средних тонах больше, а чёрное остаётся чистым. Рисуется только в 3D-проходе: HUD и меню лежат в CanvasLayer выше.
## Узел — ребёнок камеры. Сила берётся у VisualStyle каждый кадр; при нуле узел скрыт и не стоит ничего.

const SHADER := preload("res://resources/style_grain.gdshader")
const DISTANCE := 0.35
var _applied := -1.0


func _init() -> void:
	name = "StyleGrain"
	# Обычный четырёхугольник перед камерой (переопределение POSITION в вершинном шейдере в Compatibility не рисуется).
	# 6 × 6 м на расстоянии 0,35 м закрывают кадр при любом поле зрения (до 100°) и любом соотношении сторон до 3:1.
	var quad := QuadMesh.new()
	quad.size = Vector2(6.0, 6.0)
	mesh = quad
	position = Vector3(0.0, 0.0, -DISTANCE)
	var material := ShaderMaterial.new()
	material.shader = SHADER
	material.render_priority = 127 # последним среди прозрачных: после воды, тумана и частиц
	material_override = material
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	extra_cull_margin = 16384.0
	ignore_occlusion_culling = true
	gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	visible = false


func _process(_delta: float) -> void:
	var k := VisualStyle.strength("grain")
	if is_equal_approx(k, _applied):
		return
	_applied = k
	visible = k > 0.0
	(material_override as ShaderMaterial).set_shader_parameter("amount", k)
