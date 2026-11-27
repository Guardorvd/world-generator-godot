using System.Collections.Generic;

namespace Roads.Network;

internal static class RoadDefectSpans
{
	internal static double GradeBreakLimit(int kind) => kind switch { 0 => 0.15, 1 => 0.22, _ => 0.30 };

	// Grow defects inside a single unprotected run. The boundaries of a merged
	// span still have a clean approach on each side. Units follow the stations.
	internal static List<(int First, int Last)> Find(double[] along, bool[] pinned, bool[] defects, double shoulder)
	{
		var result = new List<(int, int)>();
		int start = 0;
		while (start < along.Length)
		{
			if (pinned[start]) { start++; continue; }
			int end = start + 1;
			while (end < along.Length && !pinned[end]) end++;
			int first = start, last = start, mergedFirst = -1, mergedLast = -1;
			for (int i = start; i < end; i++)
			{
				if (!defects[i]) continue;
				while (first + 1 < i && along[i] - along[first + 1] >= shoulder) first++;
				while (last + 1 < end && along[last] - along[i] < shoulder) last++;
				if (first >= i || last <= i) continue;
				if (mergedLast >= 0 && first > mergedLast)
				{
					result.Add((mergedFirst, mergedLast));
					mergedFirst = -1;
				}
				if (mergedFirst < 0) mergedFirst = first;
				mergedLast = last;
			}
			if (mergedLast >= 0) result.Add((mergedFirst, mergedLast));
			start = end;
		}
		return result;
	}
}
