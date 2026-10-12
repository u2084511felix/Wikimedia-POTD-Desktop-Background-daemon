#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="commons-potd-wallpaper.sh"
PYTHON_NAME="commons-potd-wallpaper.py"
RANDOM_WRAPPER_NAME="random-potd"
INFO_WRAPPER_NAME="potd-info"
SAVE_WRAPPER_NAME="potd-save"
UNIT_BASE="commons-potd"

NO_APT=0
ENABLE_LINGER=0
RUN_NOW=0
MAX_WIDTH=""
KEEP=""
TIMER_TIME="00:00:00"

usage() {
  cat <<EOF_USAGE
Usage: $(basename "$0") [options]

Options:
  --no-apt             Don't install Python via apt if missing
  --enable-linger      Enable lingering for this user
  --max-width N        Set MAX_WIDTH for downloads
  --keep N             Number of cached images to keep
  --timer-time HH:MM   Local daily timer time; default 00:00
  --run-now            Run once immediately after install
  -h, --help           Show this help
EOF_USAGE
}

normalise_timer_time() {
  local t="$1"
  if [[ "$t" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    printf '%s:00' "$t"
  elif [[ "$t" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$ ]]; then
    printf '%s' "$t"
  else
    echo "Invalid --timer-time '$t'. Use HH:MM or HH:MM:SS in 24-hour local time." >&2
    exit 2
  fi
}

positive_integer() {
  local option="$1" value="$2"
  if [[ ! "$value" =~ ^[0-9]+$ ]] || (( 10#$value == 0 )); then
    echo "Invalid $option '$value': expected a positive integer." >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-apt) NO_APT=1; shift ;;
    --enable-linger) ENABLE_LINGER=1; shift ;;
    --run-now) RUN_NOW=1; shift ;;
    --max-width)
      MAX_WIDTH="${2:?Missing value for --max-width}"
      positive_integer --max-width "$MAX_WIDTH"
      shift 2 ;;
    --keep)
      KEEP="${2:?Missing value for --keep}"
      positive_integer --keep "$KEEP"
      shift 2 ;;
    --timer-time)
      TIMER_TIME="$(normalise_timer_time "${2:?Missing value for --timer-time}")"
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
src_script="$repo_dir/$SCRIPT_NAME"
src_python="$repo_dir/$PYTHON_NAME"

for source_file in "$src_script" "$src_python"; do
  if [[ ! -f "$source_file" ]]; then
    echo "Error: expected $source_file to exist." >&2
    echo "Put $SCRIPT_NAME and $PYTHON_NAME alongside install.sh." >&2
    exit 1
  fi
done

if ! command -v systemctl >/dev/null 2>&1; then
  echo "Error: systemctl not found. This installer needs systemd." >&2
  exit 1
fi

install_deps() {
  if command -v python3 >/dev/null 2>&1; then
    echo "Python 3 found: $(command -v python3)"
    return 0
  fi
  if [[ $NO_APT -eq 1 ]]; then
    echo "Error: python3 is required but not found (--no-apt specified)." >&2
    exit 1
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "Error: python3 is required; apt-get is unavailable. Install Python 3 manually." >&2
    exit 1
  fi
  echo "Installing Python 3 (only required runtime dependency)"
  if ! sudo apt-get update; then
    echo "apt-get update failed. Retrying with post-invoke hooks disabled..."
    sudo apt-get \
      -o APT::Update::Post-Invoke-Success::= \
      -o APT::Update::Post-Invoke::= \
      update
  fi
  sudo apt-get install -y python3
  command -v python3 >/dev/null 2>&1 || {
    echo "Error: python3 still unavailable after installation." >&2
    exit 1
  }
}

install_scripts() {
  echo "Installing Python implementation and compatibility wrapper to ~/.local/bin"
  mkdir -p "$HOME/.local/bin"
  install -m 0755 "$src_python" "$HOME/.local/bin/$PYTHON_NAME"
  install -m 0755 "$src_script" "$HOME/.local/bin/$SCRIPT_NAME"
}

install_wrappers() {
  echo "Installing convenience commands to ~/.local/bin"
  mkdir -p "$HOME/.local/bin"

  cat > "$HOME/.local/bin/$RANDOM_WRAPPER_NAME" <<'EOF_RANDOM'
#!/usr/bin/env bash
set -euo pipefail
exec "$HOME/.local/bin/commons-potd-wallpaper.sh" --random "$@"
EOF_RANDOM

  cat > "$HOME/.local/bin/$INFO_WRAPPER_NAME" <<'EOF_INFO'
#!/usr/bin/env bash
set -euo pipefail
exec "$HOME/.local/bin/commons-potd-wallpaper.sh" --info "$@"
EOF_INFO

  cat > "$HOME/.local/bin/$SAVE_WRAPPER_NAME" <<'EOF_SAVE'
#!/usr/bin/env bash
set -euo pipefail
exec "$HOME/.local/bin/commons-potd-wallpaper.sh" --save "$@"
EOF_SAVE

  chmod 0755 \
    "$HOME/.local/bin/$RANDOM_WRAPPER_NAME" \
    "$HOME/.local/bin/$INFO_WRAPPER_NAME" \
    "$HOME/.local/bin/$SAVE_WRAPPER_NAME"
}

write_units() {
  echo "Writing systemd user units to ~/.config/systemd/user"
  mkdir -p "$HOME/.config/systemd/user"

  local env_lines=""
  if [[ -n "$MAX_WIDTH" ]]; then
    env_lines+="Environment=MAX_WIDTH=$MAX_WIDTH"$'\n'
  fi
  if [[ -n "$KEEP" ]]; then
    env_lines+="Environment=KEEP=$KEEP"$'\n'
  fi

  cat > "$HOME/.config/systemd/user/${UNIT_BASE}.service" <<EOF_SERVICE
[Unit]
Description=Wikimedia Commons Picture of the Day wallpaper

[Service]
Type=oneshot
ExecStart=%h/.local/bin/$SCRIPT_NAME
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=%t/bus
${env_lines}
EOF_SERVICE

  cat > "$HOME/.config/systemd/user/${UNIT_BASE}.timer" <<EOF_TIMER
[Unit]
Description=Run POTD wallpaper daily at $TIMER_TIME local time

[Timer]
OnCalendar=*-*-* $TIMER_TIME
Persistent=true

[Install]
WantedBy=timers.target
EOF_TIMER
}

enable_timer() {
  echo "Reloading user systemd and enabling timer"
  systemctl --user daemon-reload
  systemctl --user enable --now "${UNIT_BASE}.timer"
}

maybe_enable_linger() {
  if [[ $ENABLE_LINGER -eq 1 ]]; then
    echo "Enabling lingering for user '$(id -un)'"
    sudo loginctl enable-linger "$(id -un)"
  fi
}

maybe_run_now() {
  if [[ $RUN_NOW -eq 1 ]]; then
    echo "Running once now"
    "$HOME/.local/bin/$SCRIPT_NAME" --force || {
      echo "Warning: immediate run failed; inspect the error above or journal logs." >&2
    }
  fi
}

show_path_hint() {
  if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    echo
    echo "NOTE: $HOME/.local/bin is not currently in your PATH."
    echo "Add this to ~/.profile:"
    echo '  export PATH="$HOME/.local/bin:$PATH"'
  fi
}

show_status() {
  echo
  echo "Installed. Timer status:"
  systemctl --user list-timers --all | grep -E "${UNIT_BASE}\\.timer|NEXT|LEFT|LAST|PASSED|UNIT" || true
  echo
  echo "Timer uses local system time, so daylight saving changes are handled by the OS timezone database."
  echo "Configured local run time: $TIMER_TIME"
  echo
  echo "Commands:"
  echo "  random-potd"
  echo "  potd-info"
  echo "  potd-save"
  echo
  echo "Logs:"
  echo "  journalctl --user -u ${UNIT_BASE}.service -n 100 --no-pager"
}

install_deps
install_scripts
install_wrappers
write_units
enable_timer
maybe_enable_linger
maybe_run_now
show_path_hint
show_status