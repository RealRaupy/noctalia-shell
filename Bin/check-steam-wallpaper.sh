#!/usr/bin/env bash

# Exit 0 if either the Wallpaper Engine workshop content folder (431960)
# or the Wallpaper Engine install folder exists. Otherwise non-zero.

set -euo pipefail
set -x

home="${HOME:-}"

paths=(
  "${home}/.local/share/Steam/steamapps/workshop/content/431960"
  "${home}/.steam/steam/steamapps/common/wallpaper_engine"
  "${home}/.local/share/Steam/steamapps/common/wallpaper_engine"
)

for p in "${paths[@]}"; do
  if [ -d "$p" ]; then
    exit 0
  fi
done

exit 1
