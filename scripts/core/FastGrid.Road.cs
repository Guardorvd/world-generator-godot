using System;
using Godot;
using Simd = System.Numerics.Vector<double>;

public partial class FastGrid
{
	private static double RoadSmooth(double a, double b, double x)
	{
		double t = Math.Clamp((x - a) / (b - a), 0.0, 1.0);
		return t * t * (3.0 - 2.0 * t);
	}
	private static double RoadLerp(double a, double b, double t) => a + (b - a) * t;
	// core/math/color.h promotes these constants to double before rounding the pow input.
	// Color.SrgbToLinear() in GodotSharp uses float constants and is not bit-identical.
	private static float RoadLinear(float c) => c < 0.04045f ? c * (1.0f / 12.92f)
		: (float)Math.Pow((float)((c + 0.055) * (1.0 / (1.0 + 0.055))), 2.4f);
	private static double RoadGround(float[] hs, int w, int h, double tile, double x, double z)
	{
		double fx = Math.Clamp(x / tile - 0.5, 0.0, w - 1.001);
		double fz = Math.Clamp(z / tile - 0.5, 0.0, h - 1.001);
		int ix = (int)Math.Floor(fx), iz = (int)Math.Floor(fz), i = iz * w + ix;
		double tx = fx - ix, tz = fz - iz;
		double a = hs[i], b = hs[i + 1], c = hs[i + w], d = hs[i + w + 1];
		return tx + tz <= 1.0 ? a + (b - a) * tx + (c - a) * tz
			: d + (c - d) * (1.0 - tx) + (b - d) * (1.0 - tz);
	}
	private static double RoadWet(float[] water, int w, int h, int cell)
	{
		int x = cell % w, z = cell / w;
		double top = double.NegativeInfinity;
		for (int k = 0; k < 8; k++)
		{
			int nx = x + Dx[k], nz = z + Dy[k];
			if (nx >= 0 && nz >= 0 && nx < w && nz < h) top = Math.Max(top, water[nz * w + nx]);
		}
		return top;
	}
	private static double RoadSegmentDistance(double x, double z, double[] axes, int at)
	{
		double ax = axes[at], az = axes[at + 1], dx = axes[at + 2] - ax, dz = axes[at + 3] - az;
		double l2 = dx * dx + dz * dz;
		double t = l2 > 0.0 ? Math.Clamp(((x - ax) * dx + (z - az) * dz) / l2, 0.0, 1.0) : 0.0;
		double ox = x - ax - dx * t, oz = z - az - dz * t;
		return Math.Sqrt(ox * ox + oz * oz);
	}

	/// <summary>Batch RoadRefinement._vertex. Input segments use 15 doubles; fits use interleaved
	/// profile/strength/limit triples. SIMD preserves the scalar multiply/add order (no FMA).
	/// Outside-world sampling is deliberately left to the GDScript fallback.</summary>
	public Godot.Collections.Dictionary RoadVertices(Vector2[] points, double[] nearest, int width, int height,
		double tile, float[] ground, float[] water, float[] distWater, FastNoiseLite noise, Vector2 origin,
		double[] segments, double[] fits, double[] surfaces, int[] structureStarts, double[] structures,
		double steepLo, double steepHi, double waterGap, bool simd)
	{
		int count = points.Length;
		var bases = new double[count]; var delta = new double[count]; var influence = new double[count];
		var pins = new double[count]; var power = new double[count]; var levels = new double[count];
		var caps = new double[count]; var details = new double[count]; var structurePins = new double[count];
		var cells = new int[count]; var values = new double[count];
		var hs = new float[count]; var colors = new Color[count]; var uv = new Vector2[count];
		var surface = new byte[count]; var roadFlags = new byte[count]; var routes = new int[count];
		Array.Fill(routes, -1);
		for (int n = 0; n < count; n++)
		{
			double x = points[n].X, z = points[n].Y;
			double baseHeight = RoadGround(ground, width, height, tile, x, z);
			bases[n] = baseHeight;
			int selected = (int)nearest[n * 4];
			if (selected < 0) continue;
			int at = selected * 15;
			double u = nearest[n * 4 + 1], distance = nearest[n * 4 + 2], side = nearest[n * 4 + 3];
			double half = segments[at + 5]; bool road = segments[at + 6] != 0;
			int from = (int)segments[at + 7], to = (int)segments[at + 8];
			int surf = u < 0.5 ? from : to;
			double slow = noise.GetNoise2D((float)((x + origin.X) * 0.13), (float)((z + origin.Y) * 0.13));
			double grain = noise.GetNoise2D((float)((x + origin.X) * 0.8 + 71.0), (float)((z + origin.Y) * 0.8));
			double edge = half + slow * 0.24 + grain * 0.10, shoulder = 0.7 + (slow + 1.0) * 0.3;
			double mask = 1.0 - RoadSmooth(edge * 0.55, edge + shoulder, distance);
			var ca = new Color((float)surfaces[from * 5], (float)surfaces[from * 5 + 1], (float)surfaces[from * 5 + 2]);
			var cb = new Color((float)surfaces[to * 5], (float)surfaces[to * 5 + 1], (float)surfaces[to * 5 + 2]);
			Color color = ca.Lerp(cb, (float)RoadSmooth(0.0, 1.0, u));
			color = new Color(RoadLinear(color.R), RoadLinear(color.G), RoadLinear(color.B));
			if (surf == 7) mask *= 0.65;
			double organic = RoadLerp(surfaces[from * 5 + 4], surfaces[to * 5 + 4], RoadSmooth(0.0, 1.0, u));
			double visualEdge = edge * (1.0 - organic * 0.12), visualShoulder = shoulder * (1.0 + organic * 0.5);
			color.A = (float)((1.0 - RoadSmooth(visualEdge * 0.55, visualEdge + visualShoulder, distance)) * (1.0 - organic * 0.35));
			colors[n] = color; uv[n] = new Vector2((float)(side / half), surf);
			surface[n] = (byte)surf; roadFlags[n] = road ? (byte)1 : (byte)0; routes[n] = (int)segments[at + 12];
			double reach = 1.0 - RoadSmooth(half + 0.3, half + 3.0, distance);
			influence[n] = reach;
			int cx = Math.Clamp((int)Math.Floor(x / tile), 0, width - 1), cz = Math.Clamp((int)Math.Floor(z / tile), 0, height - 1);
			int cell = cz * width + cx; cells[n] = cell;
			double pin = RoadSmooth(1.0, 2.5, distWater[cell]);
			if (!float.IsNegativeInfinity(water[cell])) pin = 0.0;
			int key = Math.Clamp((int)Math.Floor(z / tile - 0.5), 0, height - 2) * width
				+ Math.Clamp((int)Math.Floor(x / tile - 0.5), 0, width - 2);
			double structurePin = 1.0;
			for (int s = structureStarts[key]; s < structureStarts[key + 1]; s++)
				structurePin = Math.Min(structurePin, RoadSmooth(6.0, 10.0, RoadSegmentDistance(x, z, structures, s * 4)));
			structurePins[n] = structurePin; pin = Math.Min(pin, structurePin);
			double gx = RoadGround(ground, width, height, tile, x + 1.0, z) - RoadGround(ground, width, height, tile, x - 1.0, z);
			double gz = RoadGround(ground, width, height, tile, x, z + 1.0) - RoadGround(ground, width, height, tile, x, z - 1.0);
			pin *= 1.0 - RoadSmooth(steepLo, steepHi, new Vector2((float)gx, (float)gz).Length() * 0.5);
			pins[n] = pin;
			double rough = surfaces[surf * 5 + 3];
			double crown = 0.035 * (1.0 - RoadSmooth(0.0, half, distance));
			double rut = -0.045 * Math.Exp(-Math.Pow((distance - half * 0.48) / 0.3, 2.0));
			double detail = crown + rut + grain * (0.025 + rough * 0.12) + slow * 0.06 * (1.0 - mask);
			details[n] = detail;
			double limit = road ? 0.65 : 0.3;
			double target = RoadLerp(segments[at + 9], segments[at + 10], u) + detail;
			power[n] = 1.0;
			int fitCount = (int)segments[at + 14];
			if (fitCount > 0)
			{
				double station = Math.Clamp(segments[at + 11] + u * Math.Sqrt(segments[at + 4]), 0.0, fitCount - 1.0);
				int j = Math.Min(fitCount - 2, (int)Math.Floor(station)), offset = (int)segments[at + 13] + j * 3;
				double f = station - j;
				double level = RoadLerp(fits[offset], fits[offset + 3], f);
				power[n] = RoadLerp(fits[offset + 1], fits[offset + 4], f);
				limit = RoadLerp(fits[offset + 2], fits[offset + 5], f);
				levels[n] = level; target = level + detail;
			}
			caps[n] = limit;
			delta[n] = Math.Clamp(target - baseHeight, -limit, limit);
		}
		int pos = 0;
		if (simd && System.Numerics.Vector.IsHardwareAccelerated)
		{
			int lanes = Simd.Count;
			for (; pos <= count - lanes; pos += lanes)
			{
				var blended = new Simd(delta, pos) * new Simd(influence, pos);
				blended *= new Simd(pins, pos); blended *= new Simd(power, pos);
				(blended + new Simd(bases, pos)).CopyTo(values, pos);
			}
		}
		for (; pos < count; pos++) values[pos] = bases[pos] + delta[pos] * influence[pos] * pins[pos] * power[pos];
		for (int n = 0; n < count; n++)
		{
			double value = values[n], baseHeight = bases[n];
			int selected = (int)nearest[n * 4];
			if (selected >= 0)
			{
				int at = selected * 15, cell = cells[n];
				if ((int)segments[at + 14] > 0 && float.IsNegativeInfinity(water[cell]) && power[n] > 0.0)
				{
					var a = new Vector2((float)segments[at], (float)segments[at + 1]);
					var d = new Vector2((float)segments[at + 2], (float)segments[at + 3]);
					double half = segments[at + 5], u = nearest[n * 4 + 1];
					var normal = new Vector2(-d.Y, d.X).Normalized() * (float)half;
					var axis = a + d * (float)u;
					double cross = Math.Abs(RoadGround(ground, width, height, tile, axis.X + (double)normal.X, axis.Y + (double)normal.Y)
						- RoadGround(ground, width, height, tile, axis.X - (double)normal.X, axis.Y - (double)normal.Y)) / (2.0 * half);
					double bench = RoadSmooth(steepLo, steepHi, cross);
					if (bench > 0.0)
					{
						double level = roadFlags[n] != 0 ? levels[n] : RoadGround(ground, width, height, tile, axis.X, axis.Y);
						double dry = Math.Max(level + details[n], RoadWet(water, width, height, cell) + waterGap);
						double shelf = baseHeight + Math.Clamp(dry - baseHeight, -caps[n], caps[n]);
						value = RoadLerp(value, shelf, influence[n] * structurePins[n] * power[n] * bench);
					}
				}
				if (float.IsNegativeInfinity(water[cell]) && value < baseHeight)
					value = Math.Max(value, Math.Min(baseHeight, RoadWet(water, width, height, cell) + waterGap));
			}
			hs[n] = (float)value;
		}
		return new Godot.Collections.Dictionary { ["h"] = hs, ["color"] = colors, ["uv"] = uv,
			["surface"] = surface, ["road"] = roadFlags, ["route"] = routes };
	}
}
