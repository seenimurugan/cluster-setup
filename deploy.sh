#!/usr/bin/env bash
# deploy.sh — bootstrap the homelab Kubernetes cluster.
#
# Idempotent — safe to re-run. Patches existing resources, skips installed
# brew packages, and gracefully handles already-loaded LaunchAgents.
#
# Order of operations:
#   1. Load .env (abort with a hint if missing)
#   2. ./00-prereqs.sh        — brew tools
#   3. ./10-orbstack.sh       — verify OrbStack + k3s reachable
#   4. envsubst | kubectl apply  for each numbered manifest
#   5. envsubst | launchctl bootstrap  for each plist template
#   6. Print summary
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CLUSTER_SETUP_DIR="$SCRIPT_DIR"

# ── 1. Load .env ─────────────────────────────────────────────────────────────
ENV_FILE="$SCRIPT_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env not found."
  echo "       cp .env.example .env && \$EDITOR .env"
  echo "       then re-run ./deploy.sh"
  exit 1
fi
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

# Fill any optional vars from the running shell so envsubst has them.
: "${USER_HOME:=$HOME}"
: "${USER_NAME:=$USER}"
: "${HOMELAB_NAMESPACE:=homelab}"
export USER_HOME USER_NAME HOMELAB_NAMESPACE HOMELAB_HDD_PATH HOMELAB_LOCAL_DATA HOMELAB_TIER_HDD_PATH CLUSTER_SETUP_DIR

echo "[deploy] Bootstrapping homelab cluster from: $SCRIPT_DIR"
echo "[deploy]   HOMELAB_NAMESPACE       = ${HOMELAB_NAMESPACE}"
echo "[deploy]   HOMELAB_HDD_PATH        = ${HOMELAB_HDD_PATH:-<unset>}"
echo "[deploy]   HOMELAB_LOCAL_DATA      = ${HOMELAB_LOCAL_DATA:-<unset>}"
echo "[deploy]   HOMELAB_TIER_HDD_PATH   = ${HOMELAB_TIER_HDD_PATH:-<unset>}"
echo "[deploy]   USER_HOME / USER_NAME   = ${USER_HOME} / ${USER_NAME}"

# ── 2. Prereqs ───────────────────────────────────────────────────────────────
echo ""
echo "[deploy] (1/5) brew prerequisites"
"$SCRIPT_DIR/00-prereqs.sh"

# envsubst on macOS lives under brew's gettext — make sure PATH is right for
# the rest of this script (00-prereqs already did the same export for itself).
if ! command -v envsubst &>/dev/null; then
  GETTEXT_PREFIX="$(brew --prefix gettext 2>/dev/null || true)"
  [ -n "$GETTEXT_PREFIX" ] && export PATH="$GETTEXT_PREFIX/bin:$PATH"
fi

# ── 3. OrbStack ──────────────────────────────────────────────────────────────
echo ""
echo "[deploy] (2/5) OrbStack / k3s reachability"
"$SCRIPT_DIR/10-orbstack.sh"

# ── 4. HDD path preflight ────────────────────────────────────────────────────
echo ""
echo "[deploy] (3/5) HDD preflight"
if [ -z "${HOMELAB_HDD_PATH:-}" ]; then
  echo "ERROR: HOMELAB_HDD_PATH is not set in .env"
  exit 1
fi
if [ ! -d "$HOMELAB_HDD_PATH" ]; then
  echo "ERROR: HOMELAB_HDD_PATH not found: $HOMELAB_HDD_PATH"
  echo "       Plug in the external HDD and ensure it mounts at that path."
  exit 1
fi
# Create the subfolders the PVs hostPath into so the first pod doesn't fail
# with hostPath-not-found.
for sub in jellyfin/media jellyfin/config immich/upload; do
  if [ ! -d "$HOMELAB_HDD_PATH/$sub" ]; then
    echo "  → mkdir $HOMELAB_HDD_PATH/$sub"
    mkdir -p "$HOMELAB_HDD_PATH/$sub"
  fi
done

# ── 5. Manifests ─────────────────────────────────────────────────────────────
# IMPORTANT: restrict envsubst to ONLY the placeholders we own. The
# tiered-storage-mover.yaml embeds a shell script with its own ${APP},
# ${IMMICH_SSD}, etc. — we must not clobber those.
ENVSUBST_VARS='${HOMELAB_NAMESPACE} ${HOMELAB_HDD_PATH} ${HOMELAB_LOCAL_DATA} ${HOMELAB_TIER_HDD_PATH} ${USER_HOME} ${USER_NAME} ${CLUSTER_SETUP_DIR}'

echo ""
echo "[deploy] (4/5) Cluster manifests"
for f in \
    "$SCRIPT_DIR/20-namespaces.yaml" \
    "$SCRIPT_DIR/30-storage.yaml" \
    "$SCRIPT_DIR/40-ingress.yaml" \
    "$SCRIPT_DIR/50-tiered-storage-mover.yaml"; do
  echo "  → applying $(basename "$f")"
  envsubst "$ENVSUBST_VARS" < "$f" | kubectl apply -f -
done

# Optional extras under k8s/
if [ -d "$SCRIPT_DIR/k8s" ]; then
  shopt -s nullglob
  for f in "$SCRIPT_DIR/k8s"/*.yaml; do
    echo "  → applying $(basename "$f")"
    envsubst "$ENVSUBST_VARS" < "$f" | kubectl apply -f -
  done
  shopt -u nullglob
fi

# ── 6. LaunchAgents ──────────────────────────────────────────────────────────
echo ""
echo "[deploy] (5/5) LaunchAgents (~/Library/LaunchAgents)"
LAUNCH_DIR="$USER_HOME/Library/LaunchAgents"
mkdir -p "$LAUNCH_DIR"
UID_NUM="$(id -u)"

for tpl in "$SCRIPT_DIR/launchd"/*.plist; do
  # The template files are named com.USER_NAME.<service>.plist. Rendered
  # filename substitutes USER_NAME → ${USER_NAME}.
  base="$(basename "$tpl")"
  rendered_name="${base//USER_NAME/$USER_NAME}"
  dest="$LAUNCH_DIR/$rendered_name"

  echo "  → rendering $base → $dest"
  envsubst < "$tpl" > "$dest"

  # bootstrap (load) — gracefully handle "already loaded"
  if launchctl bootstrap "gui/${UID_NUM}" "$dest" 2>/dev/null; then
    echo "    bootstrap OK"
  else
    echo "    already loaded (or bootstrap unsupported); trying refresh"
    launchctl bootout "gui/${UID_NUM}" "$dest" 2>/dev/null || true
    launchctl bootstrap "gui/${UID_NUM}" "$dest" || true
  fi
done

# ── 7. Summary ───────────────────────────────────────────────────────────────
cat <<EOF

────────────────────────────────────────────────────────────────────────
✓ cluster-setup deploy complete.
────────────────────────────────────────────────────────────────────────

Next steps (install in this order):
  1. tailscale-operator   — Tailscale Ingress class + auto-HTTPS
  2. shared-postgres      — the cluster's shared Postgres
  3. monitoring           — Prometheus + Grafana + Loki + Alloy
  4. App repos:
       chores, reminders, immich, jellyfin, grocy, filebrowser,
       arrstack, moviesda, emailmatrix, storage-console, docs-server

Useful local commands now:
  kubectl get pv,pvc -A
  kubectl get cronjob -n ${HOMELAB_NAMESPACE}
  ${SCRIPT_DIR}/scripts/tier-now.sh immich      # manual tier-storage run
  ${SCRIPT_DIR}/scripts/refresh-localhost.sh    # reload port-forwards

Docs:
  ${SCRIPT_DIR}/docs/MAINTENANCE.md
  ${SCRIPT_DIR}/docs/HDD-RECOVERY.md
  ${SCRIPT_DIR}/docs/architecture.md

EOF
