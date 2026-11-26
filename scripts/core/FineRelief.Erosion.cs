using System;
using System.Threading.Tasks;
using Godot;
using Inputs = Godot.Collections.Dictionary;

/// <summary>
/// Эрозия поверхности 4 м Типа 2 (docs/RELIEF_FINE_GEOMETRY_2.md, раздел 4.2). Сток не рисуется водой: он только
/// вырезает форму. Схема за итерацию:
/// 1) сток по одному направлению (наибольшее падение среди 8 соседей) по поверхности с заполненными впадинами;
/// 2) водосбор A — сумма площадей вверх по течению (+ условный приток с края плана);
/// 3) врезание по закону мощности потока K·(A^m − Ac^m)·S (Ac — водосбор головы лощины), неявно (Braun, Willett 2013): устойчиво при любом шаге;
/// 4) наименьшая ширина лощины — сглаживание врезания этой итерации;
/// 5) наносы: поток несёт снятое вниз и откладывает избыток над своей ёмкостью (ёмкость ~ A^m·S): выносы и ровные днища
///    там, где уклон падает;
/// 6) склон: диффузия выше голов лощин (выпуклые бровки, сглаженный шум междуречий) и сползание всего, что круче max(угол устойчивости, исходный уклон),
///    — борта лощин не круче угла устойчивости, а исходные крутые стены генератора остаются;
/// 7) предел: |изменение| ≤ min(расстояние до защиты × уклон перехода, наибольшая глубина формы), на «скальных»
///    по полю породы склонах — с долей rock_erosion_share; пласты RockRelief и места массивов — защита.
/// Считается на своей сетке: блоки grid_factor × grid_factor узлов 4 м (среднее), изменение возвращается на 4 м
/// билинейно. Так сток ведёт форма склона, а не мелкий шум генератора, и расчёт в factor² раз дешевле.
/// Последовательные шаги (сток, порядок, врезание, наносы) однопоточны — результат не зависит от числа потоков.
/// Карты: A (водосбор), D (толщина наносов), W (влажность по индексу ln(a / tg β)).
/// </summary>
public static class TerrainErosion
{
	// Порядок совпадает с WorldReliefGenerationConfig.erosion_params().
	internal enum Parameter
	{
		Iterations, TransitionGrade, MaxChange, IncisionRate, ReferenceArea, AreaExponent,
		ReposeGrade, CreepRate, Diffusion, Capacity, DepositionRate, EdgeInflow, MinWidth, WetLow, WetHigh,
		ChannelArea, Roughness, RoughnessWavelength, GridFactor, RockShare, Count
	}

	// Порядок восьми соседей; одинаковый порядок обхода — одинаковый выбор при равных падениях на любом ПК.
	private static readonly int[] Dx = { 1, -1, 0, 0, 1, -1, 1, -1 };
	private static readonly int[] Dz = { 0, 0, 1, -1, 1, 1, -1, -1 };
	/// <summary>Численный подъём заполнения на шаг сетки по плоскому дну впадины, м: задаёт направление стока по
	/// заполненной поверхности. Меньше любого заметного перепада и больше погрешности float32 высот плана.</summary>
	private const double FillRiseM = 1e-3;
	/// <summary>Нижний предел уклона в индексе влажности ln(a / tg β): на ровном месте индекс конечен.</summary>
	private const double WetSlopeFloor = 1e-3;
	/// <summary>Кодирование карты водосбора в байт: 8 ступеней на удвоение площади, от площади одной клетки
	/// (255 ступеней ≈ 2^32 клеток — больше любого плана).</summary>
	internal const double AreaStepsPerOctave = 8.0;
	/// <summary>Кодирование карты наносов в байт: 2 см на ступень (до 5,1 м).</summary>
	internal const double DepositStepM = 0.02;

	internal static Godot.Collections.Dictionary Run(Inputs input, double[] maskProfile, double[] profile)
	{
		if (profile.Length != (int)Parameter.Count)
			return null;
		foreach (double value in profile)
			if (!double.IsFinite(value))
				return null;
		var mask = ReliefMask.Build(input, maskProfile, true);
		if (mask == null)
			return null;
		double P(Parameter key) => profile[(int)key];
		int width = mask.Width, height = mask.Height, n = width * height;
		double tile = mask.Tile;
		int factor = Math.Max(1, (int)P(Parameter.GridFactor));
		if ((int)P(Parameter.Iterations) <= 0 || P(Parameter.ReferenceArea) <= 0.0 || tile <= 0.0)
			return null;
		var hv = input["hv"].AsFloat32Array();
		var wet = input["wet"].AsByteArray();
		var lake = input["lake"].AsByteArray();
		var allowed = new double[n];
		for (int k = 0; k < n; k++)
			// Склоны, которые поле породы считает скалой, размываются с долей rock_erosion_share; пласты RockRelief
			// и места массивов защищены маской (ProtectM).
			allowed[k] = Math.Min(mask.ProtectM[k] * P(Parameter.TransitionGrade), P(Parameter.MaxChange))
				* (1.0 - (1.0 - P(Parameter.RockShare)) * (1.0 - mask.RockFree[k]));

		// Сетка эрозии: блоки factor × factor узлов 4 м. Высота блока — среднее (мелкий шум генератора не ведёт сток),
		// предел — наименьший в блоке (у защиты не больше, чем у самого защищённого узла), устье — если есть хоть одно.
		int cw = (width + factor - 1) / factor, ch = (height + factor - 1) / factor, cn = cw * ch;
		var zc = new double[cn];
		var allowedC = new double[cn];
		var outletC = new bool[cn];
		Array.Fill(allowedC, double.MaxValue);
		var count = new int[cn];
		for (int zz = 0; zz < height; zz++)
		for (int x = 0; x < width; x++)
		{
			int k = zz * width + x, c = zz / factor * cw + x / factor;
			zc[c] += hv[k];
			count[c]++;
			allowedC[c] = Math.Min(allowedC[c], allowed[k]);
			outletC[c] |= wet[k] != 0 || lake[k] != 0 || x == 0 || zz == 0 || x == width - 1 || zz == height - 1;
		}
		for (int c = 0; c < cn; c++)
			zc[c] /= count[c];
		var origin = input["origin"].AsVector2I();
		var rough = Roughness((uint)input["erosion_seed"].AsInt64(), (origin.X + (factor - 1) * 0.5) * tile,
			(origin.Y + (factor - 1) * 0.5) * tile, cw, ch, tile * factor, P(Parameter.Roughness), P(Parameter.RoughnessWavelength));
		var phase = new double[6];
		var flow = Simulate(zc, outletC, allowedC, rough, cw, ch, tile * factor, profile, phase, out int sinks);

		// Итог на сетке 4 м: изменение блоков билинейно, с пределом самого узла; карты — по своим узлам.
		var heights = new float[n];
		var delta = new float[n];
		var areaMap = new byte[n];
		var depositMap = new byte[n];
		var wetMap = new byte[n];
		var changed = new System.Collections.Generic.List<int>();
		double cellArea = tile * tile, wetLow = P(Parameter.WetLow), wetHigh = P(Parameter.WetHigh);
		var change = flow.Change;
		Parallel.For(0, height, zz =>
		{
			for (int x = 0; x < width; x++)
			{
				int k = zz * width + x;
				double d = Bilinear(change, cw, ch, (x - (factor - 1) * 0.5) / factor, (zz - (factor - 1) * 0.5) / factor);
				heights[k] = (float)(hv[k] + Math.Clamp(d, -allowed[k], allowed[k]));
			}
		});
		for (int k = 0; k < n; k++)
		{
			delta[k] = heights[k] - hv[k];
			if (delta[k] != 0.0f)
				changed.Add(k);
		}
		Parallel.For(0, height, zz =>
		{
			for (int x = 0; x < width; x++)
			{
				int k = zz * width + x;
				// Водосбор блока делится между его узлами поровну по ширине потока: на узел — A / factor.
				double area = Math.Max(cellArea, flow.Area[zz / factor * cw + x / factor] / factor);
				areaMap[k] = (byte)Math.Clamp(Math.Round(AreaStepsPerOctave * Math.Log2(area / cellArea)), 0, byte.MaxValue);
				depositMap[k] = (byte)Math.Clamp(Math.Round(Math.Max(0.0, delta[k]) / DepositStepM), 0, byte.MaxValue);
				double gx = (heights[zz * width + Math.Min(width - 1, x + 1)] - heights[zz * width + Math.Max(0, x - 1)]) / (2.0 * tile);
				double gz = (heights[Math.Min(height - 1, zz + 1) * width + x] - heights[Math.Max(0, zz - 1) * width + x]) / (2.0 * tile);
				// Индекс влажности: удельный водосбор на единицу ширины склона / уклон.
				double index = Math.Log(area / tile / Math.Max(WetSlopeFloor, Math.Sqrt(gx * gx + gz * gz)));
				wetMap[k] = (byte)Math.Round(byte.MaxValue * Math.Clamp((index - wetLow) / (wetHigh - wetLow), 0.0, 1.0));
			}
		});
		return new Godot.Collections.Dictionary
		{
			["hv"] = heights, ["delta"] = delta, ["area"] = areaMap, ["deposit"] = depositMap, ["wet"] = wetMap,
			["changed"] = changed.ToArray(), ["phase_ms"] = phase, ["sinks"] = sinks,
			["max_area_m2"] = Max(flow.Area), ["allowed"] = Array.ConvertAll(allowed, v => (float)v),
		};
	}

	private static double Bilinear(double[] values, int width, int height, double fx, double fz)
	{
		fx = Math.Clamp(fx, 0.0, width - 1);
		fz = Math.Clamp(fz, 0.0, height - 1);
		int x = Math.Min((int)fx, width - 2 < 0 ? 0 : width - 2), z = Math.Min((int)fz, height - 2 < 0 ? 0 : height - 2);
		double u = fx - x, v = fz - z;
		int x1 = Math.Min(x + 1, width - 1), z1 = Math.Min(z + 1, height - 1);
		double a = values[z * width + x], b = values[z * width + x1], c = values[z1 * width + x], d = values[z1 * width + x1];
		return (a + (b - a) * u) * (1.0 - v) + (c + (d - c) * u) * v;
	}

	private sealed record Flow(double[] Change, double[] Area);

	/// <summary>Сама эрозия на своей сетке (шаг tile): возвращает изменение высот и водосбор последней итерации.</summary>
	private static Flow Simulate(double[] z0, bool[] outlet, double[] allowed, double[] rough, int width, int height,
		double tile, double[] profile, double[] phase, out int sinks)
	{
		double P(Parameter key) => profile[(int)key];
		int n = width * height;
		double cellArea = tile * tile;
		int iterations = (int)P(Parameter.Iterations);
		double incision = P(Parameter.IncisionRate), referenceArea = P(Parameter.ReferenceArea);
		double exponent = P(Parameter.AreaExponent), repose = P(Parameter.ReposeGrade);
		double creep = P(Parameter.CreepRate), diffusion = P(Parameter.Diffusion);
		double capacity = P(Parameter.Capacity), depositionRate = P(Parameter.DepositionRate);
		double channelPower = Math.Pow(Math.Max(0.0, P(Parameter.ChannelArea)) / referenceArea, exponent);
		var z = (double[])z0.Clone();
		var inflow = EdgeInflow(z0, width, height, tile * P(Parameter.EdgeInflow));
		var dist = new double[Dx.Length];
		var soil = new bool[n];
		for (int d = 0; d < Dx.Length; d++)
			dist[d] = tile * Math.Sqrt(Dx[d] * Dx[d] + Dz[d] * Dz[d]);
		// Почвенный склон: исходный уклон узла (центральные разности) не круче угла устойчивости.
		Parallel.For(0, height, zz =>
		{
			for (int x = 0; x < width; x++)
			{
				int k = zz * width + x;
				double gx = (z0[zz * width + Math.Min(width - 1, x + 1)] - z0[zz * width + Math.Max(0, x - 1)]) / (2.0 * tile);
				double gz = (z0[Math.Min(height - 1, zz + 1) * width + x] - z0[Math.Max(0, zz - 1) * width + x]) / (2.0 * tile);
				soil[k] = Math.Sqrt(gx * gx + gz * gz) <= repose;
			}
		});

		var route = new double[n];
		var receiver = new int[n];
		var reach = new double[n];
		var order = new int[n];
		var donorStart = new int[n + 1];
		var donors = new int[n];
		var area = new double[n];
		var power = new double[n];
		var before = new double[n];
		var cut = new double[n];
		var scratch = new double[n];
		var sediment = new double[n];
		var mainArea = new double[n];
		var upstream = new double[n];
		var deposit = new double[n];
		var laid = new double[n];
		int smoothPasses = SmoothPasses(P(Parameter.MinWidth), tile);

		var clock = System.Diagnostics.Stopwatch.StartNew();
		void Lap(int i) { phase[i] += clock.Elapsed.TotalMilliseconds; clock.Restart(); }
		for (int it = 0; it < iterations; it++)
		{
			clock.Restart();
			// Поверхность стока: впадины залиты один раз (priority-flood), дальше подъём по прежнему дереву стока
			// за O(N): у каждой клетки остаётся хотя бы прежний нижний сосед, бессточных ям не появляется.
			if (it == 0)
			{
				for (int k = 0; k < n; k++)
					scratch[k] = outlet[k] ? z[k] : z[k] + rough[k];
				FillRoute(scratch, outlet, width, height, dist, route);
			}
			else
				for (int i = 0; i < n; i++)
				{
					int k = order[i], r = receiver[k];
					double own = outlet[k] ? z[k] : z[k] + rough[k];
					route[k] = r == k ? own : Math.Max(own, route[r] + FillRiseM * reach[k] / dist[0]);
				}
			Lap(0);
			Receivers(route, outlet, width, height, dist, receiver, reach);
			Order(receiver, donorStart, donors, order);
			Lap(1);
			// Водосбор: площадь клетки, приток с края, затем сумма вниз по течению (от вершин к устьям).
			for (int k = 0; k < n; k++)
				area[k] = cellArea + inflow[k];
			for (int i = n - 1; i >= 0; i--)
			{
				int k = order[i], r = receiver[k];
				if (r != k)
					area[r] += area[k];
			}
			// Мощность потока сверх порога лощины: склоны выше головы лощины не врезаются, их ведут диффузия и сползание.
			Parallel.For(0, n, k => power[k] = Math.Max(0.0, Math.Pow(area[k] / referenceArea, exponent) - channelPower));
			Lap(2);
			Array.Copy(z, before, n);
			// Врезание, неявно: устья уже на новых высотах, когда считается клетка выше по течению.
			for (int i = 0; i < n; i++)
			{
				int k = order[i], r = receiver[k];
				if (r == k || allowed[k] <= 0.0 || z[k] <= z[r])
					continue;
				double f = incision * power[k] * tile / reach[k];
				z[k] = Math.Max((z[k] + f * z[r]) / (1.0 + f), z0[k] - allowed[k]);
			}
			// Наименьшая ширина: снятое этой итерацией расходится по соседям, объём сохраняется.
			for (int k = 0; k < n; k++)
				cut[k] = before[k] - z[k];
			for (int pass = 0; pass < smoothPasses; pass++)
				Binomial(cut, scratch, width, height);
			for (int k = 0; k < n; k++)
				z[k] = Math.Max(before[k] - cut[k] * Math.Sign(allowed[k]), z0[k] - allowed[k]);
			Lap(3);
			// Наносы: от вершин к устьям поток собирает снятое и откладывает избыток над ёмкостью.
			Array.Clear(sediment);
			Array.Clear(mainArea);
			Array.Clear(laid);
			for (int k = 0; k < n; k++)
				upstream[k] = z[k];
			for (int i = n - 1; i >= 0; i--)
			{
				int k = order[i], r = receiver[k];
				sediment[k] += Math.Max(0.0, before[k] - z[k]) * cellArea;
				if (r == k)
					continue;
				// Уклон по отрезку главный приток → приёмник: одиночная ступенька русла не ловит нанос (без «бус»),
				// а перелом от склона к днищу ловит.
				double slope = Math.Max(0.0, (upstream[k] - z[r]) / (2.0 * reach[k]));
				double excess = sediment[k] - capacity * power[k] * slope;
				if (excess > 0.0 && allowed[k] > 0.0)
				{
					// Нанос не поднимает клетку выше главного притока (не запруживает поток) и выше предела.
					double room = Math.Min(upstream[k], z0[k] + allowed[k]) - z[k];
					double add = Math.Clamp(depositionRate * excess / cellArea, 0.0, Math.Max(0.0, room));
					laid[k] = add;
					sediment[k] -= add * cellArea;
				}
				sediment[r] += sediment[k];
				if (area[k] > mainArea[r])
				{
					mainArea[r] = area[k];
					upstream[r] = z[k];
				}
			}
			// Нанос ложится той же шириной, что и врезание: без «бус» через клетку вдоль русла.
			for (int pass = 0; pass < smoothPasses; pass++)
				Binomial(laid, scratch, width, height);
			for (int k = 0; k < n; k++)
			{
				if (allowed[k] <= 0.0 || laid[k] <= 0.0)
					continue;
				double add = Math.Min(laid[k], z0[k] + allowed[k] - z[k]);
				if (add <= 0.0)
					continue;
				z[k] += add;
				deposit[k] += add;
			}
			Lap(4);
			Hillslope(z, z0, allowed, power, soil, width, height, dist, repose, creep, diffusion, scratch);
			Lap(5);
		}

		sinks = Sinks(receiver, outlet);
		var change = new double[n];
		for (int k = 0; k < n; k++)
			change[k] = z[k] - z0[k];
		return new Flow(change, area);
	}

	/// <summary>Шероховатость поверхности стока: на гладком ровном склоне сток по одному направлению идёт параллельно
	/// и врезание сносит склон целиком. Неровность только поверхности стока (не высот) даёт стоку сходиться — так из
	/// мелких неровностей рождается сеть лощин, дальше её ведут уже врезанные русла. Шум значений на решётке с шагом
	/// wavelength в мировых метрах (начало сетки originX/Z, шаг step), билинейно, ±amplitude, м; хеш FastGrid.MapHash.</summary>
	private static double[] Roughness(uint seed, double originX, double originZ, int width, int height, double step,
		double amplitude, double wavelength)
	{
		var values = new double[width * height];
		if (amplitude <= 0.0 || wavelength <= 0.0)
			return values;
		Parallel.For(0, height, zz =>
		{
			for (int x = 0; x < width; x++)
			{
				double fx = (originX + (x + 0.5) * step) / wavelength, fz = (originZ + (zz + 0.5) * step) / wavelength;
				int ix = (int)Math.Floor(fx), iz = (int)Math.Floor(fz);
				double u = fx - ix, v = fz - iz;
				double a = FastGrid.MapHash(ix, iz, seed), b = FastGrid.MapHash(ix + 1, iz, seed);
				double c = FastGrid.MapHash(ix, iz + 1, seed), d = FastGrid.MapHash(ix + 1, iz + 1, seed);
				// Хеш 0..1 → −1..1; билинейная интерполяция узлов решётки.
				double value = (a + (b - a) * u) * (1.0 - v) + (c + (d - c) * u) * v;
				values[zz * width + x] = amplitude * (2.0 * value - 1.0);
			}
		});
		return values;
	}

	private static int Sinks(int[] receiver, bool[] outlet)
	{
		int count = 0;
		for (int k = 0; k < receiver.Length; k++)
			count += receiver[k] == k && !outlet[k] ? 1 : 0;
		return count;
	}

	private static double Max(double[] values)
	{
		double best = 0.0;
		foreach (double v in values)
			best = Math.Max(best, v);
		return best;
	}

	/// <summary>Условный приток с края плана: водосбор продолжается за краем, иначе верх стен остаётся без лощин.
	/// Клетка у края получает площадь inflowArea (длина притока × ширина клетки), если земля за ней выше.</summary>
	private static double[] EdgeInflow(double[] z0, int width, int height, double inflowArea)
	{
		var inflow = new double[z0.Length];
		if (inflowArea <= 0.0)
			return inflow;
		for (int x = 1; x < width - 1; x++)
		{
			if (z0[x] > z0[width + x])
				inflow[width + x] += inflowArea;
			int last = (height - 1) * width + x;
			if (z0[last] > z0[last - width])
				inflow[last - width] += inflowArea;
		}
		for (int zz = 1; zz < height - 1; zz++)
		{
			int row = zz * width;
			if (z0[row] > z0[row + 1])
				inflow[row + 1] += inflowArea;
			if (z0[row + width - 1] > z0[row + width - 2])
				inflow[row + width - 2] += inflowArea;
		}
		return inflow;
	}

	/// <summary>Залитая поверхность стока (priority-flood с подъёмом, Barnes 2014) от устьев: сток по ней
	/// проходит через любую яму к реке или краю. Куча с разбором равных высот по номеру клетки — детерминированно.</summary>
	private static void FillRoute(double[] z, bool[] outlet, int width, int height, double[] dist, double[] filled)
	{
		int n = z.Length;
		var done = new bool[n];
		var heap = new MinHeap(n);
		for (int k = 0; k < n; k++)
			if (outlet[k])
			{
				filled[k] = z[k];
				done[k] = true;
				heap.Push(z[k], k);
			}
		while (heap.Count > 0)
		{
			int k = heap.Pop();
			int x = k % width, zz = k / width;
			for (int d = 0; d < Dx.Length; d++)
			{
				int nx = x + Dx[d], nz = zz + Dz[d];
				if (nx < 0 || nz < 0 || nx >= width || nz >= height)
					continue;
				int m = nz * width + nx;
				if (done[m])
					continue;
				done[m] = true;
				filled[m] = Math.Max(z[m], filled[k] + FillRiseM * dist[d] / dist[0]);
				heap.Push(filled[m], m);
			}
		}
	}

	private static void Receivers(double[] route, bool[] outlet, int width, int height, double[] dist, int[] receiver,
		double[] reach)
	{
		Parallel.For(0, height, zz =>
		{
			for (int x = 0; x < width; x++)
			{
				int k = zz * width + x;
				receiver[k] = k;
				reach[k] = dist[0];
				if (outlet[k])
					continue;
				double here = route[k], best = 0.0;
				for (int d = 0; d < Dx.Length; d++)
				{
					int nx = x + Dx[d], nz = zz + Dz[d];
					if (nx < 0 || nz < 0 || nx >= width || nz >= height)
						continue;
					int m = nz * width + nx;
					double fall = (here - route[m]) / dist[d];
					if (fall > best)
					{
						best = fall;
						receiver[k] = m;
						reach[k] = dist[d];
					}
				}
			}
		});
	}

	/// <summary>Порядок от устьев вверх по течению (обход в ширину по притокам), каждая клетка после своего приёмника.</summary>
	private static void Order(int[] receiver, int[] start, int[] donors, int[] order)
	{
		int n = receiver.Length;
		Array.Clear(start);
		for (int k = 0; k < n; k++)
			if (receiver[k] != k)
				start[receiver[k] + 1]++;
		for (int k = 0; k < n; k++)
			start[k + 1] += start[k];
		var fill = new int[n];
		for (int k = 0; k < n; k++)
			if (receiver[k] != k)
				donors[start[receiver[k]] + fill[receiver[k]]++] = k;
		int head = 0, tail = 0;
		for (int k = 0; k < n; k++)
			if (receiver[k] == k)
				order[tail++] = k;
		while (head < tail)
		{
			int k = order[head++];
			for (int i = start[k]; i < start[k + 1]; i++)
				order[tail++] = donors[i];
		}
	}

	/// <summary>Число проходов фильтра [1 2 1]/4 по обеим осям, чтобы ширина канала на половине глубины
	/// (≈ 2,355 σ гауссианы) была не меньше minWidth. Дисперсия одного прохода — 1/2 клетки².</summary>
	private static int SmoothPasses(double minWidth, double tile)
	{
		double sigma = minWidth / (2.355 * tile);
		return Math.Max(0, (int)Math.Round(sigma * sigma / 0.5));
	}

	private static void Binomial(double[] values, double[] scratch, int width, int height)
	{
		Parallel.For(0, height, zz =>
		{
			int row = zz * width;
			for (int x = 0; x < width; x++)
				scratch[row + x] = (values[row + Math.Max(0, x - 1)] + 2.0 * values[row + x] + values[row + Math.Min(width - 1, x + 1)]) * 0.25;
		});
		Parallel.For(0, height, zz =>
		{
			int up = Math.Max(0, zz - 1) * width, row = zz * width, down = Math.Min(height - 1, zz + 1) * width;
			for (int x = 0; x < width; x++)
				values[row + x] = (scratch[up + x] + 2.0 * scratch[row + x] + scratch[down + x]) * 0.25;
		});
	}

	/// <summary>Склон, схема Якоби (каждый узел считает только своё изменение): диффузия выше голов лощин делает бровки выпуклыми,
	/// сползание срезает всё, что круче max(угол устойчивости, исходный уклон того же ребра).</summary>
	private static void Hillslope(double[] z, double[] z0, double[] allowed, double[] power, bool[] soil, int width, int height, double[] dist,
		double repose, double creep, double diffusion, double[] next)
	{
		Parallel.For(0, height, zz =>
		{
			for (int x = 0; x < width; x++)
			{
				int k = zz * width + x;
				if (allowed[k] <= 0.0)
				{
					next[k] = z[k];
					continue;
				}
				double change = 0.0, sum = 0.0;
				int count = 0;
				for (int d = 0; d < Dx.Length; d++)
				{
					int nx = x + Dx[d], nz = zz + Dz[d];
					if (nx < 0 || nz < 0 || nx >= width || nz >= height)
						continue;
					int m = nz * width + nx;
					if (d < 4)
					{
						sum += z[m];
						count++;
					}
					double limit = Math.Max(repose, Math.Abs(z0[k] - z0[m]) / dist[d]);
					double grade = (z[k] - z[m]) / dist[d];
					// Половина избыточного перепада на пару, поделённая на 8 соседей: устойчиво при creep ≤ 1.
					if (Math.Abs(grade) > limit)
						change -= creep * (Math.Abs(grade) - limit) * dist[d] * Math.Sign(grade) / (2.0 * Dx.Length);
				}
				// Диффузия — склоновый процесс почвы: выше головы лощины (русла она бы засыпала) и только на склонах
				// положе угла устойчивости — крутые стены генератора не оплывают.
				if (power[k] <= 0.0 && soil[k])
					change += diffusion * (sum / count - z[k]);
				next[k] = Math.Clamp(z[k] + change, z0[k] - allowed[k], z0[k] + allowed[k]);
			}
		});
		Array.Copy(next, z, z.Length);
	}

	/// <summary>Двоичная куча (высота, номер); равные высоты — по номеру клетки.</summary>
	private sealed class MinHeap
	{
		private readonly double[] _keys;
		private readonly int[] _ids;
		public int Count { get; private set; }

		public MinHeap(int capacity)
		{
			_keys = new double[capacity];
			_ids = new int[capacity];
		}

		private bool Less(int a, int b) => _keys[a] < _keys[b] || (_keys[a] == _keys[b] && _ids[a] < _ids[b]);

		private void Swap(int a, int b)
		{
			(_keys[a], _keys[b]) = (_keys[b], _keys[a]);
			(_ids[a], _ids[b]) = (_ids[b], _ids[a]);
		}

		public void Push(double key, int id)
		{
			int i = Count++;
			_keys[i] = key;
			_ids[i] = id;
			while (i > 0)
			{
				int parent = (i - 1) / 2;
				if (!Less(i, parent))
					break;
				Swap(i, parent);
				i = parent;
			}
		}

		public int Pop()
		{
			int top = _ids[0];
			Count--;
			if (Count > 0)
			{
				_keys[0] = _keys[Count];
				_ids[0] = _ids[Count];
				int i = 0;
				while (true)
				{
					int left = 2 * i + 1, right = left + 1, least = i;
					if (left < Count && Less(left, least))
						least = left;
					if (right < Count && Less(right, least))
						least = right;
					if (least == i)
						break;
					Swap(i, least);
					i = least;
				}
			}
			return top;
		}
	}
}

public partial class FastGrid
{
	/// <summary>Эрозия плана (ReliefErosion.run): hv, delta, карты area/deposit/wet байтами, номера изменённых узлов.</summary>
	public Godot.Collections.Dictionary ErodeRelief(Inputs input, double[] maskParameters, double[] parameters)
		=> TerrainErosion.Run(input, maskParameters, parameters);

	/// <summary>Узлы, где высота изменилась больше чем на threshold, м (ReliefErosion.strata_mask: пласты RockRelief).</summary>
	public byte[] ChangedMask(float[] before, float[] after, double threshold)
	{
		if (before.Length != after.Length)
			return Array.Empty<byte>();
		var mask = new byte[before.Length];
		for (int i = 0; i < before.Length; i++)
			mask[i] = Math.Abs(after[i] - (double)before[i]) > threshold ? (byte)1 : (byte)0;
		return mask;
	}

	/// <summary>Копии полей выбора леса после эрозии (StageVegetation.fields): w.elev + delta / heightScale, w.slope
	/// заново по той же формуле там, где сдвинулась высота узла или соседа, w.moist + moistGain × (W − 1/2).
	/// Мир не меняется: эти поля читает только раскладка растительности при генерации.</summary>
	public Godot.Collections.Dictionary ErodedVegetationFields(float[] elev, float[] slope, float[] moist, float[] delta,
		byte[] wet, int width, int height, double heightScale, double moistGain)
	{
		int n = width * height;
		if (elev.Length != n || slope.Length != n || moist.Length != n || delta.Length != n || wet.Length != n || heightScale <= 0.0)
			return null;
		var e = (float[])elev.Clone();
		var s = (float[])slope.Clone();
		var m = (float[])moist.Clone();
		for (int i = 0; i < n; i++)
			if (delta[i] != 0.0f)
				e[i] = (float)(elev[i] + delta[i] / heightScale);
		for (int y = 0; y < height; y++)
		{
			int row = y * width;
			int up = y == 0 ? row : row - width;
			int down = y == height - 1 ? row : row + width;
			for (int x = 0; x < width; x++)
			{
				int i = row + x;
				int left = x == 0 ? i : i - 1, right = x == width - 1 ? i : i + 1;
				if (delta[i] == 0.0f && delta[left] == 0.0f && delta[right] == 0.0f && delta[up + x] == 0.0f && delta[down + x] == 0.0f)
					continue;
				// Та же формула, что GeographyFields: центральная разность, половина, шкала уклона.
				double gx = (double)e[right] - e[left];
				double gy = (double)e[down + x] - e[up + x];
				s[i] = (float)(Math.Sqrt(gx * gx + gy * gy) * 0.5 * SlopeUnits);
			}
		}
		if (moistGain != 0.0)
			for (int i = 0; i < n; i++)
				m[i] = (float)Math.Clamp(moist[i] + moistGain * (wet[i] / (double)byte.MaxValue - 0.5), 0.0, 1.0);
		return new Godot.Collections.Dictionary { ["elev"] = e, ["slope"] = s, ["moist"] = m };
	}
}
