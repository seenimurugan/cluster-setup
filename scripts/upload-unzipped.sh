#!/bin/bash
# Stream G — upload ~/Pictures/_unzipped (Dropbox + Google Takeout extracts)
# to Immich, auto-delete on success. SSD source, runs in parallel with
# the existing drone-footage HDD upload.

set -u

LOGDIR="$HOME/homelab/uploads"
mkdir -p "$LOGDIR"

upload_one() {
  local folder="$1"
  local name
  name=$(basename "$folder" | tr ' ' '_' | tr -d "'")
  local log="$LOGDIR/EXT_$name.log"

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] >>> START upload: $folder"
  /opt/homebrew/bin/immich upload -r -a "$folder" >> "$log" 2>&1
  local rc=$?
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] <<< END   upload: $folder (exit $rc)"

  if [ "$rc" -ne 0 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] !! Upload failed (rc=$rc), source NOT deleted: $folder"
    return
  fi

  if grep -qiE "error:|failed to upload|exception|rejected|EACCES|ENOENT" "$log"; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] !! Error markers in log, source NOT deleted. Review: $log"
    return
  fi

  if [ ! -e "$folder" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] (already gone): $folder"
    return
  fi

  local size
  size=$(du -sh "$folder" 2>/dev/null | cut -f1)
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deleting source ($size): $folder"
  rm -rf "$folder"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ Deleted: $folder"
}

stream_g() {
  upload_one "/Users/nila/Pictures/_unzipped"
}

( stream_g 2>&1 | tee "$LOGDIR/stream-g.log" )
echo "[$(date '+%Y-%m-%d %H:%M:%S')] === STREAM G DONE ==="
