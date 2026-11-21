using System;
using System.Collections.Generic;

namespace Roads.Network;

/// <summary>Граф опубликованной сети (план V2, 3.4): оси путей людей w.trails делятся в узлах — концах участков, лежащих
/// на чужой оси (правило junction_ends измерителя, 0,05 клетки), и в точках поселений (ближайшая точка оси). Рёбра —
/// куски осей между соседними узлами, длина по оси (клетки). D_net — Дейкстра по рёбрам. Индекс отрезков — ячейки BIN.</summary>
public sealed class RoadGraph
{
	public const double OnAxis = 0.05;   // конец участка на чужой оси (road_network_metrics: junction_ends)
	public const double SettleSnap = 3.0; // точка поселения не дальше стольких клеток от оси
	private const int BIN = 10;
	/// <summary>Пересечение ближе этого (клеток) к концу ломаной — её узел примыкания, не пересечение.</summary>
	public const double EndSkip = 2.0;

	public readonly List<double> NX = new(), NY = new();
	public readonly List<bool> NSettle = new();
	public readonly List<List<int>> NEdges = new();
	public readonly List<int> EA = new(), EB = new(), ESec = new();
	public readonly List<double> ELen = new();
	public readonly List<double[]> EPts = new();   // x0, y0, x1, y1, …
	public readonly List<bool> EDead = new();
	public int[] SettleNode = Array.Empty<int>();
	private readonly double _same;
	private Dictionary<long, List<(int E, int S)>> _bins = new();

	public RoadGraph(double nodeSame) { _same = nodeSame; }

	public int Degree(int n) => NEdges[n].Count;
	public bool Junction(int n) => !NSettle[n] && NEdges[n].Count >= 3;

	/// <summary>Индекс целых опубликованных осей для сглаживания, где деление на рёбра и узлы не нужно.</summary>
	public void IndexAxes(double[] xs, double[] ys, int[] starts, int excluded = -1)
	{
		for (int s = 0; s + 1 < starts.Length; s++)
		{
			if (s == excluded) continue;
			int a = starts[s], b = starts[s + 1];
			if (b - a < 2) continue;
			var pts = new double[2 * (b - a)];
			for (int k = a; k < b; k++)
			{
				pts[2 * (k - a)] = xs[k];
				pts[2 * (k - a) + 1] = ys[k];
			}
			AddEdge(NodeAt(xs[a], ys[a], false), NodeAt(xs[b - 1], ys[b - 1], false), pts, s);
		}
		Reindex();
	}

	/// <summary>Сеть из осей: xs/ys — точки всех участков подряд, starts — начало участка (S + 1 чисел),
	/// settle — точки поселений (x, y попарно).</summary>
	public void Build(double[] xs, double[] ys, int[] starts, double[] settle)
	{
		int S = starts.Length - 1;
		var candidates = new List<(double X, double Y)>();
		for (int s = 0; s < S; s++)
		{
			if (starts[s + 1] - starts[s] < 2) continue;
			candidates.Add((xs[starts[s]], ys[starts[s]]));
			candidates.Add((xs[starts[s + 1] - 1], ys[starts[s + 1] - 1]));
		}
		// Узлы из концов (одинаковые ближе _same — один узел)
		foreach (var (x, y) in candidates) NodeAt(x, y, false);
		// На каждом участке: узлы, лежащие на его оси, — точки деления. Кандидаты — по ячейкам отрезков (BIN): узел ближе
		// OnAxis к оси или ближе _same к её концу лежит в ячейке одного из её отрезков, расширенной на 1 клетку.
		var cuts = new List<(double S, int Node)>[S];
		var near = new Dictionary<long, List<int>>();
		for (int s = 0; s < S; s++)
		{
			cuts[s] = new List<(double, int)>();
			int a = starts[s], b = starts[s + 1];
			for (int k = a + 1; k < b; k++)
			{
				int bx0 = (int)Math.Floor((Math.Min(xs[k - 1], xs[k]) - 1.0) / BIN), bx1 = (int)Math.Floor((Math.Max(xs[k - 1], xs[k]) + 1.0) / BIN);
				int by0 = (int)Math.Floor((Math.Min(ys[k - 1], ys[k]) - 1.0) / BIN), by1 = (int)Math.Floor((Math.Max(ys[k - 1], ys[k]) + 1.0) / BIN);
				for (int by = by0; by <= by1; by++)
					for (int bx = bx0; bx <= bx1; bx++)
					{
						long key = (long)by << 32 | (uint)bx;
						if (!near.TryGetValue(key, out var list)) near[key] = list = new List<int>();
						if (list.Count == 0 || list[^1] != s) list.Add(s);
					}
			}
		}
		for (int n = 0; n < NX.Count; n++)
		{
			long key = (long)(int)Math.Floor(NY[n] / BIN) << 32 | (uint)(int)Math.Floor(NX[n] / BIN);
			if (!near.TryGetValue(key, out var list)) continue;
			int last = -1;
			foreach (int s in list)
			{
				if (s == last) continue;
				last = s;
				int a = starts[s], b = starts[s + 1];
				if (b - a < 2) continue;
				var (d, at) = Project(xs, ys, a, b, NX[n], NY[n]);
				if (d < OnAxis || Hypot(NX[n] - xs[a], NY[n] - ys[a]) < _same || Hypot(NX[n] - xs[b - 1], NY[n] - ys[b - 1]) < _same)
					cuts[s].Add((at, n));
			}
		}
		// Поселения: ближайшая точка любой оси (не дальше SettleSnap)
		SettleNode = new int[settle.Length / 2];
		for (int k = 0; k < SettleNode.Length; k++)
		{
			double px = settle[2 * k], py = settle[2 * k + 1];
			double best = double.PositiveInfinity, bestAt = 0;
			int bestS = -1;
			for (int s = 0; s < S; s++)
			{
				int a = starts[s], b = starts[s + 1];
				if (b - a < 2) continue;
				var (d, at) = Project(xs, ys, a, b, px, py);
				if (d < best) { best = d; bestAt = at; bestS = s; }
			}
			if (bestS < 0 || best > SettleSnap) { SettleNode[k] = -1; continue; }
			var (qx, qy) = PointAt(xs, ys, starts[bestS], starts[bestS + 1], bestAt);
			int node = NodeAt(qx, qy, true);
			SettleNode[k] = node;
			cuts[bestS].Add((bestAt, node));
		}
		for (int s = 0; s < S; s++)
		{
			int a = starts[s], b = starts[s + 1];
			if (b - a < 2) continue;
			var list = cuts[s];
			list.Sort((p, q) => p.S != q.S ? p.S.CompareTo(q.S) : p.Node.CompareTo(q.Node));
			double total = PolyLength(xs, ys, a, b);
			int prevNode = -1;
			double prevS = 0;
			foreach (var (at, node) in list)
			{
				if (prevNode < 0) { prevNode = node; prevS = at; continue; }
				if (node == prevNode) continue;
				AddEdge(prevNode, node, Slice(xs, ys, a, b, prevS, at), s);
				prevNode = node;
				prevS = at;
			}
			_ = total;
		}
		Reindex();
	}

	private int NodeAt(double x, double y, bool settle)
	{
		for (int n = 0; n < NX.Count; n++)
			if (Hypot(NX[n] - x, NY[n] - y) < _same)
			{
				if (settle) NSettle[n] = true;
				return n;
			}
		NX.Add(x); NY.Add(y); NSettle.Add(settle); NEdges.Add(new List<int>());
		return NX.Count - 1;
	}

	private int AddEdge(int a, int b, double[] pts, int sec)
	{
		int e = EA.Count;
		EA.Add(a); EB.Add(b); ESec.Add(sec); EPts.Add(pts); ELen.Add(PolyLength(pts)); EDead.Add(false);
		NEdges[a].Add(e);
		NEdges[b].Add(e);
		return e;
	}

	public static double Hypot(double x, double y) => Math.Sqrt(x * x + y * y);

	private static (double D, double S) Project(double[] xs, double[] ys, int a, int b, double px, double py)
	{
		double best = double.PositiveInfinity, bestS = 0, run = 0;
		for (int k = a + 1; k < b; k++)
		{
			double ax = xs[k - 1], ay = ys[k - 1], dx = xs[k] - ax, dy = ys[k] - ay;
			double len2 = dx * dx + dy * dy, len = Math.Sqrt(len2);
			double t = len2 > 1e-12 ? Math.Clamp(((px - ax) * dx + (py - ay) * dy) / len2, 0.0, 1.0) : 0.0;
			double d = Hypot(ax + dx * t - px, ay + dy * t - py);
			if (d < best) { best = d; bestS = run + len * t; }
			run += len;
		}
		return (best, bestS);
	}

	private static (double X, double Y) PointAt(double[] xs, double[] ys, int a, int b, double s)
	{
		double run = 0;
		for (int k = a + 1; k < b; k++)
		{
			double dx = xs[k] - xs[k - 1], dy = ys[k] - ys[k - 1], len = Hypot(dx, dy);
			if (run + len >= s && len > 1e-12)
			{
				double t = (s - run) / len;
				return (xs[k - 1] + dx * t, ys[k - 1] + dy * t);
			}
			run += len;
		}
		return (xs[b - 1], ys[b - 1]);
	}

	private static double[] Slice(double[] xs, double[] ys, int a, int b, double s0, double s1)
	{
		var outp = new List<double>();
		var (x0, y0) = PointAt(xs, ys, a, b, s0);
		outp.Add(x0); outp.Add(y0);
		double run = 0;
		for (int k = a + 1; k < b; k++)
		{
			run += Hypot(xs[k] - xs[k - 1], ys[k] - ys[k - 1]);
			if (run > s0 + 1e-9 && run < s1 - 1e-9) { outp.Add(xs[k]); outp.Add(ys[k]); }
		}
		var (x1, y1) = PointAt(xs, ys, a, b, s1);
		outp.Add(x1); outp.Add(y1);
		return outp.ToArray();
	}

	private static double PolyLength(double[] xs, double[] ys, int a, int b)
	{
		double l = 0;
		for (int k = a + 1; k < b; k++) l += Hypot(xs[k] - xs[k - 1], ys[k] - ys[k - 1]);
		return l;
	}

	public static double PolyLength(double[] p)
	{
		double l = 0;
		for (int k = 2; k + 1 < p.Length; k += 2) l += Hypot(p[k] - p[k - 2], p[k + 1] - p[k - 1]);
		return l;
	}

	private void Reindex()
	{
		_bins = new Dictionary<long, List<(int, int)>>();
		for (int e = 0; e < EA.Count; e++)
		{
			if (EDead[e]) continue;
			var p = EPts[e];
			for (int k = 2; k + 1 < p.Length; k += 2)
			{
				int bx0 = (int)Math.Floor(Math.Min(p[k - 2], p[k]) / BIN), bx1 = (int)Math.Floor(Math.Max(p[k - 2], p[k]) / BIN);
				int by0 = (int)Math.Floor(Math.Min(p[k - 1], p[k + 1]) / BIN), by1 = (int)Math.Floor(Math.Max(p[k - 1], p[k + 1]) / BIN);
				for (int by = by0; by <= by1; by++)
					for (int bx = bx0; bx <= bx1; bx++)
					{
						long key = (long)by << 32 | (uint)bx;
						if (!_bins.TryGetValue(key, out var list)) _bins[key] = list = new List<(int, int)>();
						list.Add((e, k / 2));
					}
			}
		}
	}

	/// <summary>Ближайшая к точке ось ребра в радиусе r: (ребро, расстояние, отметка по ребру) или ребро -1.</summary>
	public (int E, double D, double S) Nearest(double px, double py, double r)
	{
		int best = -1;
		double bd = r, bs = 0;
		for (int by = (int)Math.Floor((py - r) / BIN); by <= (int)Math.Floor((py + r) / BIN); by++)
			for (int bx = (int)Math.Floor((px - r) / BIN); bx <= (int)Math.Floor((px + r) / BIN); bx++)
			{
				if (!_bins.TryGetValue((long)by << 32 | (uint)bx, out var list)) continue;
				foreach (var (e, seg) in list)
				{
					var p = EPts[e];
					double ax = p[2 * seg - 2], ay = p[2 * seg - 1], dx = p[2 * seg] - ax, dy = p[2 * seg + 1] - ay;
					double len2 = dx * dx + dy * dy;
					double t = len2 > 1e-12 ? Math.Clamp(((px - ax) * dx + (py - ay) * dy) / len2, 0.0, 1.0) : 0.0;
					double d = Hypot(ax + dx * t - px, ay + dy * t - py);
					if (d < bd || d == bd && best >= 0 && e < best)
					{
						bd = d;
						best = e;
						double run = 0;
						for (int k = 1; k < seg; k++) run += Hypot(p[2 * k] - p[2 * k - 2], p[2 * k + 1] - p[2 * k - 1]);
						bs = run + Math.Sqrt(len2) * t;
					}
				}
			}
		return (best, bd, bs);
	}

	/// <summary>Узел в точке: готовый ближе _same, иначе деление ближайшего ребра (не дальше reach); -1 — нет оси рядом.</summary>
	public int Attach(double x, double y, double reach)
	{
		for (int n = 0; n < NX.Count; n++)
			if (Hypot(NX[n] - x, NY[n] - y) < _same) return n;
		var (e, d, s) = Nearest(x, y, reach);
		if (e < 0) return -1;
		var p = EPts[e];
		int n2 = NX.Count;
		var xs = new double[p.Length / 2];
		var ys = new double[p.Length / 2];
		for (int k = 0; k < xs.Length; k++) { xs[k] = p[2 * k]; ys[k] = p[2 * k + 1]; }
		var (qx, qy) = PointAt(xs, ys, 0, xs.Length, s);
		NX.Add(qx); NY.Add(qy); NSettle.Add(false); NEdges.Add(new List<int>());
		EDead[e] = true;
		NEdges[EA[e]].Remove(e);
		NEdges[EB[e]].Remove(e);
		AddEdge(EA[e], n2, Slice(xs, ys, 0, xs.Length, 0, s), ESec[e]);
		AddEdge(n2, EB[e], Slice(xs, ys, 0, xs.Length, s, ELen[e]), ESec[e]);
		Reindex();
		return n2;
	}

	/// <summary>Новое ребро-путь V2 (точки в клетках) между узлами a и b.</summary>
	public void AddPath(int a, int b, double[] pts, int sec)
	{
		if (a < 0 || b < 0 || a == b) return;
		AddEdge(a, b, pts, sec);
		Reindex();
	}

	/// <summary>Дейкстра по рёбрам от узла s: расстояния (клетки) и входящее ребро.</summary>
	public (double[] Dist, int[] Via) Dijkstra(int s)
	{
		var dist = new double[NX.Count];
		var via = new int[NX.Count];
		Array.Fill(dist, double.PositiveInfinity);
		Array.Fill(via, -1);
		if (s < 0) return (dist, via);
		var heap = new MinHeap();
		dist[s] = 0;
		heap.Push(0, s);
		while (heap.Count > 0)
		{
			var (d, u) = heap.Pop();
			if (d > dist[u]) continue;
			foreach (int e in NEdges[u])
			{
				if (EDead[e]) continue;
				int v = EA[e] == u ? EB[e] : EA[e];
				double nd = d + ELen[e];
				if (nd < dist[v]) { dist[v] = nd; via[v] = e; heap.Push(nd, v); }
			}
		}
		return (dist, via);
	}

	/// <summary>Рёбра кратчайшего пути до t (по результату Dijkstra).</summary>
	public List<int> PathEdges(int[] via, int t)
	{
		var list = new List<int>();
		int n = t;
		while (n >= 0 && via[n] >= 0)
		{
			int e = via[n];
			list.Add(e);
			n = EA[e] == n ? EB[e] : EA[e];
		}
		list.Reverse();
		return list;
	}

	/// <summary>Пересекает ли ломаная pts одну и ту же исходную ось (участок) дважды на длине crossR клеток.
	/// Касания у концов ломаной (ближе OnAxis·4) — узлы, не пересечения.</summary>
	public bool DoubleCross(double[] pts, double crossR)
	{
		var hits = new Dictionary<int, List<(double X, double Y)>>();
		double ex0 = pts[0], ey0 = pts[1], ex1 = pts[^2], ey1 = pts[^1];
		for (int k = 2; k + 1 < pts.Length; k += 2)
		{
			double ax = pts[k - 2], ay = pts[k - 1], bx = pts[k], by = pts[k + 1];
			double r = Hypot(bx - ax, by - ay) + 1;
			var seen = new HashSet<(int, int)>();
			for (int yb = (int)Math.Floor((Math.Min(ay, by) - 1) / BIN); yb <= (int)Math.Floor((Math.Max(ay, by) + 1) / BIN); yb++)
				for (int xb = (int)Math.Floor((Math.Min(ax, bx) - 1) / BIN); xb <= (int)Math.Floor((Math.Max(ax, bx) + 1) / BIN); xb++)
				{
					if (!_bins.TryGetValue((long)yb << 32 | (uint)xb, out var list)) continue;
					foreach (var (e, seg) in list)
					{
						if (!seen.Add((e, seg))) continue;
						var p = EPts[e];
						if (!Intersect(ax, ay, bx, by, p[2 * seg - 2], p[2 * seg - 1], p[2 * seg], p[2 * seg + 1], out double hx, out double hy)) continue;
						if (Hypot(hx - ex0, hy - ey0) < EndSkip || Hypot(hx - ex1, hy - ey1) < EndSkip) continue;
						if (!hits.TryGetValue(ESec[e], out var h)) hits[ESec[e]] = h = new List<(double, double)>();
						h.Add((hx, hy));
					}
				}
			_ = r;
		}
		foreach (var list in hits.Values)
			for (int i = 0; i < list.Count; i++)
				for (int j = i + 1; j < list.Count; j++)
				{
					double d = Hypot(list[i].X - list[j].X, list[i].Y - list[j].Y);
					if (d > 1.0 && d <= crossR) return true;
				}
		return false;
	}

	private static bool Intersect(double ax, double ay, double bx, double by, double cx, double cy, double dx, double dy, out double hx, out double hy)
	{
		hx = hy = 0;
		double rx = bx - ax, ry = by - ay, sx = dx - cx, sy = dy - cy;
		double den = rx * sy - ry * sx;
		if (Math.Abs(den) < 1e-12) return false;
		double t = ((cx - ax) * sy - (cy - ay) * sx) / den;
		double u = ((cx - ax) * ry - (cy - ay) * rx) / den;
		if (t < 0 || t > 1 || u < 0 || u > 1) return false;
		hx = ax + rx * t;
		hy = ay + ry * t;
		return true;
	}

	/// <summary>Наименьшее расстояние от точки до рёбер, кроме рёбер узлов skip (для зазора валидатора).</summary>
	public double Clearance(double px, double py, double r, HashSet<int> skipEdges)
	{
		double best = double.PositiveInfinity;
		for (int by = (int)Math.Floor((py - r) / BIN); by <= (int)Math.Floor((py + r) / BIN); by++)
			for (int bx = (int)Math.Floor((px - r) / BIN); bx <= (int)Math.Floor((px + r) / BIN); bx++)
			{
				if (!_bins.TryGetValue((long)by << 32 | (uint)bx, out var list)) continue;
				foreach (var (e, seg) in list)
				{
					if (skipEdges != null && skipEdges.Contains(e)) continue;
					var p = EPts[e];
					double ax = p[2 * seg - 2], ay = p[2 * seg - 1], dx = p[2 * seg] - ax, dy = p[2 * seg + 1] - ay;
					double len2 = dx * dx + dy * dy;
					double t = len2 > 1e-12 ? Math.Clamp(((px - ax) * dx + (py - ay) * dy) / len2, 0.0, 1.0) : 0.0;
					best = Math.Min(best, Hypot(ax + dx * t - px, ay + dy * t - py));
				}
			}
		return best;
	}
}
