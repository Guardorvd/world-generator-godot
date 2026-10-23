extends RefCounted
## 12.5: векторные пиктограммы интерфейса (resources/icons, белые SVG 48 px, рисуются 24 px).
## Белые, чтобы цвет задавала тема (icon_*_color у кнопок) или modulate у TextureRect.
## Вместо текстовых символов (🎲, ☆, ◎…): шрифт рисует их по-разному, а часть — цветными emoji.

const DICE := preload("res://resources/icons/dice.svg")
const STAR := preload("res://resources/icons/star.svg")
const STAR_FILLED := preload("res://resources/icons/star_filled.svg")
const CHECK := preload("res://resources/icons/check.svg")
const PLAY := preload("res://resources/icons/play.svg")
const SAVE := preload("res://resources/icons/save.svg")
const LOAD := preload("res://resources/icons/load.svg")
const GEAR := preload("res://resources/icons/gear.svg")
const HOME := preload("res://resources/icons/home.svg")
const EXIT := preload("res://resources/icons/exit.svg")
## Виды заданий (Quests.KINDS)
const QUESTS := {
	visit = preload("res://resources/icons/quest_visit.svg"),
	tour = preload("res://resources/icons/quest_tour.svg"),
	delivery = preload("res://resources/icons/quest_delivery.svg"),
	photo = preload("res://resources/icons/quest_photo.svg"),
	fragile = preload("res://resources/icons/quest_fragile.svg"),
	chronicle = preload("res://resources/icons/quest_chronicle.svg"),
}


static func star(filled: bool) -> Texture2D:
	return STAR_FILLED if filled else STAR


static func quest(kind: String) -> Texture2D:
	return QUESTS.get(kind, QUESTS.visit)


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
