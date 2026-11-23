extends RefCounted
## Shared estimate of retained derivative data. Active jobs reserve space and evict retired data.
var limit := 192 * 1024 * 1024
var _reserved := 0
var _bytes := 0
var _next_token := 0
var _entries := {}        # int token -> {owner, key, value, bytes} (global LRU order)
var _owner_tokens := {}   # int owner -> Dictionary(key -> int token, per-owner LRU order)
var _owner_sizes := {}    # int owner -> int bytes
var _owner_labels := {}   # int owner -> String label for diagnostics
var _lock := Mutex.new()
var _hits := 0
var _misses := 0
var _evictions := 0
var _peak := 0

func register_owner(owner: int, label: String) -> void:
	_lock.lock()
	_owner_labels[owner] = label
	_lock.unlock()

func get_value(owner: int, key: Variant) -> Variant:
	_lock.lock()
	var owner_map: Variant = _owner_tokens.get(owner)
	var value: Variant = null
	if owner_map != null and (owner_map as Dictionary).has(key):
		var map: Dictionary = owner_map
		var token: int = map[key]
		var entry: Dictionary = _entries[token]
		_entries.erase(token)
		_entries[token] = entry
		map.erase(key)
		map[key] = token
		value = entry.value
		_hits += 1
	else: _misses += 1
	_lock.unlock()
	return value

func put(owner: int, key: Variant, value: Variant, bytes: int, owner_limit: int) -> bool:
	_lock.lock()
	_erase_key(owner, key)
	var accepted := bytes <= owner_limit and bytes <= maxi(0, limit - _reserved)
	if accepted:
		var owner_map: Dictionary = _owner_tokens.get(owner, {})
		if not _owner_tokens.has(owner):
			_owner_tokens[owner] = owner_map
		if _owner_bytes(owner) + bytes > owner_limit:
			for old_key: Variant in owner_map.keys():
				_erase_token(owner_map[old_key])
				if _owner_bytes(owner) + bytes <= owner_limit: break
		_next_token += 1
		var token := _next_token
		_entries[token] = {owner = owner, key = key, value = value, bytes = bytes}
		owner_map[key] = token
		_bytes += bytes
		_owner_sizes[owner] = _owner_bytes(owner) + bytes
		_trim()
		_peak = maxi(_peak, _bytes)
	_lock.unlock()
	return accepted

func erase(owner: int, key: Variant) -> void:
	_lock.lock()
	_erase_key(owner, key)
	_lock.unlock()

func clear_owner(owner: int) -> void:
	_lock.lock()
	var owner_map: Variant = _owner_tokens.get(owner)
	if owner_map != null:
		for token: int in (owner_map as Dictionary).values():
			_erase_token(token)
		_owner_tokens.erase(owner)
	_lock.unlock()

func owner_bytes(owner: int) -> int:
	_lock.lock()
	var result := _owner_bytes(owner)
	_lock.unlock()
	return result

func _owner_bytes(owner: int) -> int:
	return _owner_sizes.get(owner, 0)

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
	var by_label := {}
	for owner: int in _owner_sizes:
		var label: String = _owner_labels.get(owner, "owner_%d" % owner)
		by_label[label] = by_label.get(label, 0) + _owner_sizes[owner]
	var result := {limit_bytes = limit, retained_bytes = _bytes, reserved_bytes = _reserved,
		peak_retained_bytes = _peak, hits = _hits, misses = _misses, lookup_hit_rate = _hits / float(_hits + _misses) if _hits + _misses > 0 else null,
		evictions = _evictions, entries = _entries.size(), owner_bytes_by_label = by_label}
	_lock.unlock()
	return result

func _trim() -> void:
	var available := maxi(0, limit - _reserved)
	if _bytes <= available: return
	# Один снимок ключей на всё вытеснение, а не новый массив на каждый удалённый блок.
	for token: int in _entries.keys():
		_erase_token(token)
		_evictions += 1
		if _bytes <= available: break

func _erase_key(owner: int, key: Variant) -> void:
	var owner_map: Variant = _owner_tokens.get(owner)
	if owner_map != null and (owner_map as Dictionary).has(key):
		_erase_token((owner_map as Dictionary)[key])

func _erase_token(token: int) -> void:
	var entry: Variant = _entries.get(token)
	if entry == null: return
	var dict: Dictionary = entry
	var bytes: int = dict.bytes
	var owner: int = dict.owner
	_bytes -= bytes
	var left := _owner_bytes(owner) - bytes
	if left > 0: _owner_sizes[owner] = left
	else: _owner_sizes.erase(owner)
	var owner_map: Variant = _owner_tokens.get(owner)
	if owner_map != null:
		(owner_map as Dictionary).erase(dict.key)
		if (owner_map as Dictionary).is_empty():
			_owner_tokens.erase(owner)
	_entries.erase(token)
