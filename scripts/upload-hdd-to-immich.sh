#!/bin/bash
# Upload HDD photo folders to Immich in 2 parallel streams.
# Each immich CLI runs with --concurrency=9 internally (default).
# Duplicates are skipped by Immich based on file hash.

set -u

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
  upload_one "/Volumes/Seeni's HDD/Kuttima school photos"
  upload_one "/Volumes/Seeni's HDD/Pictures"
  upload_one "/Volumes/Seeni's HDD/Nithi Iphone 25-02-2023"
}

stream_b() {
  upload_one "/Volumes/Seeni's HDD/100MEDIA"
  upload_one "/Volumes/Seeni's HDD/Seeni Iphone 25-02-2023"
  upload_one "/Volumes/Seeni's HDD/Photos and videos"
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
