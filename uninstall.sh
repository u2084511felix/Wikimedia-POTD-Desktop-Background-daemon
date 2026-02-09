#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Wikimedia Commons POTD Wallpaper - uninstaller (systemd --user)
#
# Removes:
#   - ~/.local/bin/commons-potd-wallpaper.sh
#   - ~/.config/systemd/user/commons-potd.service
#   - ~/.config/systemd/user/commons-potd.timer
#
# Optionally removes data/cache directories created by the script.
#
# Options:
#   --purge-data       Remove downloaded images/data (~/.local/share/commons-potd-wallpaper)
#   --purge-cache      Remove state/cache (~/.cache/commons-potd-wallpaper)
#   --disable-linger   Disable lingering for this user (requires sudo)
#   -h, --help         Show help
# -----------------------------------------------------------------------------

SCRIPT_NAME="commons-potd-wallpaper.sh"
UNIT_BASE="commons-potd"

PURGE_DATA=0
PURGE_CACHE=0
DISABLE_LINGER=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --purge-data       Remove downloaded images/data directory
  --purge-cache      Remove cache/state directory
  --disable-linger   Disable lingering for this user (requires sudo)
  -h, --help         Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge-data) PURGE_DATA=1; shift ;;
    --purge-cache) PURGE_CACHE=1; shift ;;
    --disable-linger) DISABLE_LINGER=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if ! command -v systemctl >/dev/null 2>&1; then
  echo "Warning: systemctl not found. Will still remove files, but can't disable timer." >&2
fi

# Stop/disable timer and service if possible
if command -v systemctl >/dev/null 2>&1; then
  systemctl --user stop "${UNIT_BASE}.timer" >/dev/null 2>&1 || true
  systemctl --user disable "${UNIT_BASE}.timer" >/dev/null 2>&1 || true

  # Also stop any in-flight service run
  systemctl --user stop "${UNIT_BASE}.service" >/dev/null 2>&1 || true
fi

# Remove unit files
unit_dir="$HOME/.config/systemd/user"
rm -f "$unit_dir/${UNIT_BASE}.timer" "$unit_dir/${UNIT_BASE}.service"

# Reload systemd user daemon to forget removed units
if command -v systemctl >/dev/null 2>&1; then
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user reset-failed >/dev/null 2>&1 || true
fi

# Remove installed script
rm -f "$HOME/.local/bin/$SCRIPT_NAME"

# Optional: purge data/cache created by the program
data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/commons-potd-wallpaper"
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/commons-potd-wallpaper"

if [[ $PURGE_DATA -eq 1 ]]; then
  rm -rf "$data_dir"
fi

if [[ $PURGE_CACHE -eq 1 ]]; then
  rm -rf "$cache_dir"
fi

# Optional: disable lingering
if [[ $DISABLE_LINGER -eq 1 ]]; then
  echo "Disabling lingering for user '$USER' (requires sudo)..."
  sudo loginctl disable-linger "$USER"
fi

echo "Uninstall complete."
echo "Removed:"
echo "  - $HOME/.local/bin/$SCRIPT_NAME"
echo "  - $unit_dir/${UNIT_BASE}.service"
echo "  - $unit_dir/${UNIT_BASE}.timer"

if [[ $PURGE_DATA -eq 1 ]]; then
  echo "  - $data_dir"
fi
if [[ $PURGE_CACHE -eq 1 ]]; then
  echo "  - $cache_dir"
fi