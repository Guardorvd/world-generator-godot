extends RefCounted
## 13.2: проект земли и маски воды по сегментам русла. Без узлов и изменения источника.
## Это ещё не публикация в игре: климат, меши и соседние растровые края проверяются отдельно.
const DEPTH := 0.8 / GameConfig.HS
const BANK := 0.15 / GameConfig.HS
const MAX_FILL := 0.012
const MAX_CUT := 0.02


static func prepare(region: Dictionary, network: Dictionary) -> Dictionary:
	var sample: Rect2i = region.sample_rect
	var rect: Rect2i = sample # один набор сегментов обрабатывает и общую полосу соседей
	var original: PackedFloat32Array = region.fields.h
	var ground := original.duplicate()
	var water := PackedFloat32Array()
	water.resize(original.size())
	water.fill(-INF)
	var mask := PackedByteArray()
	mask.resize(original.size())
	var bank_weight := PackedFloat32Array()
	bank_weight.resize(original.size())
	var reason := ""
	for river: Dictionary in network.rivers:
		var points: Array = river.points
		for k in range(1, points.size()):
			var a: Dictionary = points[k - 1]
			var b: Dictionary = points[k]
			var av := Vector2(a.x, a.y)
			var bv := Vector2(b.x, b.y)
			var delta := bv - av
			var reach := StageRivers.half_width(maxf(a.w, b.w)) / GameConfig.TILE + 1.0
			var lo := Vector2i(floori(minf(a.x, b.x) - reach), floori(minf(a.y, b.y) - reach))
			var hi := Vector2i(ceili(maxf(a.x, b.x) + reach), ceili(maxf(a.y, b.y) + reach))
			var bounds := Rect2i(lo, hi - lo).intersection(rect)
			for y in range(bounds.position.y, bounds.end.y):
				for x in range(bounds.position.x, bounds.end.x):
					var i := (y - sample.position.y) * sample.size.x + x - sample.position.x
					if region.fields.fixed[i] != 0 or region.fields.ocean[i] != 0: continue
					var p := Vector2(x + 0.5, y + 0.5)
					var t := (p - av).dot(delta) / maxf(delta.length_squared(), 1e-12)
					# Не продолжать профиль круглой заглушкой за вход/выход сегмента.
					# В общей полосе настоящий следующий сегмент предоставляет сосед.
					if t < 0.0 or t > 1.0: continue
					var distance := p.distance_to(av + delta * t)
					var width := StageRivers.half_width(lerpf(a.w, b.w, t)) / GameConfig.TILE
					if distance >= width + 1.0: continue
					var level := lerpf(a.e, b.e, t)
					var target: float
					if distance < width:
						target = level - DEPTH * (1.0 - pow(distance / width, 2.0))
					else:
						# Высокий естественный берег не надо срезать до уровня воды.
						# Поднимаем лишь низкую кромку, иначе возникал искусственный широкий ров.
						target = lerpf(maxf(original[i], level + BANK), original[i], smoothstep(0.0, 1.0, distance - width))
					if target - original[i] > MAX_FILL or original[i] - target > MAX_CUT:
						reason = "earthwork_limit"
						continue
					# У пересекающихся лент берём более глубокое дно; берег не засыпает русло.
					if distance < width:
						ground[i] = minf(ground[i], target) if mask[i] != 0 else target
						water[i] = maxf(water[i], level)
						mask[i] = 1
					elif mask[i] == 0:
						var weight := 1.0 - smoothstep(0.0, 1.0, distance - width)
						if weight > bank_weight[i] or weight == bank_weight[i] and target < ground[i]:
							ground[i] = target
							bank_weight[i] = weight
	# Не отдавать наполовину выполненные земляные работы как пригодную поверхность.
	if not reason.is_empty():
		ground = original.duplicate()
		water.fill(-INF)
		mask.fill(0)
	return {h = ground, water_level = water, river = mask, reason = reason,
		ready = reason.is_empty() and network.unresolved.is_empty()}
