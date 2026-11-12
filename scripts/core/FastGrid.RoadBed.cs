using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Godot;

public partial class FastGrid
{
	// Копия RoadBed.refine (scripts/game/road_bed.gd) для игрового рельефа без OuterLand и без метровой сетки.
	// DOD: один вызов на этап, на входе и выходе только массивы; пути — столбцами (CSR по точкам).
	// Арифметика как в GDScript: double в расчётах, float32 в PackedFloat32Array (xs, zs, half, g, near,
	// best_w, best_h, pin, weight, target, hv).
	// 11.11.2026: три прохода. 1) профиль каждого пути (параллельно); 2) узлы: путь, который касается пути, обработанного
	// раньше (порядок — дороги, тропы, горные тропы, внутри вида по номеру), подтягивает свой профиль к его высоте в точке
	// касания — у узла одна высота (последовательно, дёшево); 3) клетки рельефа (параллельно), слияние путей — среднее
	// по весам, а не победитель (строго по порядку путей).

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

	private sealed class RbProfile
	{
		public float[] Xs = Array.Empty<float>();
		public float[] Zs = Array.Empty<float>();
		public float[] Half = Array.Empty<float>();
		public double[] Prof = Array.Empty<double>();
		public double[] Fade = Array.Empty<double>();
		public double[] Along = Array.Empty<double>();
		public double[] CrossX = Array.Empty<double>();
		public double[] CrossZ = Array.Empty<double>();
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
	/// flat, shoulder, window, keep, cut, side; номер вида — его место в порядке обработки), starts — CSR по точкам,
	/// px/py/pw — x, y, w точек в клетках. Возвращает {hv — рельеф после полотна, changed — изменённые клетки}.</summary>
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
		var order = RbOrder(kinds);
		var profiles = new RbProfile[trails];
		int parts = Math.Clamp(System.Environment.ProcessorCount, 1, 8);
		var ground = hv; // читают все пути; пишется только после слияния
		Parallel.For(0, parts, new ParallelOptions { MaxDegreeOfParallelism = parts }, part =>
		{
			for (int t = part; t < trails; t += parts)
				profiles[t] = RbProfileOf(w, h, tile, ground, kindParams, kinds[t] * 6, starts[t], starts[t + 1], px, py, pw, step, steepLo, steepHi);
		});
		RbJoin(w, h, tile, pin, order, starts, px, py, profiles);
		var results = new RbTrail[trails];
		Parallel.For(0, parts, new ParallelOptions { MaxDegreeOfParallelism = parts }, part =>
		{
			var near = new float[n];
			Array.Fill(near, float.PositiveInfinity);
			var slot = new int[n];
			Array.Fill(slot, -1);
			for (int t = part; t < trails; t += parts)
				results[t] = RbStamp(w, h, tile, ground, pin, near, slot, kindParams, kinds[t] * 6, profiles[t]);
		});
		var weight = new float[n];
		var sum = new double[n];
		var total = new double[n];
		foreach (int t in order)
		{
			var r = results[t];
			for (int j = 0; j < r.Cells.Length; j++)
			{
				int i = r.Cells[j];
				double wj = r.Weight[j];
				if (wj <= 0.0) continue;
				sum[i] += wj * r.Height[j];
				total[i] += wj;
				if (r.Weight[j] > weight[i]) weight[i] = r.Weight[j];
			}
		}
		var changed = new List<int>();
		for (int i = 0; i < n; i++)
		{
			if (weight[i] <= 0.0f || !float.IsNegativeInfinity(waterLevel[i])) continue;
			float target = (float)(sum[i] / total[i]);
			double old = hv[i];
			double v = RoadLerp(old, target, weight[i]);
			if (v < old) v = Math.Max(v, Math.Min(old, RoadWet(waterLevel, w, h, i) + waterGap));
			if (Math.Abs(v - old) > 0.005) { hv[i] = (float)v; changed.Add(i); }
		}
		return new Godot.Collections.Dictionary { ["hv"] = hv, ["changed"] = changed.ToArray() };
	}

	/// <summary>Порядок обработки: по номеру вида (дорога, тропа, горная тропа), внутри вида — по номеру пути.</summary>
	private static int[] RbOrder(int[] kinds)
	{
		var order = new int[kinds.Length];
		for (int t = 0; t < order.Length; t++) order[t] = t;
		Array.Sort(order, (a, b) => kinds[a] != kinds[b] ? kinds[a].CompareTo(kinds[b]) : a.CompareTo(b));
		return order;
	}

	private static RbProfile RbProfileOf(int w, int h, double tile, float[] hv, double[] kp, int kAt, int from, int to,
		double[] px, double[] py, double[] pw, double step, double steepLo, double steepHi)
	{
		double window = kp[kAt + 2], keep = kp[kAt + 3], cut = kp[kAt + 4];
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
				half.Add((float)(RoadLerp(pw[p - 1], pw[p], (double)s / m) * tile * 0.5));
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
		var prof = new double[count];
		var fade = new double[count];
		for (int i = 0; i < count; i++)
		{
			int r = Math.Min(win, Math.Min(i, count - 1 - i));
			double smooth = (sum[i + r + 1] - sum[i - r]) / (2 * r + 1);
			prof[i] = RbClamp(smooth + keep * (g[i] - smooth), g[i] - cut, g[i] + cut);
			double gx = RoadGround(hv, w, h, tile, xs[i] + 2.0, zs[i]) - RoadGround(hv, w, h, tile, xs[i] - 2.0, zs[i]);
			double gz = RoadGround(hv, w, h, tile, xs[i], zs[i] + 2.0) - RoadGround(hv, w, h, tile, xs[i], zs[i] - 2.0);
			fade[i] = 1.0 - RoadSmooth(steepLo, steepHi, Math.Sqrt(gx * gx + gz * gz) / 4.0);
		}
		var along = new double[xs.Count];
		for (int i = 1; i < xs.Count; i++)
		{
			double dx = (double)xs[i] - xs[i - 1], dz = (double)zs[i] - zs[i - 1];
			along[i] = along[i - 1] + Math.Sqrt(dx * dx + dz * dz);
		}
		return new RbProfile {
			Xs = xs.ToArray(), Zs = zs.ToArray(), Half = half.ToArray(), Prof = prof, Fade = fade,
			Along = along, CrossX = new double[xs.Count], CrossZ = new double[xs.Count]
		};
	}

	private const double RbJoinTouch = 0.05; // клеток: конец на оси другого пути
	private const double RbJoinGrade = 0.08, RbJoinSlope = 0.16;
	private const double RbJoinMin = 6.0, RbJoinMax = 30.0; // длина перехода, м

	/// <summary>Узлы: для каждого пути по порядку — точки касания с путями раньше него (пересечения отрезков, концы
	/// на оси); профиль в окрестности точки подтягивается к профилю того пути. Узлы у сооружений и воды (pin < 0,5)
	/// не трогаются.</summary>
	private static void RbJoin(int w, int h, double tile, float[] pin, int[] order, int[] starts, double[] px, double[] py,
		RbProfile[] profiles)
	{
		var rank = new int[order.Length];
		for (int k = 0; k < order.Length; k++) rank[order[k]] = k;
		// отрезки по клеткам мира (ячейка 2 × 2 клетки)
		const int Bin = 2;
		int bw = (w + Bin - 1) / Bin, bh = (h + Bin - 1) / Bin;
		var bins = new Dictionary<int, List<int>>();
		var owner = new List<int>();
		var segA = new List<int>();
		for (int t = 0; t < order.Length; t++)
		{
			for (int p = starts[t] + 1; p < starts[t + 1]; p++)
			{
				int id = owner.Count;
				owner.Add(t);
				segA.Add(p - 1);
				int x0 = Math.Clamp((int)Math.Floor(Math.Min(px[p - 1], px[p]) - RbJoinTouch) / Bin, 0, bw - 1);
				int x1 = Math.Clamp((int)Math.Floor(Math.Max(px[p - 1], px[p]) + RbJoinTouch) / Bin, 0, bw - 1);
				int y0 = Math.Clamp((int)Math.Floor(Math.Min(py[p - 1], py[p]) - RbJoinTouch) / Bin, 0, bh - 1);
				int y1 = Math.Clamp((int)Math.Floor(Math.Max(py[p - 1], py[p]) + RbJoinTouch) / Bin, 0, bh - 1);
				for (int y = y0; y <= y1; y++)
					for (int x = x0; x <= x1; x++)
					{
						int key = y * bw + x;
						if (!bins.TryGetValue(key, out var list)) bins[key] = list = new List<int>();
						list.Add(id);
					}
			}
		}
		foreach (int t in order)
		{
			var contacts = new List<(double x, double y, int host)>();
			for (int p = starts[t] + 1; p < starts[t + 1]; p++)
			{
				double ax = px[p - 1], ay = py[p - 1], bx = px[p], by = py[p];
				int x0 = Math.Clamp((int)Math.Floor(Math.Min(ax, bx) - RbJoinTouch) / Bin, 0, bw - 1);
				int x1 = Math.Clamp((int)Math.Floor(Math.Max(ax, bx) + RbJoinTouch) / Bin, 0, bw - 1);
				int y0 = Math.Clamp((int)Math.Floor(Math.Min(ay, by) - RbJoinTouch) / Bin, 0, bh - 1);
				int y1 = Math.Clamp((int)Math.Floor(Math.Max(ay, by) + RbJoinTouch) / Bin, 0, bh - 1);
				bool first = p == starts[t] + 1, last = p == starts[t + 1] - 1;
				for (int y = y0; y <= y1; y++)
					for (int x = x0; x <= x1; x++)
					{
						if (!bins.TryGetValue(y * bw + x, out var list)) continue;
						foreach (int id in list)
						{
							int host = owner[id];
							if (rank[host] >= rank[t]) continue;
							int q = segA[id];
							double cx = px[q], cy = py[q], dx = px[q + 1], dy = py[q + 1];
							bool hostFirst = q == starts[host], hostLast = q + 1 == starts[host + 1] - 1;
							if (RbIntersect(ax, ay, bx, by, cx, cy, dx, dy, out double ix, out double iy)) contacts.Add((ix, iy, host));
							if (first && RbSegmentDist(ax, ay, cx, cy, dx, dy) < RbJoinTouch) contacts.Add((ax, ay, host));
							if (last && RbSegmentDist(bx, by, cx, cy, dx, dy) < RbJoinTouch) contacts.Add((bx, by, host));
							if (hostFirst && RbSegmentDist(cx, cy, ax, ay, bx, by) < RbJoinTouch) contacts.Add((cx, cy, host));
							if (hostLast && RbSegmentDist(dx, dy, ax, ay, bx, by) < RbJoinTouch) contacts.Add((dx, dy, host));
						}
					}
			}
			if (contacts.Count == 0) continue;
			var own = profiles[t];
			var done = new List<(double x, double y)>();
			var joined = new HashSet<int>();
			foreach (var c in contacts)
			{
				bool seen = false;
				foreach (var d in done) if ((d.x - c.x) * (d.x - c.x) + (d.y - c.y) * (d.y - c.y) < 0.125 * 0.125) seen = true;
				if (seen) continue;
				done.Add((c.x, c.y));
				if (!RbJoinOpen(w, h, pin, c.x, c.y)) continue;
				double mx = c.x * tile, mz = c.y * tile;
				int s = RbNearest(own, mx, mz);
				if (joined.Contains(s)) continue;
				RbJoinProfile(w, h, tile, pin, own, s, profiles[c.host], mx, mz, joined);
				joined.Add(s);
			}
		}
	}

	private static bool RbJoinOpen(int w, int h, float[] pin, double x, double z)
	{
		int cell = Math.Clamp((int)Math.Floor(z), 0, h - 1) * w + Math.Clamp((int)Math.Floor(x), 0, w - 1);
		return pin[cell] >= 0.5f;
	}

	private static (double x, double z, double grade) RbJoinTangent(RbProfile p, int s)
	{
		int lo = s, hi = s;
		while (lo > 0 && p.Along[s] - p.Along[lo] < 2.0) lo--;
		while (hi + 1 < p.Along.Length && p.Along[hi] - p.Along[s] < 2.0) hi++;
		double dx = (double)p.Xs[hi] - p.Xs[lo], dz = (double)p.Zs[hi] - p.Zs[lo];
		double length = Math.Max(0.00001, Math.Sqrt(dx * dx + dz * dz));
		return (dx / length, dz / length, (p.Prof[hi] - p.Prof[lo]) / Math.Max(0.00001, p.Along[hi] - p.Along[lo]));
	}

	private static void RbJoinProfile(int w, int h, double tile, float[] pin, RbProfile own, int s,
		RbProfile host, double x, double z, HashSet<int> joined)
	{
		int q = RbNearest(host, x, z);
		var ht = RbJoinTangent(host, q);
		var ot = RbJoinTangent(own, s);
		double gx = ht.x * ht.grade + host.CrossX[q], gz = ht.z * ht.grade + host.CrossZ[q];
		double slope = gx * ot.x + gz * ot.z;
		double cross = RbClamp(-gx * ot.z + gz * ot.x, -RbJoinSlope, RbJoinSlope);
		double delta = RbClamp(slope - ot.grade, -RbJoinSlope, RbJoinSlope);
		if (!RbJoinOpen(w, h, pin, own.Xs[s] / tile, own.Zs[s] / tile)) return;
		double target = host.Prof[q] + gx * ((double)own.Xs[s] - host.Xs[q]) + gz * ((double)own.Zs[s] - host.Zs[q]);
		double shift = target - own.Prof[s];
		double reach = RbClamp(1.5 * Math.Abs(shift) / RbJoinGrade, RbJoinMin, RbJoinMax);
		Span<double> spans = stackalloc double[2];
		for (int side = -1; side <= 1; side += 2)
		{
			double span = reach;
			for (int k = s + side; k >= 0 && k < own.Prof.Length; k += side)
			{
				double d = Math.Abs(own.Along[k] - own.Along[s]);
				if (d >= reach) break;
				if (joined.Contains(k) || !RbJoinOpen(w, h, pin, own.Xs[k] / tile, own.Zs[k] / tile))
				{
					span = d;
					break;
				}
			}
			spans[side < 0 ? 0 : 1] = span;
		}
		double cap = RbJoinGrade * Math.Min(spans[0], spans[1]) / 1.5;
		shift = RbClamp(shift, -cap, cap);
		own.Prof[s] += shift;
		own.CrossX[s] = -ot.z * cross;
		own.CrossZ[s] = ot.x * cross;
		for (int side = -1; side <= 1; side += 2)
		{
			double span = spans[side < 0 ? 0 : 1];
			for (int k = s + side; k >= 0 && k < own.Prof.Length; k += side)
			{
				double d = own.Along[k] - own.Along[s];
				if (Math.Abs(d) >= span) break;
				double t = Math.Abs(d) / span;
				double fade = 1.0 - RoadSmooth(0.0, 1.0, t);
				own.Prof[k] += shift * fade + delta * d * (1.0 - t) * (1.0 - t);
				own.CrossX[k] += (own.CrossX[s] - own.CrossX[k]) * fade;
				own.CrossZ[k] += (own.CrossZ[s] - own.CrossZ[k]) * fade;
			}
		}
	}

	private static int RbNearest(RbProfile p, double x, double z)
	{
		int best = 0;
		double bestD = double.PositiveInfinity;
		for (int k = 0; k < p.Xs.Length; k++)
		{
			double dx = p.Xs[k] - x, dz = p.Zs[k] - z;
			double d = dx * dx + dz * dz;
			if (d < bestD) { bestD = d; best = k; }
		}
		return best;
	}

	/// <summary>Пересечение отрезков ab и cd (включая касание концом).</summary>
	private static bool RbIntersect(double ax, double ay, double bx, double by, double cx, double cy, double dx, double dy, out double ix, out double iy)
	{
		ix = 0.0; iy = 0.0;
		double rx = bx - ax, ry = by - ay, sx = dx - cx, sy = dy - cy;
		double den = rx * sy - ry * sx;
		if (Math.Abs(den) < 1e-12) return false;
		double t = ((cx - ax) * sy - (cy - ay) * sx) / den;
		double u = ((cx - ax) * ry - (cy - ay) * rx) / den;
		if (t < -1e-9 || t > 1.0 + 1e-9 || u < -1e-9 || u > 1.0 + 1e-9) return false;
		ix = ax + rx * t;
		iy = ay + ry * t;
		return true;
	}

	private static RbTrail RbStamp(int w, int h, double tile, float[] hv, float[] pin, float[] near, int[] slot,
		double[] kp, int kAt, RbProfile p)
	{
		double flat = kp[kAt], shoulder = kp[kAt + 1], side = kp[kAt + 5];
		var touched = new List<int>();
		var bestW = new List<float>();
		var bestH = new List<float>();
		double reach = flat + shoulder;
		for (int i = 0; i < p.Xs.Length; i++)
		{
			double fade = p.Fade[i];
			if (fade <= 0.0) continue;
			double prof = p.Prof[i];
			double outer = p.Half[i] + reach;
			int x0 = Math.Max(0, (int)Math.Floor((p.Xs[i] - outer) / tile - 0.5));
			int x1 = Math.Min(w - 1, (int)Math.Ceiling((p.Xs[i] + outer) / tile - 0.5));
			int z0 = Math.Max(0, (int)Math.Floor((p.Zs[i] - outer) / tile - 0.5));
			int z1 = Math.Min(h - 1, (int)Math.Ceiling((p.Zs[i] + outer) / tile - 0.5));
			for (int cz = z0; cz <= z1; cz++)
			{
				for (int cx = x0; cx <= x1; cx++)
				{
					double ex = (cx + 0.5) * tile - p.Xs[i], ez = (cz + 0.5) * tile - p.Zs[i];
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
					bestW[j] = (float)((1.0 - RoadSmooth(p.Half[i] + flat, outer, d)) * pin[cell] * fade);
					bestH[j] = (float)RbClamp(prof + p.CrossX[i] * ex + p.CrossZ[i] * ez, ground - side, ground + side);
				}
			}
		}
		foreach (int cell in touched) { near[cell] = float.PositiveInfinity; slot[cell] = -1; }
		return new RbTrail { Cells = touched.ToArray(), Weight = bestW.ToArray(), Height = bestH.ToArray() };
	}
}
