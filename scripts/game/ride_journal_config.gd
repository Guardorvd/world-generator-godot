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
@export_group("Превью")
## Увеличение делает превью шире.
@export var thumb_width := 320
## Увеличение делает превью выше.
@export var thumb_height := 200
## Увеличение добавляет больше свободного места вокруг трека.
@export var frame_margin := 0.12
## Увеличение делает линию трека толще.
@export var track_width := 2
## Увеличение увеличивает промежуток между обновлениями превью.
@export var thumb_interval := 60.0
## Более светлый цвет делает велосипедный трек заметнее.
@export var bike_color := Color(1.0, 0.95, 0.72)
## Более светлый цвет делает пеший трек заметнее.
@export var foot_color := Color(0.85, 0.9, 1.0)
## Более яркий цвет делает падения заметнее.
@export var fall_color := Color(1.0, 0.2, 0.2)
@export_group("Хранилище")
## Увеличение сохраняет больше последних записей.
@export var entries_limit := 200
