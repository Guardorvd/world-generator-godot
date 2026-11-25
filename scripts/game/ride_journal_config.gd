class_name RideJournalConfig
extends Resource
## Все настройки общего журнала, доступные в инспекторе.

@export_group("Заезд")
## Увеличение исключает больше коротких сессий по времени.
@export var min_time := 60.0
## Увеличение исключает больше коротких сессий по расстоянию.
@export var min_distance := 200.0
## Увеличение относит больше заездов к пешим прогулкам.
@export var walk_bike_distance := 200.0
@export_group("Статистика")
## Увеличение сильнее подавляет небольшие колебания высоты.
@export var altitude_hysteresis := 2.0
## Увеличение сильнее сглаживает максимальную скорость.
@export var speed_window := 1.0
## Увеличение сокращает время, считаемое движением.
@export var moving_speed := 1.5
## Увеличение исключает больше коротких отрывов.
@export var jump_air_time := 0.4
## Увеличение сохраняет больше точек профиля высоты.
@export var profile_limit := 128
@export_group("Падения")
## Увеличение объединяет падения на большем промежутке времени.
@export var fall_merge_time := 3.0
## Увеличение объединяет более удалённые падения.
@export var fall_merge_distance := 5.0
## Увеличение сохраняет больше отметок падений.
@export var fall_marks_limit := 64
## Увеличение делает кресты падений на большой карте крупнее.
@export var map_fall_radius := 6.0
## Увеличение делает кресты падений на большой карте толще.
@export var map_fall_width := 2.5
## Более яркий цвет делает падения на карте и профиле заметнее.
@export var map_fall_color := Color.RED
@export_group("Превью")
## Увеличение делает превью шире.
@export var thumb_width := 320
## Увеличение делает превью выше.
@export var thumb_height := 200
## Увеличение добавляет больше свободного места вокруг трека.
@export var frame_margin := 0.12
## Увеличение добавляет поля вокруг коротких треков.
@export var frame_min_margin := 60.0
## Увеличение делает линию трека толще.
@export var track_width := 2
## Увеличение делает тёмную обводку маршрута шире.
@export var track_outline_width := 1
## Более тёмный цвет сильнее отделяет маршрут от светлой карты.
@export var track_outline_color := Color(0.18, 0.27, 0.23)
## Увеличение удлиняет штрихи пешего трека.
@export var foot_dash := 6
## Увеличение делает отметки начала, конца и падений крупнее.
@export var marker_radius := 3
## Увеличение увеличивает промежуток между обновлениями превью.
@export var thumb_interval := 60.0
## Более светлый цвет делает велосипедный трек заметнее.
@export var bike_color := Color(1.0, 0.95, 0.72)
## Более светлый цвет делает пеший трек заметнее.
@export var foot_color := Color(0.85, 0.9, 1.0)
## Более яркий цвет делает падения заметнее.
@export var fall_color := Color(1.0, 0.2, 0.2)
## Более светлый цвет делает начало пути заметнее.
@export var start_color := Color(0.2, 0.9, 0.4)
## Более светлый цвет делает конец пути заметнее.
@export var finish_color := Color(1.0, 0.8, 0.2)
## Более светлый цвет осветляет поля за границей карты.
@export var background_color := Color(0.91, 0.886, 0.812)
@export_group("Лента")
## Увеличение делает карточки ленты выше.
@export var card_height := 132.0
## Увеличение делает миниатюру в карточке больше.
@export var card_thumb_size := Vector2(82, 62)
## Увеличение делает карточки главного меню выше.
@export var card_wide_height := 150.0
## Увеличение делает карту в карточке главного меню крупнее.
@export var card_wide_thumb_size := Vector2(156, 98)
## Увеличение делает дату в карточке главного меню крупнее.
@export var card_wide_title_font := 16
## Увеличение делает подписи в карточке главного меню крупнее.
@export var card_wide_text_font := 13
## Увеличение добавляет внутренние поля карточки.
@export var card_padding := 8.0
## Увеличение делает значок типа мира крупнее.
@export var card_icon_size := 16.0
## Увеличение делает дату в карточке крупнее.
@export var card_title_font := 14
## Увеличение делает подписи карточки крупнее.
@export var card_text_font := 12
## Увеличение раздвигает элементы ленты.
@export var feed_spacing := 8
## Увеличение делает заголовок ленты крупнее.
@export var feed_title_font := 18
## Увеличение делает заголовок общего журнала крупнее.
@export var feed_wide_title_font := 24
## Увеличение оставляет больше места списку поездок.
@export var feed_list_height := 260.0
## Увеличение быстрее заполняет длинную ленту, но добавляет работы в кадре.
@export var feed_cards_per_frame := 2
## Увеличение реже проверяет появление готового превью в открытой ленте.
@export var pending_preview_interval := 1.0
## Увеличение продлевает ожидание фонового превью в открытой ленте.
@export var pending_preview_timeout := 30.0
## Увеличение задаёт больший минимальный размер окна поездки.
@export var detail_min_size := Vector2i(520, 500)
## Увеличение задаёт большую область прокрутки поездки.
@export var detail_scroll_size := Vector2(500, 440)
## Увеличение открывает подробную поездку в более крупном окне.
@export var detail_window_size := Vector2i(620, 650)
## Увеличение делает крупное превью выше.
@export var detail_preview_height := 240.0
## Увеличение делает график высоты выше.
@export var detail_profile_height := 100.0
## Увеличение сохраняет больше деталей загруженного снимка.
@export var detail_photo_width := 320
## Увеличение делает снимки в карточке выше.
@export var detail_photo_height := 160.0
## Увеличение показывает больше снимков за одно нажатие.
@export var detail_photos_per_batch := 6
## Увеличение раздвигает столбцы статистики.
@export var detail_grid_gap := 20
## Увеличение добавляет поля у графика высоты.
@export var profile_padding := 6.0
## Увеличение делает линию графика толще.
@export var profile_line_width := 2.0
## Увеличение делает отметки падений на графике крупнее.
@export var profile_fall_radius := 4.0
## Увеличение делает отметки падений на графике толще.
@export var profile_fall_width := 2.0
@export_group("Хранилище")
## Увеличение сохраняет больше последних записей.
@export var entries_limit := 200
