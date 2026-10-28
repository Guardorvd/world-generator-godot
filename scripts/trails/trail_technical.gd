class_name TrailTechnical
extends RefCounted
## Objects of technical bike features, laid out deterministically from the element data and the route.
## Nothing here moves a bike: small relief goes to ForestObstacles.bumps (the wheel rides over it),
## solid objects go to ForestObstacles collision capsules, and props are only for the picture.
## Every feature keeps clear corridors ("lines") wide enough for the bike, so a harder line is always
## a choice and never a trap. Placement uses cells with jitter, never free scattering.

const CORRIDOR := 0.6      # half-width of a clear line, m: the 0.6 m handlebar plus a margin
const EDGE := 0.9          # objects stay inside this share of the half width
const CELL := 0.9          # placement cell, m
const BUMP_LIMIT := 0.18   # higher than this is an obstacle, not a bump
const LOG_MAX := 0.4       # a log the rider can hop (RoadObstacles contract)
const COLLIDE_STRIDE := 7
const BUMP_STRIDE := 6

## {collide, bumps, props, lines}: lines maps element index -> lateral offsets of the clear lines (route id keyed)
static func build(h: Heightfield, routes: Array[TrailDefinition]) -> Dictionary:
	var set := {collide = PackedFloat32Array(), bumps = PackedFloat32Array(), props = [], lines = {}}
	for d in routes:
		for i in d.elements.size():
			var e := d.elements[i]
			if not TrailElement.places_objects(e.profile): continue
			var rng := RandomNumberGenerator.new()
			rng.seed = hash([e.seed, i, d.id])
			var offsets := line_offsets(d, e)
			set.lines[d.id + ":" + str(i)] = offsets
			match e.profile:
				TrailElement.Profile.ROCK_GARDEN: _rock_garden(h, d, e, rng, offsets, set)
				TrailElement.Profile.ROOTS: _roots(h, d, e, rng, offsets, set)
				TrailElement.Profile.NARROW: _narrow(h, d, e, rng, set)
				TrailElement.Profile.LOG: _logs(h, d, e, rng, set)
				TrailElement.Profile.SLALOM: _slalom(h, d, e, rng, set)
	return set

## Lateral centres (positive across) of the clean lines through an element.
static func line_offsets(d: TrailDefinition, e: TrailElement) -> PackedFloat32Array:
	var usable := d.width * 0.5 * EDGE - CORRIDOR
	var shift := e.bank * usable * 0.2
	match e.profile:
		TrailElement.Profile.NARROW: return PackedFloat32Array([shift])
		TrailElement.Profile.LOG: return PackedFloat32Array([signf(e.bank if e.bank != 0.0 else 1.0) * (d.width * 0.5 * EDGE - e.gap * 0.5)])
		TrailElement.Profile.SLALOM: return PackedFloat32Array([0.0])
	match e.lines:
		1: return PackedFloat32Array([shift])
		2: return PackedFloat32Array([-0.5 * usable + shift * 0.5, 0.5 * usable + shift * 0.5])
	return PackedFloat32Array([-0.75 * usable, 0.0, 0.75 * usable])

static func _frame(d: TrailDefinition, station: float) -> Dictionary:
	var t := d.tangent_at(station)
	return {p = d.point_at(station), t = t, lat = Vector2(t.y, -t.x)}

static func _at(d: TrailDefinition, station: float, across: float) -> Vector2:
	var f := _frame(d, station)
	return f.p + f.lat * across

## Small relief: a capsule a-b of radius r and height; the radius never drops below the wheel's arc.
static func _bump(set: Dictionary, a: Vector2, b: Vector2, r: float, height: float) -> void:
	r = maxf(r, sqrt(2.0 * BikeRide.WHEEL_R * height))
	set.bumps.append_array(PackedFloat32Array([a.x, a.y, b.x, b.y, r, height]))

static func _solid(h: Heightfield, set: Dictionary, a: Vector2, b: Vector2, r: float, top: float) -> void:
	var base := minf(h.ground_at(a.x, a.y), h.ground_at(b.x, b.y))
	set.collide.append_array(PackedFloat32Array([a.x, a.y, b.x, b.y, r, base, base + top]))

static func _blocked(across: float, offsets: PackedFloat32Array, margin: float) -> bool:
	for line in offsets:
		if absf(across - line) < CORRIDOR + margin: return true
	return false

static func _taper(t: float) -> float:
	return smoothstep(0.0, 0.18, t) * (1.0 - smoothstep(0.82, 1.0, t))

static func _rock_garden(h: Heightfield, d: TrailDefinition, e: TrailElement, rng: RandomNumberGenerator, offsets: PackedFloat32Array, set: Dictionary) -> void:
	var start := e.station - e.length * 0.5
	var half := d.width * 0.5 * EDGE
	var rows := int(e.length / CELL)
	var cols := int(2.0 * half / CELL)
	for row in rows:
		for col in cols:
			var t := (row + 0.5) / rows
			if rng.randf() > e.density * _taper(t): continue
			var along := start + (row + rng.randf_range(0.15, 0.85)) * CELL
			var across := -half + (col + rng.randf_range(0.15, 0.85)) * CELL * (2.0 * half / (cols * CELL))
			# Boulders stand near the edges; the middle only gets stones the wheel can climb over.
			var boulder := absf(across) > half * 0.62 and rng.randf() < 0.28
			var size := e.height * rng.randf_range(0.6, 1.0)
			var margin := 0.35 if boulder else 0.1
			if _blocked(across, offsets, margin): continue
			var at := _at(d, along, across)
			var ground := h.ground_at(at.x, at.y)
			if boulder:
				var scale := clampf(size * 1.4, 0.25, 0.6)
				_solid(h, set, at, at, ForestObstacles.ROCK_R * scale * 0.8, ForestObstacles.ROCK_TOP * scale - 0.1)
				set.props.append({kind = "boulder", pos = Vector3(at.x, ground, at.y), size = Vector3(1.43, 0.83, 1.1) * scale, seed = rng.randi(), rot = rng.randf() * TAU})
			else:
				var height := clampf(size * 0.9, 0.05, BUMP_LIMIT)
				var radius := rng.randf_range(0.18, 0.34)
				_bump(set, at, at, radius, height)
				set.props.append({kind = "stone", pos = Vector3(at.x, ground, at.y), size = Vector3(radius * 2.2, height * 2.0, radius * 1.8), seed = rng.randi(), rot = rng.randf() * TAU})

static func _roots(h: Heightfield, d: TrailDefinition, e: TrailElement, rng: RandomNumberGenerator, offsets: PackedFloat32Array, set: Dictionary) -> void:
	var half := d.width * 0.5 * EDGE
	var spacing := 2.4 / maxf(e.density, 0.15)
	var along := e.station - e.length * 0.5 + spacing * 0.5
	var end := e.station + e.length * 0.5
	while along < end - 0.5:
		var tilt := rng.randf_range(-0.6, 0.6)
		# The corridor of one line is left open in each row; a different line is open in the next.
		var open: float = offsets[rng.randi() % offsets.size()]
		var left := -half
		var right := half
		var pieces := [[left, open - CORRIDOR], [open + CORRIDOR, right]]
		var height := clampf(e.height * rng.randf_range(0.7, 1.0), 0.04, BUMP_LIMIT)
		for piece: Array in pieces:
			if piece[1] - piece[0] < 0.4: continue
			var a := _at(d, along + tilt * piece[0] * 0.5, piece[0])
			var b := _at(d, along + tilt * piece[1] * 0.5, piece[1])
			_bump(set, a, b, 0.11, height)
			var mid := (a + b) * 0.5
			set.props.append({kind = "root", pos = Vector3(mid.x, h.ground_at(mid.x, mid.y), mid.y), a = a, b = b, radius = height * 0.8, seed = rng.randi()})
		along += spacing * rng.randf_range(0.8, 1.25)

static func _narrow(h: Heightfield, d: TrailDefinition, e: TrailElement, rng: RandomNumberGenerator, set: Dictionary) -> void:
	var start := e.station - e.length * 0.5
	var shift := line_offsets(d, e)[0]
	var scale := clampf(e.height, 0.3, 0.7)
	var r := ForestObstacles.ROCK_R * scale * 0.8
	var along := start
	while along < start + e.length:
		var t := (along - start) / e.length
		# The mouth is wider than the throat, so the passage reads from afar and is easy to enter.
		var open := e.gap * 0.5 + (1.0 - smoothstep(0.0, 0.3, minf(t, 1.0 - t) * 1.0)) * e.gap * 0.6
		for side in [-1.0, 1.0]:
			var across: float = shift + side * (open + r)
			if absf(across) > d.width * 0.5 - 0.1: continue
			var jitter := rng.randf_range(-0.12, 0.12)
			var at := _at(d, along, across + jitter)
			var s := scale * rng.randf_range(0.85, 1.1)
			_solid(h, set, at, at, ForestObstacles.ROCK_R * s * 0.8, ForestObstacles.ROCK_TOP * s - 0.1)
			set.props.append({kind = "boulder", pos = Vector3(at.x, h.ground_at(at.x, at.y), at.y), size = Vector3(1.43, 0.83, 1.1) * s, seed = rng.randi(), rot = rng.randf() * TAU})
		along += r * 1.7

static func _logs(h: Heightfield, d: TrailDefinition, e: TrailElement, rng: RandomNumberGenerator, set: Dictionary) -> void:
	var half := d.width * 0.5 * EDGE
	var count := clampi(e.count, 1, 4)
	var radius := clampf(e.height, 0.1, LOG_MAX) * 0.5
	var bypass := signf(e.bank if e.bank != 0.0 else 1.0)
	for k in count:
		var along := e.station - e.length * 0.5 + e.length * (k + 0.5) / count
		var lean := rng.randf_range(-0.25, 0.25)
		# One open side for the whole series keeps a single clean line; the logs differ in tilt and position.
		var side := bypass
		var closed := -side * half
		var open_edge := side * (half - e.gap)
		var a := _at(d, along - lean * half, closed)
		var b := _at(d, along + lean * half, open_edge)
		_solid(h, set, a, b, radius, radius * 2.0)
		var mid := (a + b) * 0.5
		set.props.append({kind = "log", pos = Vector3(mid.x, h.ground_at(mid.x, mid.y), mid.y), a = a, b = b, radius = radius, seed = rng.randi()})

static func _slalom(h: Heightfield, d: TrailDefinition, e: TrailElement, rng: RandomNumberGenerator, set: Dictionary) -> void:
	var count := clampi(e.count, 2, 8)
	var scale := clampf(e.height, 0.3, 0.6)
	var throw := d.width * 0.5 * 0.34
	for k in count:
		var along := e.station - e.length * 0.5 + e.length * (k + 0.5) / count
		var at := _at(d, along, (1.0 if k % 2 == 0 else -1.0) * throw + rng.randf_range(-0.15, 0.15))
		_solid(h, set, at, at, ForestObstacles.ROCK_R * scale * 0.8, ForestObstacles.ROCK_TOP * scale - 0.1)
		set.props.append({kind = "boulder", pos = Vector3(at.x, h.ground_at(at.x, at.y), at.y), size = Vector3(1.43, 0.83, 1.1) * scale, seed = rng.randi(), rot = rng.randf() * TAU})
