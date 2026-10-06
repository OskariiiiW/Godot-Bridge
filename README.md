# Godot Bridge

A Godot editor plugin plus an [MCP](https://modelcontextprotocol.io) server that let an AI agent (Claude Code, or any MCP client) work inside your Godot project: run GDScript in the editor and in the running game, play scenes, take screenshots, send input, read logs, check scripts for errors and run tests.

## Requirements

- Godot 4.5 or newer (developed on 4.7)
- Python 3.7 or newer. The MCP server uses only the standard library, so there is nothing to install with pip.
- Optional, Linux only: [gamescope](https://github.com/ValveSoftware/gamescope) for running games in the background (`game_play` with `background`)

## Installation

1. Download `godot-bridge-vX.Y.Z.zip` from the [latest release](https://github.com/OskariiiiW/Godot-Bridge/releases/latest) and extract it into your project folder. It contains `addons/godot_bridge/`, so the files land in the right place. Alternatively, copy `addons/godot_bridge/` from this repository into your project's `addons/` folder.
2. In Godot, open **Project > Project Settings > Plugins** and enable **Godot Bridge**. This also adds a `GodotBridgeGame` autoload, which the game tools use to reach the running game.
3. Start your agent in the project folder. When the plugin is enabled, it adds a `godot-bridge` server to `.mcp.json` in your project, creating the file if needed. Claude Code reads that file and asks once whether to trust the server. The entry uses a path relative to the project, so you can commit `.mcp.json` for everyone working on it.

   The plugin never overwrites an existing `.mcp.json`: it adds its entry and keeps the rest. It leaves the file alone if it already runs the server, or if it isn't valid JSON (the editor's output then says so). If the plugin was already enabled before this feature existed, turn it off and on again.

   To register the server by hand instead, run this from your project folder (on Windows, use `py` or `python` instead of `python3`):

   ```sh
   claude mcp add godot-bridge -- python3 addons/godot_bridge/mcp/server.py
   ```

   Clients that don't read `.mcp.json` take the same command in their own config, for example:

   ```json
   {
     "mcpServers": {
       "godot-bridge": {
         "command": "python3",
         "args": ["/path/to/your/project/addons/godot_bridge/mcp/server.py"]
       }
     }
   }
   ```

4. Keep the project open in the editor while the agent works. The server finds the editor on its own.

### Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `GODOT_BRIDGE_PROJECT` | the project the addon is in | Project folder to connect to, if the server runs from somewhere else |
| `GODOT_BRIDGE_TIMEOUT` | `120` | Seconds to wait for the editor to answer a call |

## Tools

| Tool | What it does |
|---|---|
| `editor_status` | Godot version, project path, open scenes and unsaved edits, the scene being played |
| `editor_run` | Run GDScript inside the editor and return its result |
| `editor_result` | Get the result of an `editor_run` that outlasted its timeout |
| `editor_cancel` | Stop a running `editor_run` |
| `editor_log` | Recent editor output: prints, warnings and errors |
| `sync_from_disk` | Make the editor pick up files changed outside it |
| `diagnostics` | Compile scripts fresh and report every error with its file and line |
| `run_tests` | Run the project's headless test scripts and report pass/fail |
| `import_settings` | Read or change import settings on one or many assets |
| `game_play` | Play a scene and wait until it is running |
| `game_stop` | Stop the running game |
| `game_run` | Run GDScript inside the running game |
| `game_screenshot` | Capture the running game's current frame |
| `game_input` | Send mouse and keyboard input to the game |
| `game_wait` | Let the game run for a while, returning early on an error |
| `game_suspend` | Freeze, resume or step the game frame by frame |
| `game_log` | Recent game output: prints, warnings and errors |
| `scene_screenshot` | Render a scene to an image without running the game |
| `animation_frames` | Render several frames of an animation side by side |
| `texture_view` | Show a texture enlarged with a pixel grid, for reading sprite sheets |
| `tile_info` | Inspect a scene's TileMapLayers |
| `reload_bridge` | Apply edits to the bridge's own scripts without restarting the plugin |

Each tool's full description, which the agent sees, is in [`mcp/server.py`](addons/godot_bridge/mcp/server.py).

By default, games started with `game_play` get a throwaway copy of the project's `user://` folder, so testing never changes your real saves or settings. Pass `user_data: "real"` to use the real one.

## How it works

When the plugin is enabled, the editor listens on a random localhost port and writes the port and a random token to `.godot/godot_bridge/editor-<pid>.json`. The MCP server talks to the agent over stdio, reads that file, and forwards each tool call to the editor. The editor reaches running games through Godot's debugger connection.

## Security

This plugin lets the agent **run any GDScript in your editor and game**, and GDScript can read and write files and start programs. Only use it with agents you trust, on projects you have backed up or keep in version control.

The editor only listens on `127.0.0.1` and rejects requests without the token. Any program running as your user can read that token, though.

## License

[MIT](LICENSE)
