extends Logger
## Collects printed lines, warnings and errors while a bridge request runs.
## Loggers may be called from any thread, so the lines are guarded by a mutex.
## A line repeated while it is among the last REPEAT_WINDOW entries is counted
## on that entry instead of kept again (see add_counted()).

const KINDS := ["ERROR", "WARNING", "SCRIPT ERROR", "SHADER ERROR"]
## How far back a repeated line is looked for: warnings printed every frame
## often come as two or three taking turns.
const REPEAT_WINDOW := 8

## Backtrace file names of the bridge's own scripts (see set_bridge_scripts()).
static var _bridge_files := {}

## {"line", "count"} entries.
var _entries: Array[Dictionary] = []
var _mutex := Mutex.new()

## Names the bridge's own scripts, loaded detached, so errors are never blamed
## on them: an importer error raised while the bridge reimports a file is the
## importer's, not the line of the bridge that asked for the reimport.
static func set_bridge_scripts(scripts: Array) -> void:
	for script: Script in scripts:
		if script != null:
			_bridge_files["gdscript://%d.gd" % script.get_instance_id()] = true

static func _is_bridge_file(file: String) -> bool:
	return _bridge_files.has(file) or file.begins_with("res://addons/godot_bridge/")

func _log_message(message: String, error: bool) -> void:
	_add(("ERROR: " if error else "") + message.strip_edges(false, true))

func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, script_backtraces: Array) -> void:
	var kind: String = KINDS[error_type] if error_type < KINDS.size() else "ERROR"
	var message: String = rationale if not rationale.is_empty() else code
	# Errors that already name a script, such as parse errors, keep their own
	# line: the backtrace there only shows who compiled the script.
	var in_script := file.begins_with("res://") or file.begins_with("gdscript://") or file.begins_with("user://")
	if in_script:
		_add("%s: %s (%s, %s:%d)" % [kind, message, function, file, line])
		return
	# Other errors point at the engine's C++ source. The innermost script frame
	# that is not the bridge's own says which script line led to them. For
	# push_error() and push_warning() that line is the whole story; for an
	# engine method that failed (an importer, a loader) both places matter.
	var caller := ""
	for backtrace: ScriptBacktrace in script_backtraces:
		if backtrace == null:
			continue
		for i in backtrace.get_frame_count():
			if _is_bridge_file(backtrace.get_frame_file(i)):
				continue
			if file.ends_with("variant_utility.cpp"):
				function = backtrace.get_frame_function(i)
				file = backtrace.get_frame_file(i)
				line = backtrace.get_frame_line(i)
			else:
				caller = "; called from %s, %s:%d" % [backtrace.get_frame_function(i), backtrace.get_frame_file(i), backtrace.get_frame_line(i)]
			break
		break
	_add("%s: %s (%s, %s:%d%s)" % [kind, message, function, file, line, caller])

## Adds line count times to entries, or counts it on one of the last
## REPEAT_WINDOW entries with the same text, which then moves to the end as
## the most recent.
static func add_counted(entries: Array[Dictionary], line: String, count := 1) -> void:
	for i in range(entries.size() - 1, maxi(-1, entries.size() - 1 - REPEAT_WINDOW), -1):
		var entry: Dictionary = entries[i]
		if entry.line == line:
			entry.count += count
			entries.remove_at(i)
			entries.append(entry)
			return
	entries.append({"line": line, "count": count})

## An entry as one line, its count after it if it repeated.
static func format(entry: Dictionary) -> String:
	return entry.line if entry.count == 1 else "%s (%d times)" % [entry.line, entry.count]

## The lines collected so far, repeats counted, which are then cleared.
func take() -> PackedStringArray:
	var lines := PackedStringArray()
	for entry in take_entries():
		lines.append(format(entry))
	return lines

## The {"line", "count"} entries collected so far, which are then cleared.
func take_entries() -> Array[Dictionary]:
	_mutex.lock()
	var entries := _entries
	_entries = []
	_mutex.unlock()
	return entries

func _add(line: String) -> void:
	_mutex.lock()
	add_counted(_entries, line)
	_mutex.unlock()
