using System;

// Native numerical copy of StageRelief and mountain_detail.gd. Keep float32 output parity.
public partial class FastGrid
{
	/// <summary>Масштаб и вклад шума материков: копия StageRelief.MACRO, MACRO_AMP, MACRO_LIFT.</summary>
	private const double Macro = 1400.0;
	private const double MacroAmp = 1.2;
	private const double MacroLift = 0.30; // 0.25 до 14.11.2026 (GEO 19)
	/// <summary>Сдвиг шума материков вверх (больше суши): копия StageRelief.LAND_BIAS.</summary>
	private const double LandBias = 0.18;

	/// <summary>Негорный рельеф: копия StageRelief.SEA_RAW, CHARACTER, PLAIN_LIFT, PLAIN_HILLS, HILL_AMP, FOOTHILLS, MASK_EDGE, VALLEY, VALLEY_WIDTH, VALLEY_DEPTH.</summary>
	private const double SeaRaw = 0.067;
	private const double Character = 520.0;
	private const double PlainLift = 0.3;
	private const double PlainHills = 0.15;
	private const double HillAmp = 0.07;
	private const double InlandDetail = 0.35;
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
	public float[] ReliefField(int[] warpX, int[] warpY, int[] cont, int[] mask, int[] ridge, int[] hill, double mx, double my, int x0, int y0, int W, int H, double mountainScale, double mountainBias, double mountainHeight, double foothillSpread, bool parallel, bool detail, double heightScale, double tile)
	{
		if (W <= 0 || H <= 0) return Array.Empty<float>();
		if (!detail)
			return BaseField(warpX, warpY, cont, mask, ridge, hill, mx, my, x0, y0, W, H, mountainScale, mountainBias, mountainHeight, foothillSpread, parallel);
		// Слой детализации гор (GEO 9): основа с полосой DetailPad, затем склоны по соседям.
		const int P = DetailPad;
		int bw = W + 2 * P;
		var b = BaseField(warpX, warpY, cont, mask, ridge, hill, mx, my, x0 - P, y0 - P, bw, H + 2 * P, mountainScale, mountainBias, mountainHeight, foothillSpread, parallel);
		var outH = new float[W * H];
		void Row(int j)
		{
			for (int i = 0; i < W; i++)
				outH[j * W + i] = (float)Detail(ridge, hill, b, bw, (j + P) * bw + i + P, x0 + i, y0 + j, heightScale, tile);
		}
		RunRows(H, parallel, Row);
		return outH;
	}

	/// <summary>Копия mountain_detail.gd; единицы мира передаются из GameConfig.</summary>
	private const int DetailPad = 2;
	private const double DetailLow = 30.0;
	private const double DetailHigh = 60.0;
	private const double DetailRibBroad = 40.0;
	private const double DetailRib = 22.0;
	private const double DetailRibFine = 9.0;
	private const double DetailLong = 3.5;
	private const double DetailDepth = 26.0;
	private const double DetailWall = 12.0;
	private const double DetailLimit = 0.8;
	private const double DetailSteepFrom = 0.65;
	private const double DetailCross = 0.08;
	private const double TopRaw = 1.05; // StageRelief.TOP_RAW

	/// <summary>Копия mountain_detail.gd.apply; base b is read-only.</summary>
	private static double Detail(int[] ridge, int[] hill, float[] b, int bw, int k, double x, double y, double heightScale, double tile)
	{
		double v = b[k];
		double q = (v - SeaRaw) / (TopRaw - SeaRaw);
		if (q <= 0.0)
			return v;
		double r4 = Math.Sqrt(Math.Sqrt(q));
		double elev = q * r4 * heightScale;
		double t = Clamp01((elev - DetailLow) / (DetailHigh - DetailLow));
		if (t <= 0.0)
			return v;
		double lift = t * t * (3.0 - 2.0 * t);
		double perRaw = 1.25 * r4 / (TopRaw - SeaRaw) * heightScale;
		int r = 2 * bw;
		double gx = (((double)b[k + 2 - r] + 2.0 * b[k + 2] + b[k + 2 + r]) - ((double)b[k - 2 - r] + 2.0 * b[k - 2] + b[k - 2 + r])) * perRaw / (16.0 * tile);
		double gy = (((double)b[k - 2 + r] + 2.0 * b[k + r] + b[k + 2 + r]) - ((double)b[k - 2 - r] + 2.0 * b[k - r] + b[k + 2 - r])) * perRaw / (16.0 * tile);
		double g2 = gx * gx + gy * gy;
		if (g2 < 0.0016)
			return v;
		double s = Math.Sqrt(g2);
		if (s >= DetailLimit)
			return v;
		double bend = (((double)b[k + 2] + b[k - 2]) + ((double)b[k + r] + b[k - r]) - 4.0 * b[k]) * perRaw;
		t = Clamp01((-bend - 0.6) / (2.0 - 0.6));
		double crest = 1.0 - 0.65 * t * t * (3.0 - 2.0 * t);
		t = Clamp01((Noise(hill, x / 170.0 + 211.7, y / 170.0 - 93.1) + 0.5) / 1.0);
		double vary = t * t * (3.0 - 2.0 * t);
		t = Clamp01((Noise(hill, x / 95.0 - 57.3, y / 95.0 + 138.9) + 0.5) / 1.0);
		double patch = t * t * (3.0 - 2.0 * t);
		t = Clamp01((s - 0.04) / (0.12 - 0.04));
		double gentle = t * t * (3.0 - 2.0 * t);
		double c2 = (gx * gx - gy * gy) / g2;
		double s2 = 2.0 * gx * gy / g2;
		t = Clamp01((s - 0.25) / (0.45 - 0.25));
		double narrow = t * t * (3.0 - 2.0 * t);
		t = Clamp01((s - 0.4) / (0.6 - 0.4));
		double fine = (0.1 + 0.3 * patch) * (t * t * (3.0 - 2.0 * t));
		double cross = DetailCross * tile / ((1.0 - narrow) / DetailRibBroad + narrow / DetailRib + fine / DetailRibFine);
		t = Clamp01((s - DetailSteepFrom) / (DetailLimit - DetailSteepFrom));
		double steepFade = 1.0 - t * t * (3.0 - 2.0 * t);
		double depth = Math.Min(Math.Min(DetailDepth * s * (0.4 + 0.8 * vary), Math.Sqrt(Math.Max(0.0, DetailLimit * DetailLimit - s * s)) * DetailWall), cross) * lift * gentle * crest * steepFade;
		double f = 0.0;
		if (narrow < 1.0)
			f += Ribs(ridge, x, y, DetailRibBroad, c2, s2, 37.9) * (1.0 - narrow);
		if (narrow > 0.0)
			f += Ribs(ridge, x, y, DetailRib, c2, s2, 0.0) * narrow;
		if (fine > 0.0)
			f += Ribs(ridge, x, y, DetailRibFine, c2, s2, 71.3) * fine;
		return v + depth * f / perRaw;
	}

	/// <summary>Копия mountain_detail.gd._ribs.</summary>
	private static double Ribs(int[] ridge, double x, double y, double L, double c2, double s2, double o)
	{
		double la = L * DetailLong;
		double n = 0.0, ww = 0.0, a = 0.0;
		if (c2 > 0.0)
		{
			a = c2 * c2;
			n += a * Noise(ridge, x / la + 13.7 + o, y / L - 41.2);
		}
		else if (c2 < 0.0)
		{
			a = c2 * c2;
			n += a * Noise(ridge, y / la - 27.9 + o, x / L + 8.6);
		}
		ww += a * a;
		a = 0.0;
		double d1 = (x + y) * 0.7071067811865476;
		double d2 = (y - x) * 0.7071067811865476;
		if (s2 > 0.0)
		{
			a = s2 * s2;
			n += a * Noise(ridge, d1 / la + 55.1 + o, d2 / L - 19.4);
		}
		else if (s2 < 0.0)
		{
			a = s2 * s2;
			n += a * Noise(ridge, d2 / la - 64.8 + o, d1 / L + 33.3);
		}
		ww += a * a;
		n /= Math.Sqrt(ww);
		double d = Math.Min(Math.Sqrt(n * n + 0.02), 1.0);
		return 0.5 - (1.0 - d) * (1.0 - d);
	}

	/// <summary>Макрорельеф GEO 7 без слоя детализации (копия StageRelief._base_rows).</summary>
	private float[] BaseField(int[] warpX, int[] warpY, int[] cont, int[] mask, int[] ridge, int[] hill, double mx, double my, int x0, int y0, int W, int H, double mountainScale, double mountainBias, double mountainHeight, double foothillSpread, bool parallel)
	{
		var outH = new float[W * H];
		// World parameters are constant for the whole request, not per cell.
		double footScale = 100.0 * Math.Max(mountainScale, mountainHeight / HeightPerWidth);
		double wide = mountainScale * Math.Max(1.0, mountainHeight / (mountainScale * HeightPerWidth));
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
				double hills = Fbm(hill, X / 40.0, Y / 40.0, 4);
				if (foothills > 0.0)
				{
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
					double relief = Mountain(ridge, hill, (x + wx * MountainWarp) / wide, (y + wy * MountainWarp) / wide, inland);
					double support = ReliefSmooth(0.12, 0.55, relief);
					h -= Math.Max(0.0, h - SeaRaw) * 0.60 * core * inland * (1.0 - support);
					h += relief * m * MountainAmp * mountainHeight;
				}
				outH[j * W + i] = (float)h;
			}
		}
		RunRows(H, parallel, Row);
		return outH;
	}


	/// <summary>Горы: копия StageRelief.MASSIF, MOUNTAIN_AMP, MOUNTAIN_WARP, DIR_C, DIR_S, ASYM, PEAK_CAP.</summary>
	private const double Massif = 650.0;
	private const double MountainAmp = 1.0;
	/// <summary>Общее основание и доля гребней (с 3.3): копия StageRelief.MASSIF_BASE, CREST_SHARE.</summary>
	private const double MassifBase = 0.15;
	private const double CrestShare = 1.10;
	private const double MountainWarp = 0.35;
	private static readonly double[] DirC = { 1.0, 0.5, -0.5 };
	private static readonly double[] DirS = { 0.0, 0.8660254037844386, 0.8660254037844386 };
	private const double Asym = 1.8;
	private const double PeakCap = 1.05;
	/// <summary>Острые массивы, возвышенности и мягкий предел вершин (с 3.0): копия StageRelief.SHARP_SHIFT, UPLAND_SHIFT, UPLAND_AMP, UPLAND_SMOOTH, PEAK_KNEE, PEAK_SOFT.</summary>
	private const double SharpShift = 0.28;
	private const double UplandShift = 0.24;
	private const double UplandAmp = 0.3;
	private const double UplandSmooth = 0.8;
	private const double PeakKnee = 0.50;
	private const double PeakSoft = 0.40;

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
		double structure = inland * (1.0 - 0.62 * up);
		double asym = 1.0 + (Asym - 1.0) * sharp + 0.22 * structure;
		// С 3.1 мелкие детали сильнее у острых массивов; главный гребень шире и цельнее.
		double fine = (1.0 - UplandSmooth * up) * (0.35 + 0.65 * sharp);
		double r = 0.0;
		double lastCrest = k == 2 ? Crest(ridge, X, Y, DirC[2], DirS[2], asym, fine, 1.0 - 0.55 * up, structure) : 0.0;
		if (f < 1.0)
			r += (k == 2 ? lastCrest : Crest(ridge, X, Y, DirC[k], DirS[k], asym, fine, 1.0 - 0.55 * up, structure)) * (1.0 - f);
		if (f > 0.0)
			r += (k == 2 ? lastCrest : Crest(ridge, X, Y, DirC[Math.Min(k + 1, 2)], DirS[Math.Min(k + 1, 2)], asym, fine, 1.0 - 0.55 * up, structure)) * f;
		double pk = Fbm(hill, X / 150.0 + 17.7, Y / 150.0 - 29.3, 2);
		r = Math.Min(r * (1.0 + (0.35 + 0.70 * structure) * pk * r), PeakCap);
		double q = Math.Sqrt(r) * r;
		t = Clamp01((Fbm(hill, X / Massif - 8.3, Y / Massif + 44.6, 2) - -0.3) / 0.6);
		double amp = 0.6 + 0.55 * t * t * (3.0 - 2.0 * t);
		double m = (q + (r * r - q) * sharp) * amp;
		m += (r * UplandAmp - m) * up;
		double foundationT = Clamp01((r - 0.12) / (0.65 - 0.12));
		double foundation = 1.0 - 0.45 * inland * (1.0 - up) * (1.0 - foundationT * foundationT * (3.0 - 2.0 * foundationT));
		m = MassifBase * amp * (1.0 - (1.0 - UplandAmp) * up) * foundation + m * CrestShare;
		if (m > PeakKnee)
			m = PeakKnee + (m - PeakKnee) / (1.0 + (m - PeakKnee) / PeakSoft);
		return m;
	}

	/// <summary>StageRelief._crest and its world-addressed skeleton helpers.</summary>
	private static double Crest(int[] pm, double X, double Y, double dc, double ds, double asym, double fine, double interior, double structure)
	{
		double along = X * dc + Y * ds;
		double across = Y * dc - X * ds;
		int band = (int)Math.Floor(across / 260.0);
		int knot = (int)Math.Floor(along / 130.0);
		double height = 0.0;
		for (int row = band - 2; row < band + 3; row++)
		{
			if (Math.Abs(across - row * 260.0) > 480.0) continue;
			double center = Divide(pm, row, along);
			double offset = across - center;
			double width = 52.0 + 28.0 * (1.0 - interior);
			double d = offset * (offset > 0.0 ? asym : 1.0 / asym) / width;
			double peak = DivideHeight(pm, row, along);
			double crown = Math.Max(0.0, 1.0 - d * d / 9.0);
			double local = peak * crown * crown * crown * crown;
			for (int column = knot - 2; column < knot + 3; column++)
			{
				for (int side = -1; side <= 1; side += 2)
				{
					int salt = side < 0 ? 17 : 83;
					double root = (column + 0.15 + 0.7 * RidgeNode(pm, column, row, salt)) * 130.0;
					double rootAcross = Divide(pm, row, root);
					double dx = (RidgeNode(pm, column, row, salt + 1) - 0.5) * 240.0;
					double dy = side * (125.0 + 105.0 * RidgeNode(pm, column, row, salt + 2));
					double px = along - root, py = across - rootAcross;
					double t = Clamp01((px * dx + py * dy) / (dx * dx + dy * dy));
					double bow = 4.0 * t * (1.0 - t) * (RidgeNode(pm, column, row, salt + 4) - 0.5) * 55.0;
					double length = Math.Sqrt(dx * dx + dy * dy);
					double ex = px - dx * t + dy / length * bow, ey = py - dy * t - dx / length * bow;
					double ribWidth = 22.0 + 23.0 * RidgeNode(pm, column, row, salt + 3) + 12.0 * (1.0 - interior);
					double face = 1.0 + 0.65 * fine * structure * ReliefSmooth(-0.2, 0.25, (ex * -dy + ey * dx) / (length * ribWidth));
					double profile = Math.Max(0.0, 1.0 - (ex * ex + ey * ey) * face / (3.0 * ribWidth * ribWidth));
					double competence = ReliefSmooth(0.30, 0.85, RidgeNode(pm, column, row, salt + 5));
					double rockFace = competence * structure * (0.35 + 0.65 * fine) * ReliefSmooth(0.10, 0.30, t) * (1.0 - ReliefSmooth(0.72, 0.95, t));
					double lip = 0.28 + 0.24 * t;
					double worn = profile * profile;
					double bedrock = 0.38 * worn + 0.62 * ReliefSmooth(lip - 0.14, lip + 0.14, profile);
					double rib = DivideHeight(pm, row, root) * (1.0 - 0.88 * t) * (worn + (bedrock - worn) * rockFace);
					local = RidgeJoin(local, rib, 0.045);
				}
			}
			double shoulder = ReliefSmooth(0.12, 0.32, local) * (1.0 - ReliefSmooth(0.32, 0.55, local));
			local += (0.31 - local) * shoulder * (0.15 + 0.35 * fine) * structure;
			height = RidgeJoin(height, local, 0.035);
		}
		return height;
	}

	private static double RidgeNode(int[] pm, int x, int y, int salt) => pm[(x + pm[(y + salt) & 255]) & 255] / 255.0;

	private static double Divide(int[] pm, int row, double along)
	{
		double u = along / 280.0;
		int k = (int)Math.Floor(u);
		double t = u - k;
		t = t * t * (3.0 - 2.0 * t);
		double a = RidgeNode(pm, k, row, 131), b = RidgeNode(pm, k + 1, row, 131);
		return row * 260.0 + (a + (b - a) * t) * 190.0 - 95.0;
	}

	private static double DivideHeight(int[] pm, int row, double along)
	{
		double u = along / 150.0;
		int k = (int)Math.Floor(u);
		double t = u - k;
		t = t * t * (3.0 - 2.0 * t);
		double a = RidgeNode(pm, k, row, 211), b = RidgeNode(pm, k + 1, row, 211);
		return 0.58 + 0.44 * (a + (b - a) * t);
	}

	private static double RidgeJoin(double a, double b, double width)
	{
		width = Math.Min(width, Math.Min(a, b));
		if (width <= 0.0) return Math.Max(a, b);
		double h = Math.Max(0.0, 1.0 - Math.Abs(a - b) / width);
		return Math.Max(a, b) + width * h * h * 0.25;
	}

	private static double ReliefSmooth(double from, double to, double value)
	{
		double t = Clamp01((value - from) / (to - from));
		return t * t * (3.0 - 2.0 * t);
	}
}
