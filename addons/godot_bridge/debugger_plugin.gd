@tool
extends EditorDebuggerPlugin
## The editor's end of the game channel. Games started from the editor connect
## to its debugger; their bridge helper (game/bridge_game.gd) announces itself
## with "godot_bridge:ready". Requests go to that session and replies are kept
## in `replies` until the bridge server collects them.

const PREFIX := "godot_bridge"

## The debugger session of the game whose helper announced itself, or -1.
var game_session := -1
## What the helper reported on start: scene, window and viewport size.
var game_info := {}
## Request id -> reply Dictionary.
var replies := {}
## Session id -> why that game is stopped in the debugger: {"reason": the error
## or "Breakpoint", "stack": ["res://x.gd:12 in func", ...]}, while it is stopped.
var _breaks := {}
## The last lines the most recent game printed (from its Debugger panel tab),
## kept after it ends so game_wait can tell why it quit.
var _output: PackedStringArray = []
var _output_session := -1
const OUTPUT_KEPT := 200
## Path of code compiled by game_run (and game_play's setup) in the current
## game -> how many lines the wrapper put before it (see code_runner.compile()).
var _game_code := {}
## [node, signal, callable] connected to the Debugger panel, undone by stop_watching().
var _watched: Array = []

func _has_capture(capture: String) -> bool:
	return capture == PREFIX

func _capture(message: String, data: Array, session_id: int) -> bool:
	match message.trim_prefix(PREFIX + ":"):
		"ready":
			game_session = session_id
			game_info = data[0] if not data.is_empty() and data[0] is Dictionary else {}
		"reply":
			if data.size() >= 2:
				replies[int(data[0])] = data[1]
		"compiled":
			if data.size() >= 2:
				_game_code[String(data[0])] = int(data[1])
		_:
			return false
	return true

func _setup_session(session_id: int) -> void:
	var session := get_session(session_id)
	session.stopped.connect(func() -> void:
		_breaks.erase(session_id)
		if game_session == session_id:
			game_session = -1
			game_info = {})
	session.continued.connect(func() -> void: _breaks.erase(session_id))
	# Session ids are reused by every game, so a new game starts a new output.
	session.started.connect(func() -> void:
		_output_session = session_id
		_output = []
		_game_code = {})
	_watch_breaks.call_deferred(session_id)

## The error and stack of a break reach the session's ScriptEditorDebugger (its
## tab in the Debugger panel), not plugins, so they are read from its signals.
func _watch_breaks(session_id: int) -> void:
	var editor_debugger := _editor_debugger(session_id)
	if editor_debugger == null or _watched.any(func(entry: Array) -> bool: return entry[0] == editor_debugger):
		return
	_watch(editor_debugger, &"breaked", func(really_did: bool, _can_debug: bool, reason: String, _has_stackdump: bool) -> void:
		if really_did:
			_breaks[session_id] = {"reason": reason, "stack": []}
		else:
			_breaks.erase(session_id))
	_watch(editor_debugger, &"output", func(message: String, _level: int) -> void:
		if session_id != _output_session:
			return
		_output.append_array(message.strip_edges(false, true).split("\n"))
		if _output.size() > OUTPUT_KEPT:
			_output = _output.slice(_output.size() - OUTPUT_KEPT))
	_watch(editor_debugger, &"stack_dump", func(frames: Array) -> void:
		if not _breaks.has(session_id):
			return
		var stack := PackedStringArray()
		for frame in frames:
			var file := String(frame.get("file", ""))
			var line := int(frame.get("line", 0))
			# Code sent with game_run is "code", at its own lines; other
			# scripts without a file are the bridge's, loaded detached.
			if _game_code.has(file):
				line -= int(_game_code[file])
				file = "code"
			elif file.begins_with("gdscript://"):
				file = "(bridge code)"
			var function := String(frame.get("function", ""))
			stack.append("%s:%d%s" % [file, line, " in " + function if not function.is_empty() else ""])
		_breaks[session_id].stack = stack)

func _watch(node: Node, signal_name: StringName, callable: Callable) -> void:
	node.connect(signal_name, callable)
	_watched.append([node, signal_name, callable])

## What a reloaded bridge's debugger plugin takes over (see plugin.gd swap_bridge()).
func export_state() -> Dictionary:
	return {
		"game_session": game_session,
		"game_info": game_info,
		"replies": replies,
		"breaks": _breaks,
		"output": _output,
		"output_session": _output_session,
		"game_code": _game_code,
	}

func import_state(state: Dictionary) -> void:
	game_session = state.game_session
	game_info = state.game_info
	replies = state.replies
	_breaks = state.breaks
	_output = state.output
	_output_session = state.output_session
	_game_code = state.game_code

## Disconnects from the Debugger panel; the plugin calls it before removing this.
func stop_watching() -> void:
	for entry in _watched:
		if is_instance_valid(entry[0]) and entry[0].is_connected(entry[1], entry[2]):
			entry[0].disconnect(entry[1], entry[2])
	_watched.clear()

## The Debugger panel tab of a session: the session id is its index among the tabs.
func _editor_debugger(session_id: int) -> Node:
	for panel in EditorInterface.get_base_control().find_children("*", "EditorDebuggerNode", true, false):
		for tabs in panel.find_children("*", "TabContainer", false, false):
			if session_id < tabs.get_child_count() and tabs.get_child(session_id).get_class() == "ScriptEditorDebugger":
				return tabs.get_child(session_id)
	return null

## Sends a request to the game; false when no helper is connected.
func send(kind: String, data: Array) -> bool:
	if game_session < 0:
		return false
	var session := get_session(game_session)
	if session == null or not session.is_active():
		return false
	session.send_message(PREFIX + ":" + kind, data)
	return true

## Sends one of Godot's own debugger messages (no bridge prefix), such as
## "set_ignore_error_breaks".
func send_core(message: String, data: Array) -> void:
	var session := get_session(game_session) if game_session >= 0 else null
	if session != null and session.is_active():
		session.send_message(message, data)

## The last count lines of output from the most recent game.
func recent_output(count: int) -> PackedStringArray:
	return _output.slice(maxi(0, _output.size() - count))

## Why the game is paused in the editor's debugger (see _breaks), or {}.
func game_break() -> Dictionary:
	return _breaks.get(game_session, {}) if is_game_paused() else {}

## Why the most recently started game is paused in the editor's debugger, or
## {}. Unlike game_break(), it works before the game's helper reports in, as
## when the main scene stops at an error while it loads.
func starting_break() -> Dictionary:
	var session := get_session(_output_session) if _output_session >= 0 else null
	if session == null or not session.is_breaked():
		return {}
	return _breaks.get(_output_session, {"reason": "unknown", "stack": []})

## Whether the game is paused in the editor's debugger.
func is_game_paused() -> bool:
	var session := get_session(game_session) if game_session >= 0 else null
	return session != null and session.is_breaked()
