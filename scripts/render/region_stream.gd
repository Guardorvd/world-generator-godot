class_name RegionStream
extends Node3D
signal storage_failed(message: String)
var terrain_builder: TerrainBuilder = GameContext.scope.terrain
## 13.9: соседние области в игре. Ближайшая к игроку неготовая область за краем плана готовится
## в задаче WorkerThreadPool (по одной): заготовка, реки, поселения, дороги, закрепление в журнале.
## Готовая область передаётся в существующую загрузку: OuterLand берёт её клетки (рельеф кусков,
## высоты, вода, растительность), а здесь в главном потоке собираются вода, дороги, мосты и дома.
## Порядок подготовки зависит от пути игрока, но закреплённое потом не перестраивается.
## 13.9+: журнал хранится на диске (store_dir, общий для слотов сохранения этого мира) и
## восстанавливается при загрузке. Далёкие области освобождаются: узлы — дальше HIDE, поля
## клеток — дальше EVICT (остаются в файле и читаются снова при возвращении ближе KEEP).
## 14.4: меши воды и дорог области считаются в фоновой задаче (build_arrays), главный поток только
## собирает узлы — меньше заметных подёргиваний у края плана. Дороги — мягкая лента по рельефу
## (ROAD_SHADER): сглаженные повороты, общая с планом маска накатанной части и палитра покрытий;
## там, где у плана уже есть своя дорога, лента не кладётся поверх неё.

const Regions := preload("res://scripts/world/region_preparation.gd")
const TILE := GameConfig.TILE
const HS := GameConfig.HS
const REACH := OuterTerrain.RADIUS + 400.0 # м: области ближе готовятся заранее, до того как их видно
const QUEUE := 4                            # сколько ближайших неготовых областей держать в очереди
const HIDE := OuterTerrain.DROP + 200.0     # м: дальше узлы области (вода, дороги, мосты, дома) убираются
const KEEP := 2800.0                        # м: ближе поля клеток в памяти (соседи готовящейся области — ближе)
const EVICT := 3400.0                       # м: дальше поля клеток выгружаются из памяти
const RECHECK := 32.0                       # м пути между пересмотром очереди и выгрузки
const FORMAT := 4                           # foundation clearance: rebuild old regional building layouts
## 07.11.2026: соседние области — только вид, своей трассы у них нет (прежний поиск TrailScout — 1 в ключе журнала,
## до 8 с на область). 0 в ключе: журналы с трассами областей не подходят и готовятся заново, без трасс.
const REGION_TRAILS := 0
const ROAD_LIFT := 0.05                     # м: полотно над рельефом без мерцания
const ROAD_COLOR := Color8(0x8e, 0x7d, 0x62)
const ROAD_STEP := 1.0                      # м: шаг точек ленты вдоль дороги
const ROAD_ACROSS := [-1.35, -0.65, 0.0, 0.65, 1.35] # доли полуширины: края шире полотна и прозрачны (11.11.2026: общая кромка tread_mask сходит на нет к 1,3 полуширины)
const ROAD_SHADER := """shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled;
uniform sampler2D detail_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec3 road_color : source_color;
varying vec3 wpos;
#include "res://resources/cloud_shadow.gdshaderinc"
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	float n1 = texture(detail_tex, wpos.xz * 0.09).r;
	float n2 = texture(detail_tex, wpos.xz * 0.47).r;
	// Same tread alpha/threshold and palette as the plan. Regional ribbons follow
	// the real supporting terrain; only their sub-metre texture is simplified.
	float aa = clamp(fwidth(COLOR.a) * 0.5, 0.004, 0.18);
	ALPHA = smoothstep(0.38 - aa, 0.62 + aa, COLOR.a);
	float ruts = exp(-pow((abs(UV.x) - 0.47) / 0.13, 2.0)) * (1.0 - UV.y);
	float foot = (1.0 - smoothstep(0.12, 0.60, abs(UV.x))) * UV.y;
	ALBEDO = COLOR.rgb * (0.95 + (n1 - 0.5) * 0.10 + (n2 - 0.5) * 0.06) * (1.0 - ruts * 0.06 - foot * 0.035) * cloud_light(wpos.xz);
	ROUGHNESS = 0.95;
}
"""
static var root := "user://regions"         # тесты подменяют
var generation_enabled := true # Existing regions still stream when new generation is disabled.
const Files := preload("res://scripts/core/cache_file.gd")
const FIELD_CACHE_BYTES := 64 * 1024 * 1024
static var _store_lock := Mutex.new()
var _field_task := -1
var _field_key := Vector2i.ZERO
var _field_out := {}
var field_errors := {} # pinned corruption is visible once; never regenerate it silently
var _field_cache := preload("res://scripts/core/byte_lru.gd").new()
var _field_bytes: int:
	get: return _field_cache.bytes
var cpu_budget: RefCounted
var storage_error := ""
var _ledger_failed := false

var world: WorldData
var heights: Heightfield
var terrain: OuterTerrain
var vegetation: VegetationLayer
var ledger := {}
var failed := {}        # области, которые не удалось подготовить: остаются внешним рельефом
var fires: Array = []   # костры поселений показанных областей (как SettlementsBuilder.build)
var windows: Array = [] # материалы окон, ночью ярче
var boards: Array = []  # доски маршрутов показанных поселений: {at, place}, как GameWorld._boards
var queue: Array[Vector2i] = []
var _cancel := Mutex.new()
var _cancelled := false
var _save_task := -1
var _save_result := {}
var _unsaved_fields := {}
var _publishing := {}
var stats := {prepared = 0, loaded = 0, evicted = 0, built = 0, hidden = 0, apply_ms = 0.0, show_ms = 0.0}
var _task := -1
var _out := {}
var _key := Vector2i.ZERO
var _shown := {}        # область -> {node, fires, windows}
var _bridges := {}      # область -> её мосты в Heightfield, только пока область показана
var _resident := {}    # области с полями: дальние проверяем даже после телепорта
var _stream_keys: Array[Vector2i] = []
var _stream_at := Vector2.INF
var _stream_region_count := -1
var _checked_at := Vector2.INF
var _road_mat: ShaderMaterial
var _build_task := -1   # 14.4: фоновый расчёт мешей воды и дорог области _build_key
var _build_key := Vector2i.ZERO
var _build_out := {}


func setup(w: WorldData, h: Heightfield, t: OuterTerrain, v: VegetationLayer) -> void:
	_field_cache.budget = cpu_budget
	world = w
	heights = h
	terrain = t
	vegetation = v
	_road_mat = ShaderMaterial.new()
	_road_mat.shader = Shader.new()
	_road_mat.shader.code = ROAD_SHADER
	_road_mat.set_shader_parameter("road_color", ROAD_COLOR)
	_road_mat.set_shader_parameter("detail_tex", terrain_builder.outer_material().get_shader_parameter("detail_tex"))


## Папка журнала этого мира: тот же план (зерно, размер, рельеф, пути) — те же области.
static func store_dir(w: WorldData) -> String:
	if w.region_basis_id.is_empty():
		# Fingerprint v2 includes geography, even when relief/path bytes happen to match.
		var ctx := HashingContext.new()
		ctx.start(HashingContext.HASH_SHA256)
		ctx.update(("region-basis-v2|%s|%d|%d|%d|%d|%d|%d|" % [w.seed_text, w.W, w.H, WorldCache.SCHEMA_GEO_VERSION, FORMAT, StageTrailPlan.VERSION, REGION_TRAILS]).to_utf8_buffer())
		ctx.update(w.h.to_byte_array())
		ctx.update(w.path_mask)
		w.region_basis_id = ctx.finish().hex_encode().left(24)
	if w.region_store_leaf.is_empty():
		# Legacy journals predate the rare-water geography. They must not pin old
		# rivers/climate onto a newly generated dry plan; player progress is separate.
		w.region_store_leaf = w.region_basis_id
	return root.path_join(w.region_store_leaf)


## Сохранённый журнал мира без полей клеток или {} (места и задания читают его и до игры)
static func read_ledger(w: WorldData) -> Dictionary:
	var path := store_dir(w).path_join("ledger.bin")
	if not FileAccess.file_exists(path) and not FileAccess.file_exists(path + ".bak"): return {}
	var saved: Variant = _read(path, func(value: Dictionary) -> bool:
		return _valid_ledger(value))
	if not saved is Dictionary or saved.get("format") != FORMAT:
		push_warning("Журнал областей не прочитан: %s" % path)
		return {}
	var result: Dictionary = saved.ledger
	result.settlements = EntityCodec.settlements(result.get("settlements", []))
	for entry: Dictionary in result.get("regions", {}).values():
		if entry.has("decor"):
			entry.decor.settlements = EntityCodec.settlements(entry.decor.get("settlements", []))
	return result


static func _valid_ledger(value: Dictionary) -> bool:
	if value.get("format") != FORMAT or not value.get("ledger") is Dictionary: return false
	var current: Dictionary = value.ledger
	if not current.get("regions") is Dictionary or not current.get("settlements", []) is Array: return false
	for key: Variant in current.regions:
		var entry: Variant = current.regions[key]
		if not key is Vector2i or not entry is Dictionary or not entry.get("rect") is Rect2i or not entry.rect.has_area(): return false
		if not entry.get("decor") is Dictionary: return false
		for field: String in ["settlements", "bridges", "trails"]:
			if not entry.decor.get(field) is Array: return false
		if entry.decor.has("tunnels") and not entry.decor.tunnels is Array: return false
		for field: String in ["field_file", "field_sha"]:
			if entry.has(field) and not entry[field] is String: return false
		if entry.has("trail_plan") and not entry.trail_plan is Dictionary: return false
		if entry.has("map") and not entry.map is PackedByteArray: return false
	return true


## Восстановить сохранённый журнал; поля областей ближе KEEP к точке (x, z) — сразу.
func restore(x: float, z: float) -> void:
	_resident.clear()
	_stream_at = Vector2.INF
	ledger = read_ledger(world)
	if ledger.is_empty():
		var path := store_dir(world).path_join("ledger.bin")
		if FileAccess.file_exists(path) or FileAccess.file_exists(path + ".bak"):
			_ledger_failed = true
			_storage_failure("Не удалось прочитать журнал закреплённых областей. Подготовка новых областей остановлена.")
		return
	for key: Vector2i in ledger.regions:
		if _distance(key, Vector2(x, z)) <= KEEP:
			_load_fields(key)
	world.outer.set_ledger(ledger)


## Каждый кадр: забрать готовую область, затем одно действие — показать, убрать, подгрузить,
## выгрузить или начать следующую. true — в кадре была заметная работа главного потока.
func update(x: float, z: float) -> bool:
	if _ledger_failed: return false
	if _save_task != -1 and WorkerThreadPool.is_task_completed(_save_task):
		_finish_save()
	var p := Vector2(x, z)
	if _field_task != -1 and WorkerThreadPool.is_task_completed(_field_task):
		WorkerThreadPool.wait_for_task_completion(_field_task)
		_field_task = -1
		var fields: Dictionary = _field_out.get("fields", {})
		_field_out = {}
		if not fields.is_empty():
			_publish_fields(_field_key, fields)
			var rect: Rect2i = ledger.regions[_field_key].rect.grow(2)
			terrain.refresh(rect)
			vegetation.refresh(rect)
		else:
			field_errors[_field_key] = "сохранённая область повреждена или недоступна"
			_storage_failure("Поля закреплённой области %s не прочитаны; область сохранена для восстановления." % _field_key)
		return true
	if _task != -1 and _distance(_key, p) > REACH:
		_cancel.lock()
		_cancelled = true
		_cancel.unlock()
	if not _publishing.is_empty():
		# Результат подготовки уже окончательный. Пауза и очередь GPU не меняют
		# его содержимое; готовые части остаются скрыты до общей публикации.
		if _distance(_key, p) > REACH:
			for node: MeshInstance3D in _publishing.nodes.values():
				if node != null: node.queue_free()
			if _publishing.done.has("decor"): _publishing.done.decor.node.free()
			_publishing = {}
			_checked_at = Vector2.INF
			return false
		if not _publishing.pending_keys.is_empty():
			var chunk: Vector2i = _publishing.pending_keys.pop_back()
			var upload_started := Time.get_ticks_usec()
			_publishing.nodes[chunk] = terrain.stage_chunk(chunk, _publishing.done.chunks[chunk])
			var elapsed := (Time.get_ticks_usec() - upload_started) / 1000.0
			var timing: Dictionary = _publishing.done.trail.stats
			timing.upload_ms = timing.get("upload_ms", 0.0) + elapsed
			timing.max_upload_ms = maxf(timing.get("max_upload_ms", 0.0), elapsed)
			return true
		var pending: Dictionary = _publishing
		_publishing = {}
		var publish_started := Time.get_ticks_usec()
		terrain.publish_chunks(pending.done.chunks, pending.nodes)
		_apply(_key, pending.done, false)
		if pending.done.has("decor"): _show(_key, {decor = pending.done.decor})
		var timing: Dictionary = pending.done.trail.stats
		timing.publish_ms = (Time.get_ticks_usec() - publish_started) / 1000.0
		timing.complete_ms = Time.get_ticks_msec() - pending.done.trail_started
		stats.max_publish_ms = maxf(stats.get("max_publish_ms", 0.0), timing.publish_ms)
		if OS.is_debug_build():
			print("Region ready ", _key, ": ", timing)
		_persist(_key)
		return true
	if _task != -1 and WorkerThreadPool.is_task_completed(_task):
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		var result: Dictionary = _out.get("r", {})
		_out = {}
		if result.get("cancelled", false) or _distance(_key, p) > REACH:
			if result.has("decor"): result.decor.node.free()
			_checked_at = Vector2.INF
			return false
		if result.get("ready", false) and result.has("chunks"):
			_publishing = {done = result, pending_keys = result.chunks.keys(), nodes = {}}
		else:
			_apply(_key, result)
		return true
	if _build_task != -1 and WorkerThreadPool.is_task_completed(_build_task):
		WorkerThreadPool.wait_for_task_completion(_build_task)
		_build_task = -1
		var entry: Variant = ledger.get("regions", {}).get(_build_key)
		if entry != null and entry.has("fields") and not _shown.has(_build_key) and _distance(_build_key, p) <= REACH:
			var built := _build_out
			_build_out = {}
			_show(_build_key, built)
			return true
		var unused: Node = _build_out.get("decor", {}).get("node")
		if is_instance_valid(unused) and unused.get_parent() == null: unused.free()
		_build_out = {}
	if generation_enabled and p.distance_to(_checked_at) > RECHECK:
		_checked_at = p
		_plan(p)
	for key: Vector2i in _stream_candidates(p):
		var d := _distance(key, p)
		var entry: Dictionary = ledger.regions[key]
		if d <= KEEP and not entry.has("fields") and not field_errors.has(key):
			if _field_task == -1: _request_fields(key)
			continue
		if d > EVICT and entry.has("fields") and not _unsaved_fields.has(key):
			_evict(key)
			return false
		if d <= REACH and not _shown.has(key) and entry.has("fields"):
			if _build_task == -1:
				_start_build(key)
			continue
		if d > HIDE and _shown.has(key):
			_hide(key)
			return true
	if generation_enabled and _task == -1 and _save_task == -1 and not queue.is_empty():
		var key: Vector2i = queue.pop_front()
		if ledger.get("regions", {}).has(key) or failed.has(key) or not _neighbors_ready(key):
			_checked_at = Vector2.INF # пересмотреть очередь в следующем кадре
			return false
		_key = key
		_cancelled = false
		_out = {}
		var out := _out
		# Словари и вложенные массивы принадлежат задаче до wait_for_task_completion.
		var snapshot: Dictionary = ledger.duplicate()
		snapshot.regions = ledger.get("regions", {}).duplicate()
		var w := world
		var view := preload("res://scripts/game/navigation_snapshot.gd").capture(heights, false)
		var material := _road_mat
		_task = WorkerThreadPool.add_task(func() -> void: out.r = prepare_region(w, key, snapshot, "", _stopped, terrain, view, material), false, "Область")
	return false


## Historical maps/places remain available, but never form a per-frame work queue.
## Query the regular region grid and include currently resident/shown regions for eviction.
func _stream_candidates(p: Vector2) -> Array[Vector2i]:
	var regions: Dictionary = ledger.get("regions", {})
	if p.distance_to(_stream_at) < RECHECK and _stream_region_count == regions.size():
		return _stream_keys
	_stream_at = p
	_stream_region_count = regions.size()
	var keys := _resident.duplicate()
	keys.merge(_shown)
	var side := WorldData.REGION_SIZE * TILE
	# Cover movement until the next refresh, including an exact region boundary.
	var reach := KEEP + RECHECK
	var first := Vector2i(floori((p.x - reach) / side), floori((p.y - reach) / side))
	var last := Vector2i(floori((p.x + reach) / side), floori((p.y + reach) / side))
	for y in range(first.y, last.y + 1):
		for x in range(first.x, last.x + 1):
			var key := Vector2i(x, y)
			if regions.has(key): keys[key] = true
	_stream_keys.assign(keys.keys())
	return _stream_keys


func _storage_failure(message: String) -> void:
	storage_error = message
	push_warning(message)
	storage_failed.emit(message)


func _stopped() -> bool:
	_cancel.lock()
	var value := _cancelled
	_cancel.unlock()
	return value

func finish() -> void:
	if _field_task != -1:
		WorkerThreadPool.wait_for_task_completion(_field_task)
		_field_task = -1
	_cancel.lock()
	_cancelled = true
	_cancel.unlock()
	if _save_task != -1:
		_finish_save()
	if _task != -1:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	if _build_task != -1:
		WorkerThreadPool.wait_for_task_completion(_build_task)
		_build_task = -1
	for result: Dictionary in [_out.get("r", {}), _build_out]:
		var node: Node = result.get("decor", {}).get("node")
		if is_instance_valid(node) and node.get_parent() == null: node.free()
	if not _publishing.is_empty():
		for node: Node in _publishing.nodes.values():
			if is_instance_valid(node): node.queue_free()
		var node: Node = _publishing.done.get("decor", {}).get("node")
		if is_instance_valid(node) and node.get_parent() == null: node.free()
		_publishing = {}



## 14.4: меши воды и дорог области — в фоне, по снимку журнала (поля областей там не меняются)
func _start_build(key: Vector2i) -> void:
	_build_key = key
	_build_out = {}
	var out := _build_out
	var entry: Dictionary = ledger.regions[key]
	var w := world
	var view := preload("res://scripts/game/navigation_snapshot.gd").capture(heights, false)
	var material := _road_mat
	_build_task = WorkerThreadPool.add_task(func() -> void:
		out.decor = build_decor(w, view, key, entry, material), false, "Узлы области")



func _exit_tree() -> void:
	finish()


## Подготовить, закрепить и записать одну область (в фоне). Река без допустимого русла не принимается:
## тогда область готовится без входящих рек, и вода кончается у её границы.
static func prepare_region(w: WorldData, key: Vector2i, current: Dictionary, dir := "", stop := Callable(), terrain_source: OuterTerrain = null, view: Heightfield = null, road_material: Material = null) -> Dictionary:
	if stop.is_valid() and stop.call(): return {cancelled = true}
	var r := Regions.prepare(w, key, current)
	var network := Regions.prepare_rivers(r)
	var batch := Regions.finish_neighbors(w, [r], [network], current)
	var dropped := 0
	if not batch.ready:
		dropped = r.river_inputs.size()
		r.river_inputs = []
		network = Regions.prepare_rivers(r)
		batch = Regions.finish_neighbors(w, [r], [network], current)
		if not batch.ready:
			return {ready = false, reason = batch.reason}
	if stop.is_valid() and stop.call(): return {cancelled = true}
	var roads := Regions.prepare_roads(w, [r], batch, current, stop)
	if stop.is_valid() and stop.call(): return {cancelled = true}
	var done := Regions.commit(current, [r], [network], batch, roads)
	if stop.is_valid() and stop.call(): return {cancelled = true}
	if done.ready:
		var trail_started := Time.get_ticks_msec()
		if terrain_source != null:
			done.chunks = {}
			var rect := Regions.rect_for(key).grow(1)
			for cy in range(floori(float(rect.position.y) / OuterLand.C), floori(float(rect.end.y - 1) / OuterLand.C) + 1):
				for cx in range(floori(float(rect.position.x) / OuterLand.C), floori(float(rect.end.x - 1) / OuterLand.C) + 1):
					if stop.is_valid() and stop.call(): return {cancelled = true}
					var chunk := Vector2i(cx, cy)
					done.chunks[chunk] = terrain_source._build(chunk, done.ledger)
		var mesh_ms := Time.get_ticks_msec() - trail_started
		# 07.11.2026: соседняя область — только вид, трасса не ищется (REGION_TRAILS). Запись плана остаётся для отчёта.
		done.trail = {version = REGION_TRAILS, state = "none", verdict = "off", reason = "у соседних областей нет своих трасс", stats = {}}
		done.ledger.regions[key].trail_plan = done.trail
		if view != null:
			view.world.outer.set_ledger(done.ledger)
			var decor_started := Time.get_ticks_msec()
			done.decor = build_decor(w, view, key, done.ledger.regions[key], road_material)
			done.trail.stats.decor_ms = Time.get_ticks_msec() - decor_started
			if stop.is_valid() and stop.call():
				done.decor.node.free()
				return {cancelled = true}
		done.trail.stats.mesh_ms = mesh_ms
		done.trail.stats.worker_ms = Time.get_ticks_msec() - trail_started
		done.trail_started = trail_started
	done.dropped_rivers = dropped
	done.roads = roads
	if done.ready:
		# Картинка области для большой карты: остаётся в журнале и после выгрузки полей.
		var entry: Dictionary = done.ledger.regions[key]
		entry.map = map_png(entry)
	if done.ready and not dir.is_empty():
		var err := save(dir, done.ledger, key)
		if err != OK:
			push_warning("Область %s не записана: ошибка %d" % [key, err])
	return done


## Поля области — в свой файл, журнал без полей — в ledger.bin; запись через временный файл.
static func save(dir: String, current: Dictionary, key: Vector2i, written := {}) -> Error:
	_store_lock.lock()
	var result := _save_generation(dir, current, key, written)
	_store_lock.unlock()
	return result


static func _save_generation(dir: String, current: Dictionary, key: Vector2i, written: Dictionary) -> Error:
	var err := DirAccess.make_dir_recursive_absolute(dir)
	if err != OK:
		return err
	var previous: Variant = _read(dir.path_join("ledger.bin"))
	var old_regions: Dictionary = previous.get("ledger", {}).get("regions", {}) if previous is Dictionary else {}
	var light := current.duplicate()
	light.regions = {}
	for k: Vector2i in current.regions:
		var e: Dictionary = current.regions[k]
		light.regions[k] = {rect = e.rect, decor = e.decor, trail_plan = e.get("trail_plan", {}), map = e.get("map", PackedByteArray())}
		var ref: Dictionary = old_regions.get(k, e)
		if k == key or not ref.has("field_file"):
			if e.has("fields"):
				var data: Variant = EntityCodec.encode({format = FORMAT, rect = e.rect, fields = e.fields})
				var bytes := _pack(data)
				var digest := Util.sha256(bytes).hex_encode()
				var name := "%d_%d.%s.region" % [k.x, k.y, digest]
				if not _block_ok(dir.path_join(name), digest):
					err = Files.replace(dir.path_join(name), bytes)
					if err != OK: return err
				# Verify every block before publishing a ledger referencing it.
				if Util.sha256(FileAccess.get_file_as_bytes(dir.path_join(name))).hex_encode() != digest: return ERR_FILE_CORRUPT
				ref = {field_file = name, field_sha = digest}
			else:
				# A legacy unloaded region keeps its old immutable address until loaded/saved.
				ref = {field_file = "%d_%d.region" % [k.x, k.y], field_sha = ""}
		light.regions[k].field_file = ref.field_file
		light.regions[k].field_sha = ref.get("field_sha", "")
	err = _write(dir.path_join("ledger.bin"), {format = FORMAT, ledger = light})
	if err == OK:
		written.regions = light.regions
		_prune_blocks(dir, light.regions, old_regions)
	return err


## Блоки полей, на которые не ссылается ни новый журнал, ни прежний (он остаётся резервной копией ledger.bin.bak), удаляются.
static func _prune_blocks(dir: String, current_regions: Dictionary, old_regions: Dictionary) -> void:
	var keep := {}
	for regions: Dictionary in [current_regions, old_regions]:
		for k: Variant in regions:
			var file := String(regions[k].get("field_file", ""))
			if not file.is_empty():
				keep[file] = true
	var pattern := RegEx.create_from_string("^-?\\d+_-?\\d+\\.[0-9a-f]{64}\\.region(\\.bak)?$")
	for file: String in DirAccess.get_files_at(dir):
		if pattern.search(file) == null:
			continue
		if keep.has(file.trim_suffix(".bak")):
			continue
		DirAccess.remove_absolute(dir.path_join(file))


## Блок с таким именем уже лежит на диске и его хеш сходится (испорченный будет записан заново).
static func _block_ok(path: String, digest: String) -> bool:
	return FileAccess.file_exists(path) and Util.sha256(FileAccess.get_file_as_bytes(path)).hex_encode() == digest


static func _write(path: String, value: Variant) -> Error:
	var preserve := FileAccess.file_exists(path) and _read_one(path) == null
	return Files.replace(path, _pack(EntityCodec.encode(value)), preserve)


static func _pack(value: Variant) -> PackedByteArray:
	var raw := var_to_bytes(value)
	var packed := raw.compress(FileAccess.COMPRESSION_ZSTD)
	return "RGC1".to_ascii_buffer() + var_to_bytes({storage = 1, size = raw.size(), sha = Util.sha256(packed), packed = packed})


static func _read(path: String, validator := Callable()) -> Variant:
	for suffix: String in ["", ".bak"]:
		var data: Variant = _read_one(path + suffix)
		if data is Dictionary and (not validator.is_valid() or validator.call(data)): return data
	return null


static func _read_one(path: String) -> Variant:
	if not FileAccess.file_exists(path): return null
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() < 4: return null
	var magic := bytes.slice(0, 4).get_string_from_ascii()
	if magic == "GCPF":
		var f := FileAccess.open_compressed(path, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
		var legacy: Variant = f.get_var(false) if f != null else null
		return legacy if legacy is Dictionary else null
	if magic != "RGC1": return null
	var envelope: Variant = bytes_to_var(bytes.slice(4))
	if not envelope is Dictionary or envelope.get("storage") != 1 or not envelope.get("packed") is PackedByteArray or not envelope.get("size") is int: return null
	if envelope.size <= 0 or envelope.size > (1 << 30) or Util.sha256(envelope.packed) != envelope.get("sha"): return null
	var raw: PackedByteArray = envelope.packed.decompress(envelope.size, FileAccess.COMPRESSION_ZSTD)
	if raw.size() != envelope.size: return null
	var data: Variant = bytes_to_var(raw)
	return data if data is Dictionary else null


## Очередь: ближайшие неготовые области за краем плана ближе REACH, не больше QUEUE
func _plan(p: Vector2) -> void:
	var c := p / TILE
	var reach := REACH / TILE
	var size := WorldData.REGION_SIZE
	var plan := Rect2i(0, 0, world.W, world.H)
	var regions: Dictionary = ledger.get("regions", {})
	var found: Array = []
	for ky in range(floori((c.y - reach) / size), floori((c.y + reach) / size) + 1):
		for kx in range(floori((c.x - reach) / size), floori((c.x + reach) / size) + 1):
			var key := Vector2i(kx, ky)
			if Regions.rect_for(key).intersects(plan) or regions.has(key) or failed.has(key) or (_task != -1 and key == _key):
				continue
			var d := _distance(key, p)
			if d <= REACH:
				found.append([d, key])
	found.sort_custom(func(a: Array, b: Array) -> bool:
		return a[0] < b[0] or a[0] == b[0] and (a[1].y < b[1].y or a[1].y == b[1].y and a[1].x < b[1].x))
	queue.clear()
	for item: Array in found.slice(0, QUEUE):
		queue.append(item[1])


## Соседи готовящейся области передают ей окончательные клетки: их поля должны быть в памяти
func _neighbors_ready(key: Vector2i) -> bool:
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var e: Variant = ledger.get("regions", {}).get(key + Vector2i(dx, dy))
			if e != null and not e.has("fields"):
				return false
	return true


func _distance(key: Vector2i, p: Vector2) -> float:
	var rect := Regions.rect_for(key)
	var a := Vector2(rect.position) * TILE
	return p.distance_to(p.clamp(a, a + Vector2(rect.size) * TILE))


func _load_fields(key: Vector2i) -> void:
	var fields := _read_fields(store_dir(world), key, ledger.regions[key])
	if fields.is_empty():
		field_errors[key] = "сохранённая область повреждена или недоступна"
		_storage_failure("Поля закреплённой области %s не прочитаны; область сохранена для восстановления." % key)
	else: _publish_fields(key, fields)


static func _read_fields(dir: String, key: Vector2i, entry: Dictionary) -> Dictionary:
	if not entry.get("rect") is Rect2i or not entry.rect.has_area(): return {}
	if not entry.get("field_file", "") is String or not entry.get("field_sha", "") is String: return {}
	var name: String = entry.get("field_file", "%d_%d.region" % [key.x, key.y])
	if name != name.get_file(): return {}
	var path := dir.path_join(name)
	var digest: String = entry.get("field_sha", "")
	for suffix: String in ["", ".bak"]:
		if not digest.is_empty():
			if not FileAccess.file_exists(path + suffix): continue
			if Util.sha256(FileAccess.get_file_as_bytes(path + suffix)).hex_encode() != digest: continue
		var saved: Variant = _read_one(path + suffix)
		if _valid_fields(saved, entry.rect): return saved.fields
	return {}


## Проверка содержимого нужна и после контрольной суммы: старые записи могут быть
## корректным контейнером с неполными полями. Такой primary не скрывает исправный backup.
static func _valid_fields(saved: Variant, rect: Rect2i) -> bool:
	if not saved is Dictionary or saved.get("format") != FORMAT or saved.get("rect") != rect or not saved.get("fields") is Dictionary: return false
	var fields: Dictionary = saved.fields
	var n := rect.get_area()
	for field: String in ["h", "water_level", "dist", "slope", "dw", "dist_path"]:
		if not fields.get(field) is PackedFloat32Array or fields[field].size() != n: return false
	for field: String in ["biome", "river", "ocean", "lake", "path", "village"]:
		if not fields.get(field) is PackedByteArray or fields[field].size() != n: return false
	var climate := ["elev", "temp", "moist", "light"]
	if climate.any(func(field: String) -> bool: return fields.has(field)):
		for field: String in climate:
			if not fields.get(field) is PackedFloat32Array or fields[field].size() != n: return false
			for value: float in fields[field]:
				if not is_finite(value) or value < 0.0 or (field != "elev" and value > 1.0): return false
	for i in n:
		if not is_finite(fields.h[i]): return false
		var water: float = fields.water_level[i]
		if not is_finite(water) and water != -INF: return false
		if fields.biome[i] >= Biomes.LIST.size(): return false
	return true


func _request_fields(key: Vector2i) -> void:
	_field_key = key
	_field_out = {}
	var out := _field_out
	var cached: Variant = _field_cache.get_value(key)
	if cached != null:
		out.fields = cached
		_field_cache.erase(key)
		_field_task = WorkerThreadPool.add_task(func() -> void: pass, false)
		return
	var dir := store_dir(world)
	var entry: Dictionary = ledger.regions[key]
	_field_task = WorkerThreadPool.add_task(func() -> void: out.fields = _read_fields(dir, key, entry), false, "Чтение области")


func _publish_fields(key: Vector2i, fields: Dictionary) -> void:
	_resident[key] = true
	_stream_at = Vector2.INF
	ledger = ledger.duplicate()
	ledger.regions = ledger.regions.duplicate()
	var entry: Dictionary = ledger.regions[key].duplicate()
	entry.fields = fields
	ledger.regions[key] = entry
	world.outer.set_ledger(ledger)
	stats.loaded += 1


## Поля далёкой области остаются только в файле; запись журнала (rect, decor) — в памяти
func _evict(key: Vector2i) -> void:
	_resident.erase(key)
	_stream_at = Vector2.INF
	var fields: Dictionary = ledger.regions[key].fields
	_field_cache.limit = FIELD_CACHE_BYTES
	_field_cache.put(key, fields)
	ledger = ledger.duplicate()
	ledger.regions = ledger.regions.duplicate()
	var entry: Dictionary = ledger.regions[key].duplicate()
	entry.erase("fields")
	ledger.regions[key] = entry
	world.outer.set_ledger(ledger)
	stats.evicted += 1


func _apply(key: Vector2i, done: Dictionary, persist := true) -> void:
	var started := Time.get_ticks_usec()
	if not done.get("ready", false):
		failed[key] = true
		push_warning("Область %s не подготовлена: %s" % [key, done.get("reason", "")])
		return
	# Результат строился на снимке журнала: перенести прочитанные и выгруженные с тех пор поля.
	var next: Dictionary = done.ledger
	next.regions = next.regions.duplicate()
	for k: Vector2i in ledger.get("regions", {}):
		if next.regions.has(k) and ledger.regions[k].has("fields") != next.regions[k].has("fields"):
			next.regions[k] = ledger.regions[k]
	ledger = next
	_resident[key] = true
	_stream_at = Vector2.INF
	world.outer.set_ledger(ledger)
	var rect := Regions.rect_for(key)
	if not done.has("chunks"): terrain.refresh(rect.grow(2))
	vegetation.refresh(rect.grow(2))
	if persist: _persist(key)
	stats.prepared += 1
	stats.apply_ms = maxf(stats.apply_ms, (Time.get_ticks_usec() - started) / 1000.0)
	_checked_at = Vector2.INF # узлы покажет следующий кадр: принятие и сборка в разных кадрах


## Узлы области: вода по мокрым клеткам, лента дорог, мосты и дома штатными сборщиками.
## arrays — посчитанные в фоне {water, roads}; без них считаются здесь
func _show(key: Vector2i, arrays := {}) -> void:
	var started := Time.get_ticks_usec()
	var entry: Dictionary = ledger.regions[key]
	if not _bridges.has(key): _bridges[key] = heights.add_outer_bridges(entry.decor.bridges)
	var built: Dictionary = arrays.decor if arrays.has("decor") else build_decor(world, heights, key, entry, _road_mat, _bridges[key])
	add_child(built.node)
	_shown[key] = built
	stats.built += 1
	stats.show_ms = maxf(stats.get("show_ms", 0.0), (Time.get_ticks_usec() - started) / 1000.0)
	_collect()


static func build_decor(world: WorldData, heights: Heightfield, key: Vector2i, entry: Dictionary, road_material: Material, registered_bridges: Variant = null) -> Dictionary:
	var decor: Dictionary = entry.decor
	var node := Node3D.new()
	node.name = "Region_%d_%d" % [key.x, key.y]
	var water := WaterBuilder.flat_mesh(water_arrays(entry), WaterBuilder._material(), "Water")
	if water != null:
		water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		water.add_to_group("regional_water_effects")
		node.add_child(water)
	var ribbons: Array = road_arrays(world, func(x: float, z: float) -> float: return heights.ground_at(x, z), decor.trails)
	if not ribbons.is_empty():
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, ribbons)
		var mi := MeshInstance3D.new()
		mi.name = "Roads"
		mi.mesh = mesh
		mi.material_override = road_material
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.add_child(mi)
	var bridges: Array = heights.add_outer_bridges(decor.bridges) if registered_bridges == null else registered_bridges
	StructuresBuilder.build(node, heights, bridges)
	# Тот же сборщик домов, что у плана: временный мир только со списком поселений области.
	var places := WorldData.new()
	places.seed_num = world.seed_num ^ (key.x * 73856093) ^ (key.y * 19349663)
	places.settlements = decor.settlements
	var built := SettlementsBuilder.build(node, places, heights)
	var own: Array = []
	for s: SettlementData in decor.settlements:
		var foot := SettlementsBuilder.board_foot(s, heights)
		own.append({at = Transform3D(Basis(Vector3.UP, -PI / 4.0), foot + Vector3(0, 1.35, 0)), place = s})
	return {node = node, fires = built.fires, windows = built.windows, boards = own}


func _hide(key: Vector2i) -> void:
	_shown[key].node.queue_free()
	_shown.erase(key)
	_stream_at = Vector2.INF
	if _bridges.has(key):
		heights.remove_outer_bridges(_bridges[key])
		_bridges.erase(key)
	stats.hidden += 1
	_collect()


func _collect() -> void:
	fires = []
	windows = []
	boards = []
	for key: Vector2i in _shown:
		fires.append_array(_shown[key].fires)
		windows.append(_shown[key].windows)
		boards.append_array(_shown[key].boards)


## Сколько областей с полями в памяти и показанных (для проверок памяти)
func counts() -> Dictionary:
	var with_fields := 0
	for key: Vector2i in ledger.get("regions", {}):
		with_fields += int(ledger.regions[key].has("fields"))
	return {regions = ledger.get("regions", {}).size(), fields = with_fields, shown = _shown.size()}


## Карта области в PNG, клетка — пиксель: цвет биома с отмывкой склонов, вода, дороги.
static func map_png(region: Dictionary) -> PackedByteArray:
	var rect: Rect2i = region.rect
	var f: Dictionary = region.fields
	var W := rect.size.x
	var H := rect.size.y
	var img := Image.create(W, H, false, Image.FORMAT_RGB8)
	var water := Color8(0x4a, 0x7f, 0xb0)
	var road := Color8(0xb8, 0x9a, 0x6a)
	for y in H:
		for x in W:
			var i := y * W + x
			var c: Color
			if f.river[i] != 0 or f.lake[i] != 0:
				c = water
			elif f.path[i] >= 2:
				c = road
			else:
				var rgb: Array = Biomes.LIST[f.biome[i]].color
				c = Color8(rgb[0], rgb[1], rgb[2])
				# свет с северо-запада, как отмывка карты плана
				var dx: float = f.h[y * W + mini(x + 1, W - 1)] - f.h[y * W + maxi(x - 1, 0)]
				var dy: float = f.h[mini(y + 1, H - 1) * W + x] - f.h[maxi(y - 1, 0) * W + x]
				c = c * clampf(1.0 - (dx + dy) * 6.0, 0.6, 1.3)
			img.set_pixel(x, y, c)
	return img.save_png_to_buffer()


## Плоская вода области: квадрат на каждую мокрую клетку, углы — средний уровень соседних мокрых
## клеток, поэтому поверхность непрерывна и вдоль русла понижается без ступенек.
static func water_arrays(region: Dictionary) -> Array:
	var rect: Rect2i = region.rect
	var f: Dictionary = region.fields
	var W := rect.size.x
	var H := rect.size.y
	var level: PackedFloat32Array = f.water_level
	var wet := PackedByteArray()
	wet.resize(W * H)
	var any := false
	for i in W * H:
		if (f.river[i] != 0 or f.lake[i] != 0) and is_finite(level[i]):
			wet[i] = 1
			any = true
	var pos := PackedVector3Array()
	if not any:
		return []
	var corner := PackedVector3Array()
	corner.resize(4)
	for y in H:
		for x in W:
			if wet[y * W + x] == 0:
				continue
			for c in 4:
				var cx := x + (c & 1)
				var cy := y + (c >> 1)
				corner[c] = Vector3((rect.position.x + cx) * TILE, OuterLand.water_corner(f, W, H, cx, cy) * HS, (rect.position.y + cy) * TILE)
			pos.append_array([corner[0], corner[1], corner[2], corner[1], corner[3], corner[2]])
	return WaterBuilder._arrays(pos)


## Полотно дорог области лентой над рельефом в главном потоке (Heightfield игры)
func _road_arrays(trails: Array) -> Array:
	return road_arrays(world, func(x: float, z: float) -> float: return heights.ground_at(x, z), trails)


## Высота земли для фоновой задачи: внутри плана — Heightfield (его поля после загрузки не меняются),
## за краем — поля закреплённых областей из снимка журнала, той же триангуляцией, что сетка рельефа.
## Куски OuterLand не читаются: главный поток в это время их меняет.
static func snapshot_ground(w: WorldData, heights: Heightfield, regions: Dictionary, x: float, z: float) -> float:
	var refined := OuterLand.refined_at(regions, x, z)
	if not refined.is_empty(): return refined.h
	var fx := x / TILE - 0.5
	var fz := z / TILE - 0.5
	if fx >= 0.0 and fz >= 0.0 and fx <= w.W - 1.001 and fz <= w.H - 1.001:
		return heights.ground_at(x, z)
	var i := floori(fx)
	var j := floori(fz)
	var a := _cell_m(w, heights, regions, i, j)
	var b := _cell_m(w, heights, regions, i + 1, j)
	var c := _cell_m(w, heights, regions, i, j + 1)
	var d := _cell_m(w, heights, regions, i + 1, j + 1)
	var tx := fx - i
	var tz := fz - j
	if tx + tz <= 1.0:
		return a + (b - a) * tx + (c - a) * tz
	return d + (c - d) * (1.0 - tx) + (b - d) * (1.0 - tz)


static func _cell_m(w: WorldData, heights: Heightfield, regions: Dictionary, i: int, j: int) -> float:
	if i >= 0 and j >= 0 and i < w.W and j < w.H:
		return heights.hv[j * w.W + i]
	var size := WorldData.REGION_SIZE
	var r: Variant = regions.get(Vector2i(floori(float(i) / size), floori(float(j) / size)))
	if r == null or not r.has("fields"):
		return heights.hv[clampi(j, 0, w.H - 1) * w.W + clampi(i, 0, w.W - 1)]
	var rect: Rect2i = r.rect
	var k := (j - rect.position.y) * rect.size.x + i - rect.position.x
	return Heightfield.outer_meters(r.fields.h[k], r.fields.ocean[k] == 0)


## 14.4: лента дорог. Повороты сглажены (два прохода Чайкина), точки каждые ROAD_STEP м, поперёк пять
## рядов: высота каждой вершины — земля под ней, поэтому лента ложится по рельефу, а не висит хордой.
## Прозрачность края — общая tread_mask в цвете вершины; UV.x — поперечная доля, UV.y — singletrack.
## Участки по клеткам, где у плана уже есть дорога (path_mask ≥ 2), пропускаются: её рисует план.
static func road_arrays(w: WorldData, ground: Callable, trails: Array) -> Array:
	var noise := FastNoiseLite.new()
	noise.seed = w.seed_num
	noise.frequency = 1.0
	noise.fractal_octaves = 2
	var pos := PackedVector3Array()
	var col := PackedColorArray()
	var uv := PackedVector2Array()
	var idx := PackedInt32Array()
	for trail: Dictionary in trails:
		if trail.has("trail_id"): continue # its tread is part of the refined ground mesh
		var pts: Array = trail.pts
		var line := PackedVector2Array()
		var half := PackedFloat32Array()
		var colors := PackedColorArray()
		for p_idx in pts.size():
			var p: Dictionary = pts[p_idx]
			line.append(Vector2(p.x, p.y) * TILE)
			half.append(float(p.w) * TILE * 0.5)
			var surface: int = trail.surf[p_idx] if trail.has("surf") and p_idx < trail.surf.size() else RoadSurface.GRAVEL
			var data: Dictionary = RoadSurface.LIST[maxi(1, surface)]
			var color := Color8(data.color[0], data.color[1], data.color[2]).srgb_to_linear()
			color.a = data.organic
			colors.append(color)
		for pass_n in 2:
			if line.size() < 3:
				break
			var sl := PackedVector2Array([line[0]])
			var sh := PackedFloat32Array([half[0]])
			var sc := PackedColorArray([colors[0]])
			for k in line.size() - 1:
				sl.append_array([line[k].lerp(line[k + 1], 0.25), line[k].lerp(line[k + 1], 0.75)])
				sh.append_array([lerpf(half[k], half[k + 1], 0.25), lerpf(half[k], half[k + 1], 0.75)])
				sc.append_array([colors[k].lerp(colors[k + 1], 0.25), colors[k].lerp(colors[k + 1], 0.75)])
			sl.append(line[-1])
			sh.append(half[-1])
			sc.append(colors[-1])
			line = sl
			half = sh
			colors = sc
		# ровный шаг вдоль дороги
		var dense := PackedVector2Array()
		var dhalf := PackedFloat32Array()
		var dcolors := PackedColorArray()
		for k in line.size():
			if k > 0:
				var q := line[k - 1]
				var steps := maxi(1, ceili(q.distance_to(line[k]) / ROAD_STEP))
				for st in range(1, steps):
					dense.append(q.lerp(line[k], float(st) / steps))
					dhalf.append(lerpf(half[k - 1], half[k], float(st) / steps))
					dcolors.append(colors[k - 1].lerp(colors[k], float(st) / steps))
			dense.append(line[k])
			dhalf.append(half[k])
			dcolors.append(colors[k])
		var run := -1 # номер первой вершины текущего непрерывного участка
		for k in dense.size():
			var at := dense[k]
			var cell := Vector2i(floori(at.x / TILE), floori(at.y / TILE))
			if cell.x >= 0 and cell.y >= 0 and cell.x < w.W and cell.y < w.H and w.path_mask[cell.y * w.W + cell.x] >= 2:
				run = -1
				continue
			var along := (dense[mini(k + 1, dense.size() - 1)] - dense[maxi(k - 1, 0)]).normalized()
			var side := along.orthogonal() * dhalf[k]
			var base := pos.size()
			var road: bool = trail.kind == "road"
			var slow := noise.get_noise_2d(at.x * 0.13, at.y * 0.13)
			for u: float in ROAD_ACROSS:
				var v := at + side * u
				pos.append(Vector3(v.x, ground.call(v.x, v.y) + ROAD_LIFT, v.y))
				var tint := dcolors[k]
				tint.a = RoadRefinement.tread_mask(dhalf[k], absf(u) * dhalf[k], slow, tint.a, road)
				col.append(tint)
				uv.append(Vector2(u, 0.0 if road else 1.0))
			if run != -1:
				var n := ROAD_ACROSS.size()
				for c in n - 1:
					var a0 := base - n + c
					var b0 := base + c
					idx.append_array([a0, b0, a0 + 1, a0 + 1, b0, b0 + 1])
			run = base
	if idx.is_empty():
		return []
	var nor := PackedVector3Array()
	nor.resize(pos.size())
	nor.fill(Vector3.UP)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = nor
	arrays[Mesh.ARRAY_COLOR] = col
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = idx
	return arrays


func publication_pending() -> bool:
	return not _publishing.is_empty()

func _persist(key: Vector2i) -> void:
	# Own a snapshot of the entity records and fields. Generation waits for the
	# write, but the frame only polls and can keep streaming existing regions.
	_unsaved_fields[key] = true
	var accepted: Dictionary = EntityCodec.encode(ledger).duplicate(true)
	_save_result = {key = key}
	var result := _save_result
	var dir := store_dir(world)
	_save_task = WorkerThreadPool.add_task(func() -> void:
		result.error = save(dir, accepted, key, result), false, "Запись области")


func _finish_save() -> void:
	WorkerThreadPool.wait_for_task_completion(_save_task)
	_save_task = -1
	var result := _save_result
	_save_result = {}
	if result.error != OK:
		_storage_failure("Не удалось записать область %s (%d)." % [result.key, result.error])
		return
	ledger = ledger.duplicate()
	ledger.regions = ledger.regions.duplicate()
	for key: Vector2i in _unsaved_fields.keys():
		var saved: Dictionary = result.regions[key]
		var entry: Dictionary = ledger.regions[key].duplicate()
		entry.field_file = saved.field_file
		entry.field_sha = saved.field_sha
		ledger.regions[key] = entry
		_unsaved_fields.erase(key)
	world.outer.set_ledger(ledger)
