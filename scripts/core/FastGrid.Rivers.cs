using System;
using Godot;

public partial class FastGrid
{
	// StageRivers._shape_valleys (scripts/world/stages/stage_rivers.gd): профиль воды в руслах и подрезка склонов долины.
	// Один вызов на этап, массивы на входе и выходе. Арифметика как в GDScript: double в расчётах, float32 в хранилище
	// (h, filled, bank). Порядок обхода тот же (руслá — по order, подрезка — по клеткам), поэтому результат тот же бит в бит.

	/// <summary>Возвращает {h, filled} после этапа; входные h и filled не меняются (копии).</summary>
	public Godot.Collections.Dictionary RiverValleys(int width, int height, float[] hIn, float[] filledIn, int[] order, int orderCount,
		byte[] river, byte[] ocean, byte[] lake, float[] acc, int[] down, double riverAcc, double shoreLift)
	{
		int n = width * height;
		var original = (float[])hIn.Clone();
		var h = (float[])hIn.Clone();
		var filled = (float[])filledIn.Clone();
		for (int k = 0; k < orderCount; k++)
		{
			int i = order[k];
			if (river[i] == 0) continue;
			int x = i % width, y = i / width;
			double edge = Math.Min(Math.Min(x, width - 1 - x), Math.Min(y, height - 1 - y));
			double fade = RoadSmooth(0.0, 8.0, edge);
			double size = RvClamp(Math.Sqrt(acc[i] / riverAcc), 0.0, 3.0);
			int d = down[i];
			double floorLevel = d < 0 ? 0.0 : Math.Max(0.0, filled[d]);
			double level = Math.Max(floorLevel, original[i] - (0.003 + 0.003 * size) * fade);
			filled[i] = (float)level;
			h[i] = (float)level;
		}
		var bank = new float[n];
		Array.Fill(bank, float.NegativeInfinity);
		for (int i = 0; i < n; i++)
		{
			if (lake[i] == 0 || ocean[i] != 0) continue;
			int cx = i % width, cy = i / width;
			for (int k = 0; k < 8; k++)
			{
				int nx = cx + Dx[k], ny = cy + Dy[k];
				if (nx < 0 || ny < 0 || nx >= width || ny >= height) continue;
				int m = ny * width + nx;
				bank[m] = (float)Math.Max((double)bank[m], filled[i] + shoreLift);
			}
		}
		for (int i = 0; i < n; i++)
		{
			if (river[i] == 0) continue;
			int x = i % width, y = i / width;
			double relief = 0.0;
			for (int k = 0; k < 8; k++)
			{
				int nx = Math.Clamp(x + Dx[k] * 2, 0, width - 1), ny = Math.Clamp(y + Dy[k] * 2, 0, height - 1);
				relief = Math.Max(relief, Math.Abs((double)original[ny * width + nx] - original[i]));
			}
			double steep = RoadSmooth(0.012, 0.09, relief);
			double size = RvClamp(Math.Sqrt(acc[i] / riverAcc), 0.0, 3.0);
			double radius = RoadLerp(3.0 + size * 1.5, 1.5 + size * 0.4, steep);
			int r = (int)Math.Ceiling(radius);
			double fi = filled[i];
			for (int ny = Math.Max(0, y - r); ny < Math.Min(height, y + r + 1); ny++)
			{
				for (int nx = Math.Max(0, x - r); nx < Math.Min(width, x + r + 1); nx++)
				{
					int m = ny * width + nx;
					if (ocean[m] != 0 || lake[m] != 0 || river[m] != 0) continue;
					double t = new Vector2(nx - x, ny - y).Length() / radius;
					if (t >= 1.0) continue;
					double edge = Math.Min(Math.Min(nx, width - 1 - nx), Math.Min(ny, height - 1 - ny));
					double blend = (1.0 - RoadSmooth(0.0, 1.0, t)) * RoadSmooth(0.0, 8.0, edge);
					double profile = fi + 0.002 + RoadLerp(0.012 * t * t, 0.09 * t, steep);
					double orig = original[m];
					double target = Math.Max(profile, orig - RoadLerp(0.012, 0.035, steep));
					double cut = RoadLerp(orig, Math.Min(orig, target), blend);
					h[m] = (float)Math.Min((double)h[m], Math.Max(cut, Math.Min(orig, (double)bank[m])));
				}
			}
		}
		return new Godot.Collections.Dictionary { ["h"] = h, ["filled"] = filled };
	}

	private static double RvClamp(double v, double lo, double hi) => v < lo ? lo : (v > hi ? hi : v);
}
