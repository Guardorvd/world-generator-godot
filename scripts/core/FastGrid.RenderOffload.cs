using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Godot;

public partial class FastGrid
{
	private readonly struct DetailSectorKey : IEquatable<DetailSectorKey>
	{
		public readonly int X;
		public readonly int Z;
		public readonly int Shadow;

		public DetailSectorKey(int x, int z, int shadow)
		{
			X = x;
			Z = z;
			Shadow = shadow;
		}

		public bool Equals(DetailSectorKey other) => X == other.X && Z == other.Z && Shadow == other.Shadow;
		public override bool Equals(object obj) => obj is DetailSectorKey other && Equals(other);
		public override int GetHashCode() => HashCode.Combine(X, Z, Shadow);
	}

	private sealed class DetailSectorBucket
	{
		public int Index;
		public DetailSectorKey Key;
		public readonly List<int> Offsets = new();
		public readonly List<double> Changes = new();
		public readonly List<int> SourceChanges = new();
		public float MinX, MinY, MinZ, MaxX, MaxY, MaxZ;

		public void Reset(int index, DetailSectorKey key)
		{
			Index = index;
			Key = key;
			Offsets.Clear();
			Changes.Clear();
			SourceChanges.Clear();
			MinX = MinY = MinZ = float.PositiveInfinity;
			MaxX = MaxY = MaxZ = float.NegativeInfinity;
		}
	}

	[ThreadStatic] private static Dictionary<DetailSectorKey, DetailSectorBucket> _sectorBuckets;
	[ThreadStatic] private static Stack<DetailSectorBucket> _bucketPool;
	[ThreadStatic] private static List<DetailSectorBucket> _bucketOrder;
	[ThreadStatic] private static int[] _rowSector;
	[ThreadStatic] private static int[] _rowLocalAt;
	[ThreadStatic] private static Dictionary<int, float[]> _pow2OutBufs;

	/// <summary>
	/// Разбивает плоский буфер растительности (grass/understory) на сектора на CPU
	/// с переиспользованием ThreadStatic-буферов, разделением теней (<= shadowRadius) и пересчётом смещений changes.
	/// </summary>
	public Godot.Collections.Dictionary PartitionDetailSectors(float[] buffer, int count, int stride, float sectorSize,
		float playerX, float playerZ, float shadowRadius, bool splitShadows, float instanceMargin, double[] changes)
	{
		if (count <= 0 || stride < 12 || (sectorSize <= 0f && !splitShadows) || buffer == null || buffer.Length < count * stride)
		{
			return new Godot.Collections.Dictionary
			{
				["keys"] = Array.Empty<int>(),
				["counts"] = Array.Empty<int>(),
				["bounds"] = Array.Empty<float>(),
				["hashes"] = Array.Empty<long>(),
				["buffers"] = new Godot.Collections.Array(),
				["changes"] = new Godot.Collections.Array(),
				["source_changes"] = new Godot.Collections.Array(),
			};
		}

		var buckets = _sectorBuckets ??= new Dictionary<DetailSectorKey, DetailSectorBucket>(64);
		var pool = _bucketPool ??= new Stack<DetailSectorBucket>(64);
		var order = _bucketOrder ??= new List<DetailSectorBucket>(64);
		foreach (var prev in order)
		{
			prev.Offsets.Clear();
			prev.Changes.Clear();
			prev.SourceChanges.Clear();
			pool.Push(prev);
		}
		buckets.Clear();
		order.Clear();

		if (_rowSector == null || _rowSector.Length < count)
		{
			int capRows = Math.Max(count, 256);
			_rowSector = new int[capRows];
			_rowLocalAt = new int[capRows];
		}

		bool spatial = sectorSize > 0f;
		float invSector = spatial ? 1.0f / sectorSize : 0.0f;
		float shadowR2 = shadowRadius * shadowRadius;

		for (int n = 0; n < count; n++)
		{
			int at = n * stride;
			float x = buffer[at + 3];
			float y = buffer[at + 7];
			float z = buffer[at + 11];
			int sx = spatial ? (int)MathF.Floor(x * invSector) : 0;
			int sz = spatial ? (int)MathF.Floor(z * invSector) : 0;
			int isShadow = 0;
			if (splitShadows)
			{
				float dx = x - playerX;
				float dz = z - playerZ;
				if (dx * dx + dz * dz <= shadowR2)
					isShadow = 1;
			}
			var key = new DetailSectorKey(sx, sz, isShadow);
			if (!buckets.TryGetValue(key, out var bucket))
			{
				bucket = pool.Count > 0 ? pool.Pop() : new DetailSectorBucket();
				bucket.Reset(order.Count, key);
				buckets.Add(key, bucket);
				order.Add(bucket);
			}
			_rowSector[n] = bucket.Index;
			_rowLocalAt[n] = bucket.Offsets.Count * stride;
			bucket.Offsets.Add(at);
			if (x < bucket.MinX) bucket.MinX = x;
			if (y < bucket.MinY) bucket.MinY = y;
			if (z < bucket.MinZ) bucket.MinZ = z;
			if (x > bucket.MaxX) bucket.MaxX = x;
			if (y > bucket.MaxY) bucket.MaxY = y;
			if (z > bucket.MaxZ) bucket.MaxZ = z;
		}

		if (changes != null && changes.Length >= 3)
		{
			for (int i = 0; i + 2 < changes.Length; i += 3)
			{
				int row = (int)changes[i] / stride;
				if ((uint)row < (uint)count)
				{
					var target = order[_rowSector[row]];
					target.Changes.Add(_rowLocalAt[row]);
					target.Changes.Add(changes[i + 1]);
					target.Changes.Add(changes[i + 2]);
					target.SourceChanges.Add(row * stride);
				}
			}
		}

		int sectorCount = order.Count;
		// Publication can span several frames. Cover the ground nearest the player first.
		if (spatial && !splitShadows && sectorCount > 1)
		{
			var player = new Vector2(playerX, playerZ);
			float Distance(DetailSectorBucket bucket) => player.DistanceSquaredTo(
				new Vector2((bucket.MinX + bucket.MaxX) * 0.5f, (bucket.MinZ + bucket.MaxZ) * 0.5f));
			order.Sort((a, b) => Distance(a).CompareTo(Distance(b)));
		}
		var keys = new int[sectorCount * 3];
		var counts = new int[sectorCount];
		var bounds = new float[sectorCount * 6];
		var hashes = new long[sectorCount];
		var buffers = new Godot.Collections.Array();
		var sectorChanges = new Godot.Collections.Array();
		var sourceChanges = new Godot.Collections.Array();
		var outBufs = _pow2OutBufs ??= new Dictionary<int, float[]>(8);

		for (int idx = 0; idx < sectorCount; idx++)
		{
			var bucket = order[idx];
			var key = bucket.Key;
			int c = bucket.Offsets.Count;
			keys[idx * 3] = key.X;
			keys[idx * 3 + 1] = key.Z;
			keys[idx * 3 + 2] = key.Shadow;
			counts[idx] = c;

			int b = idx * 6;
			bounds[b] = bucket.MinX - instanceMargin;
			bounds[b + 1] = bucket.MinY - instanceMargin;
			bounds[b + 2] = bucket.MinZ - instanceMargin;
			bounds[b + 3] = bucket.MaxX + instanceMargin;
			bounds[b + 4] = bucket.MaxY + instanceMargin;
			bounds[b + 5] = bucket.MaxZ + instanceMargin;

			int cap = 16;
			while (cap < c) cap *= 2;
			int totalFloats = cap * stride;
			if (!outBufs.TryGetValue(totalFloats, out var outBuf))
			{
				outBuf = new float[totalFloats];
				outBufs[totalFloats] = outBuf;
			}
			for (int i = 0; i < c; i++)
				Array.Copy(buffer, bucket.Offsets[i], outBuf, i * stride, stride);
			int activeFloats = c * stride;
			ulong h = 14695981039346656037UL;
			var u64 = MemoryMarshal.Cast<float, ulong>(outBuf.AsSpan(0, activeFloats & ~1));
			for (int k = 0; k < u64.Length; k++)
			{
				h ^= u64[k];
				h *= 1099511628211UL;
			}
			if ((activeFloats & 1) != 0)
			{
				h ^= (uint)BitConverter.SingleToInt32Bits(outBuf[activeFloats - 1]);
				h *= 1099511628211UL;
			}
			if (h == 0UL)
				h = 1UL;
			hashes[idx] = unchecked((long)h);
			if (cap > c)
				Array.Clear(outBuf, activeFloats, totalFloats - activeFloats);
			buffers.Add(outBuf);
			sectorChanges.Add(bucket.Changes.Count > 0 ? bucket.Changes.ToArray() : Array.Empty<double>());
			sourceChanges.Add(bucket.SourceChanges.Count > 0 ? bucket.SourceChanges.ToArray() : Array.Empty<int>());
		}

		return new Godot.Collections.Dictionary
		{
			["keys"] = keys,
			["counts"] = counts,
			["bounds"] = bounds,
			["hashes"] = hashes,
			["buffers"] = buffers,
			["changes"] = sectorChanges,
			["source_changes"] = sourceChanges,
		};
	}

	/// <summary>
	/// Генерирует упрощённый меш чанка рельефа (LOD1 step=2, LOD2 step=4) с юбками по краям против швов.
	/// </summary>
	public Godot.Collections.Array BuildTerrainLod(int worldW, int worldH, float tile, int chunkX, int chunkY,
		int chunkCells, int step, float[] heights, byte[] pathMask, float skirtDepth)
		=> BuildTerrainLodArrays(worldW, worldH, tile, chunkX, chunkY, chunkCells, step, heights, skirtDepth);

	internal static Vector3 TerrainGridNormal(float[] heights, int w, int h, float tile, int x, int z)
	{
		float hl = heights[z * w + Math.Max(0, x - 1)], hr = heights[z * w + Math.Min(w - 1, x + 1)];
		float hu = heights[Math.Max(0, z - 1) * w + x], hd = heights[Math.Min(h - 1, z + 1) * w + x];
		return (x > 0 && z > 0 && x < w - 1 && z < h - 1)
			? new Vector3(hl - hr, 2.0f * tile, hu - hd).Normalized()
			: new Vector3((hl - hr) / ((x == 0 || x == w - 1) ? tile : 2.0f * tile), 1.0f,
				(hu - hd) / ((z == 0 || z == h - 1) ? tile : 2.0f * tile)).Normalized();
	}

	internal static Godot.Collections.Array BuildTerrainLodArrays(int worldW, int worldH, float tile, int chunkX, int chunkY,
		int chunkCells, int step, float[] heights, float skirtDepth)
	{
		step = Math.Max(2, step);
		int x0 = chunkX * chunkCells;
		int y0 = chunkY * chunkCells;
		int x1 = Math.Min(worldW - 1, x0 + chunkCells);
		int y1 = Math.Min(worldH - 1, y0 + chunkCells);
		if (worldW < 2 || worldH < 2 || heights == null || heights.Length < worldW * worldH || x0 < 0 || y0 < 0 || x1 <= x0 || y1 <= y0)
			return new Godot.Collections.Array();

		var xs = new List<int>(chunkCells / step + 2);
		var ys = new List<int>(chunkCells / step + 2);
		for (int i = x0; i < x1; i += step) xs.Add(i);
		xs.Add(x1);
		for (int j = y0; j < y1; j += step) ys.Add(j);
		ys.Add(y1);

		int cols = xs.Count;
		int rows = ys.Count;
		int baseVerts = cols * rows;
		int skirtVerts = cols * 2 + rows * 2;
		int totalVerts = baseVerts + skirtVerts;

		var pos = new Vector3[totalVerts];
		var nor = new Vector3[totalVerts];
		var uv = new Vector2[totalVerts];
		var uv2 = new Vector2[totalVerts];
		var colors = new Color[totalVerts];

		float invW = 1.0f / worldW;
		float invH = 1.0f / worldH;
		for (int r = 0; r < rows; r++)
		{
			int j = ys[r];
			for (int c = 0; c < cols; c++)
			{
				int i = xs[c];
				int k = r * cols + c;
				pos[k] = new Vector3((i + 0.5f) * tile, heights[j * worldW + i], (j + 0.5f) * tile);
				nor[k] = TerrainGridNormal(heights, worldW, worldH, tile, i, j);
				uv[k] = new Vector2((i + 0.5f) * invW, (j + 0.5f) * invH);
				uv2[k] = Vector2.Zero;
				colors[k] = new Color(0f, 0f, 0f, 0f);
			}
		}

		int mainQuads = (cols - 1) * (rows - 1);
		int skirtQuads = (cols - 1) * 2 + (rows - 1) * 2;
		var idx = new int[(mainQuads + skirtQuads) * 6];
		int p = 0;
		for (int r = 0; r < rows - 1; r++)
		{
			for (int c = 0; c < cols - 1; c++)
			{
				int a = r * cols + c;
				int b = a + 1;
				int cc = a + cols;
				int d = cc + 1;
				idx[p] = a; idx[p + 1] = b; idx[p + 2] = cc;
				idx[p + 3] = b; idx[p + 4] = d; idx[p + 5] = cc;
				p += 6;
			}
		}

		int sv = baseVerts;
		// Top edge (j = 0, outward -Z)
		int topStart = sv;
		for (int c = 0; c < cols; c++, sv++)
			CopySkirtVertex(c, sv, skirtDepth, pos, nor, uv, uv2, colors);
		for (int c = 0; c < cols - 1; c++)
		{
			int t0 = c, t1 = c + 1, s0 = topStart + c, s1 = s0 + 1;
			idx[p] = t0; idx[p + 1] = s0; idx[p + 2] = t1;
			idx[p + 3] = t1; idx[p + 4] = s0; idx[p + 5] = s1;
			p += 6;
		}

		// Bottom edge (j = rows - 1, outward +Z)
		int botStart = sv;
		int botRow = (rows - 1) * cols;
		for (int c = 0; c < cols; c++, sv++)
			CopySkirtVertex(botRow + c, sv, skirtDepth, pos, nor, uv, uv2, colors);
		for (int c = 0; c < cols - 1; c++)
		{
			int t0 = botRow + c, t1 = t0 + 1, s0 = botStart + c, s1 = s0 + 1;
			idx[p] = t0; idx[p + 1] = t1; idx[p + 2] = s0;
			idx[p + 3] = t1; idx[p + 4] = s1; idx[p + 5] = s0;
			p += 6;
		}

		// Left edge (i = 0, outward -X)
		int leftStart = sv;
		for (int r = 0; r < rows; r++, sv++)
			CopySkirtVertex(r * cols, sv, skirtDepth, pos, nor, uv, uv2, colors);
		for (int r = 0; r < rows - 1; r++)
		{
			int t0 = r * cols, t1 = (r + 1) * cols, s0 = leftStart + r, s1 = s0 + 1;
			idx[p] = t0; idx[p + 1] = t1; idx[p + 2] = s0;
			idx[p + 3] = t1; idx[p + 4] = s1; idx[p + 5] = s0;
			p += 6;
		}

		// Right edge (i = cols - 1, outward +X)
		int rightStart = sv;
		for (int r = 0; r < rows; r++, sv++)
			CopySkirtVertex(r * cols + cols - 1, sv, skirtDepth, pos, nor, uv, uv2, colors);
		for (int r = 0; r < rows - 1; r++)
		{
			int t0 = r * cols + cols - 1, t1 = (r + 1) * cols + cols - 1, s0 = rightStart + r, s1 = s0 + 1;
			idx[p] = t0; idx[p + 1] = s0; idx[p + 2] = t1;
			idx[p + 3] = t1; idx[p + 4] = s0; idx[p + 5] = s1;
			p += 6;
		}

		var arrays = new Godot.Collections.Array();
		arrays.Resize((int)Mesh.ArrayType.Max);
		arrays[(int)Mesh.ArrayType.Vertex] = pos;
		arrays[(int)Mesh.ArrayType.Normal] = nor;
		arrays[(int)Mesh.ArrayType.TexUV] = uv;
		arrays[(int)Mesh.ArrayType.TexUV2] = uv2;
		arrays[(int)Mesh.ArrayType.Color] = colors;
		arrays[(int)Mesh.ArrayType.Index] = idx;
		return arrays;
	}

	private static void CopySkirtVertex(int src, int dst, float skirtDepth, Vector3[] pos, Vector3[] nor,
		Vector2[] uv, Vector2[] uv2, Color[] colors)
	{
		Vector3 v = pos[src];
		v.Y -= skirtDepth;
		pos[dst] = v;
		nor[dst] = nor[src];
		uv[dst] = uv[src];
		uv2[dst] = uv2[src];
		colors[dst] = colors[src];
	}

	private static float WgHash2(int cx, int cy, int seed)
	{
		uint h = (unchecked((uint)cx) * 374761393u + unchecked((uint)cy) * 668265263u) ^ unchecked((uint)seed);
		h = (h ^ (h >> 13)) * 1274126177u;
		return (h ^ (h >> 16)) * (1.0f / 4294967296.0f);
	}

	private static float WgVNoise(float x, float y, float scale, int seed)
	{
		float fx = x / scale;
		float fy = y / scale;
		int ix = (int)MathF.Floor(fx);
		int iy = (int)MathF.Floor(fy);
		float tx = fx - ix;
		float ty = fy - iy;
		tx = tx * tx * (3.0f - 2.0f * tx);
		ty = ty * ty * (3.0f - 2.0f * ty);
		float a = WgHash2(ix, iy, seed) * (1.0f - tx) + WgHash2(ix + 1, iy, seed) * tx;
		float b = WgHash2(ix, iy + 1, seed) * (1.0f - tx) + WgHash2(ix + 1, iy + 1, seed) * tx;
		return a * (1.0f - ty) + b * ty;
	}

	/// <summary>
	/// Запекает 3 канала шума открытых растительных сообществ (big=36, mid=11, bloom=6) в RGB8 текстуру на CPU.
	/// </summary>
	public byte[] BakeCommunityNoise(int width, int height, int seedX, int seedY, int seedW)
	{
		if (width <= 0 || height <= 0)
			return Array.Empty<byte>();
		var bytes = new byte[width * height * 3];
		System.Threading.Tasks.Parallel.For(0, height, j =>
		{
			float cy = j + 0.5f;
			int row = j * width * 3;
			for (int i = 0; i < width; i++)
			{
				float cx = i + 0.5f;
				int at = row + i * 3;
				bytes[at] = (byte)Math.Clamp((int)MathF.Round(WgVNoise(cx, cy, 36.0f, seedX) * 255.0f), 0, 255);
				bytes[at + 1] = (byte)Math.Clamp((int)MathF.Round(WgVNoise(cx, cy, 11.0f, seedY) * 255.0f), 0, 255);
				bytes[at + 2] = (byte)Math.Clamp((int)MathF.Round(WgVNoise(cx, cy, 6.0f, seedW) * 255.0f), 0, 255);
			}
		});
		return bytes;
	}

	[ThreadStatic] private static float[][] _carpetParts;
	[ThreadStatic] private static int[] _carpetFilled;
	private static readonly Color[] CarpetPetals =
	{
		new(1.0f, 1.0f, 0.94f),
		new(1.0f, 0.84f, 0.2f),
		new(0.66f, 0.52f, 0.98f),
		new(1.0f, 0.6f, 0.76f),
	};

	private static float Smoothstep(float edge0, float edge1, float x)
	{
		float t = Math.Clamp((x - edge0) / (edge1 - edge0), 0.0f, 1.0f);
		return t * t * (3.0f - 2.0f * t);
	}

	private static float CarpetValueNoise(float sx, float sz, int salt)
	{
		int x0 = (int)MathF.Floor(sx);
		int z0 = (int)MathF.Floor(sz);
		float fx = sx - x0;
		float fz = sz - z0;
		fx = fx * fx * (3.0f - 2.0f * fx);
		fz = fz * fz * (3.0f - 2.0f * fz);
		float a = Mathf.Lerp(WgHash2(x0, z0, salt), WgHash2(x0 + 1, z0, salt), fx);
		float b = Mathf.Lerp(WgHash2(x0, z0 + 1, salt), WgHash2(x0 + 1, z0 + 1, salt), fx);
		return Mathf.Lerp(a, b, fz);
	}

	private static void PutCarpetRow(float[] dst, int index, in Basis basis, float x, float y, float z,
		float r, float g, float b, float a, float seed, float bend)
	{
		int o = index * 20;
		dst[o] = basis.X.X;
		dst[o + 1] = basis.Y.X;
		dst[o + 2] = basis.Z.X;
		dst[o + 3] = x;
		dst[o + 4] = basis.X.Y;
		dst[o + 5] = basis.Y.Y;
		dst[o + 6] = basis.Z.Y;
		dst[o + 7] = y;
		dst[o + 8] = basis.X.Z;
		dst[o + 9] = basis.Y.Z;
		dst[o + 10] = basis.Z.Z;
		dst[o + 11] = z;
		dst[o + 12] = r;
		dst[o + 13] = g;
		dst[o + 14] = b;
		dst[o + 15] = a;
		dst[o + 16] = 0.0f;
		dst[o + 17] = seed;
		dst[o + 18] = bend;
		dst[o + 19] = 0.0f;
	}

	private const int CarpetMeadow = 0, CarpetDry = 1, CarpetShade = 2, CarpetMoss = 5, CarpetLeaves = 6, CarpetBerry = 7, CarpetSedge = 8;
	private const float ExpMixNoiseM = 4.7f, ExpMixMossEnd = 0.38f, ExpMixBerryEnd = 0.87f;
	// Доля мха в лесном ковре ложбины; остальное — осока (прежние доли мха 0,38 и осоки 1 − 0,87 в общем ковре).
	private const float ExpHollowMossShare = ExpMixMossEnd / (ExpMixMossEnd + 1.0f - ExpMixBerryEnd);
	// [rBase, rParched, gBase, gParched, bBase, bJitter] для CARPET_MOSS..CARPET_SEDGE (как GroundCarpet.EXP_CARPET_PALETTE)
	private static readonly float[][] ExpCarpetPalette =
	{
		new[] { 0.22f, 0.06f, 0.38f, -0.05f, 0.17f, 0.03f },
		new[] { 0.42f, 0.08f, 0.31f, -0.03f, 0.16f, 0.03f },
		new[] { 0.36f, 0.10f, 0.30f, -0.04f, 0.18f, 0.04f },
		new[] { 0.31f, 0.08f, 0.38f, -0.03f, 0.20f, 0.03f },
	};

	/// <summary>
	/// Быстрая сборка буферов травяных куртинок 4м плитки GroundCarpet на C# поверх потокобезопасного RideGround.
	/// </summary>
	public Godot.Collections.Dictionary BuildCarpetGrassTile(RideGround ride, int tileI, int tileJ, float tileSize, int sub,
		float cover, float shade, float parched, float straw, float tall, float grow, bool flowers,
		float tcR, float tcG, float tcB, float surfaceR, float forestMix, float fern, float shrub, float berry,
		bool expedition, float flowerMul = 1.0f)
	{
		if (ride == null || !ride.Ready() || sub <= 0)
			return new Godot.Collections.Dictionary { ["ok"] = false };

		const int stride = 20;
		int maxRows = sub * sub;
		// The first five slots match GroundCarpet; stones are filled in GDScript.
		const int kinds = 9;
		var partsBuf = _carpetParts;
		if (partsBuf == null || partsBuf[0].Length < maxRows * stride)
		{
			partsBuf = new float[kinds][];
			for (int k = 0; k < kinds; k++)
				partsBuf[k] = new float[maxRows * stride];
			_carpetParts = partsBuf;
		}
		var filled = _carpetFilled ??= new int[kinds];
		Array.Clear(filled);

		float step = tileSize / sub;
		float alpha = 1.0f - surfaceR;
		float yLow = float.PositiveInfinity;
		float yHigh = float.NegativeInfinity;

		for (int m = 0; m < maxRows; m++)
		{
			int gx = tileI * sub + m % sub;
			int gz = tileJ * sub + m / sub;
			float x = (gx + 0.12f + 0.76f * WgHash2(gx, gz, 211)) * step;
			float z = (gz + 0.12f + 0.76f * WgHash2(gx, gz, 223)) * step;
			float patch = CarpetValueNoise(x / 6.0f, z / 6.0f, 229);
			float keep = cover * Smoothstep(0.03f + 0.37f * shade, 0.22f + 0.46f * shade, patch);
			if (WgHash2(gx, gz, 227) > keep)
				continue;

			double depth = ride.Depth(x, z, double.NegativeInfinity);
			if (double.IsNaN(depth))
				return new Godot.Collections.Dictionary { ["ok"] = false };
			if (depth > 0.0)
				continue;

			double y0 = ride.Ground(x, z);
			double yx = ride.Ground(x + 0.4, z);
			double yz = ride.Ground(x, z + 0.4);
			if (double.IsNaN(y0) || double.IsNaN(yx) || double.IsNaN(yz))
				return new Godot.Collections.Dictionary { ["ok"] = false };

			float y = (float)y0;
			var normal = new Vector3(y - (float)yx, 0.4f, y - (float)yz).Normalized();
			float h1 = WgHash2(gx, gz, 233);
			float h2 = WgHash2(gx, gz, 239);
			float lum = 0.78f + 0.5f * CarpetValueNoise(x / 2.6f, z / 2.6f, 251) * (0.6f + 0.8f * h1);
			float dryPatch = Smoothstep(0.6f, 0.9f, CarpetValueNoise(x / 9.0f, z / 9.0f, 257));
			float dry = Math.Clamp(straw * (0.5f + h2 * 1.1f) + 0.3f * dryPatch * (1.0f - 0.6f * surfaceR), 0.0f, 0.85f);

			int kind = CarpetMeadow;
			if (WgHash2(gx, gz, 261) < shade)
				kind = CarpetShade;
			else if (WgHash2(gx, gz, 263) < parched * (0.15f + 0.85f * dryPatch) + dry * 0.3f)
			{
				kind = CarpetDry;
				dry = MathF.Max(dry, 0.45f);
			}

			if (forestMix > 0.0f && WgHash2(gx, gz, 295) < forestMix)
			{
				// Вид по сообществу клетки (VegetationLayer.forest_community): ложбина — мох и осока, склон — опад,
				// ребро — ягодник; шум 4,7 м только перемешивает их на границах.
				float mix = 0.75f * CarpetValueNoise(x / ExpMixNoiseM, z / ExpMixNoiseM, 297) + 0.25f * h2;
				float mossEnd = fern * ExpHollowMossShare;
				if (mix < mossEnd)
					kind = CarpetMoss;
				else if (mix < mossEnd + shrub)
					kind = CarpetLeaves;
				else if (mix < mossEnd + shrub + berry)
					kind = CarpetBerry;
				else
					kind = CarpetSedge;
			}
			float sc = 0.85f + 0.45f * h1;
			float sy = sc * tall * (0.7f + 0.6f * h2);
			var basis = new Basis(Vector3.Up, h2 * Mathf.Tau);
			var axis = Vector3.Up.Cross(normal);
			if (axis.LengthSquared() > 1e-6f)
				basis = new Basis(axis.Normalized(), Vector3.Up.AngleTo(normal)) * basis;
			y -= 0.015f;

			float r = Mathf.Lerp(tcR * 0.9f, 0.6f, dry) * lum * 1.15f;
			float g = Mathf.Lerp(tcG, 0.57f, dry) * lum * 1.15f;
			float b = Mathf.Lerp(tcB, 0.32f, dry) * lum * 1.15f;
			if (kind == CarpetShade)
			{
				r *= 0.66f;
				g *= 0.8f;
				b *= 0.74f;
			}
			else if (kind >= CarpetMoss)
			{
				float[] pal = ExpCarpetPalette[Math.Clamp(kind - CarpetMoss, 0, ExpCarpetPalette.Length - 1)];
				r = (pal[0] + pal[1] * parched) * lum;
				g = (pal[2] + pal[3] * parched) * lum;
				b = (pal[4] + pal[5] * h2) * lum;
			}
			PutCarpetRow(partsBuf[kind], filled[kind]++, basis.ScaledLocal(new Vector3(sc, sy, sc)),
				x, y, z, r, g, b, alpha, WgHash2(gx, gz, 241), 0.3f * h1);

			if (flowers && kind < 2)
			{
				float bloom = Smoothstep(0.52f, 0.78f, CarpetValueNoise(x / 5.0f, z / 5.0f, 269)) * (1.0f - 0.7f * parched);
				if (WgHash2(gx, gz, 271) < 0.16f * bloom * flowerMul)
				{
					int pick = (int)(CarpetValueNoise(x / 14.0f, z / 14.0f, 277) * 3.999f);
					if (WgHash2(gx, gz, 281) < 0.25f)
						pick = (int)(WgHash2(gx, gz, 283) * 3.999f);
					Color petal = CarpetPetals[Math.Clamp(pick, 0, 3)];
					float fs = (0.8f + 0.5f * h2) * grow;
					PutCarpetRow(partsBuf[3], filled[3]++, basis.Orthonormalized().ScaledLocal(new Vector3(fs, fs, fs)),
						x, y, z, petal.R, petal.G, petal.B, alpha, h1, 0.2f);
				}
			}

			if (y < yLow) yLow = y;
			if (y > yHigh) yHigh = y;
		}

		if (float.IsPositiveInfinity(yLow))
			return new Godot.Collections.Dictionary { ["ok"] = true, ["any"] = false };

		var parts = new Godot.Collections.Array();
		int activeKinds = expedition ? kinds : 5;
		for (int k = 0; k < activeKinds; k++)
		{
			int n = filled[k];
			if (n > 0)
			{
				var arr = new float[n * stride];
				Array.Copy(partsBuf[k], 0, arr, 0, n * stride);
				parts.Add(arr);
			}
			else
			{
				parts.Add(Array.Empty<float>());
			}
		}

		return new Godot.Collections.Dictionary
		{
			["ok"] = true,
			["any"] = true,
			["y"] = new Vector2(yLow, yHigh + 0.7f),
			["parts"] = parts,
		};
	}

	private static float TileableValueNoise(float u, float v, int period, int seed)
	{
		float fx = u * period;
		float fy = v * period;
		int ix = (int)MathF.Floor(fx);
		int iy = (int)MathF.Floor(fy);
		float tx = fx - ix;
		float ty = fy - iy;
		tx = tx * tx * (3.0f - 2.0f * tx);
		ty = ty * ty * (3.0f - 2.0f * ty);
		int ix0 = ((ix % period) + period) % period;
		int ix1 = (ix0 + 1) % period;
		int iy0 = ((iy % period) + period) % period;
		int iy1 = (iy0 + 1) % period;
		float a = WgHash2(ix0, iy0, seed) * (1.0f - tx) + WgHash2(ix1, iy0, seed) * tx;
		float b = WgHash2(ix0, iy1, seed) * (1.0f - tx) + WgHash2(ix1, iy1, seed) * tx;
		return a * (1.0f - ty) + b * ty;
	}

	/// <summary>
	/// Запекает бесшовную 2-канальную (RG8) карту кучевого шума для cloud_shadow_tex.
	/// </summary>
	public byte[] BakeCloudShadowNoise(int size)
	{
		if (size <= 0)
			return Array.Empty<byte>();
		var bytes = new byte[size * size * 2];
		float invSize = 1.0f / size;
		System.Threading.Tasks.Parallel.For(0, size, j =>
		{
			float v = (j + 0.5f) * invSize;
			int row = j * size * 2;
			for (int i = 0; i < size; i++)
			{
				float u = (i + 0.5f) * invSize;
				float wxA = (TileableValueNoise(u, v, 5, 101) - 0.5f) * (0.42f / 8.0f);
				float wyA = (TileableValueNoise(u, v, 5, 211) - 0.5f) * (0.42f / 8.0f);
				float quA = u + wxA;
				float qvA = v + wyA;
				float nA = 0.52f * TileableValueNoise(quA, qvA, 8, 307)
					+ 0.31f * TileableValueNoise(quA, qvA, 17, 409)
					+ 0.17f * TileableValueNoise(quA, qvA, 35, 521);

				float wxB = (TileableValueNoise(u, v, 5, 613) - 0.5f) * (0.42f / 8.0f);
				float wyB = (TileableValueNoise(u, v, 5, 719) - 0.5f) * (0.42f / 8.0f);
				float quB = u + wxB;
				float qvB = v + wyB;
				float nB = 0.52f * TileableValueNoise(quB, qvB, 8, 827)
					+ 0.31f * TileableValueNoise(quB, qvB, 17, 937)
					+ 0.17f * TileableValueNoise(quB, qvB, 35, 1049);

				int at = row + i * 2;
				bytes[at] = (byte)Math.Clamp((int)MathF.Round(nA * 255.0f), 0, 255);
				bytes[at + 1] = (byte)Math.Clamp((int)MathF.Round(nB * 255.0f), 0, 255);
			}
		});
		return bytes;
	}
}
