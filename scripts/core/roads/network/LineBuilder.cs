using System;
using System.Collections.Generic;

namespace Roads.Network;

/// <summary>Фаза 3.1 плана V2: порт RoadLine.build (scripts/world/road_line.gd) один к одному. Арифметика повторяет
/// GDScript: векторы Vector2 — float32 (операции движка: normalized, angle_to, lerp, distance_to, rotated,
/// Geometry2D.get_closest_point_to_segment), скаляры и словари точек — double. Проверки участка и воды — FastGrid.RoadSegment
/// (= RoadLine.segment_ok с probe), земля профиля — FastGrid.GroundAt (= Heightfield.ground_at без сооружений).
/// Сверка с GDScript — tools/road_v2_test.gd (точки до 1e-6 клетки). Коридор областей (Callable) здесь не поддерживается:
/// с ним StageTrails зовёт GDScript.</summary>
public sealed class LineBuilder
{
	// ---- float32-вектор с арифметикой движка (core/math/vector2.h)
	public readonly struct V
	{
		public readonly float X, Y;
		public V(float x, float y) { X = x; Y = y; }
		public static V operator +(V a, V b) => new(a.X + b.X, a.Y + b.Y);
		public static V operator -(V a, V b) => new(a.X - b.X, a.Y - b.Y);
		public static V operator -(V a) => new(-a.X, -a.Y);
		public static V operator *(V a, float s) => new(a.X * s, a.Y * s);
		public static V operator *(float s, V a) => new(a.X * s, a.Y * s);
		public static V operator /(V a, float s) => new(a.X / s, a.Y / s);
		public float Dot(V b) => X * b.X + Y * b.Y;
		public float Cross(V b) => X * b.Y - Y * b.X;
		public float Length() => MathF.Sqrt(X * X + Y * Y);
		public float DistanceTo(V b) => MathF.Sqrt((X - b.X) * (X - b.X) + (Y - b.Y) * (Y - b.Y));
		public float DistanceSquaredTo(V b) => (X - b.X) * (X - b.X) + (Y - b.Y) * (Y - b.Y);
		public V Normalized()
		{
			float l = X * X + Y * Y;
			if (l == 0f) return new V(0f, 0f);
			l = MathF.Sqrt(l);
			return new V(X / l, Y / l);
		}
		public float AngleTo(V b) => MathF.Atan2(Cross(b), Dot(b));
		public V Lerp(V to, float t) => new(X + (to.X - X) * t, Y + (to.Y - Y) * t);
		public V Orthogonal() => new(Y, -X);
		public V Rotated(float by)
		{
			float sine = MathF.Sin(by), cosi = MathF.Cos(by);
			return new V(X * cosi - Y * sine, X * sine + Y * cosi);
		}
		public static V Of(double x, double y) => new((float)x, (float)y);
	}

	public static V ClosestOnSegment(V p, V a, V b)
	{
		V q = p - a;
		V n = b - a;
		float l2 = n.X * n.X + n.Y * n.Y;
		if (l2 < 1e-20f) return a;
		float d = n.Dot(q) / l2;
		if (d <= 0.0f) return a;
		if (d >= 1.0f) return b;
		return a + n * d;
	}

	public struct P
	{
		public double X, Y, W;
		public P(double x, double y, double w) { X = x; Y = y; W = w; }
	}

	// ---- числа road_line.gd и StageTrails
	private const double TurnCorridor = 0.65;
	private const double Tile = 4.0, Gravity = 16.0, ProfileBase = 3.0;
	private const int StraightSpan = 10;
	private static readonly V[] TurnTrims =
	{
		new(1f, 1f), new(1f, 0.72f), new(0.72f, 1f), new(0.72f, 0.72f), new(0.52f, 0.72f), new(0.72f, 0.52f),
		new(0.52f, 0.52f), new(0.38f, 0.52f), new(0.52f, 0.38f), new(0.38f, 0.38f),
	};
	private static readonly float[][] GroupTrims = { new[] { 1f, 1f, 1f, 1f }, new[] { 0.72f, 1f, 1f, 1f }, new[] { 1f, 0.72f, 1f, 1f }, new[] { 0.72f, 0.72f, 1f, 1f } };
	private static readonly float[] GroupLong = { 1f, 1f, 1.25f, 1.25f };
	private static readonly float[][] GroupRetries = { new[] { 1f, 1f, 1.30f, 1f }, new[] { 1f, 1f, 1f, 1.30f } };

	private readonly FastGrid _probe;
	private readonly byte[] _axis;
	private readonly int _w, _h;
	// правила вида (rules в _build_with)
	private double _grade, _cross, _speed, _accel, _relax;
	private bool _longS, _mountain;
	private List<P> _raw;
	private List<byte> _rawPinned;
	public bool Fallback;

	public LineBuilder(FastGrid probe, byte[] axis, int w, int h)
	{
		_probe = probe ?? throw new ArgumentException("LineBuilder: нет земли и воды (fast_water)");
		_axis = axis ?? Array.Empty<byte>();
		_w = w; _h = h;
	}

	/// <summary>Math::deg_to_rad движка: p_y * (Math_PI / 180.0).</summary>
	private static double Deg(double d) => d * (Math.PI / 180.0);

	private static double DesignGrade(string design, double road, double trail, double mountain) =>
		design == "mountain" ? mountain : design == "trail" ? trail : road;

	/// <summary>RoadLine.build: pts — точки поиска, kind/smooth — вид, joins — касательные хозяина у концов (null — нет),
	/// relax — поблажка line_relax вида, tolerance — straighten вида, пределы — StageTrails.</summary>
	public List<P> Build(List<P> pts, string kind, string smooth, V? join0, V? join1, double relax, double tolerance,
		double roadLimit, double trailGrade, double mountainGrade, double benchCross, double speed, double accel)
	{
		Fallback = false;
		if (relax <= 1.0 || pts.Count < 3)
			return BuildWith(pts, kind, smooth, join0, join1, 0.0, tolerance, roadLimit, trailGrade, mountainGrade, benchCross, speed, accel);
		var line = BuildWith(pts, kind, smooth, join0, join1, relax, tolerance, roadLimit, trailGrade, mountainGrade, benchCross, speed, accel);
		string design = smooth.Length == 0 ? kind : smooth;
		double grade = DesignGrade(design, roadLimit, trailGrade, mountainGrade);
		var profile = new V[line.Count];
		var skip = new byte[line.Count];
		for (int k = 0; k < line.Count; k++)
		{
			profile[k] = V.Of(line[k].X, line[k].Y);
			skip[k] = (byte)(AxisBlocked(profile[k]) ? 1 : 0);
		}
		if (ProfileOk(profile, grade, skip)) return line;
		Fallback = true;
		return BuildWith(pts, kind, smooth, join0, join1, 0.0, tolerance, roadLimit, trailGrade, mountainGrade, benchCross, speed, accel);
	}

	private List<P> BuildWith(List<P> pts, string kind, string smooth, V? join0, V? join1, double relax, double tolerance,
		double roadLimit, double trailGrade, double mountainGrade, double benchCross, double speed, double accel)
	{
		if (pts.Count < 2) { _raw = pts; _rawPinned = null; return pts; }
		var fixedv = new byte[pts.Count];
		if (_axis.Length > 0)
			for (int k = 0; k < pts.Count; k++)
				if (AxisBlocked(V.Of(pts[k].X, pts[k].Y)))
					for (int j = Math.Max(0, k - 2); j < Math.Min(pts.Count, k + 3); j++) fixedv[j] = 1;
		string design = smooth.Length == 0 ? kind : smooth;
		_mountain = design == "mountain";
		_grade = DesignGrade(design, roadLimit, trailGrade, mountainGrade);
		_cross = design == "mountain" ? mountainGrade : benchCross;
		_speed = speed;
		_accel = accel;
		_longS = kind == "road";
		_relax = relax;
		if (tolerance > 0.0 && pts.Count > 2)
		{
			var (pulled, pulledFixed) = Straighten(pts, fixedv, tolerance);
			pts = pulled;
			fixedv = pulledFixed;
		}
		var bends = new List<P> { pts[0] };
		var pins = new List<byte> { fixedv[0] };
		for (int k = 1; k < pts.Count - 1; k++)
		{
			V a = V.Of(pts[k - 1].X, pts[k - 1].Y), b = V.Of(pts[k].X, pts[k].Y), c = V.Of(pts[k + 1].X, pts[k + 1].Y);
			if (fixedv[k] != 0 || pts[k].W != pts[k - 1].W || pts[k].W != pts[k + 1].W
				|| Math.Abs((double)(b - a).Normalized().AngleTo((c - b).Normalized())) > 0.001)
			{
				bends.Add(pts[k]);
				pins.Add(fixedv[k]);
			}
		}
		bends.Add(pts[^1]);
		pins.Add(fixedv[^1]);
		var start = pins[0] == 0 ? Approach(bends[0], bends[1], join0) : null;
		var finish = pins[^1] == 0 ? Approach(bends[^1], bends[^2], join1) : null;
		List<P> outp;
		List<byte> outPinned;
		if (start == null)
		{
			outp = new List<P> { bends[0] };
			outPinned = new List<byte> { 1 };
		}
		else
		{
			outp = start;
			outPinned = new List<byte>(start.Count);
			for (int k = 0; k < start.Count; k++) outPinned.Add((byte)(k == 0 ? 1 : 0));
		}
		int i = 1;
		while (i < bends.Count - 1)
		{
			List<P> curve = null;
			if (pins[i] == 0 && bends[i - 1].W == bends[i].W && bends[i + 1].W == bends[i].W)
			{
				V a = V.Of(bends[i - 1].X, bends[i - 1].Y), b = V.Of(bends[i].X, bends[i].Y), c = V.Of(bends[i + 1].X, bends[i + 1].Y);
				int last = i;
				while (last + 2 < bends.Count && last < i + 3 && pins[last + 1] == 0 && bends[last + 2].W == bends[i].W)
				{
					V next = V.Of(bends[last + 1].X, bends[last + 1].Y), prev = V.Of(bends[last].X, bends[last].Y);
					if ((double)next.DistanceTo(prev) > 2.5) break;
					last++;
				}
				int consumed = 0;
				List<V> pair = null;
				for (int end = last; end > i; end--)
				{
					var path = new List<V>();
					for (int j = i - 1; j < end + 2; j++) path.Add(V.Of(bends[j].X, bends[j].Y));
					curve = BendGroup(path, bends[i].W, false);
					if (curve != null) { consumed = end - i + 1; break; }
					if (end == i + 1) pair = path;
				}
				if (consumed == 0 && kind == "road" && pair != null && (double)b.DistanceSquaredTo(c) <= 2.25)
				{
					curve = BendGroup(pair, bends[i].W, true);
					if (curve != null) consumed = 2;
				}
				if (consumed > 0)
				{
					outp.AddRange(curve);
					for (int k = 0; k < curve.Count; k++) outPinned.Add(0);
					i += consumed;
					continue;
				}
				curve = Bend(a, b, c, bends[i].W);
			}
			if (curve == null)
			{
				outp.Add(bends[i]);
				outPinned.Add((byte)(pins[i] != 0 || bends[i].W != bends[i - 1].W || bends[i].W != bends[i + 1].W ? 1 : 0));
			}
			else
			{
				outp.AddRange(curve);
				for (int k = 0; k < curve.Count; k++) outPinned.Add(0);
			}
			i++;
		}
		if (finish == null)
		{
			outp.Add(bends[^1]);
			outPinned.Add(1);
		}
		else
		{
			finish.Reverse();
			outp.AddRange(finish);
			for (int k = 0; k < finish.Count; k++) outPinned.Add((byte)(k == finish.Count - 1 ? 1 : 0));
		}
		_raw = outp;
		_rawPinned = outPinned;
		return Stations(outp);
	}

	public (List<P>, byte[]) Straighten(List<P> pts, byte[] fixedv, double tolerance)
	{
		int n = pts.Count;
		var outp = new List<P> { pts[0] };
		var outFixed = new List<byte> { fixedv[0] };
		int i = 0;
		while (i < n - 1)
		{
			int best = i + 1;
			if (fixedv[i] == 0)
			{
				int j = Math.Min(n - 1, i + StraightSpan);
				while (j > i + 1)
				{
					if (ChordOk(pts, fixedv, i, j, tolerance)) { best = j; break; }
					j--;
				}
			}
			outp.Add(pts[best]);
			outFixed.Add(fixedv[best]);
			i = best;
		}
		return (outp, outFixed.ToArray());
	}

	private bool ChordOk(List<P> pts, byte[] fixedv, int i, int j, double tolerance)
	{
		V a = V.Of(pts[i].X, pts[i].Y), b = V.Of(pts[j].X, pts[j].Y);
		if (pts[j].W != pts[i].W) return false;
		for (int k = i + 1; k < j; k++)
		{
			if (fixedv[k] != 0 || pts[k].W != pts[i].W) return false;
			V p = V.Of(pts[k].X, pts[k].Y);
			if ((double)p.DistanceSquaredTo(ClosestOnSegment(p, a, b)) > tolerance * tolerance) return false;
		}
		double length = a.DistanceTo(b);
		if (length < 0.001) return false;
		V normal = (b - a).Orthogonal() * (float)(pts[i].W * 0.5 / length);
		int samples = (int)Math.Ceiling(length / 0.25);
		for (int k = 0; k <= samples; k++)
		{
			V p = a.Lerp(b, (float)((double)k / samples));
			foreach (float side in Sides)
				if (AxisBlocked(p + normal * side)) return false;
		}
		if (_relax <= 1.0) return SegmentOk(pts[i], pts[j], _grade, _cross);
		if (!SegmentOk(pts[i], pts[j], _grade * _relax, _cross)) return false;
		var profile = new V[samples + 1];
		for (int k = 0; k <= samples; k++) profile[k] = a.Lerp(b, (float)((double)k / samples));
		return ProfileOk(profile, _grade, null);
	}

	private static readonly float[] Sides = { -1f, 0f, 1f };

	/// <summary>RoadLine.stations: вершины сохраняются, длинные прямые делятся по 2 м (double).</summary>
	public static List<P> Stations(List<P> points)
	{
		var outp = new List<P> { points[0] };
		for (int k = 1; k < points.Count; k++)
		{
			P a = points[k - 1], b = points[k];
			double dx = b.X - a.X, dy = b.Y - a.Y;
			double length = Math.Sqrt(dx * dx + dy * dy) * Tile;
			int steps = (int)Math.Ceiling(length / 2.0);
			for (int j = 1; j < steps; j++)
			{
				double t = (double)j / steps;
				outp.Add(new P(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t, a.W + (b.W - a.W) * t));
			}
			outp.Add(b);
		}
		return outp;
	}

	public bool AxisBlocked(V p)
	{
		int x = (int)Math.Floor((double)p.X), y = (int)Math.Floor((double)p.Y);
		return x < 0 || y < 0 || x >= _w || y >= _h || (_axis.Length > 0 && _axis[y * _w + x] != 0);
	}

	private List<P> BendGroup(List<V> path, double width, bool retry)
	{
		V a = path[0], b = path[1], c = path[^2], d = path[^1];
		V incoming = (b - a).Normalized(), outgoing = (d - c).Normalized(), axis = (d - a).Normalized();
		double angle = Math.Abs((double)incoming.AngleTo(outgoing));
		if (angle > Math.PI * 0.75) return null;
		for (int j = 1; j < path.Count; j++)
		{
			V direction = (path[j] - path[j - 1]).Normalized();
			if ((double)axis.Dot(direction) < 0.25) return null;
		}
		double speed = _speed * (angle >= Deg(105.0) ? 0.62 : 1.0);
		double handle = 3.0 * Math.Pow(Math.Cos(angle * 0.25), 2.0);
		double left = Math.Min((double)a.DistanceTo(b) * 0.49, 3.5);
		double right = Math.Min((double)c.DistanceTo(d) * 0.49, 3.5);
		bool shortS = false;
		if (_longS && path.Count == 4 && (double)b.DistanceSquaredTo(c) <= 2.25)
		{
			V middle = (c - b).Normalized();
			double first = incoming.Cross(middle), second = middle.Cross(outgoing);
			shortS = first * second < 0.0 && Math.Min(Math.Abs(first), Math.Abs(second)) >= 0.65;
		}
		bool parallel = (double)incoming.Dot(outgoing) >= 0.99;
		var attempts = new List<float[]>(GroupTrims);
		if (retry)
		{
			if (!shortS) return null;
			attempts = parallel ? new List<float[]>(GroupRetries) : new List<float[]> { GroupLong, GroupRetries[0], GroupRetries[1] };
		}
		else if (shortS && parallel) attempts.Add(GroupLong);
		foreach (var trim in attempts)
		{
			V p = b - incoming * (float)left * trim[0];
			V q = c + outgoing * (float)right * trim[1];
			double lead = (double)p.DistanceTo(q) / handle;
			var curve = FitCurve(new[] { p, p + incoming * (float)(lead * trim[2]), q - outgoing * (float)(lead * trim[3]), q }, path, width, speed);
			if (curve != null) return curve;
		}
		return null;
	}

	private List<P> Bend(V a, V b, V c, double width)
	{
		V incoming = (b - a).Normalized(), outgoing = (c - b).Normalized();
		double angle = Math.Abs((double)incoming.AngleTo(outgoing));
		if (angle < 0.04 || angle > Math.PI - 0.04) return null;
		bool hairpin = angle >= Deg(105.0);
		double speed = _speed * (hairpin ? 0.62 : 1.0);
		double left = Math.Min((double)a.DistanceTo(b) * 0.49, 3.0);
		double right = Math.Min((double)b.DistanceTo(c) * 0.49, 3.0);
		double handle = 4.0 / 3.0 * Math.Tan(angle * 0.25) / Math.Tan(angle * 0.5);
		var corridor = new List<V> { a, b, c };
		foreach (double factor in new[] { 1.0, 0.72, 0.55 })
			foreach (V trim in TurnTrims)
			{
				double l = left * trim.X, r = right * trim.Y;
				V p = b - incoming * (float)l;
				V q = b + outgoing * (float)r;
				var curve = FitCurve(new[] { p, p + incoming * (float)l * (float)handle, q - outgoing * (float)r * (float)handle, q }, corridor, width, speed * factor);
				if (curve != null) return curve;
			}
		return null;
	}

	private List<P> Approach(P end, P next, V? join)
	{
		if (join == null || end.W != next.W) return null;
		V a = V.Of(end.X, end.Y), b = V.Of(next.X, next.Y);
		V direction = (b - a).Normalized();
		V host = join.Value;
		double side = Math.Sign((double)host.Cross(direction));
		if (side == 0.0) return null;
		if ((double)host.Dot(direction) < 0.0) { host = -host; side = -side; }
		double angle = Math.Abs((double)host.AngleTo(direction));
		double target = angle < Deg(30.0) ? Deg(30.0) : angle;
		if (angle >= Deg(60.0)) target = Math.PI * 0.5;
		if (Math.Abs(target - angle) < 0.04) return null;
		V heading = host.Rotated((float)(side * target));
		var corridor = new List<V> { a, b };
		foreach (double scale in new[] { 1.0, 0.8, 0.6 })
		{
			double lead = Math.Min((double)a.DistanceTo(b) * 0.49, 3.0) * scale;
			V q = a + direction * (float)lead;
			var curve = FitCurve(new[] { a, a + heading * (float)lead / 3.0f, q - direction * (float)lead / 3.0f, q }, corridor, end.W, _speed * 0.72);
			if (curve != null)
			{
				curve[0] = end;
				return curve;
			}
		}
		return null;
	}

	public List<P> FitCurve(V[] control, List<V> corridor, double width, double speed)
	{
		V a = control[0], b = control[1], c = control[2], d = control[3];
		int steps = Math.Max(8, (int)Math.Ceiling(((double)a.DistanceTo(b) + b.DistanceTo(c) + c.DistanceTo(d)) / 0.25));
		var curve = new List<P>(steps + 1);
		double grade = _grade;
		for (int k = 0; k <= steps; k++)
		{
			float t = (float)((double)k / steps);
			V ab = a.Lerp(b, t), bc = b.Lerp(c, t), cd = c.Lerp(d, t);
			V left = ab.Lerp(bc, t), right = bc.Lerp(cd, t);
			V p = left.Lerp(right, t);
			V tangent = (right - left) * 3.0f;
			V second = (cd - 2.0f * bc + ab) * 6.0f;
			double length = tangent.Length();
			if (length < 0.001) return null;
			double curvature = Math.Abs((double)tangent.Cross(second)) / (length * length * length * Tile);
			double lateral = speed * speed * curvature;
			double brakeSq = _accel * _accel - lateral * lateral;
			if (brakeSq <= 0.0 || curvature * (width * Tile * 0.5 + 0.15) >= 1.0) return null;
			grade = Math.Min(grade, Math.Sqrt(brakeSq) / Gravity);
			double deviation = double.PositiveInfinity;
			for (int j = 1; j < corridor.Count; j++)
				deviation = Math.Min(deviation, p.DistanceSquaredTo(ClosestOnSegment(p, corridor[j - 1], corridor[j])));
			if (deviation > TurnCorridor * TurnCorridor) return null;
			V normal = tangent.Orthogonal() * (float)(width * 0.5 / length);
			foreach (float side in Sides)
				if (AxisBlocked(p + normal * side)) return null;
			curve.Add(new P(p.X, p.Y, width));
		}
		double local = _relax > 1.0 ? grade * _relax : grade;
		for (int k = 1; k < curve.Count; k++)
			if (!SegmentOk(curve[k - 1], curve[k], local, _cross)) return null;
		if (_relax > 1.0)
		{
			var profile = new V[curve.Count];
			for (int k = 0; k < curve.Count; k++) profile[k] = V.Of(curve[k].X, curve[k].Y);
			if (!ProfileOk(profile, grade, null)) return null;
		}
		return curve;
	}

	// ---- фаза 3.4: сглаживание по прорежённой линии (~4 м) с Якоби-проходами, монотонной защитой угла и 2-м профилем
	public const double SmoothSpacing = 0.98;       // шаг прореживания до Stations(), клеток (~3,92 м)
	public const double AxisPinCells = 2.0;         // закрепление вокруг осей сооружений, клеток (8 м)
	public const int BiharmonicPasses = 10;
	public const double BiharmonicStep = 0.375;
	public const int KinkLaplacianPasses = 4;
	public const double KinkLaplacianAngle = 34.0;  // град.: прицельный Лаплас на изломах > 34°
	public const double SmoothStep = 0.45;
	public const double MoveEpsSq = 1e-4;           // порог «нечего двигать», кл²
	public const double RoundAngle = 18.0;          // град.: скругление вершин > 18° перед Stations()
	private static readonly double[] RoundFractions = { 0.34, 0.22, 0.14, 0.08 };
	private static readonly double[] MountainRoundFractions = { 0.14, 0.08 };
	public int SmoothMoved, SmoothRejected, Hairpins, HairpinsMoved;
	public readonly record struct WideBendTuning(double RadiusM, double ShiftM, double MinDegrees, double MaxDegrees);
	public WideBendTuning WideBend;
	public int WideBends;
	/// <summary>Фаза 3.3+: сглаживание с бигармоническим членом Δ⁴.</summary>
	public bool Biharmonic = true;

	/// <summary>Сглаживание по прорежённой линии (~4 м) до Stations(): ресэмпл свободных участков с локальным возвратом _raw
	/// при редком нарушении 2-м профиля, одновременные Δ⁴-проходы и прицельный Лаплас с откатом по очереди зависимостей,
	/// монотонная защита наибольшего угла на хордах 4 м в [i−3, i+3], 2-м профиль в окне и скругление вершин > 18°.</summary>
	public List<P> Smooth(List<P> line, GeometryValidator validator)
	{
		SmoothMoved = SmoothRejected = Hairpins = HairpinsMoved = 0;
		if (_raw == null || _raw.Count < 3 || _rawPinned == null || _rawPinned.Count != _raw.Count)
			return line;
		int m = _raw.Count;
		var rawPin = new byte[m];
		for (int k = 0; k < m; k++) rawPin[k] = _rawPinned[k];
		rawPin[0] = rawPin[m - 1] = 1;
		var rawS = new double[m];
		for (int k = 1; k < m; k++)
		{
			double dx = _raw[k].X - _raw[k - 1].X, dy = _raw[k].Y - _raw[k - 1].Y;
			rawS[k] = rawS[k - 1] + Math.Sqrt(dx * dx + dy * dy);
			if (_raw[k].W != _raw[k - 1].W) { rawPin[k] = 1; rawPin[k - 1] = 1; }
		}
		if (_axis.Length > 0)
		{
			for (int k = 0; k < m; k++)
				if (AxisBlocked(V.Of(_raw[k].X, _raw[k].Y)))
					PinAxisSpan(rawS, rawPin, k, m);
		}
		double local = _relax > 1.0 ? _grade * _relax : _grade;
		if (_mountain)
		{
			var mPts = new List<P>(_raw);
			var mHardPin = new bool[m];
			var mBlock = new byte[m];
			for (int k = 0; k < m; k++)
			{
				mHardPin[k] = rawPin[k] != 0;
				if (AxisBlocked(V.Of(mPts[k].X, mPts[k].Y)))
				{
					mBlock[k] = 1;
					for (int j = k; j >= 0 && rawS[k] - rawS[j] <= AxisPinCells + 1e-6; j--) mHardPin[j] = true;
					for (int j = k; j < m && rawS[j] - rawS[k] <= AxisPinCells + 1e-6; j++) mHardPin[j] = true;
				}
			}
			var mRounded = RoundBends(mPts, _raw, mHardPin, mBlock, validator, local);
			var mRes = Stations(mRounded);
			if (WholeProfileOk(line, _grade) && !WholeProfileOk(mRes, _grade))
				return line;
			return validator.KeepsCrossings(line, mRes) ? mRes : line;
		}
		var pts = new List<P>(m * 2);
		var pinList = new List<byte>(m * 2);
		var ptsRawS = new List<double>(m * 2);
		int a = 0;
		while (a < m - 1)
		{
			int b = a + 1;
			while (b < m - 1 && rawPin[b] == 0) b++;
			double spanLen = rawS[b] - rawS[a];
			if (b == a + 1 || spanLen < 1e-6)
			{
				pts.Add(_raw[a]);
				pinList.Add(1);
				ptsRawS.Add(rawS[a]);
			}
			else
			{
				int segs = Math.Max(1, (int)Math.Ceiling(spanLen / SmoothSpacing));
				var ts = new List<double>(segs + 4);
				for (int k = 0; k <= segs; k++) ts.Add(spanLen * k / segs);
				int idx = 0;
				while (idx < ts.Count - 1)
				{
					double s0 = ts[idx], s1 = ts[idx + 1];
					P p0 = SampleSpan(_raw, rawS, a, b, s0);
					P p1 = SampleSpan(_raw, rawS, a, b, s1);
					P mid = new((p0.X + p1.X) * 0.5, (p0.Y + p1.Y) * 0.5, p0.W);
					bool ok = validator.Segment(p0.X, p0.Y, p1.X, p1.Y, p0.W, local, _cross);
					if (s1 - s0 > 0.35 && (!ok || AxisBlocked(V.Of(mid.X, mid.Y)) ||
						!validator.KeepsClearance(SampleSpan(_raw, rawS, a, b, (s0 + s1) * 0.5), mid, _raw[0], _raw[^1])))
					{
						ts.Insert(idx + 1, 0.5 * (s0 + s1));
						continue;
					}
					pts.Add(p0);
					pinList.Add((byte)(idx == 0 ? 1 : 0));
					ptsRawS.Add(rawS[a] + s0);
					idx++;
				}
			}
			a = b;
		}
		pts.Add(_raw[m - 1]);
		pinList.Add(1);
		ptsRawS.Add(rawS[m - 1]);
		bool baseWholeOk = WholeProfileOk(line, _grade);
		if (baseWholeOk)
			EnsureInitialProfile(_raw, rawS, rawPin, pts, pinList, ptsRawS, _grade);
		int n = pts.Count;
		if (n < 3) return line;
		var pinned = new bool[n];
		var hardPinned = new bool[n];
		var ptsS = new double[n];
		for (int k = 0; k < n; k++)
		{
			pinned[k] = pinList[k] != 0;
			hardPinned[k] = pinList[k] == 1;
			if (k > 0)
			{
				double dx = pts[k].X - pts[k - 1].X, dy = pts[k].Y - pts[k - 1].Y;
				ptsS[k] = ptsS[k - 1] + Math.Sqrt(dx * dx + dy * dy);
				if (pts[k].W != pts[k - 1].W)
				{
					pinned[k] = true; pinned[k - 1] = true;
					hardPinned[k] = true; hardPinned[k - 1] = true;
				}
			}
		}
		var heights = new double[n];
		var blocked = new byte[n];
		for (int k = 0; k < n; k++)
		{
			heights[k] = _probe.GroundAt(pts[k].X * Tile, pts[k].Y * Tile);
			if (AxisBlocked(V.Of(pts[k].X, pts[k].Y)))
			{
				blocked[k] = 1;
				for (int j = k; j >= 0 && ptsS[k] - ptsS[j] <= AxisPinCells + 1e-6; j--) { pinned[j] = true; hardPinned[j] = true; }
				for (int j = k; j < n && ptsS[j] - ptsS[k] <= AxisPinCells + 1e-6; j++) { pinned[j] = true; hardPinned[j] = true; }
			}
		}
		var midHeights = new double[n - 1];
		var midBlocked = new byte[n - 1];
		var segBad = new byte[n - 1];
		for (int k = 0; k < n - 1; k++)
			UpdateSeg(pts, midHeights, midBlocked, segBad, k, validator, local);
		var orig = new List<P>(pts);
		// буферы Якоби-проходов — одно выделение на линию
		var prev = new P[n];
		var prevH = new double[n];
		var prevMidH = new double[n - 1];
		var prevMidB = new byte[n - 1];
		var newSegBad = new byte[n - 1];
		var prevAng = new double[n];
		var prevWinMax = new double[n];
		var curAng = new double[n];
		var moved = new bool[n];
		var prevProfOk = new sbyte[n];
		var prevRadOk = new sbyte[n];
		var inQueue = new bool[n];
		var qBuf = new int[n + 1];
		var active = new bool[n];

		if (Biharmonic)
		{
			for (int pass = 0; pass < BiharmonicPasses; pass++)
			{
				int movedPass = RunJacobiPass(pts, orig, pinned, null, heights, midHeights, blocked, midBlocked, segBad,
					prev, prevH, prevMidH, prevMidB, newSegBad, prevAng, prevWinMax, curAng, moved, prevProfOk, prevRadOk, inQueue, qBuf,
					true, BiharmonicStep, validator, local);
				if (movedPass == 0) break;
			}
		}
		else
		{
			for (int pass = 0; pass < 4; pass++)
			{
				int movedPass = RunJacobiPass(pts, orig, pinned, null, heights, midHeights, blocked, midBlocked, segBad,
					prev, prevH, prevMidH, prevMidB, newSegBad, prevAng, prevWinMax, curAng, moved, prevProfOk, prevRadOk, inQueue, qBuf,
					false, SmoothStep, validator, local);
				if (movedPass == 0) break;
			}
		}
		double kinkRad = Deg(KinkLaplacianAngle);
		for (int pass = 0; pass < KinkLaplacianPasses; pass++)
		{
			bool anyActive = false;
			Array.Clear(active, 0, n);
			for (int k = 1; k < n - 1; k++)
			{
				if (TurnAngle4m(pts, k) > kinkRad)
				{
					for (int j = Math.Max(1, k - 1); j <= Math.Min(n - 2, k + 1); j++)
						if (!pinned[j]) { active[j] = true; anyActive = true; }
				}
			}
			if (!anyActive) break;
			int movedPass = RunJacobiPass(pts, orig, pinned, active, heights, midHeights, blocked, midBlocked, segBad,
				prev, prevH, prevMidH, prevMidB, newSegBad, prevAng, prevWinMax, curAng, moved, prevProfOk, prevRadOk, inQueue, qBuf,
				false, SmoothStep, validator, local);
			if (movedPass == 0) break;
		}
		for (int pass = 0; pass < 2; pass++)
		{
			int movedPass = 0;
			for (int i = 1; i < n - 1; i++)
			{
				if (pinned[i]) continue;
				if (TurnAngle4m(pts, i) <= kinkRad) continue;
				double mx = (pts[i - 1].X + pts[i + 1].X) * 0.5, my = (pts[i - 1].Y + pts[i + 1].Y) * 0.5;
				double dx = (mx - pts[i].X) * SmoothStep, dy = (my - pts[i].Y) * SmoothStep;
				if (dx * dx + dy * dy < MoveEpsSq) continue;
				if (TryMove(pts, orig, heights, midHeights, blocked, midBlocked, segBad, i, dx, dy, validator, local)) movedPass++;
			}
			if (movedPass == 0) break;
		}
		var rounded = RoundBends(pts, orig, hardPinned, blocked, validator, local);
		var result = Stations(rounded);
		if (baseWholeOk && !WholeProfileOk(result, _grade))
			return line;
		if (WideBend.RadiusM > 0.0)
		{
			var wide = RoundWideBends(result, validator);
			if (WideBends > 0 && WholeProfileOk(wide, _grade) && validator.KeepsCrossings(result, wide))
				result = wide;
			else
				WideBends = 0;
		}
		if (validator.KeepsCrossings(line, result)) return result;
		WideBends = 0;
		return line;
	}

	// Строим дугу на свободной земле там, где за крутым локальным поворотом стоят длинные
	// перегоны. Начальный и конечный касательные берутся с неизменённых отрезков.
	private List<P> RoundWideBends(List<P> line, GeometryValidator validator)
	{
		int n = line.Count;
		var along = new double[n];
		var protectedCount = new int[n + 1];
		for (int k = 0; k < n; k++)
		{
			if (k > 0) along[k] = along[k - 1] + RoadGraph.Hypot(line[k].X - line[k - 1].X, line[k].Y - line[k - 1].Y);
			bool pinned = AxisBlocked(V.Of(line[k].X, line[k].Y)) || k > 0 && line[k - 1].W != line[k].W;
			protectedCount[k + 1] = protectedCount[k] + (pinned ? 1 : 0);
		}
		var output = new List<P>(n);
		var arc = new List<P>(64);
		int copied = 0;
		double minimum = Deg(WideBend.MinDegrees), maximum = Deg(WideBend.MaxDegrees);
		for (int k = 2; k + 2 < n; k++)
		{
			double angle = TurnAngle(line, k, 6.0);
			if (angle < minimum || angle > maximum || angle < TurnAngle(line, k + 1, 6.0)) continue;
			double reach = WideBend.RadiusM / Tile * Math.Tan(angle * 0.5);
			int a = k - 1, b = k + 1;
			while (a > 1 && along[k] - along[a] < reach) a--;
			while (b < n - 2 && along[b] - along[k] < reach) b++;
			if (a < copied || along[k] - along[a] < reach || along[b] - along[k] < reach ||
				protectedCount[b + 2] != protectedCount[a - 1]) continue;
			if (!WideArc(line, a, b, minimum, maximum, validator, arc)) continue;
			for (; copied < a; copied++) output.Add(line[copied]);
			output.AddRange(arc);
			copied = b + 1;
			k = b;
			WideBends++;
		}
		if (WideBends == 0) return line;
		for (; copied < n; copied++) output.Add(line[copied]);
		return output;
	}

	private bool WideArc(List<P> line, int a, int b, double minimum, double maximum, GeometryValidator validator, List<P> arc)
	{
		P start = line[a], end = line[b];
		V av = V.Of(start.X, start.Y), bv = V.Of(end.X, end.Y);
		V u = (av - V.Of(line[a - 1].X, line[a - 1].Y)).Normalized();
		V v = (V.Of(line[b + 1].X, line[b + 1].Y) - bv).Normalized();
		double angle = Math.Abs(u.AngleTo(v));
		if (angle < minimum * 0.75 || angle > maximum) return false;
		float det = u.Cross(v);
		if (Math.Abs(det) < 1e-5f) return false;
		float d1 = (bv - av).Cross(v) / det, d2 = u.Cross(bv - av) / det;
		if (d1 < 1f || d2 < 1f || d1 > d2 * 1.8 || d2 > d1 * 1.8) return false;
		V corner = av + u * d1;
		V derivative = bv - av;
		V second = (av + bv - corner * 2f) * 2f;
		double cross = Math.Abs(derivative.Cross(second));
		if (cross < 1e-6) return false;
		double radius = Math.Pow(derivative.Length(), 3) * Tile / cross;
		if (radius < 60.0 || radius > 200.0) return false;
		int steps = Math.Max(2, (int)Math.Ceiling((d1 + d2) / 0.45));
		arc.Clear();
		arc.Add(start);
		double maxShift = WideBend.ShiftM / Tile;
		for (int k = 1; k <= steps; k++)
		{
			float t = (float)k / steps;
			V sample = av.Lerp(corner, t).Lerp(corner.Lerp(bv, t), t);
			P p = k == steps ? end : new P(sample.X, sample.Y, start.W);
			if (AxisBlocked(sample)) return false;
			double nearestDistance = double.PositiveInfinity;
			V nearest = sample;
			for (int j = a + 1; j <= b; j++)
			{
				V q = ClosestOnSegment(sample, V.Of(line[j - 1].X, line[j - 1].Y), V.Of(line[j].X, line[j].Y));
				double distance = sample.DistanceSquaredTo(q);
				if (distance < nearestDistance) { nearestDistance = distance; nearest = q; }
			}
			if (nearestDistance > maxShift * maxShift ||
				!validator.KeepsClearance(new P(nearest.X, nearest.Y, start.W), p, line[0], line[^1]) ||
				!validator.Segment(arc[^1].X, arc[^1].Y, p.X, p.Y, start.W, _grade, _cross))
				return false;
			arc.Add(p);
		}
		return true;
	}

	private void EnsureInitialProfile(List<P> raw, double[] rawS, byte[] rawPin, List<P> pts, List<byte> pinList, List<double> ptsRawS, double grade)
	{
		for (int rep = 0; rep < 64; rep++)
		{
			int failIdx = FirstStationsProfileFail(pts, grade);
			if (failIdx < 0) break;
			int lo = failIdx;
			while (lo > 0 && ptsRawS[failIdx] - ptsRawS[lo] < 4.0) lo--;
			int hi = Math.Min(pts.Count - 1, failIdx + 1);
			while (hi < pts.Count - 1 && ptsRawS[hi] - ptsRawS[failIdx] < 1.5) hi++;
			while (true)
			{
				int ra = 0;
				for (int r = 0; r < raw.Count; r++)
					if (rawS[r] <= ptsRawS[lo] + 1e-9) ra = r; else break;
				int rb = raw.Count - 1;
				for (int r = raw.Count - 1; r >= ra; r--)
					if (rawS[r] >= ptsRawS[hi] - 1e-9) rb = r; else break;
				while (lo > 0 && ptsRawS[lo] > rawS[ra] + 1e-9) lo--;
				while (hi < pts.Count - 1 && ptsRawS[hi] < rawS[rb] - 1e-9) hi++;
				bool same = (hi - lo) == (rb - ra);
				if (same)
					for (int q = 0; q <= hi - lo; q++)
						if (pts[lo + q].X != raw[ra + q].X || pts[lo + q].Y != raw[ra + q].Y || pts[lo + q].W != raw[ra + q].W) { same = false; break; }
				if (same)
				{
					if (lo == 0 && hi == pts.Count - 1) return;
					lo = Math.Max(0, lo - 1);
					hi = Math.Min(pts.Count - 1, hi + 1);
					continue;
				}
				pts.RemoveRange(lo, hi - lo + 1);
				pinList.RemoveRange(lo, hi - lo + 1);
				ptsRawS.RemoveRange(lo, hi - lo + 1);
				for (int r = rb; r >= ra; r--)
				{
					pts.Insert(lo, raw[r]);
					pinList.Insert(lo, (byte)(rawPin[r] != 0 ? 1 : 2));
					ptsRawS.Insert(lo, rawS[r]);
				}
				break;
			}
		}
	}

	private int FirstStationsProfileFail(List<P> pts, double grade)
	{
		if (pts.Count < 2) return -1;
		var st = Stations(pts);
		int sn = st.Count;
		if (sn < 2) return -1;
		// сопоставление станций к индексам отрезков ломаной pts
		var segOf = new int[sn];
		segOf[0] = 0;
		int pos = 1;
		for (int k = 1; k < pts.Count; k++)
		{
			P a = pts[k - 1], b = pts[k];
			double dx = b.X - a.X, dy = b.Y - a.Y;
			double length = Math.Sqrt(dx * dx + dy * dy) * Tile;
			int steps = Math.Max(1, (int)Math.Ceiling(length / 2.0));
			for (int s = 0; s < steps && pos < sn; s++) segOf[pos++] = k - 1;
		}
		var heights = new double[sn];
		var along = new double[sn];
		V prevV = V.Of(st[0].X, st[0].Y);
		heights[0] = _probe.GroundAt((double)prevV.X * Tile, (double)prevV.Y * Tile);
		int j = 0;
		double run = 0.0;
		for (int k = 1; k < sn; k++)
		{
			V curV = V.Of(st[k].X, st[k].Y);
			run += curV.DistanceTo(prevV);
			prevV = curV;
			along[k] = run;
			heights[k] = _probe.GroundAt((double)curV.X * Tile, (double)curV.Y * Tile);
			if (_axis.Length > 0 && AxisBlocked(curV)) { j = k; continue; }
			while (j + 1 < k && along[k] - along[j + 1] >= ProfileBase) j++;
			if (Math.Abs(heights[k] - heights[j]) > grade * (along[k] - along[j]) * Tile + 0.00001) return segOf[k];
		}
		return -1;
	}

	private void UpdateSeg(IReadOnlyList<P> pts, double[] midHeights, byte[] midBlocked, byte[] segBadArr, int k, GeometryValidator validator, double local)
	{
		P a = pts[k], b = pts[k + 1];
		double mx = (a.X + b.X) * 0.5, my = (a.Y + b.Y) * 0.5;
		midHeights[k] = _probe.GroundAt(mx * Tile, my * Tile);
		midBlocked[k] = (byte)(_axis.Length > 0 && AxisBlocked(V.Of(mx, my)) ? 1 : 0);
		segBadArr[k] = (byte)(validator.Segment(a.X, a.Y, b.X, b.Y, a.W, local, _cross) ? 0 : 1);
	}

	private int RunJacobiPass(List<P> pts, List<P> orig, bool[] pinned, bool[] active,
		double[] heights, double[] midHeights, byte[] blocked, byte[] midBlocked, byte[] segBad,
		P[] prev, double[] prevH, double[] prevMidH, byte[] prevMidB, byte[] newSegBad,
		double[] prevAng, double[] prevWinMax, double[] curAng, bool[] moved,
		sbyte[] prevProfOk, sbyte[] prevRadOk, bool[] inQueue, int[] qBuf,
		bool biharmonic, double step, GeometryValidator validator, double local)
	{
		int n = pts.Count;
		int qCap = qBuf.Length;
		for (int k = 0; k < n; k++)
		{
			prev[k] = pts[k];
			prevH[k] = heights[k];
			moved[k] = false;
			inQueue[k] = false;
			prevProfOk[k] = -1;
			prevRadOk[k] = -1;
			if (k < n - 1)
			{
				prevMidH[k] = midHeights[k];
				prevMidB[k] = midBlocked[k];
				newSegBad[k] = segBad[k];
			}
		}
		prevAng[0] = prevAng[n - 1] = 0.0;
		for (int k = 1; k < n - 1; k++)
			prevAng[k] = TurnAngle4m(prev, k);
		for (int i = 1; i < n - 1; i++)
		{
			double mx = 0.0;
			int lo = Math.Max(1, i - 3), hi = Math.Min(n - 2, i + 3);
			for (int k = lo; k <= hi; k++)
				if (prevAng[k] > mx) mx = prevAng[k];
			prevWinMax[i] = mx;
		}
		bool anyMoved = false;
		for (int i = 1; i < n - 1; i++)
		{
			if (pinned[i] || (active != null && !active[i])) continue;
			double tx, ty, lam;
			if (biharmonic && i >= 2 && i <= n - 3)
			{
				tx = (-prev[i - 2].X + 4.0 * prev[i - 1].X + 4.0 * prev[i + 1].X - prev[i + 2].X) / 6.0;
				ty = (-prev[i - 2].Y + 4.0 * prev[i - 1].Y + 4.0 * prev[i + 1].Y - prev[i + 2].Y) / 6.0;
				lam = step;
			}
			else
			{
				tx = (prev[i - 1].X + prev[i + 1].X) * 0.5;
				ty = (prev[i - 1].Y + prev[i + 1].Y) * 0.5;
				lam = biharmonic ? 0.35 : step;
			}
			double dx = (tx - prev[i].X) * lam, dy = (ty - prev[i].Y) * lam;
			if (dx * dx + dy * dy < MoveEpsSq) continue;
			bool ok = false;
			for (int attempt = 0; attempt < 3; attempt++, dx *= 0.5, dy *= 0.5)
			{
				if (dx * dx + dy * dy < MoveEpsSq) break;
				double mx = prev[i].X + dx, my = prev[i].Y + dy;
				V p = V.Of(mx, my);
				double dev = double.PositiveInfinity;
				for (int j = Math.Max(1, i - 3); j <= Math.Min(orig.Count - 1, i + 3); j++)
					dev = Math.Min(dev, p.DistanceSquaredTo(ClosestOnSegment(p, V.Of(orig[j - 1].X, orig[j - 1].Y), V.Of(orig[j].X, orig[j].Y))));
				if (dev > TurnCorridor * TurnCorridor) continue;
				if (AxisBlocked(p)) continue;
				pts[i] = new P(mx, my, prev[i].W);
				moved[i] = true;
				anyMoved = true;
				ok = true;
				break;
			}
			if (!ok) SmoothRejected++;
		}
		if (!anyMoved) return 0;

		for (int i = 1; i < n - 1; i++)
			if (moved[i])
				heights[i] = _probe.GroundAt(pts[i].X * Tile, pts[i].Y * Tile);
		for (int k = 0; k < n - 1; k++)
			if (moved[k] || moved[k + 1])
				UpdateSeg(pts, midHeights, midBlocked, newSegBad, k, validator, local);
		curAng[0] = curAng[n - 1] = 0.0;
		for (int k = 1; k < n - 1; k++)
			curAng[k] = TurnAngle4m(pts, k);

		int qHead = 0, qTail = 0;
		for (int i = 1; i < n - 1; i++)
		{
			if (!moved[i]) continue;
			qBuf[qTail] = i;
			qTail = (qTail + 1) % qCap;
			inQueue[i] = true;
		}
		while (qHead != qTail)
		{
			int i = qBuf[qHead];
			qHead = (qHead + 1) % qCap;
			inQueue[i] = false;
			if (!moved[i]) continue;

			bool fail = newSegBad[i - 1] > segBad[i - 1] || newSegBad[i] > segBad[i]
				|| !validator.KeepsClearance(prev[i], pts[i], pts[0], pts[^1])
				|| !validator.KeepsClearance(Midpoint(prev[i - 1], prev[i]), Midpoint(pts[i - 1], pts[i]), pts[0], pts[^1])
				|| !validator.KeepsClearance(Midpoint(prev[i], prev[i + 1]), Midpoint(pts[i], pts[i + 1]), pts[0], pts[^1]);
			if (!fail)
			{
				double maxCur = 0.0;
				int lo = Math.Max(1, i - 3), hi = Math.Min(n - 2, i + 3);
				for (int k = lo; k <= hi; k++)
					if (curAng[k] > maxCur) maxCur = curAng[k];
				if (maxCur > prevWinMax[i] + 1e-6) fail = true;
			}
			if (!fail)
			{
				double needR = pts[i].W * 0.5 * Tile + 0.5;
				if (MinRadiusWindow4m(pts, i) < needR)
				{
					if (prevRadOk[i] < 0)
						prevRadOk[i] = (sbyte)(MinRadiusWindow4m(prev, i) >= needR ? 1 : 0);
					if (prevRadOk[i] == 1) fail = true;
				}
			}
			if (!fail && !ProfileWindowOk(pts, heights, midHeights, blocked, midBlocked, i, _grade))
			{
				if (prevProfOk[i] < 0)
					prevProfOk[i] = (sbyte)(ProfileWindowOk(prev, prevH, prevMidH, blocked, prevMidB, i, _grade) ? 1 : 0);
				if (prevProfOk[i] == 1) fail = true;
			}
			if (!fail) continue;

			pts[i] = prev[i];
			moved[i] = false;
			heights[i] = prevH[i];
			SmoothRejected++;
			if (!moved[i - 1])
			{
				midHeights[i - 1] = prevMidH[i - 1];
				midBlocked[i - 1] = prevMidB[i - 1];
				newSegBad[i - 1] = segBad[i - 1];
			}
			else
				UpdateSeg(pts, midHeights, midBlocked, newSegBad, i - 1, validator, local);
			if (!moved[i + 1])
			{
				midHeights[i] = prevMidH[i];
				midBlocked[i] = prevMidB[i];
				newSegBad[i] = segBad[i];
			}
			else
				UpdateSeg(pts, midHeights, midBlocked, newSegBad, i, validator, local);
			int alo = Math.Max(1, i - 4), ahi = Math.Min(n - 2, i + 4);
			for (int k = alo; k <= ahi; k++) curAng[k] = TurnAngle4m(pts, k);
			int qlo = Math.Max(1, i - 8), qhi = Math.Min(n - 2, i + 8);
			for (int j = qlo; j <= qhi; j++)
			{
				if (moved[j] && !inQueue[j])
				{
					qBuf[qTail] = j;
					qTail = (qTail + 1) % qCap;
					inQueue[j] = true;
				}
			}
		}

		int kept = 0;
		for (int i = 1; i < n - 1; i++)
		{
			if (!moved[i]) continue;
			kept++;
			segBad[i - 1] = newSegBad[i - 1];
			segBad[i] = newSegBad[i];
		}
		SmoothMoved += kept;
		return kept;
	}

	private static void PinAxisSpan(double[] rawS, byte[] rawPin, int k, int m)
	{
		for (int j = k; j >= 0 && rawS[k] - rawS[j] <= AxisPinCells + 1e-6; j--) rawPin[j] = 1;
		for (int j = k; j < m && rawS[j] - rawS[k] <= AxisPinCells + 1e-6; j++) rawPin[j] = 1;
	}

	private static P SampleSpan(List<P> raw, double[] rawS, int a, int b, double s)
	{
		if (s <= 0.0) return raw[a];
		double target = rawS[a] + s;
		if (target >= rawS[b]) return raw[b];
		int k = a;
		while (k + 1 < b && rawS[k + 1] < target) k++;
		double seg = rawS[k + 1] - rawS[k];
		double t = seg > 1e-12 ? Math.Clamp((target - rawS[k]) / seg, 0.0, 1.0) : 0.0;
		P pa = raw[k], pb = raw[k + 1];
		return new P(pa.X + (pb.X - pa.X) * t, pa.Y + (pb.Y - pa.Y) * t, pa.W + (pb.W - pa.W) * t);
	}

	/// <summary>Точка вдоль ломаной на расстоянии targetLen от вершины k в направлении dir (−1 / +1); у конца ≥ 0,3 кл
	/// фиксируется на концевой точке (без скачка угла/радиуса при длине краевого отрезка 0,87..1,0 кл).</summary>
	private static bool ChordPoint(IReadOnlyList<P> pts, int k, int dir, double targetLen, out double px, out double py)
	{
		double rem = targetLen, walked = 0.0;
		int cur = k, n = pts.Count;
		while (true)
		{
			int next = cur + dir;
			if (next < 0 || next >= n)
			{
				if (walked >= 0.3) { px = pts[cur].X; py = pts[cur].Y; return true; }
				px = py = 0.0;
				return false;
			}
			double sx = pts[next].X - pts[cur].X, sy = pts[next].Y - pts[cur].Y;
			double seg = Math.Sqrt(sx * sx + sy * sy);
			if (seg >= rem - 1e-9)
			{
				double t = seg > 1e-12 ? Math.Min(1.0, rem / seg) : 0.0;
				px = pts[cur].X + sx * t;
				py = pts[cur].Y + sy * t;
				return true;
			}
			rem -= seg;
			walked += seg;
			cur = next;
		}
	}

	private static double TurnAngle4m(IReadOnlyList<P> pts, int k) => TurnAngle(pts, k, 1.0);

	private static double TurnAngle(IReadOnlyList<P> pts, int k, double chord)
	{
		if (!ChordPoint(pts, k, -1, chord, out double ax, out double ay)) return 0.0;
		if (!ChordPoint(pts, k, 1, chord, out double cx, out double cy)) return 0.0;
		double vx0 = pts[k].X - ax, vy0 = pts[k].Y - ay;
		double vx1 = cx - pts[k].X, vy1 = cy - pts[k].Y;
		if (vx0 * vx0 + vy0 * vy0 < 1e-10 || vx1 * vx1 + vy1 * vy1 < 1e-10) return 0.0;
		return Math.Abs(Math.Atan2(vx0 * vy1 - vy0 * vx1, vx0 * vx1 + vy0 * vy1));
	}

	private static double MaxTurnAngleWindow(IReadOnlyList<P> pts, int i)
	{
		double best = 0.0;
		int lo = Math.Max(1, i - 3), hi = Math.Min(pts.Count - 2, i + 3);
		for (int k = lo; k <= hi; k++)
			best = Math.Max(best, TurnAngle4m(pts, k));
		return best;
	}

	private double MinRadiusWindow4m(IReadOnlyList<P> pts, int i)
	{
		double best = double.PositiveInfinity;
		int lo = Math.Max(1, i - 2), hi = Math.Min(pts.Count - 2, i + 2);
		for (int k = lo; k <= hi; k++)
		{
			if (!ChordPoint(pts, k, -1, 1.0, out double ax, out double ay)) continue;
			if (!ChordPoint(pts, k, 1, 1.0, out double cx, out double cy)) continue;
			double bx = pts[k].X, by = pts[k].Y;
			double a = Math.Sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay));
			double b = Math.Sqrt((cx - bx) * (cx - bx) + (cy - by) * (cy - by));
			double c = Math.Sqrt((cx - ax) * (cx - ax) + (cy - ay) * (cy - ay));
			if (a < 0.3 || b < 0.3) continue;
			double cross = Math.Abs((bx - ax) * (cy - ay) - (by - ay) * (cx - ax));
			if (cross < 1e-9) continue;
			best = Math.Min(best, a * b * c / (2.0 * cross) * Tile);
		}
		return best;
	}

	private bool ProfileWindowOk(IReadOnlyList<P> pts, double[] heights, double[] midHeights, byte[] blocked, byte[] midBlocked, int i, double grade)
	{
		int n = pts.Count;
		int from = i;
		double backDist = 0.0;
		while (from > 0 && (i - from < 6 || backDist < ProfileBase + 1.5) && i - from < 16)
		{
			from--;
			double dx = pts[from + 1].X - pts[from].X, dy = pts[from + 1].Y - pts[from].Y;
			backDist += Math.Sqrt(dx * dx + dy * dy);
		}
		int to = i;
		double fwdDist = 0.0;
		while (to < n - 1 && (to - i < 6 || fwdDist < ProfileBase + 1.5) && to - i < 16)
		{
			double dx = pts[to + 1].X - pts[to].X, dy = pts[to + 1].Y - pts[to].Y;
			fwdDist += Math.Sqrt(dx * dx + dy * dy);
			to++;
		}
		int segCount = to - from;
		if (segCount <= 0) return true;
		Span<double> segLens = stackalloc double[32];
		Span<int> segSteps = stackalloc int[32];
		int totalStations = 1;
		for (int s = 0; s < segCount; s++)
		{
			P pa = pts[from + s], pb = pts[from + s + 1];
			double dx = pb.X - pa.X, dy = pb.Y - pa.Y;
			double sl = Math.Sqrt(dx * dx + dy * dy);
			int steps = Math.Max(1, (int)Math.Ceiling(sl * Tile / 2.0));
			segLens[s] = sl;
			segSteps[s] = steps;
			totalStations += steps;
		}
		Span<double> along = totalStations <= 128 ? stackalloc double[totalStations] : new double[totalStations];
		Span<double> h = totalStations <= 128 ? stackalloc double[totalStations] : new double[totalStations];
		Span<byte> skip = totalStations <= 128 ? stackalloc byte[totalStations] : new byte[totalStations];
		along[0] = 0.0;
		h[0] = heights[from];
		skip[0] = blocked[from];
		int cnt = 1;
		double run = 0.0;
		for (int s = 0; s < segCount; s++)
		{
			int k = from + s;
			double sl = segLens[s];
			int steps = segSteps[s];
			if (steps == 2)
			{
				along[cnt] = run + sl * 0.5;
				h[cnt] = midHeights[k];
				skip[cnt] = midBlocked[k];
				cnt++;
			}
			else if (steps > 2)
			{
				P pa = pts[k], pb = pts[k + 1];
				for (int j = 1; j < steps; j++)
				{
					double t = (double)j / steps;
					double px = pa.X + (pb.X - pa.X) * t, py = pa.Y + (pb.Y - pa.Y) * t;
					along[cnt] = run + sl * t;
					h[cnt] = _probe.GroundAt(px * Tile, py * Tile);
					skip[cnt] = (byte)(_axis.Length > 0 && AxisBlocked(V.Of(px, py)) ? 1 : 0);
					cnt++;
				}
			}
			run += sl;
			along[cnt] = run;
			h[cnt] = heights[k + 1];
			skip[cnt] = blocked[k + 1];
			cnt++;
		}
		int jIdx = 0;
		bool shortOk = from == 0;
		for (int k = 1; k < cnt; k++)
		{
			if (skip[k] != 0) { jIdx = k; shortOk = true; continue; }
			while (jIdx + 1 < k && along[k] - along[jIdx + 1] >= ProfileBase) jIdx++;
			if (!shortOk && along[k] - along[jIdx] < ProfileBase) continue;
			if (Math.Abs(h[k] - h[jIdx]) > grade * (along[k] - along[jIdx]) * Tile + 0.00001) return false;
		}
		return true;
	}

	private static P Midpoint(P a, P b) => new((a.X + b.X) * 0.5, (a.Y + b.Y) * 0.5, a.W);

	private bool TryMove(List<P> pts, List<P> orig, double[] heights, double[] midHeights, byte[] blocked, byte[] midBlocked, byte[] segBad,
		int i, double dx, double dy, GeometryValidator validator, double local)
	{
		var keep = pts[i];
		double keepH = heights[i];
		double keepMidH0 = midHeights[i - 1], keepMidH1 = midHeights[i];
		byte keepMidB0 = midBlocked[i - 1], keepMidB1 = midBlocked[i];
		double needR = keep.W * 0.5 * Tile + 0.5;
		int before = segBad[i - 1] + segBad[i]
			+ (ProfileWindowOk(pts, heights, midHeights, blocked, midBlocked, i, _grade) ? 0 : 1)
			+ (MinRadiusWindow4m(pts, i) < needR ? 1 : 0);
		double maxAngleBefore = MaxTurnAngleWindow(pts, i);
		for (int attempt = 0; attempt < 3; attempt++, dx *= 0.5, dy *= 0.5)
		{
			if (dx * dx + dy * dy < MoveEpsSq) break;
			var moved = new P(keep.X + dx, keep.Y + dy, keep.W);
			V p = V.Of(moved.X, moved.Y);
			double deviation = double.PositiveInfinity;
			for (int j = Math.Max(1, i - 3); j <= Math.Min(orig.Count - 1, i + 3); j++)
				deviation = Math.Min(deviation, p.DistanceSquaredTo(ClosestOnSegment(p, V.Of(orig[j - 1].X, orig[j - 1].Y), V.Of(orig[j].X, orig[j].Y))));
			if (deviation > TurnCorridor * TurnCorridor) continue;
			if (AxisBlocked(p)) continue;
			if (!validator.KeepsClearance(keep, moved, pts[0], pts[^1])
				|| !validator.KeepsClearance(Midpoint(pts[i - 1], keep), Midpoint(pts[i - 1], moved), pts[0], pts[^1])
				|| !validator.KeepsClearance(Midpoint(keep, pts[i + 1]), Midpoint(moved, pts[i + 1]), pts[0], pts[^1])) continue;
			pts[i] = moved;
			if (MaxTurnAngleWindow(pts, i) > maxAngleBefore + 1e-6) { pts[i] = keep; continue; }
			int radAfter = MinRadiusWindow4m(pts, i) < needR ? 1 : 0;
			if (before == 0 && radAfter != 0) { pts[i] = keep; continue; }
			heights[i] = _probe.GroundAt(moved.X * Tile, moved.Y * Tile);
			double m0x = (pts[i - 1].X + moved.X) * 0.5, m0y = (pts[i - 1].Y + moved.Y) * 0.5;
			double m1x = (moved.X + pts[i + 1].X) * 0.5, m1y = (moved.Y + pts[i + 1].Y) * 0.5;
			midHeights[i - 1] = _probe.GroundAt(m0x * Tile, m0y * Tile);
			midHeights[i] = _probe.GroundAt(m1x * Tile, m1y * Tile);
			midBlocked[i - 1] = (byte)(_axis.Length > 0 && AxisBlocked(V.Of(m0x, m0y)) ? 1 : 0);
			midBlocked[i] = (byte)(_axis.Length > 0 && AxisBlocked(V.Of(m1x, m1y)) ? 1 : 0);
			int profAfter = ProfileWindowOk(pts, heights, midHeights, blocked, midBlocked, i, _grade) ? 0 : 1;
			if (before == 0 && profAfter != 0)
			{
				pts[i] = keep; heights[i] = keepH;
				midHeights[i - 1] = keepMidH0; midHeights[i] = keepMidH1;
				midBlocked[i - 1] = keepMidB0; midBlocked[i] = keepMidB1;
				continue;
			}
			byte sb0 = (byte)(validator.Segment(pts[i - 1].X, pts[i - 1].Y, moved.X, moved.Y, pts[i - 1].W, local, _cross) ? 0 : 1);
			if (before == 0 && sb0 != 0)
			{
				pts[i] = keep; heights[i] = keepH;
				midHeights[i - 1] = keepMidH0; midHeights[i] = keepMidH1;
				midBlocked[i - 1] = keepMidB0; midBlocked[i] = keepMidB1;
				continue;
			}
			byte sb1 = (byte)(validator.Segment(moved.X, moved.Y, pts[i + 1].X, pts[i + 1].Y, moved.W, local, _cross) ? 0 : 1);
			int after = sb0 + sb1 + profAfter + radAfter;
			if (after <= before && (after == 0 || after < before))
			{
				segBad[i - 1] = sb0;
				segBad[i] = sb1;
				SmoothMoved++;
				return true;
			}
			pts[i] = keep;
			heights[i] = keepH;
			midHeights[i - 1] = keepMidH0; midHeights[i] = keepMidH1;
			midBlocked[i - 1] = keepMidB0; midBlocked[i] = keepMidB1;
		}
		SmoothRejected++;
		return false;
	}

	private List<P> RoundBends(List<P> pts, List<P> orig, bool[] hardPinned, byte[] blocked, GeometryValidator validator, double local)
	{
		int n = pts.Count;
		var outp = new List<P>(n * 2) { pts[0] };
		var outpBlock = new List<byte>(n * 2) { blocked[0] };
		double roundRad = Deg(RoundAngle);
		double[] fracs = _mountain ? MountainRoundFractions : RoundFractions;
		var fillet = new List<P>(16);
		var win = new List<P>(48);
		var winBlock = new List<byte>(48);
		var profAlong = new List<double>(160);
		var profH = new List<double>(160);
		var profSkip = new List<byte>(160);
		for (int i = 1; i < n - 1; i++)
		{
			P a = pts[i - 1], b = pts[i], c = pts[i + 1];
			if (hardPinned[i] || a.W != b.W || c.W != b.W) { outp.Add(b); outpBlock.Add(blocked[i]); continue; }
			double ax = b.X - a.X, ay = b.Y - a.Y, bx = c.X - b.X, by = c.Y - b.Y;
			double la = Math.Sqrt(ax * ax + ay * ay), lb = Math.Sqrt(bx * bx + by * by);
			if (la < 1e-6 || lb < 1e-6 || (la < 0.25 && lb < 0.25)) { outp.Add(b); outpBlock.Add(blocked[i]); continue; }
			double ang = Math.Abs(Math.Atan2(ax * by - ay * bx, ax * bx + ay * by));
			if (ang <= roundRad) { outp.Add(b); outpBlock.Add(blocked[i]); continue; }
			double seg0Len = Math.Sqrt((b.X - outp[^1].X) * (b.X - outp[^1].X) + (b.Y - outp[^1].Y) * (b.Y - outp[^1].Y));
			double badLenBefore = (!validator.Segment(outp[^1].X, outp[^1].Y, b.X, b.Y, b.W, local, _cross) ? seg0Len : 0.0)
								+ (!validator.Segment(b.X, b.Y, c.X, c.Y, b.W, local, _cross) ? lb : 0.0);
			int outFrom = outp.Count - 1;
			double back = 0.0;
			while (outFrom > 0 && (outp.Count - 1 - outFrom < 3 || back < ProfileBase + 1.5) && outp.Count - 1 - outFrom < 24)
			{
				outFrom--;
				double dx = outp[outFrom + 1].X - outp[outFrom].X, dy = outp[outFrom + 1].Y - outp[outFrom].Y;
				back += Math.Sqrt(dx * dx + dy * dy);
			}
			int to = i;
			double fwd = 0.0;
			while (to < n - 1 && (to - i < 3 || fwd < ProfileBase + 1.5) && to - i < 16)
			{
				double dx = pts[to + 1].X - pts[to].X, dy = pts[to + 1].Y - pts[to].Y;
				fwd += Math.Sqrt(dx * dx + dy * dy);
				to++;
			}
			win.Clear(); winBlock.Clear();
			for (int j = outFrom; j < outp.Count; j++) { win.Add(outp[j]); winBlock.Add(outpBlock[j]); }
			win.Add(b); winBlock.Add(blocked[i]);
			for (int j = i + 1; j <= to; j++) { win.Add(pts[j]); winBlock.Add(blocked[j]); }
			bool baseProf = RangeProfileOk(win, winBlock, _grade, outFrom == 0, profAlong, profH, profSkip);
			bool added = false;
			foreach (double f in fracs)
			{
				fillet.Clear();
				double r0 = la > 1.2 ? f * 1.2 / la : f;
				double r1 = lb > 1.2 ? f * 1.2 / lb : f;
				double p0x = b.X - ax * r0, p0y = b.Y - ay * r0;
				double p2x = b.X + bx * r1, p2y = b.Y + by * r1;
				double arcLen = Math.Sqrt((p0x - b.X) * (p0x - b.X) + (p0y - b.Y) * (p0y - b.Y))
							  + Math.Sqrt((p2x - b.X) * (p2x - b.X) + (p2y - b.Y) * (p2y - b.Y));
				int steps = Math.Max(2, (int)Math.Ceiling(arcLen / 0.22));
				bool valid = true;
				for (int s = 0; s <= steps; s++)
				{
					double t = (double)s / steps, u = 1.0 - t;
					double x = u * u * p0x + 2.0 * u * t * b.X + t * t * p2x;
					double y = u * u * p0y + 2.0 * u * t * b.Y + t * t * p2y;
					V vp = V.Of(x, y);
					if (AxisBlocked(vp)) { valid = false; break; }
					double dev = double.PositiveInfinity;
					V nearest = vp;
					for (int j = Math.Max(1, i - 3); j <= Math.Min(orig.Count - 1, i + 3); j++)
					{
						V q = ClosestOnSegment(vp, V.Of(orig[j - 1].X, orig[j - 1].Y), V.Of(orig[j].X, orig[j].Y));
						double d = vp.DistanceSquaredTo(q);
						if (d < dev) { dev = d; nearest = q; }
					}
					if (dev > TurnCorridor * TurnCorridor) { valid = false; break; }
					if (!validator.KeepsClearance(new P(nearest.X, nearest.Y, b.W), new P(x, y, b.W), pts[0], pts[^1]))
					{ valid = false; break; }
					if (fillet.Count == 0 || Math.Sqrt((x - fillet[^1].X) * (x - fillet[^1].X) + (y - fillet[^1].Y) * (y - fillet[^1].Y)) > 1e-5)
						fillet.Add(new P(x, y, b.W));
				}
				if (!valid || fillet.Count < 2) continue;
				double badLenAfter = 0.0;
				bool dry = true;
				void CheckSeg(double x0, double y0, double x1, double y1)
				{
					if (!dry || badLenAfter > badLenBefore + 1e-6) return;
					if (!validator.Segment(x0, y0, x1, y1, b.W, local, _cross))
					{
						if (badLenBefore <= 0.0 || !validator.Segment(x0, y0, x1, y1, b.W, 1e9, 1e9))
						{
							dry = false;
							return;
						}
						badLenAfter += Math.Sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0));
					}
				}
				CheckSeg(outp[^1].X, outp[^1].Y, fillet[0].X, fillet[0].Y);
				for (int s = 1; s < fillet.Count && dry && badLenAfter <= badLenBefore + 1e-6; s++)
					CheckSeg(fillet[s - 1].X, fillet[s - 1].Y, fillet[s].X, fillet[s].Y);
				CheckSeg(fillet[^1].X, fillet[^1].Y, c.X, c.Y);
				if (!dry || badLenAfter > badLenBefore + 1e-6) continue;
				if (baseProf)
				{
					win.Clear(); winBlock.Clear();
					for (int j = outFrom; j < outp.Count; j++) { win.Add(outp[j]); winBlock.Add(outpBlock[j]); }
					foreach (var fp in fillet) { win.Add(fp); winBlock.Add(0); }
					for (int j = i + 1; j <= to; j++) { win.Add(pts[j]); winBlock.Add(blocked[j]); }
					if (!RangeProfileOk(win, winBlock, _grade, outFrom == 0, profAlong, profH, profSkip)) continue;
				}
				foreach (var fp in fillet) { outp.Add(fp); outpBlock.Add(0); }
				added = true;
				SmoothMoved++;
				break;
			}
			if (!added) { outp.Add(b); outpBlock.Add(blocked[i]); }
		}
		outp.Add(pts[n - 1]);
		outpBlock.Add(blocked[n - 1]);
		return outp;
	}

	private bool RangeProfileOk(List<P> pts, List<byte> skip, double grade, bool atStart,
		List<double> along, List<double> heights, List<byte> stSkip)
	{
		int n = pts.Count;
		if (n < 2) return true;
		along.Clear(); heights.Clear(); stSkip.Clear();
		double run = 0.0;
		along.Add(0.0);
		heights.Add(_probe.GroundAt(pts[0].X * Tile, pts[0].Y * Tile));
		stSkip.Add(skip[0]);
		for (int k = 1; k < n; k++)
		{
			P pa = pts[k - 1], pb = pts[k];
			double dx = pb.X - pa.X, dy = pb.Y - pa.Y;
			double sl = Math.Sqrt(dx * dx + dy * dy);
			int steps = Math.Max(1, (int)Math.Ceiling(sl * Tile / 2.0));
			for (int s = 1; s < steps; s++)
			{
				double t = (double)s / steps;
				double px = pa.X + dx * t, py = pa.Y + dy * t;
				along.Add(run + sl * t);
				heights.Add(_probe.GroundAt(px * Tile, py * Tile));
				stSkip.Add((byte)(_axis.Length > 0 && AxisBlocked(V.Of(px, py)) ? 1 : 0));
			}
			run += sl;
			along.Add(run);
			heights.Add(_probe.GroundAt(pb.X * Tile, pb.Y * Tile));
			stSkip.Add(skip[k]);
		}
		int j = 0;
		bool shortOk = atStart;
		for (int k = 1; k < along.Count; k++)
		{
			if (stSkip[k] != 0) { j = k; shortOk = true; continue; }
			while (j + 1 < k && along[k] - along[j + 1] >= ProfileBase) j++;
			if (!shortOk && along[k] - along[j] < ProfileBase) continue;
			if (Math.Abs(heights[k] - heights[j]) > grade * (along[k] - along[j]) * Tile + 0.00001) return false;
		}
		return true;
	}

	private bool WholeProfileOk(List<P> pts, double grade)
	{
		int n = pts.Count;
		if (n < 2) return true;
		var v = new V[n];
		var skip = _axis.Length > 0 ? new byte[n] : null;
		for (int k = 0; k < n; k++)
		{
			v[k] = V.Of(pts[k].X, pts[k].Y);
			if (skip != null && AxisBlocked(v[k])) skip[k] = 1;
		}
		return ProfileOk(v, grade, skip);
	}

	/// <summary>RoadLine.profile_ok: точки — float32 (Vector2), высоты и пробег — double.</summary>
	public bool ProfileOk(V[] points, double grade, byte[] skip)
	{
		int n = points.Length;
		var heights = new double[n];
		var along = new double[n];
		double run = 0.0;
		for (int k = 0; k < n; k++)
		{
			if (k > 0) run += points[k].DistanceTo(points[k - 1]);
			along[k] = run;
			heights[k] = _probe.GroundAt((double)points[k].X * Tile, (double)points[k].Y * Tile);
		}
		int j = 0;
		for (int k = 1; k < n; k++)
		{
			if (skip != null && skip.Length > 0 && skip[k] != 0) { j = k; continue; }
			while (j + 1 < k && along[k] - along[j + 1] >= ProfileBase) j++;
			if (Math.Abs(heights[k] - heights[j]) > grade * (along[k] - along[j]) * Tile + 0.00001) return false;
		}
		return true;
	}

	/// <summary>RoadLine.segment_ok с probe: FastGrid.RoadSegment по точкам-словарям (double).</summary>
	private bool SegmentOk(P a, P b, double maxGrade, double maxCross)
	{
		bool ok = _probe.RoadSegment(a.X, a.Y, b.X, b.Y, a.W, maxGrade, maxCross);
		if (!ok && _probe.WaterSetupError().Length > 0) throw new InvalidOperationException("LineBuilder: " + _probe.WaterSetupError());
		return ok;
	}
}
