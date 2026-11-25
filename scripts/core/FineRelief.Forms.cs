using System;
using System.Numerics;
using Godot;
using Inputs = Godot.Collections.Dictionary;

public partial class FineRelief
{
	private enum Form { Rill, Root, Terrace, Flood, Bank }
	private const byte ClearWater = 1 << 7;
	private double[] _formProfile;
	private byte[] _habitat;
	private float[] _forestCover;
	private double[] _riverAxis;
	private long[] _formSeeds;
	private Vector2I _worldOrigin;

	private bool InitializeForms(Inputs input, double[] profile, int cells)
	{
		_habitat = input["biome"].AsByteArray();
		_forestCover = input["forest_cover"].AsFloat32Array();
		_riverAxis = input["river_axis"].AsFloat64Array();
		_formSeeds = input["form_seeds"].AsInt64Array();
		_worldOrigin = input["origin"].AsVector2I();
		_formProfile = profile;
		return _habitat.Length == cells && _riverAxis.Length == _height * 2 && _formSeeds.Length == (int)Form.Bank + 1
			&& _forestCover.Length > 0 && _forestCover.Length < ClearWater;
	}

	private long FormBytes() => _formProfile == null ? 0 : _habitat.LongLength + _forestCover.LongLength * sizeof(float)
		+ _riverAxis.LongLength * sizeof(double) + _formProfile.LongLength * sizeof(double) + _formSeeds.LongLength * sizeof(long);

	private double Setting(Parameter key) => _formProfile[(int)key];

	private void BuildForms(float[] result, int width, int height, int gx, int gz)
	{
		// The output halo also needs its own complete incident triangles. Evaluate one further row on every side.
		int stride = width + 2, rows = height + 2;
		var baseH = new float[stride * rows];
		var shape = new float[baseH.Length];
		var scale = new float[baseH.Length];
		int originX = gx - 1, originZ = gz - 1;
		Paint(shape, stride, rows, originX, originZ, _step, Form.Rill, Parameter.Rill);
		Paint(shape, stride, rows, originX, originZ, _step, Form.Root, Parameter.Root);
		Paint(shape, stride, rows, originX, originZ, _step, Form.Terrace, Parameter.Terrace);
		Paint(shape, stride, rows, originX, originZ, _step, Form.Flood, Parameter.Flood);
		Paint(shape, stride, rows, originX, originZ, _step, Form.Bank, Parameter.Bank);
		double maxShape = Math.Max(0.0, Setting(Parameter.FormDelta));
		double maxOffset = Math.Max(_reconstructionDelta, Setting(Parameter.TotalDelta));
		for (int j = 0; j < rows; j++)
		for (int i = 0; i < stride; i++)
		{
			int x = ClampX(originX + i), z = ClampZ(originZ + j);
			int k = j * stride + i;
			double smooth = Reconstruct(x, z);
			baseH[k] = (float)smooth;
			if (shape[k] == 0.0f)
				continue;
			int cell = CoarseQuad(x, z, out double u, out double v);
			double weight = Triangle(_weight, cell, _width, u, v);
			double existing = smooth - Triangle(_coarse, cell, _width, u, v);
			double limit = maxShape * Math.Max(0.0, weight);
			// Include zero in the interval so the triangle limiter can always reduce a form towards the base.
			shape[k] = (float)Math.Clamp(shape[k] * weight, Math.Min(0.0, Math.Max(-limit, -maxOffset - existing)),
				Math.Max(0.0, Math.Min(limit, maxOffset - existing)));
		}

		LimitTriangleGrades(baseH, shape, scale, stride, rows, _step, Setting(Parameter.FormGradeLimit), Setting(Parameter.FormGradeGain));
		for (int j = 0; j < height; j++)
		for (int i = 0; i < width; i++)
		{
			int k = (j + 1) * stride + i + 1;
			result[j * width + i] = (float)(baseH[k] + (double)shape[k] * scale[k]);
		}
	}

	private static void LimitTriangleGrades(float[] baseH, float[] shape, float[] scale, int stride, int rows, double step,
		double gradeLimit, double gradeGain)
	{
		gradeGain = Math.Max(0.0, gradeGain);
		Array.Fill(scale, 1.0f);
		for (int j = 0; j < rows - 1; j++)
		for (int i = 0; i < stride - 1; i++)
		{
			int a = j * stride + i, b = a + 1, c = a + stride, d = c + 1;
			Limit(a, b, c);
			Limit(d, c, b);
		}

		void Limit(int a, int b, int c)
		{
			double va = shape[a], vb = shape[b], vc = shape[c];
			if (va == 0.0 && vb == 0.0 && vc == 0.0)
				return;
			double dx = baseH[b] - (double)baseH[a], dz = baseH[c] - (double)baseH[a];
			double baseGrade = Math.Sqrt(dx * dx + dz * dz) / step;
			// Adjacent triangles can attenuate the vertices differently. Bound the entire
			// range between each signed form and zero, including an opposite-sign neighbour.
			double px = Math.Max(Math.Abs(va - vb), Math.Max(Math.Abs(va), Math.Abs(vb)));
			double pz = Math.Max(Math.Abs(va - vc), Math.Max(Math.Abs(va), Math.Abs(vc)));
			double allow = Math.Min(gradeGain, Math.Max(0.0, gradeLimit - baseGrade));
			float factor = (float)Math.Min(1.0, allow * step / Math.Sqrt(px * px + pz * pz));
			scale[a] = Math.Min(scale[a], factor);
			scale[b] = Math.Min(scale[b], factor);
			scale[c] = Math.Min(scale[c], factor);
		}
	}

	private void Paint(float[] output, int stride, int rows, int gx, int gz, double step, Form kind, Parameter first)
	{
		int p = (int)first;
		double spacing = _formProfile[p], along = _formProfile[p + 1], across = _formProfile[p + 2];
		double magnitude = _formProfile[p + 3], cover = _formProfile[p + 4];
		if (spacing <= 0.0 || along <= 0.0 || across <= 0.0 || magnitude <= 0.0 || cover <= 0.0)
			return;
		double pair = kind == Form.Root ? Setting(Parameter.RootPair) * 0.5 : 0.0;
		double reach = Math.Max(along + Math.Abs(pair), across);
		double ox = _worldOrigin.X * _tile, oz = _worldOrigin.Y * _tile;
		double startX = ox + _tile * 0.5 + gx * step, startZ = oz + _tile * 0.5 + gz * step;
		int x0 = (int)Math.Floor((startX - reach) / spacing), x1 = (int)Math.Floor((startX + (stride - 1) * step + reach) / spacing);
		int z0 = (int)Math.Floor((startZ - reach) / spacing), z1 = (int)Math.Floor((startZ + (rows - 1) * step + reach) / spacing);
		uint seed = (uint)_formSeeds[(int)kind];
		uint select = BitOperations.RotateLeft(seed, sizeof(uint) * 4);

		for (int z = z0; z <= z1; z++)
		for (int x = x0; x <= x1; x++)
		{
			double chance = FastGrid.MapHash(x, z, select);
			if (chance > cover)
				continue;
			double sx = (x + FastGrid.MapHash(x, z, seed)) * spacing;
			double sz = (z + FastGrid.MapHash(z, x, ~seed)) * spacing;
			int jx = (int)Math.Floor((sx - ox) / _tile), jz = (int)Math.Floor((sz - oz) / _tile);
			if (jx <= 0 || jz <= 0 || jx >= _width - 1 || jz >= _height - 1)
				continue;
			int cell = jz * _width + jx;
			if (_weight[cell] == 0.0f)
				continue;

			double hz = At(jx, jz - 1), hz1 = At(jx, jz + 1), hx = At(jx - 1, jz), hx1 = At(jx + 1, jz);
			double downX = hx - hx1, downZ = hz - hz1;
			double fall = Math.Sqrt(downX * downX + downZ * downZ);
			double grade = fall / (2.0 * _tile);
			double forest = _forestCover[_habitat[cell] & (ClearWater - 1)];
			double dx = fall > 0.0 ? downX / fall : 1.0, dz = fall > 0.0 ? downZ / fall : 0.0;
			double strength, bankSide = 1.0;
			switch (kind)
			{
				case Form.Rill:
					double hollow = hx + hx1 + hz + hz1 - 4.0 * At(jx, jz);
					double curvature = Setting(Parameter.RillCurvature);
					strength = Band(Setting(Parameter.RillSlopeFrom), Setting(Parameter.RillSlopeTo), grade)
						* Smooth(-curvature, curvature, hollow);
					break;
				case Form.Root:
					if (chance > cover * forest)
						continue;
					strength = forest;
					double angle = Math.Tau * FastGrid.MapHash(~x, ~z, select);
					dx = Math.Cos(angle);
					dz = Math.Sin(angle);
					break;
				case Form.Terrace:
					strength = forest > 0.0 ? 0.0 : Band(Setting(Parameter.TerraceSlopeFrom), Setting(Parameter.TerraceSlopeTo), grade);
					(dx, dz) = (dz, -dx);
					break;
				case Form.Flood:
				case Form.Bank:
					double shore = RiverLocal(sx - ox, jz, out dx, out dz, out bankSide);
					if (kind == Form.Flood)
						strength = Band(Setting(Parameter.FloodNear), Setting(Parameter.FloodFar), shore)
							* (1.0 - Smooth(0.0, Setting(Parameter.FloodGrade), grade));
					else
						strength = Band(Setting(Parameter.BankNear), Setting(Parameter.BankFar), shore);
					break;
				default:
					continue;
			}
			if (strength <= 0.0)
				continue;
			int xa = Math.Max(0, (int)Math.Ceiling((sx - reach - startX) / step));
			int xb = Math.Min(stride - 1, (int)Math.Floor((sx + reach - startX) / step));
			int za = Math.Max(0, (int)Math.Ceiling((sz - reach - startZ) / step));
			int zb = Math.Min(rows - 1, (int)Math.Floor((sz + reach - startZ) / step));
			for (int j = za; j <= zb; j++)
			for (int i = xa; i <= xb; i++)
			{
				double px = startX + i * step - sx, pz = startZ + j * step - sz;
				double u = dx * px + dz * pz, v = dx * pz - dz * px;
				double t = u / along, q = v / across;
				double form;
				switch (kind)
				{
					case Form.Rill:
						// A broad bed and a much lower berm share the same downstream taper.
						form = Bell(t * t + q * q) * (Setting(Parameter.RillRim) * q * q - Bell(2.0 * q * q));
						break;
					case Form.Root:
						double hill = (u - pair) / along, pit = (u + pair) / along;
						form = Bell(hill * hill + q * q) - Setting(Parameter.RootPitShare) * Bell(pit * pit + q * q);
						break;
					case Form.Terrace:
						double lip = Setting(Parameter.TerraceLip) * 0.5;
						form = Bell(t * t + q * q) * (2.0 * Smooth(-lip, lip, v) - 1.0);
						break;
					case Form.Flood:
						form = -Bell(t * t + q * q);
						break;
					case Form.Bank:
						if (!AboveWaterFade(gx + i, gz + j))
							continue;
						double edge = Setting(Parameter.BankLip) * 0.5;
						form = Bell(t * t + q * q) * Smooth(-edge, edge, v * bankSide);
						break;
					default:
						continue;
				}
				output[j * stride + i] += (float)(magnitude * strength * form);
			}
		}
	}

	private double RiverLocal(double x, int z, out double dx, out double dz, out double toward)
	{
		double axis = _riverAxis[z * 2];
		// Наклон оси реки по соседним рядам: направление вдоль реки.
		double meander = (_riverAxis[(z + 1) * 2] - _riverAxis[(z - 1) * 2]) / (2.0 * _tile);
		dz = 1.0 / Math.Sqrt(1.0 + meander * meander);
		dx = meander * dz;
		toward = -Math.Sign(x - axis);
		return Math.Abs(x - axis) * dz - _riverAxis[z * 2 + 1];
	}

	private bool AboveWaterFade(int x, int z)
	{
		int cell = CoarseQuad(ClampX(x), ClampZ(z), out _, out _);
		return (_habitat[cell] & _habitat[cell + 1] & _habitat[cell + _width] & _habitat[cell + _width + 1] & ClearWater) != 0;
	}

	private static double Bell(double squared)
	{
		double t = Math.Max(0.0, 1.0 - squared);
		return t * t;
	}

	private static double Band(double lo, double hi, double value)
	{
		double mid = (lo + hi) * 0.5;
		return Smooth(lo, mid, value) * (1.0 - Smooth(mid, hi, value));
	}
}
