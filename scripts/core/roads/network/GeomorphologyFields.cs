using System;
using System.Threading.Tasks;

namespace Roads.Network;

/// <summary>Поля рельефа для цены V2 (план V2, 3.3), по одному разу на вызов, плоские массивы W·H:
/// Hσ — сглаженная земля (σ = 3 клетки, вода маскируется), |∇Hσ|, TPI = Hσ − H3σ (только для горных ответвлений),
/// экотон — доля леса 5×5 в [EcoLow; EcoHigh], меандр — низкочастотный готовый шум мира, полоса у моря и озера.
/// Цена V2 = w.cost × множители только на клетках вне сети и не дешевле наименьшей цены w.cost.</summary>
public sealed class GeomorphologyFields
{
	public float[] Smooth = Array.Empty<float>();   // Hσ, м
	public float[] Slope = Array.Empty<float>();    // |∇Hσ|, м/м
	public float[] Tpi = Array.Empty<float>();      // Hσ − H3σ, м (пусто, если не нужен)
	public float[] Raw = Array.Empty<float>();      // цена V2 без правил узлов
	public float[] ShoreDist = Array.Empty<float>(); // клеток до моря или озера
	public double MinCost;

	private readonly TerrainSnapshot _t;
	public GeomorphologyFields(TerrainSnapshot t) { _t = t; }

	/// <summary>ridge — множитель хребтов (горные ответвления), иначе без него. session — неизменные поля рельефа
	/// (Hσ, |∇Hσ|, TPI, сглаженный шум, полоса воды, лес) берутся из сессии, если её ключ совпал с входами.</summary>
	public void Build(bool ridge, NetStats stats, NetworkSession session = null)
	{
		long t0 = NetStats.Now();
		int W = _t.W, H = _t.H, N = _t.N;
		var P = _t.P;
		ulong key = NetworkSession.Hash(NetworkSession.Hash(NetworkSession.Hash(NetworkSession.Hash(NetworkSession.Hash(
			NetworkSession.Seed, _t.Hv), _t.Noise), _t.Ocean), _t.Lake), _t.River);
		key = NetworkSession.Hash(NetworkSession.Hash(key, _t.Biome), (long)(P.Tile * 1e6));
		for (int b = 0; b < 256; b++) if (_t.Forest[b]) key = NetworkSession.Hash(key, b + 1000);
		bool cached = session != null && session.FieldsKey == key && session.Smooth.Length == N;
		var land = new float[0];
		if (!cached)
		{
			land = new float[N];
			for (int i = 0; i < N; i++) land[i] = _t.Wet(i) ? 0f : 1f;
			Smooth = Gauss(_t.Hv, land, 3.0);
			Slope = new float[N];
			double step = 2.0 * P.Tile;
			Parallel.For(0, H, y =>
			{
				for (int x = 0; x < W; x++)
				{
					int i = y * W + x;
					double gx = (Smooth[y * W + Math.Min(W - 1, x + 1)] - Smooth[y * W + Math.Max(0, x - 1)]) / step;
					double gy = (Smooth[Math.Min(H - 1, y + 1) * W + x] - Smooth[Math.Max(0, y - 1) * W + x]) / step;
					Slope[i] = (float)Math.Sqrt(gx * gx + gy * gy);
				}
			});
		}
		else
		{
			Smooth = session.Smooth;
			Slope = session.Slope;
			Tpi = session.Tpi;
		}
		if (ridge && Tpi.Length != N)
		{
			if (land.Length != N)
			{
				land = new float[N];
				for (int i = 0; i < N; i++) land[i] = _t.Wet(i) ? 0f : 1f;
			}
			var wide = Gauss(_t.Hv, land, 9.0);
			Tpi = new float[N];
			for (int i = 0; i < N; i++) Tpi[i] = Smooth[i] - wide[i];
		}
		stats.Time("fields_relief", t0);
		t0 = NetStats.Now();
		int[] sum;
		float[] low;
		double top;
		if (!cached)
		{
			// Экотон: доля леса в квадрате 5×5 по интегральной сумме
			sum = new int[(W + 1) * (H + 1)];
			for (int y = 0; y < H; y++)
			{
				int row = 0;
				for (int x = 0; x < W; x++)
				{
					row += _t.Forest[_t.Biome[y * W + x]] ? 1 : 0;
					sum[(y + 1) * (W + 1) + x + 1] = sum[y * (W + 1) + x + 1] + row;
				}
			}
			// Меандр: шум мира, сглаженный σ = 6 клеток, приведённый к [-1; 1]
			var ones = new float[N];
			Array.Fill(ones, 1f);
			var noise = new float[N];
			for (int i = 0; i < N; i++) noise[i] = (float)_t.Noise[i];
			low = Gauss(noise, ones, 6.0);
			top = 1e-9;
			for (int i = 0; i < N; i++) top = Math.Max(top, Math.Abs(low[i]));
			var water = new byte[N];
			for (int i = 0; i < N; i++) water[i] = (byte)(_t.Ocean[i] != 0 || _t.Lake[i] != 0 ? 1 : 0);
			ShoreDist = _t.Router.DistanceField(W, H, water);
		}
		else
		{
			sum = session.ForestSum;
			low = session.Low;
			top = session.LowTop;
			ShoreDist = session.ShoreDist;
			stats.Count("fields_cached");
		}
		if (session != null)
		{
			session.FieldsKey = key;
			session.Smooth = Smooth; session.Slope = Slope; session.Tpi = Tpi;
			session.ForestSum = sum; session.Low = low; session.LowTop = top; session.ShoreDist = ShoreDist;
		}
		MinCost = double.PositiveInfinity;
		for (int i = 0; i < N; i++)
			if (float.IsFinite(_t.Cost[i])) MinCost = Math.Min(MinCost, _t.Cost[i]);
		Raw = new float[N];
		double minCost = MinCost;
		Parallel.For(0, H, y =>
		{
			for (int x = 0; x < W; x++)
			{
				int i = y * W + x;
				float c = _t.Cost[i];
				if (!float.IsFinite(c) || _t.Unsafe[i] != 0)
				{
					Raw[i] = float.PositiveInfinity;
					continue;
				}
				if (_t.Owner[i] >= 0)
				{
					Raw[i] = c;
					continue;
				}
				double mul = 1.0;
				int x0 = Math.Max(0, x - 2), x1 = Math.Min(W, x + 3), y0 = Math.Max(0, y - 2), y1 = Math.Min(H, y + 3);
				int forest = sum[y1 * (W + 1) + x1] - sum[y0 * (W + 1) + x1] - sum[y1 * (W + 1) + x0] + sum[y0 * (W + 1) + x0];
				double share = (double)forest / ((x1 - x0) * (y1 - y0));
				if (share >= P.EcoLow && share <= P.EcoHigh) mul *= P.EcoMul;
				double fade = SmoothStep(P.MeanderFlat, P.MeanderSlope, Slope[i]);
				mul *= 1.0 + P.MeanderAmp * (low[i] / top) * fade;
				if (ShoreDist[i] <= P.ShoreBand) mul *= P.ShoreMul;
				if (ridge && Tpi[i] > P.RidgeTpi) mul *= P.RidgeMul;
				Raw[i] = (float)Math.Max(minCost, c * mul);
			}
		});
		stats.Time("fields_cost", t0);
	}

	/// <summary>smoothstep(e0, e1, v) как в GDScript (e0 &gt; e1 даёт убывающую ступень).</summary>
	public static double SmoothStep(double e0, double e1, double v)
	{
		double t = Math.Clamp((v - e0) / (e1 - e0), 0.0, 1.0);
		return t * t * (3.0 - 2.0 * t);
	}

	/// <summary>Сепарабельный Гаусс со взвешиванием по маске (клетки с весом 0 не влияют на соседей).
	/// Клетка без веса в окне получает своё значение.</summary>
	public float[] Gauss(float[] v, float[] weight, double sigma)
	{
		int W = _t.W, H = _t.H, N = _t.N;
		int r = (int)Math.Ceiling(sigma * 3.0);
		var k = new double[2 * r + 1];
		for (int j = -r; j <= r; j++) k[j + r] = Math.Exp(-j * j / (2.0 * sigma * sigma));
		var sv = new double[N];
		var sw = new double[N];
		Parallel.For(0, H, y =>
		{
			for (int x = 0; x < W; x++)
			{
				double a = 0.0, b = 0.0;
				for (int j = Math.Max(-r, -x); j <= Math.Min(r, W - 1 - x); j++)
				{
					int i = y * W + x + j;
					double m = k[j + r] * weight[i];
					a += m * v[i];
					b += m;
				}
				sv[y * W + x] = a;
				sw[y * W + x] = b;
			}
		});
		var outv = new float[N];
		Parallel.For(0, H, y =>
		{
			for (int x = 0; x < W; x++)
			{
				double a = 0.0, b = 0.0;
				for (int j = Math.Max(-r, -y); j <= Math.Min(r, H - 1 - y); j++)
				{
					int i = (y + j) * W + x;
					a += k[j + r] * sv[i];
					b += k[j + r] * sw[i];
				}
				int c = y * W + x;
				outv[c] = b > 1e-9 ? (float)(a / b) : v[c];
			}
		});
		return outv;
	}
}
