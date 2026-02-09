#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Wikimedia Commons POTD Wallpaper - installer for Ubuntu (systemd --user)
#
# Installs:
#   - ~/.local/bin/commons-potd-wallpaper.sh
#   - ~/.local/bin/random-potd   (wrapper utility)
#   - ~/.config/systemd/user/commons-potd.service
#   - ~/.config/systemd/user/commons-potd.timer
#
# Enables:
#   - commons-potd.timer (runs daily at 00:00 UTC, and catches up on next login)
#
# Options:
#   --no-apt           Don't attempt to install dependencies via apt
#   --enable-linger    Enable user lingering (runs even while logged out)
#   --max-width N      Set MAX_WIDTH env for downloads (default 3840)
#   --keep N           Set KEEP env for retention (default 30)
#   --run-now          Run once immediately after install
# -----------------------------------------------------------------------------

SCRIPT_NAME="commons-potd-wallpaper.sh"
RANDOM_WRAPPER_NAME="random-potd"
UNIT_BASE="commons-potd"

NO_APT=0
ENABLE_LINGER=0
RUN_NOW=0
MAX_WIDTH=""
KEEP=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --no-apt           Don't install deps via apt
  --enable-linger    Enable lingering for this user (requires sudo)
  --max-width N      Set MAX_WIDTH for downloads (e.g. 3840)
  --keep N           Number of images to keep (e.g. 30)
  --run-now          Run once immediately after install
  -h, --help         Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-apt) NO_APT=1; shift ;;
    --enable-linger) ENABLE_LINGER=1; shift ;;
    --run-now) RUN_NOW=1; shift ;;
    --max-width) MAX_WIDTH="${2:?Missing value for --max-width}"; shift 2 ;;
    --keep) KEEP="${2:?Missing value for --keep}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
src_script="$repo_dir/$SCRIPT_NAME"

if [[ ! -f "$src_script" ]]; then
  echo "Error: expected $src_script to exist." >&2
  echo "Put $SCRIPT_NAME in the same repo directory as install.sh." >&2
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "Error: systemctl not found. This installer needs systemd." >&2
  exit 1
fi

install_deps() {
  local pkgs=(curl jq libxml2-utils)

  if [[ $NO_APT -eq 1 ]]; then
    echo "Skipping apt dependency install (--no-apt). Ensure these are installed: ${pkgs[*]}"
    return 0
  fi

  if ! command -v apt-get >/dev/null 2>&1; then
    echo "apt-get not found. Install dependencies manually: ${pkgs[*]}" >&2
    return 0
  fi

  echo "Installing dependencies: ${pkgs[*]}"

  # Be resilient to broken APT post-invoke hooks
  if ! sudo apt-get update; then
    echo "apt-get update failed. Retrying with post-invoke hooks disabled..."
    sudo apt-get \
      -o APT::Update::Post-Invoke-Success::= \
      -o APT::Update::Post-Invoke::= \
      update
  fi

  sudo apt-get install -y "${pkgs[@]}"
}

install_script() {
  echo "Installing main script to ~/.local/bin/$SCRIPT_NAME"
  mkdir -p "$HOME/.local/bin"
  install -m 0755 "$src_script" "$HOME/.local/bin/$SCRIPT_NAME"
}

install_random_wrapper() {
  echo "Installing random wrapper to ~/.local/bin/$RANDOM_WRAPPER_NAME"
  mkdir -p "$HOME/.local/bin"
  cat > "$HOME/.local/bin/$RANDOM_WRAPPER_NAME" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec "$HOME/.local/bin/commons-potd-wallpaper.sh" --random "$@"
EOF
  chmod 0755 "$HOME/.local/bin/$RANDOM_WRAPPER_NAME"
}

write_units() {
  echo "Writing systemd user units to ~/.config/systemd/user/"
  mkdir -p "$HOME/.config/systemd/user"

  local env_lines=""
  if [[ -n "$MAX_WIDTH" ]]; then
    env_lines+="Environment=MAX_WIDTH=$MAX_WIDTH"$'\n'
  fi
  if [[ -n "$KEEP" ]]; then
    env_lines+="Environment=KEEP=$KEEP"$'\n'
  fi

  cat > "$HOME/.config/systemd/user/${UNIT_BASE}.service" <<EOF
[Unit]
Description=Wikimedia Commons Picture of the Day wallpaper

[Service]
Type=oneshot
ExecStart=%h/.local/bin/$SCRIPT_NAME
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=%t/bus
${env_lines}
EOF

  cat > "$HOME/.config/systemd/user/${UNIT_BASE}.timer" <<'EOF'
[Unit]
Description=Run POTD wallpaper daily at 00:00 UTC

[Timer]
OnCalendar=*-*-* 00:00:00 UTC
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

enable_timer() {
  echo "Reloading user systemd and enabling timer..."
  systemctl --user daemon-reload
  systemctl --user enable --now "${UNIT_BASE}.timer"
}

maybe_run_now() {
  if [[ $RUN_NOW -eq 1 ]]; then
    echo "Running once now..."
    "$HOME/.local/bin/$SCRIPT_NAME" --force || true
  fi
}

maybe_enable_linger() {
  if [[ $ENABLE_LINGER -eq 1 ]]; then
    echo "Enabling lingering for user '$USER' (requires sudo)..."
    sudo loginctl enable-linger "$USER"
  fi
}

show_path_hint() {
  if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    echo
    echo "NOTE: $HOME/.local/bin is not currently in your PATH."
    echo "To make '$RANDOM_WRAPPER_NAME' available in new shells, add this to ~/.profile:"
    echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
  fi
}

show_status() {
  echo
  echo "Installed. Timer status:"
  systemctl --user list-timers --all | grep -E "${UNIT_BASE}\.timer|NEXT|LEFT|LAST|PASSED|UNIT" || true
  echo
  echo "Quick commands:"
  echo "  Latest POTD now:   ~/.local/bin/$SCRIPT_NAME --force"
  echo "  Random POTD now:   $RANDOM_WRAPPER_NAME"
  echo
  echo "Logs:"
  echo "  journalctl --user -u ${UNIT_BASE}.service -n 100 --no-pager"
}

install_deps
install_script
install_random_wrapper
write_units
enable_timer
maybe_enable_linger
maybe_run_now
show_path_hint
show_status
