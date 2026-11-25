extends SceneTree
## Проверка исходных массивов поверхности и физики без окна и GPU. Использует обе сохранённые фикстуры.

const Fixture := preload("res://tools/relief_fine_fixture.gd")
const Metrics := preload("res://tools/relief_fine_metrics.gd")


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 45)
	_run.call_deferred()


func _run() -> void:
	var failures := 0
	var rows: Array = []
	for seed in Fixture.SEEDS:
		var started := Time.get_ticks_msec()
		var fixture := Fixture.restore(seed)
		if fixture.is_empty():
			printerr("RELIEF_FAIL отсутствует фикстура ", seed)
			failures += 1
			continue
		var h: Heightfield = fixture.heights
		var chunks := TerrainBuilder.build_chunks(fixture.world, h)
		for i in fixture.views.size():
			var view: Dictionary = fixture.views[i]
			var pieces := []
			for key: Vector2i in chunks:
				if Metrics.near_view(key, Vector2(view.eye.x, view.eye.z), view.focus):
					pieces.append(chunks[key])
			var row := Metrics.mesh_stats(pieces, h, view.eye, view.focus, true)
			row.seed = seed
			row.name = Fixture.VIEW_NAMES[i]
			row.energy_pct = Metrics.spectrum(h, view.focus)
			if row.parity_samples == 0 or row.parity_failed != 0 or row.natural_edge_m == 0.0:
				printerr("RELIEF_FAIL ", seed, " ", row.name)
				failures += 1
			rows.append(row)
			print("RELIEF_GEOMETRY ", JSON.stringify(row))
		print("RELIEF_GEOMETRY_SEED ", seed, " ms=", Time.get_ticks_msec() - started)
	var report := FileAccess.open(Fixture.DIR.path_join("baseline_geometry.json"), FileAccess.WRITE)
	if report == null:
		failures += 1
	else:
		report.store_string(JSON.stringify(rows, "\t"))
	print("RELIEF_GEOMETRY_RESULT failures=", failures)
	quit(int(failures > 0))
