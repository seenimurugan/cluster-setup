# Backups & Disaster Recovery

How every piece of homelab data is backed up, where it lands, how to trigger it, and how to restore. **All backups are now manual** (the Mac is a laptop — nothing runs on a schedule).

**On this page:** [What is backed up](#what-is-backed-up) · [The backup disk](#the-backup-disk) · [Immich (restic)](#1-immich--restic) · [Databases](#2-databases) · [Secrets (two mechanisms)](#3-secrets--two-mechanisms) · [Jellyfin (not backed up)](#4-jellyfin-media--not-backed-up) · [How to trigger a backup](#how-to-trigger-a-backup) · [How to restore](#how-to-restore) · [Disaster-recovery checklist](#disaster-recovery-checklist) · [Retired mechanisms](#retired-mechanisms)

---

## What is backed up

| Data | Mechanism | Destination | Trigger | Retention |
|---|---|---|---|---|
| **Immich** (photos lib + DB) | `restic` incremental | `homelab-backup-hdd/restic-immich` | Manual — *Immich Backup* card | keep-weekly 8, keep-monthly 24, prune |
| **All databases** (Postgres + SQLite) | `db-backup` CronJob | `homelab-backup-hdd/backups/databases/` | Manual — *DB Backup* card | latest dumps (overwritten per run) |
| **Secrets** — offline copy | `age`-encrypted dump | `homelab-backup-hdd/secrets/*.age` | Manual — *Secrets Backup* card | timestamped files |
| **Secrets** — in git | `SealedSecret` (ciphertext) | each app repo `k8s/sealed/` | per-change (committed) | git history |
| **Jellyfin media** | *(none — re-downloadable)* | — | — | — |

Everything writes to the **`homelab-backup-hdd`** disk. The two secret mechanisms are intentionally redundant — see [Secrets](#3-secrets--two-mechanisms).

---

## The backup disk

- **`homelab-backup-hdd`** — 3 TB, **HFS+ (journaled)**, the dedicated backup target, normally always connected. HFS+ (not exFAT) is required: journaled/crash-safe and preserves Unix permissions.
- A sentinel file **`/Volumes/homelab-backup-hdd/.homelab-backup-hdd`** marks the disk. Every backup job **refuses to run** if the marker is absent (i.e. the disk isn't mounted) — this prevents writing a "backup" into an empty mount point. `deploy.sh` recreates the marker.
- In-cluster, jobs reach the disk via the propagation-safe mount `/Volumes` → `/hdd-root` (`mountPropagation: HostToContainer`), so an unplug/replug is picked up without restarting pods. See [HDD recovery](/homelab-k8s-setup/HDD-RECOVERY.md).
- The separate **`homelab-hdd`** disk holds movies / large files and is **not** a backup target.

---

## 1. Immich — restic

The `immich-backup` CronJob (owned by **storage-console**, `k8s/40-cronjobs.yaml`; schedule `0 4 * * *` but **suspended/Manual**) runs a deduplicating incremental backup with [`restic`](https://restic.net):

- **initContainer** `pg-dump` → dumps the Immich Postgres DB to a shared `emptyDir` at `/work/immich-db.sql`.
- **main container** runs `restic backup --host immich --tag weekly /ssd-immich /hdd-immich /work`, which covers:
  - `/ssd-immich` — the live upload library on SSD (read-only mount of the Immich PVC),
  - `/hdd-immich` — the **tiered originals** that storage-console moved to `homelab-hdd`,
  - `/work` — the Postgres dump.
- **Repo:** `RESTIC_REPOSITORY=/repo` → host `/Volumes/homelab-backup-hdd/restic-immich`. Password from secret `restic-immich-secret`.
- **Incremental & deduplicated:** only chunks not already in the repo are written — a normal run uploads just the delta. The first run after a big import (e.g. a Google Takeout) is slow because that data is genuinely new and both disks are USB; subsequent runs are minutes.
- **Retention:** `restic forget --keep-weekly 8 --keep-monthly 24 --prune`.
- **Guard:** aborts unless `/backup-root/.homelab-backup-hdd` (the disk sentinel) exists.

> ⚠️ **Don't run two at once.** The job clears stale restic locks on startup, so two concurrent runs (e.g. a manual run plus a scheduled one) will steal each other's locks and one fails. With the CronJob on Manual and `concurrencyPolicy: Forbid`, just trigger one and let it finish.

---

## 2. Databases

The `db-backup` CronJob (storage-console, `k8s/60-db-backup.yaml`; schedule `0 5 * * *` but **suspended/Manual**) dumps every database in the homelab to `homelab-backup-hdd/backups/databases/`:

**Postgres** (`pg_dump`, gzipped → `…/databases/postgres/`):
- `shared-postgres-0`: `kidstasks`, `reminders`, `moviesda`, `emailmatrix`, `storage_console`
- `immich-postgres-0`: `immich`

**SQLite** (copied out of each app pod, then `sqlite3 .backup` runs *inside the backup job pod* for a checkpointed, integrity-checked copy → `…/databases/sqlite/`):
- `jellyfin` `/config/data/jellyfin.db`, `radarr` `/config/radarr.db`, `prowlarr` `/config/prowlarr.db`, `bazarr` `/config/db/bazarr.db`, `grocy` `/config/data/grocy.db`, `filebrowser` `/database/filebrowser.db`

If `sqlite3 .backup` fails for an app it falls back to a raw db copy and continues (one bad app doesn't abort the run). Guarded by the same disk sentinel.

**Restore runbook:** `apps/storage-console/docs/DB-RESTORE.md`. Background on which app uses which engine: [Databases](/homelab-k8s-setup/DATABASES.md).

---

## 3. Secrets — two mechanisms

Secrets are backed up **two ways on purpose**, because each fails differently:

**(a) Offline `age`-encrypted dump** — the *Secrets Backup* card (or `cluster-setup/scripts/backup-secrets.sh`) creates a one-off Job that dumps **all** cluster secrets and `age`-encrypts them to `homelab-backup-hdd/secrets/secrets-<timestamp>.age`.
- Recipient public key: `age1u79eew0x7dm8s6pnk7yvpzg2m0q3mgmrf72cn0wmm55fv5zu2gqs29y59m` (shipped in a ConfigMap — public keys are safe to ship).
- **Private key — KEEP OFFLINE:** `~/homelab-secrets-age-key.txt` (mode 600). This is the only thing that can decrypt the dump; store a copy somewhere off this Mac.
- Runs under a dedicated least-privilege ServiceAccount (`get,list` on `secrets` only).

**(b) `SealedSecret`s committed in git** — each app commits its secrets as encrypted `SealedSecret`s under `k8s/sealed/`. Only ciphertext is in git; decryption needs the in-cluster sealing key. See the [sealed-secrets explainer in the monitoring docs](/homelab-k8s-setup/apps/monitoring/MAINTENANCE.md) for how kubeseal works.
- The **sealing key** (`sealed-secrets-key*` in `kube-system`) is the crown jewel — without it the committed SealedSecrets are undecryptable. `backup-secrets.sh` captures it into the `age` dump (a), so the two mechanisms cover each other: the `.age` dump can rebuild a fresh cluster's sealing key, after which all committed SealedSecrets light up.

---

## 4. Jellyfin media — not backed up

Movie/TV files are **deliberately not backed up** — they're re-downloadable via the *arr stack (Radarr/Prowlarr/qBittorrent). Only Jellyfin's **config DB** is backed up (see [Databases](#2-databases)), which preserves watch state, users, and metadata. The media itself is acquired again on demand.

---

## How to trigger a backup

All three are **manual**. Easiest is the **storage-console dashboard** at <https://tier.stoat-perch.ts.net>:

- **Immich Backup** card → *Trigger Now*
- **DB Backup** card → *Trigger Now*
- **Secrets Backup** card → *Back Up Secrets Now* (on-demand, no schedule)

From the CLI instead:

```sh
kubectl -n homelab create job --from=cronjob/immich-backup immich-backup-manual-$(date +%s)
kubectl -n homelab create job --from=cronjob/db-backup     db-backup-manual-$(date +%s)
```

(The secrets backup is a one-off Job created by the storage-console backend, or run `cluster-setup/scripts/backup-secrets.sh` directly.)

Before triggering, make sure `homelab-backup-hdd` is mounted — otherwise the guard exits the job 0 (skipped, not failed).

---

## How to restore

- **Databases** → follow `apps/storage-console/docs/DB-RESTORE.md` (per-engine `psql` / `sqlite3` restore steps).
- **Immich** → restore from the restic repo:
  ```sh
  export RESTIC_REPOSITORY=/Volumes/homelab-backup-hdd/restic-immich
  export RESTIC_PASSWORD=...           # from secret/restic-immich-secret
  restic snapshots                      # list
  restic restore latest --target /tmp/immich-restore
  ```
  Then restore the Postgres dump (`/work/immich-db.sql` inside the snapshot) and copy the library back.
- **Secrets** → decrypt the offline dump with the offline private key:
  ```sh
  age -d -i ~/homelab-secrets-age-key.txt homelab-backup-hdd/secrets/secrets-<ts>.age > secrets.yaml
  ```
  Or, on a rebuilt cluster, restore the sealing key from that dump, then `kubectl apply` the committed `SealedSecret`s.

---

## Disaster-recovery checklist

To fully rebuild from nothing you need **all** of:

1. **The git repos** (app manifests + committed `SealedSecret`s).
2. **`homelab-backup-hdd`** (restic repo + DB dumps + the `.age` secret dump).
3. **The offline `age` private key** (`~/homelab-secrets-age-key.txt`) — store a copy off-Mac.

With those: redeploy apps from git → restore the sealing key from the `.age` dump → apply SealedSecrets → restore DBs from the dumps → restore Immich from restic.

---

## Retired mechanisms

- **`~/homelab/backup-immich.sh`** (weekly host `tar` of Immich + Jellyfin, run by launchd `com.nila.homelab-backup`) — **retired**. Immich is now covered by restic; Jellyfin media is not backed up by design. The launchd job is disabled (plist moved to `.disabled`). Do not re-enable it.
