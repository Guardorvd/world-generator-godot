using System;
using Godot;

/// <summary>
/// Самые долгие циклы генерации на C#: поиск пути A* (Pathfinder), заполнение впадин (StageHydrology),
/// шум макрорельефа (StageRelief) и поля шума (Parallel.fbm_field).
/// Алгоритмы те же, что в GDScript, и дают тот же результат бит в бит, но в десятки раз быстрее.
/// Работает только в сборке Godot .NET, иначе генерация идёт на GDScript (см. Grid.fast_grid).
/// Арифметика повторяет GDScript: расчёт в double, значения в массивах float — во float.
/// </summary>
public partial class FastGrid : RefCounted
{
	private static readonly int[] Dx = { 1, -1, 0, 0, 1, 1, -1, -1 };
	private static readonly int[] Dy = { 0, 0, 1, -1, 1, -1, 1, -1 };
	private static readonly double[] Dl = { 1.0, 1.0, 1.0, 1.0, 1.4142135623730951, 1.4142135623730951, 1.4142135623730951, 1.4142135623730951 };

	private int _w;
	private int _h;
	private float[] _g = Array.Empty<float>();
	private int[] _from = Array.Empty<int>();
	private int[] _seen = Array.Empty<int>();
	private int[] _done = Array.Empty<int>();
	private int[] _heapIds = new int[1 << 16];
	private double[] _heapKeys = new double[1 << 16];
	private int _gen;

	/// <summary>Размер карты для FindPath.</summary>
	public void Setup(int w, int h)
	{
		_w = w;
		_h = h;
		_g = new float[w * h];
		_from = new int[w * h];
		_seen = new int[w * h];
		_done = new int[w * h];
		_gen = 0;
	}

	/// <summary>Путь от клетки s до клетки t по стоимости cost или пустой массив. Копия Pathfinder.find_path.</summary>
	public int[] FindPath(float[] cost, int s, int t)
	{
		int W = _w, H = _h, W1 = W - 1, H1 = H - 1;
		var off = new int[8];
		for (int k = 0; k < 8; k++)
			off[k] = Dy[k] * W + Dx[k];
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
			done[c] = gn;
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
				double ng = gc + Dl[k] * (cc + cn) * 0.5;
				if (seen[n] != gn || ng < g[n])
				{
					seen[n] = gn;
					g[n] = (float)ng;
					from[n] = c;
					int ax = Math.Abs(nx - tx), ay = Math.Abs(ny - ty);
					double key = ng + (Math.Max(ax, ay) + 0.414 * Math.Min(ax, ay)) * 0.6;
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
	/// Заполнение впадин (priority flood) от океана. Копия цикла из StageHydrology.run.
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
			if (ocean[i] != 0)
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
		var r = new double[W * H];
		System.Threading.Tasks.Parallel.For(0, H, y =>
		{
			for (int x = 0; x < W; x++)
				r[y * W + x] = Fbm(perm, x / d + ox, y / d + oy, oct);
		});
		return r;
	}

	/// <summary>
	/// Макрорельеф до уровня моря: копия цикла StageRelief._rows. Шумы — perm в порядке
	/// warpX, warpY, cont, mask, ridge, hill.
	/// </summary>
	public float[] ReliefField(int[] warpX, int[] warpY, int[] cont, int[] mask, int[] ridge, int[] hill, int W, int H)
	{
		var outH = new float[W * H];
		System.Threading.Tasks.Parallel.For(0, H, y =>
		{
			for (int x = 0; x < W; x++)
			{
				double wx = Fbm(warpX, x / 170.0, y / 170.0, 3) * 45.0;
				double wy = Fbm(warpY, x / 170.0 + 13.1, y / 170.0 - 7.7, 3) * 45.0;
				double X = x + wx;
				double Y = y + wy;
				double c = Fbm(cont, X / 240.0, Y / 240.0, 6);
				double dx = Math.Abs(((double)x / (W - 1)) * 2.0 - 1.0);
				double dy = Math.Abs(((double)y / (H - 1)) * 2.0 - 1.0);
				double d = Math.Sqrt(Math.Sqrt(dx * dx * dx * dx + dy * dy * dy * dy));
				double t = Clamp01((d - 0.55) / (1.0 - 0.55));
				double fall = t * t * (3.0 - 2.0 * t);
				double bas = c + 0.1 - fall * 0.75;
				t = Clamp01((bas - -0.05) / (0.25 - -0.05));
				double land = t * t * (3.0 - 2.0 * t);
				t = Clamp01((Fbm(mask, X / 280.0 + 7.0, Y / 280.0 - 3.0, 3) - -0.15) / (0.3 - -0.15));
				double m = t * t * (3.0 - 2.0 * t);
				double r = Ridged(ridge, X / 120.0, Y / 120.0, 5);
				double hills = Fbm(hill, X / 40.0, Y / 40.0, 4);
				outH[y * W + x] = (float)(bas * 0.55 + r * r * m * land * 0.9 + hills * 0.05 * (0.3 + land));
			}
		});
		return outH;
	}

	// Куча как MinHeap.push / MinHeap.pop
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
