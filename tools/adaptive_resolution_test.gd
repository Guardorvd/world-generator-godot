extends SceneTree
## Изолированная проверка логики адаптивного разрешения (AdaptiveResolution): без окна, мира и рендера, секунды.
##   godot --headless --path . --script res://tools/adaptive_resolution_test.gd
const Adaptive := preload("res://scripts/render/adaptive_resolution.gd")
const DT := 1.0 / 60.0

var _failures := 0


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 30)
	var budget := Adaptive.budget_ms(60.0)
	_check(is_equal_approx(budget, 1000.0 / 60.0) and is_equal_approx(Adaptive.budget_ms(144.0), budget)
		and is_equal_approx(Adaptive.budget_ms(50.0), 20.0) and is_equal_approx(Adaptive.budget_ms(0.0), budget),
		"цель — 60 к/с; экран 50 Гц — его частота; неизвестная частота — 60")

	var a := Adaptive.new()
	_check(_run(a, 15.0, 10.0, budget) == 0 and a.level == 0, "15 мс при кадре 16,7 — полное разрешение 10 с без смен")

	a = Adaptive.new()
	var changes := 0
	for i in 600:
		changes += int(a.update(100.0 if i % 120 == 0 else 15.0, DT, budget))
	_check(changes == 0, "одиночные кадры по 100 мс раз в 2 с не опускают разрешение")

	# видеокарта «как в записи»: 22 мс при полном разрешении, цена пикселей ∝ площади
	a = Adaptive.new()
	var first_drop := -1.0
	var t := 0.0
	while t < 12.0:
		if a.update(_gpu(22.0, a.scale()), DT, budget) and first_drop < 0.0:
			first_drop = t
		t += DT
	_check(first_drop >= Adaptive.DROP_HOLD_S - DT and first_drop < Adaptive.DROP_HOLD_S + 0.2, "перегрузка опускает ступень через %.2f с" % first_drop)
	_check(a.level == 2 and is_equal_approx(a.scale(), 0.8), "22 мс: 90 % мало (≈18,6 мс) — ступень 80 %")
	_check(_run(a, -1.0, 10.0, budget, 22.0) == 0, "у 80 % (≈15,7 мс) ступень держится, не прыгает вверх-вниз")

	# нагрузка ушла: 12 мс при полном разрешении
	var t_up := _time_to_level(a, 12.0, budget, 0, 30.0)
	_check(a.level == 0 and t_up >= 2.0 * Adaptive.RAISE_HOLD_S, "запас возвращает полное разрешение по ступени, не раньше %.0f с (%.1f с)" % [2.0 * Adaptive.RAISE_HOLD_S, t_up])

	# пограничная нагрузка: 17 мс — одна ступень вниз, обратно не поднимается
	a = Adaptive.new()
	_run(a, -1.0, 20.0, budget, 17.0)
	_check(a.level == 1, "17 мс — 90 %% (≈13,8 мс) и без колебаний (ступень %d)" % a.level)
	_check(a.reset() and a.level == 0 and not a.reset(), "сброс возвращает 100 % один раз")
	_check(not a.update(30.0, DT, budget) and a.level == 0, "после смены кадры буферов не считаются")

	print("adaptive_resolution_test: %d failures" % _failures)
	quit(1 if _failures else 0)


## Время GPU при доле scale, если при 100 % оно full_ms: 15 % кадра не зависит от разрешения
static func _gpu(full_ms: float, scale: float) -> float:
	return full_ms * (0.15 + 0.85 * scale * scale)


## seconds кадров; gpu_ms ≥ 0 — постоянное время, иначе по модели _gpu от full_ms. Возвращает число смен.
func _run(a: Adaptive, gpu_ms: float, seconds: float, budget: float, full_ms := 0.0) -> int:
	var changes := 0
	for i in roundi(seconds / DT):
		changes += int(a.update(gpu_ms if gpu_ms >= 0.0 else _gpu(full_ms, a.scale()), DT, budget))
	return changes


func _time_to_level(a: Adaptive, full_ms: float, budget: float, level: int, limit: float) -> float:
	var t := 0.0
	while a.level != level and t < limit:
		a.update(_gpu(full_ms, a.scale()), DT, budget)
		t += DT
	return t


func _check(ok: bool, label: String) -> void:
	print(("OK " if ok else "FAIL ") + label)
	_failures += int(not ok)
