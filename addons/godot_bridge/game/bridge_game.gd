extends Node
## The game side of Godot Bridge, started by game_loader.gd in games run from
## the editor. Over the debugger connection it runs GDScript in the game, takes
## screenshots, simulates mouse and keyboard input and keeps a log of recent
## output. Requests arrive as "godot_bridge:<kind>" [id, args]; every answer
## is "godot_bridge:reply" [id, result].

const PREFIX := "godot_bridge"
## Recent output lines kept for game_log.
const LOG_LIMIT := 500
const BUTTONS := {"left": MOUSE_BUTTON_LEFT, "right": MOUSE_BUTTON_RIGHT, "middle": MOUSE_BUTTON_MIDDLE}

## Loaded detached by game_loader.gd.
var code_runner_script: GDScript
var log_capture_script: GDScript
## Its grid and digit font draw game_screenshot's world grid.
var texture_view_script: GDScript

## Collects everything the game prints, warns or errors.
var _log_capture
var _log_lines: PackedStringArray = []
## Window pixels per pixel of the last screenshot, and the window pixel its
## top left corner shows, so input positions read off a downscaled or zoomed
## screenshot land in the right place.
var _shot_scale := 1.0
var _shot_offset := Vector2.ZERO
## Whether mouse input moves the real cursor too (see _input_events).
var _real_cursor := false
## Mouse buttons held by "press" or a drag, and where the mouse last went, so
## motion events carry the button mask and relative movement a drag needs.
var _held_buttons := 0
var _mouse_at := Vector2.ZERO
## Keys (name -> keycode) and actions held by "press" events until their
## "release", across game_input calls, so other tools can run in between.
var _held_keys := {}
var _held_actions := {}
## Frames this helper has processed. Nodes, this one included, do not process
## while the game is suspended (game_suspend), so it tells a stepped frame apart
## from Engine.get_process_frames(), which counts on regardless.
var _processed_frames := 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_log_capture = log_capture_script.new()
	OS.add_logger(_log_capture)
	EngineDebugger.register_message_capture(PREFIX, _on_message)
	# Let the main scene finish loading before reporting it.
	await get_tree().process_frame
	await get_tree().process_frame
	var scene := get_tree().current_scene
	var info := {
		"scene": scene.scene_file_path if scene != null else "",
		"window_size": _size_array(get_window().size),
		"viewport_size": _size_array(get_viewport().get_visible_rect().size),
	}
	# Errors and warnings raised while the game started, which did not stop it.
	_collect_log()
	var errors := Array(_log_lines).filter(func(line: String) -> bool: return line.begins_with("ERROR") or line.contains("SCRIPT ERROR") or line.begins_with("SHADER ERROR"))
	if not errors.is_empty():
		info.startup_errors = errors
	var warnings := Array(_log_lines).filter(func(line: String) -> bool: return line.begins_with("WARNING"))
	if not warnings.is_empty():
		info.startup_warnings = warnings
	EngineDebugger.send_message(PREFIX + ":ready", [info])

func _exit_tree() -> void:
	EngineDebugger.unregister_message_capture(PREFIX)
	if _log_capture != null:
		OS.remove_logger(_log_capture)

func _process(_delta: float) -> void:
	_processed_frames += 1
	_collect_log()
	_redraw_overlays()

func _on_message(message: String, data: Array) -> bool:
	var id: int = data[0] if not data.is_empty() else 0
	var args: Dictionary = data[1] if data.size() > 1 and data[1] is Dictionary else {}
	# Requests may take frames (run, input); they answer when done.
	match message.trim_prefix(PREFIX + ":"):
		"run":
			_run(id, String(args.get("code", "")))
		"screenshot":
			_screenshot(id, args)
		"input":
			_input_events(id, args.get("events", []), bool(args.get("real_cursor", false)))
		"log":
			_reply(id, _log_reply(int(args.get("lines", 50)), bool(args.get("clear", false))))
		"state":
			_reply(id, _state())
		"step_wait":
			_step_wait(id)
		_:
			return false
	return true

func _reply(id: int, result: Dictionary) -> void:
	EngineDebugger.send_message(PREFIX + ":reply", [id, result])

# --- run ---------------------------------------------------------------------

func _run(id: int, code: String) -> void:
	var capture = log_capture_script.new()
	OS.add_logger(capture)
	# Code that does not compile never ran in the game: its errors go back in
	# the reply, and are kept out of game_log, which is the game's own output.
	_collect_log()
	var compiled: Dictionary = code_runner_script.compile(code)
	if compiled.has("error"):
		OS.remove_logger(capture)
		var compile_lines: PackedStringArray = capture.take()
		_add_log_lines(PackedStringArray(Array(_log_capture.take()).filter(func(line: String) -> bool: return not line in compile_lines)))
		_reply(id, {"error": compiled.error, "logs": code_runner_script.code_lines(compile_lines, compiled)})
		return
	# So the editor's debugger shows a break in this code (now, or later in a
	# lambda or overlay it left behind) at code:N, not as the bridge's own.
	EngineDebugger.send_message(PREFIX + ":compiled", [compiled.path, compiled.line_offset])
	var outcome: Dictionary = await code_runner_script.run(compiled.script, self, {"path": compiled.path, "line_offset": compiled.line_offset})
	OS.remove_logger(capture)
	outcome.logs = code_runner_script.code_lines(capture.take(), compiled)
	_reply(id, code_runner_script.trimmed(outcome))

# --- screenshot --------------------------------------------------------------

## Saves the game's current frame as a PNG at args.path, downscaled so its
## longest side is at most args.max_size (0 keeps the full size).
## A region can be captured instead and enlarged without smoothing, so small
## details stay visible: args.node (a node path; a 2D node is framed by
## args.size world pixels around it, a 3D node by args.size meters or else its
## bounding box (see _frame_3d()), a Control by its own rectangle) or
## args.rect ([x, y, width, height] in world coordinates, or window pixels
## with args.space "window", for the HUD). args.zoom sets the
## enlargement (a whole number); by default the region is enlarged as far as
## max_size allows. args.grid draws world grid lines that far apart (doubled
## until they are a few image pixels apart), labelled with world coordinates.
func _screenshot(id: int, args: Dictionary) -> void:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var full := image.get_size()
	var max_size := int(args.get("max_size", 1280))
	var region := Rect2i(Vector2i.ZERO, full)
	# A whole-frame capture shows the world too.
	var in_world := args.get("node") == null and args.get("rect") == null
	# How a 3D node was framed, for the reply.
	var framed := ""
	if args.get("node") != null or args.get("rect") != null:
		var found: Variant = _screenshot_region(args)
		if found is String:
			_reply(id, {"error": found})
			return
		in_world = found.world
		framed = String(found.get("framed", ""))
		var shown := (found.window as Rect2).abs().intersection(Rect2(Vector2.ZERO, full))
		var corner := Vector2i(shown.position.floor())
		region = Rect2i(corner, Vector2i(shown.end.ceil()) - corner).intersection(Rect2i(Vector2i.ZERO, full))
		if not region.has_area():
			_reply(id, {"error": "That region is outside the visible screen."})
			return
		image = image.get_region(region)
	var size := image.get_size()
	var scale := 1.0
	var zoom := int(args.get("zoom", 0))
	if region.size != full and zoom <= 0:
		zoom = maxi(1, (max_size if max_size > 0 else 1280) / maxi(size.x, size.y))
	if zoom > 1:
		image.resize(size.x * zoom, size.y * zoom, Image.INTERPOLATE_NEAREST)
		scale = 1.0 / zoom
	elif max_size > 0 and maxi(size.x, size.y) > max_size:
		scale = float(maxi(size.x, size.y)) / max_size
		image.resize(roundi(size.x / scale), roundi(size.y / scale), Image.INTERPOLATE_LANCZOS)
	_shot_scale = scale
	_shot_offset = Vector2(region.position)
	# A window with a see-through background (a desktop pet, an overlay) leaves
	# its empty pixels transparent, which image viewers show as white, the same
	# as white in the game itself. They are shown over a checkerboard instead.
	var transparent := image.detect_alpha() != Image.ALPHA_NONE
	if transparent:
		image.convert(Image.FORMAT_RGBA8)
		var backdrop: Image = texture_view_script.new()._checkerboard(image.get_size())
		backdrop.blend_rect(image, Rect2i(Vector2i.ZERO, image.get_size()), Vector2i.ZERO)
		image = backdrop
	var grid_note := ""
	var grid := int(args.get("grid", 0))
	if grid > 0:
		grid_note = _draw_world_grid(image, region, scale, grid) if in_world else "The grid is drawn only over the world, not a window rect, Control or 3D node."
	var path := String(args.get("path", ""))
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var error := image.save_png(path)
	if error != OK:
		_reply(id, {"error": "Could not save the screenshot: %s" % error_string(error)})
		return
	var reply := {
		"path": path,
		"image_size": _size_array(image.get_size()),
		"window_size": _size_array(full),
		"viewport_size": _size_array(get_viewport().get_visible_rect().size),
		"scale": scale,
	}
	if region.size != full:
		reply.region = [region.position.x, region.position.y, region.size.x, region.size.y]
		if in_world:
			# The region is in window pixels; world sizes there are scaled by
			# the camera's zoom and the window's stretch.
			var world := (get_viewport().get_final_transform() * get_viewport().get_canvas_transform()).affine_inverse() * Rect2(region)
			reply.world_rect = [world.position.x, world.position.y, world.size.x, world.size.y]
		reply.zoom = maxi(zoom, 1)
		if not framed.is_empty():
			reply.framed = framed
	if not grid_note.is_empty():
		reply.grid = grid_note
	if transparent:
		reply.transparency = "The window's transparent pixels are shown over a dark checkerboard. For their alpha, read get_viewport().get_texture().get_image() in game_run."
	_reply(id, reply)

## Draws world grid lines every `grid` world pixels over a screenshot of the
## window region (scaled by 1 / scale), with each line's world coordinate along
## the top and left edges. Returns what was drawn, for the reply.
func _draw_world_grid(image: Image, region: Rect2i, scale: float, grid: int) -> String:
	var view = texture_view_script.new()
	var viewport := get_viewport()
	var to_window := viewport.get_final_transform() * viewport.get_canvas_transform()
	var to_image := func(point: Vector2i) -> Vector2i:
		return Vector2i(((to_window * Vector2(point) - Vector2(region.position)) / scale).round())
	var image_per_world := to_window.get_scale().x / scale
	var step := grid
	while step * image_per_world < view.MIN_GRID_SPACING:
		step *= 2
	var world := to_window.affine_inverse() * Rect2(region)
	var corner := Vector2i(world.position.ceil())
	var shown := Rect2i(corner, Vector2i(world.end.floor()) - corner)
	# Thin lines are lost in an enlarged shot: about one line pixel per 3 image
	# pixels a world pixel covers, and more opaque once they are wider.
	var width := clampi(roundi(image_per_world / 3.0), 1, 4)
	var color: Color = view.GRID_COLOR
	color.a = minf(0.4 + 0.15 * (width - 1), 0.75)
	view._draw_grid(image, shown, step, to_image, width, color)
	# Labels just right of / below each line, as much bigger as the lines are
	# wider, skipping any that would overlap the last.
	var font_scale: int = view.FONT_SCALE * width
	var label_height := 5 * font_scale
	var free_from := 0
	for x in range(view._first_multiple(shown.position.x, step), shown.end.x + 1, step):
		var text := str(x)
		var at: int = to_image.call(Vector2i(x, shown.position.y)).x + width + 1
		if at >= free_from and at + view._text_width(text, font_scale) < image.get_width():
			view._label(image, text, Vector2i(at, width + 1), true, font_scale)
			free_from = at + view._text_width(text, font_scale) + 3 * font_scale
	free_from = label_height + 3 * font_scale
	for y in range(view._first_multiple(shown.position.y, step), shown.end.y + 1, step):
		var at: int = to_image.call(Vector2i(shown.position.x, y)).y + width + 1
		if at >= free_from and at + label_height < image.get_height():
			view._label(image, str(y), Vector2i(width + 1, at), true, font_scale)
			free_from = at + label_height + 2 * font_scale
	return "World grid every %d px (%s image px)%s." % [step, String.num(step * image_per_world, 1), " (doubled from %d to stay readable)" % grid if step != grid else ""]

## The window rectangle a region screenshot shows ({window: Rect2, world:
## whether it frames world coordinates, not a Control or 3D node}), or an
## error message.
func _screenshot_region(args: Dictionary) -> Variant:
	var viewport := get_viewport()
	# World (canvas) coordinates -> window pixels.
	var to_window := viewport.get_final_transform() * viewport.get_canvas_transform()
	if args.get("rect") != null:
		var rect: Array = args.rect
		if rect.size() != 4:
			return "rect is [x, y, width, height] in world coordinates, or window pixels with space 'window'."
		var area := Rect2(rect[0], rect[1], rect[2], rect[3])
		if String(args.get("space", "world")) == "window":
			return {"window": area, "world": false}
		return {"window": to_window * area, "world": true}
	var path := NodePath(String(args.node))
	var scene := get_tree().current_scene
	var node: Node = scene.get_node_or_null(path) if scene != null and not path.is_absolute() else null
	if node == null:
		node = get_tree().root.get_node_or_null(path)
	if node == null:
		return "No node at %s (paths are relative to the current scene, or absolute)." % args.node
	var size: Array = args.get("size", []) if args.get("size") is Array else []
	if not size.is_empty() and size.size() != 2:
		return "size is [width, height]: world pixels for a 2D node, meters for a 3D one."
	var world_size := Vector2(size[0], size[1]) if size.size() == 2 else Vector2(128, 128)
	if node is Control:
		var control := node as Control
		var corner := control.get_global_transform_with_canvas()
		return {"window": viewport.get_final_transform() * (corner * Rect2(Vector2.ZERO, control.size)), "world": false}
	if node is Node2D:
		var centre := (node as Node2D).get_global_transform_with_canvas().origin
		var to_screen := viewport.get_final_transform()
		var scaled := world_size * viewport.get_canvas_transform().get_scale() * to_screen.get_scale()
		return {"window": Rect2(to_screen * centre - scaled / 2.0, scaled), "world": true}
	if node is Node3D:
		return _frame_3d(node as Node3D, size, String(args.node))
	return "%s is not a 2D, 3D or Control node." % args.node

## The window rectangle framing a 3D node, as _screenshot_region() returns it:
## size [width, height] in meters, a box facing the camera around the middle of
## the node's bounding box (the meshes and other geometry in it and under it;
## a character's origin is usually at its feet), or without a size that
## bounding box itself with a margin. A node without geometry is framed around
## its origin.
func _frame_3d(node: Node3D, size: Array, label: String) -> Variant:
	var viewport := get_viewport()
	var camera := viewport.get_camera_3d()
	if camera == null:
		return "There is no 3D camera to frame %s with." % label
	var corners := PackedVector3Array()
	var framed := ""
	var box := _visual_bounds(node)
	if size.size() == 2:
		var right := camera.global_basis.x.normalized() * float(size[0]) / 2.0
		var up := camera.global_basis.y.normalized() * float(size[1]) / 2.0
		var centre := node.global_position if box.size == Vector3.ZERO else box.get_center()
		corners = [centre - right - up, centre + right - up, centre - right + up, centre + right + up]
		framed = "%s x %s m around the node's %s" % [size[0], size[1], "origin" if box.size == Vector3.ZERO else "bounding box centre"]
	else:
		if box.size == Vector3.ZERO:
			box = AABB(node.global_position - Vector3.ONE / 2.0, Vector3.ONE)
			framed = "1 m around the node's origin: it has no meshes or other geometry to fit"
		else:
			framed = "the node's bounding box, %s x %s x %s m" % [snappedf(box.size.x, 0.01), snappedf(box.size.y, 0.01), snappedf(box.size.z, 0.01)]
		for i in 8:
			corners.append(box.get_endpoint(i))
	var to_screen := viewport.get_final_transform()
	var points := PackedVector2Array()
	for corner in corners:
		if not camera.is_position_behind(corner):
			points.append(to_screen * camera.unproject_position(corner))
	if points.is_empty():
		return "%s is behind the camera." % label
	var rect := Rect2(points[0], Vector2.ZERO)
	for point in points:
		rect = rect.expand(point)
	if size.is_empty():
		rect = rect.grow(maxf(4.0, maxf(rect.size.x, rect.size.y) * 0.1))
	return {"window": rect, "world": false, "framed": framed}

## The global bounding box of the geometry in node and under it (meshes,
## sprites, particles, CSG...), or an empty AABB when there is none. Lights
## and probes are left out: their bounds are their reach, not anything seen.
func _visual_bounds(node: Node3D) -> AABB:
	var box := AABB()
	var found := false
	var nodes: Array[Node] = [node]
	nodes.append_array(node.find_children("*", "GeometryInstance3D", true, false))
	for item in nodes:
		var visual := item as GeometryInstance3D
		if visual == null or not visual.is_visible_in_tree():
			continue
		var local := visual.get_aabb()
		if local.size == Vector3.ZERO:
			continue
		var global := visual.global_transform * local
		box = global if not found else box.merge(global)
		found = true
	return box

# --- overlays ----------------------------------------------------------------

## Debug drawings added by game_run code through ctx.draw_2d() and
## ctx.draw_3d(), by name: {node, draw, every_frame} plus a painter and mesh
## for 3D. They stay until ctx.clear_overlays() or the game stops; without a
## parent they are children of this helper, so changing scenes keeps them.
## While the game is suspended they keep their last drawing.
var _overlays := {}

## Collects a 3D overlay's lines and triangles for one drawing, in world
## coordinates (or its parent's).
class Painter3D extends RefCounted:
	var lines := PackedVector3Array()
	var line_colors := PackedColorArray()
	var triangles := PackedVector3Array()
	var triangle_colors := PackedColorArray()

	func line(from: Vector3, to: Vector3, color := Color.WHITE) -> void:
		lines.append_array([from, to])
		line_colors.append_array([color, color])

	func triangle(a: Vector3, b: Vector3, c: Vector3, color := Color(1, 1, 1, 0.4)) -> void:
		triangles.append_array([a, b, c])
		triangle_colors.append_array([color, color, color])

	## Corners in order around the edge.
	func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, color := Color(1, 1, 1, 0.4)) -> void:
		triangle(a, b, c, color)
		triangle(a, c, d, color)

	## An AABB's twelve edges, or its six faces when filled.
	func box(area: AABB, color := Color.WHITE, filled := false) -> void:
		var corners: Array[Vector3] = []
		for i in 8:
			corners.append(area.get_endpoint(i))
		if filled:
			# AABB endpoints: bit 0 is x, bit 1 y and bit 2 z.
			for face in [[0, 1, 3, 2], [4, 6, 7, 5], [0, 4, 5, 1], [2, 3, 7, 6], [0, 2, 6, 4], [1, 5, 7, 3]]:
				quad(corners[face[0]], corners[face[1]], corners[face[2]], corners[face[3]], color)
			return
		for edge in [[0, 1], [2, 3], [4, 5], [6, 7], [0, 2], [1, 3], [4, 6], [5, 7], [0, 4], [1, 5], [2, 6], [3, 7]]:
			line(corners[edge[0]], corners[edge[1]], color)

	## Three crossing lines marking a point.
	func cross(point: Vector3, size := 0.25, color := Color.WHITE) -> void:
		for axis in [Vector3.RIGHT, Vector3.UP, Vector3.BACK]:
			line(point - axis * size, point + axis * size, color)

	func clear() -> void:
		lines.clear()
		line_colors.clear()
		triangles.clear()
		triangle_colors.clear()

	func commit(mesh: ImmediateMesh) -> void:
		mesh.clear_surfaces()
		for surface in [[Mesh.PRIMITIVE_LINES, lines, line_colors], [Mesh.PRIMITIVE_TRIANGLES, triangles, triangle_colors]]:
			var points: PackedVector3Array = surface[1]
			if points.is_empty():
				continue
			var colors: PackedColorArray = surface[2]
			mesh.surface_begin(surface[0])
			for i in points.size():
				mesh.surface_set_color(colors[i])
				mesh.surface_add_vertex(points[i])
			mesh.surface_end()

## Adds (or replaces) a 2D overlay: a Node2D drawn above everything in its
## canvas, whose draw callback is draw(canvas). Returns an error message or "".
func add_overlay_2d(overlay_name: String, draw: Callable, every_frame := true, parent: Node = null, source := {}) -> String:
	var problem := _overlay_problem(overlay_name, draw, parent, "draw_2d", "func(canvas: Node2D): canvas.draw_rect(Rect2(0, 0, 32, 32), Color(1, 0, 0, 0.4))")
	if not problem.is_empty():
		return problem
	clear_overlays(overlay_name)
	var canvas := Node2D.new()
	canvas.name = ("Overlay2D " + overlay_name).validate_node_name()
	canvas.z_as_relative = false
	canvas.z_index = RenderingServer.CANVAS_ITEM_Z_MAX
	canvas.draw.connect(func() -> void: _call_overlay(overlay_name, canvas, draw, canvas))
	_overlays[overlay_name] = {"node": canvas, "draw": draw, "every_frame": every_frame, "source": source}
	(parent if parent != null else self).add_child(canvas)
	return ""

## Adds (or replaces) a 3D overlay: an unlit mesh drawn through walls, refilled
## by draw(painter) (see Painter3D). Returns an error message or "".
func add_overlay_3d(overlay_name: String, draw: Callable, every_frame := true, parent: Node = null, source := {}) -> String:
	var problem := _overlay_problem(overlay_name, draw, parent, "draw_3d", "func(painter): painter.box(AABB(Vector3.ZERO, Vector3.ONE), Color.RED)")
	if not problem.is_empty():
		return problem
	clear_overlays(overlay_name)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.render_priority = Material.RENDER_PRIORITY_MAX
	var mesh := ImmediateMesh.new()
	var instance := MeshInstance3D.new()
	instance.name = ("Overlay3D " + overlay_name).validate_node_name()
	instance.mesh = mesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var overlay := {"node": instance, "draw": draw, "every_frame": every_frame, "source": source, "painter": Painter3D.new(), "mesh": mesh}
	_overlays[overlay_name] = overlay
	(parent if parent != null else self).add_child(instance)
	_draw_3d(overlay)
	return ""

func _overlay_problem(overlay_name: String, draw: Callable, parent: Node, method: String, example: String) -> String:
	if overlay_name.is_empty():
		return "%s needs a name, so the overlay can be replaced or cleared." % method
	if not draw.is_valid():
		return "%s needs a callable, such as %s." % [method, example]
	if parent != null and not is_instance_valid(parent):
		return "%s: the parent node no longer exists." % method
	return ""

## Removes the overlay of that name, or every overlay for "". Returns "".
func clear_overlays(overlay_name := "") -> String:
	for key in _overlays.keys():
		if overlay_name.is_empty() or key == overlay_name:
			var node: Node = _overlays[key].node
			if is_instance_valid(node):
				node.queue_free()
			_overlays.erase(key)
	return ""

## Log lines with locations in overlay code (see code_runner.compile())
## rewritten to that code's lines, as overlay "name" code:12.
func _overlay_code_lines(lines: PackedStringArray) -> PackedStringArray:
	var names_by_path := {}
	for key in _overlays:
		var path: String = _overlays[key].source.get("path", "")
		if not path.is_empty():
			names_by_path[path] = names_by_path.get(path, []) + ["\"%s\"" % key]
	for key in _overlays:
		var source: Dictionary = _overlays[key].source
		if names_by_path.has(source.get("path", "")):
			var names: Array = names_by_path[source.path]
			lines = code_runner_script.code_locations(lines, source, "%s %s code" % ["overlay" if names.size() == 1 else "overlays", ", ".join(names)])
			names_by_path.erase(source.path)
	return lines

func _redraw_overlays() -> void:
	for key in _overlays.keys():
		var overlay: Dictionary = _overlays[key]
		# A parent elsewhere in the game may have taken it away.
		if not is_instance_valid(overlay.node):
			_overlays.erase(key)
		elif overlay.every_frame:
			if overlay.has("painter"):
				_draw_3d(overlay)
			else:
				overlay.node.queue_redraw()

func _draw_3d(overlay: Dictionary) -> void:
	overlay.painter.clear()
	for key in _overlays:
		if _overlays[key] == overlay:
			_call_overlay(key, overlay.node, overlay.draw, overlay.painter)
	overlay.painter.commit(overlay.mesh)

## Calls an overlay's draw callback. One that raises an error would raise it
## every frame, so the overlay stops redrawing and the log says so once.
## The log is collected before the call, so what arrives during it is the
## callback's own.
func _call_overlay(overlay_name: String, node: Node, draw: Callable, target: Object) -> void:
	_collect_log()
	draw.call(target)
	var lines: PackedStringArray = _log_capture.take() if _log_capture != null else PackedStringArray()
	if lines.is_empty():
		return
	var overlay: Dictionary = _overlays.get(overlay_name, {})
	# Overlays from one snippet share its source; this callback's are its own.
	lines = code_runner_script.code_locations(lines, overlay.get("source", {}), "overlay \"%s\" code" % overlay_name)
	var failed := Array(lines).any(func(line: String) -> bool: return line.begins_with("ERROR") or line.begins_with("SCRIPT ERROR"))
	if failed and overlay.get("node") == node and overlay.every_frame:
		overlay.every_frame = false
		lines.append("ERROR: Overlay \"%s\" stopped redrawing after an error in its callback. Fix it and draw it again with the same name." % overlay_name)
	_add_log_lines(lines)

# --- input -------------------------------------------------------------------

## Plays a list of input events, one frame apart. Positions (x, y) are in
## pixels of the last screenshot by default; "space": "viewport" takes canvas
## coordinates (such as a Control's global_position) and "window" raw window
## pixels.
##
## Simulated mouse events do not move the real cursor, which is what
## get_global_mouse_position() and hover checks read. With real_cursor the
## cursor is warped there instead, and the display sends the motion event
## itself, so both agree. It is on for background games, whose cursor is
## their own; in a game on screen it would move the user's mouse.
func _input_events(id: int, events: Array, real_cursor := false) -> void:
	_real_cursor = real_cursor
	var played := 0
	for event in events:
		if not event is Dictionary:
			continue
		match String(event.get("type", "")):
			"move":
				_mouse_motion(_point(event))
			"click":
				var point := _point(event)
				var button: MouseButton = BUTTONS.get(String(event.get("button", "left")), MOUSE_BUTTON_LEFT)
				_mouse_motion(point)
				await get_tree().process_frame
				if _real_cursor:
					# The display's motion event for the warp arrives a frame later.
					await get_tree().process_frame
				for click in (2 if event.get("double", false) else 1):
					_mouse_button(point, button, true, click == 1)
					await get_tree().process_frame
					_mouse_button(point, button, false)
					await get_tree().process_frame
			"press", "release" when event.has("key"):
				var key_name := String(event.key)
				var pressed := String(event.type) == "press"
				if OS.find_keycode_from_string(key_name) == KEY_NONE:
					_reply(id, {"error": "Unknown key: %s" % key_name, "played": played, "held": _held_inputs()})
					return
				# The held key's own event, so Shift's press carries shift.
				if pressed:
					_held_keys[key_name] = OS.find_keycode_from_string(key_name)
				_key(key_name, event, pressed)
				if not pressed:
					_held_keys.erase(key_name)
			"press", "release" when event.has("action"):
				var action := StringName(event.action)
				if not InputMap.has_action(action):
					var own := InputMap.get_actions().filter(func(name: StringName) -> bool: return not String(name).begins_with("ui_"))
					var known := "the project has %s" % ", ".join(own) if not own.is_empty() else "the project defines none of its own, only Godot's ui_ actions"
					_reply(id, {"error": "No input action %s; %s." % [action, known], "played": played, "held": _held_inputs()})
					return
				if String(event.type) == "press":
					Input.action_press(action)
					_held_actions[action] = true
				else:
					Input.action_release(action)
					_held_actions.erase(action)
			"press", "release":
				var pressed := String(event.type) == "press"
				var point := _point(event) if event.has("x") else _mouse_at
				var button: MouseButton = BUTTONS.get(String(event.get("button", "left")), MOUSE_BUTTON_LEFT)
				if point != _mouse_at:
					_mouse_motion(point)
					await get_tree().process_frame
				_mouse_button(point, button, pressed)
			"drag":
				# Press at (x, y), move to (to_x, to_y) in steps, release there.
				var from := _point(event)
				var to := _point({"x": event.get("to_x", 0), "y": event.get("to_y", 0), "space": event.get("space", "screenshot")})
				var button: MouseButton = BUTTONS.get(String(event.get("button", "left")), MOUSE_BUTTON_LEFT)
				_mouse_motion(from)
				await get_tree().process_frame
				if _real_cursor:
					await get_tree().process_frame
				_mouse_button(from, button, true)
				await get_tree().process_frame
				var steps := maxi(1, int(event.get("steps", 8)))
				for step in steps:
					_mouse_motion(from.lerp(to, float(step + 1) / steps), true)
					await get_tree().process_frame
				_mouse_button(to, button, false)
			"scroll":
				var point := _point(event)
				var wheel := MOUSE_BUTTON_WHEEL_UP if String(event.get("direction", "down")) == "up" else MOUSE_BUTTON_WHEEL_DOWN
				if _real_cursor:
					_mouse_motion(point)
					await get_tree().process_frame
					await get_tree().process_frame
				for step in int(event.get("amount", 1)):
					_mouse_button(point, wheel, true)
					_mouse_button(point, wheel, false)
					await get_tree().process_frame
			"key":
				_key(String(event.get("key", "")), event, true)
				await get_tree().process_frame
				_key(String(event.get("key", "")), event, false)
			"text":
				for character in String(event.get("text", "")):
					_text_key(character, true)
					_text_key(character, false)
					await get_tree().process_frame
			"action":
				var action := StringName(event.get("action", ""))
				Input.action_press(action)
				await get_tree().create_timer(float(event.get("hold", 0.1)), true, false, true).timeout
				Input.action_release(action)
			"wait":
				await get_tree().create_timer(float(event.get("seconds", 0.5)), true, false, true).timeout
			_:
				_reply(id, {"error": "Unknown input event type: %s" % event.get("type"), "played": played})
				return
		played += 1
		await get_tree().process_frame
	_reply(id, {"played": played, "held": _held_inputs()})

## What "press" events left held: keys, actions and mouse buttons, by name.
func _held_inputs() -> Array:
	var held: Array = _held_keys.keys()
	for action in _held_actions:
		held.append("action " + String(action))
	for button in BUTTONS:
		var bit := 1 << (int(BUTTONS[button]) - 1)
		if int(BUTTONS[button]) <= MOUSE_BUTTON_MIDDLE and _held_buttons & bit:
			held.append("mouse " + button)
	return held

func _point(event: Dictionary) -> Vector2:
	var point := Vector2(float(event.get("x", 0)), float(event.get("y", 0)))
	match String(event.get("space", "screenshot")):
		"viewport":
			return get_tree().root.get_final_transform() * point
		"window":
			return point
	return _shot_offset + point * _shot_scale

## Moves the mouse to a window point. With the real cursor, warping it makes
## the display send the motion event, except for a drag (dragging), whose
## events must carry the held buttons, so it is sent here as well.
func _mouse_motion(point: Vector2, dragging := false) -> void:
	var relative := point - _mouse_at
	_mouse_at = point
	if _real_cursor:
		Input.warp_mouse(point)
		if not dragging:
			return
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	motion.relative = relative
	motion.button_mask = _held_buttons
	Input.parse_input_event(motion)

func _mouse_button(point: Vector2, button: MouseButton, pressed: bool, double_click := false) -> void:
	var click := InputEventMouseButton.new()
	click.position = point
	click.global_position = point
	click.button_index = button
	click.pressed = pressed
	click.double_click = double_click
	if button <= MOUSE_BUTTON_MIDDLE:
		var bit := 1 << (button - 1)
		_held_buttons = (_held_buttons | bit) if pressed else (_held_buttons & ~bit)
	click.button_mask = _held_buttons
	_mouse_at = point
	Input.parse_input_event(click)

func _key(key_name: String, event: Dictionary, pressed: bool) -> void:
	var key := InputEventKey.new()
	key.keycode = OS.find_keycode_from_string(key_name)
	key.physical_keycode = key.keycode
	key.pressed = pressed
	# Modifiers held by "press" apply to every key event meanwhile.
	key.shift_pressed = bool(event.get("shift", false)) or _held_keys.values().has(KEY_SHIFT)
	key.ctrl_pressed = bool(event.get("ctrl", false)) or _held_keys.values().has(KEY_CTRL)
	key.alt_pressed = bool(event.get("alt", false)) or _held_keys.values().has(KEY_ALT)
	if pressed and key_name.length() == 1 and not key.ctrl_pressed and not key.alt_pressed:
		key.unicode = (key_name.to_upper() if key.shift_pressed else key_name.to_lower()).unicode_at(0)
	Input.parse_input_event(key)

func _text_key(character: String, pressed: bool) -> void:
	var key := InputEventKey.new()
	key.keycode = OS.find_keycode_from_string(character.to_upper())
	key.pressed = pressed
	if pressed:
		key.unicode = character.unicode_at(0)
	Input.parse_input_event(key)

# --- log ---------------------------------------------------------------------

func _collect_log() -> void:
	if _log_capture == null:
		return
	_add_log_lines(_log_capture.take())

func _add_log_lines(lines: PackedStringArray) -> void:
	if lines.is_empty():
		return
	_log_lines.append_array(_overlay_code_lines(lines))
	if _log_lines.size() > LOG_LIMIT:
		_log_lines = _log_lines.slice(_log_lines.size() - LOG_LIMIT)

func _log_reply(count: int, clear: bool) -> Dictionary:
	_collect_log()
	var lines := _log_lines.slice(maxi(0, _log_lines.size() - count))
	if clear:
		_log_lines = []
	return {"lines": lines, "kept": LOG_LIMIT}

# --- suspend -----------------------------------------------------------------

## This helper always processes (PROCESS_MODE_ALWAYS) unless the game is suspended.
func _state() -> Dictionary:
	return {"suspended": not can_process(), "processed_frames": _processed_frames}

## Sent right after Godot's "scene:next_frame": answers once the stepped frame
## is drawn. Godot suspends the game again on that frame's frame_post_draw, and
## its handler was connected first, so it has run by the time this one wakes.
## If the frame already ran (the messages came in separate polls), it answers
## at once.
func _step_wait(id: int) -> void:
	if can_process():
		await RenderingServer.frame_post_draw
	_reply(id, _state())

## Vector2 or Vector2i -> [x, y] in whole pixels.
func _size_array(size) -> Array:
	return [roundi(size.x), roundi(size.y)]
