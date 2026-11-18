using System;
using System.Threading;
using Godot;

public partial class FastGrid
{
	/// <summary>RockRelief.apply; exclusions are (x, y, radius) triples in local grid cells.</summary>
	public Godot.Collections.Dictionary ApplyRockRelief(int width, int height, Vector2I origin, long seed,
		float[] heights, float[] elevation, float[] slope, byte[] biome, byte[] exposure, float[] waterDistance,
		byte[] paths, byte[] waterBiomes, double[] exclusions, int rockBiome, int peakBiome,
		double heightScale, double tile, int edge, double pathClear, double pathFull, double maxShift)
	{
		int cells = width * height;
		var distance = DistanceSources(cells, paths, 1);
		for (int n = 0; n < exclusions.Length; n += 3)
		{
			double x = exclusions[n], y = exclusions[n + 1], r = exclusions[n + 2];
			int x0 = Math.Max(0, (int)Math.Floor(x - r));
			int x1 = Math.Min(width, (int)Math.Ceiling(x + r) + 1);
			int y0 = Math.Max(0, (int)Math.Floor(y - r));
			int y1 = Math.Min(height, (int)Math.Ceiling(y + r) + 1);
			for (int yy = y0; yy < y1; yy++)
				for (int xx = x0; xx < x1; xx++)
					distance[yy * width + xx] = 0f;
		}
		PropagateDistances(width, height, distance);

		uint s = unchecked((uint)seed);
		const uint Salt = 0x524c4946;
		var sturdy = new RockLattice(s, 28.0, 0x434f4d50, origin, width, height);
		var crag = new RockLattice(s, 90.0, 0x43524147, origin, width, height);
		var band = new RockLattice(s, 70.0, 0x42414e44, origin, width, height);
		var phase = new RockLattice(s, 45.0, 0x50484153, origin, width, height);
		var teeth = new RockLattice(s ^ Salt, 5.0, 0x5a554243, origin, width, height);
		var spire = new RockLattice(s ^ Salt, 4.5, 0x53504952, origin, width, height);
		bool hasWaterDistance = waterDistance.Length == cells;
		int changed = 0;
		// Each row writes directly to its own heights; all contour lookups read the original elevation field.
		// The interop call copied the height array, so these writes never mutate a shared Godot buffer.
		int first = edge + 1;
		RunRows(Math.Max(0, height - 2 * first), cells >= 65536, row =>
		{
			int y = row + first;
			int edgeY = Math.Min(y, height - 1 - y);
			int wy = y + origin.Y;
			int count = 0;
			for (int x = first; x < width - first; x++)
			{
				int i = y * width + x;
				double e = elevation[i];
				int bi = biome[i];
				if (e <= 0.12 || waterBiomes[bi] != 0 || distance[i] * tile <= pathClear)
					continue;
				double exposed = bi == rockBiome || bi == peakBiome ? Math.Max(0.62, exposure[i] / 255.0) : exposure[i] / 255.0;
				if (exposed <= 0.3 || (hasWaterDistance && waterDistance[i] <= 3.0))
					continue;
				double rock = ReliefSmooth(0.3, 0.62, exposed) * ReliefSmooth(0.12, 0.3, e);
				rock *= ReliefSmooth(edge, edge + 6, Math.Min(edgeY, Math.Min(x, width - 1 - x)));
				rock *= ReliefSmooth(pathClear, pathFull, distance[i] * tile);
				if (hasWaterDistance)
					rock *= ReliefSmooth(3.0, 6.0, waterDistance[i]);
				double convex = (e - ((double)elevation[i - 1] + elevation[i + 1] + elevation[i - width] + elevation[i + width]) * 0.25) * heightScale;
				double grade = slope[i];
				if (grade <= 0.15 && convex <= 0.0)
					continue;
				int wx = x + origin.X;
				double spacing = RoadLerp(9.0, 21.0, band.At(wx, wy));
				// GDScript stores the strata pair in a Vector2 and the shift in a PackedFloat32Array.
				double shift = RockShift(e * heightScale, grade, convex, rock, sturdy.At(wx, wy), crag.At(wx, wy),
					(float)spacing, (float)(phase.At(wx, wy) * spacing * 3.0), teeth.At(wx, wy), spire.At(wx, wy), maxShift);
				if (Math.Abs(shift) >= 0.01)
				{
					heights[i] += (float)shift;
					count++;
				}
			}
			if (count != 0)
				Interlocked.Add(ref changed, count);
		});
		return new Godot.Collections.Dictionary { ["height"] = heights, ["changed"] = changed };
	}

	private static double RockShift(double h, double slope, double convex, double rock, double sturdy, double crag,
		double spacing, double phase, double teeth, double spire, double maxShift)
	{
		double u = (h - phase) / spacing;
		double bed = Math.Floor(u);
		double f = u - bed;
		double competence = ReliefSmooth(0.24, 0.7, sturdy);
		int bedType = (int)bed % 3;
		double k = RoadLerp(2.8, 6.5, competence);
		double terrace = (Math.Pow(f, k) - f + (0.5 - 1.0 / (k + 1.0)) * 6.0 * f * (1.0 - f)) * spacing;
		double ledge = RoadLerp(0.18, 1.0, competence);
		if (bedType == 1 || bedType == -2)
			ledge *= RoadLerp(0.22, 0.82, competence);
		double open = ReliefSmooth(0.22, 0.72, crag);
		double steep = ReliefSmooth(0.15, 0.5, slope);
		double shift = terrace * ledge * RoadLerp(0.3, 1.05, open) * steep;
		double fracture = ReliefSmooth(0.26, 0.77, teeth);
		double ribs = ReliefSmooth(0.0, 0.65, convex);
		shift += (fracture - 0.45) * RoadLerp(2.0, 6.4, 1.0 - competence) * open * steep;
		shift += ReliefSmooth(0.52, 0.87, spire) * 5.2 * ribs * open;
		return Math.Clamp(shift * rock, -maxShift, maxShift);
	}

	private sealed class RockLattice
	{
		private readonly double _step;
		private readonly int _x0, _y0, _columns;
		private readonly float[] _values;

		public RockLattice(uint seed, double step, uint salt, Vector2I origin, int width, int height)
		{
			_step = step;
			_x0 = (int)Math.Floor(origin.X / step);
			_y0 = (int)Math.Floor(origin.Y / step);
			_columns = (int)Math.Floor((origin.X + width) / step) - _x0 + 2;
			int rows = (int)Math.Floor((origin.Y + height) / step) - _y0 + 2;
			_values = new float[rows * _columns];
			for (int y = 0; y < rows; y++)
				for (int x = 0; x < _columns; x++)
					_values[y * _columns + x] = (float)MapHash(_x0 + x, _y0 + y, seed ^ salt);
		}

		public double At(int x, int y)
		{
			double gx = x / _step, gy = y / _step;
			int ix = (int)Math.Floor(gx), iy = (int)Math.Floor(gy);
			double tx = ReliefSmooth(0.0, 1.0, gx - ix), ty = ReliefSmooth(0.0, 1.0, gy - iy);
			int i = (iy - _y0) * _columns + ix - _x0;
			return RoadLerp(RoadLerp(_values[i], _values[i + 1], tx),
				RoadLerp(_values[i + _columns], _values[i + _columns + 1], tx), ty);
		}
	}
}
