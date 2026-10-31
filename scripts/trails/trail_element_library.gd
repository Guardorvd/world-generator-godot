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
	TrailElement.Profile.OFF_CAMBER: "Контруклон",
	TrailElement.Profile.PUMP: "Памп-секция",
	TrailElement.Profile.DROP: "Дроп",
	TrailElement.Profile.NORTHSHORE: "Норшор",
	TrailElement.Profile.GAP: "Гэп",
}
## Typical size at difficulty 0 and 1: length, height. Waves and pump rollers scale length with their count.
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
	# Bike-park features: by hand (lab course "Байк-парк") or through TrailComposer moods (pump, drop, off-camber).
	TrailElement.Profile.OFF_CAMBER: [Vector2(14, 0.4), Vector2(22, 0.9)],
	TrailElement.Profile.PUMP: [Vector2(4.8, 0.3), Vector2(5.5, 0.55)], # per crest, like waves
	TrailElement.Profile.DROP: [Vector2(12, 0.5), Vector2(18, 1.2)],
	TrailElement.Profile.NORTHSHORE: [Vector2(14, 0.9), Vector2(24, 1.5)], # deck height must stay above Heightfield.STEP
	TrailElement.Profile.GAP: [Vector2(14, 1.0), Vector2(22, 1.8)], # gap (lip to landing) — the element's `gap`
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

## Size of an element for a difficulty in 0..1; waves and pump rollers return per-crest length.
static func sized(profile: TrailElement.Profile, difficulty: float) -> Vector2:
	var range: Array = RANGE[profile]
	return (range[0] as Vector2).lerp(range[1], clampf(difficulty, 0.0, 1.0))

## Legacy entry point over TrailComposer: one flow/technical mix at a fixed difficulty.
static func compose(d: TrailDefinition, seed_value: int, difficulty := 0.5, density := 0.6, technical := 0.0) -> Array[TrailElement]:
	var profile := {difficulty = Vector2(difficulty, difficulty), density = density, section = Vector2(80, 130),
		moods = {flow = 3.0 * (1.0 - technical) + 0.01, jump = 1.0 - technical, tech = 4.0 * technical}}
	var result: Array[TrailElement] = []
	result.assign(TrailComposer.compose(d, profile, seed_value).elements)
	return result