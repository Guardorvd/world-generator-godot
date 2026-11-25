extends SceneTree
## Эрозия плана без окна и без генерации мира (план части 2, этап 3): фикстура relief_fine_fixture хранит поверхность
## до эрозии, restore прогоняет ReliefErosion с текущими настройками river_expedition.tres. Печатает время, глубины,
## повтор (детерминизм) и пишет карту erosion_map.png: отмывка до, после, изменение высот (красное — снято, синее —
## насыпано), водосбор. Секунды на сид. --seeds a,b — сиды, --tag — папка прогона.

const Fixture := preload("res://tools/relief_fine_fixture.gd")
const Metrics := preload("res://tools/relief_fine_metrics.gd")
const Dev := preload("res://tools/control/control.gd")


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 120)
	var failures := 0
	for seed: String in Dev.arg("seeds", Fixture.SEEDS[0]).split(",", false):
		var fixture := Fixture.restore(seed)
		if fixture.is_empty():
			printerr("EROSION_FAIL нет фикстуры ", seed)
			failures += 1
			continue
		var folder := Fixture.DIR.path_join(Dev.arg("tag", "erosion")).path_join(seed)
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
		var h: Heightfield = fixture.heights
		var report := Metrics.erosion_report(h, folder.path_join("erosion_map.png"))
		if report.is_empty():
			printerr("EROSION_FAIL эрозия выключена или не прошла ", seed)
			failures += 1
			continue
		if "--repeat" in OS.get_cmdline_user_args():
			var again := Fixture.restore(seed)
			report.repeat_identical = again.heights.hv == h.hv and again.heights.relief_flow == h.relief_flow
			failures += int(not report.repeat_identical)
		print("EROSION ", seed, " ", JSON.stringify(report))
	print("EROSION_RESULT failures=", failures)
	quit(int(failures > 0))
