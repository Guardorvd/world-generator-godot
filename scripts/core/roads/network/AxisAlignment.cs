using System;
using System.Collections.Generic;
using P = Roads.Network.LineBuilder.P;
using V = Roads.Network.LineBuilder.V;

namespace Roads.Network;

/// <summary>Local changes to a published axis. Source stations also locate ride intervals after a splice.</summary>
internal sealed partial class AxisAlignment
{
	private const double Tile = 4.0;
	private const double Sample = 0.25; // Validate at one metre, as in the road profile.
	private readonly List<P> _source;
	private readonly double[] _along;
	private readonly bool[] _protected;
	private readonly GeometryValidator _validator;
	private readonly Func<V, bool> _blocked;
	private readonly double _grade, _cross;
	private readonly List<Splice> _splices = new();
	internal readonly Dictionary<string, int> Refused = new();
	internal readonly List<double> AcceptedRadii = new();
	internal int Accepted => _splices.Count;
	private record Splice(int First, int Last, List<P> Points);

	internal AxisAlignment(List<P> source, byte[] pins, GeometryValidator validator, Func<V, bool> blocked,
		double grade, double cross, double protection)
	{
		_source = source;
		_validator = validator;
		_blocked = blocked;
		_grade = grade;
		_cross = cross;
		_along = Stations(source);
		_protected = new bool[source.Count];
		for (int i = 0; i < source.Count; i++)
		{
			bool anchor = i == 0 || i == source.Count - 1 || pins[i] != 0 || blocked(At(source[i])) ||
				validator.NearAxis(source[i], RoadGraph.OnAxis);
			if (i > 0 && source[i - 1].W != source[i].W) anchor = _protected[i - 1] = true;
			if (!anchor) continue;
			for (int j = i; j >= 0 && _along[i] - _along[j] <= protection / Tile; j--) _protected[j] = true;
			for (int j = i + 1; j < source.Count && _along[j] - _along[i] <= protection / Tile; j++) _protected[j] = true;
		}
	}

	internal void FitArcs(double[] radii, double minAngle, double shoulder, double tolerance, double transition)
	{
		var knots = Knots(tolerance / Tile);
		for (int i = 1; i + 1 < knots.Count; i++)
		{
			int left = knots[i - 1], vertex = knots[i], right = knots[i + 1];
			if (_protected[vertex]) continue;
			V corner = At(_source[vertex]);
			V before = corner - At(_source[left]), after = At(_source[right]) - corner;
			if (Math.Min(before.Length(), after.Length()) * Tile < shoulder) continue;
			V incoming = before.Normalized(), outgoing = after.Normalized();
			double turn = incoming.AngleTo(outgoing);
			if (Math.Abs(turn) <= minAngle * Math.PI / 180.0) continue;
			foreach (double radiusMetres in radii)
			{
				double radius = radiusMetres / Tile;
				double trim = radius * Math.Tan(Math.Abs(turn) * 0.5);
				if (trim > 0.5 * Math.Min(before.Length(), after.Length())) { Reject("shoulder"); continue; }
				// The circle bisector passes R * (sec(turn/2) - 1) inside the corner.
				V start = corner - incoming * (float)trim, finish = corner + outgoing * (float)trim;
				int first = AtOrBefore(_along[vertex] - trim - transition / Tile);
				int last = AtOrBefore(_along[vertex] + trim + transition / Tile) + 1;
				if (first <= left || last >= right || (_splices.Count > 0 && first < _splices[^1].Last))
				{
					Reject("approach");
					continue;
				}
				V centre = start - incoming.Orthogonal() * (float)(Math.Sign(turn) * radius);
				double width = _source[vertex].W;
				var curve = new List<P> { _source[first] };
				AddTransition(curve, start, Direction(first, -1), incoming, width);
				int steps = Math.Max(2, (int)Math.Ceiling(Math.Abs(turn) * radius / Sample));
				for (int j = 1; j < steps; j++)
					curve.Add(Point(centre + (start - centre).Rotated((float)(turn * j / steps)), width));
				curve.Add(Point(finish, width));
				AddTransition(curve, At(_source[last]), outgoing, Direction(last, 1), width);
				curve[^1] = _source[last];
				if (!TrySplice(first, last, curve, radiusMetres)) continue;
				AcceptedRadii.Add(radiusMetres);
				break;
			}
		}
	}

	private List<int> Knots(double tolerance)
	{
		var knots = new List<int> { 0 };
		var pending = new Stack<(int First, int Last)>();
		for (int end = 1; end < _source.Count; end++)
		{
			if (!_protected[end]) continue;
			pending.Push((knots[^1], end));
			while (pending.TryPop(out var span))
			{
				V a = At(_source[span.First]), b = At(_source[span.Last]);
				double furthest = tolerance * tolerance;
				int split = -1;
				for (int k = span.First + 1; k < span.Last; k++)
				{
					V point = At(_source[k]);
					double distance = point.DistanceSquaredTo(LineBuilder.ClosestOnSegment(point, a, b));
					if (distance > furthest) { furthest = distance; split = k; }
				}
				if (split < 0) knots.Add(span.Last);
				else { pending.Push((split, span.Last)); pending.Push((span.First, split)); }
			}
		}
		return knots;
	}

	private V Direction(int i, int side) => (At(_source[i + side]) - At(_source[i])).Normalized() * side;

	private int AtOrBefore(double station)
	{
		int i = Array.BinarySearch(_along, station);
		return i >= 0 ? i : ~i - 1;
	}

	private static void AddTransition(List<P> points, V end, V incoming, V outgoing, double width)
	{
		V start = At(points[^1]);
		float arm = start.DistanceTo(end) / 3.0f;
		V p = start + incoming * arm, q = end - outgoing * arm;
		double lengthBound = 3.0 * Math.Max(arm, p.DistanceTo(q));
		int steps = Math.Max(2, (int)Math.Ceiling(lengthBound / Sample));
		for (int k = 1; k < steps; k++)
		{
			float t = (float)k / steps;
			V middle = p.Lerp(q, t);
			points.Add(Point(start.Lerp(p, t).Lerp(middle, t).Lerp(middle.Lerp(q.Lerp(end, t), t), t), width));
		}
		points.Add(Point(end, width));
	}

	private bool Reject(string reason)
	{
		Refused[reason] = Refused.GetValueOrDefault(reason) + 1;
		return false;
	}

	private bool TrySplice(int first, int last, List<P> curve, double targetRadius)
	{
		// Check the published chords at the same spacing as RoadLine. Keep the
		// dense curve for the profile so short variations are checked as well.
		var points = PublishedStations(curve);
		for (int i = 1; i < points.Count; i++)
		{
			P a = points[i - 1], b = points[i];
			V normal = (At(b) - At(a)).Normalized().Orthogonal() * (float)(a.W * 0.5);
			V middle = At(a).Lerp(At(b), 0.5f);
			if (_blocked(At(b)) || _blocked(middle) || _blocked(middle + normal) || _blocked(middle - normal))
				return Reject("structure");
			string issue = _validator.SegmentRefusal(a, b, _grade, _cross);
			if (issue != null) return Reject(issue);
			if (!_validator.HasClearance(a, b)) return Reject("clearance");
		}
		int from = first, to = last;
		while (from > 0 && (_along[first] - _along[from]) * Tile < _validator.ProfileWindowMetres) from--;
		while (to + 1 < _source.Count && (_along[to] - _along[last]) * Tile < _validator.ProfileWindowMetres) to++;
		var before = _source.GetRange(from, to - from + 1);
		var context = Context(points);
		double[] shaped = Pack(context);
		if (!_validator.Profile(Pack(Context(curve)), _grade) || !_validator.Profile(shaped, _grade)) return Reject("profile");
		double radius = Math.Min(_validator.MinRadius(Pack(before)), targetRadius);
		if (_validator.MinRadius(shaped) + 0.1 < Math.Max(points[0].W * Tile * 0.5 + 0.5, radius))
			return Reject("seam");
		var splice = new Splice(first, last, points);
		if (!_validator.KeepsCrossings(before, context) || !_validator.KeepsCrossings(_source, Assemble(splice).Points))
			return Reject("double_cross");
		_splices.Add(splice);
		return true;

		List<P> Context(List<P> part)
		{
			var context = _source.GetRange(from, first - from);
			context.AddRange(part);
			for (int j = last + 1; j <= to; j++) context.Add(_source[j]);
			return context;
		}
	}

	private static List<P> PublishedStations(List<P> curve)
	{
		double[] along = Stations(curve);
		int count = (int)Math.Ceiling(along[^1] * Tile / LineBuilder.StationSpacingMetres);
		var result = new List<P>(count + 1) { curve[0] };
		int next = 1;
		for (int i = 1; i < count; i++)
		{
			double station = along[^1] * i / count;
			while (along[next] < station) next++;
			double t = (station - along[next - 1]) / (along[next] - along[next - 1]);
			P a = curve[next - 1], b = curve[next];
			result.Add(new P(a.X + t * (b.X - a.X), a.Y + t * (b.Y - a.Y), a.W + t * (b.W - a.W)));
		}
		result.Add(curve[^1]);
		return result;
	}

	internal (List<P> Points, double[] FromMetres, double[] ToMetres) Finish()
	{
		var (points, from) = Assemble(null);
		for (int i = 0; i < from.Count; i++) from[i] *= Tile;
		double[] to = Stations(points);
		for (int i = 0; i < to.Length; i++) to[i] *= Tile;
		return (points, from.ToArray(), to);
	}

	private (List<P> Points, List<double> SourceStations) Assemble(Splice extra)
	{
		var result = new List<P>(_source.Count);
		var stations = new List<double>(_source.Count);
		int next = 0;
		void Append(Splice span)
		{
			while (next < span.First) { result.Add(_source[next]); stations.Add(_along[next++]); }
			double[] local = Stations(span.Points);
			for (int i = 0; i < span.Points.Count; i++)
			{
				if (next > span.First && i == 0) continue;
				result.Add(span.Points[i]);
				stations.Add(_along[span.First] + (_along[span.Last] - _along[span.First]) * (local[i] / local[^1]));
			}
			next = span.Last + 1;
		}
		foreach (Splice span in _splices) Append(span);
		if (extra != null) Append(extra);
		while (next < _source.Count) { result.Add(_source[next]); stations.Add(_along[next++]); }
		return (result, stations);
	}

	private static double[] Stations(List<P> points)
	{
		var result = new double[points.Count];
		for (int i = 1; i < points.Count; i++) result[i] = result[i - 1] + At(points[i - 1]).DistanceTo(At(points[i]));
		return result;
	}

	private static double[] Pack(List<P> points)
	{
		var result = new double[points.Count * 2];
		for (int i = 0; i < points.Count; i++) { result[2 * i] = points[i].X; result[2 * i + 1] = points[i].Y; }
		return result;
	}

	private static V At(P p) => V.Of(p.X, p.Y);
	private static P Point(V point, double width) => new(point.X, point.Y, width);
}
