using System;
using System.Collections.Generic;
using Godot;

/// <summary>
/// Земля и вода базового рельефа для дорожного этапа (с 9.7): копии Heightfield.base_ground_at, river_level,
/// lake_level, depth_at без настилов мостов и StageTrails._road_segment. Только для рельефа генерации:
/// без полотна дорог (RoadRefinement) и без земли за краем карты (OuterLand). Арифметика как в GDScript:
/// double, значения массивов и вершин лент — float.
/// </summary>
public partial class FastGrid
{
	public float[] CompleteWaterLevels(byte[] ocean, byte[] river, byte[] riverCells, double heightScale)
	{
		if (!RequireWater()) return Array.Empty<float>();
		if (ocean.Length != _sw * _sh || river.Length != ocean.Length || riverCells.Length != ocean.Length)
		{
			WaterFailure("Invalid complete-water masks");
			return Array.Empty<float>();
		}
		var levels = new float[_sw * _sh];
		for (int i = 0; i < levels.Length; i++)
		{
			if (ocean[i] != 0) { levels[i] = 0; continue; }
			if (_lake[i] != 0) { levels[i] = (float)(_filled[i] * heightScale - _lakeDrop); continue; }
			double level = double.NegativeInfinity;
			if (riverCells[i] != 0)
			{
				level = RiverLevel((i % _sw + 0.5) * _tile, (i / _sw + 0.5) * _tile);
				if (river[i] != 0) level = Math.Max(level, _filled[i] * heightScale - _lakeDrop);
			}
			levels[i] = (float)level;
			for (int j = _cellStart[i]; j < _cellStart[i + 1]; j++)
			{
				int at = _cellSeg[j] * 12;
				levels[i] = Math.Max(levels[i], Math.Max(_segPts[at + 1], _segPts[at + 7]));
			}
		}
		return levels;
	}

	private int _sw, _sh;
	private double _tile, _hs, _lakeDrop;
	private float[] _surfHv = Array.Empty<float>();
	private float[] _segPts = Array.Empty<float>(); // по 12 на отрезок ленты: a.left, a.right, b.left, b.right
	private int[] _cellStart = Array.Empty<int>();
	private int[] _cellSeg = Array.Empty<int>();
	private byte[] _lake = Array.Empty<byte>();
	private float[] _filled = Array.Empty<float>();
	private bool _waterValid, _groundValid;
	private string _waterError = "Water and ground have not been configured";

	public bool WaterReady() => _waterValid && _groundValid;
	public string WaterSetupError() => _waterError;
	private bool WaterFailure(string reason) { _waterError = reason; return false; }
	private bool RequireWater() => WaterReady() || WaterFailure("Complete SetWater and SetGround successfully before querying the surface");
	private static bool Finite(double a, double b) => double.IsFinite(a) && double.IsFinite(b);

	/// <summary>Ленты рек по клеткам: пары (клетка, отрезок) в любом порядке, как Heightfield._river_cells.</summary>
	public bool SetWater(int w, int h, double tile, double hs, double lakeDrop, float[] segPts, int[] pairCells, int[] pairSegs, byte[] lake, float[] filled)
	{
		// A failed replacement must never expose an earlier world's surface.
		_waterValid = _groundValid = false;
		_surfHv = Array.Empty<float>();
		long count = (long)w * h;
		if (w < 2 || h < 2 || count >= int.MaxValue || !Finite(tile, hs) || tile <= 0 || hs <= 0 || !Finite(tile * w, tile * h) || !double.IsFinite(lakeDrop) || lakeDrop < 0)
			return WaterFailure("Invalid water grid dimensions or scale");
		if (segPts == null || pairCells == null || pairSegs == null || lake == null || filled == null || lake.Length != count || filled.Length != count)
			return WaterFailure("Missing or incomplete water arrays");
		if (segPts.Length % 12 != 0 || pairCells.Length != pairSegs.Length)
			return WaterFailure("Incomplete river segment or mismatched river index pairs");
		foreach (float value in segPts)
			if (!float.IsFinite(value)) return WaterFailure("Non-finite river vertex");
		foreach (float value in filled)
			if (!float.IsFinite(value)) return WaterFailure("Non-finite filled height");
		for (int k = 0; k < pairCells.Length; k++)
			if ((uint)pairCells[k] >= (uint)count || (uint)pairSegs[k] >= (uint)(segPts.Length / 12))
				return WaterFailure("River index references a cell or segment outside the configured arrays");
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
		_waterValid = true;
		_waterError = "";
		return true;
	}

	/// <summary>Высоты hv: рельеф меняется после выемок туннелей, поэтому передаётся перед каждым использованием.</summary>
	public bool SetGround(float[] hv)
	{
		_groundValid = false;
		if (!_waterValid || hv == null || hv.Length != (long)_sw * _sh)
			return WaterFailure("Ground requires a configured water grid and exactly W*H heights");
		foreach (float value in hv)
			if (!float.IsFinite(value)) return WaterFailure("Non-finite ground height");
		_surfHv = hv;
		_groundValid = true;
		_waterError = "";
		return true;
	}

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
		if (!RequireWater()) return Array.Empty<int>();
		if (cells == null || !double.IsFinite(limit) || limit < 0)
		{ WaterFailure("Invalid ford cells or depth limit"); return Array.Empty<int>(); }
		foreach (int cell in cells)
			if ((uint)cell >= (uint)(_sw * _sh))
			{ WaterFailure("Ford cell outside the water grid"); return Array.Empty<int>(); }
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
		if (!RequireWater()) return false;
		if (!Finite(ax, ay) || !Finite(bx, by) || !Finite(aw, maxGrade) || !double.IsFinite(maxCross) || aw < 0 || maxGrade < 0 || maxCross < 0)
			return WaterFailure("Invalid road segment coordinates or limits");
		double dx = bx - ax, dy = by - ay;
		double length = Math.Sqrt(dx * dx + dy * dy);
		if (!double.IsFinite(length) || length > (double)_sw + _sh || length / 0.1 >= int.MaxValue)
			return WaterFailure("Road segment exceeds supported sampling range");
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
				if (!Finite(x, z)) return WaterFailure("Road sampling coordinates overflow");
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
			if (!Finite(x + nx * _tile, z + ny * _tile) || !Finite(x - nx * _tile, z - ny * _tile))
				return WaterFailure("Road cross-slope sampling coordinates overflow");
			double across = Math.Abs(Ground(x + nx * _tile, z + ny * _tile) - Ground(x - nx * _tile, z - ny * _tile));
			if (across > maxCross * aw * _tile + 0.00001)
				return false;
		}
		return true;
	}

	/// <summary>Копия StageTrails._road_line (07.11.2026: раньше вызов RoadSegment из GDScript на каждую точку, ~треть
	/// публикации путей): три прохода скругления углов. Точка k неподвижна, если клетка её или соседней точки на оси
	/// сооружения (onAxis, пустой — нет осей); иначе угол срезается точками на четверти отрезков, когда три новых отрезка
	/// проходят RoadSegment. Ширина отрезка — у его первой точки. Возвращает [x..., y..., w...] (по n значений).</summary>
	public double[] RoadLine(double[] xs, double[] ys, double[] ws, byte[] onAxis, int width, int height, double maxGrade, double maxCross)
	{
		var x = new List<double>(xs);
		var y = new List<double>(ys);
		var w = new List<double>(ws);
		bool axis = onAxis.Length > 0;
		for (int iteration = 0; iteration < 3; iteration++)
		{
			int n = x.Count;
			var ox = new List<double>(n * 2) { x[0] };
			var oy = new List<double>(n * 2) { y[0] };
			var ow = new List<double>(n * 2) { w[0] };
			for (int k = 1; k < n - 1; k++)
			{
				bool fixedPoint = false;
				if (axis)
					for (int m = k - 1; m <= k + 1 && !fixedPoint; m++)
					{
						int cx = Math.Clamp((int)x[m], 0, width - 1);
						int cy = Math.Clamp((int)y[m], 0, height - 1);
						fixedPoint = onAxis[cy * width + cx] != 0;
					}
				double qx = x[k] + (x[k - 1] - x[k]) * 0.25, qy = y[k] + (y[k - 1] - y[k]) * 0.25;
				double rx = x[k] + (x[k + 1] - x[k]) * 0.25, ry = y[k] + (y[k + 1] - y[k]) * 0.25;
				int last = ox.Count - 1;
				if (!fixedPoint && RoadSegment(ox[last], oy[last], qx, qy, ow[last], maxGrade, maxCross)
					&& RoadSegment(qx, qy, rx, ry, w[k], maxGrade, maxCross) && RoadSegment(rx, ry, x[k + 1], y[k + 1], w[k], maxGrade, maxCross))
				{
					ox.Add(qx); oy.Add(qy); ow.Add(w[k]);
					ox.Add(rx); oy.Add(ry); ow.Add(w[k]);
				}
				else
				{
					ox.Add(x[k]); oy.Add(y[k]); ow.Add(w[k]);
				}
			}
			ox.Add(x[n - 1]); oy.Add(y[n - 1]); ow.Add(w[n - 1]);
			x = ox; y = oy; w = ow;
		}
		var result = new double[x.Count * 3];
		for (int i = 0; i < x.Count; i++)
		{
			result[i] = x[i];
			result[x.Count + i] = y[i];
			result[2 * x.Count + i] = w[i];
		}
		return result;
	}

	/// <summary>Копия StageTrails._bridge_ends (ревью дорожной сети 29.10, шаг 5): концы настила на оси (ax, az) → (bx, bz)
	/// длиной len и направлением (ux, uz), полуширина half. 0 — годятся, 1 — перепад концов больше maxRise,
	/// 2 — край въезда над водой глубже 0,3 м, 3 — край въезда дальше landingGap от конца настила.</summary>
	public int BridgeEnds(double ax, double az, double bx, double bz, double ux, double uz, double len, double half,
		double maxRise, double landingGap)
	{
		if (!RequireWater()) return -1;
		if (!Finite(ax, az) || !Finite(bx, bz) || !Finite(ux, uz) || !Finite(len, half) || !Finite(maxRise, landingGap) || len < 0 || half < 0 || maxRise < 0 || landingGap < 0)
		{ WaterFailure("Invalid bridge ends or landing limits"); return -1; }
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
				if (!Finite(x, z)) { WaterFailure("Bridge landing sampling coordinates overflow"); return -1; }
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
		if (!RequireWater()) return false;
		if (!Finite(ax, az) || !Finite(ux, uz) || !double.IsFinite(len) || len < 0 || len > ((double)_sw + _sh) * _tile || len >= int.MaxValue)
			return WaterFailure("Invalid bridge water-crossing axis");
		int n = (int)Math.Ceiling(len);
		for (int k = 1; k < n; k++)
		{
			if (!Finite(ax + ux * k, az + uz * k)) return WaterFailure("Water-crossing sampling coordinates overflow");
			if (Depth(ax + ux * k, az + uz * k) > 0.3)
				return true;
		}
		return false;
	}

	private const double SpanMargin = 1e-6;

	/// <summary>Часть StageTrails._bridge_span без сооружений: земля в пролёте не выше настила + 0,3 м и вода под осью
	/// не выше настила − 0,1 м. Настил — копия Heightfield.level (дуга arch по секциям section). false — пролёт
	/// точно не годится; true — пролёт проверяет GDScript целиком. Запас SpanMargin: спорная граница (последний знак sin)
	/// не отвергается здесь, её решает GDScript, поэтому выбранный мост тот же.</summary>
	public bool BridgeSpanGround(double ax, double az, double ay, double bx, double bz, double by, double ux, double uz,
		double len, double half, double arch, double section)
	{
		if (!RequireWater()) return false;
		if (!Finite(ax, az) || !Finite(ay, bx) || !Finite(bz, by) || !Finite(ux, uz) || !Finite(len, half) || !Finite(arch, section) || len <= 0 || len > ((double)_sw + _sh) * _tile || len >= int.MaxValue - 3 || half < 0 || section <= 0 || len / section >= int.MaxValue)
			return WaterFailure("Invalid bridge span or section length");
		int last = (int)Math.Ceiling(len) + 2;
		for (int k = -2; k <= last; k++)
		{
			double t = Math.Clamp((double)k, -2.0, len + 2.0);
			double deck = Level(ay, by, len, arch, section, t);
			for (int s = -1; s <= 1; s++)
			{
				double side = s;
				double x = ax + ux * t - uz * side * (half + 0.8);
				double z = az + uz * t + ux * side * (half + 0.8);
				if (!Finite(x, z) || !double.IsFinite(deck)) return WaterFailure("Bridge span sampling coordinates overflow");
				double ground = Ground(x, z);
				if (t > 1.0 && t < len - 1.0 && ground > deck + 0.3 + SpanMargin)
					return false;
				if (s == 0)
				{
					double depth = Depth(x, z);
					if (depth > 0.3 + SpanMargin && ground + depth > deck - 0.1 + SpanMargin)
						return false;
				}
			}
		}
		return true;
	}

	/// <summary>Копия Heightfield.level для моста: прямая между концами и дуга по секциям.</summary>
	private static double Level(double ay, double by, double len, double arch, double section, double t)
	{
		double u = Math.Clamp(t / len, 0.0, 1.0);
		double straight = ay + (by - ay) * u;
		if (arch == 0.0)
			return straight;
		int count = Math.Max(1, (int)Math.Ceiling(len / section));
		double part = Math.Min(u * count, count - 1.0);
		int k = (int)Math.Floor(part);
		double blend = u * count - k;
		double a = Math.Sin(Math.PI * k / count), b = Math.Sin(Math.PI * (k + 1) / count);
		return straight + arch * (a + (b - a) * blend);
	}

	/// <summary>Перебор пар берегов StageTrails._bridge_site на C#: для каждого a из aIdx (в этом порядке) и b от shore
	/// до min(n, shore + approach + 1, a + span) − 1, кроме мокрых b и одинаковых клеток, — те же оси, что
	/// Heightfield._axis (центры клеток × tile), BridgeEnds и CrossesWater. Возвращает
	/// [перепад, въезд над водой, въезд не на уровне, не над водой, затем пары a, b, прошедшие обе проверки — в порядке перебора].</summary>
	public int[] BridgeCandidates(int[] cells, int[] aIdx, int shore, int span, int approach, byte[] wet, int w,
		double tile, double gradeScale, double landingGap, double half)
	{
		var outList = new System.Collections.Generic.List<int> { 0, 0, 0, 0 };
		if (!RequireWater()) return outList.ToArray();
		if (cells == null || aIdx == null || wet == null || cells.Length != wet.Length || w != _sw || tile != _tile || shore < 0 || shore > cells.Length || span <= 0 || approach < 0 || !Finite(gradeScale, landingGap) || !double.IsFinite(half) || gradeScale < 0 || landingGap < 0 || half < 0)
		{ WaterFailure("Invalid bridge candidate arrays, grid or limits"); return outList.ToArray(); }
		foreach (int cell in cells)
			if ((uint)cell >= (uint)(_sw * _sh))
			{ WaterFailure("Bridge candidate cell outside the water grid"); return outList.ToArray(); }
		foreach (int a in aIdx)
			if ((uint)a >= (uint)cells.Length)
			{ WaterFailure("Bridge candidate start outside the path"); return outList.ToArray(); }
		int n = cells.Length;
		foreach (int a in aIdx)
		{
			int end = (int)Math.Min(n, Math.Min((long)shore + approach + 1, (long)a + span));
			double ax = (cells[a] % w + 0.5) * tile, az = (cells[a] / w + 0.5) * tile;
			for (int b = shore; b < end; b++)
			{
				if (wet[b] != 0 || cells[b] == cells[a])
					continue;
				double bx = (cells[b] % w + 0.5) * tile, bz = (cells[b] / w + 0.5) * tile;
				double len = Math.Max(Math.Sqrt((bx - ax) * (bx - ax) + (bz - az) * (bz - az)), 0.01);
				double ux = (bx - ax) / len, uz = (bz - az) / len;
				int code = BridgeEnds(ax, az, bx, bz, ux, uz, len, half, gradeScale * len, landingGap);
				if (code < 0) return new int[] { 0, 0, 0, 0 };
				if (code == 0 && !CrossesWater(ax, az, ux, uz, len))
					code = 4;
				if (code != 0)
				{
					outList[code - 1]++;
					continue;
				}
				outList.Add(a);
				outList.Add(b);
			}
		}
		return outList.ToArray();
	}

	/// <summary>Копия поиска в StageTrails._mountain_trails: первая клетка с mask ≥ 2 и проходимой стоимостью,
	/// ближайшая к (px, py) по центрам клеток; [клетка, расстояние] или [-1, INF].</summary>
	public double[] NearestPath(byte[] mask, float[] cost, int w, double px, double py)
	{
		if (mask == null || cost == null || w <= 0 || mask.Length != cost.Length || mask.Length % w != 0 || !Finite(px, py))
		{ WaterFailure("Invalid nearest-path grid or arrays"); return new double[] { -1, double.PositiveInfinity }; }
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
