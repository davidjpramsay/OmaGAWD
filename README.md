# OmaGAWD

Winamp-inspired music player for **Omarchy and macOS**, with Jellyfin streaming and local files.

## macOS

[Download the signed macOS beta](https://github.com/davidjpramsay/OmaGAWD/releases/tag/macos-v0.1.0-beta.1) (macOS 14+, Apple silicon and Intel). Open the DMG and drag the app to Applications.

The native Swift menu bar app lives in [`macOS/`](macOS/README.md). Build and open it with:

```sh
./script/build_and_run.sh --release
```

See the [macOS guide](macOS/README.md) for installation, shortcuts, format support, and tests.

## Omarchy

Use a direct Jellyfin URL; audio redirects are blocked.

Safety limits: 8 MiB per API response; 100,000 tracks per local scan or 100,000 tracks / 64 MiB per Jellyfin scan; 2 MiB of metadata per local file.

<img src="preview.png" alt="OmaGAWD playing music with its frequency visualizer and library" width="420">

```sh
git clone https://github.com/davidjpramsay/OmaGAWD.git
cd OmaGAWD && ./scripts/install.sh
```

Requires Omarchy/Quickshell, mpv, Python 3 with python-gobject, libsecret (`secret-tool`), ffmpeg (`ffprobe`), and zenity.

Open the llama icon; the llama inside the player dances while playing. Choose music from the source menu. **?** shows keyboard shortcuts. Volume, shuffle, and repeat are remembered; the queue is session-only. Spectrum analysis stops while hidden or paused. **Manage sources…** adds or removes local sources without deleting files.

| Shortcut | Action |
|---|---|
| P / L | Playlist / library |
| ⌘F / Ctrl+F | Clear filters and focus search |
| Tab / Shift+Tab | Cycle Artist → Album → Songs; update child lists |
| Arrows / Home / End | Select and update child lists without playing |
| Space | Select / toggle filter |
| Return / double-click | Play |
| Option/Alt-click or Option/Alt+Return | Add to queue without interrupting playback |
| Delete | Remove from queue |
| Option+↑/↓ | Reorder |
| Escape | Hide |

Open from a terminal or bind this command to **Super+Alt+O** (Command+Option+O on Mac keys), if free:

```sh
omarchy-shell shell summon david.omaamp '{}'
```

Remove with `omarchy plugin remove david.omaamp`. The script-installed launcher/icon can also be removed from `~/.local/share/applications/omaamp.desktop` and `~/.local/share/icons/hicolor/scalable/apps/omaamp.svg`. Music files, saved sources, and keyring sign-in remain.
