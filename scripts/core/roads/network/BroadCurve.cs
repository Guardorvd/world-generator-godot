using System;
using System.Collections.Generic;
using P = Roads.Network.LineBuilder.P;
using V = Roads.Network.LineBuilder.V;

namespace Roads.Network;

/// <summary>Fits cubic spans to the coarse shape of an already built search line.</summary>
internal sealed class BroadCurve
{
	private const double Tile = 4.0;
	private const double Sample = 0.25;
	private readonly GeometryValidator _validator;
	private readonly Func<V, bool> _blocked;
	private readonly double _spacing, _radius, _offset, _grade, _cross, _straight;
	internal readonly Dictionary<string, int> Refused = new();
	internal int Accepted;

	internal BroadCurve(GeometryValidator validator, Func<V, bool> blocked, double spacing, double radius,
		double offset, double straight, double grade, double cross)
	{
		_validator = validator;
		_blocked = blocked;
		_spacing = spacing / Tile;
		_radius = radius / Tile;
		_offset = offset / Tile;
		_straight = straight / Tile;
		_grade = grade;
		_cross = cross;
	}

	internal (List<P> Points, List<byte> Pins) Fit(List<P> source, List<byte> sourcePins, List<P> search)
	{
		(source, sourcePins) = Densify(source, sourcePins);
		var along = new double[source.Count];
		var fixedPoints = new bool[source.Count];
		fixedPoints[0] = fixedPoints[^1] = true;
		for (int i = 1; i < source.Count; i++)
		{
			along[i] = along[i - 1] + (At(source[i]) - At(source[i - 1])).Length();
			if (source[i - 1].W != source[i].W) fixedPoints[i - 1] = fixedPoints[i] = true;
		}
		for (int i = 0; i < source.Count; i++)
		{
			if (sourcePins[i] == 0 && !_blocked(At(source[i])) && !_validator.NearAxis(source[i], 0.35)) continue;
			// Keep the approaches as well as the exact pin or intersection.
			for (int j = i; j >= 0 && along[i] - along[j] <= LineBuilder.AxisPinCells; j--) fixedPoints[j] = true;
			for (int j = i; j < source.Count && along[j] - along[i] <= LineBuilder.AxisPinCells; j++) fixedPoints[j] = true;
		}

		var result = new List<P>(source.Count);
		var pins = new List<byte>(source.Count);
		result.Add(source[0]);
		pins.Add(1);
		for (int lo = 0; lo < source.Count - 1;)
		{
			int hi = lo + 1;
			while (hi < source.Count - 1 && !fixedPoints[hi]) hi++;
			var knots = Knots(source, along, lo, hi);
			for (int i = 1; i < knots.Count; i++)
			{
				int start = knots[i - 1], end = knots[i];
				if (end > start + 1 && along[end] - along[start] >= 0.60 * _spacing)
				{
					// Leave already rounded spans alone, including their adjoining chords.
					int shoulderStart = Math.Max(lo, start - 1), shoulderEnd = Math.Min(hi, end + 1);
					if (_validator.MinRadius(Pack(source.GetRange(shoulderStart, shoulderEnd - shoulderStart + 1))) >= _radius * Tile)
					{
						Refused["already_rounded"] = Refused.GetValueOrDefault("already_rounded") + 1;
						for (int j = start + 1; j <= end; j++) { result.Add(source[j]); pins.Add(sourcePins[j]); }
						continue;
					}
					V startDirection = Direction(source, along, start, lo, hi);
					V endDirection = Direction(source, along, end, lo, hi);
					string reason = Curve(source[start], source[end], startDirection, endDirection, out var curve)
						? Validate(source, search, along, start, end, result, curve)
						: "radius";
					if (reason == null)
					{
						Accepted++;
						for (int j = 1; j < curve.Count; j++) { result.Add(curve[j]); pins.Add(1); }
						continue;
					}
					Refused[reason] = Refused.GetValueOrDefault(reason) + 1;
				}
				for (int j = start + 1; j <= end; j++) { result.Add(source[j]); pins.Add(sourcePins[j]); }
			}
			lo = hi;
		}
		return (result, pins);
	}

	private static (List<P>, List<byte>) Densify(List<P> points, List<byte> pins)
	{
		var result = new List<P> { points[0] };
		var flags = new List<byte> { pins[0] };
		for (int i = 1; i < points.Count; i++)
		{
			P a = points[i - 1], b = points[i];
			int count = (int)Math.Ceiling((At(b) - At(a)).Length());
			for (int k = 1; k < count; k++)
			{
				double t = k / (double)count;
				result.Add(new P(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t, a.W + (b.W - a.W) * t));
				flags.Add(0);
			}
			result.Add(b);
			flags.Add(pins[i]);
		}
		return (result, flags);
	}

	private List<int> Knots(List<P> source, double[] along, int lo, int hi)
	{
		var result = new List<int> { lo };
		int count = Math.Max(1, (int)Math.Round((along[hi] - along[lo]) / _spacing));
		int at = lo;
		for (int i = 1; i < count; i++)
		{
			double target = along[lo] + (along[hi] - along[lo]) * i / count;
			while (at + 1 < hi && Math.Abs(along[at + 1] - target) < Math.Abs(along[at] - target)) at++;
			if (at != result[^1]) result.Add(at);
		}
		result.Add(hi);
		for (int i = result.Count - 2; i > 0; i--)
		{
			int a = result[i - 1], b = result[i + 1];
			if (along[b] - along[a] > 2.1 * _spacing) continue;
			V first = At(source[a]), last = At(source[b]);
			bool straight = true;
			for (int j = a + 1; j < b && straight; j++)
				straight = (At(source[j]) - LineBuilder.ClosestOnSegment(At(source[j]), first, last)).Length() <= _straight;
			if (straight) result.RemoveAt(i);
		}
		return result;
	}

	private V Direction(List<P> source, double[] along, int index, int lo, int hi)
	{
		int first = index, last = index;
		if (index == lo && lo > 0) return (At(source[index]) - At(source[index - 1])).Normalized();
		if (index == hi && hi + 1 < source.Count) return (At(source[index + 1]) - At(source[index])).Normalized();
		while (first > lo && along[index] - along[first] < _spacing * 0.4) first--;
		while (last < hi && along[last] - along[index] < _spacing * 0.4) last++;
		return (At(source[last]) - At(source[first])).Normalized();
	}

	private bool Curve(P a, P b, V incoming, V outgoing, out List<P> points)
	{
		points = null;
		V start = At(a), end = At(b);
		float chord = (end - start).Length();
		if (chord < 0.01f) return false;
		V p = start + incoming * (chord / 3);
		V q = end - outgoing * (chord / 3);
		V d0 = (p - start) * 3, d1 = (q - p) * 3, d2 = (end - q) * 3;
		V dd0 = (d1 - d0) * 2, dd1 = (d2 - d1) * 2;
		int steps = Math.Max(2, (int)Math.Ceiling(Math.Max(d0.Length(), Math.Max(d1.Length(), d2.Length())) / Sample));
		var curve = new List<P>(steps + 1) { a };
		for (int i = 1; i <= steps; i++)
		{
			// Bound speed and the curvature numerator over the sampling interval.
			float t = (i - 0.5f) / steps;
			V derivative = d0.Lerp(d1, t).Lerp(d1.Lerp(d2, t), t);
			V acceleration = dd0.Lerp(dd1, t);
			double speedError = Math.Max(dd0.Length(), dd1.Length()) * (0.5 / steps);
			double accelerationError = (dd1 - dd0).Length() * (0.5 / steps);
			double speed = derivative.Length() - speedError;
			double turn = Math.Abs(derivative.Cross(acceleration)) + speedError * acceleration.Length() +
				(derivative.Length() + speedError) * accelerationError;
			if (speed <= 0 || turn * _radius > speed * speed * speed) return false;
			if (i == steps) break;
			t = i / (float)steps;
			V middle = p.Lerp(q, t);
			V at = start.Lerp(p, t).Lerp(middle, t).Lerp(middle.Lerp(q.Lerp(end, t), t), t);
			curve.Add(new P(at.X, at.Y, a.W));
		}
		curve.Add(b);
		points = curve;
		return true;
	}

	private string Validate(List<P> source, List<P> search, double[] along, int start, int end,
		List<P> built, List<P> curve)
	{
		bool changed = false;
		for (int i = 1; i < curve.Count; i++)
		{
			P a = curve[i - 1], b = curve[i];
			V at = At(a).Lerp(At(b), 0.5f);
			P mid = new(at.X, at.Y, a.W);
			V before = Nearest(source, start, end, at);
			if ((before - at).Length() > _offset - Sample / 2 ||
				(Nearest(search, 0, search.Count - 1, at) - at).Length() > _offset - Sample / 2) return "corridor";
			changed |= (before - at).Length() > _straight;
			V side = (At(b) - At(a)).Normalized().Orthogonal() * (float)(a.W * 0.5);
			if (_blocked(at) || _blocked(at + side) || _blocked(at - side)) return "structure";
			string issue = _validator.SegmentRefusal(a, b, _grade, _cross);
			if (issue != null) return issue;
			if (!_validator.KeepsClearance(new P(before.X, before.Y, a.W), mid, source[0], source[^1])) return "clearance";
		}
		if (!changed) return "straight";
		if (!_validator.Profile(Pack(curve), _grade)) return "profile";

		int from = start, to = end;
		while (from > 0 && along[start] - along[from] < 3) from--;
		while (to + 1 < source.Count && along[to] - along[end] < 3) to++;
		var context = new List<P>();
		for (int i = built.Count - 1; i >= 0; i--)
		{
			context.Add(built[i]);
			if ((At(built[i]) - At(source[start])).Length() >= 3) break;
		}
		context.Reverse();
		for (int i = 1; i < curve.Count; i++) context.Add(curve[i]);
		for (int i = end + 1; i <= to; i++) context.Add(source[i]);
		var beforeContext = source.GetRange(from, to - from + 1);
		var beforePacked = Pack(beforeContext);
		var afterPacked = Pack(context);
		if (!_validator.Profile(afterPacked, _grade) && _validator.Profile(beforePacked, _grade)) return "profile";
		double beforeRadius = _validator.MinRadius(beforePacked);
		if (_validator.MinRadius(afterPacked) < Math.Min(200.0, beforeRadius * 0.95)) return "seam";

		var candidate = new List<P>(built);
		for (int i = 1; i < curve.Count; i++) candidate.Add(curve[i]);
		for (int i = end + 1; i < source.Count; i++) candidate.Add(source[i]);
		if (!_validator.KeepsCrossings(beforeContext, context) || !_validator.KeepsCrossings(source, candidate)) return "double_cross";
		return null;
	}

	private static V Nearest(List<P> points, int start, int end, V at)
	{
		V closest = At(points[start]);
		float distance = closest.DistanceSquaredTo(at);
		for (int i = start + 1; i <= end; i++)
		{
			V candidate = LineBuilder.ClosestOnSegment(at, At(points[i - 1]), At(points[i]));
			float next = candidate.DistanceSquaredTo(at);
			if (next < distance) { closest = candidate; distance = next; }
		}
		return closest;
	}

	private static double[] Pack(List<P> points)
	{
		var packed = new double[2 * points.Count];
		for (int i = 0; i < points.Count; i++) { packed[2 * i] = points[i].X; packed[2 * i + 1] = points[i].Y; }
		return packed;
	}

	private static V At(P p) => V.Of(p.X, p.Y);
}
