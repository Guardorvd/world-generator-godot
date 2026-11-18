shader_type canvas_item;
render_mode unshaded;

// 18.11.2026: подложка мини-карты рисуется в окно вдвое больше круга (LocalMap.MAP_SIZE) и перерисовывается
// только при сдвиге игрока дальше LocalMap.SHIFT_M. Каждый кадр меняется лишь сдвиг выборки view_offset.
uniform vec2 view_offset = vec2(0.25);
uniform float view_scale = 0.5;

void fragment() {
	COLOR = texture(TEXTURE, view_offset + UV * view_scale);
	float dist = length(UV - vec2(0.5));
	float aa = fwidth(dist);
	COLOR.a *= 1.0 - smoothstep(0.5 - aa, 0.5, dist);
}
