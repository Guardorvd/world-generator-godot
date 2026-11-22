using System;

namespace Roads.Network;

/// <summary>Сессия V2 на этап путей (шаг 3 закрытия фазы 2): то, что не меняется между вызовами петель, ответвлений и
/// горных троп, считается один раз. Каждый кэш помечен ключом своих входов (хеш массивов, версия коридора поиска,
/// предел уклона) — при любом отличии он считается заново, поэтому результат тот же, что без сессии.</summary>
public sealed class NetworkSession
{
	public long Id = -1;
	// Поля рельефа и множителей (ключ — высота, вода, шум, биомы, параметры).
	public ulong FieldsKey;
	public float[] Smooth = Array.Empty<float>(), Slope = Array.Empty<float>(), Tpi = Array.Empty<float>();
	public float[] ShoreDist = Array.Empty<float>();
	public float[] CharacterCommon = Array.Empty<float>(), CharacterWave = Array.Empty<float>();
	// Грубый граф по пределу уклона (ключ — проходимость цены, высоты, связи, версия коридора, предел)
	public ulong CoarseKey;
	public CoarseGraph Coarse;

	public static ulong Hash(ulong h, float[] a)
	{
		for (int i = 0; i < a.Length; i++) h = (h ^ (uint)BitConverter.SingleToInt32Bits(a[i])) * 1099511628211UL;
		return h;
	}

	public static ulong Hash(ulong h, double[] a)
	{
		for (int i = 0; i < a.Length; i++) h = (h ^ (ulong)BitConverter.DoubleToInt64Bits(a[i])) * 1099511628211UL;
		return h;
	}

	public static ulong Hash(ulong h, byte[] a)
	{
		for (int i = 0; i < a.Length; i++) h = (h ^ a[i]) * 1099511628211UL;
		return h;
	}

	public static ulong Hash(ulong h, long v) => (h ^ (ulong)v) * 1099511628211UL;

	public const ulong Seed = 14695981039346656037UL;
}
