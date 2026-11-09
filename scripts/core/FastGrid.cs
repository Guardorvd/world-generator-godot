using System;
using Godot;

/// <summary>
/// Самые долгие циклы генерации на C#: поиск пути A* (Pathfinder, FastGrid.Path.cs), заполнение впадин (StageHydrology),
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
			int selected = -1;
			double u = 0.0, distance = 0.0, side = 0.0;
			RoadNearest(points[i], width, height, tile, reach, anchors, deltas, lengths, halves, roads, starts, candidates,
				ref selected, ref u, ref distance, ref side);
			int at = i * 4;
			result[at] = selected;
			result[at + 1] = u;
			result[at + 2] = distance;
			result[at + 3] = side;
		}
		return result;
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

	/// <summary>Grid.path_clearance (15.0): расстояние (м) от центра клетки до кромки полотна ближайшего пути минус запас его вида,
	/// не больше cap; считается только в полосе у линий. Те же операции в double, хранение во float.</summary>
	public float[] PathClearance(int w, int h, int[] starts, double[] px, double[] py, double[] pw, double[] margin, double tile, double cap)
	{
		var outv = new float[w * h];
		System.Array.Fill(outv, (float)cap);
		for (int r = 0; r < margin.Length; r++)
		{
			for (int n = starts[r] + 1; n < starts[r + 1]; n++)
			{
				double ax = px[n - 1], ay = py[n - 1], dx = px[n] - ax, dy = py[n] - ay;
				double l2 = dx * dx + dy * dy;
				double wa = pw[n - 1] * tile * 0.5, wb = pw[n] * tile * 0.5;
				// A fixed envelope also covers the averaged width of RoadRefinement segments.
				// Interpolating width at the axis projection is not a 1-Lipschitz distance:
				// clearance_at could then overestimate the safe gap on tapered segments.
				double half = Math.Max(wa, wb);
				double reach = (Math.Max(wa, wb) + margin[r] + cap) / tile;
				int y0 = Math.Max(0, (int)Math.Floor(Math.Min(ay, ay + dy) - reach)), y1 = Math.Min(h, (int)Math.Floor(Math.Max(ay, ay + dy) + reach) + 1);
				int x0 = Math.Max(0, (int)Math.Floor(Math.Min(ax, ax + dx) - reach)), x1 = Math.Min(w, (int)Math.Floor(Math.Max(ax, ax + dx) + reach) + 1);
				for (int y = y0; y < y1; y++)
				{
					for (int x = x0; x < x1; x++)
					{
						double t = l2 == 0.0 ? 0.0 : Math.Clamp(((x + 0.5 - ax) * dx + (y + 0.5 - ay) * dy) / l2, 0.0, 1.0);
						double ox = x + 0.5 - ax - dx * t, oy = y + 0.5 - ay - dy * t;
						double value = Math.Sqrt(ox * ox + oy * oy) * tile - half - margin[r];
						int i = y * w + x;
						if (value < outv[i]) outv[i] = (float)value;
					}
				}
			}
		}
		return outv;
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
