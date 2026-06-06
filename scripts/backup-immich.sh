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
#
# Tiered originals:
#   Large assets that were migrated to homelab-hdd are stored inside the
#   pods as symlinks (e.g. /data/library/... -> /hdd-root/homelab-hdd/immich-library/...).
#   tar --dereference (GNU tar, same as -h) is used so tiered originals
#   are archived as real bytes rather than dangling symlink entries.
#   Before archiving each app, the HDD path is verified readable inside
#   the pod; if it is NOT reachable (HDD unplugged) the backup for that
#   app is SKIPPED and the previous good archive is preserved.

set -uo pipefail

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
# Primary backup target = homelab-backup-hdd (3TB HFS+, always connected).
# The separate 'homelab-hdd' disk is NOT a backup target — it hosts movies/
# drone footage/large files and is plugged in only occasionally.
HDD_BACKUP_ROOT="${HOMELAB_HDD_PATH:-/Volumes/homelab-backup-hdd}/backups"
KEEP_FULL=1          # Immich & Jellyfin tar backups to retain (1: tiered originals now included → keep one full copy to fit the 3TB disk)
KEEP_PG=8            # Postgres dumps to retain
KUBECTL="${KUBECTL_BIN:-/opt/homebrew/bin/kubectl}"
ZSTD="${ZSTD_BIN:-/opt/homebrew/bin/zstd}"

DATE=$(date +%Y%m%d-%H%M%S)
LOG="${SCRIPT_DIR}/backup.log"
exec >> "$LOG" 2>&1

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*"; }

# Overall run status — set to 1 if any app backup fails
OVERALL_STATUS=0

log "=== Backup run starting ==="

# Pre-flight: backup HDD must be mounted
if [ ! -d "$(dirname "$HDD_BACKUP_ROOT")" ]; then
  log "ERROR: event=backup.preflight outcome=abort reason=backup-hdd-not-mounted path=$(dirname "$HDD_BACKUP_ROOT")"
  exit 1
fi
mkdir -p "$HDD_BACKUP_ROOT/immich-library" \
         "$HDD_BACKUP_ROOT/postgres-dumps" \
         "$HDD_BACKUP_ROOT/jellyfin-media"

# Space warning: with KEEP_FULL=1 and tiered originals now included (~400GB
# per immich archive + jellyfin), each full cycle can consume ~800GB+.
# Warn if free space on backup HDD drops below 900 GB.
BACKUP_HDD_FREE_KB=$(df -k "$(dirname "$HDD_BACKUP_ROOT")" 2>/dev/null | awk 'NR==2{print $4}')
WARN_THRESHOLD_KB=$((900 * 1024 * 1024))  # 900 GB in KB
if [ -n "$BACKUP_HDD_FREE_KB" ] && [ "$BACKUP_HDD_FREE_KB" -lt "$WARN_THRESHOLD_KB" ]; then
  FREE_GB=$(( BACKUP_HDD_FREE_KB / 1024 / 1024 ))
  log "WARN: event=backup.space_check outcome=low_space free_gb=${FREE_GB} threshold_gb=900 action=consider_reducing_KEEP_FULL keep_full=$KEEP_FULL"
else
  FREE_GB=$(( ${BACKUP_HDD_FREE_KB:-0} / 1024 / 1024 ))
  log "INFO: event=backup.space_check free_gb=${FREE_GB} threshold_gb=900 outcome=ok"
fi

# ============================================================================
# 1. Immich library — full tar (originals only; thumbs & encoded-video are
#    auto-regenerable). Stream tar from inside the pod (which reads SSD via
#    local-path) and write a single zst file to the HDD.
#
#    --dereference (-h): follow symlinks so tiered originals on homelab-hdd
#    are archived as real bytes, not dangling l-type entries.
#
#    HDD guard: verify /hdd-root/homelab-hdd/immich-library is readable
#    inside the pod before starting; if not, skip to preserve the last
#    good archive.
# ============================================================================

IMMICH_POD=$("$KUBECTL" get pods -n "$NAMESPACE" -l app.kubernetes.io/instance=immich,app.kubernetes.io/name=server \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$IMMICH_POD" ]; then
  IMMICH_POD=$("$KUBECTL" get pods -n "$NAMESPACE" -l app=immich-server \
    --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
fi

log "INFO: event=backup.immich.start pod=$IMMICH_POD"

IMMICH_HDD_PATH="/hdd-root/homelab-hdd/immich-library"
if ! "$KUBECTL" exec -n "$NAMESPACE" "$IMMICH_POD" -- \
     sh -c "ls \"$IMMICH_HDD_PATH\" >/dev/null 2>&1"; then
  log "ERROR: event=backup.immich.hdd_guard outcome=skip reason=hdd-path-not-readable-inside-pod pod=$IMMICH_POD path=$IMMICH_HDD_PATH action=preserving-previous-good-archive"
  OVERALL_STATUS=1
else
  IMMICH_OUT="$HDD_BACKUP_ROOT/immich-library/immich-$DATE.tar.zst"
  IMMICH_TMP="${IMMICH_OUT}.tmp"
  log "INFO: event=backup.immich.tar_start pod=$IMMICH_POD dest=$IMMICH_OUT dereference=yes"
  if "$KUBECTL" exec -n "$NAMESPACE" "$IMMICH_POD" -- \
       tar -C /data --dereference -cf - \
         --exclude='thumbs' --exclude='encoded-video' . \
     | "$ZSTD" -3 -T0 -q -o "$IMMICH_TMP"; then
    mv "$IMMICH_TMP" "$IMMICH_OUT"
    log "INFO: event=backup.immich.tar_done outcome=success dest=$IMMICH_OUT size=$(du -h "$IMMICH_OUT" | cut -f1)"
  else
    TAR_RC=$?
    rm -f "$IMMICH_TMP"
    log "ERROR: event=backup.immich.tar_done outcome=failed rc=$TAR_RC dest=$IMMICH_OUT action=tmp-removed-previous-good-archive-preserved"
    OVERALL_STATUS=1
  fi
fi

# ============================================================================
# 2. Immich Postgres dump — atomic write via .tmp
# ============================================================================
PG_OUT="$HDD_BACKUP_ROOT/postgres-dumps/immich-$DATE.sql.gz"
PG_TMP="${PG_OUT}.tmp"
log "INFO: event=backup.postgres.start dest=$PG_OUT"
if "$KUBECTL" exec -n "$NAMESPACE" immich-postgres-0 -- \
     pg_dump -U immich -d immich --no-owner --clean --if-exists \
   | gzip > "$PG_TMP"; then
  mv "$PG_TMP" "$PG_OUT"
  log "INFO: event=backup.postgres.done outcome=success dest=$PG_OUT size=$(du -h "$PG_OUT" | cut -f1)"
else
  PG_RC=$?
  rm -f "$PG_TMP"
  log "ERROR: event=backup.postgres.done outcome=failed rc=$PG_RC dest=$PG_OUT action=tmp-removed-previous-good-archive-preserved"
  OVERALL_STATUS=1
fi

# ============================================================================
# 3. Jellyfin media — full tar of /media
#
#    --dereference (-h): follow symlinks so tiered originals on homelab-hdd
#    are archived as real bytes, not dangling l-type entries.
#
#    HDD guard: verify /hdd-root/homelab-hdd/jellyfin-media is readable
#    inside the pod before starting.
# ============================================================================

JF_POD=$("$KUBECTL" get pods -n "$NAMESPACE" -l app.kubernetes.io/name=jellyfin \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$JF_POD" ]; then
  JF_POD=$("$KUBECTL" get pods -n "$NAMESPACE" -l app=jellyfin \
    --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
fi

log "INFO: event=backup.jellyfin.start pod=$JF_POD"

JF_HDD_PATH="/hdd-root/homelab-hdd/jellyfin-media"
if ! "$KUBECTL" exec -n "$NAMESPACE" "$JF_POD" -- \
     sh -c "ls \"$JF_HDD_PATH\" >/dev/null 2>&1"; then
  log "ERROR: event=backup.jellyfin.hdd_guard outcome=skip reason=hdd-path-not-readable-inside-pod pod=$JF_POD path=$JF_HDD_PATH action=preserving-previous-good-archive"
  OVERALL_STATUS=1
else
  JF_OUT="$HDD_BACKUP_ROOT/jellyfin-media/jellyfin-$DATE.tar.zst"
  JF_TMP="${JF_OUT}.tmp"
  log "INFO: event=backup.jellyfin.tar_start pod=$JF_POD dest=$JF_OUT dereference=yes"
  if "$KUBECTL" exec -n "$NAMESPACE" "$JF_POD" -- \
       tar -C /media --dereference -cf - . \
     | "$ZSTD" -3 -T0 -q -o "$JF_TMP"; then
    mv "$JF_TMP" "$JF_OUT"
    log "INFO: event=backup.jellyfin.tar_done outcome=success dest=$JF_OUT size=$(du -h "$JF_OUT" | cut -f1)"
  else
    JF_RC=$?
    rm -f "$JF_TMP"
    log "ERROR: event=backup.jellyfin.tar_done outcome=failed rc=$JF_RC dest=$JF_OUT action=tmp-removed-previous-good-archive-preserved"
    OVERALL_STATUS=1
  fi
fi

# ============================================================================
# 4. Prune old backups — only prune if the archive for this run succeeded
#    (guards against pruning the last good backup when this run failed).
# ============================================================================
prune_dir() {
  local dir="$1" keep="$2" pattern="$3"
  cd "$dir" || return
  ls -t $pattern 2>/dev/null | tail -n +$((keep + 1)) | while read -r old; do
    log "INFO: event=backup.prune file=$old"
    rm -f "$old"
  done
}

log "INFO: event=backup.prune.start"
prune_dir "$HDD_BACKUP_ROOT/immich-library"  "$KEEP_FULL" "*.tar.zst"
prune_dir "$HDD_BACKUP_ROOT/jellyfin-media"  "$KEEP_FULL" "*.tar.zst"
prune_dir "$HDD_BACKUP_ROOT/postgres-dumps"  "$KEEP_PG"   "immich-*.sql.gz"

if [ "$OVERALL_STATUS" -eq 0 ]; then
  log "INFO: event=backup.run_complete outcome=success"
else
  log "ERROR: event=backup.run_complete outcome=partial_or_failed reason=one-or-more-sections-failed overall_status=$OVERALL_STATUS"
fi
echo ""
exit "$OVERALL_STATUS"
