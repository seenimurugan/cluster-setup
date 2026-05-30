# Databases in the homelab

How databases work in this homelab, and which apps use what.

## What you have

| App | DB engine | Where the data lives |
|---|---|---|
| **Grocy** (inventory) | SQLite (file) | `/config/data/grocy.db` inside the Grocy PVC |
| **Jellyfin** (movies) | SQLite (file) | `/config/data/jellyfin.db` inside the Jellyfin config PVC |
| **Email Matrix** | Postgres 17 | inside the `shared-postgres` pod |
| **Chores** (kids) | Postgres 17 | inside the `shared-postgres` pod |
| **Immich** (photos) | Postgres 17 + `pgvector` + `vectorchord` | inside the dedicated `immich-postgres` pod |

Two Postgres instances exist on purpose:
- **`shared-postgres`** — vanilla Postgres, shared by your custom apps (chores, emailmatrix, future apps).
- **`immich-postgres`** — specialized Postgres with vector-search extensions Immich requires. Isolated from the shared one to avoid affecting other apps if Immich's vector indexing misbehaves.

See per-app docs (`apps/<name>/ARCHITECTURE.md`) for each app's specifics. See `apps/shared-postgres/` for the shared instance.

---

## SQLite — what it actually is

**SQLite is a database stored entirely in a single file** on disk.

```
/config/data/grocy.db    ← the whole Grocy database is this one file
```

- Open it → it's a database
- Copy it → you've backed up the database
- Delete it → the database is gone

No server process running in the background. No port to connect to. No connection pool. When the app needs data, it directly opens and reads/writes the file like any other file on the filesystem.

### SQLite vs Postgres / MySQL / MariaDB

| | SQLite | Postgres / MySQL / MariaDB |
|---|---|---|
| What it is | A library + a file | A separate server process |
| Stored as | One binary file (`grocy.db`) | A directory of files managed by the server |
| How apps connect | Open the file directly | TCP/socket connection to the server |
| Needs a separate pod / container? | ❌ No | ✅ Yes |
| Concurrent writers | One at a time (serialized) | Many simultaneously |
| Network access | None — local file only | Network-accessible |
| Backup | `cp grocy.db backup.db` | `pg_dump` |
| Failure modes | File corruption (very rare); disk full | DB pod crash, network split, replication lag, … |

### Real-world analogy

- **SQLite** = an Excel file. You and one other person can't really edit it at the same time, but it's the simplest possible database. You move the file, you move the data.
- **Postgres** = a database server. Many apps connect at once, lots of features, but you need to keep the server running.

### When SQLite is great

- Single-user or low-write-rate apps (Grocy, Jellyfin config)
- Embedded databases (most desktop apps use it: Photos.app, WhatsApp, Firefox, etc.)
- Easy backup story (one file)
- No "what if the DB server is down" failure mode
- No network hop between app and DB

### When SQLite hits limits

- Multiple writers simultaneously (it serializes — can become a bottleneck)
- Cross-machine access (the file has to be local to the writer)
- Advanced features (full-text search at scale, replication, sharding, fancy types like vector embeddings)

For a family homelab, **both are fine** — Grocy and Jellyfin work great on SQLite because at most one person edits inventory or admin settings at a time. Postgres makes sense for apps where multiple family members hit it simultaneously (Immich = everyone backing up photos; Chores = each kid logging in).

---

## Why some apps use Postgres and others use SQLite

It's mostly determined by what the upstream app supports:

| App | Supported DB engines (upstream) | What we picked |
|---|---|---|
| **Grocy** | SQLite (default), MySQL, MariaDB — **not Postgres** | SQLite (no separate pod needed) |
| **Jellyfin** | SQLite (default) — newer versions experiment with Postgres | SQLite |
| **Immich** | **Postgres only** (requires pgvector + vectorchord for AI search) | Postgres, dedicated `immich-postgres` |
| **Chores** | Custom-built — we chose Postgres for it | Postgres on `shared-postgres` |
| **Email Matrix** | Custom-built — we chose Postgres for it | Postgres on `shared-postgres` |

For Grocy, we couldn't have used `shared-postgres` even if we wanted — Grocy doesn't support Postgres. The choices were SQLite (current), or running MariaDB just for Grocy. SQLite was the obvious pick — no extra pod, simpler backup.

---

## Inspect a database

### Open Grocy's SQLite interactively
```bash
kubectl exec -it -n homelab deployment/grocy -- sqlite3 /config/data/grocy.db
```

At the `sqlite>` prompt:
```sql
.tables                                    -- list tables
SELECT name, location_id FROM products;    -- view products
.quit
```

### Open Immich's Postgres
```bash
kubectl exec -it -n homelab immich-postgres-0 -- psql -U immich -d immich
```

### Open shared Postgres
```bash
kubectl exec -it -n homelab shared-postgres-0 -- psql -U postgres
```

Each app has more in its `apps/<name>/USAGE.md` or `MAINTENANCE.md`.

---

## Backup approaches

| Type | How to back up |
|---|---|
| SQLite | tar the whole PVC (which includes the `.db` file) — `kubectl exec ... -- tar czf - /config > backup.tar.gz` |
| Postgres | `pg_dump` for one DB, `pg_dumpall` for everything — pipe to gzip on the HDD |

Already-running weekly backup script: `~/homelab/backup-immich.sh` — currently only backs up Immich. To extend for other apps, see the script + each app's MAINTENANCE.md backup section.

---

## Adding a new app — pick the right DB

| If your app… | Use |
|---|---|
| Is yours, written from scratch, and you control the schema | `shared-postgres` (consistent with chores/emailmatrix) |
| Is upstream OSS supporting Postgres | `shared-postgres` (create a new DB inside it — see `apps/shared-postgres/USAGE.md`) |
| Is upstream OSS supporting only SQLite | SQLite + a PVC for the data file (like Grocy) |
| Needs vector / AI search | Dedicated Postgres with pgvector extension (or extend immich-postgres pattern — but better to stay separate per app) |
| Has very high write load (rare for homelab) | Its own dedicated Postgres pod to isolate failures |

See [ADD-NEW-APP.md](ADD-NEW-APP.md) for the deployment runbook.
