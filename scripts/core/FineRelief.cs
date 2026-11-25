using System;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using Godot;
using Inputs = Godot.Collections.Dictionary;

/// <summary>Derived terrain. Workers calculate immutable tiles; only the scene publishes them to physics.</summary>
public partial class FineRelief : RefCounted
{
	// Keep the native parameter layout in sync with WorldReliefDetailConfig.params(). The mask has its own (ReliefMask).
	internal enum Parameter
	{
		Step, Bicubic, Clamp, MaxOffset, TileBytes,
		Forms, FormGradeLimit, FormGradeGain,
		Rill, RillAlong, RillAcross, RillDepth, RillCover, RillSlopeFrom, RillSlopeTo, RillCurvature, RillRim,
		Root, RootAlong, RootAcross, RootHeight, RootCover, RootPair, RootPitShare,
		Terrace, TerraceAlong, TerraceAcross, TerraceHeight, TerraceCover, TerraceSlopeFrom, TerraceSlopeTo, TerraceLip,
		Flood, FloodAlong, FloodAcross, FloodDepth, FloodCover, FloodNear, FloodFar, FloodGrade,
		Bank, BankAlong, BankAcross, BankHeight, BankCover, BankNear, BankFar, BankLip, Count
	}
	private int _width, _height, _cells, _columns, _rows;
	private double _tile, _step, _maxOffset;
	private float[] _coarse, _weight;
	private bool _bicubic, _clamp, _smallForms;
	private Lazy<Tile>[] _tiles;
	private long _tileBytes;
	// A one-node halo stores the same final heights as the neighbouring tile for shared vertex normals.
	private sealed record Tile(int Stride, float[] Values)
	{
		public float Node(int x, int z) => Values[(z + 1) * Stride + x + 1];
	}
	private bool UsesDetail => _bicubic || _smallForms;

	internal bool Initialize(Inputs input, ReliefMask mask, double[] profile)
	{
		if (mask == null || profile.Length != (int)Parameter.Count)
			return false;
		foreach (double value in profile)
			if (!double.IsFinite(value))
				return false;
		double P(Parameter key) => profile[(int)key];
		_width = mask.Width;
		_height = mask.Height;
		_tile = mask.Tile;
		_cells = input["cells"].AsInt32();
		_step = P(Parameter.Step);
		int count = _width * _height;
		// Узлы 2 м совпадают с узлами 4 м и их диагоналями только при шаге в половину клетки.
		if (_cells <= 0 || _step <= 0.0 || _step * 2.0 != _tile)
			return false;
		_coarse = input["hv"].AsFloat32Array();
		if (_coarse.Length != count)
			return false;
		_columns = (_width - 2) / _cells + 1;
		_rows = (_height - 2) / _cells + 1;
		_smallForms = P(Parameter.Forms) != 0.0;
		// Худший случай памяти плиток: узлы 2 м всех чанков с ореолом в один узел, плюс маска и высоты 4 м.
		long maxNodes = (2L * (_width - 1) + 3L * _columns) * (2L * (_height - 1) + 3L * _rows);
		if (_smallForms && !InitializeForms(input, profile, count))
			return false;
		if ((maxNodes + 2L * count) * sizeof(float) + FormBytes() > P(Parameter.TileBytes))
			return false;
		_bicubic = P(Parameter.Bicubic) != 0.0;
		_clamp = P(Parameter.Clamp) != 0.0;
		_maxOffset = Math.Max(0.0, P(Parameter.MaxOffset));
		_weight = mask.Weight;
		if (_smallForms)
			for (int i = 0; i < count; i++)
				if (mask.ClearOfWater[i])
					_habitat[i] |= ClearWater;
		_tiles = new Lazy<Tile>[_columns * _rows];
		for (int i = 0; i < _tiles.Length; i++)
		{
			int key = i;
			_tiles[i] = new Lazy<Tile>(() => BuildTile(key), LazyThreadSafetyMode.ExecutionAndPublication);
		}
		return true;
	}

	private static double Smooth(double a, double b, double v) => ReliefMask.Smooth(a, b, v);

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
		return linear + Math.Clamp(smooth - linear, -_maxOffset, _maxOffset) * weight;
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

	/// <summary>Опора и посадка: поле 2 м везде, где маска разрешает, независимо от того, показан ли уже меш 2 м.
	/// Плитка строится по первому запросу (обычно её заранее готовит Warm), меш догоняет её морфингом.</summary>
	public double Sample(double x, double z)
	{
		double fx = x / _tile - 0.5, fz = z / _tile - 0.5;
		if (!UsesDetail || !(fx >= 0.0 && fz >= 0.0 && fx < _width - 1 && fz < _height - 1))
			return double.NaN;
		int i = (int)fx, j = (int)fz;
		int cx = i / _cells, cz = j / _cells, id = Index(cx, cz);
		if (Triangle(_weight, j * _width + i, _width, fx - i, fz - j) <= 0.0)
			return double.NaN;
		Tile tile = _tiles[id].Value;
		double u = (fx - cx * _cells) * 2.0, v = (fz - cz * _cells) * 2.0;
		int a = (int)u, b = (int)v;
		return Triangle(tile.Values, (b + 1) * tile.Stride + a + 1, tile.Stride, u - a, v - b);
	}

	private float CoarseNode(int x, int z) => _coarse[z * _width + x];

	private int ClampX(int x) => Math.Clamp(x, 0, (_width - 1) * 2);
	private int ClampZ(int z) => Math.Clamp(z, 0, (_height - 1) * 2);
}

public partial class FastGrid
{
	public FineRelief CreateFineRelief(Inputs input, double[] maskParameters, double[] parameters)
	{
		var fine = new FineRelief();
		if (fine.Initialize(input, ReliefMask.Build(input, maskParameters), parameters))
			return fine;
		fine.Dispose();
		return null;
	}
}
