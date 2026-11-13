shader_type spatial;
render_mode cull_back, specular_disabled, shadows_disabled;
global uniform vec2 veg_center;
global uniform vec4 distant_vegetation; // near end, near fade band, far end, enabled
#include "res://resources/cloud_shadow.gdshaderinc"
// Must match distant_forest.gd.
const float SPLIT = 620.0;
const float SPLIT_BAND = 60.0;
const float SCRUB_BEGIN = 150.0;
const float SCRUB_BAND = 90.0;
const float SCRUB_END = 950.0;
// Per instance: fragments are kept while keep_lo <= dither < keep_hi. Neighbouring rings use complementary
// windows, so where fine crowns hand over to coarse clumps each pixel is drawn by one of them only.
varying flat float keep_lo;
varying flat float keep_hi;
varying flat float stuff;
varying flat float lobe_tone;
varying float canopy_light;
varying float body_height;
varying float lobe_height;

float hash12(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	float d = length(origin.xz - veg_center);
	float kind = INSTANCE_CUSTOM.x;
	float trees = INSTANCE_CUSTOM.y;
	stuff = INSTANCE_CUSTOM.z;
	canopy_light = cloud_light(origin.xz);
	float near_keep = clamp((distant_vegetation.x - d) / max(distant_vegetation.y, 1.0), 0.0, 1.0);
	float far_keep = 1.0 - smoothstep(distant_vegetation.z - 180.0, distant_vegetation.z, d);
	float split = clamp((d - (SPLIT - SPLIT_BAND * 0.5)) / SPLIT_BAND, 0.0, 1.0);
	if (kind < 0.5) {
		keep_lo = max(near_keep, split);
		keep_hi = far_keep;
	} else if (kind < 1.5) {
		keep_lo = near_keep;
		keep_hi = min(split, far_keep);
	} else {
		float end = min(distant_vegetation.z, SCRUB_END);
		keep_lo = clamp((SCRUB_BEGIN + SCRUB_BAND - d) / SCRUB_BAND, 0.0, 1.0);
		keep_hi = 1.0 - smoothstep(end - 150.0, end, d);
	}
	// Lobe data: UV — lobe centre (x, z); UV2.x — index * 4 + centre y + 1; UV2.y — lobe-local height (-0.7..1).
	float index = floor(UV2.x * 0.25);
	vec3 centre = vec3(UV.x, mod(UV2.x, 4.0) - 1.0, UV.y);
	lobe_height = UV2.y;
	body_height = VERTEX.y;
	float seed = hash12(origin.xz * 0.37 + index * 7.13);
	lobe_tone = seed;
	// Lone trees and small groups show one or two lobes; scrub thickets one to three.
	float lobes = kind > 1.5 ? 1.0 + floor(hash12(origin.zx * 0.71) * 2.99) : (kind > 0.5 ? 4.0 : clamp(trees, 1.0, 3.0));
	vec3 v = VERTEX - centre;
	if (lobes < 1.5) {
		// A single crown fills the box: the main lobe grows, the others vanish below.
		v *= vec3(1.4, 1.05, 1.4);
		centre = vec3(0.0, centre.y * 0.5, 0.0);
	}
	// Height variety per lobe: uneven canopy line instead of equal mounds.
	float grow = mix(0.78, 1.22, seed);
	v.y *= grow;
	centre.y += (grow - 1.0) * 0.35;
	float up = clamp((lobe_height + 0.7) / 1.7, 0.0, 1.0);
	float conifer = stuff > 0.5 ? 0.0 : COLOR.a;
	float lump = hash12(origin.xz * 0.53 + VERTEX.xz * 5.3 + VERTEX.y * 3.1) - 0.5;
	float rock = step(0.5, stuff);
	// Conifers: each lobe becomes a narrow spire; broadleaf lobes get a ragged outline; boulders stay compact.
	v.xz *= mix(mix(1.0 + lump * 0.38, mix(1.05, 0.1, up), conifer), 1.0 + lump * 0.12, rock);
	v.y *= 1.0 + conifer * 0.25;
	VERTEX = centre + v;
	bool hidden = index >= lobes || keep_lo >= keep_hi || distant_vegetation.w < 0.5;
	if (hidden) VERTEX = vec3(0.0); // degenerate: nothing rasterised
}

void fragment() {
	float dither = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
	if (dither < keep_lo || dither >= keep_hi) discard;
	float under = mix(0.55, 1.0, smoothstep(-0.7, 0.6, lobe_height)) * mix(0.78, 1.0, smoothstep(-1.0, 0.4, body_height));
	if (stuff > 0.5) {
		ALBEDO = COLOR.rgb * mix(0.8, 1.0, smoothstep(-0.7, 0.6, lobe_height)) * mix(0.9, 1.05, lobe_tone);
		ROUGHNESS = 0.95;
	} else {
		// Mean leaf-texture reflectance: plain instance tint alone makes solid crowns too bright.
		// Lobes of one cluster differ a little in tone and hue (mixed stands, light and shade).
		vec3 tone = COLOR.rgb * vec3(1.0 + (lobe_tone - 0.5) * 0.14, 1.0, 1.0 - (lobe_tone - 0.5) * 0.2) * mix(0.88, 1.1, lobe_tone);
		ALBEDO = tone * 0.5 * under;
		ROUGHNESS = 1.0;
	}
	AO = mix(0.65, 1.0, smoothstep(-0.7, 0.6, lobe_height));
}

// Как у земли и ближних деревьев: тень облака гасит только прямое солнце, свет неба остаётся.
void light() {
	float visibility = ATTENUATION * (LIGHT_IS_DIRECTIONAL ? canopy_light : 1.0);
	DIFFUSE_LIGHT += vec3(max(dot(NORMAL, LIGHT), 0.0)) * LIGHT_COLOR * visibility / PI;
}
