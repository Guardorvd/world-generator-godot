using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Godot;

public partial class FastGrid
{
	private static readonly StringName NameH = "h", NameColor = "color", NameUv = "uv", NameSurface = "surface", NameRoad = "road";

	// RoadRefinement.build (scripts/game/road_refinement.gd), DOD: индекс и патчи двумя вызовами;
	// формы коридора всех путей — внутри RoadFitNetwork (FastGrid.Road.cs).
	// на входе и выходе только массивы. RoadIndex — отрезки метровой дорожной сетки и индекс «клетка -> отрезки»
	// (копия RoadRefinement._index); RoadPatches — уникальные вершины патчей, ближайший отрезок, высота/цвет/UV
	// вершины и сборка словарей патчей (копии _nearest_vertices, _vertex и цикла сборки build).
	// Арифметика как в GDScript: Vector2 и PackedFloat32Array — float, остальное — double.

	/// <summary>Отрезки и индекс. Пути (только виды RoadBed.KINDS) — столбцами: ptStarts — CSR по точкам,
	/// px/py/pw — x, y, w точек в клетках, psurf — покрытие точки; smoothing — сглаживание профиля пути,
	/// roadKind — 1 у дороги, routeIds — номер пути в w.trails.</summary>
	public Godot.Collections.Dictionary RoadIndex(int width, int height, double tile, double reach, float[] ground,
		int[] ptStarts, double[] px, double[] py, double[] pw, int[] psurf, double[] smoothing, byte[] roadKind, int[] routeIds)
	{
		var segA = new List<Vector2>(); var segDelta = new List<Vector2>();
		var segLen2 = new List<double>(); var segHalf = new List<double>(); var segRoad = new List<byte>();
		var segSurf = new List<int>(); var segNext = new List<int>(); var segHa = new List<double>(); var segHb = new List<double>();
		var segAlong = new List<double>(); var segRoute = new List<int>();
		var pairKey = new List<int>(); var pairId = new List<int>();
		int cells = width * height;
		var firstSeen = new bool[cells];
		var keys = new List<int>();
		float ftile = (float)tile;
		for (int t = 0; t < routeIds.Length; t++)
		{
			int from = ptStarts[t], to = ptStarts[t + 1], count = to - from;
			double sm = smoothing[t];
			var baseHeights = new double[count];
			if (sm > 0.0)
				for (int n = 0; n < count; n++)
					baseHeights[n] = RoadGround(ground, width, height, tile, px[from + n] * tile, py[from + n] * tile);
			var profile = new float[count];
			for (int n = 0; n < count; n++)
			{
				var p = new Vector2((float)px[from + n], (float)py[from + n]) * ftile;
				double h = RoadGround(ground, width, height, tile, p.X, p.Y);
				double sum = h; int num = 1;
				int radius = sm > 0.0 ? Math.Min(3, Math.Min(n, count - 1 - n)) : 0;
				for (int j = n - radius; j <= n + radius; j++)
					if (j != n) { sum += baseHeights[j]; num++; }
				profile[n] = (float)RoadLerp(h, sum / num, sm);
			}
			double along = 0.0;
			for (int n = 1; n < count; n++)
			{
				var a = new Vector2((float)px[from + n - 1], (float)py[from + n - 1]) * ftile;
				var b = new Vector2((float)px[from + n], (float)py[from + n]) * ftile;
				if (a.DistanceSquaredTo(b) < 0.0001) continue;
				double half = ((double)pw[from + n - 1] + (double)pw[from + n]) * tile * 0.25;
				var delta = b - a;
				double len2 = a.DistanceSquaredTo(b);
				int id = -1;
				double myAlong = along;
				along += a.DistanceTo(b);
				double rr = half + reach + tile;
				int z0 = Math.Max(0, (int)Math.Floor((Math.Min((double)a.Y, b.Y) - rr) / tile - 0.5));
				int z1 = Math.Min(height - 1, (int)Math.Ceiling((Math.Max((double)a.Y, b.Y) + rr) / tile - 0.5));
				int x0 = Math.Max(0, (int)Math.Floor((Math.Min((double)a.X, b.X) - rr) / tile - 0.5));
				int x1 = Math.Min(width - 1, (int)Math.Ceiling((Math.Max((double)a.X, b.X) + rr) / tile - 0.5));
				for (int z = z0; z < z1; z++)
				{
					for (int x = x0; x < x1; x++)
					{
						var center = new Vector2((float)(x + 1.0), (float)(z + 1.0)) * ftile;
						if (RbSegmentDist(center.X, center.Y, a.X, a.Y, b.X, b.Y) > half + reach + tile * 0.71) continue;
						if (id < 0)
						{
							id = segA.Count;
							segA.Add(a); segDelta.Add(delta); segLen2.Add(len2); segHalf.Add(half);
							segRoad.Add(roadKind[t]); segSurf.Add(psurf[from + n - 1]); segNext.Add(psurf[from + n]);
							segHa.Add(profile[n - 1]); segHb.Add(profile[n]); segAlong.Add(myAlong); segRoute.Add(routeIds[t]);
						}
						int key = z * width + x;
						if (!firstSeen[key]) { firstSeen[key] = true; keys.Add(key); }
						pairKey.Add(key); pairId.Add(id);
					}
				}
			}
		}
		// «клетка -> отрезки» в порядке создания отрезков (устойчивая раскладка по клеткам)
		var starts = new int[cells + 1];
		foreach (int k in pairKey) starts[k + 1]++;
		for (int i = 0; i < cells; i++) starts[i + 1] += starts[i];
		var fill = new int[cells];
		var candidates = new int[pairKey.Count];
		for (int i = 0; i < pairKey.Count; i++)
		{
			int k = pairKey[i];
			candidates[starts[k] + fill[k]++] = pairId[i];
		}
		return new Godot.Collections.Dictionary
		{
			["a"] = segA.ToArray(), ["delta"] = segDelta.ToArray(), ["len2"] = segLen2.ToArray(), ["half"] = segHalf.ToArray(),
			["road"] = segRoad.ToArray(), ["surf"] = segSurf.ToArray(), ["next"] = segNext.ToArray(), ["ha"] = segHa.ToArray(),
			["hb"] = segHb.ToArray(), ["along"] = segAlong.ToArray(), ["route"] = segRoute.ToArray(),
			["starts"] = starts, ["candidates"] = candidates, ["keys"] = keys.ToArray(),
		};
	}

	private static void RoadStructureIndex(int width, int height, double tile, double[] structures, double reach,
		out int[] starts, out double[] axes)
	{
		int cells = width * height;
		var pairKey = new List<int>(); var pairAt = new List<int>();
		for (int s = 0; s * 4 < structures.Length; s++)
		{
			double ax = structures[s * 4], az = structures[s * 4 + 1], bx = structures[s * 4 + 2], bz = structures[s * 4 + 3];
			int z0 = Math.Max(0, (int)Math.Floor((Math.Min(az, bz) - reach) / tile - 0.5));
			int z1 = Math.Min(height - 1, (int)Math.Ceiling((Math.Max(az, bz) + reach) / tile - 0.5));
			int x0 = Math.Max(0, (int)Math.Floor((Math.Min(ax, bx) - reach) / tile - 0.5));
			int x1 = Math.Min(width - 1, (int)Math.Ceiling((Math.Max(ax, bx) + reach) / tile - 0.5));
			for (int z = z0; z < z1; z++)
				for (int x = x0; x < x1; x++) { pairKey.Add(z * width + x); pairAt.Add(s); }
		}
		starts = new int[cells + 1];
		foreach (int k in pairKey) starts[k + 1]++;
		for (int i = 0; i < cells; i++) starts[i + 1] += starts[i];
		var fill = new int[cells];
		axes = new double[pairKey.Count * 4];
		for (int i = 0; i < pairKey.Count; i++)
		{
			int k = pairKey[i], at = (starts[k] + fill[k]++) * 4, s = pairAt[i] * 4;
			axes[at] = structures[s]; axes[at + 1] = structures[s + 1]; axes[at + 2] = structures[s + 2]; axes[at + 3] = structures[s + 3];
		}
	}

	/// <summary>Патчи метровой сетки по клеткам keys. Входные отрезки — столбцы из RoadIndex (a, delta, len2, half, road, surf,
	/// next, ha, hb, along, route, starts, candidates), fitStart/fitCount — смещение и длина профиля подгонки пути (по номеру
	/// пути), fits — profile/strength/limit подряд; corStart/corCount — начало (в числах) и число станций форм коридора пути,
	/// corridor — 7 чисел на станцию (RoadFitNetwork). Возвращает {patches — словарь клетка -> {h, color, uv, surface, road},
	/// points — число уникальных вершин}.</summary>
	public Godot.Collections.Dictionary RoadPatches(int[] keys, int width, int height, double tile, int div,
		Vector2[] segA, Vector2[] segDelta, double[] segLen2, double[] segHalf, byte[] segRoad, int[] segSurf, int[] segNext,
		double[] segHa, double[] segHb, double[] segAlong, int[] segRoute, int[] cellStarts, int[] candidates,
		int[] fitStart, int[] fitCount, double[] fits, int[] corStart, int[] corCount, double[] corridor, double[] surfaces,
		float[] ground, float[] water, float[] distWater, FastNoiseLite noise, Vector2 origin, double[] structureAxes,
		double steepLo, double steepHi, double waterGap, double pinStart, double pinFade, double reach)
	{
		var clock = System.Diagnostics.Stopwatch.StartNew();
		int stride = div + 1, fineW = width * div, fineH = height * div;
		double step = tile / div;
		RoadStructureIndex(width, height, tile, structureAxes, pinStart + pinFade, out int[] structStarts, out double[] structs);
		// уникальные вершины: плотный индекс «точка мелкой сетки -> номер запроса» вместо словаря
		var request = new int[fineW * fineH];
		Array.Fill(request, -1);
		var points = new List<Vector2>(keys.Length * 16);
		foreach (int key in keys)
		{
			int cx = key % width, cz = key / width;
			for (int z = 0; z < stride; z++)
			{
				for (int x = 0; x < stride; x++)
				{
					int ix = cx * div + x, iz = cz * div + z, vk = iz * fineW + ix;
					if (request[vk] >= 0) continue;
					request[vk] = points.Count;
					points.Add(new Vector2((float)(ix * step + tile * 0.5), (float)(iz * step + tile * 0.5)));
				}
			}
		}
		double msPoints = clock.Elapsed.TotalMilliseconds;
		int count = points.Count;
		var hs = new float[count]; var colors = new Color[count]; var uv = new Vector2[count];
		var surface = new byte[count]; var roadFlags = new byte[count];
		int chunks = (count + 4095) / 4096;
		Parallel.For(0, chunks, c =>
		{
			int end = Math.Min(count, (c + 1) * 4096);
			for (int n = c * 4096; n < end; n++)
			{
				int selected = -1; double u = 0.0, dist = 0.0, side = 0.0;
				RoadNearest(points[n], width, height, tile, reach, segA, segDelta, segLen2, segHalf, segRoad, cellStarts, candidates,
					ref selected, ref u, ref dist, ref side);
				RoadVertexOne(n, points[n], selected, u, dist, side, width, height, tile, step, segHalf, segRoad, segSurf, segNext, segHa, segHb,
					segAlong, segLen2, segRoute, segA, segDelta, fitStart, fitCount, fits, corStart, corCount, corridor, surfaces, ground, water, distWater, noise, origin,
					structStarts, structs, steepLo, steepHi, waterGap, hs, colors, uv, surface, roadFlags);
			}
		});
		double msVertices = clock.Elapsed.TotalMilliseconds;
		var patches = new Godot.Collections.Dictionary();
		int cellsPer = stride * stride;
		foreach (int key in keys)
		{
			int cx = key % width, cz = key / width;
			var ph = new float[cellsPer]; var pc = new Color[cellsPer]; var pu = new Vector2[cellsPer];
			var ps = new byte[cellsPer]; var pr = new byte[cellsPer];
			for (int z = 0; z < stride; z++)
			{
				for (int x = 0; x < stride; x++)
				{
					int q = request[(cz * div + z) * fineW + cx * div + x], idx = z * stride + x;
					ph[idx] = hs[q]; pc[idx] = colors[q]; pu[idx] = uv[q]; ps[idx] = surface[q]; pr[idx] = roadFlags[q];
				}
			}
			// ключи — StringName, как у литерала {h = ...} в GDScript: словарь побайтно тот же
			patches[key] = new Godot.Collections.Dictionary { [NameH] = ph, [NameColor] = pc, [NameUv] = pu, [NameSurface] = ps, [NameRoad] = pr };
		}
		return new Godot.Collections.Dictionary { ["patches"] = patches, ["points"] = count, ["ms_points"] = msPoints,
			["ms_vertices"] = msVertices - msPoints, ["ms_assemble"] = clock.Elapsed.TotalMilliseconds - msVertices };
	}

	private static void RoadNearest(Vector2 point, int width, int height, double tile, double reach, Vector2[] anchors, Vector2[] deltas,
		double[] lengths, double[] halves, byte[] roads, int[] starts, int[] candidates,
		ref int selected, ref double uOut, ref double distOut, ref double sideOut)
	{
		int x = Math.Clamp((int)Math.Floor(point.X / tile - 0.5), 0, width - 2);
		int z = Math.Clamp((int)Math.Floor(point.Y / tile - 0.5), 0, height - 2);
		int key = z * width + x;
		double best = double.PositiveInfinity;
		selected = -1;
		for (int j = starts[key]; j < starts[key + 1]; j++)
		{
			int id = candidates[j];
			Vector2 delta = deltas[id];
			double f = Math.Clamp((double)(point - anchors[id]).Dot(delta) / lengths[id], 0.0, 1.0);
			Vector2 offset = point - (anchors[id] + delta * (float)f);
			double d = offset.Length();
			double rank = d / halves[id] - (roads[id] != 0 ? 0.08 : 0.0);
			if (d < halves[id] + reach && rank < best)
			{
				best = rank; selected = id; uOut = f; distOut = d; sideOut = offset.Cross(delta.Normalized());
			}
		}
	}

	/// <summary>RoadRefinement._vertex для одной точки без пути (selected &lt; 0) и с путём; тот же порядок операций, что у
	/// RoadVertices (двухпроходная запись там нужна только SIMD, значения те же).</summary>
	private static void RoadVertexOne(int n, Vector2 pt, int selected, double u, double distance, double side, int width, int height,
		double tile, double step, double[] segHalf, byte[] segRoad, int[] segSurf, int[] segNext, double[] segHa, double[] segHb, double[] segAlong,
		double[] segLen2, int[] segRoute, Vector2[] segA, Vector2[] segDelta, int[] fitStart, int[] fitCount, double[] fits,
		int[] corStart, int[] corCount, double[] corridor, double[] surfaces, float[] ground, float[] water, float[] distWater, FastNoiseLite noise, Vector2 origin,
		int[] structStarts, double[] structs, double steepLo, double steepHi, double waterGap,
		float[] hs, Color[] colors, Vector2[] uvs, byte[] surfaceOut, byte[] roadOut)
	{
		double x = pt.X, z = pt.Y;
		double baseHeight = RoadGround(ground, width, height, tile, x, z);
		if (selected < 0) { hs[n] = (float)baseHeight; return; }
		double half = segHalf[selected]; bool road = segRoad[selected] != 0;
		int from = segSurf[selected], to = segNext[selected];
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
		uvs[n] = new Vector2((float)(side / half), surf);
		surfaceOut[n] = (byte)surf; roadOut[n] = road ? (byte)1 : (byte)0;
		double influence = 1.0 - RoadSmooth(half + 0.3, half + 3.0, distance);
		int cx = Math.Clamp((int)Math.Floor(x / tile), 0, width - 1), cz = Math.Clamp((int)Math.Floor(z / tile), 0, height - 1);
		int cell = cz * width + cx;
		double pin = RoadSmooth(1.0, 2.5, distWater[cell]);
		if (!float.IsNegativeInfinity(water[cell])) pin = 0.0;
		int key = Math.Clamp((int)Math.Floor(z / tile - 0.5), 0, height - 2) * width + Math.Clamp((int)Math.Floor(x / tile - 0.5), 0, width - 2);
		double structurePin = 1.0;
		for (int s = structStarts[key]; s < structStarts[key + 1]; s++)
			structurePin = Math.Min(structurePin, RoadSmooth(6.0, 10.0, RoadSegmentDistance(x, z, structs, s * 4)));
		pin = Math.Min(pin, structurePin);
		double gx = RoadGround(ground, width, height, tile, x + 1.0, z) - RoadGround(ground, width, height, tile, x - 1.0, z);
		double gz = RoadGround(ground, width, height, tile, x, z + 1.0) - RoadGround(ground, width, height, tile, x, z - 1.0);
		pin *= 1.0 - RoadSmooth(steepLo, steepHi, new Vector2((float)gx, (float)gz).Length() * 0.5);
		double crown = 0.035 * (1.0 - RoadSmooth(0.0, half, distance));
		double detail = crown + slow * 0.06 * (1.0 - mask);
		double limit = road ? 0.65 : 0.3;
		double target = RoadLerp(segHa[selected], segHb[selected], u) + detail;
		double power = 1.0, level = 0.0, relief = 0.0;
		int route = segRoute[selected], fitLen = fitCount[route];
		if (fitLen > 0)
		{
			double station = Math.Clamp((segAlong[selected] + u * Math.Sqrt(segLen2[selected])) / step, 0.0, fitLen - 1.0);
			int j = Math.Min(fitLen - 2, (int)Math.Floor(station)), offset = fitStart[route] + j * 3;
			double f = station - j;
			level = RoadLerp(fits[offset], fits[offset + 3], f);
			power = RoadLerp(fits[offset + 1], fits[offset + 4], f);
			limit = RoadLerp(fits[offset + 2], fits[offset + 5], f);
			target = level + detail;
		}
		if (corCount[route] > 0)
		{
			double gain = pin * RoadReliefEdge(pt, width, height, tile);
			relief = RoadCorridorShape(corridor, corStart[route], corCount[route], (segAlong[selected] + u * Math.Sqrt(segLen2[selected])) / step,
				side, distance, half, out double section, out double bank) * gain;
			RoadCorridorColor(ref color, section, bank, gain);
		}
		colors[n] = color;
		double delta = Math.Clamp(target - baseHeight, -limit, limit);
		double value = baseHeight + delta * influence * pin * power;
		if (fitLen > 0 && float.IsNegativeInfinity(water[cell]) && power > 0.0)
		{
			var a = segA[selected];
			var d = segDelta[selected];
			var normal = new Vector2(-d.Y, d.X).Normalized() * (float)half;
			var axis = a + d * (float)u;
			double cross = Math.Abs(RoadGround(ground, width, height, tile, axis.X + (double)normal.X, axis.Y + (double)normal.Y)
				- RoadGround(ground, width, height, tile, axis.X - (double)normal.X, axis.Y - (double)normal.Y)) / (2.0 * half);
			double bench = RoadSmooth(steepLo, steepHi, cross);
			if (bench > 0.0)
			{
				double lvl = road ? level : RoadGround(ground, width, height, tile, axis.X, axis.Y);
				double dry = Math.Max(lvl + detail, RoadWet(water, width, height, cell) + waterGap);
				double shelf = baseHeight + Math.Clamp(dry - baseHeight, -limit, limit);
				value = RoadLerp(value, shelf, influence * structurePin * power * bench);
			}
		}
		value += relief;
		if (float.IsNegativeInfinity(water[cell]) && value < baseHeight)
			value = Math.Max(value, Math.Min(baseHeight, RoadWet(water, width, height, cell) + waterGap));
		hs[n] = (float)value;
	}
}

