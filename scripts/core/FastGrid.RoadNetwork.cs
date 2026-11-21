using System;
using Godot;
using Roads.Network;

/// <summary>Сеть V2 (docs/ROAD_NETWORK_V2_PLAN_2026_11_21.md): одна точка входа PlanNetworkV2. Вызывается на экземпляре
/// поиска этапа (Pathfinder.fast(): высоты, связи и ширина прохода уже заданы), water — Heightfield.fast_water().
/// Вход — словарь плоских массивов, выход — словарь (пути клетками, виды, блок network_v2); ошибка — ключ error
/// с текстом, вызывающий делает push_error (без молчаливого отката на V1).</summary>
public partial class FastGrid
{
	internal readonly struct SearchState
	{
		public readonly int X0, Y0, X1, Y1, Budget;
		public readonly double Turn, Bend;
		public readonly long CostVersion;
		public SearchState(int x0, int y0, int x1, int y1, int budget, double turn, double bend, long costVersion)
		{ X0 = x0; Y0 = y0; X1 = x1; Y1 = y1; Budget = budget; Turn = turn; Bend = bend; CostVersion = costVersion; }
	}

	private NetworkSession _v2Session;
	internal int CorridorVersion => _corridorVersion;

	/// <summary>Двухпроходная фаска 1 / √2 (копия PropagateDistances, FastGrid.cs) только в окне x0..x1, y0..y1 поверх
	/// готового поля d: новые источники sources получают 0, значения окна — минимум старого и нового. В пределах окна
	/// это то же, что полный пересчёт Grid.distance_field со старыми и новыми источниками (сверка — road_v2_test).</summary>
	internal static void LocalChamfer(float[] d, int w, int h, int x0, int y0, int x1, int y1, System.Collections.Generic.List<int> sources)
	{
		const double Sqrt2 = 1.4142135623730951;
		x0 = Math.Max(0, x0); y0 = Math.Max(0, y0); x1 = Math.Min(w, x1); y1 = Math.Min(h, y1);
		foreach (int s in sources) d[s] = 0f;
		for (int y = y0; y < y1; y++)
			for (int x = x0; x < x1; x++)
			{
				int i = y * w + x;
				double v = d[i];
				if (x > x0) v = Math.Min(v, d[i - 1] + 1.0);
				if (y > y0)
				{
					v = Math.Min(v, d[i - w] + 1.0);
					if (x > x0) v = Math.Min(v, d[i - w - 1] + Sqrt2);
					if (x < x1 - 1) v = Math.Min(v, d[i - w + 1] + Sqrt2);
				}
				d[i] = (float)v;
			}
		for (int y = y1 - 1; y >= y0; y--)
			for (int x = x1 - 1; x >= x0; x--)
			{
				int i = y * w + x;
				double v = d[i];
				if (x < x1 - 1) v = Math.Min(v, d[i + 1] + 1.0);
				if (y < y1 - 1)
				{
					v = Math.Min(v, d[i + w] + 1.0);
					if (x < x1 - 1) v = Math.Min(v, d[i + w + 1] + Sqrt2);
					if (x > x0) v = Math.Min(v, d[i + w - 1] + Sqrt2);
				}
				d[i] = (float)v;
			}
	}

	internal SearchState SaveSearchState() => new(_winX0, _winY0, _winX1, _winY1, SearchBudget, TurnCost, BendCost, CostVersion);

	internal void RestoreSearchState(SearchState s)
	{
		_winX0 = s.X0; _winY0 = s.Y0; _winX1 = s.X1; _winY1 = s.Y1;
		SearchBudget = s.Budget; TurnCost = s.Turn; BendCost = s.Bend; CostVersion = s.CostVersion;
	}

	/// <summary>Шаг c → c + шаг k проходим для FindPath с этими входами (окно не в счёт): копия условий шага из
	/// FastGrid.Path.cs (Search.Run: цена, диагональ между непроходимыми, уклон с серединой диагонали 4/7, коридор
	/// ширины и крена, связи сооружений). Грубый граф V2 строится только по таким шагам, поэтому связность грубого
	/// графа означает путь FindPath в окне его компонент (проверка — road_v2_test).</summary>
	internal bool StepOk(float[] cost, float[] heights, byte[] links, int c, int k, double maxGrade, double maxCross)
	{
		int W = _w;
		int n = c + _off[k];
		if (float.IsPositiveInfinity(cost[c]) || float.IsPositiveInfinity(cost[n])) return false;
		bool linked = links.Length > 0 && (links[c] & (1 << k)) != 0;
		if (k >= 4 && !linked && (float.IsPositiveInfinity(cost[c + Dx[k]]) || float.IsPositiveInfinity(cost[c + Dy[k] * W]))) return false;
		double grade = Math.Abs((double)heights[n] - heights[c]) / Dl[k];
		if ((k == 4 || k == 7) && !linked)
		{
			double mid = ((double)heights[c + Dx[k]] + heights[c + Dy[k] * W]) * 0.5;
			grade = Math.Max(Math.Abs(mid - heights[c]), Math.Abs(heights[n] - mid)) * 2.0 / Dl[k];
		}
		double cross = 0.0;
		if (_hasCorridor && !linked)
		{
			grade = Math.Max(grade, _corridor[c * 16 + k * 2]);
			cross = _corridor[c * 16 + k * 2 + 1];
			if (double.IsPositiveInfinity(grade)) return false;
		}
		return grade <= maxGrade && cross <= maxCross;
	}

	/// <summary>Номер шага FastGrid (Dx, Dy) для смещения (dx, dy), -1 — не сосед.</summary>
	internal static int StepIndex(int dx, int dy) => (uint)(dx + 1) < 3 && (uint)(dy + 1) < 3 ? StepTable[(dy + 1) * 3 + dx + 1] : -1;

	private static readonly int[] StepTable = BuildStepTable();

	private static int[] BuildStepTable()
	{
		var t = new int[9];
		Array.Fill(t, -1);
		for (int k = 0; k < 8; k++) t[(Dy[k] + 1) * 3 + Dx[k] + 1] = k;
		return t;
	}

	/// <summary>Порт StageTrails._water_dist: расстояние (клеток, Grid.distance_field) до моря или озера.</summary>
	public float[] WaterDistance(int w, int h, byte[] ocean, byte[] lake)
	{
		var water = new byte[checked(w * h)];
		for (int i = 0; i < water.Length; i++) water[i] = (byte)(ocean[i] != 0 || lake[i] != 0 ? 1 : 0);
		return DistanceField(w, h, water);
	}

	/// <summary>Порт StageTrails._shore для каждой точки anchors: ближайшая клетка морского или озёрного берега
	/// (waterD ≤ 1,5) от shoreMin до shoreMax клеток, не в коридоре near, с конечной ценой; -1 — нет. Сверка — road_v2_test.</summary>
	public int[] ShoreTargets(int w, int h, int[] anchors, byte[] near, float[] cost, float[] waterD, int shoreMin, int shoreMax)
	{
		var outv = new int[anchors.Length];
		for (int k = 0; k < anchors.Length; k++)
		{
			int s = anchors[k], sx = s % w, sy = s / w, best = -1;
			double bd = double.PositiveInfinity;
			for (int y = Math.Max(0, sy - shoreMax); y < Math.Min(h, sy + shoreMax + 1); y++)
				for (int x = Math.Max(0, sx - shoreMax); x < Math.Min(w, sx + shoreMax + 1); x++)
				{
					int i = y * w + x;
					int d = (x - sx) * (x - sx) + (y - sy) * (y - sy);
					if (d < shoreMin * shoreMin || d >= bd || near[i] != 0 || float.IsPositiveInfinity(cost[i]) || waterD[i] > 1.5f) continue;
					bd = d;
					best = i;
				}
			outv[k] = best;
		}
		return outv;
	}

	/// <summary>Порт StageTrails._overlook для каждой точки anchors: самая высокая клетка суши в кольце vmin..vmax (шаг step),
	/// выше точки на rise (единицы w.h), не в коридоре near и не на краю кольца; -1 — нет. Сверка — road_v2_test.</summary>
	public int[] Overlooks(int w, int h, int[] anchors, byte[] near, float[] cost, float[] height, byte[] ocean, byte[] lake,
		double rise, int vmin, int vmax, int step)
	{
		var outv = new int[anchors.Length];
		for (int k = 0; k < anchors.Length; k++)
		{
			int s = anchors[k], sx = s % w, sy = s / w, best = -1, bestD = 0;
			double top = height[s] + rise;
			for (int y = Math.Max(0, sy - vmax); y < Math.Min(h, sy + vmax + 1); y += step)
				for (int x = Math.Max(0, sx - vmax); x < Math.Min(w, sx + vmax + 1); x += step)
				{
					int d = (x - sx) * (x - sx) + (y - sy) * (y - sy);
					if (d < vmin * vmin || d > vmax * vmax) continue;
					int i = y * w + x;
					if (height[i] <= top || near[i] != 0 || float.IsPositiveInfinity(cost[i]) || ocean[i] != 0 || lake[i] != 0) continue;
					top = height[i];
					best = i;
					bestD = d;
				}
			outv[k] = best < 0 || bestD > (vmax - 3) * (vmax - 3) ? -1 : best;
		}
		return outv;
	}

	/// <summary>Порт StageTrails._corridor: клетки ближе r (квадрат) к клеткам cells. Сверка — road_v2_test.</summary>
	public byte[] CorridorMask(int w, int h, int[] cells, int r)
	{
		var near = new byte[checked(w * h)];
		foreach (int i in cells)
		{
			if ((uint)i >= (uint)near.Length) throw new ArgumentException("CorridorMask: клетка вне карты");
			int cx = i % w, cy = i / w;
			for (int y = Math.Max(0, cy - r); y < Math.Min(h, cy + r + 1); y++)
				for (int x = Math.Max(0, cx - r); x < Math.Min(w, cx + r + 1); x++)
					near[y * w + x] = 1;
		}
		return near;
	}

	/// <summary>Фаза 3.1: линия пути (RoadLine.build) на C# — LineBuilder. water — Heightfield.fast_water() поверхности поиска.
	/// Выход: x, y, w (точки линии), fallback — профиль с поблажкой вышел круче предела; ошибка — ключ error.</summary>
	public Godot.Collections.Dictionary BuildRoadLine(Godot.Collections.Dictionary input, FastGrid water)
	{
		try
		{
			var xs = input["x"].AsFloat64Array();
			var ys = input["y"].AsFloat64Array();
			var ws = input["w"].AsFloat64Array();
			var pts = new System.Collections.Generic.List<LineBuilder.P>(xs.Length);
			for (int k = 0; k < xs.Length; k++) pts.Add(new LineBuilder.P(xs[k], ys[k], ws[k]));
			LineBuilder.V? Join(string key)
			{
				if (!input.ContainsKey(key)) return null;
				var t = input[key].AsFloat64Array();
				return t.Length == 2 ? new LineBuilder.V((float)t[0], (float)t[1]) : null;
			}
			var builder = new LineBuilder(water, input["axis"].AsByteArray(), input["W"].AsInt32(), input["H"].AsInt32());
			var line = builder.Build(pts, input["kind"].AsString(), input["smooth"].AsString(), Join("join0"), Join("join1"),
				input["relax"].AsDouble(), input["tolerance"].AsDouble(), input["road_limit"].AsDouble(), input["trail_grade"].AsDouble(),
				input["mountain_grade"].AsDouble(), input["bench_cross"].AsDouble(), input["speed"].AsDouble(), input["accel"].AsDouble());
			// фаза 3.2: сглаживание троп и горных троп (дороги road — нет)
			var smoothStats = new Godot.Collections.Dictionary();
			if (input.ContainsKey("smooth_line") && input["smooth_line"].AsBool())
			{
				builder.Biharmonic = input.ContainsKey("biharmonic") && input["biharmonic"].AsBool();
				line = builder.Smooth(line, new GeometryValidator(water, 4.0, input["profile_base"].AsDouble()));
				smoothStats["moved"] = builder.SmoothMoved;
				smoothStats["rejected"] = builder.SmoothRejected;
				smoothStats["hairpins"] = builder.Hairpins;
				smoothStats["hairpins_moved"] = builder.HairpinsMoved;
			}
			var ox = new double[line.Count];
			var oy = new double[line.Count];
			var ow = new double[line.Count];
			for (int k = 0; k < line.Count; k++) { ox[k] = line[k].X; oy[k] = line[k].Y; ow[k] = line[k].W; }
			return new Godot.Collections.Dictionary { ["x"] = ox, ["y"] = oy, ["w"] = ow, ["fallback"] = builder.Fallback, ["smooth"] = smoothStats };
		}
		catch (Exception e)
		{
			return new Godot.Collections.Dictionary { ["error"] = "LineBuilder: " + e.GetType().Name + ": " + e.Message + " " + e.StackTrace };
		}
	}

	/// <summary>mode: "loops" — петли (t-спаннер), "spurs" — ответвления; "probe" — проверки стенда road_v2_test.</summary>
	public Godot.Collections.Dictionary PlanNetworkV2(Godot.Collections.Dictionary input, FastGrid water)
	{
		try
		{
			var mode = input.ContainsKey("mode") ? input["mode"].AsString() : "";
			var snapshot = new TerrainSnapshot(input, water, this);
			// Сессия этапа: новая при session_new (первый вызов этапа) или другом номере сессии
			long id = input.ContainsKey("session") ? input["session"].AsInt64() : -1;
			if (_v2Session == null || id < 0 || _v2Session.Id != id) _v2Session = new NetworkSession { Id = id };
			var planner = new NetworkPlanner(snapshot, input, id >= 0 ? _v2Session : null);
			return mode switch
			{
				"loops" => planner.PlanLoops(),
				"spurs" => planner.PlanSpurs(),
				"nodes" => planner.CheckNodes(),
				"node_dist" => planner.NodeField(),
				"probe" => NetworkProbe.Run(snapshot, planner, input),
				_ => throw new ArgumentException("V2: неизвестный режим «" + mode + "»"),
			};
		}
		catch (Exception e)
		{
			return new Godot.Collections.Dictionary { ["error"] = "V2: " + e.GetType().Name + ": " + e.Message + "\n" + e.StackTrace };
		}
	}
}
