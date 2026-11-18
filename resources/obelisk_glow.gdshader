shader_type spatial;
// 18.11.2026: ночная подсветка обелисков снизу (ObeliskModels.glow_node). Без источников света: сложение цвета поверх
// граней памятника (полосы «света» от фонаря вверх) и пятно у фонаря на земле. COLOR.a — вид: 1 — грань, 0.5 — пятно.
// UV.x — поперёк грани 0..1, UV.y — доля высоты подсветки 0..1 (у пятна UV — квадрат вокруг фонаря).
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform float night = 0.0;

void fragment() {
	float a;
	if (COLOR.a > 0.75) {
		float across = 1.0 - pow(abs(UV.x * 2.0 - 1.0), 2.5);
		a = across * pow(clamp(1.0 - UV.y, 0.0, 1.0), 1.7) * 0.6;
	} else {
		float r = length(UV * 2.0 - 1.0);
		a = (1.0 - smoothstep(0.0, 1.0, r)) * 0.4;
	}
	ALBEDO = COLOR.rgb * a * night;
}
