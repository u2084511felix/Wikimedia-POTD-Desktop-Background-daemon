#!/usr/bin/env bash
set -euo pipefail

RSS_URL="https://commons.wikimedia.org/w/api.php?action=featuredfeed&feed=potd&feedformat=rss&language=en"
API_URL="https://commons.wikimedia.org/w/api.php"

MAX_WIDTH="${MAX_WIDTH:-3840}"   # override via env if you want
KEEP="${KEEP:-30}"               # how many images to keep

DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/commons-potd-wallpaper"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/commons-potd-wallpaper"
IMG_DIR="$DATA_DIR/images"
STATE_FILE="$CACHE_DIR/state"

mkdir -p "$IMG_DIR" "$CACHE_DIR"

FORCE=0
DOWNLOAD_ONLY=0
RANDOM_MODE=0
RANDOM_START="2004-12-15"
RANDOM_TRIES=30

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
  if [[ -n "$out" ]]; then urldecode "$out"; return 0; fi

  out="$(printf '%s' "$url" | sed -nE 's@.*[?&]title=(File:[^&#]+).*@\1@p' | head -n1 || true)"
  if [[ -n "$out" ]]; then urldecode "$out"; return 0; fi

  return 1
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

    # The template usually expands to a filename without "File:"
    if [[ "$file" == File:* ]]; then
      title="$file"
    else
      title="File:$file"
    fi

    # Basic sanity: must have an extension
    if ! printf '%s' "$title" | grep -qiE '\.(jpg|jpeg|png|gif|tif|tiff|webp|svg)$'; then
      continue
    fi

    # export globals used later
    POTD_DATE="$d"
    file_title="${title// /_}"
    entry_id="random:$d:$(date -u +%s)"   # always unique so --random always applies
    return 0
  done

  echo "Failed to pick a random POTD after $RANDOM_TRIES tries." >&2
  exit 1
}

FORCE=0
DOWNLOAD_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --download-only) DOWNLOAD_ONLY=1; shift ;;
    --max-width) MAX_WIDTH="$2"; shift 2 ;;
    --keep) KEEP="$2"; shift 2 ;;
    --random) RANDOM_MODE=1; shift ;;
    --random-start) RANDOM_START="$2"; shift 2 ;;
    --random-tries) RANDOM_TRIES="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Commands needed in all modes
need_cmd curl
need_cmd jq
need_cmd xmllint

file_title=""
entry_id=""
POTD_DATE=""

if [[ $RANDOM_MODE -eq 1 ]]; then
  # Always apply in random mode
  FORCE=1
  pick_random_potd
else
  # --- Fetch RSS and parse first item fields (XML) ---
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

# --- Skip if already applied ---
if [[ $FORCE -eq 0 ]] && [[ -f "$STATE_FILE" ]]; then
  if grep -qxF "$entry_id|$file_title" "$STATE_FILE"; then
    exit 0
  fi
fi

# --- MediaWiki API: get imageinfo with a large thumb ---
JSON="$(curl -fsSLG "$API_URL" \
  --data-urlencode "action=query" \
  --data-urlencode "titles=$file_title" \
  --data-urlencode "prop=imageinfo" \
  --data-urlencode "iiprop=url|size|mime" \
  --data-urlencode "iiurlwidth=$MAX_WIDTH" \
  --data-urlencode "format=json")"

orig_url="$(printf '%s' "$JSON" | jq -r '.query.pages[] | .imageinfo[0].url // empty')"
orig_width="$(printf '%s' "$JSON" | jq -r '.query.pages[] | .imageinfo[0].width // 0')"
thumb_url="$(printf '%s' "$JSON" | jq -r '.query.pages[] | .imageinfo[0].thumburl // empty')"

if [[ -z "$orig_url" && -z "$thumb_url" ]]; then
  echo "MediaWiki API did not return a usable URL for $file_title" >&2
  exit 1
fi

download_url="$orig_url"
if [[ -n "$thumb_url" ]] && [[ "$orig_width" =~ ^[0-9]+$ ]] && (( orig_width > MAX_WIDTH )); then
  download_url="$thumb_url"
fi

today_utc="$(date -u +%F)"
base="${file_title#File:}"
base="${base//\//_}"

# Prefix the filename with the chosen archive date when random; otherwise "today"
prefix="$today_utc"
if [[ -n "$POTD_DATE" ]]; then
  prefix="potd_${POTD_DATE}"
fi

dest="$IMG_DIR/${prefix}_${base}"

if [[ ! -f "$dest" ]]; then
  curl -fL --retry 3 --retry-delay 2 -o "$dest" "$download_url"
fi

if [[ $DOWNLOAD_ONLY -eq 0 ]]; then
  # GNOME
  if command -v gsettings >/dev/null 2>&1; then
    uri="file://$(realpath "$dest")"

    if gsettings writable org.gnome.desktop.background picture-uri >/dev/null 2>&1; then
      gsettings set org.gnome.desktop.background picture-uri "$uri" || true
    fi

    if gsettings writable org.gnome.desktop.background picture-uri-dark >/dev/null 2>&1; then
      gsettings set org.gnome.desktop.background picture-uri-dark "$uri" || true
    fi
  fi

  # KDE Plasma
  if command -v plasma-apply-wallpaperimage >/dev/null 2>&1; then
    plasma-apply-wallpaperimage "$dest" >/dev/null 2>&1 || true
  fi
fi

# Save state
printf '%s|%s\n' "$entry_id" "$file_title" > "$STATE_FILE"

# Cleanup old images
if [[ "$KEEP" =~ ^[0-9]+$ ]] && (( KEEP > 0 )); then
  ls -1t "$IMG_DIR" 2>/dev/null | tail -n +"$((KEEP+1))" | while read -r f; do
    rm -f "$IMG_DIR/$f" || true
  done
fi

