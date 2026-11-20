using System;
using System.Buffers;
using Godot;

public partial class FastGrid
{
	/// <summary>StageGeography: normalize water sources and elevations, then read that elevation snapshot for slopes.
	/// A missing dist_water key tells the caller to copy its existing ocean distance field.</summary>
	public Godot.Collections.Dictionary GeographyFields(int width, int height, float[] heights, float[] filled,
		byte[] ocean, byte[] lake, byte[] river, bool canReuseOceanDistance, bool parallel)
	{
		int cells = checked(width * height);
		parallel = parallel && cells >= 65536;
		var elev = new float[cells];
		var slope = new float[cells];
		var water = new byte[cells];
		RunRows(height, parallel, y =>
		{
			int start = y * width;
			for (int i = start; i < start + width; i++)
			{
				water[i] = (ocean[i] | lake[i] | river[i]) != 0 ? (byte)1 : (byte)0;
				elev[i] = ocean[i] != 0 ? 0f : lake[i] != 0 ? filled[i] : LandHeight(heights[i]);
			}
		});
		RunRows(height, parallel, y =>
		{
			int row = y * width;
			int up = y == 0 ? row : row - width;
			int down = y == height - 1 ? row : row + width;
			for (int x = 0; x < width; x++)
			{
				int i = row + x;
				double gx = (double)elev[x == width - 1 ? i : i + 1] - elev[x == 0 ? i : i - 1];
				double gy = (double)elev[down + x] - elev[up + x];
				slope[i] = (float)(Math.Sqrt(gx * gx + gy * gy) * 0.5 * 60.0);
			}
		});
		var result = new Godot.Collections.Dictionary { ["elev"] = elev, ["slope"] = slope };
		if (!canReuseOceanDistance || !water.AsSpan().SequenceEqual(ocean))
			result["dist_water"] = DistanceField(width, height, water);
		return result;
	}

	/// <summary>StageHydrology.position_field. Two prefix passes with the original float32 rounding of both means.</summary>
	public float[] TerrainPosition(int width, int height, float[] heights, int radius, bool parallel)
	{
		int cells = checked(width * height);
		if (cells == 0)
			return Array.Empty<float>();
		parallel = parallel && cells >= 65536;
		const int Block = 16;
		var rowMean = new float[cells];
		RunRows((height + Block - 1) / Block, parallel, band =>
		{
			var prefix = ArrayPool<double>.Shared.Rent(width + 1);
			try
			{
				prefix[0] = 0.0;
				int first = band * Block;
				for (int y = first; y < Math.Min(height, first + Block); y++)
				{
					int row = y * width;
					for (int x = 0; x < width; x++)
						prefix[x + 1] = prefix[x] + LandHeight(heights[row + x]);
					for (int x = 0; x < width; x++)
					{
						int from = Math.Max(0, x - radius), to = Math.Min(width, x + radius + 1);
						rowMean[row + x] = (float)((prefix[to] - prefix[from]) / (to - from));
					}
				}
			}
			finally
			{
				ArrayPool<double>.Shared.Return(prefix);
			}
		});

		var position = new float[cells];
		RunRows((width + Block - 1) / Block, parallel, band =>
		{
			// Prefixes of adjacent columns share a contiguous block. Both reads and final writes stay row-major.
			int first = band * Block;
			int pitch = Math.Min(Block, width - first);
			var prefix = ArrayPool<double>.Shared.Rent(checked((height + 1) * pitch));
			try
			{
				Array.Clear(prefix, 0, pitch);
				for (int y = 0; y < height; y++)
				{
					int row = y * width + first, at = y * pitch;
					for (int x = 0; x < pitch; x++)
						prefix[at + pitch + x] = prefix[at + x] + rowMean[row + x];
				}
				for (int y = 0; y < height; y++)
				{
					int from = Math.Max(0, y - radius), to = Math.Min(height, y + radius + 1);
					int row = y * width + first, lo = from * pitch, hi = to * pitch;
					for (int x = 0; x < pitch; x++)
					{
						float mean = (float)((prefix[hi + x] - prefix[lo + x]) / (to - from));
						position[row + x] = LandHeight(heights[row + x]) - mean;
					}
				}
			}
			finally
			{
				ArrayPool<double>.Shared.Return(prefix);
			}
		});
		return position;
	}

	// maxf(0.0, height) in GDScript preserves the sign of a zero height.
	private static float LandHeight(float height) => height < 0f ? 0f : height;

	/// <summary>StageHydrology.rainfall for the plan. Keep position and regional noise on the managed side.</summary>
	public float[] HydrologyRain(int width, int height, float[] heights, float[] distOcean, double[] moistNoise,
		int[] moistPerm, bool regional, double coastReach, double regionScale, double regionOx, double regionOy,
		double regionAmp, double reliefWet, double reliefDry, int radius, double positionScale, Vector2 keep, double dryFloor)
	{
		int cells = checked(width * height);
		bool parallel = cells >= 65536;
		var rain = regional ? TerrainPosition(width, height, heights, radius, parallel) : new float[cells];
		double far = Math.Exp(-coastReach / 30.0);
		RunRows(height, parallel, y =>
		{
			double ry = y / regionScale + regionOy;
			for (int x = 0; x < width; x++)
			{
				int i = y * width + x;
				double coast = distOcean[i] < coastReach ? (Math.Exp(-distOcean[i] / 30.0) - far) / (1.0 - far) : 0.0;
				double baseline = 0.66 + 0.48 * moistNoise[i] + 0.08 * coast;
				double value = baseline;
				double e = heights[i];
				if (regional && e > 0.0 && e < keep.Y)
				{
					double regionalRain = regionAmp * Fbm(moistPerm, x / regionScale + regionOx, ry, 2);
					double scale = positionScale * (0.65 + (1.0 - 0.65) * ReliefSmooth(0.43, 0.60, baseline + regionalRain));
					double position = rain[i];
					double local = ReliefSmooth(0.0, scale, Math.Abs(position)) * (position < 0.0 ? reliefWet : -reliefDry);
					value += (regionalRain + local) * (1.0 - ReliefSmooth(keep.X, keep.Y, e));
					double floor = Math.Min(baseline, dryFloor);
					if (value < floor)
						value = floor + (value - floor) * 0.3;
				}
				rain[i] = (float)Math.Clamp(value, 0.12, 1.0);
			}
		});
		return rain;
	}

	/// <summary>Shared surface exposure; byte-identical to mountain_surface.gd.</summary>
	public byte[] MountainExposure(float[] elev, float[] slope, float[] moist)
	{
		var result = new byte[elev.Length];
		bool wet = moist.Length == elev.Length;
		for (int i = 0; i < result.Length; i++)
		{
			double high = RoadSmooth(0.10, 0.26, elev[i]);
			double dry = 1.0 - RoadSmooth(0.35, 0.88, wet ? moist[i] : 0.5);
			double rock = RoadSmooth(0.24, 1.20, slope[i]) * (0.35 + 0.65 * dry);
			result[i] = (byte)Math.Floor(Clamp01(high * rock + 0.035 * RoadSmooth(0.2, 0.8, slope[i])) * 255.0 + 0.5);
		}
		return result;
	}

	/// <summary>Копия высот поиска в StageTrails.run: 0 у моря, уровень озера (filled × scale), река — max(hv, water) / tile, иначе hv / tile.</summary>
	public float[] RouteHeights(byte[] ocean, byte[] lake, byte[] river, float[] filled, float[] hv, float[] water, double scale, double tile, double lakeDrop = 0.1)
	{
		var heights = new float[hv.Length];
		for (int i = 0; i < hv.Length; i++)
			heights[i] = ocean[i] != 0 ? 0f : (float)(lake[i] != 0 ? filled[i] * scale - lakeDrop / tile : (river[i] != 0 ? Math.Max(hv[i], water[i]) : hv[i]) / tile);
		return heights;
	}

	/// <summary>Копия StageTrails._network_cost: 1 там, где mask ≥ min, иначе +∞.</summary>
	public float[] MaskCost(byte[] mask, int min)
	{
		var cost = new float[mask.Length];
		for (int i = 0; i < mask.Length; i++)
			cost[i] = mask[i] >= min ? 1f : float.PositiveInfinity;
		return cost;
	}

	/// <summary>Копия StageTrails._avoiding: копия cost, в которой проходимые клетки near дороже в mul раз.</summary>
	public float[] ScaledCost(float[] cost, byte[] near, double mul)
	{
		var outCost = (float[])cost.Clone();
		for (int i = 0; i < outCost.Length; i++)
			if (near[i] != 0 && !float.IsPositiveInfinity(outCost[i]))
				outCost[i] = (float)(outCost[i] * mul);
		return outCost;
	}

	/// <summary>StageTrails._build_cost: one interop call, double arithmetic, float32 result.</summary>
	public float[] PathCost(int w, int h, byte[] ocean, byte[] lake, byte[] river,
		float[] slope, byte[] biome, double[] noise, double[] biomeCost, double fordSlope)
	{
		var cost = new float[checked(w * h)];
		RunRows(h, true, y =>
		{
			for (int x = 0; x < w; x++)
			{
				int i = y * w + x;
				if (ocean[i] != 0 || lake[i] != 0 || river[i] != 0 && (AtMouth(x, y) || slope[i] > fordSlope))
				{
					cost[i] = float.PositiveInfinity;
					continue;
				}
				cost[i] = (float)(biomeCost[biome[i]] + slope[i] * 7.0 + (noise[i] * 0.5 + 0.5) * 0.9 + (river[i] != 0 ? 12.0 : 0.0));
			}
		});
		return cost;

		bool AtMouth(int x, int y)
		{
			for (int ny = Math.Max(0, y - 1); ny < Math.Min(h, y + 2); ny++)
				for (int nx = Math.Max(0, x - 1); nx < Math.Min(w, x + 2); nx++)
					if (ocean[ny * w + nx] != 0 || lake[ny * w + nx] != 0) return true;
			return false;
		}
	}

	// Indices address the IDs supplied by GDScript; Biomes remains the source of IDs.
	private enum ClimateKind { Deep, Ocean, Shallow, Lake, Beach, Desert, Savanna, Steppe,
		Grass, Forest, Jungle, Swamp, Taiga, Tundra, Snow, Rock, Peak, StoneShore }

	/// <summary>StageClimate.run. Preserve Vector2's float32 rounding before using light/retention.</summary>
	public Godot.Collections.Dictionary ClimateFields(int w, int h, float[] heights, byte[] ocean, byte[] lake,
		float[] rain, float[] distOcean, float[] distWater, float[] elev, float[] slope,
		double[] tempNoise, double latCells, byte[] biomeIds)
	{
		int n = checked(w * h);
		var temp = new float[n];
		var moist = new float[n];
		var biome = new byte[n];
		var light = new float[n];
		RunRows(h, true, y =>
		{
			double lat = 0.5 + (y - 383.5) / latCells;
			for (int x = 0; x < w; x++)
			{
				int i = y * w + x;
				double e = elev[i];
				double gx = ((double)elev[y * w + Math.Min(w - 1, x + 1)] - elev[y * w + Math.Max(0, x - 1)]) * 30.0;
				double gy = ((double)elev[Math.Min(h - 1, y + 1) * w + x] - elev[Math.Max(0, y - 1) * w + x]) * 30.0;
				light[i] = (float)Math.Clamp(0.5 - 0.5 * gy / Math.Sqrt(1.0 + gx * gx + gy * gy), 0.0, 1.0);
				double t = Math.Clamp(0.43 + lat * 0.32 + tempNoise[i] * 0.18 - e * 0.6, 0.0, 1.0);
				double waterMoisture = 0.22 * Math.Exp(-distWater[i] / 4.0);
				double m;
				if (ocean[i] == 0 && lake[i] == 0)
				{
					double around = ((double)elev[y * w + Math.Max(0, x - 2)] + elev[y * w + Math.Min(w - 1, x + 2)]
						+ elev[Math.Max(0, y - 2) * w + x] + elev[Math.Min(h - 1, y + 2) * w + x]) * 0.25;
					double retention = (float)Math.Clamp((around - e) * 18.0, -0.16, 0.16);
					t = Math.Clamp(t + (light[i] - 0.5) * 0.08, 0.0, 1.0);
					m = Math.Clamp(rain[i] + waterMoisture + retention - 0.10 * Math.Clamp((double)slope[i], 0.0, 1.5)
						- (light[i] - 0.5) * (0.08 + 0.12 * t), 0.0, 1.0);
				}
				else m = Math.Clamp(rain[i] + waterMoisture, 0.0, 1.0);
				temp[i] = (float)t;
				moist[i] = (float)m;
				ClimateKind b;
				if (ocean[i] != 0) b = heights[i] < -0.35 ? ClimateKind.Deep : heights[i] < -0.07 ? ClimateKind.Ocean : ClimateKind.Shallow;
				else if (lake[i] != 0) b = ClimateKind.Lake;
				else
				{
					b = LandBiome(e, t, m, slope[i], distOcean[i]);
					if (distWater[i] <= 1.0 && distOcean[i] > 2.5 && slope[i] > 0.55 && e < 0.62) b = ClimateKind.StoneShore;
				}
				biome[i] = biomeIds[(int)b];
			}
		});
		return new Godot.Collections.Dictionary { ["temp"] = temp, ["moist"] = moist, ["biome"] = biome, ["light"] = light };
	}

	private static ClimateKind LandBiome(double e, double t, double m, double slope, double distOcean)
	{
		if (e > 0.62 || e > 0.42 && t < 0.2)
			return slope < 0.30 && m > 0.50 && t > 0.12 ? ClimateKind.Tundra : ClimateKind.Peak;
		if (slope > 1.3 || e > 0.4 && (slope > 0.48 || m < 0.40)) return ClimateKind.Rock;
		if (e > 0.4) return ClimateKind.Tundra;
		if (distOcean <= 2.5 && e < 0.03) return t < 0.3 ? ClimateKind.StoneShore : ClimateKind.Beach;
		if (t < 0.12) return ClimateKind.Snow;
		if (t < 0.24) return m > 0.6 ? ClimateKind.Taiga : ClimateKind.Tundra;
		if (t < 0.42) return m < 0.3 ? ClimateKind.Steppe : ClimateKind.Taiga;
		if (t < 0.7)
		{
			if (m < 0.25) return ClimateKind.Steppe;
			if (m < 0.45) return ClimateKind.Grass;
			if (m > 0.86 && e < 0.12 && slope < 0.25) return ClimateKind.Swamp; // 0.82 до 14.11.2026, StageClimate.land_biome
			return ClimateKind.Forest;
		}
		if (m < 0.27) return ClimateKind.Desert;
		if (m < 0.42) return ClimateKind.Savanna;
		if (m < 0.55) return ClimateKind.Grass;
		if (m > 0.86 && e < 0.1 && slope < 0.25) return ClimateKind.Swamp;
		return ClimateKind.Jungle;
	}
}
