using System;
using Godot;

/// <summary>
/// Самые долгие циклы генерации на C#: поиск пути A* (Pathfinder), заполнение впадин (StageHydrology),
/// шум макрорельефа (StageRelief) и поля шума (Parallel.fbm_field).
/// Пакетный выбор сегментов метровой дорожной сетки — NearestRoadSegments.
/// Алгоритмы те же, что в GDScript, и дают тот же результат бит в бит, но в десятки раз быстрее.
/// Работает только в сборке Godot .NET, иначе генерация идёт на GDScript (см. Grid.fast_grid).
/// Арифметика повторяет GDScript: расчёт в double, значения в массивах float — во float.
/// </summary>
public partial class FastGrid : RefCounted
{
	private static readonly int[] Dx = { 1, -1, 0, 0, 1, 1, -1, -1 };
	private static readonly int[] Dy = { 0, 0, 1, -1, 1, -1, 1, -1 };
	/// <summary>Множитель оценки остатка пути A* (как Pathfinder.H_COST).</summary>
	private const double HCost = 0.6;
	private static readonly double[] Dl = { 1.0, 1.0, 1.0, 1.0, 1.4142135623730951, 1.4142135623730951, 1.4142135623730951, 1.4142135623730951 };

	private int _w;
	private int _h;
	private float[] _g = Array.Empty<float>();
	private int[] _from = Array.Empty<int>();
	private int[] _seen = Array.Empty<int>();
	private int[] _done = Array.Empty<int>();
	// Шумы и гидрология тоже создают FastGrid, но буферы A* нужны только после Setup.
	private int[] _heapIds = Array.Empty<int>();
	private double[] _heapKeys = Array.Empty<double>();
	private int _gen;
	public bool ProfileSearches { get; set; }
	public int SearchBudget { get; set; } = -1;
	private long _searchCount, _expandedCount, _searchTicks;
	public Godot.Collections.Dictionary SearchStats() => new()
	{
		["calls"] = _searchCount, ["expanded"] = _expandedCount,
		["native_ms"] = _searchTicks * 1000.0 / System.Diagnostics.Stopwatch.Frequency
	};
	private readonly int[] _off = new int[8];
	private float[] _corridorGround = Array.Empty<float>();
	private float[] _corridorWater = Array.Empty<float>();
	private byte[] _corridorWet = Array.Empty<byte>();
	private float[] _corridorGrades = Array.Empty<float>();
	private float[] _corridorCross = Array.Empty<float>();
	private double _corridorHalf;
	private static readonly int[] Opposite = { 1, 0, 3, 2, 7, 6, 5, 4 };

	/// <summary>Поиск ближайшей ячейки водопоя, точная копия цикла StageTrails._animal_trails.</summary>
	public int FindNearestWater(float[] cost, float[] distWater, int W, int H, int sx, int sy, int R)
	{
		int y0 = Math.Max(0, sy - R);
		int y1 = Math.Min(H, sy + R);
		int x0 = Math.Max(0, sx - R);
		int x1 = Math.Min(W, sx + R);
		double bd = double.PositiveInfinity;
		int best = -1;
		for (int y = y0; y < y1; y++)
		{
			int row = y * W;
			int dy = y - sy;
			int dy2 = dy * dy;
			for (int x = x0; x < x1; x++)
			{
				int i = row + x;
				if (float.IsPositiveInfinity(cost[i]) || distWater[i] > 1.5f)
					continue;
				int dx = x - sx;
				int d = dx * dx + dy2;
				if (d < bd)
				{
					bd = d;
					best = i;
				}
			}
		}
		return best;
	}

	/// <summary>Пакетный выбор ближайшего сегмента, точная копия цикла RoadRefinement._vertex.
	/// Индекс ячейки содержит те же сегменты в прежнем порядке; геометрия и покрытие считаются GDScript.</summary>
	public double[] NearestRoadSegments(Vector2[] points, int width, int height, double tile, double reach,
		Vector2[] anchors, Vector2[] deltas, double[] lengths, double[] halves, byte[] roads,
		int[] starts, int[] candidates)
	{
		var result = new double[points.Length * 4];
		for (int i = 0; i < points.Length; i++)
		{
			Vector2 point = points[i];
			int x = Math.Clamp((int)Math.Floor(point.X / tile - 0.5), 0, width - 2);
			int z = Math.Clamp((int)Math.Floor(point.Y / tile - 0.5), 0, height - 2);
			int key = z * width + x;
			double best = double.PositiveInfinity;
			int at = i * 4;
			result[at] = -1;
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
					best = rank;
					result[at] = id;
					result[at + 1] = f;
					result[at + 2] = d;
					result[at + 3] = offset.Cross(delta.Normalized());
				}
			}
		}
		return result;
	}

	/// <summary>Ленивый кэш ширины прохода, копия Pathfinder.set_corridor.</summary>
	public void SetCorridor(float[] ground, float[] water, byte[] wet, double half)
	{
		_corridorGround = ground;
		_corridorWater = water;
		_corridorWet = wet;
		_corridorHalf = half;
		int count = _w * _h * 8;
		if (_corridorGrades.Length != count)
			_corridorGrades = new float[count];
		Array.Fill(_corridorGrades, -1f);
		if (_corridorCross.Length != count)
			_corridorCross = new float[count];
		// Cross читается только после MeasureCorridor, который заполняет обе величины.
		// Sentinel в Grades сбрасывает кэш при смене поверхности или ширины прохода.
	}

	private double CorridorHeight(double x, double y)
	{
		x = Math.Clamp(x, 0.0, _w - 1.001);
		y = Math.Clamp(y, 0.0, _h - 1.001);
		int ix = (int)Math.Floor(x), iy = (int)Math.Floor(y);
		double tx = x - ix, ty = y - iy;
		int a = iy * _w + ix;
		var h = _corridorGround;
		if (tx + ty <= 1.0)
			return h[a] + ((double)h[a + 1] - h[a]) * tx + ((double)h[a + _w] - h[a]) * ty;
		int d = a + _w + 1;
		return h[d] + ((double)h[d - 1] - h[d]) * (1.0 - tx) + ((double)h[d - _w] - h[d]) * (1.0 - ty);
	}

	private void MeasureCorridor(int c, int k)
	{
		int key = c * 8 + k;
		if (_corridorGrades[key] >= 0f) return;
		int n = c + _off[k];
		double grade = 0.0, cross = 0.0;
		if ((_corridorWet[c] == 0 || _corridorGround[c] >= _corridorWater[c]) &&
			(_corridorWet[n] == 0 || _corridorGround[n] >= _corridorWater[n]))
		{
			double nx = -Dy[k] / Dl[k] * _corridorHalf, ny = Dx[k] / Dl[k] * _corridorHalf;
			Span<double> previous = stackalloc double[3];
			for (int j = 0; j < 5; j++)
			{
				double left = 0.0, right = 0.0;
				for (int side = 0; side < 3; side++)
				{
					double x = c % _w + Dx[k] * j * 0.25 + nx * (side - 1);
					double y = c / _w + Dy[k] * j * 0.25 + ny * (side - 1);
					double h = CorridorHeight(x, y);
					int cell = Math.Clamp((int)Math.Floor(y + 0.5), 0, _h - 1) * _w + Math.Clamp((int)Math.Floor(x + 0.5), 0, _w - 1);
					if (_corridorWater[cell] > h) grade = double.PositiveInfinity;
					if (j > 0) grade = Math.Max(grade, Math.Abs(h - previous[side]) * 4.0 / Dl[k]);
					previous[side] = h;
					if (side == 0) left = h;
					if (side == 2) right = h;
				}
				cross = Math.Max(cross, Math.Max(Math.Abs(right - previous[1]), Math.Abs(left - previous[1])) / _corridorHalf);
			}
		}
		_corridorGrades[key] = _corridorGrades[n * 8 + Opposite[k]] = (float)grade;
		_corridorCross[key] = _corridorCross[n * 8 + Opposite[k]] = (float)cross;
	}

	/// <summary>Задаёт размер карты и выделяет буферы поиска; вызывается из Pathfinder._init до FindPath.</summary>
	public void Setup(int w, int h)
	{
		_w = w;
		_h = h;
		for (int k = 0; k < 8; k++)
			_off[k] = Dy[k] * w + Dx[k];
		_g = new float[w * h];
		_from = new int[w * h];
		_seen = new int[w * h];
		_done = new int[w * h];
		if (_heapIds.Length == 0)
		{
			_heapIds = new int[1 << 16];
			_heapKeys = new double[1 << 16];
		}
		_gen = 0;
	}

	/// <summary>Путь от клетки s до клетки t по стоимости cost или пустой массив. Копия Pathfinder.find_path.</summary>
	public int[] FindPath(float[] cost, int s, int t, float[] heights, double climb, double maxGrade, byte[] links, bool useCorridor, double maxCrossGrade)
	{
		if (!ProfileSearches)
			return FindPathCore(cost, s, t, heights, climb, maxGrade, links, useCorridor, maxCrossGrade);
		long started = System.Diagnostics.Stopwatch.GetTimestamp();
		_searchCount++;
		var path = FindPathCore(cost, s, t, heights, climb, maxGrade, links, useCorridor, maxCrossGrade);
		_searchTicks += System.Diagnostics.Stopwatch.GetTimestamp() - started;
		return path;
	}

	private int[] FindPathCore(float[] cost, int s, int t, float[] heights, double climb, double maxGrade, byte[] links, bool useCorridor, double maxCrossGrade)
	{
		bool terrain = heights.Length > 0 && (climb > 0.0 || maxGrade < double.PositiveInfinity);
		int W = _w, H = _h, W1 = W - 1, H1 = H - 1;
		var off = _off;
		var g = _g;
		var from = _from;
		var seen = _seen;
		var done = _done;
		var ids = _heapIds;
		var keys = _heapKeys;
		int gn = ++_gen;
		int tx = t % W, ty = t / W;
		g[s] = 0f;
		seen[s] = gn;
		from[s] = -1;
		ids[0] = s;
		keys[0] = 0.0;
		int hn = 1;
		while (hn > 0)
		{
			int c = Pop(ids, keys, ref hn);
			if (c == t)
				break;
			if (done[c] == gn)
				continue;
			if (SearchBudget == 0)
			{
				_heapIds = ids;
				_heapKeys = keys;
				return Array.Empty<int>();
			}
			if (SearchBudget > 0) SearchBudget--;
			done[c] = gn;
			if (ProfileSearches) _expandedCount++;
			int cx = c % W, cy = c / W;
			double gc = g[c];
			double cc = cost[c];
			bool inner = cx > 0 && cy > 0 && cx < W1 && cy < H1;
			for (int k = 0; k < 8; k++)
			{
				int nx = cx + Dx[k], ny = cy + Dy[k];
				int n = c + off[k];
				if (!inner && (nx < 0 || ny < 0 || nx >= W || ny >= H))
					continue;
				double cn = cost[n];
				if (double.IsPositiveInfinity(cn) || done[n] == gn)
					continue;
				double step = (cc + cn) * 0.5;
				bool linked = links.Length > 0 && (links[c] & (1 << k)) != 0;
				if (k >= 4 && !linked)
				{
					double ca = cost[c + Dx[k]], cb = cost[c + Dy[k] * W];
					if (double.IsPositiveInfinity(ca) || double.IsPositiveInfinity(cb))
						continue;
					step = Math.Max(step, (ca + cb) * 0.5);
				}
				if (terrain)
				{
					double grade = Math.Abs((double)heights[n] - heights[c]) / Dl[k];
					if ((k == 4 || k == 7) && !linked)
					{
						double mid = ((double)heights[c + Dx[k]] + heights[c + Dy[k] * W]) * 0.5;
						grade = Math.Max(Math.Abs(mid - heights[c]), Math.Abs(heights[n] - mid)) * 2.0 / Dl[k];
					}
					double crossGrade = 0.0;
					if (useCorridor && _corridorGround.Length > 0 && !linked)
					{
						MeasureCorridor(c, k);
						grade = Math.Max(grade, _corridorGrades[c * 8 + k]);
						crossGrade = _corridorCross[c * 8 + k];
						if (double.IsPositiveInfinity(grade)) continue;
					}
					if (grade > maxGrade || crossGrade > maxCrossGrade)
						continue;
					double steep = Math.Max(0.0, grade - 0.22);
					step += climb * (grade * grade + 4.0 * steep * steep + crossGrade * crossGrade);
				}
				double ng = gc + Dl[k] * step;
				if (seen[n] != gn || ng < g[n])
				{
					seen[n] = gn;
					g[n] = (float)ng;
					from[n] = c;
					int ax = Math.Abs(nx - tx), ay = Math.Abs(ny - ty);
					double key = ng + (Math.Max(ax, ay) + 0.414 * Math.Min(ax, ay)) * HCost;
					if (hn >= ids.Length)
					{
						Array.Resize(ref ids, ids.Length * 2);
						Array.Resize(ref keys, keys.Length * 2);
					}
					Push(ids, keys, ref hn, n, key);
				}
			}
		}
		_heapIds = ids;
		_heapKeys = keys;
		if (seen[t] != gn)
			return Array.Empty<int>();
		int len = 0;
		for (int c = t; c != -1; c = from[c])
			len++;
		var path = new int[len];
		for (int c = t, i = len - 1; c != -1; c = from[c], i--)
			path[i] = c;
		return path;
	}

	/// <summary>
	/// Заполнение впадин (priority flood) от океана. Копия цикла из StageHydrology._priority_flood.
	/// Возвращает {filled, down, order, order_n}.
	/// </summary>
	public Godot.Collections.Dictionary PriorityFlood(float[] h, byte[] ocean, int W, int H)
	{
		int N = W * H;
		var filled = (float[])h.Clone();
		var down = new int[N];
		Array.Fill(down, -1);
		var order = new int[N];
		int orderN = 0;
		var closed = new bool[N];
		var ids = new int[N + 16];
		var keys = new double[N + 16];
		int hn = 0;
		for (int i = 0; i < N; i++)
		{
			int ex = i % W, ey = i / W;
			if (ocean[i] != 0 || ex == 0 || ey == 0 || ex == W - 1 || ey == H - 1)
			{
				closed[i] = true;
				Push(ids, keys, ref hn, i, h[i]);
			}
		}
		while (hn > 0)
		{
			int c = Pop(ids, keys, ref hn);
			order[orderN++] = c;
			int cx = c % W, cy = c / W;
			double fc = filled[c];
			for (int k = 0; k < 8; k++)
			{
				int nx = cx + Dx[k], ny = cy + Dy[k];
				if (nx < 0 || ny < 0 || nx >= W || ny >= H)
					continue;
				int n = ny * W + nx;
				if (closed[n])
					continue;
				closed[n] = true;
				double hv = h[n];
				double up = fc + 1e-5;
				filled[n] = (float)(hv > up ? hv : up);
				down[n] = c;
				Push(ids, keys, ref hn, n, filled[n]);
			}
		}
		return new Godot.Collections.Dictionary
		{
			["filled"] = filled,
			["down"] = down,
			["order"] = order,
			["order_n"] = orderN,
		};
	}

	// ---------- Шум: копия Simplex.noise / fbm / ridged и циклов StageRelief._rows, Parallel.fbm_field ----------

	private static readonly double F2 = 0.5 * (Math.Sqrt(3.0) - 1.0);
	private static readonly double G2 = (3.0 - Math.Sqrt(3.0)) / 6.0;

	private static double Grad(int g, double x, double y)
	{
		if (g < 4)
			return ((g & 1) == 0 ? x : -x) + (g < 2 ? y : -y);
		if (g < 6)
			return g == 4 ? x : -x;
		return g == 6 ? y : -y;
	}

	/// <summary>Копия Simplex.noise; perm — Simplex.perm (512 чисел).</summary>
	private static double Noise(int[] pm, double xin, double yin)
	{
		double g2 = G2;
		double s = (xin + yin) * F2;
		int i = (int)Math.Floor(xin + s);
		int j = (int)Math.Floor(yin + s);
		double t = (i + j) * g2;
		double x0 = xin - (i - t);
		double y0 = yin - (j - t);
		int i1 = 0, j1 = 1;
		if (x0 > y0)
		{
			i1 = 1;
			j1 = 0;
		}
		double x1 = x0 - i1 + g2;
		double y1 = y0 - j1 + g2;
		double x2 = x0 - 1.0 + 2.0 * g2;
		double y2 = y0 - 1.0 + 2.0 * g2;
		int ii = i & 255, jj = j & 255;
		double n = 0.0;
		double t0 = 0.5 - x0 * x0 - y0 * y0;
		if (t0 > 0.0)
		{
			double d = Grad(pm[ii + pm[jj]] & 7, x0, y0);
			t0 *= t0;
			n += t0 * t0 * d;
		}
		double t1 = 0.5 - x1 * x1 - y1 * y1;
		if (t1 > 0.0)
		{
			double d = Grad(pm[ii + i1 + pm[jj + j1]] & 7, x1, y1);
			t1 *= t1;
			n += t1 * t1 * d;
		}
		double t2 = 0.5 - x2 * x2 - y2 * y2;
		if (t2 > 0.0)
		{
			double d = Grad(pm[ii + 1 + pm[jj + 1]] & 7, x2, y2);
			t2 *= t2;
			n += t2 * t2 * d;
		}
		return 70.0 * n;
	}

	private static double Fbm(int[] pm, double x, double y, int oct)
	{
		double a = 1.0, f = 1.0, s = 0.0, n = 0.0;
		for (int o = 0; o < oct; o++)
		{
			s += a * Noise(pm, x * f, y * f);
			n += a;
			a *= 0.5;
			f *= 2.0;
		}
		return s / n;
	}

	private static double Ridged(int[] pm, double x, double y, int oct)
	{
		double a = 0.5, f = 1.0, s = 0.0, w = 1.0;
		for (int o = 0; o < oct; o++)
		{
			double v = 1.0 - Math.Abs(Noise(pm, x * f, y * f));
			v *= v;
			v *= w;
			w = Math.Min(1.0, Math.Max(0.0, v * 2.0));
			s += v * a;
			f *= 2.1;
			a *= 0.5;
		}
		return s;
	}

	private static double Clamp01(double v) => v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v);

	/// <summary>Поле fbm(x / d + ox, y / d + oy, oct) по всем клеткам. Копия Parallel.fbm_field.</summary>
	public double[] FbmField(int[] perm, int W, int H, double d, int oct, double ox, double oy)
	{
		return FbmRect(perm, 0, 0, W, H, d, oct, ox, oy, true);
	}

	/// <summary>То же поле по прямоугольнику клеток W × H с углом (x0, y0), в том числе за картой (OuterLand).</summary>
	public double[] FbmRect(int[] perm, int x0, int y0, int W, int H, double d, int oct, double ox, double oy, bool parallel)
	{
		var r = new double[W * H];
		void Row(int j)
		{
			int y = y0 + j;
			for (int i = 0; i < W; i++)
				r[j * W + i] = Fbm(perm, (x0 + i) / d + ox, y / d + oy, oct);
		}
		RunRows(H, parallel, Row);
		return r;
	}

	/// <summary>Расстояние в клетках до ближайшей клетки source != 0 (фаска 1 / √2): копия Grid.distance_field,
	/// с теми же округлениями (сравнение в double, хранение во float). С 8.4: его считают и куски OuterLand.</summary>
	public float[] DistanceField(int w, int h, byte[] source)
	{
		const double Sqrt2 = 1.4142135623730951;
		int n = w * h;
		var d = new float[n];
		for (int i = 0; i < n; i++)
			d[i] = source[i] != 0 ? 0f : 1e9f;
		for (int y = 0; y < h; y++)
			for (int x = 0; x < w; x++)
			{
				int i = y * w + x;
				double v = d[i];
				if (x > 0) v = Math.Min(v, d[i - 1] + 1.0);
				if (y > 0)
				{
					v = Math.Min(v, d[i - w] + 1.0);
					if (x > 0) v = Math.Min(v, d[i - w - 1] + Sqrt2);
					if (x < w - 1) v = Math.Min(v, d[i - w + 1] + Sqrt2);
				}
				d[i] = (float)v;
			}
		for (int y = h - 1; y >= 0; y--)
			for (int x = w - 1; x >= 0; x--)
			{
				int i = y * w + x;
				double v = d[i];
				if (x < w - 1) v = Math.Min(v, d[i + 1] + 1.0);
				if (y < h - 1)
				{
					v = Math.Min(v, d[i + w] + 1.0);
					if (x < w - 1) v = Math.Min(v, d[i + w + 1] + Sqrt2);
					if (x > 0) v = Math.Min(v, d[i + w - 1] + Sqrt2);
				}
				d[i] = (float)v;
			}
		return d;
	}

	// Куски уже параллельны на WorkerThreadPool Godot. Вложенный пул .NET здесь
	// лишь отнимает ядра у кадра и растительности. Целое поле при загрузке распараллеливаем.
	private static void RunRows(int height, bool parallel, Action<int> row)
	{
		if (parallel)
			System.Threading.Tasks.Parallel.For(0, height, row);
		else
			for (int j = 0; j < height; j++)
				row(j);
	}

	/// <summary>Масштаб и вклад шума материков: копия StageRelief.MACRO, MACRO_AMP, MACRO_LIFT.</summary>
	private const double Macro = 1400.0;
	private const double MacroAmp = 1.2;
	private const double MacroLift = 0.25;
	/// <summary>Сдвиг шума материков вверх (больше суши): копия StageRelief.LAND_BIAS.</summary>
	private const double LandBias = 0.18;

	/// <summary>Негорный рельеф: копия StageRelief.SEA_RAW, CHARACTER, PLAIN_LIFT, PLAIN_HILLS, HILL_AMP, FOOTHILLS, MASK_EDGE, VALLEY, VALLEY_WIDTH, VALLEY_DEPTH.</summary>
	private const double SeaRaw = 0.067;
	private const double Character = 520.0;
	private const double PlainLift = 0.3;
	private const double PlainHills = 0.15;
	private const double HillAmp = 0.07;
	private const double Foothills = 0.35;
	private const double FoothillLift = 0.18; // StageRelief.FOOTHILL_LIFT (с 3.6)
	private const double MaskEdge = 0.9;
	private const double Valley = 260.0;
	private const double ValleyWidth = 0.24;
	private const double ValleyDepth = 0.06;

	/// <summary>
	/// Макрорельеф до уровня моря: копия StageRelief.raw_at по прямоугольнику клеток W × H с углом (x0, y0).
	/// Шумы — perm в порядке warpX, warpY, cont, mask, ridge, hill; (mx, my) — сдвиг шума материков.
	/// </summary>
	public float[] ReliefField(int[] warpX, int[] warpY, int[] cont, int[] mask, int[] ridge, int[] hill, double mx, double my, int x0, int y0, int W, int H, double mountainScale, double mountainBias, double mountainHeight, double foothillSpread, bool parallel)
	{
		var outH = new float[W * H];
		void Row(int j)
		{
			int y = y0 + j;
			for (int i = 0; i < W; i++)
			{
				int x = x0 + i;
				double wx = Fbm(warpX, x / 240.0, y / 240.0, 3) * 25.0;
				double wy = Fbm(warpY, x / 240.0 + 13.1, y / 240.0 - 7.7, 3) * 25.0;
				double X = x + wx;
				double Y = y + wy;
				// С 3.7 мелкие октавы основания затухают внутри массива.
				double mountainField = Fbm(mask, X / (Massif * mountainScale) + 7.0, Y / (Massif * mountainScale) - 3.0, 2) + mountainBias;
				double t = Clamp01(mountainField / MaskEdge);
				double core = t * t * (3.0 - 2.0 * t);
				double c = Continental(cont, X / 240.0, Y / 240.0, 1.0 - 0.85 * core);
				double macro = Fbm(cont, (X + mx) / Macro + 91.7, (Y + my) / Macro - 43.1, 2);
				double lift = macro * MacroAmp;
				double bas = c + (lift < MacroLift ? lift : MacroLift) + LandBias;
				t = Clamp01((bas - -0.05) / (0.25 - -0.05));
				double land = t * t * (3.0 - 2.0 * t);
				double m = core;
				t = Clamp01((Fbm(hill, X / Character + 41.9, Y / Character - 66.1, 2) - -0.15) / 0.4);
				double rough = t * t * (3.0 - 2.0 * t);
				t = Clamp01((bas - 0.18) / 0.17);
				double inland = t * t * (3.0 - 2.0 * t);
				t = Clamp01(1.0 - Math.Abs(Noise(ridge, X / Valley + 5.3, Y / Valley - 9.4)) / ValleyWidth);
				double valley = t * t * (3.0 - 2.0 * t);
				double width = 0.1 + 0.4 * foothillSpread * (0.6 + 0.4 * rough);
				t = Clamp01((mountainField + width) / (MaskEdge * 0.65 + width));
				double foothills = t * t * (3.0 - 2.0 * t) * (1.0 - core) * foothillSpread * (0.5 + 0.5 * rough) * (1.0 - 0.5 * valley);
				t = Clamp01((m - Foothills) / Foothills);
				m *= rough + (1.0 - rough) * m * m;
				rough = Math.Max(rough, t * t * (3.0 - 2.0 * t));
				rough += (1.0 - rough) * foothills;
				double h = bas * 0.55;
				if (h > SeaRaw)
					h = SeaRaw + (h - SeaRaw) * (PlainLift + (1.0 - PlainLift) * rough);
				double hills = Fbm(hill, X / 40.0, Y / 40.0, 4);
				if (foothills > 0.0)
				{
					double rolling = Fbm(hill, X / (100.0 * mountainScale) + 32.4, Y / (100.0 * mountainScale) - 18.6, 2);
					hills += (rolling - hills) * foothills;
					h += foothills * (FoothillLift + 0.08 * rolling) * mountainHeight;
				}
				h += hills * HillAmp * (0.3 + land) * (PlainHills + (1.0 - PlainHills) * rough) * (1.0 - m * 0.85);
				h -= valley * ValleyDepth * rough * inland;
				if (m > 0.0)
					h += Mountain(ridge, hill, (x + wx * MountainWarp) / mountainScale, (y + wy * MountainWarp) / mountainScale) * m * MountainAmp * mountainHeight;
				outH[j * W + i] = (float)h;
			}
		}
		RunRows(H, parallel, Row);
		return outH;
	}

	/// <summary>Копия StageRelief._continental: прежние шесть октав, без усиления крупных форм.</summary>
	private static double Continental(int[] pm, double x, double y, double detail)
	{
		double a = 1.0, f = 1.0, s = 0.0, n = 0.0;
		for (int o = 0; o < 6; o++)
		{
			s += a * Noise(pm, x * f, y * f) * (o >= 2 ? detail : 1.0);
			n += a;
			a *= 0.5;
			f *= 2.0;
		}
		return s / n;
	}

	/// <summary>Горы: копия StageRelief.MASSIF, MOUNTAIN_AMP, MOUNTAIN_WARP, RIDGE_ALONG, RIDGE_ACROSS, DIR_C, DIR_S, ASYM, PEAK_CAP, CREST_ROUND.</summary>
	private const double Massif = 650.0;
	private const double MountainAmp = 1.0;
	/// <summary>Общее основание и доля гребней (с 3.3): копия StageRelief.MASSIF_BASE, CREST_SHARE.</summary>
	private const double MassifBase = 0.24;
	private const double CrestShare = 0.75;
	/// <summary>Внутренние долины (с 3.4): копия StageRelief.INNER_ALONG, INNER_ACROSS, INNER_CUT, SIDE_CUT.</summary>
	private const double InnerAlong = 520.0;
	private const double InnerAcross = 180.0;
	private const double InnerCut = 0.75;
	private const double SideCut = 0.28;
	private const double MountainWarp = 0.35;
	private const double RidgeAlong = 220.0;
	private const double RidgeAcross = 125.0;
	private static readonly double[] DirC = { 1.0, 0.5, -0.5 };
	private static readonly double[] DirS = { 0.0, 0.8660254037844386, 0.8660254037844386 };
	private const double Asym = 1.8;
	private const double PeakCap = 1.05;
	private const double CrestRound = 0.12;
	/// <summary>Острые массивы, возвышенности и мягкий предел вершин (с 3.0): копия StageRelief.SHARP_SHIFT, UPLAND_SHIFT, UPLAND_AMP, UPLAND_SMOOTH, PEAK_KNEE, PEAK_SOFT.</summary>
	private const double SharpShift = 0.28;
	private const double UplandShift = 0.24;
	private const double UplandAmp = 0.3;
	private const double UplandSmooth = 0.8;
	private const double PeakKnee = 0.36;
	private const double PeakSoft = 0.25;

	/// <summary>Копия StageRelief.mountain.</summary>
	private static double Mountain(int[] ridge, int[] hill, double X, double Y)
	{
		double s = Fbm(ridge, X / Massif + 31.4, Y / Massif - 17.2, 2) * 3.0 + 1.5;
		s = s < 0.0 ? 0.0 : (s > 2.999 ? 2.999 : s);
		int k = (int)s;
		double t = Clamp01((s - k - 0.3) / 0.4);
		double f = t * t * (3.0 - 2.0 * t);
		t = Clamp01((Fbm(hill, X / Massif + 63.2, Y / Massif + 12.5, 2) + 0.25 - SharpShift) / 0.5);
		double sharp = t * t * (3.0 - 2.0 * t);
		t = Clamp01((Fbm(hill, X / Massif + 25.1, Y / Massif - 71.3, 2) + UplandShift) / 0.4);
		double up = t * t * (3.0 - 2.0 * t);
		// С 3.2 холмистый характер смягчает и форму склона, а не только высоту гребня.
		sharp *= 1.0 - up;
		double asym = 1.0 + (Asym - 1.0) * sharp;
		// С 3.1 мелкие детали сильнее у острых массивов; главный гребень шире и цельнее.
		double fine = (1.0 - UplandSmooth * up) * (0.35 + 0.65 * sharp);
		double r = 0.0;
		if (f < 1.0)
			r += Crest(ridge, X, Y, DirC[k], DirS[k], asym, fine, 1.0 - 0.55 * up) * (1.0 - f);
		if (f > 0.0)
			r += Crest(ridge, X, Y, DirC[Math.Min(k + 1, 2)], DirS[Math.Min(k + 1, 2)], asym, fine, 1.0 - 0.55 * up) * f;
		r = Math.Min(r * (1.0 + 0.35 * Fbm(hill, X / 85.0 + 17.7, Y / 85.0 - 29.3, 2) * r), PeakCap);
		double sp = Ridged(ridge, X / 70.0 - 57.1, Y / 70.0 + 11.9, 2);
		r = Math.Max(0.0, r + sp * sp * Math.Max(0.0, r * (1.0 - r)) * 0.55 * fine);
		// С 3.5 пологое плечо сглаженного массива, с плавным входом и выходом.
		t = Clamp01((r - 0.25) / 0.15);
		double shoulder = t * t * (3.0 - 2.0 * t);
		t = Clamp01((0.7 - r) / 0.15);
		r += (0.475 - r) * shoulder * t * t * (3.0 - 2.0 * t) * 0.45 * up;
		double q = Math.Sqrt(r) * r;
		t = Clamp01((Fbm(hill, X / Massif - 8.3, Y / Massif + 44.6, 2) - -0.3) / 0.6);
		double amp = 0.6 + 0.55 * t * t * (3.0 - 2.0 * t);
		double m = (q + (r * r - q) * sharp) * amp;
		m += (r * UplandAmp - m) * up;
		m = MassifBase * amp * (1.0 - (1.0 - UplandAmp) * up) + m * CrestShare;
		if (m > PeakKnee)
			m = PeakKnee + (m - PeakKnee) / (1.0 + (m - PeakKnee) / PeakSoft);
		return m;
	}

	/// <summary>Копия StageRelief._crest.</summary>
	private static double Crest(int[] pm, double X, double Y, double dc, double ds, double asym, double fine, double interior)
	{
		double along = X * dc + Y * ds;
		double across = Y * dc - X * ds;
		double u = along / RidgeAlong;
		double v = across / RidgeAcross;
		double a = 0.6, fq = 1.0, s = 0.0, wt = 1.0;
		for (int o = 0; o < 4; o++)
		{
			double n = Noise(pm, u * fq, v * fq);
			if (o == 0)
				n *= n > 0.0 ? asym : 1.0 / asym;
			double e = Math.Sqrt(n * n + CrestRound * CrestRound);
			double val = Math.Max(0.0, 1.0 - e);
			val *= val;
			val *= wt;
			wt = Math.Min(1.0, Math.Max(0.0, val * 2.0));
			s += val * a * (o >= 2 ? fine : 1.0);
			fq *= 2.1;
			a = o == 0 ? 0.25 : a * 0.3;
		}
		if (interior > 0.0)
		{
			// Продольная долина, широкие котловины и впадающие сбоку ложбины.
			double course = Noise(pm, along / InnerAlong + 18.7, across / InnerAcross - 37.1);
			double side = Noise(pm, along / 180.0 - 51.3, across / 320.0 + 24.8);
			double t = Clamp01((side + 0.2) / 0.6);
			double opening = t * t * (3.0 - 2.0 * t);
			t = Clamp01(1.0 - Math.Abs(course) / ((0.24 + 0.32 * opening) * (1.4 - 0.7 * interior)));
			double valley = t * t * (3.0 - 2.0 * t);
			s -= Math.Max(0.0, s - (0.18 + 0.16 * opening)) * valley * InnerCut * interior;
			t = Clamp01(1.0 - Math.Abs(side) / 0.2);
			double branch = t * t * (3.0 - 2.0 * t);
			t = Clamp01(1.0 - Math.Abs(course) / 0.65);
			s *= 1.0 - branch * t * t * (3.0 - 2.0 * t) * (1.0 - valley) * SideCut * interior;
		}
		return s;
	}

	// Двоичная куча (min-heap): та же, что MinHeap.push и развёрнутое извлечение в GDScript
	private static void Push(int[] ids, double[] keys, ref int hn, int id, double key)
	{
		int i = hn++;
		while (i > 0)
		{
			int p = (i - 1) >> 1;
			if (keys[p] <= key)
				break;
			ids[i] = ids[p];
			keys[i] = keys[p];
			i = p;
		}
		ids[i] = id;
		keys[i] = key;
	}

	private static int Pop(int[] ids, double[] keys, ref int hn)
	{
		int top = ids[0];
		hn--;
		if (hn > 0)
		{
			int id = ids[hn];
			double kk = keys[hn];
			int i = 0;
			while (true)
			{
				int l = 2 * i + 1;
				if (l >= hn)
					break;
				int r = l + 1;
				if (r < hn && keys[r] < keys[l])
					l = r;
				if (keys[l] >= kk)
					break;
				ids[i] = ids[l];
				keys[i] = keys[l];
				i = l;
			}
			ids[i] = id;
			keys[i] = kk;
		}
		return top;
	}
}
