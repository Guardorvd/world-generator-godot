class_name UiStyle
extends RefCounted
## Оформление интерфейса, которое собирается в коде. Основная тема (панели, кнопки, поля, варианты
## PrimaryButton и TitleLabel) — ресурс resources/ui_theme.tres, его удобно править в редакторе.


## Полупрозрачная панель со скруглёнными углами
static func panel(bg: Color, radius: int = 12, pad: int = 24) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(radius)
	s.set_content_margin_all(pad)
	return s
