#!/usr/bin/env python3
"""MCP server (stdio) for the Godot Bridge editor plugin.

Speaks MCP JSON-RPC on stdin/stdout and forwards each tool call to the
Godot editor running this project. The editor plugin writes one connection
file per editor process to .godot/godot_bridge/editor-<pid>.json; this server
picks the newest one whose process is still alive. Standard library only.
"""
import base64
import glob
import hashlib
import itertools
import json
import os
import socket
import sys

PROJECT = os.environ.get("GODOT_BRIDGE_PROJECT") or os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
CONNECTION_DIR = os.path.join(PROJECT, ".godot", "godot_bridge")
VERSION = "0.1.0"
TIMEOUT = float(os.environ.get("GODOT_BRIDGE_TIMEOUT", "120"))

TOOLS = [
    {
        "name": "editor_status",
        "description": "Show the connected Godot editor: Godot version, project path, the scene being edited, open scenes, which of them have unsaved edits in the editor (so editing their files on disk would conflict) and the scene being played.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "editor_run",
        "description": (
            "Run GDScript inside the Godot editor and return its result. Write statements as the body of "
            "run(ctx) (loops, load(), EditorInterface, Engine, OS, Input and other singletons all work), or "
            "define `func run(ctx)` yourself. `return value` sends a value back (nodes come back as "
            "'path (Class)'); ctx.log(value) adds output lines. Engine output, warnings and errors raised "
            "while it runs are returned as logs. By default files changed on disk are synced first. "
            "For measuring an animated scene, `var root = await ctx.pose(scene_path, animation, seconds, player_path = '')` "
            "returns it posed as animation_frames poses it (AnimationTrees off, BoneAttachment3Ds on their bones) in an "
            "off-screen viewport freed when the run ends; pass that root instead of the path to pose it again. "
            "Code that awaits (e.g. `await Engine.get_main_loop().process_frame` every so often) and outlasts "
            "`timeout` is answered with its progress and a run_id and keeps running: collect it with "
            "editor_result or stop it with editor_cancel. Code that never awaits blocks the editor until it "
            "returns and cannot be cancelled, so make long jobs await now and then. A result too long for a reply "
            "(over 40,000 characters) is saved to a file and replaced by a summary of its shape (its largest keys, "
            "first and largest items, with sizes), and output and logs keep their last 300 lines."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "code": {"type": "string", "description": "GDScript to run."},
                "sync": {"type": "boolean", "description": "Reload files changed on disk first (default true)."},
                "timeout": {"type": "number", "description": "Seconds to wait before answering with progress (default 90)."},
            },
            "required": ["code"],
        },
    },
    {
        "name": "editor_result",
        "description": "The result of an editor_run that outlasted its timeout (or whose answer was lost because the editor was busy): its reply once finished, otherwise its progress so far. The last 5 finished runs are kept.",
        "inputSchema": {
            "type": "object",
            "properties": {"run_id": {"type": "integer", "description": "The run's id; default the most recent run."}},
        },
    },
    {
        "name": "editor_cancel",
        "description": "Stop a running editor_run. Code runs in the editor's main thread, so it stops at its next await; code that defines its own class stops where it checks ctx.cancelled.",
        "inputSchema": {
            "type": "object",
            "properties": {"run_id": {"type": "integer", "description": "The run's id; default the most recent run."}},
        },
    },
    {
        "name": "reload_bridge",
        "description": (
            "Apply edits to the Godot Bridge addon's own scripts (bridge_server.gd, code_runner.gd, log_capture.gd, "
            "debugger_plugin.gd, texture_view.gd) without turning the plugin off and on. Every script is compiled "
            "first; if any fails, the errors come back and the running bridge is left as it is. Otherwise the bridge "
            "is replaced right after the reply and the next call reaches the new one, still connected to a running "
            "game. Refused while an editor_run or another request is still going. Edits to plugin.gd still need the "
            "plugin turned off and on, and edits to mcp/server.py a reconnect of this MCP server."
        ),
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "run_tests",
        "description": (
            "Run the project's headless test scripts and report pass/fail with their errors. Files changed on disk "
            "are synced first, so the tests see new class_names. Each script runs in its own `godot --headless -s "
            "<script>` (extending SceneTree or MainLoop) and passes when it exits with code 0 (quit(0)); the "
            "editor keeps working meanwhile. Without scripts, the scripts in res://tests/ and res://test/ that "
            "extend SceneTree or MainLoop are run. For a test framework, pass its command-line runner as the "
            "script and its options in args (GUT: scripts ['res://addons/gut/gut_cmdln.gd'], args ['-gdir=res://test', '-gexit'])."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "scripts": {"type": "array", "items": {"type": "string"}, "description": "Test scripts or folders of them (default: res://tests/ and res://test/)."},
                "args": {"type": "array", "items": {"type": "string"}, "description": "Extra command-line arguments passed to every run, after the script."},
                "timeout": {"type": "number", "description": "Seconds each script may take before it is stopped (default 120)."},
            },
        },
    },
    {
        "name": "sync_from_disk",
        "description": "Make the editor pick up files changed outside it (scripts, scenes, resources, new class_names), as when its window regains focus. Run after editing project files on disk. This also rewrites the class cache (.godot/global_script_class_cache.cfg) that headless runs such as `godot --headless -s test.gd` read, so they see a new class_name only after a sync (run_tests syncs by itself). Open scenes changed on disk are reloaded in the editor; any that also have unsaved edits there are listed as unsaved_conflicts instead.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "import_settings",
        "description": (
            "Read an imported asset's import settings (texture, audio, model...), or change them on one or many assets at once. "
            "Reading takes one path and lists every setting. Pass params (setting name -> value) to change them: every file "
            "given (path and/or paths, where * matches any imported files, also across folders, e.g. res://anims/*.fbx) is "
            "checked first, and nothing is saved unless every file has every setting; files whose settings changed are then "
            "reimported together. The reply is short: reimported (file -> the settings that changed there) and unchanged "
            "(files already set that way, not reimported). A reimport that fails is returned as an error with the importer's logs. "
            "Scenes (glTF, FBX, Blend) also keep settings per animation "
            "and per node: reading lists them as subresources (without Godot's empty slice entries) and the names "
            "there are as available, and the subresources argument changes them, e.g. "
            "{\"animations/*\": {\"settings/loop_mode\": \"linear\", \"save_to_file/enabled\": true, \"save_to_file/path\": \"res://anims/walk.res\"}, "
            "\"nodes/PATH:Skeleton3D\": {\"retarget/bone_map\": \"res://bone_map.tres\"}}. Resource settings take a res:// or uid:// path; "
            "loop modes take none, linear or ping_pong; \"*\" stands for every animation or node."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Asset path, such as res://textures/icon.png."},
                "paths": {"type": "array", "items": {"type": "string"}, "description": "More assets to change the same way; * matches any imported files, e.g. res://Animations/*.FBX."},
                "params": {"type": "object", "description": "Settings to change, by name as listed in the [params] section."},
                "subresources": {"type": "object", "description": "Scenes: per-animation or per-node settings to change, \"<animations|nodes|meshes|materials>/<name>\" -> {setting: value}."},
            },
        },
    },
    {
        "name": "game_play",
        "description": "Play a scene from the editor and wait until it is running: scene '' (default) is the main scene, 'current' the scene being edited, or a path like res://scenes/x.tscn. Pass restart to stop a running game first. Pass background to run it where it is never shown (gamescope's headless backend) instead of the editor's game window; every game tool works the same. Files changed on disk are synced first, as with sync_from_disk, so the game runs the latest scripts and scenes, with new class_names and imports registered. Errors and warnings printed while the game started come back as startup_errors and startup_warnings. If the game stops in the debugger while starting (a script error in the main scene) or quits, the error, stack and the game's last output are returned at once instead of waiting for the timeout. setup runs GDScript in the game once it is up, exactly as game_run would (overlays included), so a restart can rebuild test state and debug drawings in the same call; its reply comes back as setup, and a setup error does not stop the game.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "scene": {"type": "string", "description": "'' for the main scene, 'current', or a scene path."},
                "restart": {"type": "boolean", "description": "Stop the running game first (default false)."},
                "background": {"type": "boolean", "description": "Run the game off screen and muted, never shown or focused (default false). Linux only: needs gamescope."},
                "embed": {"type": "boolean", "description": "Embed the game in the editor's Game view (true) or give it a window of its own (false), for this play only; an embedded game cannot move or resize its window. Default: the Game view's own choice. The reply's embedded says which it was."},
                "user_data": {"type": "string", "enum": ["copy", "empty", "real"], "description": "The game's user:// folder (saves, settings): 'copy' (default) a throwaway copy of the real one, 'empty' a fresh one, 'real' the player's own, which the game may change. The reply's user_data_dir is where it is."},
                "setup": {"type": "string", "description": "GDScript to run in the game once it is up, as with game_run (at most 60 s)."},
            },
        },
    },
    {
        "name": "game_stop",
        "description": "Stop the running game, whether the editor is playing it or it runs in the background.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "game_run",
        "description": (
            "Run GDScript inside the running game (started with game_play) and return its result, like "
            "editor_run: statements form the body of run(ctx), `return` sends a value back, ctx.log() adds "
            "output, and engine output and errors raised meanwhile come back as logs. get_tree() is not "
            "available on the script; use Engine.get_main_loop() for the SceneTree. Debug overlays outlast the "
            "run until cleared or the game stops, and show in game_screenshot: ctx.draw_2d(name, func(canvas: Node2D): ...) "
            "draws over the 2D world in world coordinates with CanvasItem methods (canvas.draw_rect(rect, color), "
            "draw_line, draw_circle, draw_string...); ctx.draw_3d(name, func(painter): ...) draws unlit through "
            "walls with painter.line(a, b, color), triangle(a, b, c, color), quad(a, b, c, d, color), "
            "box(aabb, color, filled) and cross(point, size, color). Both redraw every frame; pass every_frame "
            "false to draw once (for costly scans), and a parent node to draw in its coordinates or viewport. "
            "The same name replaces an overlay; ctx.clear_overlays(name) removes one, or all without a name. "
            "An overlay whose callback raises an error stops redrawing and says so once in game_log, where its "
            "errors point at lines of its code as overlay \"name\" code:N. Errors point at lines of your code as code:N. ctx and untyped lambda parameters are Variants, so "
            "`:=` cannot infer types from them: use `=` or type the parameter. Skeleton3D bone poses read the "
            "animation without skeleton modifiers (spring bones, look-ats), which Godot undoes after each update; "
            "for the pose as shown, read them right after `await skeleton.skeleton_updated`. As with editor_run, a result too long "
            "for a reply is saved to a file and summarized."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "code": {"type": "string", "description": "GDScript to run in the game."},
                "timeout": {"type": "integer", "description": "Seconds to wait for the result (default 60)."},
            },
            "required": ["code"],
        },
    },
    {
        "name": "game_screenshot",
        "description": (
            "Capture the running game's current frame as an image. Input positions for game_input are given in "
            "this image's pixels. To see small details, capture a region instead: node (a 2D node framed by size "
            "world pixels around it, a 3D node by size meters around the middle of its bounding box or, without size, by the bounding box itself, "
            "or a Control's own rectangle) or rect (a world rectangle, or with space 'window' a rectangle of window pixels, for the HUD). Regions are "
            "enlarged without smoothing, by zoom or as far as max_size allows. The reply's region is the "
            "captured rectangle in window pixels, so a world size comes back scaled by the camera's zoom and "
            "the window's stretch; for node and rect captures, world_rect gives it in world coordinates."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "max_size": {"type": "integer", "description": "Longest side in pixels (default 1280; 0 = full size)."},
                "node": {"type": "string", "description": "Node to frame: a path relative to the current scene (like 'Player'), or absolute."},
                "size": {"type": "array", "items": {"type": "number"}, "description": "[width, height] framed around node: world pixels for a 2D node (default [128, 128]), meters for a 3D node (default: fit its bounding box)."},
                "rect": {"type": "array", "items": {"type": "number"}, "description": "[x, y, width, height] to capture, in world coordinates (or window pixels with space 'window')."},
                "space": {"type": "string", "enum": ["world", "window"], "description": "What rect is measured in: 'world' (default) or 'window' pixels, as for HUD and other screen-space UI."},
                "zoom": {"type": "integer", "description": "Whole-number enlargement of the region (default: as large as max_size allows)."},
                "grid": {"type": "integer", "description": "Draw world grid lines this many world pixels apart (e.g. the tile size), labelled with world coordinates along the top and left edges; doubled until lines are a few image pixels apart. For whole-frame and world captures only (default 0: none)."},
            },
        },
    },
    {
        "name": "game_input",
        "description": (
            "Send mouse and keyboard input to the running game, one event per frame. Events: "
            "{type: 'move', x, y}, {type: 'click', x, y, button: 'left'|'right'|'middle', double}, "
            "{type: 'drag', x, y, to_x, to_y, button, steps} (press, move in steps, default 8, release), "
            "{type: 'press'|'release', x, y, button} (hold a mouse button across other events; x, y optional for release), "
            "{type: 'press'|'release', key} and {type: 'press'|'release', action} (hold a key, such as 'Shift' or 'Left', or "
            "an input action until its release, also across game_input calls, so screenshots can be taken meanwhile; "
            "a held Shift, Ctrl or Alt applies to the other key events), "
            "{type: 'scroll', x, y, direction: 'up'|'down', amount}, {type: 'key', key: 'Enter'|'Escape'|'A'|'F1'..., "
            "shift, ctrl, alt} (a tap), {type: 'text', text}, {type: 'action', action, hold}, {type: 'wait', seconds}. "
            "The reply's held lists what is still held. "
            "Positions are pixels of the last game_screenshot; add space: 'viewport' for canvas coordinates "
            "(such as a Control's global_position) or 'window' for window pixels. Mouse events move the real "
            "cursor too in background games (so get_global_mouse_position() and hover checks see them); pass "
            "real_cursor to choose, but in a game on screen it moves the user's mouse."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "events": {"type": "array", "items": {"type": "object"}, "description": "Input events in order."},
                "real_cursor": {"type": "boolean", "description": "Warp the real cursor with mouse events (default: on for background games, off otherwise)."},
            },
            "required": ["events"],
        },
    },
    {
        "name": "game_wait",
        "description": (
            "Let the running game play on its own for up to `seconds`, with error breaks on, and return early "
            "if it stops in the debugger (an error in the game's own code or a breakpoint) or exits. The outcome "
            "is 'paused' (with the error and stack), 'exited' or 'running'. Use it to play until something breaks: "
            "game_run switches error breaks off while its code runs, so errors then are only logged."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "seconds": {"type": "number", "description": "How long to let the game run (default 30, at most 600)."},
            },
        },
    },
    {
        "name": "game_suspend",
        "description": (
            "Freeze or resume the running game, like the Game view's Suspend and Next Frame buttons. While "
            "suspended no node processes (whatever its process_mode), physics and game time stop and input "
            "events are not handled, but the game still draws and answers game_run and game_screenshot: set up "
            "a pose or state with game_run, and the game's own code will not undo it before you capture it. "
            "step_frames plays exactly that many frames and suspends again (it suspends a running game first); "
            "each frame takes a round trip of about 80 ms, so for long jumps resume and suspend instead. Game "
            "code cannot change SceneTree.paused while suspended. The Game view's own Suspend button does not "
            "show this state."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "suspended": {"type": "boolean", "description": "true to freeze the game, false to resume it (default true)."},
                "step_frames": {"type": "integer", "description": "Frames to play before suspending again (default 0, at most 600)."},
            },
        },
    },
    {
        "name": "game_log",
        "description": "Recent output of the running game: printed lines, warnings and errors (the last 500 are kept).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "lines": {"type": "integer", "description": "How many recent lines (default 50)."},
                "clear": {"type": "boolean", "description": "Clear the kept lines afterwards."},
            },
        },
    },
    {
        "name": "diagnostics",
        "description": (
            "Check scripts for errors after editing: syncs from disk, compiles each script fresh and returns "
            "every error with its file and line. Without paths it checks the whole project except res://addons/. "
            "scenes: true also loads every scene to catch broken references and missing resources."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "paths": {"type": "array", "items": {"type": "string"}, "description": "Scripts (.gd) or scenes (.tscn) to check; default the whole project."},
                "scenes": {"type": "boolean", "description": "Also load scenes (default false unless scene paths are given)."},
            },
        },
    },
    {
        "name": "editor_log",
        "description": "Recent output of the Godot editor: printed lines, warnings and errors, including those raised while syncing or importing (the last 500 are kept). A line that repeats while it is among the last few kept, such as warnings printed every frame, is kept once with its count, as \"<line> (N times)\", and moves to the end as the most recent.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "lines": {"type": "integer", "description": "How many recent lines (default 50), counted after the level filter."},
                "level": {"type": "string", "enum": ["all", "warnings", "errors"], "description": "Which lines: all (default), warnings (warnings and errors) or errors only."},
                "clear": {"type": "boolean", "description": "Clear the kept lines afterwards."},
            },
        },
    },
    {
        "name": "tile_info",
        "description": (
            "Inspect a scene's TileMapLayers (the scene being edited by default). With position, the tile at "
            "that world point on every layer: source, texture, atlas coordinates, terrain and its peering "
            "terrains, custom data and collision. With layer alone, a summary of the tiles it uses plus its "
            "TileSet's sources, terrain names and custom data layers. With layer and cells, every tile in that block."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "scene": {"type": "string", "description": "Scene path; default the scene being edited."},
                "position": {"type": "array", "items": {"type": "number"}, "description": "[x, y] world point in the scene's coordinates."},
                "layer": {"type": "string", "description": "TileMapLayer path relative to the scene root, like 'TrainingGround/Ground1'."},
                "cells": {"type": "array", "items": {"type": "integer"}, "description": "[x, y, width, height] block of cells on layer (at most 400 cells)."},
            },
        },
    },
    {
        "name": "texture_view",
        "description": (
            "Show a texture enlarged without smoothing, over a checkerboard, with a pixel grid and the texture "
            "coordinates of grid lines in the margins: for reading sprite-sheet regions (Rect2) off the image. "
            "path may also be a resource that uses a texture, such as an AtlasTexture or an item with a texture "
            "property: its whole sheet is shown with the region it uses outlined in yellow. sprites: true finds "
            "the separate sprites (touching non-transparent pixels) in the shown area, outlines and numbers them "
            "in green and lists them as [x, y, width, height]; sprites that touch each other come out as one box."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "A texture (res://x.png) or a resource that uses one (res://items/x.tres)."},
                "property": {"type": "string", "description": "Which texture of a resource to show, like 'texture' or 'animation_sprites[1]' (default 'texture' or its first)."},
                "rect": {"type": "array", "items": {"type": "integer"}, "description": "[x, y, width, height] part of the texture to show, in texture pixels (default all of it)."},
                "grid": {"type": "integer", "description": "Grid cell size in texture pixels (default 16; 0 for none). Doubled until lines are at least 6 image pixels apart."},
                "zoom": {"type": "number", "description": "Image pixels per texture pixel (default: the largest whole number that fits max_size)."},
                "max_size": {"type": "integer", "description": "Longest side of the image without the margins, when zoom is not given (default 1280)."},
                "sprites": {"type": "boolean", "description": "Find, outline and list the sprites in the shown area (default false)."},
            },
            "required": ["path"],
        },
    },
    {
        "name": "animation_frames",
        "description": (
            "Render an AnimationPlayer animation of a scene at several times without running the game, side by "
            "side in one image with each frame's time in seconds above it: for checking an animation's poses and "
            "timing. 2D scenes are framed once to fit every frame, so the frames line up. 3D scenes use their own "
            "camera, or with view an orthographic camera from that side fitted to the posed character over every "
            "frame; root decides what happens to root motion: the camera follows the root bone (default), the "
            "bone is locked in place, or the camera stays still in the world so the travel shows. The reply's "
            "animation_info gives the clip's length, loop mode, tracks by type and, for a 3D character, its root "
            "motion over the whole clip: start-to-end distance and speed (meters, meters per second), path length, "
            "largest stray from the start and vertical change. Spring bones and other skeleton modifiers play through the "
            "second before each frame, so they hang as in the game. AnimationTrees are switched off so the player drives the animation. Only "
            "@tool scripts run in the editor, so a scene whose code fills in textures or state at runtime looks "
            "empty: pass setup, GDScript run first as the body of setup(root: Node), to set those (e.g. "
            "root.get_node('Sprite').texture = load('res://x.tres').texture)."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "scene": {"type": "string", "description": "Scene path, such as res://scenes/components/weapon.tscn."},
                "animation": {"type": "string", "description": "Animation name; an unknown name lists the ones there are."},
                "player": {"type": "string", "description": "AnimationPlayer path relative to the scene root (default the first one)."},
                "times": {"type": "array", "items": {"type": "number"}, "description": "Times in seconds to show."},
                "count": {"type": "integer", "description": "Without times, this many frames spread from start to end (default 6, at most 64)."},
                "setup": {"type": "string", "description": "GDScript run on the scene before rendering, as the body of setup(root: Node)."},
                "frame_size": {"type": "array", "items": {"type": "integer"}, "description": "[width, height] of each frame in pixels (default [256, 256])."},
                "columns": {"type": "integer", "description": "Frames per row (default up to 6)."},
                "view": {"type": "string", "enum": ["camera", "three_quarter", "front", "back", "left", "right", "top"],
                         "description": "3D: where to look from. 'camera' is the scene's own Camera3D (the default when it has one); the others look at the character's front, back, left or right side (its front is +Z of its skeleton, as imported humanoids face, or of the scene root without one), or between front and left from a little above (three_quarter, the default otherwise), or straight down with the front toward the image's bottom (top)."},
                "focus": {"type": "string", "description": "3D: a bone to frame closely instead of the whole character, with the bones under it (e.g. a hand and its fingers), fitted over every frame; picks three_quarter unless view is given."},
                "root": {"type": "string", "enum": ["follow", "lock", "world"],
                         "description": "3D root motion: 'follow' moves the camera with the root bone so the character stays in place (default), 'lock' pins the root bone's sideways position, 'world' keeps the camera still so the travel shows."},
                "root_bone": {"type": "string", "description": "3D: the bone root motion moves (default: the one an AnimationTree's root_motion_track names, else the skeleton's top bone)."},
            },
            "required": ["scene", "animation"],
        },
    },
    {
        "name": "scene_screenshot",
        "description": (
            "Render a scene to an image without running the game. A Control root is laid out by its own anchors "
            "in a screen of the project's window size (shown even if saved hidden), 2D scenes are framed to fit their content. 3D scenes use their own camera, or with view (the default without "
            "one) an orthographic camera from that side fitted to the scene as posed; a scene without lights gets a sun behind the camera. "
            "Only @tool scripts run in the editor, so nodes a scene creates from code at runtime are missing; "
            "use game_play and game_screenshot for those."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "scene": {"type": "string", "description": "Scene path, such as res://scenes/ui/shop_menu.tscn."},
                "width": {"type": "integer", "description": "Render width in pixels (default: the project's window width)."},
                "height": {"type": "integer", "description": "Render height in pixels (default: the project's window height)."},
                "max_size": {"type": "integer", "description": "Longest side of the returned image (default 1280; 0 = full size)."},
                "view": {"type": "string", "enum": ["camera", "three_quarter", "front", "back", "left", "right", "top"],
                         "description": "3D: where to look from, as in animation_frames: 'camera' is the scene's own Camera3D (the default when it has one), the others a side of the character or scene (three_quarter by default otherwise)."},
            },
            "required": ["scene"],
        },
    },
]
# MCP tool name -> editor plugin tool name.
EDITOR_TOOLS = {"editor_status": "status", "editor_run": "run", "editor_result": "run_result", "editor_cancel": "run_cancel",
                "sync_from_disk": "sync", "import_settings": "import_settings",
                "game_play": "game_play", "game_stop": "game_stop", "game_run": "game_run",
                "game_screenshot": "game_screenshot", "game_input": "game_input", "game_log": "game_log",
                "game_wait": "game_wait", "game_suspend": "game_suspend",
                "diagnostics": "diagnostics", "editor_log": "editor_log", "scene_screenshot": "scene_screenshot",
                "tile_info": "tile_info", "texture_view": "texture_view",
                "animation_frames": "animation_frames", "reload_bridge": "reload", "run_tests": "run_tests"}
# Tools whose result names a PNG to return as an image.
IMAGE_TOOLS = {"game_screenshot", "scene_screenshot", "texture_view", "animation_frames"}

_request_ids = itertools.count(1)


class BridgeError(Exception):
    pass


if os.name == "nt":
    import ctypes
    from ctypes import wintypes

    _kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    _kernel32.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
    _kernel32.OpenProcess.restype = wintypes.HANDLE
    _kernel32.GetExitCodeProcess.argtypes = (wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD))
    _kernel32.GetExitCodeProcess.restype = wintypes.BOOL
    _kernel32.CloseHandle.argtypes = (wintypes.HANDLE,)
    _PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
    _ERROR_ACCESS_DENIED = 5
    _STILL_ACTIVE = 259


def _alive(pid):
    if pid <= 0:
        return False  # os.kill(0, 0) would signal our own process group.
    if os.name == "nt":
        # os.kill(pid, 0) on Windows sends CTRL_C_EVENT instead of checking the process.
        handle = _kernel32.OpenProcess(_PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
        if not handle:
            return ctypes.get_last_error() == _ERROR_ACCESS_DENIED
        try:
            code = wintypes.DWORD()
            return bool(_kernel32.GetExitCodeProcess(handle, ctypes.byref(code))) and code.value == _STILL_ACTIVE
        finally:
            _kernel32.CloseHandle(handle)
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def find_editor():
    editors = []
    for path in glob.glob(os.path.join(CONNECTION_DIR, "editor-*.json")):
        try:
            with open(path, encoding="utf-8") as handle:
                info = json.load(handle)
        except (OSError, ValueError):
            continue
        if _alive(int(info.get("pid", 0))):
            editors.append(info)
    if not editors:
        raise BridgeError(
            "No Godot editor with the Godot Bridge plugin is running for %s. Open the project in the editor and "
            "enable Project > Project Settings > Plugins > Godot Bridge." % PROJECT)
    return max(editors, key=lambda info: info.get("started", 0))


def _timeout_for(tool, args):
    """Tools that wait on purpose get their waiting time on top of TIMEOUT."""
    try:
        if tool == "game_wait":
            return TIMEOUT + min(float(args.get("seconds", 30)), 600.0)
        if tool == "game_run":
            return TIMEOUT + float(args.get("timeout", 60))
        if tool == "run_tests":
            # Every script may take its timeout; their number is not known here.
            return max(3600.0, TIMEOUT)
        if tool == "run":
            # The editor answers with progress at `timeout`; the margin covers blocking code.
            return max(TIMEOUT, float(args.get("timeout", 90)) + 30)
    except (TypeError, ValueError):
        pass
    return TIMEOUT


def call_editor(tool, args):
    editor = find_editor()
    request = {"token": editor["token"], "id": next(_request_ids), "tool": tool, "args": args}
    timeout = _timeout_for(tool, args)
    try:
        with socket.create_connection(("127.0.0.1", int(editor["port"])), timeout=timeout) as connection:
            connection.sendall((json.dumps(request) + "\n").encode("utf-8"))
            data = b""
            while not data.endswith(b"\n"):
                chunk = connection.recv(65536)
                if not chunk:
                    break
                data += chunk
    except socket.timeout:
        hint = " It may be busy running blocking code; editor_result returns that code's result once it finishes." if tool == "run" else ""
        raise BridgeError("The editor did not answer within %d seconds.%s" % (timeout, hint))
    except OSError as error:
        raise BridgeError("Could not reach the editor on port %s: %s" % (editor["port"], error))
    if not data:
        raise BridgeError("The editor closed the connection without answering.")
    # Godot's JSON leaves control characters such as terminal colour codes unescaped.
    return json.loads(data.decode("utf-8"), strict=False)


def _own_source_hash():
    try:
        with open(__file__, "rb") as handle:
            return hashlib.sha256(handle.read()).hexdigest()
    except OSError:
        return None


# The tool definitions the client got are the ones in this file as it was when
# this process started. The client drops arguments it does not know of
# without a word, so a changed file is reported on every reply until a reconnect.
STARTED_SOURCE = _own_source_hash()
STALE_NOTE = (
    "Note: mcp/server.py has changed since this MCP server started, so the client still has the old tool "
    "definitions and silently drops arguments added since. Reconnect the MCP server (/mcp in Claude Code) "
    "to load the new ones."
)


def call_tool(name, args):
    result = _call_tool(name, args)
    current = _own_source_hash()
    if STARTED_SOURCE is not None and current is not None and current != STARTED_SOURCE:
        result["content"].append({"type": "text", "text": STALE_NOTE})
    return result


def _call_tool(name, args):
    if name not in EDITOR_TOOLS:
        return _text_result("Unknown tool: %s" % name, error=True)
    try:
        reply = call_editor(EDITOR_TOOLS[name], args or {})
    except BridgeError as error:
        return _text_result(str(error), error=True)
    if not reply.get("ok"):
        text = reply.get("error", "The editor reported an error.")
        if reply.get("logs"):
            text += "\n\nLogs:\n" + "\n".join(reply["logs"])
        return _text_result(text, error=True)
    result = reply.get("result")
    if name in IMAGE_TOOLS and isinstance(result, dict) and result.get("path"):
        try:
            with open(result["path"], "rb") as handle:
                image = base64.b64encode(handle.read()).decode("ascii")
        except OSError as error:
            return _text_result("Screenshot saved but unreadable: %s" % error, error=True)
        return {"content": [
            {"type": "image", "data": image, "mimeType": "image/png"},
            {"type": "text", "text": json.dumps(result, indent=2)},
        ], "isError": False}
    return _text_result(json.dumps(result, indent=2, ensure_ascii=False))


def _text_result(text, error=False):
    return {"content": [{"type": "text", "text": text}], "isError": error}


def handle(message):
    method = message.get("method")
    params = message.get("params") or {}
    if method == "initialize":
        return {
            "protocolVersion": params.get("protocolVersion", "2025-06-18"),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "godot-bridge", "version": VERSION},
            "instructions": (
                "Godot Bridge connects to the Godot editor open on this project. Edit project files on disk as "
                "usual, then call sync_from_disk (editor_run syncs by default) so the editor sees them. Use "
                "editor_run to inspect or change editor state with full GDScript."
            ),
        }
    if method == "tools/list":
        return {"tools": TOOLS}
    if method == "tools/call":
        return call_tool(params.get("name"), params.get("arguments"))
    if method == "ping":
        return {}
    raise KeyError(method)


def main():
    # MCP messages are UTF-8, but Windows pipes default to the ANSI code page and \r\n.
    sys.stdin.reconfigure(encoding="utf-8")
    sys.stdout.reconfigure(encoding="utf-8", newline="\n")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if "id" not in message:
            continue  # Notifications, such as notifications/initialized, need no reply.
        try:
            response = {"jsonrpc": "2.0", "id": message["id"], "result": handle(message)}
        except KeyError:
            response = {"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32601, "message": "Method not found: %s" % message.get("method")}}
        except Exception as error:  # Keep serving after an unexpected failure.
            response = {"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32603, "message": str(error)}}
        sys.stdout.write(json.dumps(response) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
