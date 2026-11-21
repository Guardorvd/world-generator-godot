using System;
using System.Collections.Generic;
using P = Roads.Network.LineBuilder.P;
using V = Roads.Network.LineBuilder.V;

namespace Roads.Network;

/// <summary>Replaces individual uphill zigzags with traverses joined by circular turning platforms.</summary>
internal sealed class SwitchbackBuilder
{
	private const double Tile = 4.0;
	private const double ZigzagWindow = 30.0 / Tile;
	private const double MinArm = 25.0 / Tile;
	private const double ProfileMargin = 12.0 / Tile;
	private const double LongClimb = 60.0 / Tile;
	private const double LengthLimit = 1.35;
	private const double Corner = 35 * Math.PI / 180;
	private const double Turn = 105 * Math.PI / 180;
	private static readonly double[] AnchorDistances = { 8, 12, 17, 23, 30 };
	private static readonly double[] SteepAnchorDistances = { 8, 10, 12, 15, 17, 20, 23, 26, 30 };
	private static readonly float[] SideDistances = { 7, 8.5f, 10, 12, 14, 16, 19 };
	private static readonly float[] TurnBiases = { 0, -0.12f, 0.12f };
	private static readonly int[] TurnCounts = { 1, 2 };
	private static readonly float[] TurnSides = { -1, 1 };

	internal enum Refusal { Anchors, Layout, Length, Structure, Water, Grade, Crossfall, Profile, Radius, Clearance, Ride }
	internal sealed record Placement(P Start, P End, P[] Turns, double Radius, double ShortestArm, double Length, double Rise, bool Long);
	internal readonly List<Placement> Placements = new();
	internal readonly Dictionary<Refusal, int> Refused = new();
	internal readonly List<(P At, Refusal Why)> RefusalSpots = new();
	internal int Candidates;

	private readonly GeometryValidator _validator;
	private readonly Func<GeometryValidator> _foreign;
	private readonly Func<V, bool> _blocked;
	private readonly double _grade, _cross, _radius;
	private readonly bool _protectedRide;

	internal SwitchbackBuilder(GeometryValidator validator, Func<GeometryValidator> foreign, Func<V, bool> blocked,
		double grade, double cross, double radius, bool protectedRide)
	{
		_validator = validator;
		_foreign = foreign;
		_blocked = blocked;
		_grade = grade;
		_cross = cross;
		_radius = radius;
		_protectedRide = protectedRide;
	}

	internal List<P> Rebuild(List<P> axis, List<P> raw, byte[] pins)
	{
		if (axis.Count < 3 || raw.Count < 3) return axis;
		var search = Along(raw);
		var along = Along(axis);
		var result = new List<P>(axis.Count);
		int written = 0;
		double lengthReserve = along[^1] * (LengthLimit - 1);
		foreach (P hit in Zigzags(raw, search))
		{
			int middle = Nearest(axis, hit);
			if (middle < written) continue;
			Candidates++;
			Refusal cause = _protectedRide ? Refusal.Ride : Refusal.Anchors;
			int first = written == 0 ? 0 : LowerBound(along, along[written - 1] + ProfileMargin);
			if (!_protectedRide && middle > first && TrySection(axis, along, pins, middle, first, result, lengthReserve, ref cause,
				out int from, out int to, out var replacement, out var placement))
			{
				for (; written < from; written++) result.Add(axis[written]);
				result.AddRange(replacement);
				written = to + 1;
				lengthReserve -= placement.Length / Tile - (along[to] - along[from]);
				Placements.Add(placement);
			}
			else
			{
				Refused[cause] = Refused.GetValueOrDefault(cause) + 1;
				if (!_protectedRide) RefusalSpots.Add((axis[middle], cause));
			}
		}
		if (Placements.Count == 0) return axis;
		for (; written < axis.Count; written++) result.Add(axis[written]);
		return result;
	}

	private IEnumerable<P> Zigzags(List<P> raw, double[] along)
	{
		var heights = new double[raw.Count];
		var grades = new double[raw.Count];
		for (int i = 0; i < raw.Count; i++)
		{
			heights[i] = Height(raw[i]);
			if (i > 0)
				grades[i] = Math.Abs(heights[i] - heights[i - 1]) / Math.Max(0.01, Tile * (along[i] - along[i - 1]));
		}
		int previous = -1;
		for (int i = 1; i + 1 < raw.Count; i++)
		{
			if (!LineBuilder.ChordPoint(raw, i, -1, 1, out double ax, out double ay) ||
				!LineBuilder.ChordPoint(raw, i, 1, 1, out double bx, out double by)) continue;
			double angle = Math.Abs((At(raw[i]) - V.Of(ax, ay)).AngleTo(V.Of(bx, by) - At(raw[i])));
			if (angle <= Corner) continue;
			if (previous >= 0 && along[i] - along[previous] <= ZigzagWindow)
			{
				int a = previous - 1, b = i + 1;
				double rise = Math.Abs(heights[b] - heights[a]);
				double steep = 0;
				for (int k = a + 1; k <= b; k++) steep = Math.Max(steep, grades[k]);
				if (rise >= 0.08 * Tile * (along[b] - along[a]) && steep >= 0.80 * _grade)
				{
					yield return raw[(previous + i) / 2];
					while (i + 1 < raw.Count && along[i + 1] - along[b] < ZigzagWindow) i++;
					previous = -1;
					continue;
				}
			}
			previous = i;
		}
	}

	private bool TrySection(List<P> axis, double[] along, byte[] pins, int middle, int firstAllowed, List<P> rebuilt,
		double lengthReserve, ref Refusal cause,
		out int from, out int to, out List<P> result, out Placement placement)
	{
		from = to = 0;
		result = null;
		placement = null;
		double bestScore = double.PositiveInfinity;
		var center = At(axis[middle]);
		var uphill = Gradient(center).Normalized();
		if (uphill.Length() < 0.5) return false;
		var across = uphill.Orthogonal();
		int first = middle, last = middle;
		while (first > firstAllowed && !Pinned(axis, pins, first)) first--;
		while (last < axis.Count - 1 && !Pinned(axis, pins, last)) last++;
		if (last <= first + 1) return false;
		var visited = new HashSet<(int, int)>();
		var distances = _grade >= 0.5 ? SteepAnchorDistances : AnchorDistances;
		foreach (double back in distances)
		foreach (double ahead in distances)
		{
			int lo = Math.Clamp(LowerBound(along, along[middle] - back), first, middle);
			int hi = Math.Clamp(LowerBound(along, along[middle] + ahead), middle, last);
			if (!visited.Add((lo, hi)) || lo == middle || hi == middle || along[hi] - along[lo] < 2 * MinArm) continue;
			if (_blocked(At(axis[lo])) || _blocked(At(axis[hi]))) continue;
			P a = axis[lo], b = axis[hi];
			double run = along[hi] - along[lo];
			if (Math.Abs(Height(b) - Height(a)) < run * Tile * 0.08) continue;
			V start = At(a), end = At(b), span = end - start;
			float riseRun = span.Dot(uphill);
			if (Math.Abs(riseRun) < 2 * _radius / Tile) continue;
			cause = Later(cause, Refusal.Layout);
			float shift = span.Dot(across);
			foreach (int count in TurnCounts)
			foreach (float side in SideDistances)
			foreach (float sign in TurnSides)
			foreach (float bias in TurnBiases)
			{
				var knots = new List<V>(4) { start };
				for (int j = 1; j <= count; j++)
				{
					float frac = j / (float)(count + 1) + bias;
					knots.Add(start + uphill * (riseRun * frac) + across * (shift * frac + sign * side * (j == 1 ? 1 : -1)));
				}
				knots.Add(end);
				if (!Fillets(knots, uphill, a, b, out var candidate, out var turns, out double arm)) continue;
				var candidateAlong = Along(candidate);
				double length = candidateAlong[^1];
				if (length > run + Math.Min(lengthReserve, 17.5)) { cause = Later(cause, Refusal.Length); continue; }
				double score = 0;
				foreach (P turn in turns) score += _validator.TerrainGrade(turn.X, turn.Y);
				score = score / turns.Length + 0.12 * length / run;
				if (score >= bestScore) continue;
				if (!Validate(axis, along, lo, hi, candidate, candidateAlong, rebuilt, out Refusal failure, out double radius))
				{
					cause = Later(cause, failure);
					if (failure != Refusal.Radius || !BlendSeams(axis, lo, hi, candidate, arm, out candidate, out arm)) continue;
					candidateAlong = Along(candidate);
					length = candidateAlong[^1];
					if (length > run + Math.Min(lengthReserve, 17.5) ||
						!Validate(axis, along, lo, hi, candidate, candidateAlong, rebuilt, out failure, out radius))
					{
						cause = Later(cause, failure);
						continue;
					}
				}
				bestScore = score;
				from = lo;
				to = hi;
				result = candidate;
				placement = new Placement(a, b, turns, radius, arm * Tile, length * Tile, Math.Abs(Height(b) - Height(a)), length >= LongClimb);
			}
		}
		return result != null;
	}

	private bool Fillets(List<V> knots, V uphill, P a, P b, out List<P> stations, out P[] turns, out double minArm)
	{
		stations = null;
		minArm = double.PositiveInfinity;
		turns = new P[knots.Count - 2];
		var cut = new double[knots.Count];
		var signed = new double[knots.Count];
		var direction = new V[knots.Count - 1];
		double radius = (_radius + 0.25) / Tile;
		for (int j = 0; j < direction.Length; j++)
		{
			direction[j] = (knots[j + 1] - knots[j]).Normalized();
			if (Math.Abs(direction[j].Dot(uphill)) > 0.60) return false;
		}
		for (int j = 1; j < knots.Count - 1; j++)
		{
			signed[j] = direction[j - 1].AngleTo(direction[j]);
			if (Math.Abs(signed[j]) < Turn) return false;
			cut[j] = radius * Math.Tan(Math.Abs(signed[j]) / 2);
		}
		for (int j = 0; j < direction.Length; j++)
			minArm = Math.Min(minArm, knots[j].DistanceTo(knots[j + 1]) - cut[j] - cut[j + 1]);
		if (minArm < MinArm) return false;
		var points = new List<P> { a };
		double width = Math.Max(a.W, b.W);
		for (int j = 1; j < knots.Count - 1; j++)
		{
			V entry = knots[j] - direction[j - 1] * (float)cut[j];
			V center = entry - direction[j - 1].Orthogonal() * (float)(Math.Sign(signed[j]) * radius);
			V radial = entry - center;
			int steps = (int)Math.Ceiling(Math.Abs(signed[j]) * radius * Tile);
			for (int k = 0; k <= steps; k++)
			{
				double t = k / (double)steps;
				V at = center + radial.Rotated((float)(signed[j] * t));
				var p = new P(at.X, at.Y, width + 0.4 / Tile * Math.Sin(Math.PI * t));
				points.Add(p);
				if (k == steps / 2) turns[j - 1] = p;
			}
		}
		points.Add(b);
		stations = LineBuilder.Stations(points);
		return true;
	}

	private bool BlendSeams(List<P> axis, int lo, int hi, List<P> section, double arm, out List<P> shaped, out double remainingArm)
	{
		var start = BlendEnd(axis, lo, -1, section, 0, out int first, out double usedStart);
		var finish = BlendEnd(axis, hi, 1, section, section.Count - 1, out int last, out double usedEnd);
		remainingArm = arm - Math.Max(usedStart, usedEnd);
		shaped = null;
		if (remainingArm < MinArm || (start.Count == 0 && finish.Count == 0) || first >= last) return false;
		shaped = start;
		shaped.AddRange(section.GetRange(first, last - first + 1));
		finish.Reverse();
		shaped.AddRange(finish);
		return true;
	}

	private List<P> BlendEnd(List<P> axis, int anchor, int outside, List<P> section, int end, out int cut, out double used)
	{
		cut = end;
		used = 0;
		var blend = new List<P>();
		if (!LineBuilder.ChordPoint(axis, anchor, outside, 1, out double x, out double y)) return blend;
		int inside = -outside;
		P a = section[end];
		V start = At(a);
		V incoming = (start - V.Of(x, y)).Normalized();
		V straight = (At(section[end + inside]) - start).Normalized();
		double angle = Math.Abs(incoming.AngleTo(straight));
		if (angle < 0.015 || angle > Math.PI / 3) return blend;
		double reach = Math.Max(1.5, 5 * _radius / Tile * Math.Sin(angle));
		for (int j = end + inside; j >= 0 && j < section.Count; j += inside)
		{
			V delta = At(section[j]) - start;
			if (Math.Abs(delta.Cross(straight)) > 0.001) return blend;
			if (delta.Dot(straight) < reach) continue;
			cut = j;
			used = delta.Length();
			P b = section[j];
			V p1 = start + incoming * (float)(used / 3);
			V p2 = At(b) - straight * (float)(used / 3);
			int steps = (int)Math.Ceiling(used * Tile);
			blend.Add(a);
			for (int k = 1; k < steps; k++)
			{
				float t = k / (float)steps;
				V q0 = start.Lerp(p1, t), q1 = p1.Lerp(p2, t), q2 = p2.Lerp(At(b), t);
				V p = q0.Lerp(q1, t).Lerp(q1.Lerp(q2, t), t);
				blend.Add(new P(p.X, p.Y, a.W + (b.W - a.W) * t));
			}
			break;
		}
		return blend;
	}

	private bool Validate(List<P> axis, double[] along, int lo, int hi, List<P> section, double[] stations, List<P> rebuilt,
		out Refusal failure, out double radius)
	{
		radius = 0;
		failure = Refusal.Structure;
		for (int i = 1; i < section.Count; i++)
		{
			P a = section[i - 1], b = section[i];
			double width = Math.Max(a.W, b.W);
			V direction = (At(b) - At(a)).Normalized();
			V side = direction.Orthogonal() * (float)(width / 2);
			for (int k = 0; k <= 4; k++)
			{
				V p = At(a).Lerp(At(b), k * 0.25f);
				if (_blocked(p) || _blocked(p + side) || _blocked(p - side)) return false;
			}
			if (!_validator.Segment(a.X, a.Y, b.X, b.Y, width, _grade, _cross))
			{
				failure = !_validator.Segment(a.X, a.Y, b.X, b.Y, width, 1e6, 1e6) ? Refusal.Water :
					!_validator.Segment(a.X, a.Y, b.X, b.Y, width, _grade, 1e6) ? Refusal.Grade : Refusal.Crossfall;
				return false;
			}
		}
		int first = Math.Max(0, LowerBound(along, along[lo] - ProfileMargin) - 1);
		int last = LowerBound(along, along[hi] + ProfileMargin);
		var window = axis.GetRange(first, lo - first);
		window.AddRange(section);
		window.AddRange(axis.GetRange(hi + 1, last - hi));
		failure = Refusal.Profile;
		if (!_validator.Profile(Pack(window, dense: true), _grade)) return false;
		failure = Refusal.Radius;
		// Include a 4 m chord of the old line on both sides when checking each seam.
		first = Math.Max(0, LowerBound(along, along[lo] - 1) - 1);
		last = LowerBound(along, along[hi] + 1);
		window = axis.GetRange(first, lo - first);
		window.AddRange(section);
		window.AddRange(axis.GetRange(hi + 1, last - hi));
		radius = _validator.MinRadius(Pack(window));
		if (radius < _radius) return false;
		failure = Refusal.Clearance;
		var foreign = _foreign();
		for (int i = 0; i < section.Count; i++)
		{
			P point = section[i];
			if (i > 0 && !foreign.HasClearance(section[i - 1], point)) return false;
			// Avoid folding onto the unchanged portion of this same axis.
			double gap = point.W + 0.5;
			if (NearPart(point, rebuilt, 0, rebuilt.Count - 1, gap)) return false;
			if (stations[i] > 2 && NearPart(point, axis, 0, first, gap)) return false;
			if (stations[^1] - stations[i] > 2 && NearPart(point, axis, last, axis.Count - 1, gap)) return false;
		}
		return true;
	}

	private static bool NearPart(P p, List<P> axis, int lo, int hi, double gap)
	{
		V at = At(p);
		for (int j = lo + 1; j <= hi; j++)
			if (at.DistanceSquaredTo(LineBuilder.ClosestOnSegment(at, At(axis[j - 1]), At(axis[j]))) < gap * gap) return true;
		return false;
	}

	private bool Pinned(List<P> axis, byte[] pins, int i) => pins[i] != 0 || _blocked(At(axis[i]));
	private double Height(P p) => _validator.Ground(p.X, p.Y);
	private V Gradient(V p) => V.Of(_validator.Ground(p.X + 2, p.Y) - _validator.Ground(p.X - 2, p.Y),
		_validator.Ground(p.X, p.Y + 2) - _validator.Ground(p.X, p.Y - 2));
	private static V At(P p) => V.Of(p.X, p.Y);
	private static Refusal Later(Refusal a, Refusal b) => a > b ? a : b;
	private static int Nearest(List<P> points, P target)
	{
		int best = 0;
		double distance = double.PositiveInfinity;
		for (int i = 0; i < points.Count; i++)
		{
			double d = At(points[i]).DistanceSquaredTo(At(target));
			if (d < distance) { best = i; distance = d; }
		}
		return best;
	}
	private static double[] Along(List<P> points)
	{
		var along = new double[points.Count];
		for (int i = 1; i < points.Count; i++)
			along[i] = along[i - 1] + RoadGraph.Hypot(points[i].X - points[i - 1].X, points[i].Y - points[i - 1].Y);
		return along;
	}
	private static int LowerBound(double[] along, double distance)
	{
		int i = Array.BinarySearch(along, distance);
		return Math.Clamp(i < 0 ? ~i : i, 0, along.Length - 1);
	}
	private static double[] Pack(List<P> points, bool dense = false)
	{
		if (dense)
		{
			var samples = new List<double> { points[0].X, points[0].Y };
			for (int i = 1; i < points.Count; i++)
			{
				P a = points[i - 1], b = points[i];
				int steps = Math.Max(1, (int)Math.Ceiling(RoadGraph.Hypot(b.X - a.X, b.Y - a.Y) * 4));
				for (int k = 1; k <= steps; k++)
				{
					double t = k / (double)steps;
					samples.Add(a.X + (b.X - a.X) * t);
					samples.Add(a.Y + (b.Y - a.Y) * t);
				}
			}
			return samples.ToArray();
		}
		var packed = new double[points.Count * 2];
		for (int i = 0; i < points.Count; i++) { packed[2 * i] = points[i].X; packed[2 * i + 1] = points[i].Y; }
		return packed;
	}
}
