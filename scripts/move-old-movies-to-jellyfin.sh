#!/bin/bash
# Move ~/Pictures/old_movies → Jellyfin /media/movies/old_movies, then delete source.
# Source is internal SSD, destination is OrbStack VM ext4 (also on internal SSD).
# No virtiofs in the data path; safe to run in parallel with HDD photo uploads.

set -euo pipefail

# Load parent .env (cluster-setup/.env) so HOMELAB_HDD_PATH / USER_HOME work
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
fi
: "${HOMELAB_HDD_PATH:=/Volumes/Seeni's HDD}"
: "${USER_HOME:=$HOME}"

LOG="$HOME/homelab/uploads/move-old-movies.log"
SOURCE="${USER_HOME}/Pictures/old_movies"
NAMESPACE=homelab
exec >> "$LOG" 2>&1

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*"; }

log "=== START move old_movies → jellyfin ==="
SRC_SIZE_BEFORE=$(du -sh "$SOURCE" | cut -f1)
SRC_FILES_BEFORE=$(find "$SOURCE" -type f ! -name '.DS_Store' ! -name '._*' | wc -l | tr -d ' ')
log "Source: $SOURCE — $SRC_SIZE_BEFORE / $SRC_FILES_BEFORE files"

log "Streaming tar from macOS → jellyfin pod /media/movies/"
cd "$HOME/Pictures"
tar --exclude='._*' --exclude='.DS_Store' --exclude='.fseventsd' --exclude='.Spotlight-V100' \
    -cf - old_movies | \
  /opt/homebrew/bin/kubectl exec -i -n "$NAMESPACE" deployment/jellyfin -- tar -C /media/movies -xf -
log "tar pipe finished, verifying"

# Verify destination
DST_SIZE=$(/opt/homebrew/bin/kubectl exec -n "$NAMESPACE" deployment/jellyfin -- du -sh /media/movies/old_movies | cut -f1)
DST_FILES=$(/opt/homebrew/bin/kubectl exec -n "$NAMESPACE" deployment/jellyfin -- find /media/movies/old_movies -type f | wc -l | tr -d ' ')
log "Destination: /media/movies/old_movies — $DST_SIZE / $DST_FILES files"

# Sanity check
if [ "$SRC_FILES_BEFORE" != "$DST_FILES" ]; then
  log "ERROR: file count mismatch — source=$SRC_FILES_BEFORE dest=$DST_FILES. NOT deleting source."
  exit 1
fi

log "Counts match. Deleting source: $SOURCE"
rm -rf "$SOURCE"
log "Source deleted. $(du -sh "$HOME/Pictures" 2>/dev/null | cut -f1) now in ~/Pictures"
log "=== DONE ==="
