extends RefCounted
## Recoverable replacement on Windows and Unix. Readers try primary, then backup.
## Writers serialize replacement, flush and verify before rotating the previous file.
## This is recovery after interruption, not a claim of power-loss atomicity/fsync.
static var _mutex := Mutex.new()

static func replace(path: String, bytes: PackedByteArray, preserve_backup := false) -> Error:
	_mutex.lock()
	var err := _replace(path, bytes, preserve_backup)
	_mutex.unlock()
	return err

static func _replace(path: String, bytes: PackedByteArray, preserve_backup: bool) -> Error:
	var err := DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if err != OK: return err
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null: return FileAccess.get_open_error()
	f.store_buffer(bytes)
	f.flush()
	err = f.get_error()
	f.close()
	if err != OK: return err
	if FileAccess.get_file_as_bytes(tmp) != bytes: return ERR_FILE_CORRUPT
	# A missing primary means an earlier rotation was interrupted: preserve its backup.
	if FileAccess.file_exists(path) and preserve_backup:
		err = DirAccess.remove_absolute(path) # known invalid primary; keep the readable backup
		if err != OK: return err
	elif FileAccess.file_exists(path):
		if FileAccess.file_exists(path + ".bak"):
			err = DirAccess.remove_absolute(path + ".bak")
			if err != OK: return err
		err = DirAccess.rename_absolute(path, path + ".bak")
		if err != OK: return err
	return DirAccess.rename_absolute(tmp, path)

static func remove(path: String) -> Error:
	var result := OK
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(path + suffix):
			var err := DirAccess.remove_absolute(path + suffix)
			if err != OK: result = err
	return result
