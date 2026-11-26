using System;
using System.Collections.Generic;
using System.Numerics;
using Godot;
using Inputs = Godot.Collections.Dictionary;

public partial class FineRelief
{
	private enum Form { Rill, Swale, Hummock, ForestHummock, Windthrow }

	/// <summary>Число итераций Якоби точного ограничителя уклонов, верхний предел локальной доводки нарушивших граней и запас узлов вокруг плитки.</summary>
	private const int LimitPasses = 10;
	private const int FallbackPasses = 32;
	private const int TileMargin = 22;
	/// <summary>Запас точности float32 при записи высот плитки, м/м: убирает перехлёст на границе предела уклона.</summary>
	private const double GradePrecisionMargin = 1e-4;
	/// <summary>Пик функции (1 − q²)² · q² равен 4/27 при q² = 1/3; нормируем рёбрышко промоины к 1.</summary>
	private const double RimPeakScale = 27.0 / 4.0;
	/// <summary>Затухание промоины у истока и устья по доле длины, без резких краёв.</summary>
	private const double RillTaperStart = 0.15;
	private const double RillTaperEnd = 0.85;
	/// <summary>Минимальная доля веса защитной маски для постановки лесного вывала, чтобы корни не лезли на тропу/воду.</summary>
	private const float WindthrowMinWeight = 0.5f;
	private const int MaxTracePoints = 64;

	private double[] _formProfile;
	private byte[] _habitat;
	private byte[] _flowArea;
	private byte[] _flowDeposit;
	private byte[] _flowWet;
	private float[] _forestCover;
	private double[] _riverAxis;
	private long[] _formSeeds;
	private Vector2I _worldOrigin;

	private bool InitializeForms(Inputs input, double[] profile, int cells)
	{
		_habitat = input["biome"].AsByteArray();
		_forestCover = input["forest_cover"].AsFloat32Array();
		_riverAxis = input["river_axis"].AsFloat64Array();
		_formSeeds = input["form_seeds"].AsInt64Array();
		_worldOrigin = input["origin"].AsVector2I();
		_flowArea = input["flow_area"].AsByteArray();
		_flowDeposit = input["flow_deposit"].AsByteArray();
		_flowWet = input["flow_wet"].AsByteArray();
		_formProfile = profile;
		bool flowValid = (_flowArea.Length == 0 || _flowArea.Length == cells)
			&& _flowDeposit.Length == _flowArea.Length && _flowWet.Length == _flowArea.Length;
		return flowValid && _habitat.Length == cells && _riverAxis.Length == _height * 2
			&& _formSeeds.Length == (int)Form.Windthrow + 1 && _forestCover.Length > 0;
	}

	private long FormBytes() => _formProfile == null ? 0 : _habitat.LongLength
		+ _flowArea.LongLength + _flowDeposit.LongLength + _flowWet.LongLength
		+ _forestCover.LongLength * sizeof(float) + _riverAxis.LongLength * sizeof(double)
		+ _formProfile.LongLength * sizeof(double) + _formSeeds.LongLength * sizeof(long);

	private double Setting(Parameter key) => _formProfile[(int)key];

	private void BuildForms(float[] result, int width, int height, int gx, int gz)
	{
		// Запас в TileMargin узлов 2 м с каждой стороны, чтобы ограничитель уклона не зависел от границ плиток.
		int margin = TileMargin;
		int stride = width + 2 * margin, rows = height + 2 * margin;
		int originX = gx - margin, originZ = gz - margin;
		var baseH = new float[stride * rows];
		var shape = new double[baseH.Length];
		var lo = new double[baseH.Length];
		var hi = new double[baseH.Length];
		var raw = new float[baseH.Length];

		double rillReach = Setting(Parameter.RillLength) + Setting(Parameter.RillAcross) * (1.0 + Math.Max(0.0, Setting(Parameter.RillWiden)));
		var areaGrid = BuildAreaGrid(originX, originZ, stride, rows, rillReach);

		PaintRills(raw, areaGrid, stride, rows, originX, originZ);
		PaintWetDeposit(raw, stride, rows, originX, originZ);
		PaintForestHummocks(raw, stride, rows, originX, originZ);
		PaintWindthrows(raw, stride, rows, originX, originZ);

		for (int j = 0; j < rows; j++)
		for (int i = 0; i < stride; i++)
		{
			int x = ClampX(originX + i), z = ClampZ(originZ + j);
			int k = j * stride + i;
			double smooth = Reconstruct(x, z);
			baseH[k] = (float)smooth;
			int cell = CoarseQuad(x, z, out double u, out double v);
			double weight = Triangle(_weight, cell, _width, u, v);
			if (weight <= 0.0)
				continue;
			double existing = smooth - Triangle(_coarse, cell, _width, u, v);
			// Единый предел отклонения от треугольника 4 м (цель морфинга и опора объектов).
			lo[k] = Math.Min(0.0, -_maxOffset - existing);
			hi[k] = Math.Max(0.0, _maxOffset - existing);
			shape[k] = Math.Clamp(raw[k] * weight, lo[k], hi[k]);
		}

		LimitTriangleGrades(baseH, shape, lo, hi, stride, rows, _step, Setting(Parameter.FormGradeLimit), Setting(Parameter.FormGradeGain));
		for (int j = 0; j < height; j++)
		for (int i = 0; i < width; i++)
		{
			int k = (j + margin) * stride + i + margin;
			result[j * width + i] = (float)(baseH[k] + shape[k]);
		}
	}

	private readonly record struct AreaGrid(int X0, int Z0, int Width, int Height, float[] Values);

	/// <summary>Локальная сглаженная карта октав водосбора: убирает ступеньку сетки эрозии (grid_factor = 2) без копии на весь мир.</summary>
	private AreaGrid BuildAreaGrid(int originX, int originZ, int stride, int rows, double reachM)
	{
		if (_flowArea.Length == 0)
			return default;
		int pad = (int)Math.Ceiling(reachM / _tile) + 2;
		int x0 = Math.Clamp((int)Math.Floor(originX * 0.5) - pad, 0, _width - 1);
		int z0 = Math.Clamp((int)Math.Floor(originZ * 0.5) - pad, 0, _height - 1);
		int x1 = Math.Clamp((int)Math.Ceiling((originX + stride) * 0.5) + pad, x0, _width - 1);
		int z1 = Math.Clamp((int)Math.Ceiling((originZ + rows) * 0.5) + pad, z0, _height - 1);
		int w = x1 - x0 + 1, h = z1 - z0 + 1;
		var values = new float[w * h];
		// 3×3 биномиальный фильтр [1, 2, 1] × [1, 2, 1] / 16 по узлам 4 м.
		for (int j = 0; j < h; j++)
		{
			int z = z0 + j, zm = Math.Max(0, z - 1), zp = Math.Min(_height - 1, z + 1);
			for (int i = 0; i < w; i++)
			{
				int x = x0 + i, xm = Math.Max(0, x - 1), xp = Math.Min(_width - 1, x + 1);
				double sum = _flowArea[zm * _width + xm] + 2.0 * _flowArea[zm * _width + x] + _flowArea[zm * _width + xp]
					+ 2.0 * _flowArea[z * _width + xm] + 4.0 * _flowArea[z * _width + x] + 2.0 * _flowArea[z * _width + xp]
					+ _flowArea[zp * _width + xm] + 2.0 * _flowArea[zp * _width + x] + _flowArea[zp * _width + xp];
				values[j * w + i] = (float)(sum / (16.0 * TerrainErosion.AreaStepsPerOctave));
			}
		}
		return new AreaGrid(x0, z0, w, h, values);
	}

	private static double SampleAreaOctaves(in AreaGrid grid, double fx, double fz)
	{
		if (grid.Values == null)
			return 0.0;
		double lx = Math.Clamp(fx - grid.X0, 0.0, grid.Width - 1);
		double lz = Math.Clamp(fz - grid.Z0, 0.0, grid.Height - 1);
		int x = Math.Min((int)lx, Math.Max(0, grid.Width - 2));
		int z = Math.Min((int)lz, Math.Max(0, grid.Height - 2));
		int x1 = Math.Min(x + 1, grid.Width - 1), z1 = Math.Min(z + 1, grid.Height - 1);
		double u = lx - x, v = lz - z;
		int k = z * grid.Width + x, k1 = z1 * grid.Width + x;
		double a = grid.Values[k], b = grid.Values[z * grid.Width + x1];
		double c = grid.Values[k1], d = grid.Values[z1 * grid.Width + x1];
		return (a + (b - a) * u) * (1.0 - v) + (c + (d - c) * u) * v;
	}

	private double SampleByteMap(byte[] map, double fx, double fz, double scale)
	{
		if (map.Length == 0)
			return 0.0;
		fx = Math.Clamp(fx, 0.0, _width - 1);
		fz = Math.Clamp(fz, 0.0, _height - 1);
		int x = Math.Min((int)fx, _width - 2), z = Math.Min((int)fz, _height - 2);
		int x1 = Math.Min(x + 1, _width - 1), z1 = Math.Min(z + 1, _height - 1);
		double u = fx - x, v = fz - z;
		double a = map[z * _width + x], b = map[z * _width + x1];
		double c = map[z1 * _width + x], d = map[z1 * _width + x1];
		return ((a + (b - a) * u) * (1.0 - v) + (c + (d - c) * u) * v) * scale;
	}

	private void SampleGradient(double fx, double fz, out double downX, out double downZ, out double grade)
	{
		fx = Math.Clamp(fx, 0.0, _width - 1);
		fz = Math.Clamp(fz, 0.0, _height - 1);
		int x = Math.Min((int)fx, _width - 2), z = Math.Min((int)fz, _height - 2);
		double u = fx - x, v = fz - z;
		double inv = 0.5 / _tile;
		void NodeGrad(int nx, int nz, out double gx, out double gz)
		{
			gx = (At(nx - 1, nz) - At(nx + 1, nz)) * inv;
			gz = (At(nx, nz - 1) - At(nx, nz + 1)) * inv;
		}
		NodeGrad(x, z, out double ax, out double az);
		NodeGrad(x + 1, z, out double bx, out double bz);
		NodeGrad(x, z + 1, out double cx, out double cz);
		NodeGrad(x + 1, z + 1, out double dx, out double dz);
		downX = (ax + (bx - ax) * u) * (1.0 - v) + (cx + (dx - cx) * u) * v;
		downZ = (az + (bz - az) * u) * (1.0 - v) + (cz + (dz - cz) * u) * v;
		grade = Math.Sqrt(downX * downX + downZ * downZ);
	}

	/// <summary>Промоины, рёбрышки и непрерывные оси стока по карте водосбора A и падению hv.</summary>
	private void PaintRills(float[] output, in AreaGrid areaGrid, int stride, int rows, int gx, int gz)
	{
		if (areaGrid.Values == null)
			return;
		double spacing = Setting(Parameter.RillSpacing), length = Setting(Parameter.RillLength), traceStep = Setting(Parameter.RillStep);
		double acrossBase = Setting(Parameter.RillAcross), widen = Math.Max(0.0, Setting(Parameter.RillWiden));
		double depthMax = Setting(Parameter.RillDepth), minShare = Setting(Parameter.RillMinShare), cover = Setting(Parameter.RillCover);
		double slopeFrom = Setting(Parameter.RillSlopeFrom), slopeFull = Setting(Parameter.RillSlopeFull);
		double areaFrom = Setting(Parameter.RillAreaFrom), areaTo = Setting(Parameter.RillAreaTo);
		double rimShare = Setting(Parameter.RillRim), mergeShare = Setting(Parameter.RillMergeShare);
		double thalwegM = Setting(Parameter.RillThalwegM), thalwegArea = Setting(Parameter.RillThalwegArea);
		double thalwegRidgeOct = Setting(Parameter.RillThalwegRidgeOct);
		if (spacing <= 0.0 || length <= 0.0 || traceStep <= 0.0 || acrossBase <= 0.0 || depthMax <= 0.0 || cover <= 0.0)
			return;

		double cellArea = _tile * _tile;
		double areaFromOct = Math.Log2(Math.Max(cellArea, areaFrom) / cellArea);
		double areaToOct = Math.Log2(Math.Max(areaFrom * 2.0, areaTo) / cellArea);
		double thalwegOct = Math.Log2(Math.Max(cellArea, thalwegArea) / cellArea);
		double maxAcross = acrossBase * (1.0 + widen);
		double traceReach = length + maxAcross;

		double ox = _worldOrigin.X * _tile, oz = _worldOrigin.Y * _tile;
		double startX = ox + _tile * 0.5 + gx * _step, startZ = oz + _tile * 0.5 + gz * _step;
		double endX = startX + (stride - 1) * _step, endZ = startZ + (rows - 1) * _step;
		int x0 = (int)Math.Floor((startX - traceReach) / spacing), x1 = (int)Math.Floor((endX + traceReach) / spacing);
		int z0 = (int)Math.Floor((startZ - traceReach) / spacing), z1 = (int)Math.Floor((endZ + traceReach) / spacing);

		uint seed = (uint)_formSeeds[(int)Form.Rill];
		uint select = BitOperations.RotateLeft(seed, sizeof(uint) * 4);
		int maxPoints = Math.Clamp((int)Math.Ceiling(length / traceStep) + 1, 2, MaxTracePoints);

		var cutSq = new double[stride * rows];
		var ribSq = new double[stride * rows];
		Span<double> ptsX = stackalloc double[MaxTracePoints];
		Span<double> ptsZ = stackalloc double[MaxTracePoints];
		Span<double> ptsD = stackalloc double[MaxTracePoints];
		Span<double> ptsW = stackalloc double[MaxTracePoints];

		for (int z = z0; z <= z1; z++)
		for (int x = x0; x <= x1; x++)
		{
			if (FastGrid.MapHash(x, z, select) > cover)
				continue;
			double cx = (x + FastGrid.MapHash(x, z, seed)) * spacing;
			double cz = (z + FastGrid.MapHash(z, x, ~seed)) * spacing;
			int count = 0;
			double prevDx = 0.0, prevDz = 0.0;
			double minX = double.MaxValue, maxX = double.MinValue, minZ = double.MaxValue, maxZ = double.MinValue;
			for (int s = 0; s < maxPoints; s++)
			{
				double fx = (cx - ox) / _tile - 0.5, fz = (cz - oz) / _tile - 0.5;
				if (fx < 0.5 || fz < 0.5 || fx > _width - 1.5 || fz > _height - 1.5)
					break;
				SampleGradient(fx, fz, out double gxV, out double gzV, out double grade);
				if (grade < slopeFrom * 0.5)
					break;
				double dx = gxV / grade, dz = gzV / grade;
				if (count > 0 && dx * prevDx + dz * prevDz < 0.0)
					break;
				double areaOct = SampleAreaOctaves(in areaGrid, fx, fz);
				double slopeW = Smooth(slopeFrom, slopeFull, grade);
				double areaW = Smooth(areaFromOct, areaToOct, areaOct);
				double startW = Smooth(areaFromOct * 0.5, areaFromOct, areaOct);
				double d = depthMax * (minShare + (1.0 - minShare) * areaW) * slopeW * startW;
				double w = acrossBase * (1.0 + widen * areaW);
				ptsX[count] = cx;
				ptsZ[count] = cz;
				ptsD[count] = d;
				ptsW[count] = w;
				minX = Math.Min(minX, cx - w);
				maxX = Math.Max(maxX, cx + w);
				minZ = Math.Min(minZ, cz - w);
				maxZ = Math.Max(maxZ, cz + w);
				count++;
				prevDx = dx;
				prevDz = dz;
				cx += dx * traceStep;
				cz += dz * traceStep;
			}
			if (count < 2 || maxX < startX || minX > endX || maxZ < startZ || minZ > endZ)
				continue;
			for (int s = 0; s < count; s++)
			{
				double t = s / (double)(count - 1);
				ptsD[s] *= Smooth(0.0, RillTaperStart, t) * (1.0 - Smooth(RillTaperEnd, 1.0, t));
			}
			int xa = Math.Max(0, (int)Math.Ceiling((minX - startX) / _step));
			int xb = Math.Min(stride - 1, (int)Math.Floor((maxX - startX) / _step));
			int za = Math.Max(0, (int)Math.Ceiling((minZ - startZ) / _step));
			int zb = Math.Min(rows - 1, (int)Math.Floor((maxZ - startZ) / _step));
			for (int j = za; j <= zb; j++)
			{
				double vz = startZ + j * _step;
				for (int i = xa; i <= xb; i++)
				{
					double vx = startX + i * _step;
					double bestDist2 = double.MaxValue, bestD = 0.0, bestW = acrossBase;
					for (int s = 0; s < count - 1; s++)
					{
						double sx = ptsX[s + 1] - ptsX[s], sz = ptsZ[s + 1] - ptsZ[s];
						double len2 = sx * sx + sz * sz;
						double u = len2 > 0.0 ? Math.Clamp(((vx - ptsX[s]) * sx + (vz - ptsZ[s]) * sz) / len2, 0.0, 1.0) : 0.0;
						double dx = ptsX[s] + u * sx - vx, dz = ptsZ[s] + u * sz - vz;
						double dist2 = dx * dx + dz * dz;
						if (dist2 < bestDist2)
						{
							bestDist2 = dist2;
							bestD = ptsD[s] + u * (ptsD[s + 1] - ptsD[s]);
							bestW = ptsW[s] + u * (ptsW[s + 1] - ptsW[s]);
						}
					}
					if (bestD <= 0.0 || bestW <= 0.0)
						continue;
					double q2 = bestDist2 / (bestW * bestW);
					if (q2 >= 1.0)
						continue;
					double bell = Bell(q2);
					double cut = bestD * bell;
					int k = j * stride + i;
					cutSq[k] += cut * cut;
					if (rimShare > 0.0)
					{
						double rib = bestD * rimShare * RimPeakScale * bell * q2;
						ribSq[k] += rib * rib;
					}
				}
			}
		}

		// Непрерывные промоины по осям стока A: соединяют мелкие промоины с лощинами этапа 3.
		if (thalwegM > 0.0)
		{
			for (int j = 0; j < rows; j++)
			{
				double wz = startZ + j * _step;
				double fz = (wz - oz) / _tile - 0.5;
				for (int i = 0; i < stride; i++)
				{
					double wx = startX + i * _step;
					double fx = (wx - ox) / _tile - 0.5;
					double area0 = SampleAreaOctaves(in areaGrid, fx, fz);
					if (area0 <= thalwegOct)
						continue;
					SampleGradient(fx, fz, out double gxV, out double gzV, out double grade);
					if (grade < slopeFrom * 0.5)
						continue;
					double dx = gxV / grade, dz = gzV / grade;
					double areaW = Smooth(thalwegOct, areaToOct, area0);
					double w = acrossBase * (1.0 + widen * Smooth(areaFromOct, areaToOct, area0));
					double cross = (2.0 * w) / _tile;
					double areaL = SampleAreaOctaves(in areaGrid, fx - dz * cross, fz + dx * cross);
					double areaR = SampleAreaOctaves(in areaGrid, fx + dz * cross, fz - dx * cross);
					double ridge = area0 - 0.5 * (areaL + areaR);
					if (ridge <= 0.0)
						continue;
					double tDepth = thalwegM * Smooth(0.0, thalwegRidgeOct, ridge) * areaW * Smooth(slopeFrom, slopeFull, grade);
					cutSq[j * stride + i] += tDepth * tDepth;
				}
			}
		}

		double cap = depthMax * (1.0 + Math.Max(0.0, mergeShare));
		for (int k = 0; k < output.Length; k++)
		{
			double cut = Math.Sqrt(cutSq[k]);
			if (cut > 0.0 && cap > 0.0)
				cut = cut * cap / Math.Sqrt(cut * cut + cap * cap);
			double rib = Math.Sqrt(ribSq[k]) * (1.0 - Math.Min(1.0, depthMax > 0.0 ? cut / depthMax : 0.0));
			output[k] += (float)(rib - cut);
		}
	}

	/// <summary>Кочки и ложбинки по картам влажности W и наносов D (выносы и сырые поймы).</summary>
	private void PaintWetDeposit(float[] output, int stride, int rows, int gx, int gz)
	{
		if (_flowWet.Length == 0)
			return;
		double wetFrom = Setting(Parameter.SwaleWetFrom), wetTo = Setting(Parameter.SwaleWetTo);
		double depFrom = Setting(Parameter.SwaleDepositFrom), depTo = Setting(Parameter.SwaleDepositTo);
		double swaleGrade = Setting(Parameter.SwaleGrade), flowGrade = Setting(Parameter.SwaleFlowGrade);

		double DriveStrength(double fx, double fz, double grade)
		{
			double wet = SampleByteMap(_flowWet, fx, fz, 1.0 / byte.MaxValue);
			double dep = SampleByteMap(_flowDeposit, fx, fz, TerrainErosion.DepositStepM);
			double drive = Math.Max(Smooth(wetFrom, wetTo, wet), Smooth(depFrom, depTo, dep));
			return drive * (1.0 - Smooth(0.0, swaleGrade, grade));
		}

		// Ложбинки, ориентированные от оси реки на ровной пойме к направлению падения склона на выносах.
		double swSpacing = Setting(Parameter.SwaleSpacing), swAlong = Setting(Parameter.SwaleAlong), swAcross = Setting(Parameter.SwaleAcross);
		double swDepth = Setting(Parameter.SwaleDepth), swCover = Setting(Parameter.SwaleCover);
		if (swSpacing > 0.0 && swAlong > 0.0 && swAcross > 0.0 && swDepth > 0.0 && swCover > 0.0)
		{
			double reach = Math.Max(swAlong, swAcross);
			double ox = _worldOrigin.X * _tile, oz = _worldOrigin.Y * _tile;
			double startX = ox + _tile * 0.5 + gx * _step, startZ = oz + _tile * 0.5 + gz * _step;
			int x0 = (int)Math.Floor((startX - reach) / swSpacing), x1 = (int)Math.Floor((startX + (stride - 1) * _step + reach) / swSpacing);
			int z0 = (int)Math.Floor((startZ - reach) / swSpacing), z1 = (int)Math.Floor((startZ + (rows - 1) * _step + reach) / swSpacing);
			uint seed = (uint)_formSeeds[(int)Form.Swale];
			uint select = BitOperations.RotateLeft(seed, sizeof(uint) * 4);

			for (int z = z0; z <= z1; z++)
			for (int x = x0; x <= x1; x++)
			{
				if (FastGrid.MapHash(x, z, select) > swCover)
					continue;
				double sx = (x + FastGrid.MapHash(x, z, seed)) * swSpacing;
				double sz = (z + FastGrid.MapHash(z, x, ~seed)) * swSpacing;
				double fx = (sx - ox) / _tile - 0.5, fz = (sz - oz) / _tile - 0.5;
				int jx = (int)Math.Floor((sx - ox) / _tile), jz = (int)Math.Floor((sz - oz) / _tile);
				if (jx <= 0 || jz <= 0 || jx >= _width - 1 || jz >= _height - 1)
					continue;
				if (_weight[jz * _width + jx] == 0.0f)
					continue;
				SampleGradient(fx, fz, out double gxV, out double gzV, out double grade);
				double strength = DriveStrength(fx, fz, grade);
				if (strength <= 0.0)
					continue;
				RiverLocal(sx - ox, jz, out double dxR, out double dzR);
				double dx = dxR, dz = dzR;
				if (grade > 0.0 && flowGrade > 0.0)
				{
					double dxG = gxV / grade, dzG = gzV / grade;
					if (dx * dxG + dz * dzG < 0.0) { dx = -dx; dz = -dz; }
					double wFlow = Smooth(0.0, flowGrade, grade);
					dx = dx * (1.0 - wFlow) + dxG * wFlow;
					dz = dz * (1.0 - wFlow) + dzG * wFlow;
					double len = Math.Sqrt(dx * dx + dz * dz);
					if (len > 0.0) { dx /= len; dz /= len; } else { dx = dxR; dz = dzR; }
				}
				StampElliptic(output, stride, rows, startX, startZ, sx, sz, dx, dz, swAlong, swAcross, -swDepth * strength);
			}
		}

		// Сырые и наносные кочки.
		double hmSpacing = Setting(Parameter.HummockSpacing), hmRadius = Setting(Parameter.HummockRadius);
		double hmHeight = Setting(Parameter.HummockHeight), hmCover = Setting(Parameter.HummockCover);
		if (hmSpacing > 0.0 && hmRadius > 0.0 && hmHeight > 0.0 && hmCover > 0.0)
		{
			double ox = _worldOrigin.X * _tile, oz = _worldOrigin.Y * _tile;
			double startX = ox + _tile * 0.5 + gx * _step, startZ = oz + _tile * 0.5 + gz * _step;
			int x0 = (int)Math.Floor((startX - hmRadius) / hmSpacing), x1 = (int)Math.Floor((startX + (stride - 1) * _step + hmRadius) / hmSpacing);
			int z0 = (int)Math.Floor((startZ - hmRadius) / hmSpacing), z1 = (int)Math.Floor((startZ + (rows - 1) * _step + hmRadius) / hmSpacing);
			uint seed = (uint)_formSeeds[(int)Form.Hummock];
			uint select = BitOperations.RotateLeft(seed, sizeof(uint) * 4);

			for (int z = z0; z <= z1; z++)
			for (int x = x0; x <= x1; x++)
			{
				if (FastGrid.MapHash(x, z, select) > hmCover)
					continue;
				double sx = (x + FastGrid.MapHash(x, z, seed)) * hmSpacing;
				double sz = (z + FastGrid.MapHash(z, x, ~seed)) * hmSpacing;
				double fx = (sx - ox) / _tile - 0.5, fz = (sz - oz) / _tile - 0.5;
				int jx = (int)Math.Floor((sx - ox) / _tile), jz = (int)Math.Floor((sz - oz) / _tile);
				if (jx <= 0 || jz <= 0 || jx >= _width - 1 || jz >= _height - 1)
					continue;
				if (_weight[jz * _width + jx] == 0.0f)
					continue;
				SampleGradient(fx, fz, out _, out _, out double grade);
				double strength = DriveStrength(fx, fz, grade);
				if (strength <= 0.0)
					continue;
				StampElliptic(output, stride, rows, startX, startZ, sx, sz, 1.0, 0.0, hmRadius, hmRadius, hmHeight * strength);
			}
		}
	}

	private void PaintForestHummocks(float[] output, int stride, int rows, int gx, int gz)
	{
		double spacing = Setting(Parameter.ForestHummockSpacing), radius = Setting(Parameter.ForestHummockRadius);
		double height = Setting(Parameter.ForestHummockHeight), cover = Setting(Parameter.ForestHummockCover);
		if (spacing <= 0.0 || radius <= 0.0 || height <= 0.0 || cover <= 0.0)
			return;
		double ox = _worldOrigin.X * _tile, oz = _worldOrigin.Y * _tile;
		double startX = ox + _tile * 0.5 + gx * _step, startZ = oz + _tile * 0.5 + gz * _step;
		int x0 = (int)Math.Floor((startX - radius) / spacing), x1 = (int)Math.Floor((startX + (stride - 1) * _step + radius) / spacing);
		int z0 = (int)Math.Floor((startZ - radius) / spacing), z1 = (int)Math.Floor((startZ + (rows - 1) * _step + radius) / spacing);
		uint seed = (uint)_formSeeds[(int)Form.ForestHummock];
		uint select = BitOperations.RotateLeft(seed, sizeof(uint) * 4);

		for (int z = z0; z <= z1; z++)
		for (int x = x0; x <= x1; x++)
		{
			double chance = FastGrid.MapHash(x, z, select);
			if (chance > cover)
				continue;
			double sx = (x + FastGrid.MapHash(x, z, seed)) * spacing;
			double sz = (z + FastGrid.MapHash(z, x, ~seed)) * spacing;
			int jx = (int)Math.Floor((sx - ox) / _tile), jz = (int)Math.Floor((sz - oz) / _tile);
			if (jx <= 0 || jz <= 0 || jx >= _width - 1 || jz >= _height - 1)
				continue;
			int cell = jz * _width + jx;
			if (_weight[cell] == 0.0f)
				continue;
			double forest = _forestCover[_habitat[cell]];
			if (chance > cover * forest || forest <= 0.0)
				continue;
			StampElliptic(output, stride, rows, startX, startZ, sx, sz, 1.0, 0.0, radius, radius, height * forest);
		}
	}

	private void PaintWindthrows(float[] output, int stride, int rows, int gx, int gz)
	{
		double spacing = Setting(Parameter.WindthrowSpacing), along = Setting(Parameter.WindthrowAlong), across = Setting(Parameter.WindthrowAcross);
		double height = Setting(Parameter.WindthrowHeight), cover = Setting(Parameter.WindthrowCover);
		double pair = Setting(Parameter.WindthrowPair) * 0.5, pitShare = Setting(Parameter.WindthrowPitShare);
		if (spacing <= 0.0 || along <= 0.0 || across <= 0.0 || height <= 0.0 || cover <= 0.0)
			return;
		double reach = Math.Max(along + Math.Abs(pair), across);
		double ox = _worldOrigin.X * _tile, oz = _worldOrigin.Y * _tile;
		double startX = ox + _tile * 0.5 + gx * _step, startZ = oz + _tile * 0.5 + gz * _step;
		int x0 = (int)Math.Floor((startX - reach) / spacing), x1 = (int)Math.Floor((startX + (stride - 1) * _step + reach) / spacing);
		int z0 = (int)Math.Floor((startZ - reach) / spacing), z1 = (int)Math.Floor((startZ + (rows - 1) * _step + reach) / spacing);

		for (int z = z0; z <= z1; z++)
		for (int x = x0; x <= x1; x++)
		{
			if (!TryWindthrow(x, z, ox, oz, out _, out _, out double sx, out double sz, out double dx, out double dz, out double strength))
				continue;
			int xa = Math.Max(0, (int)Math.Ceiling((sx - reach - startX) / _step));
			int xb = Math.Min(stride - 1, (int)Math.Floor((sx + reach - startX) / _step));
			int za = Math.Max(0, (int)Math.Ceiling((sz - reach - startZ) / _step));
			int zb = Math.Min(rows - 1, (int)Math.Floor((sz + reach - startZ) / _step));
			double amp = height * strength;
			for (int j = za; j <= zb; j++)
			for (int i = xa; i <= xb; i++)
			{
				double px = startX + i * _step - sx, pz = startZ + j * _step - sz;
				double u = dx * px + dz * pz, v = dx * pz - dz * px;
				double q = v / across;
				double hill = (u - pair) / along, pit = (u + pair) / along;
				output[j * stride + i] += (float)(amp * (Bell(hill * hill + q * q) - pitShare * Bell(pit * pit + q * q)));
			}
		}
	}

	/// <summary>Единый источник пар «яма–бугор» вывала: вызывается и генератором поля 2 м, и раскладкой ROOT_UPTURNED.</summary>
	private bool TryWindthrow(int x, int z, double ox, double oz,
		out double moundX, out double moundZ, out double centerX, out double centerZ,
		out double dx, out double dz, out double strength)
	{
		moundX = moundZ = centerX = centerZ = dx = dz = strength = 0.0;
		double spacing = Setting(Parameter.WindthrowSpacing), cover = Setting(Parameter.WindthrowCover);
		double maxGrade = Setting(Parameter.WindthrowMaxGrade), pair = Setting(Parameter.WindthrowPair) * 0.5;
		uint seed = (uint)_formSeeds[(int)Form.Windthrow];
		uint select = BitOperations.RotateLeft(seed, sizeof(uint) * 4);
		double chance = FastGrid.MapHash(x, z, select);
		if (chance > cover)
			return false;
		centerX = (x + FastGrid.MapHash(x, z, seed)) * spacing;
		centerZ = (z + FastGrid.MapHash(z, x, ~seed)) * spacing;
		int jx = (int)Math.Floor((centerX - ox) / _tile), jz = (int)Math.Floor((centerZ - oz) / _tile);
		if (jx <= 0 || jz <= 0 || jx >= _width - 1 || jz >= _height - 1)
			return false;
		int cell = jz * _width + jx;
		if (_weight[cell] <= WindthrowMinWeight)
			return false;
		double forest = _forestCover[_habitat[cell]];
		if (chance > cover * forest || forest <= 0.0)
			return false;
		double fallX = (At(jx - 1, jz) - At(jx + 1, jz)) / (2.0 * _tile);
		double fallZ = (At(jx, jz - 1) - At(jx, jz + 1)) / (2.0 * _tile);
		if (Math.Sqrt(fallX * fallX + fallZ * fallZ) > maxGrade)
			return false;
		double angle = Math.Tau * FastGrid.MapHash(~x, ~z, select);
		dx = Math.Cos(angle);
		dz = Math.Sin(angle);
		moundX = centerX + dx * pair;
		moundZ = centerZ + dz * pair;
		int mx = (int)Math.Floor((moundX - ox) / _tile), mz = (int)Math.Floor((moundZ - oz) / _tile);
		if (mx <= 0 || mz <= 0 || mx >= _width - 1 || mz >= _height - 1 || _weight[mz * _width + mx] <= WindthrowMinWeight)
			return false;
		strength = forest;
		return true;
	}

	/// <summary>Координаты бугров и направления падения вывалов [moundX, moundZ, dx, dz, ...] в прямоугольнике мира, м.</summary>
	public double[] WindthrowSites(double x0, double z0, double x1, double z1)
	{
		if (!_smallForms || _formProfile == null)
			return Array.Empty<double>();
		double spacing = Setting(Parameter.WindthrowSpacing), cover = Setting(Parameter.WindthrowCover);
		double height = Setting(Parameter.WindthrowHeight), pair = Math.Abs(Setting(Parameter.WindthrowPair)) * 0.5;
		if (spacing <= 0.0 || cover <= 0.0 || height <= 0.0)
			return Array.Empty<double>();
		double ox = _worldOrigin.X * _tile, oz = _worldOrigin.Y * _tile;
		double pad = spacing + pair;
		int gx0 = (int)Math.Floor((x0 - pad) / spacing), gx1 = (int)Math.Floor((x1 + pad) / spacing);
		int gz0 = (int)Math.Floor((z0 - pad) / spacing), gz1 = (int)Math.Floor((z1 + pad) / spacing);
		var list = new List<double>();
		for (int z = gz0; z <= gz1; z++)
		for (int x = gx0; x <= gx1; x++)
		{
			if (!TryWindthrow(x, z, ox, oz, out double mx, out double mz, out _, out _, out double dx, out double dz, out _))
				continue;
			if (mx < x0 || mx > x1 || mz < z0 || mz > z1)
				continue;
			list.Add(mx);
			list.Add(mz);
			list.Add(dx);
			list.Add(dz);
		}
		return list.ToArray();
	}

	private void StampElliptic(float[] output, int stride, int rows, double startX, double startZ,
		double sx, double sz, double dx, double dz, double along, double across, double amp)
	{
		double reach = Math.Max(along, across);
		int xa = Math.Max(0, (int)Math.Ceiling((sx - reach - startX) / _step));
		int xb = Math.Min(stride - 1, (int)Math.Floor((sx + reach - startX) / _step));
		int za = Math.Max(0, (int)Math.Ceiling((sz - reach - startZ) / _step));
		int zb = Math.Min(rows - 1, (int)Math.Floor((sz + reach - startZ) / _step));
		for (int j = za; j <= zb; j++)
		for (int i = xa; i <= xb; i++)
		{
			double px = startX + i * _step - sx, pz = startZ + j * _step - sz;
			double u = dx * px + dz * pz, v = dx * pz - dz * px;
			double t = u / along, q = v / across;
			output[j * stride + i] += (float)(amp * Bell(t * t + q * q));
		}
	}

	/// <summary>Точный итеративный ограничитель уклонов треугольников: сглаживает только крутые грани по свободным вершинам
	/// (без глобального сжатия пологих форм).</summary>
	private static void LimitTriangleGrades(float[] baseH, double[] shape, double[] lo, double[] hi,
		int stride, int rows, double step, double gradeLimit, double gradeGain)
	{
		gradeGain = Math.Max(0.0, gradeGain);
		var accum = new double[shape.Length];
		var hits = new int[shape.Length];

		bool ProjectTriangle(int p0, int p1, int p2)
		{
			double bx = baseH[p1] - (double)baseH[p0], bz = baseH[p2] - (double)baseH[p0];
			double baseGrade = Math.Sqrt(bx * bx + bz * bz) / step;
			double allow = Math.Min(Math.Max(gradeLimit, baseGrade), baseGrade + gradeGain);
			double dx = bx + shape[p1] - shape[p0], dz = bz + shape[p2] - shape[p0];
			double grade = Math.Sqrt(dx * dx + dz * dz) / step;
			if (grade <= allow || grade <= 0.0)
				return false;
			double scale = allow / grade;
			double ex = dx * scale - dx, ez = dz * scale - dz;
			double w0 = lo[p0] < hi[p0] ? 1.0 : 0.0;
			double w1 = lo[p1] < hi[p1] ? 1.0 : 0.0;
			double w2 = lo[p2] < hi[p2] ? 1.0 : 0.0;
			double det = w0 * w1 + w0 * w2 + w1 * w2;
			double d0 = 0.0, d1 = 0.0, d2 = 0.0;
			if (det > 0.0)
			{
				double lam1 = ((w0 + w2) * ex - w0 * ez) / det;
				double lam2 = ((w0 + w1) * ez - w0 * ex) / det;
				d0 = -w0 * (lam1 + lam2);
				d1 = w1 * lam1;
				d2 = w2 * lam2;
			}
			else if (w0 > 0.0)
				d0 = -0.5 * (ex + ez);
			else if (w1 > 0.0)
				d1 = ex;
			else if (w2 > 0.0)
				d2 = ez;
			else
				return false;
			if (w0 > 0.0) { accum[p0] += d0; hits[p0]++; }
			if (w1 > 0.0) { accum[p1] += d1; hits[p1]++; }
			if (w2 > 0.0) { accum[p2] += d2; hits[p2]++; }
			return true;
		}

		for (int pass = 0; pass < LimitPasses; pass++)
		{
			Array.Clear(accum);
			Array.Clear(hits);
			bool violated = false;
			for (int j = 0; j < rows - 1; j++)
			for (int i = 0; i < stride - 1; i++)
			{
				int a = j * stride + i, b = a + 1, c = a + stride, d = c + 1;
				violated |= ProjectTriangle(a, b, c);
				violated |= ProjectTriangle(d, c, b);
			}
			if (!violated)
				break;
			for (int k = 0; k < shape.Length; k++)
				if (hits[k] > 0)
					shape[k] = Math.Clamp(shape[k] + accum[k] / hits[k], lo[k], hi[k]);
		}

		// Локальная доводка исключительно нарушивших треугольников (корректные грани не трогаются).
		var scaleArr = new double[shape.Length];
		bool ShrinkViolating(int p0, int p1, int p2)
		{
			double bx = baseH[p1] - (double)baseH[p0], bz = baseH[p2] - (double)baseH[p0];
			double baseGrade = Math.Sqrt(bx * bx + bz * bz) / step;
			double allow = Math.Min(Math.Max(gradeLimit, baseGrade), baseGrade + gradeGain);
			double sx = shape[p1] - shape[p0], sz = shape[p2] - shape[p0];
			double dx = bx + sx, dz = bz + sz;
			double grade = Math.Sqrt(dx * dx + dz * dz) / step;
			if (grade <= allow || grade <= 0.0)
				return false;
			double target = Math.Max(baseGrade, allow - GradePrecisionMargin);
			double aCoef = sx * sx + sz * sz;
			double bCoef = bx * sx + bz * sz;
			double cCoef = bx * bx + bz * bz - (target * step) * (target * step);
			double t = aCoef > 0.0 ? Math.Clamp((-bCoef + Math.Sqrt(Math.Max(0.0, bCoef * bCoef - aCoef * cCoef))) / aCoef, 0.0, 1.0) : 0.0;
			scaleArr[p0] = Math.Min(scaleArr[p0], t);
			scaleArr[p1] = Math.Min(scaleArr[p1], t);
			scaleArr[p2] = Math.Min(scaleArr[p2], t);
			return true;
		}

		for (int pass = 0; pass < FallbackPasses; pass++)
		{
			Array.Fill(scaleArr, 1.0);
			bool any = false;
			for (int j = 0; j < rows - 1; j++)
			for (int i = 0; i < stride - 1; i++)
			{
				int a = j * stride + i, b = a + 1, c = a + stride, d = c + 1;
				any |= ShrinkViolating(a, b, c);
				any |= ShrinkViolating(d, c, b);
			}
			if (!any)
				break;
			for (int k = 0; k < shape.Length; k++)
				if (scaleArr[k] < 1.0)
					shape[k] *= scaleArr[k];
		}
	}

	private void RiverLocal(double x, int z, out double dx, out double dz)
	{
		// Наклон оси реки по соседним рядам: направление вдоль реки.
		double meander = (_riverAxis[(z + 1) * 2] - _riverAxis[(z - 1) * 2]) / (2.0 * _tile);
		dz = 1.0 / Math.Sqrt(1.0 + meander * meander);
		dx = meander * dz;
		_ = x;
	}

	private static double Bell(double squared)
	{
		double t = Math.Max(0.0, 1.0 - squared);
		return t * t;
	}
}
