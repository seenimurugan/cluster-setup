#!/bin/bash
# Unzip ~/Pictures/Dropbox*.zip, upload contents to Immich, then delete
# the zips and the unzipped temp dir regardless of how many photos were
# new (per user request 2026-05-28: "see if there are any new photos?
# if not then delete").

set -u

LOGDIR="$HOME/homelab/uploads"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/dropbox-unzip.log"
exec >> "$LOG" 2>&1

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*"; }

TEMPDIR="$HOME/Pictures/_dropbox_unzipped"
mkdir -p "$TEMPDIR"

ZIPS=(
  "/Users/nila/Pictures/Dropbox (1).zip"
  "/Users/nila/Pictures/Dropbox (2).zip"
)

log "=== Dropbox unzip + upload START ==="

# 1. Unzip each
for zip in "${ZIPS[@]}"; do
  [ -f "$zip" ] || { log "missing (skip): $zip"; continue; }
  name=$(basename "$zip" .zip | tr ' ' '_' | tr -d '()')
  outdir="$TEMPDIR/$name"
  log "Unzipping $(basename "$zip") → $outdir"
  unzip -q -o "$zip" -d "$outdir"
  size=$(du -sh "$outdir" 2>/dev/null | cut -f1)
  count=$(find "$outdir" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.heic" -o -iname "*.heif" -o -iname "*.mov" -o -iname "*.mp4" -o -iname "*.m4v" -o -iname "*.gif" -o -iname "*.webp" \) 2>/dev/null | wc -l | tr -d ' ')
  log "  extracted: $size, $count photo/video files"
done

# 2. Upload everything in the temp dir
log "Uploading $TEMPDIR (recursive) to Immich"
UPLOADLOG="$LOGDIR/EXT_dropbox_unzipped.log"
/opt/homebrew/bin/immich upload -r -a "$TEMPDIR" >> "$UPLOADLOG" 2>&1
rc=$?
log "Upload exit code: $rc"
log "Upload summary:"
grep -E "Found|Successfully|Skipped|created" "$UPLOADLOG" | sed 's/^/    /' | head -10

# 3. Clean up — temp dir always; zips only if upload was clean
log "Deleting temp dir: $TEMPDIR"
rm -rf "$TEMPDIR"
log "✓ temp dir removed"

if [ "$rc" -eq 0 ] && ! grep -qiE "error:|failed to upload|exception|rejected" "$UPLOADLOG"; then
  for zip in "${ZIPS[@]}"; do
    if [ -f "$zip" ]; then
      sz=$(du -sh "$zip" | cut -f1)
      log "Deleting zip ($sz): $zip"
      rm -f "$zip"
    fi
  done
  log "✓ zips removed"
else
  log "!! Upload had errors — zips NOT removed. Review $UPLOADLOG"
fi

log "=== DONE ==="
df -h ~ | tail -1
