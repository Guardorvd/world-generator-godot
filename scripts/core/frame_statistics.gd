extends RefCounted
## Общие определения метрик для стресс-теста и отчётов игровых сессий.

static func hitch_limit(typical_ms: float) -> float:
	return maxf(8.0, typical_ms * 2.0)


static func percentile(sorted: PackedFloat32Array, share: float) -> float:
	return sorted[mini(sorted.size() - 1, int(sorted.size() * share))] if not sorted.is_empty() else 0.0


static func tail_fps(sorted: PackedFloat32Array, divisor: int) -> float:
	if sorted.is_empty():
		return 0.0
	var count := maxi(1, sorted.size() / divisor)
	var total := 0.0
	for i in range(sorted.size() - count, sorted.size()):
		total += sorted[i]
	return snappedf(1000.0 * count / maxf(total, 0.001 * count), 0.1)


static func pipeline_counts() -> Vector4i:
	return Vector4i(
		int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_MESH)),
		int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_SURFACE)),
		int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_DRAW)),
		int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_CANVAS)))
