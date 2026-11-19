extends SceneTree
## Regression checks for map icon selection and incremental fog reveal.
const Icons = preload("res://scripts/ui/ui_icons.gd")
const MapView = preload("res://scripts/ui/world_map_view.gd")
var failed := 0

func check(ok: bool, description: String) -> void:
	print(("ok   " if ok else "FAIL ") + description)
	if not ok:
		failed += 1

func _initialize() -> void:
	var types := ["ruin", "tower", "stones", "shelter", "obelisk", "farm", "house", "fishing", "bench"]
	var textures := {}
	for kind: String in types:
		var record := SiteData.new()
		record.type = kind
		check(Icons.map_place_icon({kind = "site", src = record}) == kind and Icons.map_place_icon({kind = "site", src = {type = kind}}) == kind, "site type " + kind)
		textures[Icons.map_icon(kind).get_instance_id()] = true
	check(textures.size() == types.size(), "distinct site icons")
	check(Icons.map_place_icon({kind = "site"}) == "site" and Icons.map_place_icon({kind = "peak"}) == "peak", "legacy and non-site records")
	var view := MapView.new()
	view._fog = Image.create(100, 100, false, Image.FORMAT_RGBA8)
	view._fog.fill(Color.WHITE)
	view._open_fog(Vector2(800, 800), 160.0)
	check(view._fog.get_pixel(50, 50).a == 0.0 and view._fog.get_pixel(61, 50).a == 1.0, "circle center and outside")
	check(view._fog.get_pixel(57, 57).a > 0.0, "corner outside round reveal")
	var before := view._fog.get_pixel(59, 50).a
	view._open_fog(Vector2(816, 800), 160.0)
	check(view._fog.get_pixel(59, 50).a <= before, "overlapping reveals never close explored area")
	view._open_fog(Vector2.ZERO, 160.0)
	check(view._fog.get_pixel(0, 0).a == 0.0, "reveal clipped to map bounds")
	var start := Time.get_ticks_msec()
	for i in 400:
		view._open_fog(Vector2(200 + i * 3, 400), 260.0)
	print("400 fog stamps: %d ms" % (Time.get_ticks_msec() - start))
	view.free()
	quit(1 if failed else 0)
