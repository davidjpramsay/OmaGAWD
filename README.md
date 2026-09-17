# OmaGAWD

A native Omarchy shell plugin for streaming a Jellyfin music library. A compact Winamp-inspired receiver in the native Omarchy top-bar popup, with a toggleable playlist pane. The library lives in that pane: text-only artist → album → song browsing, with no extra dashboard or equalizer window.

![OmaGAWD using the active Omarchy theme; sample music data](preview.png)

## Run

Requires the current plugin-capable Omarchy shell, system Python 3 with `python-gobject`, mpv, Quickshell, and `secret-tool` (libsecret). There are no pip or npm dependencies.

Try it without installing:

```bash
./scripts/preview.sh
```

Install into your user plugin directory, enable it, add an application launcher, and open it:

```bash
./scripts/install.sh
```

Click the **llama icon** beside the top bar’s audio controls to toggle the player. You can also launch **OmaGAWD** from your app launcher, or run:

```bash
omarchy-shell shell summon david.omaamp '{}'
```

The installer copies source into `~/.config/omarchy/plugins/david.omaamp`. It refuses to overwrite an existing installation. It never edits `/usr/share/omarchy`. Before updating, stop playback. Copy the changed QML/Python files into the existing plugin directory, then run `omarchy restart shell` and reopen the player. Saved sign-in and the selected library reconnect automatically; the queue is not restored.

**Known reload issue:** an mpv process can survive its backend during shell/plugin reloads, leaving audio playing behind a fresh interface. Stop playback before editing installed files. If audio is already orphaned, identify only this app’s mpv processes by their `--input-ipc-server=/tmp/omaamp-…/mpv.sock` argument and stop those processes before reopening. Do not terminate unrelated mpv players. Automatic process cleanup still needs a permanent fix.

## Connect and listen

1. Open **PL**, then **CONNECT**. Enter your Jellyfin server URL, username, and password.
2. Select a music library from the folder dropdown. The last selected music library is remembered alongside your sign-in and restored on restart, falling back to the first available library if it no longer exists; all pages of its songs are fetched. The selected library refreshes when opened (at most once per 15 seconds) and every minute while you browse. Search, valid selections, and playback are preserved; failed updates keep the previous library and retry on the next check.
3. Select an artist, then optionally an album. **+ ADD** queues every song in that selection. Select individual songs with Ctrl/Shift. Double-click an artist, album, or song to replace the playlist with that entire artist, album, or single song and start playing immediately. Search filters do not truncate an artist or album when double-clicked; **+ ADD** still appends the current selection. Click a selected artist/album again or use **×** in the search field to widen the selection.
4. To remove music, open **PLAYLIST**, select queued tracks, and use **− SELECTED**. Removal only affects the local queue; it never deletes server media.
5. Open **PLAYLIST** and double-click a track to play. Ctrl/Shift-click selects tracks to remove; the **↑/↓ buttons** or **Option+↑/↓** reorder one highlighted entry. Plain keyboard ↑/↓ moves the selection. Duplicates are independent queue entries. **CLEAR** empties the queue.
6. **PL** toggles the playlist pane below the receiver. Click outside the popup, press Escape, or click the llama again to hide it while playback continues. Reopen from the launcher. **■** stops playback.

Transport includes previous/next, play/pause, stop, seek, volume, shuffle, and repeat off → all → one. Removing the playing entry stops it and selects its successor. Natural EOF advances; a failed stream displays an error and stops instead of skipping the entire library.

The connection button in the playlist opens the disconnect screen. **Sign out** clears the library, queue, and saved keyring entry, and requests server-side token revocation.

## Design and integration

The Winamp references inform the inset digital readout, monospace hierarchy, compact transport row, small title rails, and playlist behavior. Native `qs.Commons.Color` and `Style` tokens supply live colors, fonts, spacing, focus/hover states, and corners. The music browser uses the shell's shared text fields. Both collapsed and expanded views keep the same 460-unit width; opening the playlist fills the available vertical space down to the normal bottom margin. Artists and albums sit above the full-width song list. The shell’s shared `KeyboardPanel` anchors the popup to the llama button with standard margins, padding, borders, focus, and outside-click dismissal. A classic Winamp-style 16-band frequency spectrum displays bass on the left and treble on the right, with segmented green/yellow/red bars and falling peak markers. Log-spaced filters measure 50 Hz–16 kHz on a separate analysis branch in mpv, leaving the playback signal unchanged. The popup samples these measurements at 15 Hz. It goes idle on pause or stop. The standard-size llama bar icon is neutral while idle and uses the theme accent only during playback.

The manifest uses the installed Omarchy schema (`bar-widget`, `entryPoints.barWidget`). `OmaAmp.qml` implements `open`, `close`, and `toggle`; a Python process exchanges JSON lines over stdin/stdout and controls mpv through a private Unix socket. Both API and streaming requests use `Authorization: MediaBrowser ... Token="..."`, including servers with legacy authorization disabled.

## Session and streaming

Passwords are cleared from the field after submission and never saved. After successful login, the server URL, username, user/device IDs, last successfully loaded library, and reconnect token are saved in the desktop Secret Service keyring using `secret-tool`. The token is sent to the keyring over stdin, never in command-line arguments. Startup restores and validates that session automatically; transient network failures keep the saved session, while an expired token prompts a new sign-in. If the keyring is unavailable, login still works for the current session and a visible error explains why it could not be remembered. Tokens reach mpv as HTTP headers, never in stream URLs. TLS verification stays enabled. Use HTTPS for remote servers. API redirects are rejected; enter the final server URL, including its base path if applicable.

Streaming uses Jellyfin's original audio endpoint and mpv decoding (FLAC, MP3, AAC, and other formats supported by the installed mpv). OmaGAWD does not negotiate transcoding, persist queues across shell restarts, or sync server playlists. Desktop media keys are supported through MPRIS. Direct streaming must be allowed by the Jellyfin account. Large libraries are fetched completely into memory before browsing.

API references: [Jellyfin authentication](https://kotlin-sdk.jellyfin.org/guide/authentication.html), [Jellyfin Audio API](https://typescript-sdk.jellyfin.org/classes/generated-client.AudioApi.html). The installed `/usr/share/omarchy/shell/README.md` and `Commons/Style.qml` are the plugin and style contracts used here.

## Validation

```bash
dbus-run-session -- /usr/bin/python3 -m unittest discover -s tests -v
```

The 29 Python tests cover authentication, paginated libraries, token privacy, remembered library selection and fallback, queue replacement, append without interruption, duplicate removal/reordering, shuffle/repeat, stale network responses, desktop media commands, and actual streamed-audio frequency measurement with silent output. The HTTP, mpv, and D-Bus integration tests need local socket access. Use system Python so the MPRIS test runs rather than being skipped.

UI changes also need a QML load/render check and focused keyboard/mouse checks. Python tests do not establish that compositor shortcuts or focus navigation work. See [AGENTS.md](AGENTS.md) for the project’s maintenance notes.


## Keyboard shortcuts

- **Option + Command + O** (Alt + Super + O): optional global show/hide binding; configure it below (the installer does not add it).
- **P**: open the playlist; press again to collapse it.
- **L**: open the library; press again to collapse it. Opens sign-in when disconnected.
- **Command+F**: open the library, clear the search and artist/album filters, and focus search ready for typing. When disconnected, opens sign-in.
- **Library ↑/↓, Space, Return**: move the highlight, select/filter without playback, and replace the playlist/start playback, respectively.
- **Tab / Shift+Tab**: cycle Artist → Album → Songs, or backwards, while browsing the library. Tab from search enters Artist; Command+F returns to search.
- **Option-click / Option-Return**: append the targeted artist, album, or song without changing playback. Holding Option shows **+** on the hovered or keyboard-focused library row. Option is the Alt modifier on Linux.
- **Playlist keyboard**: opening the playlist focuses its tracks. ↑/↓ move and select, Shift+↑/↓ extend selection, Home/End jump, Space selects, Return plays, Delete/Backspace removes, Command+A selects all, and Option+↑/↓ moves the highlighted track.
- **Escape**: close the popup.

Command is Meta/Super; this Mac-style Omarchy setup can translate it to Control. Search and playlist Select All accept both forms. Option uses Alt. `/` is not a search shortcut.

P and L apply only inside the popup and never while typing into search or sign-in fields. Switching between P and L selects that view without closing the pane.

For the global shortcut, add this to `~/.config/hypr/bindings.lua` after checking for conflicting bindings:

```lua
o.bind("SUPER + ALT + O", "OmaGAWD", "omarchy-shell shell toggle david.omaamp '{}'")
```

OmaGAWD registers as `org.mpris.MediaPlayer2.OmaGAWD` for desktop media keys, including play/pause, next, and previous while the popup is hidden. It publishes track metadata and playback status using the [MPRIS desktop media interface](https://specifications.freedesktop.org/mpris-spec/latest/Player_Interface.html).

## Planned sources (not implemented)

Local music folders and individual files are the next proposed inputs, followed by M3U/M3U8 playlist import/export and internet-radio URLs. These are design ideas only: the current app connects to Jellyfin libraries. The intended direction is to reuse the existing artist/album/song browser and queue controls, with Local Music alongside Jellyfin libraries in the selector.
