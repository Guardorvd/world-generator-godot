class_name TrailElementLibrary
extends RefCounted
## Catalogue of parametric bike features and a deterministic composer for procedural flow lines.
## Elements only describe earthwork; the same data feed Trail Lab, the editor and any future generator.

const TITLES := {
	TrailElement.Profile.ROLLER: "Роллер",
	TrailElement.Profile.TABLETOP: "Стол",
	TrailElement.Profile.BERM: "Поворот",
	TrailElement.Profile.WAVES: "Волны",
	TrailElement.Profile.DIP: "Впадина",
	TrailElement.Profile.ROLLOVER: "Смена уклона",
	TrailElement.Profile.S_BERM: "S-поворот",
	TrailElement.Profile.RUTS: "Колеи",
	TrailElement.Profile.RIPPLES: "Рябь",
	TrailElement.Profile.ROUGH: "Неровное полотно",
	TrailElement.Profile.ROCK_GARDEN: "Каменный сад",
	TrailElement.Profile.ROOTS: "Корни",
	TrailElement.Profile.NARROW: "Узкий проход",
	TrailElement.Profile.LOG: "Брёвна",
	TrailElement.Profile.SLALOM: "Валуны-слалом",
}
## Typical size at difficulty 0 and 1: length, height. Waves scale length with their count.
const TECHNICAL := [TrailElement.Profile.RUTS, TrailElement.Profile.RIPPLES, TrailElement.Profile.ROUGH, TrailElement.Profile.ROCK_GARDEN, TrailElement.Profile.ROOTS, TrailElement.Profile.NARROW, TrailElement.Profile.LOG, TrailElement.Profile.SLALOM]
const RANGE := {
	TrailElement.Profile.ROLLER: [Vector2(10, 0.3), Vector2(16, 0.9)],
	TrailElement.Profile.TABLETOP: [Vector2(12, 0.4), Vector2(20, 1.0)],
	TrailElement.Profile.BERM: [Vector2(12, 0.4), Vector2(18, 0.8)],
	TrailElement.Profile.WAVES: [Vector2(8.5, 0.15), Vector2(10, 0.35)],
	TrailElement.Profile.DIP: [Vector2(8, 0.25), Vector2(14, 0.6)],
	TrailElement.Profile.ROLLOVER: [Vector2(8, 0.3), Vector2(14, 0.7)],
	TrailElement.Profile.S_BERM: [Vector2(16, 0.4), Vector2(24, 0.8)],
	TrailElement.Profile.RUTS: [Vector2(14, 0.1), Vector2(22, 0.22)],
	TrailElement.Profile.RIPPLES: [Vector2(10, 0.04), Vector2(16, 0.1)],
	TrailElement.Profile.ROUGH: [Vector2(10, 0.05), Vector2(18, 0.14)],
	TrailElement.Profile.ROCK_GARDEN: [Vector2(12, 0.1), Vector2(20, 0.18)],
	TrailElement.Profile.ROOTS: [Vector2(10, 0.07), Vector2(16, 0.15)],
	TrailElement.Profile.NARROW: [Vector2(8, 0.35), Vector2(12, 0.6)],
	TrailElement.Profile.LOG: [Vector2(10, 0.22), Vector2(16, 0.38)],
	TrailElement.Profile.SLALOM: [Vector2(14, 0.35), Vector2(20, 0.55)],
}

static func make(profile: TrailElement.Profile, station: float, length: float, height: float, bank := 1.0, count := 3, skew := 0.35) -> TrailElement:
	var e := TrailElement.new()
	e.profile = profile
	e.station = station
	e.length = length
	e.height = height
	e.bank = bank
	e.count = count
	e.skew = skew
	return e

static func title(profile: int) -> String:
	return TITLES.get(profile, "Элемент")

static func titles() -> PackedStringArray:
	var result := PackedStringArray()
	for profile in TrailElement.Profile.values(): result.append(title(profile))
	return result

## Size of an element for a difficulty in 0..1; waves return per-crest length.
static func sized(profile: TrailElement.Profile, difficulty: float) -> Vector2:
	var range: Array = RANGE[profile]
	return (range[0] as Vector2).lerp(range[1], clampf(difficulty, 0.0, 1.0))

## Fills a route with a rhythm of features. Deterministic in (route, seed, difficulty, density);
## turns get berms on the outside, straights get rollers, waves, dips and tables with a recovery gap.
static func compose(d: TrailDefinition, seed_value: int, difficulty := 0.5, density := 0.6, technical := 0.0) -> Array[TrailElement]:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var result: Array[TrailElement] = []
	var total := d.route_length()
	var cursor := 22.0
	var straight := [TrailElement.Profile.ROLLER, TrailElement.Profile.WAVES, TrailElement.Profile.DIP, TrailElement.Profile.ROLLOVER, TrailElement.Profile.TABLETOP]
	var last := -1
	var placed_object := -100.0 # end of the last object-placing feature: they keep a recovery gap
	while true:
		var kind: int = straight[rng.randi() % straight.size()]
		if rng.randf() < technical: kind = TECHNICAL[rng.randi() % TECHNICAL.size()]
		if kind == last: kind = straight[(straight.find(kind) + 1) % straight.size()]
		var turn := _turn_at(d, cursor, 14.0)
		var count := 1
		var length: float
		var height: float
		if absf(turn) > 0.012:
			kind = TrailElement.Profile.BERM
		var size := sized(kind, difficulty * rng.randf_range(0.7, 1.0))
		length = size.x
		height = size.y
		if kind == TrailElement.Profile.WAVES:
			count = rng.randi_range(3, 5)
			length *= count
		if cursor + length > total - 18.0: break
		# Straight-line features must stay straight over their whole length: long waves used to run into the next
		# turn and throw the bike off the line. Shorten to a roller, or wait until the turn is behind.
		if kind != TrailElement.Profile.BERM and not TrailElement.places_objects(kind) and _sharpest(d, cursor, length) > 0.025:
			if kind == TrailElement.Profile.WAVES or length > 12.0:
				kind = TrailElement.Profile.ROLLER
				size = sized(kind, difficulty * rng.randf_range(0.7, 1.0))
				length = size.x
				height = size.y
				count = 1
			if _sharpest(d, cursor, length) > 0.025:
				cursor += 4.0
				continue
		var bank := signf(turn) if kind == TrailElement.Profile.BERM else 1.0
		if TrailElement.places_objects(kind) and cursor < placed_object + 5.0:
			cursor = placed_object + 5.0
			continue
		var e := make(kind, cursor + length * 0.5, length, height, bank, count, rng.randf_range(0.28, 0.45))
		e.seed = rng.randi() % 10000
		e.density = rng.randf_range(0.35, 0.7)
		e.lines = rng.randi_range(1, 3) if difficulty < 0.7 else 2
		e.gap = lerpf(2.0, 1.2, difficulty)
		if kind == TrailElement.Profile.LOG: e.count = rng.randi_range(1, 3)
		if kind == TrailElement.Profile.SLALOM: e.count = rng.randi_range(3, 5)
		if kind == TrailElement.Profile.NARROW: e.gap = clampf(e.gap, 1.0, d.width - 0.6)
		if kind == TrailElement.Profile.LOG: e.gap = clampf(e.gap, 1.0, d.width * 0.5 - 0.3)
		result.append(e)
		if TrailElement.places_objects(kind): placed_object = cursor + length
		last = kind
		cursor += length + rng.randf_range(7.0, 18.0) / maxf(density, 0.2)
	return result

## Strongest curvature (1/m) anywhere over `span` metres from `from`.
static func _sharpest(d: TrailDefinition, from: float, span: float) -> float:
	var peak := 0.0
	var at := from
	while at <= from + span:
		peak = maxf(peak, absf(d.curvature_at(at)))
		at += 2.0
	return peak

## Mean signed curvature over a window starting at `from`; the sign says which side is the outside.
static func _turn_at(d: TrailDefinition, from: float, window: float) -> float:
	var sum := 0.0
	for i in 5: sum += d.curvature_at(from + window * i / 4.0)
	return sum / 5.0
