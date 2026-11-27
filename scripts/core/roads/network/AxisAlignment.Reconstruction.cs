using System;
using System.Collections.Generic;
using P = Roads.Network.LineBuilder.P;
using V = Roads.Network.LineBuilder.V;

namespace Roads.Network;

internal sealed partial class AxisAlignment
{
	private const double RepairShoulder = 7.0 / Tile;
	private static readonly double[] RepairShoulders = { 14.0 / Tile, 10.0 / Tile, RepairShoulder };
	private const double RepairMaxLength = 96.0 / Tile;
	private const double RepairMaxShift = 9.0 / Tile;
	private static readonly float[] RepairHandles = { 0.30f, 0.44f, 0.58f, 0.36f, 0.48f };

	internal static double[] CornerAngles(List<P> points, double chord)
	{
		var result = new double[points.Count];
		for (int i = 1; i + 1 < points.Count; i++)
			result[i] = LineShaper.TurnAngle(points, i, chord, chord);
		return result;
	}

	internal int QualifiedCorners { get; private set; }
	internal int ProfileOnly { get; private set; }
	internal double RebuiltAxisMetres { get; private set; }
	private readonly List<(int First, int Last)> _repairRanges = new();

	internal void ReconstructCorners(double[] angles, double angle, double chord, int kind)
	{
		double gradeBreak = RoadDefectSpans.GradeBreakLimit(kind);
		var defects = Array.ConvertAll(angles, turn => turn > angle);
		foreach (var (left, right) in RoadDefectSpans.Find(_along, _protected, defects, RepairShoulders[0]))
		{
			var (coreFirst, coreLast) = BrokenSlope(left, right, angles, angle, chord, kind, gradeBreak);
			if (coreFirst < 0) continue;
			QualifiedCorners++;
			bool accepted = false;
			int profileFirst = -1, profileLast = -1;
			int previousFirst = -1, previousLast = -1;
			foreach (double shoulder in RepairShoulders)
			{
				int first = Math.Max(left, AtOrBefore(_along[coreFirst] - shoulder));
				int last = Math.Min(right, AtOrBefore(_along[coreLast] + shoulder) + 1);
				if (first == previousFirst && last == previousLast) continue;
				previousFirst = first;
				previousLast = last;
				double length = _along[last] - _along[first];
				if (_along[coreFirst] - _along[first] < RepairShoulder - Sample ||
					_along[last] - _along[coreLast] < RepairShoulder - Sample ||
					length > RepairMaxLength) continue;
				if (profileFirst < 0 && length * Tile >= 17.0)
				{
					profileFirst = first;
					profileLast = last;
				}
				accepted = TryReconstruct(first, last, angle, chord, gradeBreak);
				if (!accepted) continue;
				_repairRanges.Add((first, last));
				break;
			}
			if (accepted) continue;
			Reject(profileFirst < 0 ? "approach" : "no_safe_curve");
			// The profile may still improve within the same broken turn when moving the axis is unsafe.
			if (profileFirst >= 0)
			{
				_repairRanges.Add((profileFirst, profileLast));
				ProfileOnly++;
			}
		}
	}

	private bool TryReconstruct(int first, int last, double angle, double chord, double gradeBreak)
	{
		for (int attempt = 0; attempt < RepairHandles.Length; attempt++)
		{
			var (curve, points) = PhaseMatchedCurve(first, last, chord, RepairHandles[attempt], attempt >= 3);
			if (curve == null) continue;
			double length = Stations(points)[^1];
			if (length > RepairMaxLength || !AcceptCorner(first, last, curve, points, angle, chord, gradeBreak)) continue;
			_splices.Add(new Splice(first, last, points));
			RebuiltAxisMetres += length * Tile;
			return true;
		}
		return false;
	}

	internal double[] RepairedRanges(double[] sourceStations = null, double[] publishedStations = null)
	{
		var ranges = new double[2 * _repairRanges.Count];
		double Station(int index)
		{
			double source = _along[index] * Tile;
			if (sourceStations == null) return source;
			int i = Array.BinarySearch(sourceStations, source);
			if (i >= 0) return publishedStations[i];
			i = Math.Clamp(~i, 1, sourceStations.Length - 1);
			return publishedStations[source - sourceStations[i - 1] < sourceStations[i] - source ? i - 1 : i];
		}
		int j = 0;
		foreach (var span in _repairRanges)
		{
			ranges[j++] = Station(span.First);
			ranges[j++] = Station(span.Last);
		}
		return ranges;
	}

	private (int First, int Last) BrokenSlope(int first, int last, double[] turns, double angle, double chord, int kind, double gradeBreak)
	{
		const int ShoulderProbe = 6;
		int left = first, right = last;
		while (left > 0 && _along[first] - _along[left] < 10.0 / Tile) left--;
		while (right + 1 < _source.Count && _along[right] - _along[last] < 10.0 / Tile) right++;
		var (_, ground) = SampleGround(_source.GetRange(left, right - left + 1));
		double minGrade = kind switch { 0 => 0.16, 1 => 0.18, _ => 0.22 };
		double severeTurn = angle + 8.0 * Math.PI / 180.0;
		int previous = -1;
		for (int i = first + 1; i < last; i++)
		{
			double turn = turns[i];
			if (turn <= angle || turn <= turns[i - 1] || turn < turns[i + 1]) continue;
			int at = (int)Math.Round((_along[i] - _along[left]) * Tile);
			bool brokenSlope = false;
			for (int j = Math.Max(ShoulderProbe, at - 4); j <= Math.Min(ground.Length - 1 - ShoulderProbe, at + 4); j++)
			{
				if (Math.Abs(ground[j + ShoulderProbe] - ground[j - ShoulderProbe]) >= 2 * ShoulderProbe * minGrade &&
					GeometryValidator.GradeBreak(ground[j - 4], ground[j], ground[j + 4]) >= 4.0 * gradeBreak)
				{
					brokenSlope = true;
					break;
				}
			}
			if (!brokenSlope) continue;
			if (turn >= Math.PI / 3.0 && LineShaper.TurnAngle(_source, i, 2.0 * chord, 2.0 * chord) >= 100.0 * Math.PI / 180.0)
				return (i, i);
			if (previous >= 0 && Math.Max(turn, turns[previous]) >= severeTurn &&
				_along[i] - _along[previous] >= 5.0 / Tile && _along[i] - _along[previous] <= 22.0 / Tile)
			{
				for (int j = previous + 1; j < i; j++)
					if (turns[j] < 0.75 * Math.Min(turn, turns[previous])) return (previous, i);
			}
			if (previous < 0 || _along[i] - _along[previous] >= 5.0 / Tile || turn > turns[previous])
				previous = i;
		}
		return (-1, -1);
	}

	private (List<P> Curve, List<P> Points) PhaseMatchedCurve(int first, int last, double chord, float handle, bool guided)
	{
		double length = _along[last] - _along[first];
		int guide = -1;
		V tangent = default;
		if (guided)
		{
			// Keep a guide on a switchback or S bend if a single curve cuts too
			// far inside it. Both halves share the guide tangent.
			guide = AtOrBefore((_along[first] + _along[last]) * 0.5);
			int lo = Math.Max(first, AtOrBefore(_along[guide] - chord));
			int hi = Math.Min(last, AtOrBefore(_along[guide] + chord) + 1);
			V across = At(_source[hi]) - At(_source[lo]);
			if (guide <= first || guide >= last || across.Length() < Sample) return (null, null);
			tangent = across.Normalized();
		}
		double width = _source[first].W;
		V incoming = Direction(first, -1), outgoing = Direction(last, 1);

		(List<P> Curve, List<P> Points, double Shift) Make(float h)
		{
			var curve = new List<P> { _source[first] };
			double remaining = length;
			if (guided)
			{
				float lead = (float)(_along[guide] - _along[first]) * h;
				AddTransition(curve, At(_source[guide]), incoming, tangent, width, lead);
				remaining = _along[last] - _along[guide];
			}
			AddTransition(curve, At(_source[last]), guided ? tangent : incoming, outgoing, width, (float)remaining * h);
			curve[^1] = _source[last];
			var points = PublishedStations(curve);
			double shift = (Stations(points)[^1] - length) * Tile;
			return (curve, points, shift);
		}

		// Keep the one-metre sampling lattice on the untouched road after the
		// splice. An arbitrary fractional change would resample its entire tread.
		const double phaseTolerance = 0.012;
		var candidate = Make(handle);
		double target = Math.Round(candidate.Shift);
		if (Math.Abs(candidate.Shift - target) <= phaseTolerance) return (candidate.Curve, candidate.Points);
		float a = handle - 0.08f, b = handle + 0.08f;
		var leftCurve = Make(a);
		var rightCurve = Make(b);
		double left = leftCurve.Shift, right = rightCurve.Shift;
		if (Math.Abs(left - target) <= phaseTolerance) return (leftCurve.Curve, leftCurve.Points);
		if (Math.Abs(right - target) <= phaseTolerance) return (rightCurve.Curve, rightCurve.Points);
		if (target < Math.Min(left, right) || target > Math.Max(left, right)) return (null, null);
		for (int step = 0; step < 7; step++)
		{
			float middle = (float)(a + (b - a) * Math.Clamp((target - left) / (right - left), 0.1, 0.9));
			candidate = Make(middle);
			if (Math.Abs(candidate.Shift - target) <= phaseTolerance) return (candidate.Curve, candidate.Points);
			if ((candidate.Shift < target) == (left < target))
			{
				a = middle;
				left = candidate.Shift;
			}
			else
			{
				b = middle;
				right = candidate.Shift;
			}
		}
		return (null, null);
	}

	private bool AcceptCorner(int first, int last, List<P> curve, List<P> points, double angle, double chord, double gradeBreak)
	{
		// Include untouched chords at both seams in the same defect detector.
		int left = first - 1, right = last + 1;
		while (left > 0 && _along[first] - _along[left] < 3.0 * chord) left--;
		while (right + 1 < _source.Count && _along[right] - _along[last] < 3.0 * chord) right++;
		var context = _source.GetRange(left, first - left);
		context.AddRange(points);
		context.AddRange(_source.GetRange(last + 1, right - last));
		for (int i = 1; i + 1 < context.Count; i++)
		{
			double turn = LineShaper.TurnAngle(context, i, chord, chord);
			if (turn <= angle) continue;
			if (i >= first - left && i < first - left + points.Count) return false;
			int source = i < first - left ? left + i : last + i - (first - left + points.Count) + 1;
			if (turn > LineShaper.TurnAngle(_source, source, chord, chord) + 0.01) return false;
		}
		double halfWidth = _source[first].W * Tile * 0.5;
		if (_validator.MinRadius(Pack(points)) < Math.Max(_minimumRadius, halfWidth + 0.5)) return false;
		for (int i = 1; i < points.Count; i++)
		{
			P a = points[i - 1], b = points[i];
			if (At(a).DistanceTo(At(b)) < 0.01) return false;
			V normal = (At(b) - At(a)).Normalized().Orthogonal() * (float)(Math.Max(a.W, b.W) * 0.5);
			V middle = At(a).Lerp(At(b), 0.5f);
			if (_blocked(At(b)) || _blocked(middle) || _blocked(middle + normal) || _blocked(middle - normal) ||
				!_validator.Segment(a.X, a.Y, b.X, b.Y, Math.Max(a.W, b.W), _grade * 1.35, _cross * 1.25) ||
				!_validator.HasClearance(a, b)) return false;
		}
		var original = _source.GetRange(first, last - first + 1);
		if (!_validator.Profile(Pack(curve), _grade) &&
			(_validator.Profile(Pack(original), _grade) || !_validator.Profile(Pack(curve), _grade * 1.18))) return false;
		if (!StaysLocal(curve, _source, first, last) || !StaysLocal(original, curve, 0, curve.Count - 1)) return false;
		if (!KeepsGradeBreaks(_source.GetRange(left, right - left + 1), context, gradeBreak)) return false;

		// A tangent-constrained curve can loop back onto itself or another leg of its own road.
		// Other roads and existing crossings have already been excluded by HasClearance.
		double clearance = (2.0 * halfWidth + 1.0) / Tile;
		double[] stations = Stations(curve);
		for (int i = 0; i < curve.Count; i++)
		{
			V point = At(curve[i]);
			for (int j = 1; j < i && stations[i] - stations[j] > 2.0 * clearance; j++)
				if (Near(point, curve[j - 1], curve[j], clearance)) return false;
			for (int j = 1; j < _source.Count; j++)
			{
				if (j <= first && stations[i] + _along[first] - _along[j] > 2.0 * clearance ||
					j > last && stations[^1] - stations[i] + _along[j - 1] - _along[last] > 2.0 * clearance)
				{
					if (Near(point, _source[j - 1], _source[j], clearance)) return false;
				}
			}
			foreach (var splice in _splices)
				for (int j = 1; j < splice.Points.Count; j++)
					if (Near(point, splice.Points[j - 1], splice.Points[j], clearance)) return false;
		}
		return true;
	}

	private bool KeepsGradeBreaks(List<P> before, List<P> after, double limit)
	{
		var (oldPoints, old) = SampleGround(before);
		var (newPoints, edited) = SampleGround(after);
		int oldDefects = 0, newDefects = 0;
		var oldBreaks = new double[old.Length];
		for (int i = 4; i + 4 < old.Length; i++)
		{
			oldBreaks[i] = GeometryValidator.GradeBreak(old[i - 4], old[i], old[i + 4]);
			if (oldBreaks[i] > 4.0 * limit) oldDefects++;
		}
		for (int i = 4; i + 4 < edited.Length; i++)
		{
			double gradeBreak = GeometryValidator.GradeBreak(edited[i - 4], edited[i], edited[i + 4]);
			if (gradeBreak <= 4.0 * limit) continue;
			if (++newDefects > oldDefects) return false;
			// A smaller count can hide a new bump on a different part of the turn.
			double nearby = 0.0;
			for (int j = 4; j + 4 < old.Length; j++)
				if (oldBreaks[j] > nearby && newPoints[i].DistanceSquaredTo(oldPoints[j]) <= 36.0 / (Tile * Tile))
					nearby = oldBreaks[j];
			if (gradeBreak > Math.Max(4.4 * limit, nearby + 0.15)) return false;
		}
		return true;
	}

	private (V[] Points, double[] Ground) SampleGround(List<P> points)
	{
		double[] stations = Stations(points);
		var y = new double[(int)Math.Floor(stations[^1] * Tile) + 1];
		var sampled = new V[y.Length];
		int segment = 1;
		for (int i = 0; i < y.Length; i++)
		{
			double at = i / Tile;
			while (segment + 1 < stations.Length && stations[segment] < at) segment++;
			P a = points[segment - 1], b = points[segment];
			double t = (at - stations[segment - 1]) / Math.Max(stations[segment] - stations[segment - 1], 1e-9);
			double x = a.X + t * (b.X - a.X), z = a.Y + t * (b.Y - a.Y);
			sampled[i] = V.Of(x, z);
			y[i] = _validator.Ground(x, z);
		}
		return (sampled, y);
	}

	private static bool StaysLocal(List<P> curve, List<P> reference, int first, int last)
	{
		foreach (P sample in curve)
		{
			bool near = false;
			for (int i = first + 1; i <= last && !near; i++)
				near = Near(At(sample), reference[i - 1], reference[i], RepairMaxShift);
			if (!near) return false;
		}
		return true;
	}

	private static bool Near(V point, P a, P b, double gap)
	{
		if (point.X < Math.Min(a.X, b.X) - gap || point.X > Math.Max(a.X, b.X) + gap ||
			point.Y < Math.Min(a.Y, b.Y) - gap || point.Y > Math.Max(a.Y, b.Y) + gap) return false;
		return point.DistanceSquaredTo(LineBuilder.ClosestOnSegment(point, At(a), At(b))) < gap * gap;
	}
}
