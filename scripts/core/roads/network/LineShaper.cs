using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using static Roads.Network.LineBuilder;

namespace Roads.Network;

/// <summary>Сглаживает ось V2 после построения линии, сохраняя закреплённые станции и допустимый профиль.</summary>
internal sealed class LineShaper
{
	private readonly LineBuilder _builder;
	private readonly FastGrid _probe;
	private readonly List<P> _raw;
	private readonly List<byte> _rawPinned;
	private readonly bool _hasAxis, _mountain;
	private readonly double _grade, _cross, _relax;

	internal sealed class Settings
	{
		internal readonly double SmoothSpacing;
		internal readonly double AxisPinCells;
		internal readonly int BiharmonicPasses;
		internal readonly double BiharmonicStep;
		internal readonly int LaplacianPasses;
		internal readonly int KinkLaplacianPasses;
		internal readonly double KinkLaplacianAngle;
		internal readonly int FinalKinkPasses;
		internal readonly double SmoothStep;
		internal readonly double BiharmonicEdgeStep;
		internal readonly double MoveEpsSq;
		internal readonly int MoveRetries;
		internal readonly double MoveRetryScale;
		internal readonly double RoundAngle;
		internal readonly double[] RoundFractions;
		internal readonly double[] MountainRoundFractions;
		internal readonly double RoundCorridor;
		internal readonly double MinSubdivision;
		internal readonly int ProfileRestoreLimit;
		internal readonly double RestoreBack;
		internal readonly double RestoreForward;
		internal readonly double TurnChord;
		internal readonly double MinTurnChord;
		internal readonly double RoundSampling;
		internal readonly double RoundMinArm;
		internal readonly double RoundTrimLimit;

		internal Settings(Godot.Collections.Dictionary input)
		{
			SmoothSpacing = Params.Num(input, "smooth_spacing");
			AxisPinCells = Params.Num(input, "axis_pin_cells");
			BiharmonicPasses = (int)Params.Num(input, "biharmonic_passes");
			BiharmonicStep = Params.Num(input, "biharmonic_step");
			LaplacianPasses = (int)Params.Num(input, "laplacian_passes");
			KinkLaplacianPasses = (int)Params.Num(input, "kink_laplacian_passes");
			KinkLaplacianAngle = Params.Num(input, "kink_laplacian_angle");
			FinalKinkPasses = (int)Params.Num(input, "final_kink_passes");
			SmoothStep = Params.Num(input, "smooth_step");
			BiharmonicEdgeStep = Params.Num(input, "biharmonic_edge_step");
			MoveEpsSq = Params.Num(input, "move_eps_sq");
			MoveRetries = (int)Params.Num(input, "move_retries");
			MoveRetryScale = Params.Num(input, "move_retry_scale");
			RoundAngle = Params.Num(input, "round_angle");
			RoundFractions = input["round_fractions"].AsFloat64Array();
			MountainRoundFractions = input["mountain_round_fractions"].AsFloat64Array();
			RoundCorridor = Params.Num(input, "round_corridor");
			MinSubdivision = Params.Num(input, "min_subdivision");
			ProfileRestoreLimit = (int)Params.Num(input, "profile_restore_limit");
			RestoreBack = Params.Num(input, "restore_back");
			RestoreForward = Params.Num(input, "restore_forward");
			TurnChord = Params.Num(input, "turn_chord");
			MinTurnChord = Params.Num(input, "min_turn_chord");
			RoundSampling = Params.Num(input, "round_sampling");
			RoundMinArm = Params.Num(input, "round_min_arm");
			RoundTrimLimit = Params.Num(input, "round_trim_limit");
		}
	}

	private readonly Settings _settings;

	internal int SmoothMoved, SmoothRejected, Hairpins, HairpinsMoved;
	/// <summary>Фаза 3.3+: сглаживание с бигармоническим членом Δ⁴.</summary>
	private readonly bool _biharmonic;

	internal LineShaper(LineBuilder builder, FastGrid probe, List<P> raw, List<byte> rawPinned,
		bool hasAxis, double grade, double cross, double relax, bool mountain, bool biharmonic, Settings settings)
	{
		_builder = builder;
		_probe = probe;
		_raw = raw;
		_rawPinned = rawPinned;
		_hasAxis = hasAxis;
		_grade = grade;
		_cross = cross;
		_relax = relax;
		_mountain = mountain;
		_biharmonic = biharmonic;
		_settings = settings;
	}

	/// <summary>Сглаживание по прорежённой линии (~4 м) до Stations(): ресэмпл свободных участков с локальным возвратом _raw
	/// при редком нарушении 2-м профиля, одновременные Δ⁴-проходы и прицельный Лаплас с откатом по очереди зависимостей,
	/// монотонная защита наибольшего угла на хордах 4 м в [i−3, i+3], 2-м профиль в окне и скругление вершин > 18°.</summary>
	internal List<P> Smooth(List<P> line, GeometryValidator validator)
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
		if (_hasAxis)
		{
			for (int k = 0; k < m; k++)
				if (_builder.AxisBlocked(V.Of(_raw[k].X, _raw[k].Y)))
					PinAxisSpan(rawS, rawPin, k, m);
		}
		double local = _relax > 1.0 ? _grade * _relax : _grade;
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
				int segs = Math.Max(1, (int)Math.Ceiling(spanLen / _settings.SmoothSpacing));
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
					if (s1 - s0 > _settings.MinSubdivision && (!ok || _builder.AxisBlocked(V.Of(mid.X, mid.Y)) ||
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
			if (_builder.AxisBlocked(V.Of(pts[k].X, pts[k].Y)))
			{
				blocked[k] = 1;
				for (int j = k; j >= 0 && ptsS[k] - ptsS[j] <= _settings.AxisPinCells + 1e-6; j--) { pinned[j] = true; hardPinned[j] = true; }
				for (int j = k; j < n && ptsS[j] - ptsS[k] <= _settings.AxisPinCells + 1e-6; j++) { pinned[j] = true; hardPinned[j] = true; }
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

		if (_biharmonic)
		{
			for (int pass = 0; pass < _settings.BiharmonicPasses; pass++)
			{
				int movedPass = RunJacobiPass(pts, orig, pinned, null, heights, midHeights, blocked, midBlocked, segBad,
					prev, prevH, prevMidH, prevMidB, newSegBad, prevAng, prevWinMax, curAng, moved, prevProfOk, prevRadOk, inQueue, qBuf,
					true, _settings.BiharmonicStep, validator, local);
				if (movedPass == 0) break;
			}
		}
		else
		{
			for (int pass = 0; pass < _settings.LaplacianPasses; pass++)
			{
				int movedPass = RunJacobiPass(pts, orig, pinned, null, heights, midHeights, blocked, midBlocked, segBad,
					prev, prevH, prevMidH, prevMidB, newSegBad, prevAng, prevWinMax, curAng, moved, prevProfOk, prevRadOk, inQueue, qBuf,
					false, _settings.SmoothStep, validator, local);
				if (movedPass == 0) break;
			}
		}
		double kinkRad = Deg(_settings.KinkLaplacianAngle);
		for (int pass = 0; pass < _settings.KinkLaplacianPasses; pass++)
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
				false, _settings.SmoothStep, validator, local);
			if (movedPass == 0) break;
		}
		for (int pass = 0; pass < _settings.FinalKinkPasses; pass++)
		{
			int movedPass = 0;
			for (int i = 1; i < n - 1; i++)
			{
				if (pinned[i]) continue;
				if (TurnAngle4m(pts, i) <= kinkRad) continue;
				double mx = (pts[i - 1].X + pts[i + 1].X) * 0.5, my = (pts[i - 1].Y + pts[i + 1].Y) * 0.5;
				double dx = (mx - pts[i].X) * _settings.SmoothStep, dy = (my - pts[i].Y) * _settings.SmoothStep;
				if (dx * dx + dy * dy < _settings.MoveEpsSq) continue;
				if (TryMove(pts, orig, heights, midHeights, blocked, midBlocked, segBad, i, dx, dy, validator, local)) movedPass++;
			}
			if (movedPass == 0) break;
		}
		var rounded = RoundBends(pts, orig, hardPinned, blocked, validator, local);
		var result = Stations(rounded);
		if (baseWholeOk && !WholeProfileOk(result, _grade))
			return line;
		return validator.KeepsCrossings(line, result) ? result : line;
	}

	private void EnsureInitialProfile(List<P> raw, double[] rawS, byte[] rawPin, List<P> pts, List<byte> pinList, List<double> ptsRawS, double grade)
	{
		for (int rep = 0; rep < _settings.ProfileRestoreLimit; rep++)
		{
			int failIdx = FirstStationsProfileFail(pts, grade);
			if (failIdx < 0) break;
			int lo = failIdx;
			while (lo > 0 && ptsRawS[failIdx] - ptsRawS[lo] < _settings.RestoreBack) lo--;
			int hi = Math.Min(pts.Count - 1, failIdx + 1);
			while (hi < pts.Count - 1 && ptsRawS[hi] - ptsRawS[failIdx] < _settings.RestoreForward) hi++;
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
			int steps = Math.Max(1, (int)Math.Ceiling(length / StationSpacingMetres));
			for (int s = 0; s < steps && pos < sn; s++) segOf[pos++] = k - 1;
		}
		var points = new V[sn];
		var skip = _hasAxis ? new byte[sn] : null;
		for (int k = 0; k < sn; k++)
		{
			points[k] = V.Of(st[k].X, st[k].Y);
			if (skip != null && _builder.AxisBlocked(points[k])) skip[k] = 1;
		}
		int failure = GeometryValidator.FirstProfileFailure(_probe, points, skip, Tile, ProfileBase, grade);
		return failure < 0 ? -1 : segOf[failure];
	}

	private void UpdateSeg(IReadOnlyList<P> pts, double[] midHeights, byte[] midBlocked, byte[] segBadArr, int k, GeometryValidator validator, double local)
	{
		P a = pts[k], b = pts[k + 1];
		double mx = (a.X + b.X) * 0.5, my = (a.Y + b.Y) * 0.5;
		midHeights[k] = _probe.GroundAt(mx * Tile, my * Tile);
		midBlocked[k] = (byte)(_hasAxis && _builder.AxisBlocked(V.Of(mx, my)) ? 1 : 0);
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
				lam = biharmonic ? _settings.BiharmonicEdgeStep : step;
			}
			double dx = (tx - prev[i].X) * lam, dy = (ty - prev[i].Y) * lam;
			if (dx * dx + dy * dy < _settings.MoveEpsSq) continue;
			bool ok = false;
			for (int attempt = 0; attempt < _settings.MoveRetries; attempt++, dx *= _settings.MoveRetryScale, dy *= _settings.MoveRetryScale)
			{
				if (dx * dx + dy * dy < _settings.MoveEpsSq) break;
				double mx = prev[i].X + dx, my = prev[i].Y + dy;
				V p = V.Of(mx, my);
				double dev = double.PositiveInfinity;
				for (int j = Math.Max(1, i - 3); j <= Math.Min(orig.Count - 1, i + 3); j++)
					dev = Math.Min(dev, p.DistanceSquaredTo(ClosestOnSegment(p, V.Of(orig[j - 1].X, orig[j - 1].Y), V.Of(orig[j].X, orig[j].Y))));
				if (dev > _settings.RoundCorridor * _settings.RoundCorridor) continue;
				if (_builder.AxisBlocked(p)) continue;
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

	private void PinAxisSpan(double[] rawS, byte[] rawPin, int k, int m)
	{
		for (int j = k; j >= 0 && rawS[k] - rawS[j] <= _settings.AxisPinCells + 1e-6; j--) rawPin[j] = 1;
		for (int j = k; j < m && rawS[j] - rawS[k] <= _settings.AxisPinCells + 1e-6; j++) rawPin[j] = 1;
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
	private bool ChordPoint(IReadOnlyList<P> pts, int k, int dir, double targetLen, out double px, out double py)
	{
		double rem = targetLen, walked = 0.0;
		int cur = k, n = pts.Count;
		while (true)
		{
			int next = cur + dir;
			if (next < 0 || next >= n)
			{
				if (walked >= _settings.MinTurnChord) { px = pts[cur].X; py = pts[cur].Y; return true; }
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

	private double TurnAngle4m(IReadOnlyList<P> pts, int k)
	{
		if (!ChordPoint(pts, k, -1, _settings.TurnChord, out double ax, out double ay)) return 0.0;
		if (!ChordPoint(pts, k, 1, _settings.TurnChord, out double cx, out double cy)) return 0.0;
		double vx0 = pts[k].X - ax, vy0 = pts[k].Y - ay;
		double vx1 = cx - pts[k].X, vy1 = cy - pts[k].Y;
		if (vx0 * vx0 + vy0 * vy0 < 1e-10 || vx1 * vx1 + vy1 * vy1 < 1e-10) return 0.0;
		return Math.Abs(Math.Atan2(vx0 * vy1 - vy0 * vx1, vx0 * vx1 + vy0 * vy1));
	}

	private double MaxTurnAngleWindow(IReadOnlyList<P> pts, int i)
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
			if (!ChordPoint(pts, k, -1, _settings.TurnChord, out double ax, out double ay)) continue;
			if (!ChordPoint(pts, k, 1, _settings.TurnChord, out double cx, out double cy)) continue;
			double bx = pts[k].X, by = pts[k].Y;
			double a = Math.Sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay));
			double b = Math.Sqrt((cx - bx) * (cx - bx) + (cy - by) * (cy - by));
			double c = Math.Sqrt((cx - ax) * (cx - ax) + (cy - ay) * (cy - ay));
			if (a < _settings.MinTurnChord || b < _settings.MinTurnChord) continue;
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
			int steps = Math.Max(1, (int)Math.Ceiling(sl * Tile / StationSpacingMetres));
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
					skip[cnt] = (byte)(_hasAxis && _builder.AxisBlocked(V.Of(px, py)) ? 1 : 0);
					cnt++;
				}
			}
			run += sl;
			along[cnt] = run;
			h[cnt] = heights[k + 1];
			skip[cnt] = blocked[k + 1];
			cnt++;
		}
		return GeometryValidator.FirstProfileFailure(along[..cnt], h[..cnt], skip[..cnt], Tile, ProfileBase, grade, from == 0) < 0;
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
		for (int attempt = 0; attempt < _settings.MoveRetries; attempt++, dx *= _settings.MoveRetryScale, dy *= _settings.MoveRetryScale)
		{
			if (dx * dx + dy * dy < _settings.MoveEpsSq) break;
			var moved = new P(keep.X + dx, keep.Y + dy, keep.W);
			V p = V.Of(moved.X, moved.Y);
			double deviation = double.PositiveInfinity;
			for (int j = Math.Max(1, i - 3); j <= Math.Min(orig.Count - 1, i + 3); j++)
				deviation = Math.Min(deviation, p.DistanceSquaredTo(ClosestOnSegment(p, V.Of(orig[j - 1].X, orig[j - 1].Y), V.Of(orig[j].X, orig[j].Y))));
			if (deviation > _settings.RoundCorridor * _settings.RoundCorridor) continue;
			if (_builder.AxisBlocked(p)) continue;
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
			midBlocked[i - 1] = (byte)(_hasAxis && _builder.AxisBlocked(V.Of(m0x, m0y)) ? 1 : 0);
			midBlocked[i] = (byte)(_hasAxis && _builder.AxisBlocked(V.Of(m1x, m1y)) ? 1 : 0);
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
		double roundRad = Deg(_settings.RoundAngle);
		double[] fracs = _mountain ? _settings.MountainRoundFractions : _settings.RoundFractions;
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
			if (la < 1e-6 || lb < 1e-6 || (la < _settings.RoundMinArm && lb < _settings.RoundMinArm)) { outp.Add(b); outpBlock.Add(blocked[i]); continue; }
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
				double r0 = la > _settings.RoundTrimLimit ? f * _settings.RoundTrimLimit / la : f;
				double r1 = lb > _settings.RoundTrimLimit ? f * _settings.RoundTrimLimit / lb : f;
				double p0x = b.X - ax * r0, p0y = b.Y - ay * r0;
				double p2x = b.X + bx * r1, p2y = b.Y + by * r1;
				double arcLen = Math.Sqrt((p0x - b.X) * (p0x - b.X) + (p0y - b.Y) * (p0y - b.Y))
							  + Math.Sqrt((p2x - b.X) * (p2x - b.X) + (p2y - b.Y) * (p2y - b.Y));
				int steps = Math.Max(2, (int)Math.Ceiling(arcLen / _settings.RoundSampling));
				bool valid = true;
				for (int s = 0; s <= steps; s++)
				{
					double t = (double)s / steps, u = 1.0 - t;
					double x = u * u * p0x + 2.0 * u * t * b.X + t * t * p2x;
					double y = u * u * p0y + 2.0 * u * t * b.Y + t * t * p2y;
					V vp = V.Of(x, y);
					if (_builder.AxisBlocked(vp)) { valid = false; break; }
					double dev = double.PositiveInfinity;
					V nearest = vp;
					for (int j = Math.Max(1, i - 3); j <= Math.Min(orig.Count - 1, i + 3); j++)
					{
						V q = ClosestOnSegment(vp, V.Of(orig[j - 1].X, orig[j - 1].Y), V.Of(orig[j].X, orig[j].Y));
						double d = vp.DistanceSquaredTo(q);
						if (d < dev) { dev = d; nearest = q; }
					}
					if (dev > _settings.RoundCorridor * _settings.RoundCorridor) { valid = false; break; }
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
			int steps = Math.Max(1, (int)Math.Ceiling(sl * Tile / StationSpacingMetres));
			for (int s = 1; s < steps; s++)
			{
				double t = (double)s / steps;
				double px = pa.X + dx * t, py = pa.Y + dy * t;
				along.Add(run + sl * t);
				heights.Add(_probe.GroundAt(px * Tile, py * Tile));
				stSkip.Add((byte)(_hasAxis && _builder.AxisBlocked(V.Of(px, py)) ? 1 : 0));
			}
			run += sl;
			along.Add(run);
			heights.Add(_probe.GroundAt(pb.X * Tile, pb.Y * Tile));
			stSkip.Add(skip[k]);
		}
		return GeometryValidator.FirstProfileFailure(CollectionsMarshal.AsSpan(along), CollectionsMarshal.AsSpan(heights),
			CollectionsMarshal.AsSpan(stSkip), Tile, ProfileBase, grade, atStart) < 0;
	}

	private bool WholeProfileOk(List<P> pts, double grade)
	{
		int n = pts.Count;
		if (n < 2) return true;
		var v = new V[n];
		var skip = _hasAxis ? new byte[n] : null;
		for (int k = 0; k < n; k++)
		{
			v[k] = V.Of(pts[k].X, pts[k].Y);
			if (skip != null && _builder.AxisBlocked(v[k])) skip[k] = 1;
		}
		return GeometryValidator.FirstProfileFailure(_probe, v, skip, Tile, ProfileBase, grade) < 0;
	}
}
