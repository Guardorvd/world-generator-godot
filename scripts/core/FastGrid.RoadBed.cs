using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Godot;

public partial class FastGrid
{
	// Копия RoadBed.refine (scripts/game/road_bed.gd) для игрового рельефа без OuterLand и без метровой сетки.
	// DOD: один вызов на этап, на входе и выходе только массивы; пути — столбцами (CSR по точкам).
	// Арифметика как в GDScript: double в расчётах, float32 в PackedFloat32Array (xs, zs, half, g, near,
	// best_w, best_h, pin, weight, target, hv). Пути не зависят друг от друга до слияния, поэтому считаются
	// параллельно (каждому потоку — свои near/slot), а слияние идёт строго по порядку путей.

	private static double RbClamp(double v, double lo, double hi) => v < lo ? lo : (v > hi ? hi : v);

	private static double RbSegmentDist(double px, double py, double ax, double ay, double bx, double by)
	{
		double vx = bx - ax, vy = by - ay;
		double l2 = vx * vx + vy * vy;
		double t = l2 == 0.0 ? 0.0 : RbClamp(((px - ax) * vx + (py - ay) * vy) / l2, 0.0, 1.0);
		double ox = px - ax - vx * t, oy = py - ay - vy * t;
		return Math.Sqrt(ox * ox + oy * oy);
	}

	private sealed class RbTrail
	{
		public int[] Cells = Array.Empty<int>();
		public float[] Weight = Array.Empty<float>();
		public float[] Height = Array.Empty<float>();
	}

	/// <summary>RoadBed._pins: доля полотна у каждой точки рельефа (0 у осей мостов/туннелей и у воды).
	/// ends — по четыре числа на сооружение: клетки a и b (индексы клеток мира).</summary>
	private static float[] RbPins(int w, int h, double tile, float[] distWater, int[] ends,
		double shoreLo, double shoreHi, double pinStart, double pinFade)
	{
		int n = w * h;
		var pin = new float[n];
		for (int i = 0; i < n; i++) pin[i] = (float)RoadSmooth(shoreLo, shoreHi, distWater[i]);
		double r = (pinStart + pinFade) / tile + 1.0;
		for (int s = 0; s + 1 < ends.Length; s += 2)
		{
			double ax = ends[s] % w + 0.5, ay = ends[s] / w + 0.5;
			double bx = ends[s + 1] % w + 0.5, by = ends[s + 1] / w + 0.5;
			int y0 = Math.Max(0, (int)Math.Floor(Math.Min(ay, by) - r)), y1 = Math.Min(h, (int)Math.Ceiling(Math.Max(ay, by) + r));
			int x0 = Math.Max(0, (int)Math.Floor(Math.Min(ax, bx) - r)), x1 = Math.Min(w, (int)Math.Ceiling(Math.Max(ax, bx) + r));
			for (int y = y0; y < y1; y++)
			{
				for (int x = x0; x < x1; x++)
				{
					double d = RbSegmentDist(x + 0.5, y + 0.5, ax, ay, bx, by) * tile;
					pin[y * w + x] = (float)Math.Min((double)pin[y * w + x], RoadSmooth(pinStart, pinStart + pinFade, d));
				}
			}
		}
		return pin;
	}

	/// <summary>RoadBed.refine для всех путей мира. kinds — номер вида на путь (параметры в kindParams по шесть:
	/// flat, shoulder, window, keep, cut, side), starts — CSR по точкам, px/py/pw — x, y, w точек в клетках.
	/// Возвращает {hv — рельеф после полотна, changed — изменённые клетки}.</summary>
	public Godot.Collections.Dictionary RoadBedRefine(int w, int h, double tile, float[] hv, float[] waterLevel,
		float[] distWater, int[] structureEnds, int[] kinds, int[] starts, double[] px, double[] py, double[] pw,
		double[] kindParams, byte[] frozen, double step, double steepLo, double steepHi, double shoreLo, double shoreHi,
		double pinStart, double pinFade, double waterGap)
	{
		int n = w * h;
		var pin = RbPins(w, h, tile, distWater, structureEnds, shoreLo, shoreHi, pinStart, pinFade);
		if (frozen.Length == n)
			for (int i = 0; i < n; i++) if (frozen[i] != 0) pin[i] = 0.0f;
		int trails = kinds.Length;
		var results = new RbTrail[trails];
		int parts = Math.Clamp(System.Environment.ProcessorCount, 1, 8);
		var ground = hv; // читают все пути; пишется только после слияния
		Parallel.For(0, parts, new ParallelOptions { MaxDegreeOfParallelism = parts }, part =>
		{
			var near = new float[n];
			Array.Fill(near, float.PositiveInfinity);
			var slot = new int[n];
			Array.Fill(slot, -1);
			for (int t = part; t < trails; t += parts)
				results[t] = RbTrailRefine(w, h, tile, ground, pin, near, slot, kindParams, kinds[t] * 6, starts[t], starts[t + 1],
					px, py, pw, step, steepLo, steepHi);
		});
		var weight = new float[n];
		var target = new float[n];
		for (int t = 0; t < trails; t++)
		{
			var r = results[t];
			for (int j = 0; j < r.Cells.Length; j++)
			{
				int i = r.Cells[j];
				if (r.Weight[j] > weight[i]) { weight[i] = r.Weight[j]; target[i] = r.Height[j]; }
			}
		}
		var changed = new List<int>();
		for (int i = 0; i < n; i++)
		{
			if (weight[i] <= 0.0f || !float.IsNegativeInfinity(waterLevel[i])) continue;
			double old = hv[i];
			double v = RoadLerp(old, target[i], weight[i]);
			if (v < old) v = Math.Max(v, Math.Min(old, RoadWet(waterLevel, w, h, i) + waterGap));
			if (Math.Abs(v - old) > 0.005) { hv[i] = (float)v; changed.Add(i); }
		}
		return new Godot.Collections.Dictionary { ["hv"] = hv, ["changed"] = changed.ToArray() };
	}

	private static RbTrail RbTrailRefine(int w, int h, double tile, float[] hv, float[] pin, float[] near, int[] slot,
		double[] kp, int kAt, int from, int to, double[] px, double[] py, double[] pw, double step, double steepLo, double steepHi)
	{
		double flat = kp[kAt], shoulder = kp[kAt + 1], window = kp[kAt + 2], keep = kp[kAt + 3], cut = kp[kAt + 4], side = kp[kAt + 5];
		var xs = new List<float>();
		var zs = new List<float>();
		var half = new List<float>();
		for (int p = from + 1; p < to; p++)
		{
			double ax = px[p - 1] * tile, az = py[p - 1] * tile;
			double dx = px[p] * tile - ax, dz = py[p] * tile - az;
			int m = Math.Max(1, (int)Math.Ceiling(Math.Sqrt(dx * dx + dz * dz) / step));
			for (int s = 0; s < m; s++)
			{
				xs.Add((float)(ax + dx * s / m));
				zs.Add((float)(az + dz * s / m));
				half.Add((float)(pw[p - 1] * tile * 0.5));
			}
		}
		xs.Add((float)(px[to - 1] * tile));
		zs.Add((float)(py[to - 1] * tile));
		half.Add((float)(pw[to - 1] * tile * 0.5));
		int count = xs.Count;
		var g = new float[count];
		var sum = new double[count + 1];
		for (int i = 0; i < count; i++)
		{
			g[i] = (float)RoadGround(hv, w, h, tile, xs[i], zs[i]);
			sum[i + 1] = sum[i] + g[i];
		}
		int win = (int)(window / step);
		var touched = new List<int>();
		var bestW = new List<float>();
		var bestH = new List<float>();
		double reach = flat + shoulder;
		for (int i = 0; i < count; i++)
		{
			int r = Math.Min(win, Math.Min(i, count - 1 - i));
			double smooth = (sum[i + r + 1] - sum[i - r]) / (2 * r + 1);
			double prof = RbClamp(smooth + keep * (g[i] - smooth), g[i] - cut, g[i] + cut);
			double gx = RoadGround(hv, w, h, tile, xs[i] + 2.0, zs[i]) - RoadGround(hv, w, h, tile, xs[i] - 2.0, zs[i]);
			double gz = RoadGround(hv, w, h, tile, xs[i], zs[i] + 2.0) - RoadGround(hv, w, h, tile, xs[i], zs[i] - 2.0);
			double fade = 1.0 - RoadSmooth(steepLo, steepHi, Math.Sqrt(gx * gx + gz * gz) / 4.0);
			if (fade <= 0.0) continue;
			double outer = half[i] + reach;
			int x0 = Math.Max(0, (int)Math.Floor((xs[i] - outer) / tile - 0.5));
			int x1 = Math.Min(w - 1, (int)Math.Ceiling((xs[i] + outer) / tile - 0.5));
			int z0 = Math.Max(0, (int)Math.Floor((zs[i] - outer) / tile - 0.5));
			int z1 = Math.Min(h - 1, (int)Math.Ceiling((zs[i] + outer) / tile - 0.5));
			for (int cz = z0; cz <= z1; cz++)
			{
				for (int cx = x0; cx <= x1; cx++)
				{
					double ex = (cx + 0.5) * tile - xs[i], ez = (cz + 0.5) * tile - zs[i];
					double d = Math.Sqrt(ex * ex + ez * ez);
					if (d >= outer) continue;
					int cell = cz * w + cx;
					if (d >= near[cell] || pin[cell] <= 0.0f) continue;
					if (slot[cell] < 0)
					{
						slot[cell] = touched.Count;
						touched.Add(cell);
						bestW.Add(0.0f);
						bestH.Add(0.0f);
					}
					near[cell] = (float)d;
					int j = slot[cell];
					double ground = hv[cell];
					bestW[j] = (float)((1.0 - RoadSmooth(half[i] + flat, outer, d)) * pin[cell] * fade);
					bestH[j] = (float)RbClamp(prof, ground - side, ground + side);
				}
			}
		}
		foreach (int cell in touched) { near[cell] = float.PositiveInfinity; slot[cell] = -1; }
		return new RbTrail { Cells = touched.ToArray(), Weight = bestW.ToArray(), Height = bestH.ToArray() };
	}
}
