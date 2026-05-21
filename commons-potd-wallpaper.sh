#!/usr/bin/env bash
set -euo pipefail

RSS_URL="https://commons.wikimedia.org/w/api.php?action=featuredfeed&feed=potd&feedformat=rss&language=en"
API_URL="https://commons.wikimedia.org/w/api.php"

MAX_WIDTH="${MAX_WIDTH:-3840}"
KEEP="${KEEP:-30}"
SAVE_DIR="${POTD_SAVE_DIR:-$HOME/Pictures/wikimedia}"

DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/commons-potd-wallpaper"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/commons-potd-wallpaper"
IMG_DIR="$DATA_DIR/images"
STATE_FILE="$CACHE_DIR/state"
METADATA_FILE="$DATA_DIR/metadata.json"

mkdir -p "$IMG_DIR" "$CACHE_DIR"

FORCE=0
DOWNLOAD_ONLY=0
RANDOM_MODE=0
INFO_MODE=0
SAVE_MODE=0
RANDOM_START="2004-12-15"
RANDOM_TRIES=30

usage() {
  cat <<EOF_USAGE
Usage: $(basename "$0") [options]

Options:
  --force              Apply even if this POTD has already been applied
  --download-only      Download the image, but do not set it as wallpaper
  --max-width N        Download thumbnail no wider than N pixels when possible
  --keep N             Number of cached images to keep
  --random             Pick a random historical POTD instead of today's POTD
  --random-start DATE  First eligible date for --random
  --random-tries N     Number of attempts to find a random POTD
  --info               Print info for the current wallpaper set by this script
  --save               Save the current wallpaper to $SAVE_DIR
  -h, --help           Show this help
EOF_USAGE
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

urldecode() {
  local s="${1//+/ }"
  printf '%b' "${s//%/\\x}"
}

extract_file_title_from_url() {
  local url="$1"
  local out=""

  out="$(printf '%s' "$url" | sed -nE 's@.*/wiki/(File:[^?#]+).*@\1@p' | head -n1 || true)"
  if [[ -n "$out" ]]; then
    urldecode "$out"
    return 0
  fi

  out="$(printf '%s' "$url" | sed -nE 's@.*[?&]title=(File:[^&#]+).*@\1@p' | head -n1 || true)"
  if [[ -n "$out" ]]; then
    urldecode "$out"
    return 0
  fi

  return 1
}

metadata_key_from_imageinfo() {
  local imageinfo_json="$1"
  local fallback_title="$2"
  local fallback="${fallback_title#File:}"

  fallback="${fallback//_/ }"

  local key
  key="$(printf '%s' "$imageinfo_json" | jq -r '.extmetadata.ObjectName.value // empty' 2>/dev/null || true)"
  key="$(printf '%s' "${key:-$fallback}" | tr '\r\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"

  if [[ -z "$key" ]]; then
    key="${fallback_title#File:}"
  fi

  printf '%s' "$key"
}

simple_image_info_from_imageinfo() {
  local imageinfo_json="$1"
  local object_name="$2"

  printf '%s' "$imageinfo_json" | jq -c --arg object_name "$object_name" '
    .extmetadata as $m
    | {
        ObjectName: ($m.ObjectName // {value: $object_name}),
        ImageDescription: ($m.ImageDescription // {value: ""}),
        DateTimeOriginal: ($m.DateTimeOriginal // {value: ""})
      }
  '
}

load_metadata_root() {
  if [[ -f "$METADATA_FILE" ]] && jq -e 'type == "object" and (has("schema_version") | not)' "$METADATA_FILE" >/dev/null 2>&1; then
    jq -c . "$METADATA_FILE"
  else
    printf '{}'
  fi
}

write_metadata_entry() {
  local object_name="$1"
  local image_url="$2"
  local image_info_json="$3"
  local time_downloaded="$4"
  local tmp existing

  mkdir -p "$(dirname "$METADATA_FILE")"
  tmp="$(mktemp "${METADATA_FILE}.tmp.XXXXXX")"
  existing="$(load_metadata_root)"

  jq -n \
    --argjson existing "$existing" \
    --arg key "$object_name" \
    --arg image_url "$image_url" \
    --arg time_downloaded "$time_downloaded" \
    --argjson image_info "$image_info_json" \
    '$existing + {
      ($key): {
        image_url: $image_url,
        time_downloaded: $time_downloaded,
        image_info: $image_info
      }
    }' > "$tmp"

  mv "$tmp" "$METADATA_FILE"
}

write_current_state() {
  local entry_id_arg="$1"
  local file_title_arg="$2"
  local object_name="$3"
  local display_path="$4"

  mkdir -p "$(dirname "$STATE_FILE")"

  jq -n \
    --arg entry_id "$entry_id_arg" \
    --arg file_title "$file_title_arg" \
    --arg metadata_key "$object_name" \
    --arg display_path "$display_path" \
    '{
      entry_id: $entry_id,
      file_title: $file_title,
      metadata_key: $metadata_key,
      display_path: $display_path
    }' > "$STATE_FILE"
}

is_already_applied() {
  [[ -f "$STATE_FILE" ]] || return 1

  if jq -e --arg entry_id "$entry_id" --arg file_title "$file_title" '
    .entry_id == $entry_id and .file_title == $file_title
  ' "$STATE_FILE" >/dev/null 2>&1; then
    return 0
  fi

  if grep -qxF "$entry_id|$file_title" "$STATE_FILE" 2>/dev/null; then
    return 0
  fi

  return 1
}

current_metadata_key() {
  if [[ -f "$STATE_FILE" ]]; then
    jq -r '.metadata_key // empty' "$STATE_FILE" 2>/dev/null || true
  fi
}

current_display_path() {
  if [[ -f "$STATE_FILE" ]]; then
    jq -r '.display_path // empty' "$STATE_FILE" 2>/dev/null || true
  fi
}

latest_metadata_key() {
  if [[ -f "$METADATA_FILE" ]]; then
    jq -r '
      if type == "object" and (has("schema_version") | not) then
        (to_entries | sort_by(.value.time_downloaded // "") | last | .key) // ""
      else
        ""
      end
    ' "$METADATA_FILE" 2>/dev/null || true
  fi
}

print_info() {
  need_cmd jq

  if [[ ! -f "$METADATA_FILE" ]]; then
    echo "No metadata found. Run random-potd or commons-potd-wallpaper.sh --force first." >&2
    exit 1
  fi

  local key
  key="$(current_metadata_key)"

  if [[ -z "$key" ]] || ! jq -e --arg key "$key" 'type == "object" and has($key)' "$METADATA_FILE" >/dev/null 2>&1; then
    key="$(latest_metadata_key)"
  fi

  if [[ -z "$key" ]]; then
    echo "No compact metadata entry found. Run random-potd or commons-potd-wallpaper.sh --force to create the new metadata format." >&2
    exit 1
  fi

  jq -r --arg key "$key" '
    def clean:
      if . == null then "" else tostring end
      | gsub("<[^>]*>"; "")
      | gsub("&amp;"; "&")
      | gsub("&quot;"; "\"")
      | gsub("&#039;"; "\u0027")
      | gsub("&#39;"; "\u0027")
      | gsub("&nbsp;"; " ")
      | gsub("[[:space:]]+"; " ")
      | sub("^ "; "")
      | sub(" $"; "");

    .[$key] as $entry
    | [
        ($entry.image_info.ObjectName.value // $key),
        ($entry.image_info.ImageDescription.value // ""),
        ($entry.image_info.DateTimeOriginal.value // ""),
        ($entry.image_url // ""),
        ($entry.time_downloaded // "")
      ]
      | map(clean)
      | map(select(. != ""))
      | join(" ")
  ' "$METADATA_FILE"
}

save_current_wallpaper() {
  need_cmd jq

  local current_path key safe_name timestamp target
  current_path="$(current_display_path)"
  key="$(current_metadata_key)"

  if [[ -z "$current_path" || ! -f "$current_path" ]]; then
    echo "Current wallpaper file is not available. Run random-potd or commons-potd-wallpaper.sh --force first." >&2
    exit 1
  fi

  mkdir -p "$SAVE_DIR"

  safe_name="$(printf '%s' "${key:-wikimedia-potd}" | tr '/' '_' | tr '\n' ' ' | sed -E 's/[[:space:]]+/_/g; s/[^A-Za-z0-9._-]/_/g; s/_+/_/g; s/^_//; s/_$//')"
  [[ -n "$safe_name" ]] || safe_name="wikimedia-potd"

  timestamp="$(date +%Y%m%d-%H%M%S)"
  target="$SAVE_DIR/${timestamp}_${safe_name}"

  case "$current_path" in
    *.jpg|*.jpeg|*.JPG|*.JPEG) target="$target.jpg" ;;
    *.png|*.PNG) target="$target.png" ;;
    *.webp|*.WEBP) target="$target.webp" ;;
    *.gif|*.GIF) target="$target.gif" ;;
    *.svg|*.SVG) target="$target.svg" ;;
    *.tif|*.tiff|*.TIF|*.TIFF) target="$target.tif" ;;
  esac

  install -m 0644 "$current_path" "$target"
  echo "Saved current POTD wallpaper to: $target"
}

pick_random_potd() {
  need_cmd shuf
  need_cmd date
  need_cmd curl
  need_cmd jq

  local start_epoch end_epoch d file title

  start_epoch="$(date -u -d "$RANDOM_START" +%s)"
  end_epoch="$(date -u +%s)"

  for _ in $(seq 1 "$RANDOM_TRIES"); do
    d="$(date -u -d "@$(shuf -i "${start_epoch}-${end_epoch}" -n1)" +%F)"

    file="$(curl -fsSLG "$API_URL" \
      --data-urlencode "action=expandtemplates" \
      --data-urlencode "text={{Potd/$d}}" \
      --data-urlencode "prop=wikitext" \
      --data-urlencode "format=json" \
      | jq -r '.expandtemplates.wikitext // empty' \
      | tr -d '\r\n')"

    [[ -n "$file" && "$file" != "null" ]] || continue

    if [[ "$file" == File:* ]]; then
      title="$file"
    else
      title="File:$file"
    fi

    if ! printf '%s' "$title" | grep -qiE '\.(jpg|jpeg|png|gif|tif|tiff|webp|svg)$'; then
      continue
    fi

    POTD_DATE="$d"
    file_title="${title// /_}"
    entry_id="random:$d:$(date -u +%s)"
    return 0
  done

  echo "Failed to pick a random POTD after $RANDOM_TRIES tries." >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --download-only) DOWNLOAD_ONLY=1; shift ;;
    --max-width) MAX_WIDTH="${2:?Missing value for --max-width}"; shift 2 ;;
    --keep) KEEP="${2:?Missing value for --keep}"; shift 2 ;;
    --random) RANDOM_MODE=1; shift ;;
    --random-start) RANDOM_START="${2:?Missing value for --random-start}"; shift 2 ;;
    --random-tries) RANDOM_TRIES="${2:?Missing value for --random-tries}"; shift 2 ;;
    --info) INFO_MODE=1; shift ;;
    --save) SAVE_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ $INFO_MODE -eq 1 ]]; then
  print_info
  exit 0
fi

if [[ $SAVE_MODE -eq 1 ]]; then
  save_current_wallpaper
  exit 0
fi

need_cmd curl
need_cmd jq
need_cmd xmllint

file_title=""
entry_id=""
POTD_DATE=""

if [[ $RANDOM_MODE -eq 1 ]]; then
  FORCE=1
  pick_random_potd
else
  RSS="$(curl -fsSL "$RSS_URL")"

  item_title="$(printf '%s' "$RSS" | xmllint --xpath 'string(//channel/item[1]/title)' - 2>/dev/null || true)"
  item_link="$(printf '%s' "$RSS" | xmllint --xpath 'string(//channel/item[1]/link)' - 2>/dev/null || true)"
  item_guid="$(printf '%s' "$RSS" | xmllint --xpath 'string(//channel/item[1]/guid)' - 2>/dev/null || true)"
  item_desc="$(printf '%s' "$RSS" | xmllint --xpath 'string(//channel/item[1]/description)' - 2>/dev/null || true)"

  entry_id="${item_guid:-$item_link}"

  if [[ "$item_title" == File:* ]]; then
    file_title="$item_title"
  fi

  if [[ -z "$file_title" ]]; then
    if file_title="$(extract_file_title_from_url "$item_link" 2>/dev/null)"; then :; fi
  fi

  if [[ -z "$file_title" ]]; then
    if file_title="$(extract_file_title_from_url "$item_guid" 2>/dev/null)"; then :; fi
  fi

  if [[ -z "$file_title" ]]; then
    file_title="$(printf '%s' "$item_desc" | grep -oE 'File:[^<>"'\'' ]+\.(jpg|jpeg|png|gif|tif|tiff|webp|svg)' | head -n1 || true)"
  fi

  if [[ -z "$file_title" ]]; then
    echo "Could not extract File: title from RSS item." >&2
    exit 1
  fi

  file_title="${file_title// /_}"
fi

if [[ $FORCE -eq 0 ]] && is_already_applied; then
  exit 0
fi

JSON="$(curl -fsSLG "$API_URL" \
  --data-urlencode "action=query" \
  --data-urlencode "titles=$file_title" \
  --data-urlencode "prop=imageinfo" \
  --data-urlencode "iiprop=url|size|mime|mediatype|extmetadata" \
  --data-urlencode "iiurlwidth=$MAX_WIDTH" \
  --data-urlencode "format=json")"

page_json="$(printf '%s' "$JSON" | jq -c '.query.pages | to_entries[0].value // {}')"
imageinfo_json="$(printf '%s' "$page_json" | jq -c '.imageinfo[0] // {}')"

orig_url="$(printf '%s' "$imageinfo_json" | jq -r '.url // empty')"
orig_width="$(printf '%s' "$imageinfo_json" | jq -r '.width // 0')"
thumb_url="$(printf '%s' "$imageinfo_json" | jq -r '.thumburl // empty')"

if [[ -z "$orig_url" && -z "$thumb_url" ]]; then
  echo "MediaWiki API did not return a usable URL for $file_title" >&2
  exit 1
fi

download_url="$orig_url"

if [[ -n "$thumb_url" ]] && [[ "$orig_width" =~ ^[0-9]+$ ]] && (( orig_width > MAX_WIDTH )); then
  download_url="$thumb_url"
fi

today_local="$(date +%F)"
base="${file_title#File:}"
base="${base//\//_}"

prefix="$today_local"
if [[ -n "$POTD_DATE" ]]; then
  prefix="potd_${POTD_DATE}"
fi

dest="$IMG_DIR/${prefix}_${base}"
downloaded_now=0

if [[ ! -f "$dest" ]]; then
  curl -fsSL --retry 3 --retry-delay 2 -o "$dest" "$download_url"
  downloaded_now=1
fi

object_name="$(metadata_key_from_imageinfo "$imageinfo_json" "$file_title")"
image_info_json="$(simple_image_info_from_imageinfo "$imageinfo_json" "$object_name")"

if [[ $downloaded_now -eq 1 ]]; then
  time_downloaded="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
else
  time_downloaded="$(jq -r --arg key "$object_name" 'if type == "object" then .[$key].time_downloaded // "" else "" end' "$METADATA_FILE" 2>/dev/null || true)"
  if [[ -z "$time_downloaded" ]]; then
    time_downloaded="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
fi

write_metadata_entry "$object_name" "$download_url" "$image_info_json" "$time_downloaded"

if [[ $DOWNLOAD_ONLY -eq 0 ]]; then
  if command -v gsettings >/dev/null 2>&1; then
    uri="file://$(realpath "$dest")"

    if [[ "$(gsettings writable org.gnome.desktop.background picture-uri 2>/dev/null || true)" == "true" ]]; then
      gsettings set org.gnome.desktop.background picture-uri "$uri" || true
    fi

    if [[ "$(gsettings writable org.gnome.desktop.background picture-uri-dark 2>/dev/null || true)" == "true" ]]; then
      gsettings set org.gnome.desktop.background picture-uri-dark "$uri" || true
    fi
  fi

  if command -v plasma-apply-wallpaperimage >/dev/null 2>&1; then
    plasma-apply-wallpaperimage "$dest" >/dev/null 2>&1 || true
  fi

  write_current_state "$entry_id" "$file_title" "$object_name" "$dest"
fi

if [[ "$KEEP" =~ ^[0-9]+$ ]] && (( KEEP > 0 )); then
  ls -1t "$IMG_DIR" 2>/dev/null | tail -n +"$((KEEP+1))" | while read -r f; do
    rm -f "$IMG_DIR/$f" || true
  done
fi