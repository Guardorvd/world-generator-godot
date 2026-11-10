using System;

public partial class FastGrid
{
	// CPU copy of MapBaker._paint_rows. The seed, sampling order and RGB rounding
	// are shared with the GDScript fallback, including water pixels on the flat map.
	public Godot.Collections.Dictionary PaintMap(int width, int height, int scale, long seedValue,
		byte[] biome, byte[] lake, float[] elevation, float[] temperature, float[] shade, float[] wet, float[] depth,
		int[] jitterX, int[] jitterY, int[] texture, int[] wave, byte[] flags, double[] colors, double[] flowers, double[] rock,
		int stoneShore, int beach, int snow, int peak, bool wantFlat, bool wantShaded)
	{
		int imageWidth = width * scale, imageHeight = height * scale;
		int bytes = imageWidth * imageHeight * 3;
		byte[] flat = wantFlat ? new byte[bytes] : Array.Empty<byte>();
		byte[] shaded = wantShaded ? new byte[bytes] : Array.Empty<byte>();
		uint seed = unchecked((uint)seedValue), detailSeed = seed ^ 0x5bd1e995u;
		RunRows(imageHeight, true, py =>
		{
			double fy = (py + 0.5) / scale - 0.5;
			int baseY = (int)Math.Floor(fy);
			double ty = fy - baseY;
			int top = Math.Clamp(baseY, 0, height - 1) * width;
			int bottom = Math.Clamp(baseY + 1, 0, height - 1) * width;
			int nearestRow = MapCell(fy, height) * width;
			int offset = py * imageWidth * 3;
			for (int px = 0; px < imageWidth; px++, offset += 3)
			{
				double fx = (px + 0.5) / scale - 0.5;
				int baseX = (int)Math.Floor(fx);
				double tx = fx - baseX;
				int left = Math.Clamp(baseX, 0, width - 1), right = Math.Clamp(baseX + 1, 0, width - 1);
				int a = top + left, b = top + right, c = bottom + left, d = bottom + right;
				double w00 = (1.0 - tx) * (1.0 - ty), w10 = tx * (1.0 - ty);
				double w01 = (1.0 - tx) * ty, w11 = tx * ty;
				double hash = MapHash(px, py, seed);
				double water = wet[a] * w00 + wet[b] * w10 + wet[c] * w01 + wet[d] * w11
					+ Noise(jitterX, fx * 0.25, fy * 0.25) * 0.006 + Noise(jitterY, fx * 0.9 + 31.0, fy * 0.9) * 0.004;
				int near = nearestRow + MapCell(fx, width);
				double r, g, blue, sr, sg, sb;
				if (water > 0.0)
				{
					if (wantShaded)
					{
						double dep = depth[a] * w00 + depth[b] * w10 + depth[c] * w01 + depth[d] * w11;
						bool isLake = lake[near] == 1;
						double t = Math.Sqrt(Math.Min(1.0, dep / (isLake ? 0.09 : 0.5)));
						sr = isLake ? 70.0 - 42.0 * t : 72.0 - 58.0 * t;
						sg = isLake ? 138.0 - 72.0 * t : 150.0 - 112.0 * t;
						sb = isLake ? 170.0 - 52.0 * t : 190.0 - 106.0 * t;
						double waveValue = Noise(wave, fx * 0.7, fy * 2.2) * 0.5 + 0.5;
						double k = 1.0 + (waveValue - 0.5) * 0.08 * (1.0 - t * 0.5) + (hash - 0.5) * 0.02;
						sr *= k; sg *= k; sb *= k;
						if (water < 0.0035)
						{
							double foam = 0.45 * (1.0 - water / 0.0035);
							sr += (235.0 - sr) * foam;
							sg += (242.0 - sg) * foam;
							sb += (245.0 - sb) * foam;
						}
						PutMapPixel(shaded, offset, sr, sg, sb);
					}
					if (wantFlat)
						PutMapPixel(flat, offset, 112.0 + (hash - 0.5) * 16.0,
							108.0 + (hash - 0.5) * 14.0, 91.0 + (hash - 0.5) * 12.0);
					continue;
				}
				double detail = MapHash(py, px, detailSeed);
				double jx = Noise(jitterX, fx * 0.3, fy * 0.3) + Noise(jitterX, fx * 1.1 + 50.0, fy * 1.1) * 0.5 + (hash - 0.5) * 0.6;
				double jy = Noise(jitterY, fx * 0.3, fy * 0.3) + Noise(jitterY, fx * 1.1, fy * 1.1 - 50.0) * 0.5 + (detail - 0.5) * 0.6;
				int bi = biome[MapCell(fy + jy, height) * width + MapCell(fx + jx, width)];
				if ((flags[bi] & 1) != 0) bi = biome[near];
				if ((flags[bi] & 1) != 0) bi = temperature[near] < 0.3 ? stoneShore : beach;
				r = colors[bi * 3]; g = colors[bi * 3 + 1]; blue = colors[bi * 3 + 2];
				if (bi != snow && bi != peak)
				{
					double e = elevation[a] * w00 + elevation[b] * w10 + elevation[c] * w01 + elevation[d] * w11;
					double t = Clamp01((e - 0.3) / (0.6 - 0.3));
					double mix = t * t * (3.0 - 2.0 * t) * 0.45;
					r += (rock[0] - r) * mix; g += (rock[1] - g) * mix; blue += (rock[2] - blue) * mix;
				}
				if (bi == beach && water > -0.0045) { r *= 0.86; g *= 0.86; blue *= 0.86; }
				double grain = Noise(texture, fx * 0.9, fy * 0.9) * 0.07 + Noise(texture, fx * 3.1, fy * 3.1) * 0.04 + (hash - 0.5) * 0.07;
				double light = (shade[a] * w00 + shade[b] * w10 + shade[c] * w01 + shade[d] * w11) * (1.0 + grain);
				double flatLight = (w00 + w10 + w01 + w11) * (1.0 + grain);
				sr = r * light; sg = g * light; sb = blue * light;
				r *= flatLight; g *= flatLight; blue *= flatLight;
				if ((flags[bi] & 2) != 0 && detail < 0.006)
				{
					int flower = ((int)Math.Floor(hash * 997) % (flowers.Length / 3)) * 3;
					sr = r = flowers[flower]; sg = g = flowers[flower + 1]; sb = blue = flowers[flower + 2];
				}
				else if ((flags[bi] & 4) != 0 && detail < 0.012)
				{
					double pebble = 0.75 + hash * 0.5;
					sr = r = 150.0 * pebble; sg = g = 146.0 * pebble; sb = blue = 140.0 * pebble;
				}
				else if (detail > 0.985)
				{
					r *= 0.85; g *= 0.9; blue *= 0.85;
					sr *= 0.85; sg *= 0.9; sb *= 0.85;
				}
				if (wantFlat) PutMapPixel(flat, offset, r, g, blue);
				if (wantShaded) PutMapPixel(shaded, offset, sr, sg, sb);
			}
		});
		return new Godot.Collections.Dictionary { ["flat"] = flat, ["shaded"] = shaded };
	}

	private static int MapCell(double coordinate, int size)
		=> Math.Clamp((int)Math.Round(coordinate, MidpointRounding.AwayFromZero), 0, size - 1);

	private static double MapHash(int x, int y, uint seed)
	{
		uint hash = unchecked((uint)x * 374761393u + (uint)y * 668265263u) ^ seed;
		hash = unchecked((hash ^ (hash >> 13)) * 1274126177u);
		return (hash ^ (hash >> 16)) / 4294967296.0;
	}

	private static void PutMapPixel(byte[] bytes, int offset, double red, double green, double blue)
	{
		bytes[offset] = MapChannel(red);
		bytes[offset + 1] = MapChannel(green);
		bytes[offset + 2] = MapChannel(blue);
	}

	private static byte MapChannel(double value)
		=> (byte)Math.Clamp((int)Math.Round(value, MidpointRounding.AwayFromZero), 0, 255);
}
