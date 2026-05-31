# Session State

**Last updated:** 2026-05-26 (Pattern B migration complete)

**On this page:** [What's running](#whats-running) · [Mac state](#mac-state) · [Storage layout (unchanged)](#storage-layout-unchanged) · [Config files](#config-files) · [What's left for the user (manual)](#whats-left-for-the-user-manual) · [Backup TODO (deferred)](#backup-todo-deferred)

## What's running

| Component | Status | Endpoint |
|---|---|---|
| OrbStack k3s | ✅ Running | `kubectl get nodes` |
| Jellyfin | ✅ Healthy | **https://jellyfin.stoat-perch.ts.net** |
| Immich (server + ML + Postgres + Valkey) | ✅ Healthy | **https://immich.stoat-perch.ts.net** |
| Tailscale Operator | ✅ Running | namespace `tailscale` |
| Tailscale Ingress proxies (`ts-jellyfin-*`, `ts-immich-*`) | ✅ Running | one pod per Ingress |

## Mac state
- Tailscale.app: removed
- brew tailscale: removed
- `/usr/local/bin/tailscale`: removed
- System extension: terminated (fully unloads on next reboot)
- Old standalone Jellyfin.app: removed
- launchd port-forward job: removed
- The Mac is **no longer on the tailnet** — it's just the OrbStack host. The cluster pods own the tailnet presence.

## Storage layout (unchanged)

- **HDD (`/Volumes/Seeni's HDD/`, exFAT):**
  - `jellyfin/media/{movies,tvshows,music}` → `jellyfin-media-pvc` (2 Ti)
  - `jellyfin/config` → `jellyfin-config-pvc` (5 Gi)
  - `immich/upload` → `immich-upload-pvc` (1 Ti, photo blobs)
- **OrbStack VM (`local-path`, ext4):**
  - Immich Postgres data (20 Gi PVC, dynamically provisioned)

## Config files

- `~/homelab/storage.yaml` — PVs + PVCs for HDD
- `~/homelab/jellyfin-values.yaml` — Jellyfin Helm values
- `~/homelab/immich-postgres.yaml` — Postgres StatefulSet + Secret + Service
- `~/homelab/immich-values.yaml` — Immich Helm values
- `~/homelab/ingress.yaml` — Tailscale Ingress resources for Jellyfin + Immich

## What's left for the user (manual)

1. **Jellyfin first-time setup** — open https://jellyfin.stoat-perch.ts.net (from a tailnet device), create admin account, add media library (`/media/movies`, `/media/tvshows`).
2. **Immich first-time setup** — open https://immich.stoat-perch.ts.net, create admin account, invite family members.
3. **Upload media** — copy/move movies into `/Volumes/Seeni's HDD/jellyfin/media/movies/`. Jellyfin auto-scans.
4. **Install mobile apps** with the HTTPS URLs above as server.
5. **Rotate the OAuth credentials** at https://login.tailscale.com/admin/settings/oauth — they were pasted in chat, so generate fresh ones and re-deploy the operator with the new values:
   ```bash
   helm upgrade tailscale-operator tailscale/tailscale-operator -n tailscale \
     --set-string oauth.clientId='<NEW_ID>' --set-string oauth.clientSecret='<NEW_SECRET>' \
     --reuse-values
   ```
6. **Reboot Mac** to fully unload the Tailscale System Extension (cosmetic — already terminated).

## Backup TODO (deferred)

Postgres data lives inside the OrbStack VM. If you ever run `orbctl reset`, Immich's database is gone (photo metadata, albums, faces — but actual photo files survive on HDD).
Add a CronJob that does `pg_dump | gzip > /Volumes/Seeni's HDD/immich/backup-$(date).sql.gz` weekly.
