# OmaGAWD

**Winamp soul. Omarchy fit. Badass llama dance moves.**

Jellyfin, local music, and radio in a compact player that follows your Omarchy theme. Real frequency spectrum, a clean Artist → Album → Song browser, named playlists, and keyboard control from search to playlist.

<img src="preview.png" alt="OmaGAWD in Tokyo Night: real playback of Cog — Anarchy OK, live spectrum, library, keyboard shortcuts, and dancing llamas." width="920">

**Bad ass llama moves.**

<img src="assets/llama-dances.gif" alt="OmaGAWD llama demonstrating running man, side shuffle, head banging and twerk" width="480">

**Radio:** **Saved** starts with 14 Cliamp stations, including Omarchy, Lofi, and Synthwave. **Discover** searches [Radio Browser](https://www.radio-browser.info/) by name, genre, country, or language; select a result and **+ SAVE**. **− FORGET** removes a saved station without touching the queue. Arrows browse, Return tunes in, Alt+Return appends. Live titles, spectrum, and llama dances work throughout; no Cliamp installation or account needed.

**Saved** names, loads, plays, renames and forgets playlists. **Recent** returns to the last 30 albums/stations. Saved remote playlists require their original Jellyfin account.

Your queue, playback position, volume, shuffle, and repeat are remembered. Restart restores paused. **Manage sources…** adds or forgets local files/folders without deleting music. Switching back to Jellyfin remembers its last library. Media keys work with the popup hidden. **Drop music…** opens a native drop window for local files/folders; imports leave the current queue playing.

## Omarchy

```sh
omarchy plugin add https://github.com/davidjpramsay/OmaGAWD.git --enable
```

Requires Omarchy/Quickshell, mpv, Python 3 with python-gobject, libsecret (`secret-tool`), ffmpeg (`ffprobe`), zenity / GTK 4, and wl-clipboard (`wl-paste`). Use a direct Jellyfin URL; audio redirects are blocked. No pip/npm dependencies.

Local files: MP3, FLAC, AAC, M4A/M4B/ALAC, Ogg/Opus, WAV, AIFF, WMA, APE and WavPack. Imports and playback restrict demuxers to music containers; scripts and playlist files are unsupported.

Open the llama in the bar. **⚙ Settings** contains playback options, sources, updates and shortcuts. Gapless preloads the next music track; matching audio formats flow without reopening the output. Volume normalization is a global on/off switch using album ReplayGain tags; untagged tracks are unchanged. Recent history and llama motion can be turned off.

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

Spectrum analysis stops while hidden or paused. Server-playlist sync, playlist import/export are not implemented. Radio accepts direct public HTTP(S) stream links; playlists and HLS are unsupported. Safety limits: 8 MiB per API response, 100,000 tracks / 64 MiB per library or playlist, 1,000,000 entries / 100,000 folders per local scan, 2 MiB of metadata per local file, 512 characters per music label, 1 MiB / 1,000 local sources, 2 MiB per radio-directory response, and 1,000 saved stations/search results.

## macOS

[Download the signed macOS 0.2.2 beta](https://github.com/davidjpramsay/OmaGAWD/releases/tag/macos-v0.2.2-beta.1) (macOS 14+, Apple silicon and Intel), including **Check for Updates…**, or see the [macOS guide](macOS/README.md) for builds, shortcuts, and format support.
