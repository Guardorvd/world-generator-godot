using System;
using System.Collections.Generic;
using P = Roads.Network.LineBuilder.P;
using V = Roads.Network.LineBuilder.V;

namespace Roads.Network;

internal sealed partial class AxisAlignment
{
	internal record MeanderSettings(double MinLength, double Fit, double Search, double MinShift, double Slope, double SlopeFade, V WaterFade,
		V Amplitude, V Wavelength, double EndFade, double Radius);

	internal void FitMeanders(double[] noise, double[] waterDistance, MeanderSettings settings)
	{
		foreach (var (first, last) in StraightSpans(settings.MinLength / Tile, settings.Fit / Tile, settings.Search / Tile))
		{
			double length = _along[last] - _along[first];
			V normal = (At(_source[last]) - At(_source[first])).Normalized().Orthogonal();
			double targetWave = Lerp(settings.Wavelength, NoiseAt(first, last, 0.5)) / Tile;
			int spans = Math.Max(1, (int)Math.Round(length / targetWave));
			for (int k = 0; k < spans; k++)
			{
				int a = k == 0 ? first : AtOrBefore(_along[first] + k * length / spans);
				int b = k + 1 == spans ? last : AtOrBefore(_along[first] + (k + 1) * length / spans);
				double amplitude = Lerp(settings.Amplitude, NoiseAt(a, b, 0.25)) / Tile;
				double wavelength = Lerp(settings.Wavelength, NoiseAt(a, b, 0.5)) / Tile;
				double phase = Math.Tau * NoiseAt(a, b, 0.75);
				FitWave(a, b, normal, amplitude, wavelength, phase, waterDistance, settings);
			}
		}

		double NoiseAt(int first, int last, double fraction)
		{
			double station = _along[first] + fraction * (_along[last] - _along[first]);
			int index = AtOrBefore(station);
			if (index >= last || _along[index + 1] == _along[index]) return Math.Clamp(0.5 + 0.5 * noise[index], 0, 1);
			double t = (station - _along[index]) / (_along[index + 1] - _along[index]);
			return Math.Clamp(0.5 + 0.5 * (noise[index] + (noise[index + 1] - noise[index]) * t), 0, 1);
		}
	}

	// Slide the initial chord inside each free interval. A small bend at one end
	// must not hide the straight run behind it.
	private IEnumerable<(int First, int Last)> StraightSpans(double minLength, double tolerance, double step)
	{
		int first = 0;
		for (int protectedEnd = 1; protectedEnd < _source.Count; protectedEnd++)
		{
			if (!_protected[protectedEnd]) continue;
			while (_along[protectedEnd] - _along[first] > minLength)
			{
				int end = AtOrBefore(_along[first] + minLength) + 1;
				if (!Straight(first, end, tolerance))
				{
					first = Math.Min(protectedEnd, AtOrBefore(_along[first] + step) + 1);
					continue;
				}
				while (end < protectedEnd)
				{
					int next = Math.Min(protectedEnd, AtOrBefore(_along[end] + step) + 1);
					if (!Straight(first, next, tolerance)) break;
					end = next;
				}
				yield return (first, end);
				first = end;
			}
			first = protectedEnd;
		}
	}

	private bool Straight(int first, int last, double tolerance)
	{
		V a = At(_source[first]), b = At(_source[last]);
		if (a.DistanceTo(b) + tolerance < _along[last] - _along[first]) return false;
		for (int k = first + 1; k < last; k++)
		{
			V point = At(_source[k]);
			if (point.DistanceSquaredTo(LineBuilder.ClosestOnSegment(point, a, b)) >= tolerance * tolerance) return false;
		}
		return true;
	}

	private void FitWave(int first, int last, V normal, double amplitude, double wavelength, double phase,
		double[] waterDistance, MeanderSettings settings)
	{
		double length = _along[last] - _along[first];
		if (length <= 0) return;
		var points = new List<P> { _source[first] };
		double most = 0;
		for (int i = first + 1; i <= last; i++)
		{
			P a = _source[i - 1], b = _source[i];
			double segment = _along[i] - _along[i - 1];
			int steps = Math.Max(1, (int)Math.Ceiling(segment / Sample));
			for (int k = 1; k <= steps; k++)
			{
				double t = k / (double)steps;
				double fromStart = _along[i - 1] - _along[first] + t * segment;
				double x = a.X + t * (b.X - a.X), y = a.Y + t * (b.Y - a.Y);
				double grade = _validator.TerrainGrade(x, y);
				double dry = waterDistance[i - 1] + t * (waterDistance[i] - waterDistance[i - 1]);
				double fade = Smooth(Math.Min(fromStart, length - fromStart) * Tile / settings.EndFade)
					* Smooth((settings.Slope - grade) / (settings.Slope - settings.SlopeFade))
					* Smooth((dry - settings.WaterFade.X) / (settings.WaterFade.Y - settings.WaterFade.X));
				double offset = amplitude * fade * Math.Sin(Math.Tau * fromStart / wavelength + phase);
				most = Math.Max(most, Math.Abs(offset));
				points.Add(new P(x + normal.X * offset, y + normal.Y * offset, b.W));
			}
		}
		if (most * Tile < settings.MinShift) { Reject("fade"); return; }
		points[^1] = _source[last];
		TrySplice(first, last, points, settings.Radius);
	}

	private static double Smooth(double t)
	{
		t = Math.Clamp(t, 0.0, 1.0);
		return t * t * (3.0 - 2.0 * t);
	}

	private static double Lerp(V bounds, double t) => bounds.X + t * (bounds.Y - bounds.X);
}
