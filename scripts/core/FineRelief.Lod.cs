using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Godot;
using MeshArrays = Godot.Collections.Array;

public partial class FineRelief
{
	private int _lodMidStep, _lodFarStep;
	private Vector2[] _lodHeightRanges;

	private readonly record struct LodRect(int X0, int Z0, int X1, int Z1)
	{
		public bool HasArea => X1 > X0 && Z1 > Z0;
	}

	private readonly record struct LodLayout(LodRect Whole, LodRect Core)
	{
		public LodRect Right => new(Core.X1, Whole.Z0, Whole.X1, Whole.Z1);
		public LodRect Bottom => new(Whole.X0, Core.Z1, Core.X1, Whole.Z1);
	}

	private LodLayout Layout(int cx, int cz)
	{
		int x = cx * _cells, z = cz * _cells;
		int endX = Math.Min(x + _cells, _width - 1), endZ = Math.Min(z + _cells, _height - 1);
		return new LodLayout(new(x, z, endX, endZ),
			new(x, z, x + (endX - x) / _lodFarStep * _lodFarStep, z + (endZ - z) / _lodFarStep * _lodFarStep));
	}

	public void PrepareLods(int midStep, int farStep)
	{
		_lodMidStep = midStep;
		_lodFarStep = farStep;
		var heightRanges = new Vector2[_columns * _rows];
		Parallel.For(0, heightRanges.Length, index =>
		{
			var b = Layout(index % _columns, index / _columns).Whole;
			float low = float.PositiveInfinity, high = float.NegativeInfinity;
			for (int z = b.Z0; z <= b.Z1; z++)
			for (int x = b.X0; x <= b.X1; x++)
			{
				float height = CoarseNode(x, z);
				low = Math.Min(low, height);
				high = Math.Max(high, height);
			}
			heightRanges[index] = new Vector2(low, high);
		});
		_lodHeightRanges = heightRanges;
	}

	public Vector2 LodHeightRange(int cx, int cz) => _lodHeightRanges[Index(cx, cz)];

	private Vector4 LodPoint(int x, int z)
	{
		var n = FastGrid.TerrainGridNormal(_coarse, _width, _height, (float)_tile, x, z);
		return new Vector4(CoarseNode(x, z), n.X, n.Y, n.Z);
	}

	// A common piecewise-linear edge also serves the short strips beyond the last complete 16 m square.
	private Vector4 LodEdge(int fixedAxis, double at, int start, int end, bool vertical)
	{
		int a = start + (int)((at - start) / _lodFarStep) * _lodFarStep;
		Vector4 Point(int axis) => vertical ? LodPoint(fixedAxis, axis) : LodPoint(axis, fixedAxis);
		if (at == a || at == end)
			return Point((int)at);
		int b = Math.Min(a + _lodFarStep, end);
		return Point(a).Lerp(Point(b), (float)((at - a) / (b - a)));
	}

	private Vector4 LodVertex(LodLayout layout, int x, int z)
	{
		var b = layout.Whole;
		var c = layout.Core;
		if (x == b.X0 || x == b.X1 || (c.HasArea && x == c.X1))
			return LodEdge(x, z, b.Z0, b.Z1, true);
		if (z == b.Z0 || z == b.Z1 || (c.HasArea && z == c.Z1 && x <= c.X1))
			return LodEdge(z, x, b.X0, b.X1, false);
		return LodPoint(x, z);
	}

	private Vector4 SampleLod(LodLayout layout, double x, double z, int step)
	{
		var c = layout.Core;
		LodRect grid;
		if (!c.HasArea)
		{
			grid = layout.Whole;
			step = 1;
		}
		else if (x > c.X1 || z > c.Z1)
		{
			grid = x > c.X1 ? layout.Right : layout.Bottom;
			step = 1;
		}
		else
			grid = c;
		int ix = Math.Min(grid.X0 + (int)((x - grid.X0) / step) * step, grid.X1 - step);
		int iz = Math.Min(grid.Z0 + (int)((z - grid.Z0) / step) * step, grid.Z1 - step);
		float u = (float)((x - ix) / step), v = (float)((z - iz) / step);
		var b = LodVertex(layout, ix + step, iz);
		var c1 = LodVertex(layout, ix, iz + step);
		if (u + v <= 1.0f)
		{
			var a = LodVertex(layout, ix, iz);
			return a + (b - a) * u + (c1 - a) * v;
		}
		var d = LodVertex(layout, ix + step, iz + step);
		return d + (c1 - d) * (1.0f - u) + (b - d) * (1.0f - v);
	}

	private Vector4 EdgeMorph(LodRect b, Vector3 position)
	{
		double x = position.X / _tile - 0.5, z = position.Z / _tile - 0.5;
		if (x == b.X0 || x == b.X1)
			return LodEdge((int)x, z, b.Z0, b.Z1, true);
		if (z == b.Z0 || z == b.Z1)
			return LodEdge((int)z, x, b.X0, b.X1, false);
		return Vector4.Zero;
	}

	private static void WriteMorph(float[] buffer, int index, Vector4 value)
	{
		int i = index * 4;
		buffer[i] = value.X;
		buffer[i + 1] = value.Y;
		buffer[i + 2] = value.Z;
		buffer[i + 3] = value.W;
	}

	public MeshArrays DecorateFullLod(int cx, int cz, MeshArrays arrays)
	{
		if (!ValidKey(cx, cz) || arrays.Count != (int)Mesh.ArrayType.Max)
			return arrays;
		var layout = Layout(cx, cz);
		var pos = arrays[(int)Mesh.ArrayType.Vertex].AsVector3Array();
		var next = new float[pos.Length * 4];
		var edges = new float[next.Length];
		for (int i = 0; i < pos.Length; i++)
		{
			Vector3 p = pos[i];
			WriteMorph(next, i, SampleLod(layout, p.X / _tile - 0.5, p.Z / _tile - 0.5, _lodMidStep));
			WriteMorph(edges, i, EdgeMorph(layout.Whole, p));
		}
		var decorated = arrays.Duplicate();
		decorated[(int)Mesh.ArrayType.Custom0] = next;
		decorated[(int)Mesh.ArrayType.Custom1] = edges;
		return decorated;
	}

	public MeshArrays BuildMorphLod(int cx, int cz, int step)
	{
		if (!ValidKey(cx, cz) || (step != _lodMidStep && step != _lodFarStep))
			return new MeshArrays();
		var layout = Layout(cx, cz);
		var piece = new MeshPiece(true);
		bool morph = step == _lodMidStep;
		if (layout.Core.HasArea)
		{
			AddGrid(layout.Core, step);
			AddGrid(layout.Right, 1);
			AddGrid(layout.Bottom, 1);
		}
		else
			AddGrid(layout.Whole, 1);
		return piece.Arrays(morph);

		int Add(int x, int z, float sink = 0.0f)
		{
			Vector4 source = LodVertex(layout, x, z);
			Vector4 target = morph ? SampleLod(layout, x, z, _lodFarStep) : source;
			var p = new Vector3((float)((x + 0.5) * _tile), source.X - sink, (float)((z + 0.5) * _tile));
			return piece.Add(p, new Vector3(source.Y, source.Z, source.W),
				new Vector2((x + 0.5f) / _width, (z + 0.5f) / _height), Vector2.Zero, new Color(0, 0, 0, 0),
				target.X - sink, new Vector3(target.Y, target.Z, target.W), source);
		}

		void AddGrid(LodRect grid, int stride)
		{
			if (!grid.HasArea)
				return;
			int columns = (grid.X1 - grid.X0) / stride + 1;
			int start = -1;
			for (int z = grid.Z0; z <= grid.Z1; z += stride)
			for (int x = grid.X0; x <= grid.X1; x += stride)
			{
				int id = Add(x, z);
				if (start == -1) start = id;
				if (x == grid.X0 || z == grid.Z0) continue;
				piece.Triangle(id - columns - 1, id - columns, id - 1);
				piece.Triangle(id - columns, id, id - 1);
			}

			// The outer terrain keeps its existing independent geometry and perimeter skirts.
			int rows = (grid.Z1 - grid.Z0) / stride + 1;
			if (grid.Z0 == 0) AddSkirt(grid.X0, grid.Z0, stride, 0, start, 1, columns, false);
			if (grid.Z1 == _height - 1) AddSkirt(grid.X0, grid.Z1, stride, 0, start + (rows - 1) * columns, 1, columns, true);
			if (grid.X0 == 0) AddSkirt(grid.X0, grid.Z0, 0, stride, start, columns, rows, true);
			if (grid.X1 == _width - 1) AddSkirt(grid.X1, grid.Z0, 0, stride, start + columns - 1, columns, rows, false);
		}

		void AddSkirt(int x, int z, int dx, int dz, int top, int stride, int count, bool reverse)
		{
			float depth = (float)(_lodFarStep * _tile * 0.5);
			int previous = Add(x, z, depth);
			for (int i = 1; i < count; i++)
			{
				int bottom = Add(x + i * dx, z + i * dz, depth);
				if (reverse)
				{
					piece.Triangle(top, top + stride, previous);
					piece.Triangle(top + stride, bottom, previous);
				}
				else
				{
					piece.Triangle(top, previous, top + stride);
					piece.Triangle(top + stride, previous, bottom);
				}
				top += stride;
				previous = bottom;
			}
		}
	}
}
