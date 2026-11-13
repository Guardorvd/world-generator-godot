// Зерно визуального стиля (scripts/render/style_grain.gd): неподвижный шум, затемняющий картинку мира до 3,5 % при полной силе.
// Чёрный с прозрачностью n·k равен умножению на (1 − n·k). Обычный blend_mix, а не blend_mul: в Compatibility с включённым свечением
// (glow) умножение даёт почти чёрный кадр.
shader_type spatial;
render_mode unshaded, blend_mix, depth_test_disabled, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

uniform float amount = 0.0;

void fragment() {
	// Interleaved gradient noise: почти синий спектр, без видимой решётки.
	float n = fract(52.9829189 * fract(dot(floor(FRAGCOORD.xy), vec2(0.06711056, 0.00583715))));
	ALBEDO = vec3(0.0);
	ALPHA = amount * 0.035 * n;
}
