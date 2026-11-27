shader_type spatial;
// Общий материал велосипеда и седока (tools/build_bike.gd, tools/build_cyclist.gd): одна отрисовка на меш.
// Данные в вершинах:
//   UV.x — место в палитре (BikePalette), UV.y — вид поверхности (KIND_* ниже);
//   COLOR.r — запечённое затенение (1 — открыто, 0 — закрыто соседними деталями, tools/vertex_ao.gd),
//   COLOR.g — подвижность ткани на ветру (0 — прилегает), COLOR.b — 1 у покрышки (сплющивается у земли).
// Перья и цепь (CylinderMesh) своих данных не несут: их место и вид задают fixed_slot / fixed_kind.
// Работает одинаково в Forward+ и Compatibility: свет движка, без своих light().
render_mode cull_back, depth_draw_opaque;

uniform vec4 palette[17] : source_color;
uniform vec4 tire_tread : source_color = vec4(0.0);
uniform vec4 tire_sidewall : source_color = vec4(0.0);
uniform vec4 grip_body : source_color = vec4(0.0);
uniform vec4 grip_rib : source_color = vec4(0.0);
uniform vec4 pedal_body : source_color = vec4(0.0);
uniform vec4 pedal_trim : source_color = vec4(0.0);
uniform float fixed_slot = -1.0;
uniform float fixed_kind = -1.0;
uniform float wind = 0.0;           // 0..1: скорость езды для трепета ткани (BikeView)
uniform float contact_flat = 0.339; // м от оси колеса: дальше покрышка сплющивается о землю

// Виды поверхности: шероховатость, металл, блик, подсветка контура, лак
const int KIND_PAINT = 0;
const int KIND_RUBBER = 1;
const int KIND_ALLOY = 2;
const int KIND_HARD = 3;     // анодированный металл, жёсткий пластик
const int KIND_FABRIC = 4;
const int KIND_SKIN = 5;
const int KIND_SHELL = 6;    // скорлупа шлема, глянцевый пластик
const int KIND_LENS = 7;
const int KIND_GLOW = 8;     // задний фонарь
const int KIND_MATTE = 9;    // наклейки, кожа седла, подошва
const int KIND_COATING = 10; // ноги вилки
const int KIND_GRIP = 11;
const int KIND_PEDAL = 12;

varying float v_ao;
varying float v_kind;
varying float v_slot;
varying float v_tire;
varying vec3 v_up; // мировое «вверх» в осях вида: для отражения неба в стекле

void vertex() {
	v_ao = COLOR.r;
	v_slot = fixed_slot >= 0.0 ? fixed_slot : UV.x;
	v_kind = fixed_kind >= 0.0 ? fixed_kind : UV.y;
	// Mesh primitives may have white default vertex color. Only baked rubber belongs to the tire.
	v_tire = fixed_slot < 0.0 && abs(v_kind - float(KIND_RUBBER)) < 0.5 ? COLOR.b : 0.0;
	if (fixed_slot >= 0.0) {
		v_ao = 1.0;
	}
	// Трепет ткани: мелкая волна вдоль поверхности, растёт со скоростью
	if (COLOR.g > 0.0 && wind > 0.0) {
		float phase = TIME * 23.0 + dot(VERTEX, vec3(31.0, 47.0, 53.0));
		float wave = sin(phase) * 0.6 + sin(phase * 1.9 + 1.7) * 0.4;
		VERTEX += NORMAL * wave * COLOR.g * wind * 0.0045;
	}
	// Покрышка у земли: всё, что дальше contact_flat от оси вниз, ложится на плоскость пятна и чуть раздаётся вбок
	if (v_tire > 0.5) {
		vec3 axle = normalize(MODEL_MATRIX[0].xyz);
		vec3 down = vec3(0.0, -1.0, 0.0) - axle * -axle.y;
		float dl = length(down);
		if (dl > 0.3) {
			down /= dl;
			vec3 p = mat3(MODEL_MATRIX) * VERTEX;
			float d = dot(p, down);
			if (d > contact_flat) {
				float over = d - contact_flat;
				float side = dot(p, axle);
				p += -down * over + axle * sign(side) * over * 0.5;
				VERTEX = transpose(mat3(MODEL_MATRIX)) * p;
			}
		}
	}
	v_up = (VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz;
}

void fragment() {
	int slot = clamp(int(v_slot + 0.5), 0, 16);
	int kind = int(v_kind + 0.5);
	vec3 base = palette[slot].rgb;
	if (v_tire > 0.5 && tire_tread.a > 0.0) {
		base = slot == 15 ? tire_sidewall.rgb : tire_tread.rgb;
	}
	if (kind == KIND_GRIP) {
		base = grip_body.a > 0.0 ? (slot == 2 ? grip_body.rgb : grip_rib.rgb) : palette[2].rgb;
	} else if (kind == KIND_PEDAL && pedal_body.a > 0.0) {
		base = slot == 1 ? pedal_trim.rgb : pedal_body.rgb;
	}
	float ao = clamp(v_ao, 0.0, 1.0);
	float rough = 0.8;
	float metal = 0.0;
	float spec = 0.5;
	float rim = 0.0;
	float rim_tint = 0.5;
	float coat = 0.0;
	float coat_rough = 0.2;
	vec3 emit = vec3(0.0);
	if (kind == KIND_PAINT || (kind == KIND_PEDAL && slot == 1)) {
		rough = 0.38; metal = 0.12; spec = 0.5; coat = 0.7; coat_rough = 0.12;
	} else if (kind == KIND_RUBBER || kind == KIND_GRIP) {
		rough = 0.9; spec = 0.25; rim = 0.08;
	} else if (kind == KIND_ALLOY) {
		rough = 0.3; metal = 0.78; spec = 0.6;
	} else if (kind == KIND_HARD || kind == KIND_PEDAL) {
		rough = 0.48; metal = 0.25; spec = 0.5;
	} else if (kind == KIND_FABRIC) {
		// трикотаж: матовый, со светлым ворсом по контуру
		rough = 0.86; spec = 0.25; rim = 0.32; rim_tint = 0.7;
	} else if (kind == KIND_SKIN) {
		rough = 0.58; spec = 0.35; rim = 0.16; rim_tint = 0.45;
		// тёплый переход в тень: в закрытых местах кожа краснее, а не серее
		base = mix(base * vec3(0.86, 0.64, 0.56), base, smoothstep(0.25, 0.95, ao));
	} else if (kind == KIND_SHELL) {
		rough = 0.3; spec = 0.6; coat = 0.6; coat_rough = 0.1;
	} else if (kind == KIND_LENS) {
		// стекло отражает небо сверху и землю снизу
		float sky = clamp(dot(NORMAL, normalize(v_up)) * 0.5 + 0.5, 0.0, 1.0);
		float edge = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.0);
		base = mix(base * 0.7, mix(base, vec3(0.62, 0.75, 0.84), 0.55), sky) + edge * 0.18;
		rough = 0.07; metal = 0.45; spec = 0.9;
	} else if (kind == KIND_GLOW) {
		rough = 0.35; emit = base * 1.6;
	} else if (kind == KIND_MATTE) {
		rough = 0.75; spec = 0.35;
	} else if (kind == KIND_COATING) {
		rough = 0.22; metal = 0.65; spec = 0.65;
	}
	// Затенение в углублениях: и рассеянный свет (AO), и немного прямой — иначе на солнце стыки плоские
	ALBEDO = base * mix(0.55, 1.0, ao);
	AO = ao;
	AO_LIGHT_AFFECT = 0.25;
	ROUGHNESS = rough;
	METALLIC = metal;
	SPECULAR = spec;
	RIM = rim;
	RIM_TINT = rim_tint;
	CLEARCOAT = coat;
	CLEARCOAT_ROUGHNESS = coat_rough;
	EMISSION = emit;
}
