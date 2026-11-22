using System;
using Godot;

namespace Roads.Network;

/// <summary>Проверки ядра V2 для стенда tools/road_v2_test.gd (синтетика, без генерации мира). Ключ probe:
/// ground — земля и глубина в точках; validator — флаги нарушений на ломаных; coarse — компоненты и проход;
/// graph — D_net между поселениями и двойные пересечения; ports — порты правил V1 для сверки с GDScript.</summary>
public static class NetworkProbe
{
	public static Godot.Collections.Dictionary Run(TerrainSnapshot t, NetworkPlanner planner, Godot.Collections.Dictionary input)
	{
		string probe = input["probe"].AsString();
		var outd = new Godot.Collections.Dictionary();
		switch (probe)
		{
			case "ground":
			{
				var pts = input["points"].AsFloat64Array();
				var g = new double[pts.Length / 2];
				var d = new double[pts.Length / 2];
				for (int k = 0; k < g.Length; k++) { g[k] = t.GroundAt(pts[2 * k], pts[2 * k + 1]); d[k] = t.DepthAt(pts[2 * k], pts[2 * k + 1]); }
				outd["ground"] = g;
				outd["depth"] = d;
				break;
			}
			case "validator":
			{
				planner.Prepare(false, false);
				var flags = new Godot.Collections.Array();
				var maxes = new Godot.Collections.Array();
				foreach (var v in input["cases"].AsGodotArray())
				{
					var c = v.AsGodotDictionary();
					var pts = c["pts"].AsFloat64Array();
					var cells = c.ContainsKey("cells") ? c["cells"].AsInt32Array() : null;
					bool gap = c.ContainsKey("gap") && c["gap"].AsBool();
					var r = ValidateCase(t, planner.Validator, pts, cells, c["width"].AsDouble(), c["grade"].AsDouble(), gap ? planner.Graph : null);
					flags.Add((int)r.Flags);
					maxes.Add(r.Max);
				}
				outd["flags"] = flags;
				outd["max"] = maxes;
				break;
			}
			case "profile":
			{
				var pts = input["pts"].AsFloat64Array();
				outd["ok"] = planner.Validator.Profile(pts, input["grade"].AsDouble());
				break;
			}
			case "coarse":
			{
				planner.Prepare(false, true);
				var cg = planner.Coarse;
				outd["components"] = cg.Comps;
				outd["comp_of"] = cg.CompOf;
				var cells = input.ContainsKey("pairs") ? input["pairs"].AsInt32Array() : Array.Empty<int>();
				var linked = new Godot.Collections.Array();
				var routed = new Godot.Collections.Array();
				for (int k = 0; k + 1 < cells.Length; k += 2)
				{
					int ca = cg.CompNear(cells[k]), cb = cg.CompNear(cells[k + 1]);
					var (dist, prev) = cg.Dijkstra(ca);
					bool ok = cb >= 0 && double.IsFinite(dist[cb]);
					linked.Add(ok);
					if (!ok) { routed.Add(false); continue; }
					var path = planner.Router.Route(planner.Base, cells[k], cells[k + 1], cg.Bounds(CoarseGraph.Chain(prev, cb)), false, planner.Stats, planner.Fields.MinCost);
					routed.Add(path.Length > 0);
				}
				outd["linked"] = linked;
				outd["routed"] = routed;
				break;
			}
			case "graph":
			{
				planner.Prepare(false, false);
				var g = planner.Graph;
				int n = g.SettleNode.Length;
				var m = new double[n * n];
				for (int a = 0; a < n; a++)
				{
					var dist = g.Dijkstra(g.SettleNode[a]).Dist;
					for (int b = 0; b < n; b++) m[a * n + b] = g.SettleNode[b] >= 0 ? dist[g.SettleNode[b]] : double.PositiveInfinity;
				}
				outd["dnet"] = m;
				var dc = new Godot.Collections.Array();
				if (input.ContainsKey("polylines"))
					foreach (var v in input["polylines"].AsGodotArray()) dc.Add(g.DoubleCross(v.AsFloat64Array(), 20.0));
				outd["double_cross"] = dc;
				outd["nodes"] = g.NX.Count;
				int junctions = 0;
				for (int k = 0; k < g.NX.Count; k++) if (g.Junction(k)) junctions++;
				outd["junctions"] = junctions;
				break;
			}
			case "ports":
			{
				planner.Prepare(false, false);
				var res = new Godot.Collections.Array();
				foreach (var v in input["paths"].AsGodotArray())
				{
					var p = v.AsInt32Array();
					var (share, longest) = planner.ParallelStats(p);
					res.Add(new Godot.Collections.Dictionary
					{
						["share"] = share, ["longest"] = longest, ["rejoins"] = planner.Rejoins(p),
						["exit_a"] = planner.ExitLoop(p, false), ["exit_b"] = planner.ExitLoop(p, true),
						["beyond"] = planner.BeyondExits(p), ["core"] = planner.Core(p), ["new_ground"] = planner.NewGround(p),
					});
				}
				outd["ports"] = res;
				break;
			}
			case "refresh":
			{
				// Локальное обновление полей после принятия путей = полный пересчёт в пределах LocalRadius
				planner.Prepare(false, false);
				int bad = 0, badBase = 0, compared = 0;
				double worst = 0, worstNode = 0;
				foreach (var v in input["accept"].AsGodotArray())
				{
					planner.AcceptForTest(v.AsInt32Array());
					var near = (float[])planner.Near.Clone();
					var nodes = (float[])planner.NodeDist.Clone();
					var cost = (float[])planner.Base.Clone();
					planner.Refresh();
					int r = planner.LocalRadius;
					for (int i = 0; i < t.N; i++)
					{
						// значения могут отличаться на округление float (порядок сложения 1 и √2); решения — пороги: их сверяем точно
						if (planner.Near[i] <= r)
						{
							compared++;
							worst = Math.Max(worst, Math.Abs(near[i] - planner.Near[i]));
							if ((near[i] <= t.P.NearNet) != (planner.Near[i] <= t.P.NearNet) || (near[i] <= 2.0f) != (planner.Near[i] <= 2.0f)) bad++;
						}
						if (planner.NodeDist[i] <= r)
						{
							compared++;
							worstNode = Math.Max(worstNode, Math.Abs(nodes[i] - planner.NodeDist[i]));
							if ((nodes[i] < t.P.NodeSep) != (planner.NodeDist[i] < t.P.NodeSep) || (nodes[i] > 1.5) != (planner.NodeDist[i] > 1.5)) bad++;
						}
						if (cost[i] != planner.Base[i] && !(float.IsNaN(cost[i]) && float.IsNaN(planner.Base[i]))) badBase++;
					}
				}
				outd["compared"] = compared;
				outd["mismatch"] = bad;
				outd["mismatch_cost"] = badBase;
				outd["worst"] = new Godot.Collections.Array { worst, worstNode };
				break;
			}
			default:
				throw new ArgumentException("V2: неизвестная проверка «" + probe + "»");
		}
		outd["network_v2"] = planner.Stats.ToDictionary();
		return outd;
	}

	/// <summary>Нарушения геометрии пути (GeometryValidator). Флаги: одно ребро может нарушать несколько правил.</summary>
	[Flags]
	private enum Violation
	{
		None = 0,
		Water = 1,      // вода глубже 0,3 м на полосе (FastGrid.RoadSegment)
		Grade = 2,      // продольный уклон отрезка (RoadSegment)
		Cross = 4,      // крен поперёк полосы (RoadSegment, BENCH_CROSS)
		Profile = 8,    // уклон на окне PROFILE_BASE (RoadLine.profile_ok)
		Ford = 16,      // брод длиннее FORD_LEN или небезопасный (StageTrails._unsafe_ford)
		Radius = 32,    // радиус поворота меньше полуширины + 0,5 м
		Gap = 64,       // ближе зазора к чужому ребру вне узлов
		Bounds = 128,   // точка вне карты
	}

	// Report all the fixture violations using the same primitive checks as the generator.
	private static (Violation Flags, double Max) ValidateCase(TerrainSnapshot t, GeometryValidator validator,
		double[] pts, int[] cells, double width, double maxGrade, RoadGraph graph)
	{
		var flags = Violation.None;
		double worst = 0.0, T = t.P.Tile;
		int n = pts.Length / 2;
		for (int k = 0; k < n; k++)
			if (pts[2 * k] < 0 || pts[2 * k + 1] < 0 || pts[2 * k] > t.W || pts[2 * k + 1] > t.H) flags |= Violation.Bounds;
		if (flags != Violation.None) return (flags, 1.0);
		for (int k = 1; k < n; k++)
		{
			double ax = pts[2 * k - 2], ay = pts[2 * k - 1], bx = pts[2 * k], by = pts[2 * k + 1];
			if (validator.Segment(ax, ay, bx, by, width, maxGrade, t.P.BenchCross)) continue;
			// какое правило: вода, уклон или крен
			if (!validator.Segment(ax, ay, bx, by, 0.0, 1e9, 1e9)) flags |= Violation.Water;
			else if (!validator.Segment(ax, ay, bx, by, width, 1e9, t.P.BenchCross)) flags |= Violation.Cross;
			else flags |= Violation.Grade;
			worst = Math.Max(worst, 1.0);
		}
		if (!validator.Profile(pts, maxGrade)) { flags |= Violation.Profile; worst = Math.Max(worst, 1.0); }
		double needR = width * 0.5 * T + 0.5;
		double r = validator.MinRadius(pts);
		if (r < needR) { flags |= Violation.Radius; worst = Math.Max(worst, needR / Math.Max(r, 1e-6)); }
		if (graph != null)
		{
			double gap = (2.0 * width * 0.5 * T + 2.0 * t.P.Reach + 2.0) / T;
			double ex0 = pts[0], ey0 = pts[1], ex1 = pts[^2], ey1 = pts[^1];
			for (int k = 0; k < n; k++)
			{
				double x = pts[2 * k], y = pts[2 * k + 1];
				if (RoadGraph.Hypot(x - ex0, y - ey0) < 1.0 || RoadGraph.Hypot(x - ex1, y - ey1) < 1.0) continue;
				double d = graph.Clearance(x, y, gap, null);
				if (d < gap) { flags |= Violation.Gap; worst = Math.Max(worst, gap / Math.Max(d, 1e-6)); }
			}
		}
		if (cells != null && !validator.Ford(cells)) { flags |= Violation.Ford; worst = Math.Max(worst, 1.0); }
		return (flags, worst);
	}
}
