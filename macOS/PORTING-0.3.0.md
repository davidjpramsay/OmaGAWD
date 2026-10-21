# macOS 0.3.0 development port

Source reference: Omarchy `omarchy-v0.9.1` (`16acca1`) plus the pushed 0.9.2 development work through `e3b6beb` on `codex/security-review-091`. Both remote references were refreshed on 21 October 2026 before the latest port.

The Mac build is 0.3.0, build 8. This is source and a local development bundle, not a newly published/notarized download. The signed updater feed continues to advertise the existing 0.2.2 beta. No stable release or Omarchy marketplace submission is part of this work.

## Coverage

| Omarchy change | Native macOS implementation |
| --- | --- |
| Mac TODO, GitHub issue #5 | One running write and one newest pending snapshot; 100,000-entry / 64 MiB limits; validation before atomic replacement; private 0600 files; latest-state shutdown flush; visible/logged write failures; original saved file survives invalid or failed writes. |
| Settings and persistent options | In-app Settings page with Playback, Sources, Updates and Shortcuts. Gapless, normalization, motion and recent-history choices use the existing preference store. |
| Named local playlists | Playlist → Saved → On device; save queue, preview, load paused, play, rename, forget and Option-append. Duplicates and remote account identity are retained. |
| Jellyfin hosted playlists | Playlist → Saved → Jellyfin; bounded catalogue/track paging, duplicate positions, preview/play/load, private create on 10.9+, confirmed delete with fresh exact-item/type/permission verification. No automatic mutation retries. |
| Recent albums/stations | Playlist → Recent, latest 30 groups; move repeated groups to front, optional history and clear. Foreign-account remote collections cannot be loaded or appended. |
| Gapless and transition polish | AVQueuePlayer with one prepared next music item; invalidation after queue edits, repeat/shuffle, account changes and stop; authenticated resource loaders survive the transition. End notification order cannot replace the already prepared item. |
| Global normalization switch | Native live K-weighted leveler in the existing audio tap. It remains active while the window is hidden. Local/Jellyfin audio works on the supported baseline; live-radio PCM requires macOS 27+. |
| Consolidated source management | Settings → Sources, Jellyfin first, native + Files / + Folder, scrollable saved paths and per-path removal. Music source menu switches sources; local imports/removals preserve the queue. |
| Drag-and-drop music | Finder file-URL drop destination imports supported files/folders and appends their music without interrupting playback. |
| Input/media/library hardening | Native AppKit text fields do not inspect clipboard offers when constructed. No Linux clipboard helper or IME workaround is needed. Imports, scans and playback check supported extensions, canonical regular files and music headers; labels, paths, scans, API pages, caches and saves are bounded. No executable/script/playlist imports. |
| Navigation polish | + ADD requires artist/album/song selection, P/L and existing keyboard control remain, playlist scopes are nested under Playlist, switching away from delayed hosted reads cannot strand the next view in a busy state. |
| Clear playback modes and All rows | Native shuffle/repeat/repeat-one symbols, current-mode accessible labels and tooltips, macOS accent border/marker when enabled. All artists... / All albums... show matching song totals, preserve search, clear the appropriate filters, and support group play/append. Selecting an All row enables + ADD; search/source resets clear it. |
| Llama updates | Curved shoulder cutout and overlapping moving neck remove the head-bang seam/spike. Four existing dances and timing remain; the monochrome toolbar llama is slightly larger. |

The native loudness control targets −18 LUFS with a 400 ms window, silence gate, smoothed gain and −1.5 dBFS sample-peak ceiling. It differs from Omarchy's FFmpeg integrated R128/true-peak implementation; it does not claim integrated mastering compliance or a true-peak guarantee. Gapless remains subject to network availability and native codec/format compatibility. Linux-only Quickshell, GTK portal, mpv, keyring and plugin updater mechanics are represented by the existing AppKit, AVFoundation, Keychain and Sparkle integrations.

## Validation

- `./script/test_macos.sh`: **70 Swift tests passed**, followed by the full **PASS** native playback report, plus muted native-app playback against disposable loopback Jellyfin and ICY radio fixtures. The installed player stays running; fixture instances use isolated preferences, do not touch real sign-in/session/playlist files, and quit after the report.
- Session tests cover a blocked write and 1,000 rapid edits, exact byte cap, exact 100,000-track cap and one-over, write failure, private permissions, malformed data, restart/position recovery, shutdown flush, and remote identity enforcement.
- Collection/hosted tests cover persistence, corruption backup, duplicate names/positions, recent limits, old-server privacy rejection, incomplete pages, uncertain mutation/no-retry, account isolation, and deletion type/permission checks.
- Native audio tests cover local preloading and automatic transition using the exact prepared next item, end-of-queue stop, queue changes, repeat, setting changes, level balance and peak limiting. The app fixture also tests authenticated remote gapless transition and actual HTTP catalogue/create/delete operations.
- Native UI tests cover all settings sections, persisted toggles, selection-dependent + ADD, source menu contents, small-screen bounds/long source wrapping and switching views during delayed hosted reads.
- Rendered inspection with native UI automation checked Playback/Sources/Updates settings, in-app Sources and Jellyfin editor, native file-picker presentation/cancel, Playlist → Saved → On device preview, rename, paused load, and Recent. No real Jellyfin playlist was modified. Settings/account navigation creates no additional visible or titled window; the system picker is attached directly to the player, and Done restores the previous music/compact view.

Validation completed on 15 October 2026 on the development Mac. The test report is generated at `dist/smoke-test.txt` (ignored build output). Physical Finder drag-and-drop, production Jellyfin server/version variations, Intel hardware, actual hardware media keys and a new signed/notarized release are separate acceptance checks; fixture and source tests are not evidence for those outcomes.

### 21 October follow-up

- Ported the four newly pushed Omarchy commits through `e3b6beb`; the Settings/account changes already match the Mac's in-player navigation.
- **74 Swift tests passed**; the muted native playback fixture reported **PASS** for local/Jellyfin/radio playback, spectrum, gapless transitions, hosted-playlist HTTP operations and all four llama dances. New UI cases exercise summary counts, parent/child resets, search retention, empty results, explicit Space selection, group play/append and shuffle/repeat mode cycling/accessibility.
- Rendered native inspection verified off/on/repeat-one icons, accent-colored icons/borders/markers, All rows with song totals, explicit All selection enabling + ADD without playback, and Sources returning to the library. Fixture media used a disposable temporary directory; no real account or playlist was edited. A uniquely identified preview's initial Documents-folder scan blocked inside the OS directory open; it was stopped and visual verification used temporary fixture media. Documents access/privacy behavior remains a separate acceptance check.
- Built local 0.3.0 build 8. No install replacement, signed distribution, release publication or updater-feed change.
