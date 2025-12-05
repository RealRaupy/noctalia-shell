#!/usr/bin/env bash
set -euo pipefail

command -v ffmpeg >/dev/null || { echo "ffmpeg is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
command -v find >/dev/null || { echo "find is required" >&2; exit 1; }
command -v sha256sum >/dev/null || { echo "sha256sum is required" >&2; exit 1; }

CONFIG_DIR=${NOCTALIA_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/noctalia}
CACHE_DIR=${NOCTALIA_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/noctalia}
SETTINGS_FILE=${NOCTALIA_SETTINGS_FILE:-$CONFIG_DIR/settings.json}
CACHE_WP="${CACHE_DIR}/images/wallpapers"
STEAM_DIR_DEFAULT="${NOCTALIA_STEAM_WORKSHOP_DIR:-$HOME/.local/share/Steam/steamapps/workshop/content/431960}"
PREVIEW_SIZE=${PREWARM_PREVIEW_SIZE:-384}

mkdir -p "$CACHE_WP"

if [ ! -f "$SETTINGS_FILE" ]; then
  echo "Settings file not found at $SETTINGS_FILE" >&2
  exit 1
fi

expand_path() {
  local path="$1"
  case "$path" in
  "~"*)
    echo "${HOME}${path#"~"}"
    ;;
  *)
    echo "$path"
    ;;
  esac
}

use_wallhaven=$(jq -r '.wallpaper.useWallhaven // false' "$SETTINGS_FILE")
steam_integration=$(jq -r '.wallpaper.steamWallpaperIntegration // false' "$SETTINGS_FILE")
use_steam=$(jq -r '.wallpaper.useSteamWallpapers // false' "$SETTINGS_FILE")
recursive=$(jq -r '.wallpaper.recursiveSearch // false' "$SETTINGS_FILE")
multi_dirs=$(jq -r '.wallpaper.enableMultiMonitorDirectories // false' "$SETTINGS_FILE")
base_dir=$(jq -r '.wallpaper.directory // ""' "$SETTINGS_FILE")
monitor_dirs=($(jq -r '.wallpaper.monitorDirectories[]?.directory // empty' "$SETTINGS_FILE"))

dirs=()

if [ "$steam_integration" = "true" ] && [ "$use_steam" = "true" ] && [ "$use_wallhaven" != "true" ]; then
  dirs+=("$STEAM_DIR_DEFAULT")
else
  if [ -n "$base_dir" ]; then
    dirs+=("$(expand_path "$base_dir")")
  fi
  if [ "$multi_dirs" = "true" ] && [ "${#monitor_dirs[@]}" -gt 0 ]; then
    for d in "${monitor_dirs[@]}"; do
      if [ -n "$d" ]; then
        dirs+=("$(expand_path "$d")")
      fi
    done
  fi
fi

if [ "${#dirs[@]}" -eq 0 ]; then
  echo "No wallpaper directories to scan." >&2
  exit 0
fi

find_flags=()
if [ "$recursive" != "true" ]; then
  find_flags+=("-maxdepth" "1")
fi

ext_args=( -iname "*.mp4" -o -iname "*.webm" -o -iname "*.mov" -o -iname "*.mkv" -o -iname "*.gif" )

generate_preview() {
  local file="$1"
  local hash
  hash=$(printf "%s" "$file" | sha256sum | cut -d' ' -f1)
  local target="${CACHE_WP}/${hash}@${PREVIEW_SIZE}x${PREVIEW_SIZE}.png"

  if [ -s "$target" ]; then
    return
  fi

  ffmpeg -y -i "$file" -vf "thumbnail,scale='min(${PREVIEW_SIZE},iw)':-2" -frames:v 1 -update 1 "$target" >/dev/null 2>&1 && \
    echo "Generated preview for $file"
}

for dir in "${dirs[@]}"; do
  [ -d "$dir" ] || continue
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    base=$(basename "$file")
    if [[ "$dir" == "$STEAM_DIR_DEFAULT" && "$base" == preview.* ]]; then
      continue
    fi
    generate_preview "$file"
  done < <(find -L "$dir" "${find_flags[@]}" -type f \( "${ext_args[@]}" \))
done
