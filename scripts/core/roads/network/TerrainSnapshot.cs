using System;
using Godot;

namespace Roads.Network;

/// <summary>Ссылки на массивы мира для V2 (только чтение, кроме своих копий Owner/Mask/Cost) и два экземпляра FastGrid:
/// Water — земля и вода (Heightfield.fast_water: SetWater/SetGround уже сделаны), Router — поиск пути с коридором
/// (Pathfinder этапа: высоты, связи сооружений и ширина прохода уже заданы). Арифметика воды и отрезка не копируется:
/// GroundAt/DepthAt/RoadSegment — методы FastGrid.Water.cs.</summary>
public sealed class TerrainSnapshot
{
	public readonly int W, H, N;
	public readonly Params P;
	public readonly float[] Cost;      // w.cost (с «протоптанностью» V1); не меняется
	public readonly float[] Heights;   // высоты поиска (StageTrails._route_heights), м / TILE
	public readonly byte[] Links;      // связи сооружений поиска (Pathfinder.links), пусто — нет
	public readonly float[] Hv;        // готовая земля, м (Heightfield.hv)
	public readonly float[] Hw;        // w.h (1 = 260 м) — уровень для правила «вдоль сети» (StageTrails._parallel_stats)
	public readonly byte[] Ocean, Lake, River, Biome, Unsafe, OnAxis;
	public readonly double[] Noise;    // готовый шум мира w.noise_field("cost")
	public readonly bool[] Forest = new bool[256];
	public readonly int[] Owner;       // копия generation.road_owner: принятые пути V2 дописываются своими номерами
	public readonly byte[] Mask;       // копия w.path_mask: принятые пути V2 отмечаются 2
	public readonly int Sections;      // число записей w.trails на входе: номера V2 начинаются с него
	public readonly FastGrid Water;
	public readonly FastGrid Router;

	public TerrainSnapshot(Godot.Collections.Dictionary d, FastGrid water, FastGrid router)
	{
		P = new Params(d);
		W = P.W; H = P.H; N = checked(W * H);
		Water = water ?? throw new ArgumentException("V2: нет земли и воды (Heightfield.fast_water)");
		Router = router ?? throw new ArgumentException("V2: нет поиска пути");
		if (!water.WaterReady()) throw new ArgumentException("V2: земля и вода не готовы: " + water.WaterSetupError());
		Cost = Floats(d, "cost");
		Heights = Floats(d, "heights");
		Hv = Floats(d, "hv");
		Hw = Floats(d, "h");
		Ocean = Bytes(d, "ocean"); Lake = Bytes(d, "lake"); River = Bytes(d, "river"); Biome = Bytes(d, "biome");
		Unsafe = Bytes(d, "unsafe"); OnAxis = Bytes(d, "on_axis");
		Links = d.ContainsKey("links") ? d["links"].AsByteArray() : Array.Empty<byte>();
		if (Links.Length != 0 && Links.Length != N) throw new ArgumentException("V2: links не W·H");
		Noise = d.ContainsKey("noise") ? d["noise"].AsFloat64Array() : throw new ArgumentException("V2: нет ключа «noise»");
		if (Noise.Length != N) throw new ArgumentException("V2: noise не W·H");
		foreach (int b in Ints(d, "forest_biomes", false)) Forest[b & 255] = true;
		Owner = (int[])Ints(d, "owner", true).Clone();
		Mask = (byte[])Bytes(d, "mask").Clone();
		Sections = (int)Params.Num(d, "sections");
	}

	private float[] Floats(Godot.Collections.Dictionary d, string key)
	{
		if (!d.ContainsKey(key)) throw new ArgumentException("V2: нет ключа «" + key + "»");
		var a = d[key].AsFloat32Array();
		if (a.Length != N) throw new ArgumentException("V2: «" + key + "» не W·H (" + a.Length + ")");
		return a;
	}

	private byte[] Bytes(Godot.Collections.Dictionary d, string key)
	{
		if (!d.ContainsKey(key)) throw new ArgumentException("V2: нет ключа «" + key + "»");
		var a = d[key].AsByteArray();
		if (a.Length != N) throw new ArgumentException("V2: «" + key + "» не W·H (" + a.Length + ")");
		return a;
	}

	private int[] Ints(Godot.Collections.Dictionary d, string key, bool grid)
	{
		if (!d.ContainsKey(key)) throw new ArgumentException("V2: нет ключа «" + key + "»");
		var a = d[key].AsInt32Array();
		if (grid && a.Length != N) throw new ArgumentException("V2: «" + key + "» не W·H (" + a.Length + ")");
		return a;
	}

	public bool Wet(int i) => Ocean[i] != 0 || Lake[i] != 0 || River[i] != 0;
	public bool Net(int i) => Owner[i] >= 0;
	public double X(int i) => i % W + 0.5;
	public double Y(int i) => i / W + 0.5;
	public double Dist(int a, int b) { double dx = a % W - b % W, dy = a / W - b / W; return Math.Sqrt(dx * dx + dy * dy); }

	/// <summary>Земля в метрах в точке (x, z, м) — FastGrid.Water.cs (Heightfield.ground_at без сооружений).</summary>
	public double GroundAt(double x, double z) => Water.GroundAt(x, z);
	/// <summary>Глубина воды в точке (м) — FastGrid.Water.cs (Heightfield.depth_at без настилов).</summary>
	public double DepthAt(double x, double z) => Water.DepthAt(x, z);

	/// <summary>Длина пути по клеткам (StageTrails._length).</summary>
	public double Length(int[] p)
	{
		double length = 0.0;
		for (int k = 1; k < p.Length; k++)
		{
			int dx = p[k] % W - p[k - 1] % W, dy = p[k] / W - p[k - 1] / W;
			length += Math.Sqrt(dx * dx + dy * dy);
		}
		return length;
	}
}
