using System;
using Godot;

/// <summary>
/// Самые долгие циклы генерации на C#: поиск пути A* (Pathfinder) и заполнение впадин (StageHydrology).
/// Алгоритмы те же, что в GDScript, и дают тот же результат бит в бит, но в десятки раз быстрее.
/// Работает только в сборке Godot .NET, иначе генерация идёт на GDScript (см. Grid.fast_grid).
/// Арифметика повторяет GDScript: расчёт в double, значения в массивах float — во float.
/// </summary>
public partial class FastGrid : RefCounted
{
	private static readonly int[] Dx = { 1, -1, 0, 0, 1, 1, -1, -1 };
	private static readonly int[] Dy = { 0, 0, 1, -1, 1, -1, 1, -1 };
	private static readonly double[] Dl = { 1.0, 1.0, 1.0, 1.0, 1.4142135623730951, 1.4142135623730951, 1.4142135623730951, 1.4142135623730951 };

	private int _w;
	private int _h;
	private float[] _g = Array.Empty<float>();
	private int[] _from = Array.Empty<int>();
	private int[] _seen = Array.Empty<int>();
	private int[] _done = Array.Empty<int>();
	private int[] _heapIds = new int[1 << 16];
	private double[] _heapKeys = new double[1 << 16];
	private int _gen;

	/// <summary>Размер карты для FindPath.</summary>
	public void Setup(int w, int h)
	{
		_w = w;
		_h = h;
		_g = new float[w * h];
		_from = new int[w * h];
		_seen = new int[w * h];
		_done = new int[w * h];
		_gen = 0;
	}

	/// <summary>Путь от клетки s до клетки t по стоимости cost или пустой массив. Копия Pathfinder.find_path.</summary>
	public int[] FindPath(float[] cost, int s, int t)
	{
		int W = _w, H = _h, W1 = W - 1, H1 = H - 1;
		var off = new int[8];
		for (int k = 0; k < 8; k++)
			off[k] = Dy[k] * W + Dx[k];
		var g = _g;
		var from = _from;
		var seen = _seen;
		var done = _done;
		var ids = _heapIds;
		var keys = _heapKeys;
		int gn = ++_gen;
		int tx = t % W, ty = t / W;
		g[s] = 0f;
		seen[s] = gn;
		from[s] = -1;
		ids[0] = s;
		keys[0] = 0.0;
		int hn = 1;
		while (hn > 0)
		{
			int c = Pop(ids, keys, ref hn);
			if (c == t)
				break;
			if (done[c] == gn)
				continue;
			done[c] = gn;
			int cx = c % W, cy = c / W;
			double gc = g[c];
			double cc = cost[c];
			bool inner = cx > 0 && cy > 0 && cx < W1 && cy < H1;
			for (int k = 0; k < 8; k++)
			{
				int nx = cx + Dx[k], ny = cy + Dy[k];
				int n = c + off[k];
				if (!inner && (nx < 0 || ny < 0 || nx >= W || ny >= H))
					continue;
				double cn = cost[n];
				if (double.IsPositiveInfinity(cn) || done[n] == gn)
					continue;
				double ng = gc + Dl[k] * (cc + cn) * 0.5;
				if (seen[n] != gn || ng < g[n])
				{
					seen[n] = gn;
					g[n] = (float)ng;
					from[n] = c;
					int ax = Math.Abs(nx - tx), ay = Math.Abs(ny - ty);
					double key = ng + (Math.Max(ax, ay) + 0.414 * Math.Min(ax, ay)) * 0.6;
					if (hn >= ids.Length)
					{
						Array.Resize(ref ids, ids.Length * 2);
						Array.Resize(ref keys, keys.Length * 2);
					}
					Push(ids, keys, ref hn, n, key);
				}
			}
		}
		_heapIds = ids;
		_heapKeys = keys;
		if (seen[t] != gn)
			return Array.Empty<int>();
		int len = 0;
		for (int c = t; c != -1; c = from[c])
			len++;
		var path = new int[len];
		for (int c = t, i = len - 1; c != -1; c = from[c], i--)
			path[i] = c;
		return path;
	}

	/// <summary>
	/// Заполнение впадин (priority flood) от океана. Копия цикла из StageHydrology.run.
	/// Возвращает {filled, down, order, order_n}.
	/// </summary>
	public Godot.Collections.Dictionary PriorityFlood(float[] h, byte[] ocean, int W, int H)
	{
		int N = W * H;
		var filled = (float[])h.Clone();
		var down = new int[N];
		Array.Fill(down, -1);
		var order = new int[N];
		int orderN = 0;
		var closed = new bool[N];
		var ids = new int[N + 16];
		var keys = new double[N + 16];
		int hn = 0;
		for (int i = 0; i < N; i++)
		{
			if (ocean[i] != 0)
			{
				closed[i] = true;
				Push(ids, keys, ref hn, i, h[i]);
			}
		}
		while (hn > 0)
		{
			int c = Pop(ids, keys, ref hn);
			order[orderN++] = c;
			int cx = c % W, cy = c / W;
			double fc = filled[c];
			for (int k = 0; k < 8; k++)
			{
				int nx = cx + Dx[k], ny = cy + Dy[k];
				if (nx < 0 || ny < 0 || nx >= W || ny >= H)
					continue;
				int n = ny * W + nx;
				if (closed[n])
					continue;
				closed[n] = true;
				double hv = h[n];
				double up = fc + 1e-5;
				filled[n] = (float)(hv > up ? hv : up);
				down[n] = c;
				Push(ids, keys, ref hn, n, filled[n]);
			}
		}
		return new Godot.Collections.Dictionary
		{
			["filled"] = filled,
			["down"] = down,
			["order"] = order,
			["order_n"] = orderN,
		};
	}

	// Куча как MinHeap.push / MinHeap.pop
	private static void Push(int[] ids, double[] keys, ref int hn, int id, double key)
	{
		int i = hn++;
		while (i > 0)
		{
			int p = (i - 1) >> 1;
			if (keys[p] <= key)
				break;
			ids[i] = ids[p];
			keys[i] = keys[p];
			i = p;
		}
		ids[i] = id;
		keys[i] = key;
	}

	private static int Pop(int[] ids, double[] keys, ref int hn)
	{
		int top = ids[0];
		hn--;
		if (hn > 0)
		{
			int id = ids[hn];
			double kk = keys[hn];
			int i = 0;
			while (true)
			{
				int l = 2 * i + 1;
				if (l >= hn)
					break;
				int r = l + 1;
				if (r < hn && keys[r] < keys[l])
					l = r;
				if (keys[l] >= kk)
					break;
				ids[i] = ids[l];
				keys[i] = keys[l];
				i = l;
			}
			ids[i] = id;
			keys[i] = kk;
		}
		return top;
	}
}
