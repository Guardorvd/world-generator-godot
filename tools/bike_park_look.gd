extends SceneTree
## Изолированная проверка прокладки велопарка (BikePark.lay_out) без мира: синтетические холмы и неровная область,
## сводка трасс и картинка tools/control/runs/bike_park/look.png (2 м на пиксель). Секунды.
##   godot --headless --path . --script res://tools/bike_park_look.gd -- [--seed X] [--flat]
const OUT := "res://tools/control/runs/bike_park"


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var args := OS.get_cmdline_user_args()
	var seed: String = args[args.find("--seed") + 1] if "--seed" in args else "look"
	var flat := "--flat" in args
	var ground := func(p: Vector2) -> float:
		if flat: return 0.0
		return 35.0 * sin(p.x / 95.0) * cos(p.y / 130.0) + 0.12 * p.x + 6.0 * sin(p.y / 23.0 + p.x / 41.0)
	var inside := func(p: Vector2) -> bool:
		var q := p - Vector2(300, 300)
		return q.length() < 230.0 + 50.0 * sin(3.0 * q.angle())
	var park := BikePark.lay_out(ground, inside, Vector2(300, 300), 200.0, seed, "look")
	var total := 0.0
	for d in park.routes:
		var steep := 0.0
		var s := 0.0
		while s < d.route_length() - 4.0:
			steep = maxf(steep, absf(ground.call(d.point_at(s + 4.0)) - ground.call(d.point_at(s))) / 4.0)
			s += 4.0
		total += d.route_length()
		print("  %s: %.0f м, элементов %d, уклон земли до %.0f%%" % [d.title, d.route_length(), d.elements.size(), steep * 100.0])
	print("bike_park_look: трасс %d, %.0f м, попыток %d, прокладка %.0f мс, остановки %s" % [park.routes.size(), total, park.stats.attempts, park.stats.layout_ms, park.stats.stops])
	var n := 300
	var img := Image.create(n, n, false, Image.FORMAT_RGB8)
	for y in n:
		for x in n:
			var p := Vector2(x, y) * 2.0
			var v: float = ground.call(p)
			var c := Color(0.3, 0.3, 0.3) if not inside.call(p) else Color(0.5, 0.6, 0.4)
			img.set_pixel(x, y, c * (0.75 + 0.25 * sin(v / 3.0)))
	var colors := [Color.RED, Color.YELLOW, Color.CYAN, Color.MAGENTA, Color.ORANGE, Color.WHITE, Color.GREEN, Color.BLUE]
	for k in park.routes.size():
		var d := park.routes[k]
		var s := 0.0
		while s < d.route_length():
			var q := Vector2i(d.point_at(s) / 2.0)
			if q.x >= 0 and q.y >= 0 and q.x < n and q.y < n: img.set_pixelv(q, colors[k % colors.size()])
			s += 0.5
	img.save_png(ProjectSettings.globalize_path(OUT + "/look.png"))
	quit(0)
