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
	public GeometryValidator(TerrainSnapshot t) { _t = t; }

	/// <summary>Отрезок полосы шириной width (клетки): FastGrid.RoadSegment.</summary>
	public bool Segment(double ax, double ay, double bx, double by, double width, double maxGrade, double maxCross)
	{
		bool ok = _t.Water.RoadSegment(ax, ay, bx, by, width, maxGrade, maxCross);
		if (!ok && _t.Water.WaterSetupError().Length > 0)
			throw new InvalidOperationException("V2: RoadSegment: " + _t.Water.WaterSetupError());
		return ok;
	}

	/// <summary>Порт RoadLine.profile_ok (scripts/world/road_line.gd): точки (клетки) не реже 0,25 клетки; на каждом окне
	/// не короче PROFILE_BASE уклон не круче grade; skip — точки на настилах начинают окно заново.</summary>
	public bool Profile(double[] pts, double grade, byte[] skip = null)
	{
		double T = _t.P.Tile, baseLen = _t.P.ProfileBase;
		int n = pts.Length / 2;
		var heights = new double[n];
		var along = new double[n];
		double run = 0;
		for (int k = 0; k < n; k++)
		{
			if (k > 0) run += RoadGraph.Hypot(pts[2 * k] - pts[2 * k - 2], pts[2 * k + 1] - pts[2 * k - 1]);
			along[k] = run;
			heights[k] = _t.GroundAt(pts[2 * k] * T, pts[2 * k + 1] * T);
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

	/// <summary>Наименьший радиус поворота по тройкам точек (отрезки не короче 0,3 клетки), м.</summary>
	public double MinRadius(double[] pts)
	{
		double best = double.PositiveInfinity, T = _t.P.Tile;
		int n = pts.Length / 2;
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
