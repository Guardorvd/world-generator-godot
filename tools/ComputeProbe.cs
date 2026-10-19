using System;
using Godot;

/// <summary>Замер выделений managed-памяти конструктором вычислительного объекта, без шума и маршалинга.</summary>
public partial class ComputeProbe : RefCounted
{
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
