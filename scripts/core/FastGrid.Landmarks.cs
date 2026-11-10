using System;
using System.Collections.Generic;

public partial class FastGrid
{
	// StageLandmarks candidate scores, including row-order ties. Settlement
	// spacing and all entity creation still run through the common GDScript path.
	public double[] SettlementCandidates(int width, int height, byte[] biome, byte[] wet, byte[] reachable,
		float[] slope, float[] distance, double[] habit, long candidateSeed, long densitySeed)
	{
		var candidates = new List<(double Score, int Cell, double Access, double Density)>();
		for (int y = 6; y < height - 6; y += 2)
		{
			for (int x = 6; x < width - 6; x += 2)
			{
				int i = y * width + x;
				if (wet[i] != 0 || reachable[i] == 0 || double.IsNegativeInfinity(habit[biome[i]]) || (double)slope[i] > 0.6) continue;
				double access = (SiteAccess(i, wet, biome, slope, habit) + SiteAccess(i - 4, wet, biome, slope, habit)
					+ SiteAccess(i + 4, wet, biome, slope, habit) + SiteAccess(i - 4 * width, wet, biome, slope, habit)
					+ SiteAccess(i + 4 * width, wet, biome, slope, habit)) / 5.0;
				if (access < 0.35) continue;
				int gx = x / 96, gy = y / 96;
				double tx = RoadSmooth(0, 1, x / 96.0 - gx), ty = RoadSmooth(0, 1, y / 96.0 - gy);
				uint seed = unchecked((uint)densitySeed);
				double density = RoadLerp(RoadLerp(MapHash(gx, gy, seed), MapHash(gx + 1, gy, seed), tx),
					RoadLerp(MapHash(gx, gy + 1, seed), MapHash(gx + 1, gy + 1, seed), tx), ty);
				double score = habit[biome[i]] + MapHash(x, y, unchecked((uint)candidateSeed)) * 0.2 - slope[i] * 0.6;
				score += access * 0.45 + density * 0.35;
				if (distance[i] >= 1.5 && distance[i] <= 6.0) score += 0.6;
				else if (distance[i] > 16.0) score -= Math.Min(0.6, (distance[i] - 16.0) / 40.0);
				if (distance[i] < 1.5) score -= 0.4;
				candidates.Add((score, i, access, density));
			}
		}
		candidates.Sort((a, b) => a.Score == b.Score ? a.Cell.CompareTo(b.Cell) : b.Score.CompareTo(a.Score));
		var columns = new double[candidates.Count * 4];
		for (int i = 0; i < candidates.Count; i++)
		{
			var candidate = candidates[i];
			columns[i * 4] = candidate.Score;
			columns[i * 4 + 1] = candidate.Cell;
			columns[i * 4 + 2] = candidate.Access;
			columns[i * 4 + 3] = candidate.Density;
		}
		return columns;
	}

	private static double SiteAccess(int cell, byte[] wet, byte[] biome, float[] slope, double[] habit)
		=> wet[cell] != 0 || double.IsNegativeInfinity(habit[biome[cell]]) ? 0.0 : Math.Max(0.0, 1.0 - slope[cell] / 0.45);

	/// <summary>Exact Grid.bridge_region traversal, including first-region tie breaking.</summary>
	public byte[] BridgeRegion(int w, int h, byte[] wet, int maxSpan)
	{
		int n = checked(w * h);
		var result = new byte[n];
		if (n == 0) return result;
		var distance = new int[n];
		int reach = Math.Max(0, maxSpan / 2);
		for (int i = 0; i < n; i++) distance[i] = wet[i] != 0 ? reach + 1 : 0;
		for (int y = 0; y < h; y++)
			for (int x = 0; x < w; x++)
			{
				int i = y * w + x;
				if (x > 0) distance[i] = Math.Min(distance[i], distance[i - 1] + 1);
				if (y > 0)
				{
					distance[i] = Math.Min(distance[i], distance[i - w] + 1);
					if (x > 0) distance[i] = Math.Min(distance[i], distance[i - w - 1] + 1);
					if (x + 1 < w) distance[i] = Math.Min(distance[i], distance[i - w + 1] + 1);
				}
			}
		for (int y = h - 1; y >= 0; y--)
			for (int x = w - 1; x >= 0; x--)
			{
				int i = y * w + x;
				if (x + 1 < w) distance[i] = Math.Min(distance[i], distance[i + 1] + 1);
				if (y + 1 < h)
				{
					distance[i] = Math.Min(distance[i], distance[i + w] + 1);
					if (x > 0) distance[i] = Math.Min(distance[i], distance[i + w - 1] + 1);
					if (x + 1 < w) distance[i] = Math.Min(distance[i], distance[i + w + 1] + 1);
				}
			}
		var regions = new int[n];
		var queue = new int[n];
		int region = 0, largest = 0, largestLand = 0;
		for (int start = 0; start < n; start++)
		{
			if (regions[start] != 0 || distance[start] > reach) continue;
			regions[start] = ++region;
			queue[0] = start;
			int head = 0, tail = 1, land = 0;
			while (head < tail)
			{
				int c = queue[head++];
				if (wet[c] == 0) land++;
				int x = c % w, y = c / w;
				for (int ny = Math.Max(0, y - 1); ny < Math.Min(h, y + 2); ny++)
					for (int nx = Math.Max(0, x - 1); nx < Math.Min(w, x + 2); nx++)
					{
						int next = ny * w + nx;
						if (regions[next] != 0 || distance[next] > reach) continue;
						regions[next] = region;
						queue[tail++] = next;
					}
			}
			if (land > largestLand) { largestLand = land; largest = region; }
		}
		if (largest != 0)
			for (int i = 0; i < n; i++) result[i] = regions[i] == largest ? (byte)1 : (byte)0;
		return result;
	}

	/// <summary>Local maxima in row order. Keep plateau ties and double threshold comparison.</summary>
	public int[] PeakCandidates(int w, int h, float[] elev, byte[] ocean, byte[] lake)
	{
		var cells = new List<int>();
		for (int y = 4; y < h - 4; y++)
			for (int x = 4; x < w - 4; x++)
			{
				int i = y * w + x;
				if ((double)elev[i] < 0.45 || ocean[i] != 0 || lake[i] != 0) continue;
				bool isMax = true;
				for (int dy = -3; dy <= 3 && isMax; dy++)
					for (int dx = -3; dx <= 3; dx++)
						if (elev[(y + dy) * w + x + dx] > elev[i]) { isMax = false; break; }
				if (isMax) cells.Add(i);
			}
		return cells.ToArray();
	}
}
