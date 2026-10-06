extends Node
## Autoload added by the Godot Bridge plugin. In a game started from the editor
## (the debugger is attached) it starts the bridge's game helper; anywhere
## else, such as command-line runs, tests and exported builds, it does nothing.
## The helper is loaded as a detached copy so live script reloads can never
## replace it in the middle of a request.

const SCRIPTS_DIR := "res://addons/godot_bridge/"

func _ready() -> void:
	if not EngineDebugger.is_active():
		return
	var helper_script := _load_detached("game/bridge_game.gd")
	if helper_script == null:
		return
	var helper: Node = helper_script.new()
	helper.name = "BridgeGame"
	helper.code_runner_script = _load_detached("code_runner.gd")
	helper.log_capture_script = _load_detached("log_capture.gd")
	helper.texture_view_script = _load_detached("texture_view.gd")
	if helper.log_capture_script != null:
		helper.log_capture_script.set_bridge_scripts([helper_script, helper.code_runner_script, helper.log_capture_script, helper.texture_view_script])
	add_child(helper)

func _load_detached(file_name: String) -> GDScript:
	var source := FileAccess.get_file_as_string(SCRIPTS_DIR + file_name)
	if source.is_empty():
		return null
	var script := GDScript.new()
	script.source_code = source
	return script if script.reload() == OK else null
