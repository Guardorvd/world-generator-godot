using System;
using System.Collections.Generic;
using Godot;

namespace Roads.Network;

/// <summary>Планировщик V2 (план V2, 3.4–3.6): петли по t-спаннеру и ответвления (берег, смотровые, вершины) поверх
/// опубликованной сети V1. Каждое принятое ребро сразу становится частью своей копии сети (Owner, Mask, граф, цена),
/// следующие кандидаты видят его. Публикует GDScript (StageTrails._add_trail) в порядке принятия.
/// Правила V1, перенесённые сюда портом (с источником): _parallel_stats, _rejoins, _exit_loop, _beyond_exits, _core,
/// _new_ground; сверка с GDScript — стенд road_v2_test.</summary>
public sealed class NetworkPlanner
{
	private readonly TerrainSnapshot _t;
	private readonly Params _p;
	private readonly Godot.Collections.Dictionary _in;
	public readonly NetStats Stats = new();
	public readonly GeomorphologyFields Fields;
	public readonly GeometryValidator Validator;
	public readonly CorridorRouter Router;
	public RoadGraph Graph;
	public CoarseGraph Coarse;
	public float[] Base = Array.Empty<float>();     // цена V2 с правилами узлов (дороже у узлов и поселений)
	private float[] _scratch = Array.Empty<float>();
	private byte[] _mark = Array.Empty<byte>();
	public float[] Near = Array.Empty<float>();     // клеток до сети (StageTrails._net_near)
	public float[] NodeDist = Array.Empty<float>(); // клеток до узла сети (развилки, не поселения)
	public float[] SettleDist = Array.Empty<float>();
	private readonly int[] _settle;
	private readonly byte[] _remote;
	private int _virtual;

	private readonly NetworkSession _session;

	public NetworkPlanner(TerrainSnapshot t, Godot.Collections.Dictionary input, NetworkSession session = null)
	{
		_session = session;
		_t = t;
		_p = t.P;
		_in = input;
		Fields = new GeomorphologyFields(t);
		Validator = new GeometryValidator(t);
		Router = new CorridorRouter(t);
		_settle = input.ContainsKey("settle") ? input["settle"].AsInt32Array() : Array.Empty<int>();
		_remote = input.ContainsKey("remote") ? input["remote"].AsByteArray() : new byte[_settle.Length];
		if (_remote.Length != _settle.Length) throw new ArgumentException("V2: remote не по числу поселений");
		foreach (int s in _settle) if ((uint)s >= (uint)t.N) throw new ArgumentException("V2: клетка поселения вне карты");
		_virtual = t.Sections;
	}

	// ---------------------------------------------------------------- подготовка

	public void Prepare(bool ridge, bool coarse, double coarseGrade = double.NaN)
	{
		Fields.Build(ridge, Stats, _session);
		long t0 = NetStats.Now();
		Graph = new RoadGraph(_p.NodeSame);
		var settlePts = new double[_settle.Length * 2];
		for (int k = 0; k < _settle.Length; k++) { settlePts[2 * k] = _t.X(_settle[k]); settlePts[2 * k + 1] = _t.Y(_settle[k]); }
		Graph.Build(_in["sec_x"].AsFloat64Array(), _in["sec_y"].AsFloat64Array(), _in["sec_start"].AsInt32Array(), settlePts);
		var src = new byte[_t.N];
		foreach (int s in _settle) src[s] = 1;
		SettleDist = _t.Router.DistanceField(_t.W, _t.H, src);
		Refresh();
		Stats.Time("graph", t0);
		if (coarse)
		{
			t0 = NetStats.Now();
			double grade = double.IsNaN(coarseGrade) ? _p.TrailGrade : coarseGrade;
			// Ключ грубого графа: проходимость цены, высоты и связи поиска, версия коридора ширины, пределы
			ulong key = NetworkSession.Hash(NetworkSession.Hash(NetworkSession.Seed, _t.Heights), _t.Links);
			key = NetworkSession.Hash(NetworkSession.Hash(NetworkSession.Hash(key, _t.Router.CorridorVersion), BitConverter.DoubleToInt64Bits(grade)),
				BitConverter.DoubleToInt64Bits(_p.BenchCross));
			for (int i = 0; i < _t.N; i++) if (!float.IsFinite(Base[i])) key = NetworkSession.Hash(key, i);
			if (_session != null && _session.Coarse != null && _session.CoarseKey == key)
			{
				Coarse = _session.Coarse;
				Stats.Count("coarse_cached");
			}
			else
			{
				Coarse = new CoarseGraph(_t, Base, grade, _p.BenchCross);
				if (_session != null) { _session.Coarse = Coarse; _session.CoarseKey = key; }
			}
			Stats.Count("coarse_components", Coarse.Comps);
			Stats.Time("coarse", t0);
		}
	}

	/// <summary>Радиус локального обновления полей: дальше значения Near и NodeDist не читаются правилами
	/// (NearNet, NodeSep, полоса цены 2 клетки).</summary>
	public int LocalRadius => (int)Math.Ceiling(Math.Max(_p.NearNet, _p.NodeSep)) + 2;

	/// <summary>После принятого пути: Near и NodeDist — локально (фаска в окне вокруг новых клеток и новых развилок),
	/// цена с правилами узлов — только в этом окне. В пределах LocalRadius то же, что полный Refresh (road_v2_test).</summary>
	public void RefreshLocal(List<int> cells, List<int> junctions, int[] path)
	{
		long t0 = NetStats.Now();
		int W = _t.W, H = _t.H, m = LocalRadius + 2;
		int x0 = int.MaxValue, y0 = int.MaxValue, x1 = 0, y1 = 0;
		foreach (var list in new[] { cells, junctions, new List<int>(path) })
			foreach (int c in list)
			{
				x0 = Math.Min(x0, c % W); y0 = Math.Min(y0, c / W); x1 = Math.Max(x1, c % W + 1); y1 = Math.Max(y1, c / W + 1);
			}
		if (x0 == int.MaxValue) { Stats.Time("refresh", t0); return; }
		x0 = Math.Max(0, x0 - m); y0 = Math.Max(0, y0 - m); x1 = Math.Min(W, x1 + m); y1 = Math.Min(H, y1 + m);
		if (cells.Count > 0) FastGrid.LocalChamfer(Near, W, H, x0, y0, x1, y1, cells);
		if (junctions.Count > 0) FastGrid.LocalChamfer(NodeDist, W, H, x0, y0, x1, y1, junctions);
		var raw = Fields.Raw;
		for (int y = y0; y < y1; y++)
			for (int x = x0; x < x1; x++)
			{
				int i = y * W + x;
				float c = raw[i];
				if (_t.Owner[i] < 0 && float.IsFinite(c) && Near[i] <= 2.0f && (NodeDist[i] < _p.NodeSep || SettleDist[i] < _p.ExitR))
					c = (float)(c * _p.ExitMul);
				Base[i] = c;
				_scratch[i] = c;
			}
		Stats.Time("refresh", t0);
	}

	/// <summary>Клетка узла графа (как в Refresh).</summary>
	private int NodeCell(int n) =>
		Math.Clamp((int)Math.Floor(Graph.NY[n]), 0, _t.H - 1) * _t.W + Math.Clamp((int)Math.Floor(Graph.NX[n]), 0, _t.W - 1);

	/// <summary>Поля расстояний до сети и узлов и цена с правилами узлов — полный пересчёт (подготовка, стенд).</summary>
	public void Refresh()
	{
		long t0 = NetStats.Now();
		int N = _t.N, W = _t.W, H = _t.H;
		var net = new byte[N];
		for (int i = 0; i < N; i++) net[i] = (byte)(_t.Owner[i] >= 0 ? 1 : 0);
		Near = _t.Router.DistanceField(W, H, net);
		var nodes = new byte[N];
		for (int n = 0; n < Graph.NX.Count; n++)
			if (Graph.Junction(n))
			{
				int x = Math.Clamp((int)Math.Floor(Graph.NX[n]), 0, W - 1), y = Math.Clamp((int)Math.Floor(Graph.NY[n]), 0, H - 1);
				nodes[y * W + x] = 1;
			}
		NodeDist = _t.Router.DistanceField(W, H, nodes);
		if (Base.Length != N) { Base = new float[N]; _scratch = new float[N]; }
		var raw = Fields.Raw;
		for (int i = 0; i < N; i++)
		{
			float c = raw[i];
			// Новая земля вплотную к сети у узла или поселения дороже: съезд там нарушил бы правила узлов (3.4)
			if (_t.Owner[i] < 0 && float.IsFinite(c) && Near[i] <= 2.0f && (NodeDist[i] < _p.NodeSep || SettleDist[i] < _p.ExitR))
				c = (float)(c * _p.ExitMul);
			Base[i] = c;
		}
		Array.Copy(Base, _scratch, N);
		Stats.Time("refresh", t0);
	}

	// ---------------------------------------------------------------- порты правил V1 (StageTrails)

	/// <summary>Порт StageTrails._parallel_stats: (доля, самый длинный подряд участок) новых клеток пути ближе NEAR_NET
	/// к сети на той же высоте (LEVEL_GAP).</summary>
	public (double Share, int Longest) ParallelStats(int[] p)
	{
		int fresh = 0, side = 0, run = 0, longest = 0, W = _t.W, H = _t.H;
		int r = (int)Math.Ceiling(_p.NearNet);
		double scale = _p.HeightScale * _p.Tile;
		for (int k = _p.NodeCells; k < p.Length - _p.NodeCells; k++)
		{
			int i = p[k];
			if (_t.Owner[i] >= 0) { run = 0; continue; }
			fresh++;
			double level = double.PositiveInfinity;
			if (Near[i] <= _p.NearNet)
			{
				int x = i % W, y = i / W;
				double reach = Near[i] + 0.75;
				for (int dy = -r; dy <= r; dy++)
					for (int dx = -r; dx <= r; dx++)
					{
						int nx = x + dx, ny = y + dy;
						if (nx < 0 || ny < 0 || nx >= W || ny >= H || dx * dx + dy * dy > reach * reach) continue;
						int j = ny * W + nx;
						if (_t.Owner[j] >= 0) level = Math.Min(level, Math.Abs((double)_t.Hw[j] - _t.Hw[i]) * scale);
					}
			}
			if (level < _p.LevelGap) { side++; run++; longest = Math.Max(longest, run); }
			else run = 0;
		}
		return (fresh > 0 ? (double)side / fresh : 0.0, longest);
	}

	/// <summary>Порт StageTrails._rejoins: путь дважды касается одного участка ближе REJOIN_GAP клеток.</summary>
	public bool Rejoins(int[] p)
	{
		int n = p.Length, first = 0, last = n - 1;
		while (first < n && _t.Owner[p[first]] >= 0) first++;
		while (last >= 0 && _t.Owner[p[last]] >= 0) last--;
		var seen = new Dictionary<int, int>();
		int previous = -1;
		for (int k = first; k <= last; k++)
		{
			int o = _t.Owner[p[k]];
			if (o >= 0 && o != previous && seen.TryGetValue(o, out int at) && k - at < _p.RejoinGap) return true;
			if (o != previous && previous >= 0) seen[previous] = k;
			previous = o;
		}
		return false;
	}

	/// <summary>Порт StageTrails._adds_network.</summary>
	public bool AddsNetwork(int[] p)
	{
		var (share, longest) = ParallelStats(p);
		return share <= _p.ParallelShare && longest <= _p.ParallelRun && !Rejoins(p);
	}

	/// <summary>Порт StageTrails._exit_loop (по Mask = path_mask ≥ 2).</summary>
	public bool ExitLoop(int[] p, bool reverse)
	{
		int n = p.Length;
		if (n < 2) return false;
		int o = reverse ? p[n - 1] : p[0];
		int ox = o % _t.W, oy = o / _t.W, fresh = 0, touch = 0;
		bool left = false;
		for (int k = 0; k < n; k++)
		{
			int c = reverse ? p[n - 1 - k] : p[k];
			int dx = c % _t.W - ox, dy = c / _t.W - oy;
			if (dx * dx + dy * dy > _p.ExitR * _p.ExitR) break;
			if (_t.Mask[c] >= 2)
			{
				fresh = 0;
				if (left && ++touch > _p.CrossRun) return true;
			}
			else
			{
				touch = 0;
				if (++fresh > _p.JitterRun) left = true;
			}
		}
		return false;
	}

	/// <summary>Порт StageTrails._beyond_exits.</summary>
	public int[] BeyondExits(int[] p)
	{
		int n = p.Length;
		if (n < 2) return p;
		double ax = p[0] % _t.W, ay = p[0] / _t.W, bx = p[n - 1] % _t.W, by = p[n - 1] / _t.W;
		int first = 0, last = n - 1;
		while (first < n - 1 && RoadGraph.Hypot(p[first] % _t.W - ax, p[first] / _t.W - ay) <= _p.ExitR) first++;
		while (last > first && RoadGraph.Hypot(p[last] % _t.W - bx, p[last] / _t.W - by) <= _p.ExitR) last--;
		return p[first..(last + 1)];
	}

	/// <summary>Порт StageTrails._core.</summary>
	public int[] Core(int[] p)
	{
		int first = 0, last = p.Length - 1;
		while (first < last && _t.Mask[p[first]] >= 2) first++;
		while (last > first && _t.Mask[p[last]] >= 2) last--;
		return p[first..(last + 1)];
	}

	/// <summary>Порт StageTrails._new_ground.</summary>
	public bool NewGround(int[] p)
	{
		int fresh = 0;
		foreach (int i in p) if (_t.Mask[i] < 2) fresh++;
		return fresh > p.Length * 0.5;
	}

	// ---------------------------------------------------------------- узлы

	/// <summary>Точки примыкания пути к сети: клетка сети у каждого перехода сеть ↔ новая земля. Короткое касание сети
	/// (не длиннее CROSS_RUN) между новыми кусками — один узел-пересечение.</summary>
	public List<(int Cell, bool Crossing)> Attachments(int[] p)
	{
		var outl = new List<(int, bool)>();
		foreach (var a in AttachmentsAt(p)) outl.Add((a.Cell, a.Crossing));
		return outl;
	}

	/// <summary>То же с местом в пути: Index — клетка узла в p, Dir — куда от неё идёт новая земля (+1 вперёд, -1 назад,
	/// 0 — пересечение).</summary>
	public List<(int Cell, bool Crossing, int Index, int Dir)> AttachmentsAt(int[] p)
	{
		var outl = new List<(int, bool, int, int)>();
		int n = p.Length, k = 0;
		while (k < n)
		{
			if (_t.Owner[p[k]] < 0) { k++; continue; }
			int s = k;
			while (k < n && _t.Owner[p[k]] >= 0) k++;
			int e = k - 1; // сеть p[s..e]
			bool before = s > 0, after = k < n;
			if (before && after && e - s + 1 <= _p.CrossRun) outl.Add((p[(s + e) / 2], true, (s + e) / 2, 0));
			else
			{
				if (before) outl.Add((p[s], false, s, -1));
				if (after) outl.Add((p[e], false, e, 1));
			}
		}
		return outl;
	}

	private int NearestJunction(int cell)
	{
		double x = _t.X(cell), y = _t.Y(cell), bd = double.PositiveInfinity;
		int best = -1;
		for (int n = 0; n < Graph.NX.Count; n++)
		{
			if (!Graph.Junction(n)) continue;
			double d = RoadGraph.Hypot(Graph.NX[n] - x, Graph.NY[n] - y);
			if (d < bd) { bd = d; best = n; }
		}
		return best;
	}

	/// <summary>Правила узлов 3.4 для точки примыкания; пустая строка — годится, иначе причина отказа.</summary>
	public string NodeRule(int cell, bool crossing, bool ignoreExit = false, double sep = double.NaN)
	{
		if (double.IsNaN(sep)) sep = _p.NodeSep;
		if (!ignoreExit && SettleDist[cell] < _p.ExitR) return "node_exit";
		if (_t.OnAxis[cell] != 0) return "node_structure";
		double d = NodeDist[cell];
		if (d < sep)
		{
			if (d > 1.5) return "node_crowded";
			int j = NearestJunction(cell);
			if (j >= 0 && Graph.Degree(j) + (crossing ? 2 : 1) > _p.MaxDegree) return "node_degree";
		}
		return "";
	}

	public string LastNode = "";

	private void NoteNode(int c, string extra = "") =>
		LastNode = string.Format(System.Globalization.CultureInfo.InvariantCulture, " узел ({0},{1}): до поселения {2:F0}, до развилки {3:F0} кл{4}",
			c % _t.W, c / _t.W, SettleDist[c], NodeDist[c], extra);

	public string NodeRules(List<(int Cell, bool Crossing)> nodes)
	{
		var list = new List<(int, bool, int, int)>();
		foreach (var (c, x) in nodes) list.Add((c, x, -1, 0));
		return NodeRules(list, null, Array.Empty<int>());
	}

	/// <summary>Правила узлов пути p. own — свои поселения петли (номера в списке мест): выезд в круге ExitR своего
	/// поселения разрешён, если направление нового выезда (хорда ExitChord клеток) отличается от каждого существующего
	/// выезда этого поселения не меньше ExitAngle и степень узла поселения после добавления ≤ MaxDegree. У чужих
	/// поселений и вне кругов своих выездов — строгие правила NodeRule.</summary>
	public string NodeRules(List<(int Cell, bool Crossing, int Index, int Dir)> nodes, int[] own, int[] p) =>
		NodeRules(nodes, own, p, false, _p.NodeSep);

	/// <summary>ignoreExit, sep — для природных маршрутов (шаг 7): без правила ExitR и с RideNodeSep.</summary>
	public string NodeRules(List<(int Cell, bool Crossing, int Index, int Dir)> nodes, int[] own, int[] p, bool ignoreExit, double sep)
	{
		var exits = new HashSet<int>();
		for (int k = 0; k < nodes.Count; k++)
		{
			var (c, x, index, dir) = nodes[k];
			NoteNode(c);
			if (own != null && !x && dir != 0 && SettleDist[c] < _p.ExitR)
			{
				int home = NearestSettlement(c);
				if (Array.IndexOf(own, home) >= 0)
				{
					string why = OwnExit(home, c, index, dir, p);
					if (why.Length > 0) return why;
					exits.Add(k);
					continue;
				}
			}
			string rule = NodeRule(c, x, ignoreExit, sep);
			if (rule.Length > 0) return rule;
		}
		for (int a = 0; a < nodes.Count; a++)
			for (int b = a + 1; b < nodes.Count; b++)
			{
				if (exits.Contains(a) || exits.Contains(b)) continue;
				double d = _t.Dist(nodes[a].Cell, nodes[b].Cell);
				if (d > 1.5 && d < sep) return "node_pair";
			}
		return "";
	}

	private int NearestSettlement(int cell)
	{
		int best = -1;
		double bd = double.PositiveInfinity;
		for (int k = 0; k < _settle.Length; k++)
		{
			double d = _t.Dist(_settle[k], cell);
			if (d < bd) { bd = d; best = k; }
		}
		return best;
	}

	/// <summary>Свой выезд петли у поселения home из клетки сети c (место index в p, новая земля в сторону dir).</summary>
	private string OwnExit(int home, int c, int index, int dir, int[] p)
	{
		int node = Graph.SettleNode[home];
		if (node < 0) return "node_exit";
		// новая хорда: от точки отхода до клетки пути ExitChord клеток дальше по новой земле
		int far = index;
		for (int k = index + dir; k >= 0 && k < p.Length; k += dir)
		{
			far = k;
			if (_t.Dist(c, p[k]) >= _p.ExitChord) break;
		}
		double nx = _t.X(p[far]) - _t.X(c), ny = _t.Y(p[far]) - _t.Y(c);
		if (RoadGraph.Hypot(nx, ny) < 1.0) return "node_exit";
		foreach (int e in Graph.NEdges[node])
		{
			if (Graph.EDead[e]) continue;
			var pts = Graph.EPts[e];
			bool fromA = Graph.EA[e] == node;
			var (ex, ey) = AlongEdge(pts, fromA, _p.ExitChord);
			double ox = ex - Graph.NX[node], oy = ey - Graph.NY[node];
			if (RoadGraph.Hypot(ox, oy) < 1e-6) continue;
			double cos = (nx * ox + ny * oy) / (RoadGraph.Hypot(nx, ny) * RoadGraph.Hypot(ox, oy));
			if (Math.Acos(Math.Clamp(cos, -1.0, 1.0)) * 180.0 / Math.PI < _p.ExitAngle)
			{
				NoteNode(c, " — выезд вдоль существующего");
				return "node_exit_same";
			}
		}
		bool atCentre = RoadGraph.Hypot(_t.X(c) - Graph.NX[node], _t.Y(c) - Graph.NY[node]) <= 1.5;
		if (atCentre && Graph.Degree(node) + 1 > _p.MaxDegree) return "node_exit_degree";
		return "";
	}

	/// <summary>Единичные направления существующих выездов поселения home (хорда ExitChord по каждому ребру его узла).</summary>
	private List<(double X, double Y)> ExitDirections(int home)
	{
		var outl = new List<(double, double)>();
		int node = Graph.SettleNode[home];
		if (node < 0) return outl;
		foreach (int e in Graph.NEdges[node])
		{
			if (Graph.EDead[e]) continue;
			var (ex, ey) = AlongEdge(Graph.EPts[e], Graph.EA[e] == node, _p.ExitChord);
			double ox = ex - Graph.NX[node], oy = ey - Graph.NY[node], l = RoadGraph.Hypot(ox, oy);
			if (l > 1e-6) outl.Add((ox / l, oy / l));
		}
		return outl;
	}

	/// <summary>Точка на ломаной ребра на дуге dist от начала (fromA) или от конца.</summary>
	private static (double X, double Y) AlongEdge(double[] pts, bool fromA, double dist)
	{
		int n = pts.Length / 2;
		double run = 0;
		for (int j = 1; j < n; j++)
		{
			int a = fromA ? j - 1 : n - j, b = fromA ? j : n - j - 1;
			double ax = pts[2 * a], ay = pts[2 * a + 1], bx = pts[2 * b], by = pts[2 * b + 1];
			double len = RoadGraph.Hypot(bx - ax, by - ay);
			if (run + len >= dist && len > 1e-9)
			{
				double t = (dist - run) / len;
				return (ax + (bx - ax) * t, ay + (by - ay) * t);
			}
			run += len;
		}
		return fromA ? (pts[^2], pts[^1]) : (pts[0], pts[1]);
	}

	// ---------------------------------------------------------------- принятие ребра

	private double[] Polyline(int[] cells, int from, int to)
	{
		var pts = new double[(to - from + 1) * 2];
		for (int k = from; k <= to; k++) { pts[2 * (k - from)] = _t.X(cells[k]); pts[2 * (k - from) + 1] = _t.Y(cells[k]); }
		return pts;
	}

	private void Accept(int[] p)
	{
		long t0 = NetStats.Now();
		int sec = _virtual++;
		var wasJunction = new bool[Graph.NX.Count];
		for (int j = 0; j < wasJunction.Length; j++) wasJunction[j] = Graph.Junction(j);
		// Куски новой земли с клетками сети по краям — новые рёбра графа
		int n = p.Length, k = 0;
		var pieces = new List<(int From, int To)>();
		while (k < n)
		{
			if (_t.Owner[p[k]] >= 0) { k++; continue; }
			int s = k;
			while (k < n && _t.Owner[p[k]] < 0) k++;
			pieces.Add((Math.Max(0, s - 1), Math.Min(n - 1, k)));
		}
		foreach (var (from, to) in pieces)
		{
			var pts = Polyline(p, from, to);
			// примыкание ближе JoinSame к развилке — в саму развилку (общий узел), как при публикации (StageTrails._join_point)
			SnapToJunction(pts, 0);
			SnapToJunction(pts, pts.Length / 2 - 1);
			int a = Graph.Attach(pts[0], pts[1], 1.5);
			int b = Graph.Attach(pts[^2], pts[^1], 1.5);
			if (b < 0)
			{
				// тупик (вершина, берег, смотровая): свой узел
				Graph.NX.Add(pts[^2]); Graph.NY.Add(pts[^1]); Graph.NSettle.Add(false); Graph.NEdges.Add(new List<int>());
				b = Graph.NX.Count - 1;
			}
			Graph.AddPath(a, b, pts, sec);
		}
		// Своя копия сети: клетки, маска и «протоптанность» (StageTrails._trodden: max(0,3; цена × human_reuse))
		var fresh = new List<int>();
		foreach (int c in p)
		{
			if (_t.Owner[c] < 0) { _t.Owner[c] = sec; fresh.Add(c); }
			if (_t.Mask[c] < 2) _t.Mask[c] = 2;
			var raw = Fields.Raw;
			if (float.IsFinite(raw[c])) raw[c] = (float)Math.Max(0.3, Math.Min(raw[c], _t.Cost[c]) * _p.HumanReuse);
		}
		var junctions = new List<int>();
		for (int j = 0; j < Graph.NX.Count; j++)
			if (Graph.Junction(j) && (j >= wasJunction.Length || !wasJunction[j])) junctions.Add(NodeCell(j));
		Stats.Time("accept", t0);
		// окно — весь путь: у его клеток сменилась цена «протоптанности»; источники Near — новые клетки сети
		RefreshLocal(fresh, junctions, p);
	}

	/// <summary>Близость к развилке, с которой примыкание идёт в саму развилку (клетки): как правило узлов (≤ 1,5).</summary>
	public const double JoinSame = 1.5;

	/// <summary>Точка k ломаной pts ближе JoinSame к развилке графа — заменяется точкой развилки.</summary>
	private void SnapToJunction(double[] pts, int k)
	{
		double x = pts[2 * k], y = pts[2 * k + 1], bd = JoinSame;
		int best = -1;
		for (int n = 0; n < Graph.NX.Count; n++)
		{
			if (!Graph.Junction(n)) continue;
			double d = RoadGraph.Hypot(Graph.NX[n] - x, Graph.NY[n] - y);
			if (d <= bd) { bd = d; best = n; }
		}
		if (best < 0) return;
		pts[2 * k] = Graph.NX[best];
		pts[2 * k + 1] = Graph.NY[best];
	}

	/// <summary>Для стенда: принять путь и вернуть (Near, NodeDist) после локального обновления.</summary>
	public void AcceptForTest(int[] p) => Accept(p);

	// ---------------------------------------------------------------- петли

	public Godot.Collections.Dictionary PlanLoops()
	{
		long total = NetStats.Now();
		Prepare(false, true);
		var pairs = _in.ContainsKey("pairs") ? _in["pairs"].AsInt32Array() : Array.Empty<int>();
		int N = _settle.Length;
		int limit = (int)Math.Ceiling(_p.LoopShare * N);
		Stats.Count("loop_limit", limit);
		var geo = new Dictionary<int, double[]>();
		double[] Geo(int s)
		{
			if (!geo.TryGetValue(s, out var d)) geo[s] = d = Coarse.Dijkstra(Coarse.CompNear(_settle[s])).Dist;
			return d;
		}
		var candidates = new List<(double Ratio, int A, int B, double DGeo)>();
		long t0 = NetStats.Now();
		for (int k = 0; k + 1 < pairs.Length; k += 2)
		{
			int a = pairs[k], b = pairs[k + 1];
			if ((uint)a >= N || (uint)b >= N) throw new ArgumentException("V2: пара вне списка поселений");
			Stats.Count("loop_pairs");
			if (_remote[a] != 0 || _remote[b] != 0) { Stats.Reject("loop_remote"); continue; }
			int cb = Coarse.CompNear(_settle[b]);
			double dGeo = cb >= 0 ? Geo(a)[cb] : double.PositiveInfinity;
			double dNet = NetDistance(a, b);
			if (!double.IsFinite(dGeo)) { Stats.Reject("loop_no_geo"); continue; }
			if (!double.IsFinite(dNet)) { Stats.Reject("loop_no_net"); continue; }
			double ratio = dNet / Math.Max(dGeo, 1.0);
			if (ratio <= _p.LoopRatio) { Stats.Reject("loop_ratio_ok"); continue; }
			candidates.Add((ratio, a, b, dGeo));
		}
		candidates.Sort((x, y) => x.Ratio != y.Ratio ? y.Ratio.CompareTo(x.Ratio) : x.A != y.A ? x.A.CompareTo(y.A) : x.B.CompareTo(y.B));
		Stats.Count("loop_candidates", candidates.Count);
		Stats.Time("loop_select", t0);
		var outPaths = new Godot.Collections.Array();
		var outWhat = new Godot.Collections.Array();
		var outPairs = new Godot.Collections.Array();
		foreach (var (_, a, b, dGeo) in candidates)
		{
			if (outPaths.Count >= limit) { Stats.Reject("loop_limit"); continue; }
			double dNet = NetDistance(a, b);
			if (dNet / Math.Max(dGeo, 1.0) <= _p.LoopRatio) { Stats.Reject("loop_short_now"); continue; }
			string why = TryLoop(a, b, dNet, dGeo, out int[] path);
			Stats.Log.Add(string.Format(System.Globalization.CultureInfo.InvariantCulture, "петля {0}-{1}: D_net {2:F0}, D_geo {3:F0}, путь {4:F0} кл — {5}",
				a, b, dNet, dGeo, path.Length > 0 ? SmoothLength(path) : 0.0, why.Length > 0 ? why + (why.Contains("node") || why.Contains("parallel") ? LastNode : "") : "принята"));
			if (why.Length > 0) { Stats.Reject(why); continue; }
			Accept(path);
			outPaths.Add(path);
			outWhat.Add(SmoothLength(path) < dNet ? "shortcut" : "alternative");
			outPairs.Add(new Godot.Collections.Array { a, b });
			Stats.Count("loops");
		}
		Stats.Time("total", total);
		return Result(outPaths, outWhat, outPairs);
	}

	private double NetDistance(int a, int b)
	{
		int na = Graph.SettleNode[a], nb = Graph.SettleNode[b];
		if (na < 0 || nb < 0) return double.PositiveInfinity;
		return Graph.Dijkstra(na).Dist[nb];
	}

	/// <summary>Одна петля между поселениями a и b; пустая строка — принята (path), иначе причина отказа.</summary>
	private string TryLoop(int a, int b, double dNet, double dGeo, out int[] path)
	{
		path = Array.Empty<int>();
		int sa = _settle[a], sb = _settle[b];
		// Старый путь по сети — коридор избегания (StageTrails._corridor/_avoiding), без кругов выездов (_open_ends)
		var (_, via) = Graph.Dijkstra(Graph.SettleNode[a]);
		var oldCells = new List<int>();
		foreach (int e in Graph.PathEdges(via, Graph.SettleNode[b])) Rasterize(Graph.EPts[e], oldCells);
		var touched = new List<int>();
		int W = _t.W, H = _t.H, ar = (int)_p.AvoidR;
		var avoid = new HashSet<int>();
		foreach (int c in oldCells)
			for (int y = Math.Max(0, c / W - ar); y < Math.Min(H, c / W + ar + 1); y++)
				for (int x = Math.Max(0, c % W - ar); x < Math.Min(W, c % W + ar + 1); x++)
					avoid.Add(y * W + x);
		var sorted = new List<int>(avoid);
		sorted.Sort();
		if (_mark.Length != _t.N) _mark = new byte[_t.N];
		foreach (int c in sorted)
		{
			if (_t.Dist(c, sa) <= _p.ExitR || _t.Dist(c, sb) <= _p.ExitR) continue;
			if (float.IsFinite(_scratch[c])) { _scratch[c] = (float)(_scratch[c] * _p.AvoidCost); touched.Add(c); _mark[c] = 1; }
		}
		// Шаг 8: в кругах выездов своих поселений дороже (EXIT_MUL) только новая земля в секторе ±ExitAngle от
		// существующих выездов этого поселения (там новый выезд шёл бы вдоль старого); другие направления — обычная цена
		int r = (int)Math.Ceiling(_p.ExitR);
		double cosLimit = Math.Cos(_p.ExitAngle * Math.PI / 180.0);
		foreach (int home in new[] { a, b })
		{
			int o = _settle[home];
			var dirs = ExitDirections(home);
			for (int y = Math.Max(0, o / W - r); y < Math.Min(H, o / W + r + 1); y++)
				for (int x = Math.Max(0, o % W - r); x < Math.Min(W, o % W + r + 1); x++)
				{
					int c = y * W + x;
					if (_t.Mask[c] >= 2 || !float.IsFinite(_scratch[c])) continue;
					double dx = x - o % W, dy = y - o / W, len = Math.Sqrt(dx * dx + dy * dy);
					if (len > _p.ExitR || len < 1e-9) continue;
					bool along = false;
					foreach (var (ux, uy) in dirs)
						if ((dx * ux + dy * uy) / len >= cosLimit) { along = true; break; }
					if (!along) continue;
					_scratch[c] = (float)(_scratch[c] * _p.ExitMul);
					touched.Add(c);
				}
		}
		try
		{
			long t0 = NetStats.Now();
			int ca = Coarse.CompNear(sa), cb = Coarse.CompNear(sb);
			var (_, prev) = Coarse.Dijkstra(ca, cb);
			if (ca < 0 || cb < 0) return "loop_no_geo";
			var chain = CoarseGraph.Chain(prev, cb);
			Stats.Time("coarse_path", t0);
			SoftAvoid(Coarse.Bounds(chain).Grow((int)_p.WindowRetry, W, H), sa, sb, _mark, touched);
			path = Router.Route(_scratch, sa, sb, Coarse.Bounds(chain), false, Stats);
			if (path.Length == 0 && chain.Count >= 2)
			{
				// одна перепланировка: середина грубого пути закрыта
				int m = chain.Count / 2;
				Coarse.Close(chain[m - 1], chain[m]);
				var (_, prev2) = Coarse.Dijkstra(ca, cb);
				Coarse.Open();
				if (cb == ca || prev2[cb] >= 0)
				{
					Stats.Count("loop_replans");
					var bounds2 = Coarse.Bounds(CoarseGraph.Chain(prev2, cb));
					SoftAvoid(bounds2.Grow((int)_p.WindowRetry, W, H), sa, sb, _mark, touched);
					path = Router.Route(_scratch, sa, sb, bounds2, false, Stats);
				}
			}
		}
		finally
		{
			foreach (int c in touched) { _scratch[c] = Base[c]; _mark[c] = 0; }
		}
		if (path.Length == 0) return "loop_no_path";
		long c0 = NetStats.Now();
		try
		{
			double length = SmoothLength(path);
			if (length > _p.LoopLenOld * dNet) return "loop_long";
			if (Math.Min(dNet, length) / Math.Max(dGeo, 1.0) > _p.LoopAccept) return "loop_ratio";
			if (!Validator.Ford(path)) return "loop_ford";
			var core = Core(path);
			if (!NewGround(core)) return "loop_not_new";
			if (ExitLoop(path, false) || ExitLoop(path, true)) return "loop_exit_loop";
			var beyond = BeyondExits(path);
			var (share, longest) = ParallelStats(beyond);
			if (share > _p.ParallelShare || longest > _p.ParallelRun)
			{
				LastNode = string.Format(System.Globalization.CultureInfo.InvariantCulture, " (доля {0:F2}, подряд {1})", share, longest);
				return "loop_parallel";
			}
			if (Rejoins(beyond)) return "loop_rejoin";
			if (core.Length >= 2 && Graph.DoubleCross(Polyline(core, 0, core.Length - 1), 20.0)) return "loop_double_cross";
			if (FarShare(core, oldCells) < _p.FarShare) return "loop_duplicate";
			string node = NodeRules(AttachmentsAt(path), new[] { a, b }, path);
			if (node.Length > 0) return "loop_" + node;
			return "";
		}
		finally
		{
			Stats.Time("checks", c0);
		}
	}

	/// <summary>Мягкое избегание всей сети: новая земля ближе NearNet к сети на той же высоте (LevelGap, как правило
	/// «вдоль сети» StageTrails._parallel_stats) вне кругов выезда sa и sb — в AvoidCost раз дороже, один раз на клетку
	/// (mark). Клетки сети не трогаются: пересечь дорогу можно.</summary>
	private void SoftAvoid(CellRect area, int sa, int sb, byte[] mark, List<int> touched) =>
		SoftAvoid(area, sa, sb, _p.ExitR, mark, touched);

	/// <summary>То же с радиусом skipR вокруг sa и sb (у ответвлений — только точка съезда).</summary>
	private void SoftAvoid(CellRect area, int sa, int sb, double skipR, byte[] mark, List<int> touched)
	{
		int W = _t.W, H = _t.H, r = (int)Math.Ceiling(_p.NearNet);
		double scale = _p.HeightScale * _p.Tile;
		for (int y = area.Y0; y < area.Y1; y++)
			for (int x = area.X0; x < area.X1; x++)
			{
				int i = y * W + x;
				if (mark[i] != 0 || _t.Owner[i] >= 0 || Near[i] > _p.NearNet || !float.IsFinite(_scratch[i])) continue;
				if (_t.Dist(i, sa) <= skipR || _t.Dist(i, sb) <= skipR) continue;
				double reach = Near[i] + 0.75;
				bool level = false;
				for (int dy = -r; dy <= r && !level; dy++)
					for (int dx = -r; dx <= r && !level; dx++)
					{
						int nx = x + dx, ny = y + dy;
						if (nx < 0 || ny < 0 || nx >= W || ny >= H || dx * dx + dy * dy > reach * reach) continue;
						int j = ny * W + nx;
						level = _t.Owner[j] >= 0 && Math.Abs((double)_t.Hw[j] - _t.Hw[i]) * scale < _p.LevelGap;
					}
				if (!level) continue;
				mark[i] = 1;
				_scratch[i] = (float)(_scratch[i] * _p.AvoidCost);
				touched.Add(i);
			}
	}

	/// <summary>Длина пути по хордам через 4 клетки — без зубцов сетки (D_geo считается по центрам компонент, а не по
	/// шагам сетки; восьмисвязный путь длиннее прямой до 8 %).</summary>
	public double SmoothLength(int[] p)
	{
		double length = 0;
		int last = 0;
		for (int k = 4; k < p.Length; k += 4) { length += _t.Dist(p[last], p[k]); last = k; }
		if (last < p.Length - 1) length += _t.Dist(p[last], p[^1]);
		return length;
	}

	private void Rasterize(double[] pts, List<int> cells)
	{
		for (int k = 2; k + 1 < pts.Length; k += 2)
		{
			double ax = pts[k - 2], ay = pts[k - 1], bx = pts[k], by = pts[k + 1];
			int steps = Math.Max(1, (int)Math.Ceiling(RoadGraph.Hypot(bx - ax, by - ay) * 2.0));
			for (int s = 0; s <= steps; s++)
			{
				double t = (double)s / steps;
				int x = Math.Clamp((int)Math.Floor(ax + (bx - ax) * t), 0, _t.W - 1), y = Math.Clamp((int)Math.Floor(ay + (by - ay) * t), 0, _t.H - 1);
				cells.Add(y * _t.W + x);
			}
		}
	}

	/// <summary>Доля клеток core дальше FarR от клеток from (StageTrails._far_share) — по окну вокруг пути.</summary>
	private double FarShare(int[] core, List<int> from)
	{
		if (core.Length == 0) return 0.0;
		int far = 0;
		double r2 = _p.FarR * _p.FarR;
		var set = new HashSet<int>(from);
		int fr = (int)Math.Ceiling(_p.FarR);
		foreach (int c in core)
		{
			bool near = false;
			int cx = c % _t.W, cy = c / _t.W;
			for (int dy = -fr; dy <= fr && !near; dy++)
				for (int dx = -fr; dx <= fr && !near; dx++)
				{
					int x = cx + dx, y = cy + dy;
					if (x < 0 || y < 0 || x >= _t.W || y >= _t.H || dx * dx + dy * dy > r2) continue;
					near = set.Contains(y * _t.W + x);
				}
			if (!near) far++;
		}
		return (double)far / core.Length;
	}

	// ---------------------------------------------------------------- ответвления

	/// <summary>Цели (targets/kinds/anchors) готовит GDScript правилами V1 (_shore, _overlook, вершины без тропы);
	/// здесь — расстановка (SHORE_GAP, VIEW_GAP, пределы числа), выбор точки съезда по правилам узлов, поиск в коридоре
	/// и проверки: длина (BRANCH_LEN), новая земля, «вдоль сети», двойные касания, брод, берег (доля у воды).</summary>
	public Godot.Collections.Dictionary PlanSpurs()
	{
		long total = NetStats.Now();
		bool mountainRun = _in.ContainsKey("mountain") && _in["mountain"].AsBool();
		Prepare(mountainRun, true, mountainRun ? _p.MountainGrade : _p.TrailGrade);
		var targets = _in["targets"].AsInt32Array();
		var kinds = _in["target_kinds"].AsInt32Array();
		var anchors = _in["anchors"].AsInt32Array();
		var keepPeaks = _in.ContainsKey("peaks_keep") ? _in["peaks_keep"].AsInt32Array() : Array.Empty<int>();
		int maxShores = (int)Params.Num(_in, "max_shores"), maxViews = (int)Params.Num(_in, "max_views");
		if (kinds.Length != targets.Length || anchors.Length != targets.Length) throw new ArgumentException("V2: цели ответвлений разной длины");
		var order = new List<int>();
		for (int k = 0; k < targets.Length; k++) order.Add(k);
		// Порядок целей: вид, затем порядок точек перегонов (как перебор V1)
		order.Sort((x, y) => kinds[x] != kinds[y] ? kinds[x].CompareTo(kinds[y]) : x.CompareTo(y));
		var outPaths = new Godot.Collections.Array();
		var outWhat = new Godot.Collections.Array();
		var outPairs = new Godot.Collections.Array();
		var tried = new List<(int Cell, int Kind)>();
		int shores = 0, views = 0;
		foreach (int k in order)
		{
			int target = targets[k], kind = kinds[k];
			string what = kind == 0 ? "shore" : kind == 1 ? "view" : "mountain";
			Stats.Count(what + "_targets");
			if (_t.Mask[target] >= 2) { Stats.Reject(what + "_on_net"); continue; }
			if (kind == 0 && shores >= maxShores || kind == 1 && views >= maxViews) { Stats.Reject(what + "_limit"); continue; }
			bool spaced = true;
			foreach (var (cell, tk) in tried)
			{
				double d = _t.Dist(cell, target);
				if (kind == 0 && tk == 0 && d < _p.ShoreGap || kind == 1 && d < _p.ViewGap || kind == 0 && tk == 1 && d < _p.ViewGap) spaced = false;
			}
			if (kind == 1)
				foreach (int pk in keepPeaks) if (_t.Dist(pk, target) < _p.ViewGap) spaced = false;
			if (!spaced) { Stats.Reject(what + "_spacing"); continue; }
			if (kind != 2) tried.Add((target, kind));
			string why = TrySpur(target, kind, anchors[k], out int[] path);
			Stats.Log.Add(string.Format(System.Globalization.CultureInfo.InvariantCulture, "{0} ({1},{2}): путь {3:F0} кл — {4}",
				what, target % _t.W, target / _t.W, path.Length > 0 ? _t.Length(path) : 0.0, why.Length > 0 ? why + (why.Contains("node") || why.Contains("parallel") ? LastNode : "") : "принято" + LastNode));
			if (why.Length > 0) { Stats.Reject(why); continue; }
			Accept(path);
			outPaths.Add(path);
			outWhat.Add(what);
			outPairs.Add(new Godot.Collections.Array { path[0], target });
			if (kind == 0) shores++;
			else if (kind == 1) views++;
			Stats.Count(what);
		}
		Stats.Time("total", total);
		return Result(outPaths, outWhat, outPairs);
	}

	/// <summary>Точка съезда: клетка сети ближе всего к цели, которая проходит правила узлов; поиск в радиусе reach.</summary>
	private int Source(int target, double reach, int anchor, out string why)
	{
		why = "";
		var list = Candidates(target, reach, anchor);
		string first = "";
		foreach (var (_, c) in list)
		{
			string rule = NodeRule(c, false);
			if (rule.Length == 0) { NoteNode(c, " — точка съезда"); return c; }
			if (first.Length == 0) { first = rule; NoteNode(c, " — ближайшая точка съезда"); }
		}
		why = list.Count == 0 ? "no_source" : "source_" + first;
		return -1;
	}

	/// <summary>Клетки сети (с конечной ценой) в круге reach вокруг цели и точка перегона anchor — по расстоянию.</summary>
	private List<(double D, int C)> Candidates(int target, double reach, int anchor)
	{
		int ct = Coarse != null ? Coarse.CompNear(target) : -1;
		int W = _t.W, H = _t.H, tx = target % W, ty = target / W, r = (int)Math.Ceiling(reach);
		var list = new List<(double D, int C)>();
		for (int y = Math.Max(0, ty - r); y < Math.Min(H, ty + r + 1); y++)
			for (int x = Math.Max(0, tx - r); x < Math.Min(W, tx + r + 1); x++)
			{
				int c = y * W + x;
				if (_t.Owner[c] < 0 || !float.IsFinite(Base[c])) continue;
				double d = RoadGraph.Hypot(x - tx, y - ty);
				// только точки, связные с целью по грубому графу (шаг 6): иначе выбор упирается в недостижимую точку
				if (d <= reach && (Coarse == null || Coarse.Linked(Coarse.CompNear(c), ct))) list.Add((d, c));
			}
		if (anchor >= 0 && _t.Owner[anchor] >= 0 && (Coarse == null || Coarse.Linked(Coarse.CompNear(anchor), ct)))
			list.Add((_t.Dist(anchor, target) + 1e-6, anchor));
		list.Sort((a, b) => a.D != b.D ? a.D.CompareTo(b.D) : a.C.CompareTo(b.C));
		return list;
	}

	/// <summary>Точка съезда горной тропы (как V1 _mountain_trails): ближайшая клетка сети, проходящая все правила узлов
	/// (вне ExitR и NodeSep), если она не дальше ближайшей точки сети × MOUNTAIN_DETOUR + 4 клетки; иначе ближайшая,
	/// проходящая правила узлов без ExitR (exitFree — съезд у поселения разрешён только в этой точке).</summary>
	private int MountainSource(int target, double nearest, out bool exitFree, out string why)
	{
		exitFree = false;
		why = "";
		long s0 = NetStats.Now();
		double limit = nearest * _p.MountainDetour + 4.0;
		try
		{
			foreach (var (d, c) in Candidates(target, limit, -1))
				if (NodeRule(c, false).Length == 0) { NoteNode(c, " — точка съезда"); return c; }
		}
		finally { Stats.Time("sources", s0); }
		var list = Candidates(target, _t.W * 0.4, -1);
		string first = "";
		foreach (var (_, c) in list)
		{
			string rule = NodeRule(c, false, true);
			if (rule.Length == 0) { exitFree = true; NoteNode(c, " — точка съезда у поселения"); return c; }
			if (first.Length == 0) { first = rule; NoteNode(c, " — ближайшая точка съезда"); }
		}
		why = list.Count == 0 ? "no_source" : "source_" + first;
		return -1;
	}

	private string TrySpur(int target, int kind, int anchor, out int[] path)
	{
		path = Array.Empty<int>();
		string what = kind == 0 ? "shore" : kind == 1 ? "view" : "mountain";
		double reach;
		if (kind == 2)
		{
			// Ближайшая клетка сети (как FastGrid.NearestPath V1); дальше W·0,4 — без тропы. Перебор — в квадрате радиуса
			// Near + 2: фаска 1 / √2 не меньше евклидова расстояния, ближайшая клетка сети внутри него
			long s0 = NetStats.Now();
			double bd = double.PositiveInfinity;
			int tx = target % _t.W, ty = target / _t.W;
			int nr = (int)Math.Ceiling(Math.Min(Near[target], _t.W)) + 2;
			for (int y = Math.Max(0, ty - nr); y < Math.Min(_t.H, ty + nr + 1); y++)
				for (int x = Math.Max(0, tx - nr); x < Math.Min(_t.W, tx + nr + 1); x++)
				{
					int i = y * _t.W + x;
					if (_t.Owner[i] >= 0 && float.IsFinite(_t.Cost[i]))
						bd = Math.Min(bd, RoadGraph.Hypot(x + 0.5 - (tx + 0.5), y + 0.5 - (ty + 0.5)));
				}
			if (!(bd <= nr - 1))
			{
				// ближайшая клетка сети с конечной ценой дальше квадрата — полный перебор, как раньше
				bd = double.PositiveInfinity;
				for (int i = 0; i < _t.N; i++)
					if (_t.Owner[i] >= 0 && float.IsFinite(_t.Cost[i]))
						bd = Math.Min(bd, RoadGraph.Hypot(i % _t.W + 0.5 - (tx + 0.5), i / _t.W + 0.5 - (ty + 0.5)));
			}
			Stats.Time("sources", s0);
			if (!(bd < _t.W * 0.4)) return what + "_far";
			reach = bd;
		}
		else reach = kind == 0 ? _p.ShoreReach : _p.ViewReach;
		bool exitFree = false;
		string why;
		int source = kind == 2 ? MountainSource(target, reach, out exitFree, out why) : Source(target, reach, anchor, out why);
		if (source < 0) return what + "_" + why;
		// Окно — компоненты грубого пути от точки съезда до цели; связи нет — пути нет
		int cs = Coarse.CompNear(source), ct = Coarse.CompNear(target);
		if (cs < 0 || ct < 0) return what + "_no_geo";
		if (!Coarse.Linked(cs, ct)) return what + "_no_geo";
		long g0 = NetStats.Now();
		var (geoDist, geoPrev) = Coarse.Dijkstra(cs, ct);
		Stats.Time("coarse_path", g0);
		if (!double.IsFinite(geoDist[ct])) return what + "_no_geo";
		var area = Coarse.Bounds(CoarseGraph.Chain(geoPrev, ct));
		// Ответвление не идёт по сети: клетки сети в окне (кроме точки съезда) в EXIT_MUL раз дороже, пересечь дорогу можно
		var win = area.Grow((int)_p.WindowRetry, _t.W, _t.H);
		var touched = new List<int>();
		for (int y = win.Y0; y < win.Y1; y++)
			for (int x = win.X0; x < win.X1; x++)
			{
				int c = y * _t.W + x;
				if (c == source || _t.Owner[c] < 0 || !float.IsFinite(_scratch[c])) continue;
				// пол цены, как у природных маршрутов (ride_routes.gd: клетка сети не дешевле 2,0), иначе дорога ×ExitMul
				// дешевле земли и ответвление идёт по ней
				_scratch[c] = (float)(Math.Max(_p.SpurNetFloor, _scratch[c]) * _p.ExitMul);
				touched.Add(c);
			}
		// Горные: мягкое избегание сети на той же высоте вокруг пути, кроме точки съезда (как у петель)
		if (kind == 2)
		{
			if (_mark.Length != _t.N) _mark = new byte[_t.N];
			foreach (int c in touched) _mark[c] = 1;
			SoftAvoid(win, source, source, 1.5, _mark, touched);
		}
		try { path = Router.Route(_scratch, source, target, area, kind == 2, Stats); }
		finally { foreach (int c in touched) { _scratch[c] = Base[c]; if (_mark.Length == _t.N) _mark[c] = 0; } }
		if (path.Length == 0) return what + "_no_path";
		long c0 = NetStats.Now();
		try
		{
			double straight = _t.Dist(source, target);
			if (kind != 2 && _t.Length(path) > straight * _p.BranchLen) return what + "_long";
			if (!Validator.Ford(path)) return what + "_ford";
			if (kind != 2 && !NewGround(path)) return what + "_not_new";
			if (kind != 2 && !AddsNetwork(path)) return what + "_parallel";
			var spurCore = Core(path);
			if (kind == 2)
			{
				// вершина у самой сети — тропа не нужна; горная тропа тоже не идёт вдоль сети (правило V1 _adds_network)
				int fresh = 0;
				foreach (int c in spurCore) if (_t.Mask[c] < 2) fresh++;
				if (fresh < 4) return what + "_short";
				if (!AddsNetwork(spurCore))
				{
					var (share, longest) = ParallelStats(spurCore);
					LastNode = string.Format(System.Globalization.CultureInfo.InvariantCulture, " (доля {0:F2}, подряд {1})", share, longest);
					return what + "_parallel";
				}
			}
			if (spurCore.Length >= 2 && Graph.DoubleCross(Polyline(spurCore, 0, spurCore.Length - 1), 20.0)) return what + "_double_cross";
			if (kind == 0)
			{
				int wet = 0, count = Math.Max(0, path.Length - 4);
				for (int k = 0; k < count; k++) if (Fields.ShoreDist[path[k]] <= _p.ShoreBand) wet++;
				if (count > 0 && (double)wet / count > _p.ShoreShare) return what + "_along_shore";
			}
			var touches = AttachmentsAt(path);
			// тупиковое ответвление к берегу или смотровой: одна точка примыкания — точка съезда
			if (kind != 2 && (touches.Count != 1 || touches[0].Cell != source)) return what + "_spur_touch";
			string node = SpurNodeRules(touches, source, exitFree);
			if (node.Length > 0) return what + "_" + node;
			return "";
		}
		finally
		{
			Stats.Time("checks", c0);
		}
	}

	/// <summary>Правила узлов ответвления; exitFree — точка съезда (source) у поселения разрешена (горная тропа, V1).</summary>
	private string SpurNodeRules(List<(int Cell, bool Crossing, int Index, int Dir)> nodes, int source, bool exitFree)
	{
		foreach (var (c, x, _, _) in nodes)
		{
			NoteNode(c);
			string rule = NodeRule(c, x, exitFree && c == source);
			if (rule.Length > 0) return rule;
		}
		for (int a = 0; a < nodes.Count; a++)
			for (int b = a + 1; b < nodes.Count; b++)
			{
				double d = _t.Dist(nodes[a].Cell, nodes[b].Cell);
				if (d > 1.5 && d < _p.NodeSep) return "node_pair";
			}
		return "";
	}

	// ---------------------------------------------------------------- примыкания природных маршрутов (шаг 4)

	/// <summary>Правила узлов 3.4 для готовых путей (природные маршруты RideRoutes): для каждого пути из paths —
	/// причина отказа по готовой сети (пусто — годится) и клетки его точек примыкания. Расстояние между точками
	/// примыкания разных маршрутов проверяет RoadNetworkV2.ride_nodes_spaced тем же NodeSep.</summary>
	public Godot.Collections.Dictionary CheckNodes()
	{
		long total = NetStats.Now();
		Prepare(false, false);
		var verdicts = new Godot.Collections.Array();
		var nodes = new Godot.Collections.Array();
		foreach (var v in _in["paths"].AsGodotArray())
		{
			var p = v.AsInt32Array();
			var att = AttachmentsAt(p);
			var cells = new int[att.Count];
			for (int k = 0; k < att.Count; k++) cells[k] = att[k].Cell;
			// шаг 7: у природных маршрутов без ExitR (мера тесных узлов узлы у поселений не считает), развилки — RideNodeSep
			string why = NodeRules(att, null, p, true, _p.RideNodeSep);
			verdicts.Add(why.Length > 0 ? why + LastNode : "");
			nodes.Add(cells);
			Stats.Count(why.Length > 0 ? "rides_rejected" : "rides_ok");
			if (why.Length > 0) Stats.Reject("ride_" + why);
		}
		// Шаг 9: подъёмы к виртуальным вершинам — те же правила узлов и «вдоль сети» (_adds_network по новой части)
		var approachVerdicts = new Godot.Collections.Array();
		var approachNodes = new Godot.Collections.Array();
		if (_in.ContainsKey("approaches"))
			foreach (var v in _in["approaches"].AsGodotArray())
			{
				var p = v.AsInt32Array();
				var att = AttachmentsAt(p);
				var cells = new int[att.Count];
				for (int k = 0; k < att.Count; k++) cells[k] = att[k].Cell;
				string why = NodeRules(att, null, p, true, _p.RideNodeSep);
				if (why.Length > 0) why += LastNode;
				else
				{
					var core = Core(p);
					if (!AddsNetwork(core))
					{
						var (share, longest) = ParallelStats(core);
						why = string.Format(System.Globalization.CultureInfo.InvariantCulture, "parallel (доля {0:F2}, подряд {1})", share, longest);
					}
				}
				approachVerdicts.Add(why);
				approachNodes.Add(cells);
				Stats.Count(why.Length > 0 ? "approach_rejected" : "approach_ok");
				if (why.Length > 0) Stats.Reject("approach_" + why.Split(' ')[0]);
			}
		Stats.Time("total", total);
		return new Godot.Collections.Dictionary { ["verdicts"] = verdicts, ["nodes"] = nodes, ["approach_verdicts"] = approachVerdicts,
			["approach_nodes"] = approachNodes, ["network_v2"] = Stats.ToDictionary() };
	}

	/// <summary>Шаг 7: расстояние до развилок сети (клетки) — по нему RideRoutes отбирает опорные точки маршрутов.</summary>
	public Godot.Collections.Dictionary NodeField()
	{
		Prepare(false, false);
		return new Godot.Collections.Dictionary { ["node_dist"] = NodeDist, ["network_v2"] = Stats.ToDictionary() };
	}

	// ---------------------------------------------------------------- выход

	private Godot.Collections.Dictionary Result(Godot.Collections.Array paths, Godot.Collections.Array what, Godot.Collections.Array pairs)
	{
		Stats.Count("searches", Router.Searches);
		Stats.Count("window_retries", Router.Retries);
		var outPaths = new Godot.Collections.Array();
		foreach (var p in paths) outPaths.Add(p);
		var junctions = new List<double>();
		for (int n = 0; n < Graph.NX.Count; n++)
			if (Graph.Junction(n)) { junctions.Add(Graph.NX[n]); junctions.Add(Graph.NY[n]); }
		return new Godot.Collections.Dictionary { ["paths"] = outPaths, ["what"] = what, ["pairs"] = pairs, ["junctions"] = junctions.ToArray(),
			["network_v2"] = Stats.ToDictionary() };
	}
}
