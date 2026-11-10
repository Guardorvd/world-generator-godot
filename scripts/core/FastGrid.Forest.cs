using System;

public partial class FastGrid
{
	// Preserve object order and the float32 Vector2 length used by ForestFloor.
	public byte[] ForestSurface(int width, int height, int count, double[] x, double[] y, int[] kinds, double[] sizes,
		byte[] trees, double[] crowns, byte[] biome, byte[] water, byte[] river, float[] moist, float[] distance, byte[] rock)
	{
		var cover = new float[width * height];
		var needles = new float[cover.Length];
		for (int o = 0; o < count; o++)
		{
			int kind = kinds[o];
			if ((uint)kind >= (uint)trees.Length || trees[kind] == 0) continue;
			double radius = crowns[kind] * sizes[o] + 0.5;
			double centerX = x[o], centerY = y[o];
			int left = Math.Max(0, (int)Math.Floor(centerX - radius));
			int right = Math.Min(width, (int)Math.Ceiling(centerX + radius));
			int top = Math.Max(0, (int)Math.Floor(centerY - radius));
			int bottom = Math.Min(height, (int)Math.Ceiling(centerY + radius));
			bool conifer = trees[kind] == 2;
			for (int j = top; j < bottom; j++)
			{
				float dy = (float)(j + 0.5 - centerY);
				for (int i = left; i < right; i++)
				{
					float dx = (float)(i + 0.5 - centerX);
					double weight = Math.Max(0.0, 1.0 - MathF.Sqrt(dx * dx + dy * dy) / radius);
					int at = j * width + i;
					cover[at] = (float)(cover[at] + weight);
					if (conifer) needles[at] = (float)(needles[at] + weight);
				}
			}
		}
		var pixels = new byte[cover.Length * 4];
		for (int i = 0; i < cover.Length; i++)
		{
			bool dry = water[biome[i]] == 0 && river[i] == 0;
			double humidity = Clamp01(moist[i] + Math.Max(0.0, 1.0 - distance[i] / 3.0) * 0.2);
			pixels[i * 4] = dry ? MapChannel(Math.Min(1.0, cover[i]) * 255.0) : (byte)0;
			pixels[i * 4 + 1] = MapChannel(needles[i] / Math.Max(cover[i], 0.001) * 255.0);
			pixels[i * 4 + 2] = MapChannel(humidity * 255.0);
			pixels[i * 4 + 3] = dry ? rock[i] : (byte)0;
		}
		return pixels;
	}
}
