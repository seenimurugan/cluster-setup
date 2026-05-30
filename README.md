# cluster-setup

Bootstrap the homelab Kubernetes cluster on a fresh macOS machine.

This repo is the **foundation** for every other homelab app — clone it first, run `./deploy.sh`, then deploy individual apps from their own repos.

## What it sets up

- Brew prereqs: `kubectl`, `helm`, `gh`, `jq`, `gettext` (envsubst), `git`
- Verifies OrbStack is installed and k3s is reachable
- Three namespaces: `homelab`, `monitoring`, `tailscale`
- HDD-backed `PersistentVolumes` + `PersistentVolumeClaims` for Jellyfin (media + config) and Immich (upload)
- Tailscale `Ingress` resources for Jellyfin + Immich (auto-HTTPS once the Tailscale operator is installed)
- The tiered-storage-mover `CronJobs` (suspended by default — manual trigger via `scripts/tier-now.sh`)
- LaunchAgents for:
  - `homelab-backup` — weekly Immich + Jellyfin tar+zstd backup to the HDD
  - `homelab-localhost` — keeps `kubectl port-forward` running for LAN access on 8096/2283/8090/3000/8080

## What it does NOT install

These are separate app repos. Install in this order **after** cluster-setup:

1. **tailscale-operator** — creates the `tailscale` `IngressClass` (until then, the Ingresses above won't get an external IP)
2. **shared-postgres** — Postgres StatefulSet used by chores, reminders, etc.
3. **monitoring** — Prometheus, Grafana, Loki, Alloy
4. App repos:
   - `chores`, `reminders`, `immich`, `jellyfin`, `grocy`, `filebrowser`, `arrstack`, `moviesda`, `emailmatrix`, `storage-console`, `docs-server`

## Prerequisites

- macOS (Apple Silicon assumed; Intel works but image builds in the app repos default to `linux/arm64`)
- [Homebrew](https://brew.sh)
- [OrbStack](https://orbstack.dev), with Kubernetes (k3s) enabled in Settings → Kubernetes
- An external HDD plugged in and mounted at `$HOMELAB_HDD_PATH` (default `/Volumes/Seeni's HDD`)
- A Tailnet (free Tailscale account) — the auth key goes into the `tailscale-operator` app, not here

## Quick start

```bash
git clone https://github.com/seenimurugan/cluster-setup.git
cd cluster-setup
cp .env.example .env && $EDITOR .env   # set HOMELAB_HDD_PATH at minimum
./deploy.sh
```

`deploy.sh` is idempotent. Re-run it any time after editing `.env` or pulling new commits.

## Tear-down

```bash
./undeploy.sh
```

Removes the namespaces, ingresses, CronJobs, PVs and LaunchAgents that this repo owns. **Does not** touch your data on `$HOMELAB_HDD_PATH`, OrbStack, brew packages, or PVCs on local-path storage.

## Layout

```
cluster-setup/
├── README.md              you are here
├── .env.example           values to copy to .env
├── deploy.sh              bootstrap entry-point (idempotent)
├── undeploy.sh            remove cluster-wide resources (data safe)
├── 00-prereqs.sh          brew installs
├── 10-orbstack.sh         verify OrbStack + k3s reachable
├── 20-namespaces.yaml     homelab / monitoring / tailscale namespaces
├── 30-storage.yaml        HDD-backed PVs + PVCs
├── 40-ingress.yaml        Tailscale Ingress for jellyfin + immich
├── 50-tiered-storage-mover.yaml   ConfigMap + suspended CronJobs
├── k8s/                   extra cluster-wide manifests (optional, none yet)
├── launchd/               plist TEMPLATES — envsubst'd into ~/Library/LaunchAgents
├── scripts/               operator scripts (tier-now, backup-immich, port-forwards, uploads, …)
└── docs/                  architecture, learnings, runbooks, HDD recovery, command log
```

## Useful commands once deployed

```bash
kubectl get pv,pvc -A
kubectl get cronjob -n homelab
scripts/tier-now.sh immich         # one-shot tiered-storage move (Immich)
scripts/tier-now.sh jellyfin       # ditto (Jellyfin)
scripts/tier-now.sh backup         # one-shot backup-immich
scripts/refresh-localhost.sh       # reload the localhost port-forward LaunchAgent
```

## Migrating to a new Mac

See [`docs/HDD-RECOVERY.md`](docs/HDD-RECOVERY.md) for the disk-recovery flow and [`docs/MAINTENANCE.md`](docs/MAINTENANCE.md) for the broader runbook.

Things that are **not** captured in this repo and must be redone manually on a new Mac:

- Plug in the HDD and let macOS mount it at the same path (or update `HOMELAB_HDD_PATH`).
- Build and push (or build locally with `imagePullPolicy: Never`) the app container images — see each app repo.
- Re-issue the Tailscale auth key inside the `tailscale-operator` app's `.env`.
- The two PVC UUIDs hard-coded in `50-tiered-storage-mover.yaml` are specific to the OrbStack VM; on a new cluster, after the first immich + jellyfin pods bind their local-path PVCs, re-discover the paths with:
  ```bash
  kubectl get pv -o jsonpath='{range .items[?(@.spec.claimRef.name=="immich-upload-localpath-pvc")]}{.spec.local.path}{end}'
  kubectl get pv -o jsonpath='{range .items[?(@.spec.claimRef.name=="jellyfin-media-localpath-pvc")]}{.spec.local.path}{end}'
  ```
  Then edit `50-tiered-storage-mover.yaml` and re-apply.
- Re-create the storage-tier symlinks inside Immich / Jellyfin (see `docs/storage-tier/deploy.md`).

## Docs

- [`docs/architecture.md`](docs/architecture.md) — overall architecture
- [`docs/MAINTENANCE.md`](docs/MAINTENANCE.md) — day-to-day operations
- [`docs/ADD-NEW-APP.md`](docs/ADD-NEW-APP.md) — how to wire a new app into the cluster
- [`docs/HDD-RECOVERY.md`](docs/HDD-RECOVERY.md) — restore from HDD on a fresh Mac
- [`docs/DATABASES.md`](docs/DATABASES.md) — shared-postgres + per-app DBs
- [`docs/MAC-ALWAYS-ON.md`](docs/MAC-ALWAYS-ON.md) — keep the host awake for 24x7 service
- [`docs/storage-tier/`](docs/storage-tier/) — SSD-to-HDD tier-mover deploy guide
- [`docs/learnings.md`](docs/learnings.md) — debugging notes, gotchas

The same docs are also rendered live at https://docs.stoat-perch.ts.net (sidebar → Homelab Setup).
