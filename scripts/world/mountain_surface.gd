extends RefCounted
## Shared exposure channel. Moisture already contains shelter, aspect and local
## retention from StageClimate; no new noise or terrain simulation.

static func exposure(elevation: float, slope: float, moisture: float) -> float:
	var high := smoothstep(0.10, 0.26, elevation)
	var dry := 1.0 - smoothstep(0.35, 0.88, moisture)
	var rock := smoothstep(0.24, 1.20, slope) * (0.35 + 0.65 * dry)
	return clampf(high * rock + 0.035 * smoothstep(0.2,0.8,slope),0.0,1.0)

static func field(elev: PackedFloat32Array, slope: PackedFloat32Array, moist: PackedFloat32Array) -> PackedByteArray:
	var fast := Grid.fast_grid()
	if fast != null: return fast.MountainExposure(elev,slope,moist)
	return reference_field(elev,slope,moist)

static func reference_field(elev: PackedFloat32Array, slope: PackedFloat32Array, moist: PackedFloat32Array) -> PackedByteArray:
	var out := PackedByteArray(); out.resize(elev.size())
	for i in elev.size():
		out[i]=roundi(exposure(elev[i],slope[i],moist[i] if moist.size()==elev.size() else 0.5)*255.0)
	return out
