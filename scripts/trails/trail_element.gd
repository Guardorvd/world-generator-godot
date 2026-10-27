class_name TrailElement
extends Resource
## Override displacement() to introduce another earthwork profile; no riding logic here.
enum Profile { ROLLER, TABLETOP, BERM }
@export var profile: Profile = Profile.ROLLER
@export var station := 30.0
@export var length := 12.0
@export var height := 0.6
## Sign selects the raised side of a berm relative to the route direction.
@export_range(-1.0, 1.0) var bank := 1.0

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
	return height * pow(sin(PI * t), 2.0) * edge
