class_name BikePhysicsConfig
extends Resource
## Unified bicycle physics, tire, brake, steering, suspension, flight, stance and pump tuning.
## Loaded from resources/bike_physics.tres via BikePhysicsConfig.current().

const PATH := "res://resources/bike_physics.tres"

@export_group("Gravity & Speed")
## Effective gravity acting on ground/slope traction, loads and lean (m/s^2).
@export var ground_gravity := 10.0
## Effective gravity acting in flight, takeoff prediction and ragdoll falls (m/s^2).
@export var air_gravity := 14.0
## Cruising speed while pedaling on flat meadow (m/s).
@export var cruise_speed := 11.0
## Speed multiplier when pedaling at full surge/boost.
@export var boost_mult := 1.3
## Base pedal acceleration scale (m/s^2).
@export var pedal_accel := 4.0
## Low-speed pedal thrust multiplier on pedal_accel.
@export var pedal_push_mult := 1.75
## Target reverse walk-pedaling speed (m/s).
@export var reverse_speed := 1.5
## Fraction of uphill grade gravity assisted while pedaling below cruise speed.
@export var climb_assist := 0.45
## Extra pedal surge acceleration from stamina burst (m/s^2).
@export var surge_push := 2.5
## Fraction by which surge_push tapers on steep uphill grades (10%..35% slope) to prevent hilltop launches.
@export var surge_climb_taper := 0.65
## Extra low-speed climb push when boosting on steep hills (m/s^2).
@export var boost_climb_push := 0.8
## Speed up to which rear drive ignores slip cap on start (m/s).
@export var start_pace := 3.0
## Time constant for pedaling effort rise (s).
@export var effort_rise := 0.16
## Time constant for pedaling effort fall (s).
@export var effort_fall := 0.10
## Flat rolling resistance deceleration (m/s^2).
@export var roll_resistance := 0.25
## Aerodynamic drag coefficient (1/m), shared in air and on ground.
@export var air_drag := 0.0028
## Ground tire/suspension speed^2 rolling loss coefficient (1/m).
@export var speed_loss := 0.0022
## Speed above which high-speed rough damping ramps in (m/s).
@export var high_speed_drag_from := 18.0
## High-speed excess drag gain (1/m).
@export var high_speed_drag_k := 0.04
## Extra resistance coefficient on rough/technical terrain (m/s^2).
@export var technical_loss_k := 0.8
## Minimum virtual gear ratio for crank cadence display.
@export var gear_min := 1.4
## Maximum virtual gear ratio for crank cadence display.
@export var gear_max := 5.0
## Low-speed crank cadence (rad/s).
@export var cadence_low := 6.3
## Cruise crank cadence (rad/s).
@export var cadence_high := 9.4
## Virtual gear adaptation rate (1/s).
@export var gear_response := 2.5
## Standing start crank angular velocity at full effort (rad/s).
@export var start_crank := 2.5

@export_group("Tires & Grip")
## Dimensionless baseline tire friction coefficient on firm packed ground (mu = grip / ground_gravity).
@export var base_mu := 1.15
## Arcade balance grip multiplier used for rider weight transfer & steering envelope.
@export var rider_grip := 1.6
## Grip multiplier when wheel is riding on wet roots or rocks.
@export var root_grip := 0.45
## Obstacle height threshold above which wheel is treated as on a slick root/rock (m).
@export var slick_bump := 0.015
## Contact patch load compliance time constant (s).
@export var tire_comply := 0.03
## Tire force relaxation length along path (m).
@export var tire_relax := 0.8
## Minimum tire relaxation time constant at high speed (s).
@export var tire_relax_min := 0.05
## Lateral frame+rider tire relaxation time constant (s).
@export var side_relax := 0.2
## Duration after touchdown during which grip tracks load immediately without lag (s).
@export var landing_grip := 0.12
## Longitudinal load transfer time constant between axles (s).
@export var pitch_transfer := 0.14
## Spring force share contributing to wheel normal load.
@export var contact_spring := 0.5
## Damping force share contributing to wheel normal load.
@export var contact_damp := 0.0
## Maximum normalized wheel load (multiple of bike+rider weight).
@export var load_max := 3.0
## Minimum wheel load ratio required for ground contact grip.
@export var contact_min := 0.02
## Lateral slip velocity damping rate (1/s).
@export var side_response := 30.0
## Speed threshold below which standing foot/tire balance resists lateral gravity (m/s).
@export var side_hold_speed := 2.0
## Slip angle above which frame self-aligns toward velocity vector (rad).
@export var align_slip := 0.3
## Maximum frame self-alignment angular rate (rad/s).
@export var align_rate := 3.0
## Slip angle that triggers a side-slide crash (rad).
@export var slide_crash := 1.05
## Speed above which extreme slip causes a side-slide crash (m/s).
@export var slide_crash_speed := 4.0

@export_group("Brakes")
## Target full brake deceleration demand on firm ground (m/s^2).
@export var brake_decel := 10.0
## Brake pressure rise time constant (s).
@export var brake_rise := 0.08
## Brake pressure release time constant (s).
@export var brake_release := 0.06
## Fraction of tire capacity reserved for steering while braking at full corner demand.
@export var brake_corner_reserve := 0.55
## Rider brace rearward CoM compensation at full brake pressure (m).
@export var brake_shift := 0.16
## Effective center-of-mass height used for braking pitch-over load transfer (m).
@export var brake_com_height := 0.78
## Rider braking brace adaptation time constant (s).
@export var brake_rider_response := 0.55
## Forward brake surge decay time constant (s).
@export var brake_surge_decay := 0.7
## Forward brake surge impulse scale on rapid brake grab.
@export var brake_surge_gain := 0.12
## CoM forward shift per unit brake surge impulse (m).
@export var brake_surge_shift := 0.18
## Nose-down pitch warning threshold angle before endo (rad).
@export var brake_warn_lift := 0.10
## Nose-down pitch angle that triggers over-the-bars crash (rad).
@export var brake_tip_angle := 0.38
## Speed above which sustained braking overload can tip over the bars (m/s).
@export var brake_min_tip_speed := 13.0
## Arcade stability margin beyond static endo threshold before overload builds.
@export var brake_balance_margin := 0.24
## Grace window showing warning lift before angular acceleration builds (s).
@export var brake_overload_grace := 0.85
## Brake input/pressure threshold required to build endo overload.
@export var brake_hard := 0.85
## Maximum share of unused spare grip one wheel can borrow during brake distribution.
@export var brake_share_limit := 0.9
## Fraction of uphill grade reducing front wheel load due to rider chest-forward posture.
@export var brake_climb_transfer := 0.45
## CoM shift range from manual Q/E body lean for endo equilibrium (m).
@export var brake_rider_back_shift := 0.28
## Minimum front brake force allocation share before load sharing.
@export var brake_front_share_min := 0.65
## Hold time at stop before re-pressed brake enters reverse walk (s).
@export var reverse_wait := 0.38
## Minimum negative throttle magnitude considered intentional reverse hold.
@export var reverse_input := 0.65
## Initial digital brake tap strength before holding reaches full brake.
@export var key_brake_tap := 0.65
## Digital brake hold duration to ramp from tap to full brake (s).
@export var key_brake_ramp := 0.14

@export_group("Steering & Lean")
## Peak handlebar yaw rate capability at reference speed (rad/s).
@export var max_turn_rate := 2.3
## Handlebar turn rate toward target steer command (1/s).
@export var steer_rate := 12.0
## Handlebar re-center rate when input released (1/s).
@export var steer_center := 16.0
## Yaw response rate at low speed (1/s).
@export var turn_response_slow := 16.0
## Yaw response rate at high speed (1/s).
@export var turn_response_fast := 12.0
## Multiplier on yaw damping rate when straightening out or reversing direction.
@export var turn_release_boost := 1.5
## Speed where low-speed yaw response begins blending to high-speed (m/s).
@export var turn_pace_low := 2.5
## Speed where high-speed yaw response completes blend (m/s).
@export var turn_pace_high := 16.0
## Fraction of tire lateral budget allocated to cornering command.
@export var turn_reserve := 0.97
## Nominal loaded tire share floor for steer command calculation.
@export var steer_nominal := 0.9
## Fraction of excess yaw demand beyond tire grip converted to drift yaw.
@export var slide_yaw := 0.5
## Slip angle range over which drift yaw self-limits (rad).
@export var slide_slip := Vector2(0.07, 0.17)
## Rate at which yaw rate bleeds down when front grip drops (rad/s^2).
@export var yaw_drop := 8.0
## Visual handlebar fraction tracking raw steer input at speed.
@export var steer_shown_input := 0.68
## Visual handlebar travel fraction at high speed.
@export var steer_shown_fast := 0.72
## Speed range over which visual handlebar travel reduces (m/s).
@export var steer_shown_pace := Vector2(5.0, 15.0)
## Exponent (< 1.0) enhancing low-angle visual handlebar readability for gentle corrections.
@export var steer_shown_exp := 0.72
## Initial digital key steer magnitude on tap (monotonically ramps to 1.0).
@export var key_steer_tap := 0.28
## Hold duration for digital key steer to ramp from tap to 1.0 (s).
@export var key_steer_ramp := 0.30
## Digital key steer rise smoothing rate (1/s).
@export var key_steer_response := 22.0
## Digital key steer release smoothing rate (1/s).
@export var key_steer_release := 18.0
## Digital key steer counter-steer reversal rate (1/s).
@export var key_steer_reverse := 28.0
## Rate at which accumulated digital hold time decays after release (s/s).
@export var key_hold_forget := 1.4
## Analog stick response exponent (1.0 linear, >1.0 finer center precision).
@export var stick_steer_exp := 1.5
## Roll lean response rate on ground (1/s).
@export var lean_response := 8.0
## Roll lean relaxation rate in air (1/s).
@export var lean_response_air := 2.5
## Lean share relative to equilibrium during gentle low-g bends (handlebar-led steering).
@export var lean_gentle_share := 0.18
## Net lateral acceleration where frame lean begins ramping from gentle to full carve share (m/s^2).
@export var lean_carve_from := 2.0
## Net lateral acceleration where frame lean reaches full carve share (m/s^2).
@export var lean_carve_full := 6.5
## Lean angle share relative to equilibrium on banked terrain.
@export var lean_share := 0.7
## Maximum cornering lean angle on banked terrain (rad).
@export var lean_max := 0.55
## Lean angle share relative to equilibrium on flat terrain.
@export var lean_share_flat := 0.5
## Maximum cornering lean angle on flat terrain (rad).
@export var lean_max_flat := 0.4
## Cross-slope threshold where banked lean bonus starts (m/m).
@export var lean_bank_from := 0.14
## Cross-slope where banked lean bonus reaches full weight (m/m).
@export var lean_bank_full := 0.36
## Cross-slope grade above which tires lose off-camber edge hold and slide downhill (m/m).
@export var offcamber_slide_grade := 0.50
## Cross-slope grade above which unbanked side-slope traversal loses balance and crashes (m/m).
@export var offcamber_crash_grade := 0.85
## Maximum tire grip reduction factor at full off-camber slide (0..1; leaves residual edge bite).
@export var offcamber_grip_loss := 0.72
## Sustained duration above offcamber_crash_grade required before balance loss triggers crash (s).
@export var offcamber_crash_grace := 0.35

@export_group("Suspension & Obstacles")
## Wheel suspension spring stiffness (1/s^2).
@export var spring_k := 130.0
## Suspension compression damping rate (1/s).
@export var spring_damp_comp := 23.0
## Suspension rebound damping rate (1/s).
@export var spring_damp_rebound := 26.0
## Maximum upward wheel travel / compression sag (m).
@export var sag_max := 0.16
## Maximum downward wheel extension droop (m).
@export var stretch_max := 0.08
## Resting suspension sag target while airborne (m).
@export var air_sag_target := -0.035
## Suspension deflection per unit longitudinal contact acceleration (m / (m/s^2)).
@export var pitch_load := 0.004
## Maximum vertical wheel velocity kick per substep (m/s).
@export var kick_max := 6.0
## Off-road random micro-bump amplitude (m).
@export var bump_height := 0.035
## Energy loss factor when wheel climbs onto obstacle bump (1/s).
@export var bump_drag := 1.0
## Suspension compression fraction per 1g profile vertical load.
@export var profile_sag := 0.0
## Fork compression speed threshold for bottom-out impact audio/rumble (m/s).
@export var bottom_out_speed := 0.8
## Fraction of felt landing impact velocity transferred into suspension compression.
@export var landing_kick := 0.4
## Minimum suspension velocity clamp on landing (m/s).
@export var squash_v_min := -2.0
## Maximum suspension velocity clamp on landing (m/s).
@export var squash_v_max := 4.0
## Lateral sample half-span used to detect rock/root side slope (m).
@export var rock_probe := 0.12
## Share of rock upward kick converted to lateral deflection.
@export var rock_deflect := 0.18
## Heading kick per unit lateral rock impulse divided by speed (rad / (m/s)).
@export var rock_steer := 0.5
## Minimum obstacle height above which side-slope rock/root kick deflects front steering (m).
@export var rock_steer_min_bump := 0.035
## Maximum angular velocity kick added to yaw rate from a rock/root side strike (rad/s).
@export var rock_yaw_kick_max := 0.9
## Contact edge climb angle below which wheel rolls cleanly without impact (rad).
@export var impact_angle := 0.12
## Front wheel longitudinal speed loss triggering endo crash at reference load (m/s).
@export var endo_dv := 5.0
## Reference wheel load fraction for endo_dv threshold.
@export var endo_reference_load := 0.5
## Maximum share of obstacle edge impulse absorbed by remaining suspension travel.
@export var edge_soak := 0.75
## Wall slide speed loss rate (1/s).
@export var wall_loss := 6.0
## Normal wall/tree impact speed that triggers collision crash (m/s).
@export var wall_crash := 9.0

@export_group("Flight, Hop & Landings")
## Height clearance required along lookahead to detach into flight (m).
@export var lift_threshold := 0.09
## Lookahead probe times for takeoff lift prediction (s).
@export var look_times := PackedFloat32Array([0.1, 0.2, 0.3])
## Instant downward ground step larger than this detaches immediately (m).
@export var drop_step := 0.12
## Minimum effective normal load factor below which fast crests physically detach wheels (g).
@export var detach_normal_min := 0.08
## Minimum forward speed required for physical crest unloading detachment (m/s).
@export var detach_min_speed := 3.5
## Grace window to jump after rolling off an edge (s).
@export var hop_coyote := 0.1
## Pre-landing / pre-edge jump input buffer window (s).
@export var hop_buffer := 0.22
## Maximum upward terrain velocity carried into a bunny hop (m/s).
@export var hop_carry := 3.0
## Cooldown before next jump after landing without buffered input (s).
@export var hop_wait := 0.08
## Flight duration above which landing enforces hop_wait cooldown (s).
@export var hop_wait_air := 0.2
## Base upward pop velocity of a full bunny hop (m/s).
@export var hop_pop := 3.1
## Front wheel lift height yielding maximum bunny hop pop (m).
@export var hop_front := 0.16
## Minimum front wheel lift height required to arm manual Q->E hop (m).
@export var hop_arm_height := 0.015
## Linking time window between Q front lift and E rear pop (s).
@export var hop_link := 0.3
## Front wheel upward lift acceleration gain per excess pull ratio (g).
@export var lift_gain_f := 5.0
## Rear wheel upward lift acceleration gain per excess pull ratio (g).
@export var lift_gain_r := 3.0
## Maximum manual wheel lift above support (m).
@export var lift_max := 0.6
## Maximum upward front wheel lift velocity (m/s).
@export var lift_rate_f := 1.9
## Maximum front wheel lift permitted during high-speed cornering (m).
@export var lift_turn_max := 0.10
## Auto-hop Q rearward lean phase duration (s).
@export var auto_back := 0.13
## Auto-hop E forward pop phase duration (s).
@export var auto_forward := 0.2
## Auto-hop body target strength.
@export var auto_strength := 1.0
## Rider fore/aft spring stiffness toward target posture (1/s^2).
@export var body_k := 160.0
## Rider fore/aft damping rate (1/s).
@export var body_d := 25.0
## Maximum rider fore/aft body velocity (units/s).
@export var body_rate := 4.0
## Static axle weight transfer fraction per unit body_x displacement.
@export var body_hold := 0.12
## Dynamic axle weight impulse fraction per unit body_v velocity.
@export var body_push := 0.15
## Frame nose-up pitch angle per unit unweight fraction (rad).
@export var pull_pitch := 0.25
## Landing normal impact speed above which forward speed is bled off (m/s).
@export var soft_impact := 7.0
## Flat landing normal impact speed triggering crash (m/s).
@export var crash_impact := 13.0
## Crash threshold reduction when landing nose-into an uphill slope (m/s).
@export var face_crash := 5.0
## Steep downhill slope grade above which wheels lose balance and crash.
@export var cliff_grade := 1.5
## Frame pitch alignment rate on ground (1/s).
@export var tilt_response := 25.0
## Maximum airborne frame trajectory pitch angle (rad).
@export var air_tilt_max := 0.55
## Speed floor used when computing airborne trajectory pitch angle (m/s).
@export var air_tilt_speed := 4.0
## Airborne Q/E manual pitch angular acceleration (rad/s^2).
@export var air_pitch_accel := 5.5
## Airborne pitch angular velocity damping rate (1/s).
@export var air_pitch_damp := 3.5
## Maximum airborne pitch angular velocity magnitude (rad/s).
@export var air_pitch_max_vel := 2.4
## Passive airborne pitch alignment rate toward trajectory when no Q/E input is held (1/s).
@export var air_pitch_align := 1.8
## Hard clamp on airborne pitch angle (rad).
@export var air_pitch_limit := 0.72
## Rate at which rider instability builds from slip/braking/impact stress (1/s).
@export var instability_rise := 6.0
## Rate at which rider instability recovers toward zero (1/s).
@export var instability_decay := 2.2
## Slip angle deadzone below which normal cornering does not raise instability (rad).
@export var instab_slip_from := 0.16
## Wheel impact threshold below which small twigs/bumps do not raise instability (m/s).
@export var instab_impact_from := 1.8
## Post-touchdown suspension settle window suppressing micro-rebound detaches (s).
@export var landing_settle := 0.22

@export_group("Pump & Profile")
## Longitudinal half-span for measuring terrain profile curvature (m).
@export var profile_span := 1.5
## Lateral half-span for measuring road camber/bank slope (m).
@export var bank_span := 0.5
## Lateral bank slope smoothing rate (1/s).
@export var bank_response := 15.0
## Maximum track bank/cross slope magnitude used in physics (m/m).
@export var bank_slope_max := 1.2
## Longitudinal profile vertical_g smoothing rate (1/s).
@export var g_response := 12.0
## Longitudinal profile vertical_g relaxation rate while airborne (1/s).
@export var g_relax_air := 8.0
## Minimum clamped profile load factor (g).
@export var g_min := -1.0
## Maximum clamped profile load factor (g).
@export var g_max := 1.5
## Crest vertical speed absorbed by legs during pump/crest passage (m/s).
@export var pump_absorb_v := 2.0
## Leg extension reach absorbing crest drop before detaching wheels (m).
@export var pump_reach := 0.22
## Auto-pump backside acceleration gain per unit wave slope (m/s^2).
@export var pump_accel := 3.0
## Speed above which auto-pump forward acceleration fades out (m/s).
@export var pump_top := 14.0
## Pause after manual hop/brake/impact before auto-pump resumes (s).
@export var pump_pause := 0.25
## Steer magnitude from which auto-pump yields to cornering.
@export var pump_steer_limit := 0.25
## Axle normal load fraction shifted by manual pump velocity.
@export var pump_body := 0.3
## Maximum acceleration gain/loss from manual pump (m/s^2).
@export var pump_body_accel := 2.5
## Slope change threshold beyond which terrain is treated as sharp kink/ledge, not wave (1/m).
@export var pump_kink := 0.55
## Decay time holding wave state across crests (s).
@export var pump_hold := 0.3
## Local wave slope range mapping Q to absorption vs manual lift.
@export var pump_wave_press := 0.06
## Passive leg crest absorption share without holding pump button.
@export var pump_passive := 0.32
## Maximum local wave slope up to which passive leg crest absorption activates (m/m).
@export var pump_passive_max_grade := 0.35

@export_group("Stop Stance & Parking")
## Speed below which stationary parking stance begins settling (m/s).
@export var stop_enter_speed := 0.25
## Speed above which bike exits parking stance back to riding (m/s).
@export var stop_exit_speed := 0.45
## Hold duration before planting support foot in parking stance (s).
@export var stop_settle_time := 0.28
## Maximum longitudinal slope grade held statically without brake (m/m).
@export var stop_hold_grade := 0.30
## Cross-slope grade above which planted foot cannot hold static stop (m/m).
@export var stop_dismount_cross := 0.55
## Lateral distance from bike centerline where support foot touches ground (m).
@export var stop_foot_offset := 0.27
## Maximum downward reach below tire contact level for planted support foot (m).
@export var stop_foot_max_reach := 0.35

static var _current: BikePhysicsConfig
static var _lock := Mutex.new()


## Shared config singleton from resources/bike_physics.tres (thread-safe).
static func current() -> BikePhysicsConfig:
	_lock.lock()
	var cached := _current
	_lock.unlock()
	if cached != null:
		return cached
	var loaded := load(PATH) as BikePhysicsConfig
	if loaded == null:
		loaded = BikePhysicsConfig.new()
	_lock.lock()
	if _current == null:
		_current = loaded
	var out := _current
	_lock.unlock()
	return out


## Replace active config in tests or live tuning and clear cached reference.
static func set_current(cfg: BikePhysicsConfig) -> void:
	_lock.lock()
	_current = cfg
	_lock.unlock()


## Nominal flat packed-ground tire acceleration capacity (m/s^2).
func base_grip() -> float:
	return base_mu * ground_gravity


## Flat copy of scalar/vector config fields for ride telemetry headers.
func to_dict() -> Dictionary:
	var out := {}
	for prop: Dictionary in get_property_list():
		var usage := int(prop.get("usage", 0))
		if (usage & PROPERTY_USAGE_SCRIPT_VARIABLE) == 0:
			continue
		var prop_name := String(prop.name)
		var val: Variant = get(prop_name)
		if val is float or val is int or val is bool or val is String:
			out[prop_name] = val
		elif val is Vector2:
			out[prop_name] = {x = val.x, y = val.y}
		elif val is PackedFloat32Array:
			out[prop_name] = Array(val)
	return out
