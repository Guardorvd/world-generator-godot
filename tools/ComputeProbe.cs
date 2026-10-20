using System;
using Godot;

/// <summary>Замер выделений managed-памяти конструктором вычислительного объекта, без шума и маршалинга.</summary>
public partial class ComputeProbe : RefCounted
{
	/// <summary>Выделения каждого переключения ширины прохода, без маршалинга входов.</summary>
	public long[] CorridorBytes(int size, int count)
	{
		using var fast = new FastGrid();
		fast.Setup(size, size);
		var result = new long[count];
		for (int i = 0; i < count; i++)
		{
			long before = GC.GetAllocatedBytesForCurrentThread();
			fast.SetCorridor(Array.Empty<float>(), Array.Empty<float>(), Array.Empty<byte>(), 0.45 - i * 0.05);
			result[i] = GC.GetAllocatedBytesForCurrentThread() - before;
		}
		return result;
	}

	public long ConstructorBytes(int count)
	{
		using (var warmup = new FastGrid()) { }
		var instances = new FastGrid[count];
		long before = GC.GetAllocatedBytesForCurrentThread();
		for (int i = 0; i < count; i++)
			instances[i] = new FastGrid();
		long bytes = GC.GetAllocatedBytesForCurrentThread() - before;
		foreach (var fast in instances)
			fast.Dispose();
		return bytes / count;
	}
}
