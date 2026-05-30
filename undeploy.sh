#!/usr/bin/env bash
# undeploy.sh — remove cluster-wide resources owned by cluster-setup.
#
# What this DELETES:
#   • LaunchAgent plists in ~/Library/LaunchAgents/ (unloaded + removed)
#   • The tiered-storage-mover ConfigMap, ServiceAccount and CronJobs
#   • The Jellyfin + Immich Tailscale Ingresses
#   • The HDD-backed PersistentVolumes (PVCs are kept — see below)
#   • The homelab / monitoring / tailscale namespaces
#
# What this DOES NOT touch:
#   • OrbStack itself, the k3s cluster, or brew-installed CLIs
#   • The data on $HOMELAB_HDD_PATH (your photos / media)
#   • PersistentVolumeClaims on local-path storage (your databases)
#
# WARNING: deleting a namespace cascades to ALL resources inside it.
# Stop apps first if you want a clean tear-down sequence.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
fi
: "${HOMELAB_NAMESPACE:=homelab}"
: "${USER_HOME:=$HOME}"
: "${USER_NAME:=$USER}"

echo "[undeploy] Removing cluster-setup resources."
echo "[undeploy]   namespace = $HOMELAB_NAMESPACE"

# ── LaunchAgents ─────────────────────────────────────────────────────────────
UID_NUM="$(id -u)"
LAUNCH_DIR="$USER_HOME/Library/LaunchAgents"
for tpl in "$SCRIPT_DIR/launchd"/*.plist; do
  base="$(basename "$tpl")"
  rendered_name="${base//USER_NAME/$USER_NAME}"
  dest="$LAUNCH_DIR/$rendered_name"
  if [ -f "$dest" ]; then
    echo "  → unloading + removing $dest"
    launchctl bootout "gui/${UID_NUM}" "$dest" 2>/dev/null || true
    rm -f "$dest"
  fi
done

# ── Tiered-storage CronJobs / ConfigMap / SA ─────────────────────────────────
kubectl -n "$HOMELAB_NAMESPACE" delete cronjob tier-mover-immich   --ignore-not-found
kubectl -n "$HOMELAB_NAMESPACE" delete cronjob tier-mover-jellyfin --ignore-not-found
kubectl -n "$HOMELAB_NAMESPACE" delete configmap tiered-storage-mover-script --ignore-not-found
kubectl -n "$HOMELAB_NAMESPACE" delete serviceaccount tiered-storage-mover    --ignore-not-found

# ── Ingresses ────────────────────────────────────────────────────────────────
kubectl -n "$HOMELAB_NAMESPACE" delete ingress jellyfin --ignore-not-found
kubectl -n "$HOMELAB_NAMESPACE" delete ingress immich   --ignore-not-found

# ── PVs (PVCs in $HOMELAB_NAMESPACE will be cascade-deleted with the ns) ─────
kubectl delete pv jellyfin-media-pv  --ignore-not-found
kubectl delete pv jellyfin-config-pv --ignore-not-found
kubectl delete pv immich-upload-pv   --ignore-not-found

# ── Namespaces (this cascades to everything else) ────────────────────────────
echo "  → deleting namespace $HOMELAB_NAMESPACE (cascades to apps)"
kubectl delete namespace "$HOMELAB_NAMESPACE" --ignore-not-found
kubectl delete namespace monitoring           --ignore-not-found
kubectl delete namespace tailscale            --ignore-not-found

cat <<EOF

────────────────────────────────────────────────────────────────────────
✓ cluster-setup undeploy complete.
────────────────────────────────────────────────────────────────────────

Data on \$HOMELAB_HDD_PATH (${HOMELAB_HDD_PATH:-unset}) is untouched.

To rebuild:  ./deploy.sh

EOF
