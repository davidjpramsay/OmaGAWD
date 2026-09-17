#!/usr/bin/env bash
# Install a copy; no shell config is overwritten and no package files are edited.
set -euo pipefail
project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
plugin_dir="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/david.omaamp"
for executable in python3 mpv quickshell omarchy secret-tool; do
  command -v "$executable" >/dev/null || { echo "Missing dependency: $executable" >&2; exit 1; }
done
if [[ -e "$plugin_dir" ]]; then
  echo "Plugin already exists at $plugin_dir; update its files deliberately." >&2
  exit 1
fi
mkdir -p "$plugin_dir"
cp "$project_dir"/*.qml "$project_dir/backend.py" "$project_dir/session_store.py" "$project_dir/manifest.json" "$project_dir/README.md" "$plugin_dir/"
cp -r "$project_dir/assets" "$plugin_dir/"
icon_dir="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps"
mkdir -p "$icon_dir"
cp "$project_dir/assets/omaamp.svg" "$icon_dir/omaamp.svg"
omarchy-shell shell rescanPlugins
# Registry rescanning is asynchronous; wait for discovery before enabling.
for attempt in {1..50}; do
  if omarchy-shell shell listPlugins | python3 -c 'import json,sys; sys.exit(not any(p["id"] == "david.omaamp" for p in json.load(sys.stdin)))'; then
    break
  fi
  sleep 0.1
done
omarchy plugin enable david.omaamp
omarchy bar put david.omaamp --section right --before omarchy.audio
mkdir -p "${XDG_DATA_HOME:-$HOME/.local/share}/applications"
cat > "${XDG_DATA_HOME:-$HOME/.local/share}/applications/omaamp.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=OmaGAWD
Comment=Jellyfin music receiver
Exec=omarchy-shell shell summon david.omaamp {}
Icon=omaamp
Terminal=false
Categories=AudioVideo;Audio;Player;
Keywords=Music;Jellyfin;Winamp;
DESKTOP
omarchy-shell shell summon david.omaamp '{}'
