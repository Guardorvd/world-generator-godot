using System;
using System.Collections.Generic;
using Godot;

public partial class FastGrid
{
	// TerrainBuilder.refine_arrays (scripts/render/terrain_builder.gd): квадраты у путей заменяются метровой сеткой патчей.
	// Один вызов на меш; патчи — столбцами (25 вершин на патч в порядке словаря). Порядок добавления вершин и индексов тот же,
	// что в GDScript (патчи по порядку, общие вершины соседей — один раз), поэтому массивы совпадают побайтно.
	// Нормали на краях патчей берут Heightfield.ground_at: метровая сетка (RoadRefinement.height_at), иначе общая сетка hv.
	// Только мир без OuterLand за краем карты.

	private static double RefineHeightAt(int[] cellPatch, float[] ph, int width, int height, double tile, int div, double x, double z)
	{
		double fx = x / tile - 0.5, fz = z / tile - 0.5;
		if (fx < 0.0 || fz < 0.0 || fx >= width - 1 || fz >= height - 1) return double.PositiveInfinity;
		double flx = Math.Floor(fx), flz = Math.Floor(fz);
		int pk = cellPatch[(int)flz * width + (int)flx];
		if (pk < 0) return double.PositiveInfinity;
		int stride = div + 1;
		double sx = (fx - flx) * div, sz = (fz - flz) * div;
		int ix = Math.Min(div - 1, (int)Math.Floor(sx)), iz = Math.Min(div - 1, (int)Math.Floor(sz));
		double tx = sx - ix, tz = sz - iz;
		int o = pk * stride * stride, a = o + iz * stride + ix;
		if (tx + tz <= 1.0)
			return ph[a] + (ph[a + 1] - (double)ph[a]) * tx + (ph[a + stride] - (double)ph[a]) * tz;
		int d = a + stride + 1;
		return ph[d] + (ph[a + stride] - (double)ph[d]) * (1.0 - tx) + (ph[a + 1] - (double)ph[d]) * (1.0 - tz);
	}

	private static double RefineGround(int[] cellPatch, float[] ph, float[] hv, int width, int height, double tile, int div, double x, double z)
	{
		double local = RefineHeightAt(cellPatch, ph, width, height, tile, div, x, z);
		return double.IsPositiveInfinity(local) ? RoadGround(hv, width, height, tile, x, z) : local;
	}

	/// <summary>Возвращает {pos, nor, uv, uv2, color, idx} вместо входных массивов меша. keys/ph/pcolor/puv — все патчи мира.</summary>
	public Godot.Collections.Dictionary RefineTerrain(int width, int height, double tile, int div, int areaX, int areaY, int areaW, int areaH,
		Vector3[] posIn, Vector3[] norIn, Vector2[] uvIn, int[] oldIdx, int[] keys, float[] ph, Color[] pcolor, Vector2[] puv, float[] hv)
	{
		int stride = div + 1, perPatch = stride * stride;
		double step = tile / div;
		var cellPatch = new int[width * height];
		Array.Fill(cellPatch, -1);
		for (int k = 0; k < keys.Length; k++) cellPatch[keys[k]] = k;
		int inArea = 0;
		for (int k = 0; k < keys.Length; k++)
		{
			int cx = keys[k] % width, cz = keys[k] / width;
			if (cx >= areaX && cz >= areaY && cx < areaX + areaW && cz < areaY + areaH) inArea++;
		}
		var pos = new List<Vector3>(posIn.Length + inArea * (perPatch - 4));
		var nor = new List<Vector3>(pos.Capacity);
		var uv = new List<Vector2>(pos.Capacity);
		pos.AddRange(posIn); nor.AddRange(norIn); uv.AddRange(uvIn);
		var uv2 = new List<Vector2>(pos.Capacity);
		var colors = new List<Color>(pos.Capacity);
		for (int k = 0; k < posIn.Length; k++) { uv2.Add(Vector2.Zero); colors.Add(new Color(0, 0, 0, 0)); }
		var idx = new int[oldIdx.Length + inArea * (div * div - 1) * 6];
		int write = 0;
		for (int j = areaY; j < areaY + areaH; j++)
		{
			for (int i = areaX; i < areaX + areaW; i++)
			{
				if (cellPatch[j * width + i] >= 0) continue;
				int at = ((j - areaY) * areaW + i - areaX) * 6;
				for (int k = 0; k < 6; k++) idx[write++] = oldIdx[at + k];
			}
		}
		var vertexIds = new Dictionary<int, int>(inArea * 16);
		var grid = new int[perPatch];
		for (int pk = 0; pk < keys.Length; pk++)
		{
			int key = keys[pk];
			int cx = key % width, cz = key / width;
			if (!(cx >= areaX && cz >= areaY && cx < areaX + areaW && cz < areaY + areaH)) continue;
			bool rightPatch = key + 1 < cellPatch.Length && cellPatch[key + 1] >= 0;
			bool lowerPatch = key + width < cellPatch.Length && cellPatch[key + width] >= 0;
			int o = pk * perPatch;
			for (int z = 0; z < stride; z++)
			{
				for (int x = 0; x < stride; x++)
				{
					int n = z * stride + x;
					int vk = (cz * div + z) * (width * div) + cx * div + x;
					if (vertexIds.TryGetValue(vk, out int known)) { grid[n] = known; continue; }
					double px = (cx + 0.5) * tile + x * step, pz = (cz + 0.5) * tile + z * step;
					int id = pos.Count;
					Vector3 normal;
					if (x > 0 && x < div && z > 0 && z < div && (x < div - 1 || rightPatch) && (z < div - 1 || lowerPatch))
						normal = new Vector3((float)(ph[o + n - 1] - (double)ph[o + n + 1]), 2.0f,
							(float)(ph[o + n - stride] - (double)ph[o + n + stride])).Normalized();
					else
						normal = new Vector3(
							(float)(RefineGround(cellPatch, ph, hv, width, height, tile, div, px - 1.0, pz) - RefineGround(cellPatch, ph, hv, width, height, tile, div, px + 1.0, pz)),
							2.0f,
							(float)(RefineGround(cellPatch, ph, hv, width, height, tile, div, px, pz - 1.0) - RefineGround(cellPatch, ph, hv, width, height, tile, div, px, pz + 1.0))).Normalized();
					if (x % div == 0 && z % div == 0)
					{
						id = (cz + z / div - areaY) * (areaW + 1) + cx + x / div - areaX;
						var v = pos[id]; v.Y = ph[o + n]; pos[id] = v;
						nor[id] = normal;
						colors[id] = pcolor[o + n];
						uv2[id] = puv[o + n];
					}
					else
					{
						pos.Add(new Vector3((float)px, ph[o + n], (float)pz));
						nor.Add(normal);
						uv.Add(new Vector2((float)(px / (width * tile)), (float)(pz / (height * tile))));
						colors.Add(pcolor[o + n]);
						uv2.Add(puv[o + n]);
					}
					vertexIds[vk] = id;
					grid[n] = id;
				}
			}
			for (int z = 0; z < div; z++)
			{
				for (int x = 0; x < div; x++)
				{
					int a = z * stride + x;
					idx[write] = grid[a]; idx[write + 1] = grid[a + 1]; idx[write + 2] = grid[a + stride];
					idx[write + 3] = grid[a + 1]; idx[write + 4] = grid[a + stride + 1]; idx[write + 5] = grid[a + stride];
					write += 6;
				}
			}
		}
		return new Godot.Collections.Dictionary
		{
			["pos"] = pos.ToArray(), ["nor"] = nor.ToArray(), ["uv"] = uv.ToArray(), ["uv2"] = uv2.ToArray(),
			["color"] = colors.ToArray(), ["idx"] = idx,
		};
	}
}
