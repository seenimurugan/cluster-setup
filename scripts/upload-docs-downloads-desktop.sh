#!/bin/bash
# 1. Move ~/Downloads/movies/* → Jellyfin /media/movies/ (then delete source)
# 2. Upload all remaining photos/videos in ~/Documents, ~/Downloads, ~/Desktop
#    to Immich; delete uploaded + duplicate files (leaves non-photo files alone)

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
LOG="$LOGDIR/docs-downloads-desktop.log"
exec >> "$LOG" 2>&1

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*"; }

log "=== START ==="

# ===========================================================================
# 1. Move ~/Downloads/movies → Jellyfin
# ===========================================================================
if [ -d "$HOME/Downloads/movies" ] && [ -n "$(ls -A "$HOME/Downloads/movies" 2>/dev/null)" ]; then
  log "Moving ~/Downloads/movies/* → jellyfin /media/movies/"
  src_count=$(find "$HOME/Downloads/movies" -type f ! -name '.DS_Store' ! -name '._*' | wc -l | tr -d ' ')
  log "  source files: $src_count"

  # COPYFILE_DISABLE=1 prevents macOS tar from synthesizing AppleDouble (._*) files
  # in the stream when source files have extended attributes.
  cd "$HOME/Downloads/movies"
  COPYFILE_DISABLE=1 tar --exclude='._*' --exclude='.DS_Store' -cf - . | \
    /opt/homebrew/bin/kubectl exec -i -n homelab deployment/jellyfin -- \
    tar -C /media/movies -xf -
  rc=$?
  log "  tar pipe exit: $rc"

  if [ "$rc" -eq 0 ]; then
    dst_count=$(/opt/homebrew/bin/kubectl exec -n homelab deployment/jellyfin -- \
      sh -c "find /media/movies -maxdepth 1 -type f -newer /media/movies/.move-marker 2>/dev/null | wc -l" 2>/dev/null | tr -d ' ' || echo "0")
    # Simpler verify: check that the specific files exist in dest
    all_present=true
    for f in "$HOME/Downloads/movies"/*; do
      [ -f "$f" ] || continue
      base=$(basename "$f")
      if ! /opt/homebrew/bin/kubectl exec -n homelab deployment/jellyfin -- \
        test -f "/media/movies/$base" 2>/dev/null; then
        log "  !! missing in dest: $base"
        all_present=false
      fi
    done
    if [ "$all_present" = "true" ]; then
      log "  ✓ all source files verified at destination, deleting source"
      rm -rf "$HOME/Downloads/movies"
      log "  ✓ ~/Downloads/movies deleted"
    else
      log "  !! some files missing in dest, source NOT deleted"
    fi
  else
    log "  !! tar pipe failed, source NOT deleted"
  fi
else
  log "~/Downloads/movies is empty or missing, skipping move"
fi

# ===========================================================================
# 2. Upload photos/videos from ~/Documents, ~/Downloads, ~/Desktop
# ===========================================================================
for dir in "$HOME/Documents" "$HOME/Downloads" "$HOME/Desktop"; do
  if [ ! -d "$dir" ]; then
    log "Skipping (missing): $dir"
    continue
  fi
  log ""
  log ">>> START immich upload --delete --delete-duplicates -r '$dir'"
  /opt/homebrew/bin/immich upload -r --delete --delete-duplicates -a "$dir" 2>&1 | \
    grep -E "Found|Successfully|Skipped|Error|Crawling" | sed 's/^/    /'
  rc=$?
  log "<<< END   immich upload (exit $rc)"
done

log ""
log "=== Final sizes ==="
du -sh "$HOME/Documents" "$HOME/Downloads" "$HOME/Desktop" 2>/dev/null | sed 's/^/  /'
log "=== DONE ==="
