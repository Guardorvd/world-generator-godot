shader_type spatial;
// 12.4: видимый конус света фары — дымка в воздухе перед фарой. Складывается с картинкой,
// края и конец тают, у земли и стволов исчезает плавно; на светлом фоне (днём) почти не виден.
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform vec3 tint : source_color = vec3(1.0, 0.9, 0.74);
uniform float strength = 0.09;
uniform float length_m = 9.0; // длина конуса (м), как у CylinderMesh.height
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

varying float along; // 0 у фары, 1 на дальнем конце

void vertex() {
	along = clamp(VERTEX.y / length_m + 0.5, 0.0, 1.0);
}

void fragment() {
	// край силуэта конуса гаснет: смотрим на поверхность вскользь — света почти нет
	float facing = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float rim = facing * facing * facing * facing;
	float a = clamp(along, 0.0, 1.0);
	float fade = smoothstep(0.0, 0.15, a) * (1.0 - a) * (1.0 - a);
	// у поверхностей за конусом свет тает за 0.8 м, без резкой линии пересечения
	float depth = texture(depth_tex, SCREEN_UV).r;
	vec4 scene = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float soft = clamp((-scene.z / scene.w + VERTEX.z) / 0.8, 0.0, 1.0);
	// у камеры тоже тает: изнутри конуса не видно стенок
	soft *= clamp((-VERTEX.z - 0.3) / 1.2, 0.0, 1.0);
	// видна в темноте: чем светлее фон, тем слабее дымка
	float bg = dot(texture(screen_tex, SCREEN_UV).rgb, vec3(0.3, 0.59, 0.11));
	float dark = 1.0 - smoothstep(0.04, 0.35, bg);
	ALBEDO = tint * strength * rim * fade * soft * dark;
}
