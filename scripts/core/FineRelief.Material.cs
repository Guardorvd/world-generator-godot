using System;
using System.Threading.Tasks;

/// <summary>
/// Земля по процессам (часть 2 плана рельефа, этап 5): карты поверхности для материала рельефа и растительности.
/// Одно место для формул, которые раньше жили в TerrainBuilder.cavity_image (затенение впадин) и для новых
/// каналов по картам стока эрозии. Числа — WorldReliefDetailConfig.surface_map_params() (поля ресурса).
/// Выход — байты по узлам плана: R — затенение впадин (как раньше, Тип 1 побайтно тот же), при картах стока ещё
/// G — промытое дно лощины (водосбор A), B — нанос (D), A — положение в рельефе: высота над средним ближней
/// окрестности (0,5 — ровно, 1 — ребро, 0 — ложбина), та же величина, что у затенения впадин.
/// </summary>
public static class ReliefMaterial
{
	// Порядок совпадает с WorldReliefDetailConfig.surface_map_params().
	internal enum Parameter
	{
		CavityNear, CavityFar, NearDepthFrom, NearDepthTo, FarDepthFrom, FarDepthTo,
		BedAreaFrom, BedAreaTo, DepositFrom, DepositTo, BedRadiusCells, Tile, Count
	}

	/// <summary>Влажность мира после эрозии: moist + gain × (W − 1/2), 0..1. Одна формула для раскладки леса при
	/// генерации (ErodedVegetationFields) и для игры (подстилка, материал, подлесок, ковёр).</summary>
	internal static float FlowMoisture(float moist, byte wet, double gain)
		=> (float)Math.Clamp(moist + gain * (wet / (double)byte.MaxValue - 0.5), 0.0, 1.0);

	/// <summary>Сглаженная ступень, как smoothstep Godot (двойная точность — тот же байт, что у прежнего GDScript).</summary>
	private static double Smooth(double from, double to, double x)
	{
		double s = Math.Clamp((x - from) / (to - from), 0.0, 1.0);
		return s * s * (3.0 - 2.0 * s);
	}

	private static byte Unit(double value)
		=> (byte)Math.Clamp((int)Math.Round(value * byte.MaxValue, MidpointRounding.AwayFromZero), 0, byte.MaxValue);

	internal static byte[] Build(float[] hv, float[] near, float[] far, int width, int height, byte[] area, byte[] deposit, double[] p)
	{
		int n = width * height;
		if (p.Length != (int)Parameter.Count || hv.Length != n || near.Length != n || far.Length != n)
			return Array.Empty<byte>();
		bool flow = area.Length == n && deposit.Length == n;
		int stride = flow ? 4 : 1;
		var bytes = new byte[n * stride];
		double P(Parameter k) => p[(int)k];
		double cavityNear = P(Parameter.CavityNear), cavityFar = P(Parameter.CavityFar);
		double nearFrom = P(Parameter.NearDepthFrom), nearTo = P(Parameter.NearDepthTo);
		double farFrom = P(Parameter.FarDepthFrom), farTo = P(Parameter.FarDepthTo);
		double tile = P(Parameter.Tile), cellArea = tile * tile;
		// Промытое дно — по логарифму водосбора: площадь растёт вниз по лощине на порядки.
		double bedFrom = Math.Log(Math.Max(cellArea, P(Parameter.BedAreaFrom))), bedTo = Math.Log(Math.Max(cellArea, P(Parameter.BedAreaTo)));
		double depFrom = P(Parameter.DepositFrom), depTo = P(Parameter.DepositTo);
		int bedRadius = (int)P(Parameter.BedRadiusCells);
		var bed = flow ? new byte[n] : Array.Empty<byte>();
		Parallel.For(0, height, z =>
		{
			for (int x = 0; x < width; x++)
			{
				int k = z * width + x;
				double h = hv[k];
				double occ = cavityNear * Smooth(nearFrom, nearTo, near[k] - h) + cavityFar * Smooth(farFrom, farTo, far[k] - h);
				bytes[k * stride] = Unit(1.0 - occ);
				if (!flow)
					continue;
				double logArea = Math.Log(cellArea) + Math.Log(2.0) * area[k] / TerrainErosion.AreaStepsPerOctave;
				bed[k] = Unit(Smooth(bedFrom, bedTo, logArea));
				bytes[k * stride + 2] = Unit(Smooth(depFrom, depTo, deposit[k] * TerrainErosion.DepositStepM));
				// Положение в рельефе — та же величина, что у затенения: высота над средним ближней окрестности (~16 м).
				// Ниже среднего — ложбина (затенение), выше — ребро; полное ребро — на той же глубине, что полная ложбина.
				bytes[k * stride + 3] = Unit(0.5 + 0.5 * Math.Clamp((h - near[k]) / nearTo, -1.0, 1.0));
			}
		});
		if (!flow)
			return bytes;
		// Дно лощины — полоса ширины лощины вокруг линии стока (сток идёт по одному узлу): наибольшее в квадрате.
		Parallel.For(0, height, z =>
		{
			for (int x = 0; x < width; x++)
			{
				byte most = 0;
				for (int zz = Math.Max(0, z - bedRadius); zz <= Math.Min(height - 1, z + bedRadius); zz++)
					for (int xx = Math.Max(0, x - bedRadius); xx <= Math.Min(width - 1, x + bedRadius); xx++)
						most = Math.Max(most, bed[zz * width + xx]);
				bytes[(z * width + x) * stride + 1] = most;
			}
		});
		return bytes;
	}

	/// <summary>Карта нормалей макро-рельефа (RG8: nx, nz в 0..1) по сетке высот для плавного перехода на дальних LOD.</summary>
	internal static byte[] BuildNormals(float[] hv, int width, int height, double tile)
	{
		int n = width * height;
		if (width < 2 || height < 2 || hv.Length != n || tile <= 0.0)
			return Array.Empty<byte>();
		var bytes = new byte[n * 2];
		Parallel.For(0, height, j =>
		{
			int u = Math.Max(0, j - 1);
			int d = Math.Min(height - 1, j + 1);
			double dz = (j == 0 || j == height - 1) ? tile : 2.0 * tile;
			for (int i = 0; i < width; i++)
			{
				int l = Math.Max(0, i - 1);
				int r = Math.Min(width - 1, i + 1);
				double dx = (i == 0 || i == width - 1) ? tile : 2.0 * tile;
				double vx = (hv[j * width + l] - hv[j * width + r]) / dx;
				double vz = (hv[u * width + i] - hv[d * width + i]) / dz;
				double invLen = 1.0 / Math.Sqrt(vx * vx + 1.0 + vz * vz);
				int k = (j * width + i) * 2;
				bytes[k] = Unit(vx * invLen * 0.5 + 0.5);
				bytes[k + 1] = Unit(vz * invLen * 0.5 + 0.5);
			}
		});
		return bytes;
	}
}

public partial class FastGrid
{
	/// <summary>Карта макро-нормалей рельефа (RG8) для дальних LOD.</summary>
	public byte[] ReliefNormalMap(float[] hv, int width, int height, double tile)
		=> ReliefMaterial.BuildNormals(hv, width, height, tile);
	/// <summary>Карты поверхности (TerrainBuilder.surface_maps): R8 затенения впадин или RGBA8 с каналами стока.
	/// near/far — высоты, усреднённые в окрестности (TerrainBuilder._blurred); area/deposit пустые — без стока.</summary>
	public byte[] ReliefSurfaceMaps(float[] hv, float[] near, float[] far, int width, int height, byte[] area, byte[] deposit, double[] parameters)
		=> ReliefMaterial.Build(hv, near, far, width, height, area, deposit, parameters);

	/// <summary>Влажность мира после эрозии по карте W (Heightfield.ground_moisture).</summary>
	public float[] FlowMoisture(float[] moist, byte[] wet, double gain)
	{
		if (moist.Length != wet.Length)
			return Array.Empty<float>();
		var m = new float[moist.Length];
		for (int i = 0; i < m.Length; i++)
			m[i] = ReliefMaterial.FlowMoisture(moist[i], wet[i], gain);
		return m;
	}
}
