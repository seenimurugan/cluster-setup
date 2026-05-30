#!/bin/bash
# tier-now.sh — manually trigger the tiered-storage mover or immich backup.
#
# Usage:
#   tier-now.sh immich    — run the immich tier mover  (cronjob/tier-mover-immich)
#   tier-now.sh jellyfin  — run the jellyfin tier mover (cronjob/tier-mover-jellyfin)
#   tier-now.sh backup    — run the immich backup       (cronjob/immich-backup)
#
# When to run the movers: after connecting homelab-hdd. They scan the SSD PVCs
# for files above the size threshold (2 GiB / 3 GiB) and move them to the HDD,
# leaving symlinks on the SSD.  Safe to re-run — already-moved files are skipped.
#
# When to run backup: any time you want a pg_dump + library tar snapshot on the HDD.
# The backup CronJob runs independently; it does not require the mover to have run first.
#
# Two concurrent invocations of the same job are NOT supported — wait for one to
# finish (concurrencyPolicy: Forbid on all three CronJobs).

set -euo pipefail

# Load parent .env so HOMELAB_TIER_HDD_PATH / HOMELAB_NAMESPACE are available.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
fi

NS="${HOMELAB_NAMESPACE:-homelab}"
HDD_ROOT="${HOMELAB_TIER_HDD_PATH:-/Volumes/homelab-hdd}"

# ----------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------
if [ $# -ne 1 ]; then
  echo "Usage: $0 immich | jellyfin | backup"
  exit 1
fi

TARGET="$1"
case "$TARGET" in
  immich)
    CRONJOB="tier-mover-immich"
    JOB_PREFIX="tier-immich"
    NEED_MOVER_DIRS=true
    ;;
  jellyfin)
    CRONJOB="tier-mover-jellyfin"
    JOB_PREFIX="tier-jellyfin"
    NEED_MOVER_DIRS=true
    ;;
  backup)
    CRONJOB="immich-backup"
    JOB_PREFIX="immich-backup"
    NEED_MOVER_DIRS=false
    ;;
  *)
    echo "ERROR: Unknown target '${TARGET}'. Must be immich, jellyfin, or backup."
    echo "Usage: $0 immich | jellyfin | backup"
    exit 1
    ;;
esac

# ----------------------------------------------------------------------
# Preflight — HDD must be mounted for all three jobs
# ----------------------------------------------------------------------
echo "[1/4] Checking HDD is mounted..."
if ! mount | grep -q " ${HDD_ROOT} "; then
    echo "ERROR: ${HDD_ROOT} is not mounted. Plug in the HDD and try again."
    exit 1
fi

if [ "$NEED_MOVER_DIRS" = "true" ]; then
  for d in immich-library jellyfin-media; do
      if [ ! -d "${HDD_ROOT}/${d}" ]; then
          echo "ERROR: ${HDD_ROOT}/${d} missing. Run docs/storage-tier/hdd-prep.md steps first."
          exit 1
      fi
  done
else
  # Backup job writes to ${HDD_ROOT}/backups
  if [ ! -d "${HDD_ROOT}/backups" ]; then
      echo "ERROR: ${HDD_ROOT}/backups missing."
      echo "       mkdir -p ${HDD_ROOT}/backups/postgres"
      echo "       mkdir -p ${HDD_ROOT}/backups/library"
      exit 1
  fi
fi

echo "[2/4] HDD OK. Triggering job from cronjob/${CRONJOB}..."
JOB_NAME="${JOB_PREFIX}-$(date +%Y%m%d-%H%M%S)"
kubectl create job --from="cronjob/${CRONJOB}" "${JOB_NAME}" -n "${NS}"

# ----------------------------------------------------------------------
# Wait for pod, then tail logs until completion
# ----------------------------------------------------------------------
echo "[3/4] Waiting for pod to start..."
# `kubectl wait --for=condition=Ready` on a Job's pod can fail because
# the pod terminates fast for tiny workloads. Poll for Pending->Running
# or Succeeded instead.
for _ in $(seq 1 30); do
    PHASE=$(kubectl get pod -n "${NS}" -l "job-name=${JOB_NAME}" \
        -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
    if [ "${PHASE}" = "Running" ] || [ "${PHASE}" = "Succeeded" ] || [ "${PHASE}" = "Failed" ]; then
        break
    fi
    sleep 2
done

echo "[4/4] Streaming logs..."
echo "----------------------------------------------------------------------"
kubectl logs -n "${NS}" -l "job-name=${JOB_NAME}" -f --tail=-1 || true
echo "----------------------------------------------------------------------"

# ----------------------------------------------------------------------
# Final job status
# ----------------------------------------------------------------------
kubectl get job -n "${NS}" "${JOB_NAME}"
FAILED=$(kubectl get job -n "${NS}" "${JOB_NAME}" -o jsonpath='{.status.failed}' 2>/dev/null || echo 0)
if [ "${FAILED:-0}" != "0" ]; then
    echo "Job reported failed pods. Check logs above for FAIL/ERROR lines."
    exit 1
fi
echo "Done. Job ${JOB_NAME} completed successfully."
