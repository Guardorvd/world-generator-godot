extends SceneTree
## Коридоры сети трасс (TrailCoarseMap.trace с CORRIDOR сети) на одном мире без дорог и сборки трасс:
## сколько их и насколько они свёрнуты клубком. Прежний обзор (узлы 32 м) и текущий в одном запуске.
## godot --headless --path . --script res://tools/trail_corridor_probe.gd -- [--seed "Вальхейм 3"]
const Coarse := preload("res://scripts/trails/trail_coarse_map.gd")
const Search := preload("res://scripts/trails/trail_site_search.gd")
const Network := preload("res://scripts/trails/trail_world_network.gd")
const GI := preload("res://scripts/trails/trail_generation_input.gd")


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 150)
	var args := OS.get_cmdline_user_args()
	var seed_text := args[args.find("--seed") + 1] if "--seed" in args else "Вальхейм 3"
	var w := WorldGenerator._geography(seed_text, 768)
	var input = GI.from_world(w, null)
	for refine in [false, true]:
		Coarse.refine = refine
		var search := Search.new({size = w.W, seed = w.seed_num, heights = input.heights, water = input.water, input = input},
			{area = Rect2i(0, 0, w.W, w.H).grow(-Network.MARGIN), probe_budget = Network.PROBES, corridor = Network.CORRIDOR, rideable = true})
		var corridors := search.find(w.seed_num)
		var rows := []
		for c: Dictionary in corridors:
			rows.append(coil(c.probe.points))
		rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.density > b.density)
		var total := 0.0
		var coiled := 0
		for r: Dictionary in rows:
			total += r.length
			coiled += int(r.density > 5.0)
		print("%s коридоров %d, длина %.1f км, клубков (длина > 5 сторон своей области) %d; худшие: %s" % ["ТЕКУЩИЙ" if refine else "ПРЕЖНИЙ", rows.size(), total / 1000.0, coiled, str(rows.slice(0, 4))])
	quit(0)


## Доля точек коридора, рядом с которыми (ближе 72 м) проходит другой его виток (не ближайшие 8 точек по ходу).
func coil(points: PackedVector2Array) -> Dictionary:
	var near := 0
	for i in points.size():
		for j in points.size():
			if absi(i - j) > 8 and points[i].distance_to(points[j]) < 72.0:
				near += 1
				break
	var length := 0.0
	for i in range(1, points.size()): length += points[i].distance_to(points[i - 1])
	var box := Rect2(points[0], Vector2.ZERO)
	for p in points: box = box.expand(p)
	return {length = roundi(length), density = snappedf(length / sqrt(maxf(1.0, box.size.x * box.size.y)), 0.1), coil = snappedf(float(near) / maxi(1, points.size()), 0.01), box = Vector2i(box.size)}
