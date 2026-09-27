# OmaGAWD for macOS

Native Swift menu bar port of OmaGAWD. Requires macOS 14 or later. AppKit renders the interface; AVFoundation plays local files and Jellyfin streams; Accelerate computes the real 16-band spectrum. No third-party packages, Python process, mpv, browser runtime, or polling server runs with the app.

## Build and open

From the repository root:

```sh
./script/build_and_run.sh --release
```

The optimized application is `dist/OmaGAWD.app`. Move it to Applications if desired. Click the llama in the menu bar or press **Command–Option–O**. The player opens at the top right of that display, just below the menu bar. It has no title bar or window controls and cannot be dragged or resized. The expanded player fills the usable screen height; artist and album lists scale with the display height. Expanded and compact views share the same top-right anchor. The Codex Run action builds and launches a debug version. Swift 6 / Xcode Command Line Tools are needed to build, not to run the app. Builds target the current Mac's architecture.

Other modes: `--build` creates the debug bundle without launching; `--verify` launches and checks the process; `--debug` runs under LLDB; `--logs` and `--telemetry` open the application and stream its process logs.

## Music and controls

Choose **Sources… → + Files / + Folder** for local music, or **Connect to Jellyfin…** in the source menu. Jellyfin accepts a direct HTTP(S) URL, including a `/jellyfin` base path. The server must support byte ranges. Sign-in tokens are saved in macOS Keychain; passwords are not retained. Sign out removes the saved token and attempts server-side revocation.

Browse Artist → Album → Song, search across metadata, play a selection, or append it without interrupting playback. The queue supports duplicates, multiple selection, removal, reordering, clear, shuffle, and repeat off/all/one. Transport includes play/pause, stop, previous/next, seek, and volume. Media keys and Control Centre use macOS Now Playing. **PL** collapses the music desk to a small receiver. Escape or the menu bar button hides the panel while playback continues; **Quit** exits.

| Shortcut | Action |
| --- | --- |
| Command–Option–O | Show/hide globally; conflicts are reported in Shortcuts |
| P / L | Toggle playlist / library when not editing text |
| Command–F / Control–F | Clear filters and focus search |
| Tab / Shift–Tab | Cycle Artist → Album → Songs |
| Arrows / Space | Browse / select |
| Return / double-click | Play selection |
| Option-click / Option–Return | Append selection |
| Command-click / Shift-click | Multiple / range selection in songs or queue |
| Delete | Remove selected queue entries |
| Option–↑ / Option–↓ | Move selected queue entry |
| Escape | Hide player |

## Efficiency and privacy

- Recycled native table cells; library scans and metadata loading are asynchronous.
- Local metadata cache reuses entries when modification time and size are unchanged.
- Remote audio is supplied directly to AVFoundation through authenticated byte-range requests; the app does not download the full library or retain whole audio responses in memory.
- Tokens stay in headers, never audio URLs. API and audio redirects are refused. TLS certificate validation uses the system defaults. HTTP is available for user-selected local servers.
- API responses are limited to 8 MiB; remote library scans to 100,000 tracks / 64 MiB. Local scans stop at 100,000 matching files. Metadata decoding uses AVFoundation, rather than the Linux port's ffprobe metadata-byte limit.
- FFT uses a reusable buffer and runs only while the player panel is visible and audio is playing. The display refreshes at 20 Hz only in that state. No idle animation timer or network polling.
- Removing a source never deletes its files. Preferences store source paths, volume, shuffle, and repeat. Queue contents are session-only, matching the original player.

## Format and distribution limits

Local formats: MP3, AAC/M4A, ALAC, FLAC, WAV, AIFF, CAF, and audio MP4, subject to macOS decoder support. Jellyfin streams original audio; this port does not include mpv's broader Ogg/Vorbis, WMA, or other codec coverage and does not request server transcoding. Unsupported audio reports a playback error.

The build script ad-hoc signs the app for local use. It is not Developer ID signed or notarized for public distribution. App Store sandboxing and launch-at-login are not configured.

## Verification

```sh
./script/test_macos.sh
```

Runs the Swift queue/filter/URL tests, builds the app, creates a disposable loopback Jellyfin fixture, and checks real AVFoundation local and remote playback, pause, seek, PCM spectrum, queue edits, hidden-spectrum shutdown, and redirect rejection. Fixture audio is muted. The fixture needs Python 3 only for tests; the application does not. The script replaces the running development app and writes `dist/smoke-test.txt`. No real account credentials are used or saved.

Manually checked on the development Mac: rendered player and source windows; Command-F clears and filters; Tab cycles all three lists; Option-Return appends; P/L change panes; Option-Down reorders; Delete removes; Escape hides; Command-Option-O shows the player again.

A real Jellyfin account, all supported audio formats, hardware media keys, Intel hardware, and notarized distribution still need separate acceptance checks.
