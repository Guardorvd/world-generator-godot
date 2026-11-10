class_name StageOcean
extends RefCounted
## Этап 2. Вся местность ниже уровня моря покрыта общей океанской плоскостью.
## Пишет: w.ocean (1 — океан).

const PROGRESS := 0.16
const LABEL := "Наполнение океанов"


static func run(w: WorldData) -> void:
	var ocean := PackedByteArray()
	ocean.resize(w.N)
	for i in w.N:
		ocean[i] = int(w.h[i] < 0.0)
	w.ocean = ocean