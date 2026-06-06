#!/bin/bash
# Upload Mac Photos library + other ~/Pictures folders to Immich,
# then DELETE the source after each successful upload to free space.
# Runs in 2 parallel streams. Duplicates skipped by Immich's hash check.
#
# Scheduled to run AFTER upload-hdd-to-immich.sh completes — see
# upload-mac-photos-watcher.sh for the chaining logic.
#
# 2026-05-28 auto-delete behaviour:
#   - On `immich upload` exit 0 AND no error markers in the log,
#     the source folder is rm -rf'd. Otherwise NOT deleted; review the log.
#   - User confirmed iCloud Photos sync is disabled, so deleting the local
#     Photos Library will NOT trigger an iCloud redownload.

set -u

LOGDIR="$HOME/homelab/uploads"
mkdir -p "$LOGDIR"

# Quit Photos.app if running — it holds locks on the library bundle
osascript -e 'tell application "Photos" to if it is running then quit' 2>/dev/null || true

upload_one() {
  local upload_path="$1"
  local delete_path="${2:-$1}"      # default: delete what we uploaded
  local name
  name=$(basename "$upload_path" | tr ' ' '_' | tr -d "'")
  local log="$LOGDIR/MAC_$name.log"

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] >>> START upload: $upload_path"
  /opt/homebrew/bin/immich upload -r -a "$upload_path" >> "$log" 2>&1
  local rc=$?
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] <<< END   upload: $upload_path (exit $rc)"

  if [ "$rc" -ne 0 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] !! Upload failed (rc=$rc), source NOT deleted: $delete_path"
    return
  fi

  # Sanity check the log for failure markers
  if grep -qiE "error:|failed to upload|exception|rejected|EACCES|ENOENT" "$log"; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] !! Error markers in log — source NOT deleted: $delete_path"
    echo "       review: $log"
    return
  fi

  if [ ! -e "$delete_path" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] (already gone): $delete_path"
    return
  fi

  local size
  size=$(du -sh "$delete_path" 2>/dev/null | cut -f1)
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deleting source ($size): $delete_path"
  rm -rf "$delete_path"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ Deleted: $delete_path"
}

stream_c() {
  # Upload from /originals (where the photos actually live), then delete the
  # WHOLE .photoslibrary bundle (originals + database + metadata caches).
  upload_one \
    "/Users/nila/Pictures/Photos Library.photoslibrary/originals" \
    "/Users/nila/Pictures/Photos Library.photoslibrary"
}

stream_d() {
  upload_one "/Users/nila/Pictures/Nithi iphone large photos"
  upload_one "/Users/nila/Pictures/portable printer photos and video"
}

( stream_c 2>&1 | tee "$LOGDIR/stream-c.log" ) &
C_PID=$!
( stream_d 2>&1 | tee "$LOGDIR/stream-d.log" ) &
D_PID=$!

echo "Stream C pid=$C_PID  → tail $LOGDIR/stream-c.log"
echo "Stream D pid=$D_PID  → tail $LOGDIR/stream-d.log"

wait $C_PID
wait $D_PID
echo "[$(date '+%Y-%m-%d %H:%M:%S')] === MAC PHOTOS UPLOAD DONE ==="
df -h ~ | tail -1
