class_name InteractionService
extends RefCounted
## Board/quest rules and target selection. Presentation is delivered through signals.
signal message(text: String, kind: StringName)
signal close_requested
const Quests = preload("res://scripts/game/quests.gd")
const BeaconSites = preload("res://scripts/game/beacon_sites.gd")
const PaintTargets = preload("res://scripts/game/paint_targets.gd")
const AIM_R := 0.3
var quests: Quests
var world: WorldData
var heights: Heightfield
var all_places: Callable
var visited: Dictionary
var is_broken: Callable  # Repairables.is_broken: какие объекты сломаны (задания «Ремонт»)
var travel: Callable     # 18.11.2026: () -> {explored, from} — где игрок ездил и откуда приехал (Quests._direction_cost)
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



## Листки доски village: не больше Quests.BOARD_OFFERS из всех предложений (offers_all)
func offers(village: Variant, catalog: Variant = null) -> Array:
	var here_key := WorldData.place_id("settlement", village.x, village.y)
	return Quests.board_pick(offers_all(village, catalog), here_key, quests.done, quests.active.id) # 19.11.2026


## 20.11.2026: указатели путей мира для маяков и меток краской — при загрузке, а не у первой доски
func warm() -> void:
	if world != null:
		BeaconSites.warm(world)
		PaintTargets.warm(world)


## Все предложения доски village (Quests.offers) — до отбора трёх листков
func offers_all(village: Variant, catalog: Variant = null) -> Array:
	var here := target(world.place(WorldData.place_id("settlement", village.x, village.y)))
	var neighbors: Array = []
	for r: Dictionary in world.routes(here.id):
		neighbors.append(target(world.place(r.to if r.from == here.id else r.from)))
	var far := world.far_destination(here.id)
	var places: Array = all_places.call() if catalog == null else catalog
	var trip: Dictionary = travel.call() if travel.is_valid() else {}
	var prefer := quests.prefer(here, trip)
	return quests.offers(here, places, neighbors, {} if far.is_empty() else target(far), visited, world.seed_num, is_broken,
		BeaconSites.route.bind(world, heights, here, quests.installed_beacons, prefer),
		PaintTargets.route.bind(world, heights, here, quests.painted_objects, prefer), trip)

func accept(q: QuestData) -> void:
	quests.accept(q)
	close_requested.emit()
	message.emit("Новое задание\n" + q.title, &"quest")


func abandon() -> void:
	quests.abandon()
	close_requested.emit()
	message.emit("Вы отказались от задания", &"warning")


## Одно уведомление о следующем шаге или завершении задания.
func progress(text: String) -> void:
	if text.is_empty():
		return
	message.emit(text if quests.active.is_empty() else "Дальше: " + text, &"quest")


## Снимок: засчитать для задания или подсказать, почему не засчитан
func photographed(shot: Dictionary) -> void:
	var s := quests.step()
	if s.get("do") != "shoot":
		return
	if shot.place.is_empty():
		message.emit("Наведите фотоаппарат на «%s»: снимок засчитается, когда в видоискателе появится название" % s.place.name, &"warning")
	elif not quests.wants_photo(shot.place):
		message.emit("Это «%s». Для задания нужен снимок «%s»" % [shot.name, s.place.name], &"warning")
	elif shot.dist > Quests.SHOT_REACH_M:
		message.emit("Слишком далеко для задания: подойдите к «%s» ближе %s (сейчас %s)" % [s.place.name, distance_text.call(Quests.SHOT_REACH_M), distance_text.call(shot.dist)], &"warning")
	else:
		progress(quests.photographed(shot.place, shot.dist))
