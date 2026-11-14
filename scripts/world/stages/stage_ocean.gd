class_name StageOcean
extends RefCounted
## Этап 2. Вся местность ниже уровня моря покрыта общей океанской плоскостью.
## Пишет: w.ocean (1 — океан); с 14.11.2026 (GEO 19) и w.h у мелких замкнутых понижений.
## Мелкие понижения ниже нуля посреди суши (не связаны с краем плана, меньше POCKET_DRY клеток) — не море,
## а сухие влажные ложбины: дно поднимается чуть выше уровня моря (POCKET_RIM у края, вдвое ниже в середине).
## Без этого обычный мир получал 15–35 таких «прудов» с пляжами на уровне моря. Крупные остаются водой.
## Понижения у края плана не трогаются: за краем OuterLand продолжает тот же рельеф, стык не меняется.

const PROGRESS := 0.16
const LABEL := "Наполнение океанов"
const POCKET_DRY := 3000   # клеток (~5 га): меньше — сухая ложбина, больше — вода, как раньше
const POCKET_RIM := 0.002  # высота дна у края ложбины в единицах WorldData.h (~0,5 м)
## false — прежнее поведение (все понижения ниже нуля — море), для сравнения в стендах
static var dry_pockets := true


static func run(w: WorldData) -> void:
	var N := w.N
	var W := w.W
	var h := w.h
	var ocean := PackedByteArray()
	ocean.resize(N)
	for i in N:
		ocean[i] = int(h[i] < 0.0)
	if dry_pockets:
		var dried := 0
		var seen := PackedByteArray()
		seen.resize(N)
		for s in N:
			if ocean[s] == 0 or seen[s] != 0:
				continue
			# Связная часть «моря» (4 соседа): касается ли края плана и сколько в ней клеток
			var cells := PackedInt32Array([s])
			seen[s] = 1
			var head := 0
			var edge := false
			while head < cells.size():
				var c := cells[head]
				head += 1
				var x := c % W
				var y := c / W
				if x == 0 or y == 0 or x == W - 1 or y == w.H - 1:
					edge = true
				if x > 0 and ocean[c - 1] != 0 and seen[c - 1] == 0:
					seen[c - 1] = 1
					cells.append(c - 1)
				if x < W - 1 and ocean[c + 1] != 0 and seen[c + 1] == 0:
					seen[c + 1] = 1
					cells.append(c + 1)
				if y > 0 and ocean[c - W] != 0 and seen[c - W] == 0:
					seen[c - W] = 1
					cells.append(c - W)
				if y < w.H - 1 and ocean[c + W] != 0 and seen[c + W] == 0:
					seen[c + W] = 1
					cells.append(c + W)
			if edge or cells.size() >= POCKET_DRY:
				continue
			for c in cells:
				ocean[c] = 0
				h[c] = POCKET_RIM * (1.0 - 0.5 * smoothstep(0.0, 0.1, -h[c]))
			dried += cells.size()
		w.h = h
		w.generation_profile.dried_pocket_cells = dried
	w.ocean = ocean
