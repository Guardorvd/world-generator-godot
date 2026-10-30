extends SceneTree
const Friendly = preload("res://tools/bike_friendly_test.gd")
class LabUI extends "res://scripts/lab/trail_lab.gd":
	func rebuild(_candidate: Array[TrailDefinition], _compose_ms := -1.0, _ready := {}) -> bool:
		return true
var fails := 0
func check(ok: bool, message: String) -> void:
	print("recorder: ", "PASS " if ok else "FAIL ", message)
	if not ok: fails += 1
func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	run.call_deferred()
func run() -> void:
	var lab := LabUI.new()
	root.add_child(lab)
	lab.set_process(false)
	lab.set_physics_process(false)
	lab.heights = Friendly.TestGround.new(Friendly.TestWorld.new())
	var d := TrailDefinition.new()
	d.id = "test"
	d.title = "test"
	d.points = PackedVector2Array([Vector2(0, 0), Vector2(0, -100)])
	d.width = 4.0
	lab.routes = [d]
	lab.preset = 14
	var rec = lab.recorder
	rec.enabled = true
	rec.root = "res://tools/control/runs/recorder_integrity"
	rec.temp_root = rec.root + "/temp"
	lab.bike.x = 10.0
	lab.bike.y = 100.0
	lab.bike.z = -20.0
	lab.bike.riding = true
	lab.bike.speed = 8.0
	rec.begin(lab, "test")
	rec.tick(lab, 1.0 / 60, 1.0, 0.0, false, false)
	check(rec._rides[0].preset == 15 and rec._route_snapshots[0].preset == 15, "correct preset and per-ride geometry")
	lab.bike.airborne = true
	lab.bike.air_time = 0.5
	lab.bike.vy = -6.0
	lab.bike._land(100.0, lab.heights)
	check(lab.bike.landing_info.air == 0.5 and lab.bike.landing_info.vy == -6.0, "landing captures flight before reset")
	rec.tick(lab, 1.0 / 60, 0.0, 0.0, false, false)
	lab.bike.landing_info = {}
	lab.bike.speed = 8.0
	lab.bike._crash(-10.0)
	lab.bike.speed = 0.0
	check(lab.bike.crash_info.speed == 8.0, "crash preserves incoming speed")
	rec.tick(lab, 1.0 / 60, 0.0, 0.0, false, false)
	var path: String = rec.save(lab)
	check(not path.is_empty(), "session saves")
	check(path.get_file() == "ride" and path.get_base_dir().get_file().begins_with("ride_"), "each session has its own folder")
	for ext in [".csv", ".events.txt", ".header.json", ".summary.txt"]:
		check(FileAccess.file_exists(path + ext), "session contains " + ext)
	var file := FileAccess.open(path + ".csv", FileAccess.READ)
	var columns := file.get_csv_line()
	var row := file.get_csv_line()
	check(row.size() == columns.size() and row[columns.find("on_route")] == "0" and row[columns.find("nearest_valid")] == "1", "CSV distinguishes outside track from missing route")
	var header = JSON.parse_string(FileAccess.get_file_as_string(path + ".header.json"))
	check(header.format == 2 and header.route_snapshots.size() == 1, "versioned metadata")
	file.close()
	var stamp = rec._stamp.duplicate()
	lab.bike.reset_motion()
	lab.bike.riding = true
	lab.bike.speed = 8.0
	rec.begin(lab, "same-second save")
	rec._stamp = stamp
	rec.tick(lab, 1.0 / 60, 1.0, 0.0, false, false)
	var second: String = rec.save(lab)
	check(not second.is_empty() and second.get_base_dir() != path.get_base_dir() and FileAccess.file_exists(path + ".csv"), "same timestamp creates a separate folder without overwriting")
	lab.queue_free()
	await process_frame
	quit(1 if fails else 0)
