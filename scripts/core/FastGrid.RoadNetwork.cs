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
	internal static int StepIndex(int dx, int dy)
	{
		for (int k = 0; k < 8; k++) if (Dx[k] == dx && Dy[k] == dy) return k;
		return -1;
	}

	/// <summary>Порт StageTrails._water_dist: расстояние (клеток, Grid.distance_field) до моря или озера.</summary>
	public float[] WaterDistance(int w, int h, byte[] ocean, byte[] lake)
	{
		var water = new byte[checked(w * h)];
		for (int i = 0; i < water.Length; i++) water[i] = (byte)(ocean[i] != 0 || lake[i] != 0 ? 1 : 0);
		return DistanceField(w, h, water);
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

	/// <summary>mode: "loops" — петли (t-спаннер), "spurs" — ответвления; "probe" — проверки стенда road_v2_test.</summary>
	public Godot.Collections.Dictionary PlanNetworkV2(Godot.Collections.Dictionary input, FastGrid water)
	{
		try
		{
			var mode = input.ContainsKey("mode") ? input["mode"].AsString() : "";
			var snapshot = new TerrainSnapshot(input, water, this);
			var planner = new NetworkPlanner(snapshot, input);
			return mode switch
			{
				"loops" => planner.PlanLoops(),
				"spurs" => planner.PlanSpurs(),
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
