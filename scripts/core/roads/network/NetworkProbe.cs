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
					var r = planner.Validator.Validate(pts, cells, c["width"].AsDouble(), c["grade"].AsDouble(), 1.0, gap ? planner.Graph : null, null, 1.0);
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
}
