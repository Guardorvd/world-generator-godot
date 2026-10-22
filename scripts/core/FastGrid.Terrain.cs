using System;
using System.Collections.Generic;
using Godot;

public partial class FastGrid
{
	// Copy attributes in original triangle/vertex encounter order. No retriangulation
	// or arithmetic on attributes: the streamed surface remains byte-identical.
	public Godot.Collections.Dictionary PartitionTerrain(Godot.Collections.Array arrays, double tile, int cells)
	{
		var positions = arrays[(int)Mesh.ArrayType.Vertex].AsVector3Array();
		var indices = arrays[(int)Mesh.ArrayType.Index].AsInt32Array();
		var normals = arrays[(int)Mesh.ArrayType.Normal].VariantType == Variant.Type.Nil
			? Array.Empty<Vector3>() : arrays[(int)Mesh.ArrayType.Normal].AsVector3Array();
		var uv = arrays[(int)Mesh.ArrayType.TexUV].VariantType == Variant.Type.Nil
			? Array.Empty<Vector2>() : arrays[(int)Mesh.ArrayType.TexUV].AsVector2Array();
		var uv2 = arrays[(int)Mesh.ArrayType.TexUV2].VariantType == Variant.Type.Nil
			? Array.Empty<Vector2>() : arrays[(int)Mesh.ArrayType.TexUV2].AsVector2Array();
		var colors = arrays[(int)Mesh.ArrayType.Color].VariantType == Variant.Type.Nil
			? Array.Empty<Color>() : arrays[(int)Mesh.ArrayType.Color].AsColorArray();
		var pieces = new Dictionary<Vector2I, TerrainPiece>();
		for (int at = 0; at < indices.Length; at += 3)
		{
			var a = positions[indices[at]];
			var b = positions[indices[at + 1]];
			var c = positions[indices[at + 2]];
			var key = new Vector2I(
				(int)Math.Floor((Math.Min(a.X, Math.Min(b.X, c.X)) / tile - 0.5) / cells),
				(int)Math.Floor((Math.Min(a.Z, Math.Min(b.Z, c.Z)) / tile - 0.5) / cells));
			if (!pieces.TryGetValue(key, out var piece))
				pieces.Add(key, piece = new TerrainPiece());
			for (int corner = 0; corner < 3; corner++)
			{
				int id = indices[at + corner];
				if (!piece.Remap.TryGetValue(id, out int local))
				{
					local = piece.Ids.Count;
					piece.Remap.Add(id, local);
					piece.Ids.Add(id);
				}
				piece.Indices.Add(local);
			}
		}
		var result = new Godot.Collections.Dictionary();
		foreach (var (key, piece) in pieces)
		{
			var output = new Godot.Collections.Array();
			output.Resize((int)Mesh.ArrayType.Max);
			output[(int)Mesh.ArrayType.Vertex] = CopyTerrainAttribute(positions, piece.Ids);
			if (normals.Length > 0) output[(int)Mesh.ArrayType.Normal] = CopyTerrainAttribute(normals, piece.Ids);
			if (uv.Length > 0) output[(int)Mesh.ArrayType.TexUV] = CopyTerrainAttribute(uv, piece.Ids);
			if (uv2.Length > 0) output[(int)Mesh.ArrayType.TexUV2] = CopyTerrainAttribute(uv2, piece.Ids);
			if (colors.Length > 0) output[(int)Mesh.ArrayType.Color] = CopyTerrainAttribute(colors, piece.Ids);
			output[(int)Mesh.ArrayType.Index] = piece.Indices.ToArray();
			result[key] = output;
		}
		return result;
	}

	private static T[] CopyTerrainAttribute<T>(T[] source, List<int> ids)
	{
		var result = new T[ids.Count];
		for (int i = 0; i < result.Length; i++) result[i] = source[ids[i]];
		return result;
	}

	private sealed class TerrainPiece
	{
		public readonly Dictionary<int, int> Remap = new();
		public readonly List<int> Ids = new();
		public readonly List<int> Indices = new();
	}
}
