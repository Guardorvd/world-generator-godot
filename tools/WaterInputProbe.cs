using System;
using System.Collections.Generic;
using Godot;

public partial class WaterInputProbe : RefCounted
{
    private static bool Configure(FastGrid g) =>
        g.SetWater(4, 3, 4, 260, 0.3, Array.Empty<float>(), Array.Empty<int>(), Array.Empty<int>(), new byte[12], new float[12])
        && g.SetGround(new float[12]);

    public string[] InvalidCases()
    {
        var results = new List<string>();
        void Check(string name, Func<FastGrid, bool> run)
        {
            try
            {
                using var g = new FastGrid();
                bool ok = Configure(g) && run(g);
                results.Add((ok ? "PASS " : "FAIL ") + name);
            }
            catch (Exception e) { results.Add("FAIL " + name + ": " + e.GetType().Name); }
        }
        bool Rejected(FastGrid g, int w, int h, double tile, float[] segments, int[] cells, int[] indices, byte[] lake, float[] filled) =>
            !g.SetWater(w, h, tile, 260, 0.3, segments, cells, indices, lake, filled)
            && !g.WaterReady() && g.WaterSetupError().Length > 0 && !g.RoadSegment(1, 1, 2, 1, 1, 1, 1);
        var empty = Array.Empty<int>();
        var noSegments = Array.Empty<float>();
        Check("zero grid", g => Rejected(g, 0, 3, 4, noSegments, empty, empty, new byte[12], new float[12]));
        Check("single row cannot support bilinear terrain", g => Rejected(g, 4, 1, 4, noSegments, empty, empty, new byte[4], new float[4]));
        Check("dimension multiplication overflow", g => Rejected(g, int.MaxValue, int.MaxValue, 4, noSegments, empty, empty, new byte[12], new float[12]));
        Check("zero tile", g => Rejected(g, 4, 3, 0, noSegments, empty, empty, new byte[12], new float[12]));
        Check("NaN tile", g => Rejected(g, 4, 3, double.NaN, noSegments, empty, empty, new byte[12], new float[12]));
        Check("null arrays", g => Rejected(g, 4, 3, 4, null, null, null, null, null));
        Check("short lake array", g => Rejected(g, 4, 3, 4, noSegments, empty, empty, new byte[11], new float[12]));
        Check("short filled array", g => Rejected(g, 4, 3, 4, noSegments, empty, empty, new byte[12], new float[11]));
        Check("incomplete ribbon", g => Rejected(g, 4, 3, 4, new float[11], empty, empty, new byte[12], new float[12]));
        Check("mismatched river pairs", g => Rejected(g, 4, 3, 4, new float[12], new[] { 1 }, empty, new byte[12], new float[12]));
        Check("negative cell", g => Rejected(g, 4, 3, 4, new float[12], new[] { -1 }, new[] { 0 }, new byte[12], new float[12]));
        Check("cell past grid", g => Rejected(g, 4, 3, 4, new float[12], new[] { 12 }, new[] { 0 }, new byte[12], new float[12]));
        Check("negative river index", g => Rejected(g, 4, 3, 4, new float[12], new[] { 1 }, new[] { -1 }, new byte[12], new float[12]));
        Check("river index past ribbon", g => Rejected(g, 4, 3, 4, new float[12], new[] { 1 }, new[] { 1 }, new byte[12], new float[12]));
        Check("non-finite river vertex", g => { var p = new float[12]; p[5] = float.NaN; return Rejected(g, 4, 3, 4, p, empty, empty, new byte[12], new float[12]); });
        Check("non-finite filled height", g => { var f = new float[12]; f[5] = float.PositiveInfinity; return Rejected(g, 4, 3, 4, noSegments, empty, empty, new byte[12], f); });
        Check("short ground invalidates previous ground", g => !g.SetGround(new float[11]) && !g.WaterReady() && g.BridgeEnds(2, 2, 6, 2, 1, 0, 4, 1, 1, 0.25) == -1);
        Check("non-finite ground", g => { var p = new float[12]; p[2] = float.NaN; return !g.SetGround(p) && !g.WaterReady(); });
        Check("new water cannot reuse previous ground", g => g.SetWater(4, 3, 4, 260, 0.3, noSegments, empty, empty, new byte[12], new float[12]) && !g.WaterReady() && !g.CrossesWater(2, 2, 1, 0, 4));
        Check("bad ford cell is diagnosed", g => g.DeepFords(new[] { -1 }, 0.3).Length == 0 && g.WaterSetupError().Length > 0);
        Check("bad candidate start is diagnosed", g => g.BridgeCandidates(new[] { 0, 1 }, new[] { 2 }, 1, 3, 2, new byte[2], 4, 4, 0.1, 0.25, 1).Length == 4 && g.WaterSetupError().Length > 0);
        Check("mismatched candidate mask", g => g.BridgeCandidates(new[] { 0, 1 }, new[] { 0 }, 1, 3, 2, new byte[1], 4, 4, 0.1, 0.25, 1).Length == 4 && g.WaterSetupError().Length > 0);
        Check("non-finite query does not become a flat road", g => !g.RoadSegment(double.NaN, 1, 2, 1, 1, 1, 1));
        Check("zero bridge section", g => !g.BridgeSpanGround(2, 2, 0, 6, 2, 0, 1, 0, 4, 1, 0, 0));
        Check("bad nearest-path arrays", g => g.NearestPath(new byte[12], new float[1], 4, 0, 0)[0] == -1 && g.WaterSetupError().Length > 0);
        Check("recovery after invalid replacement", g => { g.SetGround(new float[1]); return Configure(g) && g.WaterReady() && g.WaterSetupError() == "" && g.RoadSegment(1, 1, 2, 1, 1, 1, 1); });
        return results.ToArray();
    }
}
