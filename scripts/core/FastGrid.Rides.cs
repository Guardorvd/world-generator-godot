using System;

// Native copy of RideRoutes cost preparation (ride_routes.gd, cost_fields). Keep float32 parity.
public partial class FastGrid
{
	/// <summary>Клетки, где values[i] &gt;= threshold (1), остальные 0: маска готовой сети по path_mask.</summary>
	public byte[] BytesAtLeast(byte[] values, int threshold)
	{
		var result = new byte[values.Length];
		for (int i = 0; i < values.Length; i++)
			result[i] = (byte)(values[i] >= threshold ? 1 : 0);
		return result;
	}

	/// <summary>
	/// Стоимости природных маршрутов (копия RideRoutes.cost_fields): cost — местность, у сети и реки дороже;
	/// wood — то же, открытая земля (вне wooded[biome]) дороже в openMul; block — самая высокая (hv) клетка каждого
	/// блока blockSide × blockSide среди клеток положе topSlope, -1 — нет. Порядок обхода — по клеткам, как в GDScript
	/// (при равной высоте остаётся первая). Возвращает {cost: float[], wood: float[], block: int[]}.
	/// </summary>
	public Godot.Collections.Dictionary RideCostFields(int width, int height, float[] baseCost, byte[] net, float[] dist,
		byte[] river, byte[] biome, byte[] wooded, float[] slope, float[] hv, int blockSide,
		double nearR, double nearMul, double riverMul, double openMul, double topSlope)
	{
		int n = width * height;
		var cost = new float[n];
		var wood = new float[n];
		int bw = (width + blockSide - 1) / blockSide;
		var block = new int[bw * ((height + blockSide - 1) / blockSide)];
		Array.Fill(block, -1);
		for (int i = 0; i < n; i++)
		{
			double c = baseCost[i];
			if (double.IsPositiveInfinity(c))
			{
				cost[i] = float.PositiveInfinity;
				wood[i] = float.PositiveInfinity;
				continue;
			}
			if (net[i] != 0) c = Math.Max(c, 2.0);
			if (dist[i] < nearR) c *= nearMul;
			if (river[i] != 0) c *= riverMul;
			cost[i] = (float)c;
			wood[i] = wooded[biome[i]] != 0 ? (float)c : (float)(c * openMul);
			int b = (i / width / blockSide) * bw + (i % width) / blockSide;
			if (slope[i] < topSlope && (block[b] < 0 || hv[i] > hv[block[b]])) block[b] = i;
		}
		return new Godot.Collections.Dictionary { ["cost"] = cost, ["wood"] = wood, ["block"] = block };
	}
}
