extends "res://tools/control/perf.gd"
## Тот же мир, камера, освещение; --impostor-distance 0|80|180|100000.
const Impostors := preload("res://tools/impostor_layer.gd")
var installed := false


func _process(delta: float) -> bool:
	if not installed and main != null and main.game != null and main.game.player != null:
		var layer := Impostors.install(main.game)
		result.impostor = {distance = layer.switch_distance, shadows = layer.shadow_proxies,
			atlas = Dev.arg("atlas", "tools/control/runs/impostors65")}
		installed = true
	return super._process(delta)
