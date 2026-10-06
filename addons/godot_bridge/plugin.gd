@tool
extends EditorPlugin
## Starts the bridge server that the MCP server (mcp/server.py) talks to, and
## the debugger plugin that reaches games started from this editor through the
## GodotBridgeGame autoload (game/game_loader.gd).
## Headless editors, such as `--headless --import`, never start a server, so
## command-line runs cannot replace or disturb this editor's connection.
##
## The bridge scripts are loaded as detached copies (read from disk, with no
## resource path), so the editor never hot-reloads them: reloading a script
## while it is paused in the middle of a request aborts Godot. The reload_bridge
## tool applies edits to them instead (see load_bridge_scripts() and
## swap_bridge()); edits to this file still need the plugin turned off and on.

const SCRIPTS_DIR := "res://addons/godot_bridge/"
const GAME_AUTOLOAD := "GodotBridgeGame"
## The scripts the editor side runs, by the name start_bridge() expects.
const BRIDGE_SCRIPTS := {
	"server": "bridge_server.gd",
	"debugger": "debugger_plugin.gd",
	"log_capture": "log_capture.gd",
	"code_runner": "code_runner.gd",
	"texture_view": "texture_view.gd",
}
## Scripts a game loads when it starts, checked by a reload so a broken one is
## caught before the next game_play.
const GAME_SCRIPTS := ["game/bridge_game.gd"]

var server: Node
var debugger: EditorDebuggerPlugin

func _enable_plugin() -> void:
	add_autoload_singleton(GAME_AUTOLOAD, SCRIPTS_DIR + "game/game_loader.gd")

func _disable_plugin() -> void:
	remove_autoload_singleton(GAME_AUTOLOAD)

func _enter_tree() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var loaded := load_bridge_scripts()
	if loaded.has("error"):
		push_error("Godot Bridge: %s" % loaded.error)
		return
	_start_bridge(loaded.scripts)
	scene_changed.connect(func(_root: Node) -> void: server.note_open_scenes())
	scene_saved.connect(func(path: String) -> void: server.note_scene_saved(path))
	scene_closed.connect(func(path: String) -> void: server.forget_scene(path))

func _exit_tree() -> void:
	if debugger != null:
		debugger.stop_watching()
		remove_debugger_plugin(debugger)
	if is_instance_valid(server):
		server.queue_free()

## Compiles fresh detached copies of the bridge's scripts. Returns {"scripts":
## name -> GDScript} or, when any fails, {"error", "logs"} with the compile
## errors, the files named rather than their detached paths.
func load_bridge_scripts() -> Dictionary:
	var capture: Logger = server.log_capture_script.new() if is_instance_valid(server) else null
	if capture != null:
		OS.add_logger(capture)
	var scripts := {}
	var failed := PackedStringArray()
	# Detached path -> file name, for the compile errors.
	var paths := {}
	for key in BRIDGE_SCRIPTS:
		var script := _load_detached(BRIDGE_SCRIPTS[key], paths)
		if script == null:
			failed.append(BRIDGE_SCRIPTS[key])
		else:
			scripts[key] = script
	for file_name in GAME_SCRIPTS:
		if _load_detached(file_name, paths) == null:
			failed.append(file_name)
	var logs := PackedStringArray()
	if capture != null:
		OS.remove_logger(capture)
		for line in capture.take():
			# _load_detached()'s own note; the error message already says it.
			if line.begins_with("ERROR: Godot Bridge:"):
				continue
			for path in paths:
				line = line.replace(path, paths[path])
			logs.append(line)
	if failed.is_empty():
		return {"scripts": scripts}
	return {"error": "%s failed to compile, so the bridge was left as it is." % ", ".join(failed), "logs": logs}

## Replaces the running bridge with one built from scripts (from
## load_bridge_scripts()), handing over its state: the game it is connected
## to, a background game, kept editor_run results and the editor log. The new
## server listens on a new port and rewrites the connection file, which the MCP
## server reads on every call.
func swap_bridge(scripts: Dictionary) -> void:
	var old_server := server
	var old_debugger := debugger
	var server_state: Dictionary = old_server.export_state()
	var debugger_state: Dictionary = old_debugger.export_state()
	old_debugger.stop_watching()
	remove_debugger_plugin(old_debugger)
	# Frees the name for the new server, which would otherwise be renamed.
	old_server.name = "GodotBridgeServerReplaced"
	_start_bridge(scripts)
	debugger.import_state(debugger_state)
	server.import_state(server_state)
	# After the new server wrote its connection file, so the old one leaves it.
	old_server.get_parent().remove_child(old_server)
	old_server.free()

func _start_bridge(scripts: Dictionary) -> void:
	debugger = scripts.debugger.new()
	add_debugger_plugin(debugger)
	server = scripts.server.new()
	server.name = "GodotBridgeServer"
	server.plugin = self
	server.log_capture_script = scripts.log_capture
	server.code_runner_script = scripts.code_runner
	server.texture_view_script = scripts.texture_view
	server.debugger = debugger
	server.log_capture_script.set_bridge_scripts(scripts.values())
	add_child(server)

func _load_detached(file_name: String, paths := {}) -> GDScript:
	var script := GDScript.new()
	paths["gdscript://%d.gd" % script.get_instance_id()] = file_name
	script.source_code = FileAccess.get_file_as_string(SCRIPTS_DIR + file_name)
	if script.reload() != OK:
		push_error("Godot Bridge: %s failed to compile." % file_name)
		return null
	return script
