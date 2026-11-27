extends RefCounted
## «Музыка» in the Sound tab (27.11.2026): a copy of the «Громкость» row and slider, placed right under them,
## so it looks and behaves like its neighbour without new nodes in main.tscn.
## Bound to GameSettings.music_volume (bus Music); 50 % by default.


## Builds the row under the volume slider; on_changed is called after each change (saving, live apply).
static func attach(volume_slider: HSlider, on_changed: Callable) -> HSlider:
	var page := volume_slider.get_parent()
	var volume_row := page.get_node_or_null("VolumeRow")
	if volume_row == null:
		return null
	# без DUPLICATE_SIGNALS: иначе копия унаследует связь с _on_volume_changed и двигала бы общую громкость
	var row: Control = volume_row.duplicate(Node.DUPLICATE_GROUPS | Node.DUPLICATE_SCRIPTS)
	row.name = "MusicRow"
	var slider: HSlider = volume_slider.duplicate(Node.DUPLICATE_GROUPS | Node.DUPLICATE_SCRIPTS)
	slider.name = "MusicSlider"
	slider.unique_name_in_owner = false
	for c: Node in row.get_children():
		c.unique_name_in_owner = false
		if c is Label and c.name == "VolumeLabel":
			(c as Label).text = "Музыка"
	page.add_child(row)
	page.move_child(row, volume_slider.get_index() + 1)
	page.add_child(slider)
	page.move_child(slider, row.get_index() + 1)
	slider.value_changed.connect(func(v: float) -> void:
		GameContext.scope.settings.music_volume = v
		GameContext.scope.settings.apply_volume()
		_show(slider)
		on_changed.call())
	sync(slider)
	return slider


## Puts the slider and its value label in line with GameSettings without emitting signals.
static func sync(slider: HSlider) -> void:
	if slider == null:
		return
	slider.set_value_no_signal(GameContext.scope.settings.music_volume)
	_show(slider)


static func _show(slider: HSlider) -> void:
	var row := slider.get_parent().get_node_or_null("MusicRow")
	var value: Label = row.get_node_or_null("VolumeValue") if row != null else null
	if value != null:
		value.text = "%d %%" % roundi(GameContext.scope.settings.music_volume * 100.0)
