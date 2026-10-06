@tool
extends RefCounted
## Registers the MCP server (mcp/server.py) in the project's .mcp.json, which
## Claude Code and other MCP clients read when started in the project folder.
## The server's path is relative to the project, so the file works for anyone
## who clones it.

const FILE_NAME := ".mcp.json"
const SERVER_NAME := "godot-bridge"
const SERVER_SCRIPT := "mcp/server.py"

## Adds the server to project_dir's .mcp.json unless an entry already runs it,
## creating the file if needed. addon_dir is the addon's folder relative to the
## project, e.g. "addons/godot_bridge". Returns a line for the editor's output,
## starting with "WARNING: " when the file was left as it was because of a problem.
static func register(project_dir: String, addon_dir: String) -> String:
	var path := project_dir.path_join(FILE_NAME)
	var script := addon_dir.path_join(SERVER_SCRIPT)
	var config := {}
	if FileAccess.file_exists(path):
		var json := JSON.new()
		if json.parse(FileAccess.get_file_as_string(path)) != OK or not json.data is Dictionary:
			return "WARNING: %s is not valid JSON, so the MCP server was not added. Add it with: %s" % [FILE_NAME, _manual_command(script)]
		config = _whole_numbers(json.data)
	if not config.get("mcpServers") is Dictionary:
		config.mcpServers = {}
	var servers: Dictionary = config.mcpServers
	for key in servers:
		var server: Variant = servers[key]
		if server is Dictionary and str(server.get("args", [])).contains(script):
			return ""
	var name := SERVER_NAME
	var number := 2
	while servers.has(name):
		name = "%s-%d" % [SERVER_NAME, number]
		number += 1
	var python := find_python()
	var note := ""
	if python.is_empty():
		python = "python" if OS.get_name() == "Windows" else "python3"
		note = " Python 3 was not found: install it, or change \"command\" there to your Python 3."
	servers[name] = {"command": python, "args": [script]}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return "WARNING: Could not write %s (%s). Add the MCP server with: %s" % [FILE_NAME, error_string(FileAccess.get_open_error()), _manual_command(script)]
	file.store_string(JSON.stringify(config, "  ", false) + "\n")
	file.close()
	return "Added the \"%s\" MCP server to %s. Start your agent in the project folder to use it.%s" % [name, FILE_NAME, note]

## The first Python 3 command that runs, or "" when none does. Each is run, not
## just looked up, because Windows puts stand-ins for python and python3 on PATH
## that only open the Microsoft Store.
static func find_python() -> String:
	var candidates := ["py", "python", "python3"] if OS.get_name() == "Windows" else ["python3", "python"]
	for command in candidates:
		var output := []
		if OS.execute(command, ["--version"], output, true) == 0 and "".join(output).begins_with("Python 3"):
			return command
	return ""

## value with whole-number floats turned into ints: Godot's JSON reads every
## number as a float and would write 30000 back as 30000.0.
static func _whole_numbers(value: Variant) -> Variant:
	if value is float and value == floorf(value) and absf(value) < 1e15:
		return int(value)
	if value is Dictionary:
		var result := {}
		for key in value:
			result[key] = _whole_numbers(value[key])
		return result
	if value is Array:
		return value.map(_whole_numbers)
	return value

static func _manual_command(script: String) -> String:
	return "claude mcp add %s -- python3 %s" % [SERVER_NAME, script]
