# OmaGAWD

A native Omarchy shell plugin for streaming a Jellyfin music library. A compact Winamp-inspired receiver in the native Omarchy top-bar popup, with a toggleable playlist pane. The library lives in that pane: text-only artist → album → song browsing, with no extra dashboard or equalizer window.

![OmaGAWD using the active Omarchy theme; sample music data](preview.png)

## Run

Requires the current plugin-capable Omarchy shell, Python 3, mpv, Quickshell, and `secret-tool` (libsecret). There are no pip or npm dependencies.

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

The installer copies source into `~/.config/omarchy/plugins/david.omaamp`. It refuses to overwrite an existing installation. It never edits `/usr/share/omarchy`. To update, copy the changed QML/Python files into the existing plugin directory; because this plugin is kept loaded for playback, restart the shell when updating its code (this stops playback; saved sign-in reconnects automatically).

## Connect and listen

1. Open **PL**, then **CONNECT**. Enter your Jellyfin server URL, username, and password.
2. Select a music library from the folder dropdown. The first music library loads automatically; all pages of its songs are fetched.
3. Select an artist, then optionally an album. **+ ADD** queues every song in that selection. Select individual songs with Ctrl/Shift, or double-click a song to append it. Click a selected artist/album again or use **RESET FILTERS** to widen the selection.
4. **− REMOVE** removes those songs from the local queue, including duplicate occurrences. It never deletes server media.
5. Open **PLAYLIST** and double-click a track to play. Ctrl/Shift select tracks to remove; ↑/↓ reorder one selected entry. Duplicates are independent queue entries. **CLEAR** empties the queue.
6. **PL** toggles the playlist pane below the receiver. Click outside the popup, press Escape, or click the llama again to hide it while playback continues. Reopen from the launcher. **■** stops playback.

Transport includes previous/next, play/pause, stop, seek, volume, shuffle, and repeat off → all → one. Removing the playing entry stops it and selects its successor. Natural EOF advances; a failed stream displays an error and stops instead of skipping the entire library.

The connection button in the playlist opens the disconnect screen. **Sign out** clears the library, queue, and saved keyring entry, and requests server-side token revocation.

## Design and integration

The Winamp references inform the inset digital readout, monospace hierarchy, compact transport row, small title rails, and playlist behavior. Native `qs.Commons.Color` and `Style` tokens supply live colors, fonts, spacing, focus/hover states, and corners. The music browser uses the shell's shared text fields. Both collapsed and expanded views keep the same 460-unit width; opening the playlist fills the available vertical space down to the normal bottom margin. Artists and albums sit above the full-width song list. The shell’s shared `KeyboardPanel` anchors the popup to the llama button with standard margins, padding, borders, focus, and outside-click dismissal. A 24-bar audio-level visualizer displays recent RMS measurements from the playing track, sampled from mpv at 15 Hz while the popup is visible. It goes idle on pause or stop. The standard-size llama bar icon is neutral while idle and uses the theme accent only during playback.

The manifest uses the installed Omarchy schema (`bar-widget`, `entryPoints.barWidget`). `OmaAmp.qml` implements `open`, `close`, and `toggle`; a Python process exchanges JSON lines over stdin/stdout and controls mpv through a private Unix socket. Both API and streaming requests use `Authorization: MediaBrowser ... Token="..."`, including servers with legacy authorization disabled.

## Session and streaming

Passwords are cleared from the field after submission and never saved. After successful login, the server URL, username, user/device IDs, and reconnect token are saved in the desktop Secret Service keyring using `secret-tool`. The token is sent to the keyring over stdin, never in command-line arguments. Startup restores and validates that session automatically; transient network failures keep the saved session, while an expired token prompts a new sign-in. If the keyring is unavailable, login still works for the current session and a visible error explains why it could not be remembered. Tokens reach mpv as HTTP headers, never in stream URLs. TLS verification stays enabled. Use HTTPS for remote servers. API redirects are rejected; enter the final server URL, including its base path if applicable.

Streaming uses Jellyfin's original audio endpoint and mpv decoding (FLAC, MP3, AAC, and other formats supported by the installed mpv). This initial version does not negotiate transcoding, persist queues across shell restarts, sync server playlists, or expose MPRIS/media-key integration. Direct streaming must be allowed by the Jellyfin account. Large libraries are fetched completely into memory before browsing.

API references: [Jellyfin authentication](https://kotlin-sdk.jellyfin.org/guide/authentication.html), [Jellyfin Audio API](https://typescript-sdk.jellyfin.org/classes/generated-client.AudioApi.html). The installed `/usr/share/omarchy/shell/README.md` and `Commons/Style.qml` are the plugin and style contracts used here.

## Validation

```bash
python3 -m unittest discover -s tests -v
```

Tests cover paginated libraries, URL/base-path handling, HTTP authentication, credential-free state/URLs, duplicate queue entries, remove/reorder behavior, shuffle, repeat/EOF, stale responses, and real authenticated HTTP audio decoding and nonzero visualizer measurements through mpv with silent output. The HTTP and mpv integration tests need local socket access.

