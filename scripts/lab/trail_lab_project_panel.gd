extends Window
const Map := preload("res://scripts/lab/trail_lab_map.gd")
signal preview_requested(index: int)
signal build_requested
signal save_requested(slot: String)
signal restore_requested(slot: String)
var map := Map.new()
var description := Label.new()
var comparison := Label.new()
var timings := Label.new()

func _ready() -> void:
	title = "Места и варианты А/Б"
	size = Vector2i(780, 640)
	close_requested.connect(hide)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "top", "right", "bottom"]: margin.add_theme_constant_override("margin_" + side, 12)
	add_child(margin)
	var box := VBoxContainer.new()
	margin.add_child(box)
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	description.text = "Выберите место на карте. Просмотр проекта не строит сцену."
	box.add_child(description)
	map.custom_minimum_size = Vector2(500, 350)
	map.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(map)
	map.site_clicked.connect(func(index: int) -> void: preview_requested.emit(index))
	var actions := HBoxContainer.new()
	box.add_child(actions)
	var build := Button.new()
	build.text = "Построить сцену проекта"
	build.pressed.connect(func() -> void: build_requested.emit())
	actions.add_child(build)
	for slot in ["A", "B"]:
		var save := Button.new()
		save.text = "Сцена → " + slot
		save.tooltip_text = "Сохранить проверенную активную трассу; просмотренный проект сохраняется после построения сцены"
		save.pressed.connect(func() -> void: save_requested.emit(slot))
		actions.add_child(save)
		var restore := Button.new()
		restore.text = "Открыть " + slot
		restore.pressed.connect(func() -> void: restore_requested.emit(slot))
		actions.add_child(restore)
	comparison.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(comparison)
	timings.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(timings)
