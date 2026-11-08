using System;
using Godot;
using Simd = System.Numerics.Vector<double>;

public partial class FastGrid
{
	private static double RoadSmooth(double a, double b, double x)
	{
		double t = Math.Clamp((x - a) / (b - a), 0.0, 1.0);
		return t * t * (3.0 - 2.0 * t);
	}
	private static double RoadLerp(double a, double b, double t) => a + (b - a) * t;
	// FIT_FADE at the boundary of the prepared mesh; never add a lip against OuterLand.
	private static double RoadReliefEdge(Vector2 p, int width, int height, double tile)
		=> RoadSmooth(0.0, 12.0, Math.Min(Math.Min(p.X - tile * 0.5, (width - 0.5) * tile - p.X),
			Math.Min(p.Y - tile * 0.5, (height - 0.5) * tile - p.Y)));
	private static double RoadBell(double t)
	{
		double q = 1.0 - t * t;
		return q > 0.0 ? q * q : 0.0;
	}
	private const int CorridorStride = 7;
	private const double CorridorHollowW = 0.6;

	/// <summary>RoadRefinement._vertex, forms of the corridor at one vertex (station in STEP units).
	/// Returns the height to add before pins; the cross section and bank for the colour.</summary>
	private static double RoadCorridorShape(double[] cor, int start, int count, double station, double side, double d, double half,
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
		double core = (lift + section) * (1.0 - RoadSmooth(half + 0.3, half + 2.2, d));
		double e = d - half;
		double v = across < 0.0 ? sideNeg : sidePos;
		bank = v > 0.0 ? v * RoadBell((e - 0.35) / 0.8) : v * RoadBell((e - 1.3) / 0.75);
		return core + bank;
	}

	private static void RoadCorridorColor(ref Color color, double section, double bank, double gain)
	{
		double shade = Math.Clamp(section * gain * 2.5, -0.22, 0.12);
		color.R = (float)(color.R * (1.0 + shade));
		color.G = (float)(color.G * (1.0 + shade));
		color.B = (float)(color.B * (1.0 + shade));
		color.A = (float)(color.A * (1.0 - Math.Clamp(Math.Max(0.0, bank) * gain * 4.0, 0.0, 0.5)));
	}

	private static double RoadShoulder(double side, double cross, double n, double slope, double ditch, double lip)
	{
		double flat = n >= 0.0 ? lip * Math.Min(1.0, n * 2.5) : -ditch * Math.Min(1.0, -n * 2.5);
		double sloped = side * cross > 0.0 ? -ditch * (0.7 + 0.3 * n) : lip * (0.6 + 0.4 * n);
		return RoadLerp(flat, sloped, slope);
	}

	/// <summary>RoadRefinement._corridor_reference for one route of RoadFitNetwork (docs/ROAD_RELIEF.md): stations
	/// from..to every `step` m, their half width, surface and gate (fit allowance times corridor bit); the kind indexes `table`
	/// (11 numbers per kind, then the surface gains). Another path or a hairpin of the same route closer than both half widths
	/// + gap (segments of the 3 x 3 index cells) closes the gate. Writes 7 doubles per station (lift, tilt, dish, hollow,
	/// hollow_at, side_neg, side_pos).</summary>
	private static void CorridorRoute(int from, int to, int kind, double scale, int route, Vector2[] points, float[] half, int[] surface,
		float[] gate, float[] raw, int width, int height, double tile, FastNoiseLite noise, Vector2 origin, double step, double fade,
		double gap, double shared, int[] routeKinds, int stride, double[] table, Vector2[] segA, Vector2[] segDelta, double[] segLen2, double[] segHalf, int[] segRoute,
		double[] segAlong, int[] cellStarts, int[] candidates, double[] outv)
	{
		int kindSize = 11, surfaceAt = kindSize * 3;
		int n = to - from, k = kind * kindSize;
		double holes = scale >= 1.0 ? 1.0 : 0.0;
		var open = new double[n];
		for (int j = 0; j < n; j++)
		{
			open[j] = gate[from + j];
			Vector2 tangent = (points[Math.Min(to - 1, from + j + 2)] - points[Math.Max(from, from + j - 2)]).Normalized();
			if (open[j] > 0.0 && RoadCrowded(points[from + j], tangent, route, j * step, half[from + j], width, height, tile, gap, shared,
				routeKinds, segA, segDelta, segLen2, segHalf, segRoute, segAlong, cellStarts, candidates)) open[j] = 0.0;
		}
		var dist = new double[n];
		for (int j = 0; j < n; j++) dist[j] = open[j] <= 0.0 || j == 0 ? 0.0 : dist[j - 1] + step;
		double back = 0.0;
		for (int j = n - 1; j >= 0; j--)
		{
			back = open[j] <= 0.0 || j == n - 1 ? 0.0 : back + step;
			dist[j] = Math.Min(dist[j], back);
		}
		var lift = new double[n];
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
			double character = noise.GetNoise2D((float)(p.X * 0.005 + 311.0), (float)(p.Y * 0.005 - 97.0));
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
			double energy = RoadLerp(0.3, 1.0, RoadSmooth(-0.3, 0.0, character)) + 0.5 * RoadSmooth(0.15, 0.4, character);
			energy *= 1.0 + 0.5 * RoadSmooth(0.05, 0.15, grade);
			double broken = RoadSmooth(0.12, 0.35, character);
			double mul = table[surfaceAt + surface[i]] * scale;
			int at = i * stride;
			lift[j] = (table[k] * roll * (0.6 + 0.4 * energy) + table[k + 1] * bump * energy) * mul * g;
			double natural = cross * table[k + 3] * (1.0 - RoadSmooth(0.25, 0.5, Math.Abs(cross))) * hw;
			double limit = table[k + 4] * hw;
			outv[at + 1] = Math.Clamp(natural + table[k + 2] * wobble * (0.5 + 0.5 * energy) * scale, -limit, limit) * g;
			outv[at + 2] = (table[k + 5] + table[k + 6] * bowl) * (0.5 + 0.5 * energy) * scale * g;
			outv[at + 3] = table[k + 7] * RoadSmooth(0.2, 0.55, hole) * RoadLerp(0.3, 1.0, broken) * mul * holes * g;
			outv[at + 4] = Math.Clamp(spot * 1.6, -0.7, 0.7);
			double slope = RoadSmooth(0.04, 0.15, Math.Abs(cross)) * (1.0 - RoadSmooth(0.35, 0.6, Math.Abs(cross)));
			double gain = (0.6 + 0.4 * energy) * scale * g;
			outv[at + 5] = RoadShoulder(-1.0, cross, left, slope, table[k + 8], table[k + 9]) * gain;
			outv[at + 6] = RoadShoulder(1.0, cross, right, slope, table[k + 8], table[k + 9]) * gain;
		}
		double cap = table[k + 10] * step;
		for (int j = 1; j < n; j++) lift[j] = Math.Clamp(lift[j], lift[j - 1] - cap, lift[j - 1] + cap);
		for (int j = n - 2; j >= 0; j--) lift[j] = Math.Clamp(lift[j], lift[j + 1] - cap, lift[j + 1] + cap);
		for (int j = 0; j < n; j++) outv[(from + j) * stride] = lift[j];
	}

	/// <summary>RoadRefinement._fit_network for the whole network in one call (14.11): stations every `step` m of every road,
	/// trail and mountain trail (routes in CSR ptStarts, px/py/pw in cells, psurf per point), profile fit of roads and
	/// trails (_fit_route), gate of the corridor forms and the forms themselves (CorridorRoute). Same operations in the same
	/// order as the GDScript reference; PackedFloat32Array stores are rounded to float. kinds: 0 road, 1 trail, 2 mountain;
	/// scales: corridor scale of the route (0 — no forms; a mountain trail without forms is skipped). fitParams: shore,
	/// pin, pin fade, reach, shared, fit fade, fit limit, road bench limit, trail bench limit.
	/// Returns {routes, starts, fitted, points, profile, strength, limit, corridor} — per included route and per station.</summary>
	public Godot.Collections.Dictionary RoadFitNetwork(int[] ptStarts, double[] px, double[] py, double[] pw, int[] psurf, int[] kinds,
		float[] scales, int[] routeIds, int width, int height, double tile, double step, float[] ground, float[] raw, float[] water,
		float[] distWater, double[] structureAxes, double[] settlements, Vector2[] segA, Vector2[] segDelta, double[] segLen2,
		double[] segHalf, int[] segRoute, double[] segAlong, int[] cellStarts, int[] candidates, int[] routeKinds, FastNoiseLite noise,
		Vector2 origin, double[] fitParams, double fade, double gap, int stride, double[] table)
	{
		double shore = fitParams[0], pinStart = fitParams[1], pinFade = fitParams[2], reach = fitParams[3], shared = fitParams[4];
		double fitFade = fitParams[5], fitLimit = fitParams[6], roadBench = fitParams[7], trailBench = fitParams[8];
		RoadStructureIndex(width, height, tile, structureAxes, pinStart + pinFade, out int[] structStarts, out double[] structs);
		float ftile = (float)tile;
		var included = new System.Collections.Generic.List<int>();
		var starts = new System.Collections.Generic.List<int>();
		var points = new System.Collections.Generic.List<Vector2>();
		var halves = new System.Collections.Generic.List<float>();
		var surfs = new System.Collections.Generic.List<int>();
		for (int t = 0; t < routeIds.Length; t++)
		{
			bool fitted = kinds[t] != 2;
			if (!fitted && scales[t] <= 0.0f) continue;
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
		var fittedOut = new byte[count];
		var corridor = new double[total * stride];
		var routes = new int[count];
		var routeStarts = starts.ToArray();
		var kindOf = new int[count];
		var scaleOf = new float[count];
		for (int r = 0; r < count; r++)
		{
			int t = included[r];
			routes[r] = routeIds[t]; kindOf[r] = kinds[t]; scaleOf[r] = scales[t];
			fittedOut[r] = kinds[t] != 2 ? (byte)1 : (byte)0;
		}
		System.Threading.Tasks.Parallel.For(0, count, r =>
		{
			int t = included[r], from = routeStarts[r], to = routeStarts[r + 1], n = to - from;
			bool road = kinds[t] == 0, trail = kinds[t] == 1;
			if (kinds[t] == 2)
			{
				for (int j = 0; j < n; j++)
				{
					Vector2 tangent = (pts[from + Math.Min(n - 1, j + 2)] - pts[from + Math.Max(0, j - 2)]).Normalized();
					gate[from + j] = (FitSafe(pts[from + j], tangent, routes[r], j * step, false, half[from + j], width, height, tile, water,
						distWater, shore, structStarts, structs, pinStart + pinFade, segA, segDelta, segLen2, segHalf, segRoute, segAlong,
						cellStarts, candidates, reach, shared, settlements, routeKinds) & 2) != 0 ? 1.0f : 0.0f;
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
					allowed[j] = (float)(1.0 - RoadSmooth(0.45, 0.7, sustained));
					int safe = FitSafe(p, tangent, routes[r], j * step, road, half[from + j], width, height, tile, water, distWater, shore,
						structStarts, structs, pinStart + pinFade, segA, segDelta, segLen2, segHalf, segRoute, segAlong, cellStarts, candidates,
						reach, shared, settlements, routeKinds);
					if (safe == 0) allowed[j] = 0.0f;
					gate[from + j] = (safe & 2) != 0 ? allowed[j] : 0.0f;
					distance[j] = allowed[j] <= 0.0f ? 0.0f : (j > 0 ? (float)(distance[j - 1] + step) : 0.0f);
				}
				double back = 0.0;
				for (int j = n - 1; j >= 0; j--)
				{
					back = j == n - 1 || allowed[j] <= 0.0f ? 0.0 : back + step;
					distance[j] = (float)Math.Min(distance[j], back);
				}
				double width0 = pw[ptStarts[t]];
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
					double axialLimit = RoadLerp(0.15, 0.9, amount) * (trail ? 0.35 : 1.0);
					double target = groundAt[j] + Math.Clamp((average - groundAt[j]) * RoadLerp(0.35, 0.95, amount), -axialLimit, axialLimit);
					profile[from + j] = (float)target;
					double power = RoadLerp(0.25, 1.0, amount) * allowed[j] * RoadSmooth(0.0, fitFade, distance[j]);
					double trailPower = trail ? RoadLerp(0.55, 0.85, RoadSmooth(0.5, 0.9, crossSlope)) : 1.0;
					strength[from + j] = (float)(power * trailPower);
					double cap = RoadLerp(0.2, fitLimit, amount) * (trail ? 0.5 : 1.0);
					double benchLimit = road ? roadBench : trailBench;
					cap = Math.Max(cap, Math.Min(benchLimit, crossSlope * width0 * tile * 0.5));
					limits[from + j] = (float)cap;
				}
			}
			if (scales[t] > 0.0f)
				CorridorRoute(from, to, kinds[t], scales[t], routes[r], pts, half, surface, gate, raw, width, height, tile, noise, origin, step,
					fade, gap, shared, routeKinds, stride, table, segA, segDelta, segLen2, segHalf, segRoute, segAlong, cellStarts, candidates, corridor);
		});
		return new Godot.Collections.Dictionary
		{
			["routes"] = routes, ["starts"] = routeStarts, ["fitted"] = fittedOut, ["scales"] = scaleOf, ["points"] = pts,
			["profile"] = profile, ["strength"] = strength, ["limit"] = limits, ["corridor"] = corridor,
		};
	}

	/// <summary>RoadRefinement._fit_safe on the column index: bit 0 — profile fit allowed, bit 1 — corridor forms too.</summary>
	private static int FitSafe(Vector2 p, Vector2 tangent, int route, double along, bool shoreOk, double ownHalf, int width, int height,
		double tile, float[] water, float[] distWater, double shore, int[] structStarts, double[] structs, double pinReach, Vector2[] segA,
		Vector2[] segDelta, double[] segLen2, double[] segHalf, int[] segRoute, double[] segAlong, int[] cellStarts, int[] candidates,
		double reach, double shared, double[] settlements, int[] routeKinds)
	{
		int safe = 3;
		int cell = (int)Math.Floor(p.Y / tile) * width + (int)Math.Floor(p.X / tile);
		if (cell < 0 || cell >= width * height || (!shoreOk && distWater[cell] < shore) || !float.IsNegativeInfinity(water[cell])) return 0;
		int key = (int)Math.Floor(p.Y / tile - 0.5) * width + (int)Math.Floor(p.X / tile - 0.5);
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
				bool hairpin = false;
				if (segRoute[id] == route && Math.Abs(segAlong[id] - along) > 20.0)
				{
					double u = Math.Clamp((double)(p - a).Dot(delta) / segLen2[id], 0.0, 1.0);
					hairpin = Math.Abs(segAlong[id] + u * Math.Sqrt(segLen2[id]) - along) > 20.0;
				}
				if (other || hairpin)
				{
					double gapDist = RbSegmentDist(p.X, p.Y, a.X, a.Y, b.X, b.Y);
					if (gapDist < segHalf[id] + reach + 0.5)
					{
						if (crossing || hairpin) return 0;
						if (!RoadShared(gapDist, crossing, route, segRoute[id], ownHalf, segHalf[id], shared, routeKinds)) safe = 1;
					}
				}
			}
		}
		for (int v = 0; v + 1 < settlements.Length; v += 2)
			if (p.DistanceTo(new Vector2((float)settlements[v], (float)settlements[v + 1]) * (float)tile) < 10.0) return 0;
		return safe;
	}

	private static bool RoadShared(double gap, bool crossing, int route, int other, double ownHalf, double half, double shared, int[] routeKinds)
		=> !crossing && gap < shared && ownHalf >= 0.0 && Math.Abs(half - ownHalf) < 0.05 && routeKinds[route] == routeKinds[other];

	private static bool RoadCrowded(Vector2 p, Vector2 tangent, int route, double along, double ownHalf, int width, int height, double tile,
		double gap, double shared, int[] routeKinds, Vector2[] segA, Vector2[] segDelta, double[] segLen2, double[] segHalf, int[] segRoute, double[] segAlong, int[] cellStarts, int[] candidates)
	{
		int cx = (int)Math.Floor(p.X / tile - 0.5), cz = (int)Math.Floor(p.Y / tile - 0.5);
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
					if (segRoute[id] != route && RoadShared(dist, Math.Abs(tangent.Dot(delta.Normalized())) < 0.9, route, segRoute[id], ownHalf,
						segHalf[id], shared, routeKinds)) continue;
					if (dist < segHalf[id] + ownHalf + gap) return true;
				}
			}
		}
		return false;
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

	/// <summary>Batch RoadRefinement._vertex. Input segments use 17 doubles (the last two: corridor start and station count);
	/// fits use interleaved profile/strength/limit triples, corridor 7 doubles per station. SIMD preserves the scalar multiply/add order (no FMA).
	/// Outside-world sampling is deliberately left to the GDScript fallback.</summary>
	public Godot.Collections.Dictionary RoadVertices(Vector2[] points, double[] nearest, int width, int height,
		double tile, float[] ground, float[] water, float[] distWater, FastNoiseLite noise, Vector2 origin,
		double[] segments, double[] fits, double[] corridor, double[] surfaces, int[] structureStarts, double[] structures,
		double steepLo, double steepHi, double waterGap, bool simd)
	{
		int count = points.Length;
		var bases = new double[count]; var delta = new double[count]; var influence = new double[count];
		var pins = new double[count]; var power = new double[count]; var levels = new double[count];
		var caps = new double[count]; var details = new double[count]; var structurePins = new double[count];
		var relief = new double[count];
		var cells = new int[count]; var values = new double[count];
		var hs = new float[count]; var colors = new Color[count]; var uv = new Vector2[count];
		var surface = new byte[count]; var roadFlags = new byte[count]; var routes = new int[count];
		Array.Fill(routes, -1);
		for (int n = 0; n < count; n++)
		{
			double x = points[n].X, z = points[n].Y;
			double baseHeight = RoadGround(ground, width, height, tile, x, z);
			bases[n] = baseHeight;
			int selected = (int)nearest[n * 4];
			if (selected < 0) continue;
			int at = selected * 17;
			double u = nearest[n * 4 + 1], distance = nearest[n * 4 + 2], side = nearest[n * 4 + 3];
			double half = segments[at + 5]; bool road = segments[at + 6] != 0;
			int from = (int)segments[at + 7], to = (int)segments[at + 8];
			int surf = u < 0.5 ? from : to;
			double slow = noise.GetNoise2D((float)((x + origin.X) * 0.13), (float)((z + origin.Y) * 0.13));
			double grain = noise.GetNoise2D((float)((x + origin.X) * 0.8 + 71.0), (float)((z + origin.Y) * 0.8));
			double edge = half + slow * 0.24 + grain * 0.10, shoulder = 0.7 + (slow + 1.0) * 0.3;
			double mask = 1.0 - RoadSmooth(edge * 0.55, edge + shoulder, distance);
			var ca = new Color((float)surfaces[from * 5], (float)surfaces[from * 5 + 1], (float)surfaces[from * 5 + 2]);
			var cb = new Color((float)surfaces[to * 5], (float)surfaces[to * 5 + 1], (float)surfaces[to * 5 + 2]);
			Color color = ca.Lerp(cb, (float)RoadSmooth(0.0, 1.0, u));
			color = new Color(RoadLinear(color.R), RoadLinear(color.G), RoadLinear(color.B));
			if (surf == 7) mask *= 0.65;
			double organic = RoadLerp(surfaces[from * 5 + 4], surfaces[to * 5 + 4], RoadSmooth(0.0, 1.0, u));
			double visualEdge = edge * (1.0 - organic * 0.12), visualShoulder = shoulder * (1.0 + organic * 0.5);
			color.A = (float)((1.0 - RoadSmooth(visualEdge * 0.55, visualEdge + visualShoulder, distance)) * (1.0 - organic * 0.35));
			colors[n] = color; uv[n] = new Vector2((float)(side / half), surf);
			surface[n] = (byte)surf; roadFlags[n] = road ? (byte)1 : (byte)0; routes[n] = (int)segments[at + 12];
			double reach = 1.0 - RoadSmooth(half + 0.3, half + 3.0, distance);
			influence[n] = reach;
			int cx = Math.Clamp((int)Math.Floor(x / tile), 0, width - 1), cz = Math.Clamp((int)Math.Floor(z / tile), 0, height - 1);
			int cell = cz * width + cx; cells[n] = cell;
			double pin = RoadSmooth(1.0, 2.5, distWater[cell]);
			if (!float.IsNegativeInfinity(water[cell])) pin = 0.0;
			int key = Math.Clamp((int)Math.Floor(z / tile - 0.5), 0, height - 2) * width
				+ Math.Clamp((int)Math.Floor(x / tile - 0.5), 0, width - 2);
			double structurePin = 1.0;
			for (int s = structureStarts[key]; s < structureStarts[key + 1]; s++)
				structurePin = Math.Min(structurePin, RoadSmooth(6.0, 10.0, RoadSegmentDistance(x, z, structures, s * 4)));
			structurePins[n] = structurePin; pin = Math.Min(pin, structurePin);
			double gx = RoadGround(ground, width, height, tile, x + 1.0, z) - RoadGround(ground, width, height, tile, x - 1.0, z);
			double gz = RoadGround(ground, width, height, tile, x, z + 1.0) - RoadGround(ground, width, height, tile, x, z - 1.0);
			pin *= 1.0 - RoadSmooth(steepLo, steepHi, new Vector2((float)gx, (float)gz).Length() * 0.5);
			pins[n] = pin;
			double crown = 0.035 * (1.0 - RoadSmooth(0.0, half, distance));
			double detail = crown + slow * 0.06 * (1.0 - mask);
			details[n] = detail;
			double limit = road ? 0.65 : 0.3;
			double target = RoadLerp(segments[at + 9], segments[at + 10], u) + detail;
			power[n] = 1.0;
			int fitCount = (int)segments[at + 14];
			if (fitCount > 0)
			{
				double station = Math.Clamp(segments[at + 11] + u * Math.Sqrt(segments[at + 4]), 0.0, fitCount - 1.0);
				int j = Math.Min(fitCount - 2, (int)Math.Floor(station)), offset = (int)segments[at + 13] + j * 3;
				double f = station - j;
				double level = RoadLerp(fits[offset], fits[offset + 3], f);
				power[n] = RoadLerp(fits[offset + 1], fits[offset + 4], f);
				limit = RoadLerp(fits[offset + 2], fits[offset + 5], f);
				levels[n] = level; target = level + detail;
			}
			int corCount = (int)segments[at + 16];
			if (corCount > 0)
			{
				double gain = pin * RoadReliefEdge(points[n], width, height, tile);
				relief[n] = RoadCorridorShape(corridor, (int)segments[at + 15], corCount, segments[at + 11] + u * Math.Sqrt(segments[at + 4]),
					side, distance, half, out double section, out double bank) * gain;
				RoadCorridorColor(ref colors[n], section, bank, gain);
			}
			caps[n] = limit;
			delta[n] = Math.Clamp(target - baseHeight, -limit, limit);
		}
		int pos = 0;
		if (simd && System.Numerics.Vector.IsHardwareAccelerated)
		{
			int lanes = Simd.Count;
			for (; pos <= count - lanes; pos += lanes)
			{
				var blended = new Simd(delta, pos) * new Simd(influence, pos);
				blended *= new Simd(pins, pos); blended *= new Simd(power, pos);
				(blended + new Simd(bases, pos)).CopyTo(values, pos);
			}
		}
		for (; pos < count; pos++) values[pos] = bases[pos] + delta[pos] * influence[pos] * pins[pos] * power[pos];
		for (int n = 0; n < count; n++)
		{
			double value = values[n], baseHeight = bases[n];
			int selected = (int)nearest[n * 4];
			if (selected >= 0)
			{
				int at = selected * 17, cell = cells[n];
				if ((int)segments[at + 14] > 0 && float.IsNegativeInfinity(water[cell]) && power[n] > 0.0)
				{
					var a = new Vector2((float)segments[at], (float)segments[at + 1]);
					var d = new Vector2((float)segments[at + 2], (float)segments[at + 3]);
					double half = segments[at + 5], u = nearest[n * 4 + 1];
					var normal = new Vector2(-d.Y, d.X).Normalized() * (float)half;
					var axis = a + d * (float)u;
					double cross = Math.Abs(RoadGround(ground, width, height, tile, axis.X + (double)normal.X, axis.Y + (double)normal.Y)
						- RoadGround(ground, width, height, tile, axis.X - (double)normal.X, axis.Y - (double)normal.Y)) / (2.0 * half);
					double bench = RoadSmooth(steepLo, steepHi, cross);
					if (bench > 0.0)
					{
						double level = roadFlags[n] != 0 ? levels[n] : RoadGround(ground, width, height, tile, axis.X, axis.Y);
						double dry = Math.Max(level + details[n], RoadWet(water, width, height, cell) + waterGap);
						double shelf = baseHeight + Math.Clamp(dry - baseHeight, -caps[n], caps[n]);
						value = RoadLerp(value, shelf, influence[n] * structurePins[n] * power[n] * bench);
					}
				}
				value += relief[n];
				if (float.IsNegativeInfinity(water[cell]) && value < baseHeight)
					value = Math.Max(value, Math.Min(baseHeight, RoadWet(water, width, height, cell) + waterGap));
			}
			hs[n] = (float)value;
		}
		return new Godot.Collections.Dictionary { ["h"] = hs, ["color"] = colors, ["uv"] = uv,
			["surface"] = surface, ["road"] = roadFlags, ["route"] = routes };
	}
}
