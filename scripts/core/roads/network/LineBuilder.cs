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
	private bool _longS;
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
		if (pts.Count < 2) return pts;
		var fixedv = new byte[pts.Count];
		if (_axis.Length > 0)
			for (int k = 0; k < pts.Count; k++)
				if (AxisBlocked(V.Of(pts[k].X, pts[k].Y)))
					for (int j = Math.Max(0, k - 2); j < Math.Min(pts.Count, k + 3); j++) fixedv[j] = 1;
		string design = smooth.Length == 0 ? kind : smooth;
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
		var outp = start == null ? new List<P> { bends[0] } : start;
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
					i += consumed;
					continue;
				}
				curve = Bend(a, b, c, bends[i].W);
			}
			if (curve == null) outp.Add(bends[i]);
			else outp.AddRange(curve);
			i++;
		}
		if (finish == null) outp.Add(bends[^1]);
		else
		{
			finish.Reverse();
			outp.AddRange(finish);
		}
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

	// ---- фаза 3.2: монотонное сглаживание (план V2, 3.7, п. 2–4)
	public const int SmoothPasses = 3;
	public const double SmoothStep = 0.5;   // доля сдвига к середине соседей
	public const double ApexReach = 3.0;    // RoadRefinement.REACH, м: вынос вершины разворота
	public int SmoothMoved, SmoothRejected, Hairpins, HairpinsMoved;
	/// <summary>Фаза 3.3: дополнительный член Δ⁴ после Лапласа.</summary>
	public bool Biharmonic;

	/// <summary>Сглаживание линии: каждая свободная точка сдвигается к середине соседей (Лаплас) на SmoothStep; сдвиг
	/// проверяет GeometryValidator на окне [i−3, i+3] (отрезки с пределом вида × поблажка и крен, профиль 12 м на окне
	/// [i−6, i+6], радиус ≥ полуширины + 0,5 м), удержание в коридоре исходной линии (TURN_CORRIDOR) и оси сооружений;
	/// при ухудшении шаг ×0,5 до трёх раз, иначе точка стоит. Нарушений после сдвига не больше, чем до (монотонно).
	/// Концы, точки у осей сооружений и смены ширины закреплены. Разворот круче 105° — вершина выносится наружу до
	/// радиуса полуширина + ApexReach + 1 м, если валидатор не против. Число точек не меняется.</summary>
	public List<P> Smooth(List<P> line, GeometryValidator validator)
	{
		int n = line.Count;
		if (n < 5) return line;
		var orig = new List<P>(line);
		var pts = new List<P>(line);
		var pinned = new bool[n];
		pinned[0] = pinned[n - 1] = true;
		for (int k = 0; k < n; k++)
		{
			if (AxisBlocked(V.Of(pts[k].X, pts[k].Y)))
				for (int j = Math.Max(0, k - 2); j < Math.Min(n, k + 3); j++) pinned[j] = true;
			if (k > 0 && pts[k].W != pts[k - 1].W) { pinned[k] = true; pinned[k - 1] = true; }
		}
		double local = _relax > 1.0 ? _grade * _relax : _grade;
		for (int pass = 0; pass < SmoothPasses; pass++)
			for (int i = 1; i < n - 1; i++)
			{
				if (pinned[i]) continue;
				double mx = (pts[i - 1].X + pts[i + 1].X) * 0.5, my = (pts[i - 1].Y + pts[i + 1].Y) * 0.5;
				double dx = (mx - pts[i].X) * SmoothStep, dy = (my - pts[i].Y) * SmoothStep;
				if (dx * dx + dy * dy < 1e-8) continue;
				TryMove(pts, orig, i, dx, dy, validator, local, false);
			}
		// 3.3: член Δ⁴ — сдвиг к точке, у которой вторые разности с соседями наименьшие:
		// (−p[i−2] + 4·p[i−1] + 4·p[i+1] − p[i+2]) / 6; те же проверки (TryMove)
		if (Biharmonic)
			for (int pass = 0; pass < SmoothPasses; pass++)
				for (int i = 2; i < n - 2; i++)
				{
					if (pinned[i]) continue;
					double tx = (-pts[i - 2].X + 4.0 * pts[i - 1].X + 4.0 * pts[i + 1].X - pts[i + 2].X) / 6.0;
					double ty = (-pts[i - 2].Y + 4.0 * pts[i - 1].Y + 4.0 * pts[i + 1].Y - pts[i + 2].Y) / 6.0;
					double dx = (tx - pts[i].X) * SmoothStep, dy = (ty - pts[i].Y) * SmoothStep;
					if (dx * dx + dy * dy < 1e-8) continue;
					TryMove(pts, orig, i, dx, dy, validator, local, false);
				}
		// развороты: вершина наружу
		for (int i = 2; i < n - 2; i++)
		{
			if (pinned[i]) continue;
			double ax = pts[i].X - pts[i - 2].X, ay = pts[i].Y - pts[i - 2].Y, bx = pts[i + 2].X - pts[i].X, by = pts[i + 2].Y - pts[i].Y;
			double la = Math.Sqrt(ax * ax + ay * ay), lb = Math.Sqrt(bx * bx + by * by);
			if (la < 1e-6 || lb < 1e-6) continue;
			double cos = (ax * bx + ay * by) / (la * lb);
			if (Math.Acos(Math.Clamp(cos, -1.0, 1.0)) < Deg(105.0)) continue;
			Hairpins++;
			double need = (pts[i].W * 0.5 * Tile + ApexReach + 1.0) / Tile;
			double have = validator.MinRadius(Flat(pts, i - 1, i + 1)) / Tile;
			if (have >= need) continue;
			// наружу — против середины соседей
			double ox = pts[i].X - (pts[i - 1].X + pts[i + 1].X) * 0.5, oy = pts[i].Y - (pts[i - 1].Y + pts[i + 1].Y) * 0.5;
			double lo = Math.Sqrt(ox * ox + oy * oy);
			if (lo < 1e-6) continue;
			double push = Math.Min(need - have, TurnCorridor);
			if (TryMove(pts, orig, i, ox / lo * push, oy / lo * push, validator, local, true)) HairpinsMoved++;
		}
		return pts;
	}

	private static double[] Flat(List<P> pts, int from, int to)
	{
		from = Math.Max(0, from);
		to = Math.Min(pts.Count - 1, to);
		var outp = new double[(to - from + 1) * 2];
		for (int k = from; k <= to; k++) { outp[2 * (k - from)] = pts[k].X; outp[2 * (k - from) + 1] = pts[k].Y; }
		return outp;
	}

	/// <summary>Нарушения окна точки i: отрезки [i−3, i+3] (участок и крен), профиль на [i−6, i+6], радиус у i.</summary>
	private int Violations(List<P> pts, int i, GeometryValidator validator, double local)
	{
		int bad = 0;
		for (int k = Math.Max(1, i - 3); k <= Math.Min(pts.Count - 1, i + 3); k++)
			if (!validator.Segment(pts[k - 1].X, pts[k - 1].Y, pts[k].X, pts[k].Y, pts[k - 1].W, local, _cross)) bad++;
		if (!validator.Profile(Flat(pts, i - 6, i + 6), _grade)) bad++;
		if (validator.MinRadius(Flat(pts, i - 1, i + 1)) < pts[i].W * 0.5 * Tile + 0.5) bad++;
		return bad;
	}

	private bool TryMove(List<P> pts, List<P> orig, int i, double dx, double dy, GeometryValidator validator, double local, bool hairpin)
	{
		var keep = pts[i];
		int before = Violations(pts, i, validator, local);
		for (int attempt = 0; attempt < 3; attempt++, dx *= 0.5, dy *= 0.5)
		{
			var moved = new P(keep.X + dx, keep.Y + dy, keep.W);
			// в коридоре исходной линии и не на осях сооружений по ширине
			V p = V.Of(moved.X, moved.Y);
			double deviation = double.PositiveInfinity;
			for (int j = Math.Max(1, i - 4); j <= Math.Min(orig.Count - 1, i + 4); j++)
				deviation = Math.Min(deviation, p.DistanceSquaredTo(ClosestOnSegment(p, V.Of(orig[j - 1].X, orig[j - 1].Y), V.Of(orig[j].X, orig[j].Y))));
			if (deviation > TurnCorridor * TurnCorridor) continue;
			if (AxisBlocked(p)) continue;
			pts[i] = moved;
			int after = Violations(pts, i, validator, local);
			if (after <= before && (after == 0 || hairpin || after < before))
			{
				SmoothMoved++;
				return true;
			}
			pts[i] = keep;
		}
		SmoothRejected++;
		return false;
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
