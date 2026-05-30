#!/bin/bash
# Upload HDD photo folders to Immich in 2 parallel streams.
# Each immich CLI runs with --concurrency=9 internally (default).
# Duplicates are skipped by Immich based on file hash.

set -u

# Load parent .env (cluster-setup/.env) so HOMELAB_HDD_PATH / USER_HOME work
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
fi
: "${HOMELAB_HDD_PATH:=/Volumes/Seeni's HDD}"
: "${USER_HOME:=$HOME}"

LOGDIR="$HOME/homelab/uploads"
mkdir -p "$LOGDIR"

upload_one() {
  local folder="$1"
  local name
  name=$(basename "$folder" | tr ' ' '_')
  local log="$LOGDIR/$name.log"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] >>> START: $folder"
  /opt/homebrew/bin/immich upload -r -a "$folder" >> "$log" 2>&1
  local rc=$?
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] <<< END:   $folder (exit $rc)"
}

stream_a() {
  upload_one "${HOMELAB_HDD_PATH}/Kuttima school photos"
  upload_one "${HOMELAB_HDD_PATH}/Pictures"
  upload_one "${HOMELAB_HDD_PATH}/Nithi Iphone 25-02-2023"
}

stream_b() {
  upload_one "${HOMELAB_HDD_PATH}/100MEDIA"
  upload_one "${HOMELAB_HDD_PATH}/Seeni Iphone 25-02-2023"
  upload_one "${HOMELAB_HDD_PATH}/Photos and videos"
}

( stream_a 2>&1 | tee "$LOGDIR/stream-a.log" ) &
A_PID=$!
( stream_b 2>&1 | tee "$LOGDIR/stream-b.log" ) &
B_PID=$!

echo "Stream A pid=$A_PID  → tail $LOGDIR/stream-a.log"
echo "Stream B pid=$B_PID  → tail $LOGDIR/stream-b.log"
echo "Per-folder logs:        $LOGDIR/<folder_name>.log"

wait $A_PID
wait $B_PID
echo "[$(date '+%Y-%m-%d %H:%M:%S')] === ALL STREAMS DONE ==="
