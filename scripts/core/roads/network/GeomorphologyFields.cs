using System;
using System.Threading.Tasks;

namespace Roads.Network;

/// <summary>Общее поле характера: широкая волна на равнине, кромка леса, перегибы склонов, гребни и берег.
/// Множитель применяется к цене суши. Запреты прохода, вода и сооружения сохраняют исходную цену.</summary>
public sealed class GeomorphologyFields
{
	public float[] Smooth = Array.Empty<float>();
	public float[] Slope = Array.Empty<float>();
	public float[] Tpi = Array.Empty<float>();
	public float[] Raw = Array.Empty<float>();
	public float[] ShoreDist = Array.Empty<float>();
	public double MinCost { get; private set; }
	private float[] _common = Array.Empty<float>(), _wave = Array.Empty<float>();

	private readonly TerrainSnapshot _t;
	public GeomorphologyFields(TerrainSnapshot t) { _t = t; }

	public void Build(bool mountain, NetStats stats, NetworkSession session = null)
	{
		Prepare(stats, session);
		long t0 = NetStats.Now();
		Raw = Weighted(_t.Cost, mountain ? "mountain" : "trail", _t.OnAxis, true);
		MinCost = Minimum(Raw);
		stats.Time("fields_cost", t0);
	}

	public void Prepare(NetStats stats, NetworkSession session)
	{
		long t0 = NetStats.Now();
		int W = _t.W, H = _t.H, N = _t.N;
		var p = _t.P;
		ulong key = NetworkSession.Hash(NetworkSession.Hash(NetworkSession.Hash(NetworkSession.Hash(NetworkSession.Hash(
			NetworkSession.Seed, _t.Hv), _t.Noise), _t.Ocean), _t.Lake), _t.River);
		key = NetworkSession.Hash(NetworkSession.Hash(key, _t.Biome), W);
		foreach (double value in new double[] { p.Tile, p.ReliefSigma, p.ReliefWideSigma, p.MeanderSigma, p.MeanderRms,
			p.MeanderFlat, p.MeanderSlope, p.RidgeTpi, p.RidgeMul, p.BreakTpi, p.BreakMul, p.EcoRadius,
			p.EcoLow, p.EcoHigh, p.EcoMul, p.ShoreBand, p.ShoreMul })
			key = NetworkSession.Hash(key, BitConverter.DoubleToInt64Bits(value));
		for (int b = 0; b < 256; b++) if (_t.Forest[b]) key = NetworkSession.Hash(key, b + 1000);
		if (session != null && session.FieldsKey == key && session.Smooth.Length == N)
		{
			Smooth = session.Smooth; Slope = session.Slope; Tpi = session.Tpi; ShoreDist = session.ShoreDist;
			_common = session.CharacterCommon; _wave = session.CharacterWave;
			stats.Count("fields_cached");
			stats.Time("fields_relief", t0);
			return;
		}

		var land = new float[N];
		var noise = new float[N];
		var openWater = new byte[N];
		for (int i = 0; i < N; i++)
		{
			land[i] = _t.Wet(i) ? 0f : 1f;
			noise[i] = (float)_t.Noise[i];
			openWater[i] = (byte)(_t.Ocean[i] != 0 || _t.Lake[i] != 0 ? 1 : 0);
		}
		Smooth = Gauss(_t.Hv, land, p.ReliefSigma);
		var wide = Gauss(_t.Hv, land, p.ReliefWideSigma);
		// Исправляем общий сдвиг сглаженного шума и нормируем по RMS суши.
		var low = Gauss(noise, land, p.MeanderSigma);
		double sum = 0.0, sumSq = 0.0;
		int count = 0;
		for (int i = 0; i < N; i++)
		{
			if (land[i] == 0f) continue;
			sum += low[i]; sumSq += (double)low[i] * low[i]; count++;
		}
		double mean = sum / Math.Max(1, count);
		double top = Math.Max(1e-9, p.MeanderRms * Math.Sqrt(Math.Max(0.0, sumSq / Math.Max(1, count) - mean * mean)));
		ShoreDist = _t.Router.DistanceField(W, H, openWater);
		Slope = new float[N];
		Tpi = new float[N];
		_common = new float[N];
		_wave = new float[N];
		var forest = new int[(W + 1) * (H + 1)];
		int stride = W + 1;
		for (int y = 0; y < H; y++)
		{
			int row = 0;
			for (int x = 0; x < W; x++)
			{
				row += _t.Forest[_t.Biome[y * W + x]] ? 1 : 0;
				forest[(y + 1) * stride + x + 1] = forest[y * stride + x + 1] + row;
			}
		}
		double step = 2.0 * p.Tile;
		Parallel.For(0, H, y =>
		{
			for (int x = 0; x < W; x++)
			{
				int i = y * W + x;
				double gx = (Smooth[y * W + Math.Min(W - 1, x + 1)] - Smooth[y * W + Math.Max(0, x - 1)]) / step;
				double gy = (Smooth[Math.Min(H - 1, y + 1) * W + x] - Smooth[Math.Max(0, y - 1) * W + x]) / step;
				Slope[i] = (float)Math.Sqrt(gx * gx + gy * gy);
				Tpi[i] = Smooth[i] - wide[i];
				int r = p.EcoRadius;
				int x0 = Math.Max(0, x - r), x1 = Math.Min(W, x + r + 1), y0 = Math.Max(0, y - r), y1 = Math.Min(H, y + r + 1);
				int trees = forest[y1 * stride + x1] - forest[y0 * stride + x1] - forest[y1 * stride + x0] + forest[y0 * stride + x0];
				double cover = (double)trees / ((x1 - x0) * (y1 - y0));
				double edge = SmoothStep(0.0, p.EcoLow, cover) * SmoothStep(1.0, p.EcoHigh, cover);
				double ridge = SmoothStep(0.0, p.RidgeTpi, Tpi[i]);
				double bend = SmoothStep(0.0, p.BreakTpi, -Tpi[i]);
				double shore = SmoothStep(p.ShoreBand, 0.0, ShoreDist[i]);
				_common[i] = (float)((1.0 + (p.EcoMul - 1.0) * edge) * (1.0 + (p.RidgeMul - 1.0) * ridge) *
					(1.0 + (p.BreakMul - 1.0) * bend) * (1.0 + (p.ShoreMul - 1.0) * shore));
				_wave[i] = (float)(Math.Clamp((low[i] - mean) / top, -1.0, 1.0) * SmoothStep(p.MeanderSlope, p.MeanderFlat, Slope[i]));
			}
		});
		if (session != null)
		{
			session.FieldsKey = key;
			session.Smooth = Smooth; session.Slope = Slope; session.Tpi = Tpi; session.ShoreDist = ShoreDist;
			session.CharacterCommon = _common; session.CharacterWave = _wave;
		}
		stats.Time("fields_relief", t0);
	}

	public bool Wet(int cell) => _t.Wet(cell);

	public float[] Weighted(float[] cost, string kind, byte[] axis, bool planner = false)
	{
		var output = new float[cost.Length];
		double amplitude = _t.P.Meander(kind);
		for (int c = 0; c < cost.Length; c++)
			output[c] = planner && _t.Unsafe[c] != 0 ? float.PositiveInfinity :
				WeightedCell(cost[c], c, amplitude, axis, planner && _t.Owner[c] >= 0);
		return output;
	}

	public float WeightedCell(float cost, int cell, double amplitude, byte[] axis, bool owned = false)
	{
		if (!float.IsFinite(cost) || owned || Wet(cell) || axis.Length != 0 && axis[cell] != 0) return cost;
		double mul = Math.Clamp(_common[cell] * (1.0 + amplitude * _wave[cell]), _t.P.MulMin, _t.P.MulMax);
		return (float)(cost * mul);
	}

	public static double Minimum(float[] cost)
	{
		double min = double.PositiveInfinity;
		foreach (float c in cost)
			if (float.IsFinite(c) && c < min) min = c;
		return min;
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
