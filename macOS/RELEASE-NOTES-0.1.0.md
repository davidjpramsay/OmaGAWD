# OmaGAWD for macOS 0.1.0 beta

First native macOS menu-bar release, built in Swift with AppKit and AVFoundation.

- Local music and Jellyfin libraries, playlists, search, playback controls and spectrum display.
- Fixed top-right panel, compact player mode, square controls and llama menu-bar icon.
- Tab / Shift+Tab cycles Artists, Albums and Songs; Command–Option–O toggles the player.
- Pause commands are respected while a track is loading.
- M4A track and disc numbers preserve album order; older metadata is rescanned.
- Missing local folders no longer prevent accessible music from loading; unavailable sources are reported in Library/Playlist.

Requires macOS 14 or later. Universal app for Apple silicon and Intel; runtime testing performed on Apple silicon. Developer ID signed and Apple notarized.

Open the DMG and drag OmaGAWD into Applications, then launch it. The app lives in the menu bar. Use Sources to add local folders or connect to Jellyfin. Prefer HTTPS for Jellyfin: explicitly choosing HTTP sends sign-in credentials and tokens without encryption.

This is a beta. The queue is session-only. No automatic updater is included; download future versions from GitHub Releases.
