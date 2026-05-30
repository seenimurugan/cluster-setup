#!/bin/bash
# Weekly homelab backup (post-2026-05-27 architecture)
#
# Data layout after migration off the HDD:
#   - Immich library + Jellyfin media now live on internal SSD via
#     local-path PVCs (inside the OrbStack VM's ext4 image on APFS).
#   - The external HDD is now the BACKUP TARGET only.
#
# Strategy: stream tar from inside each running pod (reading SSD),
# pipe through zstd, write a SINGLE compressed file per app to the HDD.
# A single tar file means only one inode is created on the HDD per
# backup run — avoids the virtiofs FD accumulation that broke the
# previous rsync-based approach.

set -euo pipefail

# Load parent .env if present (so HOMELAB_HDD_PATH / HOMELAB_NAMESPACE override defaults)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
fi

# ============================================================================
# CONFIG
# ============================================================================
NAMESPACE="${HOMELAB_NAMESPACE:-homelab}"
HDD_BACKUP_ROOT="${HOMELAB_HDD_PATH:-/Volumes/Seeni's HDD}/backups"
KEEP_FULL=2          # Immich & Jellyfin tar backups to retain
KEEP_PG=8            # Postgres dumps to retain
KUBECTL="${KUBECTL_BIN:-/opt/homebrew/bin/kubectl}"
ZSTD="${ZSTD_BIN:-/opt/homebrew/bin/zstd}"

DATE=$(date +%Y%m%d-%H%M%S)
LOG="${SCRIPT_DIR}/backup.log"
exec >> "$LOG" 2>&1

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*"; }

log "=== Backup run starting ==="

# Pre-flight
if [ ! -d "$(dirname "$HDD_BACKUP_ROOT")" ]; then
  log "ERROR: HDD not mounted (parent dir missing). Skipping."
  exit 1
fi
mkdir -p "$HDD_BACKUP_ROOT/immich-library" \
         "$HDD_BACKUP_ROOT/postgres-dumps" \
         "$HDD_BACKUP_ROOT/jellyfin-media"

# 1. Immich library — full tar (originals only; thumbs & encoded-video are
#    auto-regenerable). Stream tar from inside the pod (which reads SSD via
#    local-path) and write a single zst file to the HDD.
IMMICH_OUT="$HDD_BACKUP_ROOT/immich-library/immich-$DATE.tar.zst"
log "Backing up Immich library → $IMMICH_OUT"
"$KUBECTL" exec -n "$NAMESPACE" deployment/immich-server -- \
  tar -C /data -cf - --exclude='thumbs' --exclude='encoded-video' . \
  | "$ZSTD" -3 -T0 -q -o "$IMMICH_OUT"
log "  size: $(du -h "$IMMICH_OUT" | cut -f1)"

# 2. Immich Postgres dump
PG_OUT="$HDD_BACKUP_ROOT/postgres-dumps/immich-$DATE.sql.gz"
log "Dumping Immich Postgres → $PG_OUT"
"$KUBECTL" exec -n "$NAMESPACE" immich-postgres-0 -- \
  pg_dump -U immich -d immich --no-owner --clean --if-exists \
  | gzip > "$PG_OUT"
log "  size: $(du -h "$PG_OUT" | cut -f1)"

# 3. Jellyfin media — full tar of /media
JF_OUT="$HDD_BACKUP_ROOT/jellyfin-media/jellyfin-$DATE.tar.zst"
log "Backing up Jellyfin media → $JF_OUT"
"$KUBECTL" exec -n "$NAMESPACE" deployment/jellyfin -- \
  tar -C /media -cf - . \
  | "$ZSTD" -3 -T0 -q -o "$JF_OUT"
log "  size: $(du -h "$JF_OUT" | cut -f1)"

# 4. Prune old backups
prune_dir() {
  local dir="$1" keep="$2" pattern="$3"
  cd "$dir" || return
  ls -t $pattern 2>/dev/null | tail -n +$((keep + 1)) | while read -r old; do
    log "  pruning $old"
    rm -f "$old"
  done
}
log "Pruning old backups"
prune_dir "$HDD_BACKUP_ROOT/immich-library"  "$KEEP_FULL" "*.tar.zst"
prune_dir "$HDD_BACKUP_ROOT/jellyfin-media"  "$KEEP_FULL" "*.tar.zst"
prune_dir "$HDD_BACKUP_ROOT/postgres-dumps"  "$KEEP_PG"   "immich-*.sql.gz"

log "=== Backup run finished successfully ==="
echo ""
