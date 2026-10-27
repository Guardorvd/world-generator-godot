using System;
using Godot;

/// <summary>Замер выделений managed-памяти конструктором вычислительного объекта, без шума и маршалинга.</summary>
public partial class ComputeProbe : RefCounted
{
	/// <summary>Read-only process snapshot; does not force GC. Peak covers the process lifetime.</summary>
	public Godot.Collections.Dictionary CaptureMetrics()
	{
		using var process = System.Diagnostics.Process.GetCurrentProcess();
		process.Refresh();
		return new Godot.Collections.Dictionary
		{
			["cpu_ms"] = process.TotalProcessorTime.TotalMilliseconds,
			["working_set_bytes"] = process.WorkingSet64,
			["peak_working_set_bytes"] = process.PeakWorkingSet64,
			["managed_allocated_bytes"] = GC.GetTotalAllocatedBytes(false),
			["logical_processors"] = System.Environment.ProcessorCount
		};
	}

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
		fast.Release();
		return result;
	}

	/// <summary>После прогрева реальный проход переиспользует буфер даже между объектами FastGrid.</summary>
	public long CorridorReuseBytes()
	{
		const int size = 70; // Три полосы, включая неполную последнюю.
		var ground = new float[size * size];
		var water = new float[ground.Length];
		Array.Fill(water, float.NegativeInfinity);
		var wet = new byte[ground.Length];
		using var fast = new FastGrid();
		fast.Setup(size, size);
		fast.SetCorridor(ground, water, wet, 0.45);
		fast.Release();
		using var next = new FastGrid();
		next.Setup(size, size);
		long before = GC.GetTotalAllocatedBytes(true);
		for (int i = 0; i < 3; i++)
			next.SetCorridor(ground, water, wet, 0.45 - i * 0.05);
		long bytes = GC.GetTotalAllocatedBytes(true) - before;
		next.Release();
		next.Release(); // Возврат буфера должен быть идемпотентным.
		return bytes;
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
