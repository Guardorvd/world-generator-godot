using System;
using Godot;

/// <summary>
/// Земля и вода базового рельефа для дорожного этапа (с 9.7): копии Heightfield.base_ground_at, river_level,
/// lake_level, depth_at без настилов мостов и StageTrails._road_segment. Только для рельефа генерации:
/// без полотна дорог (RoadRefinement) и без земли за краем карты (OuterLand). Арифметика как в GDScript:
/// double, значения массивов и вершин лент — float.
/// </summary>
public partial class FastGrid
{
	private int _sw, _sh;
	private double _tile, _hs, _lakeDrop;
	private float[] _surfHv = Array.Empty<float>();
	private float[] _segPts = Array.Empty<float>(); // по 12 на отрезок ленты: a.left, a.right, b.left, b.right
	private int[] _cellStart = Array.Empty<int>();
	private int[] _cellSeg = Array.Empty<int>();
	private byte[] _lake = Array.Empty<byte>();
	private float[] _filled = Array.Empty<float>();

	/// <summary>Ленты рек по клеткам: пары (клетка, отрезок) в любом порядке, как Heightfield._river_cells.</summary>
	public void SetWater(int w, int h, double tile, double hs, double lakeDrop, float[] segPts, int[] pairCells, int[] pairSegs, byte[] lake, float[] filled)
	{
		_sw = w;
		_sh = h;
		_tile = tile;
		_hs = hs;
		_lakeDrop = lakeDrop;
		_segPts = segPts;
		_lake = lake;
		_filled = filled;
		_cellStart = new int[w * h + 1];
		foreach (int c in pairCells)
			_cellStart[c + 1]++;
		for (int i = 0; i < w * h; i++)
			_cellStart[i + 1] += _cellStart[i];
		_cellSeg = new int[pairSegs.Length];
		var fill = (int[])_cellStart.Clone();
		for (int k = 0; k < pairCells.Length; k++)
			_cellSeg[fill[pairCells[k]]++] = pairSegs[k];
	}

	/// <summary>Высоты hv: рельеф меняется после выемок туннелей, поэтому передаётся перед каждым использованием.</summary>
	public void SetGround(float[] hv) => _surfHv = hv;

	private double Ground(double x, double z)
	{
		int W = _sw;
		double fx = Math.Clamp(x / _tile - 0.5, 0.0, W - 1.001);
		double fz = Math.Clamp(z / _tile - 0.5, 0.0, _sh - 1.001);
		int i = (int)Math.Floor(fx), j = (int)Math.Floor(fz);
		var hv = _surfHv;
		double a = hv[j * W + i], b = hv[j * W + i + 1], c = hv[(j + 1) * W + i], d = hv[(j + 1) * W + i + 1];
		double tx = fx - i, tz = fz - j;
		if (tx + tz <= 1.0)
			return a + (b - a) * tx + (c - a) * tz;
		return d + (c - d) * (1.0 - tx) + (b - d) * (1.0 - tz);
	}

	private static double WaterTriangle(double x, double z, double ax, double ay, double az,
		double bx, double by, double bz, double cx, double cy, double cz)
	{
		double denominator = (bz - cz) * (ax - cx) + (cx - bx) * (az - cz);
		if (Math.Abs(denominator) < 1e-8)
			return double.NegativeInfinity;
		double u = ((bz - cz) * (x - cx) + (cx - bx) * (z - cz)) / denominator;
		double v = ((cz - az) * (x - cx) + (ax - cx) * (z - cz)) / denominator;
		if (u < -1e-5 || v < -1e-5 || u + v > 1.00001)
			return double.NegativeInfinity;
		return u * ay + v * by + (1.0 - u - v) * cy;
	}

	private double RiverLevel(double x, double z)
	{
		if (x < 0.0 || z < 0.0 || x >= _sw * _tile || z >= _sh * _tile)
			return double.NegativeInfinity;
		int cell = (int)Math.Floor(z / _tile) * _sw + (int)Math.Floor(x / _tile);
		double top = double.NegativeInfinity;
		var p = _segPts;
		for (int k = _cellStart[cell]; k < _cellStart[cell + 1]; k++)
		{
			int o = _cellSeg[k] * 12;
			// a.left = o, a.right = o + 3, b.left = o + 6, b.right = o + 9
			top = Math.Max(top, WaterTriangle(x, z, p[o], p[o + 1], p[o + 2], p[o + 3], p[o + 4], p[o + 5], p[o + 6], p[o + 7], p[o + 8]));
			top = Math.Max(top, WaterTriangle(x, z, p[o + 6], p[o + 7], p[o + 8], p[o + 3], p[o + 4], p[o + 5], p[o + 9], p[o + 10], p[o + 11]));
		}
		return top;
	}

	private double LakeLevel(double x, double z)
	{
		int cx = (int)Math.Floor(x / _tile - 0.5);
		int cy = (int)Math.Floor(z / _tile - 0.5);
		if (cx < 0 || cy < 0 || cx >= _sw - 1 || cy >= _sh - 1)
			return double.NegativeInfinity;
		int a = cy * _sw + cx;
		double top = double.NegativeInfinity;
		if (_lake[a] != 0) top = _filled[a] * _hs - _lakeDrop;
		if (_lake[a + 1] != 0) top = Math.Max(top, _filled[a + 1] * _hs - _lakeDrop);
		a += _sw;
		if (_lake[a] != 0) top = Math.Max(top, _filled[a] * _hs - _lakeDrop);
		if (_lake[a + 1] != 0) top = Math.Max(top, _filled[a + 1] * _hs - _lakeDrop);
		return top;
	}

	/// <summary>Heightfield.depth_at(x, z) без ног: настилы мостов не учитываются.</summary>
	private double Depth(double x, double z)
	{
		int tx = (int)Math.Floor(x / _tile), tz = (int)Math.Floor(z / _tile);
		if (tx < 0 || tz < 0 || tx >= _sw || tz >= _sh)
			return 0.0;
		double l = Math.Max(0.0, Math.Max(RiverLevel(x, z), LakeLevel(x, z)));
		return Math.Max(0.0, l - Ground(x, z));
	}

	/// <summary>Клетки из cells, где хотя бы в одной из девяти точек StageTrails._unsafe_ford вода глубже limit
	/// без учёта мостов (с мостами глубина только меньше): кандидаты для полной проверки.</summary>
	public int[] DeepFords(int[] cells, double limit)
	{
		var outCells = new System.Collections.Generic.List<int>();
		ReadOnlySpan<double> offsets = stackalloc double[] { -0.4, 0.0, 0.4 };
		foreach (int i in cells)
		{
			bool deep = false;
			for (int a = 0; a < 3 && !deep; a++)
				for (int b = 0; b < 3 && !deep; b++)
					deep = Depth((i % _sw + 0.5 + offsets[b]) * _tile, (i / _sw + 0.5 + offsets[a]) * _tile) > limit;
			if (deep)
				outCells.Add(i);
		}
		return outCells.ToArray();
	}

	/// <summary>Копия StageTrails._road_segment: участок ленты от (ax, ay) до (bx, by) шириной aw (клетки)
	/// не уходит в воду глубже 0,3 м и не круче maxGrade вдоль и maxCross поперёк.</summary>
	public bool RoadSegment(double ax, double ay, double bx, double by, double aw, double maxGrade, double maxCross)
	{
		double dx = bx - ax, dy = by - ay;
		double length = Math.Sqrt(dx * dx + dy * dy);
		if (length < 0.00001)
			return true;
		int steps = Math.Max(1, (int)Math.Ceiling(length / 0.1));
		double nx = -dy / length * aw * 0.5;
		double ny = dx / length * aw * 0.5;
		for (int s = -1; s <= 1; s++)
		{
			double side = s;
			double previous = 0.0;
			for (int k = 0; k <= steps; k++)
			{
				double t = (double)k / steps;
				double x = (ax + dx * t + nx * side) * _tile;
				double z = (ay + dy * t + ny * side) * _tile;
				double h = Ground(x, z);
				if (Depth(x, z) > 0.3 || k > 0 && Math.Abs(h - previous) > maxGrade * length * _tile / steps + 0.00001)
					return false;
				previous = h;
			}
		}
		for (int k = 0; k <= steps; k++)
		{
			double t = (double)k / steps;
			double x = (ax + dx * t) * _tile;
			double z = (ay + dy * t) * _tile;
			double across = Math.Abs(Ground(x + nx * _tile, z + ny * _tile) - Ground(x - nx * _tile, z - ny * _tile));
			if (across > maxCross * aw * _tile + 0.00001)
				return false;
		}
		return true;
	}

	/// <summary>Копия StageTrails._bridge_ends (ревью дорожной сети 29.10, шаг 5): концы настила на оси (ax, az) → (bx, bz)
	/// длиной len и направлением (ux, uz), полуширина half. 0 — годятся, 1 — перепад концов больше maxRise,
	/// 2 — край въезда над водой глубже 0,3 м, 3 — край въезда дальше landingGap от конца настила.</summary>
	public int BridgeEnds(double ax, double az, double bx, double bz, double ux, double uz, double len, double half,
		double maxRise, double landingGap)
	{
		double ay = Ground(ax, az), by = Ground(bx, bz);
		if (Math.Abs(by - ay) > maxRise)
			return 1;
		for (int end = 0; end < 2; end++)
		{
			double t = end == 0 ? 0.0 : len;
			double deck = end == 0 ? ay : by;
			for (int s = -1; s <= 1; s++)
			{
				double side = s;
				double x = ax + ux * t - uz * side * half;
				double z = az + uz * t + ux * side * half;
				if (Depth(x, z) > 0.3)
					return 2;
				if (Math.Abs(Ground(x, z) - deck) > landingGap)
					return 3;
			}
		}
		return 0;
	}

	/// <summary>Копия StageTrails._crosses_water: вода глубже 0,3 м хотя бы в одной целой точке оси (1..ceil(len) − 1 м).</summary>
	public bool CrossesWater(double ax, double az, double ux, double uz, double len)
	{
		int n = (int)Math.Ceiling(len);
		for (int k = 1; k < n; k++)
			if (Depth(ax + ux * k, az + uz * k) > 0.3)
				return true;
		return false;
	}

	/// <summary>Копия поиска в StageTrails._mountain_trails: первая клетка с mask ≥ 2 и проходимой стоимостью,
	/// ближайшая к (px, py) по центрам клеток; [клетка, расстояние] или [-1, INF].</summary>
	public double[] NearestPath(byte[] mask, float[] cost, int w, double px, double py)
	{
		int best = -1;
		double bd = double.PositiveInfinity;
		for (int i = 0; i < mask.Length; i++)
		{
			if (mask[i] < 2 || float.IsPositiveInfinity(cost[i]))
				continue;
			double a = i % w + 0.5 - px, b = i / w + 0.5 - py;
			double d = Math.Sqrt(a * a + b * b);
			if (d < bd)
			{
				bd = d;
				best = i;
			}
		}
		return new double[] { best, bd };
	}
}
