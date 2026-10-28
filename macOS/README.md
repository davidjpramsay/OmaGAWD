# OmaGAWD for macOS

Native Swift menu bar port of OmaGAWD. Requires macOS 14 or later. AppKit renders the interface; AVFoundation plays local files, Jellyfin streams, and live radio; Accelerate computes the real 16-band spectrum. Sparkle handles signed app updates. No Python process, mpv, browser runtime, or polling server runs with the app.

## Download

Download the signed and notarized [macOS 0.2.2 beta](https://github.com/davidjpramsay/OmaGAWD/releases/tag/macos-v0.2.2-beta.1), including in-app updates, radio discovery and all four llama dances. Open the DMG, drag OmaGAWD to Applications, and launch it. The universal app supports Apple silicon and Intel on macOS 14 or later.

## Current development version

The native Mac source is now **0.3.0 (build 10)**. It ports the Omarchy work through `e3b6beb` (the pushed 0.9.2 development branch), including settings, saved playlists, recents, gapless preloading, live normalization, safe music drops, consolidated sources and the smoother head-bang shoulder. The latest additions are the Omarchy receiver layout, native shuffle/repeat icons with accent-colored active indicators, All artists... / All albums... library rows, and remote buffering/recovery for Jellyfin listening. The downloadable signed release above remains **0.2.2** until a new Mac beta is packaged, notarized and published. See [port coverage and validation](PORTING-0.3.0.md).

## Updates

Choose **Check for Updates…** from the player's gear menu or the **OmaGAWD** application menu. Sparkle checks the macOS release feed, offers available updates, and downloads, verifies, installs and restarts the app when you approve the update. Checks are manual by default; background checks and unattended installation are disabled. The feed and downloads are signed with the app's update key, and published apps are Developer ID signed and notarized. The updater sends no music library, account credentials or system profile.

Version 0.2.0 and earlier need one manual download of 0.2.2 to gain the updater. Install the app in Applications before updating. Queue and playback position survive a restart; playback resumes paused.

## Build and open

From the repository root:

```sh
./script/build_and_run.sh --release
```

The optimized application is `dist/build.noindex/OmaGAWD.app`. Development and release staging folders use `.noindex` to keep extra copies out of Spotlight. Keep the installed app in `/Applications/OmaGAWD.app` for everyday use. Click the llama in the menu bar or press **Command–Option–O**. The player opens at the top right of the display under the pointer, just below the menu bar, including over full-screen apps. It has no title bar or window controls and cannot be dragged or resized. Long track details truncate within the panel; hovering reveals the full text. The expanded player fills the usable screen height; artist and album lists scale with the display height. Expanded and compact views share the same top-right anchor and refit when the display or active Space changes. The Codex Run action builds and launches a debug version. Swift 6 / Xcode Command Line Tools are needed to build, not to run the app. Builds target the current Mac's architecture.

Other modes: `--build` creates the debug bundle without launching; `--verify` launches and checks the process; `--debug` runs under LLDB; `--logs` and `--telemetry` open the application and stream its process logs.

## Music and controls

Choose **Settings → Sources → Local Music → + Files / + Folder**, or **Settings → Sources → Jellyfin → Connect…**. The source menu switches Jellyfin, Local Music and Radio; it remembers the last Jellyfin library. Imports and source removal keep the current queue. Drop supported music files or folders onto the player to add their music to the library and queue. Jellyfin accepts a direct HTTP(S) URL, including a `/jellyfin` base path. The server must support byte ranges. Sign-in tokens are saved in macOS Keychain; passwords are not retained. Sign out removes the saved token and attempts server-side revocation.

Browse Artist → Album → Song, search across metadata, play a selection, or append it without interrupting playback. The queue supports duplicates, multiple selection, removal, reordering, clear, shuffle, and repeat off/all/one. Transport includes play/pause, stop, previous/next, seek, and volume. Media keys and Control Centre use macOS Now Playing. **PL** collapses the music desk to a small receiver. Escape or the menu bar button hides the panel while playback continues; **Quit** exits.

The receiver follows the Omarchy panel: a compact llama header with a current-track source badge, framed time/spectrum and metadata areas, slim native sliders, and elapsed/total times beside the seek bar. The Mac accent colour highlights playback and navigation. Live radio shows its song title above the station and hides the seek bar. Empty queues disable the transport controls. The panel keeps its screen-fitting expanded desk and in-app Settings.

**All artists...** clears artist and album filters; **All albums...** keeps the artist and clears the album. Both show matching song totals and keep search active. Selecting a row browses without playing; Return/double-click plays its group, while Option-click/Option–Return appends. Explicitly selecting an All row enables **+ ADD**; a new search clears that selection. Shuffle and repeat use native symbols with the macOS accent color, a border and a small marker when enabled. Repeat-one shows **1**; hovering describes the current mode.

The header llama cycles through running man, side shuffle, head banging and twerking every ten seconds of playback. Head banging uses planted feet, a knee bounce and four quick neck snaps per phrase. Twerking keeps the head and front steady with four big hip pops, a sideways wiggle and bent rear knees. It rests when playback pauses or stops, and respects macOS Reduce Motion. The menu bar uses a 17-point SVG llama with the system's monochrome tint.

Choose **Radio** in the music source menu. **Saved** starts with the same 14 Cliamp stations as Omarchy, including Omarchy, Lofi, Synthwave and the NCS channels. **Discover** searches [Radio Browser](https://www.radio-browser.info/) by station name, genre, country or language. Station names get the main column; country is shown separately and full details appear on hover. Select a result and **+ SAVE**, or use **+ STATION** to enter a name and direct HTTP(S) stream link. **− FORGET** removes a saved station without changing the queue or interrupting playback. Return tunes in, Option–Return appends, and arrows browse without starting playback. Saved stations work independently of Jellyfin sign-in and directory availability.

Radio shows **LIVE**, hides the seek bar, displays stream-provided song titles, and supports the usual volume, queue, media controls and llama dances. A station that disconnects stops with an error and can be reconnected with Play. Live streams restart at the current broadcast when resumed; they do not retain a seekable listening history. After an app restart, the radio queue is restored paused and connects only when Play is pressed.

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

## Playlists, recents and playback settings

**Playlist → Queue / Saved / Recent** keeps playback and saved music together. **Saved → On device** saves the current queue with a name, previews its songs, and supports rename and forget. **LOAD** replaces the queue paused; **PLAY** starts it. Option–Return appends a saved playlist without interrupting playback. Saved remote tracks require their original Jellyfin server and account. On-device playlists may include duplicate songs, local music and radio.

**Saved → Jellyfin** lists server music playlists and previews their songs. Arrow keys select playlists, Tab switches the playlist/song lists, and Return or double-click plays. CREATE saves a Jellyfin-only queue as a private server playlist on Jellyfin 10.9 or newer. DELETE requires confirmation, then rechecks the exact item type and the account's permission before deleting the playlist. It keeps songs and the playback queue. Failed or uncertain creates/deletes are never retried automatically. Lists refresh when opened and every minute while visible. Server playlist editing and import/export are not implemented.

**Recent** remembers the last 30 albums and radio stations. **Settings → Playback** can turn history off or clear it, keep the llama still, switch gapless preloading on/off, and enable volume normalization. These preferences persist. System Reduce Motion always applies too. Settings, source management and Jellyfin sign-in stay inside the main player, with transport controls above them. **Done** returns to the previous music view. Only the native file/folder picker opens as a separate sheet, attached directly to the player.

Gapless uses AVQueuePlayer with one prepared next music item, including authenticated Jellyfin audio; queue edits, shuffle, repeat, account changes and stop invalidate stale preloads. Network buffering and format changes can still create gaps. Radio remains live and is not preloaded.

Jellyfin audio loads on a background serial queue in authenticated 1 MiB byte ranges. Before AVFoundation starts, the player prepares container/index data and approximately 30 seconds around the starting position, capped at 4 MiB of forward data plus the first/last blocks. Native playback also requests a 30-second forward buffer. Each queued item keeps an in-memory LRU of at most 8 MiB, plus up to 16 pending 1 MiB range reads; Stop/replacement clears it. No persistent audio cache is written. Remote seeks prepare the target section before moving the playhead. Starting or seeking on a slow connection can take longer while the player shows **BUFFERING**.

Transient network failures and HTTP 408/429/500/502/503/504 retry a range at most twice, with 1/2-second backoff, retaining partial data and requesting its first missing byte. Each attempt has a 30-second inactivity timeout and a 90-second total limit. Invalid ranges, changed files, authentication/certificate failures and redirects are not retried. A stalled/failed current Jellyfin track can reconnect at its retained playback position up to twice, with 1.5/3-second backoff. Pause, Stop, Seek, Next and account changes invalidate delayed recovery; the retry budget does not reset merely because an automatic reconnect started playing. The final error keeps the queue and position and offers manual Play. Retry logic applies only to read-only audio GETs; playlist writes/deletes and live-radio behaviour are unchanged.

This improves tolerance of delays; it cannot compensate indefinitely for a connection slower than the track's bitrate. Recovery counts/outcomes can be inspected in unified logging under subsystem `com.davidjpramsay.OmaGAWD`, category `RemotePlayback`; logs contain no titles, server addresses, account identifiers or credentials.

Native normalization measures K-weighted live loudness over 400 ms, targets −18 LUFS, gates silence, smooths gain changes and limits sample peaks to −1.5 dBFS. It runs inside the native audio tap, including when the window is hidden. It does not edit tags or scan music in advance. This native streaming leveler differs from Omarchy's FFmpeg integrated EBU R128/true-peak filter; it does not claim an integrated mastering or true-peak guarantee. Live radio normalization, like live-radio PCM spectrum, requires macOS 27 or later.

## Efficiency and privacy

- Recycled native table cells; library scans and metadata loading are asynchronous.
- Local metadata cache reuses entries when modification time and size are unchanged.
- Remote audio is supplied directly to AVFoundation through authenticated byte-range requests; the app does not download the full library or retain whole audio responses in memory.
- Tokens stay in headers, never audio URLs. API and audio redirects are refused. TLS certificate validation uses the system defaults. HTTP is accepted for explicitly selected servers, including public hosts, and sends credentials without encryption. Prefer HTTPS.
- API responses are limited to 8 MiB; remote library scans to 100,000 tracks / 64 MiB. Local scans stop at 100,000 matching files. Metadata decoding uses AVFoundation, rather than the Linux port's ffprobe metadata-byte limit.
- FFT uses a reusable buffer and runs only while the player panel is visible and audio is playing. The spectrum and cached llama poses share a 30 Hz display timer only in that state. No idle animation timer or network polling.
- Removing a source never deletes its files. Preferences store source paths, volume, shuffle, repeat, and the selected library. Queue order, duplicate entries, current track, and position are saved locally and restored with playback paused after restart. Playback position is checkpointed every five seconds and when pausing, seeking, or quitting. Session files contain track metadata and local paths; sign-in tokens remain in Keychain. Saves retain at most one newest pending snapshot while a write runs, enforce 100,000 tracks / 64 MiB before replacing the file, and use atomic owner-only (0600) files. Failed saves keep the previous file and report an error; shutdown drains the latest snapshot. Named playlists and recents share a private atomic `collections.json`, limited to 128 named lists, 30 recent items, 100,000 total entries and 64 MiB.
- Keychain access runs off the UI thread. Refresh retries failed Jellyfin library discovery or saved sign-in access; local music can still refresh while Jellyfin is unavailable.
- Radio streams receive no Jellyfin authorization. Custom station links cannot contain credentials, and directory entries with private/local addresses are discarded. Search uses two Radio Browser mirrors, bounded requests, a 2 MiB response limit and a maximum of 1,000 results. Saved stations are written atomically to `~/Library/Application Support/com.davidjpramsay.OmaGAWD/radio.json` with owner-only permissions; damaged files are backed up before starting with the built-in catalogue.

## Format and distribution limits

Local formats: MP3, AAC/M4A/M4B, ALAC, FLAC, WAV, AIFF, CAF, and audio MP4, subject to macOS decoder support. Jellyfin streams original audio; this port does not include mpv's broader Ogg/Vorbis, WMA, or other codec coverage and does not request server transcoding. Unsupported audio reports a playback error.

Radio accepts direct MP3/AAC streams and HLS links supported by AVFoundation. PLS/M3U/XSPF playlist files and sign-in streams are unsupported. Song titles depend on station metadata. The live-radio spectrum uses Apple's mixed-output audio tap on macOS 27 or later; older systems can play radio and animate the llama but may not expose stream PCM for the spectrum. Local and Jellyfin spectrum support is unchanged. See Apple's [mixed-output tap description](https://developer-rno.apple.com/streaming/Whats-new-HLS.pdf).

The development build script ad-hoc signs the app for local use. Published DMGs are Developer ID signed and Apple notarized. App Store sandboxing and launch-at-login are not configured. [Sparkle 2.10.0](https://github.com/sparkle-project/Sparkle) is pinned in SwiftPM; its license is included in the application bundle.

Maintainers can create a universal signed release with `SIGNING_IDENTITY="Developer ID Application: …" NOTARY_PROFILE="your-profile" ./script/release_macos.sh`. Packaging stages the app at `dist/release.noindex/OmaGAWD.app` without replacing the running development bundle. This requires a Developer ID certificate/private key and saved notarytool credentials; the script verifies and staples the app and DMG before producing a SHA-256 file. It does not publish automatically. To run the muted playback checks against that exact bundle, use `OMAGAWD_TEST_BUNDLE="$PWD/dist/release.noindex/OmaGAWD.app" ./script/test_macos.sh --existing-bundle`.

After packaging, run `./script/generate_macos_appcast.sh macos-vVERSION-beta.N` with the release tag. This generates and signs `macOS/updates/appcast.xml` from the notarized DMG using the `com.davidjpramsay.OmaGAWD.sparkle` signing key in macOS Keychain. The private key must remain available for future releases; never commit or publish it. Upload the DMG to that GitHub release before merging the appcast into main, then verify the published feed and archive signatures. Keep macOS releases marked prerelease so the Omarchy release track remains independent.

## Verification

```sh
./script/test_macos.sh
```

Runs the Swift queue/filter/URL tests, dance timing tests, startup recovery and session restoration tests, radio validation/persistence/search/paging tests, session-save coalescing/limits/disk-failure/shutdown checks, saved and hosted playlist contracts, actual native gapless transitions, normalization, settings/layout checks, and M4A/missing-source/pause-during-loading regressions. It builds the app and creates disposable loopback Jellyfin and ICY radio fixtures, checking real AVFoundation playback, live titles, pause, seek, PCM spectrum, queue edits, dance rotation, hidden-animation shutdown, stream teardown and redirect rejection. Radio PCM verification runs on macOS 27 or later. Fixture audio is muted. The fixture needs Python 3 only for tests; the application does not. The script launches a separate muted fixture instance, keeps the installed player running, and writes `dist/smoke-test.txt`. No real account credentials or playback sessions are used or saved by the tests.

Manually checked on the development Mac: rendered player and source windows; Command-F clears and filters; Tab cycles all three lists; Option-Return appends; P/L change panes; Option-Down reorders; Delete removes; Escape hides; Command-Option-O shows the player again.

A real Jellyfin account, all supported audio formats, hardware media keys, and Intel hardware still need separate acceptance checks. Release signing, notarization and Gatekeeper acceptance are verified during packaging.
