class_name TrailElement
extends Resource
## Override displacement() to introduce another earthwork profile; no riding logic here.
## Every profile is a function of (along, across) only, so any combination can be placed on any route.
## Profiles up to ROUGH reshape the ground only. ROCK_GARDEN and later also place objects (TrailTechnical),
## except the relief-only bike-park features OFF_CAMBER, PUMP and DROP. NORTHSHORE leaves the ground alone:
## its raised decks are structures (Heightfield.add_decks), because a one-metre grid cannot hold a vertical edge.
## New profiles only ever go to the end: saved trails store the number.
enum Profile { ROLLER, TABLETOP, BERM, WAVES, DIP, ROLLOVER, S_BERM, RUTS, RIPPLES, ROUGH, ROCK_GARDEN, ROOTS, NARROW, LOG, SLALOM, OFF_CAMBER, PUMP, DROP, NORTHSHORE }
const KEYS := ["station", "length", "height", "bank", "count", "skew", "density", "gap", "lines", "seed", "period"]
const INTEGER_KEYS := ["count", "lines", "seed"]
@export var profile: Profile = Profile.ROLLER
@export var station := 30.0
@export var length := 12.0
@export var height := 0.6
## Sign selects the raised side of a berm relative to the route direction.
@export_range(-1.0, 1.0) var bank := 1.0
## WAVES / PUMP: number of crests inside `length`.
@export_range(1, 12) var count := 3
## ROLLOVER / TABLETOP: where the crest sits along the element (0.5 is symmetric; lower — steeper face, longer back).
@export_range(0.15, 0.85) var skew := 0.35
## Technical features: share of free cells that get an object (rocks, roots).
@export_range(0.05, 1.0) var density := 0.5
## NARROW: clear width between the walls; LOG: width of the bypass, m; NORTHSHORE: width of the deck, m.
@export_range(1.0, 6.0) var gap := 1.6
## ROCK_GARDEN / ROOTS: number of clear alternative lines through the feature.
@export_range(1, 3) var lines := 2
## Placement seed: the same element data always yields the same objects.
@export var seed := 1
## RIPPLES: distance between crests, m (the relief grid is one metre, so at least 1.5).
@export_range(1.5, 6.0) var period := 2.4

static func places_objects(kind: int) -> bool:
	return kind >= Profile.ROCK_GARDEN and kind != Profile.OFF_CAMBER and kind != Profile.PUMP and kind != Profile.DROP

## A berm's raised outside continues past the trail edge and falls back to the ground there (m).
const BERM_BACK := 2.0
## OFF_CAMBER: the lowered outside stays at full depth this far past the edge, then climbs back over BERM_BACK (m).
const SIDEHILL := 0.5
## DROP: the approach ramp and the lip as shares of the length; the edge between lip and landing is this many metres.
const DROP_RAMP := 0.45
const DROP_LIP := 0.62
const DROP_EDGE := 1.5
## Steepest takeoff of a table lip (rise per metre); the face is concave, so the bike leaves the lip at this angle.
const LIP_MAX := 0.6
## How far the deck sits below the lip, m (at most half the table height): more than the bike's lift threshold.
const LIP_STEP := 0.3

func displacement(along: float, across: float, half_width: float) -> float:
	var t := (along - station) / length + 0.5
	var berm := profile == Profile.BERM or profile == Profile.S_BERM
	var back := BERM_BACK if berm else (BERM_BACK + SIDEHILL if profile == Profile.OFF_CAMBER else 0.0)
	if t <= 0.0 or t >= 1.0 or absf(across) >= half_width + back:
		return 0.0
	var edge := 1.0 - smoothstep(0.55, 1.0, absf(across) / half_width)
	match profile:
		Profile.TABLETOP:
			# Concave face up to a lip, a deck slightly below the lip, then a rounded landing. On the one-metre
			# relief grid a lip level with the deck rounds over and the bike just rolls onto the table;
			# the small step behind the lip lets the ground fall away, so the bike pops off it.
			var face := clampf(height / (LIP_MAX * length) * 2.0, 0.25, 0.35)
			var rise := pow(clampf(t / face, 0.0, 1.0), 2.0)
			var deck := 1.0 - minf(LIP_STEP / height, 0.5) * smoothstep(face, face + 1.5 / length, t)
			return height * rise * deck * (1.0 - smoothstep(0.7, 1.0, t)) * edge
		Profile.BERM:
			return height * pow(sin(PI * t), 2.0) * _berm_side(across * bank, half_width)
		Profile.S_BERM:
			# Two opposite berms that hand over in the middle: the raised side flips smoothly.
			var side := sin(TAU * t)
			return height * pow(sin(PI * t), 2.0) * _berm_side(across * bank * signf(side), half_width) * sqrt(absf(side))
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
		Profile.OFF_CAMBER:
			# The whole width falls away towards the outside of the turn (the berm's raised side, turned over):
			# the bank assist of BikeRide takes grip instead of adding it. It is added to the route's own banking,
			# which the bike-track preset makes up to 38 %: use it with auto_bank near 0 (or a natural-trail preset).
			var taper := smoothstep(0.0, 0.2, t) * (1.0 - smoothstep(0.8, 1.0, t))
			return -height * taper * _off_camber_side(across * bank, half_width)
		Profile.PUMP:
			# Short steep rollers of equal height, trough to trough at ground level; `count` crests inside `length`.
			return height * pow(sin(PI * count * t), 2.0) * edge
		Profile.DROP:
			# Rising approach to a flat lip, a short steep face and the landing on the natural ground.
			# The ground leaves the wheels at the lip (BikeRide.DROP_STEP): a drop, not a rounded hump.
			var s := t * length
			var rise := smoothstep(0.0, length * DROP_RAMP, s)
			var fall := 1.0 - smoothstep(length * DROP_LIP, length * DROP_LIP + DROP_EDGE, s)
			return height * rise * fall * edge
		Profile.ROCK_GARDEN, Profile.ROOTS, Profile.NARROW, Profile.LOG, Profile.SLALOM, Profile.NORTHSHORE:
			return 0.0
		Profile.ROLLOVER:
			var u := pow(t, log(0.5) / log(skew))
			return height * pow(sin(PI * u), 2.0) * edge
	return height * pow(sin(PI * t), 2.0) * edge

## Cross-section of a berm, 0..1 along `outward` (across towards the raised side): the riding line is
## already banked at the centre, the wall rises to the outer edge and falls off behind it.
static func _berm_side(outward: float, half_width: float) -> float:
	if outward > half_width:
		return 1.0 - smoothstep(half_width, half_width + BERM_BACK, outward)
	return pow(clampf((outward / half_width + 0.35) / 1.35, 0.0, 1.0), 1.5)

## Cross-section of an off-camber stretch, 0..1 along `outward`: level at the inner edge, down by the full height
## at the outer one, then the side-hill falls on for SIDEHILL metres and climbs back to the ground.
static func _off_camber_side(outward: float, half_width: float) -> float:
	if outward > half_width:
		return 1.0 - smoothstep(half_width + SIDEHILL, half_width + SIDEHILL + BERM_BACK, outward)
	return clampf((outward / half_width + 1.0) * 0.5, 0.0, 1.0)

## Smooth value noise in 0..1, deterministic in the element seed.
func _noise(x: float, z: float) -> float:
	var ix := floori(x)
	var iz := floori(z)
	var fx := smoothstep(0.0, 1.0, x - ix)
	var fz := smoothstep(0.0, 1.0, z - iz)
	var a := lerpf(WGRandom.hash2(ix, iz, seed), WGRandom.hash2(ix + 1, iz, seed), fx)
	var b := lerpf(WGRandom.hash2(ix, iz + 1, seed), WGRandom.hash2(ix + 1, iz + 1, seed), fx)
	return lerpf(a, b, fz)
