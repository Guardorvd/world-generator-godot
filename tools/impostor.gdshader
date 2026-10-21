shader_type spatial;
render_mode cull_disabled;
uniform sampler2D color_atlas : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D normal_atlas : source_color, filter_linear_mipmap, repeat_disable;
uniform vec3 reference_color = vec3(1.0);
uniform float frame_texel = 0.00390625;
varying flat float frame;
varying mat3 tree_rotation;

void vertex() {
 vec3 origin = MODEL_MATRIX[3].xyz;
 vec3 to_camera = MAIN_CAM_INV_VIEW_MATRIX[3].xyz - origin;
 vec3 local_view = transpose(mat3(normalize(MODEL_MATRIX[0].xyz), normalize(MODEL_MATRIX[1].xyz), normalize(MODEL_MATRIX[2].xyz))) * to_camera;
 float angle = atan(local_view.x, local_view.z);
 frame = mod(floor(angle * 8.0 / 6.28318530718 + 0.5) + 8.0, 8.0);
 tree_rotation = mat3(normalize(MODEL_MATRIX[0].xyz), normalize(MODEL_MATRIX[1].xyz), normalize(MODEL_MATRIX[2].xyz));
 vec3 front = normalize(vec3(to_camera.x, 0.0, to_camera.z));
 vec3 right = cross(vec3(0.0, 1.0, 0.0), front);
 mat4 billboard = mat4(vec4(right * length(MODEL_MATRIX[0].xyz), 0.0), MODEL_MATRIX[1], vec4(front * length(MODEL_MATRIX[2].xyz), 0.0), MODEL_MATRIX[3]);
 MODELVIEW_MATRIX = VIEW_MATRIX * billboard;
}

void fragment() {
 vec2 uv = vec2((clamp(UV.x, frame_texel * 0.5, 1.0 - frame_texel * 0.5) + frame) / 8.0, UV.y);
 vec4 color = texture(color_atlas, uv);
 if (color.a < 0.4) discard;
 ALBEDO = color.rgb * COLOR.rgb / reference_color;
 vec3 n = texture(normal_atlas, uv).rgb * 2.0 - 1.0;
 NORMAL = normalize(mat3(VIEW_MATRIX) * tree_rotation * n);
 ROUGHNESS = 1.0;
}
