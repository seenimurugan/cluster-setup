#!/bin/bash
# Watcher: waits for the HDD upload to finish, then triggers the Mac Photos upload.
# "HDD upload finished" = no more `immich upload ... HDD` processes running.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
fi

LOG="$HOME/homelab/uploads/watcher.log"
mkdir -p "$(dirname "$LOG")"
exec >> "$LOG" 2>&1

ts() { date '+%Y-%m-%d %H:%M:%S'; }

echo "[$(ts)] Watcher started, waiting for HDD upload to complete..."

# Poll until no more immich upload processes are working on $HOMELAB_HDD_PATH/
# Match by the HDD path basename so different mount names still work.
HDD_PATTERN="${HOMELAB_HDD_PATH:-/Volumes/Seeni\'s HDD}"
while pgrep -fl "immich upload .*${HDD_PATTERN}" >/dev/null 2>&1; do
  sleep 60
done

echo "[$(ts)] HDD upload finished. Starting Mac Photos upload..."
exec ${SCRIPT_DIR}/upload-mac-photos-to-immich.sh
