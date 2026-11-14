global uniform vec2 ground_carpet_forward;

// Same axes as GroundCarpet: forward, side, rear. The two half ellipses meet at the sides.
float carpet_profile_distance(vec2 offset, vec3 axes) {
	float along = dot(offset, ground_carpet_forward);
	float across = dot(offset, vec2(-ground_carpet_forward.y, ground_carpet_forward.x));
	return length(vec2(along / (along >= 0.0 ? axes.x : axes.z), across / axes.y));
}

float carpet_fade_distance(vec2 offset) {
	return carpet_profile_distance(offset, vec3(2.0, 1.18, 0.85));
}

float carpet_detail_distance(vec2 offset) {
	return carpet_profile_distance(offset, vec3(1.25, 0.59, 0.425));
}
