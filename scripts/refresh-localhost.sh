#!/bin/zsh
# Refresh the launchd-managed localhost port-forward.
# Run when http://localhost:8096 / :2283 / :8090 returns HTTP 000
# (typically after a pod was restarted, or after a long-running upload
# that broke the kubectl port-forward connection).

set -uo pipefail

echo "[homelab] Refreshing localhost port-forward..."
launchctl unload ~/Library/LaunchAgents/com.nila.homelab-localhost.plist 2>/dev/null
pkill -f "kubectl port-forward" 2>/dev/null
sleep 2
launchctl load ~/Library/LaunchAgents/com.nila.homelab-localhost.plist
sleep 4

echo ""
echo "[homelab] Health checks:"
curl -s -o /dev/null -w "  Jellyfin (http://localhost:8096): HTTP %{http_code}\n" \
  --connect-timeout 5 http://localhost:8096/health
curl -s -o /dev/null -w "  Immich   (http://localhost:2283): HTTP %{http_code}\n" \
  --connect-timeout 5 http://localhost:2283/api/server/ping
curl -s -o /dev/null -w "  Docs     (http://localhost:8090): HTTP %{http_code}\n" \
  --connect-timeout 5 http://localhost:8090/
