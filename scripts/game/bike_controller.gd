class_name BikeController
extends RefCounted
## BikeRide owns balance/physics; BikeCrash owns ragdoll. This controller coordinates them.
signal recovery_started
signal recovered
signal mount_changed(riding: bool)
signal message(text: String)
var stamina := Stamina.new()

func toggle_mount(player: PlayerState, bike: BikeRide, world: WorldData, heights: Heightfield) -> void:
	if bike.riding:
		if bike.airborne:
			message.emit("Сначала приземлитесь")
			return
		bike.dismount(player, world, heights)
		mount_changed.emit(false)
		return
	var distance := bike.distance_to(player)
	if distance > GameConfig.BIKE_MOUNT:
		message.emit("Велосипед в %d м отсюда" % roundi(distance))
		return
	if not bike.can_mount(player):
		message.emit("Велосипед выше или ниже вас")
		return
	if not bike.prepare_mount(player, world, heights):
		message.emit("Не хватает места для посадки. Подойдите с другой стороны")
		return
	bike.mount(player)
	mount_changed.emit(true)

func recover(dt: float, player: PlayerState, bike: BikeRide, crash: BikeCrash,
		world: WorldData, heights: Heightfield) -> bool:
	var was_ragdoll := crash.phase == BikeCrash.Phase.RAGDOLL
	var back := crash.tick(dt, bike, world, heights)
	var at := crash.focus(bike)
	player.x = at.x
	player.z = at.z
	player.feet = at.y
	var changed := was_ragdoll and crash.phase == BikeCrash.Phase.RECOVER
	if changed or back:
		player.vx = 0.0
		player.vy = 0.0
		player.vz = 0.0
	if changed:
		recovery_started.emit()
	if back:
		player.on_ground = true
		player.land_impact = 0.0
		recovered.emit()
	return changed or back

func ride(dt: float, player: PlayerState, bike: BikeRide, world: WorldData,
		heights: Heightfield, forward: float, steer: float, run: bool, jump: bool,
		opening: bool) -> float:
	var boost := not opening and stamina.can_boost(run, forward)
	if forward > 0.0 and not opening:
		forward *= stamina.pedal_scale()
	bike.step(player, forward, steer, boost, jump, dt, world, heights)
	if not opening:
		stamina.tick_ride(dt, forward, boost, bike.speed, bike.grade(heights), bike.airborne)
	return forward

func begin_crash(view: BikeView, bike: BikeRide, crash: BikeCrash, heights: Heightfield) -> void:
	bike.crashed = false
	crash.start(view, bike, bike.crash_velocity, heights)
	bike.speed = 0.0
