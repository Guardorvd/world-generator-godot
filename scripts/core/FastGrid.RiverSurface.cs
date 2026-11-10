using System;
using System.Threading.Tasks;
using Godot;

public partial class FastGrid
{
	// Heightfield._init для рек (scripts/game/heightfield.gd): высоты hv_raw/hv, подрезка русел (_carve_rivers),
	// срез дна под лентой и подгонка берегов (_fit_banks_local). Ленты — столбцами (CSR по точкам): ribbons строит GDScript
	// (_river_ribbons), результат берегов он же записывает обратно в словари точек. Только мир без OuterLand и без
	// полотна дорог (генерация). Арифметика как в GDScript: double в расчётах, float32 в PackedFloat32Array и Vector2/Vector3.

	/// <summary>Возвращает {hv_raw, hv, left, right}: left/right — по три float (x, y, z) на точку ленты, в порядке столбцов.</summary>
	public Godot.Collections.Dictionary RiverSurface(int width, int height, double tile, double hs, double oceanDepth, double lakeDrop,
		float[] h, byte[] ocean, byte[] lake, float[] filled, int[] ribbonStarts, double[] px, double[] pz, double[] pw, double[] py,
		double[] pdepth, double[] pbend, double[] leftX, double[] leftZ)
	{
		int n = width * height;
		var raw = new float[n];
		var hv = new float[n];
		for (int i = 0; i < n; i++)
		{
			double v = ocean[i] == 0 && lake[i] == 0 ? Math.Max(0.0, h[i]) : h[i];
			raw[i] = ocean[i] != 0 ? (float)(Math.Max(-oceanDepth, v * oceanDepth) - 0.5) : (float)(v * hs);
			hv[i] = raw[i];
		}
		hv = RiverCarve(width, height, tile, ocean, lake, raw, hv, ribbonStarts, px, pz, pw, py, pdepth, pbend);
		// срез дна под лентой: порядок значим (ground_at читает уже срезанный рельеф)
		for (int k = 0; k < px.Length; k++)
		{
			double fx = RbClamp(px[k] / tile - 0.5, 0.0, width - 1.001);
			double fz = RbClamp(pz[k] / tile - 0.5, 0.0, height - 1.001);
			int i = (int)Math.Floor(fx), j = (int)Math.Floor(fz);
			int a, b, c;
			if ((fx - i) + (fz - j) <= 1.0) { a = j * width + i; b = j * width + i + 1; c = (j + 1) * width + i; }
			else { a = (j + 1) * width + i + 1; b = (j + 1) * width + i; c = j * width + i + 1; }
			double bed = py[k] - pdepth[k];
			double cut = RoadGround(hv, width, height, tile, px[k], pz[k]) - bed;
			if (cut > 0.0)
			{
				hv[a] = (float)(hv[a] - cut);
				hv[b] = (float)(hv[b] - cut);
				hv[c] = (float)(hv[c] - cut);
			}
		}
		var left = new float[px.Length * 3];
		var right = new float[px.Length * 3];
		int ribbons = ribbonStarts.Length - 1;
		var ground = hv;
		Parallel.For(0, ribbons, r =>
		{
			for (int k = ribbonStarts[r]; k < ribbonStarts[r + 1]; k++)
				RiverBanks(k, width, height, tile, hs, lakeDrop, ground, lake, filled, px, pz, pw, py, leftX, leftZ, left, right);
		});
		return new Godot.Collections.Dictionary { ["hv_raw"] = raw, ["hv"] = hv, ["left"] = left, ["right"] = right };
	}

	private static float[] RiverCarve(int width, int height, double tile, byte[] ocean, byte[] lake, float[] raw, float[] src,
		int[] ribbonStarts, double[] px, double[] pz, double[] pw, double[] py, double[] pdepth, double[] pbend)
	{
		var segs = new System.Collections.Generic.List<int>(); // индекс точки b сегмента (a = b - 1)
		for (int r = 0; r + 1 < ribbonStarts.Length; r++)
		{
			for (int k = ribbonStarts[r] + 1; k < ribbonStarts[r + 1]; k++)
			{
				var delta = new Vector2((float)(px[k] - px[k - 1]), (float)(pz[k] - pz[k - 1]));
				if (delta.LengthSquared() < 1e-8) continue;
				segs.Add(k);
			}
		}
		var output = (float[])src.Clone();
		int bands = Math.Max(1, Math.Min(height, System.Environment.ProcessorCount * 4));
		Parallel.For(0, bands, band =>
		{
			int y0 = (int)((long)height * band / bands), y1 = (int)((long)height * (band + 1) / bands);
			foreach (int k in segs)
			{
				int ia = k - 1;
				double ax = px[ia], az = pz[ia], aw = pw[ia], ay = py[ia], ad = pdepth[ia], ab = pbend[ia];
				double bx = px[k], bz = pz[k], bw = pw[k], by = py[k], bd = pdepth[k], bb = pbend[k];
				var delta = new Vector2((float)(bx - ax), (float)(bz - az));
				double len2 = delta.LengthSquared();
				double reach = Math.Max(aw, bw) * 1.8 + tile;
				int zLo = Math.Max(0, (int)Math.Floor((Math.Min(az, bz) - reach) / tile));
				int zHi = Math.Min(height, (int)Math.Ceiling((Math.Max(az, bz) + reach) / tile));
				int xLo = Math.Max(0, (int)Math.Floor((Math.Min(ax, bx) - reach) / tile));
				int xHi = Math.Min(width, (int)Math.Ceiling((Math.Max(ax, bx) + reach) / tile));
				if (zHi <= y0 || zLo >= y1) continue;
				for (int y = Math.Max(y0, zLo); y < Math.Min(y1, zHi); y++)
				{
					for (int x = xLo; x < xHi; x++)
					{
						int i = y * width + x;
						var offset = new Vector2((float)((x + 0.5) * tile - ax), (float)((y + 0.5) * tile - az));
						double u = RbClamp(offset.Dot(delta) / len2, 0.0, 1.0);
						double wd = RoadLerp(aw, bw, u);
						double distance = (offset - delta * (float)u).Length();
						if (ocean[i] != 0 || lake[i] != 0 || distance >= wd * 1.8) continue;
						double t = distance / wd;
						double level = RoadLerp(ay, by, u);
						double depth = RoadLerp(ad, bd, u);
						double bend = RoadLerp(ab, bb, u);
						double cross = offset.Cross(delta);
						double sign = cross == 0.0 ? 0.0 : (cross < 0.0 ? -1.0 : 1.0);
						double inside = Math.Max(0.0, -sign * bend);
						double bed = level - depth * (1.0 - 0.85 * RoadSmooth(0.15, 1.0, t));
						bed += inside * depth * 0.55 * RoadSmooth(0.1, 0.7, t);
						if (t > 1.0) bed = RoadLerp(level + 0.06, raw[i], RoadSmooth(1.0, 1.8, t));
						output[i] = (float)Math.Min((double)output[i], bed);
					}
				}
			}
		});
		return output;
	}

	private static void RiverBanks(int k, int width, int height, double tile, double hs, double drop, float[] heights, byte[] lake,
		float[] filled, double[] px, double[] pz, double[] pw, double[] py, double[] leftX, double[] leftZ, float[] left, float[] right)
	{
		double x = px[k], z = pz[k], y = py[k], w = pw[k];
		var normal = new Vector2((float)(leftX[k] - x), (float)(leftZ[k] - z)).Normalized();
		double level = double.NegativeInfinity;
		int cx = (int)Math.Floor(x / tile - 0.5), cy = (int)Math.Floor(z / tile - 0.5);
		if (!(cx < 0 || cy < 0 || cx >= width - 1 || cy >= height - 1))
		{
			int a = cy * width + cx;
			if (lake[a] != 0) level = filled[a] * hs - drop;
			if (lake[a + 1] != 0) level = Math.Max(level, filled[a + 1] * hs - drop);
			a += width;
			if (lake[a] != 0) level = Math.Max(level, filled[a] * hs - drop);
			if (lake[a + 1] != 0) level = Math.Max(level, filled[a + 1] * hs - drop);
		}
		for (int s = 0; s < 2; s++)
		{
			double side = s == 0 ? 1.0 : -1.0;
			double reach = w;
			if (y > Math.Max(0.0, level) + 0.001)
			{
				reach = 0.0;
				double limit = w + tile;
				while (reach < limit)
				{
					reach += 0.5;
					var q = new Vector2((float)x, (float)z) + normal * (float)side * (float)reach;
					if (RoadGround(heights, width, height, tile, q.X, q.Y) >= y + 0.02) break;
				}
				if (reach >= limit) reach = w;
			}
			var bank = new Vector3((float)(x + normal.X * side * reach), (float)y, (float)(z + normal.Y * side * reach));
			var target = s == 0 ? left : right;
			target[k * 3] = bank.X; target[k * 3 + 1] = bank.Y; target[k * 3 + 2] = bank.Z;
		}
	}
}
