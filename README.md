# OmaGAWD

A Winamp-inspired Omarchy music player for **Jellyfin and local files**, with a llama bar icon, expandable playlist, frequency visualiser, and media-key support.

![OmaGAWD](preview.png)

## Install

Requires Omarchy/Quickshell, system Python with `python-gobject`, mpv, FFmpeg, `secret-tool`, and zenity.

```sh
./scripts/install.sh
```

Open from the llama icon or app launcher. Connect to Jellyfin, or choose **Local Music → + FILES / + FOLDER**. Sources and sign-in are remembered; the queue is not. Libraries refresh automatically.

**Double-click/Return** replaces the playlist and plays. **+ ADD** or **Option-click/Return** appends without interrupting playback. Removing tracks only changes the playlist.

## Shortcuts

| Key | Action |
|---|---|
| P / L | Toggle playlist / library |
| ⌘F | Clear and focus search |
| Tab / Shift+Tab | Cycle Artist → Album → Songs / backwards |
| ↑ / ↓ | Move through tracks |
| Space | Select/filter |
| Return | Play |
| Option-click / Option-Return | Add to playlist; hold Option to show + |
| Shift+↑/↓ | Extend playlist selection |
| ⌘A | Select all playlist tracks |
| Delete / Backspace | Remove from playlist |
| Option+↑/↓ | Reorder playlist track |
| Escape | Hide player |
| Media keys | Play/pause, previous, next |

Command = Super; Option = Alt. P/L are inactive while typing. Optional global shortcut in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + O", "OmaGAWD", "omarchy-shell shell toggle david.omaamp '{}'")
```

Stop playback before updates: shell reloads can leave orphaned audio processes. Installation/update and test notes: [AGENTS.md](AGENTS.md).
