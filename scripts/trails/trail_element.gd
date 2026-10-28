class_name TrailElement
extends Resource
## Override displacement() to introduce another earthwork profile; no riding logic here.
## Every profile is a function of (along, across) only, so any combination can be placed on any route.
## Profiles up to ROUGH reshape the ground only. ROCK_GARDEN and later also place objects (TrailTechnical).
enum Profile { ROLLER, TABLETOP, BERM, WAVES, DIP, ROLLOVER, S_BERM, RUTS, RIPPLES, ROUGH, ROCK_GARDEN, ROOTS, NARROW, LOG, SLALOM }
const KEYS := ["station", "length", "height", "bank", "count", "skew", "density", "gap", "lines", "seed", "period"]
const INTEGER_KEYS := ["count", "lines", "seed"]
@export var profile: Profile = Profile.ROLLER
@export var station := 30.0
@export var length := 12.0
@export var height := 0.6
## Sign selects the raised side of a berm relative to the route direction.
@export_range(-1.0, 1.0) var bank := 1.0
## WAVES: number of crests inside `length`.
@export_range(1, 12) var count := 3
## ROLLOVER / TABLETOP: where the crest sits along the element (0.5 is symmetric; lower — steeper face, longer back).
@export_range(0.15, 0.85) var skew := 0.35
## Technical features: share of free cells that get an object (rocks, roots).
@export_range(0.05, 1.0) var density := 0.5
## NARROW: clear width between the walls; LOG: width of the bypass, m.
@export_range(1.0, 6.0) var gap := 1.6
## ROCK_GARDEN / ROOTS: number of clear alternative lines through the feature.
@export_range(1, 3) var lines := 2
## Placement seed: the same element data always yields the same objects.
@export var seed := 1
## RIPPLES: distance between crests, m (the relief grid is one metre, so at least 1.5).
@export_range(1.5, 6.0) var period := 2.4

static func places_objects(kind: int) -> bool:
	return kind >= Profile.ROCK_GARDEN

func displacement(along: float, across: float, half_width: float) -> float:
	var t := (along - station) / length + 0.5
	if t <= 0.0 or t >= 1.0 or absf(across) >= half_width:
		return 0.0
	var edge := 1.0 - smoothstep(0.55, 1.0, absf(across) / half_width)
	match profile:
		Profile.TABLETOP:
			return height * smoothstep(0.0, 0.3, t) * (1.0 - smoothstep(0.7, 1.0, t)) * edge
		Profile.BERM:
			return height * pow(sin(PI * t), 2.0) * pow(maxf(0.0, across * bank / half_width), 2.0) * edge
		Profile.S_BERM:
			# Two opposite berms that hand over in the middle: the raised side flips smoothly.
			var side := sin(TAU * t)
			return height * pow(sin(PI * t), 2.0) * pow(maxf(0.0, across * bank * signf(side) / half_width), 2.0) * sqrt(absf(side)) * edge
		Profile.WAVES:
			# Crests rise from the first trough and fade out; the outer waves are smaller than the middle.
			return height * pow(sin(PI * count * t), 2.0) * pow(sin(PI * t), 0.6) * edge
		Profile.DIP:
			return -height * pow(sin(PI * t), 2.0) * edge
		Profile.RUTS:
			# Two wheel ruts that wander gently; the crown between them stays untouched.
			var taper := smoothstep(0.0, 0.15, t) * (1.0 - smoothstep(0.85, 1.0, t))
			var wander := 0.25 * sin(along * 0.31 + seed)
			var depth := 0.0
			for side: float in [-1.0, 1.0]:
				var offset: float = (across - side * 0.42 * half_width - wander) / 0.45
				depth += exp(-offset * offset)
			return -height * depth * taper * edge
		Profile.RIPPLES:
			var taper := smoothstep(0.0, 0.2, t) * (1.0 - smoothstep(0.8, 1.0, t))
			return height * 0.5 * (1.0 - cos(TAU * (along - station + length * 0.5) / period)) * taper * edge
		Profile.ROUGH:
			var taper := smoothstep(0.0, 0.2, t) * (1.0 - smoothstep(0.8, 1.0, t))
			return height * (_noise(along * 0.7, across * 0.7) * 2.0 - 1.0) * taper * edge
		Profile.ROCK_GARDEN, Profile.ROOTS, Profile.NARROW, Profile.LOG, Profile.SLALOM:
			return 0.0
		Profile.ROLLOVER:
			var u := pow(t, log(0.5) / log(skew))
			return height * pow(sin(PI * u), 2.0) * edge
	return height * pow(sin(PI * t), 2.0) * edge

## Smooth value noise in 0..1, deterministic in the element seed.
func _noise(x: float, z: float) -> float:
	var ix := floori(x)
	var iz := floori(z)
	var fx := smoothstep(0.0, 1.0, x - ix)
	var fz := smoothstep(0.0, 1.0, z - iz)
	var a := lerpf(WGRandom.hash2(ix, iz, seed), WGRandom.hash2(ix + 1, iz, seed), fx)
	var b := lerpf(WGRandom.hash2(ix, iz + 1, seed), WGRandom.hash2(ix + 1, iz + 1, seed), fx)
	return lerpf(a, b, fz)
