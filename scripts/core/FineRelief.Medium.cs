using System;
using Godot;
using MeshArrays = Godot.Collections.Array;

public partial class FineRelief
{
	private void BuildMedium(int[] guard)
	{
		var shape = new float[_coarse.Length];
		var scratch = new float[shape.Length];
		Paint(shape, _width, _height, 0, 0, _tile, Form.Knoll, Parameter.Knoll);
		Paint(shape, _width, _height, 0, 0, _tile, Form.Hollow, Parameter.Hollow);
		Paint(shape, _width, _height, 0, 0, _tile, Form.Gully, Parameter.Gully);
		for (int k = 0; k < shape.Length; k++)
			shape[k] *= _weight[k];
		// Filter the masked shape as well: abrupt changes of rock or slope also introduce short wavelengths.
		BlurMedium(shape, scratch, true);
		BlurMedium(scratch, shape, false);

		ResetDistance(guard);
		for (int k = 0; k < guard.Length; k++)
			if (_weight[k] == 0.0f)
				guard[k] = 0;
		DistanceToGuard(guard);
		double fade = Setting(Parameter.MidFade);
		double limit = Math.Max(0.0, Setting(Parameter.MidDelta));
		for (int k = 0; k < shape.Length; k++)
		{
			double allowed = limit * _weight[k];
			shape[k] = (float)(Math.Clamp(shape[k], -allowed, allowed) * Smooth(0.0, fade, guard[k] * _tile));
		}
		LimitTriangleGrades(_coarse, shape, scratch, _width, _height, _tile, Setting(Parameter.FormGradeLimit), Setting(Parameter.MidGradeGain));
		// _coarse already owns a native copy. The cached plan retains its original heights.
		for (int k = 0; k < shape.Length; k++)
			if (shape[k] != 0.0f && scratch[k] != 0.0f)
				_coarse[k] = (float)(_coarse[k] + (double)shape[k] * scratch[k]);
	}

	private void BlurMedium(float[] source, float[] result, bool horizontal)
	{
		int stride = horizontal ? 1 : _width, last = horizontal ? _width - 1 : _height - 1;
		for (int z = 0; z < _height; z++)
		for (int x = 0; x < _width; x++)
		{
			int k = z * _width + x, at = horizontal ? x : z;
			double Value(int offset) => source[k + (Math.Clamp(at + offset, 0, last) - at) * stride];
			result[k] = (float)((Value(-2) + 4.0 * Value(-1) + 6.0 * source[k] + 4.0 * Value(1) + Value(2)) / 16.0);
		}
	}

	private double RiverLocal(double x, int z, out double dx, out double dz, out double toward)
	{
		double axis = _riverAxis[z * 2];
		double meander = (_riverAxis[(z + 1) * 2] - _riverAxis[(z - 1) * 2]) / (2.0 * _tile);
		dz = 1.0 / Math.Sqrt(1.0 + meander * meander);
		dx = meander * dz;
		toward = -Math.Sign(x - axis);
		return Math.Abs(x - axis) * dz - _riverAxis[z * 2 + 1];
	}

	private double MediumSite(Form kind, double x, int z, double grade, double hollow, ref double dx, ref double dz)
	{
		double shore = RiverLocal(x, z, out double axisX, out double axisZ, out double toward);
		double fade = Setting(Parameter.MidFade);
		if (kind == Form.Gully)
		{
			double curvature = Setting(Parameter.GullyCurvature);
			double across = toward * (dx * axisZ - dz * axisX);
			return Math.Max(0.0, across) * Band(Setting(Parameter.GullySlopeFrom), Setting(Parameter.GullySlopeTo), grade)
				* ShoreBand(Setting(Parameter.GullyNear), Setting(Parameter.GullyFar), shore, fade)
				* Smooth(-curvature, curvature, hollow);
		}
		(dx, dz) = (axisX, axisZ);
		double relief = Setting(Parameter.ShelfCurvature);
		return ShoreBand(Setting(Parameter.ShelfNear), Setting(Parameter.ShelfFar), shore, fade)
			* (1.0 - Smooth(0.0, Setting(Parameter.ShelfGrade), grade))
			* Smooth(-relief, relief, kind == Form.Hollow ? hollow : -hollow);
	}

	private static double ShoreBand(double near, double far, double distance, double fade)
		=> Smooth(near, near + fade, distance) * (1.0 - Smooth(far - fade, far, distance));

	/// <summary>Replace only the unprotected 4 m vertices of the immutable cached mesh.</summary>
	public MeshArrays ProjectCoarseMesh(MeshArrays arrays)
	{
		if (!_mediumForms || arrays.Count != (int)Mesh.ArrayType.Max)
			return arrays;
		var pos = arrays[(int)Mesh.ArrayType.Vertex].AsVector3Array();
		var normals = arrays[(int)Mesh.ArrayType.Normal].AsVector3Array();
		for (int i = 0; i < pos.Length; i++)
		{
			double fx = pos[i].X / _tile - 0.5, fz = pos[i].Z / _tile - 0.5;
			int x = (int)fx, z = (int)fz;
			if (fx != x || fz != z || _weight[z * _width + x] == 0.0f)
				continue;
			pos[i].Y = CoarseNode(x, z);
			normals[i] = FastGrid.TerrainGridNormal(_coarse, _width, _height, (float)_tile, x, z);
		}
		var projected = arrays.Duplicate();
		projected[(int)Mesh.ArrayType.Vertex] = pos;
		projected[(int)Mesh.ArrayType.Normal] = normals;
		return projected;
	}

	public MeshArrays BuildCoarseLod(int chunkX, int chunkZ, int step, float skirt)
		=> FastGrid.BuildTerrainLodArrays(_width, _height, (float)_tile, chunkX, chunkZ, _cells, step, _coarse, skirt);
}
