using System;
using System.Collections.Generic;

namespace Roads.Network;

/// <summary>Единый валидатор геометрии пути V2 (план V2, фаза 1, п. 2). Правила не копируются:
/// отрезок — FastGrid.RoadSegment (= RoadLine.segment_ok: вода 0,3 м, уклон, крен BENCH_CROSS);
/// профиль — порт RoadLine.profile_ok (окно PROFILE_BASE, источник scripts/world/road_line.gd; сверка на стенде
/// road_v2_test с GDScript); брод — клетки небезопасных бродов приходят готовыми из StageTrails._unsafe_fords,
/// здесь только длина брода ≤ FORD_LEN; радиус ≥ полуширина + 0,5 м; зазор до чужих рёбер вне узлов
/// ≥ 2·half + 2·REACH + 2 м. Результат — (Ok, нарушения, наибольшее отношение нарушения к пределу).</summary>
public sealed class GeometryValidator
{
	public readonly struct Result
	{
		public readonly bool Ok;
		public readonly Violation Flags;
		public readonly double Max;
		public Result(Violation flags, double max) { Flags = flags; Ok = flags == Violation.None; Max = max; }
	}

	private readonly TerrainSnapshot _t;
	private readonly FastGrid _water;
	private readonly double _tile, _profileBase;
	private readonly RoadGraph _axes;
	private readonly double _reach;
	public GeometryValidator(TerrainSnapshot t) { _t = t; _water = t.Water; _tile = t.P.Tile; _profileBase = t.P.ProfileBase; }

	/// <summary>Сглаживание линии с проверкой зазора до уже опубликованных осей.</summary>
	public GeometryValidator(FastGrid water, double tile, double profileBase, RoadGraph axes = null, double reach = 0.0)
	{
		_water = water ?? throw new ArgumentException("GeometryValidator: нет земли и воды");
		_tile = tile;
		_profileBase = profileBase;
		_axes = axes;
		_reach = reach;
	}

	/// <summary>Узел на конце и пересечение исходной оси допустимы. За их пределами сдвиг
	/// сохраняет полный зазор или увеличивает уже недостаточный зазор.</summary>
	public bool KeepsClearance(LineBuilder.P before, LineBuilder.P after, LineBuilder.P start, LineBuilder.P end)
	{
		if (_axes == null || RoadGraph.Hypot(after.X - start.X, after.Y - start.Y) < RoadGraph.EndSkip ||
			RoadGraph.Hypot(after.X - end.X, after.Y - end.Y) < RoadGraph.EndSkip) return true;
		double gap = (after.W * _tile + 2.0 * _reach + 2.0) / _tile;
		double distance = _axes.Clearance(after.X, after.Y, gap, null);
		if (distance >= gap) return true;
		return distance + 1e-5 >= _axes.Clearance(before.X, before.Y, gap, null);
	}

	public bool KeepsCrossings(IReadOnlyList<LineBuilder.P> before, IReadOnlyList<LineBuilder.P> after)
	{
		if (_axes == null) return true;
		static double[] Pack(IReadOnlyList<LineBuilder.P> points)
		{
			var pts = new double[2 * points.Count];
			for (int k = 0; k < points.Count; k++)
			{
				pts[2 * k] = points[k].X;
				pts[2 * k + 1] = points[k].Y;
			}
			return pts;
		}
		return !_axes.DoubleCross(Pack(after), 20.0) || _axes.DoubleCross(Pack(before), 20.0);
	}

	/// <summary>Отрезок полосы шириной width (клетки): FastGrid.RoadSegment.</summary>
	public bool Segment(double ax, double ay, double bx, double by, double width, double maxGrade, double maxCross)
	{
		bool ok = _water.RoadSegment(ax, ay, bx, by, width, maxGrade, maxCross);
		if (!ok && _water.WaterSetupError().Length > 0)
			throw new InvalidOperationException("V2: RoadSegment: " + _water.WaterSetupError());
		return ok;
	}

	/// <summary>Порт RoadLine.profile_ok (scripts/world/road_line.gd): точки (клетки) не реже 0,25 клетки; на каждом окне
	/// не короче PROFILE_BASE уклон не круче grade; skip — точки на настилах начинают окно заново.</summary>
	public bool Profile(double[] pts, double grade, byte[] skip = null)
	{
		double T = _tile, baseLen = _profileBase;
		int n = pts.Length / 2;
		var heights = new double[n];
		var along = new double[n];
		double run = 0;
		for (int k = 0; k < n; k++)
		{
			if (k > 0) run += RoadGraph.Hypot(pts[2 * k] - pts[2 * k - 2], pts[2 * k + 1] - pts[2 * k - 1]);
			along[k] = run;
			heights[k] = _water.GroundAt(pts[2 * k] * T, pts[2 * k + 1] * T);
		}
		int j = 0;
		for (int k = 1; k < n; k++)
		{
			if (skip != null && skip.Length > 0 && skip[k] != 0) { j = k; continue; }
			while (j + 1 < k && along[k] - along[j + 1] >= baseLen) j++;
			if (Math.Abs(heights[k] - heights[j]) > grade * (along[k] - along[j]) * T + 0.00001) return false;
		}
		return true;
	}

	/// <summary>Брод по клеткам пути: подряд не больше FORD_LEN клеток реки вне осей сооружений, ни одной клетки
	/// небезопасного брода, моря или озера (они непроходимы в цене V1).</summary>
	public bool Ford(int[] cells)
	{
		int run = 0;
		foreach (int c in cells)
		{
			if (_t.OnAxis[c] != 0) { run = 0; continue; }
			if (_t.Unsafe[c] != 0 || _t.Ocean[c] != 0 || _t.Lake[c] != 0) return false;
			if (_t.River[c] != 0)
			{
				if (++run > _t.P.FordLen) return false;
			}
			else run = 0;
		}
		return true;
	}

	/// <summary>Наименьший радиус поворота по хордам не короче 4 м (при короткой ломаной — по тройкам точек ≥ 0,3 кл), м.</summary>
	public double MinRadius(double[] pts)
	{
		double best = double.PositiveInfinity, T = _tile;
		int n = pts.Length / 2;
		if (n < 3) return best;
		double minChord = 4.0 / T;
		double totalLen = 0.0;
		for (int k = 1; k < n; k++)
			totalLen += RoadGraph.Hypot(pts[2 * k] - pts[2 * k - 2], pts[2 * k + 1] - pts[2 * k - 1]);
		if (totalLen < 2.0 * minChord)
		{
			for (int k = 1; k + 1 < n; k++)
			{
				double ax = pts[2 * k - 2], ay = pts[2 * k - 1], bx = pts[2 * k], by = pts[2 * k + 1], cx = pts[2 * k + 2], cy = pts[2 * k + 3];
				double a = RoadGraph.Hypot(bx - ax, by - ay), b = RoadGraph.Hypot(cx - bx, cy - by), c = RoadGraph.Hypot(cx - ax, cy - ay);
				if (a < 0.3 || b < 0.3) continue;
				double cross = Math.Abs((bx - ax) * (cy - ay) - (by - ay) * (cx - ax));
				if (cross < 1e-9) continue;
				best = Math.Min(best, a * b * c / (2.0 * cross) * T);
			}
			return best;
		}
		for (int k = 1; k + 1 < n; k++)
		{
			if (!WalkArc(pts, n, k, -1, minChord, out double ax, out double ay)) continue;
			if (!WalkArc(pts, n, k, 1, minChord, out double cx, out double cy)) continue;
			double bx = pts[2 * k], by = pts[2 * k + 1];
			double a = RoadGraph.Hypot(bx - ax, by - ay), b = RoadGraph.Hypot(cx - bx, cy - by), c = RoadGraph.Hypot(cx - ax, cy - ay);
			if (a < 1e-6 || b < 1e-6) continue;
			double cross = Math.Abs((bx - ax) * (cy - ay) - (by - ay) * (cx - ax));
			if (cross < 1e-9) continue;
			best = Math.Min(best, a * b * c / (2.0 * cross) * T);
		}
		return best;
	}

	private static bool WalkArc(double[] pts, int n, int start, int dir, double targetLen, out double ox, out double oy)
	{
		double rem = targetLen;
		int cur = start;
		while (true)
		{
			int next = cur + dir;
			if (next < 0 || next >= n) { ox = oy = 0.0; return false; }
			double sx = pts[2 * next] - pts[2 * cur], sy = pts[2 * next + 1] - pts[2 * cur + 1];
			double seg = RoadGraph.Hypot(sx, sy);
			if (seg >= rem - 1e-9)
			{
				double t = seg > 1e-12 ? Math.Min(1.0, rem / seg) : 0.0;
				ox = pts[2 * cur] + sx * t;
				oy = pts[2 * cur + 1] + sy * t;
				return true;
			}
			rem -= seg;
			cur = next;
		}
	}

	/// <summary>Полная проверка ломаной pts (клетки) полосы width (клетки): отрезки с пределом maxGrade × relax и креном,
	/// профиль, радиус, зазор до графа (без рёбер skipEdges у узлов; graph = null — без зазора), клетки брода.</summary>
	public Result Validate(double[] pts, int[] cells, double width, double maxGrade, double relax, RoadGraph graph, HashSet<int> skipEdges, double nodeR)
	{
		var flags = Violation.None;
		double worst = 0.0, T = _t.P.Tile;
		int n = pts.Length / 2;
		for (int k = 0; k < n; k++)
			if (pts[2 * k] < 0 || pts[2 * k + 1] < 0 || pts[2 * k] > _t.W || pts[2 * k + 1] > _t.H) flags |= Violation.Bounds;
		if (flags != Violation.None) return new Result(flags, 1.0);
		for (int k = 1; k < n; k++)
		{
			double ax = pts[2 * k - 2], ay = pts[2 * k - 1], bx = pts[2 * k], by = pts[2 * k + 1];
			if (Segment(ax, ay, bx, by, width, maxGrade * relax, _t.P.BenchCross)) continue;
			// какое правило: вода, уклон или крен
			if (!Segment(ax, ay, bx, by, 0.0, 1e9, 1e9)) flags |= Violation.Water;
			else if (!Segment(ax, ay, bx, by, width, 1e9, _t.P.BenchCross)) flags |= Violation.Cross;
			else flags |= Violation.Grade;
			worst = Math.Max(worst, 1.0);
		}
		if (!Profile(pts, maxGrade)) { flags |= Violation.Profile; worst = Math.Max(worst, 1.0); }
		double needR = width * 0.5 * T + 0.5;
		double r = MinRadius(pts);
		if (r < needR) { flags |= Violation.Radius; worst = Math.Max(worst, needR / Math.Max(r, 1e-6)); }
		if (graph != null)
		{
			double gap = (2.0 * width * 0.5 * T + 2.0 * _t.P.Reach + 2.0) / T;
			double ex0 = pts[0], ey0 = pts[1], ex1 = pts[^2], ey1 = pts[^1];
			for (int k = 0; k < n; k++)
			{
				double x = pts[2 * k], y = pts[2 * k + 1];
				if (RoadGraph.Hypot(x - ex0, y - ey0) < nodeR || RoadGraph.Hypot(x - ex1, y - ey1) < nodeR) continue;
				double d = graph.Clearance(x, y, gap, skipEdges);
				if (d < gap) { flags |= Violation.Gap; worst = Math.Max(worst, gap / Math.Max(d, 1e-6)); }
			}
		}
		if (cells != null && !Ford(cells)) { flags |= Violation.Ford; worst = Math.Max(worst, 1.0); }
		return new Result(flags, worst);
	}
}
