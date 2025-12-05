#!/usr/bin/env bash
# Pre-generate PNG previews for video wallpapers (local + Wallpaper Engine/Steam)
# using the same hash+size naming as WallpaperService:
#   <sha256(path)>@384x384.png in ~/.cache/noctalia/images/wallpapers

set -euo pipefail
IFS=$'\n\t'

preview_size="${NOCTALIA_WALLPAPER_PREVIEW_SIZE:-384}"
cache_root="${NOCTALIA_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/noctalia}/images/wallpapers"
config_dir="${NOCTALIA_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/noctalia}"
settings_file="${NOCTALIA_SETTINGS_FILE:-$config_dir/settings.json}"
steam_dir="${NOCTALIA_STEAM_WALLPAPER_DIR:-$HOME/.local/share/Steam/steamapps/workshop/content/431960}"
default_wallpaper_dir="$HOME/Pictures/Wallpapers"
video_patterns_default=(mp4 webm mov mkv gif)
video_patterns_steam=(mp4 webm mov mkv)

usage() {
  cat <<'EOF'
Usage: prewarm-video-wallpapers.sh [ADDITIONAL_DIR...]
Reads ~/.config/noctalia/settings.json to mirror the wallpaper directories,
recursive flag, and Steam/Wallpaper Engine toggle, then writes previews to:
  ~/.cache/noctalia/images/wallpapers/<sha256>@384x384.png
Environment overrides: NOCTALIA_CACHE_DIR, NOCTALIA_CONFIG_DIR, NOCTALIA_SETTINGS_FILE,
NOCTALIA_STEAM_WALLPAPER_DIR, NOCTALIA_WALLPAPER_PREVIEW_SIZE.
Requires: ffmpeg, jq, find, sha256sum.
EOF
}

if [[ "${1-}" == "-h" || "${1-}" == "--help" ]]; then
  usage
  exit 0
fi

if ! [[ "$preview_size" =~ ^[0-9]+$ ]]; then
  echo "Invalid preview size: $preview_size" >&2
  exit 1
fi

require_cmd() {
  local missing=0
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Missing dependency: $cmd" >&2
      missing=1
    fi
  done
  [[ $missing -eq 0 ]] || exit 1
}

require_cmd ffmpeg jq sha256sum find

expand_path() {
  case "$1" in
    "~") echo "$HOME" ;;
    "~/"*) echo "$HOME/${1#~/}" ;;
    *) echo "$1" ;;
  esac
}

declare -A seen_dirs=()
dirs=()

add_dir() {
  local dir="$1"
  [[ -z "$dir" ]] && return
  dir=$(expand_path "$dir")
  dir="${dir%/}"
  if [[ -z "${seen_dirs[$dir]:-}" ]]; then
    dirs+=("$dir")
    seen_dirs["$dir"]=1
  fi
}

recursive_search="false"
multi_dir="false"
use_wallhaven="false"
use_steam="false"
main_dir="$default_wallpaper_dir"
monitor_dirs=()

if [[ -r "$settings_file" ]]; then
  config_values="$(jq -r '[
    .wallpaper.recursiveSearch // false,
    .wallpaper.enableMultiMonitorDirectories // false,
    .wallpaper.useWallhaven // false,
    .wallpaper.useSteamWallpapers // false,
    .wallpaper.steamWallpaperIntegration // false,
    .wallpaper.directory // ""
  ] | @tsv' "$settings_file")"

  read -r recursive_search multi_dir use_wallhaven use_steam_flag steam_integration main_dir <<<"$config_values"
  [[ "$main_dir" == "null" || -z "$main_dir" ]] && main_dir="$default_wallpaper_dir"

  if [[ "$multi_dir" == "true" ]]; then
    while IFS= read -r monitor_dir; do
      [[ -n "$monitor_dir" && "$monitor_dir" != "null" ]] && monitor_dirs+=("$monitor_dir")
    done < <(jq -r '.wallpaper.monitors[]?.directory // ""' "$settings_file")
  fi

  if [[ "$use_steam_flag" == "true" && "$steam_integration" == "true" && "$use_wallhaven" != "true" ]]; then
    use_steam="true"
  fi
else
  echo "Config not found at $settings_file; falling back to defaults." >&2
fi

if [[ "$multi_dir" == "true" && ${#monitor_dirs[@]} -gt 0 ]]; then
  for d in "${monitor_dirs[@]}"; do
    add_dir "$d"
  done
fi
add_dir "$main_dir"

for extra in "$@"; do
  add_dir "$extra"
done

if [[ "$use_steam" == "true" ]]; then
  add_dir "$steam_dir"
fi

if [[ ${#dirs[@]} -eq 0 ]]; then
  echo "No directories to scan." >&2
  exit 0
fi

mkdir -p "$cache_root"

# Ensure cache directory is writable (detect immutable/readonly issues early)
write_probe="$cache_root/.prewarm-write-test.$$"
if ! touch "$write_probe" 2>/dev/null; then
  echo "cache directory not writable: $cache_root" >&2
  echo "If immutability is set, try: chattr -i \"$cache_root\"" >&2
  exit 1
fi
rm -f "$write_probe"

processed=0
skipped=0
failed=0
missing=0
declare -A seen_files=()

process_dir() {
  local dir="$1"
  local is_steam_dir="$2"

  if [[ ! -d "$dir" ]]; then
    echo "skip: $dir (not a directory)" >&2
    return
  fi

  local -a patterns=("${video_patterns_default[@]}")
  [[ "$is_steam_dir" == "true" ]] && patterns=("${video_patterns_steam[@]}")

  local -a find_cmd=(find -L "$dir")
  if [[ "$is_steam_dir" != "true" && "$recursive_search" != "true" ]]; then
    find_cmd+=(-maxdepth 1)
  fi
  find_cmd+=(-type f \( )
  for i in "${!patterns[@]}"; do
    find_cmd+=(-iname "*.${patterns[i]}")
    if (( i < ${#patterns[@]} - 1 )); then
      find_cmd+=(-o)
    fi
  done
  find_cmd+=( \) -print0)

  while IFS= read -r -d '' file; do
    # Normalize to absolute if find ever returns relative (defensive, also fixes leading slash loss)
    [[ "${file:0:1}" == "/" ]] || file="/$file"

    if [[ -n "${seen_files[$file]:-}" ]]; then
      continue
    fi
    seen_files["$file"]=1

    file_abs="$(realpath -e "$file" 2>/dev/null || true)"
    if [[ -z "$file_abs" || ! -e "$file_abs" ]]; then
      echo "skip (missing): ${file}" >&2
      ((++missing))
      continue
    fi

    hash="$(printf '%s' "$file_abs" | sha256sum | awk '{print $1}')"
    out="$cache_root/${hash}@${preview_size}x${preview_size}.png"

    if [[ -s "$out" ]]; then
      ((++skipped))
      continue
    fi

    tmp="${out}.tmp"
    if ffmpeg -y -v error -i "$file_abs" -frames:v 1 -vf "thumbnail,scale=min(${preview_size}\\,iw):-2" -vcodec png -f image2 "$tmp"; then
      mv "$tmp" "$out"
      ((++processed))
    else
      echo "failed: $file_abs" >&2
      rm -f "$tmp"
      ((++failed))
    fi
  done < <("${find_cmd[@]}" 2>/dev/null || true)
}

for dir in "${dirs[@]}"; do
  is_steam="false"
  [[ "$use_steam" == "true" && "${dir%/}" == "${steam_dir%/}" ]] && is_steam="true"
  process_dir "$dir" "$is_steam"
done

echo "done. new previews: $processed, skipped existing: $skipped, failed: $failed"
if [[ $missing -gt 0 ]]; then
  echo "missing files (not processed): $missing"
fi
