@tool
extends Node
## Listens on localhost for requests from the MCP server (mcp/server.py).
##
## Each editor writes its own connection file, named after its process ID, to
## res://.godot/godot_bridge/, holding the port and a random token. Nothing is
## shared between editors, so no other Godot process can replace this one's
## entry. Requests and replies are single JSON lines:
##   {"token": "...", "id": 1, "tool": "run", "args": {...}}
##   {"id": 1, "ok": true, "result": {...}}  or  {"id": 1, "ok": false, "error": "..."}

const CONNECTION_DIR := "res://.godot/godot_bridge"
const VERSION := "0.2.0"
## How long a sync waits for the editor's filesystem scan to finish.
const SYNC_TIMEOUT_MS := 10000
## How long game_play waits for the game's bridge helper to report in.
const GAME_START_TIMEOUT_MS := 30000
## game_play's user_data choices (see _prepare_user_data); folders of the real
## user:// left out of a copy.
const USER_DATA_MODES := ["copy", "empty", "real"]
const USER_DATA_SKIPPED := ["logs"]
## The variable Godot finds its data folder by, on this platform: user:// is a
## folder under it (see _data_home_for()).
var _data_home_variable: String = {"Windows": "APPDATA", "macOS": "HOME"}.get(OS.get_name(), "XDG_DATA_HOME")
## _data_home_variable as it was before _prepare_user_data changed it (null: unset).
var _saved_data_home: Variant = null
var _data_home_set := false
const GAME_REQUEST_TIMEOUT_MS := 30000
## How long game_play waits for its setup code.
const GAME_SETUP_TIMEOUT_MS := 60000
const GAME_INPUT_TIMEOUT_MS := 120000
## editor_run's default time limit; the MCP server waits a little longer, so
## code that awaits is answered with its progress rather than cut off.
const EDITOR_RUN_TIMEOUT_SECONDS := 90.0
## Finished editor runs kept for editor_result.
const EDITOR_RUNS_KEPT := 5
## The longest game_wait.
const GAME_WAIT_MAX_SECONDS := 600.0
## The most frames one game_suspend call steps, and how long one step may take.
const GAME_STEP_MAX_FRAMES := 600
const GAME_STEP_TIMEOUT_MS := 5000
const NO_GAME_ERROR := "No game with the bridge helper is running from this editor. Start one with game_play."
const EDITOR_LOG_LIMIT := 500
const EDITOR_LOG_LEVELS := ["all", "warnings", "errors"]
## Compiled editor_run code whose locations editor_log rewrites, the latest
## ones: its errors can come long after the run, from callbacks it left behind.
const EDITOR_RUN_SOURCES_KEPT := 50
## Screenshots kept in CONNECTION_DIR/screenshots; older ones are deleted.
const SCREENSHOTS_KEPT := 20
## How often open scenes are checked for changes on disk.
const SCENE_CHECK_INTERVAL_MS := 1000
## The editor's Debug menu item "Keep Debug Server Open". Background games are
## not started by the editor, so its debugger only accepts them while this is on.
const KEEP_DEBUG_SERVER_OPEN_ID := 9

var _tcp := TCPServer.new()
var _peers: Array[StreamPeerTCP] = []
## Peer -> bytes received but not yet ending in a newline.
var _buffers := {}
var _token := ""
var _connection_file := ""
## log_capture.gd and code_runner.gd, loaded detached by plugin.gd.
var log_capture_script: GDScript
var code_runner_script: GDScript
var texture_view_script: GDScript
## debugger_plugin.gd, the channel to games started from this editor.
var debugger
## plugin.gd, which replaces this server on reload_bridge (see _reload_bridge()).
var plugin
## Requests being answered; reload_bridge waits until it is the only one.
var _requests_in_flight := 0
## Scripts for the bridge that replaces this one once the reload request's reply is sent.
var _pending_reload := {}
## MD5s of the bridge's files as this bridge was loaded, file name -> hash
## (see _source_hashes()), so a reload can say which changed.
var _loaded_hashes := {}
## Set when a reloaded bridge took over: its state, a background game
## included, then lives on and must not be stopped here.
var _handed_over := false
var _next_game_request := 0
## editor_run id -> {"run": code_runner Run, "capture": logger, "started": msec,
## "outcome": reply once finished}. The running ones and the last few finished.
var _editor_runs := {}
var _next_editor_run := 0
## Collects the editor's output for editor_log; the last EDITOR_LOG_LIMIT
## entries, {"line", "count"}, are kept, with repeats counted across reads as
## LogCapture counts them within one (see its add_counted()).
var _editor_log
var _editor_log_lines: Array[Dictionary] = []
## Compiled editor_run code: {path, line_offset, label} (see code_runner.compile()).
var _editor_run_sources := []
## Open scene path -> modified time of its file when the editor last loaded or
## saved it, which tells changes made on disk apart from the editor's own saves.
var _scene_times := {}
## Open scene path -> {path of a scene it instances, directly or deeper ->
## that file's modified time when the open scene was loaded}: an open scene
## keeps the instanced scenes it was loaded with, so it is stale once one
## of them changes on disk, though its own file did not.
var _dependency_times := {}
var _next_scene_check := 0
## The gamescope process a background game runs in (see _play_background), or -1.
var _background_pid := -1
var _background_scene := ""
## The background game's stdout and stderr (non-blocking pipes), and the last
## lines read from them. Native crashes print their backtrace there; it never
## reaches the debugger. Kept after the game ends, until the next one starts.
var _background_pipes: Array[FileAccess] = []
var _background_partial := ["", ""]
## Per pipe: whether its last line was noise, so indented lines after it are too.
var _background_in_noise := [false, false]
var _background_output: PackedStringArray = []
const BACKGROUND_OUTPUT_KEPT := 200
## Lines from gamescope and its X server that say nothing about the game.
## The engine's start-up lines, left out of game_play's error logs.
const ENGINE_BANNER := ["Godot Engine v", "OpenGL API ", "Vulkan ", "WARNING: Project setting"]
## Lines from gamescope and its Vulkan layer in a background game's output,
## left out with the indented lines that continue them.
const BACKGROUND_NOISE := ["[gamescope", "[Gamescope WSI]", "ATTENTION: default value of option", "Tracing is enabled", "The XKEYBOARD keymap compiler", "> ", "Errors from xkbcomp", "(EE) failed to read Wayland events"]
var _terminal_colours := RegEx.create_from_string("\\x1b\\[[0-9;]*[A-Za-z]")
## Whether the bridge switched on "Keep Debug Server Open" and must switch it off.
var _opened_debug_server := false

func _ready() -> void:
	_loaded_hashes = _source_hashes()
	_editor_log = log_capture_script.new()
	OS.add_logger(_editor_log)
	note_open_scenes()
	var error := _tcp.listen(0, "127.0.0.1")
	if error != OK:
		push_error("Godot Bridge could not listen: %s" % error_string(error))
		return
	_token = Crypto.new().generate_random_bytes(16).hex_encode()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CONNECTION_DIR))
	_connection_file = ProjectSettings.globalize_path(CONNECTION_DIR.path_join("editor-%d.json" % OS.get_process_id()))
	var file := FileAccess.open(_connection_file, FileAccess.WRITE)
	file.store_string(JSON.stringify({
		"pid": OS.get_process_id(),
		"port": _tcp.get_local_port(),
		"token": _token,
		"project": ProjectSettings.globalize_path("res://"),
		"godot": Engine.get_version_info().string,
		"bridge": VERSION,
		"started": Time.get_unix_time_from_system(),
	}, "\t"))
	file.close()

func _exit_tree() -> void:
	if not _handed_over:
		_stop_background()
	if _editor_log != null:
		OS.remove_logger(_editor_log)
	_tcp.stop()
	for peer in _peers:
		peer.disconnect_from_host()
	# A server started before this one is freed (the plugin turned off and on
	# within a frame) has already written its own file under the same name.
	if not _connection_file.is_empty() and FileAccess.get_file_as_string(_connection_file).contains(_token):
		DirAccess.remove_absolute(_connection_file)

func _process(_delta: float) -> void:
	_collect_editor_log()
	_finish_editor_runs()
	_read_background_output()
	if Time.get_ticks_msec() >= _next_scene_check:
		_next_scene_check = Time.get_ticks_msec() + SCENE_CHECK_INTERVAL_MS
		_reload_changed_scenes()
		# A background game that quit or crashed by itself.
		if _background_pid >= 0 and not OS.is_process_running(_background_pid):
			_stop_background()
	while _tcp.is_connection_available():
		var peer := _tcp.take_connection()
		_peers.append(peer)
		_buffers[peer] = PackedByteArray()
	for peer: StreamPeerTCP in _peers.duplicate():
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_peers.erase(peer)
			_buffers.erase(peer)
			continue
		var available := peer.get_available_bytes()
		if available <= 0:
			continue
		var received: Array = peer.get_data(available)
		if received[0] != OK:
			continue
		var buffer: PackedByteArray = _buffers[peer]
		buffer.append_array(received[1])
		var newline := buffer.find(10)
		while newline >= 0:
			_handle(peer, buffer.slice(0, newline).get_string_from_utf8())
			buffer = buffer.slice(newline + 1)
			newline = buffer.find(10)
		_buffers[peer] = buffer

func _handle(peer: StreamPeerTCP, line: String) -> void:
	var request = JSON.parse_string(line)
	if not request is Dictionary:
		_reply(peer, {"id": null, "ok": false, "error": "Request is not a JSON object."})
		return
	if request.get("token", "") != _token:
		_reply(peer, {"id": request.get("id"), "ok": false, "error": "Wrong token: the editor may have restarted; reconnect."})
		return
	var args: Dictionary = request.get("args", {}) if request.get("args") is Dictionary else {}
	var reply := {"id": request.get("id")}
	_requests_in_flight += 1
	var outcome: Dictionary = await _call(String(request.get("tool", "")), args)
	_requests_in_flight -= 1
	# Every tool answers with something; nothing back means a script error
	# stopped it partway.
	if outcome.is_empty():
		outcome = {"error": "The bridge failed with a script error while handling %s; the editor's latest errors are in logs." % request.get("tool", ""),
			"logs": _editor_log_reply(3, false, "errors").lines}
	if outcome.has("error"):
		reply.ok = false
		reply.error = outcome.error
		if outcome.has("logs"):
			reply.logs = outcome.logs
	else:
		reply.ok = true
		reply.result = outcome
	_reply(peer, reply)
	# Replaced only now: the reply had to go out through this server's connection.
	if not _pending_reload.is_empty():
		plugin.swap_bridge.call_deferred(_pending_reload)
		_pending_reload = {}

func _reply(peer: StreamPeerTCP, reply: Dictionary) -> void:
	if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		peer.put_data((JSON.stringify(reply) + "\n").to_utf8_buffer())

func _call(tool: String, args: Dictionary) -> Dictionary:
	match tool:
		"status":
			return _status()
		"run":
			return _limit_reply(await _run(String(args.get("code", "")), bool(args.get("sync", true)), float(args.get("timeout", EDITOR_RUN_TIMEOUT_SECONDS))))
		"run_result":
			return _limit_reply(_run_result(int(args.get("run_id", 0))))
		"run_cancel":
			return _run_cancel(int(args.get("run_id", 0)))
		"sync":
			return await _sync()
		"import_settings":
			var import_paths := PackedStringArray(args.get("paths", []) if args.get("paths") is Array else [])
			if not String(args.get("path", "")).is_empty():
				import_paths.insert(0, String(args.path))
			return await _import_settings(import_paths, args.get("params", {}), args.get("subresources", {}))
		"game_play":
			return await _game_play(String(args.get("scene", "")), bool(args.get("restart", false)), bool(args.get("background", false)), String(args.get("user_data", "copy")), String(args.get("setup", "")), args.get("embed"))
		"game_stop":
			return await _game_stop()
		"game_run":
			return _limit_reply(await _game_request("run", {"code": String(args.get("code", ""))}, int(args.get("timeout", 60)) * 1000))
		"game_screenshot":
			var shot := {"path": _screenshot_path(), "max_size": int(args.get("max_size", 1280))}
			for key in ["node", "rect", "space", "size", "zoom", "grid"]:
				if args.has(key):
					shot[key] = args[key]
			return await _game_request("screenshot", shot)
		"game_input":
			var real_cursor: bool = args.get("real_cursor", _background_pid >= 0)
			return await _game_request("input", {"events": args.get("events", []), "real_cursor": real_cursor}, GAME_INPUT_TIMEOUT_MS)
		"game_wait":
			return await _game_wait(float(args.get("seconds", 30.0)))
		"game_suspend":
			return await _game_suspend(bool(args.get("suspended", true)), int(args.get("step_frames", 0)))
		"game_log":
			return await _game_request("log", {"lines": int(args.get("lines", 50)), "clear": bool(args.get("clear", false))})
		"diagnostics":
			return await _diagnostics(args.get("paths", []) if args.get("paths") is Array else [], bool(args.get("scenes", false)), bool(args.get("warnings", true)))
		"editor_log":
			return _editor_log_reply(int(args.get("lines", 50)), bool(args.get("clear", false)), String(args.get("level", "all")))
		"texture_view":
			return _texture_view(args)
		"tile_info":
			return _tile_info(String(args.get("scene", "")), args.get("position"), String(args.get("layer", "")), args.get("cells"))
		"scene_screenshot":
			var project_size := Vector2i(ProjectSettings.get_setting("display/window/size/viewport_width", 1280), ProjectSettings.get_setting("display/window/size/viewport_height", 720))
			return await _scene_screenshot(String(args.get("scene", "")), Vector2i(int(args.get("width", project_size.x)), int(args.get("height", project_size.y))), int(args.get("max_size", 1280)), args.get("view"))
		"animation_frames":
			return await _animation_frames(args)
		"reload":
			return _reload_bridge()
		"run_tests":
			return await _run_tests(args)
	return {"error": "Unknown tool: %s" % tool}

# --- Tools -------------------------------------------------------------------

## The longest a reply of code run by the bridge may get: a result (or output,
## or logs) longer than this, in JSON characters, is saved to a file instead
## and replaced by a summary of its shape, so it never overflows the agent's
## reply limit. Output and log lists keep their last REPLY_LINES_MAX lines.
const REPLY_CHARS_MAX := 40000
const REPLY_LINES_MAX := 300
const RESULTS_KEPT := 10
## How much of a too-large value its summary shows.
const SHAPE_KEYS_SHOWN := 15
const SHAPE_DEPTH := 2

## Keeps a run's reply (editor_run, editor_result, game_run, game_play's
## setup) within REPLY_CHARS_MAX; see there.
func _limit_reply(outcome: Dictionary) -> Dictionary:
	var notes := PackedStringArray()
	for key in ["output", "logs", "output_so_far", "logs_so_far"]:
		var value: Variant = outcome.get(key)
		if (value is Array or value is PackedStringArray) and value.size() > REPLY_LINES_MAX:
			notes.append("%s had %d lines; the last %d are shown." % [key, value.size(), REPLY_LINES_MAX])
			outcome[key] = Array(value).slice(value.size() - REPLY_LINES_MAX)
	for key in ["result", "output", "logs", "output_so_far", "logs_so_far"]:
		if not outcome.has(key):
			continue
		var text := JSON.stringify(outcome[key])
		if text.length() <= REPLY_CHARS_MAX:
			continue
		var path := _result_path(key)
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_string(JSON.stringify(outcome[key], "\t"))
		file.close()
		notes.append("%s was %d characters, too long for a reply: it is saved whole to %s, and %s shows its shape (sizes in characters). Return a smaller part, or read the file." % [key, text.length(), path, key])
		outcome[key] = _shape(outcome[key], 0)
	if not notes.is_empty():
		outcome.too_large = notes
	return outcome

func _result_path(label: String) -> String:
	var folder := ProjectSettings.globalize_path(CONNECTION_DIR.path_join("results"))
	DirAccess.make_dir_recursive_absolute(folder)
	var files := Array(DirAccess.get_files_at(folder)).filter(func(file: String) -> bool: return file.ends_with(".json"))
	files.sort()
	while files.size() >= RESULTS_KEPT:
		DirAccess.remove_absolute(folder.path_join(files.pop_front()))
	return folder.path_join("%d-%s.json" % [int(Time.get_unix_time_from_system() * 1000), label])

## A short description of a large value, SHAPE_DEPTH levels deep:
## dictionaries by their largest keys, arrays by their first items (a sample)
## and largest ones (outliers), long strings by their start.
func _shape(value: Variant, depth: int) -> Variant:
	var size := JSON.stringify(value).length()
	if value is Dictionary or value is Array:
		var label := "%s, %d %s, %d chars" % ["dictionary" if value is Dictionary else "array", value.size(), "keys" if value is Dictionary else "items", size]
		if depth >= SHAPE_DEPTH:
			return label
		var keys: Array = value.keys() if value is Dictionary else range(value.size())
		var sized := keys.map(func(key: Variant) -> Array: return [key, JSON.stringify(value[key]).length()])
		sized.sort_custom(func(a: Array, b: Array) -> bool: return a[1] > b[1])
		var picked: Array = sized.slice(0, SHAPE_KEYS_SHOWN).map(func(entry: Array) -> Variant: return entry[0])
		var how := "the %d largest" % SHAPE_KEYS_SHOWN
		if value is Array:
			picked = range(mini(3, value.size()))
			for entry in sized.slice(0, 3):
				if not entry[0] in picked:
					picked.append(entry[0])
			how = "the first and the largest items"
		var shown := {"(this)": label + ("; %s:" % how if picked.size() < keys.size() else "")}
		for key in picked:
			shown[str(key) if value is Dictionary else "[%d]" % key] = _shape(value[key], depth + 1)
		return shown
	if value is String and value.length() > 200:
		return "%s... (%d chars)" % [value.left(200), value.length()]
	return value

## reload_bridge: compiles the bridge's scripts from disk and, when they all
## compile, replaces this server and the debugger plugin with new ones once this
## reply is sent (plugin.gd swap_bridge()). Waits for nothing: it refuses while
## another request or an editor_run is still going, since replacing the code a
## coroutine is paused in would end it.
func _reload_bridge() -> Dictionary:
	if plugin == null:
		return {"error": "This bridge was not started by plugin.gd, so it cannot reload itself."}
	_finish_editor_runs()
	var running := _running_editor_runs()
	if not running.is_empty():
		return {"error": "editor_run %d is still running. Wait for it with editor_result or stop it with editor_cancel, then reload." % running[0].run_id}
	if _requests_in_flight > 1:
		return {"error": "Another request is still being answered (game_wait, game_play...). Reload once it has finished."}
	var loaded: Dictionary = plugin.load_bridge_scripts()
	if loaded.has("error"):
		return loaded
	_pending_reload = loaded.scripts
	var now := _source_hashes()
	var changed := func(file_name: String) -> bool: return now.get(file_name) != _loaded_hashes.get(file_name)
	var reply := {"reloading": true, "changed": plugin.BRIDGE_SCRIPTS.values().filter(changed)}
	var notes := PackedStringArray(["The new bridge answers from the next call." if not reply.changed.is_empty() else "No bridge script changed since the bridge was loaded; it is reloaded anyway."])
	var game_changed: Array = plugin.GAME_SCRIPTS.filter(changed)
	if not game_changed.is_empty():
		reply.next_game_play = game_changed
		notes.append("%s compiled, and %s." % [", ".join(game_changed), "a running game keeps the old version until it is restarted" if _game_running() else "loads with the next game_play"])
	if changed.call("plugin.gd"):
		notes.append("plugin.gd changed too: it only reloads when the plugin is turned off and on.")
	reply.note = " ".join(notes)
	return reply

## Hashes of the bridge's files, to tell which changed since the bridge was
## loaded (see _reload_bridge()).
func _source_hashes() -> Dictionary:
	var hashes := {}
	if plugin == null:
		return hashes
	for file_name: String in plugin.BRIDGE_SCRIPTS.values() + plugin.GAME_SCRIPTS + ["plugin.gd"]:
		hashes[file_name] = FileAccess.get_md5(plugin.SCRIPTS_DIR + file_name)
	return hashes

## What the bridge that replaces this one takes over (see plugin.gd swap_bridge()).
## A background game is handed over rather than stopped.
func export_state() -> Dictionary:
	_collect_editor_log()
	_handed_over = true
	return {
		"saved_data_home": _saved_data_home,
		"data_home_set": _data_home_set,
		"next_game_request": _next_game_request,
		"editor_runs": _editor_runs,
		"next_editor_run": _next_editor_run,
		"editor_log_lines": _editor_log_lines,
		"editor_run_sources": _editor_run_sources,
		"scene_times": _scene_times,
		"dependency_times": _dependency_times,
		"background_pid": _background_pid,
		"background_scene": _background_scene,
		"background_pipes": _background_pipes,
		"background_partial": _background_partial,
		"background_output": _background_output,
		"opened_debug_server": _opened_debug_server,
		"loaded_hashes": _loaded_hashes,
	}

func import_state(state: Dictionary) -> void:
	# A reload loads every file but plugin.gd, which stays as the old bridge
	# had it until the plugin is turned off and on.
	var loaded_before: Dictionary = state.get("loaded_hashes", {})
	if loaded_before.has("plugin.gd"):
		_loaded_hashes["plugin.gd"] = loaded_before["plugin.gd"]
	_saved_data_home = state.saved_data_home
	_data_home_set = state.data_home_set
	_next_game_request = state.next_game_request
	_editor_runs = state.editor_runs
	_next_editor_run = state.next_editor_run
	# Lines logged since this server started come after the old ones.
	_collect_editor_log()
	var newer := _editor_log_lines
	_editor_log_lines = []
	# A bridge from before repeats were counted hands over plain lines.
	for entry in state.editor_log_lines:
		if entry is Dictionary:
			_editor_log_lines.append(entry)
		else:
			log_capture_script.add_counted(_editor_log_lines, String(entry))
	for entry in newer:
		_editor_log_lines.append(entry)
	if _editor_log_lines.size() > EDITOR_LOG_LIMIT:
		_editor_log_lines = _editor_log_lines.slice(_editor_log_lines.size() - EDITOR_LOG_LIMIT)
	_editor_run_sources = state.get("editor_run_sources", [])
	_scene_times = state.scene_times
	_dependency_times = state.get("dependency_times", {})
	_background_pid = state.background_pid
	_background_scene = state.background_scene
	_background_pipes.assign(state.background_pipes)
	_background_partial = state.background_partial
	_background_output = state.background_output
	_opened_debug_server = state.opened_debug_server

func _status() -> Dictionary:
	var edited := EditorInterface.get_edited_scene_root()
	return {
		"godot": Engine.get_version_info().string,
		"bridge": VERSION,
		"project": ProjectSettings.globalize_path("res://"),
		"pid": OS.get_process_id(),
		"edited_scene": edited.scene_file_path if edited != null else "",
		"open_scenes": Array(EditorInterface.get_open_scenes()),
		"unsaved_scenes": Array(EditorInterface.get_unsaved_scenes()),
		"playing_scene": _playing_scene(),
		"playing_in_background": _background_pid >= 0,
		"editor_runs": _running_editor_runs(),
		"game_paused": debugger.game_break() if debugger != null and debugger.is_game_paused() else false,
	}

## Runs GDScript in the editor. With sync, files changed on disk are reloaded
## first, so the code sees the latest scripts and scenes. Code that awaits and
## outlasts timeout is answered with its progress and keeps running, to be
## collected with editor_result or stopped with editor_cancel. Every run is
## kept (see EDITOR_RUNS_KEPT), so even blocking code that outlasted the MCP
## server's wait can still be collected afterwards.
func _run(code: String, sync: bool, timeout: float) -> Dictionary:
	if sync:
		await _sync()
	var capture = log_capture_script.new()
	OS.add_logger(capture)
	var compiled: Dictionary = code_runner_script.compile(code)
	if compiled.has("error"):
		OS.remove_logger(capture)
		_note_editor_run_source(compiled, "editor_run code")
		return {"error": compiled.error, "logs": code_runner_script.code_lines(capture.take(), compiled)}
	_next_editor_run += 1
	var id := _next_editor_run
	_note_editor_run_source(compiled, "editor_run %d code" % id)
	# The entry is complete before the code starts: the code can process frames
	# (reimport_files() does) before its first await, and _process then looks at it.
	var entry := {"run": code_runner_script.prepare(compiled.script), "capture": capture, "compiled": compiled, "started": Time.get_ticks_msec(), "logs": []}
	entry.run.context.bridge = self
	_editor_runs[id] = entry
	code_runner_script.drive(entry.run)
	while not entry.run.done and not entry.run.stopped and Time.get_ticks_msec() - entry.started < timeout * 1000.0:
		await get_tree().process_frame
	_finish_editor_runs()
	if entry.has("outcome"):
		return _run_reply(id)
	return _run_progress(id, "The code is still running after %d s. Collect its result with editor_result (run_id %d) or stop it with editor_cancel." % [int(timeout), id])

func _note_editor_run_source(compiled: Dictionary, label: String) -> void:
	_editor_run_sources.append({"path": compiled.path, "line_offset": compiled.line_offset, "label": label})
	if _editor_run_sources.size() > EDITOR_RUN_SOURCES_KEPT:
		_editor_run_sources.pop_front()

## line with locations in compiled editor_run code rewritten to that code's
## own lines, as "editor_run 12 code:3" (run 12, line 3 of its code).
func _editor_run_locations(line: String) -> String:
	if not line.contains("gdscript://"):
		return line
	for source: Dictionary in _editor_run_sources:
		if line.contains(source.path + ":"):
			line = code_runner_script.code_locations(PackedStringArray([line]), source, source.label)[0]
	return line

## Finishes runs that have returned (or were cancelled): stops their log
## capture and keeps their reply. Drops the oldest finished runs beyond EDITOR_RUNS_KEPT.
func _finish_editor_runs() -> void:
	var finished := []
	for id in _editor_runs:
		var entry: Dictionary = _editor_runs[id]
		if entry.has("outcome"):
			finished.append(id)
			continue
		if not entry.run.done and not entry.run.stopped:
			continue
		# Scenes ctx.pose() loaded are only for the run that asked.
		for viewport: Node in entry.run.context.posed_viewports:
			if is_instance_valid(viewport):
				viewport.queue_free()
		OS.remove_logger(entry.capture)
		entry.logs.append_array(Array(code_runner_script.code_lines(entry.capture.take(), entry.compiled)))
		var outcome: Dictionary = code_runner_script.outcome(entry.run) if entry.run.done else {"output": entry.run.context.output, "cancelled": true}
		outcome.logs = entry.logs
		outcome.seconds = snappedf((Time.get_ticks_msec() - entry.started) / 1000.0, 0.01)
		entry.outcome = outcome
		finished.append(id)
	finished.sort()
	while finished.size() > EDITOR_RUNS_KEPT:
		_editor_runs.erase(finished.pop_front())

## A finished run's reply, with its run_id, which editor_log names it by (see
## _editor_run_locations()), and its time only when it took long enough to matter.
func _run_reply(id: int) -> Dictionary:
	var outcome: Dictionary = _editor_runs[id].outcome.duplicate()
	outcome.run_id = id
	if outcome.seconds < 1.0:
		outcome.erase("seconds")
	return code_runner_script.trimmed(outcome)

func _run_progress(id: int, note: String) -> Dictionary:
	var entry: Dictionary = _editor_runs[id]
	entry.logs.append_array(Array(code_runner_script.code_lines(entry.capture.take(), entry.compiled)))
	return {
		"running": true,
		"run_id": id,
		"seconds": snappedf((Time.get_ticks_msec() - entry.started) / 1000.0, 0.01),
		"output_so_far": entry.run.context.output,
		"logs_so_far": entry.logs,
		"note": note,
	}

## The given run, or with id 0 the most recent one.
func _find_run(id: int) -> int:
	if id == 0 and not _editor_runs.is_empty():
		id = _editor_runs.keys().max()
	return id if _editor_runs.has(id) else -1

## editor_result: a finished run's reply, or a running one's progress.
func _run_result(id: int) -> Dictionary:
	_finish_editor_runs()
	id = _find_run(id)
	if id < 0:
		return {"error": "No such editor_run is kept; only the last %d finished runs are." % EDITOR_RUNS_KEPT}
	if _editor_runs[id].has("outcome"):
		return _run_reply(id)
	return _run_progress(id, "Still running. Ask again with editor_result, or stop it with editor_cancel.")

## editor_cancel: stops a running run at its next await (see code_runner Run.cancel).
func _run_cancel(id: int) -> Dictionary:
	_finish_editor_runs()
	id = _find_run(id)
	if id < 0:
		return {"error": "No such editor_run is kept."}
	var entry: Dictionary = _editor_runs[id]
	if entry.has("outcome"):
		return {"error": "editor_run %d has already finished; editor_result returns its result." % id}
	entry.run.cancel()
	_finish_editor_runs()
	if entry.has("outcome"):
		return _run_reply(id)
	return _run_progress(id, "Asked to stop: its code defines its own class, so it stops only where it checks ctx.cancelled.")

func _running_editor_runs() -> Array:
	var running := []
	for id in _editor_runs:
		if not _editor_runs[id].has("outcome"):
			running.append({"run_id": id, "seconds": snappedf((Time.get_ticks_msec() - _editor_runs[id].started) / 1000.0, 0.1)})
	return running

## Picks up files changed outside the editor: open scenes changed on disk are
## reloaded (see _reload_changed_scenes), scripts open in the script editor are
## compared with the disk as when the editor window regains focus, and a
## sources scan reloads other changed resources and the class list.
##
## The scan is scan_sources(), the editor's own focus-in check, which compares
## file times with the editor's in-memory file list. A full scan() instead trusts
## the times in .godot/editor/filesystem_cache10, which another Godot process
## (such as a headless --import) rewrites with the new times: files it
## lists as unchanged are then neither reloaded nor have their class_name
## registered, so scripts extending them fail to compile until a later scan.
func _sync() -> Dictionary:
	var scenes := _reload_changed_scenes()
	var script_editor := EditorInterface.get_script_editor()
	if script_editor != null:
		script_editor.notification(NOTIFICATION_APPLICATION_FOCUS_IN)
	var filesystem := EditorInterface.get_resource_filesystem()
	# A scan already running would only queue this one until much later.
	while filesystem.is_scanning():
		await get_tree().process_frame
	# The scan runs on a thread and may start frames later, so wait for its
	# sources_changed signal (with a time limit) rather than is_scanning().
	# Unlike filesystem_changed, it is sent even when nothing changed.
	var finished := [false]
	var on_finished := func(_changed: bool) -> void: finished[0] = true
	filesystem.sources_changed.connect(on_finished, CONNECT_ONE_SHOT)
	filesystem.scan_sources()
	var started := Time.get_ticks_msec()
	while not finished[0] and Time.get_ticks_msec() - started < SYNC_TIMEOUT_MS:
		await get_tree().process_frame
	if filesystem.sources_changed.is_connected(on_finished):
		filesystem.sources_changed.disconnect(on_finished)
	while filesystem.is_scanning() or filesystem.is_importing():
		await get_tree().process_frame
	scenes.synced = true
	return scenes

# --- Tests -------------------------------------------------------------------

## Where run_tests looks for test scripts when none are given.
const TEST_DIRS := ["res://tests", "res://test"]
const TEST_TIMEOUT_SECONDS := 120.0
## Output lines kept per test script, the last ones.
const TEST_OUTPUT_KEPT := 40
## How many test scripts run at once: by default a third of the CPU cores, up
## to TEST_JOBS_DEFAULT_MAX, and at most TEST_JOBS_MAX. Tests with tight time
## limits of their own can fail when too many share the CPU.
const TEST_JOBS_DEFAULT_MAX := 4
const TEST_JOBS_MAX := 16
## Engine messages printed as a script quits (leaked objects and resources),
## reported apart from its errors: they rarely mean a test is wrong.
const TEST_EXIT_NOISE := [" at exit", "was leaked"]
var _extends_regex := RegEx.create_from_string("(?m)^extends\\s+(?:\"([^\"]+)\"|'([^']+)'|([A-Za-z_][\\w.]*))")
var _initialize_regex := RegEx.create_from_string("(?m)^func\\s+_initialize\\s*\\(")

## run_tests: syncs first, so headless runs see new class_names (they read the
## class cache the editor's scan writes), then runs each test script in its own
## headless Godot, several at once (jobs) without blocking the editor. A script
## passes when its process exits with code 0, as quit(0) does.
func _run_tests(args: Dictionary) -> Dictionary:
	await _sync()
	var scripts := PackedStringArray()
	var given: Variant = args.get("scripts")
	if given is Array and not given.is_empty():
		for item in given:
			var path := _res_path(String(item))
			if DirAccess.dir_exists_absolute(path):
				scripts.append_array(_without_test_bases(_find_test_scripts(path)))
			elif FileAccess.file_exists(path):
				scripts.append(path)
			else:
				return {"error": "No script or folder at %s." % path}
	else:
		for folder in TEST_DIRS:
			if DirAccess.dir_exists_absolute(folder):
				scripts.append_array(_find_test_scripts(folder))
		scripts = _without_test_bases(scripts)
	if scripts.is_empty():
		return {"error": "No test scripts found. Pass scripts: scripts that extend SceneTree or MainLoop (or folders of them), or a test framework's command-line runner with its options in args. Without scripts, %s are searched." % " and ".join(TEST_DIRS)}
	var extra := PackedStringArray()
	if args.get("args") is Array:
		for item in args.args:
			extra.append(String(item))
	var timeout := maxf(1.0, float(args.get("timeout", TEST_TIMEOUT_SECONDS)))
	# Empty by default, unlike game_play: a test's outcome should not depend on
	# whatever saves and settings the person running it has.
	var user_data := String(args.get("user_data", "empty"))
	if not user_data in USER_DATA_MODES:
		return {"error": "user_data is one of %s." % ", ".join(USER_DATA_MODES)}
	var details := String(args.get("details", "failures"))
	if not details in ["failures", "all"]:
		return {"error": "details is failures or all."}
	var jobs := clampi(int(args.get("jobs", clampi(OS.get_processor_count() / 3, 1, TEST_JOBS_DEFAULT_MAX))), 1, TEST_JOBS_MAX)
	var started := Time.get_ticks_msec()
	var results := []
	results.resize(scripts.size())
	# Each worker runs one script at a time, taking the next one not yet started.
	var state := {"next": 0, "workers": mini(jobs, scripts.size())}
	var worker := func(slot: int) -> void:
		while state.next < scripts.size():
			var index: int = state.next
			state.next += 1
			# A fresh folder for every script, so one test's saves cannot change another's.
			var data_home: Variant = null
			if user_data != "real":
				data_home = OS.get_temp_dir().path_join("godot_bridge_test_data").path_join(str(slot))
				_make_user_data(user_data, data_home)
			results[index] = await _run_test_script(scripts[index], extra, timeout, data_home)
		state.workers -= 1
	for slot in state.workers:
		worker.call(slot)
	while state.workers > 0:
		await get_tree().process_frame
	var failed := results.filter(func(result: Dictionary) -> bool: return not result.passed)
	var reply := {"passed": scripts.size() - failed.size(), "failed": failed.size(), "seconds": snappedf((Time.get_ticks_msec() - started) / 1000.0, 0.1), "user_data": user_data}
	if details == "all":
		reply.results = results
		return reply
	if not failed.is_empty():
		reply.failures = failed
	# Passing scripts that printed errors or warnings, without their output.
	var noisy := []
	for result: Dictionary in results:
		if result.passed and (result.has("errors") or result.has("warnings") or result.has("exit_warnings")):
			var entry := {"script": result.script}
			for key in ["errors", "warnings", "exit_warnings"]:
				if result.has(key):
					entry[key] = result[key]
			noisy.append(entry)
	if not noisy.is_empty():
		reply.noisy = noisy
	return reply

## The scripts under folder that extend SceneTree or MainLoop, directly or
## through other scripts, so `-s` runs them.
func _find_test_scripts(folder: String) -> PackedStringArray:
	var found := PackedStringArray()
	var global_classes := _global_class_paths()
	for file in DirAccess.get_files_at(folder):
		var path := folder.path_join(file)
		if file.get_extension() == "gd" and _extends_main_loop(path, global_classes):
			found.append(path)
	for sub in DirAccess.get_directories_at(folder):
		found.append_array(_find_test_scripts(folder.path_join(sub)))
	return found

## class_name -> script path, for the project's named scripts.
func _global_class_paths() -> Dictionary:
	var paths := {}
	for entry in ProjectSettings.get_global_class_list():
		paths[String(entry["class"])] = String(entry.path)
	return paths

## Whether the script at path extends SceneTree or MainLoop, following its
## extends chain through script paths and class_names.
func _extends_main_loop(path: String, global_classes: Dictionary, depth := 0) -> bool:
	var parent := _extended_script(path, global_classes)
	if parent in ["SceneTree", "MainLoop"]:
		return true
	return depth < 16 and parent.ends_with(".gd") and _extends_main_loop(parent, global_classes, depth + 1)

## What the script at path extends: a script's path, a native class's name, or "".
func _extended_script(path: String, global_classes: Dictionary) -> String:
	var found := _extends_regex.search(FileAccess.get_file_as_string(path))
	if found == null:
		return ""
	var given := found.get_string(1) + found.get_string(2)
	if not given.is_empty():
		return given if given.begins_with("res://") else path.get_base_dir().path_join(given).simplify_path()
	var name := found.get_string(3).get_slice(".", 0)
	return global_classes.get(name, name)

## scripts without the bases other test scripts extend (helpers such as a
## test_base.gd that only sets up), unless they define _initialize, as a test
## of their own does.
func _without_test_bases(scripts: PackedStringArray) -> PackedStringArray:
	var global_classes := _global_class_paths()
	var bases := {}
	for script in scripts:
		bases[_extended_script(script, global_classes)] = true
	var kept := PackedStringArray()
	for script in scripts:
		if not bases.has(script) or _initialize_regex.search(FileAccess.get_file_as_string(script)) != null:
			kept.append(script)
	return kept

## Runs one script with `godot --headless -s`, reading its output as it comes
## so the editor keeps running. Killed after timeout seconds. With data_home,
## the script runs with _data_home_variable set to it (see _make_user_data()).
func _run_test_script(script: String, extra: PackedStringArray, timeout: float, data_home: Variant = null) -> Dictionary:
	var arguments := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"), "-s", script])
	arguments.append_array(extra)
	# The process inherits the editor's environment as it starts, so the
	# variable is changed only for that moment (a game being started may have it set too).
	var saved: Variant = OS.get_environment(_data_home_variable) if OS.has_environment(_data_home_variable) else null
	if data_home != null:
		OS.set_environment(_data_home_variable, data_home)
	var process := OS.execute_with_pipe(OS.get_executable_path(), arguments, false)
	if data_home != null:
		if saved == null:
			OS.unset_environment(_data_home_variable)
		else:
			OS.set_environment(_data_home_variable, saved)
	if process.is_empty():
		return {"script": script, "passed": false, "error": "Could not start a headless Godot."}
	var pipes: Array[FileAccess] = [process.stdio, process.stderr]
	var partial := ["", ""]
	var lines := PackedStringArray()
	var started := Time.get_ticks_msec()
	var timed_out := false
	while OS.is_process_running(process.pid):
		_read_test_pipes(pipes, partial, lines)
		if Time.get_ticks_msec() - started > timeout * 1000.0:
			OS.kill(process.pid)
			timed_out = true
			break
		await get_tree().process_frame
	_read_test_pipes(pipes, partial, lines)
	for rest in partial:
		if not rest.strip_edges().is_empty():
			lines.append(rest)
	for pipe in pipes:
		pipe.close()
	var exit_code := OS.get_process_exit_code(process.pid)
	# Errors and warnings with the "at:" line that says where, as one line each.
	var errors := PackedStringArray()
	var warnings := PackedStringArray()
	var exit_warnings := PackedStringArray()
	for i in lines.size():
		var line := lines[i].strip_edges()
		var is_error := line.begins_with("SCRIPT ERROR:") or line.begins_with("ERROR:") or line.begins_with("USER ERROR:")
		if not is_error and not line.begins_with("WARNING:") and not line.begins_with("USER WARNING:"):
			continue
		var at := lines[i + 1].strip_edges() if i + 1 < lines.size() else ""
		line += " (%s)" % at.trim_prefix("at: ") if at.begins_with("at:") else ""
		if TEST_EXIT_NOISE.any(func(noise: String) -> bool: return line.contains(noise)):
			exit_warnings.append(line)
		elif is_error:
			errors.append(line)
		else:
			warnings.append(line)
	var result := {
		"script": script,
		"passed": not timed_out and exit_code == 0,
		# A stopped script has no exit code of its own.
		"exit_code": null if timed_out else exit_code,
		"seconds": snappedf((Time.get_ticks_msec() - started) / 1000.0, 0.01),
		"errors": errors,
		"warnings": warnings,
		"output": lines.slice(maxi(0, lines.size() - TEST_OUTPUT_KEPT)),
	}
	if not exit_warnings.is_empty():
		result.exit_warnings = exit_warnings
	if timed_out:
		result.note = "Stopped after %d s. A script must call quit() when done, or it runs forever; a script error before quit() leaves it running too. Pass a longer timeout if it needs more." % int(timeout)
	return code_runner_script.trimmed(result, ["errors", "warnings", "output"])

func _read_test_pipes(pipes: Array[FileAccess], partial: Array, lines: PackedStringArray) -> void:
	for i in pipes.size():
		var chunk := pipes[i].get_buffer(65536)
		while not chunk.is_empty():
			var split: PackedStringArray = (partial[i] + chunk.get_string_from_utf8()).split("\n")
			partial[i] = split[-1]
			for line in split.slice(0, split.size() - 1):
				line = _terminal_colours.sub(line, "", true).strip_edges(false, true)
				if not line.strip_edges().is_empty() and not ENGINE_BANNER.any(func(banner: String) -> bool: return line.begins_with(banner)):
					lines.append(line)
			chunk = pipes[i].get_buffer(65536)

## Records the file times of open scenes not seen before (just opened), and
## of the scenes they instance.
func note_open_scenes() -> void:
	for path in EditorInterface.get_open_scenes():
		if not _scene_times.has(path):
			_scene_times[path] = FileAccess.get_modified_time(path)
		# Also for scenes handed over by a bridge from before these were kept.
		if not _dependency_times.has(path):
			_dependency_times[path] = _scene_dependency_times(path)

## The editor saved a scene, so its file's new time is the editor's own. The
## editor updates the instances of a scene it saved in the other open scenes
## itself, so those are not stale either.
func note_scene_saved(path: String) -> void:
	var time := FileAccess.get_modified_time(path)
	if _scene_times.has(path) or EditorInterface.get_open_scenes().has(path):
		_scene_times[path] = time
		_dependency_times[path] = _scene_dependency_times(path)
	for times: Dictionary in _dependency_times.values():
		if times.has(path):
			times[path] = time

func forget_scene(path: String) -> void:
	_scene_times.erase(path)
	_dependency_times.erase(path)

## The scenes path instances, directly or through other instanced scenes,
## with their files' modified times.
func _scene_dependency_times(path: String, times := {}) -> Dictionary:
	for dependency in ResourceLoader.get_dependencies(path):
		# Entries look like "uid://...::::res://house.tscn" or a plain path.
		var dependency_path := dependency.get_slice("::", dependency.get_slice_count("::") - 1)
		if dependency_path.begins_with("uid://"):
			dependency_path = ResourceUID.get_id_path(ResourceUID.text_to_id(dependency_path))
		if not dependency_path.get_extension() in ["tscn", "scn"] or times.has(dependency_path):
			continue
		times[dependency_path] = FileAccess.get_modified_time(dependency_path)
		_scene_dependency_times(dependency_path, times)
	return times

## Reloads open scenes whose files changed on disk since the editor loaded or
## saved them, before the editor notices them itself (on focus, on play) and
## asks with its "Files have been modified outside Godot" dialog. Open scenes
## that instance a scene changed on disk are reloaded too: the editor keeps
## their old instances, and saving would write those back. A scene with
## unsaved edits in the editor is left alone, since both copies changed.
func _reload_changed_scenes() -> Dictionary:
	note_open_scenes()
	var reloaded := []
	var conflicts := []
	var stale := []
	var unsaved := EditorInterface.get_unsaved_scenes()
	for path in EditorInterface.get_open_scenes():
		var on_disk := FileAccess.get_modified_time(path)
		var changed := on_disk > int(_scene_times.get(path, on_disk))
		var changed_instances := []
		var recorded: Dictionary = _dependency_times.get(path, {})
		for dependency in recorded:
			if FileAccess.get_modified_time(dependency) > int(recorded[dependency]):
				changed_instances.append(dependency)
		if not changed and changed_instances.is_empty():
			continue
		if unsaved.has(path):
			if changed:
				conflicts.append(path)
			else:
				stale.append({"scene": path, "changed_instances": changed_instances})
			continue
		EditorInterface.reload_scene_from_path(path)
		_scene_times[path] = on_disk
		_dependency_times[path] = _scene_dependency_times(path)
		reloaded.append(path)
	var outcome := {}
	if not reloaded.is_empty():
		outcome.reloaded_scenes = reloaded
	var notes := PackedStringArray()
	if not conflicts.is_empty():
		outcome.unsaved_conflicts = conflicts
		notes.append("unsaved_conflicts changed on disk but also have unsaved edits in the editor, so they were not reloaded; the editor will ask which copy to keep.")
	if not stale.is_empty():
		outcome.stale_unsaved_scenes = stale
		notes.append("stale_unsaved_scenes instance scenes that changed on disk, but have unsaved edits in the editor, so they were not reloaded and still hold the old instances: saving them would write those back. Reload them (EditorInterface.reload_scene_from_path) to drop the unsaved edits, or redo the edits on disk.")
	if not notes.is_empty():
		outcome.note = " ".join(notes)
	return outcome

## Reads one imported asset's import settings, or changes them on every file
## in paths (params: name -> value; subresources: "category/name" -> {setting
## -> value}, see _change_subresources()) and reimports those that changed in
## one go. Nothing is saved unless every file takes every change.
func _import_settings(paths: PackedStringArray, params, subresources = {}) -> Dictionary:
	var files := _import_settings_files(paths)
	if files.has("error"):
		return files
	var changing: bool = (params is Dictionary and not params.is_empty()) or (subresources is Dictionary and not subresources.is_empty())
	if not changing:
		if files.paths.size() != 1:
			return {"error": "Reading settings takes one file, but %d match; pass params or subresources to change them all." % files.paths.size()}
		return _import_settings_reply(files.paths[0], files.settings[0])
	# Path -> its changed settings, and the names of those that changed.
	var changes := {}
	var changed_keys := {}
	var unchanged := PackedStringArray()
	for i in files.paths.size():
		var path: String = files.paths[i]
		var settings: ConfigFile = files.settings[i]
		var changed := PackedStringArray()
		if params is Dictionary:
			for key in params:
				if key == "_subresources":
					return {"error": "Change _subresources with the subresources argument, by animation or node name."}
				if not settings.has_section_key("params", key):
					return {"error": "%s (%s importer) has no setting %s; nothing was changed. Call import_settings with just its path to list its settings." % [path, settings.get_value("remap", "importer", ""), key]}
				var value: Variant = params[key]
				var old: Variant = settings.get_value("params", key)
				# JSON numbers arrive as floats; keep integer settings integers.
				if typeof(old) == TYPE_INT and typeof(value) == TYPE_FLOAT:
					value = int(value)
				elif typeof(old) != typeof(value) and value is String:
					value = str_to_var(value)
				if typeof(value) == typeof(old) and value == old:
					continue
				settings.set_value("params", key, value)
				changed.append(key)
		if subresources is Dictionary and not subresources.is_empty():
			var outcome := _change_subresources(path, settings, subresources)
			if outcome.has("error"):
				return {"error": outcome.error + " Nothing was changed."}
			changed.append_array(outcome.changed)
		if changed.is_empty():
			unchanged.append(path)
		else:
			changes[path] = settings
			changed_keys[path] = changed
	var reply := {"reimported": {}, "unchanged": unchanged}
	if changes.is_empty():
		return reply
	for path in changes:
		changes[path].save(path + ".import")
	var capture = log_capture_script.new()
	OS.add_logger(capture)
	EditorInterface.get_resource_filesystem().reimport_files(PackedStringArray(changes.keys()))
	while EditorInterface.get_resource_filesystem().is_importing():
		await get_tree().process_frame
	OS.remove_logger(capture)
	# A failed import is only marked in the .import file (valid=false), which
	# the editor rewrote; the importer's reasons are in the log.
	var failed := PackedStringArray()
	for path in changes:
		var written := ConfigFile.new()
		written.load(path + ".import")
		if not written.get_value("remap", "valid", true):
			failed.append(path)
		else:
			reply.reimported[path] = changed_keys[path]
	if not failed.is_empty():
		var note := "Reimporting %s failed; the new settings are saved, but %s not imported." % [", ".join(failed), "it was" if failed.size() == 1 else "they were"]
		if not reply.reimported.is_empty():
			note += " The other %d changed files were reimported." % reply.reimported.size()
		return {"error": note, "logs": capture.take()}
	return reply

## The files paths name, "*" matching any imported files (across folders too):
## {"paths", "settings": their ConfigFiles} or {"error"}.
func _import_settings_files(paths: PackedStringArray) -> Dictionary:
	var found := PackedStringArray()
	var imported := PackedStringArray()
	for given in paths:
		var path := given if given.begins_with("res://") else "res://" + given.trim_prefix("/")
		if not path.contains("*"):
			if not FileAccess.file_exists(path + ".import"):
				return {"error": "%s has no .import file; only imported assets have import settings." % path}
			if not path in found:
				found.append(path)
			continue
		if imported.is_empty():
			_imported_files(EditorInterface.get_resource_filesystem().get_filesystem(), imported)
		var matched := false
		for candidate in imported:
			if candidate.match(path):
				matched = true
				if not candidate in found:
					found.append(candidate)
		if not matched:
			return {"error": "No imported file matches %s." % path}
	if found.is_empty():
		return {"error": "Pass path, or paths, of the imported assets."}
	var settings := []
	for path in found:
		var file := ConfigFile.new()
		if file.load(path + ".import") != OK:
			return {"error": "%s's .import file could not be read." % path}
		settings.append(file)
	return {"paths": found, "settings": settings}

func _imported_files(folder: EditorFileSystemDirectory, into: PackedStringArray) -> void:
	for i in folder.get_file_count():
		if FileAccess.file_exists(folder.get_file_path(i) + ".import"):
			into.append(folder.get_file_path(i))
	for i in folder.get_subdir_count():
		_imported_files(folder.get_subdir(i), into)

## One asset's settings in full, for reading them.
func _import_settings_reply(path: String, settings: ConfigFile) -> Dictionary:
	var current := {}
	if settings.has_section("params"):
		for key in settings.get_section_keys("params"):
			if key != "_subresources":
				current[key] = code_runner_script.to_json(settings.get_value("params", key))
	var reply := {
		"path": path,
		"importer": settings.get_value("remap", "importer", ""),
		"type": settings.get_value("remap", "type", ""),
		"params": current,
	}
	if reply.importer == "scene":
		reply.subresources = _subresource_summary(settings.get_value("params", "_subresources", {}))
		reply.available = _scene_import_names(path)
	return reply

## The kinds of per-item settings a scene import keeps in _subresources.
const SUBRESOURCE_CATEGORIES := ["animations", "nodes", "meshes", "materials"]
## Settings that hold a resource, given as its res:// or uid:// path.
const IMPORT_RESOURCE_KEYS := ["retarget/bone_map"]
## Settings that hold names (StringNames), which JSON can only send as strings.
const IMPORT_NAME_LIST_KEYS := ["retarget/rest_fixer/fix_silhouette/filter"]
const LOOP_MODES := {"none": 0, "linear": 1, "pingpong": 2, "ping_pong": 2}

## Applies subresources ("animations/<name>", "nodes/PATH:<node path>", with
## "*" for every one of that category) to settings' _subresources. Names come
## from the source file, as _scene_import_names() lists them. Returns
## {"changed"} or {"error"}.
func _change_subresources(path: String, settings: ConfigFile, changes: Dictionary) -> Dictionary:
	var all: Dictionary = settings.get_value("params", "_subresources", {})
	var available := _scene_import_names(path)
	var changed := PackedStringArray()
	for target: String in changes:
		var category := target.get_slice("/", 0)
		var item := target.substr(category.length() + 1)
		if not category in SUBRESOURCE_CATEGORIES or item.is_empty():
			return {"error": "subresources keys are \"<category>/<name>\" with category one of %s, like \"animations/Take 001\" or \"nodes/PATH:Skeleton3D\" (\"animations/*\" for all)." % ", ".join(SUBRESOURCE_CATEGORIES)}
		if not changes[target] is Dictionary:
			return {"error": "subresources[\"%s\"] is a dictionary of setting -> value." % target}
		var known: Dictionary = all.get(category, {})
		var names := []
		for name in known.keys() + Array(available.get(category, [])):
			if not name in names:
				names.append(name)
		var items := names if item == "*" else [item]
		if items.is_empty() or (item != "*" and not item in names):
			return {"error": "%s has no %s \"%s\"; it has %s." % [path, category.trim_suffix("s"), item, ", ".join(PackedStringArray(names)) if not names.is_empty() else "none"]}
		for name in items:
			var entry: Dictionary = known.get(name, {})
			for key: String in changes[target]:
				var value: Variant = _import_value(key, entry.get(key), changes[target][key])
				if value is Dictionary and value.has("error"):
					return value
				if entry.has(key) and typeof(entry[key]) == typeof(value) and entry[key] == value:
					continue
				entry[key] = value
				# Godot finds a saved file by its uid first and this path second.
				if key.ends_with("save_to_file/path") and String(value).begins_with("res://"):
					entry[key.trim_suffix("path") + "fallback_path"] = value
				changed.append("%s/%s: %s" % [category, name, key])
			known[name] = entry
		all[category] = known
	settings.set_value("params", "_subresources", all)
	return {"changed": changed}

## A subresource setting's new value in the type the importer expects.
func _import_value(key: String, old: Variant, value: Variant) -> Variant:
	if value is String and (value.begins_with("res://") or value.begins_with("uid://")) and (old is Object or key in IMPORT_RESOURCE_KEYS):
		var resource := load(value)
		return resource if resource != null else {"error": "No resource at %s for %s." % [value, key]}
	if value is Array and (key in IMPORT_NAME_LIST_KEYS or (old is Array and not old.is_empty() and old[0] is StringName)):
		return value.map(func(name: Variant) -> StringName: return StringName(name))
	if key.ends_with("loop_mode") and value is String:
		return LOOP_MODES.get(value.to_lower(), {"error": "%s is one of %s." % [key, ", ".join(LOOP_MODES.keys())]})
	if value is float and (old is int or key.ends_with("loop_mode") or key.ends_with("_frame") or key.ends_with("amount")):
		return int(value)
	return value

## The settings an asset's import keeps per animation and node, without the
## many empty slice_N entries Godot writes (only the slices/amount in use are
## kept), resources as their paths.
func _subresource_summary(all: Dictionary) -> Dictionary:
	var summary := {}
	for category in all:
		summary[category] = {}
		for name in all[category]:
			var entry: Dictionary = all[category][name]
			var slices := int(entry.get("slices/amount", 0))
			var shown := {}
			for key: String in entry:
				if key.begins_with("slice_") and int(key.get_slice("/", 0).trim_prefix("slice_")) > slices:
					continue
				var value: Variant = entry[key]
				shown[key] = value.resource_path if value is Resource else code_runner_script.to_json(value)
			summary[category][name] = shown
	return summary

## The animation names and node paths an imported scene offers for per-item
## settings: its animations by name, and its skeletons and meshes as
## "PATH:<path from the root>". They are read from the source file as the
## importer sees it before its own changes, since a retarget renames the
## skeleton (to GeneralSkeleton) while its settings keep the source name.
## Formats other than FBX and glTF fall back to the imported scene.
func _scene_import_names(path: String) -> Dictionary:
	var root: Node = null
	var source := ""
	var document: Variant = null
	match path.get_extension().to_lower():
		"fbx":
			document = [FBXDocument.new(), FBXState.new()]
		"gltf", "glb":
			document = [GLTFDocument.new(), GLTFState.new()]
	if document != null and document[0].append_from_file(ProjectSettings.globalize_path(path), document[1]) == OK:
		root = document[0].generate_scene(document[1])
		source = "source file"
	if root == null:
		var packed := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
		if packed == null:
			return {}
		root = packed.instantiate()
		source = "imported scene; nodes the import renamed have their new names here, but their settings use the names in the source file"
	var animations := []
	for player: AnimationPlayer in root.find_children("*", "AnimationPlayer", true, false):
		for animation_name in player.get_animation_list():
			if not String(animation_name) in animations:
				animations.append(String(animation_name))
	var nodes := []
	for node in root.find_children("*", "Skeleton3D", true, false) + root.find_children("*", "MeshInstance3D", true, false):
		nodes.append("PATH:" + str(root.get_path_to(node)))
	root.free()
	return {"animations": animations, "nodes": nodes, "from": source}

# --- Game tools --------------------------------------------------------------

## Plays a scene: "" the main scene, "current" the scene being edited, or a
## path, after syncing files changed on disk. Waits until the game's bridge
## helper reports in. A background game runs where it is never seen (see
## _play_background) instead of the editor's game window. user_data picks the
## game's user:// folder (see _prepare_user_data). setup is GDScript run in the
## game once it is up, as by game_run; its reply comes back as `setup`, and a
## setup that fails does not fail the start.
func _game_play(scene: String, restart: bool, background: bool, user_data := "copy", setup := "", embed: Variant = null) -> Dictionary:
	if not user_data in USER_DATA_MODES:
		return {"error": "user_data is one of %s." % ", ".join(USER_DATA_MODES)}
	if embed != null and not embed is bool:
		return {"error": "embed is true or false, not %s." % JSON.stringify(embed)}
	if embed == true and background:
		return {"error": "A background game is never embedded; leave out embed or background."}
	var embed_item := _embed_menu_item() if not background else {}
	if embed != null and not background:
		if embed_item.is_empty():
			return {"error": "The Game view's Embed Game on Next Play option was not found, so embedding cannot be chosen; leave out embed."}
		if embed == true and embed_item.popup.is_item_disabled(embed_item.index):
			return {"error": "The Game view cannot embed games here (its Embed Game on Next Play option is disabled)."}
	if _game_running():
		if not restart:
			return {"error": "%s is already playing. Stop it with game_stop, or pass restart." % _playing_scene()}
		await _game_stop()
	if not scene.is_empty() and scene != "current" and not scene.begins_with("res://"):
		scene = "res://" + scene.trim_prefix("/")
	if not scene.is_empty() and scene != "current" and not ResourceLoader.exists(scene):
		return {"error": "No scene at %s." % scene}
	# Like editor_run: the game then runs the latest scripts, with new
	# class_names and imports registered.
	var scenes := await _sync()
	debugger.game_session = -1
	debugger.game_info = {}
	_background_output = []
	var user_dir := _prepare_user_data(user_data)
	var embedded: Variant = false if background else null
	# The option is read as the game starts, so it is switched only for this
	# play and switched back once the game has started.
	var embedding_was: Variant = null
	if not embed_item.is_empty():
		embedding_was = _embedding_chosen(embed_item)
		if embed != null:
			_choose_embedding(embed_item, embed)
		embedded = _embedding_chosen(embed_item) and not embed_item.popup.is_item_disabled(embed_item.index)
	var started := Time.get_ticks_msec()
	var failed := ""
	if background:
		failed = _play_background(scene)
	else:
		match scene:
			"":
				EditorInterface.play_main_scene()
			"current":
				EditorInterface.play_current_scene()
			_:
				EditorInterface.play_custom_scene(scene)
	var outcome := {"error": failed} if not failed.is_empty() else await _await_game_start(background)
	_restore_data_home()
	if embedding_was != null:
		_choose_embedding(embed_item, embedding_was)
	if outcome.has("error"):
		return outcome
	var info: Dictionary = debugger.game_info.duplicate()
	info.started_in_seconds = (Time.get_ticks_msec() - started) / 1000.0
	info.background = background
	if embedded != null:
		info.embedded = embedded
	if embedded == true:
		info.note = "The game is embedded in the editor's Game view, so it cannot move, resize or change the mode of its own window, and Window.is_embedded() still returns false. Play it with embed false for a window of its own."
	info.user_data = user_data
	info.user_data_dir = user_dir
	info.merge(scenes)
	if not setup.strip_edges().is_empty():
		info.setup = _limit_reply(await _game_request("run", {"code": setup}, GAME_SETUP_TIMEOUT_MS))
	return info

## The Game view's "Embed Game on Next Play" menu item, as {"popup", "index"},
## or {} if there is none. The editor has no API for embedding, and the
## project's game_view/embed_on_play metadata is only read when the editor
## starts, so the Game view's own menu is read and pressed instead.
func _embed_menu_item() -> Dictionary:
	for view in EditorInterface.get_base_control().find_children("*", "GameView", true, false):
		for menu: MenuButton in view.find_children("*", "MenuButton", true, false):
			var popup := menu.get_popup()
			for i in popup.item_count:
				if popup.get_item_text(i) == "Embed Game on Next Play":
					return {"popup": popup, "index": i}
	return {}

func _embedding_chosen(item: Dictionary) -> bool:
	return item.popup.is_item_checked(item.index)

## Ticks or unticks the item through the Game view's own handler, which also
## saves the choice, as clicking it would.
func _choose_embedding(item: Dictionary, embed: bool) -> void:
	if _embedding_chosen(item) != embed:
		item.popup.id_pressed.emit(item.popup.get_item_id(item.index))

## Waits until the started game's helper reports in: {} then, or an error
## (see _start_break_error and _start_failure).
func _await_game_start(background: bool) -> Dictionary:
	var started := Time.get_ticks_msec()
	var seen_running := background
	while debugger.game_session < 0 or debugger.game_info.is_empty():
		var running := _game_running()
		seen_running = seen_running or running
		if not debugger.starting_break().is_empty():
			return await _start_break_error()
		if seen_running and not running:
			return _start_failure("The game quit or crashed while starting, before the bridge helper reported in.")
		if Time.get_ticks_msec() - started > GAME_START_TIMEOUT_MS:
			return _start_failure("The game did not report in within %d s. Is the GodotBridgeGame autoload missing (turn the plugin off and on)? Running: %s" % [GAME_START_TIMEOUT_MS / 1000, running])
		await get_tree().process_frame
	return {}

## Points the next game's user:// at a throwaway folder unless user_data is
## "real": "copy" starts it from a copy of the real one (saves, settings),
## "empty" from nothing, so testing never changes the player's own data. The
## game inherits the editor's environment, so _data_home_variable is set until
## it has started (_restore_data_home). Returns the game's user:// folder.
func _prepare_user_data(user_data: String) -> String:
	if user_data == "real":
		return OS.get_user_data_dir()
	var variable_value := OS.get_temp_dir().path_join("godot_bridge_user_data")
	var game_dir := _make_user_data(user_data, variable_value)
	_saved_data_home = OS.get_environment(_data_home_variable) if OS.has_environment(_data_home_variable) else null
	_data_home_set = true
	OS.set_environment(_data_home_variable, variable_value)
	return game_dir

## Clears out variable_value, a folder only the bridge uses, and sets up a
## user:// folder under it as a game finds it with _data_home_variable set to
## variable_value: a copy of the real one, or empty. Returns that folder.
func _make_user_data(user_data: String, variable_value: String) -> String:
	var real := OS.get_user_data_dir()
	_remove_tree(variable_value)
	# The user folder's place under the data folder, e.g. godot/app_userdata/<name>.
	var game_dir := _data_home_for(variable_value).path_join(real.trim_prefix(OS.get_data_dir()).trim_prefix("/"))
	DirAccess.make_dir_recursive_absolute(game_dir)
	if user_data == "copy":
		_copy_tree(real, game_dir, USER_DATA_SKIPPED)
	return game_dir

## The data folder Godot uses when _data_home_variable is value: the value
## itself (XDG_DATA_HOME on Linux, APPDATA on Windows), or on macOS, where it
## is HOME, the Application Support folder under it.
func _data_home_for(value: String) -> String:
	if _data_home_variable == "HOME":
		return value.path_join("Library/Application Support")
	return value

func _restore_data_home() -> void:
	if not _data_home_set:
		return
	_data_home_set = false
	if _saved_data_home == null:
		OS.unset_environment(_data_home_variable)
	else:
		OS.set_environment(_data_home_variable, _saved_data_home)

func _copy_tree(from: String, to: String, skipped: Array = []) -> void:
	var dir := DirAccess.open(from)
	if dir == null:
		return
	DirAccess.make_dir_recursive_absolute(to)
	for file in dir.get_files():
		DirAccess.copy_absolute(from.path_join(file), to.path_join(file))
	for folder in dir.get_directories():
		if not folder in skipped:
			_copy_tree(from.path_join(folder), to.path_join(folder))

func _remove_tree(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for file in dir.get_files():
		DirAccess.remove_absolute(path.path_join(file))
	for folder in dir.get_directories():
		# A link is removed, never followed into.
		if dir.is_link(folder):
			DirAccess.remove_absolute(path.path_join(folder))
		else:
			_remove_tree(path.path_join(folder))
	DirAccess.remove_absolute(path)

## game_play's answer when the game stopped in the debugger while starting,
## typically at a script error in the main scene: the error and stack, with
## the game's output as logs. The game stays paused so it can be inspected in
## the Debugger panel.
func _start_break_error() -> Dictionary:
	# The stack arrives in a message of its own just after the break.
	var asked := Time.get_ticks_msec()
	while debugger.starting_break().get("stack", []).is_empty() and Time.get_ticks_msec() - asked < 1000:
		await get_tree().process_frame
	var paused: Dictionary = debugger.starting_break()
	var text := "The game stopped in the editor's debugger while starting, before the bridge helper reported in: %s" % paused.get("reason", "unknown")
	for frame in paused.get("stack", []):
		text += "\n  at %s" % frame
	text += "\nIt is still paused: inspect it in the Debugger panel, then restart it (game_play with restart) or stop it with game_stop."
	return {"error": text, "logs": _start_output()}

## game_play's answer when the game quit or never reported in, with its output
## as logs. A background game is stopped.
func _start_failure(text: String) -> Dictionary:
	if _background_pid >= 0:
		_stop_background()
	return {"error": text, "logs": _start_output()}

## The starting game's last output: from the Debugger panel, and for a
## background game also the process's own stdout and stderr (which include
## errors and native crash backtraces).
func _start_output() -> PackedStringArray:
	_read_background_output()
	# The process output holds everything the Debugger panel shows, and more.
	var lines: PackedStringArray = _background_output.slice(maxi(0, _background_output.size() - 40)) if not _background_output.is_empty() else debugger.recent_output(30)
	return PackedStringArray(Array(lines).filter(func(line: String) -> bool: return not ENGINE_BANNER.any(func(banner: String) -> bool: return line.begins_with(banner))))

## Starts the game inside gamescope's headless backend: a private display with
## full GPU rendering that is never shown, so the game cannot appear on screen
## or take focus (window managers place and focus new windows wherever they
## like, whatever position or minimized flag the game asks for). It is muted,
## and connects to the editor's debugger like a game the editor plays. Returns
## an error, or "".
func _play_background(scene: String) -> String:
	if OS.get_name() != "Linux":
		return "Background games need gamescope's headless backend, which only runs on Linux. Play without background instead."
	var gamescope := _find_executable("gamescope")
	if gamescope.is_empty():
		return "Background games need gamescope (its headless backend), which is not installed."
	match scene:
		"":
			scene = String(ProjectSettings.get_setting("application/run/main_scene", ""))
		"current":
			var edited := EditorInterface.get_edited_scene_root()
			scene = edited.scene_file_path if edited != null else ""
	if scene.begins_with("uid://"):
		scene = ResourceUID.get_id_path(ResourceUID.text_to_id(scene))
	if scene.is_empty():
		return "There is no scene to play."
	if not _set_debug_server_kept_open(true):
		return "Could not find the Debug menu's \"Keep Debug Server Open\" item, which background games need."
	# Like the editor's own Play, which saves first when run/auto_save/save_before_running is on.
	if EditorInterface.get_editor_settings().get_setting("run/auto_save/save_before_running"):
		EditorInterface.save_all_scenes()
	var size := _project_window_size()
	var settings := EditorInterface.get_editor_settings()
	var debug_address := "tcp://%s:%d" % [settings.get_setting("network/debug/remote_host"), settings.get_setting("network/debug/remote_port")]
	var args := PackedStringArray([
		"--backend", "headless",
		"-w", str(size.x), "-h", str(size.y), "-W", str(size.x), "-H", str(size.y),
		"--",
		OS.get_executable_path(), "--path", ProjectSettings.globalize_path("res://"),
		"--remote-debug", debug_address, "--scene", scene,
		# Muted: a game nobody sees should not be heard either.
		"--audio-driver", "Dummy",
	])
	var process := OS.execute_with_pipe(gamescope, args, false)
	if process.is_empty():
		_stop_background()
		return "Could not start gamescope."
	_background_pid = process.pid
	_background_pipes = [process.stdio, process.stderr]
	_background_partial = ["", ""]
	_background_in_noise = [false, false]
	_background_output = []
	_background_scene = scene
	return ""

## Reads whatever the background game has written since the last call.
func _read_background_output() -> void:
	for i in _background_pipes.size():
		var pipe := _background_pipes[i]
		if pipe == null or not pipe.is_open():
			continue
		var chunk := pipe.get_buffer(65536)
		if chunk.is_empty():
			continue
		var lines: PackedStringArray = (_background_partial[i] + chunk.get_string_from_utf8()).split("\n")
		_background_partial[i] = lines[-1]
		lines.resize(lines.size() - 1)
		for line in lines:
			line = _terminal_colours.sub(line, "", true).strip_edges(false, true)
			if line.strip_edges().is_empty():
				continue
			var continues := line.begins_with(" ") or line.begins_with("\t")
			if not continues:
				_background_in_noise[i] = BACKGROUND_NOISE.any(func(noise: String) -> bool: return line.begins_with(noise))
			if not _background_in_noise[i]:
				_background_output.append(line)
	if _background_output.size() > BACKGROUND_OUTPUT_KEPT:
		_background_output = _background_output.slice(_background_output.size() - BACKGROUND_OUTPUT_KEPT)

## The window size the game opens with, from the project's display settings.
func _project_window_size() -> Vector2i:
	var size := Vector2i(ProjectSettings.get_setting("display/window/size/viewport_width", 1152), ProjectSettings.get_setting("display/window/size/viewport_height", 648))
	var override := Vector2i(ProjectSettings.get_setting("display/window/size/window_width_override", 0), ProjectSettings.get_setting("display/window/size/window_height_override", 0))
	return Vector2i(override.x if override.x > 0 else size.x, override.y if override.y > 0 else size.y)

func _find_executable(executable: String) -> String:
	for folder in OS.get_environment("PATH").split(":", false):
		if FileAccess.file_exists(folder.path_join(executable)):
			return folder.path_join(executable)
	return ""

## Switches the Debug menu's "Keep Debug Server Open" on, remembering to switch
## it back off afterwards, or back off if the bridge switched it on. False when
## the menu item is missing.
func _set_debug_server_kept_open(open: bool) -> bool:
	var menu := EditorInterface.get_base_control().find_child("Debug", true, false) as PopupMenu
	var index := menu.get_item_index(KEEP_DEBUG_SERVER_OPEN_ID) if menu != null else -1
	if index < 0 or not menu.is_item_checkable(index):
		return false
	if open and not menu.is_item_checked(index):
		menu.id_pressed.emit(KEEP_DEBUG_SERVER_OPEN_ID)
		_opened_debug_server = true
	elif not open and _opened_debug_server:
		if menu.is_item_checked(index):
			menu.id_pressed.emit(KEEP_DEBUG_SERVER_OPEN_ID)
		_opened_debug_server = false
	return true

## Ends a background game (stopping gamescope also ends the game in it).
func _stop_background() -> void:
	if _background_pid >= 0 and OS.is_process_running(_background_pid):
		OS.kill(_background_pid)
	_read_background_output()
	for pipe in _background_pipes:
		if pipe != null:
			pipe.close()
	_background_pipes = []
	_background_pid = -1
	_background_scene = ""
	_set_debug_server_kept_open(false)

func _game_running() -> bool:
	return EditorInterface.is_playing_scene() or (_background_pid >= 0 and OS.is_process_running(_background_pid))

func _playing_scene() -> String:
	if _background_pid >= 0:
		return _background_scene
	return EditorInterface.get_playing_scene() if EditorInterface.is_playing_scene() else ""

func _game_stop() -> Dictionary:
	var was_playing := _game_running()
	if _background_pid >= 0:
		_stop_background()
		# Wait for the debugger session to close, so a new game is not mistaken for it.
		var started := Time.get_ticks_msec()
		while debugger.game_session >= 0 and Time.get_ticks_msec() - started < 5000:
			await get_tree().process_frame
	EditorInterface.stop_playing_scene()
	while EditorInterface.is_playing_scene():
		await get_tree().process_frame
	if not was_playing:
		return {"stopped": false, "note": "No game was running, so there was nothing to stop."}
	return {"stopped": true}

## Sends a request to the running game and waits for its reply.
##
## While bridge code runs ("run"), the game ignores error breaks: a script
## error in that code would otherwise pause the whole game in the editor's
## debugger. The errors still come back as logs. Afterwards error breaks are
## switched back on, which also undoes the Debugger panel's "Ignore Error
## Breaks" button if it was on.
func _game_request(kind: String, payload: Dictionary, timeout_ms := GAME_REQUEST_TIMEOUT_MS) -> Dictionary:
	if debugger == null or not _game_running() or debugger.game_session < 0:
		return {"error": NO_GAME_ERROR}
	if debugger.is_game_paused():
		return _paused_error()
	_next_game_request += 1
	var id := _next_game_request
	var ignore_error_breaks := kind == "run"
	if ignore_error_breaks:
		debugger.send_core("set_ignore_error_breaks", [true])
	if not debugger.send(kind, [id, payload]):
		return {"error": "Could not reach the game's debugger session."}
	var outcome: Dictionary = await _await_game_reply(id, timeout_ms)
	if ignore_error_breaks:
		debugger.send_core("set_ignore_error_breaks", [false])
	return outcome

## Lets the game play on its own, with error breaks on (unlike game_run), until
## it stops in the debugger at an error in its own code or a breakpoint, quits,
## or the seconds pass.
func _game_wait(seconds: float) -> Dictionary:
	if debugger == null or not _game_running() or debugger.game_session < 0:
		return {"error": NO_GAME_ERROR}
	# Already stopped in the debugger: that is the outcome a wait would end on.
	if debugger.is_game_paused():
		return await _paused_outcome(0.0)
	var state := await _game_request("state", {})
	if state.get("suspended", false):
		return {"error": "The game is suspended, so it would not play. Resume it with game_suspend(suspended=false), or step it with step_frames."}
	seconds = clampf(seconds, 0.0, GAME_WAIT_MAX_SECONDS)
	var started := Time.get_ticks_msec()
	var waited := func() -> float: return snappedf((Time.get_ticks_msec() - started) / 1000.0, 0.01)
	while Time.get_ticks_msec() - started < seconds * 1000.0:
		if not _game_running() or debugger.game_session < 0:
			if _background_pid >= 0:
				_stop_background()
			var exited := {"outcome": "exited", "waited_seconds": waited.call(), "note": "The game quit or crashed; its last output is below."}
			exited.last_output = debugger.recent_output(30)
			if not _background_output.is_empty():
				exited.process_output = _background_output.slice(maxi(0, _background_output.size() - 40))
			return exited
		if debugger.is_game_paused():
			return await _paused_outcome(waited.call())
		await get_tree().process_frame
	return {"outcome": "running", "waited_seconds": waited.call()}

## game_wait's reply for a game stopped in the debugger, with its error and stack.
func _paused_outcome(waited_seconds: float) -> Dictionary:
	# The stack arrives in a message of its own just after the break.
	var asked := Time.get_ticks_msec()
	while debugger.game_break().get("stack", []).is_empty() and Time.get_ticks_msec() - asked < 1000:
		await get_tree().process_frame
	var paused: Dictionary = debugger.game_break()
	return {
		"outcome": "paused",
		"waited_seconds": waited_seconds,
		"reason": paused.get("reason", "unknown"),
		"stack": paused.get("stack", []),
		"note": "The game is paused in the editor's debugger. Continue it from the Debugger panel, restart it (game_play with restart) or stop it with game_stop.",
	}

## Freezes or resumes the running game with Godot's own debugger messages, the
## ones behind the Game view's Suspend and Next Frame buttons. While suspended no
## node processes, whatever its process_mode, and physics and game time stop,
## but the game still draws and answers game_run and game_screenshot, so a pose
## set up with game_run stays put. step_frames > 0 suspends the game and then
## plays that many frames, each suspended again once it is drawn.
func _game_suspend(suspended: bool, step_frames: int) -> Dictionary:
	if debugger == null or not _game_running() or debugger.game_session < 0:
		return {"error": NO_GAME_ERROR}
	if debugger.is_game_paused():
		return _paused_error()
	step_frames = clampi(step_frames, 0, GAME_STEP_MAX_FRAMES)
	if step_frames > 0:
		suspended = true
	debugger.send_core("scene:suspend_changed", [suspended])
	var state := await _game_request("state", {})
	if state.has("error"):
		return state
	if step_frames > 0:
		state = await _step_frames(step_frames, state)
		if state.has("error"):
			return state
	return {"suspended": state.suspended, "stepped": step_frames}

## Plays frames one at a time from a suspended game and returns its state after
## the last, or an error with how many were stepped. Each step is a round trip
## through the debugger connection, about 80 ms, so long jumps are quicker by
## resuming and suspending again.
func _step_frames(step_frames: int, state: Dictionary) -> Dictionary:
	for step in step_frames:
		var processed: int = state.processed_frames
		debugger.send_core("scene:next_frame", [])
		state = await _game_request("step_wait", {})
		# The stepped frame is done once the helper has processed it and the
		# game has suspended itself again after drawing it.
		var started := Time.get_ticks_msec()
		while not state.has("error") and not (state.suspended and state.processed_frames > processed):
			if Time.get_ticks_msec() - started > GAME_STEP_TIMEOUT_MS:
				return {"error": "Frame %d of %d did not finish within %d s." % [step + 1, step_frames, GAME_STEP_TIMEOUT_MS / 1000], "stepped": step}
			state = await _game_request("state", {})
		if state.has("error"):
			state.stepped = step
			return state
	return state

## The game stopped in the editor's debugger, at an error in its own code or a
## breakpoint: says where, with the error and the stack as the Debugger panel
## shows them.
func _paused_error() -> Dictionary:
	var paused: Dictionary = debugger.game_break()
	var text := "The game is paused in the editor's debugger"
	if paused.is_empty():
		text += ", at a breakpoint or a script error in the game's own code."
	else:
		text += ": %s" % paused.reason
		for frame in paused.stack:
			text += "\n  at %s" % frame
	text += "\nContinue it from the Debugger panel, restart it (game_play with restart) or stop it with game_stop."
	return {"error": text, "paused": paused}

func _await_game_reply(id: int, timeout_ms: int) -> Dictionary:
	var started := Time.get_ticks_msec()
	while not debugger.replies.has(id):
		if not _game_running():
			return {"error": "The game stopped before answering."}
		if debugger.is_game_paused():
			return _paused_error()
		if Time.get_ticks_msec() - started > timeout_ms:
			return {"error": "The game did not answer within %d s; it may be frozen." % (timeout_ms / 1000)}
		await get_tree().process_frame
	var reply = debugger.replies[id]
	debugger.replies.erase(id)
	return reply if reply is Dictionary else {"error": "The game sent an unreadable reply."}

## A new screenshot file path; the oldest screenshots beyond SCREENSHOTS_KEPT are deleted.
func _screenshot_path() -> String:
	var folder := ProjectSettings.globalize_path(CONNECTION_DIR.path_join("screenshots"))
	DirAccess.make_dir_recursive_absolute(folder)
	var files := Array(DirAccess.get_files_at(folder)).filter(func(file: String) -> bool: return file.ends_with(".png"))
	files.sort()
	while files.size() >= SCREENSHOTS_KEPT:
		DirAccess.remove_absolute(folder.path_join(files.pop_front()))
	return folder.path_join("shot-%d.png" % int(Time.get_unix_time_from_system() * 1000))

# --- Diagnostics, editor log and scene screenshots ----------------------------

## Compiles scripts fresh from disk (and with scenes, loads scenes) and
## reports every error with its file and line, and with warnings the scripts'
## GDScript warnings (see _script_warnings()). Without paths it checks the
## whole project except res://addons/.
func _diagnostics(paths: Array, scenes: bool, warnings := true) -> Dictionary:
	await _sync()
	var scripts := PackedStringArray()
	var scene_files := PackedStringArray()
	if paths.is_empty():
		_collect_files(EditorInterface.get_resource_filesystem().get_filesystem(), scripts, scene_files)
	else:
		for given in paths:
			var path := _res_path(String(given))
			if path.get_extension() == "gd":
				scripts.append(path)
			elif path.get_extension() in ["tscn", "scn"]:
				scene_files.append(path)
				scenes = true
	if not scenes:
		scene_files.clear()
	var problems := []
	var capture = log_capture_script.new()
	OS.add_logger(capture)
	for path in scripts + scene_files:
		if not FileAccess.file_exists(path):
			problems.append({"path": path, "messages": ["File not found."]})
			continue
		var loaded := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		var messages: PackedStringArray = capture.take()
		if loaded == null or not messages.is_empty():
			problems.append({"path": path, "messages": messages if not messages.is_empty() else PackedStringArray(["Failed to load."])})
	OS.remove_logger(capture)
	var reply := {"ok": problems.is_empty(), "scripts_checked": scripts.size(), "scenes_checked": scene_files.size(), "problems": problems}
	if warnings:
		var found := await _script_warnings(Array(scripts).filter(func(path: String) -> bool: return FileAccess.file_exists(path)))
		if found.has("error"):
			reply.warnings_note = found.error
		else:
			reply.warning_count = found.warnings.reduce(func(total: int, entry: Dictionary) -> int: return total + entry.messages.size(), 0)
			reply.warnings = found.warnings
	return reply

# --- GDScript warnings, from the editor's language server --------------------

## How long _script_warnings() waits to connect, and for all its answers.
const LSP_CONNECT_TIMEOUT_MS := 3000
const LSP_ANSWER_TIMEOUT_MS := 20000

## {"warnings": [{path, messages}]} for the scripts at paths that have any, as
## the script editor shows them, or {"error"}. Godot reports GDScript warnings
## only to the script editor and the debugger, never to loggers, so they come
## from the editor's GDScript language server, which analyzes each script sent
## to it with the project's warning settings.
func _script_warnings(paths: Array) -> Dictionary:
	if paths.is_empty():
		return {"warnings": []}
	var settings := EditorInterface.get_editor_settings()
	var host := String(settings.get_setting("network/language_server/remote_host"))
	var port := int(settings.get_setting("network/language_server/remote_port"))
	var peer := StreamPeerTCP.new()
	var unavailable := "Warnings were not checked: the editor's GDScript language server (%s:%d, Editor Settings > Network > Language Server) did not answer." % [host, port]
	if peer.connect_to_host(host, port) != OK:
		return {"error": unavailable}
	var started := Time.get_ticks_msec()
	while peer.get_status() == StreamPeerTCP.STATUS_CONNECTING and Time.get_ticks_msec() - started < LSP_CONNECT_TIMEOUT_MS:
		await get_tree().process_frame
		peer.poll()
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return {"error": unavailable}
	var buffer := [PackedByteArray()]
	var root_uri := _file_uri(ProjectSettings.globalize_path("res://"))
	_lsp_send(peer, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"processId": OS.get_process_id(), "rootUri": root_uri, "capabilities": {}}})
	var initialized := false
	var by_uri := {}
	for path: String in paths:
		by_uri[_file_uri(ProjectSettings.globalize_path(path)).uri_decode()] = path
	var answered := {}
	var found := {}
	started = Time.get_ticks_msec()
	while answered.size() < by_uri.size() and Time.get_ticks_msec() - started < LSP_ANSWER_TIMEOUT_MS:
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			break
		var message: Variant = _lsp_receive(peer, buffer)
		if message == null:
			await get_tree().process_frame
			continue
		if not initialized and message.get("id") == 1:
			initialized = true
			_lsp_send(peer, {"jsonrpc": "2.0", "method": "initialized", "params": {}})
			for path: String in paths:
				var uri := _file_uri(ProjectSettings.globalize_path(path))
				_lsp_send(peer, {"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {"textDocument": {"uri": uri, "languageId": "gdscript", "version": 1, "text": FileAccess.get_file_as_string(path)}}})
				_lsp_send(peer, {"jsonrpc": "2.0", "method": "textDocument/didClose", "params": {"textDocument": {"uri": uri}}})
		elif message.get("method") == "textDocument/publishDiagnostics":
			var path: String = by_uri.get(String(message.params.uri).uri_decode(), "")
			# didClose answers with an empty list of its own, after the real one.
			if path.is_empty() or answered.has(path):
				continue
			answered[path] = true
			for diagnostic: Dictionary in message.params.diagnostics:
				if int(diagnostic.get("severity", 0)) == 2:
					found[path] = found.get(path, PackedStringArray()) + PackedStringArray(["WARNING: %s (%s:%d)" % [diagnostic.message, path, int(diagnostic.range.start.line) + 1]])
	peer.disconnect_from_host()
	if not initialized:
		return {"error": unavailable}
	var warnings := []
	for path: String in paths:
		if found.has(path):
			warnings.append({"path": path, "messages": found[path]})
	var reply := {"warnings": warnings}
	if answered.size() < by_uri.size():
		reply.error = "Warnings were checked for only %d of %d scripts: the language server stopped answering." % [answered.size(), by_uri.size()]
	return reply

## A file:// URI for an absolute path, as the language server writes them.
func _file_uri(path: String) -> String:
	var parts := PackedStringArray()
	for part in path.split("/"):
		parts.append(part.uri_encode())
	return "file://" + ("" if path.begins_with("/") else "/") + "/".join(parts)

func _lsp_send(peer: StreamPeerTCP, message: Dictionary) -> void:
	var body := JSON.stringify(message).to_utf8_buffer()
	peer.put_data(("Content-Length: %d\r\n\r\n" % body.size()).to_ascii_buffer() + body)

## The next whole message from the language server, or null while none has
## fully arrived. buffer holds what was read past it.
func _lsp_receive(peer: StreamPeerTCP, buffer: Array) -> Variant:
	var available := peer.get_available_bytes()
	if available > 0:
		buffer[0] += peer.get_data(available)[1]
	var data: PackedByteArray = buffer[0]
	var header_end := -1
	for i in range(0, data.size() - 3):
		if data[i] == 13 and data[i + 1] == 10 and data[i + 2] == 13 and data[i + 3] == 10:
			header_end = i
			break
	if header_end < 0:
		return null
	var length := -1
	for line in data.slice(0, header_end).get_string_from_ascii().split("\r\n"):
		if line.to_lower().begins_with("content-length:"):
			length = int(line.get_slice(":", 1).strip_edges())
	var body_start := header_end + 4
	if length < 0 or data.size() < body_start + length:
		return null
	buffer[0] = data.slice(body_start + length)
	var message: Variant = JSON.parse_string(data.slice(body_start, body_start + length).get_string_from_utf8())
	return message if message is Dictionary else {}

func _collect_files(folder: EditorFileSystemDirectory, scripts: PackedStringArray, scene_files: PackedStringArray) -> void:
	if folder.get_path().begins_with("res://addons/"):
		return
	for i in folder.get_file_count():
		var path := folder.get_file_path(i)
		if path.get_extension() == "gd":
			scripts.append(path)
		elif path.get_extension() in ["tscn", "scn"]:
			scene_files.append(path)
	for i in folder.get_subdir_count():
		_collect_files(folder.get_subdir(i), scripts, scene_files)

func _collect_editor_log() -> void:
	if _editor_log == null:
		return
	var entries: Array[Dictionary] = _editor_log.take_entries()
	if entries.is_empty():
		return
	for entry in entries:
		log_capture_script.add_counted(_editor_log_lines, entry.line, entry.count)
	if _editor_log_lines.size() > EDITOR_LOG_LIMIT:
		_editor_log_lines = _editor_log_lines.slice(_editor_log_lines.size() - EDITOR_LOG_LIMIT)

func _editor_log_reply(count: int, clear: bool, level: String) -> Dictionary:
	if not level in EDITOR_LOG_LEVELS:
		return {"error": "level is one of %s." % ", ".join(EDITOR_LOG_LEVELS)}
	_collect_editor_log()
	var shown := PackedStringArray()
	for i in range(_editor_log_lines.size() - 1, -1, -1):
		if shown.size() >= count:
			break
		var entry: Dictionary = _editor_log_lines[i]
		var line: String = entry.line
		var is_error := line.begins_with("ERROR:") or line.begins_with("SCRIPT ERROR:") or line.begins_with("SHADER ERROR:")
		if level == "errors" and not is_error or level == "warnings" and not is_error and not line.begins_with("WARNING:"):
			continue
		shown.append(_editor_run_locations(log_capture_script.format(entry)))
	shown.reverse()
	if clear:
		_editor_log_lines = []
	return {"lines": shown, "kept": EDITOR_LOG_LIMIT}

## Renders a scene in an off-screen viewport without running the game. A
## Control root fills the image; 2D scenes are framed to fit their sprites,
## tile layers, controls and polygons; 3D scenes use their own camera or a
## camera aimed at their meshes. Only @tool scripts run in the editor, so
## nodes a scene builds from code at runtime are missing.
func _scene_screenshot(scene_path: String, size: Vector2i, max_size: int, view: Variant = null) -> Dictionary:
	scene_path = _res_path(scene_path)
	if not ResourceLoader.exists(scene_path):
		return {"error": "No scene at %s." % scene_path}
	await _sync()
	var packed := ResourceLoader.load(scene_path) as PackedScene
	if packed == null:
		return {"error": "%s is not a scene." % scene_path}
	size = Vector2i(clampi(size.x, 16, 4096), clampi(size.y, 16, 4096))
	var capture = log_capture_script.new()
	OS.add_logger(capture)
	var viewport := SubViewport.new()
	viewport.size = size
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.own_world_3d = true
	add_child(viewport)
	var instance := packed.instantiate()
	viewport.add_child(instance)
	_apply_project_theme(instance)
	var framing := {}
	var notes := PackedStringArray()
	# Windows and menus are often saved hidden and shown by the game.
	if instance is CanvasItem and not instance.visible:
		instance.visible = true
		notes.append("The root is hidden in the scene; it was shown for this screenshot.")
	if instance is Control:
		framing = {"view": "Control laid out by its own anchors in a %dx%d screen" % [size.x, size.y]}
	elif instance is Node2D:
		var bounds := _bounds_2d(instance)
		var camera := Camera2D.new()
		viewport.add_child(camera)
		camera.position = bounds.get_center()
		if bounds.has_area():
			var zoom := minf(size.x / bounds.size.x, size.y / bounds.size.y) * 0.95
			camera.zoom = Vector2(zoom, zoom)
		camera.make_current()
		framing = {"view": "2D at zoom %s" % snappedf(camera.zoom.x, 0.001), "fit": "bounds %s" % var_to_str(bounds)}
	elif instance is Node3D:
		var framed := _frame_3d(viewport, instance, view)
		if framed.has("error"):
			viewport.queue_free()
			OS.remove_logger(capture)
			return framed
		framing = framed.framing
	for i in 3:
		await get_tree().process_frame
	RenderingServer.force_draw(false)
	var image := viewport.get_texture().get_image()
	viewport.queue_free()
	OS.remove_logger(capture)
	var full := image.get_size()
	if max_size > 0 and maxi(full.x, full.y) > max_size:
		var scale := float(maxi(full.x, full.y)) / max_size
		image.resize(roundi(full.x / scale), roundi(full.y / scale), Image.INTERPOLATE_LANCZOS)
	var path := _screenshot_path()
	image.save_png(path)
	return code_runner_script.trimmed({"path": path, "scene": scene_path, "image_size": [image.get_width(), image.get_height()], "render_size": [size.x, size.y], "framing": framing, "notes": notes, "logs": capture.take()}, ["framing", "notes", "logs"])

## Renders an AnimationPlayer animation of a scene at several times, without
## running the game, side by side in one image with each frame's time above it.
## 2D scenes are framed once to fit their content at every one of those times,
## so the frames line up. AnimationTrees are switched off so the player drives
## the animation. As in scene_screenshot only @tool scripts run, so `setup`
## (GDScript, the body of setup(root: Node)) can fill in what the game's code
## would, such as a sprite's texture, before the frames are taken.
func _animation_frames(args: Dictionary) -> Dictionary:
	var scene_path := _res_path(String(args.get("scene", "")))
	if not ResourceLoader.exists(scene_path):
		return {"error": "No scene at %s." % scene_path}
	await _sync()
	# Read from disk, as the game would: the editor's cached copy can be stale.
	var packed := ResourceLoader.load(scene_path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	if packed == null:
		return {"error": "%s is not a scene." % scene_path}
	var given_size: Array = args.get("frame_size", []) if args.get("frame_size") is Array else []
	var size := Vector2i(256, 256) if given_size.size() != 2 else Vector2i(clampi(int(given_size[0]), 16, 2048), clampi(int(given_size[1]), 16, 2048))
	var capture = log_capture_script.new()
	OS.add_logger(capture)
	var viewport := SubViewport.new()
	viewport.size = size
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.canvas_item_default_texture_filter = int(ProjectSettings.get_setting("rendering/textures/canvas_textures/default_texture_filter", 1))
	add_child(viewport)
	var instance := packed.instantiate()
	viewport.add_child(instance)
	_apply_project_theme(instance)
	var reply := await _render_animation_frames(viewport, instance, args)
	viewport.queue_free()
	OS.remove_logger(capture)
	reply.logs = capture.take()
	return code_runner_script.trimmed(reply, ["framing", "notes", "logs"])

func _render_animation_frames(viewport: SubViewport, instance: Node, args: Dictionary) -> Dictionary:
	var posing := await _prepare_posing(instance, args)
	if posing.has("error"):
		return posing
	var notes: PackedStringArray = posing.notes
	var player: AnimationPlayer = posing.player
	var animation_name: StringName = posing.animation_name
	var animation: Animation = posing.animation
	var pose: Callable = posing.pose
	var length := animation.length
	var times := []
	if args.get("times") is Array and not args.times.is_empty():
		times = args.times.map(func(time) -> float: return clampf(float(time), 0.0, length))
	else:
		var count := clampi(int(args.get("count", 6)), 1, 64)
		for i in count:
			times.append(0.0 if count == 1 else length * i / (count - 1))

	var info := _animation_info(player, animation_name, instance, pose, String(args.get("root_bone", "")))
	if instance is Node3D and not _draws_anything_3d(instance):
		var skeletons := instance.find_children("*", "Skeleton3D", true, false)
		if not skeletons.is_empty():
			return {"error": "%s has a skeleton (%d bones) but no mesh, so every frame would be empty: it holds animations only. Add the animation to the character it is made for and pose that scene instead." % [args.get("scene", ""), skeletons.map(func(skeleton: Skeleton3D) -> int: return skeleton.get_bone_count()).reduce(func(a: int, b: int) -> int: return a + b, 0)]}

	var framing := {}
	if instance is Node2D:
		var bounds := Rect2()
		for i in times.size():
			pose.call(times[i])
			bounds = _bounds_2d(instance) if i == 0 else bounds.merge(_bounds_2d(instance))
		var camera := Camera2D.new()
		viewport.add_child(camera)
		camera.position = bounds.get_center().round()
		var fit := minf(viewport.size.x / maxf(bounds.size.x, 1.0), viewport.size.y / maxf(bounds.size.y, 1.0)) * 0.9
		# Whole-number zoom keeps pixel art pixels even.
		var zoom := floorf(fit) if fit >= 1.0 else fit
		camera.zoom = Vector2(zoom, zoom)
		camera.make_current()
		framing = {"view": "2D at zoom %s, the same for every frame" % zoom, "fit": "bounds %s over every frame" % var_to_str(bounds)}
	# Called before each frame is rendered, with its index (see _frame_animation_3d()).
	var before_frame := func(_index: int) -> void: pass
	if instance is Node3D:
		# Spring bones set themselves up in their first frame in the tree; posed
		# before that, they would not move.
		await get_tree().process_frame
		var set_up := _frame_animation_3d(viewport, instance, times, pose, animation, args)
		if set_up.has("error"):
			return set_up
		framing = set_up.framing
		pose = set_up.pose
		before_frame = set_up.before_frame

	var frames: Array[Image] = []
	for i in times.size():
		pose.call(times[i])
		before_frame.call(i)
		await get_tree().process_frame
		await get_tree().process_frame
		# The editor (low processor mode) redraws only when it sees a change, and
		# a new skeleton pose is not one: without this every 3D frame would show
		# the first frame's pose.
		RenderingServer.force_draw(false)
		frames.append(viewport.get_texture().get_image())

	# Lay the frames out in rows, each under its time.
	var font = texture_view_script.new()
	var columns := clampi(int(args.get("columns", mini(times.size(), 6))), 1, times.size())
	var rows := ceili(float(times.size()) / columns)
	var gap := 4
	var label_height: int = 5 * font.FONT_SCALE + 6
	var cell := Vector2i(viewport.size.x, viewport.size.y + label_height)
	var strip := Image.create(columns * cell.x + (columns + 1) * gap, rows * cell.y + (rows + 1) * gap, false, Image.FORMAT_RGBA8)
	strip.fill(font.BACKGROUND)
	for i in frames.size():
		var corner := Vector2i(gap + (i % columns) * (cell.x + gap), gap + (i / columns) * (cell.y + gap))
		font._label(strip, String.num(times[i], 3), corner + Vector2i(2, 3))
		frames[i].convert(Image.FORMAT_RGBA8)
		strip.blit_rect(frames[i], Rect2i(Vector2i.ZERO, frames[i].get_size()), corner + Vector2i(0, label_height))
	var path := _screenshot_path()
	strip.save_png(path)
	return {
		"path": path,
		"image_size": [strip.get_width(), strip.get_height()],
		"player": str(instance.get_path_to(player)),
		"animation": String(animation_name),
		"animation_info": info,
		"times": times,
		"frame_size": [viewport.size.x, viewport.size.y],
		"framing": framing,
		"notes": notes,
	}

## Gets a scene instance ready to be posed by its AnimationPlayer, for
## animation_frames and ctx.pose(): AnimationTrees switched off so the player
## drives the bones, args.setup run on it, and the player (args.player, else
## the first) put in manual mode. Returns {"notes", "player",
## "animation_name", "animation", "pose": Callable(time)} or {"error"}.
func _prepare_posing(instance: Node, args: Dictionary) -> Dictionary:
	var notes := PackedStringArray()
	for tree: AnimationTree in instance.find_children("*", "AnimationTree", true, false):
		if tree.active:
			tree.active = false
			notes.append("AnimationTree %s was switched off so the AnimationPlayer drives the animation." % instance.get_path_to(tree))
	var setup := String(args.get("setup", ""))
	if not setup.strip_edges().is_empty():
		var script := GDScript.new()
		script.source_code = "extends RefCounted\n\nfunc setup(root: Node) -> void:\n" + "\n".join(Array(setup.split("\n")).map(func(line: String) -> String: return "\t" + line)) + "\n"
		if script.reload() != OK:
			return {"error": "The setup code failed to compile; see logs."}
		await script.new().setup(instance)

	var player_path := String(args.get("player", ""))
	var player: AnimationPlayer = instance.get_node_or_null(player_path) as AnimationPlayer if not player_path.is_empty() else null
	if player == null:
		var players := instance.find_children("*", "AnimationPlayer", true, false)
		if not player_path.is_empty() or players.is_empty():
			return {"error": "No AnimationPlayer %sin the scene." % ("at %s " % player_path if not player_path.is_empty() else "")}
		player = players[0]
	var animation_name := StringName(args.get("animation", ""))
	if not player.has_animation(animation_name):
		return {"error": "%s has no animation '%s'; it has %s." % [instance.get_path_to(player), animation_name, ", ".join(PackedStringArray(Array(player.get_animation_list())))]}
	player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	# A looping clip seeked to its length wraps around to its start, so its last
	# frame and root motion are taken from a copy that does not loop. The copy
	# lives on this throwaway instance's player, not on the shared Animation.
	var posed_name := animation_name
	var animation := player.get_animation(animation_name)
	# Posed before (ctx.pose() on a root it returned): the old copy goes.
	if player.has_animation_library(&"_bridge"):
		player.stop()
		player.remove_animation_library(&"_bridge")
	if animation.loop_mode != Animation.LOOP_NONE:
		var once := animation.duplicate() as Animation
		once.loop_mode = Animation.LOOP_NONE
		var library := AnimationLibrary.new()
		library.add_animation(&"once", once)
		player.add_animation_library(&"_bridge", library)
		posed_name = &"_bridge/once"
	var pose := func(time: float) -> void:
		player.play(posed_name)
		player.seek(time, true)
	return {"notes": notes, "player": player, "animation_name": animation_name, "animation": animation, "pose": pose}

## ctx.pose() in editor_run (see code_runner.gd): scene, a scene path loaded
## from disk into an off-screen viewport or a root an earlier call returned,
## posed time seconds into animation as animation_frames poses it, with its
## BoneAttachment3Ds moved to their bones. Returns {"root", "viewport": the new
## viewport to free when the run ends, or null} or {"error"}.
func pose_scene(scene: Variant, animation: String, time: float, player: String) -> Dictionary:
	var instance: Node = scene if scene is Node else null
	var viewport: SubViewport = null
	if instance == null:
		var path := String(scene)
		if not path.begins_with("res://"):
			path = "res://" + path.trim_prefix("/")
		if not ResourceLoader.exists(path):
			return {"error": "No scene at %s." % path}
		# Read from disk, as the game would: the editor's cached copy can be stale.
		var packed := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
		if packed == null:
			return {"error": "%s is not a scene." % path}
		# Only for measuring: it is never drawn.
		viewport = SubViewport.new()
		viewport.own_world_3d = true
		viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		add_child(viewport)
		instance = packed.instantiate()
		viewport.add_child(instance)
	var posing := await _prepare_posing(instance, {"animation": animation, "player": player})
	if posing.has("error"):
		if viewport != null:
			viewport.queue_free()
		return posing
	var length: float = posing.animation.length
	if time < 0.0 or time > length:
		push_warning("ctx.pose(): %s is %s s long, so it was posed at %s s rather than %s s." % [animation, length, clampf(time, 0.0, length), time])
	posing.pose.call(clampf(time, 0.0, length))
	# Attachments follow their bone only when the skeleton next updates, a frame
	# after a seek; this way they are where the pose puts them now.
	for attachment: BoneAttachment3D in instance.find_children("*", "BoneAttachment3D", true, false):
		attachment.on_skeleton_update()
	return {"root": instance, "viewport": viewport}

## Gives top-level Controls the project theme: inside the editor they would
## otherwise inherit the editor's own theme.
## Whether anything under root renders in 3D: a mesh, sprite, CSG shape or the like.
func _draws_anything_3d(root: Node) -> bool:
	for geometry: GeometryInstance3D in root.find_children("*", "GeometryInstance3D", true, false):
		if not (geometry is MeshInstance3D and geometry.mesh == null):
			return true
	return false

func _apply_project_theme(node: Node) -> void:
	var theme_path := String(ProjectSettings.get_setting("gui/theme/custom", ""))
	if theme_path.is_empty():
		return
	var project_theme := load(theme_path) as Theme
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var current: Node = stack.pop_back()
		if current is Control and not current.get_parent() is Control:
			if current.theme == null:
				current.theme = project_theme
			continue
		stack.append_array(current.get_children())

## The global rectangle covering a 2D scene's visible content.
func _bounds_2d(root: Node) -> Rect2:
	var bounds := Rect2()
	var found := false
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is CanvasItem and not node.visible:
			continue
		stack.append_array(node.get_children())
		var rect := Rect2()
		if node is Sprite2D and node.texture != null:
			rect = node.get_global_transform() * node.get_rect()
		elif node is TileMapLayer and node.tile_set != null and node.get_used_rect().has_area():
			var used: Rect2i = node.get_used_rect()
			var tile := Vector2(node.tile_set.tile_size)
			rect = node.get_global_transform() * Rect2(Vector2(used.position) * tile, Vector2(used.size) * tile)
		elif node is Control:
			rect = node.get_global_rect()
		elif node is Polygon2D and not node.polygon.is_empty():
			var polygon_rect := Rect2(node.polygon[0], Vector2.ZERO)
			for point in node.polygon:
				polygon_rect = polygon_rect.expand(point)
			rect = node.get_global_transform() * polygon_rect
		else:
			continue
		bounds = rect if not found else bounds.merge(rect)
		found = true
	return bounds if found else Rect2(-160, -90, 320, 180)

## animation_frames' views of a 3D scene: its own camera, or an orthographic
## one looking at the character from that side, in the character's own axes
## (see _character_basis()): its front is +Z and its left hand on +X.
const ANIMATION_VIEWS := {
	"three_quarter": Vector3(0.6, 0.35, 1.0),
	"front": Vector3(0, 0, 1),
	"back": Vector3(0, 0, -1),
	# The character's own left and right: its left hand is on +X.
	"left": Vector3(1, 0, 0),
	"right": Vector3(-1, 0, 0),
	# Straight down, the character's front toward the image's bottom.
	"top": Vector3(0, 1, 0),
}
## How animation_frames treats a root bone that moves (root motion): follow
## it with the camera, lock it in place, or keep the camera still in the world.
const ANIMATION_ROOT_MODES := ["follow", "lock", "world"]
## How much of the clip animation_frames plays before each frame, and in what
## steps, so spring bones hang as they would in the game (see _settled_pose()).
const ANIMATION_SETTLE_SECONDS := 1.0
const ANIMATION_SETTLE_STEP := 1.0 / 60.0

## Wraps pose so that skeleton modifiers end up as they would in the game at
## that time: spring bones carry their motion from frame to frame, so posed
## just once they would hang as if nothing had moved. The springs start at
## rest and the skeletons play the second before the time in steps, running
## their modifiers after each. Before the clip's start a looping clip plays its
## end, its root bone moved back by lap (its travel over one play) so it does
## not jump; a one-shot clip holds its first pose.
func _settled_pose(skeletons: Array, pose: Callable, animation: Animation, root: Dictionary, lap: Vector3) -> Callable:
	var looping := animation.loop_mode != Animation.LOOP_NONE and animation.length > 0.0
	for skeleton: Skeleton3D in skeletons:
		skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
	var steps := ceili(ANIMATION_SETTLE_SECONDS / ANIMATION_SETTLE_STEP)
	return func(time: float) -> void:
		for step in steps + 1:
			var at := time - (steps - step) * ANIMATION_SETTLE_STEP
			if at >= 0.0 or not looping:
				pose.call(maxf(at, 0.0))
			else:
				var laps := floorf(at / animation.length)
				pose.call(at - laps * animation.length)
				if not root.is_empty():
					var skeleton: Skeleton3D = root.skeleton
					skeleton.set_bone_pose_position(root.bone, skeleton.get_bone_pose_position(root.bone) + lap * laps)
			for skeleton: Skeleton3D in skeletons:
				if step == 0:
					for spring: SpringBoneSimulator3D in skeleton.find_children("*", "SpringBoneSimulator3D", false, false):
						spring.reset()
				skeleton.advance(ANIMATION_SETTLE_STEP)
				# advance() leaves the work to the skeleton's next deferred update;
				# run it now.
				skeleton.notification(Skeleton3D.NOTIFICATION_UPDATE_SKELETON)

## Sets up the camera for a 3D animation_frames render, fitted to the posed
## character over all frames rather than its rest pose. Returns {"framing",
## "pose": the pose Callable, pinning the root bone with root "lock" and
## settling skeleton modifiers (see _settled_pose()), "before_frame":
## Callable(index), moving the camera with root "follow"} or {"error"}.
func _frame_animation_3d(viewport: SubViewport, instance: Node3D, times: Array, pose: Callable, animation: Animation, args: Dictionary) -> Dictionary:
	var focus_name := String(args.get("focus", ""))
	# A focus is framed by the bridge's own camera, so it picks a view by default.
	var picked := _pick_view(instance, args.get("view", "three_quarter" if not focus_name.is_empty() else null))
	if picked.has("error"):
		return picked
	var view: String = picked.view
	if view == "camera" and not focus_name.is_empty():
		return {"error": "focus frames a bone with one of the views %s, not the scene's own camera." % ", ".join(ANIMATION_VIEWS.keys())}
	var root_mode := String(args.get("root", "follow"))
	if not root_mode in ANIMATION_ROOT_MODES:
		return {"error": "root is one of %s." % ", ".join(ANIMATION_ROOT_MODES)}
	var skeletons: Array[Skeleton3D] = []
	skeletons.assign(instance.find_children("*", "Skeleton3D", true, false))
	var root: Dictionary = _animation_root_bone(instance, skeletons, String(args.get("root_bone", "")))
	if root.has("error"):
		return root
	var focus := {}
	if not focus_name.is_empty():
		for skeleton in skeletons:
			if skeleton.find_bone(focus_name) >= 0:
				focus = {"skeleton": skeleton, "bones": _bone_and_below(skeleton, skeleton.find_bone(focus_name))}
				break
		if focus.is_empty():
			var names := PackedStringArray()
			for skeleton in skeletons:
				for bone in skeleton.get_bone_count():
					names.append(skeleton.get_bone_name(bone))
			return {"error": "No bone %s; the skeletons have %s." % [focus_name, ", ".join(names)] if not names.is_empty() else "focus is a bone, but the scene has no Skeleton3D."}
	var root_at := func() -> Vector3:
		var skeleton: Skeleton3D = root.skeleton
		return skeleton.global_transform * skeleton.get_bone_global_pose(root.bone).origin
	# How far the root strays sideways from where it is in the first frame.
	var travel := 0.0
	var posed := pose
	if not root.is_empty():
		var start_at := Vector3.ZERO
		for i in times.size():
			pose.call(times[i])
			var at: Vector3 = root_at.call()
			if i == 0:
				start_at = at
			travel = maxf(travel, Vector2(at.x - start_at.x, at.z - start_at.z).length())
		pose.call(times[0])
		if root_mode == "lock":
			var skeleton: Skeleton3D = root.skeleton
			var start := skeleton.get_bone_pose_position(root.bone)
			posed = func(time: float) -> void:
				pose.call(time)
				var now := skeleton.get_bone_pose_position(root.bone)
				skeleton.set_bone_pose_position(root.bone, Vector3(start.x, now.y, start.z))
	var modified := skeletons.filter(func(skeleton: Skeleton3D) -> bool:
		return skeleton.get_children().any(func(child: Node) -> bool: return child is SkeletonModifier3D and child.active))
	if not modified.is_empty():
		# How far the root bone moves over one play of a looping clip; a locked
		# root does not move.
		var lap := Vector3.ZERO
		if animation.loop_mode != Animation.LOOP_NONE and not root.is_empty() and root_mode != "lock":
			var skeleton: Skeleton3D = root.skeleton
			pose.call(0.0)
			var start := skeleton.get_bone_pose_position(root.bone)
			pose.call(animation.length)
			lap = skeleton.get_bone_pose_position(root.bone) - start
		posed = _settled_pose(modified, posed, animation, root, lap)

	# Where each frame's root is relative to the first, sideways only, for the
	# camera to follow; and the box every frame fits in, seen from there.
	var offsets: Array[Vector3] = []
	var box := AABB()
	var first := Vector3.ZERO
	for i in times.size():
		posed.call(times[i])
		var offset := Vector3.ZERO
		if root_mode == "follow" and not root.is_empty():
			var at: Vector3 = root_at.call()
			if i == 0:
				first = at
			offset = Vector3(at.x - first.x, 0, at.z - first.z)
		offsets.append(offset)
		var frame_box := _posed_bounds(instance, skeletons) if focus.is_empty() else _bones_bounds(focus.skeleton, focus.bones)
		frame_box.position -= offset
		box = frame_box if i == 0 else box.merge(frame_box)

	var camera: Camera3D
	if view == "camera":
		camera = picked.camera
	else:
		camera = Camera3D.new()
		viewport.add_child(camera)
		var character := _character_basis(instance, skeletons)
		_aim_orthographic(camera, box, (character * ANIMATION_VIEWS[view]).normalized(), Vector2(viewport.size), -character.z)
	camera.make_current()
	var lit := _light_if_unlit(viewport, instance, camera)
	var base := camera.global_position
	# One short entry per fact, those that do not apply left out.
	var framing := {}
	if view == "camera":
		framing.view = "scene camera %s" % instance.get_path_to(camera)
	else:
		framing.view = "%s, orthographic" % view
		var fitted := "the posed character" if focus.is_empty() else "bone %s and the bones below it" % focus_name
		framing.fit = "%s over every frame, %s m" % [fitted, _size_text(box.size)]
	if not lit.is_empty():
		framing.lighting = lit
	if root.is_empty():
		framing.root = "no skeleton, so no root motion to follow or lock"
	else:
		framing.root = "%s on bone %s, which strays up to %s m sideways from its first-frame position over the frames shown" % [root_mode, root.name, snappedf(travel, 0.01)]
	if not modified.is_empty():
		framing.modifiers = "spring bones and other skeleton modifiers played through the %s s before each frame" % ANIMATION_SETTLE_SECONDS
	return {
		"framing": framing,
		"pose": posed,
		"before_frame": func(index: int) -> void: camera.global_position = base + offsets[index],
	}

## The bone root motion comes from: root_bone if given, else the one an
## AnimationTree's root_motion_track names, else the first skeleton's top
## bone. {} without skeletons; {"error"} for an unknown root_bone.
func _animation_root_bone(instance: Node, skeletons: Array[Skeleton3D], bone_name: String) -> Dictionary:
	if skeletons.is_empty():
		return {"error": "The scene has no Skeleton3D, so there is no bone %s." % bone_name} if not bone_name.is_empty() else {}
	var wanted := bone_name
	var tree_track := ""
	if wanted.is_empty():
		for tree: AnimationTree in instance.find_children("*", "AnimationTree", true, false):
			if tree.root_motion_track.get_subname_count() > 0:
				wanted = tree.root_motion_track.get_subname(0)
				tree_track = str(tree.root_motion_track)
				break
	for skeleton in skeletons:
		var bone := skeleton.find_bone(wanted) if not wanted.is_empty() else -1
		if bone >= 0:
			return {"skeleton": skeleton, "bone": bone, "name": wanted}
	if not bone_name.is_empty():
		return {"error": "No skeleton in the scene has a bone %s." % bone_name}
	var top := skeletons[0].get_parentless_bones()
	if top.is_empty():
		return {}
	var found := {"skeleton": skeletons[0], "bone": top[0], "name": skeletons[0].get_bone_name(top[0])}
	if not tree_track.is_empty():
		found.note = "the AnimationTree's root_motion_track %s names a bone the skeleton does not have, so its top bone was used" % tree_track
	return found

## The character's own axes, its front +Z: those of its first skeleton, as
## imported humanoids face +Z in their skeleton's space even when the skeleton
## node is turned; the scene root's without a skeleton. Upright, so views stay level.
func _character_basis(root: Node3D, skeletons: Array[Skeleton3D]) -> Basis:
	var facing := (skeletons[0].global_basis.z if not skeletons.is_empty() else root.global_basis.z) * Vector3(1, 0, 1)
	if facing.length() < 0.001:
		facing = Vector3.BACK
	var forward := facing.normalized()
	return Basis(Vector3.UP.cross(forward), Vector3.UP, forward)

## The global box around a 3D scene as it is posed now: the joints of its
## skeletons, padded since skin reaches past them (the head's top, the hands),
## and the geometry not bent by a skeleton. A skinned mesh's own box is its
## rest pose, so it is left out.
func _posed_bounds(root: Node3D, skeletons: Array[Skeleton3D]) -> AABB:
	# Attachments follow their bone only when the skeleton next updates, a
	# frame after a seek; a held sword would otherwise be measured where it was.
	for attachment: BoneAttachment3D in root.find_children("*", "BoneAttachment3D", true, false):
		attachment.on_skeleton_update()
	var box := AABB()
	var found := false
	for skeleton in skeletons:
		for bone in skeleton.get_bone_count():
			var point := skeleton.global_transform * skeleton.get_bone_global_pose(bone).origin
			box = AABB(point, Vector3.ZERO) if not found else box.expand(point)
			found = true
	if found:
		box = box.grow(maxf(box.size.x, maxf(box.size.y, box.size.z)) * 0.08)
	for geometry: GeometryInstance3D in root.find_children("*", "GeometryInstance3D", true, false):
		if not geometry.is_visible_in_tree() or _is_skinned(geometry):
			continue
		var local := geometry.get_aabb()
		if local.size == Vector3.ZERO:
			continue
		var global := geometry.global_transform * local
		box = global if not found else box.merge(global)
		found = true
	return box if found else AABB(root.global_position - Vector3.ONE, Vector3.ONE * 2)

func _is_skinned(geometry: GeometryInstance3D) -> bool:
	var mesh := geometry as MeshInstance3D
	return mesh != null and (mesh.skin != null or mesh.get_node_or_null(mesh.skeleton) is Skeleton3D)

## A bone and every bone under it, such as a hand and its fingers.
func _bone_and_below(skeleton: Skeleton3D, bone: int) -> PackedInt32Array:
	var bones := PackedInt32Array([bone])
	var i := 0
	while i < bones.size():
		bones.append_array(skeleton.get_bone_children(bones[i]))
		i += 1
	return bones

## The global box around some bones' joints as posed now, padded since the
## skin reaches past them (a fingertip past its last joint): by a third of the
## box's size, and at least 8 cm.
func _bones_bounds(skeleton: Skeleton3D, bones: PackedInt32Array) -> AABB:
	var box := AABB(skeleton.global_transform * skeleton.get_bone_global_pose(bones[0]).origin, Vector3.ZERO)
	for bone in bones:
		box = box.expand(skeleton.global_transform * skeleton.get_bone_global_pose(bone).origin)
	return box.grow(maxf(0.08, maxf(box.size.x, maxf(box.size.y, box.size.z)) / 3.0))

## Points an orthographic camera at box from direction (from the box toward
## the camera), its view just fitting the box with a small margin. Looking
## straight down or up, up_hint is the image's up.
func _aim_orthographic(camera: Camera3D, box: AABB, direction: Vector3, view_size: Vector2, up_hint := Vector3.FORWARD) -> void:
	var centre := box.get_center()
	var distance := box.size.length() + 1.0
	var up := Vector3.UP if absf(direction.dot(Vector3.UP)) < 0.99 else up_hint
	camera.look_at_from_position(centre + direction * distance, centre, up)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	# The box as the camera sees it, across and up.
	var low := Vector2(INF, INF)
	var high := -low
	for i in 8:
		var corner := box.get_endpoint(i) - centre
		var seen := Vector2(corner.dot(camera.global_basis.x), corner.dot(camera.global_basis.y))
		low = low.min(seen)
		high = high.max(seen)
	var middle := (low + high) / 2.0
	camera.global_position += camera.global_basis.x * middle.x + camera.global_basis.y * middle.y
	var extent := (high - low) * 1.05
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.size = maxf(extent.y, extent.x * view_size.y / view_size.x)
	camera.near = 0.05
	camera.far = distance * 2.0 + box.size.length()

func _size_text(size: Vector3) -> String:
	return "%s x %s x %s" % [snappedf(size.x, 0.01), snappedf(size.y, 0.01), snappedf(size.z, 0.01)]

## The view a 3D render looks from (see ANIMATION_VIEWS): {"view", "camera":
## the scene's first Camera3D for "camera"} or {"error"}. By default the
## scene's camera when it has one, else three_quarter.
func _pick_view(root: Node3D, requested: Variant) -> Dictionary:
	var cameras := root.find_children("*", "Camera3D", true, false)
	var view := String(requested) if requested != null else ("camera" if not cameras.is_empty() else "three_quarter")
	var views := ["camera"] + ANIMATION_VIEWS.keys()
	if not view in views:
		return {"error": "view is one of %s." % ", ".join(views)}
	if view == "camera" and cameras.is_empty():
		return {"error": "The scene has no Camera3D; pick one of the views %s." % ", ".join(ANIMATION_VIEWS.keys())}
	return {"view": view, "camera": cameras[0] if view == "camera" else null}

## Frames a 3D scene for scene_screenshot: its own camera, or an orthographic
## one from that view fitted to the scene as it is posed (see _posed_bounds()).
## Returns {"framing"} or {"error"}.
func _frame_3d(viewport: SubViewport, root: Node3D, requested_view: Variant) -> Dictionary:
	var picked := _pick_view(root, requested_view)
	if picked.has("error"):
		return picked
	var camera: Camera3D = picked.camera
	var framing := {}
	if camera != null:
		framing.view = "scene camera %s" % root.get_path_to(camera)
	else:
		var skeletons: Array[Skeleton3D] = []
		skeletons.assign(root.find_children("*", "Skeleton3D", true, false))
		var box := _posed_bounds(root, skeletons)
		camera = Camera3D.new()
		viewport.add_child(camera)
		var character := _character_basis(root, skeletons)
		_aim_orthographic(camera, box, (character * ANIMATION_VIEWS[picked.view]).normalized(), Vector2(viewport.size), -character.z)
		framing.view = "%s, orthographic" % picked.view
		framing.fit = "the scene as posed, %s m" % _size_text(box.size)
	camera.make_current()
	var lit := _light_if_unlit(viewport, root, camera)
	if not lit.is_empty():
		framing.lighting = lit
	return {"framing": framing}

const TRACK_TYPES := {
	Animation.TYPE_VALUE: "value", Animation.TYPE_POSITION_3D: "position_3d", Animation.TYPE_ROTATION_3D: "rotation_3d",
	Animation.TYPE_SCALE_3D: "scale_3d", Animation.TYPE_BLEND_SHAPE: "blend_shape", Animation.TYPE_METHOD: "method",
	Animation.TYPE_BEZIER: "bezier", Animation.TYPE_AUDIO: "audio", Animation.TYPE_ANIMATION: "animation",
}
const ROOT_MOTION_SAMPLES_PER_SECOND := 30

## Facts about an animation for animation_frames' reply: length, loop mode,
## tracks by type and, for a 3D character, the root bone's motion over the
## whole clip (see _animation_root_bone()), sampled 30 times a second.
func _animation_info(player: AnimationPlayer, animation_name: StringName, instance: Node, pose: Callable, root_bone: String) -> Dictionary:
	var animation := player.get_animation(animation_name)
	var tracks := {}
	for track in animation.get_track_count():
		var type_name: String = TRACK_TYPES.get(animation.track_get_type(track), "other")
		tracks[type_name] = tracks.get(type_name, 0) + 1
	var info := {
		"length": animation.length,
		"loop_mode": ["none", "linear", "ping_pong"][animation.loop_mode],
		"step": animation.step,
		"track_count": animation.get_track_count(),
		"tracks": tracks,
	}
	if not instance is Node3D:
		return info
	var skeletons: Array[Skeleton3D] = []
	skeletons.assign(instance.find_children("*", "Skeleton3D", true, false))
	var root := _animation_root_bone(instance, skeletons, root_bone)
	if root.is_empty() or root.has("error"):
		return info
	var skeleton: Skeleton3D = root.skeleton
	var samples := maxi(2, ceili(animation.length * ROOT_MOTION_SAMPLES_PER_SECOND) + 1)
	var start := Vector3.ZERO
	var last := Vector3.ZERO
	var path := 0.0
	var stray := 0.0
	for i in samples:
		pose.call(animation.length * i / (samples - 1))
		var at := skeleton.global_transform * skeleton.get_bone_global_pose(root.bone).origin
		if i == 0:
			start = at
		else:
			path += Vector2(at.x - last.x, at.z - last.z).length()
		stray = maxf(stray, Vector2(at.x - start.x, at.z - start.z).length())
		last = at
	var travel := Vector2(last.x - start.x, last.z - start.z).length()
	info.root_motion = {
		"bone": root.name,
		# Sideways, in meters; speed is the start-to-end distance over the length.
		"start_to_end": snappedf(travel, 0.001),
		"speed": snappedf(travel / animation.length, 0.001) if animation.length > 0.0 else 0.0,
		"path_length": snappedf(path, 0.001),
		"max_stray": snappedf(stray, 0.001),
		"vertical_change": snappedf(last.y - start.y, 0.001),
	}
	if root.has("note"):
		info.root_motion.note = root.note
	return info

## Lights a 3D scene that has no light of its own, which would otherwise
## render nearly black, whichever camera shows it: a sun from over the
## camera's shoulder, so the side shown is lit. A scene with lights keeps its
## own lighting. Returns what was done, for the reply's framing, or "".
func _light_if_unlit(viewport: SubViewport, root: Node3D, camera: Camera3D) -> String:
	for light: Light3D in root.find_children("*", "Light3D", true, false):
		if light.is_visible_in_tree():
			return ""
	var sun := DirectionalLight3D.new()
	viewport.add_child(sun)
	sun.global_basis = camera.global_basis * Basis.from_euler(Vector3(deg_to_rad(-35), deg_to_rad(30), 0))
	return "the scene has no light, so a sun was added behind the camera"

# --- Tile info ---------------------------------------------------------------

## Shows a texture enlarged with a pixel grid and coordinates (see texture_view.gd).
func _texture_view(args: Dictionary) -> Dictionary:
	var path := String(args.get("path", ""))
	if path.is_empty():
		return {"error": "Pass the path of a texture, or of a resource that uses one."}
	if not path.begins_with("uid://"):
		path = _res_path(path)
	return texture_view_script.new().render(path, String(args.get("property", "")), args.get("rect"), int(args.get("grid", 16)),
			float(args.get("zoom", 0)), int(args.get("max_size", 1280)), bool(args.get("sprites", false)), _screenshot_path())

## Reports tiles of a scene's TileMapLayers (the scene being edited by default):
## with position, the tile at that world point on every layer, topmost last;
## with layer, a summary of the tiles it uses and its TileSet's sources,
## terrains and custom data layers; with layer and cells ([x, y, width, height]
## in cells), the tiles in that block.
func _tile_info(scene_path: String, position: Variant, layer_path: String, cells: Variant) -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	var loaded: Node = null
	if not scene_path.is_empty() and (root == null or root.scene_file_path != _res_path(scene_path)):
		scene_path = _res_path(scene_path)
		var packed := ResourceLoader.load(scene_path) as PackedScene
		if packed == null:
			return {"error": "No scene at %s." % scene_path}
		# In the tree, so world positions work; only @tool scripts run in the editor.
		loaded = packed.instantiate()
		add_child(loaded)
		root = loaded
	if root == null:
		return {"error": "No scene is being edited; pass scene."}
	var reply := _tile_report(root, position, layer_path, cells)
	if loaded != null:
		loaded.queue_free()
	return reply

func _tile_report(root: Node, position: Variant, layer_path: String, cells: Variant) -> Dictionary:
	var layers: Array[TileMapLayer] = []
	if layer_path.is_empty():
		for node in root.find_children("*", "TileMapLayer", true, false):
			layers.append(node)
		if root is TileMapLayer:
			layers.push_front(root)
	else:
		var node := root.get_node_or_null(layer_path)
		if not node is TileMapLayer:
			return {"error": "%s is not a TileMapLayer in %s." % [layer_path, root.scene_file_path]}
		layers.append(node)
	if layers.is_empty():
		return {"error": "%s has no TileMapLayers." % root.scene_file_path}
	if position is Array and position.size() == 2:
		var point := Vector2(position[0], position[1])
		var found := []
		var empty := 0
		for layer in layers:
			if layer.tile_set == null:
				continue
			var tile := _tile_details(layer, layer.local_to_map(layer.to_local(point)))
			if tile.has("empty"):
				empty += 1
				continue
			tile.layer = str(root.get_path_to(layer))
			found.append(tile)
		return {"position": [point.x, point.y], "layers": found, "empty_layers": empty, "note": "Layers with a tile there, in draw order; the last is on top."}
	if layers.size() != 1:
		return {"error": "Pass position, or layer (optionally with cells)."}
	var layer := layers[0]
	if cells is Array and cells.size() == 4:
		var block := Rect2i(cells[0], cells[1], cells[2], cells[3])
		if block.get_area() > 400:
			return {"error": "That block has %d cells; ask for at most 400." % block.get_area()}
		var tiles := []
		for y in range(block.position.y, block.end.y):
			for x in range(block.position.x, block.end.x):
				var tile := _tile_details(layer, Vector2i(x, y))
				if tile.has("source_id"):
					tiles.append(tile)
		return {"layer": layer_path, "cells": cells, "tiles": tiles}
	return _layer_summary(layer, layer_path)

## One cell: its source, atlas coordinates, terrain and custom data.
func _tile_details(layer: TileMapLayer, cell: Vector2i) -> Dictionary:
	var tile := {"cell": [cell.x, cell.y]}
	var source_id := layer.get_cell_source_id(cell)
	if source_id == -1 or layer.tile_set == null:
		tile.empty = true
		return tile
	var tile_set := layer.tile_set
	var atlas := layer.get_cell_atlas_coords(cell)
	var alternative := layer.get_cell_alternative_tile(cell)
	tile.source_id = source_id
	tile.atlas_coords = [atlas.x, atlas.y]
	if alternative != 0:
		tile.alternative = alternative
	var source := tile_set.get_source(source_id) if tile_set.has_source(source_id) else null
	if source is TileSetAtlasSource and source.texture != null:
		tile.texture = source.texture.resource_path
	elif source is TileSetScenesCollectionSource:
		var scene: PackedScene = source.get_scene_tile_scene(alternative)
		tile.scene = scene.resource_path if scene != null else ""
	var data := layer.get_cell_tile_data(cell)
	if data == null:
		return tile
	if data.terrain_set >= 0:
		tile.terrain_set = data.terrain_set
		tile.terrain = _terrain_name(tile_set, data.terrain_set, data.terrain)
		var peering := {}
		for side in TERRAIN_SIDES:
			if data.is_valid_terrain_peering_bit(TERRAIN_SIDES[side]):
				var terrain := data.get_terrain_peering_bit(TERRAIN_SIDES[side])
				if terrain >= 0:
					peering[side] = _terrain_name(tile_set, data.terrain_set, terrain)
		if not peering.is_empty():
			tile.terrain_peering = peering
	var custom := {}
	for i in tile_set.get_custom_data_layers_count():
		var value: Variant = data.get_custom_data_by_layer_id(i)
		if value != null:
			custom[tile_set.get_custom_data_layer_name(i)] = code_runner_script.to_json(value)
	if not custom.is_empty():
		tile.custom_data = custom
	var collision := 0
	for i in tile_set.get_physics_layers_count():
		collision += data.get_collision_polygons_count(i)
	if collision > 0:
		tile.collision_polygons = collision
	return tile

const TERRAIN_SIDES := {
	"top": TileSet.CELL_NEIGHBOR_TOP_SIDE, "top_right": TileSet.CELL_NEIGHBOR_TOP_RIGHT_CORNER,
	"right": TileSet.CELL_NEIGHBOR_RIGHT_SIDE, "bottom_right": TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_CORNER,
	"bottom": TileSet.CELL_NEIGHBOR_BOTTOM_SIDE, "bottom_left": TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_CORNER,
	"left": TileSet.CELL_NEIGHBOR_LEFT_SIDE, "top_left": TileSet.CELL_NEIGHBOR_TOP_LEFT_CORNER,
}

func _terrain_name(tile_set: TileSet, terrain_set: int, terrain: int) -> String:
	if terrain < 0:
		return "(none)"
	return tile_set.get_terrain_name(terrain_set, terrain) if terrain < tile_set.get_terrains_count(terrain_set) else str(terrain)

## A layer's used tiles grouped by source, atlas coordinates and terrain, with
## its TileSet's sources, terrains and custom data layers.
func _layer_summary(layer: TileMapLayer, layer_path: String) -> Dictionary:
	var groups := {}
	for cell in layer.get_used_cells():
		var source_id := layer.get_cell_source_id(cell)
		var atlas := layer.get_cell_atlas_coords(cell)
		var data := layer.get_cell_tile_data(cell)
		var key := "%d %s %d" % [source_id, atlas, layer.get_cell_alternative_tile(cell)]
		if not groups.has(key):
			var group := {"source_id": source_id, "atlas_coords": [atlas.x, atlas.y], "count": 0}
			if data != null and data.terrain_set >= 0:
				group.terrain = _terrain_name(layer.tile_set, data.terrain_set, data.terrain)
			groups[key] = group
		groups[key].count += 1
	var used: Array = groups.values()
	used.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.count > b.count)
	var bounds := layer.get_used_rect()
	var reply := {
		"layer": layer_path,
		"cells_used": layer.get_used_cells().size(),
		"used_rect": [bounds.position.x, bounds.position.y, bounds.size.x, bounds.size.y],
		"tile_size": [layer.tile_set.tile_size.x, layer.tile_set.tile_size.y] if layer.tile_set != null else null,
		"tiles": used.slice(0, 100),
	}
	if used.size() > 100:
		reply.note = "Showing the 100 most used of %d different tiles." % used.size()
	var tile_set := layer.tile_set
	if tile_set != null:
		var sources := []
		for i in tile_set.get_source_count():
			var id := tile_set.get_source_id(i)
			var source := tile_set.get_source(id)
			var entry := {"id": id, "type": source.get_class()}
			if source is TileSetAtlasSource and source.texture != null:
				entry.texture = source.texture.resource_path
				entry.tiles = source.get_tiles_count()
			sources.append(entry)
		var terrains := []
		for set_index in tile_set.get_terrain_sets_count():
			var names := []
			for terrain in tile_set.get_terrains_count(set_index):
				names.append(tile_set.get_terrain_name(set_index, terrain))
			terrains.append({"terrain_set": set_index, "terrains": names})
		var custom := []
		for i in tile_set.get_custom_data_layers_count():
			custom.append({"name": tile_set.get_custom_data_layer_name(i), "type": type_string(tile_set.get_custom_data_layer_type(i))})
		reply.tile_set = {"path": tile_set.resource_path, "sources": sources, "terrain_sets": terrains, "custom_data_layers": custom}
	return reply

func _res_path(path: String) -> String:
	return path if path.begins_with("res://") else "res://" + path.trim_prefix("/")
