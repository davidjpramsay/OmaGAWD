# OmaGAWD for macOS

Native Swift menu bar port of OmaGAWD. Requires macOS 14 or later. AppKit renders the interface; AVFoundation plays local files, Jellyfin streams, and live radio; Accelerate computes the real 16-band spectrum. No third-party packages, Python process, mpv, browser runtime, or polling server runs with the app.

## Download

Download the signed and notarized [macOS beta](https://github.com/davidjpramsay/OmaGAWD/releases/tag/macos-v0.1.0-beta.1). Open the DMG, drag OmaGAWD to Applications, and launch it. The universal app supports Apple silicon and Intel on macOS 14 or later.

The published beta predates radio discovery. Build the current `codex/native-macos` source branch for the features described below.

## Build and open

From the repository root:

```sh
./script/build_and_run.sh --release
```

The optimized application is `dist/OmaGAWD.app`. Move it to Applications if desired. Click the llama in the menu bar or press **Command–Option–O**. The player opens at the top right of the display under the pointer, just below the menu bar, including over full-screen apps. It has no title bar or window controls and cannot be dragged or resized. Long track details truncate within the panel; hovering reveals the full text. The expanded player fills the usable screen height; artist and album lists scale with the display height. Expanded and compact views share the same top-right anchor and refit when the display or active Space changes. The Codex Run action builds and launches a debug version. Swift 6 / Xcode Command Line Tools are needed to build, not to run the app. Builds target the current Mac's architecture.

Other modes: `--build` creates the debug bundle without launching; `--verify` launches and checks the process; `--debug` runs under LLDB; `--logs` and `--telemetry` open the application and stream its process logs.

## Music and controls

Choose **Sources… → + Files / + Folder** for local music, or **Connect to Jellyfin…** in the source menu. Jellyfin accepts a direct HTTP(S) URL, including a `/jellyfin` base path. The server must support byte ranges. Sign-in tokens are saved in macOS Keychain; passwords are not retained. Sign out removes the saved token and attempts server-side revocation.

Browse Artist → Album → Song, search across metadata, play a selection, or append it without interrupting playback. The queue supports duplicates, multiple selection, removal, reordering, clear, shuffle, and repeat off/all/one. Transport includes play/pause, stop, previous/next, seek, and volume. Media keys and Control Centre use macOS Now Playing. **PL** collapses the music desk to a small receiver. Escape or the menu bar button hides the panel while playback continues; **Quit** exits.

The header llama alternates between running man and side shuffle every ten seconds of playback. It rests when playback pauses or stops, and respects macOS Reduce Motion. The menu bar uses a 16-point SVG llama with the system's monochrome tint.

Choose **Radio** in the music source menu. **Saved** starts with the same 14 Cliamp stations as Omarchy, including Omarchy, Lofi, Synthwave and the NCS channels. **Discover** searches [Radio Browser](https://www.radio-browser.info/) by station name, genre, country or language. Station names get the main column; country is shown separately and full details appear on hover. Select a result and **+ SAVE**, or use **+ STATION** to enter a name and direct HTTP(S) stream link. **− FORGET** removes a saved station without changing the queue or interrupting playback. Return tunes in, Option–Return appends, and arrows browse without starting playback. Saved stations work independently of Jellyfin sign-in and directory availability.

Radio shows **LIVE**, disables seeking, displays stream-provided song titles, and supports the usual volume, queue, media controls and llama dances. A station that disconnects stops with an error and can be reconnected with Play. Live streams restart at the current broadcast when resumed; they do not retain a seekable listening history. After an app restart, the radio queue is restored paused and connects only when Play is pressed.

| Shortcut | Action |
| --- | --- |
| Command–Option–O | Show/hide globally; conflicts are reported in Shortcuts |
| P / L | Toggle playlist / library when not editing text |
| Command–F / Control–F | Clear filters and focus search |
| Tab / Shift–Tab | Cycle Artist → Album → Songs, or radio search fields and stations |
| Arrows / Space | Browse / select |
| Home / End | First / last row |
| Command–A | Select all songs or queue entries |
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
- Tokens stay in headers, never audio URLs. API and audio redirects are refused. TLS certificate validation uses the system defaults. HTTP is accepted for explicitly selected servers, including public hosts, and sends credentials without encryption. Prefer HTTPS.
- API responses are limited to 8 MiB; remote library scans to 100,000 tracks / 64 MiB. Local scans stop at 100,000 matching files. Metadata decoding uses AVFoundation, rather than the Linux port's ffprobe metadata-byte limit.
- FFT uses a reusable buffer and runs only while the player panel is visible and audio is playing. The spectrum and cached llama poses share a 30 Hz display timer only in that state. No idle animation timer or network polling.
- Removing a source never deletes its files. Preferences store source paths, volume, shuffle, repeat, and the selected library. Queue order, duplicate entries, current track, and position are saved locally and restored with playback paused after restart. Playback position is checkpointed every five seconds and when pausing, seeking, or quitting. Session files contain track metadata and local paths; sign-in tokens remain in Keychain.
- Keychain access runs off the UI thread. Refresh retries failed Jellyfin library discovery or saved sign-in access; local music can still refresh while Jellyfin is unavailable.
- Radio streams receive no Jellyfin authorization. Custom station links cannot contain credentials, and directory entries with private/local addresses are discarded. Search uses two Radio Browser mirrors, bounded requests, a 2 MiB response limit and a maximum of 1,000 results. Saved stations are written atomically to `~/Library/Application Support/com.davidjpramsay.OmaGAWD/radio.json` with owner-only permissions; damaged files are backed up before starting with the built-in catalogue.

## Format and distribution limits

Local formats: MP3, AAC/M4A, ALAC, FLAC, WAV, AIFF, CAF, and audio MP4, subject to macOS decoder support. Jellyfin streams original audio; this port does not include mpv's broader Ogg/Vorbis, WMA, or other codec coverage and does not request server transcoding. Unsupported audio reports a playback error.

Radio accepts direct MP3/AAC streams and HLS links supported by AVFoundation. PLS/M3U/XSPF playlist files and sign-in streams are unsupported. Song titles depend on station metadata. The live-radio spectrum uses Apple's mixed-output audio tap on macOS 27 or later; older systems can play radio and animate the llama but may not expose stream PCM for the spectrum. Local and Jellyfin spectrum support is unchanged. See Apple's [mixed-output tap description](https://developer-rno.apple.com/streaming/Whats-new-HLS.pdf).

The development build script ad-hoc signs the app for local use. Published DMGs are Developer ID signed and Apple notarized. App Store sandboxing, automatic updates, and launch-at-login are not configured.

Maintainers can create a universal signed release with `SIGNING_IDENTITY="Developer ID Application: …" NOTARY_PROFILE="your-profile" ./script/release_macos.sh`. This requires a Developer ID certificate/private key and saved notarytool credentials; the script verifies and staples the app and DMG before producing a SHA-256 file. It does not publish automatically.

## Verification

```sh
./script/test_macos.sh
```

Runs the Swift queue/filter/URL tests, dance timing tests, startup recovery and session restoration tests, radio validation/persistence/search/paging tests, and M4A/missing-source/pause-during-loading regressions. It builds the app and creates disposable loopback Jellyfin and ICY radio fixtures, checking real AVFoundation playback, live titles, pause, seek, PCM spectrum, queue edits, dance rotation, hidden-animation shutdown, stream teardown and redirect rejection. Radio PCM verification runs on macOS 27 or later. Fixture audio is muted. The fixture needs Python 3 only for tests; the application does not. The script replaces the running development app and writes `dist/smoke-test.txt`. No real account credentials or playback sessions are used or saved by the tests.

Manually checked on the development Mac: rendered player and source windows; Command-F clears and filters; Tab cycles all three lists; Option-Return appends; P/L change panes; Option-Down reorders; Delete removes; Escape hides; Command-Option-O shows the player again.

A real Jellyfin account, all supported audio formats, hardware media keys, and Intel hardware still need separate acceptance checks. Release signing, notarization and Gatekeeper acceptance are verified during packaging.
