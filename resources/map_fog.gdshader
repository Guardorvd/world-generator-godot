shader_type canvas_item;
// 18.11.2026: бумага поверх неисследованного на личной карте (WorldMapView._fog). Маска грубая (16 м на пиксель),
// размытие 5×5 делает край мягким, как размытая акварель на карте нацпарка
uniform vec2 texel = vec2(0.005);

void fragment() {
	vec4 sum = vec4(0.0);
	float weight = 0.0;
	for (int x = -2; x <= 2; x++) {
		for (int y = -2; y <= 2; y++) {
			float k = 1.0 / (1.0 + float(x * x + y * y));
			sum += texture(TEXTURE, UV + vec2(float(x), float(y)) * texel * 1.4) * k;
			weight += k;
		}
	}
	vec4 paper = sum / weight;
	// World-anchored, restrained engraving on closed paper; it disappears with the mask.
	vec2 cell = UV / texel;
	float hatch = smoothstep(0.86, 0.98, sin((cell.x + cell.y) * 1.15));
	float grain = fract(sin(dot(floor(cell * 2.0), vec2(12.9898, 78.233))) * 43758.5453);
	float edge = min(min(UV.x, UV.y), min(1.0 - UV.x, 1.0 - UV.y));
	float fade = smoothstep(0.0, 0.08, edge);
	paper.rgb *= 1.0 - fade * (0.018 * hatch + 0.012 * grain);
	COLOR = paper;
}
