#!/bin/bash
# Expose Jellyfin and Immich via Tailscale IP (all your devices on the Tailnet
# can hit these URLs). kubectl port-forward listens on 0.0.0.0 so it's reachable
# on the Tailscale interface.
#
# Run in foreground (Ctrl-C to stop) or via launchd for auto-start.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
fi

NAMESPACE="${HOMELAB_NAMESPACE:-homelab}"
TAILSCALE_BIN="${TAILSCALE_BIN:-/Applications/Tailscale.app/Contents/MacOS/Tailscale}"
TS_IP="$($TAILSCALE_BIN ip -4)"

echo "[homelab] Tailscale IP: $TS_IP"
echo "[homelab] Starting port-forwards..."

# Forward Jellyfin (8096) and Immich (2283) — bind to all interfaces
kubectl port-forward svc/jellyfin 8096:8096 -n "$NAMESPACE" --address 0.0.0.0 &
JELLYFIN_PID=$!

kubectl port-forward svc/immich-server 2283:2283 -n "$NAMESPACE" --address 0.0.0.0 &
IMMICH_PID=$!

echo ""
echo "[homelab] Services exposed on Tailscale:"
echo "  Jellyfin:  http://$TS_IP:8096"
echo "  Immich:    http://$TS_IP:2283"
echo ""
echo "[homelab] PIDs: jellyfin=$JELLYFIN_PID immich=$IMMICH_PID"
echo "[homelab] Press Ctrl-C to stop."

trap 'echo "[homelab] Stopping..."; kill $JELLYFIN_PID $IMMICH_PID 2>/dev/null; exit 0' INT TERM

wait
