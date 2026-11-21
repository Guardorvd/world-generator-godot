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
