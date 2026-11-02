extends Window
const Map := preload("res://scripts/lab/trail_lab_map.gd")
signal preview_requested(index: int)
signal build_requested
signal save_requested(slot: String)
signal restore_requested(slot: String)
signal world_requested(source: Dictionary)
var game_seed := LineEdit.new()
var snapshot_path := LineEdit.new()
var dry_channels := CheckBox.new()
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
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)
	var source_row := HBoxContainer.new()
	box.add_child(source_row)
	game_seed.placeholder_text = "Игровой сид (точная строка)"
	game_seed.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	source_row.add_child(game_seed)
	var open_seed := Button.new()
	open_seed.text = "Открыть игровой мир"
	open_seed.pressed.connect(func() -> void:
		if not game_seed.text.is_empty(): world_requested.emit({game_seed = game_seed.text, dry_channels = dry_channels.button_pressed}))
	source_row.add_child(open_seed)
	var snapshot_row := HBoxContainer.new()
	box.add_child(snapshot_row)
	snapshot_path.placeholder_text = "Путь к снимку мира (.res/.tres)"
	snapshot_path.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	snapshot_row.add_child(snapshot_path)
	var open_snapshot := Button.new()
	open_snapshot.text = "Открыть снимок"
	open_snapshot.pressed.connect(func() -> void:
		if not snapshot_path.text.is_empty(): world_requested.emit({snapshot_path = snapshot_path.text, dry_channels = dry_channels.button_pressed}))
	snapshot_row.add_child(open_snapshot)
	var save_snapshot := Button.new()
	save_snapshot.text = "Сохранить снимок"
	save_snapshot.pressed.connect(func() -> void: world_requested.emit({save_snapshot = snapshot_path.text}))
	snapshot_row.add_child(save_snapshot)
	dry_channels.text = "Эксперимент: сухие русла (выключено для игровых условий)"
	box.add_child(dry_channels)
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
