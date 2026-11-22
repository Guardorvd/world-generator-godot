using System;

namespace Roads.Network;

/// <summary>Поиск ребра V2 в коридоре (план V2, 3.2): существующий FastGrid.FindPath с окном SetWindow, свой A* не пишется.
/// Окно — прямоугольник (грубый путь или концы) ± WindowMargin клеток, при неудаче ± WindowRetry. Высоты, связи
/// сооружений и ширина прохода — те, что уже заданы поиску этапа (Pathfinder). Окно, штрафы и запас поиска этапа
/// восстанавливаются после каждого вызова; кэш поиска не используется (CostVersion = -1).</summary>
public sealed class CorridorRouter
{
	private readonly TerrainSnapshot _t;
	public int Searches, Retries;
	public CorridorRouter(TerrainSnapshot t) { _t = t; }

	public int[] Route(float[] cost, int s, int t, CellRect area, bool mountain, NetStats stats, double minCost)
	{
		var P = _t.P;
		var r = _t.Router;
		var saved = r.SaveSearchState();
		long t0 = NetStats.Now();
		try
		{
			r.TurnCost = mountain ? P.TurnMountain : P.TurnTrail;
			r.BendCost = mountain ? P.BendMountain : P.BendTrail;
			r.SearchBudget = -1;
			r.CostVersion = -1;
			r.HeuristicScale = FastGrid.CharacterHeuristic(P.MulMin, minCost);
			double climb = mountain ? P.ClimbMountain : P.ClimbTrail;
			double grade = mountain ? P.MountainGrade : P.TrailGrade;
			foreach (double m in new[] { P.WindowMargin, P.WindowRetry })
			{
				var win = area.Grow((int)m, _t.W, _t.H);
				r.SetWindow(win.X0, win.Y0, win.X1, win.Y1);
				Searches++;
				var path = r.FindPath(cost, s, t, _t.Heights, climb, grade, _t.Links, true, P.BenchCross);
				if (path.Length > 0) return path;
				if (m == P.WindowMargin) Retries++;
			}
			return Array.Empty<int>();
		}
		finally
		{
			r.RestoreSearchState(saved);
			stats.Time("corridors", t0);
		}
	}
}
