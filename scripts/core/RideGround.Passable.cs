using System;
using System.Collections.Generic;
using System.Threading;
using Godot;

/// <summary>
/// 15.11.2026, этап 2: проверка габарита PlayerState.is_passable на C# одним вызовом — край открытой земли
/// (WorldData.accessible, Heightfield.known), дома поселений и постройки мест, перила мостов и стены туннелей
/// (Heightfield.wall_at), стволы, валуны и валежник (ForestObstacles.hits), брод (depth_at). Тот же порядок
/// арифметики: double, а где GDScript считает в Vector2 (ForestObstacles) — во float, как движок.
/// cos/sin поворота построек и синусы дуги мостов приходят из движка (sin .NET расходится в последнем бите).
/// Ответ: 1 — свободно, 0 — занято, -1 — не знаю (нет снимка, точка у края плана, где бывают поселения
/// закреплённых областей, или за открытой территорией): тогда считает GDScript.
/// </summary>
public partial class RideGround
{
	private sealed class Places
	{
		public int RectX, RectY, RectW, RectH; // WorldData.available_rect (клетки), без площади — всё открыто
		public bool HasOuter;
		public double SettlementReach, SiteReach, FordDepth; // GameConfig.FORD_DEPTH
		// поселения и места по клеткам столкновений (OuterLand.collision_cell): CSR номеров, номера — по 2 числа центра
		public Dictionary<long, int[]> SettlementCells = new(), SiteCells = new();
		public double[] Centers = Array.Empty<double>();
		// постройки каждого места подряд: x, y (клетки), cos, sin, half.x, half.y
		public int[] HutStart = Array.Empty<int>();
		public double[] Huts = Array.Empty<double>();
	}

	private sealed class Obstacles
	{
		public float[] Data = Array.Empty<float>();
		public Dictionary<long, int[]> Grid = new();
	}

	private const int HutStride = 6;
	private const double Wall = 0.6, TunnelWall = 1.0, TunnelHeight = 4.5; // Heightfield.WALL, TUNNEL_WALL, TUNNEL_HEIGHT
	private const double Cell = 2.0;      // ForestObstacles.CELL
	private const int ObstacleStride = 7; // ForestObstacles.STRIDE
	private Places _places;
	private Obstacles _obstacles = new();

	private static long Key(int x, int y) => ((long)x << 32) ^ (uint)y;

	/// <summary>Места для проверки построек. places — центры (x, y в клетках) подряд; hutStart — начало построек
	/// каждого места в huts (по 6 чисел), последний элемент — конец. settlementCells/siteCells — пары
	/// (ключ клетки x, y; номер места), как OuterLand.index_collision_places.</summary>
	public bool SetPlaces(int rx, int ry, int rw, int rh, bool hasOuter, double settlementReach, double siteReach, double fordDepth,
		double[] centers, int[] hutStart, double[] huts, int[] settlementCells, int[] siteCells)
	{
		Volatile.Write(ref _places, null);
		int count = centers.Length / 2;
		if (centers.Length % 2 != 0 || hutStart.Length != count + 1 || hutStart[count] * HutStride != huts.Length
			|| settlementCells.Length % 3 != 0 || siteCells.Length % 3 != 0)
			return Fail("Places are incomplete");
		var p = new Places { RectX = rx, RectY = ry, RectW = rw, RectH = rh, HasOuter = hasOuter, SettlementReach = settlementReach,
			SiteReach = siteReach, FordDepth = fordDepth, Centers = centers, HutStart = hutStart, Huts = huts };
		if (!Index(p.SettlementCells, settlementCells, count) || !Index(p.SiteCells, siteCells, count))
			return Fail("Place index out of range");
		Volatile.Write(ref _places, p);
		return true;
	}

	private static bool Index(Dictionary<long, int[]> cells, int[] triples, int count)
	{
		var lists = new Dictionary<long, List<int>>();
		for (int k = 0; k < triples.Length; k += 3)
		{
			if ((uint)triples[k + 2] >= (uint)count) return false;
			long key = Key(triples[k], triples[k + 1]);
			if (!lists.TryGetValue(key, out var list)) lists[key] = list = new List<int>();
			list.Add(triples[k + 2]);
		}
		foreach (var pair in lists)
			cells[pair.Key] = pair.Value.ToArray();
		return true;
	}

	/// <summary>Препятствия ForestObstacles: data по 7 float и его сетка (тройки x, y клетки и начало записи).</summary>
	public bool SetObstacles(float[] data, int[] grid)
	{
		if (data.Length % ObstacleStride != 0 || grid.Length % 3 != 0)
			return Fail("Obstacles are incomplete");
		var o = new Obstacles { Data = data };
		var lists = new Dictionary<long, List<int>>();
		for (int k = 0; k < grid.Length; k += 3)
		{
			if (grid[k + 2] < 0 || grid[k + 2] + ObstacleStride > data.Length) return Fail("Obstacle grid out of range");
			long key = Key(grid[k], grid[k + 1]);
			if (!lists.TryGetValue(key, out var list)) lists[key] = list = new List<int>();
			list.Add(grid[k + 2]);
		}
		foreach (var pair in lists)
			o.Grid[pair.Key] = pair.Value.ToArray();
		Volatile.Write(ref _obstacles, o);
		return true;
	}

	public int Passable(double x, double z, double feet, double r, bool objectsOnly, double climb, bool aboveWater)
	{
		var s = Volatile.Read(ref _snap);
		var p = Volatile.Read(ref _places);
		var o = Volatile.Read(ref _obstacles);
		if (s == null || p == null || !Inside(s, x, z)) return -1;
		// поселения закреплённых областей стоят за краем плана, но клетки их стен заходят в план на две клетки столкновений
		if (p.HasOuter)
		{
			double edge = 2.0 * p.SettlementReach + 1.0;
			if (x < edge || z < edge || x > s.W * s.Tile - edge || z > s.H * s.Tile - edge) return -1;
		}
		if (!objectsOnly)
		{
			// WorldData.accessible: внутри открытой территории с запасом тела; иначе решает GDScript (закреплённые области)
			if (p.RectW > 0 && p.RectH > 0)
			{
				double cx = x / s.Tile, cy = z / s.Tile, margin = r / s.Tile;
				if (!(cx >= p.RectX + margin && cy >= p.RectY + margin && cx < (p.RectX + p.RectW) - margin && cy < (p.RectY + p.RectH) - margin))
					return -1;
			}
			// Heightfield.known: в плане земля известна; без OuterLand — не ближе клетки к краю карты
			if (!p.HasOuter && !(x >= s.Tile && z >= s.Tile && x <= (s.W - 1) * s.Tile && z <= (s.H - 1) * s.Tile))
				return 0;
		}
		long cell = Key((int)Math.Floor(x / p.SettlementReach), (int)Math.Floor(z / p.SettlementReach));
		if (HitsPlaces(p, p.SettlementCells, cell, p.SettlementReach, s.Tile, x, z, r)) return 0;
		if (HitsPlaces(p, p.SiteCells, cell, p.SiteReach, s.Tile, x, z, r)) return 0;
		if (WallIn(s, x, z, feet, r)) return 0;
		if (HitsObstacle(o, x, z, feet, r, climb)) return 0;
		if (objectsOnly) return 1;
		double depth = DepthIn(s, x, z, feet);
		return depth < p.FordDepth || (aboveWater && feet > GroundIn(s, x, z) + depth) ? 1 : 0;
	}


	private static bool HitsPlaces(Places p, Dictionary<long, int[]> cells, long cell, double reach, double tile, double x, double z, double r)
	{
		if (!cells.TryGetValue(cell, out var list)) return false;
		foreach (int k in list)
		{
			if (Math.Abs(p.Centers[k * 2] * tile - x) > reach || Math.Abs(p.Centers[k * 2 + 1] * tile - z) > reach)
				continue;
			for (int u = p.HutStart[k]; u < p.HutStart[k + 1]; u++)
			{
				int o = u * HutStride;
				var h = p.Huts;
				if (BoxHits(x - h[o] * tile, z - h[o + 1] * tile, h[o + 2], h[o + 3], h[o + 4], h[o + 5], r))
					return true;
			}
		}
		return false;
	}

	/// <summary>PlayerState._box_hits с cos и sin угла из движка.</summary>
	private static bool BoxHits(double dx, double dz, double cos, double sin, double hx, double hz, double r)
	{
		double reach = Max(hx, hz) * 1.5 + r;
		if (Math.Abs(dx) > reach || Math.Abs(dz) > reach)
			return false;
		double ox = Math.Abs(dx * cos - dz * sin) - hx;
		double oz = Math.Abs(dx * sin + dz * cos) - hz;
		return ox < r && oz < r && (ox <= 0.0 || oz <= 0.0 || ox * ox + oz * oz < r * r);
	}

	/// <summary>Heightfield.wall_at внутри плана.</summary>
	private static bool WallIn(Snapshot s, double x, double z, double feet, double r)
	{
		int cell = (int)Math.Floor(z / s.Tile) * s.W + (int)Math.Floor(x / s.Tile);
		bool wall = false;
		var g = s.Geo;
		for (int n = s.StructStart[cell]; n < s.StructStart[cell + 1]; n++)
		{
			int k = s.StructOf[n];
			int o = k * GeoStride;
			double dx = x - g[o], dz = z - g[o + 1];
			double t = dx * g[o + 8] + dz * g[o + 9];
			double side = Math.Abs(dx * g[o + 9] - dz * g[o + 8]);
			bool tunnel = s.Tunnel[k];
			if (t < 0.0 || t > g[o + 7] || side > g[o + 6] + (tunnel ? TunnelWall : Wall) + r)
				continue;
			if (!tunnel && !s.Rails[k])
				continue;
			double d = Level(s, k, t);
			bool onLevel = tunnel ? feet < d + TunnelHeight : (feet >= d - Step && feet < d + 1.5);
			if (!onLevel)
				continue;
			if (side <= g[o + 6] - r)
				return false;
			wall = true;
		}
		return wall;
	}

	/// <summary>ForestObstacles.hits: Vector2 движка — float, поэтому ось и расстояние во float.</summary>
	private static bool HitsObstacle(Obstacles o, double x, double z, double feet, double r, double climb)
	{
		var d = o.Data;
		if (d.Length == 0) return false;
		float px = (float)x, pz = (float)z;
		int y0 = (int)Math.Floor((z - r) / Cell), y1 = (int)Math.Floor((z + r) / Cell);
		int x0 = (int)Math.Floor((x - r) / Cell), x1 = (int)Math.Floor((x + r) / Cell);
		for (int cy = y0; cy <= y1; cy++)
			for (int cx = x0; cx <= x1; cx++)
			{
				if (!o.Grid.TryGetValue(Key(cx, cy), out var list)) continue;
				foreach (int at in list)
				{
					if (feet >= d[at + 6] || (double)d[at + 6] - d[at + 5] <= climb)
						continue;
					double reach = d[at + 4] + r;
					// _on_axis
					float ax = d[at], az = d[at + 1];
					float abx = d[at + 2] - ax, abz = d[at + 3] - az;
					float ln = abx * abx + abz * abz;
					float qx = ax, qz = az;
					if (!(ln < 1e-8))
					{
						float vx = px - ax, vz = pz - az;
						float dot = vx * abx + vz * abz;
						float t = (float)Math.Clamp((double)dot / ln, 0.0, 1.0);
						qx = ax + abx * t;
						qz = az + abz * t;
					}
					float ex = px - qx, ez = pz - qz;
					float dist = MathF.Sqrt(ex * ex + ez * ez);
					if (reach - dist > 0.0)
						return true;
				}
			}
		return false;
	}
}
