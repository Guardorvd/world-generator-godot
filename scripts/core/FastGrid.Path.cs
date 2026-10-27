using System;
using System.Buffers;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Threading;
using System.Threading.Tasks;
using Godot;

/// <summary>
/// Поиск пути A* — копия Pathfinder.find_path: тот же порядок раскрытия, те же пути и тот же остаток SearchBudget.
/// С 9.9 быстрее без изменения результата:
/// - ширина прохода (set_corridor) считается для всех шагов сразу и параллельно, а не лениво внутри поиска;
///   обратный шаг берёт значение прямого — точки выборки и пары сравнений у них совпадают бит в бит;
/// - узел поиска — одна запись (g и отметка «видел / раскрыл»), массивы читаются по указателям;
/// - куча та же двоичная, с теми же сравнениями (порядок равных ключей не меняется), просеивание без ветвлений;
/// - кэш поисков: тот же запрос (версии входов, концы, пределы) не ищется второй раз;
/// - Prefetch: запасной поиск дороги заранее ищется в фоне, пока проверяется первый.
/// Результат запроса с другим запасом раскрытий восстанавливается из числа раскрытий (Resolve).
/// </summary>
public partial class FastGrid
{
	private int _w;
	private int _h;
	private readonly int[] _off = new int[8];
	private static readonly int[] Opposite = { 1, 0, 3, 2, 7, 6, 5, 4 };
	public bool ProfileSearches { get; set; }
	public int SearchBudget { get; set; } = -1;
	// Версия стоимости уникальна для снимка данных в пределах этого finder. -1 отключает кэш и prefetch.
	public long CostVersion { get; set; } = -1;
	public long HeightsVersion { get; set; }
	public long LinksVersion { get; set; }
	private long _searchCount, _expandedCount, _searchTicks, _cacheHits, _prefetchHits, _prefetchCount;
	public Godot.Collections.Dictionary SearchStats() => new()
	{
		["calls"] = _searchCount, ["expanded"] = _expandedCount,
		["native_ms"] = _searchTicks * 1000.0 / System.Diagnostics.Stopwatch.Frequency,
		["cache_hits"] = _cacheHits, ["prefetches"] = _prefetchCount, ["prefetch_hits"] = _prefetchHits
	};

	// Ширина прохода: [(c * 8 + k) * 2] — продольный уклон шага, [+1] — поперечный крен.
	private float[] _corridorGround = Array.Empty<float>();
	private float[] _corridorWater = Array.Empty<float>();
	private byte[] _corridorWet = Array.Empty<byte>();
	private double _corridorHalf;
	private float[] _corridor = Array.Empty<float>();
	private bool _hasCorridor;
	private int _corridorVersion;
	// Owned scratch buffers, reused across widths. Never write while a prefetch can read them.
	private float[] _preparedGround = Array.Empty<float>();
	private float[] _preparedWater = Array.Empty<float>();
	private byte[] _preparedWet = Array.Empty<byte>();
	private double _corridorPrepareMs, _corridorMeasureMs;
	public Godot.Collections.Dictionary CorridorStats() => new()
	{
		["prepare_ms"] = _corridorPrepareMs, ["measure_ms"] = _corridorMeasureMs,
		["input_buffer_bytes"] = (long)_preparedGround.Length * 4 + (long)_preparedWater.Length * 4 + _preparedWet.Length,
		["cache_buffer_bytes"] = (long)_corridor.Length * 4
	};
	private static readonly ParallelOptions CorridorParallel = new()
	{
		MaxDegreeOfParallelism = Math.Max(1, System.Environment.ProcessorCount)
	};

	private Search _main;
	private Search _spare;
	private const int CacheSize = 4;
	private readonly List<Found> _found = new();
	private Task<Found> _pending;
	private Query _pendingQuery;
	private volatile bool _cancel;

	private sealed class Query
	{
		public float[] Cost, Heights;
		public byte[] Links;
		public int S, T, Version;
		public long CostVersion, HeightsVersion, LinksVersion;
		public double Climb, MaxGrade, MaxCross;
		public bool UseCorridor;

		public bool Same(Query o) =>
			CostVersion >= 0 && CostVersion == o.CostVersion &&
			HeightsVersion == o.HeightsVersion && LinksVersion == o.LinksVersion &&
			S == o.S && T == o.T && Version == o.Version && UseCorridor == o.UseCorridor &&
			Climb.Equals(o.Climb) && MaxGrade.Equals(o.MaxGrade) && MaxCross.Equals(o.MaxCross);
	}

	/// <summary>Итог поиска с запасом Budget (-1 — без предела): путь, число раскрытий, остановлен ли запасом.</summary>
	private sealed class Found
	{
		public Query Q;
		public int[] Path;
		public int Expanded;
		public bool Stopped;
		public int Budget;
	}

	/// <summary>Задаёт размер карты и выделяет буферы поиска; вызывается из Pathfinder._init до FindPath.</summary>
	public void Setup(int w, int h)
	{
		CancelPrefetch();
		_w = w;
		_h = h;
		for (int k = 0; k < 8; k++)
			_off[k] = Dy[k] * w + Dx[k];
		_main = new Search(w * h);
		_spare = null;
		_found.Clear();
	}

	/// <summary>Ширина прохода, копия Pathfinder.set_corridor; считается сразу для всех шагов.</summary>
	public void SetCorridor(float[] ground, float[] water, byte[] wet, double half)
	{
		_corridorPrepareMs = 0.0;
		_corridorMeasureMs = 0.0;
		CancelPrefetch();
		_found.Clear();
		_corridorVersion++;
		_corridorGround = ground;
		_corridorWater = water;
		_corridorWet = wet;
		_corridorHalf = half;
		_hasCorridor = ground.Length > 0;
		if (!_hasCorridor)
			return;
		int count = checked(_w * _h * 16);
		if (_corridor.Length < count)
		{
			var previous = _corridor;
			_corridor = ArrayPool<float>.Shared.Rent(count);
			if (previous.Length > 0)
				ArrayPool<float>.Shared.Return(previous);
		}
		// Полосы по 32 строки: обратный шаг пишется в соседнюю строку, общие строки полос — только на их краях.
		// Каждая пара направленных шагов имеет одного писателя; Parallel.For ждёт готовности всех полос.
		long started = System.Diagnostics.Stopwatch.GetTimestamp();
		int blocks = (_h + CorridorRows - 1) / CorridorRows;
		Parallel.For(0, blocks, CorridorParallel, MeasureRows);
		_corridorMeasureMs = (System.Diagnostics.Stopwatch.GetTimestamp() - started) * 1000.0 / System.Diagnostics.Stopwatch.Frequency;
	}

	/// <summary>Exact StageTrails._route_surface input conversion, followed by SetCorridor.
	/// Raw inputs are read-only. Scratch storage belongs to this finder and is never published to callers.</summary>
	public void SetWorldCorridor(float[] groundMeters, float[] waterMeters, byte[] ocean, byte[] lake,
		byte[] river, double tile, double half)
	{
		int n = checked(_w * _h);
		if (groundMeters.Length != n || waterMeters.Length != n || ocean.Length != n || lake.Length != n || river.Length != n)
			throw new ArgumentException("Corridor inputs must match the finder dimensions.");
		if (!(tile > 0.0) || !double.IsFinite(tile)) throw new ArgumentOutOfRangeException(nameof(tile));
		CancelPrefetch(); // joins the reader before modifying buffers reused from the previous width
		long started = System.Diagnostics.Stopwatch.GetTimestamp();
		if (_preparedGround.Length != n)
		{
			_preparedGround = new float[n];
			_preparedWater = new float[n];
			_preparedWet = new byte[n];
		}
		Parallel.For(0, _h, CorridorParallel, y =>
		{
			for (int i = y * _w, end = i + _w; i < end; i++)
			{
				_preparedGround[i] = (float)(groundMeters[i] / tile);
				_preparedWater[i] = (float)((Math.Max(0.0, waterMeters[i]) - 0.1) / tile);
				_preparedWet[i] = (byte)(ocean[i] != 0 || lake[i] != 0 || river[i] != 0 ? 1 : 0);
			}
		});
		double prepareMs = (System.Diagnostics.Stopwatch.GetTimestamp() - started) * 1000.0 / System.Diagnostics.Stopwatch.Frequency;
		SetCorridor(_preparedGround, _preparedWater, _preparedWet, half);
		_corridorPrepareMs = prepareMs;
	}

	private const int CorridorRows = 32;

	[MethodImpl(MethodImplOptions.AggressiveOptimization)]
	private void MeasureRows(int block)
	{
		int W = _w, H = _h;
		var corridor = _corridor;
		for (int y = block * CorridorRows; y < Math.Min(H, block * CorridorRows + CorridorRows); y++)
			for (int x = 0; x < W; x++)
			{
				int c = y * W + x;
				for (int k = 0; k < 8; k += 2)
				{
					int nx = x + Dx[k], ny = y + Dy[k];
					if (nx < 0 || ny < 0 || nx >= W || ny >= H)
						continue;
					MeasureCorridor(c, k, out double grade, out double cross);
					int a = (c * 8 + k) * 2, b = ((ny * W + nx) * 8 + Opposite[k]) * 2;
					corridor[a] = corridor[b] = (float)grade;
					corridor[a + 1] = corridor[b + 1] = (float)cross;
				}
			}
	}

	[MethodImpl(MethodImplOptions.AggressiveInlining)]
	private double CorridorHeight(double x, double y)
	{
		x = Math.Clamp(x, 0.0, _w - 1.001);
		y = Math.Clamp(y, 0.0, _h - 1.001);
		int ix = (int)Math.Floor(x), iy = (int)Math.Floor(y);
		double tx = x - ix, ty = y - iy;
		int a = iy * _w + ix;
		var h = _corridorGround;
		if (tx + ty <= 1.0)
			return h[a] + ((double)h[a + 1] - h[a]) * tx + ((double)h[a + _w] - h[a]) * ty;
		int d = a + _w + 1;
		return h[d] + ((double)h[d - 1] - h[d]) * (1.0 - tx) + ((double)h[d - _w] - h[d]) * (1.0 - ty);
	}

	/// <summary>Продольный уклон и крен шага c → c + _off[k]; копия Pathfinder._measure_corridor.</summary>
	[MethodImpl(MethodImplOptions.AggressiveOptimization)]
	private void MeasureCorridor(int c, int k, out double grade, out double cross)
	{
		int n = c + _off[k];
		grade = 0.0;
		cross = 0.0;
		if ((_corridorWet[c] == 0 || _corridorGround[c] >= _corridorWater[c]) &&
			(_corridorWet[n] == 0 || _corridorGround[n] >= _corridorWater[n]))
		{
			double nx = -Dy[k] / Dl[k] * _corridorHalf, ny = Dx[k] / Dl[k] * _corridorHalf;
			Span<double> previous = stackalloc double[3];
			for (int j = 0; j < 5; j++)
			{
				double left = 0.0, right = 0.0;
				for (int side = 0; side < 3; side++)
				{
					double x = c % _w + Dx[k] * j * 0.25 + nx * (side - 1);
					double y = c / _w + Dy[k] * j * 0.25 + ny * (side - 1);
					double h = CorridorHeight(x, y);
					int cell = Math.Clamp((int)Math.Floor(y + 0.5), 0, _h - 1) * _w + Math.Clamp((int)Math.Floor(x + 0.5), 0, _w - 1);
					if (_corridorWater[cell] > h)
					{
						// Every consumer rejects an infinite grade before reading cross.
						grade = double.PositiveInfinity;
						return;
					}
					if (j > 0) grade = Math.Max(grade, Math.Abs(h - previous[side]) * 4.0 / Dl[k]);
					previous[side] = h;
					if (side == 0) left = h;
					if (side == 2) right = h;
				}
				cross = Math.Max(cross, Math.Max(Math.Abs(right - previous[1]), Math.Abs(left - previous[1])) / _corridorHalf);
			}
		}
	}

	private Query MakeQuery(float[] cost, int s, int t, float[] heights, double climb, double maxGrade, byte[] links, bool useCorridor, double maxCrossGrade) =>
		new()
		{
			Cost = cost, S = s, T = t, Heights = heights, Climb = climb, MaxGrade = maxGrade, Links = links,
			UseCorridor = useCorridor, MaxCross = maxCrossGrade, Version = _corridorVersion,
			CostVersion = CostVersion, HeightsVersion = HeightsVersion, LinksVersion = LinksVersion
		};

	/// <summary>Путь от клетки s до клетки t по стоимости cost или пустой массив. Копия Pathfinder.find_path.</summary>
	public int[] FindPath(float[] cost, int s, int t, float[] heights, double climb, double maxGrade, byte[] links, bool useCorridor, double maxCrossGrade)
	{
		long started = ProfileSearches ? System.Diagnostics.Stopwatch.GetTimestamp() : 0;
		var q = MakeQuery(cost, s, t, heights, climb, maxGrade, links, useCorridor, maxCrossGrade);
		int budget = SearchBudget;
		int[] path = null;
		if (_pending != null && _pendingQuery.Same(q))
		{
			var found = _pending.Result;
			_pending = null;
			_pendingQuery = null;
			if (found != null)
			{
				Remember(found);
				path = Resolve(found, budget);
				if (path != null) _prefetchHits++;
			}
		}
		if (path == null)
			foreach (var found in _found)
				if (found.Q.Same(q) && (path = Resolve(found, budget)) != null)
				{
					_cacheHits++;
					break;
				}
		if (path == null)
		{
			var found = _main.Run(this, q, budget, false);
			_expandedCount += found.Expanded;
			Remember(found);
			path = Resolve(found, budget);
		}
		if (ProfileSearches)
		{
			_searchCount++;
			_searchTicks += System.Diagnostics.Stopwatch.GetTimestamp() - started;
		}
		return path;
	}

	/// <summary>Начать в фоне тот же поиск, что FindPath с этими аргументами и запасом не больше cap.
	/// FindPath с совпадающим запросом дождётся его и возьмёт результат; иначе он не используется.</summary>
	public void Prefetch(float[] cost, int s, int t, float[] heights, double climb, double maxGrade, byte[] links, bool useCorridor, double maxCrossGrade, int cap)
	{
		CancelPrefetch();
		if (cap == 0 || CostVersion < 0)
			return;
		_spare ??= new Search(_w * _h);
		var q = MakeQuery(cost, s, t, heights, climb, maxGrade, links, useCorridor, maxCrossGrade);
		var search = _spare;
		_cancel = false;
		_pendingQuery = q;
		// Отдельный поток (LongRunning): в общем пуле .NET поиск мог бы ждать очереди, а FindPath — его.
		_pending = Task.Factory.StartNew(() => search.Run(this, q, cap, true), CancellationToken.None,
			TaskCreationOptions.LongRunning, TaskScheduler.Default);
		_prefetchCount++;
	}

	/// <summary>Остановить фоновый поиск, если его результат больше не нужен.</summary>
	public void CancelPrefetch()
	{
		if (_pending == null)
			return;
		_cancel = true;
		_pending.Wait();
		_pending = null;
		_pendingQuery = null;
	}

	/// <summary>Отпустить буферы и кэш поиска после этапа троп, вернуть полосу в пул без принудительной сборки GC.</summary>
	public void Release()
	{
		CancelPrefetch();
		_found.Clear();
		_main = null;
		_spare = null;
		if (_corridor.Length > 0)
			ArrayPool<float>.Shared.Return(_corridor);
		_corridor = Array.Empty<float>();
		_corridorGround = Array.Empty<float>();
		_corridorWater = Array.Empty<float>();
		_corridorWet = Array.Empty<byte>();
		_preparedGround = Array.Empty<float>();
		_preparedWater = Array.Empty<float>();
		_preparedWet = Array.Empty<byte>();
		_hasCorridor = false;
	}

	private void Remember(Found found)
	{
		// Поиск завершён: скалярному ключу больше не нужны мегабайтные копии входных массивов.
		found.Q.Cost = null;
		found.Q.Heights = null;
		found.Q.Links = null;
		if (found.Q.CostVersion < 0)
			return;
		if (_found.Count >= CacheSize)
			_found.RemoveAt(0);
		_found.Add(found);
	}

	/// <summary>Результат поиска с запасом budget по поиску с запасом found.Budget и SearchBudget после него;
	/// null, если по found его не узнать. Как в find_path: каждое раскрытие тратит единицу запаса,
	/// на нуле поиск сдаётся (пустой путь, запас 0), а снятая с кучи цель или уже раскрытая клетка запас не тратят.</summary>
	private int[] Resolve(Found found, int budget)
	{
		if (found.Stopped)
		{
			// Раскрытий нужно больше found.Budget: меньший запас тоже кончится.
			if (budget < 0 || budget > found.Budget)
				return null;
			SearchBudget = 0;
			return Array.Empty<int>();
		}
		if (budget < 0)
			return found.Path;
		if (found.Expanded > budget)
		{
			SearchBudget = 0;
			return Array.Empty<int>();
		}
		SearchBudget = budget - found.Expanded;
		return found.Path;
	}

	private struct Node
	{
		public float G;
		public int Mark; // 2 * номер поиска — клетка в куче, 2 * номер + 1 — раскрыта
	}

	private struct Item
	{
		public double Key;
		public int Id;
	}

	/// <summary>Буферы одного поиска; у фонового поиска свои.</summary>
	private sealed unsafe class Search
	{
		private readonly Node[] _nodes;
		private readonly int[] _from;
		private Item[] _heap = new Item[1 << 16];
		private int _gen;

		public Search(int n)
		{
			_nodes = new Node[n];
			_from = new int[n];
		}

		/// <summary>a > b ? a : b — для конечных неотрицательных значений здесь то же, что Math.Max, но без разбора NaN.</summary>
		[MethodImpl(MethodImplOptions.AggressiveInlining)]
		private static double Max(double a, double b) => a > b ? a : b;

		[MethodImpl(MethodImplOptions.AggressiveOptimization)]
		public Found Run(FastGrid grid, Query q, int budget, bool cancellable)
		{
			var found = new Found { Q = q, Budget = budget, Path = Array.Empty<int>() };
			float[] cost = q.Cost, heights = q.Heights;
			int s = q.S, t = q.T;
			double climb = q.Climb, maxGrade = q.MaxGrade, maxCrossGrade = q.MaxCross;
			bool terrain = heights.Length > 0 && (climb > 0.0 || maxGrade < double.PositiveInfinity);
			bool corridor = q.UseCorridor && grid._hasCorridor;
			bool hasLinks = q.Links.Length > 0;
			int W = grid._w, H = grid._h, W1 = W - 1, H1 = H - 1;
			int gn = ++_gen;
			int seenMark = gn * 2, doneMark = gn * 2 + 1;
			int tx = t % W, ty = t / W;
			int expanded = 0;
			int* off = stackalloc int[8];
			int* dxs = stackalloc int[8];
			int* dys = stackalloc int[8];
			double* dl = stackalloc double[8];
			for (int k = 0; k < 8; k++)
			{
				off[k] = grid._off[k];
				dxs[k] = Dx[k];
				dys[k] = Dy[k];
				dl[k] = Dl[k];
			}
			var heap = _heap;
			int hn = 1;
			fixed (Node* nodes = _nodes)
			fixed (int* from = _from)
			fixed (float* costs = cost)
			fixed (float* hs = heights)
			fixed (byte* links = q.Links)
			fixed (float* corr = grid._corridor)
			{
				nodes[s].G = 0f;
				nodes[s].Mark = seenMark;
				from[s] = -1;
				heap[0].Id = s;
				heap[0].Key = 0.0;
				while (hn > 0)
				{
					int c = Pop(heap, ref hn);
					if (c == t)
						break;
					Node* nc = nodes + c;
					if (nc->Mark == doneMark)
						continue;
					if (expanded == budget)
					{
						found.Expanded = expanded;
						found.Stopped = true;
						return found;
					}
					expanded++;
					if (cancellable && (expanded & 1023) == 0 && grid._cancel)
						return null;
					nc->Mark = doneMark;
					int cx = c % W, cy = c / W;
					double gc = nc->G;
					double cc = costs[c];
					bool inner = cx > 0 && cy > 0 && cx < W1 && cy < H1;
					int linkBits = hasLinks ? links[c] : 0;
					float* ce = corr + c * 16;
					for (int k = 0; k < 8; k++)
					{
						int nx = cx + dxs[k], ny = cy + dys[k];
						if (!inner && (nx < 0 || ny < 0 || nx >= W || ny >= H))
							continue;
						int n = c + off[k];
						double cn = costs[n];
						Node* nn = nodes + n;
						if (double.IsPositiveInfinity(cn) || nn->Mark == doneMark)
							continue;
						double step = (cc + cn) * 0.5;
						bool linked = (linkBits & (1 << k)) != 0;
						if (k >= 4 && !linked)
						{
							double ca = costs[c + dxs[k]], cb = costs[c + dys[k] * W];
							if (double.IsPositiveInfinity(ca) || double.IsPositiveInfinity(cb))
								continue;
							step = Max(step, (ca + cb) * 0.5);
						}
						if (terrain)
						{
							double grade = Math.Abs((double)hs[n] - hs[c]) / dl[k];
							if ((k == 4 || k == 7) && !linked)
							{
								double mid = ((double)hs[c + dxs[k]] + hs[c + dys[k] * W]) * 0.5;
								grade = Max(Math.Abs(mid - hs[c]), Math.Abs(hs[n] - mid)) * 2.0 / dl[k];
							}
							double crossGrade = 0.0;
							if (corridor && !linked)
							{
								grade = Max(grade, ce[k * 2]);
								crossGrade = ce[k * 2 + 1];
								if (double.IsPositiveInfinity(grade))
									continue;
							}
							if (grade > maxGrade || crossGrade > maxCrossGrade)
								continue;
							double steep = Max(0.0, grade - 0.22);
							step += climb * (grade * grade + 4.0 * steep * steep + crossGrade * crossGrade);
						}
						double ng = gc + dl[k] * step;
						if (nn->Mark != seenMark || ng < nn->G)
						{
							nn->Mark = seenMark;
							nn->G = (float)ng;
							from[n] = c;
							int ax = Math.Abs(nx - tx), ay = Math.Abs(ny - ty);
							double key = ng + (Math.Max(ax, ay) + 0.414 * Math.Min(ax, ay)) * HCost;
							if (hn >= heap.Length)
							{
								Array.Resize(ref heap, heap.Length * 2);
								_heap = heap;
							}
							Push(heap, ref hn, n, key);
						}
					}
				}
				found.Expanded = expanded;
				if (nodes[t].Mark != seenMark && nodes[t].Mark != doneMark)
					return found;
				int len = 0;
				for (int c = t; c != -1; c = from[c])
					len++;
				var path = new int[len];
				for (int c = t, i = len - 1; c != -1; c = from[c], i--)
					path[i] = c;
				found.Path = path;
				return found;
			}
		}

		[MethodImpl(MethodImplOptions.AggressiveInlining)]
		private static void Push(Item[] heap, ref int hn, int id, double key)
		{
			int i = hn++;
			while (i > 0)
			{
				int p = (i - 1) >> 1;
				if (heap[p].Key <= key)
					break;
				heap[i] = heap[p];
				i = p;
			}
			heap[i].Id = id;
			heap[i].Key = key;
		}

		/// <summary>Те же сравнения, что FastGrid.Pop: из равных сыновей — левый, остановка на сыне не меньше.</summary>
		[MethodImpl(MethodImplOptions.AggressiveInlining)]
		private static int Pop(Item[] heap, ref int hn)
		{
			int top = heap[0].Id;
			int size = --hn;
			if (size > 0)
			{
				Item last = heap[size];
				double kk = last.Key;
				// За концом кучи — +∞: правый сын за концом не выбирается, как при проверке r < hn.
				heap[size].Key = double.PositiveInfinity;
				int i = 0;
				fixed (Item* h = heap)
				{
					while (true)
					{
						int l = 2 * i + 1;
						if (l >= size)
							break;
						l += h[l + 1].Key < h[l].Key ? 1 : 0;
						if (h[l].Key >= kk)
							break;
						h[i] = h[l];
						i = l;
					}
					h[i] = last;
				}
			}
			return top;
		}
	}
}
