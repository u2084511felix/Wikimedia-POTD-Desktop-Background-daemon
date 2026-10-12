#!/usr/bin/env bash
# Compatibility entry point for existing cron jobs, timers and shortcuts.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec /usr/bin/env python3 "$SCRIPT_DIR/commons-potd-wallpaper.py" "$@"