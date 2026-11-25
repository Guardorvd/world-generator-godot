// Ranges are shared by the silhouettes and their supplementary canopy. Keep the cutoffs
// in sync with DistantForest.apply_ranges, whose margins allow for the size of a batch.
const float SCRUB_END = 950.0;
const float OUTER_END = 940.0;
const float OUTER_SCRUB_END = 720.0;

float distant_veg_near(float dist, bool scrub, bool grass) {
	if (scrub) {
		float begin = grass ? 144.0 : 150.0;
		float band = grass ? 56.0 : 90.0;
		return 1.0 - smoothstep(begin, begin + band, dist);
	}
	return clamp((distant_vegetation.x - dist) / max(distant_vegetation.y, 1.0), 0.0, 1.0);
}

float distant_veg_end(float dist, bool outer, bool scrub, bool small) {
	float end = distant_vegetation.z;
	if (outer) end = min(end, scrub ? OUTER_SCRUB_END : OUTER_END);
	if (scrub) end = min(end, SCRUB_END);
	else if (small) end = min(end, 820.0);
	return 1.0 - smoothstep(end - (small ? 135.0 : 170.0), end, dist);
}

float distant_veg_density(float dist, bool small) {
	float full = small ? 300.0 : 500.0;
	float ratio = min(1.0, full / max(dist, 1.0));
	return max(small ? 0.15 : 0.22, ratio * ratio);
}

float distant_veg_dither(vec2 pixel) {
	return fract(52.9829189 * fract(dot(pixel, vec2(0.06711056, 0.00583715))));
}
global uniform float vegetation_clock;
instance uniform vec2 distant_reveal = vec2(0.0);

float distant_veg_reveal() {
	return distant_reveal.y > 0.0
		? smoothstep(distant_reveal.x, distant_reveal.x + distant_reveal.y, vegetation_clock) : 1.0;
}
