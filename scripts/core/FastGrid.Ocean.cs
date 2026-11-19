using System;

// Native copy of StageOcean.run: ocean mask and dry closed pockets below sea level. Keep float32 parity.
public partial class FastGrid
{
	/// <summary>
	/// Океан по высотам (h &lt; 0) и сухие ложбины: связные части «моря» (4 соседа), не касающиеся края плана
	/// и меньше pocketDry клеток, становятся сушей с дном rim * (1 - 0.5 * smoothstep(0, 0.1, -h)).
	/// Копия StageOcean.run; pocketDry 0 — без ложбин. Возвращает {ocean: byte[], h: float[], dried: int}.
	/// </summary>
	public Godot.Collections.Dictionary OceanPockets(float[] h, int width, int height, int pocketDry, double rim)
	{
		int n = width * height;
		var ocean = new byte[n];
		for (int i = 0; i < n; i++)
			ocean[i] = (byte)(h[i] < 0.0f ? 1 : 0);
		int dried = 0;
		if (pocketDry > 0)
		{
			// Одна очередь на все части: клетки части — queue[0..tail), она же список для осушения.
			var queue = new int[n];
			var seen = new bool[n];
			for (int s = 0; s < n; s++)
			{
				if (ocean[s] == 0 || seen[s]) continue;
				int head = 0, tail = 0;
				queue[tail++] = s;
				seen[s] = true;
				bool edge = false;
				while (head < tail)
				{
					int c = queue[head++];
					int x = c % width;
					int y = c / width;
					if (x == 0 || y == 0 || x == width - 1 || y == height - 1)
						edge = true;
					if (x > 0 && ocean[c - 1] != 0 && !seen[c - 1]) { seen[c - 1] = true; queue[tail++] = c - 1; }
					if (x < width - 1 && ocean[c + 1] != 0 && !seen[c + 1]) { seen[c + 1] = true; queue[tail++] = c + 1; }
					if (y > 0 && ocean[c - width] != 0 && !seen[c - width]) { seen[c - width] = true; queue[tail++] = c - width; }
					if (y < height - 1 && ocean[c + width] != 0 && !seen[c + width]) { seen[c + width] = true; queue[tail++] = c + width; }
				}
				if (edge || tail >= pocketDry) continue;
				for (int k = 0; k < tail; k++)
				{
					int c = queue[k];
					ocean[c] = 0;
					h[c] = (float)(rim * (1.0 - 0.5 * ReliefSmooth(0.0, 0.1, -(double)h[c])));
				}
				dried += tail;
			}
		}
		return new Godot.Collections.Dictionary { ["ocean"] = ocean, ["h"] = h, ["dried"] = dried };
	}
}
