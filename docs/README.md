# Homelab K8s Setup — Knowledge Base

Self-hosted homelab on Nila's Mac running OrbStack k3s. All captured knowledge lives in this folder.

## Documentation index

### Apps (grouped per-app — usage + maintenance + troubleshooting)
- 📸 [Immich (photos)](apps/immich/README.md) — [bulk upload](apps/immich/BULK-UPLOAD.md) · [upgrade](apps/immich/UPGRADE.md)
- 🎬 [Jellyfin (movies)](apps/jellyfin/README.md)
- 🥕 [Grocy (household inventory)](apps/grocy/README.md)
- 🐘 [Shared Postgres (for custom apps)](apps/shared-postgres/README.md)
- 📖 [Docs site](apps/docs-server/README.md)
- 🌐 [Tailscale operator](apps/tailscale/README.md)
- 📊 [Monitoring (Grafana / Prometheus / Loki)](apps/monitoring/README.md)

### Cluster-wide (one-stop)
- 🛠 [Maintenance](MAINTENANCE.md) — health checks, restart, scale, stuck things, cheat sheet
- ➕ [Add a new app](ADD-NEW-APP.md) — runbook for deploying anything new
- 🏛 [Architecture](architecture.md) + [Excalidraw diagram](architecture.excalidraw)

### Reference
- 🧠 [Learnings](learnings.md) — gotchas, tribal knowledge
- 📜 [Command Log](command-log.md) — what we ran during setup
- 📍 [Session State](session-state.md) — current state snapshot
- ⚙ [Configs (snapshots)](configs/) — live YAML copies for reference

## Workflow

- **Per-app questions** (how to use Jellyfin, restart Immich, etc.) → look in `apps/<app>/`
- **Cluster-wide** (Mac reboot, OrbStack restart, "add an app") → `MAINTENANCE.md` or `ADD-NEW-APP.md`
- **Anything mysterious** → `learnings.md`

## Where files live

| Purpose | Path |
|---|---|
| Documentation (this folder) | `/Users/nila/Developer/agents/docs/homelab-k8s-setup/` |
| Skill (reusable for new devices) | `/Users/nila/Developer/agents/skills/homelab-k8s-setup/SKILL.md` |
| Live runtime configs | `~/homelab/` (yaml, scripts) + `~/Library/LaunchAgents/` (launchd plists) |
| Snapshots of live configs | `configs/` in this folder |

## Adding new informational content

Any new file (markdown, txt, pdf) dropped into this folder is **instantly served** by the docs site at https://docs.stoat-perch.ts.net — no rebuild, no restart. To make it appear in the sidebar, edit `_sidebar.md`.
