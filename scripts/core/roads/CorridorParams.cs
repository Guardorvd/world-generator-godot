using System;
using Godot;

namespace Roads;

/// <summary>Числа одного вида пути для форм дорожного коридора (RoadRefinement.CORRIDOR, docs/ROAD_RELIEF.md):
/// roll — пологие волны, bump — бугры, tilt/keep/max — перекос, dish/dishVar — выпуклость или корыто,
/// hollow — продавленные места, ditch/lip — канава и вал у края, grade — предел добавленного продольного уклона.</summary>
public readonly struct CorridorKind
{
	public readonly double Roll, Bump, Tilt, Keep, Max, Dish, DishVar, Hollow, Ditch, Lip, Grade, BenchScale, TurnBank, ProfileFit, CrossFit, NaturalCross, TechnicalRelief;
	public readonly double SupportCut, TurnGradeScale;
	public readonly Vector2 DirectionalGrades;

	public CorridorKind(Godot.Collections.Dictionary d)
	{
		Roll = Num(d, "roll"); Bump = Num(d, "bump"); Tilt = Num(d, "tilt"); Keep = Num(d, "keep"); Max = Num(d, "max");
		Dish = Num(d, "dish"); DishVar = Num(d, "var"); Hollow = Num(d, "hollow"); Ditch = Num(d, "ditch"); Lip = Num(d, "lip");
		Grade = Num(d, "grade");
		BenchScale = OptionalNum(d, "bench_scale", 1.0);
		TurnBank = OptionalNum(d, "turn_bank", 0.0);
		ProfileFit = OptionalNum(d, "profile_fit", 1.0);
		CrossFit = OptionalNum(d, "cross_fit", 1.0);
		NaturalCross = OptionalNum(d, "natural_cross", 0.0);
		TechnicalRelief = OptionalNum(d, "technical_relief", 0.0);
		SupportCut = OptionalNum(d, "support_cut", 0.0);
		TurnGradeScale = OptionalNum(d, "turn_grade_scale", 1.0);
		DirectionalGrades = d.TryGetValue("directional_grades", out var grades) ? grades.AsVector2() : Vector2.Zero;
	}

	internal static double Num(Godot.Collections.Dictionary d, string key)
	{
		if (!d.ContainsKey(key)) throw new ArgumentException("нет ключа «" + key + "» в параметрах дорог");
		return d[key].AsDouble();
	}

	internal static double OptionalNum(Godot.Collections.Dictionary d, string key, double fallback)
	{
		return d.ContainsKey(key) ? d[key].AsDouble() : fallback;
	}
}

/// <summary>Подгонка профиля пути (RoadRefinement._fit_route) и пределы полки: shore — где у воды полотно сходит на нет (клеток,
/// RoadBed.SHORE.y), pin/pinFade — место закрепления у мостов (RoadBed.PIN, PIN_FADE), reach — досягаемость соседних осей,
/// shared — порог общей оси, fitFade — плавный вход подгонки, fitLimit — её предел, roadBench/trailBench — полка дороги и тропы,
/// landGap — зазор для широких форм земли.</summary>
public sealed class FitParams
{
	public readonly double Shore, Pin, PinFade, Reach, Shared, FitFade, FitLimit, RoadBench, TrailBench, LandGap;

	public FitParams(Godot.Collections.Dictionary d)
	{
		Shore = CorridorKind.Num(d, "shore"); Pin = CorridorKind.Num(d, "pin"); PinFade = CorridorKind.Num(d, "pin_fade");
		Reach = CorridorKind.Num(d, "reach"); Shared = CorridorKind.Num(d, "shared"); FitFade = CorridorKind.Num(d, "fit_fade");
		FitLimit = CorridorKind.Num(d, "fit_limit"); RoadBench = CorridorKind.Num(d, "road_bench");
		TrailBench = CorridorKind.Num(d, "trail_bench"); LandGap = CorridorKind.Num(d, "land_gap");
	}
}

/// <summary>Все настройки подгонки и форм коридора одним объектом. GDScript собирает словарь в одном месте
/// (RoadRefinement.corridor_params), C# разбирает его один раз на вызов; прежние позиционные массивы (смещения по виду,
/// покрытию, характеру) больше не нужны. Ключи: kinds (по виду пути: road, trail, mountain), surface_gain[8], character[8×3],
/// rhythm, level_kind[3], level_surface[8], fit{…}, fade, gap, stride.</summary>
public sealed class CorridorParams
{
	public const int Surfaces = 8, KindCount = 3;

	public readonly CorridorKind[] Kinds;
	public readonly double[] SurfaceGain;   // по покрытию RoadSurface: выраженность форм
	public readonly double[] Character;     // по покрытию × (roll, bump, wobble)
	public readonly bool Rhythm;            // ритм участков по RoadBump.patch (характер местности иначе — медленный шум)
	public readonly double[] LevelKind;     // выравнивание спокойных участков по виду пути
	public readonly double[] LevelSurface;  // и по покрытию
	public readonly FitParams Fit;
	public readonly double Fade, Gap;       // формы включаются на Fade м от закреплённого места; зазор между полотнами
	public readonly int Stride;             // чисел на станцию в массиве форм
	public readonly int LevelR;             // радиус выравнивания спокойных участков, станций
	public readonly double RhythmSpan;      // размах характера при ритме по RoadBump.patch

	public CorridorParams(Godot.Collections.Dictionary d)
	{
		var kinds = d["kinds"].AsGodotArray();
		if (kinds.Count != KindCount) throw new ArgumentException("видов пути должно быть " + KindCount);
		Kinds = new CorridorKind[KindCount];
		for (int i = 0; i < KindCount; i++) Kinds[i] = new CorridorKind(kinds[i].AsGodotDictionary());
		SurfaceGain = Table(d, "surface_gain", Surfaces);
		Character = Table(d, "character", Surfaces * 3);
		LevelKind = Table(d, "level_kind", KindCount);
		LevelSurface = Table(d, "level_surface", Surfaces);
		Rhythm = d["rhythm"].AsBool();
		Fit = new FitParams(d["fit"].AsGodotDictionary());
		Fade = CorridorKind.Num(d, "fade");
		Gap = CorridorKind.Num(d, "gap");
		Stride = d["stride"].AsInt32();
		LevelR = d["level_r"].AsInt32();
		RhythmSpan = CorridorKind.Num(d, "rhythm_span");
		if (Stride != 8) throw new ArgumentException("формы коридора: восемь чисел на станцию");
	}

	private static double[] Table(Godot.Collections.Dictionary d, string key, int size)
	{
		var values = d[key].AsFloat64Array();
		if (values.Length != size) throw new ArgumentException(key + ": ожидалось " + size + " чисел, пришло " + values.Length);
		return values;
	}
}
