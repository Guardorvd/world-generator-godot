using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Godot;

public partial class FastGrid
{
	private static readonly StringName NameH = "h", NameColor = "color", NameUv = "uv", NameSurface = "surface", NameRoad = "road", NameOwner = "owner";

	// RoadRefinement.build: индекс и профили передаются между этапами как обычные массивы C#.
	// В Godot возвращаются только опубликованные профили и патчи.
	public Godot.Collections.Dictionary BuildRoadRefinement(int width, int height, double tile, int div, double reach,
		float[] ground, float[] raw, float[] water, float[] distWater, int[] ptStarts, double[] px, double[] py, double[] pw,
		int[] psurf, int[] kinds, float[] scales, int[] routeIds, byte[] authoredRoutes, byte[] localRoutes,
		FastNoiseLite noise, Vector2 origin, double[] structureAxes, double[] settlements, double[] surfaces,
		bool fitRoad, bool withGaps, Godot.Collections.Dictionary settings, double steepLo, double steepHi, double waterGap,
		double pinStart, double pinFade, double[] tread)
	{
		var clock = System.Diagnostics.Stopwatch.StartNew();
		var index = RoadIndex(width, height, tile, reach, ground, ptStarts, px, py, pw, psurf, kinds, routeIds, localRoutes);
		double indexMs = clock.Elapsed.TotalMilliseconds;
		var fit = fitRoad
			? RoadFitNetwork(ptStarts, px, py, pw, psurf, kinds, scales, routeIds, width, height, tile, tile / div,
				ground, raw, water, distWater, structureAxes, settlements, index, noise, origin, settings, authoredRoutes, localRoutes)
			: RoadFitData.Empty;
		double fitMs = clock.Elapsed.TotalMilliseconds - indexMs;
		var result = RoadPatches(index, fit, width, height, tile, div, surfaces, ground, water, distWater, noise, origin,
			structureAxes, steepLo, steepHi, waterGap, pinStart, pinFade, reach, authoredRoutes, tread, localRoutes);
		result["index_ms"] = indexMs;
		result["fit_network_ms"] = fitMs;
		result["routes"] = fit.Routes;
		result["starts"] = fit.Starts;
		result["scales"] = fit.Scales;
		result["points"] = fit.Points;
		result["profile"] = fit.Profile;
		result["strength"] = fit.Strength;
		result["limit"] = fit.Limit;
		result["corridor"] = fit.Corridor;
		if (withGaps)
		{
			double step = tile / div;
			result["gap_clear"] = Callable.From<Rect2I, Vector2, int, int, double, bool>(
				(cells, center, route, station, approach) => RoadGapClear(index, width, cells, center, route, station * step, approach));
		}
		return result;
	}

	private static bool RoadGapClear(RoadSegments index, int width, Rect2I cells, Vector2 center, int route,
		double station, double approach)
	{
		var seen = new HashSet<int>();
		for (int z = cells.Position.Y; z < cells.End.Y; z++)
			for (int x = cells.Position.X; x < cells.End.X; x++)
			{
				int key = z * width + x;
				for (int n = index.CellStarts[key]; n < index.CellStarts[key + 1]; n++)
				{
					int id = index.Candidates[n];
					if (!seen.Add(id))
						continue;
					Vector2 from = index.A[id], delta = index.Delta[id];
					double t = Math.Clamp((center - from).Dot(delta) / index.Len2[id], 0.0, 1.0);
					if (index.Route[id] == route && Math.Abs(index.Along[id] + t * delta.Length() - station) <= approach + 3.0)
						continue;
					if (center.DistanceTo(from + delta * (float)t) < approach + RoadMaxHalf(index.Half, id))
						return false;
				}
			}
		return true;
	}

	/// <summary>Отрезки и индекс. Пути (только виды RoadBed.KINDS) — столбцами: ptStarts — CSR по точкам,
	/// px/py/pw — x, y, w точек в клетках, psurf — покрытие точки; kinds — road/trail/mountain,
	/// routeIds — номер пути в w.trails. localRoutes — 1 по номеру пути у путей частичной пересборки
	/// (RoadRefinement.build(..., only), Trail Lab: новая трасса на готовом участке); пусто — все пути (игра). Частичный режим —
	/// копия прежнего GDScript: сначала отрезки только этих путей определяют нужные клетки (с соседними) и охватывающий прямоугольник,
	/// затем индексируются все пути, но только в нужных клетках и у точек вблизи прямоугольника; keys — клетки с отрезком местного пути.</summary>
	private static RoadSegments RoadIndex(int width, int height, double tile, double reach, float[] ground,
		int[] ptStarts, double[] px, double[] py, double[] pw, int[] psurf, int[] kinds, int[] routeIds,
		byte[] localRoutes)
	{
		bool local = localRoutes.Length > 0;
		int cells = width * height;
		byte[] wanted = null;
		Rect2 box = default;
		if (local)
		{
			var first = RoadIndexBuild(width, height, tile, reach, ground, ptStarts, px, py, pw, psurf, kinds, routeIds,
				localRoutes, true, null, default, null);
			float ftile = (float)tile;
			var mask = new byte[cells];
			int count = 0;
			foreach (int key in first.Keys)
			{
				mask[key] = 1;
				count++;
				var point = new Vector2((float)(key % width + 1), (float)(key / width + 1)) * ftile;
				box = count == 1 ? new Rect2(point, Vector2.Zero) : box.Expand(point);
			}
			if (count > 0)
			{
				box = box.Grow(ftile);
				foreach (int key in first.Keys)
					for (int dz = -1; dz <= 1; dz++)
						for (int dx = -1; dx <= 1; dx++)
						{
							int x = key % width + dx, z = key / width + dz;
							if (x >= 0 && z >= 0 && x < width && z < height) mask[z * width + x] = 1;
						}
				wanted = mask;
			}
		}
		var all = RoadIndexBuild(width, height, tile, reach, ground, ptStarts, px, py, pw, psurf, kinds, routeIds,
			localRoutes, false, wanted, box, local ? new bool[cells] : null);
		return new RoadSegments(all);
	}

	private sealed class RoadSegments
	{
		public readonly int[] Keys, Route, Surface, Next, CellStarts, Candidates;
		public readonly Vector2[] A, Delta;
		public readonly double[] Len2, Half, Ha, Hb, Along;
		public readonly byte[] Road, Kind;

		public RoadSegments(RoadIndexData data)
		{
			Keys = data.LocalCell == null ? data.Keys.ToArray() : data.Keys.Where(k => data.LocalCell[k]).ToArray();
			Route = data.SegRoute.ToArray();
			Surface = data.SegSurf.ToArray();
			Next = data.SegNext.ToArray();
			CellStarts = data.CellStarts;
			Candidates = data.Candidates;
			A = data.SegA.ToArray();
			Delta = data.SegDelta.ToArray();
			Len2 = data.SegLen2.ToArray();
			Half = data.SegHalf.ToArray();
			Ha = data.SegHa.ToArray();
			Hb = data.SegHb.ToArray();
			Along = data.SegAlong.ToArray();
			Road = data.SegRoad.ToArray();
			Kind = data.SegKind.ToArray();
		}
	}

	private sealed class RoadIndexData
	{
		public readonly List<Vector2> SegA = new(), SegDelta = new();
		public readonly List<double> SegLen2 = new(), SegHalf = new(), SegHa = new(), SegHb = new(), SegAlong = new();
		public readonly List<byte> SegRoad = new(), SegKind = new();
		public readonly List<int> SegSurf = new(), SegNext = new(), SegRoute = new();
		public readonly List<int> Keys = new();
		public bool[] LocalCell;
		public int[] CellStarts = Array.Empty<int>(), Candidates = Array.Empty<int>();
	}

	/// <summary>Отрезки путей и «клетка -> отрезки». onlyLocal — только пути localRoutes и без пересчёта клеток (первый проход
	/// частичного режима); wanted/box — нужные клетки и прямоугольник второго прохода (null — без ограничения);
	/// localCell — отметить клетки с отрезком местного пути.</summary>
	private static RoadIndexData RoadIndexBuild(int width, int height, double tile, double reach, float[] ground,
		int[] ptStarts, double[] px, double[] py, double[] pw, int[] psurf, int[] kinds, int[] routeIds,
		byte[] localRoutes, bool onlyLocal, byte[] wanted, Rect2 box, bool[] localCell)
	{
		var d = new RoadIndexData { LocalCell = localCell };
		var pairKey = new List<int>(); var pairId = new List<int>();
		int cells = width * height;
		var firstSeen = new bool[cells];
		float ftile = (float)tile;
		for (int t = 0; t < routeIds.Length; t++)
		{
			bool isLocal = localRoutes.Length > 0 && localRoutes[routeIds[t]] != 0;
			if (onlyLocal && !isLocal) continue;
			int from = ptStarts[t], to = ptStarts[t + 1], count = to - from;
			double sm = kinds[t] == 0 ? 0.65 : kinds[t] == 1 ? 0.25 : 0.0;
			byte[] needed = null;
			if (wanted != null)
			{
				needed = new byte[count];
				bool any = false;
				for (int n = 1; n < count; n++)
				{
					var a = new Vector2((float)px[from + n - 1], (float)py[from + n - 1]) * ftile;
					var b = new Vector2((float)px[from + n], (float)py[from + n]) * ftile;
					double nr = Math.Max(pw[from + n - 1], pw[from + n]) * tile * 0.5 + reach + tile;
					if (new Rect2(a, b - a).Abs().Grow((float)nr).Intersects(box, true)) { needed[n - 1] = 1; needed[n] = 1; any = true; }
				}
				if (!any) continue;
			}
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
				if (needed != null && (needed[n - 1] == 0 || needed[n] == 0)) { along += a.DistanceTo(b); continue; }
				double halfA = pw[from + n - 1] * tile * 0.5, halfB = pw[from + n] * tile * 0.5;
				double half = Math.Max(halfA, halfB);
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
						int key = z * width + x;
						if (wanted != null && wanted[key] == 0) continue;
						var center = new Vector2((float)(x + 1.0), (float)(z + 1.0)) * ftile;
						if (RbSegmentDist(center.X, center.Y, a.X, a.Y, b.X, b.Y) > half + reach + tile * 0.71) continue;
						if (id < 0)
						{
							id = d.SegA.Count;
							d.SegA.Add(a); d.SegDelta.Add(delta); d.SegLen2.Add(len2); d.SegHalf.Add(halfA); d.SegHalf.Add(halfB);
							d.SegRoad.Add(kinds[t] == 0 ? (byte)1 : (byte)0); d.SegKind.Add((byte)kinds[t]); d.SegSurf.Add(psurf[from + n - 1]); d.SegNext.Add(psurf[from + n]);
							d.SegHa.Add(profile[n - 1]); d.SegHb.Add(profile[n]); d.SegAlong.Add(myAlong); d.SegRoute.Add(routeIds[t]);
						}
						if (!firstSeen[key]) { firstSeen[key] = true; d.Keys.Add(key); }
						if (localCell != null && isLocal) localCell[key] = true;
						pairKey.Add(key); pairId.Add(id);
					}
				}
			}
		}
		if (onlyLocal) return d;
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
		d.CellStarts = starts; d.Candidates = candidates;
		return d;
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

	/// <summary>Уникальные вершины метровой сетки и публикация патчей в формате RoadRefinement.</summary>
	private static Godot.Collections.Dictionary RoadPatches(RoadSegments index, RoadFitData fit, int width, int height,
		double tile, int div, double[] surfaces,
		float[] ground, float[] water, float[] distWater, FastNoiseLite noise, Vector2 origin, double[] structureAxes,
		double steepLo, double steepHi, double waterGap, double pinStart, double pinFade, double reach, byte[] authoredRoutes, double[] tread,
		byte[] localRoutes)
	{
		bool local = localRoutes.Length > 0;
		var clock = System.Diagnostics.Stopwatch.StartNew();
		var fitStart = new int[authoredRoutes.Length];
		var fitCount = new int[authoredRoutes.Length];
		var corStart = new int[authoredRoutes.Length];
		var corCount = new int[authoredRoutes.Length];
		for (int n = 0; n < fit.Routes.Length; n++)
		{
			int route = fit.Routes[n];
			int from = fit.Starts[n], stations = fit.Starts[n + 1] - from;
			fitStart[route] = from;
			fitCount[route] = stations;
			if (fit.Scales[n] > 0.0f)
			{
				corStart[route] = from * CorridorStride;
				corCount[route] = stations;
			}
		}
		int stride = div + 1, fineW = width * div, fineH = height * div;
		double step = tile / div;
		RoadStructureIndex(width, height, tile, structureAxes, pinStart + pinFade, out int[] structStarts, out double[] structs);
		// уникальные вершины: плотный индекс «точка мелкой сетки -> номер запроса» вместо словаря
		var request = new int[fineW * fineH];
		Array.Fill(request, -1);
		var points = new List<Vector2>(index.Keys.Length * 16);
		var patchKeys = new List<int>(index.Keys.Length);
		foreach (int key in index.Keys)
		{
			int cx = key % width, cz = key / width;
			if (!RoadPatchMayChange(key, cx, cz, tile, step, index.CellStarts, index.Candidates, index.A, index.Delta, index.Len2,
				index.Half, index.Along, index.Route, corStart, corCount, fit.Corridor)) continue;
			patchKeys.Add(key);
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
		var active = new bool[count];
		var vertexRoute = new int[count]; // номер пути ближайшего отрезка вершины, -1 — нет (владелец при частичной сборке)
		int chunks = (count + 4095) / 4096;
		Parallel.For(0, chunks, c =>
		{
			int end = Math.Min(count, (c + 1) * 4096);
			for (int n = c * 4096; n < end; n++)
			{
				int selected = -1; double u = 0.0, dist = 0.0, side = 0.0;
				RoadNearest(points[n], width, height, tile, reach, index.A, index.Delta, index.Len2, index.Half,
					index.Road, index.CellStarts, index.Candidates,
					ref selected, ref u, ref dist, ref side);
				RoadVertexOne(n, points[n], selected, u, dist, side, width, height, tile, step, index.Half, index.Road, index.Kind, index.Surface,
					index.Next, index.Ha, index.Hb, index.Along, index.Len2, index.Route, index.A, index.Delta,
					fitStart, fitCount, fit, corStart, corCount, surfaces, ground, water, distWater, noise, origin,
					structStarts, structs, steepLo, steepHi, waterGap, hs, colors, uv, surface, roadFlags, active,
					selected >= 0 && authoredRoutes[index.Route[selected]] != 0, tread);
				vertexRoute[n] = selected >= 0 ? index.Route[selected] : -1;
			}
		});
		double msVertices = clock.Elapsed.TotalMilliseconds;
		using var patches = new Godot.Collections.Dictionary();
		int cellsPer = stride * stride;
		// Variant copies these into Godot packed arrays. Reuse the managed buffers across patches.
		var ph = new float[cellsPer];
		var pc = new Color[cellsPer];
		var pu = new Vector2[cellsPer];
		var ps = new byte[cellsPer];
		var pr = new byte[cellsPer];
		var po = local ? new byte[cellsPer] : null;
		foreach (int key in patchKeys)
		{
			int cx = key % width, cz = key / width;
			// Leave cells whose vertices all lie on the original terrain in the coarse mesh.
			// Частичная сборка (Trail Lab): патч нужен, только если сдвинулась вершина, принадлежащая местному пути.
			bool changed = false;
			for (int z = 0; z < stride && !changed; z++)
				for (int x = 0; x < stride && !changed; x++)
				{
					int q0 = request[(cz * div + z) * fineW + cx * div + x];
					changed = active[q0] && (!local || (vertexRoute[q0] >= 0 && localRoutes[vertexRoute[q0]] != 0));
				}
			if (!changed) continue;
			for (int z = 0; z < stride; z++)
			{
				for (int x = 0; x < stride; x++)
				{
					int q = request[(cz * div + z) * fineW + cx * div + x], idx = z * stride + x;
					ph[idx] = hs[q]; pc[idx] = colors[q]; pu[idx] = uv[q]; ps[idx] = surface[q]; pr[idx] = roadFlags[q];
					if (local) po[idx] = (byte)(vertexRoute[q] >= 0 && localRoutes[vertexRoute[q]] != 0 ? 1 : 0);
				}
			}
			// ключи — StringName, как у литерала {h = ...} в GDScript: словарь побайтно тот же
			using Variant patchHeight = ph;
			using Variant patchColor = pc;
			using Variant patchUv = pu;
			using Variant patchSurface = ps;
			using Variant patchRoad = pr;
			using var patch = new Godot.Collections.Dictionary
				{ [NameH] = patchHeight, [NameColor] = patchColor, [NameUv] = patchUv, [NameSurface] = patchSurface, [NameRoad] = patchRoad };
			if (local)
			{
				using Variant owner = po;
				patch[NameOwner] = owner;
			}
			using Variant published = patch;
			patches[key] = published;
		}
		return new Godot.Collections.Dictionary { ["patches"] = patches, ["points"] = count, ["ms_points"] = msPoints,
			["ms_vertices"] = msVertices - msPoints, ["ms_assemble"] = clock.Elapsed.TotalMilliseconds - msVertices };
	}

	private static bool RoadPatchMayChange(int key, int cx, int cz, double tile, double step, int[] starts, int[] candidates,
		Vector2[] anchors, Vector2[] deltas, double[] lengths, double[] halves, double[] along, int[] routes,
		int[] corStart, int[] corCount, double[] corridor)
	{
		var center = new Vector2((float)((cx + 1) * tile), (float)((cz + 1) * tile));
		double corner = tile * 0.71;
		for (int j = starts[key]; j < starts[key + 1]; j++)
		{
			int id = candidates[j];
			Vector2 offset = center - anchors[id];
			double t = Math.Clamp((double)offset.Dot(deltas[id]) / lengths[id], 0.0, 1.0);
			double distance = (offset - deltas[id] * (float)t).Length();
			if (distance <= RoadMaxHalf(halves, id) + 3.0 + corner) return true;
			int route = routes[id], count = corCount[route];
			if (count == 0) continue;
			double station = along[id] + t * Math.Sqrt(lengths[id]);
			int lo = Math.Clamp((int)Math.Floor((station - corner) / step), 0, count - 1);
			int hi = Math.Clamp((int)Math.Ceiling((station + corner) / step), 0, count - 1);
			for (int s = lo; s <= hi; s++)
				if (corridor[corStart[route] + s * CorridorStride + 7] > 0.0) return true;
		}
		return false;
	}

	private static void RoadNearest(Vector2 point, int width, int height, double tile, double reach, Vector2[] anchors, Vector2[] deltas,
		double[] lengths, double[] halves, byte[] roads, int[] starts, int[] candidates,
		ref int selected, ref double uOut, ref double distOut, ref double sideOut)
	{
		int x = Math.Clamp((int)Math.Floor(point.X / tile - 0.5), 0, width - 2);
		int z = Math.Clamp((int)Math.Floor(point.Y / tile - 0.5), 0, height - 2);
		int key = z * width + x;
		double best = double.PositiveInfinity;
		bool fitted = false;
		selected = -1;
		Vector2 bestOffset = default;
		for (int j = starts[key]; j < starts[key + 1]; j++)
		{
			int id = candidates[j];
			Vector2 delta = deltas[id];
			double f = Math.Clamp((double)(point - anchors[id]).Dot(delta) / lengths[id], 0.0, 1.0);
			Vector2 offset = point - (anchors[id] + delta * (float)f);
			double d = offset.Length();
			double half = RoadHalfAt(halves, id, f);
			bool inFit = d < half + 3.0;
			double rank = d / half - (roads[id] != 0 ? 0.08 : 0.0);
			if (d < half + reach && (inFit && !fitted || inFit == fitted && rank < best))
			{
				best = rank; fitted = inFit; selected = id; uOut = f; distOut = d; bestOffset = offset;
			}
		}
		if (selected >= 0)
			sideOut = bestOffset.Cross(deltas[selected].Normalized());
	}

	/// <summary>RoadRefinement._vertex для одной точки без пути (selected &lt; 0) и с путём; тот же порядок операций, что у
	/// прежнего пакета RoadVertices (удалён 16.11.2026; двухпроходная запись там нужна была только SIMD, значения те же).</summary>
	private static void RoadVertexOne(int n, Vector2 pt, int selected, double u, double distance, double side, int width, int height,
		double tile, double step, double[] segHalf, byte[] segRoad, byte[] segKind, int[] segSurf, int[] segNext, double[] segHa, double[] segHb, double[] segAlong,
		double[] segLen2, int[] segRoute, Vector2[] segA, Vector2[] segDelta, int[] fitStart, int[] fitCount, RoadFitData fit,
		int[] corStart, int[] corCount, double[] surfaces, float[] ground, float[] water, float[] distWater, FastNoiseLite noise, Vector2 origin,
		int[] structStarts, double[] structs, double steepLo, double steepHi, double waterGap,
		float[] hs, Color[] colors, Vector2[] uvs, byte[] surfaceOut, byte[] roadOut, bool[] active, bool authored, double[] tread)
	{
		double x = pt.X, z = pt.Y;
		double baseHeight = RoadGround(ground, width, height, tile, x, z);
		if (selected < 0) { hs[n] = (float)baseHeight; return; }
		double half = RoadHalfAt(segHalf, selected, u); bool road = segRoad[selected] != 0;
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
		color.A = (float)RoadTreadMask(half, distance, slow, organic, authored, grain, tread);
		uvs[n] = new Vector2((float)(side / half), surf + (road || authored ? 0.0f : 0.25f));
		surfaceOut[n] = (byte)surf; roadOut[n] = road ? (byte)1 : (byte)0;
		double influence = 1.0 - RoadSmooth(half + 0.3, half + 3.0, distance);
		int cx = Math.Clamp((int)Math.Floor(x / tile), 0, width - 1), cz = Math.Clamp((int)Math.Floor(z / tile), 0, height - 1);
		int cell = cz * width + cx;
		double pin = RoadSmooth(1.0, 2.5, distWater[cell]);
		if (!float.IsNegativeInfinity(water[cell])) pin = 0.0;
		double dryPin = pin;
		int key = Math.Clamp((int)Math.Floor(z / tile - 0.5), 0, height - 2) * width + Math.Clamp((int)Math.Floor(x / tile - 0.5), 0, width - 2);
		double structurePin = 1.0;
		for (int s = structStarts[key]; s < structStarts[key + 1]; s++)
			structurePin = Math.Min(structurePin, RoadSmooth(6.0, 10.0, RoadSegmentDistance(x, z, structs, s * 4)));
		pin = Math.Min(pin, structurePin);
		double gx = RoadGround(ground, width, height, tile, x + 1.0, z) - RoadGround(ground, width, height, tile, x - 1.0, z);
		double gz = RoadGround(ground, width, height, tile, x, z + 1.0) - RoadGround(ground, width, height, tile, x, z - 1.0);
		pin *= 1.0 - RoadSmooth(steepLo, steepHi, new Vector2((float)gx, (float)gz).Length() * 0.5);
		double crownHeight = tread.Length > 7 ? tread[7] : 0.035;
		double crown = crownHeight * (1.0 - RoadSmooth(0.0, half, distance));
		double detail = crown + slow * 0.06 * (1.0 - mask);
		double limit = road ? 0.65 : 0.3;
		double target = RoadLerp(segHa[selected], segHb[selected], u) + detail;
		double power = 1.0, level = 0.0, relief = 0.0;
		int route = segRoute[selected], fitLen = fitCount[route];
		if (fitLen > 0)
		{
			double station = Math.Clamp((segAlong[selected] + u * Math.Sqrt(segLen2[selected])) / step, 0.0, fitLen - 1.0);
			int j = Math.Min(fitLen - 2, (int)Math.Floor(station)), offset = fitStart[route] + j;
			double f = station - j;
			level = RoadLerp(fit.Profile[offset], fit.Profile[offset + 1], f);
			power = RoadLerp(fit.Strength[offset], fit.Strength[offset + 1], f);
			limit = RoadLerp(fit.Limit[offset], fit.Limit[offset + 1], f);
			target = level + detail;
		}
		if (corCount[route] > 0)
		{
			double gain = pin * RoadReliefEdge(pt, width, height, tile);
			relief = RoadCorridorShape(fit.Corridor, corStart[route], corCount[route], (segAlong[selected] + u * Math.Sqrt(segLen2[selected])) / step,
				side, distance, half, noise, x + origin.X, z + origin.Y, out double section, out double bank) * gain;
			RoadCorridorColor(ref color, section, bank, gain);
		}
		colors[n] = color;
		double delta = Math.Clamp(target - baseHeight, -limit, limit);
		double value = baseHeight + delta * influence * pin * power;
		var kind = fit.Kinds != null ? fit.Kinds[segKind[selected]] : default;
		if (kind.SupportCut > 0.0 && fitLen > 0 && power > 0.0 && dryPin > 0.0)
		{
			Vector2 tangent = segDelta[selected].Normalized(), normal = new(tangent.Y, -tangent.X);
			Vector2 axis = segA[selected] + segDelta[selected] * (float)u;
			double cross = (RoadGround(ground, width, height, tile, axis.X + normal.X, axis.Y + normal.Y)
				- RoadGround(ground, width, height, tile, axis.X - normal.X, axis.Y - normal.Y)) * 0.5;
			// The metre triangles need support outside the visible tread edge too.
			double shelf = 1.0 - RoadSmooth(half + step * 0.65, half + step * 1.9, distance);
			double bench = RoadSmooth(BenchLo, BenchHi, Math.Abs(cross));
			double crossfall = Math.Clamp(cross * kind.NaturalCross, -kind.Max, kind.Max);
			double correction = Math.Clamp(level + side * crossfall - baseHeight, -kind.SupportCut, kind.SupportCut);
			value = RoadLerp(value, baseHeight + correction * dryPin * structurePin * power,
				shelf * RoadLerp(1.0, kind.BenchScale, bench));
		}
		else if (fitLen > 0 && influence > 0.0 && float.IsNegativeInfinity(water[cell]) && power > 0.0)
		{
			var a = segA[selected];
			var d = segDelta[selected];
			var normal = new Vector2(-d.Y, d.X).Normalized() * (float)half;
			var axis = a + d * (float)u;
			double cross = Math.Abs(RoadGround(ground, width, height, tile, axis.X + (double)normal.X, axis.Y + (double)normal.Y)
				- RoadGround(ground, width, height, tile, axis.X - (double)normal.X, axis.Y - (double)normal.Y)) / (2.0 * half);
			double benchScale = fit.Kinds != null ? kind.BenchScale : 1.0;
			double bench = benchScale == 1.0 ? RoadSmooth(BenchLo, BenchHi, cross) : RoadSmooth(BenchLo, BenchHi, cross) * benchScale;
			if (bench > 0.0)
			{
				double lvl = road ? level : RoadGround(ground, width, height, tile, axis.X, axis.Y);
				double dry = Math.Max(lvl + detail, RoadWet(water, width, height, cell) + waterGap);
				double shelf = baseHeight + Math.Clamp(dry - baseHeight, -limit, limit);
				value = RoadLerp(value, shelf, influence * structurePin * power * bench);
			}
		}
		value = RoadLerp(baseHeight, value, RoadReliefEdge(pt, width, height, tile)) + relief;
		if (float.IsNegativeInfinity(water[cell]) && value < baseHeight)
			value = Math.Max(value, Math.Min(baseHeight, RoadWet(water, width, height, cell) + waterGap));
		hs[n] = (float)value;
		active[n] = hs[n] != (float)baseHeight || color.A > 0.0f;
	}
}

