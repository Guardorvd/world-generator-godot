class_name StageHydrology
extends RefCounted
## Rare closed lakes on unchanged relief; rainfall does not require physical water.
## No global flood, drainage ordering, discharge accumulation or depression filling.

const PROGRESS := 0.2
const LABEL := "Осадки и редкие озёра"
const SHORE_LIFT := 0.003 # retained for the explicit river shaping tools
const LAKE_MIN := 24
const LAKE_MAX := 320
const LAKE_DEPTH := 0.004
const COAST_REACH := 32


static func rainfall(noise_value: float, distance_to_ocean: float) -> float:
	# Compact coastal influence: OuterLand can reproduce it within its fixed halo.
	var far := exp(-COAST_REACH / 30.0)
	var coast := maxf(0.0, (exp(-distance_to_ocean / 30.0) - far) / (1.0 - far))
	return clampf(0.66 + 0.48 * noise_value + 0.08 * coast, 0.12, 1.0)


## lake_budget = 0 explicitly exercises a freshwater-free world; -1 selects by seed.
static func run(w: WorldData, lake_budget := -1) -> void:
	w.filled = w.h.duplicate()
	var empty_mask := PackedByteArray()
	empty_mask.resize(w.N)
	w.lake = empty_mask.duplicate()
	w.river = empty_mask.duplicate()
	w.river_area = w.river.duplicate()
	var empty_acc := PackedFloat32Array()
	empty_acc.resize(w.N)
	w.acc = empty_acc
	var no_down := PackedInt32Array()
	no_down.resize(w.N)
	no_down.fill(-1)
	w.down = no_down
	w.watershed = no_down.duplicate()
	w.order = PackedInt32Array()
	w.order_n = 0
	w.rivers.clear()
	w.river_exits.clear()
	w.dist_ocean = Grid.distance_field(w.W, w.H, w.ocean)
	var noise_values := w.noise_field("moist")
	var rain := PackedFloat32Array()
	rain.resize(w.N)
	for i in w.N:
		rain[i] = rainfall(noise_values[i], w.dist_ocean[i])
	w.rain = rain
	var budget_rng := WGRandom.new(WGRandom.derive(w.seed_num, "water.rare_lakes"))
	var want := mini(2, floori(budget_rng.next_float() * 3.0)) if lake_budget < 0 else clampi(lake_budget, 0, 2)
	var count := 0
	# Work is bounded independently of the number of depressions in the map.
	for attempt in (192 if want > 0 and mini(w.W, w.H) > 48 else 0):
		if count >= want: break
		var candidate := lake_candidate(w.seed_num, w.W, w.H, attempt)
		var x: int = candidate.x
		var y: int = candidate.y
		var c := y * w.W + x
		# A short local descent only proposes a basin; it never edits terrain.
		for step in 24:
			var best := c
			for k in 8:
				var n: int = c + Grid.DY[k] * w.W + Grid.DX[k]
				if n >= 0 and n < w.N and absi(n % w.W - c % w.W) <= 1 and w.h[n] < w.h[best]: best = n
			if best == c: break
			c = best
		if w.ocean[c] != 0 or w.lake[c] != 0 or w.dist_ocean[c] < 12.0: continue
		var level := w.h[c] + float(candidate.depth)
		var cells := _closed_basin(w, c, level)
		if cells.is_empty(): continue
		for i in cells:
			w.lake[i] = 1
			w.filled[i] = level
		count += 1
	w.generation_profile.freshwater_lakes = count


## Each proposal owns its random stream. Rejecting a basin must not consume or
## skip numbers belonging to later coordinates/depths. Terrain still decides
## which proposals form real lakes; the bounded lake budget is a separate policy.
## depth uses the same normalized height units as w.h (not metres).
static func lake_candidate(seed_num: int, width: int, height: int, attempt: int) -> Dictionary:
	var proposal := WGRandom.at(seed_num, "water.lake_candidate", attempt, 0)
	return {x=24+floori(proposal.next_float()*(width-48)),
		y=24+floori(proposal.next_float()*(height-48)), depth=0.006+proposal.next_float()*0.010}


## Reject open, narrow, oversized or overlapping pools. One constant level per lake.
## Eight-neighbour closure also rejects diagonal leaks; no artificial banks or steps.
static func _closed_basin(w: WorldData, start: int, level: float) -> PackedInt32Array:
	var cells := PackedInt32Array([start])
	var seen := {start: true}
	var head := 0
	var origin := Vector2i(start % w.W, start / w.W)
	var lo := origin
	var hi := origin
	while head < cells.size():
		var c := cells[head]
		head += 1
		var p := Vector2i(c % w.W, c / w.W)
		if p.x < 4 or p.y < 4 or p.x >= w.W - 4 or p.y >= w.H - 4 or absi(p.x - origin.x) > 20 or absi(p.y - origin.y) > 20:
			return PackedInt32Array()
		lo = lo.min(p)
		hi = hi.max(p)
		for k in 8:
			var n: int = c + Grid.DY[k] * w.W + Grid.DX[k]
			if w.ocean[n] != 0 or w.lake[n] != 0: return PackedInt32Array()
			if w.h[n] >= level or seen.has(n): continue
			seen[n] = true
			cells.append(n)
			if cells.size() > LAKE_MAX: return PackedInt32Array()
	var span := hi - lo + Vector2i.ONE
	if cells.size() < LAKE_MIN or mini(span.x, span.y) < 5 or float(cells.size()) / (span.x * span.y) < 0.3:
		return PackedInt32Array()
	return cells
