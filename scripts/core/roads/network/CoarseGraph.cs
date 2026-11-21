using System;
using System.Collections.Generic;

namespace Roads.Network;

/// <summary>Грубый граф (план V2, 3.5): блоки B×B клеток, в блоке — компоненты проходимых клеток (8-связность;
/// проходимо — конечная цена V2: суша и броды, без моря, озёр и небезопасных бродов). Ребро соседних компонент —
/// только при общей проходимой границе: две соседние клетки разных блоков, шаг между ними не круче maxGrade
/// (высоты поиска). Вес ребра — расстояние между центрами компонент, клеток. Дейкстра даёт D_geo и коридор поиска.</summary>
public sealed class CoarseGraph
{
	public const int B = 4;
	public int Comps => _cx.Count;
	public readonly int[] CompOf;               // клетка → компонента или -1
	private readonly List<double> _cx = new(), _cy = new();
	private readonly List<int> _x0 = new(), _y0 = new(), _x1 = new(), _y1 = new();
	private readonly List<List<(int To, double W)>> _adj = new();
	private readonly HashSet<long> _closed = new();
	private readonly int _w, _h;

	public CoarseGraph(TerrainSnapshot t, float[] cost, double maxGrade)
	{
		_w = t.W; _h = t.H;
		int W = _w, H = _h;
		CompOf = new int[t.N];
		Array.Fill(CompOf, -1);
		var stack = new Stack<int>();
		for (int by = 0; by < H; by += B)
			for (int bx = 0; bx < W; bx += B)
				for (int y = by; y < Math.Min(H, by + B); y++)
					for (int x = bx; x < Math.Min(W, bx + B); x++)
					{
						int s = y * W + x;
						if (CompOf[s] >= 0 || !float.IsFinite(cost[s])) continue;
						int id = _cx.Count;
						double sx = 0, sy = 0;
						int count = 0, x0 = int.MaxValue, y0 = int.MaxValue, x1 = 0, y1 = 0;
						CompOf[s] = id;
						stack.Push(s);
						while (stack.Count > 0)
						{
							int c = stack.Pop();
							int cx = c % W, cy = c / W;
							sx += cx + 0.5; sy += cy + 0.5; count++;
							x0 = Math.Min(x0, cx); y0 = Math.Min(y0, cy); x1 = Math.Max(x1, cx + 1); y1 = Math.Max(y1, cy + 1);
							for (int dy = -1; dy <= 1; dy++)
								for (int dx = -1; dx <= 1; dx++)
								{
									int nx = cx + dx, ny = cy + dy;
									if ((dx == 0 && dy == 0) || nx < bx || ny < by || nx >= Math.Min(W, bx + B) || ny >= Math.Min(H, by + B)) continue;
									int n = ny * W + nx;
									if (CompOf[n] >= 0 || !float.IsFinite(cost[n])) continue;
									double step = dx != 0 && dy != 0 ? Math.Sqrt(2.0) : 1.0;
									if (Math.Abs(t.Heights[n] - t.Heights[c]) > maxGrade * step + 1e-9) continue;
									if (dx != 0 && dy != 0 && !float.IsFinite(cost[cy * W + nx]) && !float.IsFinite(cost[ny * W + cx])) continue;
									CompOf[n] = id;
									stack.Push(n);
								}
						}
						_cx.Add(sx / count); _cy.Add(sy / count);
						_x0.Add(x0); _y0.Add(y0); _x1.Add(x1); _y1.Add(y1);
						_adj.Add(new List<(int, double)>());
					}
		// Рёбра: соседние клетки разных блоков, проходимый шаг (уклон по высотам поиска)
		var seen = new HashSet<long>();
		for (int y = 0; y < H; y++)
			for (int x = 0; x < W; x++)
			{
				int c = y * W + x;
				int a = CompOf[c];
				if (a < 0) continue;
				for (int k = 0; k < 4; k++)
				{
					// вправо, вниз, вниз-вправо, вниз-влево: каждая пара клеток один раз
					int dx = k == 0 ? 1 : k == 1 ? 0 : k == 2 ? 1 : -1;
					int dy = k == 0 ? 0 : 1;
					int nx = x + dx, ny = y + dy;
					if (nx < 0 || ny >= H || nx >= W) continue;
					int n = ny * W + nx;
					int b = CompOf[n];
					if (b < 0 || b == a) continue;
					double len = dx != 0 && dy != 0 ? Math.Sqrt(2.0) : 1.0;
					if (Math.Abs(t.Heights[n] - t.Heights[c]) > maxGrade * len + 1e-9) continue;
					if (dx != 0 && dy != 0)
					{
						// диагональ между двумя непроходимыми клетками — не проход
						if (!float.IsFinite(cost[y * W + nx]) && !float.IsFinite(cost[ny * W + x])) continue;
					}
					long key = Key(a, b);
					if (!seen.Add(key)) continue;
					double d = Math.Sqrt((_cx[a] - _cx[b]) * (_cx[a] - _cx[b]) + (_cy[a] - _cy[b]) * (_cy[a] - _cy[b]));
					_adj[a].Add((b, d));
					_adj[b].Add((a, d));
				}
			}
		foreach (var list in _adj) list.Sort((p, q) => p.To.CompareTo(q.To));
	}

	private static long Key(int a, int b) => (long)Math.Min(a, b) << 32 | (uint)Math.Max(a, b);

	/// <summary>Компонента клетки; клетка без неё — ближайшая проходимая в радиусе 2.</summary>
	public int CompNear(int cell)
	{
		if (CompOf[cell] >= 0) return CompOf[cell];
		int x = cell % _w, y = cell / _w, best = -1;
		double bd = double.PositiveInfinity;
		for (int dy = -2; dy <= 2; dy++)
			for (int dx = -2; dx <= 2; dx++)
			{
				int nx = x + dx, ny = y + dy;
				if (nx < 0 || ny < 0 || nx >= _w || ny >= _h) continue;
				int c = CompOf[ny * _w + nx];
				double d = dx * dx + dy * dy;
				if (c >= 0 && d < bd) { bd = d; best = c; }
			}
		return best;
	}

	public void Close(int a, int b) => _closed.Add(Key(a, b));
	public void Open() => _closed.Clear();

	/// <summary>Дейкстра от компоненты s: расстояния (клеток) и предшественники.</summary>
	public (double[] Dist, int[] Prev) Dijkstra(int s)
	{
		var dist = new double[Comps];
		var prev = new int[Comps];
		Array.Fill(dist, double.PositiveInfinity);
		Array.Fill(prev, -1);
		if (s < 0) return (dist, prev);
		var heap = new MinHeap();
		dist[s] = 0.0;
		heap.Push(0.0, s);
		while (heap.Count > 0)
		{
			var (d, u) = heap.Pop();
			if (d > dist[u]) continue;
			foreach (var (v, w) in _adj[u])
			{
				if (_closed.Count > 0 && _closed.Contains(Key(u, v))) continue;
				double nd = d + w;
				if (nd < dist[v]) { dist[v] = nd; prev[v] = u; heap.Push(nd, v); }
			}
		}
		return (dist, prev);
	}

	public static List<int> Chain(int[] prev, int t)
	{
		var chain = new List<int>();
		for (int c = t; c >= 0; c = prev[c]) chain.Add(c);
		chain.Reverse();
		return chain;
	}

	/// <summary>Прямоугольник клеток компонент цепочки.</summary>
	public CellRect Bounds(List<int> chain)
	{
		int x0 = int.MaxValue, y0 = int.MaxValue, x1 = 0, y1 = 0;
		foreach (int c in chain) { x0 = Math.Min(x0, _x0[c]); y0 = Math.Min(y0, _y0[c]); x1 = Math.Max(x1, _x1[c]); y1 = Math.Max(y1, _y1[c]); }
		return new CellRect(x0, y0, x1, y1);
	}

	/// <summary>Число компонент, связанных с s (для стенда).</summary>
	public int Reachable(int s)
	{
		var (dist, _) = Dijkstra(s);
		int n = 0;
		foreach (double d in dist) if (double.IsFinite(d)) n++;
		return n;
	}
}
