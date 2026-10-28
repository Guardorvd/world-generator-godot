extends SceneTree
## Аналитические поля без сида: континент не должен обрезать высоту горного массива.

class ConstantNoise extends Simplex:
	var value := 0.0
	func noise(_x: float, _y: float) -> float:
		return value
	func fbm(_x: float, _y: float, _oct: int, _lac := 2.0, _gain := 0.5) -> float:
		return 0.0
	func ridged(_x: float, _y: float, _oct: int) -> float:
		return 0.5

func _init() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	var zero := ConstantNoise.new()
	var cont := ConstantNoise.new()
	var ridge := ConstantNoise.new()
	ridge.value = 0.5
	var fails := 0
	var previous := 0.0
	for j in 21:
		cont.value = -0.3 + j * 0.025
		var raw := StageRelief.raw_at(zero, zero, cont, zero, ridge, zero, 0, 0, 0, 0, 1.0, 0.9, 1.0, 1.0)
		var uplift := raw - StageRelief._continental(cont, 0, 0, 0.15) * 0.55
		if j > 0 and absf(uplift - previous) > 0.000001:
			fails += 1
		previous = uplift
	cont.value = -0.1
	var bare := StageRelief.raw_at(zero, zero, cont, zero, ridge, zero, 0, 0, 0, 0, 1.0, 0.35, 1.0, 0.0)
	var foot := StageRelief.raw_at(zero, zero, cont, zero, ridge, zero, 0, 0, 0, 0, 1.0, 0.35, 1.0, 1.0)
	if foot - bare < 0.01:
		fails += 1
	print("Плавный переход континента под горами и предгорья у побережья: ошибок %d" % fails)
	quit(1 if fails else 0)
