#!/bin/bash
# Watcher: waits for the HDD upload to finish, then triggers the Mac Photos upload.
# "HDD upload finished" = no more `immich upload ... HDD` processes running.

set -u

LOG="$HOME/homelab/uploads/watcher.log"
exec >> "$LOG" 2>&1

ts() { date '+%Y-%m-%d %H:%M:%S'; }

echo "[$(ts)] Watcher started, waiting for HDD upload to complete..."

# Poll until no more immich upload processes are working on /Volumes/Seeni's HDD/
while pgrep -fl "immich upload .*Volumes/Seeni" >/dev/null 2>&1; do
  sleep 60
done

echo "[$(ts)] HDD upload finished. Starting Mac Photos upload..."
exec /Users/nila/homelab/upload-mac-photos-to-immich.sh
