extends PanelContainer
signal retry_requested
signal exit_requested
var heading := Label.new()
var description := Label.new()
var retry := Button.new()
var leave := Button.new()
func _ready() -> void:
	position = Vector2(12, 12)
	theme_type_variation = "HudPanel"
	var margin := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]: margin.add_theme_constant_override("margin_" + side, 12)
	add_child(margin)
	var box := VBoxContainer.new(); margin.add_child(box)
	heading.add_theme_font_size_override("font_size", 20)
	box.add_child(heading)
	description.add_theme_font_size_override("font_size", 14)
	box.add_child(description)
	var row := HBoxContainer.new(); box.add_child(row)
	retry.text = "Повторить · R"; retry.pressed.connect(func() -> void: retry_requested.emit()); row.add_child(retry)
	leave.text = "Лаборатория"; leave.pressed.connect(func() -> void: exit_requested.emit()); row.add_child(leave)

func present(trial) -> void:
	var phase: int = trial.phase
	heading.text = trial.title
	match phase:
		trial.Phase.READY: description.text = "W — к старту\nПроедьте стартовые ворота, чтобы начать отсчёт"
		trial.Phase.APPROACH: description.text = "К старту · отсчёт ещё не начат"
		trial.Phase.RUNNING: description.text = "%.1f с   ·   %.0f / %.0f м%s" % [trial.elapsed, trial.progress, trial.route.route_length(), "\nТестовый заезд с автопилотом" if trial.assisted else ""]
		trial.Phase.FINISHED: description.text = "Финиш!   %.2f с%s\nВсе контрольные точки пройдены · можно повторить" % [trial.elapsed, " · автопилот" if trial.assisted else ""]
		trial.Phase.FAILED: description.text = "%s\nПопытка не засчитана · повторите со старта" % trial.result.reason
	if phase == trial.Phase.READY and not trial.pace_note.is_empty(): description.text += "\n" + trial.pace_note
	retry.visible = phase in [trial.Phase.FINISHED, trial.Phase.FAILED]
