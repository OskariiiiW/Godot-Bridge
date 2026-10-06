extends RefCounted
## Compiles and runs GDScript sent by the assistant, in the editor or (later)
## the running game. Code that defines `func run(ctx)` runs as written; any
## other code becomes the body of run(ctx), so statements, loops, load() and
## engine singletons all work. `return` sends a value back.

## Passed to run(ctx): ctx.log() adds lines to the reply. ctx.cancelled turns
## true when the run is cancelled, for code that defines its own class (wrapped
## code is simply stopped at its next await). In a game, ctx.draw_2d(),
## ctx.draw_3d() and ctx.clear_overlays() add debug drawings that outlast the
## run (see bridge_game.gd); `host` is the game's bridge helper, null in the editor.
## In the editor, ctx.pose() poses a scene for measuring, and `bridge` is the
## bridge server itself (bridge_server.gd, the GodotBridgeServer node), for
## inspecting or debugging the bridge from editor_run; null in a game.
class Context extends RefCounted:
	var output: PackedStringArray = []
	var cancelled := false
	var host: Object
	var bridge: Object
	## Viewports ctx.pose() made, freed by the bridge when the run ends.
	var posed_viewports: Array[Node] = []
	## Where the running code was compiled ({path, line_offset}, see compile()),
	## so overlays can report errors in their callbacks as lines of the code.
	var source := {}

	func log(value: Variant) -> void:
		output.append(str(value))

	## Draws over the 2D world every frame (or once, unless every_frame) until
	## cleared: draw(canvas) gets a Node2D in world coordinates to call
	## draw_rect(), draw_line() and the other CanvasItem draw methods on. A
	## parent node puts it in that node's coordinates (and its viewport).
	## The same name replaces an earlier overlay.
	func draw_2d(name: String, draw: Callable, every_frame := true, parent: Node = null) -> bool:
		return _overlay("add_overlay_2d", [name, draw, every_frame, parent, source])

	## Draws in the 3D world every frame (or once, unless every_frame) until
	## cleared, unlit and through walls: draw(painter) gets a painter with
	## line(), triangle(), quad(), box() and cross() (see bridge_game.gd).
	func draw_3d(name: String, draw: Callable, every_frame := true, parent: Node = null) -> bool:
		return _overlay("add_overlay_3d", [name, draw, every_frame, parent, source])

	## The scene at a path (loaded from disk into an off-screen viewport) or a
	## root this returned before, posed time seconds into animation as
	## animation_frames poses it, its attachments on their bones; null after
	## an error, which is logged. Await it. The scene is freed when the run ends.
	func pose(scene: Variant, animation: String, time: float, player := "") -> Node:
		if bridge == null:
			push_error("ctx.pose() works in editor_run, not in the game.")
			return null
		var posed: Dictionary = await bridge.pose_scene(scene, animation, time, player)
		if posed.has("error"):
			push_error(posed.error)
			return null
		if posed.viewport != null:
			posed_viewports.append(posed.viewport)
		return posed.root

	## Removes the overlay of that name, or all of them.
	func clear_overlays(name := "") -> bool:
		return _overlay("clear_overlays", [name])

	func _overlay(method: String, arguments: Array) -> bool:
		if host == null or not host.has_method(method):
			push_error("Overlays are drawn in a running game: use them in game_run or game_play's setup.")
			return false
		var problem: String = host.callv(method, arguments)
		if not problem.is_empty():
			push_error(problem)
		return problem.is_empty()

## A run started with start(): done once run(ctx) returns.
class Run extends RefCounted:
	var context := Context.new()
	var instance: Object
	var done := false
	var result: Variant
	## True once cancel() freed the instance, which stops the code at its next await.
	var stopped := false

	## Cancels the run: wrapped code (a plain Object) is freed, so Godot drops it
	## at its next await; code with its own RefCounted class can only be asked,
	## through ctx.cancelled. A run that never awaits cannot be reached at all.
	func cancel() -> void:
		context.cancelled = true
		if not done and is_instance_valid(instance) and not instance is RefCounted:
			instance.free()
			stopped = true

## Returns {"script": GDScript} or {"error": String}, both with "path" and
## "line_offset": where errors in the compiled source point, and how many lines
## the wrapper put before the code (see code_lines()).
static func compile(code: String) -> Dictionary:
	var prefix := ""
	var body := code
	# Code defines its own run() only with a top-level `func run(`; the words
	# anywhere else (a string, a comment) do not count.
	if RegEx.create_from_string("(?m)^func run\\(").search(code) == null:
		var lines := PackedStringArray()
		for line in code.split("\n"):
			lines.append("\t" + line)
		# A plain Object, so a run can be cancelled by freeing it.
		prefix = "extends Object\n\nfunc run(ctx):\n"
		body = "\tpass\n" if code.strip_edges().is_empty() else "\n".join(lines) + "\n"
	elif not code.strip_edges().begins_with("extends") and not "\nextends " in code:
		prefix = "extends Object\n"
	# Only tool scripts run inside the editor; in a game the annotation is harmless.
	if not (prefix + body).strip_edges().begins_with("@tool"):
		prefix = "@tool\n" + _relaxed_warnings() + prefix
	var script := GDScript.new()
	script.source_code = prefix + body
	var where := {"path": "gdscript://%d.gd" % script.get_instance_id(), "line_offset": prefix.count("\n")}
	var error := script.reload()
	if error != OK:
		return {"error": "Compile failed: %s" % error_string(error)}.merged(where)
	return {"script": script}.merged(where)

## An annotation line ignoring the warnings treated as errors (by Godot's
## defaults, such as inference_on_variant, or the project's settings), or "":
## that strictness is meant for a project's own scripts, and would fail quick
## code like `var last := list.filter(f).back()`.
static func _relaxed_warnings() -> String:
	var names := PackedStringArray()
	for property in ProjectSettings.get_property_list():
		var setting: String = property.name
		if not setting.begins_with("debug/gdscript/warnings/"):
			continue
		var level: Variant = ProjectSettings.get_setting(setting)
		if level is int and level == 2:
			names.append('"%s"' % setting.get_file())
	return "@warning_ignore_start(%s)\n" % ", ".join(names) if not names.is_empty() else ""

## Log lines with locations in compiled code (see compile()) rewritten to the
## code's own lines, "code:12", rather than the wrapped source's, and a "HINT:"
## line added for a common mistake among them (see hint()).
static func code_lines(lines: PackedStringArray, compiled: Dictionary) -> PackedStringArray:
	var result := code_locations(lines, compiled)
	var advice := hint(result)
	if not advice.is_empty():
		result.append("HINT: " + advice)
	return result

## Log lines with locations in compiled code rewritten to "<label>:12".
static func code_locations(lines: PackedStringArray, compiled: Dictionary, label := "code") -> PackedStringArray:
	var marker: String = compiled.get("path", "") + ":"
	if marker == ":":
		return lines
	var offset: int = compiled.get("line_offset", 0)
	var result := PackedStringArray()
	for line in lines:
		var at := line.find(marker)
		while at >= 0:
			var digits := at + marker.length()
			var end := digits
			while end < line.length() and line[end] >= "0" and line[end] <= "9":
				end += 1
			if end == digits:
				break
			var number := int(line.substr(digits, end - digits)) - offset
			var replacement := "%s:%d" % [label, number] if number > 0 else label + " (wrapper)"
			line = line.substr(0, at) + replacement + line.substr(end)
			at = line.find(marker, at + replacement.length())
		result.append(line)
	return result

## Advice for common mistakes in the logs of a run, or "".
static func hint(lines: PackedStringArray) -> String:
	for line in lines:
		if line.contains("Cannot infer the type of") and not line.begins_with("HINT:"):
			return "`:=` needs a known type. Values from untyped names, such as ctx or a lambda parameter without a type, are Variants: use `=`, or type the parameter (func(canvas: Node2D): ...)."
	return ""

## Runs compiled code; returns {"result", "output"}. host becomes ctx.host
## and the compile location ({path, line_offset}) ctx.source.
static func run(script: GDScript, host: Object = null, source := {}) -> Dictionary:
	var started := start(script, host, source)
	while not started.done:
		await Engine.get_main_loop().process_frame
	return outcome(started)

## Starts compiled code without waiting for it. Code that never awaits has
## finished when this returns.
static func start(script: GDScript, host: Object = null, source := {}) -> Run:
	var started := prepare(script, host, source)
	drive(started)
	return started

## A Run for compiled code that has not started yet; drive() starts it. Lets a
## caller keep the Run before any of the code executes, since the code can
## process frames (reimport_files() does) before its first await returns.
static func prepare(script: GDScript, host: Object = null, source := {}) -> Run:
	var started := Run.new()
	started.context.host = host
	started.context.source = source
	started.instance = script.new()
	return started

static func drive(started: Run) -> void:
	var result: Variant = await started.instance.run(started.context)
	started.result = to_json(result)
	started.done = true
	# The instance is not freed: lambdas the code left connected (timers,
	# signals) may still need it. Each run leaves one small Object behind.

## A finished run's reply: {"result", "output"}.
static func outcome(started: Run) -> Dictionary:
	return {"result": started.result, "output": started.context.output}

## A reply with those of keys that are empty left out (by default a run's
## output and logs), so a quick query answers with little more than its result.
static func trimmed(reply: Dictionary, keys: Array = ["output", "logs"]) -> Dictionary:
	for key in keys:
		if reply.has(key) and reply[key].is_empty():
			reply.erase(key)
	return reply

## Converts a value to something JSON can carry: plain values as they are,
## arrays and dictionaries recursively, nodes as "path (Class)", and other
## engine types in GDScript notation.
static func to_json(value: Variant, depth := 0) -> Variant:
	if depth > 8:
		return str(value)
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return value
		TYPE_STRING_NAME, TYPE_NODE_PATH:
			return str(value)
		TYPE_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY:
			return Array(value).map(func(item): return to_json(item, depth + 1))
		TYPE_DICTIONARY:
			var out := {}
			for key in value:
				out[str(key)] = to_json(value[key], depth + 1)
			return out
		TYPE_OBJECT:
			if value == null:
				return null
			if value is Node:
				return "%s (%s)" % [value.get_path() if value.is_inside_tree() else value.name, value.get_class()]
			if value is Resource and not value.resource_path.is_empty():
				return "%s (%s)" % [value.resource_path, value.get_class()]
			return str(value)
	return var_to_str(value)
