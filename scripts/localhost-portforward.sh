#!/bin/bash
# Local + LAN port-forward for accessing homelab services from the Mac
# and any device on the home WiFi (TV, other laptops, etc.).
# Binds to 0.0.0.0 so LAN devices reach it via the Mac's LAN IP.
# Remote access (over internet) goes through Tailscale Ingress instead.

set -euo pipefail

NAMESPACE="homelab"

echo "[homelab] Port-forwards starting..."

kubectl port-forward svc/jellyfin 8096:8096 -n "$NAMESPACE" --address 0.0.0.0 &
J=$!

kubectl port-forward svc/immich-server 2283:2283 -n "$NAMESPACE" --address 0.0.0.0 &
I=$!

kubectl port-forward svc/docs 8090:80 -n "$NAMESPACE" --address 0.0.0.0 &
D=$!

kubectl port-forward svc/chores-frontend 3000:3000 -n "$NAMESPACE" --address 0.0.0.0 &
C=$!

kubectl port-forward svc/chores-backend 8080:8080 -n "$NAMESPACE" --address 0.0.0.0 &
CB=$!

echo "  Jellyfin:       http://localhost:8096   (LAN: http://<mac-lan-ip>:8096)"
echo "  Immich:         http://localhost:2283   (LAN: http://<mac-lan-ip>:2283)"
echo "  Docs:           http://localhost:8090   (LAN: http://<mac-lan-ip>:8090)"
echo "  Chores (web):   http://localhost:3000   (LAN: http://<mac-lan-ip>:3000)"
echo "  Chores (API):   http://localhost:8080   (LAN: http://<mac-lan-ip>:8080)"
echo "  PIDs: jellyfin=$J immich=$I docs=$D chores-fe=$C chores-be=$CB"

trap 'echo "[homelab] Stopping..."; kill $J $I $D $C $CB 2>/dev/null; exit 0' INT TERM

wait
