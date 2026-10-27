using System;

public partial class FastGrid
{
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
			double lat = 0.5 + (y - 255.5) / latCells;
			for (int x = 0; x < w; x++)
			{
				int i = y * w + x;
				double e = elev[i];
				double gx = ((double)elev[y * w + Math.Min(w - 1, x + 1)] - elev[y * w + Math.Max(0, x - 1)]) * 30.0;
				double gy = ((double)elev[Math.Min(h - 1, y + 1) * w + x] - elev[Math.Max(0, y - 1) * w + x]) * 30.0;
				light[i] = (float)Math.Clamp(0.5 - 0.5 * gy / Math.Sqrt(1.0 + gx * gx + gy * gy), 0.0, 1.0);
				double t = Math.Clamp(0.16 + lat * 0.86 + tempNoise[i] * 0.18 - e * 0.6, 0.0, 1.0);
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
		if (e > 0.62 || e > 0.42 && t < 0.2) return ClimateKind.Peak;
		if (e > 0.4 || slope > 1.3) return ClimateKind.Rock;
		if (distOcean <= 2.5 && e < 0.03) return t < 0.3 ? ClimateKind.StoneShore : ClimateKind.Beach;
		if (t < 0.12) return ClimateKind.Snow;
		if (t < 0.24) return m > 0.6 ? ClimateKind.Taiga : ClimateKind.Tundra;
		if (t < 0.42) return m < 0.3 ? ClimateKind.Steppe : ClimateKind.Taiga;
		if (t < 0.7)
		{
			if (m < 0.25) return ClimateKind.Steppe;
			if (m < 0.45) return ClimateKind.Grass;
			if (m > 0.82 && e < 0.12 && slope < 0.25) return ClimateKind.Swamp;
			return ClimateKind.Forest;
		}
		if (m < 0.27) return ClimateKind.Desert;
		if (m < 0.42) return ClimateKind.Savanna;
		if (m < 0.55) return ClimateKind.Grass;
		if (m > 0.86 && e < 0.1 && slope < 0.25) return ClimateKind.Swamp;
		return ClimateKind.Jungle;
	}
}
