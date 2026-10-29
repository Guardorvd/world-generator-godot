using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Godot;

/// <summary>Read-only diagnostics. No collection, working-set trimming or process priority changes.</summary>
public partial class ProcessMetrics : RefCounted
{
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    public Godot.Collections.Dictionary Capture()
    {
        using var process = Process.GetCurrentProcess();
        process.Refresh();
        var result = new Godot.Collections.Dictionary {
            ["cpu_ms"] = process.TotalProcessorTime.TotalMilliseconds,
            ["rss_bytes"] = process.WorkingSet64,
            ["private_bytes"] = process.PrivateMemorySize64,
            ["peak_rss_bytes"] = process.PeakWorkingSet64,
            ["managed_allocated_bytes"] = GC.GetTotalAllocatedBytes(false),
            ["managed_heap_bytes"] = GC.GetTotalMemory(false),
            ["gc0"] = GC.CollectionCount(0), ["gc1"] = GC.CollectionCount(1), ["gc2"] = GC.CollectionCount(2),
            ["logical_processors"] = System.Environment.ProcessorCount
        };
        if (OperatingSystem.IsWindows()) {
            uint id = GetCurrentThreadId();
            foreach (ProcessThread thread in process.Threads) {
                using (thread) {
                    try {
                        if (thread.Id == id) result["calling_thread_cpu_ms"] = thread.TotalProcessorTime.TotalMilliseconds;
                    } catch (InvalidOperationException) { } // A worker may exit during enumeration.
                }
            }
        }
        return result;
    }
}
