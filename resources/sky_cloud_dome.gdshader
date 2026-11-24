// Купол облаков (16.11.2026): считает облака неба (sky_clouds.gdshaderinc) в текстуру развёртки верхней
// полусферы — полосу band_v0..band_v0 + band_vh за кадр. Небо (sky.gdshader) берёт из неё (C, T).
// Параметры те же, что у неба, и с теми же подсказками (source_color): движок переводит цвета так же, как для неба.
shader_type canvas_item;
render_mode blend_disabled, unshaded;

uniform vec3 zenith_color : source_color = vec3(0.32, 0.52, 0.82);
uniform vec3 horizon_color : source_color = vec3(0.62, 0.74, 0.88);
uniform vec3 sun_dir = vec3(0.0, 0.7, 0.7);
uniform vec3 sun_color : source_color = vec3(1.0, 0.93, 0.8);
uniform float halo = 0.3;
uniform vec3 moon_dir = vec3(0.0, -0.7, -0.7);
uniform float night = 0.0;
uniform vec3 cloud_color : source_color = vec3(1.0);
uniform float cloud_cover = 0.4;
uniform float overcast_deck = 0.0;
uniform int cumulus_steps = 5;
uniform bool cloud_lite = false;
uniform float cloud_time = 0.0;
uniform float cloud_seed = 0.0;
uniform float moon_phase = 0.5;
uniform float band_v0 = 0.0;
uniform float band_vh = 1.0;

#include "res://resources/sky_clouds.gdshaderinc"

void fragment() {
	vec2 uv = vec2(UV.x, band_v0 + UV.y * band_vh);
	vec3 d = cloud_dome_dir(uv);
	COLOR = d.y > 0.005 ? sky_clouds(d) : vec4(0.0, 0.0, 0.0, 1.0);
}
