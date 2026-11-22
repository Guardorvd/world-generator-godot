using System;
using System.Collections.Generic;

namespace Roads.Network;

/// <summary>Грубый граф (план V2, 3.5): блоки B×B клеток, в блоке — компоненты проходимых клеток (8-связность;
/// проходимо — конечная цена V2: суша и броды, без моря, озёр и небезопасных бродов). Ребро соседних компонент —
/// только при общей проходимой границе: две соседние клетки разных блоков, шаг между ними проходим для FastGrid.FindPath
/// (FastGrid.StepOk: уклон, коридор ширины и крена, диагонали, связи сооружений). Вес ребра — расстояние между центрами компонент, клеток. Дейкстра даёт D_geo и коридор поиска.</summary>
public sealed class CoarseGraph
{
	public const int B = 4;
	private const double Sqrt2 = 1.4142135623730951;
	public int Comps => _cx.Count;
	public readonly int[] CompOf;               // клетка → компонента или -1
	private readonly List<double> _cx = new(), _cy = new();
	private readonly List<int> _x0 = new(), _y0 = new(), _x1 = new(), _y1 = new();
	private readonly List<List<(int To, double W)>> _adj = new();
	private readonly HashSet<long> _closed = new();
	private readonly int _w, _h;

	public CoarseGraph(TerrainSnapshot t, float[] cost, double maxGrade, double maxCross)
	{
		var router = t.Router;
		var links = t.Links;
		_w = t.W; _h = t.H;
		int W = _w, H = _h;
		CompOf = new int[t.N];
		Array.Fill(CompOf, -1);
		var stack = new int[B * B];
		var heights = t.Heights;
		for (int by = 0; by < H; by += B)
			for (int bx = 0; bx < W; bx += B)
			{
				int ex = Math.Min(W, bx + B), ey = Math.Min(H, by + B);
				for (int y = by; y < ey; y++)
					for (int x = bx; x < ex; x++)
					{
						int s = y * W + x;
						if (CompOf[s] >= 0 || !float.IsFinite(cost[s])) continue;
						int id = _cx.Count;
						double sx = 0, sy = 0;
						int count = 0, x0 = int.MaxValue, y0 = int.MaxValue, x1 = 0, y1 = 0, top = 0;
						CompOf[s] = id;
						stack[top++] = s;
						while (top > 0)
						{
							int c = stack[--top];
							int cx = c % W, cy = c / W;
							sx += cx + 0.5; sy += cy + 0.5; count++;
							if (cx < x0) x0 = cx; if (cy < y0) y0 = cy; if (cx + 1 > x1) x1 = cx + 1; if (cy + 1 > y1) y1 = cy + 1;
							for (int dy = -1; dy <= 1; dy++)
							{
								int ny = cy + dy;
								if (ny < by || ny >= ey) continue;
								for (int dx = -1; dx <= 1; dx++)
								{
									int nx = cx + dx;
									if ((dx | dy) == 0 || nx < bx || nx >= ex) continue;
									int n = ny * W + nx;
									if (CompOf[n] >= 0 || !float.IsFinite(cost[n])) continue;
									if (!router.StepOk(cost, heights, links, c, FastGrid.StepIndex(dx, dy), maxGrade, maxCross)) continue;
									CompOf[n] = id;
									stack[top++] = n;
								}
							}
						}
						_cx.Add(sx / count); _cy.Add(sy / count);
						_x0.Add(x0); _y0.Add(y0); _x1.Add(x1); _y1.Add(y1);
						_adj.Add(new List<(int, double)>(8));
					}
			}
		// Рёбра: соседние клетки разных компонент, проходимый шаг (уклон по высотам поиска). Повтор пары — поиском
		// в коротком списке соседей компоненты (их не больше нескольких десятков).
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
					if (!router.StepOk(cost, heights, links, c, FastGrid.StepIndex(dx, dy), maxGrade, maxCross)) continue;
					var la = _adj[a];
					bool known = false;
					for (int j = 0; j < la.Count && !known; j++) known = la[j].To == b;
					if (known) continue;
					double d = Math.Sqrt((_cx[a] - _cx[b]) * (_cx[a] - _cx[b]) + (_cy[a] - _cy[b]) * (_cy[a] - _cy[b]));
					la.Add((b, d));
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

	private int[] _label = Array.Empty<int>();

	/// <summary>Связны ли компоненты a и b в грубом графе (без закрытых рёбер): метки связности считаются один раз.
	/// Несвязные — Дейкстра не нужна (она обошла бы всю связную часть впустую).</summary>
	public bool Linked(int a, int b)
	{
		if (a < 0 || b < 0) return false;
		if (_label.Length != Comps)
		{
			_label = new int[Comps];
			Array.Fill(_label, -1);
			var queue = new int[Comps];
			for (int s = 0; s < Comps; s++)
			{
				if (_label[s] >= 0) continue;
				int head = 0, tail = 0;
				queue[tail++] = s;
				_label[s] = s;
				while (head < tail)
				{
					int u = queue[head++];
					foreach (var (v, _) in _adj[u])
						if (_label[v] < 0) { _label[v] = s; queue[tail++] = v; }
				}
			}
		}
		return _label[a] == _label[b];
	}

	public void Close(int a, int b) => _closed.Add(Key(a, b));
	public void Open() => _closed.Clear();

	/// <summary>Дейкстра от компоненты s: расстояния (клеток) и предшественники.</summary>
	public (double[] Dist, int[] Prev) Dijkstra(int s, int stopAt = -1)
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
			if (u == stopAt) break;
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
