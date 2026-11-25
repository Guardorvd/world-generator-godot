using System;
using Godot;
using Roads;
using Simd = System.Numerics.Vector<double>;

public partial class FastGrid
{
	/// <summary>Roads.RoadCode.Version для ключа кэша поверхности (WorldCache.artifact_key).</summary>
	public int RoadCodeVersion() => Roads.RoadCode.Version;

	/// <summary>RoadSurface.pick, batched at route points. Same bilinear 16 m kernel and decision order as GDScript.</summary>
	public byte[] PickRoadSurfaces(double[] xs, double[] ys, int[] kinds, int width, int height, byte[] biome, float[] slopes,
		float[] moisture, double[] villages, int[] biomes, double villageRadius, double stoneSlope)
	{
		var result = new byte[xs.Length];
		for (int n = 0; n < xs.Length; n++)
		{
			double x = xs[n], y = ys[n];
			double wooded = 0.0, rocky = 0.0, sandy = 0.0, grass = 0.0, slope = 0.0, moist = 0.0;
			for (int dz = -1; dz <= 1; dz++)
				for (int dx = -1; dx <= 1; dx++)
				{
					double px = Math.Clamp(x + dx * 2.0 - 0.5, 0.0, width - 1.0);
					double py = Math.Clamp(y + dz * 2.0 - 0.5, 0.0, height - 1.0);
					int ix = (int)Math.Floor(px), iy = (int)Math.Floor(py);
					double kernel = (dx == 0 ? 2.0 : 1.0) * (dz == 0 ? 2.0 : 1.0) / 16.0;
					for (int oz = 0; oz < 2; oz++)
						for (int ox = 0; ox < 2; ox++)
						{
							double weight = kernel * (ox != 0 ? px - ix : 1.0 - px + ix) * (oz != 0 ? py - iy : 1.0 - py + iy);
							int i = Math.Min(iy + oz, height - 1) * width + Math.Min(ix + ox, width - 1);
							int b = biome[i];
							wooded += b == biomes[0] || b == biomes[1] || b == biomes[2] ? weight : 0.0;
							rocky += b == biomes[3] || b == biomes[4] || b == biomes[5] || b == biomes[6] ? weight : 0.0;
							sandy += b == biomes[7] || b == biomes[8] ? weight : 0.0;
							grass += b == biomes[9] ? weight : 0.0;
							slope += Math.Min((double)slopes[i], 0.4) * weight;
							moist += moisture[i] * weight;
						}
				}
			if (sandy > 0.55) { result[n] = 5; continue; }
			if (kinds[n] == 0)
			{
				bool packed = false;
				for (int v = 0; v + 1 < villages.Length; v += 2)
				{
					double vx = villages[v] - x, vy = villages[v + 1] - y;
					if (Math.Abs(vx) < villageRadius && Math.Abs(vy) < villageRadius && Math.Sqrt(vx * vx + vy * vy) < villageRadius)
					{ packed = true; break; }
				}
				result[n] = packed ? (byte)3 : (rocky > 0.6 && slope > stoneSlope + 0.04 ? (byte)4 : (byte)1);
			}
			else if (rocky > 0.55 || slope > stoneSlope) result[n] = 4;
			else if (wooded > 0.45) result[n] = 6;
			else if (kinds[n] == 2) result[n] = 2;
			else result[n] = grass > 0.6 && moist > 0.32 && slope < 0.10 ? (byte)7 : (byte)2;
		}
		return result;
	}

	private static double RoadSmooth(double a, double b, double x)
	{
		double t = Math.Clamp((x - a) / (b - a), 0.0, 1.0);
		return t * t * (3.0 - 2.0 * t);
	}
	private static double RoadLerp(double a, double b, double t) => a + (b - a) * t;
	private const float CorridorLandformReach = 10.0f;

	private static double CorridorTurnAngle(Vector2[] points, int from, int to, int i, int radius, bool normalize = false)
	{
		Vector2 entry = points[i] - points[Math.Max(from, i - radius)];
		Vector2 exit = points[Math.Min(to - 1, i + radius)] - points[i];
		return Math.Abs(normalize ? entry.Normalized().AngleTo(exit.Normalized()) : entry.AngleTo(exit));
	}

	// RoadRefinement.BENCH (11.11.2026): полка в склон с умеренного поперечного уклона, а не только на крутом
	private const double BenchLo = 0.15, BenchHi = 0.45;
	// The index stores the two endpoint half-widths consecutively for each segment.
	private static double RoadMaxHalf(double[] halves, int id) => Math.Max(halves[2 * id], halves[2 * id + 1]);
	private static double RoadHalfAt(double[] halves, int id, double u) => RoadLerp(halves[2 * id], halves[2 * id + 1], u);

	// RoadRefinement.tread_mask: shared by the whole-network and batched vertex paths.
	private static double RoadTreadMask(double half, double distance, double slow, double organic, bool authored, double grain, double[] tread)
	{
		if (authored)
		{
			double originalEdge = (half + slow * 0.24 + grain * 0.10) * (1.0 - organic * 0.12);
			double originalShoulder = (0.7 + (slow + 1.0) * 0.3) * (1.0 + organic * 0.5);
			return (1.0 - RoadSmooth(originalEdge * 0.55, originalEdge + originalShoulder, distance)) * (1.0 - organic * 0.35);
		}
		// RoadSection.tread_alpha (natural roads).
		double edge = half * (tread[0] - organic * tread[1]) + slow * tread[2] * Math.Min(1.0, half / tread[3]);
		double ramp = Math.Clamp(half * tread[4], tread[5], tread[6]);
		return Math.Clamp(0.5 + (edge - distance) / ramp, 0.0, 1.0);
	}
	// FIT_FADE at the boundary of the prepared mesh; never add a lip against OuterLand.
	private static double RoadReliefEdge(Vector2 p, int width, int height, double tile)
		=> RoadSmooth(0.0, 12.0, Math.Min(Math.Min(p.X - tile * 0.5, (width - 0.5) * tile - p.X),
			Math.Min(p.Y - tile * 0.5, (height - 0.5) * tile - p.Y)));
	private static double RoadBell(double t)
	{
		double q = 1.0 - t * t;
		return q > 0.0 ? q * q : 0.0;
	}
	private const int CorridorStride = 8;
	private const double CorridorHollowW = 0.6;

	/// <summary>RoadRefinement._vertex, forms of the corridor at one vertex (station in STEP units).
	/// Returns the height to add before pins; the cross section and bank for the colour.</summary>
	private static double RoadCorridorShape(double[] cor, int start, int count, double station, double side, double d, double half,
		FastNoiseLite noise, double x, double z,
		out double section, out double bank)
	{
		double at = Math.Clamp(station, 0.0, count - 1.0);
		int j = Math.Min(count - 2, (int)Math.Floor(at));
		double f = at - j;
		int o = start + j * CorridorStride, q = o + CorridorStride;
		double lift = RoadLerp(cor[o], cor[q], f), tilt = RoadLerp(cor[o + 1], cor[q + 1], f), dish = RoadLerp(cor[o + 2], cor[q + 2], f);
		double hollow = RoadLerp(cor[o + 3], cor[q + 3], f), hollowAt = RoadLerp(cor[o + 4], cor[q + 4], f);
		double sideNeg = RoadLerp(cor[o + 5], cor[q + 5], f), sidePos = RoadLerp(cor[o + 6], cor[q + 6], f);
		double across = side / half;
		double s = Math.Clamp(across, -1.0, 1.0);
		section = tilt * s + dish * (1.0 - s * s) - hollow * RoadBell((across - hollowAt) / CorridorHollowW);
		double core = (lift + section) * (1.0 - RoadSmooth(half, half + 1.5, d));
		double e = d - half;
		double v = across < 0.0 ? sideNeg : sidePos;
		bank = v > 0.0 ? v * RoadBell((e - 0.35) / 0.8) : v * RoadBell((e - 0.85) / 0.65);
		double strength = RoadLerp(cor[o + 7], cor[q + 7], f);
		double land = 0.0;
		if (strength > 0.0)
		{
			double contour = noise.GetNoise2D((float)(x * 0.027 + z * 0.016 + 629.0), (float)(z * 0.028 - x * 0.016 - 137.0));
			double patch = noise.GetNoise2D((float)(x * 0.012 - 79.0), (float)(z * 0.012 + 401.0));
			double cut = RoadBell((contour - 0.12) / 0.21) * RoadSmooth(-0.2, 0.35, patch);
			double blend = (1.0 - RoadSmooth(0.8, 5.0, e)) * RoadLerp(0.72, 1.0, RoadSmooth(0.0, 1.8, e));
			land = -cut * 0.32 * strength * blend;
		}
		return core + bank + land;
	}

	private static void RoadCorridorColor(ref Color color, double section, double bank, double gain)
	{
		double shade = Math.Clamp(section * gain * 2.5, -0.22, 0.12);
		color.R = (float)(color.R * (1.0 + shade));
		color.G = (float)(color.G * (1.0 + shade));
		color.B = (float)(color.B * (1.0 + shade));
	}

	private static double RoadShoulder(double side, double cross, double n, double slope, double ditch, double lip)
	{
		double flat = n >= 0.0 ? lip * Math.Min(1.0, n * 2.5) : -ditch * Math.Min(1.0, -n * 2.5);
		double sloped = side * cross > 0.0 ? -ditch * (0.7 + 0.3 * n) : lip * (0.6 + 0.4 * n);
		return RoadLerp(flat, sloped, slope);
	}

	/// <summary>RoadRefinement._corridor_reference for one route of RoadFitNetwork (docs/ROAD_RELIEF.md): stations
	/// from..to every `step` m, their half width, surface and gate (fit allowance times corridor bit); the kind indexes CorridorParams.Kinds
	/// (Roads.CorridorParams — typed settings from RoadRefinement.corridor_params). Another path or a hairpin of the same route closer than both half widths
	/// + gap closes the tread gate. Wider terrain forms require additional clearance. Writes eight doubles per station.</summary>
	/// <summary>RoadBump.patch(x, z).x — медленное поле участков (копия; оно же в шейдере road_patch и у RoadObstacles).</summary>
	private static double RoadPatchX(double x, double z) =>
		0.5 + 0.5 * (0.55 * Math.Sin(0.083 * x + 0.047 * z + 1.7) + 0.45 * Math.Sin(-0.039 * x + 0.091 * z + 4.1));

	private static void CorridorRoute(int from, int to, int kind, double scale, int route, Vector2[] points, float[] half, int[] surface,
		float[] gate, float[] fitProfile, float[] fitStrength, float[] fitLimit, float[] raw, float[] bedHeights, int width, int height, double tile, FastNoiseLite noise, Vector2 origin, double step,
		CorridorParams cp, int[] routeKinds, Vector2[] segA, Vector2[] segDelta, double[] segLen2, double[] segHalf, int[] segRoute,
		double[] segAlong, int[] cellStarts, int[] candidates, double[] outv)
	{
		// 15.11: характер по покрытию и признак ритма по RoadBump.patch (копия RoadRefinement); числа — из CorridorParams
		var kp = cp.Kinds[kind];
		double fade = cp.Fade, gap = cp.Gap, landGap = cp.Fit.LandGap, shared = cp.Fit.Shared;
		int stride = cp.Stride;
		bool rhythm = cp.Rhythm;
		int n = to - from;
		double holes = scale >= 1.0 ? 1.0 : 0.0;
		var open = new double[n];
		var landDist = new double[n];
		for (int j = 0; j < n; j++)
		{
			open[j] = gate[from + j];
			Vector2 tangent = (points[Math.Min(to - 1, from + j + 2)] - points[Math.Max(from, from + j - 2)]).Normalized();
			double clearance = open[j] > 0.0 ? RoadClearance(points[from + j], tangent, route, j * step, half[from + j], width, height, tile, gap,
				landGap, shared, routeKinds, segA, segDelta, segLen2, segHalf, segRoute, segAlong, cellStarts, candidates) : 0.0;
			if (clearance < gap) open[j] = 0.0;
			landDist[j] = clearance < landGap || j == 0 || j == n - 1 ? 0.0 : landDist[j - 1] + step;
		}
		var dist = new double[n];
		for (int j = 0; j < n; j++) dist[j] = open[j] <= 0.0 || j == 0 ? 0.0 : dist[j - 1] + step;
		double back = 0.0;
		double landBack = 0.0;
		for (int j = n - 1; j >= 0; j--)
		{
			back = open[j] <= 0.0 || j == n - 1 ? 0.0 : back + step;
			dist[j] = Math.Min(dist[j], back);
			landBack = landDist[j] == 0.0 ? 0.0 : landBack + step;
			landDist[j] = Math.Min(landDist[j], landBack);
		}
		// высота оси по станциям и скользящие суммы — выравнивание спокойных участков (копия RoadRefinement).
		// 16.11: у дорог и троп ось после подгонки профиля — без двойного выравнивания троп
		var bed = new double[n];
		var bedSum = new double[n + 1];
		for (int j = 0; j < n; j++)
		{
			bed[j] = RoadGround(bedHeights, width, height, tile, points[from + j].X, points[from + j].Y);
			if (kind != 2)
				bed[j] += Math.Clamp((double)fitProfile[from + j] - bed[j], -(double)fitLimit[from + j], (double)fitLimit[from + j]) * fitStrength[from + j];
			bedSum[j + 1] = bedSum[j] + bed[j];
		}
		var lift = new double[n];
		int ledgeRadius = Math.Min(kp.LedgeSampleStations, n - 1);
		int ledgeTurnRadius = Math.Min(kp.LedgeTurnStations, n - 1);
		bool shapeLedges = kp.LedgeCrest.IsValid && kp.LedgeDescent.IsValid;
		bool shapeRuts = kp.RutDepth.IsValid && kp.RutNoise.IsValid;
		for (int j = 0; j < n; j++)
		{
			int i = from + j;
			double g = open[j] * RoadSmooth(0.0, fade, dist[j]);
			if (g <= 0.0) continue;
			Vector2 tangent = (points[Math.Min(to - 1, i + 2)] - points[Math.Max(from, i - 2)]).Normalized();
			var acrossV = new Vector2(tangent.Y, -tangent.X);
			double hw = half[i];
			double reach = hw + 3.0;
			Vector2 a = points[i] + acrossV * (float)reach, b = points[i] - acrossV * (float)reach;
			double cross = (RoadGround(raw, width, height, tile, a.X, a.Y) - RoadGround(raw, width, height, tile, b.X, b.Y)) / (2.0 * reach);
			int g0 = Math.Max(from, i - 5), g1 = Math.Min(to - 1, i + 5);
			double grade = Math.Abs(RoadGround(raw, width, height, tile, points[g1].X, points[g1].Y)
				- RoadGround(raw, width, height, tile, points[g0].X, points[g0].Y)) / Math.Max(1.0, g1 - g0) / step;
			Vector2 p = points[i] + origin;
			double character = rhythm ? (Math.Floor(RoadPatchX(p.X, p.Y) * 1048576.0) / 1048576.0 - 0.5) * cp.RhythmSpan : noise.GetNoise2D((float)(p.X * 0.005 + 311.0), (float)(p.Y * 0.005 - 97.0));
			int cAt = surface[i] * 3;
			double roll = noise.GetNoise2D((float)(p.X * 0.033 + 17.0), (float)(p.Y * 0.033 + 53.0));
			double bump = noise.GetNoise2D((float)(p.X * 0.1 - 41.0), (float)(p.Y * 0.1 + 9.0));
			Vector2 wide = acrossV * 6.0f;
			double wobble = ((double)noise.GetNoise2D((float)(((double)p.X + wide.X) * 0.045 + 88.0), (float)(((double)p.Y + wide.Y) * 0.045 - 14.0))
				- noise.GetNoise2D((float)(((double)p.X - wide.X) * 0.045 + 88.0), (float)(((double)p.Y - wide.Y) * 0.045 - 14.0))) * 0.9;
			double bowl = noise.GetNoise2D((float)(p.X * 0.022 - 201.0), (float)(p.Y * 0.022 + 77.0));
			double hole = noise.GetNoise2D((float)(p.X * 0.12 + 57.0), (float)(p.Y * 0.12 + 211.0));
			Vector2 near = acrossV * 4.0f;
			double spot = (double)noise.GetNoise2D((float)(((double)p.X + near.X) * 0.04 - 140.0), (float)(((double)p.Y + near.Y) * 0.04 + 33.0))
				- noise.GetNoise2D((float)(((double)p.X - near.X) * 0.04 - 140.0), (float)(((double)p.Y - near.Y) * 0.04 + 33.0));
			Vector2 outR = p + acrossV * (float)(hw + 1.5), outL = p - acrossV * (float)(hw + 1.5);
			double left = noise.GetNoise2D((float)(outL.X * 0.028 + 400.0), (float)(outL.Y * 0.028 + 12.0));
			double right = noise.GetNoise2D((float)(outR.X * 0.028 + 400.0), (float)(outR.Y * 0.028 + 12.0));
			double lumpL = noise.GetNoise2D((float)(outL.X * 0.11 + 37.0), (float)(outL.Y * 0.11 - 19.0));
			double lumpR = noise.GetNoise2D((float)(outR.X * 0.11 + 37.0), (float)(outR.Y * 0.11 - 19.0));
			double energy = RoadLerp(0.3, 1.0, RoadSmooth(-0.3, 0.0, character)) + 0.5 * RoadSmooth(0.15, 0.4, character);
			energy *= 1.0 + 0.5 * RoadSmooth(0.05, 0.15, grade);
			double broken = RoadSmooth(0.12, 0.35, character);
			double mul = cp.SurfaceGain[surface[i]] * scale;
			int at = i * stride;
			Vector2 reachAlong = tangent * CorridorLandformReach;
			double rawMid = RoadGround(raw, width, height, tile, points[i].X, points[i].Y);
			double rawA = RoadGround(raw, width, height, tile, (double)points[i].X - reachAlong.X, (double)points[i].Y - reachAlong.Y);
			double rawB = RoadGround(raw, width, height, tile, (double)points[i].X + reachAlong.X, (double)points[i].Y + reachAlong.Y);
			double curve = rawMid - (rawA + rawB) * 0.5;
			double landform = RoadSmooth(0.035, 0.16, Math.Abs(curve)) * (kind == 0 ? 1.0 : 0.55);
			double terrainLift = Math.Clamp(curve, -0.35, 0.35) * (1.0 - RoadSmooth(0.25, 0.5, Math.Max(grade, Math.Abs(cross))));
			double freeLift = kp.Roll * roll * (0.6 + 0.4 * energy) * cp.Character[cAt] + kp.Bump * bump * energy * cp.Character[cAt + 1];
			lift[j] = RoadLerp(freeLift, terrainLift, landform) * mul * g;
			if (kp.TechnicalRelief > 0.0 && ledgeRadius > 0 && (shapeLedges || shapeRuts))
			{
				// Short ledges on roundovers and runnels on concave ground. Select coherent terrain
				// patches, then use the same metre stations and grade limiter as the corridor.
				Vector2 before = points[Math.Max(from, i - ledgeRadius)], after = points[Math.Min(to - 1, i + ledgeRadius)];
				double h0 = RoadGround(raw, width, height, tile, before.X, before.Y);
				double h1 = RoadGround(raw, width, height, tile, after.X, after.Y);
				double crest = rawMid - (h0 + h1) * 0.5;
				double pitch = Math.Max(0.0, (h0 - h1) / (2.0 * kp.LedgeSampleStations * step));
				double exposed = surface[i] == 4 ? 1.0 : kp.LedgeSoilGain;
				double lip = shapeLedges
					? RoadSmooth(kp.LedgeCrest.Min, kp.LedgeCrest.Max, crest) * RoadSmooth(kp.LedgeDescent.Min, kp.LedgeDescent.Max, pitch) * exposed
					: 0.0;
				double rut = shapeRuts
					? RoadSmooth(kp.RutDepth.Min, kp.RutDepth.Max, -crest) * RoadSmooth(kp.RutNoise.Min, kp.RutNoise.Max, hole)
					: 0.0;
				if (shapeLedges && kp.HasShelf && kp.LedgeExposure.IsValid)
				{
					// Leave a braking approach and a supported runout before adding a lip to a crest.
					double turn = ledgeTurnRadius > 0 ? CorridorTurnAngle(points, from, to, i, ledgeTurnRadius, normalize: true) : 0.0;
					double approach = Math.Abs(rawMid - rawA) / CorridorLandformReach;
					double landing = Math.Abs(rawB - h1) / Math.Max(1.0, CorridorLandformReach - kp.LedgeSampleStations * step);
					double exposure = Math.Abs(cross) * kp.NaturalCross + Math.Max(approach, landing) + turn * kp.LedgeTurnWeight;
					lip *= 1.0 - RoadSmooth(kp.LedgeExposure.Min, kp.LedgeExposure.Max, exposure);
				}
				lift[j] += kp.TechnicalRelief * (lip - kp.RutGain * rut) * g;
			}
			if (rhythm)
			{
				int lr = Math.Min(cp.LevelR, Math.Min(j, n - 1 - j));
				double deviation = bed[j] - (bedSum[j + lr + 1] - bedSum[j - lr]) / (2 * lr + 1);
				double calm = 1.0 - RoadSmooth(-0.3, 0.15, character);
				lift[j] -= deviation * Math.Min(0.9, cp.LevelKind[kind] * cp.LevelSurface[surface[i]]) * calm * g;
			}
			double natural = cross * kp.Keep * (1.0 - RoadSmooth(0.25, 0.5, Math.Abs(cross))) * hw;
			double baseTilt = natural * (1.0 - kp.NaturalCross);
			if (kp.TurnBank != 0.0 && j >= 2 && j <= n - 3)
			{
				int b0 = Math.Max(from, i - 5), b1 = Math.Min(to - 1, i + 5);
				Vector2 tPrev = (points[i] - points[b0]).Normalized();
				Vector2 tNext = (points[b1] - points[i]).Normalized();
				double chord = Math.Max(1.0, (b1 - b0) * 0.5 * step);
				double kappa = (tNext - tPrev).Dot(acrossV) / chord;
				baseTilt -= kappa * kp.TurnBank * hw;
			}
			double limit = kp.Max * hw;
			outv[at + 1] = Math.Clamp(baseTilt + kp.Tilt * wobble * (0.5 + 0.5 * energy) * cp.Character[cAt + 2], -limit, limit) * scale * g;
			outv[at + 2] = (kp.Dish + kp.DishVar * bowl) * (0.5 + 0.5 * energy) * scale * g;
			outv[at + 3] = kp.Hollow * RoadSmooth(0.2, 0.55, hole) * RoadLerp(0.3, 1.0, broken) * mul * holes * g;
			outv[at + 4] = Math.Clamp(spot * 1.6, -0.7, 0.7);
			double slope = RoadSmooth(0.04, 0.15, Math.Abs(cross));
			double gain = (0.6 + 0.4 * energy) * scale * g;
			outv[at + 5] = RoadShoulder(-1.0, cross, left, slope, kp.Ditch, kp.Lip) * gain * RoadLerp(0.2, 1.25, RoadSmooth(-0.35, 0.35, lumpL));
			outv[at + 6] = RoadShoulder(1.0, cross, right, slope, kp.Ditch, kp.Lip) * gain * RoadLerp(0.2, 1.25, RoadSmooth(-0.35, 0.35, lumpR));
			double gradeMax = Math.Max(grade, Math.Abs(cross));
			double landSlope = (0.3 + 0.7 * RoadSmooth(0.02, 0.18, gradeMax)) * (1.0 - RoadSmooth(0.28, 0.58, gradeMax));
			outv[at + 7] = holes * mul * g * RoadSmooth(0.0, cp.Fit.FitFade, landDist[j]) * landSlope * RoadSmooth(-0.25, 0.12, character) * RoadLerp(0.35, 1.0, RoadSmooth(0.02, 0.3, -curve));
		}
		double cap = kp.Grade * step;
		// Bound by the distance to every protected zero before the slope passes. Otherwise
		// clamping a zero against a high neighbour can move the protected station itself.
		for (int j = 0; j < n; j++) lift[j] = Math.Clamp(lift[j], -cap * dist[j] / step, cap * dist[j] / step);
		for (int j = 1; j < n; j++) lift[j] = Math.Clamp(lift[j], lift[j - 1] - cap, lift[j - 1] + cap);
		for (int j = n - 2; j >= 0; j--) lift[j] = Math.Clamp(lift[j], lift[j + 1] - cap, lift[j + 1] + cap);
		for (int j = 0; j < n; j++) outv[(from + j) * stride] = dist[j] == 0.0 ? 0.0 : lift[j];
	}

	/// <summary>RoadRefinement._fit_network for the whole network in one call (14.11): stations every `step` m of every road,
	/// trail and mountain trail (routes in CSR ptStarts, px/py/pw in cells, psurf per point), profile fit of roads and
	/// trails (_fit_route), gate of the corridor forms and the forms themselves (CorridorRoute). Same operations in the same
	/// order as the GDScript reference; PackedFloat32Array stores are rounded to float. kinds: 0 road, 1 trail, 2 mountain;
	/// scales: corridor scale of the route (0 — no forms; natural mountain profiles still carry protection gates). settings: Roads.CorridorParams (fit: shore,
	/// pin, pin fade, reach, shared, fit fade, fit limit, road bench limit, trail bench limit.
	/// Returns profile and corridor columns by included route and station.</summary>
	private static RoadFitData RoadFitNetwork(int[] ptStarts, double[] px, double[] py, double[] pw, int[] psurf, int[] kinds,
		float[] scales, int[] routeIds, int width, int height, double tile, double step, float[] ground, float[] raw, float[] water,
		float[] distWater, double[] structureAxes, double[] settlements, RoadSegments index, FastNoiseLite noise,
		Vector2 origin, Godot.Collections.Dictionary settings, byte[] authoredRoutes, byte[] localRoutes)
	{
		var segA = index.A;
		var segDelta = index.Delta;
		var segLen2 = index.Len2;
		var segHalf = index.Half;
		var segRoute = index.Route;
		var segAlong = index.Along;
		var cellStarts = index.CellStarts;
		var candidates = index.Candidates;
		// Each section exists once; only identical route IDs share an alignment.
		var routeKinds = new int[authoredRoutes.Length];
		for (int route = 0; route < routeKinds.Length; route++)
			routeKinds[route] = route;
		var cp = new CorridorParams(settings);
		var fp = cp.Fit;
		double gap = cp.Gap;
		int stride = cp.Stride;
		double shore = fp.Shore, pinStart = fp.Pin, pinFade = fp.PinFade, reach = fp.Reach, shared = fp.Shared;
		double fitFade = fp.FitFade, fitLimit = fp.FitLimit, roadBench = fp.RoadBench, trailBench = fp.TrailBench;
		RoadStructureIndex(width, height, tile, structureAxes, pinStart + pinFade, out int[] structStarts, out double[] structs);
		float ftile = (float)tile;
		var included = new System.Collections.Generic.List<int>();
		var starts = new System.Collections.Generic.List<int>();
		var points = new System.Collections.Generic.List<Vector2>();
		var halves = new System.Collections.Generic.List<float>();
		var surfs = new System.Collections.Generic.List<int>();
		for (int t = 0; t < routeIds.Length; t++)
		{
			if (localRoutes.Length != 0 && localRoutes[routeIds[t]] == 0)
				continue;
			int from = ptStarts[t], to = ptStarts[t + 1], first = points.Count;
			double along = 0.0, next = 0.0;
			for (int n = from + 1; n < to; n++)
			{
				var a = new Vector2((float)px[n - 1], (float)py[n - 1]) * ftile;
				var b = new Vector2((float)px[n], (float)py[n]) * ftile;
				double length = a.DistanceTo(b);
				if (length < 0.01) continue;
				while (next <= along + length)
				{
					double f = (next - along) / length;
					points.Add(a.Lerp(b, (float)f));
					halves.Add((float)(RoadLerp(pw[n - 1], pw[n], f) * tile * 0.5));
					surfs.Add(f < 0.5 ? psurf[n - 1] : psurf[n]);
					next += step;
				}
				along += length;
			}
			if (points.Count - first < 3)
			{
				points.RemoveRange(first, points.Count - first);
				halves.RemoveRange(first, halves.Count - first);
				surfs.RemoveRange(first, surfs.Count - first);
				continue;
			}
			included.Add(t);
			starts.Add(first);
		}
		starts.Add(points.Count);
		int total = points.Count, count = included.Count;
		var pts = points.ToArray();
		var half = halves.ToArray();
		var surface = surfs.ToArray();
		var gate = new float[total];
		var profile = new float[total];
		var strength = new float[total];
		var limits = new float[total];
		var corridor = new double[total * stride];
		var routes = new int[count];
		var routeStarts = starts.ToArray();
		var scaleOf = new float[count];
		for (int r = 0; r < count; r++)
		{
			int t = included[r];
			routes[r] = routeIds[t];
			scaleOf[r] = scales[t];
		}
		System.Threading.Tasks.Parallel.For(0, count, r =>
		{
			int t = included[r], from = routeStarts[r], to = routeStarts[r + 1], n = to - from;
			bool road = kinds[t] == 0, trail = kinds[t] == 1;
			var kind = cp.Kinds[kinds[t]];
			if (kinds[t] == 2)
			{
				var distance = new float[n];
				for (int j = 0; j < n; j++)
				{
					Vector2 tangent = (pts[from + Math.Min(n - 1, j + 2)] - pts[from + Math.Max(0, j - 2)]).Normalized();
					int safe = FitSafe(pts[from + j], tangent, routes[r], j * step, false, half[from + j], width, height, tile, water,
						distWater, shore, structStarts, structs, pinStart + pinFade, segA, segDelta, segLen2, segHalf, segRoute, segAlong,
						cellStarts, candidates, reach, shared, settlements, routeKinds, gap);
					gate[from + j] = (safe & 2) != 0 ? 1.0f : 0.0f;
					profile[from + j] = (float)RoadGround(ground, width, height, tile, pts[from + j].X, pts[from + j].Y);
					distance[j] = safe == 0 || j == 0 ? 0.0f : (float)(distance[j - 1] + step);
				}
				double back = 0.0;
				for (int j = n - 1; j >= 0; j--)
				{
					back = j == n - 1 || distance[j] == 0.0f ? 0.0 : back + step;
					distance[j] = (float)Math.Min(distance[j], back);
				}
				for (int j = 0; j < n; j++)
				{
					strength[from + j] = (float)RoadSmooth(0.0, fitFade, distance[j]);
					limits[from + j] = scales[t] > 0.0 ? 0.6f : 0.3f;
				}
			}
			else
			{
				var groundAt = new float[n];
				var need = new float[n];
				var crossSlopes = new float[n];
				var allowed = new float[n];
				var distance = new float[n];
				for (int j = 0; j < n; j++) groundAt[j] = (float)RoadGround(ground, width, height, tile, pts[from + j].X, pts[from + j].Y);
				for (int j = 0; j < n; j++)
				{
					Vector2 p = pts[from + j];
					int lo = Math.Max(0, j - 2), hi = Math.Min(n - 1, j + 2);
					Vector2 tangent = (pts[from + hi] - pts[from + lo]).Normalized();
					Vector2 normal = new Vector2(-tangent.Y, tangent.X) * 1.5f;
					double crossGrade = Math.Abs(RoadGround(ground, width, height, tile, (double)p.X + normal.X, (double)p.Y + normal.Y)
						- RoadGround(ground, width, height, tile, (double)p.X - normal.X, (double)p.Y - normal.Y)) / 3.0;
					crossSlopes[j] = (float)crossGrade;
					double grade = Math.Abs((double)groundAt[hi] - groundAt[lo]) / Math.Max((hi - lo) * step, step);
					double ripple = Math.Abs((double)groundAt[Math.Max(0, j - 4)] - 2.0 * groundAt[j] + groundAt[Math.Min(n - 1, j + 4)]) / (8.0 * step);
					need[j] = (float)Math.Max(RoadSmooth(0.02, 0.10, crossGrade), Math.Max(RoadSmooth(0.08, 0.30, grade), RoadSmooth(0.004, 0.035, ripple)));
					lo = Math.Max(0, j - 12);
					hi = Math.Min(n - 1, j + 12);
					double sustained = Math.Abs((double)groundAt[hi] - groundAt[lo]) / Math.Max((hi - lo) * step, step);
					allowed[j] = kind.HasShelf ? 1.0f : (float)(1.0 - RoadSmooth(0.45, 0.7, sustained));
					int safe = FitSafe(p, tangent, routes[r], j * step, road, half[from + j], width, height, tile, water, distWater, shore,
						structStarts, structs, pinStart + pinFade, segA, segDelta, segLen2, segHalf, segRoute, segAlong, cellStarts, candidates,
						reach, shared, settlements, routeKinds, gap, Math.Max(grade, crossGrade) <= 0.25);
					gate[from + j] = (safe & 2) != 0 ? allowed[j] : 0.0f;
					if ((safe & 1) == 0) allowed[j] = 0.0f;
					distance[j] = allowed[j] <= 0.0f ? 0.0f : (j > 0 ? (float)(distance[j - 1] + step) : 0.0f);
				}
				double back = 0.0;
				for (int j = n - 1; j >= 0; j--)
				{
					back = j == n - 1 || allowed[j] <= 0.0f ? 0.0 : back + step;
					distance[j] = (float)Math.Min(distance[j], back);
				}
				for (int j = 0; j < n; j++)
				{
					double amount = 0.0, crossSlope = 0.0;
					int lo = Math.Max(0, j - 4), hi = Math.Min(n - 1, j + 4);
					for (int k = lo; k <= hi; k++) { amount += need[k]; crossSlope += crossSlopes[k]; }
					amount /= hi - lo + 1;
					crossSlope /= hi - lo + 1;
					int radius = Math.Min(12, Math.Max(0, (int)Math.Floor(distance[j] / step) - 1));
					int small = Math.Min(4, radius);
					double sumH = 0.0, sumSmall = 0.0;
					for (int k = j - radius; k <= j + radius; k++)
					{
						sumH += groundAt[k];
						if (Math.Abs(k - j) <= small) sumSmall += groundAt[k];
					}
					double average = RoadLerp(sumSmall / (2 * small + 1), sumH / (2 * radius + 1), amount);
					double axialLimit = kind.HasShelf ? kind.SupportCut : RoadLerp(0.15, 0.9, amount) * (trail ? 0.35 : 1.0);
					double smoothing = road && authoredRoutes[routes[r]] == 0 ? 0.0 : RoadLerp(0.35, 0.95, amount) * kind.ProfileFit;
					double target = groundAt[j] + Math.Clamp((average - groundAt[j]) * smoothing, -axialLimit, axialLimit);
					profile[from + j] = (float)target;
					double power = RoadLerp(0.25, 1.0, amount) * allowed[j] * RoadSmooth(0.0, fitFade, distance[j]);
					double trailPower = trail ? RoadLerp(0.55, 0.85, RoadSmooth(0.5, 0.9, crossSlope)) : 1.0;
					strength[from + j] = kind.HasShelf
						? (float)(kind.CrossFit * RoadSmooth(0.0, fitFade, distance[j]))
						: (float)(power * trailPower * kind.CrossFit);
					double cap = RoadLerp(0.2, fitLimit, amount) * (trail ? 0.5 : 1.0);
					double benchLimit = road ? roadBench : trailBench;
					cap = Math.Max(cap, Math.Min(benchLimit, crossSlope * half[from + j]));
					limits[from + j] = (float)cap;
				}
				if (kind.HasShelf && kind.DirectionalGrades.X > 0.0f)
				{
					int radius = Math.Clamp(kind.TurnGradeStations, 0, n - 1);
					var angle = kind.TurnGradeAngle;
					var gradeScale = new double[n];
					for (int j = 0; j < n; j++)
					{
						double turn = CorridorTurnAngle(pts, from, to, from + j, radius);
						gradeScale[j] = radius > 0 && angle.IsValid
							? RoadLerp(1.0, kind.TurnGradeScale, RoadSmooth(angle.Min, angle.Max, turn)) : 1.0;
					}
					// Reduce short grade breaks within the earthwork budget. Long profiles that
					// exhaust the budget remain visible to the routing and ride diagnostics.
					const int relaxPasses = 4;
					for (int pass = 0; pass < relaxPasses; pass++)
					for (int k = 1; k < n; k++)
					{
						int j = pass % 2 == 0 ? k : n - k;
						int a = from + j - 1, b = a + 1;
						double dh = profile[b] - profile[a];
						double localStep = step * Math.Min(gradeScale[j - 1], gradeScale[j]);
						double excess = dh - Math.Clamp(dh, -kind.DirectionalGrades.Y * localStep, kind.DirectionalGrades.X * localStep);
						if (excess == 0.0 || strength[a] <= 0.0f || strength[b] <= 0.0f) continue;
						double cut = kind.SupportCut;
						profile[a] = (float)Math.Clamp(profile[a] + excess * 0.5, groundAt[j - 1] - cut, groundAt[j - 1] + cut);
						profile[b] = (float)Math.Clamp(profile[b] - excess * 0.5, groundAt[j] - cut, groundAt[j] + cut);
					}
				}
			}
			if (scales[t] > 0.0f)
				CorridorRoute(from, to, kinds[t], scales[t], routes[r], pts, half, surface, gate, profile, strength, limits, raw, ground, width, height, tile, noise, origin, step,
					cp, routeKinds, segA, segDelta, segLen2, segHalf, segRoute, segAlong, cellStarts, candidates, corridor);
		});
		return new RoadFitData(routes, routeStarts, scaleOf, pts, profile, strength, limits, corridor, cp.Kinds);
	}

	private sealed record RoadFitData(int[] Routes, int[] Starts, float[] Scales, Vector2[] Points,
		float[] Profile, float[] Strength, float[] Limit, double[] Corridor, Roads.CorridorKind[] Kinds)
	{
		public static readonly RoadFitData Empty = new(Array.Empty<int>(), new[] { 0 }, Array.Empty<float>(),
			Array.Empty<Vector2>(), Array.Empty<float>(), Array.Empty<float>(), Array.Empty<float>(), Array.Empty<double>(), null);
	}

	/// <summary>RoadRefinement._fit_safe on the column index: bit 0 — profile fit allowed, bit 1 — corridor forms too.</summary>
	private static int FitSafe(Vector2 p, Vector2 tangent, int route, double along, bool shoreOk, double ownHalf, int width, int height,
		double tile, float[] water, float[] distWater, double shore, int[] structStarts, double[] structs, double pinReach, Vector2[] segA,
		Vector2[] segDelta, double[] segLen2, double[] segHalf, int[] segRoute, double[] segAlong, int[] cellStarts, int[] candidates,
		double reach, double shared, double[] settlements, int[] routeKinds, double corridorGap, bool shortFold = false)
	{
		int safe = 3;
		int x = (int)Math.Floor(p.X / tile), z = (int)Math.Floor(p.Y / tile);
		if (x < 0 || x >= width || z < 0 || z >= height) return 0;
		int cell = z * width + x;
		if ((!shoreOk && distWater[cell] < shore) || !float.IsNegativeInfinity(water[cell])) return 0;
		int key = Math.Clamp((int)Math.Floor(p.Y / tile - 0.5), 0, height - 2) * width
			+ Math.Clamp((int)Math.Floor(p.X / tile - 0.5), 0, width - 2);
		if (key >= 0 && key < width * height)
		{
			for (int s = structStarts[key]; s < structStarts[key + 1]; s++)
				if (RoadSegmentDistance(p.X, p.Y, structs, s * 4) < pinReach) return 0;
			for (int k = cellStarts[key]; k < cellStarts[key + 1]; k++)
			{
				int id = candidates[k];
				Vector2 a = segA[id], delta = segDelta[id];
				Vector2 b = a + delta;
				bool other = segRoute[id] != route;
				bool crossing = other && Math.Abs(tangent.Dot(delta.Normalized())) < 0.9;
				double combinedHalf = RoadMaxHalf(segHalf, id) + Math.Max(0.0, ownHalf);
				bool hairpin = false;
				if (!other)
				{
					double dot = tangent.Dot(delta);
					bool opposite = shortFold && dot < 0.0 && 4.0 * dot * dot > segLen2[id];
					if (opposite || Math.Abs(segAlong[id] - along) > 20.0)
					{
						Vector2 offset = p - a;
						double u = Math.Clamp((double)offset.Dot(delta) / segLen2[id], 0.0, 1.0);
						double separation = Math.Abs(segAlong[id] + u * Math.Sqrt(segLen2[id]) - along);
						double closeGap = combinedHalf + corridorGap;
						// The two legs can overlap the corridor within the usual 20 m exclusion.
						hairpin = separation > 20.0 || (opposite && separation >= 6.0 &&
							(offset - delta * (float)u).LengthSquared() < Math.Min(closeGap * closeGap, separation * separation * 0.25));
					}
				}
				if (other || hairpin)
				{
					double gapDist = RbSegmentDist(p.X, p.Y, a.X, a.Y, b.X, b.Y);
					if (gapDist < combinedHalf + 2.0 * reach + 0.5)
					{
						if (crossing || hairpin) return 0;
						if (!RoadShared(Math.Abs((p - a).Cross(delta.Normalized())), crossing, route, segRoute[id], ownHalf, RoadMaxHalf(segHalf, id), shared, routeKinds))
						{
							if (gapDist < combinedHalf + corridorGap) return 0;
							safe &= 2;
						}
					}
				}
			}
		}
		for (int v = 0; v + 1 < settlements.Length; v += 2)
			if (p.DistanceTo(new Vector2((float)settlements[v], (float)settlements[v + 1]) * (float)tile) < 10.0) return 0;
		return safe;
	}

	private static bool RoadShared(double gap, bool crossing, int route, int other, double ownHalf, double half, double shared, int[] routeKinds)
		=> route == other || routeKinds[route] == routeKinds[other]; // IDs of proven identical complete routes

	private static double RoadClearance(Vector2 p, Vector2 tangent, int route, double along, double ownHalf, int width, int height, double tile,
		double gap, double landGap, double shared, int[] routeKinds, Vector2[] segA, Vector2[] segDelta, double[] segLen2, double[] segHalf, int[] segRoute, double[] segAlong, int[] cellStarts, int[] candidates)
	{
		int cx = (int)Math.Floor(p.X / tile - 0.5), cz = (int)Math.Floor(p.Y / tile - 0.5);
		double clearance = landGap;
		for (int dz = -1; dz <= 1; dz++)
		{
			for (int dx = -1; dx <= 1; dx++)
			{
				int x = cx + dx, z = cz + dz;
				if (x < 0 || z < 0 || x >= width || z >= height) continue;
				int key = z * width + x;
				for (int c = cellStarts[key]; c < cellStarts[key + 1]; c++)
				{
					int id = candidates[c];
					Vector2 a = segA[id], delta = segDelta[id];
					if (segRoute[id] == route)
					{
						if (Math.Abs(segAlong[id] - along) <= 20.0) continue;
						double u = Math.Clamp((double)(p - a).Dot(delta) / segLen2[id], 0.0, 1.0);
						if (Math.Abs(segAlong[id] + u * Math.Sqrt(segLen2[id]) - along) <= 20.0) continue;
					}
					Vector2 b = a + delta;
					double dist = RbSegmentDist(p.X, p.Y, a.X, a.Y, b.X, b.Y);
					double margin = dist - RoadMaxHalf(segHalf, id) - ownHalf;
					if (margin >= clearance) continue;
					if (segRoute[id] != route && dist < 20.0)
					{
						Vector2 direction = delta.Normalized();
						if (RoadShared(Math.Abs((p - a).Cross(direction)), Math.Abs(tangent.Dot(direction)) < 0.9, route, segRoute[id], ownHalf,
							RoadMaxHalf(segHalf, id), shared, routeKinds)) continue;
					}
					clearance = margin;
					if (clearance < gap) return clearance;
				}
			}
		}
		return clearance;
	}
	// core/math/color.h promotes these constants to double before rounding the pow input.
	// Color.SrgbToLinear() in GodotSharp uses float constants and is not bit-identical.
	private static float RoadLinear(float c) => c < 0.04045f ? c * (1.0f / 12.92f)
		: (float)Math.Pow((float)((c + 0.055) * (1.0 / (1.0 + 0.055))), 2.4f);
	private static double RoadGround(float[] hs, int w, int h, double tile, double x, double z)
	{
		double fx = Math.Clamp(x / tile - 0.5, 0.0, w - 1.001);
		double fz = Math.Clamp(z / tile - 0.5, 0.0, h - 1.001);
		int ix = (int)Math.Floor(fx), iz = (int)Math.Floor(fz), i = iz * w + ix;
		double tx = fx - ix, tz = fz - iz;
		double a = hs[i], b = hs[i + 1], c = hs[i + w], d = hs[i + w + 1];
		return tx + tz <= 1.0 ? a + (b - a) * tx + (c - a) * tz
			: d + (c - d) * (1.0 - tx) + (b - d) * (1.0 - tz);
	}
	private static double RoadWet(float[] water, int w, int h, int cell)
	{
		int x = cell % w, z = cell / w;
		double top = double.NegativeInfinity;
		for (int k = 0; k < 8; k++)
		{
			int nx = x + Dx[k], nz = z + Dy[k];
			if (nx >= 0 && nz >= 0 && nx < w && nz < h) top = Math.Max(top, water[nz * w + nx]);
		}
		return top;
	}
	private static double RoadSegmentDistance(double x, double z, double[] axes, int at)
	{
		double ax = axes[at], az = axes[at + 1], dx = axes[at + 2] - ax, dz = axes[at + 3] - az;
		double l2 = dx * dx + dz * dz;
		double t = l2 > 0.0 ? Math.Clamp(((x - ax) * dx + (z - az) * dz) / l2, 0.0, 1.0) : 0.0;
		double ox = x - ax - dx * t, oz = z - az - dz * t;
		return Math.Sqrt(ox * ox + oz * oz);
	}
}
