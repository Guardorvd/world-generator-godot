using System;
using System.Threading;
using Godot;

/// <summary>
/// 15.11.2026: опора и вода для физики велосипеда и пешехода на C# — копия Heightfield.ground_at, deck_at,
/// surface_at, depth_at и immersion_at внутри стартового плана (тот же порядок действий, расчёт в double,
/// значения массивов во float — ответ бит в бит тот же). Данные — неизменяемый снимок Heightfield: hv, метровая
/// сетка дорог RoadRefinement, мосты и туннели плана, ленты рек и озёра. Heightfield сбрасывает снимок
/// при любой смене опоры (ground_changed) и строит заново на главном потоке.
/// Вне плана (закреплённые области), в полосе у края карты и без снимка ответ — NaN: тогда считает GDScript.
/// </summary>
public partial class RideGround : RefCounted
{
	private sealed class Snapshot
	{
		public int W, H, RoadH;
		public double Tile, Hs, LakeDrop;
		public float[] Hv = Array.Empty<float>();
		public FineRelief Detail;
		public bool DetailForPlacement;
		// метровая сетка дорог: клетка -> номер участка (-1 — нет), высоты участков по Stride*Stride
		public int[] PatchOf = Array.Empty<int>();
		public float[] PatchH = Array.Empty<float>();
		public bool Roads;
		// мосты и туннели: клетка -> номера (CSR), поля по номеру
		public int[] StructStart = Array.Empty<int>();
		public int[] StructOf = Array.Empty<int>();
		public bool[] Tunnel = Array.Empty<bool>();
		public bool[] Rails = Array.Empty<bool>();
		public double[] Geo = Array.Empty<double>(); // по GeoStride: ax, az, ay, bx, bz, by, half, len, ux, uz, arch
		// sin(PI * k / count) дуги моста, посчитанные движком (GDScript): sin движка и .NET расходятся в последнем бите
		public int[] SineStart = Array.Empty<int>();
		public double[] Sines = Array.Empty<double>();
		// ленты рек: по 12 чисел на отрезок, клетка -> отрезки (CSR); озёра
		public float[] SegPts = Array.Empty<float>();
		public int[] SegStart = Array.Empty<int>();
		public int[] SegOf = Array.Empty<int>();
		public byte[] Lake = Array.Empty<byte>();
		public float[] Filled = Array.Empty<float>();
	}

	private const int Div = 4;          // RoadRefinement.DIV
	private const int Stride = Div + 1; // RoadRefinement.STRIDE
	private const int GeoStride = 11;
	private const double Step = 0.8;          // Heightfield.STEP
	private const double BridgeSection = 2.0; // Heightfield.BRIDGE_SECTION
	private Snapshot _snap;
	private string _error = "";

	public string Error() => _error;
	public bool Ready() => Volatile.Read(ref _snap) != null;
	public void Invalidate() => Volatile.Write(ref _snap, null);

	public void SetFineRelief(FineRelief detail, bool forPlacement)
	{
		var snapshot = Volatile.Read(ref _snap);
		if (snapshot == null)
			return;
		snapshot.Detail = detail;
		snapshot.DetailForPlacement = forPlacement;
	}

	/// <summary>Новый снимок; при ошибке входа прежний сброшен и ответы — NaN (GDScript).
	/// patchKeys — клетки участков сетки дорог, patchH — их высоты подряд по Stride*Stride.
	/// structCells/structIds — пары клетка — номер сооружения; structGeo — по 11 чисел на номер.</summary>
	public bool Build(int w, int h, double tile, double hs, double lakeDrop, float[] hv,
		int roadH, int[] patchKeys, float[] patchH, bool roads,
		int[] structCells, int[] structIds, byte[] tunnel, byte[] rails, double[] structGeo, int[] sineStart, double[] sines,
		float[] segPts, int[] pairCells, int[] pairSegs, byte[] lake, float[] filled)
	{
		Invalidate();
		long count = (long)w * h;
		if (w < 2 || h < 2 || count >= int.MaxValue || !(tile > 0) || !(hs > 0) || !double.IsFinite(lakeDrop))
			return Fail("Invalid grid");
		if (hv == null || hv.Length != count || lake == null || lake.Length != count || filled == null || filled.Length != count)
			return Fail("Heights, lakes or filled do not match W*H");
		if (patchKeys == null || patchH == null || patchH.Length != (long)patchKeys.Length * Stride * Stride)
			return Fail("Road patches do not match their keys");
		int structs = tunnel?.Length ?? -1;
		if (structs < 0 || rails == null || rails.Length != structs || structGeo == null || structGeo.Length != (long)structs * GeoStride
			|| structCells == null || structIds == null || structCells.Length != structIds.Length
			|| sineStart == null || sineStart.Length != structs + 1 || sines == null || sineStart[structs] != sines.Length)
			return Fail("Structures are incomplete");
		if (segPts == null || segPts.Length % 12 != 0 || pairCells == null || pairSegs == null || pairCells.Length != pairSegs.Length)
			return Fail("River segments are incomplete");
		var s = new Snapshot { W = w, H = h, RoadH = roadH, Tile = tile, Hs = hs, LakeDrop = lakeDrop, Hv = hv, PatchH = patchH,
			Roads = roads, Tunnel = new bool[structs], Rails = new bool[structs], Geo = structGeo, SineStart = sineStart, Sines = sines, SegPts = segPts, Lake = lake, Filled = filled };
		s.PatchOf = new int[count];
		Array.Fill(s.PatchOf, -1);
		for (int k = 0; k < patchKeys.Length; k++)
		{
			if ((uint)patchKeys[k] >= (uint)count) return Fail("Road patch outside the map");
			s.PatchOf[patchKeys[k]] = k;
		}
		for (int k = 0; k < structs; k++)
		{
			s.Tunnel[k] = tunnel[k] != 0;
			s.Rails[k] = rails[k] != 0;
		}
		foreach (int c in structCells)
			if ((uint)c >= (uint)count) return Fail("Structure cell outside the map");
		foreach (int id in structIds)
			if ((uint)id >= (uint)structs) return Fail("Structure id out of range");
		(s.StructStart, s.StructOf) = Csr((int)count, structCells, structIds);
		int segs = segPts.Length / 12;
		foreach (int c in pairCells)
			if ((uint)c >= (uint)count) return Fail("River cell outside the map");
		foreach (int id in pairSegs)
			if ((uint)id >= (uint)segs) return Fail("River segment out of range");
		(s.SegStart, s.SegOf) = Csr((int)count, pairCells, pairSegs);
		_error = "";
		Volatile.Write(ref _snap, s);
		return true;
	}

	private bool Fail(string reason)
	{
		_error = reason;
		return false;
	}

	/// <summary>Индекс клетка -> значения в порядке пар (как списки словарей Heightfield).</summary>
	private static (int[], int[]) Csr(int count, int[] cells, int[] values)
	{
		var start = new int[count + 1];
		foreach (int c in cells)
			start[c + 1]++;
		for (int i = 0; i < count; i++)
			start[i + 1] += start[i];
		var of = new int[values.Length];
		var fill = (int[])start.Clone();
		for (int k = 0; k < cells.Length; k++)
			of[fill[cells[k]]++] = values[k];
		return (start, of);
	}

	/// <summary>Точка, где ответ целиком считается здесь: внутри сетки высот плана (без полосы у края).</summary>
	private static bool Inside(Snapshot s, double x, double z)
	{
		double fx = x / s.Tile - 0.5, fz = z / s.Tile - 0.5;
		return fx >= 0.0 && fz >= 0.0 && fx <= s.W - 1.001 && fz <= s.H - 1.001;
	}

	/// <summary>Heightfield.ground_at(x, z) (не raw).</summary>
	public double Ground(double x, double z)
	{
		var s = Volatile.Read(ref _snap);
		if (s == null || !Inside(s, x, z)) return double.NaN;
		return GroundIn(s, x, z);
	}

	private static double GroundIn(Snapshot s, double x, double z)
	{
		int W = s.W;
		double fx = x / s.Tile - 0.5, fz = z / s.Tile - 0.5;
		if (s.Roads && !(fx < 0.0 || fz < 0.0 || fx >= W - 1 || fz >= s.RoadH - 1))
		{
			int patch = s.PatchOf[(int)Math.Floor(fz) * W + (int)Math.Floor(fx)];
			if (patch >= 0)
			{
				double sx = (fx - Math.Floor(fx)) * Div;
				double sz = (fz - Math.Floor(fz)) * Div;
				int ix = Math.Min(Div - 1, (int)Math.Floor(sx));
				int iz = Math.Min(Div - 1, (int)Math.Floor(sz));
				double tx = sx - ix, tz = sz - iz;
				int a = iz * Stride + ix;
				var hs = s.PatchH;
				int o = patch * Stride * Stride;
				if (tx + tz <= 1.0)
					return hs[o + a] + (hs[o + a + 1] - (double)hs[o + a]) * tx + (hs[o + a + Stride] - (double)hs[o + a]) * tz;
				int d = a + Stride + 1;
				return hs[o + d] + (hs[o + a + Stride] - (double)hs[o + d]) * (1.0 - tx) + (hs[o + a + 1] - (double)hs[o + d]) * (1.0 - tz);
			}
		}
		if (s.Detail != null)
		{
			double detail = s.Detail.SampleSurface(x, z, s.DetailForPlacement);
			if (!double.IsNaN(detail))
				return detail;
		}
		{
			var arr = s.Hv;
			int i = (int)Math.Floor(fx), j = (int)Math.Floor(fz);
			double ha = arr[j * W + i], hb = arr[j * W + i + 1], hc = arr[(j + 1) * W + i], hd = arr[(j + 1) * W + i + 1];
			double u = fx - i, v = fz - j;
			if (u + v <= 1.0)
				return ha + (hb - ha) * u + (hc - ha) * v;
			return hd + (hc - hd) * (1.0 - u) + (hb - hd) * (1.0 - v);
		}
	}

	/// <summary>Heightfield.level(s, t): высота настила или пола сооружения k в t метрах от начала оси.</summary>
	private static double Level(Snapshot s, int k, double t)
	{
		var g = s.Geo;
		int o = k * GeoStride;
		double ay = g[o + 2], by = g[o + 5], len = g[o + 7], arch = g[o + 10];
		double u = Math.Clamp(t / len, 0.0, 1.0);
		if (arch == 0.0)
			return ay + (by - ay) * u;
		int count = Math.Max(1, (int)Math.Ceiling(len / BridgeSection));
		double section = Math.Min(u * count, count - 1.0);
		int kk = (int)Math.Floor(section);
		double blend = u * count - kk;
		int at = s.SineStart[k];
		if (s.SineStart[k + 1] - at != count + 1)
			return double.NaN; // таблица не от этой дуги: такого быть не должно (сверка покажет)
		double a = s.Sines[at + kk], b = s.Sines[at + kk + 1];
		double rise = a + (b - a) * blend;
		return ay + (by - ay) * u + arch * rise;
	}

	/// <summary>Heightfield.deck_at внутри плана.</summary>
	private static double DeckIn(Snapshot s, double x, double z, double feet)
	{
		int cx = (int)Math.Floor(x / s.Tile), cz = (int)Math.Floor(z / s.Tile);
		int cell = cz * s.W + cx;
		double best = double.NegativeInfinity;
		var g = s.Geo;
		for (int n = s.StructStart[cell]; n < s.StructStart[cell + 1]; n++)
		{
			int k = s.StructOf[n];
			if (s.Tunnel[k]) continue;
			int o = k * GeoStride;
			double dx = x - g[o], dz = z - g[o + 1];
			double t = dx * g[o + 8] + dz * g[o + 9];
			if (t < 0.0 || t > g[o + 7] || Math.Abs(dx * g[o + 9] - dz * g[o + 8]) > g[o + 6]) continue;
			double d = Level(s, k, t);
			if (feet >= d - Step)
				best = Max(best, d);
		}
		return best;
	}

	/// <summary>maxf из Godot: (a &lt; b) ? b : a.</summary>
	private static double Max(double a, double b) => a < b ? b : a;

	/// <summary>Heightfield.surface_at.</summary>
	public double Surface(double x, double z, double feet)
	{
		var s = Volatile.Read(ref _snap);
		if (s == null || !Inside(s, x, z)) return double.NaN;
		return Max(GroundIn(s, x, z), DeckIn(s, x, z, feet));
	}

	/// <summary>First blocked point on the same discrete ray as PlayerCameraController, or -1 outside the snapshot.</summary>
	public int CameraRayHit(Vector3 target, Vector3 direction, double distance, int steps, double feet, double gap, double wallRadius)
	{
		var s = Volatile.Read(ref _snap);
		if (s == null)
			return -1;
		for (int k = 1; k <= steps; k++)
		{
			Vector3 p = target - direction * (float)(distance * k / steps);
			if (!Inside(s, p.X, p.Z))
				return -1;
			double y = p.Y;
			if (y < Max(GroundIn(s, p.X, p.Z), DeckIn(s, p.X, p.Z, y)) + gap
				|| y > CeilingIn(s, p.X, p.Z, feet) - gap || WallIn(s, p.X, p.Z, y - 1.0, wallRadius))
				return k;
		}
		return steps + 1;
	}

	private static double CeilingIn(Snapshot s, double x, double z, double feet)
	{
		int cell = (int)Math.Floor(z / s.Tile) * s.W + (int)Math.Floor(x / s.Tile);
		double top = double.PositiveInfinity;
		var g = s.Geo;
		for (int n = s.StructStart[cell]; n < s.StructStart[cell + 1]; n++)
		{
			int k = s.StructOf[n];
			if (!s.Tunnel[k])
				continue;
			int o = k * GeoStride;
			double dx = x - g[o], dz = z - g[o + 1];
			double t = dx * g[o + 8] + dz * g[o + 9];
			if (t < 0.0 || t > g[o + 7] || Math.Abs(dx * g[o + 9] - dz * g[o + 8]) > g[o + 6] + TunnelWall)
				continue;
			double floor = Level(s, k, t);
			if (feet >= floor - Step && feet < floor + TunnelHeight)
				top = Math.Min(top, floor + TunnelHeight);
		}
		return top;
	}

	private static double WaterTriangle(double x, double z, double ax, double ay, double az,
		double bx, double by, double bz, double cx, double cy, double cz)
	{
		double denominator = (bz - cz) * (ax - cx) + (cx - bx) * (az - cz);
		if (Math.Abs(denominator) < 1e-8)
			return double.NegativeInfinity;
		double u = ((bz - cz) * (x - cx) + (cx - bx) * (z - cz)) / denominator;
		double v = ((cz - az) * (x - cx) + (ax - cx) * (z - cz)) / denominator;
		if (u < -1e-5 || v < -1e-5 || u + v > 1.00001)
			return double.NegativeInfinity;
		return u * ay + v * by + (1.0 - u - v) * cy;
	}

	private static double RiverLevel(Snapshot s, double x, double z)
	{
		int cell = (int)Math.Floor(z / s.Tile) * s.W + (int)Math.Floor(x / s.Tile);
		double top = double.NegativeInfinity;
		var p = s.SegPts;
		for (int k = s.SegStart[cell]; k < s.SegStart[cell + 1]; k++)
		{
			int o = s.SegOf[k] * 12;
			top = Max(top, WaterTriangle(x, z, p[o], p[o + 1], p[o + 2], p[o + 3], p[o + 4], p[o + 5], p[o + 6], p[o + 7], p[o + 8]));
			top = Max(top, WaterTriangle(x, z, p[o + 6], p[o + 7], p[o + 8], p[o + 3], p[o + 4], p[o + 5], p[o + 9], p[o + 10], p[o + 11]));
		}
		return top;
	}

	private static double LakeLevel(Snapshot s, double x, double z)
	{
		int cx = (int)Math.Floor(x / s.Tile - 0.5);
		int cy = (int)Math.Floor(z / s.Tile - 0.5);
		int W = s.W;
		if (cx < 0 || cy < 0 || cx >= W - 1 || cy >= s.H - 1)
			return double.NegativeInfinity;
		int a = cy * W + cx;
		double top = double.NegativeInfinity;
		var lake = s.Lake;
		if (lake[a] != 0 || lake[a + 1] != 0 || lake[a + W] != 0 || lake[a + W + 1] != 0)
		{
			var filled = s.Filled;
			if (lake[a] != 0) top = filled[a] * s.Hs - s.LakeDrop;
			if (lake[a + 1] != 0) top = Max(top, filled[a + 1] * s.Hs - s.LakeDrop);
			a += W;
			if (lake[a] != 0) top = Max(top, filled[a] * s.Hs - s.LakeDrop);
			if (lake[a + 1] != 0) top = Max(top, filled[a + 1] * s.Hs - s.LakeDrop);
		}
		return top;
	}

	private static double DepthIn(Snapshot s, double x, double z, double feet)
	{
		if (feet > double.NegativeInfinity && DeckIn(s, x, z, feet) > double.NegativeInfinity)
			return 0.0;
		double l = Max(0.0, Max(RiverLevel(s, x, z), LakeLevel(s, x, z)));
		return Max(0.0, l - GroundIn(s, x, z));
	}

	/// <summary>Heightfield.depth_at (feet = -INF — без мостов).</summary>
	public double Depth(double x, double z, double feet)
	{
		var s = Volatile.Read(ref _snap);
		if (s == null || !Inside(s, x, z)) return double.NaN;
		return DepthIn(s, x, z, feet);
	}

	/// <summary>
	/// Heightfield.ground_depth_at одним вызовом: (грунт, глубина без мостов), как Vector2 GDScript (float32).
	/// Вне снимка — (NaN, NaN): тогда считает GDScript.
	/// </summary>
	public Godot.Vector2 GroundDepth(double x, double z)
	{
		var s = Volatile.Read(ref _snap);
		if (s == null || !Inside(s, x, z)) return new Godot.Vector2(float.NaN, float.NaN);
		return new Godot.Vector2((float)GroundIn(s, x, z), (float)DepthIn(s, x, z, double.NegativeInfinity));
	}

	/// <summary>Heightfield.immersion_at.</summary>
	public double Immersion(double x, double z, double feet)
	{
		var s = Volatile.Read(ref _snap);
		if (s == null || !Inside(s, x, z)) return double.NaN;
		double depth = DepthIn(s, x, z, feet);
		if (depth <= 0.0)
			return 0.0;
		return Math.Clamp(GroundIn(s, x, z) + depth - feet, 0.0, depth);
	}
}
