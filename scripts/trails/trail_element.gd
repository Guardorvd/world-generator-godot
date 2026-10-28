class_name TrailElement
extends Resource
## Override displacement() to introduce another earthwork profile; no riding logic here.
## Every profile is a function of (along, across) only, so any combination can be placed on any route.
enum Profile { ROLLER, TABLETOP, BERM, WAVES, DIP, ROLLOVER, S_BERM }
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
		Profile.ROLLOVER:
			var u := pow(t, log(0.5) / log(skew))
			return height * pow(sin(PI * u), 2.0) * edge
	return height * pow(sin(PI * t), 2.0) * edge
