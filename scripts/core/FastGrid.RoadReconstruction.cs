using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;
using Godot;
using Roads.Network;

public partial class FastGrid
{
	private sealed class RoadProfileReconstruction
	{
		private readonly double[] _grades, _places;
		private readonly Dictionary<int, double[]> _ranges = new();
		private readonly double _window, _downhill;
		private readonly (int Before, int After, int Rebuilt)[] _stats;
		internal readonly float[] Target, Weight;
		internal readonly int[] SpanAt;
		private readonly List<(int First, int Last, int Kind)>[] _spans;
		private int _bakedBefore, _bakedAfter, _rejected;
		private bool[] _rejectedSpans;
		private long _fitTicks;
		private double _verificationMs, _rebuiltMetres;

		internal RoadProfileReconstruction(Godot.Collections.Dictionary settings, int stations, int routes)
		{
			_grades = settings["repair_grades"].AsFloat64Array();
			_places = settings["repair_places"].AsFloat64Array();
			_window = settings["repair_profile_window"].AsDouble();
			_downhill = settings["repair_downhill"].AsDouble();
			using var ranges = settings["repair_ranges"].AsGodotDictionary();
			foreach (var range in ranges)
				_ranges.Add(range.Key.AsInt32(), range.Value.AsFloat64Array());
			Target = new float[stations];
			Weight = new float[stations];
			SpanAt = new int[stations];
			_stats = new (int, int, int)[routes];
			_spans = new List<(int First, int Last, int Kind)>[routes];
		}

		internal static double Cut(int kind) => kind == 2 ? 3.0 : 5.0;
		internal bool HasWork => Array.Exists(_spans, spans => spans != null);

		internal Godot.Collections.Dictionary Report()
		{
			int before = 0, after = 0, rebuilt = 0;
			foreach (var route in _stats)
			{
				before += route.Before;
				after += route.After;
				rebuilt += route.Rebuilt;
			}
			return new Godot.Collections.Dictionary { ["before"] = before, ["after"] = after, ["proposed"] = rebuilt,
				["rebuilt"] = rebuilt - _rejected, ["reverted"] = _rejected, ["baked_before"] = _bakedBefore, ["baked_after"] = _bakedAfter,
				["profile_m"] = _rebuiltMetres, ["fit_work_ms"] = 1000.0 * _fitTicks / Stopwatch.Frequency, ["verification_ms"] = _verificationMs };
		}

		internal void Fit(int entry, int from, int to, int kind, int route, Vector2[] points, float[] halves, float[] profile,
			float[] strength, float[] ground, int width, int height, double tile, double step, float[] water, float[] distWater,
			RoadSegments index, int[] structStarts, double[] structs, double structureReach, double reach)
		{
			if (!_ranges.TryGetValue(route, out var ranges)) return;
			long started = Stopwatch.GetTimestamp();
			int context = (int)Math.Ceiling(_window / step);
			for (int k = 0; k < ranges.Length; k += 2)
			{
				int first = from + (int)Math.Ceiling(ranges[k] / step);
				int last = from + (int)Math.Floor(ranges[k + 1] / step);
				if ((last - first) * step < 16.0) continue;
				FitWindow(entry, Math.Max(from, first - context), Math.Min(to, last + context + 1),
					from, first, last, context, kind, route, points, halves, profile, strength, ground, width, height, tile,
					step, water, distWater, index, structStarts, structs, structureReach, reach);
			}
			Interlocked.Add(ref _fitTicks, Stopwatch.GetTimestamp() - started);
		}

		private void FitWindow(int entry, int from, int to, int routeFrom, int allowedFirst, int allowedLast, int context,
			int kind, int route, Vector2[] points, float[] halves, float[] profile, float[] strength, float[] ground,
			int width, int height, double tile, double step, float[] water, float[] distWater, RoadSegments index,
			int[] structStarts, double[] structs, double structureReach, double reach)
		{
			int n = to - from, chord = (int)Math.Ceiling(4.0 / step);
			if (n < 2 * context + 1) return;
			var along = new double[n];
			var original = new double[n];
			var terrain = new double[n];
			for (int i = 0; i < n; i++)
			{
				int j = from + i;
				along[i] = i * step;
				terrain[i] = RoadGround(ground, width, height, tile, points[j].X, points[j].Y);
				original[i] = kind == 2 ? terrain[i] : RoadLerp(terrain[i], profile[j], strength[j]);
			}
			double grade = _grades[kind];
			double gradeBreak = 4.0 * RoadDefectSpans.GradeBreakLimit(kind);
			var defects = new bool[n];
			MarkDefects(along, original, chord, grade, gradeBreak, defects);
			int firstAllowed = Math.Max(context, allowedFirst - from);
			int lastAllowed = Math.Min(n - 1 - context, allowedLast - from);
			if (firstAllowed > lastAllowed) return;
			Array.Clear(defects, 0, firstAllowed);
			Array.Clear(defects, lastAllowed + 1, n - lastAllowed - 1);
			int before = Count(defects), after = before, rebuilt = 0;
			if (before == 0) return;

			var pinned = new bool[n];
			Array.Fill(pinned, true, 0, firstAllowed);
			Array.Fill(pinned, true, lastAllowed + 1, n - lastAllowed - 1);
			// Test clearance only where a defect can require an earthwork.
			int checkedThrough = firstAllowed - 1;
			int margin = (int)Math.Ceiling(16.0 / step) + 2;
			for (int i = firstAllowed; i <= lastAllowed; i++)
			{
				if (!defects[i]) continue;
				int end = Math.Min(lastAllowed, i + margin);
				for (int k = Math.Max(checkedThrough + 1, i - margin); k <= end; k++)
					pinned[k] = !Safe(points[from + k], halves[from + k] + reach, route, (from + k - routeFrom) * step,
						width, height, tile, water, distWater, index, structStarts, structs, structureReach);
				checkedThrough = Math.Max(checkedThrough, end);
			}

			var current = (double[])original.Clone();
			foreach (var (first, last) in RoadDefectSpans.Find(along, pinned, defects, 14.0))
			{
				double length = along[last] - along[first];
				if (length < 16.0 || length > 96.0) continue;
				int left = Math.Max(0, first - context), right = Math.Min(n - 1, last + context);
				var candidate = new double[right - left + 1];
				Array.Copy(current, left, candidate, 0, candidate.Length);
				double a = original[first], b = original[last];
				double slopeA = (a - original[first - chord]) / (chord * step);
				double slopeB = (original[last + chord] - b) / (chord * step);
				bool withinBudget = true;
				for (int i = first + 1; i < last; i++)
				{
					double distance = along[i] - along[first], t = distance / length;
					double target = Hermite(a, b, slopeA * length, slopeB * length, t);
					double fade = RoadSmooth(0.0, 6.0, Math.Min(distance, length - distance));
					if (Math.Abs(target - terrain[i]) > Cut(kind) - 0.25)
					{
						withinBudget = false;
						break;
					}
					candidate[i - left] = RoadLerp(original[i], target, fade);
				}
				if (!withinBudget) continue;
				var oldDefects = new bool[candidate.Length];
				var newDefects = new bool[candidate.Length];
				var stations = along.AsSpan(left, candidate.Length);
				MarkDefects(stations, current.AsSpan(left, candidate.Length), chord, grade, gradeBreak, oldDefects);
				MarkDefects(stations, candidate, chord, grade, gradeBreak, newDefects);
				int gain = Count(oldDefects) - Count(newDefects);
				if (gain <= 0 || 2 * gain < Count(oldDefects)) continue;
				bool newSeamDefect = false;
				for (int k = 0; k < newDefects.Length; k++)
					if ((k + left <= first + chord || k + left >= last - chord) && newDefects[k] && !oldDefects[k])
						newSeamDefect = true;
				if (newSeamDefect) continue;
				for (int i = first + 1; i < last; i++)
				{
					double distance = along[i] - along[first];
					Target[from + i] = (float)Hermite(a, b, slopeA * length, slopeB * length, distance / length);
					Weight[from + i] = (float)RoadSmooth(0.0, 6.0, Math.Min(distance, length - distance));
					SpanAt[from + i] = from + first + 1;
					current[i] = candidate[i - left];
				}
				(_spans[entry] ??= new()).Add((from + first, from + last, kind));
				rebuilt++;
			}
			if (rebuilt > 0)
			{
				Array.Clear(defects);
				MarkDefects(along, current, chord, grade, gradeBreak, defects);
				after = Count(defects.AsSpan(firstAllowed, lastAllowed - firstAllowed + 1));
			}
			var previous = _stats[entry];
			_stats[entry] = (previous.Before + before, previous.After + after, previous.Rebuilt + rebuilt);
		}

		// Profile fitting knows the ideal axis. Check once more on the actual metre
		// triangles, where lateral fall and grid interpolation can move the jolts.
		internal bool[] CheckBaked(RoadFitData fit, double step, Func<Vector2, int, double> heightAt)
		{
			var timer = Stopwatch.StartNew();
			var rejected = _rejectedSpans = new bool[Weight.Length + 1];
			int context = (int)Math.Ceiling(_window / step), chord = (int)Math.Ceiling(4.0 / step);
			for (int r = 0; r < _spans.Length; r++)
			{
				if (_spans[r] == null) continue;
				foreach (var (first, last, kind) in _spans[r])
				{
					int left = Math.Max(fit.Starts[r], first - 2 * context);
					int right = Math.Min(fit.Starts[r + 1] - 1, last + context);
					int count = right - left + 1;
					var along = new double[count];
					var original = new double[count];
					var edited = new double[count];
					for (int i = 0; i < count; i++)
					{
						along[i] = i * step;
						original[i] = heightAt(fit.Points[left + i], 0);
						edited[i] = heightAt(fit.Points[left + i], first + 1);
					}
					var before = new bool[count];
					var after = new bool[count];
					var beforeBreaks = new bool[count];
					var afterBreaks = new bool[count];
					double limit = 4.0 * RoadDefectSpans.GradeBreakLimit(kind);
					MarkDefects(along, original, chord, _grades[kind], limit, before, beforeBreaks);
					MarkDefects(along, edited, chord, _grades[kind], limit, after, afterBreaks);
					int oldCount = 0, newCount = 0;
					bool displaced = false;
					for (int i = first - left - chord; i <= last - left + context && i < count; i++)
					{
						if (i < context) continue;
						oldCount += before[i] || beforeBreaks[i] ? 1 : 0;
						newCount += after[i] || afterBreaks[i] ? 1 : 0;
						displaced |= after[i] && !NearDefect(before, i) || afterBreaks[i] && !NearDefect(beforeBreaks, i);
					}
					if (displaced || newCount >= oldCount)
					{
						rejected[first + 1] = true;
						_rejected++;
					}
					else
					{
						_bakedBefore += oldCount;
						_bakedAfter += newCount;
						_rebuiltMetres += (last - first) * step;
					}
				}
			}
			_verificationMs = timer.Elapsed.TotalMilliseconds;
			return rejected;
		}

		private static bool NearDefect(bool[] defects, int at)
		{
			for (int i = Math.Max(0, at - 3); i <= Math.Min(defects.Length - 1, at + 3); i++)
				if (defects[i]) return true;
			return false;
		}

		private void MarkDefects(ReadOnlySpan<double> along, ReadOnlySpan<double> y, int chord, double grade,
			double gradeBreakHeight, Span<bool> defects, Span<bool> breaks = default)
		{
			GeometryValidator.FirstProfileFailure(along, y, default, 1.0, _window, grade,
				atStart: false, downhillRatio: _downhill, failures: defects);
			if (breaks.IsEmpty) breaks = defects;
			for (int i = chord; i + chord < y.Length; i++)
				if (GeometryValidator.GradeBreak(y[i - chord], y[i], y[i + chord]) > gradeBreakHeight) breaks[i] = true;
		}

		internal bool ClearsGap(RoadFitData fit, int route, int station, int radius)
		{
			int entry = Array.IndexOf(fit.Routes, route);
			if (entry < 0) return true;
			for (int j = Math.Max(fit.Starts[entry], fit.Starts[entry] + station - radius);
				j < Math.Min(fit.Starts[entry + 1], fit.Starts[entry] + station + radius + 1); j++)
			{
				int span = SpanAt[j];
				if (span != 0 && !_rejectedSpans[span]) return false;
			}
			return true;
		}

		private static int Count(ReadOnlySpan<bool> flags)
		{
			int count = 0;
			foreach (bool flag in flags) if (flag) count++;
			return count;
		}

		private static double Hermite(double a, double b, double slopeA, double slopeB, double t)
		{
			double u = 1.0 - t;
			return RoadLerp(a, b, t * t * (3.0 - 2.0 * t)) + t * u * (u * slopeA - t * slopeB);
		}

		private bool Safe(Vector2 point, double radius, int route, double station, int width, int height, double tile,
			float[] water, float[] distWater, RoadSegments index, int[] structStarts, double[] structs, double structureReach)
		{
			double apron = radius + tile * 0.5;
			if (RoadReliefEdge(point, width, height, tile) < 1.0 ||
				point.X < apron || point.Y < apron || point.X >= width * tile - apron || point.Y >= height * tile - apron) return false;
			int cell = (int)Math.Floor(point.Y / tile) * width + (int)Math.Floor(point.X / tile);
			if (distWater[cell] < 2.5 + radius / tile || !float.IsNegativeInfinity(water[cell])) return false;
			for (int i = 0; i < _places.Length; i += 3)
				if (RoadGraph.Hypot(point.X - _places[i], point.Y - _places[i + 1]) < _places[i + 2] + apron) return false;
			int x0 = Math.Max(0, (int)Math.Floor((point.X - apron) / tile - 0.5));
			int z0 = Math.Max(0, (int)Math.Floor((point.Y - apron) / tile - 0.5));
			int x1 = Math.Min(width - 2, (int)Math.Floor((point.X + apron) / tile - 0.5));
			int z1 = Math.Min(height - 2, (int)Math.Floor((point.Y + apron) / tile - 0.5));
			for (int z = z0; z <= z1; z++)
			for (int x = x0; x <= x1; x++)
			{
				int key = z * width + x;
				if (!float.IsNegativeInfinity(water[key])) return false;
				for (int k = structStarts[key]; k < structStarts[key + 1]; k++)
					if (RoadSegmentDistance(point.X, point.Y, structs, k * 4) < structureReach + apron) return false;
			}
			return RoadGapClear(index, width, new Rect2I(x0, z0, x1 - x0 + 1, z1 - z0 + 1), point, route, station, apron);
		}
	}
}
