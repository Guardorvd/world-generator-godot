using System;
using System.Collections.Generic;
using Godot;
using MeshArrays = Godot.Collections.Array;

public partial class FineRelief
{
	// Subdivide the production 4 m triangles in place. The 1 m road triangles and all their
	// vertex attributes are copied unchanged, including the original coarse morph target.
	public MeshArrays BuildMeshes(int cx, int cz, int pieceCells, MeshArrays arrays)
	{
		var result = new MeshArrays();
		if (!ValidKey(cx, cz) || arrays.Count != (int)Mesh.ArrayType.Max || pieceCells <= 0 || _cells % pieceCells != 0)
			return result;
		var fine = _tiles[Index(cx, cz)].Value;
		bool joinEdges = _lodHeightRanges != null;
		var bounds = joinEdges ? Layout(cx, cz).Whole : default;
		int ox = cx * _cells, oz = cz * _cells;
		var xyz = arrays[(int)Mesh.ArrayType.Vertex].AsVector3Array();
		var normals = arrays[(int)Mesh.ArrayType.Normal].AsVector3Array();
		var uv = arrays[(int)Mesh.ArrayType.TexUV].AsVector2Array();
		var uv2 = arrays[(int)Mesh.ArrayType.TexUV2].AsVector2Array();
		var color = arrays[(int)Mesh.ArrayType.Color].AsColorArray();
		var idx = arrays[(int)Mesh.ArrayType.Index].AsInt32Array();
		int piecesPerSide = _cells / pieceCells;
		var pieces = new MeshPiece[piecesPerSide * piecesPerSide];

		for (int at = 0; at < idx.Length; at += 3)
		{
			int a = idx[at], b = idx[at + 1], c = idx[at + 2];
			float x0 = Math.Min(xyz[a].X, Math.Min(xyz[b].X, xyz[c].X));
			float z0 = Math.Min(xyz[a].Z, Math.Min(xyz[b].Z, xyz[c].Z));
			int x = (int)(x0 / _tile - 0.5), z = (int)(z0 / _tile - 0.5);
			int part = (z - oz) / pieceCells * piecesPerSide + (x - ox) / pieceCells;
			var piece = pieces[part] ??= new MeshPiece(joinEdges);
			int ia = Copy(a, piece), ib = Copy(b, piece), ic = Copy(c, piece);
			float dx = Math.Max(xyz[a].X, Math.Max(xyz[b].X, xyz[c].X)) - x0;
			float dz = Math.Max(xyz[a].Z, Math.Max(xyz[b].Z, xyz[c].Z)) - z0;
			if (!UsesDetail || dx != _tile || dz != _tile || ProtectedCell(x, z))
			{
				piece.Triangle(ia, ib, ic);
				continue;
			}
			int ab = Mid(a, b, piece), bc = Mid(b, c, piece), ca = Mid(c, a, piece);
			piece.Triangle(ia, ab, ca);
			piece.Triangle(ab, ib, bc);
			piece.Triangle(ca, bc, ic);
			piece.Triangle(ab, bc, ca);
		}
		foreach (var piece in pieces)
			if (piece != null)
				result.Add(piece.Arrays());
		return result;

		int Copy(int id, MeshPiece piece)
		{
			if (piece.Vertices.TryGetValue(id, out int target))
				return target;
			Vector3 p = xyz[id], n = normals[id];
			float baseHeight = p.Y;
			double fx = p.X / _tile - 0.5, fz = p.Z / _tile - 0.5;
			if (UsesDetail && fx == (int)fx && fz == (int)fz && _weight[(int)fz * _width + (int)fx] > 0.0f)
			{
				p.Y = fine.Node(((int)fx - ox) * 2, ((int)fz - oz) * 2);
				n = Normal((int)fx * 2, (int)fz * 2);
			}
			target = piece.Add(p, n, uv[id], uv2.Length == 0 ? Vector2.Zero : uv2[id],
				color.Length == 0 ? new Color(0, 0, 0, 0) : color[id], baseHeight, normals[id], Edge(p));
			piece.Vertices.Add(id, target);
			return target;
		}

		int Mid(int a, int b, MeshPiece piece)
		{
			var edge = (Math.Min(a, b), Math.Max(a, b));
			if (piece.Edges.TryGetValue(edge, out int target))
				return target;
			Vector3 p = (xyz[a] + xyz[b]) * 0.5f;
			var baseNormal = (normals[a] + normals[b]) * 0.5f;
			int gx = (int)((p.X - _tile * 0.5) / _step), gz = (int)((p.Z - _tile * 0.5) / _step);
			float baseHeight = p.Y;
			p.Y = fine.Node(gx - 2 * ox, gz - 2 * oz);
			// On a protected edge keep the original interpolated height and normal, also at a road T-junction.
			int cell = CoarseQuad(gx, gz, out double u, out double v);
			double weight = Triangle(_weight, cell, _width, u, v);
			var n = weight > 0.0 ? Normal(gx, gz) : baseNormal.Normalized();
			if (weight <= 0.0)
				p.Y = baseHeight;
			target = piece.Add(p, n, (uv[a] + uv[b]) * 0.5f,
				uv2.Length == 0 ? Vector2.Zero : (uv2[a] + uv2[b]) * 0.5f,
				color.Length == 0 ? new Color(0, 0, 0, 0) : (color[a] + color[b]) * 0.5f, baseHeight, baseNormal, Edge(p));
			piece.Edges.Add(edge, target);
			return target;
		}

		Vector4 Edge(Vector3 p) => joinEdges ? EdgeMorph(bounds, p) : Vector4.Zero;

		Vector3 Normal(int x, int z)
		{
			int i = x - 2 * ox, j = z - 2 * oz;
			return new Vector3(fine.Node(i - 1, j) - fine.Node(i + 1, j), (float)(2.0 * _step),
				fine.Node(i, j - 1) - fine.Node(i, j + 1)).Normalized();
		}
	}

	private sealed class MeshPiece
	{
		public readonly Dictionary<int, int> Vertices = new();
		public readonly Dictionary<(int, int), int> Edges = new();
		private readonly List<Vector3> _positions = new(), _normals = new();
		private readonly List<Vector2> _uv = new(), _uv2 = new();
		private readonly List<Color> _colors = new();
		private readonly List<float> _coarse = new();
		private readonly List<float> _edges;
		private readonly List<int> _indices = new();

		public MeshPiece(bool joinEdges = false)
		{
			if (joinEdges) _edges = new();
		}

		public int Add(Vector3 p, Vector3 n, Vector2 uv, Vector2 uv2, Color color, float y, Vector3 normal, Vector4 edge = default)
		{
			int id = _positions.Count;
			_positions.Add(p);
			_normals.Add(n);
			_uv.Add(uv);
			_uv2.Add(uv2);
			_colors.Add(color);
			_coarse.Add(y);
			_coarse.Add(normal.X);
			_coarse.Add(normal.Y);
			_coarse.Add(normal.Z);
			if (_edges != null)
			{
				_edges.Add(edge.X);
				_edges.Add(edge.Y);
				_edges.Add(edge.Z);
				_edges.Add(edge.W);
			}
			return id;
		}

		public void Triangle(int a, int b, int c)
		{
			_indices.Add(a);
			_indices.Add(b);
			_indices.Add(c);
		}

		public MeshArrays Arrays(bool morph = true)
		{
			var result = new MeshArrays();
			result.Resize((int)Mesh.ArrayType.Max);
			result[(int)Mesh.ArrayType.Vertex] = _positions.ToArray();
			result[(int)Mesh.ArrayType.Normal] = _normals.ToArray();
			result[(int)Mesh.ArrayType.TexUV] = _uv.ToArray();
			result[(int)Mesh.ArrayType.TexUV2] = _uv2.ToArray();
			result[(int)Mesh.ArrayType.Color] = _colors.ToArray();
			if (morph) result[(int)Mesh.ArrayType.Custom0] = _coarse.ToArray();
			if (_edges != null) result[(int)Mesh.ArrayType.Custom1] = _edges.ToArray();
			result[(int)Mesh.ArrayType.Index] = _indices.ToArray();
			return result;
		}
	}
}
