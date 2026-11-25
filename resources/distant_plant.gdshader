shader_type spatial;
render_mode cull_disabled, specular_disabled, shadows_disabled;

global uniform vec2 veg_center;
global uniform vec4 distant_vegetation;
uniform sampler2D leaves : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D needles : source_color, filter_linear_mipmap, repeat_disable;

#include "res://resources/distant_vegetation.gdshaderinc"
#include "res://resources/cloud_shadow.gdshaderinc"
#include "res://resources/depth_tone.gdshaderinc"

varying flat float keep_lo;
varying flat float keep_hi;
varying flat float material_kind;
varying flat float cloud;
varying float plant_height;

// DistantForest.PlantClass in INSTANCE_CUSTOM.x.
const int BUSH = 1;
const int SCRUB = 2;
const int GRASS = 3;

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	float dist = length(origin.xz - veg_center);
	int kind = int(INSTANCE_CUSTOM.x);
	float rank = INSTANCE_CUSTOM.y;
	bool outer = INSTANCE_CUSTOM.z > 0.5;
	bool grass = kind == GRASS;
	bool scrub = kind == SCRUB || grass;
	bool small = kind == BUSH || scrub;
	keep_lo = distant_veg_near(dist, scrub, grass);
	keep_hi = distant_veg_end(dist, outer, scrub, small);
	float density = distant_veg_density(dist, small);
	keep_hi = min(keep_hi, 1.0 - smoothstep(rank, rank + 0.14, 1.0 - density));
	keep_hi = mix(keep_lo, keep_hi, distant_veg_reveal());
	material_kind = UV2.x;
	plant_height = VERTEX.y;
	cloud = 1.0;
	if (keep_lo >= keep_hi || distant_vegetation.w < 0.5) {
		VERTEX = vec3(0.0);
	} else {
		if (INSTANCE_CUSTOM.w > 0.5) {
			bool young = INSTANCE_CUSTOM.w < 1.5;
			VERTEX.y = VERTEX.y * (young ? 1.13 : 0.88) + (young ? -0.13 : 0.12) * smoothstep(0.0, 0.3, VERTEX.y);
		}
		cloud = cloud_light(origin.xz);
	}
}

void fragment() {
	float dither = distant_veg_dither(FRAGCOORD.xy);
	if (dither < keep_lo || dither >= keep_hi) discard;
	vec3 color = COLOR.rgb;
	if (!OUTPUT_IS_SRGB) {
		color = mix(pow((color + 0.055) / 1.055, vec3(2.4)), color / 12.92, lessThan(color, vec3(0.04045)));
	}
	if (material_kind < 0.5) {
		color = mix(vec3(0.055, 0.04, 0.026), vec3(0.14, 0.11, 0.078), smoothstep(0.0, 0.8, plant_height));
	} else {
		bool grass = material_kind > 2.5;
		vec2 uv = grass ? vec2(UV.x * 1.75, UV.y * 0.65 + 0.17) : UV;
		if (grass) uv.x = fract(uv.x);
		vec4 leaf;
		if (material_kind > 1.5 && !grass) {
			leaf = texture(needles, uv);
		} else {
			leaf = texture(leaves, uv);
		}
		if (leaf.a < (grass ? 0.36 : 0.46)) discard;
		float shade = mix(0.57, 1.0, smoothstep(0.07, 0.94, plant_height));
		color *= mix(0.55, 0.96, leaf.r) * shade;
	}
	ALBEDO = depth_tone(color, length(VERTEX));
	AO = mix(0.70, 1.0, clamp(plant_height, 0.0, 1.0));
	ROUGHNESS = 1.0;
}

void light() {
	float visibility = ATTENUATION * (LIGHT_IS_DIRECTIONAL ? cloud : 1.0);
	float diffuse = dot(NORMAL, LIGHT);
	float leaf = step(0.5, material_kind);
	float transmit = max(-diffuse, 0.0) * leaf * 0.14;
	DIFFUSE_LIGHT += vec3(max(diffuse, 0.0) + transmit) * LIGHT_COLOR * visibility / PI;
}
