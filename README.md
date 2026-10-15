# OmaGAWD

**Winamp soul. Omarchy fit. Badass llama dance moves.**

Jellyfin, local music, and radio in a compact player that follows your Omarchy theme. Real frequency spectrum, a clean Artist → Album → Song browser, named playlists, and keyboard control from search to playlist.

<img src="preview.png" alt="OmaGAWD in Tokyo Night: real playback of Cog — Anarchy OK, live spectrum, library, keyboard shortcuts, and dancing llamas." width="920">

**Bad ass llama moves.**

<img src="assets/llama-dances.gif" alt="OmaGAWD llama demonstrating running man, side shuffle, head banging and twerk" width="480">

**Radio:** **Saved** starts with 14 Cliamp stations, including Omarchy, Lofi, and Synthwave. **Discover** searches [Radio Browser](https://www.radio-browser.info/) by name, genre, country, or language; select a result and **+ SAVE**. **− FORGET** removes a saved station without touching the queue. Arrows browse, Return tunes in, Alt+Return appends. Live titles, spectrum, and llama dances work throughout; no Cliamp installation or account needed.

**Playlist → Saved → Jellyfin** browses server playlists and their songs. **CREATE** saves the current Jellyfin-only queue as a private server playlist (Jellyfin 10.9+); **LOAD** replaces the queue paused, **PLAY** starts it. **DELETE** removes a selected server playlist after confirmation, when your account permits it; songs and the current queue are kept. Arrows browse; Tab switches playlists/songs; Return plays. Lists refresh on opening and every minute. **Saved → On device** keeps existing named playlists, including rename/forget. **Playlist → Recent** returns to the last 30 albums/stations. Remote playlists require their original Jellyfin account.

Your queue, playback position, volume, shuffle, and repeat are remembered. Restart restores paused. **Settings → Sources → Local Music** has **+ Files**, **+ Folder**, and **Remove** beside each saved path. File/folder selection uses your system's default desktop picker and returns to Settings. Imports and removals keep the current queue; Remove never deletes music. The source menu only switches Jellyfin/Local Music/Radio. Switching back to Jellyfin remembers its last library. Media keys work with the popup hidden.

## Omarchy

```sh
omarchy plugin add https://github.com/davidjpramsay/OmaGAWD.git --enable
```

Requires Omarchy/Quickshell, mpv, Python 3 with python-gobject, libsecret (`secret-tool`), ffmpeg (`ffprobe`), GTK 4 / the desktop FileChooser portal, and wl-clipboard (`wl-paste`). Use a direct Jellyfin URL; audio redirects are blocked. No pip/npm dependencies.

Local files: MP3, FLAC, AAC, M4A/M4B/ALAC, Ogg/Opus, WAV, AIFF, WMA, APE and WavPack. Imports and playback restrict demuxers to music containers; scripts and playlist files are unsupported.

Open the llama in the bar. Library **+ ADD** activates after selecting an artist, album or songs. **⚙ Settings** contains playback options, sources, updates and shortcuts. Gapless preloads the next music track; matching audio formats flow without reopening the output. Optional volume normalization measures all music and radio live using EBU R128 (−18 LUFS, −1.5 dB true peak); it can soften volume contrasts and add buffering. No tags, scans or media edits. Recent history and llama motion can be turned off.

| Shortcut | Action |
|---|---|
| P / L | Playlist / library |
| ⌘F / Ctrl+F | Clear filters and focus search |
| Tab / Shift+Tab | Cycle Artist → Album → Songs; focus radio stations |
| Arrows / Home / End | Browse and update child lists without playing |
| Space | Select / toggle filter |
| Return / double-click | Replace queue and play; play selected row in playlist |
| Option/Alt-click or Option/Alt+Return | Append without interrupting playback |
| Shift+arrows / ⌘A or Ctrl+A | Extend selection / select all in playlist |
| Delete / Backspace | Remove from queue |
| Option/Alt+↑/↓ | Reorder |
| Escape | Hide |

P/L apply outside text fields. Option is Alt. Command accepts Meta and translated Control.

Text fields support typing, selection, undo and explicit paste (Command/Ctrl+V, Shift+Insert, middle-click or the context menu). Clipboard reads run outside the shell with a 64 KiB / 2-second limit. IME composition is temporarily unsupported; compose elsewhere and paste.

Suggested global binding: **Super+Alt+O** (Command+Option+O on Mac keys), if free. Bind it to:

```sh
omarchy-shell shell summon david.omaamp '{}'
```

The **↑** notice shows available OmaGAWD releases; **⚙ → Updates** checks manually and opens the normal updater after saving playback. Updating pauses music. You can also update with `omarchy plugin update david.omaamp`. Remove with `omarchy plugin remove david.omaamp`. The script-installed launcher/icon live at `~/.local/share/applications/omaamp.desktop` and `~/.local/share/icons/hicolor/scalable/apps/omaamp.svg`; remove those separately. Music, saved sources, playback settings, and keyring sign-in remain.

Spectrum analysis stops while hidden or paused. Editing existing Jellyfin playlists and playlist import/export are not implemented. Radio accepts direct public HTTP(S) stream links; playlists and HLS are unsupported. Safety limits: 8 MiB per API response, 100,000 tracks / 64 MiB per library or playlist, 1,000 hosted playlists, 1,000,000 entries / 100,000 folders per local scan, 2 MiB of metadata per local file with a 512 MiB probe address-space cap, 512 characters per music label, 1 MiB / 1,000 local sources, 2 MiB per radio-directory response, and 1,000 saved stations/search results.

## macOS

[Download the signed macOS 0.2.2 beta](https://github.com/davidjpramsay/OmaGAWD/releases/tag/macos-v0.2.2-beta.1) (macOS 14+, Apple silicon and Intel), including **Check for Updates…**, or see the [macOS guide](macOS/README.md) for builds, shortcuts, and format support.
