# OmaGAWD maintenance notes

## Scope and architecture

OmaGAWD is a native Omarchy/Quickshell music plugin, not a web app or Codex plugin. The public name is OmaGAWD; keep internal `david.omaamp`, the `omaamp` desktop-entry/icon name, and Secret Service attributes compatible with existing installs.

- `BarWidget.qml`: llama button and popup ownership.
- `OmaAmp.qml`: state, JSON-lines backend process, panel focus, keyboard shortcuts, and timed library refresh.
- `Receiver.qml`, `Visualizer.qml`: compact head unit and real 16-band spectrum with peak markers.
- `Library.qml`, `TextList.qml`: library/queue views, selection and keyboard interaction.
- `backend.py`: Jellyfin API, local queue, mpv IPC and playback state.
- `local_library.py`: explicitly chosen local paths, persistent sources, cached ffprobe tags, recursive scans.
- `session_store.py`: Secret Service reconnect token and last successful library.
- `spectrum.py`: analysis-only filter bank; preserve the playback signal.
- `mpris.py`: Gio/GLib desktop media controls and metadata.
- `scripts/install.sh`: copies plugin files; refuses to overwrite an existing install.
- `scripts/preview.sh`: native standalone preview; uses the real backend and keyring.

The backend launches with `/usr/bin/python3` because system `python-gobject` supplies Gio/GLib. Keep all Python modules in the installer copy list. Local music uses ffprobe and zenity. Use the native desktop portal picker via zenity without GTK/GDK portal overrides. The stale Strata service path was repaired to /usr/bin/strata; do not reinstate the direct GTK chooser workaround. No pip/npm dependencies are needed.

## Product behaviour to preserve

Keep the head and expanding pane the same width. The pane expands downward to the available screen height with normal Omarchy margins. Use shared theme/font/tooltip components; the spectrum intentionally uses classic green/yellow/red segments. The llama is neutral unless playing; the connected dot uses the theme accent.

Library: text-based Artist → Album → Song browser, short “Search” placeholder, inline × to clear query and filters. No library Remove button, reset row, or manual refresh button. Refresh on opening (15-second throttle), then every minute while browsing; preserve valid selections/search and leave playback alone. Remember the last successfully loaded Jellyfin library; fall back if unavailable.

- Click or Space selects/filters. Return or double-click replaces the queue with the whole targeted artist/album or single song and plays.
- Option-click/Option-Return appends only; a little + marks the hovered/focused row while held. Command-click is not the add gesture.
- Library Tab/Shift+Tab cycles only Artist, Album, Songs.
- Command+F clears filters and focuses search. Accept native Meta and translated Control; slash is not a shortcut.
- Playlist opens with track focus. Arrows select; Shift+arrows extends; Return plays; Delete/Backspace removes; Command+A selects all; Option+arrows reorders.
- P/L toggle playlist/library only outside text input. Escape hides the popup.
- Media keys use MPRIS, including when the popup is hidden.

The top-right source button opens a themed menu for Local Music, adding local files/folders, switching to Jellyfin, and account settings. Local Music is listed only after files/folders have been added; add-source actions remain available. Its label reflects the selected source; the connection dot only appears for Jellyfin. Local files/folders are also available through Local Music with + FILES/+ FOLDER and saved sources. File drag-and-drop, playlist-file import/export, and radio are proposed only. Do not describe them as implemented. Queue persistence and server-playlist sync are also not implemented.

## Credentials and playback

Never log tokens/passwords or put them in argv/stream URLs. Secret-tool receives saved data over stdin; passwords are not saved. Keep TLS verification, the modern Authorization header, and stale-network-response protection. Removing items affects the local queue only. Appending must preserve current track, position, and play/pause state. Clear mpv HTTP authentication headers before local playback. Never send a local path to Jellyfin. Saved local roots live in the user config, never in the repository; do not crawl unselected folders.

## Verification

Run backend checks with:

```sh
dbus-run-session -- /usr/bin/python3 -m unittest discover -s tests -v
git diff --check
bash -n scripts/install.sh scripts/preview.sh
```

Use an isolated session bus for MPRIS tests to avoid controlling the real player. Integration tests use a local HTTP server and silent mpv output. QML changes need load/render checks; keyboard changes need focus and modifier verification. Test empty lists, filtering, queue model updates, and forward/reverse focus traversal when relevant. Do not claim visual/input checks from Python test results alone.

## Installation and reloads

Use the Omarchy skill for desktop configuration/installed-plugin work. `/usr/share/omarchy` is read-only reference material. The installed copy is `~/.config/omarchy/plugins/david.omaamp`; repo edits do not deploy themselves.

**Known issue:** shell/plugin reloads have left orphaned mpv processes playing while a new UI shows no track. Stop playback before modifying installed files. If orphaned playback already exists, identify only mpv instances with this app's `--input-ipc-server=/tmp/omaamp-…/mpv.sock` argument and stop those. Never blanket-kill mpv. Tell the user a reload stops playback. A durable parent/child cleanup fix remains outstanding.

After deployment, restart using `omarchy restart shell`, reopen using `omarchy-shell shell summon david.omaamp '{}'`, and check logs. Rescanning alone has previously left cached QML. Avoid synthetic keyboard input while the user is typing in another app.

## Documentation and Git

Keep README behaviour, shortcuts, dependencies, limitations, installer module list, and sample preview in sync. Use sample music data for screenshots; do not publish personal server addresses or credentials. Preserve unrelated changes. Commit/push when requested; do not recreate or delete the existing GitHub repository during routine updates.
