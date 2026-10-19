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
	/// <summary>Множитель оценки остатка пути A* (как Pathfinder.H_COST).</summary>
	private const double HCost = 0.6;
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
	private readonly int[] _off = new int[8];

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
		_gen = 0;
	}

	/// <summary>Путь от клетки s до клетки t по стоимости cost или пустой массив. Копия Pathfinder.find_path.</summary>
	public int[] FindPath(float[] cost, int s, int t)
	{
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
				double step = (cc + cn) * 0.5;
				if (k >= 4)
				{
					double ca = cost[c + Dx[k]], cb = cost[c + Dy[k] * W];
					if (double.IsPositiveInfinity(ca) || double.IsPositiveInfinity(cb))
						continue;
					step = Math.Max(step, (ca + cb) * 0.5);
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
		return FbmRect(perm, 0, 0, W, H, d, oct, ox, oy);
	}

	/// <summary>То же поле по прямоугольнику клеток W × H с углом (x0, y0), в том числе за картой (OuterLand).</summary>
	public double[] FbmRect(int[] perm, int x0, int y0, int W, int H, double d, int oct, double ox, double oy)
	{
		var r = new double[W * H];
		System.Threading.Tasks.Parallel.For(0, H, j =>
		{
			int y = y0 + j;
			for (int i = 0; i < W; i++)
				r[j * W + i] = Fbm(perm, (x0 + i) / d + ox, y / d + oy, oct);
		});
		return r;
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
	public float[] ReliefField(int[] warpX, int[] warpY, int[] cont, int[] mask, int[] ridge, int[] hill, double mx, double my, int x0, int y0, int W, int H, double mountainScale, double mountainBias, double mountainHeight, double foothillSpread)
	{
		var outH = new float[W * H];
		System.Threading.Tasks.Parallel.For(0, H, j =>
		{
			int y = y0 + j;
			for (int i = 0; i < W; i++)
			{
				int x = x0 + i;
				double wx = Fbm(warpX, x / 170.0, y / 170.0, 3) * 45.0;
				double wy = Fbm(warpY, x / 170.0 + 13.1, y / 170.0 - 7.7, 3) * 45.0;
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
				double m = core * land;
				t = Clamp01((Fbm(hill, X / Character + 41.9, Y / Character - 66.1, 2) - -0.15) / 0.4);
				double rough = t * t * (3.0 - 2.0 * t);
				t = Clamp01((bas - 0.18) / 0.17);
				double inland = t * t * (3.0 - 2.0 * t);
				t = Clamp01(1.0 - Math.Abs(Noise(ridge, X / Valley + 5.3, Y / Valley - 9.4)) / ValleyWidth);
				double valley = t * t * (3.0 - 2.0 * t);
				double width = 0.1 + 0.4 * foothillSpread * (0.6 + 0.4 * rough);
				t = Clamp01((mountainField + width) / (MaskEdge * 0.65 + width));
				double foothills = t * t * (3.0 - 2.0 * t) * (1.0 - core) * land * inland * foothillSpread * (0.5 + 0.5 * rough) * (1.0 - 0.5 * valley);
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
		});
		return outH;
	}

	/// <summary>Копия StageRelief._continental: прежние шесть октав, без усиления крупных форм.</summary>
	private static double Continental(int[] pm, double x, double y, double detail)
	{
		double a = 1.0, f = 1.0, s = 0.0, n = 0.0;
		for (int o = 0; o < 6; o++)
		{
			s += a * Noise(pm, x * f, y * f) * (o >= 3 ? detail : 1.0);
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
