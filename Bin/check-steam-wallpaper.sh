#!/usr/bin/env bash
set -e

paths=(
  "${XDG_DATA_HOME:-$HOME/.local/share}/Steam/steamapps/workshop/content/431960"
  "$HOME/.steam/steam/steamapps/workshop/content/431960"
  "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/workshop/content/431960"
  "${XDG_DATA_HOME:-$HOME/.local/share}/Steam/steamapps/common/wallpaper_engine"
  "$HOME/.steam/steam/steamapps/common/wallpaper_engine"
  "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/common/wallpaper_engine"
)

for dir in "${paths[@]}"; do
  if [ -d "$dir" ]; then
    exit 0
  fi
done

exit 1
