extends RefCounted
## Shared estimate of retained derivative data. Active jobs reserve space and evict retired data.
var limit := 192 * 1024 * 1024
var _reserved := 0
var _bytes := 0
var _entries := {}
var _lock := Mutex.new()
var _hits := 0
var _misses := 0
var _evictions := 0
var _peak := 0

func get_value(owner: int, key: Variant) -> Variant:
	_lock.lock()
	var id := [owner, key]
	var value: Variant = null
	if _entries.has(id):
		var entry: Dictionary = _entries[id]
		_entries.erase(id)
		_entries[id] = entry
		value = entry.value
		_hits += 1
	else: _misses += 1
	_lock.unlock()
	return value

func put(owner: int, key: Variant, value: Variant, bytes: int, owner_limit: int) -> bool:
	_lock.lock()
	var id := [owner, key]
	_erase(id)
	var accepted := bytes <= owner_limit and bytes <= maxi(0, limit - _reserved)
	if accepted:
		while _owner_bytes(owner) + bytes > owner_limit:
			for old: Array in _entries:
				if old[0] == owner:
					_erase(old)
					break
		_entries[id] = {value = value, bytes = bytes}
		_bytes += bytes
		_trim()
		_peak = maxi(_peak, _bytes)
	_lock.unlock()
	return accepted

func erase(owner: int, key: Variant) -> void:
	_lock.lock()
	_erase([owner, key])
	_lock.unlock()

func clear_owner(owner: int) -> void:
	_lock.lock()
	for id: Array in _entries.keys():
		if id[0] == owner: _erase(id)
	_lock.unlock()

func owner_bytes(owner: int) -> int:
	_lock.lock()
	var result := _owner_bytes(owner)
	_lock.unlock()
	return result

func _owner_bytes(owner: int) -> int:
	var n := 0
	for id: Array in _entries:
		if id[0] == owner: n += _entries[id].bytes
	return n

func reserve(bytes: int) -> void:
	_lock.lock()
	_reserved += bytes
	_trim()
	_lock.unlock()

func release(bytes: int) -> void:
	_lock.lock()
	_reserved = maxi(0, _reserved - bytes)
	_lock.unlock()

func snapshot() -> Dictionary:
	_lock.lock()
	var result := {limit_bytes = limit, retained_bytes = _bytes, reserved_bytes = _reserved,
		peak_retained_bytes = _peak, hits = _hits, misses = _misses, lookup_hit_rate = _hits / float(_hits + _misses) if _hits + _misses > 0 else null,
		evictions = _evictions, entries = _entries.size()}
	_lock.unlock()
	return result

func _trim() -> void:
	while _bytes > maxi(0, limit - _reserved) and not _entries.is_empty():
		_erase(_entries.keys()[0])
		_evictions += 1

func _erase(id: Array) -> void:
	if _entries.has(id):
		_bytes -= _entries[id].bytes
		_entries.erase(id)
