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
	private const double BottomRaw = -0.7; // StageRelief.BOTTOM_RAW
	private const double Character = 520.0;
	private const double PlainLift = 0.50;
	private const double PlainHills = 0.34;
	private const double HillAmp = 0.09;
	private const double InlandDetail = 0.35;
	private const double HeightPerWidth = 0.7;
	private const double Foothills = 0.35;
	private const double FoothillLift = 0.18; // StageRelief.FOOTHILL_LIFT (с 3.6)
	private const double MaskEdge = 0.9;
	private const double Valley = 260.0;
	private const double ValleyWidth = 0.24;
	private const double ValleyDepth = 0.06;

	/// <summary>
	/// Рельеф прямоугольника W × H с углом (x0, y0). Нулевая полоса microPad запрашивает
	/// сырые высоты, положительная — готовую поверхность с рябью.
	/// Шумы — perm в порядке warpX, warpY, cont, mask, ridge, hill; (mx, my) — сдвиг шума материков.
	/// </summary>
	public float[] ReliefField(int[] warpX, int[] warpY, int[] cont, int[] mask, int[] ridge, int[] hill, double mx, double my, int x0, int y0, int W, int H, double mountainScale, double mountainBias, double mountainHeight, double foothillSpread, bool parallel, bool detail, double heightScale, double tile, int[] microNoise, int microPad)
	{
		if (W <= 0 || H <= 0) return Array.Empty<float>();
		int stride = W + 2 * microPad;
		int rows = H + 2 * microPad;
		var heights = RawReliefField(warpX, warpY, cont, mask, ridge, hill, mx, my,
			x0 - microPad, y0 - microPad, stride, rows, mountainScale, mountainBias, mountainHeight, foothillSpread, parallel, detail, heightScale, tile);
		if (microPad == 0) return heights;
		void NormalizeRow(int y)
		{
			for (int i = y * stride, end = i + stride; i < end; i++)
			{
				double v = heights[i];
				heights[i] = (float)(v >= SeaRaw ? Math.Min(Math.Pow((v - SeaRaw) / (TopRaw - SeaRaw), 1.25), 1.4) : (v - SeaRaw) / (SeaRaw - BottomRaw));
			}
		}
		RunRows(rows, parallel, NormalizeRow);
		return ReliefMicro(heights, microNoise, x0, y0, W, H, microPad, heightScale, tile, parallel);
	}

	/// <summary>
	/// Рельеф долины (docs/WORLD_TEMPLATES.md): дно, мягкое русло, предгорья с поперечными отрогами,
	/// стены гор (Mountain) и торцы формируются ДО MountainDetail и ReliefMicro.
	/// Все настраиваемые числа передаются одним массивом rp из WorldTypeConfig.relief_params() — без дублей в C#.
	/// </summary>
	public float[] ValleyReliefField(int[] warpX, int[] warpY, int[] ridge, int[] hill,
		int x0, int y0, int W, int H, int roadSide,
		double[] axisX, double[] axisCos, double[] floorH, double[] riverHw, double[] bedDepth,
		double[] spurH, double[] spurReach, double[] oppSpurH, double[] oppSpurReach,
		double[] wallShiftR, double[] wallShiftL, double[] channelFade, double[] endWall,
		double[] rp, double mountainScale, double mountainHeight, bool parallel, bool detail,
		double heightScale, double tile, int[] microNoise, int microPad)
	{
		if (W <= 0 || H <= 0) return Array.Empty<float>();
		int dPad = detail ? DetailPad : 0;
		int totalPad = microPad + dPad;
		int bw = W + 2 * totalPad;
		int bh = H + 2 * totalPad;
		int bx0 = x0 - totalPad;
		int by0 = y0 - totalPad;
		double wide = mountainScale * Math.Max(1.0, mountainHeight / (mountainScale * HeightPerWidth));
		double dampStart = rp[4], dampEnd = rp[5], knee = rp[32], soft = rp[33];
		var baseRaw = new float[bw * bh];
		void BaseRow(int j)
		{
			double ax = axisX[j], ac = axisCos[j], fh = floorH[j], rhw = riverHw[j], bd = bedDepth[j];
			double sh = spurH[j], sr = spurReach[j], osh = oppSpurH[j], osr = oppSpurReach[j];
			double wsr = wallShiftR[j], wsl = wallShiftL[j], cf = channelFade[j], ew = endWall[j];
			int wy = by0 + j;
			for (int i = 0; i < bw; i++)
			{
				double hv = ValleyBaseAt(warpX, warpY, ridge, hill, bx0 + i, wy, roadSide,
					ax, ac, fh, rhw, bd, sh, sr, osh, osr, wsr, wsl, cf, ew, rp, mountainHeight, wide);
				baseRaw[j * bw + i] = (float)(SeaRaw + Math.Pow(Math.Max(1e-6, hv), 0.8) * (TopRaw - SeaRaw));
			}
		}
		RunRows(bh, parallel, BaseRow);

		int stride = W + 2 * microPad;
		int rows = H + 2 * microPad;
		var norm = new float[stride * rows];
		void DetailNormRow(int j)
		{
			int rj = j + dPad;
			double ax = axisX[rj], ac = axisCos[rj], rhw = riverHw[rj], cf = channelFade[rj];
			int wy = y0 - microPad + j;
			for (int i = 0; i < stride; i++)
			{
				int wx = x0 - microPad + i;
				int bk = rj * bw + i + dPad;
				double rawV = baseRaw[bk];
				if (detail)
				{
					double detV = Detail(ridge, hill, baseRaw, bw, bk, wx, wy, heightScale, tile);
					double damp = 1.0 - (1.0 - ReliefSmooth(rhw + dampStart, rhw + dampEnd, Math.Abs(wx - ax) * ac)) * cf;
					rawV += (detV - rawV) * damp;
				}
				double q = Math.Max(0.0, (rawV - SeaRaw) / (TopRaw - SeaRaw));
				double h = Math.Pow(q, 1.25);
				if (h > knee)
					h = knee + (h - knee) / (1.0 + (h - knee) / soft);
				norm[j * stride + i] = (float)h;
			}
		}
		RunRows(rows, parallel, DetailNormRow);
		if (microPad == 0)
			return norm;
		var withMicro = ReliefMicro(norm, microNoise, x0, y0, W, H, microPad, heightScale, tile, parallel, rp[59], rp[60]);
		// Гасим мелкую рябь внутри русла и на кромке берега (по нормали к руслу).
		void DampMicroRow(int j)
		{
			int rj = j + totalPad;
			double ax = axisX[rj], ac = axisCos[rj], rhw = riverHw[rj], cf = channelFade[rj];
			for (int i = 0; i < W; i++)
			{
				double damp = 1.0 - (1.0 - ReliefSmooth(rhw + dampStart, rhw + dampEnd, Math.Abs((x0 + i) - ax) * ac)) * cf;
				if (damp < 1.0)
				{
					int nk = (j + microPad) * stride + i + microPad;
					int ok = j * W + i;
					withMicro[ok] = (float)(norm[nk] + (withMicro[ok] - norm[nk]) * damp);
				}
			}
		}
		RunRows(H, parallel, DampMicroRow);
		return withMicro;
	}

	/// <summary>Разрежённый макрорельеф долины (шаг step клеток) для лёгкого дальнего пояса OuterTerrain.</summary>
	public float[] ValleyReliefCoarse(int[] warpX, int[] warpY, int[] ridge, int[] hill,
		int x0, int y0, int cols, int rows, int step, int roadSide,
		double[] axisX, double[] axisCos, double[] floorH, double[] riverHw, double[] bedDepth,
		double[] spurH, double[] spurReach, double[] oppSpurH, double[] oppSpurReach,
		double[] wallShiftR, double[] wallShiftL, double[] channelFade, double[] endWall,
		double[] rp, double mountainScale, double mountainHeight, bool parallel)
	{
		if (cols <= 0 || rows <= 0) return Array.Empty<float>();
		double wide = mountainScale * Math.Max(1.0, mountainHeight / (mountainScale * HeightPerWidth));
		double knee = rp[32], soft = rp[33];
		var outH = new float[cols * rows];
		void CoarseRow(int j)
		{
			double ax = axisX[j], ac = axisCos[j], fh = floorH[j], rhw = riverHw[j], bd = bedDepth[j];
			double sh = spurH[j], sr = spurReach[j], osh = oppSpurH[j], osr = oppSpurReach[j];
			double wsr = wallShiftR[j], wsl = wallShiftL[j], cf = channelFade[j], ew = endWall[j];
			int wy = y0 + j * step;
			for (int i = 0; i < cols; i++)
			{
				double hv = ValleyBaseAt(warpX, warpY, ridge, hill, x0 + i * step, wy, roadSide,
					ax, ac, fh, rhw, bd, sh, sr, osh, osr, wsr, wsl, cf, ew, rp, mountainHeight, wide);
				float rawV = (float)(SeaRaw + Math.Pow(Math.Max(1e-6, hv), 0.8) * (TopRaw - SeaRaw));
				double q = Math.Max(0.0, (rawV - SeaRaw) / (TopRaw - SeaRaw));
				double h = Math.Pow(q, 1.25);
				if (h > knee)
					h = knee + (h - knee) / (1.0 + (h - knee) / soft);
				outH[j * cols + i] = (float)h;
			}
		}
		RunRows(rows, parallel, CoarseRow);
		return outH;
	}

	// Indices in WorldTypeConfig.relief_params(). Both samplers get the numbers from the same resource.
	private const int ValleyMesoScale = 55, ValleyMesoAmp = 56, ValleyBankVariation = 57, ValleyFloorGully = 58;
	private const int ValleyBankScaleX = 61, ValleyBankScaleY = 62, ValleyBankPhaseX = 63, ValleyBankPhaseY = 64;
	private const int ValleyMesoSkew = 65, ValleyMesoAspect = 66, ValleyMesoPhaseX = 67, ValleyMesoPhaseY = 68;
	private const int ValleyRidgeSkew = 69, ValleyRidgeScaleX = 70, ValleyRidgeScaleY = 71;
	private const int ValleyRidgePhaseX = 72, ValleyRidgePhaseY = 73, ValleyRidgeMin = 74, ValleyRidgeMax = 75;
	private const int ValleyRidgeCenter = 76, ValleyRidgeGain = 77, ValleyMesoDryStart = 78, ValleyMesoDryEnd = 79;
	private const int ValleyFloorGullyStart = 80, ValleyFloorGullyEnd = 81;

	private static double ValleyBaseAt(int[] warpX, int[] warpY, int[] ridge, int[] hill,
		double x, double y, int roadSide, double ax, double ac, double fh, double rhw, double bd,
		double sh, double sr, double osh, double osr, double wsr, double wsl,
		double cf, double ew, double[] rp, double mountainHeight, double wide)
	{
		double wx = Fbm(warpX, x / rp[0], y / rp[0], 3) * rp[1];
		double wy = Fbm(warpY, x / rp[0] + 13.1, y / rp[0] - 7.7, 3) * rp[1];
		double X = x + wx;
		double Y = y + wy;
		double rawSd = (x - ax) * roadSide;
		double rawAd = Math.Abs(rawSd);
		double cosEff = ac + (1.0 - ac) * ReliefSmooth(28.0, 92.0, rawAd);
		double sd = rawSd * cosEff;
		double ad = Math.Abs(sd);
		double dChan;
		if (ad < rhw)
		{
			double u = ad / Math.Max(0.5, rhw);
			dChan = -bd * (1.0 - u * u);
		}
		else
		{
			double bank = 0.0;
			if (rp[ValleyBankVariation] > 0.0)
				bank = Noise(hill, X / rp[ValleyBankScaleX] + rp[ValleyBankPhaseX],
					Y / rp[ValleyBankScaleY] + rp[ValleyBankPhaseY]) * rp[ValleyBankVariation];
			dChan = rp[2] * (1.0 + bank) * (1.0 - Math.Exp(-(ad - rhw) / (rp[3] * (1.0 - bank))));
		}
		double landDamp = 1.0 - (1.0 - ReliefSmooth(rhw + rp[4], rhw + rp[5], ad)) * cf;
		double hillsFine = Fbm(hill, X / rp[6], Y / rp[6], 4);
		double hillsBroad = Fbm(hill, X / rp[7] + 32.4, Y / rp[7] - 18.6, 2);
		double folds = rp[8] * hillsBroad + rp[9] * hillsFine;

		if (rp[ValleyMesoAmp] > 0.0)
		{
			double scale = rp[ValleyMesoScale], skew = rp[ValleyMesoSkew], ridgeSkew = rp[ValleyRidgeSkew];
			double m = Fbm(hill, (X + skew * Y) / scale + rp[ValleyMesoPhaseX],
				(Y - skew * X) / (scale * rp[ValleyMesoAspect]) + rp[ValleyMesoPhaseY], 2);
			double crest = 1.0 - Math.Abs(Noise(ridge,
				(X - ridgeSkew * Y) / (scale * rp[ValleyRidgeScaleX]) + rp[ValleyRidgePhaseX],
				(Y + X * ridgeSkew) / (scale * rp[ValleyRidgeScaleY]) + rp[ValleyRidgePhaseY]));
			double ridgeShape = ReliefSmooth(rp[ValleyRidgeMin], rp[ValleyRidgeMax], crest) - rp[ValleyRidgeCenter];
			double dryBand = ReliefSmooth(rhw + rp[ValleyMesoDryStart], rhw + rp[ValleyMesoDryEnd], ad);
			folds += rp[ValleyMesoAmp] * dryBand * (m + rp[ValleyRidgeGain] * ridgeShape);
		}
		double roadD = Math.Max(0.0, sd - (rhw + rp[10]));
		double benchRise = rp[11] * roadD + rp[12] * roadD * roadD;
		double spurLift = 0.0;
		if (sh > 0.0 && sd > rhw + rp[13])
		{
			double sm = ReliefSmooth(rhw + rp[13], sr, sd);
			double saddle = (sd - (sr + rp[14])) / rp[15];
			spurLift = sh * sm * (1.0 - rp[16] * Math.Exp(-saddle * saddle));
		}
		double oppSpurLift = 0.0;
		if (osh > 0.0 && -sd > rhw + rp[54])
		{
			oppSpurLift = osh * ReliefSmooth(rhw + rp[54], osr, -sd);
		}
		double sdR = sd - wsr;
		double sdL = -sd - wsl;
		double wallR = ReliefSmooth(rp[17], rp[18], sdR);
		double wallBaseR = ReliefSmooth(rp[19], rp[20], sdR) * rp[21];
		double wallL = ReliefSmooth(rp[22], rp[23], sdL);
		double wallBaseL = ReliefSmooth(rp[24], rp[25], sdL) * rp[26];
		double wall = Math.Max(wallR, wallL);
		double outerSpan = Math.Max(1.0, rp[51]);
		double outerWall = (rp[52] > 0.0 || rp[53] > 0.0)
			? Math.Max(ReliefSmooth(rp[49], rp[49] + outerSpan, sd), ReliefSmooth(rp[50], rp[50] + outerSpan, -sd))
			: 0.0;
		double wallBase = Math.Max(wallBaseR, wallBaseL) + outerWall * rp[52] + ew;
		double wallTerm = wallBase;
		double mStrength = Math.Max(wall, ew * rp[27]);
		double mGain = mStrength * rp[28] + outerWall * rp[53];
		if (mGain > 0.0)
		{
			double mRelief = Mountain(ridge, hill, (x + wx * MountainWarp) / wide, (y + wy * MountainWarp) / wide, 1.0);
			wallTerm += mRelief * mGain * mountainHeight;
		}
		double floorCut = 0.0;
		double floorGate = rp[ValleyFloorGully] * ReliefSmooth(rhw + rp[ValleyFloorGullyStart], rhw + rp[ValleyFloorGullyEnd], ad);
		if (rp[37] > 0.0 && (wall > rp[38] || floorGate > 0.0))
		{
			double gwMask = ReliefSmooth(rp[38], rp[39], wall);
			double gWarp = Fbm(warpY, X / 95.0 - 5.2, Y / 95.0 + 11.4, 2) * 38.0;
			double gu = (ad + Fbm(warpX, X / 140.0 + 9.1, Y / 140.0 - 4.3, 2) * 24.0) / rp[34];
			double gv = (Y - 0.28 * ad + gWarp) / rp[35];
			double gn = Math.Abs(Fbm(ridge, gu + 19.3, gv - 7.1, 2));
			double gT = Clamp01(1.0 - gn / Math.Max(1e-4, rp[36]));
			double gShape = gT * gT * (3.0 - 2.0 * gT);
			wallTerm -= gwMask * rp[37] * (1.0 - 0.55 * outerWall) * gShape;
			floorCut = floorGate * gShape * (1.0 - wall);
		}
		if (rp[43] > 0.0 && wall > rp[47])
		{
			double cwMask = ReliefSmooth(rp[47], rp[48], wall);
			double cPatch = ReliefSmooth(rp[45], rp[46], Fbm(hill, X / rp[44] - 27.4, Y / rp[44] + 19.2, 2));
			if (cPatch > 0.0)
			{
				double cWarp = Fbm(warpX, X / 55.0 + 31.2, Y / 55.0 - 14.8, 2) * 18.0;
				double cu = ad / rp[40];
				double cv = (Y - 0.18 * ad + cWarp) / rp[41];
				double cn = Math.Abs(Noise(ridge, cu - 11.7, cv + 23.5));
				double cT = Clamp01(1.0 - cn / Math.Max(1e-4, rp[42]));
				wallTerm -= cwMask * cPatch * rp[43] * (cT * cT * (3.0 - 2.0 * cT));
			}
		}
		if (wallTerm < 0.0) wallTerm = 0.0;
		double h = fh + dChan * cf + rp[30] * (1.0 - cf) + landDamp * (benchRise + folds * (1.0 - rp[29] * wall) + spurLift + oppSpurLift + wallTerm - floorCut);
		if (h < rp[31]) h = rp[31];
		return h;
	}

	private static float[] RawReliefField(int[] warpX, int[] warpY, int[] cont, int[] mask, int[] ridge, int[] hill, double mx, double my, int x0, int y0, int W, int H, double mountainScale, double mountainBias, double mountainHeight, double foothillSpread, bool parallel, bool detail, double heightScale, double tile)
	{
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
	private const double DetailLow = 3.0;
	private const double DetailLowFull = 20.0;
	private const double DetailMountain = 30.0;
	private const double DetailTransition = 42.0;
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

	/// <summary>Копия StageRelief.add_micro. Вход — нормированные высоты с полосой соседей.</summary>
	private static float[] ReliefMicro(float[] heights, int[] noise, int x0, int y0, int width, int height, int pad, double heightScale, double tile, bool parallel, double open = 0.0, double gain = 1.0)
	{
		int stride = width + 2 * pad;
		int d = pad * stride;
		var output = new float[width * height];
		void Row(int j)
		{
			int y = y0 + j;
			for (int i = 0; i < width; i++)
			{
				int k = (j + pad) * stride + i + pad;
				double h = heights[k];
				if (h > 0.0)
				{
					double around = ((double)heights[k - pad] + heights[k + pad] + heights[k - d] + heights[k + d]) * 0.25;
					double hollow = (around - h) * heightScale;
					double lowland = 1.0 - ReliefSmooth(32.0, 68.0, h * heightScale);
					int x = x0 + i;
					double strength = 1.0;
					if (lowland > 0.0 || hollow > 0.25)
					{
						double gx = (double)heights[k + 2] - heights[k - 2];
						double gy = (double)heights[k + 2 * stride] - heights[k - 2 * stride];
						double grade = Math.Sqrt(gx * gx + gy * gy) * heightScale / (4.0 * tile);
						double shelter = ReliefSmooth(0.25, 1.5, hollow) * (1.0 - ReliefSmooth(0.12, 0.35, grade));
						double weight = Math.Max(lowland, shelter);
						if (weight > 0.0)
						{
							double flank = ReliefSmooth(0.02, 0.16, grade);
							double shoulder = ReliefSmooth(0.25, 1.5, -hollow);
							double terrain = 0.06 + 0.94 * Math.Max(flank, shoulder) * (1.0 - 0.9 * shelter);
							double patch = Noise(noise, x / 90.0 + 83.7, y / 90.0 - 41.3);
							if (patch > 0.16 && lowland > 0.0)
								terrain += 0.10 * ReliefSmooth(0.16, 0.48, patch) * lowland * (1.0 - shelter) * (1.0 - terrain);
							double varied = terrain * (0.35 + 0.65 * ReliefSmooth(-0.55, 0.15, patch));
							strength = 1.0 + (varied - 1.0) * weight;
						}
					}
					h = Math.Max(1e-4, h + Fbm(noise, x / 9.0, y / 9.0, 2) * 0.006 * Math.Min(1.0, h * 40.0) * (strength + (1.0 - strength) * open) * gain);
				}
				output[j * width + i] = (float)h;
			}
		}
		RunRows(height, parallel, Row);
		return output;
	}

	/// <summary>Копия mountain_detail.gd.apply; base b is read-only.</summary>
	private static double Detail(int[] ridge, int[] hill, float[] b, int bw, int k, double x, double y, double heightScale, double tile)
	{
		double v = b[k];
		double q = (v - SeaRaw) / (TopRaw - SeaRaw);
		if (q <= 0.0)
			return v;
		double r4 = Math.Sqrt(Math.Sqrt(q));
		double elev = q * r4 * heightScale;
		if (elev <= DetailLow)
			return v;
		double t = Clamp01((elev - DetailMountain) / (DetailHigh - DetailMountain));
		double lift = t * t * (3.0 - 2.0 * t);
		double mountain = 1.0;
		if (elev < DetailTransition)
		{
			mountain = ReliefSmooth(DetailMountain, DetailTransition, elev);
			double shore = ReliefSmooth(0.015, 0.08, v - SeaRaw);
			lift += 0.42 * ReliefSmooth(DetailLow, DetailLowFull, elev) * (1.0 - mountain) * shore;
		}
		double perRaw = 1.25 * r4 / (TopRaw - SeaRaw) * heightScale;
		int r = 2 * bw;
		double gx = (((double)b[k + 2 - r] + 2.0 * b[k + 2] + b[k + 2 + r]) - ((double)b[k - 2 - r] + 2.0 * b[k - 2] + b[k - 2 + r])) * perRaw / (16.0 * tile);
		double gy = (((double)b[k - 2 + r] + 2.0 * b[k + r] + b[k + 2 + r]) - ((double)b[k - 2 - r] + 2.0 * b[k - r] + b[k + 2 - r])) * perRaw / (16.0 * tile);
		double g2 = gx * gx + gy * gy;
		double lowland = 1.0 - mountain;
		double gentleStart = 0.04 - 0.025 * lowland;
		if (g2 <= gentleStart * gentleStart)
			return v;
		double s = Math.Sqrt(g2);
		if (s >= DetailLimit)
			return v;
		double bend = (((double)b[k + 2] + b[k - 2]) + ((double)b[k + r] + b[k - r]) - 4.0 * b[k]) * perRaw;
		t = Clamp01((-bend - 0.6) / (2.0 - 0.6));
		double crest = 1.0 - 0.65 * t * t * (3.0 - 2.0 * t);
		t = Clamp01((Noise(hill, x / 170.0 + 211.7, y / 170.0 - 93.1) + 0.5) / 1.0);
		double vary = t * t * (3.0 - 2.0 * t);
		double gentleEnd = 0.12 - 0.03 * lowland;
		t = Clamp01((s - gentleStart) / (gentleEnd - gentleStart));
		double gentle = t * t * (3.0 - 2.0 * t);
		double c2 = (gx * gx - gy * gy) / g2;
		double s2 = 2.0 * gx * gy / g2;
		t = Clamp01((s - 0.25) / (0.45 - 0.25));
		double narrow = t * t * (3.0 - 2.0 * t) * mountain;
		double fine = 0.0;
		if (mountain > 0.0 && s > 0.4)
		{
			t = Clamp01((Noise(hill, x / 95.0 - 57.3, y / 95.0 + 138.9) + 0.5) / 1.0);
			double patch = t * t * (3.0 - 2.0 * t);
			t = Clamp01((s - 0.4) / (0.6 - 0.4));
			fine = (0.1 + 0.3 * patch) * (t * t * (3.0 - 2.0 * t)) * mountain;
		}
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
	private static float[] BaseField(int[] warpX, int[] warpY, int[] cont, int[] mask, int[] ridge, int[] hill, double mx, double my, int x0, int y0, int W, int H, double mountainScale, double mountainBias, double mountainHeight, double foothillSpread, bool parallel)
	{
		var outH = new float[W * H];
		// World parameters are constant for the whole request, not per cell.
		double footScale = 100.0 * Math.Max(mountainScale, mountainHeight / HeightPerWidth);
		double wide = mountainScale * Math.Max(1.0, mountainHeight / (mountainScale * HeightPerWidth));
		void Row(int j)
		{
			for (int i = 0; i < W; i++)
				outH[j * W + i] = (float)BaseAt(warpX, warpY, cont, mask, ridge, hill, x0 + i, y0 + j, mx, my, mountainScale, mountainBias, mountainHeight, foothillSpread, footScale, wide, true);
		}
		RunRows(H, parallel, Row);
		return outH;
	}

	/// <summary>
	/// Сырой макрорельеф в точках (px[k], py[k]) со своим сдвигом шума материков (mx[k], my[k]), в double,
	/// как StageRelief.raw_at без новых увалов: оценка кандидатов стартовой области (StageRelief._start_raws).
	/// </summary>
	public double[] ReliefRawPoints(int[] warpX, int[] warpY, int[] cont, int[] mask, int[] ridge, int[] hill, double[] mx, double[] my, double[] px, double[] py, double mountainScale, double mountainBias, double mountainHeight, double foothillSpread)
	{
		int n = px.Length;
		var raw = new double[n];
		double footScale = 100.0 * Math.Max(mountainScale, mountainHeight / HeightPerWidth);
		double wide = mountainScale * Math.Max(1.0, mountainHeight / (mountainScale * HeightPerWidth));
		System.Threading.Tasks.Parallel.For(0, n, k =>
			raw[k] = BaseAt(warpX, warpY, cont, mask, ridge, hill, px[k], py[k], mx[k], my[k], mountainScale, mountainBias, mountainHeight, foothillSpread, footScale, wide, false));
		return raw;
	}

	/// <summary>fbm(px[k], py[k], oct) в точках: копия Simplex.fbm с усилением 0.5 и лакунарностью 2.</summary>
	public double[] FbmPoints(int[] perm, double[] px, double[] py, int oct)
	{
		var v = new double[px.Length];
		for (int k = 0; k < v.Length; k++)
			v[k] = Fbm(perm, px[k], py[k], oct);
		return v;
	}

	/// <summary>Макрорельеф одной клетки (копия StageRelief.raw_at); footScale и wide — параметры мира, см. BaseField.</summary>
	private static double BaseAt(int[] warpX, int[] warpY, int[] cont, int[] mask, int[] ridge, int[] hill, double x, double y, double mx, double my, double mountainScale, double mountainBias, double mountainHeight, double foothillSpread, double footScale, double wide, bool shapePlains)
	{
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
		double aboveSea = h - SeaRaw;
		if (shapePlains && calm > 0.0 && core < 0.35 && aboveSea > 0.015 && aboveSea < 0.30)
		{
			double plain = calm * (1.0 - ReliefSmooth(0.1, 0.35, core));
			double lowland = ReliefSmooth(0.015, 0.07, aboveSea) * (1.0 - ReliefSmooth(0.18, 0.30, aboveSea));
			double rolling = Noise(hill, X / 90.0 - 24.7, Y / 90.0 + 53.1);
			double fold = 0.055 * rolling - 0.025 * hills * shoreFade - 0.010 * valley;
			h += fold * plain * lowland;
		}
		return h;
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
	private const double UplandAmp = 0.42;
	private const double UplandSmooth = 0.50;
	private const double PeakKnee = 0.45;
	private const double PeakSoft = 0.30;

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
