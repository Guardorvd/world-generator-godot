using System;
using System.Collections.Generic;

public partial class FastGrid
{
	/// <summary>Exact Grid.bridge_region traversal, including first-region tie breaking.</summary>
	public byte[] BridgeRegion(int w, int h, byte[] wet, int maxSpan)
	{
		int n = checked(w * h);
		var result = new byte[n];
		if (n == 0) return result;
		var distance = new int[n];
		int reach = Math.Max(0, maxSpan / 2);
		for (int i = 0; i < n; i++) distance[i] = wet[i] != 0 ? reach + 1 : 0;
		for (int y = 0; y < h; y++)
			for (int x = 0; x < w; x++)
			{
				int i = y * w + x;
				if (x > 0) distance[i] = Math.Min(distance[i], distance[i - 1] + 1);
				if (y > 0)
				{
					distance[i] = Math.Min(distance[i], distance[i - w] + 1);
					if (x > 0) distance[i] = Math.Min(distance[i], distance[i - w - 1] + 1);
					if (x + 1 < w) distance[i] = Math.Min(distance[i], distance[i - w + 1] + 1);
				}
			}
		for (int y = h - 1; y >= 0; y--)
			for (int x = w - 1; x >= 0; x--)
			{
				int i = y * w + x;
				if (x + 1 < w) distance[i] = Math.Min(distance[i], distance[i + 1] + 1);
				if (y + 1 < h)
				{
					distance[i] = Math.Min(distance[i], distance[i + w] + 1);
					if (x > 0) distance[i] = Math.Min(distance[i], distance[i + w - 1] + 1);
					if (x + 1 < w) distance[i] = Math.Min(distance[i], distance[i + w + 1] + 1);
				}
			}
		var regions = new int[n];
		var queue = new int[n];
		int region = 0, largest = 0, largestLand = 0;
		for (int start = 0; start < n; start++)
		{
			if (regions[start] != 0 || distance[start] > reach) continue;
			regions[start] = ++region;
			queue[0] = start;
			int head = 0, tail = 1, land = 0;
			while (head < tail)
			{
				int c = queue[head++];
				if (wet[c] == 0) land++;
				int x = c % w, y = c / w;
				for (int ny = Math.Max(0, y - 1); ny < Math.Min(h, y + 2); ny++)
					for (int nx = Math.Max(0, x - 1); nx < Math.Min(w, x + 2); nx++)
					{
						int next = ny * w + nx;
						if (regions[next] != 0 || distance[next] > reach) continue;
						regions[next] = region;
						queue[tail++] = next;
					}
			}
			if (land > largestLand) { largestLand = land; largest = region; }
		}
		if (largest != 0)
			for (int i = 0; i < n; i++) result[i] = regions[i] == largest ? (byte)1 : (byte)0;
		return result;
	}

	/// <summary>Local maxima in row order. Keep plateau ties and double threshold comparison.</summary>
	public int[] PeakCandidates(int w, int h, float[] elev, byte[] ocean, byte[] lake)
	{
		var cells = new List<int>();
		for (int y = 4; y < h - 4; y++)
			for (int x = 4; x < w - 4; x++)
			{
				int i = y * w + x;
				if ((double)elev[i] < 0.45 || ocean[i] != 0 || lake[i] != 0) continue;
				bool isMax = true;
				for (int dy = -3; dy <= 3 && isMax; dy++)
					for (int dx = -3; dx <= 3; dx++)
						if (elev[(y + dy) * w + x + dx] > elev[i]) { isMax = false; break; }
				if (isMax) cells.Add(i);
			}
		return cells.ToArray();
	}
}
