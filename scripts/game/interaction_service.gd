class_name InteractionService
extends RefCounted
## Board/quest rules and target selection. Presentation is delivered through signals.
signal message(text: String)
signal banner(title: String, text: String, color: Color)
signal completed(title: String)
signal close_requested
const Quests = preload("res://scripts/game/quests.gd")
const AIM_R := 0.3
var quests: Quests
var world: WorldData
var all_places: Callable
var visited: Dictionary
var completion_color := Color(1.0, 0.82, 0.32)
var distance_text: Callable = Util.distance_text

## Место как цель задания: копия с ключом key = id
static func target(place: Dictionary) -> Dictionary:
	var out := place.duplicate()
	out.key = place.id
	return out

func select(items: Array, from: Vector3, dir: Vector3) -> Dictionary:
	var best := {}
	var best_hit := INF
	var best_angle := INF
	for it: Dictionary in items:
		var inv: Transform3D = it.at.affine_inverse()
		var o := inv * from
		var d := inv.basis * dir
		var hit := _ray_box(o, d, it.half)
		if hit < best_hit:
			best = it
			best_hit = hit
		elif best_hit == INF and _ray_box(o, d, it.half + Vector3.ONE * AIM_R) < INF:
			var to: Vector3 = it.at.origin - from
			var angle := to.angle_to(dir)
			if angle < best_angle:
				best = it
				best_angle = angle
	return best

static func _ray_box(o: Vector3, d: Vector3, half: Vector3) -> float:
	var near := 0.0
	var far := INF
	for k in 3:
		if absf(d[k]) < 1e-6:
			if absf(o[k]) > half[k]:
				return INF
			continue
		var a := (-half[k] - o[k]) / d[k]
		var b := (half[k] - o[k]) / d[k]
		near = maxf(near, minf(a, b))
		far = minf(far, maxf(a, b))
	return near if near <= far else INF



func offers(village: Variant) -> Array:
	var here := target(world.place(WorldData.place_id("settlement", village.x, village.y)))
	var neighbors: Array = []
	for r: Dictionary in world.routes(here.id):
		neighbors.append(target(world.place(r.to if r.from == here.id else r.from)))
	var far := world.far_destination(here.id)
	return quests.offers(here, all_places.call(), neighbors, {} if far.is_empty() else target(far), visited, world.seed_num)

func accept(q: QuestData) -> void:
	quests.accept(q)
	close_requested.emit()
	banner.emit("Новое задание", q.title, Quests.KINDS[q.kind].color)
	message.emit(quests.step_text())


func abandon() -> void:
	quests.abandon()
	close_requested.emit()
	message.emit("Вы отказались от задания")


## Сообщение о шаге задания: следующий шаг или «Задание выполнено» (крупно посередине и в счётчике)
func progress(text: String) -> void:
	if text.is_empty():
		return
	if quests.active.is_empty():
		completed.emit(quests.last)
		banner.emit("Задание выполнено", "%s · всего выполнено: %d" % [quests.last, quests.done], completion_color)
	else:
		message.emit("Дальше: " + text)


## Снимок: засчитать для задания или подсказать, почему не засчитан
func photographed(shot: Dictionary) -> void:
	var s := quests.step()
	if s.get("do") != "shoot":
		return
	if shot.place.is_empty():
		message.emit("Наведите фотоаппарат на «%s»: снимок засчитается, когда в видоискателе появится название" % s.place.name)
	elif not quests.wants_photo(shot.place):
		message.emit("Это «%s». Для задания нужен снимок «%s»" % [shot.name, s.place.name])
	elif shot.dist > Quests.SHOT_REACH:
		message.emit("Слишком далеко для задания: подойдите к «%s» ближе %s (сейчас %s)" % [s.place.name, distance_text.call(Quests.SHOT_REACH), distance_text.call(shot.dist)])
	else:
		progress(quests.photographed(shot.place, shot.dist))
