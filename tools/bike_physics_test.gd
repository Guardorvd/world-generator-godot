extends SceneTree
## Продольная физика 5.1 на постоянном уклоне, без влияния случайного рельефа.

var fails := 0

func check(ok: bool, label: String) -> void:
	print(("✓ " if ok else "✗ ") + label)
	if not ok:
		fails += 1

func ride(initial: float, throttle: float, slope: float, seconds: float, boost := false, terrain := 1.0, hz := 60) -> BikeRide:
	var b := BikeRide.new()
	b.speed = initial
	for i in roundi(seconds * hz):
		b._step_speed(throttle, boost, slope, terrain, 1.0 / hz)
	return b

func _init() -> void:
	var start := ride(0.0, 1.0, 0.0, 0.5).speed
	check(start > 2.5 and start < 3.5, "отзывчивый старт: %.2f м/с за 0.5 с" % start)
	var cruise := ride(0.0, 1.0, 0.0, 25.0).speed
	check(absf(cruise - GameConfig.BIKE_SPEED) < 0.15, "плавный выход на крейсерскую: %.2f м/с" % cruise)
	check(ride(8.0, 1.0, 0.0, 0.5).speed - 8.0 < start * 0.5, "тяга плавно ослабевает с ростом скорости")
	var coast := ride(11.0, 0.0, 0.0, 2.0).speed
	check(coast > 8.6 and coast < 10.0, "накат сохраняет ход: %.2f м/с через 2 с" % coast)
	check(ride(1.0, 0.0, 0.0, 5.0).speed == 0.0, "накат останавливается без дрожания и смены направления")
	check(ride(0.0, 0.0, -0.15, 3.0).speed > 1.5, "спуск разгоняет без педалей")
	check(ride(8.0, 0.0, 0.15, 2.0).speed < ride(8.0, 0.0, 0.0, 2.0).speed, "подъём съедает инерцию")
	check(ride(0.0, 0.0, 0.3, 3.0).speed == 0.0, "в подъём нет самопроизвольного отката")
	check(ride(0.0, 1.0, 0.15, 20.0).speed < cruise, "под педалями подъём медленнее равнины")
	var fast := ride(18.0, 1.0, -0.3, 0.1).speed
	check(fast > 17.0, "педали не обрезают скорость спуска")
	check(ride(11.0, 1.0, 0.0, 0.1).speed > 10.99, "педали поддерживают крейсерскую скорость")
	check(ride(0.0, 1.0, 0.0, 25.0, true).speed > cruise * 1.25, "Shift даёт дополнительную тягу")
	check(ride(11.0, 0.0, 0.0, 2.0, true).speed == coast, "Shift не меняет накат без педалей")
	check(ride(8.0, 0.0, 0.0, 2.0, false, 0.6).speed < ride(8.0, 0.0, 0.0, 2.0).speed, "мягкое покрытие сильнее замедляет")
	var brake := ride(11.0, -1.0, -0.3, 1.6)
	check(brake.speed == 0.0, "торможение со спуска до остановки без заднего хода")
	check(ride(0.0, -1.0, -0.3, 0.3).speed == 0.0, "тормоз удерживает на склоне")
	check(ride(0.0, -1.0, 0.0, 1.0).speed == -GameConfig.BIKE_REVERSE, "задний ход после паузы")
	check(ride(-1.5, 1.0, 0.0, 0.1).speed < 0.0, "смена направления проходит через торможение")
	var slow_tick := ride(0.0, 1.0, -0.1, 5.0, false, 1.0, 30).speed
	var fast_tick := ride(0.0, 1.0, -0.1, 5.0, false, 1.0, 120).speed
	check(absf(slow_tick - fast_tick) < 0.1, "близкий результат при 30 и 120 тактах/с")
	quit(1 if fails else 0)
