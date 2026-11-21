using System;
using System.Collections.Generic;
using Godot;

namespace Roads.Network;

/// <summary>Нарушения геометрии пути (GeometryValidator). Флаги: одно ребро может нарушать несколько правил.</summary>
[Flags]
public enum Violation
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

/// <summary>Числа V2: значения V1 приходят из GDScript (StageTrails, RoadTuning) — здесь только чтение словаря.
/// Нет ключа — исключение с понятным текстом (ошибка громко, без молчаливых значений по умолчанию).</summary>
public sealed class Params
{
	public readonly int W, H;
	public readonly double Tile, HeightScale;
	public readonly double TrailGrade, MountainGrade, BenchCross;
	public readonly double ClimbTrail, ClimbMountain, TurnTrail, TurnMountain, BendTrail, BendMountain;
	public readonly double WidthTrail, WidthMountain;
	public readonly double ExitR, ExitMul, AvoidCost, AvoidR, HumanReuse;
	public readonly int ParallelRun, NodeCells, FordLen, CrossRun, JitterRun, RejoinGap;
	public readonly double ParallelShare, NearNet, LevelGap;
	public readonly double NodeSep, NodeSame, MaxDegree;
	public readonly double LoopRatio, LoopAccept, LoopShare, LoopLenOld, FarR, FarShare;
	public readonly double WindowMargin, WindowRetry;
	public readonly double RidgeTpi, RidgeMul, BreakTpi, BreakMul, EcoLow, EcoHigh, EcoMul, ShoreBand, ShoreMul;
	public readonly double ReliefSigma, ReliefWideSigma, MeanderSigma, MeanderRms, MeanderFlat, MeanderSlope;
	public readonly double MeanderRoad, MeanderAmp, MeanderMountain, MeanderRide, MulMin, MulMax;
	public readonly int EcoRadius, ShapeRadius, ShapePortal, ShapeMin;
	public readonly double BranchLen, ShoreGap, ViewGap, ViewRise, ShoreReach, ViewReach, ShoreShare, MountainDetour, MountainReach;
	public readonly double ProfileBase, LineRelax, Reach;
	public readonly double ExitAngle, ExitChord, SpurNetFloor, RideNodeSep;

	public Params(Godot.Collections.Dictionary d)
	{
		W = (int)Num(d, "W"); H = (int)Num(d, "H");
		Tile = Num(d, "tile"); HeightScale = Num(d, "height_scale");
		TrailGrade = Num(d, "trail_grade"); MountainGrade = Num(d, "mountain_grade"); BenchCross = Num(d, "bench_cross");
		ClimbTrail = Num(d, "climb_trail"); ClimbMountain = Num(d, "climb_mountain");
		TurnTrail = Num(d, "turn_trail"); TurnMountain = Num(d, "turn_mountain");
		BendTrail = Num(d, "bend_trail"); BendMountain = Num(d, "bend_mountain");
		WidthTrail = Num(d, "width_trail"); WidthMountain = Num(d, "width_mountain");
		ExitR = Num(d, "exit_r"); ExitMul = Num(d, "exit_mul"); AvoidCost = Num(d, "avoid_cost"); AvoidR = Num(d, "avoid_r");
		HumanReuse = Num(d, "human_reuse");
		ParallelRun = (int)Num(d, "parallel_run"); NodeCells = (int)Num(d, "node_cells"); FordLen = (int)Num(d, "ford_len");
		CrossRun = (int)Num(d, "cross_run"); JitterRun = (int)Num(d, "jitter_run"); RejoinGap = (int)Num(d, "rejoin_gap");
		ParallelShare = Num(d, "parallel_share"); NearNet = Num(d, "near_net"); LevelGap = Num(d, "level_gap");
		NodeSep = Num(d, "node_sep"); NodeSame = Num(d, "node_same"); MaxDegree = Num(d, "max_degree");
		LoopRatio = Num(d, "loop_ratio"); LoopAccept = Num(d, "loop_accept"); LoopShare = Num(d, "loop_share");
		LoopLenOld = Num(d, "loop_len_old"); FarR = Num(d, "far_r"); FarShare = Num(d, "far_share");
		WindowMargin = Num(d, "window_margin"); WindowRetry = Num(d, "window_retry");
		RidgeTpi = Num(d, "ridge_tpi"); RidgeMul = Num(d, "ridge_mul");
		BreakTpi = Num(d, "break_tpi"); BreakMul = Num(d, "break_mul");
		EcoLow = Num(d, "eco_low"); EcoHigh = Num(d, "eco_high"); EcoMul = Num(d, "eco_mul");
		EcoRadius = (int)Num(d, "eco_radius");
		MeanderAmp = Num(d, "meander_amp"); MeanderFlat = Num(d, "meander_flat"); MeanderSlope = Num(d, "meander_slope");
		MeanderRoad = Num(d, "meander_amp_road"); MeanderMountain = Num(d, "meander_amp_mountain"); MeanderRide = Num(d, "meander_amp_ride");
		ReliefSigma = Num(d, "relief_sigma"); ReliefWideSigma = Num(d, "relief_wide_sigma");
		MeanderSigma = Num(d, "meander_sigma"); MeanderRms = Num(d, "meander_rms");
		ShoreBand = Num(d, "shore_band"); ShoreMul = Num(d, "shore_mul");
		MulMin = Num(d, "mul_min"); MulMax = Num(d, "mul_max");
		ShapeRadius = (int)Num(d, "shape_radius"); ShapePortal = (int)Num(d, "shape_portal"); ShapeMin = (int)Num(d, "shape_min");
		BranchLen = Num(d, "branch_len"); ShoreGap = Num(d, "shore_gap"); ViewGap = Num(d, "view_gap");
		ViewRise = Num(d, "view_rise");
		ShoreReach = Num(d, "shore_reach"); ViewReach = Num(d, "view_reach"); ShoreShare = Num(d, "shore_share");
		MountainDetour = Num(d, "mountain_detour"); MountainReach = Num(d, "mountain_reach");
		ProfileBase = Num(d, "profile_base"); LineRelax = Num(d, "line_relax"); Reach = Num(d, "reach");
		ExitAngle = Num(d, "exit_angle"); ExitChord = Num(d, "exit_chord"); SpurNetFloor = Num(d, "spur_net_floor");
		RideNodeSep = Num(d, "ride_node_sep");
		if (W <= 0 || H <= 0 || !(Tile > 0)) throw new ArgumentException("V2: неверный размер карты или клетки");
		if (!(MulMin > 0.0 && MulMin <= 1.0 && MulMax >= 1.0 && MeanderSlope > MeanderFlat &&
			ReliefSigma > 0.0 && ReliefWideSigma > ReliefSigma && MeanderSigma > 0.0 && MeanderRms > 0.0 &&
			RidgeTpi > 0.0 && BreakTpi > 0.0 && ShoreBand > 0.0 && EcoRadius > 0 &&
			ShapeRadius > 0 && ShapePortal >= 0 && ShapeMin > 0))
			throw new ArgumentException("V2: неверные параметры поля характера");
	}

	public double Meander(string kind) => kind switch
	{
		"road" => MeanderRoad, "mountain" => MeanderMountain, "ride" => MeanderRide, _ => MeanderAmp,
	};

	public static double Num(Godot.Collections.Dictionary d, string key)
	{
		if (!d.ContainsKey(key)) throw new ArgumentException("V2: нет ключа «" + key + "» во входе");
		return d[key].AsDouble();
	}
}

/// <summary>Счётчики и время частей V2 — блок generation_profile.network_v2.</summary>
public sealed class NetStats
{
	private readonly SortedDictionary<string, double> _ms = new(StringComparer.Ordinal);
	private readonly SortedDictionary<string, int> _counts = new(StringComparer.Ordinal);
	private readonly SortedDictionary<string, int> _rejects = new(StringComparer.Ordinal);

	public void Time(string key, long since) =>
		_ms[key] = (_ms.TryGetValue(key, out var v) ? v : 0.0) + (System.Diagnostics.Stopwatch.GetTimestamp() - since) * 1000.0 / System.Diagnostics.Stopwatch.Frequency;
	public void Count(string key, int add = 1) => _counts[key] = (_counts.TryGetValue(key, out var v) ? v : 0) + add;
	public void Reject(string reason) => _rejects[reason] = (_rejects.TryGetValue(reason, out var v) ? v : 0) + 1;
	public readonly List<string> Log = new();
	public static long Now() => System.Diagnostics.Stopwatch.GetTimestamp();

	public Godot.Collections.Dictionary ToDictionary()
	{
		var ms = new Godot.Collections.Dictionary();
		foreach (var (k, v) in _ms) ms[k] = Math.Round(v, 3);
		var counts = new Godot.Collections.Dictionary();
		foreach (var (k, v) in _counts) counts[k] = v;
		var rejects = new Godot.Collections.Dictionary();
		foreach (var (k, v) in _rejects) rejects[k] = v;
		var log = new Godot.Collections.Array();
		foreach (var line in Log) log.Add(line);
		return new Godot.Collections.Dictionary { ["ms"] = ms, ["counts"] = counts, ["rejects"] = rejects, ["log"] = log };
	}
}

/// <summary>Прямоугольник клеток x0 ≤ x &lt; x1, y0 ≤ y &lt; y1.</summary>
public readonly struct CellRect
{
	public readonly int X0, Y0, X1, Y1;
	public CellRect(int x0, int y0, int x1, int y1) { X0 = x0; Y0 = y0; X1 = x1; Y1 = y1; }
	public CellRect Grow(int m, int w, int h) => new(Math.Max(0, X0 - m), Math.Max(0, Y0 - m), Math.Min(w, X1 + m), Math.Min(h, Y1 + m));
	public static CellRect Of(int a, int b, int w) =>
		new(Math.Min(a % w, b % w), Math.Min(a / w, b / w), Math.Max(a % w, b % w) + 1, Math.Max(a / w, b / w) + 1);
	public bool Empty => X1 <= X0 || Y1 <= Y0;
}

/// <summary>Двоичная куча (ключ, номер) с детерминированным разрывом равенства по номеру.</summary>
internal sealed class MinHeap
{
	private readonly List<(double Key, int Id)> _items = new();
	public int Count => _items.Count;
	public void Clear() => _items.Clear();

	private static bool Less((double Key, int Id) a, (double Key, int Id) b) => a.Key < b.Key || a.Key == b.Key && a.Id < b.Id;

	public void Push(double key, int id)
	{
		_items.Add((key, id));
		int i = _items.Count - 1;
		while (i > 0)
		{
			int p = (i - 1) / 2;
			if (!Less(_items[i], _items[p])) break;
			(_items[i], _items[p]) = (_items[p], _items[i]);
			i = p;
		}
	}

	public (double Key, int Id) Pop()
	{
		var top = _items[0];
		var last = _items[^1];
		_items.RemoveAt(_items.Count - 1);
		if (_items.Count > 0)
		{
			_items[0] = last;
			int i = 0;
			while (true)
			{
				int l = 2 * i + 1, r = l + 1, m = i;
				if (l < _items.Count && Less(_items[l], _items[m])) m = l;
				if (r < _items.Count && Less(_items[r], _items[m])) m = r;
				if (m == i) break;
				(_items[i], _items[m]) = (_items[m], _items[i]);
				i = m;
			}
		}
		return top;
	}
}
