# OmaGAWD across Omarchy and macOS

One product, two native implementations. Keep the music workflow consistent;
use each platform's own UI, audio engine, credential store and updater.

## Shared behaviour

- Compact player with an expanding music desk; the Settings cog opens settings
  inside the player and returns to the previous section and compact/expanded state.
- Settings contains Playback, Sources, Updates and Keys/Shortcuts. Jellyfin
  account editing stays inside Sources; keep source setup out of the source menu.
- Jellyfin, explicitly selected local music and saved/discovered radio stations.
- Artist → Album → Song selection updates children without playing. Return or
  double-click replaces the queue and plays; Option/Alt appends without interruption.
- Playlist contains Queue, Saved and Recent. Queue/position restore paused.
  Hosted playlists belong to Jellyfin; device snapshots remain private.
- A static toolbar llama; themed playing colour and dancing player llama.
- Gapless, global normalization, motion and history options. Never rewrite music.
- Keep credentials out of logs, URLs, arguments, snapshots and published assets.
  Bound untrusted input, network responses, metadata, queues and background work.

## Intentional platform differences

| Area | Omarchy | macOS |
|---|---|---|
| UI / audio | Quickshell / mpv | AppKit / AVFoundation |
| Credentials | Secret Service | Keychain |
| Local import | System portal file/folder picker; no drag-and-drop | Native picker and Finder drops |
| Normalization | FFmpeg EBU R128 live loudnorm, true-peak limiting | Native K-weighted live leveler, sample-peak limiting; radio PCM depends on OS support |
| Updates | Explicit native plugin update from stable main | Signed Sparkle release feed |

Do not copy a platform's helpers or restrictions into the other platform merely
to make their implementations identical. Document a deliberate difference here.

## Working on two machines/accounts

Use GitHub as the shared record; neither agent needs the other account's chat.
At the start of work, fetch branches and read this file plus the relevant platform
notes and recent commits. A local, ignored AGENTS.md can point here; do not publish
machine-specific agent instructions or personal configuration.

For each change, record the behaviour, affected platforms, commit/branch and
verification in a shared issue or pull request. Mark each platform as implemented,
verified, intentionally different or pending. Ask the other machine to port the
same change by that link/commit, rather than relying on a remembered conversation.

Use short `codex/` feature branches. A shared development integration branch can
collect both ports after review; `main` stays stable because Omarchy users update
from it. This is a suggested workflow, not an automatically created branch or
publication policy change. Test each implementation on its own OS before stable
publication. Pushes, releases and marketplace submissions are separate actions;
publish a release or marketplace update only when explicitly requested.

## Latest parity check — 15 October 2026

- macOS source: `codex/macos-parity-0.9.2`, `5899ada`. Development 0.3.0;
  the downloadable signed release remains 0.2.2 beta.
- That branch starts from Omarchy development `8f49e9e`. Most of its changes
  port existing Omarchy work; the shared llama shoulder fix already matches.
- This Omarchy follow-up restores compact mode when closing Settings and nests
  Jellyfin account editing under Sources. Signing in opens Library; background
  reconnects preserve the active settings/music section. Signing out from the
  account editor leaves the editor available for another account.
- Native Mac device-playlist preview/append is a remaining parity candidate;
  Omarchy currently offers device save/load/play/rename/forget. Do not describe
  planned functionality as available.
- Mac's reported tests are recorded in `macOS/PORTING-0.3.0.md` on that branch.
  They are not a substitute for running Omarchy tests or for Mac hardware checks.
- This Omarchy follow-up passed 173 isolated backend tests, 39 QML checks and
  native 460-pixel account/Sources rendering and navigation checks, including
  compact return, popup reopen, background reconnect and explicit sign-in/out.

## Omarchy playback controls — 20 October 2026

Shuffle and repeat now use native font icons. Enabled modes show the theme
accent, accent border and a small marker; repeat-one has a distinct “1” icon.
Tooltips and accessible names state off/on/all songs/one song. Keyboard activation
and backend mode cycling are unchanged. Theme palette references are qualified
to avoid the newer Qt Color name collision. Verified with 173 backend tests,
40 QML checks and native themed renders of off/all/one, Library and Settings.
This is local development work; no release or marketplace update is implied.

## Omarchy library — 20 October 2026

Artist and Album panes start with All artists / All albums when results exist.
All artists clears both filters; All albums keeps the artist. Search remains in
effect. Click/Space and keyboard browsing update children without playing;
Return/double-click plays the group and Option/Alt appends. The All rows show
song totals and do not inflate artist/album heading counts. Explicitly selecting
an All row enables + ADD; initial/reset browsing keeps + ADD inactive. Empty
results keep their existing message. Revisiting a pane preserves child choices.

Omarchy passed 173 backend tests, 43 QML checks and native 460-pixel renders.
This behaviour is a macOS parity candidate, pending implementation/verification
there; no Mac changes or stable publication accompany this local update.
