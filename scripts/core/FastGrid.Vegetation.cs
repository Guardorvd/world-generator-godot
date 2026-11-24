using System;
using System.Collections.Generic;
using Godot;

// Native copy of StageVegetation.place_chunk, RockScatter.place_chunk and StageVegetation.ObjStore for the start plan
// (stride W, corner 0, 0). Result must be bit-identical to GDScript: tools/dod_verify.gd -- --only vegetation.
// Float32 spots of GDScript (Vector2, PackedFloat32Array) are repeated with float. Trigonometry is NOT computed here:
// .NET cos/sin/atan2 differ from the engine's in the last bit (~3 % of values), so angles go through the engine
// callback `trig(a, b, mode)`: 0 — cos(a), 1 — sin(a), 2 — atan2(a, b).
public partial class FastGrid
{
	// Biomes (scripts/data/biomes.gd)
	private const int BBeach = 4, BDesert = 5, BSavanna = 6, BSteppe = 7, BGrass = 8, BForest = 9, BJungle = 10,
		BSwamp = 11, BTaiga = 12, BTundra = 13, BSnow = 14, BRock = 15, BPeak = 16;
	private const int TOak = 0, TPine = 1, TPalm = 2, TBush = 4, TRock = 6, TSnowpine = 7, TBirch = 8, TReed = 10,
		TRowan = 12, TMugo = 13, TSpruce = 14, TLarch = 15, TAlder = 16, TWesternRedcedar = 17, TSiberianCedar = 18, TMaple = 19,
		THemlock = 20, TDouglasFir = 21;
	// ForestModels ages
	private const int AdultAge = 0, YoungAge = 1, OldAge = 2;
	// StageVegetation
	private const double VegVillageR = 7.0, VegHighLo = 0.12, VegHighHi = 0.26, VegLineLo = 0.28, VegLineHi = 0.50,
		VegSteep = 0.6, VegShore = 3.0, VegSpread = 0.55, VegLowCrown = 0.3, VegGapK = 0.75;
	private const int VegLayer = 1;
	private const double HutSearchRadius = 2.0;
	// RockScatter
	private const int PatchCells = 8;
	private const double MaxChance = 0.48, ConvexityGain = 0.45, MaxConvexityFactor = 1.0 + ConvexityGain,
		OutcropChance = 0.12, HillOutcropChance = 0.065, HillOutcropSlope = 0.28, OutcropClear = 2.2;
	private const double LowHillChance = 0.052, LowHillMin = 0.018, LowHillMax = 0.085, LowHillSlope = 0.16;
	private const int LowHillReach = 4;
	private static readonly int[] TalusReach = { 2, 4, 6 };
	private const int OutcropV = 3, MassifV = 6; // RockModels.OUTCROP_V, MASSIF_V
	private const int MassifStride = 10;          // RockMassif.STRIDE
	private const double TalusRange = 6.5;        // RockMassif.TALUS_RANGE
	private const double Tau = 6.283185307179586; // Math_TAU

	/// <summary>Числа поля и таблицы раскладки одного плана (только чтение из потоков).</summary>
	private sealed class VegInput
	{
		public long Seed;
		public bool Expedition;
		public int W, H, CS, CW, CH;
		public byte[] Biome, River, Village, Rock, PathMask;
		public double[] Forest, Stony, AgeN, Wood, Stand, Glade;
		public float[] Elev, Slope, Dw, Temp, Moist, DistPath, Light;
		public byte[] BWater, BTree;
		public double[] BTrees, Crown, Trunk; // Trunk: NaN — вида нет в StageVegetation.TRUNK
		public int[] KindsStart, Kinds;
		public double CoverBias, Tile, Hs;
		public int[] MassifStart; public float[] Massifs; public byte[] MassifTor; // по чанкам
		public int[] CoreStart; public float[] Cores;                             // по чанкам, x, y, r
		public double[] Huts;
		public Callable Trig;
	}

	/// <summary>
	/// Растительность всего плана (StageVegetation.run после полей): объекты по рядам чанков, как Parallel.bands(CH, job, 1)
	/// со склейкой по порядку рядов. Возвращает {x, y: double[], k, v: int[], s: double[], start: int[CW*CH+1], items: int[]}:
	/// номера объектов чанка c — items[start[c]..start[c+1]) (уже по y, затем по номеру).
	/// </summary>
	public Godot.Collections.Dictionary VegetationPlan(long seed, int width, int height, int chunkSide, int chunkCols, int chunkRows,
		byte[] biome, double[] forest, double[] stony, float[] elev, float[] slope, float[] dw, float[] temp, float[] moist,
		byte[] river, float[] distPath, byte[] village, float[] light, double[] ageN, double[] wood, double[] stand, double[] glade,
		byte[] rock, byte[] pathMask, byte[] bWater, double[] bTrees, int[] kindsStart, int[] kinds, byte[] bTree, double[] crown,
		double[] trunk, double coverBias, double tile, double hs, int[] massifStart, float[] massifs, byte[] massifTor,
		int[] coreStart, float[] cores, double[] huts, Callable trig, bool expedition)
	{
		var input = new VegInput
		{
			Seed = seed, W = width, H = height, CS = chunkSide, CW = chunkCols, CH = chunkRows,
			Biome = biome, Forest = forest, Stony = stony, Elev = elev, Slope = slope, Dw = dw, Temp = temp, Moist = moist,
			River = river, DistPath = distPath, Village = village, Light = light, AgeN = ageN, Wood = wood, Stand = stand,
			Glade = glade, Rock = rock, PathMask = pathMask, BWater = bWater, BTrees = bTrees, KindsStart = kindsStart,
			Kinds = kinds, BTree = bTree, Crown = crown, Trunk = trunk, CoverBias = coverBias, Tile = tile, Hs = hs,
			MassifStart = massifStart, Massifs = massifs, MassifTor = massifTor, CoreStart = coreStart, Cores = cores,
			Huts = huts, Trig = trig, Expedition = expedition,
		};
		var rows = new VegStore[chunkRows];
		System.Threading.Tasks.Parallel.For(0, chunkRows, cy =>
		{
			var st = new VegStore(input, cy * chunkCols, chunkCols);
			for (int cx = 0; cx < chunkCols; cx++)
			{
				int x0 = cx * chunkSide, y0 = cy * chunkSide;
				PlaceVegChunk(input, st, cy * chunkCols + cx, x0, y0, Math.Min(width, x0 + chunkSide), Math.Min(height, y0 + chunkSide));
			}
			// Объекты в чанке — с севера на юг (при равных y — в порядке добавления)
			var oy = st.Y;
			foreach (var list in st.ChunkLists)
				list.Sort((a, b) => oy[a] != oy[b] ? (oy[a] < oy[b] ? -1 : 1) : a.CompareTo(b));
			rows[cy] = st;
		});
		int total = 0;
		foreach (var st in rows) total += st.X.Count;
		var ox = new double[total];
		var oyAll = new double[total];
		var ok = new int[total];
		var ov = new int[total];
		var os = new double[total];
		var start = new int[chunkCols * chunkRows + 1];
		var items = new int[total];
		int baseIndex = 0, at = 0;
		for (int cy = 0; cy < chunkRows; cy++)
		{
			var st = rows[cy];
			for (int c = 0; c < chunkCols; c++)
			{
				start[cy * chunkCols + c] = at;
				foreach (int o in st.ChunkLists[c]) items[at++] = o + baseIndex;
			}
			st.X.CopyTo(ox, baseIndex);
			st.Y.CopyTo(oyAll, baseIndex);
			st.K.CopyTo(ok, baseIndex);
			st.V.CopyTo(ov, baseIndex);
			st.S.CopyTo(os, baseIndex);
			baseIndex += st.X.Count;
		}
		start[chunkCols * chunkRows] = at;
		return new Godot.Collections.Dictionary
		{
			["x"] = ox, ["y"] = oyAll, ["k"] = ok, ["v"] = ov, ["s"] = os, ["start"] = start, ["items"] = items,
		};
	}

	/// <summary>Копия StageVegetation.ObjStore для одной полосы чанков (с миром: дома, отступы внутри чанка).</summary>
	private sealed class VegStore
	{
		public readonly List<double> X = new(), Y = new(), S = new();
		public readonly List<int> K = new(), V = new();
		public readonly List<int>[] ChunkLists;
		private readonly VegInput _in;
		private readonly int _firstChunk;
		private readonly List<int> _chunkHuts = new();
		private int[] _heads = Array.Empty<int>();
		private readonly List<int> _next = new();
		private readonly List<double> _radii = new();
		private double _maxRadius;
		private int _chunkBase, _x0, _y0, _x1, _y1;
		private List<int> _list;

		public VegStore(VegInput input, int firstChunk, int count)
		{
			_in = input;
			_firstChunk = firstChunk;
			ChunkLists = new List<int>[count];
		}

		public void BeginChunk(int x0, int y0, int x1, int y1)
		{
			_x0 = x0; _y0 = y0; _x1 = x1; _y1 = y1;
			int n = (x1 - x0) * (y1 - y0);
			if (_heads.Length != n) _heads = new int[n];
			Array.Fill(_heads, -1);
			_next.Clear();
			_radii.Clear();
			_maxRadius = 0.0;
			_chunkBase = X.Count;
			int c = (int)Math.Floor((double)y0 / _in.CS) * _in.CW + (int)Math.Floor((double)x0 / _in.CS) - _firstChunk;
			_list = new List<int>();
			ChunkLists[c] = _list;
			_chunkHuts.Clear();
			const double Reach = HutSearchRadius + 0.75;
			var huts = _in.Huts;
			for (int h = 0; h < huts.Length; h += 4)
			{
				double hx = huts[h + 2], hy = huts[h + 3];
				if (hx >= x0 - Reach && hx <= x1 + Reach && hy >= y0 - Reach && hy <= y1 + Reach)
					_chunkHuts.Add(h);
			}
		}

		private bool NearHut(int n, double ox, double oy, double radius)
		{
			var huts = _in.Huts;
			return Math.Abs(huts[n + 2] - ox) < 0.75 + radius && Math.Abs(huts[n + 3] - oy) < 0.75 + radius
				&& Math.Abs(huts[n] - ox) <= VegVillageR + radius && Math.Abs(huts[n + 1] - oy) <= VegVillageR + radius;
		}

		public void Add(double ox, double oy, int kind, int variant, double sc)
		{
			bool massif = kind == TRock && variant >= MassifV;
			double radius = _in.Crown[kind] * sc;
			int cx = (int)Math.Floor(ox);
			int cy = (int)Math.Floor(oy);
			if (radius <= HutSearchRadius)
			{
				foreach (int n in _chunkHuts)
					if (NearHut(n, ox, oy, radius)) return;
			}
			else
			{
				for (int n = 0; n < _in.Huts.Length; n += 4)
					if (NearHut(n, ox, oy, radius)) return;
			}
			int cw = _x1 - _x0;
			if (!massif && _radii.Count > 0)
			{
				bool isRock = kind == TRock;
				double maxGap = 0.18 + (isRock ? 0.55 : VegGapK) * (radius + _maxRadius);
				int reach = Math.Min(3, (int)Math.Floor(maxGap + 0.000001) + 1);
				int left = Math.Max(_x0, cx - reach);
				int right = Math.Min(_x1, cx + reach + 1);
				int top = Math.Max(_y0, cy - reach), bottom = Math.Min(_y1, cy + reach + 1);
				for (int yy = top; yy < bottom; yy++)
				{
					int row = (yy - _y0) * cw - _x0;
					for (int xx = left; xx < right; xx++)
					{
						int local = _heads[row + xx];
						while (local != -1)
						{
							int o = _chunkBase + local;
							double gap = 0.18 + (isRock || K[o] == TRock ? 0.55 : VegGapK) * (radius + _radii[local]);
							// Vector2(ox - x[o], oy - y[o]).length_squared(): float32, как в движке
							float dx = (float)(ox - X[o]);
							float dy = (float)(oy - Y[o]);
							float l2 = dx * dx + dy * dy;
							if (l2 < gap * gap) return;
							local = _next[local];
						}
					}
				}
			}
			int cell = (cy - _y0) * cw + cx - _x0;
			_next.Add(_heads[cell]);
			_heads[cell] = _radii.Count;
			_radii.Add(radius);
			_maxRadius = Math.Max(_maxRadius, radius);
			_list.Add(X.Count);
			X.Add(ox);
			Y.Add(oy);
			K.Add(kind);
			V.Add(variant);
			S.Add(sc);
		}
	}

	// --- WGRandom (mulberry32), 32-битная арифметика как в wg_random.gd ---
	private struct VegRng
	{
		private uint _a;
		public void Reset(long seed) => _a = (uint)(seed & 0xFFFFFFFFL);
		public double Next()
		{
			unchecked
			{
				_a += 0x6d2b79f5u;
				uint a = _a;
				uint t = (a ^ (a >> 15)) * (1u | a);
				t = (t + ((t ^ (t >> 7)) * (61u | t))) ^ t;
				return (t ^ (t >> 14)) / 4294967296.0;
			}
		}
	}

	private static long VegHashCell(long seed, long x, long y, long layer)
	{
		long h = ((x * 73856093L + y * 19349663L + layer * 83492791L) ^ seed) & 0xFFFFFFFFL;
		h = (((h >> 16) ^ h) * 0x45d9f3bL) & 0xFFFFFFFFL;
		h = (((h >> 16) ^ h) * 0x45d9f3bL) & 0xFFFFFFFFL;
		return (h >> 16) ^ h;
	}

	private static double VegHash2(long x, long y, long seed)
	{
		unchecked
		{
			uint h = ((uint)x * 374761393u + (uint)y * 668265263u) ^ (uint)(seed & 0xFFFFFFFFL);
			h = (h ^ (h >> 13)) * 1274126177u;
			return (h ^ (h >> 16)) / 4294967296.0;
		}
	}

	// --- функции движка и StageVegetation ---
	private static double VegSs(double a, double b, double x)
	{
		double t = Clamp01((x - a) / (b - a));
		return t * t * (3.0 - 2.0 * t);
	}

	private const int VegMeadowReach = 12;
	private const double VegMeadowBackground = 0.20;

	private static double VegMeadowCover(double cover, double standNoise, double moist, double position)
	{
		double shelter = VegClamp(-position / 3.5, -1.0, 1.0);
		double grove = VegSs(0.04, 0.48, standNoise + 0.23 * shelter);
		double edge = VegSs(0.2, 0.55, cover + 0.08 * shelter);
		return VegSs(0.29, 0.44, moist) * (0.57 * grove + edge * (0.09 + 0.34 * grove));
	}

	private static double VegLerp(double a, double b, double t) => a + (b - a) * t;
	private static double VegClamp(double v, double lo, double hi) => v < lo ? lo : (v > hi ? hi : v);
	private static double VegMax(double a, double b) => a > b ? a : b;
	private static double VegMin(double a, double b) => a < b ? a : b;

	private static double VegPosMod(double x, double y)
	{
		double v = x % y;
		if ((v < 0 && y > 0) || (v > 0 && y < 0)) v += y;
		return v + 0.0;
	}

	private static int VegRound(double v) => (int)Math.Round(v, MidpointRounding.AwayFromZero);

	private static bool VegCovers(float[] cores, int from, int to, double px, double py, double pad)
	{
		for (int c = from; c < to; c += 3)
		{
			double cxv = cores[c], cyv = cores[c + 1];
			double r = cores[c + 2] + pad;
			if ((px - cxv) * (px - cxv) + (py - cyv) * (py - cyv) < r * r) return true;
		}
		return false;
	}

	/// <summary>Grid.clearance_at</summary>
	private static double VegClearanceAt(float[] field, int stride, double x, double y, double tile)
	{
		int rows = field.Length / stride;
		int i0 = Math.Clamp((int)Math.Floor(x - 0.5), 0, stride - 2);
		int j0 = Math.Clamp((int)Math.Floor(y - 0.5), 0, rows - 2);
		double best = double.NegativeInfinity;
		for (int j = j0; j < j0 + 2; j++)
			for (int i = i0; i < i0 + 2; i++)
			{
				double dx = x - (i + 0.5);
				double dy = y - (j + 0.5);
				best = VegMax(best, field[j * stride + i] - Math.Sqrt(dx * dx + dy * dy) * tile);
			}
		return best;
	}

	private static bool HasAges(int kind) => kind is TPine or TBirch or TOak or TRowan or TSpruce or TLarch or TAlder or TWesternRedcedar or TSiberianCedar or TMaple or THemlock or TDouglasFir;

	/// <summary>StageVegetation.clear_of_path</summary>
	private static bool VegClearOfPath(VegInput f, double x, double y, int kind, double sc, int age)
	{
		double trunk = f.Trunk[kind];
		bool hasTrunk = !double.IsNaN(trunk);
		if (kind == TWesternRedcedar)
			trunk *= age == OldAge ? 1.58 : (age == YoungAge ? 0.90 : 1.22);
		else if (kind == TDouglasFir)
			trunk *= age == OldAge ? 1.42 : (age == YoungAge ? 0.77 : 1.0);
		double need = (hasTrunk ? trunk : 0.0) * sc;
		if (kind == TSnowpine || kind == TMugo || kind == TAlder || (age == YoungAge && HasAges(kind)))
		{
			double lowShare = kind switch
			{
				TSpruce or THemlock => 0.82,
				TMaple or TDouglasFir => 0.55,
				_ => VegLowCrown,
			};
			need += lowShare * f.Crown[kind] * sc * f.Tile;
		}
		else if (!hasTrunk)
			need = 0.5 * f.Crown[kind] * sc * f.Tile;
		return VegClearanceAt(f.DistPath, f.W, x, y, f.Tile) >= need;
	}

	/// <summary>RockScatter.clear_path</summary>
	private static bool VegClearPath(VegInput f, byte[] mask, double x, double y, double scale)
	{
		double radius = f.Crown[TRock] * scale + 0.25;
		int stride = f.W;
		int rows = mask.Length / stride;
		int top = Math.Max(0, (int)Math.Floor(y - radius)), bottom = Math.Min(rows, (int)Math.Floor(y + radius) + 1);
		int left = Math.Max(0, (int)Math.Floor(x - radius)), right = Math.Min(stride, (int)Math.Floor(x + radius) + 1);
		for (int yy = top; yy < bottom; yy++)
			for (int xx = left; xx < right; xx++)
			{
				if (mask[yy * stride + xx] == 0) continue;
				double dx = VegMax(VegMax(xx - x, x - xx - 1.0), 0.0);
				double dy = VegMax(VegMax(yy - y, y - yy - 1.0), 0.0);
				if (dx * dx + dy * dy < radius * radius) return false;
			}
		return true;
	}

	/// <summary>RockScatter.local_convexity</summary>
	private static double VegConvexity(VegInput f, int i, int radius = 2)
	{
		int stride = f.W;
		var elev = f.Elev;
		int x = i % stride;
		int d = radius * stride;
		if (x < radius || x + radius >= stride || i < d || i + d >= elev.Length) return 0.0;
		return (elev[i] - ((double)elev[i - radius] + elev[i + radius] + elev[i - d] + elev[i + d]) * 0.25) * f.Hs;
	}

	private static bool VegDryOpen(int bi) => bi == BDesert || bi == BSavanna || bi == BSteppe || bi == BTundra || bi == BGrass;
	private static bool VegReedy(int bi) => bi == BGrass || bi == BForest || bi == BSwamp || bi == BTaiga || bi == BSteppe || bi == BSavanna;

	/// <summary>StageVegetation.tree_form: (размер как float32 из Vector2, возрастной класс)</summary>
	private static (float Size, int Cls) VegTreeForm(double age, double interior, double line, double moist, double exposed, double r, int kind)
	{
		double r2 = VegPosMod(r * 9.73, 1.0);
		double r3 = VegPosMod(r * 31.7 + 0.37, 1.0);
		double youngStand = 1.0 - VegSs(0.08, 0.24, age);
		double pOld = (1.0 - youngStand) * 0.032 * VegSs(0.4, 0.85, age);
		if (kind == TMaple) pOld += 0.18 * VegSs(0.24, 0.66, age);
		else if (kind == TDouglasFir) pOld += 0.10 * VegSs(0.30, 0.72, age);
		double pYoung = youngStand * 0.9 + (1.0 - youngStand) * (0.095 + 0.15 * (1.0 - interior));
		double pSecond = (1.0 - youngStand) * 0.14;
		double canopy = VegLerp(0.86, 1.06, age) * (0.82 + 0.18 * interior) * (0.85 + 0.15 * moist);
		double size;
		int cls = AdultAge;
		if (r < pOld)
		{
			cls = OldAge;
			size = 1.25 + 0.25 * r2;
		}
		else if (r < pOld + pYoung)
		{
			cls = YoungAge;
			size = 0.2 + 0.22 * r2;
			if (kind is (THemlock or TSpruce) && r3 < 0.58)
				size = 0.048 + 0.10 * r2;
		}
		else if (r < pOld + pYoung + pSecond)
			size = canopy * (0.6 + 0.15 * r2);
		else
			size = canopy * (0.88 + 0.24 * r2);
		double harsh = VegSs(0.25, 0.8, VegMax(line, exposed));
		if (harsh > 0.0)
		{
			size = VegLerp(size, 0.5, harsh);
			if (r3 < harsh * 1.3) cls = YoungAge;
		}
		return ((float)size, cls);
	}

	/// <summary>StageVegetation._kind</summary>
	// StageVegetation.expedition_kind. Shares one roll across the eligible species.
	private static int VegExpeditionKind(int kind, int bi, double roll, double elev, double moist, double water, double light, double stand,
		double slope, double exposed)
	{
		if (bi is not (BForest or BTaiga or BGrass or BSwamp) || kind is TRock or TMugo or TReed)
			return kind;
		double alder = (1.0 - VegSs(1.0, 7.0, water)) * VegSs(0.30, 0.67, moist) * (0.38 + 0.43 * stand);
		if (roll < alder) return TAlder;
		if (kind is not (TPine or TBirch or TOak)) return kind;
		roll -= alder;
		double wet = VegSs(0.39, 0.76, moist);
		double cool = VegSs(0.055, 0.22, elev);
		double cedar = 0.22 * wet * wet * (1.0 - 0.65 * cool) * (0.55 + 0.45 * stand);
		if (roll < cedar) return TWesternRedcedar;
		roll -= cedar;
		double spruce = (0.07 + 0.53 * wet) * (0.73 + 0.27 * stand) * (1.13 - 0.55 * light);
		if (roll < spruce)
		{
			if (bi is BForest or BTaiga)
			{
				double terrace = VegSs(1.5, 4.0, water) * VegLerp(1.0, 0.55, VegSs(8.0, 28.0, water));
				double lowland = 1.0 - VegSs(0.085, 0.19, elev);
				double shelter = (1.0 - VegSs(0.38, 0.82, slope)) * (1.0 - VegSs(0.13, 0.50, exposed));
				double patch = VegSs(0.28, 0.66, stand) * (0.65 + 0.35 * light);
				double maple = 0.37 * terrace * lowland * shelter * patch * VegSs(0.50, 0.79, moist);
				if (roll < spruce * maple) return TMaple;
				double coastal = VegSs(0.40, 0.73, moist) * (1.0 - 0.72 * cool);
				double hemlock = coastal * (0.14 + 0.22 * stand) * (1.0 - 0.30 * light);
				double douglas = coastal * VegSs(0.20, 0.70, light) * (0.13 + 0.12 * shelter);
				if (roll < spruce * (maple + hemlock)) return THemlock;
				if (roll < spruce * (maple + hemlock + douglas)) return TDouglasFir;
			}
			return TSpruce;
		}
		roll -= spruce;
		double larch = (0.08 + 0.48 * cool) * (0.5 + 0.5 * light) * (1.0 - 0.68 * wet) * (1.32 - 0.65 * stand);
		if (roll < larch) return TLarch;
		roll -= larch;
		double siberian = (0.07 + 0.42 * cool) * (0.65 + 0.35 * wet) * (0.48 + 0.52 * stand);
		return roll < siberian ? TSiberianCedar : kind;
	}

	private static int VegKind(VegInput f, int bi, double r, double e, double m, double sl, double dw, double t, double light,
		double interior, double stand, double exposed)
	{
		bool shore = dw < VegShore;
		double rSub = VegPosMod(r * 17.37, 1.0);
		double rRowan = VegPosMod(r * 23.17, 1.0);
		if ((bi == BTaiga || bi == BForest || bi == BGrass || bi == BTundra) && sl < 0.72 && (e > 0.20 || (e > 0.14 && (sl > 0.25 || exposed > 0.22))))
		{
			double mugoShare = VegMin(0.10, (VegSs(0.20, 0.34, e) * 0.55 + VegSs(0.14, 0.26, e) * VegMax(VegSs(0.22, 0.52, sl), exposed) * 0.45) * 0.14);
			if (mugoShare > 0.011 && rSub < mugoShare) return TMugo;
		}
		if ((bi == BForest || bi == BGrass || bi == BTaiga) && m < 0.58 && r < 0.28 * VegSs(0.24, 0.45, e))
			return TBush;
		if (sl > 1.0 && r < 0.4)
			return r < 0.2 ? TRock : TBush;
		switch (bi)
		{
			case BForest:
			case BGrass:
			{
				if (bi == BGrass && m < 0.35)
					return r < 0.75 ? TBush : TPine;
				double rowanChance = (0.045 + 0.065 * (1.0 - interior) + 0.04 * VegSs(0.12, 0.28, e)) * VegSs(0.22, 0.55, m);
				if (rRowan > 1.0 - rowanChance) return TRowan;
				double high = VegSs(VegHighLo, VegHighHi, e);
				double pine = 0.1 + 0.5 * high + 0.25 * (1.0 - m) + 0.1 * light;
				double birch = 0.12 + 0.18 * m + 0.12 * (1.0 - interior);
				double lowland = 1.0 - high;
				double pineStand = (1.0 - VegSs(0.18, 0.48, stand)) * lowland;
				double birchStand = VegSs(0.35, 0.62, stand) * (1.0 - VegSs(0.68, 0.94, stand)) * lowland * VegSs(0.25, 0.6, m);
				double oakStand = VegSs(0.68, 0.94, stand) * lowland;
				pine = VegLerp(VegLerp(pine, 0.69, pineStand), 0.17, VegMax(birchStand, oakStand));
				birch = VegLerp(VegLerp(birch, 0.17, VegMax(pineStand, oakStand)), 0.65, birchStand);
				if (r < pine) return TPine;
				if (r < pine + birch) return TBirch;
				return r < 0.94 || interior > 0.75 ? TOak : TBush;
			}
			case BTaiga:
			{
				double rowanChance = (0.025 + 0.055 * (1.0 - interior) + 0.03 * VegSs(0.10, 0.26, e)) * VegSs(0.25, 0.55, m);
				if (e < 0.32 && rRowan > 1.0 - rowanChance) return TRowan;
				double high = VegSs(VegHighLo, VegHighHi, e);
				double birch = VegLerp(0.30 + 0.18 * m, 0.06 + 0.07 * m, high);
				birch += (VegSs(0.26, 0.8, stand) - 0.5) * 0.42 * (1.0 - high) * VegSs(0.25, 0.55, m);
				return r < birch ? TBirch : TPine;
			}
			case BDesert:
				if (shore) return t > 0.65 && r < 0.7 ? TPalm : TBush;
				break;
			case BSavanna:
				if (shore && t > 0.65 && r < 0.4) return TPalm;
				break;
			case BSteppe:
			case BTundra:
				if (shore && t > 0.24) return r < 0.45 ? TBirch : TBush;
				break;
			case BRock:
				if (e >= 0.16 && e < 0.44 && sl < 0.72 && r < 0.48)
					return e >= 0.22 || rSub < 0.65 ? TMugo : TPine;
				return e < 0.3 && r < 0.5 ? TPine : TRock;
			case BJungle:
				if (e > VegHighHi && r < 0.5) return TPine;
				break;
		}
		int from = f.KindsStart[bi], count = f.KindsStart[bi + 1] - from;
		return f.Kinds[from + (int)Math.Floor(r * count)];
	}

	/// <summary>StageVegetation.place_chunk + RockScatter.place_chunk для чанка c плана</summary>
	private static void PlaceVegChunk(VegInput f, VegStore store, int c, int x0, int y0, int x1, int y1)
	{
		int W = f.W;
		var biome = f.Biome;
		var rng = new VegRng();
		long seed = f.Seed;
		store.BeginChunk(x0, y0, x1, y1);
		int coreFrom = f.CoreStart[c], coreTo = f.CoreStart[c + 1];
		bool hasCores = coreTo > coreFrom;
		for (int y = y0; y < y1; y++)
		{
			for (int x = x0; x < x1; x++)
			{
				int i = y * W + x;
				int bi = biome[i];
				if (f.BWater[bi] != 0 || f.River[i] != 0) continue;
				if (f.DistPath[i] < -3.0) continue;
				double dens = f.BTrees[bi];
				double fv = f.Forest[i];
				double e = f.Elev[i];
				double sl = f.Slope[i];
				double exposed = f.Rock[i] / 255.0;
				double dw = f.Dw[i];
				double light = f.Light[i];
				double ageRaw = f.AgeN[i];
				double age = VegSs(-0.45, 0.45, ageRaw);
				double interior = 0.0;
				double wv = f.Wood[i];
				double cover = wv * 1.15 + f.CoverBias + fv * 0.4;
				double stand = 0.5;
				double moistI = f.Moist[i];
				if (dens > 0.3)
				{
					double t = Clamp01((cover + 0.3) / (0.12 + 0.3));
					interior = t * t * (3.0 - 2.0 * t);
					double sv = f.Stand[i];
					double gv = f.Glade[i];
					stand = VegSs(-0.4, 0.4, sv);
					double glade = VegSs(0.3, 0.45, gv) * interior;
					dens *= interior * VegSs(-0.45, -0.12, f.Stony[i]) * VegLerp(1.35, 0.75, age) * VegLerp(0.55, 1.3, stand) * (1.0 - 0.92 * glade);
					interior *= 1.0 - 0.6 * glade;
				}
				else
				{
					double t = Clamp01((fv - 0.1) / (0.5 - 0.1));
					dens *= 0.3 + 1.8 * (t * t * (3.0 - 2.0 * t));
					if (bi == BGrass)
					{
						double sv = f.Stand[i];
						int reach = Math.Min(VegMeadowReach, Math.Min(Math.Min(x, W - 1 - x), Math.Min(y, f.H - 1 - y)));
						double position = VegConvexity(f, i, reach);
						interior = VegMeadowCover(cover, sv, moistI, position);
						dens = VegMax(dens * VegMeadowBackground, VegSpread * interior);
						stand = VegSs(-0.4, 0.4, sv);
					}
					if (dw < VegShore && VegDryOpen(bi) && f.Temp[i] > 0.24)
						dens += 0.22 * (1.0 - dw / VegShore);
				}
				if (bi == BForest || bi == BTaiga || bi == BJungle || bi == BGrass)
					dens *= (0.55 + 0.65 * VegSs(0.2, 0.75, moistI)) * (1.08 - 0.16 * light);
				if (bi == BBeach && f.Temp[i] < 0.6)
					dens = 0.0;
				double line = e <= VegLineLo ? 0.0 : VegSs(VegLineLo + 0.05 * moistI, VegLineHi + 0.10 * moistI - 0.04 * light, e);
				dens *= 1.0 - 0.72 * exposed;
				if (line > 0.0 && bi != BSnow && bi != BRock && bi != BPeak)
					dens *= 1.0 - 0.65 * line;
				if (sl > VegSteep)
					dens /= 1.0 + (sl - VegSteep) * 1.5;
				double mugoFrom = double.PositiveInfinity;
				if (e > 0.18 && e < 0.46 && (bi == BTaiga || bi == BForest || bi == BRock || bi == BTundra))
				{
					double mugoBelt = VegSs(0.18, 0.28, e) * (1.0 - VegSs(0.38, 0.46, e)) * (1.0 - VegSs(0.58, 0.78, sl)) * VegSs(-0.25, 0.25, fv);
					if (mugoBelt > 0.0 && mugoBelt * 0.42 > dens)
					{
						mugoFrom = dens * 0.6;
						dens = mugoBelt * 0.42;
					}
				}
				if (f.Village[i] != 0)
				{
					dens *= 0.08;
					mugoFrom *= 0.08;
				}
				bool reeds = dw < 1.6 && VegReedy(bi) && sl < 0.5 && f.Temp[i] > 0.24 && moistI > 0.48;
				if (dens <= 0.0 && !reeds) continue;
				rng.Reset(VegHashCell(seed, x, y, VegLayer));
				double communityMoist = -1.0;
				for (int k = 0; k < 2; k++)
				{
					double roll = rng.Next();
					if (roll < dens * 0.6)
					{
						double px = x + 0.1 + rng.Next() * 0.8;
						double py = y + 0.15 + rng.Next() * 0.8;
						if (communityMoist < 0.0)
						{
							double dryShoulder = VegClamp(VegConvexity(f, i) / 0.9, -1.0, 1.0);
							communityMoist = VegClamp(moistI + (age - 0.5) * 0.22 + (stand - 0.5) * 0.3 - 0.16 * dryShoulder, 0.0, 1.0);
						}
						double rKind = rng.Next();
						int kind = roll >= mugoFrom ? TMugo : VegKind(f, bi, rKind, e, communityMoist, sl, dw, f.Temp[i], light, interior, stand, exposed);
						if (f.Expedition)
							kind = VegExpeditionKind(kind, bi, VegHash2(x, y, seed ^ (8179 + k)), e, communityMoist, dw, light, stand, sl, exposed);
						int v = (int)Math.Floor(rng.Next() * 3);
						double sc;
						int treeAge = AdultAge;
						if (f.BTree[kind] != 0)
						{
							var form = VegTreeForm(age, interior, line, moistI, exposed, rng.Next(), kind);
							sc = form.Size;
							if (kind == TMugo)
								sc = VegLerp(0.74, 1.30, VegPosMod(form.Size * 7.13, 1.0)) * VegLerp(1.0, 0.76, VegSs(0.28, 0.44, e));
							else if (HasAges(kind))
							{
								treeAge = form.Cls;
								v += 3 * treeAge;
								if (kind == TRowan) sc *= 0.92;
							}
							else if (form.Cls == YoungAge)
								sc = VegMax(sc, 0.55);
						}
						else
						{
							sc = 0.8 + rng.Next() * 0.45;
							if (kind == TBush && dw >= VegShore && (bi == BForest || bi == BGrass || bi == BTaiga))
							{
								if (VegHash2(x, y, seed ^ (3221 + k)) > VegLerp(0.58, 1.0, VegSs(-0.25, 0.3, fv)))
									continue;
							}
						}
						if (kind != TRock && (f.DistPath[i] > 5.0 || VegClearOfPath(f, px, py, kind, sc, treeAge))
							&& (!hasCores || !VegCovers(f.Cores, coreFrom, coreTo, px, py, 0.2)))
							store.Add(px, py, kind, v, sc);
					}
				}
				if (reeds)
				{
					double stonyI = f.Stony[i];
					if (sl > 0.25 && stonyI > 0.3)
					{
						double legacyChance = 0.05 * VegClamp((stonyI - 0.3) * 4.0, 0.0, 1.0) * VegClamp(sl, 0.0, 1.0);
						if (rng.Next() < legacyChance)
							for (int unused = 0; unused < 4; unused++) rng.Next();
					}
					if (rng.Next() < 0.12)
					{
						double px = x + rng.Next();
						double py = y + rng.Next();
						int v = (int)Math.Floor(rng.Next() * 3);
						double sc = 0.8 + rng.Next() * 0.3;
						if ((f.DistPath[i] > 5.0 || VegClearOfPath(f, px, py, TReed, sc, AdultAge))
							&& (!hasCores || !VegCovers(f.Cores, coreFrom, coreTo, px, py, 0.0)))
							store.Add(px, py, TReed, v, sc);
					}
				}
			}
		}
		PlaceRockChunk(f, store, c, x0, y0, x1, y1);
	}

	/// <summary>RockScatter.place_chunk (план: поля с просветом, маска путей мира, дома и реки)</summary>
	private static void PlaceRockChunk(VegInput f, VegStore store, int c, int x0, int y0, int x1, int y1)
	{
		var rng = new VegRng();
		rng.Reset(1);
		int stride = f.W;
		var biome = f.Biome;
		var slope = f.Slope;
		var elev = f.Elev;
		var dw = f.Dw;
		var paths = f.DistPath;
		var rock = f.Rock;
		long seed = f.Seed;
		int rows = elev.Length / stride;
		int px0 = (int)Math.Floor((double)x0 / PatchCells);
		int py0 = (int)Math.Floor((double)y0 / PatchCells);
		int pw = (int)Math.Floor((double)(x1 - 1) / PatchCells) - px0 + 2;
		int ph = (int)Math.Floor((double)(y1 - 1) / PatchCells) - py0 + 2;
		var patches = new float[pw * ph];
		for (int yy = 0; yy < ph; yy++)
			for (int xx = 0; xx < pw; xx++)
				patches[yy * pw + xx] = (float)VegHash2(px0 + xx, py0 + yy, seed ^ 0x524f434b);
		var big = f.Massifs;
		int bigFrom = f.MassifStart[c], bigTo = f.MassifStart[c + 1];
		int coreFrom = f.CoreStart[c], coreTo = f.CoreStart[c + 1];
		bool hasBodies = coreTo > coreFrom;
		for (int at = bigFrom; at < bigTo; at += MassifStride)
			if (big[at] >= x0 && big[at] < x1 && big[at + 1] >= y0 && big[at + 1] < y1)
				store.Add(big[at], big[at + 1], TRock, (int)big[at + 2], big[at + 3]);
		for (int y = y0; y < y1; y++)
		{
			double gy = (double)y / PatchCells;
			double ty = Smooth01(gy - Math.Floor(gy));
			int patchRow = ((int)Math.Floor(gy) - py0) * pw;
			for (int x = x0; x < x1; x++)
			{
				int i = y * stride + x;
				int bi = biome[i];
				if (f.BWater[bi] != 0 || f.River[i] != 0 || f.Village[i] != 0) continue;
				double sl = slope[i];
				if (dw[i] < 0.65) continue;
				double dp = paths[i];
				if (dp < 0.0) continue;
				bool outcropClear = dp > 10.0 && dw[i] >= 1.5;
				double e = elev[i];
				bool lowHill = outcropClear && sl > LowHillSlope && e > LowHillMin && e < LowHillMax
					&& (bi == BGrass || bi == BSteppe || bi == BSavanna) && f.Moist[i] < 0.52;
				bool outcropSite = outcropClear && (lowHill || sl > HillOutcropSlope || (bi == BRock && sl > 0.12));
				long hc = VegHashCell(seed, x, y, 37);
				double roll = hc / 4294967296.0;
				bool boulderCandidate = sl <= 0.85 && roll < MaxChance;
				if (!boulderCandidate && !outcropSite) continue;
				double mountain = ReliefSmooth(0.12, 0.36, e);
				double exposed = rock[i] / 255.0;
				double gx = (double)x / PatchCells;
				double tx = Smooth01(gx - Math.Floor(gx));
				int pi = patchRow + (int)Math.Floor(gx) - px0;
				double deposit = VegLerp(VegLerp(patches[pi], patches[pi + 1], tx), VegLerp(patches[pi + pw], patches[pi + pw + 1], tx), ty);
				if (outcropSite)
				{
					double steep = ReliefSmooth(0.45, 0.95, sl);
					double oc = 0.0;
					if (mountain > 0.0 && exposed > 0.3)
					{
						double tor = bi == BRock ? ReliefSmooth(0.12, 0.4, sl) * 0.03 : 0.0;
						oc = OutcropChance * ReliefSmooth(0.3, 0.75, exposed) * mountain * VegMax(steep, tor) * VegLerp(0.04, 1.8, ReliefSmooth(0.3, 0.85, deposit));
					}
					if (e > 0.035 && e < 0.15 && sl > HillOutcropSlope && deposit > 0.55 && f.Moist[i] < 0.62)
					{
						double convex = VegConvexity(f, i);
						double hill = ReliefSmooth(0.035, 0.07, e) * (1.0 - ReliefSmooth(0.11, 0.15, e));
						double dry = 1.0 - ReliefSmooth(0.42, 0.62, f.Moist[i]);
						double shoulderChance = HillOutcropChance * hill * dry * ReliefSmooth(0.15, 0.9, convex)
							* ReliefSmooth(HillOutcropSlope, 0.62, sl) * ReliefSmooth(0.55, 0.84, deposit);
						oc = VegMax(oc, shoulderChance);
					}
					double lowChance = 0.0;
					if (lowHill && deposit > 0.62)
					{
						double convex = VegConvexity(f, i, LowHillReach);
						double height = ReliefSmooth(LowHillMin, 0.036, e) * (1.0 - ReliefSmooth(0.065, LowHillMax, e));
						double dry = 1.0 - ReliefSmooth(0.37, 0.52, f.Moist[i]);
						lowChance = LowHillChance * height * dry * ReliefSmooth(0.20, 1.0, convex)
							* ReliefSmooth(LowHillSlope, 0.36, sl) * ReliefSmooth(0.62, 0.86, deposit);
					}
					double chanceOutcrop = VegMax(oc, lowChance);
					long ho = chanceOutcrop > 0.0 ? VegHashCell(seed, x, y, 38) : 0;
					double outcropRoll = ho / 4294967296.0;
					if (outcropRoll < chanceOutcrop)
					{
						if (hasBodies && VegCovers(f.Cores, coreFrom, coreTo, x + 0.5, y + 0.5, 0.0)) continue;
						rng.Reset(ho ^ 0x0c7c0e5);
						double ocx = x + 0.3 + rng.Next() * 0.4;
						double ocy = y + 0.3 + rng.Next() * 0.4;
						double r = rng.Next();
						double os = outcropRoll >= oc ? 0.60 + r * r * 0.50 : 0.85 + r * r * 0.95 + steep * 0.25;
						int otint = OutcropV + (int)VegClamp(deposit * 3.0, 0.0, 2.0);
						double reach = os * OutcropClear;
						if (VegClearPath(f, f.PathMask, ocx, ocy, reach) && VegClearPath(f, f.Village, ocx, ocy, reach)
							&& VegClearPath(f, f.River, ocx, ocy, reach))
						{
							store.Add(ocx, ocy, TRock, otint, os);
							continue;
						}
					}
				}
				if (!boulderCandidate) continue;
				double patch = ReliefSmooth(-0.15, 0.5, f.Stony[i]);
				double edge = 1.0 - Math.Abs(VegClamp(f.Forest[i] + 0.5, 0.0, 1.0) * 2.0 - 1.0);
				double depositWeight = VegLerp(0.15, 1.65, ReliefSmooth(0.2, 0.8, deposit));
				double groundWeight = depositWeight * (1.0 - ReliefSmooth(0.6, 0.85, sl));
				double moistureWeight = VegLerp(1.6, 0.6, ReliefSmooth(0.42, 0.82, f.Moist[i]));
				double biomeWeight = 1.0;
				if (bi == BSwamp || bi == BSnow) biomeWeight = 0.35;
				else if (bi == BDesert || bi == BBeach) biomeWeight = 0.5;
				double baseChance = 0.005 + patch * (0.014 + edge * 0.014 + mountain * (0.05 * patch + exposed * 0.12));
				double talusSlope = 1.0 - ReliefSmooth(0.45, 0.85, sl);
				double talusGain = 0.12 + 0.14 * patch;
				double upperChance = (baseChance + mountain * talusSlope * talusGain) * groundWeight * moistureWeight * biomeWeight;
				if (roll >= upperChance * MaxConvexityFactor) continue;
				if (hasBodies && VegCovers(f.Cores, coreFrom, coreTo, x + 0.5, y + 0.5, 0.0)) continue;
				double source = 0.0;
				int reachCells = 0;
				float downX = 0f, downY = 0f; // Vector2 down (float32)
				if (mountain > 0.0)
				{
					int lx = x, ly = y;
					double ex = lx > 0 && lx + 1 < stride ? (double)elev[i + 1] - elev[i - 1] : 0.0;
					double ey = ly > 0 && ly + 1 < rows ? (double)elev[i + stride] - elev[i - stride] : 0.0;
					double gl = Math.Sqrt(ex * ex + ey * ey);
					if (gl > 1e-7)
					{
						float g = (float)gl;
						downX = (float)(-ex) / g;
						downY = (float)(-ey) / g;
						foreach (int step in TalusReach)
						{
							int nx = lx - VegRound(downX * (double)step);
							int ny = ly - VegRound(downY * (double)step);
							if (nx < 0 || ny < 0 || nx >= stride || ny >= rows) break;
							int ni = ny * stride + nx;
							if (elev[ni] <= elev[i]) continue;
							double src = rock[ni] / 255.0 * (0.5 + 0.5 * ReliefSmooth(0.4, 0.9, slope[ni]));
							if (src > source)
							{
								source = src;
								reachCells = step;
							}
						}
					}
				}
				for (int at = bigFrom; at < bigTo; at += MassifStride)
				{
					float mdx = big[at + 6], mdy = big[at + 7];
					if (mdx == 0f && mdy == 0f) continue;
					float relX = (float)(x + 0.5 - big[at]);
					float relY = (float)(y + 0.5 - big[at + 1]);
					float along = relX * mdx + relY * mdy;
					float across = Math.Abs(relX * -mdy + relY * mdx);
					double half = big[at + 5] * 0.8;
					if (along > 0.1 && along < TalusRange && across < half)
					{
						if (f.MassifTor[at / MassifStride] != 0) continue;
						double fed = 0.92 * (1.0 - along / TalusRange) * (1.0 - ReliefSmooth(half * 0.4, half, across));
						if (fed > source)
						{
							source = fed;
							reachCells = Math.Clamp(VegRound(along), 2, 6);
							if (downX == 0f && downY == 0f) { downX = mdx; downY = mdy; }
						}
					}
				}
				double talus = ReliefSmooth(0.15, 0.55, source) * talusSlope;
				double chance = (baseChance + mountain * talus * talusGain) * groundWeight * moistureWeight * biomeWeight;
				if (roll >= chance * MaxConvexityFactor) continue;
				chance *= 1.0 + ConvexityGain * VegClamp(VegConvexity(f, i) / 0.9, -1.0, 1.0);
				if (roll >= VegMin(MaxChance, chance)) continue;
				double shoulder = (1.0 - ReliefSmooth(1.0, 8.0, dp)) * VegMax(exposed, mountain);
				double toe = reachCells / 6.0;
				rng.Reset(hc ^ 0x51ed270b);
				double cxp = x + 0.12 + rng.Next() * 0.76;
				double cyp = y + 0.12 + rng.Next() * 0.76;
				bool large = shoulder < 0.1 && rng.Next() < 0.06 + exposed * 0.12 + talus * (0.04 + 0.2 * toe);
				double rr = rng.Next();
				double scale = large ? (0.75 + rr * rr * 1.35) : (mountain > 0.3 && rr > 0.55 ? (0.24 + rr * rr * 0.48) : (0.07 + rr * rr * 0.30));
				if (VegClearanceAt(paths, stride, cxp, cyp, f.Tile) < f.Crown[TRock] * scale * f.Tile) continue;
				if (!VegClearPath(f, f.Village, cxp, cyp, scale)) continue;
				if (!VegClearPath(f, f.River, cxp, cyp, scale)) continue;
				int tint = (int)VegClamp(deposit * 3.0, 0.0, 2.0);
				store.Add(cxp, cyp, TRock, tint, scale);
				int count = large ? 3 : (shoulder > 0.2 || mountain > 0.4 ? 2 : 1);
				if (talus > 0.5 && toe < 0.5) count += 1;
				bool trail = talus > 0.3 && !(downX == 0f && downY == 0f);
				for (int n = 0; n < count; n++)
				{
					double a = rng.Next() * Tau;
					if (trail) a = f.Trig.Call(downY, downX, 2).AsDouble() + (a / Tau - 0.5) * 1.6;
					double radius = 0.18 + rng.Next() * (large ? 0.45 : 0.32);
					double px = cxp + f.Trig.Call(a, 0.0, 0).AsDouble() * radius;
					double py = cyp + f.Trig.Call(a, 0.0, 1).AsDouble() * radius;
					if ((int)Math.Floor(px) != x || (int)Math.Floor(py) != y) continue;
					double fragment = 0.055 + rng.Next() * (0.16 + mountain * 0.16) * (1.0 - 0.35 * talus * (1.0 - toe));
					if (VegClearanceAt(paths, stride, px, py, f.Tile) < f.Crown[TRock] * fragment * f.Tile) continue;
					if (!VegClearPath(f, f.Village, px, py, fragment)) continue;
					if (!VegClearPath(f, f.River, px, py, fragment)) continue;
					store.Add(px, py, TRock, tint, fragment);
				}
			}
		}
	}

	/// <summary>smoothstep(0, 1, v) движка</summary>
	private static double Smooth01(double v) => ReliefSmooth(0.0, 1.0, v);
}
