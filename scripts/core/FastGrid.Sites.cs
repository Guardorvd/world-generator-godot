using System;
using System.Collections.Generic;

public partial class FastGrid
{
	// StageSites.CANDIDATE_TYPES order. Scores are rounded to float like its Vector2 sort keys.
	private enum SiteKind { Ruin, Tower, Stones, Shelter, Obelisk, Farm, House }
	private const byte SiteOpen = 1, SiteFarm = 2, SiteForest = 4;
	private static readonly (int X, int Y)[] SiteRing =
	{
		(10, 0), (7, 7), (0, 10), (-7, 7), (-10, 0), (-7, -7), (0, -10), (7, -7),
	};

	public Godot.Collections.Dictionary SiteCandidates(int width, int height, int step,
		byte[] paths, byte[] ocean, byte[] lake, byte[] river, float[] elevation, float[] slope, byte[] biome,
		double[] habit, byte[] flags, double[] settlements, double nearVillage, double settlementReach,
		long pickSeed, long[] densitySeeds, double densityCell)
	{
		var distance = DistanceSources(width * height, paths, 2);
		PropagateDistances(width, height, distance);
		var lists = new List<(float Score, int Cell)>[densitySeeds.Length];
		for (int t = 0; t < lists.Length; t++)
			lists[t] = new List<(float Score, int Cell)>();
		var nearby = new (double X, double DySquared)[settlements.Length / 2];
		const int Margin = 8;
		for (int y = Margin; y < height - Margin; y += step)
		{
			int count = 0;
			for (int s = 0; s < settlements.Length; s += 2)
			{
				double dy = settlements[s + 1] - y;
				if (Math.Abs(dy) <= settlementReach)
					nearby[count++] = (settlements[s], dy * dy);
			}
			for (int x = Margin; x < width - Margin; x += step)
			{
				int i = y * width + x;
				if ((ocean[i] | lake[i] | river[i] | paths[i]) != 0)
					continue;
				double nearest = double.PositiveInfinity;
				for (int s = 0; s < count; s++)
				{
					double dx = nearby[s].X - x;
					nearest = Math.Min(nearest, dx * dx + nearby[s].DySquared);
				}
				double settle = Math.Sqrt(nearest);
				if (settle < nearVillage)
					continue;
				double e = elevation[i], grade = slope[i], dp = distance[i];
				int bi = biome[i];
				double home = habit[bi];
				bool open = (flags[bi] & SiteOpen) != 0;
				bool ruin = (home > 0.0 || (flags[bi] & SiteForest) != 0) && grade <= 0.6 && settle >= 30.0;
				bool tower = dp <= 24.0 && grade <= 0.5 && e <= 0.62;
				bool stones = open && dp >= 6.0 && settle >= 35.0 && grade <= 0.4;
				double prom = ruin || tower || stones ? SiteProminence(elevation, width, height, x, y) : 0.0;
				double r = MapHash(x, y, unchecked((uint)pickSeed));
				if (ruin)
					AddSiteCandidate(lists, SiteKind.Ruin, densitySeeds, densityCell, x, y, i,
						prom * 15.0 + r * 0.8 + (settle > 45.0 ? 0.4 : 0.0) + (dp > 8.0 ? 0.3 : 0.0));
				if (tower && prom >= 0.02)
					AddSiteCandidate(lists, SiteKind.Tower, densitySeeds, densityCell, x, y, i,
						prom * 25.0 + (1.0 - dp / 24.0) * 0.6 + r * 0.3);
				if (stones && prom >= 0.008)
					AddSiteCandidate(lists, SiteKind.Stones, densitySeeds, densityCell, x, y, i, prom * 20.0 + r * 0.5);
				if (e >= 0.45 && grade <= 0.55 && dp <= 10.0 && settle >= 40.0)
					AddSiteCandidate(lists, SiteKind.Shelter, densitySeeds, densityCell, x, y, i,
						e + (1.0 - dp / 10.0) * 0.3 + r * 0.3);
				if (dp >= 1.5 && dp <= 4.0 && grade <= 0.35 && settle >= 30.0)
					AddSiteCandidate(lists, SiteKind.Obelisk, densitySeeds, densityCell, x, y, i,
						e * 0.8 + (open ? 0.3 : 0.0) + r * 0.8);
				if ((flags[bi] & SiteFarm) != 0 && grade <= 0.25 && dp >= 2.0 && dp <= 10.0 && settle <= settlementReach)
					AddSiteCandidate(lists, SiteKind.Farm, densitySeeds, densityCell, x, y, i,
						home + (1.0 - Math.Abs(settle - 30.0) / 40.0) * 0.5 + r * 0.4);
				if (home >= 0.2 && dp >= 2.0 && dp <= 8.0 && grade <= 0.35 && settle >= 20.0)
					AddSiteCandidate(lists, SiteKind.House, densitySeeds, densityCell, x, y, i,
						home + r * 0.6 + (settle > 40.0 ? 0.3 : 0.0));
			}
		}

		using var ranked = new Godot.Collections.Array();
		foreach (var list in lists)
		{
			list.Sort(static (a, b) =>
			{
				int byScore = b.Score.CompareTo(a.Score);
				return byScore != 0 ? byScore : a.Cell.CompareTo(b.Cell);
			});
			var cells = new int[list.Count];
			for (int i = 0; i < cells.Length; i++)
				cells[i] = list[i].Cell;
			ranked.Add(cells);
		}
		return new Godot.Collections.Dictionary { ["distance"] = distance, ["candidates"] = ranked };
	}

	private static double SiteProminence(float[] elevation, int width, int height, int x, int y)
	{
		double sum = 0.0;
		foreach (var offset in SiteRing)
		{
			int sx = Math.Clamp(x + offset.X, 0, width - 1);
			int sy = Math.Clamp(y + offset.Y, 0, height - 1);
			sum += elevation[sy * width + sx];
		}
		return elevation[y * width + x] - sum / 8.0;
	}

	private static void AddSiteCandidate(List<(float Score, int Cell)>[] lists, SiteKind kind, long[] seeds,
		double densityCell, int x, int y, int i, double score)
	{
		int t = (int)kind;
		uint seed = unchecked((uint)seeds[t]);
		double gx = x / densityCell, gy = y / densityCell;
		int ix = (int)gx, iy = (int)gy;
		double tx = ReliefSmooth(0.0, 1.0, gx - ix), ty = ReliefSmooth(0.0, 1.0, gy - iy);
		double density = RoadLerp(RoadLerp(MapHash(ix, iy, seed), MapHash(ix + 1, iy, seed), tx),
			RoadLerp(MapHash(ix, iy + 1, seed), MapHash(ix + 1, iy + 1, seed), tx), ty);
		if (density >= 0.22)
			lists[t].Add(((float)(score + (density - 0.5) * 1.2), i));
	}
}
