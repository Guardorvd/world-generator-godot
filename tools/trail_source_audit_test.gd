extends SceneTree
const Network := preload("res://scripts/trails/trail_world_network.gd")
var failures := 0

func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	failures += int(not ok)

func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 15)
	var site := TrailSite.new()
	site.size = Vector2i(16, 16)
	site.source = {seed_text = "clipped source", seed_num = 1}
	site.hv.resize(256); site.hv.fill(30)
	site.hv_raw = site.hv.duplicate()
	site.water_level.resize(256); site.water_level.fill(-INF)
	var values := PackedFloat32Array()
	values.resize(RoadRefinement.STRIDE * RoadRefinement.STRIDE); values.fill(50)
	var key := 14 * 16 + 14
	site.patches[key] = {h = values}
	site._prepare_template()
	var input := TrailGenerationInput.new()
	input.size = site.size
	input.water.resize(256); input.forbidden.resize(256); input.rivers.resize(256)
	input.earthwork_limits = Network.EARTHWORKS.duplicate()
	var source := site.surface()
	check(source.ground_at(62, 62) != values[-1], "clipped boundary samples coarse support rather than the saved patch vertex")
	check(Network.audit(site, source, input).is_empty(), "an unchanged source patch is zero earthworks even at a clipped boundary")
	if FileAccess.file_exists("res://.godot/network_before.gd"):
		check(not load("res://.godot/network_before.gd").audit(site, source, input).is_empty(), "uncapped old audit reproduces the false construction rejection")
	var changed := source.copy()
	var patch := {h = values.duplicate()}
	changed.road_refinement = RoadRefinement.from_patches({key: patch}, 16)
	patch.h[0] += 1
	check(Network.audit(site, changed, input).is_empty(), "a small real change is measured against saved vertices, not a different edge triangle")
	patch.h[0] += 8
	check(not Network.audit(site, changed, input).is_empty(), "real excavation/fill violations still reject the proposal")
	print("SOURCE AUDIT RESULT ", failures, " failures")
	quit(1 if failures else 0)
