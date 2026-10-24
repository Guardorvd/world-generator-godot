extends RefCounted
## One bounded, seed-selected relict forest. Pure functions: safe in streaming workers.
## Geography is read only to anchor the patch; no RNG or biome/road fields are changed.
const OLD_AGE := 0.88
const DENSITY := 0.95
const DOMINANCE := 0.82
const OAK := 1
const PINE := 2
const SCALE := 190.0 # cells: slow irregular edges, continuous across chunks/regions
const OX := -421.0
const OY := 619.0
const CANDIDATES := 64
const ANCHOR_OFFSETS: Array[Vector2i] = [Vector2i.ZERO, Vector2i(-24, 0), Vector2i(24, 0), Vector2i(0, -24), Vector2i(0, 24)]


static func character(seed_num: int) -> float:
	# A soft world character, not a fixed-probability switch or a quota of special worlds.
	var rng := WGRandom.new(WGRandom.derive(seed_num, "forest.massive.character"))
	var climate := (rng.next_float() + rng.next_float() + rng.next_float()) / 3.0
	return smoothstep(0.45, 0.6, climate)


static func suitability(scenario: int, biome: int, elevation: float, slope: float, moist: float, temp: float) -> float:
	if biome != Biomes.FOREST and biome != Biomes.GRASS and biome != Biomes.TAIGA and biome != Biomes.ROCK:
		return 0.0
	var grade := 1.0 - smoothstep(0.5, 1.0, slope)
	if scenario == PINE:
		return grade * smoothstep(0.09, 0.16, elevation) * (1.0 - smoothstep(0.29, 0.38, elevation)) \
			* smoothstep(0.2, 0.38, moist) * smoothstep(0.2, 0.35, temp) * (1.0 - smoothstep(0.72, 0.9, temp))
	if biome == Biomes.TAIGA or biome == Biomes.ROCK: return 0.0
	return grade * (1.0 - smoothstep(0.12, 0.2, elevation)) * smoothstep(0.28, 0.48, moist) \
		* smoothstep(0.3, 0.45, temp) * (1.0 - smoothstep(0.78, 0.95, temp))


static func profile(w: WorldData) -> Dictionary:
	var rng := WGRandom.new(WGRandom.derive(w.seed_num, "forest.massive"))
	var strength := character(w.seed_num)
	if strength <= 0.0 or w.N <= 0 or w.biome.size() != w.N or w.elev.size() != w.N \
			or w.slope.size() != w.N or w.moist.size() != w.N or w.temp.size() != w.N:
		return {}
	var oak_affinity := 0.7 + rng.next_float() * 0.6
	var pine_affinity := 0.7 + rng.next_float() * 0.6
	var radius := Vector2(150.0 * exp((rng.next_float() + rng.next_float() - 1.0) * 0.8),
		150.0 * exp((rng.next_float() + rng.next_float() - 1.0) * 0.8))
	var best := [0.0, 0.0, 0.0]
	var centers := [Vector2.ZERO, Vector2.ZERO, Vector2.ZERO]
	var biome := w.biome
	var elev := w.elev
	var slope := w.slope
	var moist := w.moist
	var temp := w.temp
	# Read immutable climate, not roads, territory window, or streamed region overlays.
	# Five samples favour a coherent belt over an isolated summit or tiny shore meadow.
	for candidate in CANDIDATES:
		var x := mini(w.W - 1, floori(rng.next_float() * w.W))
		var y := mini(w.H - 1, floori(rng.next_float() * w.H))
		for scenario in [OAK, PINE]:
			var score := 0.0
			for offset: Vector2i in ANCHOR_OFFSETS:
				var i := clampi(y + offset.y, 0, w.H - 1) * w.W + clampi(x + offset.x, 0, w.W - 1)
				var value := suitability(scenario, biome[i], elev[i], slope[i], moist[i], temp[i])
				score += value * (0.4 if offset == Vector2i.ZERO else 0.15)
			if score > best[scenario]:
				best[scenario] = score
				centers[scenario] = Vector2(x, y)
	var scenario := PINE if best[PINE] * pine_affinity > best[OAK] * oak_affinity else OAK
	strength *= smoothstep(0.0, 0.55, best[scenario])
	if strength <= 0.0: return {}
	return {scenario = scenario, center = centers[scenario], radius = radius, strength = strength}


static func fields(w: WorldData, x0: int, y0: int, cw: int, ch: int, selected: Variant = null) -> Dictionary:
	if not w.noise.has("forest"): return {}
	var p: Dictionary = profile(w) if selected == null else selected
	if p.is_empty(): return {}
	# Do not sample another noise map over the whole plan or distant streaming rectangles.
	var bounds := Rect2i(Vector2i(p.center - p.radius * 1.25), Vector2i(p.radius * 2.5) + Vector2i(3, 3))
	var part := bounds.intersection(Rect2i(x0, y0, cw, ch))
	if not part.has_area(): return {}
	var out := PackedFloat32Array()
	out.resize(cw * ch)
	var noise := Parallel.fbm_rect(w.noise.forest, part.position.x, part.position.y, part.size.x, part.size.y, SCALE, 2, OX, OY)
	for y in range(part.position.y, part.end.y):
		for x in range(part.position.x, part.end.x):
			var dx: float = (float(x) - p.center.x) / p.radius.x
			var dy: float = (float(y) - p.center.y) / p.radius.y
			var n := noise[(y - part.position.y) * part.size.x + x - part.position.x]
			out[(y - y0) * cw + x - x0] = p.strength * smoothstep(0.0, 0.35, 1.0 - sqrt(dx * dx + dy * dy) + n * 0.22)
	return {massive = out, massive_scenario = p.scenario}
