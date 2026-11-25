using System;
using Godot;
using Inputs = Godot.Collections.Dictionary;

/// <summary>
/// Общая маска рельефа после генерации: где высоты 4 м можно менять (вес 1) и где нельзя (вес 0).
/// Одна для поля 2 м (FineRelief) и для эрозии генерации (часть 2, этап 3). Числа — WorldReliefGenerationConfig.mask_params(),
/// входы — Heightfield.relief_mask_inputs().
/// </summary>
public sealed class ReliefMask
{
	// Порядок совпадает с WorldReliefGenerationConfig.mask_params().
	internal enum Parameter
	{
		RoadGuard, RoadFade, WaterClearance, WaterFade, PlaceFade, RockFrom, RockTo, SteepFrom, SteepTo,
		EdgeGuard, EdgeFade, Count
	}

	public readonly int Width, Height;
	public readonly double Tile;
	/// <summary>Вес изменения высоты в узле 4 м, 0..1.</summary>
	public readonly float[] Weight;
	/// <summary>Узел дальше полосы перехода от воды (берег не защищён).</summary>
	public readonly bool[] ClearOfWater;
	/// <summary>Только для эрозии: расстояние до ближайшей защищённой зоны (дорога за своей полосой, вода, место,
	/// сооружение, край плана за своей полосой), м. Эрозия меняет высоту не больше чем на это расстояние × уклон перехода.</summary>
	public readonly float[] ProtectM;
	/// <summary>Только для эрозии: доля «не скалы» 0..1 по полю породы (RockRelief).</summary>
	public readonly float[] RockFree;

	private ReliefMask(int width, int height, double tile, bool erosion)
	{
		Width = width;
		Height = height;
		Tile = tile;
		Weight = new float[width * height];
		ClearOfWater = new bool[Weight.Length];
		ProtectM = erosion ? new float[Weight.Length] : null;
		RockFree = erosion ? new float[Weight.Length] : null;
		if (erosion)
			Array.Fill(ProtectM, float.MaxValue);
	}

	/// <summary>erosion — заполнить ещё ProtectM и RockFree (эрозия генерации); вес поля 2 м от этого не меняется.</summary>
	internal static ReliefMask Build(Inputs input, double[] profile, bool erosion = false)
	{
		if (profile.Length != (int)Parameter.Count)
			return null;
		foreach (double value in profile)
			if (!double.IsFinite(value))
				return null;
		double P(Parameter key) => profile[(int)key];
		int width = input["width"].AsInt32(), height = input["height"].AsInt32();
		double tile = input["tile"].AsDouble();
		int count = width * height;
		var heights = input["hv"].AsFloat32Array();
		var water = input["water"].AsFloat32Array();
		var wet = input["wet"].AsByteArray();
		var lake = input["lake"].AsByteArray();
		var rock = input["rock"].AsByteArray();
		if (width < 2 || height < 2 || tile <= 0.0 || heights.Length != count || water.Length != count || wet.Length != count
			|| lake.Length != count || rock.Length != count)
			return null;
		var mask = new ReliefMask(width, height, tile, erosion);
		var weight = mask.Weight;
		Array.Fill(weight, 1.0f);
		double At(int x, int z) => heights[Math.Clamp(z, 0, height - 1) * width + Math.Clamp(x, 0, width - 1)];

		var distance = new int[count];
		mask.ResetDistance(distance);
		foreach (int cell in input["patches"].AsInt32Array())
		{
			int x = cell % width, z = cell / width;
			mask.Mark(distance, x, z, x + 1, z + 1);
		}
		mask.ApplyDistance(distance, P(Parameter.RoadGuard), P(Parameter.RoadFade));

		mask.ResetDistance(distance);
		double clearance = P(Parameter.WaterClearance);
		for (int z = 0; z < height; z++)
		for (int x = 0; x < width; x++)
		{
			int k = z * width + x;
			if (wet[k] != 0 || lake[k] != 0 || heights[k] <= clearance)
				mask.Mark(distance, x - 1, z - 1, x + 1, z + 1);
			if (float.IsNegativeInfinity(water[k]))
				continue;
			double limit = water[k] + clearance;
			for (int dz = Math.Max(0, z - 1); dz <= Math.Min(z + 1, height - 1); dz++)
			for (int dx = Math.Max(0, x - 1); dx <= Math.Min(x + 1, width - 1); dx++)
				if (heights[dz * width + dx] <= limit)
					mask.Mark(distance, dx - 1, dz - 1, dx + 1, dz + 1);
		}
		mask.ApplyDistance(distance, 0.0, P(Parameter.WaterFade));
		for (int i = 0; i < count; i++)
			mask.ClearOfWater[i] = distance[i] * tile >= P(Parameter.WaterFade);

		mask.ResetDistance(distance);
		foreach (int cell in input["structures"].AsInt32Array())
		{
			int x = cell % width, z = cell / width;
			mask.Mark(distance, x - 1, z - 1, x + 1, z + 1);
		}
		// Эрозия: пласты RockRelief (узлы, которые он сдвинул) защищены как сооружения.
		if (erosion && input.ContainsKey("strata"))
		{
			var strata = input["strata"].AsByteArray();
			if (strata.Length == count)
				for (int k = 0; k < count; k++)
					if (strata[k] != 0)
						mask.Mark(distance, k % width, k / width, k % width, k / width);
		}
		double[] sites = input["places"].AsFloat64Array();
		// Тройки (x, z, радиус) в метрах; клетка (x, z) — узел на (x + 0,5) * tile.
		for (int k = 0; k + 2 < sites.Length; k += 3)
		{
			double x = sites[k] / tile - 0.5, z = sites[k + 1] / tile - 0.5, r = sites[k + 2] / tile;
			mask.Mark(distance, (int)Math.Floor(x - r), (int)Math.Floor(z - r), (int)Math.Ceiling(x + r), (int)Math.Ceiling(z + r));
		}
		mask.ApplyDistance(distance, 0.0, P(Parameter.PlaceFade));

		double rockFrom = P(Parameter.RockFrom), rockTo = P(Parameter.RockTo);
		double steepFrom = P(Parameter.SteepFrom), steepTo = P(Parameter.SteepTo);
		double edgeGuard = P(Parameter.EdgeGuard), edgeFade = P(Parameter.EdgeFade);
		for (int z = 0; z < height; z++)
		for (int x = 0; x < width; x++)
		{
			int k = z * width + x;
			if (weight[k] == 0.0f && !erosion)
				continue;
			int edge = Math.Min(Math.Min(x, width - 1 - x), Math.Min(z, height - 1 - z));
			if (erosion)
			{
				mask.ProtectM[k] = (float)Math.Max(0.0, Math.Min(mask.ProtectM[k], edge * tile - edgeGuard));
				mask.RockFree[k] = (float)(1.0 - Smooth(rockFrom, rockTo, rock[k] / (double)byte.MaxValue));
			}
			if (weight[k] == 0.0f)
				continue;
			// Центральная разность высот: уклон узла, м/м.
			double sx = (At(x + 1, z) - At(x - 1, z)) / (2.0 * tile);
			double sz = (At(x, z + 1) - At(x, z - 1)) / (2.0 * tile);
			weight[k] *= (float)(Smooth(edgeGuard, edgeGuard + edgeFade, edge * tile)
				* (1.0 - Smooth(steepFrom, steepTo, Math.Sqrt(sx * sx + sz * sz)))
				* (1.0 - Smooth(rockFrom, rockTo, rock[k] / (double)byte.MaxValue)));
		}
		return mask;
	}

	public long Bytes() => (long)Weight.Length * sizeof(float) + ClearOfWater.LongLength
		+ (ProtectM == null ? 0L : 2L * ProtectM.Length * sizeof(float));

	private void ResetDistance(int[] distance) => Array.Fill(distance, Math.Max(Width, Height));

	private void Mark(int[] distance, int x0, int z0, int x1, int z1)
	{
		x0 = Math.Max(x0, 0);
		x1 = Math.Min(x1, Width - 1);
		if (x0 > x1)
			return;
		for (int z = Math.Max(0, z0); z <= Math.Min(z1, Height - 1); z++)
			Array.Clear(distance, z * Width + x0, x1 - x0 + 1);
	}

	// Distance to protected coarse nodes in grid rings. Eight neighbours make the zero ring continuous around corners.
	private void ApplyDistance(int[] d, double guard, double fade)
	{
		DistanceToGuard(d);
		for (int k = 0; k < d.Length; k++)
		{
			Weight[k] *= (float)Smooth(guard, guard + fade, d[k] * Tile);
			if (ProtectM != null)
				ProtectM[k] = (float)Math.Min(ProtectM[k], Math.Max(0.0, d[k] * Tile - guard));
		}
	}

	private void DistanceToGuard(int[] d)
	{
		for (int z = 0; z < Height; z++)
		for (int x = 0; x < Width; x++)
		{
			int k = z * Width + x, best = d[k];
			if (x > 0) best = Math.Min(best, d[k - 1] + 1);
			if (z > 0)
				for (int dx = Math.Max(0, x - 1); dx <= Math.Min(x + 1, Width - 1); dx++)
					best = Math.Min(best, d[k - Width - x + dx] + 1);
			d[k] = best;
		}
		for (int z = Height - 1; z >= 0; z--)
		for (int x = Width - 1; x >= 0; x--)
		{
			int k = z * Width + x, best = d[k];
			if (x < Width - 1) best = Math.Min(best, d[k + 1] + 1);
			if (z < Height - 1)
				for (int dx = Math.Max(0, x - 1); dx <= Math.Min(x + 1, Width - 1); dx++)
					best = Math.Min(best, d[k + Width - x + dx] + 1);
			d[k] = best;
		}
	}

	internal static double Smooth(double a, double b, double v)
	{
		if (b <= a)
			return v > a ? 1.0 : 0.0;
		double t = Math.Clamp((v - a) / (b - a), 0.0, 1.0);
		return t * t * (3.0 - 2.0 * t);
	}
}
