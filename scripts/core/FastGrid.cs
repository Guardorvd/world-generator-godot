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
	private const double InlandDetail = 0.35;
	private const double SlopeRoll = 0.015; // StageRelief.SLOPE_ROLL
	private const double HeightPerWidth = 0.7;
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
				double cx = X / 240.0, cy = Y / 240.0, low = 0.0, high = 0.0, amp = 1.0, fr = 1.0, norm = 0.0;
				for (int o = 0; o < 6; o++)
				{
					if (o < 2)
						low += amp * Noise(cont, cx * fr, cy * fr);
					else
						high += amp * Noise(cont, cx * fr, cy * fr);
					norm += amp;
					amp *= 0.5;
					fr *= 2.0;
				}
				double detail = 1.0 - 0.85 * core;
				double c = (low + high * detail) / norm;
				double fineC = high * detail / norm;
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
				// С GEO 7 мелкие октавы основания вглубь суши слабее; берег прежний.
				double h = (bas - fineC * (1.0 - InlandDetail) * inland) * 0.55;
				if (h > SeaRaw)
					h = SeaRaw + (h - SeaRaw) * (PlainLift + (1.0 - PlainLift) * rough);
				double hills = 0.0, slopeRoll = 0.0;
				amp = 1.0; fr = 1.0; norm = 0.0;
				for (int o = 0; o < 4; o++)
				{
					hills += amp * Noise(hill, X / 40.0 * fr, Y / 40.0 * fr);
					norm += amp;
					if (o == 1) slopeRoll = hills / norm;
					amp *= 0.5; fr *= 2.0;
				}
				hills /= norm;
				if (foothills > 0.0)
				{
					double footScale = 100.0 * Math.Max(mountainScale, mountainHeight / HeightPerWidth);
					double rolling = Fbm(hill, X / footScale + 32.4, Y / footScale - 18.6, 2);
					hills += (rolling - hills) * foothills;
					h += foothills * (FoothillLift + 0.08 * rolling) * mountainHeight;
				}
				h += hills * HillAmp * (0.3 + land) * (PlainHills + (1.0 - PlainHills) * rough) * (1.0 - m * 0.85);
				double calm = (1.0 - rough) * (1.0 - m) * (1.0 - m) * (1.0 - foothills);
			 double shoreT = Clamp01(((h - SeaRaw) - 0.015) / (0.08 - 0.015));
			 double shoreFade = shoreT * shoreT * (3.0 - 2.0 * shoreT);
			 h += (hills * 0.025 - valley * 0.008) * calm * shoreFade;
			 h -= valley * ValleyDepth * rough * inland;
				if (m > 0.0)
				{
					double wide = mountainScale * Math.Max(1.0, mountainHeight / (mountainScale * HeightPerWidth));
					h += Mountain(ridge, hill, (x + wx * MountainWarp) / wide, (y + wy * MountainWarp) / wide, inland) * m * MountainAmp * mountainHeight;
				}
				double rollT = Clamp01(((h - SeaRaw) - 0.015) / (0.08 - 0.015));
				double rollFade = rollT * rollT * (3.0 - 2.0 * rollT);
				h += slopeRoll * SlopeRoll * m * (1.0 - 0.7 * valley) * rollFade;
				outH[j * W + i] = (float)h;
			}
		}
		RunRows(H, parallel, Row);
		return outH;
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
	private const double FlankFold = 0.07; // StageRelief.FLANK_FOLD
	private const double MountainWarp = 0.35;
	private const double RidgeAlong = 220.0;
	private const double RidgeAcross = 125.0;
	private static readonly double[] DirC = { 1.0, 0.5, -0.5 };
	private static readonly double[] DirS = { 0.0, 0.8660254037844386, 0.8660254037844386 };
	private const double Asym = 1.8;
	private const double PeakCap = 1.05;
	private const double CrestRound = 0.2;
	/// <summary>Острые массивы, возвышенности и мягкий предел вершин (с 3.0): копия StageRelief.SHARP_SHIFT, UPLAND_SHIFT, UPLAND_AMP, UPLAND_SMOOTH, PEAK_KNEE, PEAK_SOFT.</summary>
	private const double SharpShift = 0.28;
	private const double UplandShift = 0.24;
	private const double UplandAmp = 0.3;
	private const double UplandSmooth = 0.8;
	private const double PeakKnee = 0.36;
	private const double PeakSoft = 0.25;

	/// <summary>Копия StageRelief.mountain.</summary>
	private static double Mountain(int[] ridge, int[] hill, double X, double Y, double inland)
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
			r += Crest(ridge, X, Y, DirC[k], DirS[k], asym, fine, 1.0 - 0.55 * up, inland) * (1.0 - f);
		if (f > 0.0)
			r += Crest(ridge, X, Y, DirC[Math.Min(k + 1, 2)], DirS[Math.Min(k + 1, 2)], asym, fine, 1.0 - 0.55 * up, inland) * f;
		double pk = Fbm(hill, X / 85.0 + 17.7, Y / 85.0 - 29.3, 2);
		r = Math.Min(r * (1.0 + 0.35 * pk * r), PeakCap);
		// С 3.5 пологое плечо сглаженного массива; с GEO 6 и у гор, слабее, с высотой вдоль хребта.
		t = Clamp01((r - 0.25) / 0.15);
		double shoulder = t * t * (3.0 - 2.0 * t);
		t = Clamp01((0.7 - r) / 0.15);
		r += (0.475 + 0.08 * pk * (1.0 - up) - r) * shoulder * t * t * (3.0 - 2.0 * t) * (0.45 * up + 0.2 * (1.0 - up));
		double q = Math.Sqrt(r) * r;
		t = Clamp01((Fbm(hill, X / Massif - 8.3, Y / Massif + 44.6, 2) - -0.3) / 0.6);
		double amp = 0.6 + 0.55 * t * t * (3.0 - 2.0 * t);
		double m = (q + (r * r - q) * sharp) * amp;
		m += (r * UplandAmp - m) * up;
		double foundationT = Clamp01((r - 0.12) / (0.65 - 0.12));
		double foundation = 1.0 - 0.2 * inland * (1.0 - up) * (1.0 - foundationT * foundationT * (3.0 - 2.0 * foundationT));
		m = MassifBase * amp * (1.0 - (1.0 - UplandAmp) * up) * foundation + m * CrestShare;
		if (m > PeakKnee)
			m = PeakKnee + (m - PeakKnee) / (1.0 + (m - PeakKnee) / PeakSoft);
		return m;
	}

	/// <summary>Копия StageRelief._crest.</summary>
	private static double Crest(int[] pm, double X, double Y, double dc, double ds, double asym, double fine, double interior, double inland)
	{
		double along = X * dc + Y * ds;
		double across = Y * dc - X * ds;
		double u = along / RidgeAlong;
		double v = across / RidgeAcross;
		double a = 0.6, fq = 1.0, s = 0.0, wt = 1.0, fold = 0.0;
		for (int o = 0; o < 4; o++)
		{
			double n = Noise(pm, u * fq, v * fq);
			if (o == 0)
				n *= n > 0.0 ? asym : 1.0 / asym;
			double e = Math.Sqrt(n * n + CrestRound * CrestRound);
			double val = Math.Max(0.0, 1.0 - e);
			val *= val;
			// The same small oriented octaves, before recursive crest attenuation.
			if (o >= 2) fold += (val - 0.35) * (o == 2 ? 1.0 : 0.3);
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
			double flankIn = Clamp01((s - 0.12) / (0.30 - 0.12));
			double flankOut = Clamp01((s - 0.55) / (0.75 - 0.55));
			double flank = flankIn * flankIn * (3.0 - 2.0 * flankIn) * (1.0 - flankOut * flankOut * (3.0 - 2.0 * flankOut));
			s += fold * FlankFold * flank * interior * inland * (1.0 - 0.85 * valley);
			double shelfLevel = 0.36 + 0.12 * opening;
			double shelfIn = Clamp01((s - (shelfLevel - 0.12)) / (shelfLevel - (shelfLevel - 0.12)));
			double shelfOut = Clamp01((s - shelfLevel) / ((shelfLevel + 0.12) - shelfLevel));
			double shelf = shelfIn * shelfIn * (3.0 - 2.0 * shelfIn) * (1.0 - shelfOut * shelfOut * (3.0 - 2.0 * shelfOut));
			s += (shelfLevel - s) * shelf * 0.35 * fine * interior * (1.0 - 0.8 * valley);
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
