shader_type spatial;
render_mode cull_disabled;

// Один материал, одна выборка глубины. Отражение неба и солнца — штатный PBR.
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;
uniform bool ocean = false;
uniform bool river_surface = false;
// xz центра, возраст, сила; уровень отдельно, чтобы не задевать воду под мостом/на другом ярусе.
uniform vec4 disturbances[16];
uniform float disturbance_levels[16];
uniform vec3 shallow_color : source_color = vec3(0.22, 0.43, 0.38);
uniform vec3 deep_color : source_color = vec3(0.10, 0.27, 0.25);
varying vec3 world_position;

float hash(vec2 p) {
	vec3 q = fract(vec3(p.xyx) * 0.1031);
	q += dot(q, q.yzx + 33.33);
	return fract((q.x + q.y) * q.z);
}

// Значение и производные плавного шума: нерегулярная рябь без текстур.
vec3 ripple(vec2 p) {
	vec2 cell = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	vec2 du = 6.0 * f * (1.0 - f);
	float a = hash(cell);
	float b = hash(cell + vec2(1.0, 0.0));
	float c = hash(cell + vec2(0.0, 1.0));
	float d = hash(cell + vec2(1.0, 1.0));
	return vec3(mix(mix(a, b, u.x), mix(c, d, u.x), u.y),
		mix(b - a, d - c, u.y) * du.x, mix(c - a, d - b, u.x) * du.y);
}

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float river = river_surface ? 1.0 : 0.0;
	vec2 direction = river > 0.5 ? normalize(UV + vec2(0.00001)) : normalize(vec2(0.8, 0.35));
	vec2 across = vec2(-direction.y, direction.x);
	float speed = river > 0.5 ? mix(0.3, 2.8, COLOR.r) : 0.12;
	float rapid = river * COLOR.g;
	vec2 p = vec2(dot(world_position.xz, across), dot(world_position.xz, direction));
	vec2 drift = vec2(p.x, p.y - TIME * speed);
	vec3 small = ripple(drift * vec2(2.7, 1.8));
	vec3 broad = ripple(drift * vec2(0.75, 0.9) + vec2(17.2, 9.4));
	// Только нормали: берег, уровень воды и игровая глубина остаются согласованы.
	float distance_to_eye = length(VERTEX);
	float detail = 1.0 - smoothstep(55.0, 210.0, distance_to_eye);
	float strength = mix(0.045, 0.13, rapid) * detail;
	float antialias = 1.0 - smoothstep(0.15, 0.8, max(length(dFdx(drift)), length(dFdy(drift))));
	float broad_antialias = 1.0 - smoothstep(0.4, 1.6, max(length(dFdx(drift)), length(dFdy(drift))));
	vec2 gradient = (small.yz * vec2(2.7, 1.8) * antialias + broad.yz * 0.8 * broad_antialias) * strength;
	vec2 wake_gradient = vec2(0.0);
	float wake_foam = 0.0;
	for (int i = 0; i < 16; i++) {
		vec4 event = disturbances[i];
		float age = event.z;
		float fade = max(0.0, 1.0 - age / 1.6) * event.w;
		fade *= 1.0 - smoothstep(0.08, 0.3, abs(world_position.y - disturbance_levels[i]));
		if (fade <= 0.001) { continue; }
		vec2 delta = world_position.xz - event.xy;
		float radius = length(delta);
		float front = radius - (0.12 + age * 1.45);
		float envelope = exp(-front * front * 32.0) * fade * detail;
		wake_gradient += delta / max(radius, 0.01) * sin(front * 24.0) * envelope * 0.18;
		wake_foam = max(wake_foam, envelope * exp(-age * 4.0) * 0.45);
	}
	vec3 base_normal = (INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz;
	vec3 normal_world = normalize(base_normal + vec3(-across.x * gradient.x - direction.x * gradient.y, 0.0,
		-across.y * gradient.x - direction.y * gradient.y));

	float depth = textureLod(depth_texture, SCREEN_UV, 0.0).r;
	#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
		vec3 ndc = vec3(SCREEN_UV, depth) * 2.0 - 1.0;
	#else
		vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);
	#endif
	vec4 behind = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	behind /= behind.w;
	vec3 ground = (INV_VIEW_MATRIX * behind).xyz;
	float thickness = max(0.0, world_position.y - ground.y);
	float absorption = 1.0 - exp(-thickness * 1.15);
	float shoal = 1.0 - smoothstep(0.18, 1.2, thickness);
	// Пересечения с видимыми камнями, опорами и берегом: дробящаяся рябь в мелкой воде.
	// Используем ту же выборку глубины, без списка препятствий и дополнительных проходов.
	float contact = (1.0 - smoothstep(0.04, 0.5, thickness)) * smoothstep(0.0, 0.035, thickness);
	float turbulence = contact * mix(0.12, 0.8, river) * (0.4 + 0.6 * broad.x) * detail;
	vec2 contact_gradient = small.yz * turbulence * 0.12 * antialias;
	vec2 interaction = wake_gradient + across * contact_gradient.x + direction * contact_gradient.y;
	normal_world = normalize(normal_world - vec3(interaction.x, 0.0, interaction.y));
	NORMAL = normalize((VIEW_MATRIX * vec4(normal_world, 0.0)).xyz);
	if (!FRONT_FACING) { NORMAL = -NORMAL; }
	// Пятна пены движутся вниз, перекаты возникают на мелком крутом русле.
	float crest = smoothstep(0.55, 0.78, small.x) * smoothstep(0.3, 0.65, broad.x) * antialias;
	float riffle = rapid * mix(0.3, 1.0, shoal);
	float foam = crest * riffle * 0.72 * detail;
	float shore = (1.0 - smoothstep(0.02, 0.18, thickness)) * smoothstep(0.0, 0.035, thickness);
	foam = max(foam, shore * crest * mix(0.08, 0.24, rapid) * detail);
	foam = max(foam, max(wake_foam, turbulence * crest * 0.6));
	vec3 deep = ocean ? vec3(0.045, 0.15, 0.23) : deep_color;
	ALBEDO = mix(mix(shallow_color, deep, absorption), vec3(0.80, 0.87, 0.82), foam);
	METALLIC = 0.0;
	// Микроблики остаются только вблизи. Одной шероховатости 0.5 было мало:
	// вдали плоская нормаль всё ещё давала большие круглые пятна от источников света.
	float far_rough = smoothstep(55.0, 220.0, distance_to_eye);
	ROUGHNESS = mix(mix(mix(0.24, 0.36, rapid), 0.88, far_rough), 0.65, foam);
	SPECULAR = 0.4 * (1.0 - smoothstep(45.0, 180.0, distance_to_eye));
	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 5.0);
	float bank = river > 0.5 ? smoothstep(0.0, 0.045, min(UV2.x, 1.0 - UV2.x)) : 1.0;
	float join = river_surface ? 1.0 - COLOR.b : 1.0;
	ALPHA = smoothstep(0.0, 0.08, thickness) * bank * join * clamp(0.38 + absorption * 0.56 + fresnel * 0.22 + foam * 0.4, 0.0, 0.97);
}
