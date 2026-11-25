using System;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using Godot;
using Inputs = Godot.Collections.Dictionary;

/// <summary>Derived terrain. Workers calculate immutable tiles; only the scene publishes them to physics.</summary>
public partial class FineRelief : RefCounted
{
	// Keep the native parameter layout in sync with WorldReliefDetailConfig.params().
	internal enum Parameter
	{
		Step, RoadGuard, RoadFade, WaterClearance, WaterFade, PlaceFade, RockFrom, RockTo, SteepFrom, SteepTo,
		EdgeGuard, EdgeFade, Bicubic, Clamp, ReconstructionDelta, TileBytes,
		Forms, FormGradeLimit, FormGradeGain, FormDelta, TotalDelta,
		Rill, RillAlong, RillAcross, RillDepth, RillCover, RillSlopeFrom, RillSlopeTo, RillCurvature, RillRim,
		Root, RootAlong, RootAcross, RootHeight, RootCover, RootPair, RootPitShare,
		Terrace, TerraceAlong, TerraceAcross, TerraceHeight, TerraceCover, TerraceSlopeFrom, TerraceSlopeTo, TerraceLip,
		Flood, FloodAlong, FloodAcross, FloodDepth, FloodCover, FloodNear, FloodFar, FloodGrade,
		Bank, BankAlong, BankAcross, BankHeight, BankCover, BankNear, BankFar, BankLip,
		MidForms, MidFade, MidGradeGain, MidDelta,
		Knoll, KnollAlong, KnollAcross, KnollHeight, KnollCover,
		Hollow, HollowAlong, HollowAcross, HollowDepth, HollowCover,
		ShelfGrade, ShelfNear, ShelfFar, ShelfCurvature,
		Gully, GullyAlong, GullyAcross, GullyDepth, GullyCover,
		GullySlopeFrom, GullySlopeTo, GullyNear, GullyFar, GullyCurvature, Count
	}
	private int _width, _height, _cells, _columns, _rows;
	private double _tile, _step, _reconstructionDelta;
	private float[] _coarse, _weight;
	private bool _bicubic, _clamp, _smallForms, _mediumForms;
	private Lazy<Tile>[] _tiles;
	private bool[] _active;
	private long _tileBytes;
	// A one-node halo stores the same final heights as the neighbouring tile for shared vertex normals.
	private sealed record Tile(int Stride, float[] Values)
	{
		public float Node(int x, int z) => Values[(z + 1) * Stride + x + 1];
	}
	private bool UsesDetail => _bicubic || _smallForms;

	internal bool Initialize(Inputs input, double[] profile)
	{
		if (profile.Length != (int)Parameter.Count)
			return false;
		foreach (double value in profile)
			if (!double.IsFinite(value))
				return false;
		double P(Parameter key) => profile[(int)key];
		_width = input["width"].AsInt32();
		_height = input["height"].AsInt32();
		_cells = input["cells"].AsInt32();
		_tile = input["tile"].AsDouble();
		_step = P(Parameter.Step);
		int count = _width * _height;
		if (_width < 2 || _height < 2 || _cells <= 0 || _step <= 0.0 || _step * 2.0 != _tile)
			return false;
		_coarse = input["hv"].AsFloat32Array();
		var water = input["water"].AsFloat32Array();
		var wet = input["wet"].AsByteArray();
		var lake = input["lake"].AsByteArray();
		var rock = input["rock"].AsByteArray();
		if (_coarse.Length != count || water.Length != count || wet.Length != count || lake.Length != count || rock.Length != count)
			return false;
		_columns = (_width - 2) / _cells + 1;
		_rows = (_height - 2) / _cells + 1;
		_smallForms = P(Parameter.Forms) != 0.0;
		_mediumForms = P(Parameter.MidForms) != 0.0;
		long maxNodes = (2L * (_width - 1) + 3L * _columns) * (2L * (_height - 1) + 3L * _rows);
		if ((_smallForms || _mediumForms) && !InitializeForms(input, profile, count))
			return false;
		if ((maxNodes + 2L * count) * sizeof(float) + FormBytes() > P(Parameter.TileBytes))
			return false;
		_bicubic = P(Parameter.Bicubic) != 0.0;
		_clamp = P(Parameter.Clamp) != 0.0;
		_reconstructionDelta = P(Parameter.ReconstructionDelta);
		_weight = new float[count];
		Array.Fill(_weight, 1.0f);

		var distance = new int[count];
		ResetDistance(distance);
		foreach (int cell in input["patches"].AsInt32Array())
		{
			int x = cell % _width, z = cell / _width;
			Mark(distance, x, z, x + 1, z + 1);
		}
		ApplyDistance(distance, P(Parameter.RoadGuard), P(Parameter.RoadFade));

		ResetDistance(distance);
		double clearance = P(Parameter.WaterClearance);
		for (int z = 0; z < _height; z++)
		for (int x = 0; x < _width; x++)
		{
			int k = z * _width + x;
			if (wet[k] != 0 || lake[k] != 0 || _coarse[k] <= clearance)
				Mark(distance, x - 1, z - 1, x + 1, z + 1);
			if (float.IsNegativeInfinity(water[k]))
				continue;
			double limit = water[k] + clearance;
			for (int dz = Math.Max(0, z - 1); dz <= Math.Min(z + 1, _height - 1); dz++)
			for (int dx = Math.Max(0, x - 1); dx <= Math.Min(x + 1, _width - 1); dx++)
				if (_coarse[dz * _width + dx] <= limit)
					Mark(distance, dx - 1, dz - 1, dx + 1, dz + 1);
		}
		ApplyDistance(distance, 0.0, P(Parameter.WaterFade));
		if (_smallForms)
			for (int i = 0; i < count; i++)
				if (distance[i] * _tile >= P(Parameter.WaterFade))
					_habitat[i] |= ClearWater;

		ResetDistance(distance);
		foreach (int cell in input["structures"].AsInt32Array())
		{
			int x = cell % _width, z = cell / _width;
			Mark(distance, x - 1, z - 1, x + 1, z + 1);
		}
		double[] sites = input["places"].AsFloat64Array();
		for (int k = 0; k + 2 < sites.Length; k += 3)
		{
			double x = sites[k] / _tile - 0.5, z = sites[k + 1] / _tile - 0.5, r = sites[k + 2] / _tile;
			Mark(distance, (int)Math.Floor(x - r), (int)Math.Floor(z - r), (int)Math.Ceiling(x + r), (int)Math.Ceiling(z + r));
		}
		ApplyDistance(distance, 0.0, P(Parameter.PlaceFade));
		double rockFrom = P(Parameter.RockFrom), rockTo = P(Parameter.RockTo);
		double steepFrom = P(Parameter.SteepFrom), steepTo = P(Parameter.SteepTo);
		double edgeGuard = P(Parameter.EdgeGuard), edgeFade = P(Parameter.EdgeFade);
		for (int z = 0; z < _height; z++)
		for (int x = 0; x < _width; x++)
		{
			int k = z * _width + x;
			if (_weight[k] == 0.0f)
				continue;
			int edge = Math.Min(Math.Min(x, _width - 1 - x), Math.Min(z, _height - 1 - z));
			double sx = (At(x + 1, z) - At(x - 1, z)) / (2.0 * _tile);
			double sz = (At(x, z + 1) - At(x, z - 1)) / (2.0 * _tile);
			_weight[k] *= (float)(Smooth(edgeGuard, edgeGuard + edgeFade, edge * _tile)
				* (1.0 - Smooth(steepFrom, steepTo, Math.Sqrt(sx * sx + sz * sz)))
				* (1.0 - Smooth(rockFrom, rockTo, rock[k] / (double)byte.MaxValue)));
		}
		if (_mediumForms)
			BuildMedium(distance);
		_tiles = new Lazy<Tile>[_columns * _rows];
		_active = new bool[_tiles.Length];
		for (int i = 0; i < _tiles.Length; i++)
		{
			int key = i;
			_tiles[i] = new Lazy<Tile>(() => BuildTile(key), LazyThreadSafetyMode.ExecutionAndPublication);
		}
		return true;
	}

	private void ResetDistance(int[] distance) => Array.Fill(distance, Math.Max(_width, _height));

	private void Mark(int[] distance, int x0, int z0, int x1, int z1)
	{
		x0 = Math.Max(x0, 0);
		x1 = Math.Min(x1, _width - 1);
		if (x0 > x1)
			return;
		for (int z = Math.Max(0, z0); z <= Math.Min(z1, _height - 1); z++)
			Array.Clear(distance, z * _width + x0, x1 - x0 + 1);
	}

	// Distance to protected coarse nodes in grid rings. Eight neighbours make the zero ring continuous around corners.
	private void ApplyDistance(int[] d, double guard, double fade)
	{
		DistanceToGuard(d);
		for (int k = 0; k < d.Length; k++)
			_weight[k] *= (float)Smooth(guard, guard + fade, d[k] * _tile);
	}

	private void DistanceToGuard(int[] d)
	{
		for (int z = 0; z < _height; z++)
		for (int x = 0; x < _width; x++)
		{
			int k = z * _width + x, best = d[k];
			if (x > 0) best = Math.Min(best, d[k - 1] + 1);
			if (z > 0)
				for (int dx = Math.Max(0, x - 1); dx <= Math.Min(x + 1, _width - 1); dx++)
					best = Math.Min(best, d[k - _width - x + dx] + 1);
			d[k] = best;
		}
		for (int z = _height - 1; z >= 0; z--)
		for (int x = _width - 1; x >= 0; x--)
		{
			int k = z * _width + x, best = d[k];
			if (x < _width - 1) best = Math.Min(best, d[k + 1] + 1);
			if (z < _height - 1)
				for (int dx = Math.Max(0, x - 1); dx <= Math.Min(x + 1, _width - 1); dx++)
					best = Math.Min(best, d[k + _width - x + dx] + 1);
			d[k] = best;
		}
	}

	private static double Smooth(double a, double b, double v)
	{
		if (b <= a)
			return v > a ? 1.0 : 0.0;
		double t = Math.Clamp((v - a) / (b - a), 0.0, 1.0);
		return t * t * (3.0 - 2.0 * t);
	}

	private double At(int x, int z) => _coarse[Math.Clamp(z, 0, _height - 1) * _width + Math.Clamp(x, 0, _width - 1)];

	internal static double Triangle(double a, double b, double c, double d, double u, double v)
		=> u + v <= 1.0 ? a + (b - a) * u + (c - a) * v : d + (c - d) * (1.0 - u) + (b - d) * (1.0 - v);

	private static double Triangle(float[] data, int k, int stride, double u, double v)
		=> Triangle(data[k], data[k + 1], data[k + stride], data[k + stride + 1], u, v);

	private static double Cubic(double a, double b, double c, double d, double t)
		=> b + 0.5 * t * (c - a + t * ((2.0 * a - 5.0 * b + 4.0 * c - d) + t * (3.0 * (b - c) + d - a)));

	private double CubicRow(int x, int z, double u) => Cubic(At(x - 1, z), At(x, z), At(x + 1, z), At(x + 2, z), u);

	private int CoarseQuad(int gx, int gz, out double u, out double v)
	{
		int x = Math.Min(gx / 2, _width - 2), z = Math.Min(gz / 2, _height - 2);
		u = gx * 0.5 - x;
		v = gz * 0.5 - z;
		return z * _width + x;
	}

	private double Reconstruct(int gx, int gz)
	{
		if (gx % 2 == 0 && gz % 2 == 0)
			return At(gx / 2, gz / 2);
		int k = CoarseQuad(gx, gz, out double u, out double v);
		double weight = Triangle(_weight, k, _width, u, v);
		double linear = Triangle(_coarse, k, _width, u, v);
		if (!_bicubic || weight <= 0.0)
			return linear;
		int x = k % _width, z = k / _width;
		double smooth = Cubic(CubicRow(x, z - 1, u), CubicRow(x, z, u), CubicRow(x, z + 1, u), CubicRow(x, z + 2, u), v);
		if (_clamp)
		{
			double a = _coarse[k], b = _coarse[k + 1], c = _coarse[k + _width], d = _coarse[k + _width + 1];
			// A boundary sample must fit both incident quads, including a different chunk.
			if (u == 0.0) { b = a; d = c; }
			if (u == 1.0) { a = b; c = d; }
			if (v == 0.0) { c = a; d = b; }
			if (v == 1.0) { a = c; b = d; }
			smooth = Math.Clamp(smooth, Math.Min(Math.Min(a, b), Math.Min(c, d)), Math.Max(Math.Max(a, b), Math.Max(c, d)));
		}
		return linear + Math.Clamp(smooth - linear, -_reconstructionDelta, _reconstructionDelta) * weight;
	}

	private Tile BuildTile(int index)
	{
		int cx = index % _columns * _cells, cz = index / _columns * _cells;
		int stride = 2 * Math.Min(_cells, _width - 1 - cx) + 3;
		int rows = 2 * Math.Min(_cells, _height - 1 - cz) + 3;
		var h = new float[stride * rows];
		if (_smallForms)
			BuildForms(h, stride, rows, 2 * cx - 1, 2 * cz - 1);
		else
			for (int j = 0; j < rows; j++)
			for (int i = 0; i < stride; i++)
				h[j * stride + i] = (float)Reconstruct(ClampX(2 * cx + i - 1), ClampZ(2 * cz + j - 1));
		Interlocked.Add(ref _tileBytes, h.Length * sizeof(float));
		return new Tile(stride, h);
	}

	private int Index(int cx, int cz) => cz * _columns + cx;
	private bool ValidKey(int cx, int cz) => (uint)cx < (uint)_columns && (uint)cz < (uint)_rows;

	public void Warm(Vector2[] points, double radius)
	{
		Parallel.For(0, _tiles.Length, index =>
		{
			double x = (index % _columns * _cells + 0.5) * _tile, z = (index / _columns * _cells + 0.5) * _tile;
			double side = _cells * _tile;
			foreach (var p in points)
			{
				double dx = p.X - Math.Clamp(p.X, x, x + side), dz = p.Y - Math.Clamp(p.Y, z, z + side);
				if (dx * dx + dz * dz > radius * radius)
					continue;
				_ = _tiles[index].Value;
				break;
			}
		});
	}

	public void SetActive(int cx, int cz, bool active)
	{
		if (!ValidKey(cx, cz))
			return;
		int id = Index(cx, cz);
		if (!active || _tiles[id].IsValueCreated)
			Volatile.Write(ref _active[id], active);
	}

	public long Bytes() => Interlocked.Read(ref _tileBytes) + ((long)_weight.Length + _coarse.Length) * sizeof(float) + FormBytes();

	public string TileHash(int cx, int cz)
	{
		if (!ValidKey(cx, cz))
			return "";
		var tile = _tiles[Index(cx, cz)].Value;
		int rowBytes = (tile.Stride - 2) * sizeof(float);
		var bytes = new byte[(tile.Values.Length / tile.Stride - 2) * rowBytes];
		for (int j = 0; j < bytes.Length / rowBytes; j++)
			Buffer.BlockCopy(tile.Values, ((j + 1) * tile.Stride + 1) * sizeof(float), bytes, j * rowBytes, rowBytes);
		return Convert.ToHexString(SHA256.HashData(bytes));
	}

	private bool ProtectedCell(int x, int z)
	{
		int k = z * _width + x;
		return _weight[k] == 0.0f && _weight[k + 1] == 0.0f && _weight[k + _width] == 0.0f && _weight[k + _width + 1] == 0.0f;
	}

	public double Sample(double x, double z, bool forPlacement)
	{
		double fx = x / _tile - 0.5, fz = z / _tile - 0.5;
		if (!UsesDetail || !(fx >= 0.0 && fz >= 0.0 && fx < _width - 1 && fz < _height - 1))
			return double.NaN;
		int i = (int)fx, j = (int)fz;
		int cx = i / _cells, cz = j / _cells, id = Index(cx, cz);
		if ((!forPlacement && !Volatile.Read(ref _active[id])) ||
			Triangle(_weight, j * _width + i, _width, fx - i, fz - j) <= 0.0)
			return double.NaN;
		Tile tile = _tiles[id].Value;
		double u = (fx - cx * _cells) * 2.0, v = (fz - cz * _cells) * 2.0;
		int a = (int)u, b = (int)v;
		return Triangle(tile.Values, (b + 1) * tile.Stride + a + 1, tile.Stride, u - a, v - b);
	}

	public bool HasMedium() => _mediumForms;

	public double SampleSurface(double x, double z, bool forPlacement)
	{
		double fine = Sample(x, z, forPlacement);
		return double.IsNaN(fine) ? SampleCoarse(x, z) : fine;
	}

	public double SampleCoarse(double x, double z)
	{
		double fx = x / _tile - 0.5, fz = z / _tile - 0.5;
		if (!_mediumForms || !(fx >= 0.0 && fz >= 0.0 && fx < _width - 1 && fz < _height - 1))
			return double.NaN;
		int i = (int)fx, j = (int)fz;
		return Triangle(_coarse, j * _width + i, _width, fx - i, fz - j);
	}

	public float CoarseNode(int x, int z) => _coarse[z * _width + x];

	private int ClampX(int x) => Math.Clamp(x, 0, (_width - 1) * 2);
	private int ClampZ(int z) => Math.Clamp(z, 0, (_height - 1) * 2);
}

public partial class FastGrid
{
	public FineRelief CreateFineRelief(Inputs input, double[] parameters)
	{
		var fine = new FineRelief();
		if (fine.Initialize(input, parameters))
			return fine;
		fine.Dispose();
		return null;
	}
}
