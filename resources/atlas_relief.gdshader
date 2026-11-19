shader_type canvas_item;
render_mode unshaded;

uniform sampler2D heights : filter_linear, repeat_disable;
uniform sampler2D biomes : filter_nearest, repeat_disable;
uniform sampler2D lakes : filter_nearest, repeat_disable;
uniform float height_scale;
uniform float beach_index;
uniform vec4 contour_ink : source_color = vec4(0.56, 0.48, 0.31, 1.0);

void fragment() {
	float h = texture(heights, UV).r * height_scale;
	float west = texture(heights, UV - vec2(TEXTURE_PIXEL_SIZE.x, 0.0)).r * height_scale;
	float north = texture(heights, UV - vec2(0.0, TEXTURE_PIXEL_SIZE.y)).r * height_scale;
	float gradient = fwidth(h);
	float land = step(beach_index - 0.5, texture(biomes, UV).r * 255.0)
		* (1.0 - step(0.5 / 255.0, texture(lakes, UV).r));
	float shade = clamp((west + north - 2.0 * h) * 0.012, -0.16, 0.10);
	float contour_distance = abs(fract(h / 15.0 + 0.5) - 0.5) * 15.0;
	float contour = 1.0 - smoothstep(max(0.16, gradient * 0.16), max(0.65, gradient * 0.66), contour_distance);
	contour *= smoothstep(0.02, 0.15, gradient) * (1.0 - smoothstep(7.5, 16.0, gradient));
	COLOR.rgb = mix(COLOR.rgb * (1.0 + land * shade), contour_ink.rgb, land * contour * 0.29);
}
