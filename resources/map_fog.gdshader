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
	COLOR = sum / weight;
}
