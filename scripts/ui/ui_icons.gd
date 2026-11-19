extends RefCounted
## 12.5: векторные пиктограммы интерфейса (resources/icons, белые SVG 48 px, рисуются 24 px).
## Белые, чтобы цвет задавала тема (icon_*_color у кнопок) или modulate у TextureRect.
## Вместо текстовых символов (🎲, ☆, ◎…): шрифт рисует их по-разному, а часть — цветными emoji.

const STAR := preload("res://resources/icons/star.svg")
const STAR_FILLED := preload("res://resources/icons/star_filled.svg")
const CHECK := preload("res://resources/icons/check.svg")
const PLAY := preload("res://resources/icons/play.svg")
const HOME := preload("res://resources/icons/home.svg")
const PEAK := preload("res://resources/icons/place_peak.svg")
const LAKE := preload("res://resources/icons/place_lake.svg")
const SITE := preload("res://resources/icons/place_site.svg")
const EXIT := preload("res://resources/icons/exit.svg")
const JOURNAL := preload("res://resources/icons/journal.svg")
const ALBUM := preload("res://resources/icons/album.svg")
const CLOCK := preload("res://resources/icons/clock.svg")
const ALTITUDE := preload("res://resources/icons/altitude.svg")
const THERMOMETER := preload("res://resources/icons/thermometer.svg")
const SPEED := preload("res://resources/icons/speed.svg")
const BAG := preload("res://resources/icons/bag.svg")
const ALERT := preload("res://resources/icons/alert.svg")
const INFO := preload("res://resources/icons/info.svg")
const CLOSE := preload("res://resources/icons/close.svg")
## Виды заданий (Quests.KINDS)
const QUESTS := {
	visit = preload("res://resources/icons/quest_visit.svg"),
	tour = preload("res://resources/icons/quest_tour.svg"),
	delivery = preload("res://resources/icons/quest_delivery.svg"),
	supplies = preload("res://resources/icons/quest_supplies.svg"),
	repair = preload("res://resources/icons/quest_repair.svg"),
	beacons = preload("res://resources/icons/quest_beacons.svg"),
	paint = preload("res://resources/icons/quest_paint.svg"),
	photo = preload("res://resources/icons/quest_photo.svg"),
	fragile = preload("res://resources/icons/quest_fragile.svg"),
	chronicle = preload("res://resources/icons/quest_chronicle.svg"),
}

const OBELISK_SVGS := [
	"<path d=\"M10.5 3.5L12 2l1.5 1.5L14.5 19h-5z\"/><path d=\"M6.5 21.5h11v-2.5h-11z\"/>",
	"<path d=\"M9.5 19V11l2.5-1.5 2 1.5v8\"/><path d=\"M15.5 16l3-2.5 1.5 1.5-3 2.5\"/><path d=\"M6.5 21.5h11v-2.5h-11z\"/>",
	"<circle cx=\"12\" cy=\"5.5\" r=\"2\"/><path d=\"M9 15V9.5c0-1 1.2-1.5 3-1.5s3 .5 3 1.5V15\"/><path d=\"M8 15h8v4H8zM6.5 21.5h11v-2.5h-11z\"/>",
	"<path d=\"M8.5 19V9h4v10\"/><path d=\"M7.5 9h6M15.5 18l3-3\"/><path d=\"M6 21.5h12v-2.5H6z\"/>",
	"<path d=\"M7.5 19V7.5c0-2 2-3.5 4.5-3.5s4.5 1.5 4.5 3.5V19\"/><path d=\"M10 10.5h4M10 13.5h4\"/><path d=\"M5.5 21.5h13v-2.5h-13z\"/>",
]
const _MAP_HOME := "<path d=\"M4 11.5L12 4.5l8 7\"/><path d=\"M6.5 10v9.5h11V10\"/>"
const MAP_SVGS := {
	settlement = _MAP_HOME,
	home = _MAP_HOME,
	peak = "<path d=\"M3 19L10 6.5l4.2 6.8 2.6-3.3L21 19z\"/>",
	lake = "<path d=\"M3 9.5c2-1.8 4-1.8 6 0s4 1.8 6 0 4-1.8 6 0\"/><path d=\"M3 15.5c2-1.8 4-1.8 6 0s4 1.8 6 0 4-1.8 6 0\"/>",
	site = "<path d=\"M5 20h14\"/><path d=\"M8.5 20L10 9h4l1.5 11\"/><path d=\"M7.5 9h9l-1-4h-7z\"/>",
	bike = "<circle cx=\"6\" cy=\"16\" r=\"3.5\"/><circle cx=\"18\" cy=\"16\" r=\"3.5\"/><path d=\"M6 16l4.5-6.5h4L18 16M14.5 9.5l1-3h2.5\"/>",
}
const QUEST_SMALL_SVGS := {
	visit = "<path d=\"M6 20.5V4m0 1c4-2.5 7 2.5 12 0v8c-5 2.5-8-2.5-12 0\"/>",
	tour = "<circle cx=\"5.5\" cy=\"17.5\" r=\"2\"/><circle cx=\"18.5\" cy=\"6.5\" r=\"2\"/><path d=\"M7.5 17.5h4.5a3 3 0 0 0 0-6H10a2.5 2.5 0 0 1 0-5h6.5\"/>",
	delivery = "<path d=\"M12 3.5l8 4v9l-8 4-8-4v-9z\"/><path d=\"M4 7.5l8 4 8-4M12 11.5v9\"/>",
	supplies = "<path d=\"M9 6.5V5a3 3 0 0 1 6 0v1.5\"/><path d=\"M5.5 10.5a4 4 0 0 1 4-4h5a4 4 0 0 1 4 4V19a1.5 1.5 0 0 1-1.5 1.5h-10A1.5 1.5 0 0 1 5.5 19z\"/><path d=\"M9 12h6\"/>",
	repair = "<path d=\"M11.3 10.3L4.8 16.8a1.7 1.7 0 1 0 2.4 2.4l6.5-6.5A5.2 5.2 0 0 0 21 6.8l-3.4 3.4-3.8-3.8 3.4-3.4a5.2 5.2 0 0 0-5.9 7.3z\"/>",
	beacons = "<circle cx=\"12\" cy=\"8.5\" r=\"2\"/><path d=\"M10.5 10.5L7.5 20.5M13.5 10.5L16.5 20.5M9 16.5h6\"/><path d=\"M7 4.5a6.5 6.5 0 0 0 0 8M17 4.5a6.5 6.5 0 0 1 0 8\"/>",
	paint = "<rect x=\"4\" y=\"3.5\" width=\"13\" height=\"5.5\" rx=\"1.5\"/><path d=\"M17 6.2h2.5v4.8H11v4\"/><rect x=\"9\" y=\"15\" width=\"4\" height=\"5.5\" rx=\"1.2\"/>",
	photo = "<rect x=\"3\" y=\"7\" width=\"18\" height=\"12.5\" rx=\"2\"/><path d=\"M8.5 7l1.5-2.5h4L15.5 7\"/><circle cx=\"12\" cy=\"13.2\" r=\"3.2\"/>",
	fragile = "<path d=\"M5 7l7-4 7 4v10l-7 4-7-4z\"/><path d=\"M12 10.5l-1.5 3.5 2.5 1-1 3.5\"/>",
	chronicle = "<path d=\"M5 4.5h12a2 2 0 0 1 2 2V20H7a2 2 0 0 1-2-2z\"/><path d=\"M5 18a2 2 0 0 1 2-2h12M9 9h6\"/>",
	obelisks = "<path d=\"M10.5 3.5L12 2l1.5 1.5L14.5 19h-5z\"/><path d=\"M6.5 21.5h11v-2.5h-11z\"/>",
}

static var _svg_cache := {}


static func _svg(body: String, stroke := 2.0, px := 48) -> Texture2D:
	var cache_key := "%d:%.1f:%s" % [px, stroke, body]
	if _svg_cache.has(cache_key):
		return _svg_cache[cache_key]
	var tex: Texture2D = QUESTS.visit
	var img := Image.new()
	var markup := "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%d\" height=\"%d\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"#fff\" stroke-width=\"%.1f\" stroke-linecap=\"round\" stroke-linejoin=\"round\">%s</svg>" % [px, px, stroke, body]
	if img.has_method(&"load_svg_from_string") and img.load_svg_from_string(markup, 1.0) == OK and not img.is_empty():
		tex = ImageTexture.create_from_image(img)
	_svg_cache[cache_key] = tex
	return tex


static func bike() -> Texture2D:
	return _svg("<circle cx=\"5.5\" cy=\"16.5\" r=\"3.5\"/><circle cx=\"18.5\" cy=\"16.5\" r=\"3.5\"/><path d=\"M5.5 16.5L10 9.5h4.5l4 7M10 9.5l-1.5-3h-2M14.5 9.5l1.5-3h2.5\"/>")


static func foot() -> Texture2D:
	return _svg("<path d=\"M8.5 3.5c2 0 3.5 1.8 3.2 4.3-.2 2-.8 3.2-2.6 3.5-1.6.2-2.8-1-2.8-3.3 0-2.6 1-4.5 2.2-4.5z\"/><path d=\"M7.5 13.5h3c.4 1.8-.3 3.2-1.5 3.2s-1.9-1.4-1.5-3.2z\"/><path d=\"M16 7.5c2 0 3.2 1.8 3 4.3-.2 2-.9 3.2-2.6 3.4-1.6.2-2.7-1-2.7-3.2 0-2.6 1.1-4.5 2.3-4.5z\"/><path d=\"M14.8 17.3h3c.3 1.7-.4 3.2-1.5 3.2s-1.8-1.5-1.5-3.2z\"/>")


static func clock() -> Texture2D:
	return CLOCK


static func leaf() -> Texture2D:
	return _svg("<path d=\"M19.5 4.5C12 4.5 6 8.5 6 15.5c0 1.4.4 2.5 1 3.5 1-.6 2.1-1 3.5-1 7 0 9-6 9-13.5z\"/><path d=\"M4.5 19.5L14 10\"/>")


static func obelisk(form := 0) -> Texture2D:
	return _svg(OBELISK_SVGS[clampi(form, 0, OBELISK_SVGS.size() - 1)])


static func place_category(title: String) -> Texture2D:
	var low := title.to_lower()
	if low.contains("поселен") or low.contains("хутор") or low.contains("дом"):
		return HOME
	if low.contains("вершин"):
		return PEAK
	if low.contains("озер") or low.contains("озёр"):
		return LAKE
	if low.contains("обелиск"):
		return obelisk(0)
	return SITE


static func album_icon(group: int, key: String, form := 0) -> Texture2D:
	match group:
		0: return leaf()
		1:
			if key == "settlement" or key in ["site:house", "site:farm", "site:fishing"]:
				return HOME
			if key == "site:obelisk":
				return obelisk(0)
			return SITE
		2: return LAKE if key == "lake" else PEAK
		3: return STAR_FILLED
		4: return obelisk(form)
	return SITE


static func star(filled: bool) -> Texture2D:
	return STAR_FILLED if filled else STAR


static func quest(kind: String) -> Texture2D:
	if kind == "obelisks":
		return obelisk(0)
	return QUESTS.get(kind, QUESTS.visit)


## Упрощённый картографический значок (stroke-width 2.4, 28 px) для мелких меток на картах и компасе
static func map_icon(kind: String) -> Texture2D:
	if kind == "goal":
		return STAR_FILLED
	return _svg(MAP_SVGS.get(kind, MAP_SVGS.site), 2.4, 28)


## Упрощённая пиктограмма вида задания (stroke-width 2.4, 28 px) для компаса и карт
static func quest_small(kind: String) -> Texture2D:
	return _svg(QUEST_SMALL_SVGS.get(kind, QUEST_SMALL_SVGS.visit), 2.4, 28)


## Пиктограмма рядом с текстом: квадрат side px, цвет — color
static func rect(tex: Texture2D, side: float, color := Color.WHITE) -> TextureRect:
	var r := TextureRect.new()
	r.texture = tex
	r.custom_minimum_size = Vector2(side, side)
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.modulate = color
	return r
