extends SceneTree
## Быстрый режим трасс (QuickTrails): папки кэша и сохранений и область сети. Без генерации мира, секунды.
## Запускать дважды: `-- --expect-quick` (с ключом `--quick-trails`) и без ключа (`-- --expect-normal`).
const SaveGame := preload("res://scripts/game/save_game.gd")
var failures := 0


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 30)
	var args := OS.get_cmdline_user_args()
	var quick := QuickTrails.FLAG in args
	check(QuickTrails.active() == quick, "режим включён только ключом %s (active=%s)" % [QuickTrails.FLAG, QuickTrails.active()])
	var cache := WorldCache.new()
	check((cache.dir == QuickTrails.CACHE_DIR) == quick, "папка кэша миров: %s" % cache.dir)
	check((SaveGame.dir == QuickTrails.SAVES_DIR) == quick, "папка сохранений: %s" % SaveGame.dir)
	check(quick or (cache.dir == "user://world_cache" and SaveGame.dir == "user://saves"), "обычный режим не меняет папки")
	cache.dir = "user://world_cache_quick_test"
	cache.reset()
	check((cache.dir == QuickTrails.CACHE_DIR) == quick, "reset() возвращает папку своего режима: %s" % cache.dir)
	var full := Rect2i(0, 0, 768, 768)
	check(QuickTrails.area(full) == Rect2i(256, 256, 256, 256), "область — средняя треть мира: %s" % QuickTrails.area(full))
	check(QuickTrails.options().length_target < load("res://scripts/trails/trail_world_network.gd").LENGTH_TARGET, "быстрая сеть короче обычной")
	print("QUICK TRAILS TEST ", failures, " failures")
	quit(1 if failures else 0)


func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	failures += int(not ok)
