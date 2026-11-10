extends SceneTree
const Floor = preload("res://scripts/render/forest_floor.gd")
var fails := 0
func check(ok: bool, label: String) -> void:
	if not ok:
		fails += 1
		printerr(label)
func _initialize() -> void:
	var w := WorldData.new()
	w.W = 32
	w.H = 32
	w.N = w.W * w.H
	w.CS = 16
	w.CW = 2
	w.CH = 2
	w.path_mask.resize(w.N)
	w.biome.resize(w.N)
	w.biome.fill(Biomes.GRASS)
	w.river.resize(w.N)
	w.moist.resize(w.N)
	w.dist_water.resize(w.N)
	w.elev.resize(w.N)
	w.slope.resize(w.N)
	w.generation.surface_rock.resize(w.N)
	w.obj_x = PackedFloat64Array([15.8, 18.2])
	w.obj_y = PackedFloat64Array([16.1, 17.5])
	w.obj_k = PackedInt32Array([Biomes.T_PINE, Biomes.T_BIRCH])
	w.obj_s = PackedFloat64Array([1.4, 1.1])
	w.obj_count = 2
	var rect := Rect2i(0, 0, w.W, w.H)
	var actual := Floor.canopy_image(rect, [{x=w.obj_x, y=w.obj_y, k=w.obj_k, s=w.obj_s}])
	var reference := Floor.surface_image(w)
	for y in w.H:
		for x in w.W:
			check(actual.get_pixel(x, y).r == reference.get_pixel(x, y).r and actual.get_pixel(x, y).g == reference.get_pixel(x, y).g, "canopy kernel parity %s %s: %s / %s" % [x,y,actual.get_pixel(x,y),reference.get_pixel(x,y)])
	var tunnel := TunnelData.new(8 * w.W + 16, 24 * w.W + 16)
	var clear := StageVegetation.path_clearance(w.W, w.H, [], [tunnel])
	check(clear[16 * w.W + 18] < 0.0, "tunnel cut must exclude plants 8m from axis")
	check(clear[16 * w.W + 20] > 0.0, "cut must retain ground beyond radius")
	var store := StageVegetation.ObjStore.new(w)
	check(store.chunk_lists[0] == null and store.chunk_lists[3] == null, "unused chunks must not allocate lists")
	store.begin_chunk(0, 0, 16, 16)
	check(store.chunk_lists[0] is Array and store.chunk_lists[3] == null, "only active chunk owns a list")
	var layer := VegetationLayer.new()
	layer.world = w
	w.outer = OuterLand.new()
	var old := {Vector2i.ZERO: {fields = {tag=1}}}
	w.outer.set_ledger({regions=old})
	var snapshot := layer._detail_snapshot()
	w.outer.set_ledger({regions={}})
	check(snapshot.regions == old, "task must retain published snapshot across ledger replacement")
	layer.free()
	print("vegetation_audit_test: ", fails, " failures")
	quit(1 if fails else 0)
