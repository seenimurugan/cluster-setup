# Homelab maintenance — self-serve runbook

Everything you need to operate the homelab without Claude. Read top-down when something's wrong; jump to specific sections for routine tasks.

**On this page:** [0. Quick health check (run first when anything seems wrong)](#0-quick-health-check-run-first-when-anything-seems-wrong) · [1. After a Mac reboot — what auto-recovers](#1-after-a-mac-reboot--what-auto-recovers) · [2. Where everything lives](#2-where-everything-lives) · [3. Restart things (smallest to biggest blast radius)](#3-restart-things-smallest-to-biggest-blast-radius) · [4. Scale things](#4-scale-things) · [5. Where to find logs](#5-where-to-find-logs) · [6. Stuck things — diagnosis flowchart](#6-stuck-things--diagnosis-flowchart) · [7. Routine tasks](#7-routine-tasks) · [8. Reach the services](#8-reach-the-services) · [9. Managing content on the docs site](#9-managing-content-on-the-docs-site) · [10. The "everything broke, start over" nuclear option](#10-the-everything-broke-start-over-nuclear-option) · [11. Cheat sheet — most-used commands](#11-cheat-sheet--most-used-commands) · [12. Bootstrap dependencies](#12-bootstrap-dependencies--what-must-be-true-on-a-fresh-mac)

---

## 0. Quick health check (run first when anything seems wrong)

```bash
# Are pods alive?
kubectl get pods -n homelab

# Cluster node ready?
kubectl get nodes

# Browser-facing endpoints?
curl -s -o /dev/null -w "Jellyfin: HTTP %{http_code}\n" http://localhost:8096/health
curl -s -o /dev/null -w "Immich:   HTTP %{http_code}\n" http://localhost:2283/api/server/ping

# CLI-facing (cluster DNS — most reliable):
curl -s -o /dev/null -w "Immich DNS: HTTP %{http_code}\n" http://immich-server.homelab.svc.cluster.local:2283/api/server/ping

# Storage growth:
du -sh "/Volumes/Seeni's HDD/immich/upload/library/"
```

Expected: pods all `1/1 Running`, node `Ready`, all HTTPs `200`.

---

## 1. After a Mac reboot — what auto-recovers

| Thing | Auto-starts? | Notes |
|---|---|---|
| OrbStack | ✅ Yes, if "Start at login" enabled | Check Apple menu → System Settings → Login Items |
| k3s cluster (inside OrbStack) | ✅ Yes | Comes up with OrbStack |
| All pods (Jellyfin, Immich, etc.) | ✅ Yes | Kubernetes Deployments restart pods automatically |
| Tailscale operator + proxy pods | ✅ Yes | Re-joins tailnet automatically using OAuth creds |
| Docs server (`https://docs.stoat-perch.ts.net`) | ✅ Yes | nginx + Docsify pod, mounted on the docs folder |
| launchd port-forward (`http://localhost:8096`, `:2283`) | ✅ Yes | Auto-loads from `~/Library/LaunchAgents/com.nila.homelab-localhost.plist` |
| External HDD (`/Volumes/Seeni's HDD`) | ⚠️ Only if physically plugged in | If HDD not present → Jellyfin/Immich won't have media/upload storage; pods may crash. Plug HDD in **before** Mac boots, ideally. |
| Backups | ⚙️ **Manual only** (no schedule) | Immich (restic), all DBs, and secrets are triggered on demand from the storage-console dashboard. See **[Backups & DR](BACKUP.md)**. |

> **Backups (updated 2026-06-06):** Backups are now **manual** (this Mac is a laptop, not always on at a fixed hour). Immich is backed up with **restic**, all databases via the `db-backup` job, and secrets two ways (offline `age` dump + committed SealedSecrets) — all to **`homelab-backup-hdd`** (3 TB Journaled HFS+). The old weekly `backup-immich.sh` launchd job is **retired/disabled**. Full details, trigger steps, and restore runbooks are in **[Backups & DR](BACKUP.md)**. The separate **`homelab-hdd`** disk holds movies / large files and is *not* a backup target. HFS+ (not exFAT) is required for backup/cluster-mounted disks: journaled (crash-safe) + preserves Unix permissions.

**Order on cold boot** (if you forget what to check):
1. Mac boots.
2. Plug in `Seeni's HDD` if not already.
3. OrbStack starts (small icon in menu bar).
4. Wait ~30s for k3s to come up.
5. Run health checks (section 0).
6. If anything's red, scroll to section "Stuck things" below.

### After Mac wake from sleep / hibernate

**TL;DR: don't panic for the first ~60 seconds.** OrbStack and all pods auto-recover with no intervention. The cluster comes back on its own; you'll see transient errors during the reconnection window.

What happens when Mac wakes:

1. OrbStack VM resumes from snapshot (or auto-starts if it was paused).
2. k3s API server becomes reachable within ~10-20s.
3. Pods that hold long-lived connections (Postgres clients, Valkey/Redis clients, CoreDNS) reconnect — you'll see their `RESTARTS` count tick up by 1.
4. Tailscale operator re-establishes DERP relay connections — proxy pods (`ts-*`) automatically rejoin the tailnet.
5. Everything is usually green within **30-90 seconds** of wake.

**Typical transient errors during the wake window** (all of these self-heal — ignore unless they persist > 2 minutes):

```
kubectl: "TLS handshake timeout"               ← API server not yet reachable
immich-server: "EAI_AGAIN immich-valkey"       ← DNS resolution catching up
immich-server: "connect ETIMEDOUT"             ← reconnecting to Valkey/Postgres
http2: client connection lost                  ← long-lived watches restarting
```

**Steps to verify cluster came back after wake:**

```bash
# 1. Is OrbStack running?
orbctl status                          # expect: "Running"

# 2. Is k3s API up?
kubectl get nodes                      # expect: orbstack  Ready  ... 

# 3. All pods 1/1 Ready?
kubectl get pods -A | grep -v "1/1\s*Running" | grep -v NAME
# expect: empty (no output) — everything 1/1 Running
```

If pods stay not-Ready for > 2 minutes after wake, see the next sub-section.

### If something stays broken after wake

**Most common: a pod is stuck reconnecting → rollout restart it.**

```bash
# Find pods with high restart counts or not 1/1 Ready
kubectl get pods -n homelab

# Restart whatever's misbehaving (no data loss — deployments restart cleanly)
kubectl rollout restart deployment/<name> -n homelab
# e.g. kubectl rollout restart deployment/immich-server -n homelab
```

**If OrbStack itself didn't resume:**

```bash
# Check the OrbStack helper process
ps aux | grep "OrbStack Helper" | grep -v grep | head -1

# Or use the menu bar icon → "Start" if it shows as paused

# Or via CLI:
orbctl start

# Then wait ~30s and re-run health check.
```

**If the Tailscale URLs (`*.stoat-perch.ts.net`) don't resolve after wake:**

This is usually because the Tailscale operator's DERP relay is reconnecting. Wait 60 seconds. If still broken:

```bash
# Restart the Tailscale operator (the proxy pods will be re-minted)
kubectl rollout restart deployment/operator -n tailscale

# Optional: also restart the proxy pods so they re-register with tailnet
kubectl rollout restart statefulset -n tailscale --all
```

**If Immich/Jellyfin pods are crashlooping after wake:**

Almost always a stale Postgres/Valkey connection. Rollout restart fixes:

```bash
kubectl rollout restart deployment/immich-server -n homelab
kubectl rollout restart deployment/immich-machine-learning -n homelab
kubectl rollout restart deployment/jellyfin -n homelab
```

**If absolutely nothing comes back after several minutes:**

Hard restart OrbStack:

```bash
orbctl stop
orbctl start
# Wait 60s, then re-run health check.
```

This is the equivalent of "rebooting the VM" — pod data on the SSD `local-path` PVCs is preserved.

### Prevent sleep & keep services always reachable

For the homelab to stay online 24/7, the Mac must not sleep. Configured via [MAC-ALWAYS-ON.md](MAC-ALWAYS-ON.md).

Current setting: never sleep on AC OR battery (`pmset -a sleep 0`). Three quick-change recipes:

```bash
# Change BATTERY behaviour only — let laptop sleep on battery, stay up on AC
sudo pmset -c sleep 0 disksleep 0       # AC: never sleep
sudo pmset -b sleep 10 disksleep 10     # Battery: sleep after 10 min idle

# Both AC and battery never sleep (current setting)
sudo pmset -a sleep 0 disksleep 0

# Restore macOS defaults (laptop becomes a normal laptop again)
sudo pmset -a sleep 1 disksleep 10 womp 0
orbctl config set power.pause_in_sleep true
orbctl stop && orbctl start

# Inspect what's set right now
pmset -g custom
```

Full guide with reasoning, clamshell tips, and OrbStack `power.pause_in_sleep` settings: [MAC-ALWAYS-ON.md](MAC-ALWAYS-ON.md).

### Operating rule — never stop the cluster

The homelab is shared with family. Stopping it = visible outage. **Don't quit OrbStack, don't run `orb stop`, don't `kubectl scale --replicas=0`, don't `kubectl delete deployment/...`, don't drain the node** unless you've decided you're OK with an outage right now.

- `kubectl rollout restart deployment/<x>` is the right tool for "make this pod re-read its config" — zero-downtime on multi-replica Deployments, ~10–30 s blip on single-replica.
- If you must take something down, scope it tight (one Deployment, not the cluster) and time-box it.
- After any planned restart, run section 0 health checks before walking away.

### If the VM was found Stopped (Mac was NOT rebooted)

Different from a Mac wake/reboot — this is "macOS is still up, OrbStack VM is Stopped". Happened on 2026-06-01 at 12:34 (root cause: most likely OrbStack app was quit or auto-paused; macOS uptime was 4 d at the time so it wasn't a sleep event).

Symptoms:
- `kubectl get nodes` → `connection refused` on `127.0.0.1:26443`
- Every Tailnet URL (`*.stoat-perch.ts.net`) → not reachable
- `orb status` → `Stopped`

Diagnose before restarting (so you can fix the underlying cause):

```bash
# When did the VM stop, and was it clean?
grep -E "shutting down|stopped|graceful|force|kill" ~/.orbstack/log/vmgr.log ~/.orbstack/log/vmgr.1.log 2>/dev/null | tail -20

# Look for a clean shutdown trail:
#   "scon ... shutting down"
#   "Service ... exited: status 0"
#   "Unmounting /data" / "Unmounting /mnt/mac"
#   "reboot: Power down"
#   "[VM] stopped"
# If you see "graceful stop timed out, forcing" — something requested stop but the VM didn't drain in time.

# Was the Mac asleep? (uptime should be days, not minutes)
uptime
last reboot | head -3

# Is OrbStack still in login items?
osascript -e 'tell application "System Events" to get the name of every login item' | tr ',' '\n' | grep -i orb
```

Likely causes (in order):
1. **Someone quit OrbStack** from the menu bar or Cmd-Q'd the app. The VM is configured to stay up during sleep but quitting the app stops the VM.
2. **`orb stop` was run** by a script or shell session.
3. **OrbStack auto-updated** and restarted itself but didn't relaunch the VM.
4. **macOS killed the helper** under memory pressure (rare; check `~/.orbstack/log/vmgr.log` and Console.app for `OrbStack Helper` crash reports around the stop timestamp).

Restart:

```bash
orb start
kubectl get nodes                  # should be Ready within ~30s
kubectl get pods -A | grep -v Running | grep -v Completed   # check no pod is stuck
```

All Deployments self-recover (the cluster boots, pods schedule, Tailscale sidecars rejoin the tailnet). Sidecar restart counts will tick up by 1.

If `orb start` says "already running" but `orb status` says `Stopped`, you're in the split state where the GUI is up but the VM is down — start the VM explicitly from the OrbStack menu bar → Kubernetes → Start, or `orbctl start`.

---

## 2. Where everything lives

### Files (live, that the system uses)
| Path | Purpose |
|---|---|
| `~/homelab/storage.yaml` | PVs/PVCs (HDD-backed) |
| `~/homelab/jellyfin-values.yaml` | Jellyfin Helm values |
| `~/homelab/immich-postgres.yaml` | Postgres StatefulSet + Secret + Service |
| `~/homelab/immich-values.yaml` | Immich Helm values |
| `~/homelab/immich-photos-readonly.yaml` | Immich library RO PVC (was for Jellyfin /photos; mount disabled) |
| `~/homelab/ingress.yaml` | Tailscale Ingress for HTTPS access (Jellyfin + Immich) |
| `~/homelab/docs-server.yaml` | Docs site nginx + Docsify + Tailscale Ingress |
| `~/homelab/localhost-portforward.sh` | Port-forward script (auto-run by launchd) |
| `~/homelab/refresh-localhost.sh` | Manual port-forward reload |
| `~/homelab/backup-immich.sh` | **Retired** legacy host tar backup (superseded by restic + db-backup; launchd disabled). See [Backups & DR](BACKUP.md). |
| `~/Library/LaunchAgents/com.nila.homelab-localhost.plist` | launchd: port-forward at login |
| `~/Library/LaunchAgents/com.nila.homelab-backup.plist.disabled` | launchd: weekly backup — **disabled/retired** |
| `/Volumes/homelab-backup-hdd/` | **Primary backup target** (3 TB Journaled HFS+) — restic Immich repo, DB dumps, and `age` secret dumps. See [Backups & DR](BACKUP.md). |
| `/Volumes/homelab-hdd/` | Media / large-files disk (movies, drone footage) — plugged in occasionally; **not** a backup target |

### Documentation
- `/Users/nila/Developer/agents/docs/homelab-k8s-setup/` — all docs
  - `README.md` — index
  - `architecture.md` + `architecture.excalidraw` — visual + narrative
  - `command-log.md` — chronological log of every command run during setup
  - `learnings.md` — tribal knowledge / gotchas
  - `MAINTENANCE.md` (this file)
  - `IMMICH-BULK-UPLOAD.md` — uploading photos
  - `IMMICH-UPGRADE.md` — upgrading Immich versions
  - `configs/` — snapshot copies of all the above live files

---

## 3. Restart things (smallest to biggest blast radius)

### Restart one pod
```bash
# Just kill the pod — Deployment recreates it
kubectl rollout restart deployment/immich-server -n homelab

# Watch it come back
kubectl get pods -n homelab -w   # Ctrl-C when done
```

Same pattern for any deployment: `jellyfin`, `immich-server`, `immich-machine-learning`, `immich-valkey`.

For the Postgres StatefulSet:
```bash
kubectl rollout restart statefulset/immich-postgres -n homelab
```

### Refresh just the localhost port-forward
```bash
~/homelab/refresh-localhost.sh
```
Use when `http://localhost:8096` or `:2283` returns HTTP 000.

### Restart the whole cluster (k3s inside OrbStack)
```bash
orbctl stop
orbctl start
# Wait ~30s
kubectl get nodes
```
Use when "Too many open files in system" errors appear on the HDD (the exFAT passthrough state in the VM is wedged).

### Reboot the Mac
Last resort. Same effect as the OrbStack restart but heavier.

---

## 4. Scale things

### Scale Immich machine-learning (for faster photo processing)
```bash
# Bump to 3 replicas during/after bulk uploads
kubectl scale deployment immich-machine-learning -n homelab --replicas=3

# Scale back to 1 to save memory
kubectl scale deployment immich-machine-learning -n homelab --replicas=1

# Check current replicas
kubectl get deploy immich-machine-learning -n homelab
```

Don't scale to >3 — OrbStack VM has 40 GB and 3 × 6 GB = 18 GB headroom is enough.

### Increase OrbStack VM resources
```bash
# Check current
orbctl config show | grep -E "^cpu|memory_mib"

# Bump memory (e.g., 48 GB if you're rarely using the Mac for other things)
orbctl config set memory_mib 49152
orbctl stop
orbctl start
```

Mac has 64 GB total. Leave at least 16 GB for macOS itself.

---

## 5. Where to find logs

### Pod logs (most important)
```bash
# Last 50 lines of a pod's logs
kubectl logs -n homelab deployment/immich-server --tail=50

# Live tail
kubectl logs -n homelab deployment/immich-server -f

# Previous instance's logs (if pod crashed and restarted)
kubectl logs -n homelab deployment/immich-server --previous

# Logs from all containers of a deployment with label
kubectl logs -n homelab -l app.kubernetes.io/name=server --tail=100
```

### Pod events (why is it failing to start?)
```bash
kubectl describe pod -n homelab -l app.kubernetes.io/name=server | tail -30
```

### launchd logs (the auto-running scripts)
```bash
tail ~/homelab/localhost-portforward.out.log
tail ~/homelab/localhost-portforward.err.log
tail ~/homelab/backup.log
```

### Upload logs
```bash
ls ~/homelab/upload-logs/
# Latest:
tail -f $(ls -t ~/homelab/upload-logs/sequential-*.log | head -1)
```

---

## 6. Stuck things — diagnosis flowchart

### "localhost:8096 or localhost:2283 won't load"
1. `~/homelab/refresh-localhost.sh` — most common fix
2. If still 000: `kubectl get pods -n homelab` — pod up?
   - If pod has `RESTARTS` climbing → `kubectl logs -n homelab deployment/<name> --tail=50` to see error
3. Try cluster DNS instead — `http://jellyfin.homelab.svc.cluster.local:8096` (works even when port-forward dies)

### "Pod stuck in CrashLoopBackOff"
```bash
# What does it say in events?
kubectl describe pod -n homelab <pod-name> | tail -30

# Previous logs?
kubectl logs -n homelab <pod-name> --previous
```
Common causes:
- Probe too strict → check `kubectl get deploy <name> -o yaml | grep -A5 Probe`. Fix: increase timeouts (see `learnings.md`).
- PVC binding failure → `kubectl get pvc -n homelab`. Check the HDD is mounted.
- Image pull error → check network / GHCR availability.

### "Too many open files in system" anywhere
The OrbStack exFAT passthrough state is wedged.
1. `orbctl stop && orbctl start` — refreshes the VM. ~1 min downtime.
2. After OrbStack comes back, refresh the port-forward: `~/homelab/refresh-localhost.sh`

### "Upload very slow / stuck on 'Crawling'"
1. Concurrency too high for exFAT → use `--concurrency 1` or `2`
2. Check HDD activity: `iostat -d -w 2 disk4 5` (replace disk4 with your HDD's device — `df -h | grep Volumes` to find it)
3. If HDD is idle (0 MB/s), CLI is hung → `pkill -9 -f "immich upload"` and restart

### "Jellyfin scan finds no movies"
1. Delete macOS metadata files:
   ```bash
   find "/Volumes/Seeni's HDD/jellyfin/media" -name "._*" -type f -delete
   find "/Volumes/Seeni's HDD/jellyfin/media" -name ".DS_Store" -type f -delete
   ```
2. Force a scan: Jellyfin UI → Dashboard → Scheduled Tasks → "Scan Media Library" → ▶
3. Check folder naming: use clean names like `Movie Name (2024)/` not `Movie.Name.2024.UHD.BluRay[xyz]/`

### "Cluster k8s node NotReady"
Heavy load (usually big upload + ML processing) maxes out the VM.
1. `kubectl scale deployment immich-machine-learning -n homelab --replicas=1` to drop ML load
2. Kill any in-flight CLI: `pkill -f "immich upload"`
3. Wait 1-2 min, check `kubectl get nodes`
4. If still NotReady: `orbctl stop && orbctl start`

### "I can access via Tailscale URL but not localhost"
Port-forward is broken but cluster is fine. Run `~/homelab/refresh-localhost.sh`.

### "I can access via localhost but not Tailscale URL"
Tailscale Ingress proxy pods have lost their auth. Check:
```bash
kubectl get pods -n tailscale
kubectl logs -n tailscale -l app=operator --tail=30
```
Often fixed by: `kubectl rollout restart deployment/operator -n tailscale`

---

## 7. Routine tasks

### Bulk upload photos to Immich
See **`IMMICH-BULK-UPLOAD.md`**. Quick form:
```bash
# CLI uses cluster DNS — no port-forward needed for uploads
immich upload --recursive --concurrency 4 "/path/to/photos"
```

### Run a backup manually
All backups are manual now — trigger from the storage-console dashboard (<https://tier.stoat-perch.ts.net>) or via:
```bash
kubectl -n homelab create job --from=cronjob/immich-backup immich-backup-manual-$(date +%s)
kubectl -n homelab create job --from=cronjob/db-backup     db-backup-manual-$(date +%s)
```
Full trigger/restore steps and what each backup covers: **[Backups & DR](BACKUP.md)**. (The old `~/homelab/backup-immich.sh` is retired.)

### Upgrade Immich to a newer version
See **`IMMICH-UPGRADE.md`**. Quick form:
```bash
# Backup first!
BACKUP_FILE="/Volumes/Seeni's HDD/immich/pre-upgrade-$(date +%Y%m%d).sql.gz"
PG_POD=$(kubectl get pod -n homelab -l app=immich-postgres -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n homelab "$PG_POD" -- pg_dump -U immich -d immich --no-owner --clean --if-exists | gzip > "$BACKUP_FILE"

# Pin a new image tag (replace v2.7.5 with target)
TARGET=v2.7.5
kubectl set image deployment/immich-server -n homelab main=ghcr.io/immich-app/immich-server:$TARGET
kubectl set image deployment/immich-machine-learning -n homelab main=ghcr.io/immich-app/immich-machine-learning:$TARGET

# Watch
kubectl rollout status deployment/immich-server -n homelab
~/homelab/refresh-localhost.sh
```

### Rotate Tailscale OAuth credentials
1. Browser → `https://login.tailscale.com/admin/settings/oauth` → revoke old, generate new
2. In Terminal (zsh):
   ```zsh
   read -s "TS_ID?Client ID: "; echo
   read -s "TS_SECRET?Client Secret: "; echo
   helm upgrade tailscale-operator tailscale/tailscale-operator \
     --namespace tailscale --reuse-values \
     --set-string oauth.clientId="$TS_ID" \
     --set-string oauth.clientSecret="$TS_SECRET"
   unset TS_ID TS_SECRET
   kubectl rollout restart deployment/operator -n tailscale
   ```

### Add a new movie to Jellyfin
1. Drop the file into `/Volumes/Seeni's HDD/jellyfin/media/movies/<Movie Name (Year)>/<file.mkv>`
2. Delete macOS metadata: `find "/Volumes/Seeni's HDD/jellyfin/media" -name "._*" -delete; find "/Volumes/Seeni's HDD/jellyfin/media" -name ".DS_Store" -delete`
3. Jellyfin auto-scans within ~10 min, OR force: UI → Dashboard → Scheduled Tasks → "Scan Media Library" → ▶

---

## 8. Reach the services

| URL | When |
|---|---|
| **`http://localhost:8096`** | Jellyfin web UI from this Mac (via launchd port-forward) |
| **`http://localhost:2283`** | Immich web UI from this Mac |
| **`http://localhost:8090`** | Docs site from this Mac |
| **`http://192.168.68.57:8096`** | Jellyfin from any LAN device (TV, other laptops) |
| **`http://192.168.68.57:2283`** | Immich from any LAN device |
| **`http://192.168.68.57:8090`** | Docs from any LAN device |
| **`https://jellyfin.stoat-perch.ts.net`** | Jellyfin from any Tailscale device (phone, remote) |
| **`https://immich.stoat-perch.ts.net`** | Immich from any Tailscale device |
| **`https://docs.stoat-perch.ts.net`** | Docs from any Tailscale device (phone reading) |
| **`https://grocy.stoat-perch.ts.net`** | Grocy (household inventory) from any Tailscale device |
| **`http://jellyfin.homelab.svc.cluster.local:8096`** | Jellyfin from this Mac (cluster DNS — most reliable, browser-friendly) |
| **`http://immich-server.homelab.svc.cluster.local:2283`** | Immich from this Mac (cluster DNS — used by CLI uploads) |
| **`http://docs.homelab.svc.cluster.local`** | Docs from this Mac (cluster DNS) |
| **`http://grocy.homelab.svc.cluster.local`** | Grocy from this Mac (cluster DNS) |

If LAN IP `192.168.68.57` ever changes, run `ipconfig getifaddr en0` to find new value.

### Docs server

The docs site (`docs.stoat-perch.ts.net`) is an nginx pod that serves the `.md` files from `/Users/nila/Developer/agents/docs/homelab-k8s-setup/` rendered as HTML via Docsify (client-side JavaScript from CDN).

- **Content source**: `/Users/nila/Developer/agents/docs/homelab-k8s-setup/` (read-only hostPath PV — edits to any `.md` file show up live on the site, no rebuild)
- **Config**: `~/homelab/docs-server.yaml` (Deployment + Service + Ingress + ConfigMap)
- **Pod check**: `kubectl get pods -n homelab -l app=docs`
- **Restart**: `kubectl rollout restart deployment/docs -n homelab`
- **Logs**: `kubectl logs -n homelab deployment/docs`
- **Re-apply config** (if you change `docs-server.yaml`): `kubectl apply -f ~/homelab/docs-server.yaml`

Sidebar entries are configured in two places — both should be updated if you add/rename a doc:
1. `_sidebar.md` (in the docs folder itself — what the docs site shows)
2. `docs-sidebar-redirect` ConfigMap inside `docs-server.yaml`

Or just edit one and copy to the other.

---

## 9. Managing content on the docs site

The docs site (`https://docs.stoat-perch.ts.net`) serves **whatever's in `/Users/nila/Developer/agents/docs/homelab-k8s-setup/`** — live, no build, no restart. Drop a file in, it's accessible. Delete it, it's gone. Edit it, refresh the page, you see the change.

### File types & how they display

| File type | URL pattern | What browser does |
|---|---|---|
| `.md` (markdown) | `…/#/notes` (Docsify hash routing) | Renders as pretty page with sidebar |
| `.txt`, `.json`, `.yaml` | `…/docs/file.txt` | Plain text |
| `.html` | `…/docs/page.html` | Renders as HTML |
| `.pdf` | `…/docs/file.pdf` | Opens inline |
| `.xlsx`, `.csv` | `…/docs/sheet.xlsx` | Downloads (browsers don't render Excel) |
| `.png`, `.jpg` | `…/docs/img.png` | Displays inline |

### Add a new file

```bash
# Plain markdown
cat > /Users/nila/Developer/agents/docs/homelab-k8s-setup/network-notes.md <<'EOF'
# Network Notes
Router: 192.168.68.1 / admin / xxx
EOF

# Or a text file
echo "Quick reminders…" > /Users/nila/Developer/agents/docs/homelab-k8s-setup/reminders.txt

# Or copy in an existing file
cp ~/Documents/budget.xlsx /Users/nila/Developer/agents/docs/homelab-k8s-setup/
```

Already accessible at `https://docs.stoat-perch.ts.net/docs/network-notes.md` etc. No restart, no rebuild.

### Make a new markdown file appear in the sidebar

Edit `/Users/nila/Developer/agents/docs/homelab-k8s-setup/_sidebar.md` and add a line under the right section:

```markdown
* **🛠 Operate**
  * [Maintenance](MAINTENANCE.md)
  * [Network Notes](network-notes.md)   ← new line
```

Refresh the page — sidebar update is live.

### Subfolders

Just create them:
```bash
mkdir /Users/nila/Developer/agents/docs/homelab-k8s-setup/network
mv /Users/nila/Developer/agents/docs/homelab-k8s-setup/network-notes.md \
   /Users/nila/Developer/agents/docs/homelab-k8s-setup/network/notes.md
```

Sidebar link uses relative paths:
```markdown
* **Network**
  * [Router notes](network/notes.md)
```

### Update / edit an existing file

Use any editor — VS Code, vim, TextEdit, Obsidian:
```bash
# Quick edit
open -a "TextEdit" /Users/nila/Developer/agents/docs/homelab-k8s-setup/MAINTENANCE.md
# or
code /Users/nila/Developer/agents/docs/homelab-k8s-setup/
```

Save → refresh the docs page on phone/browser → see the change immediately.

### Delete a file

```bash
rm /Users/nila/Developer/agents/docs/homelab-k8s-setup/old-notes.md
```

Also remove its entry from `_sidebar.md` (otherwise a broken link sits there).

### View files without going through the docs server

The docs folder is just a regular directory on the Mac:
- Open in Finder: `open /Users/nila/Developer/agents/docs/homelab-k8s-setup/`
- Or in terminal: `ls /Users/nila/Developer/agents/docs/homelab-k8s-setup/`

### Embed Excel/Spreadsheet content nicely

Three patterns:

**Pattern A — convert small data to markdown table** (recommended for things you want to read on phone):
```markdown
| Column 1 | Column 2 |
|---|---|
| value1 | value2 |
```

**Pattern B — link to the `.xlsx`** for download:
```markdown
See [budget.xlsx](budget.xlsx) — open in Numbers/Excel.
```

**Pattern C — link to Google Sheets / iCloud Numbers** (best for shared/editable docs):
```markdown
[Budget spreadsheet](https://docs.google.com/spreadsheets/d/abc123…)
```

### How URL routing works (so you can predict the URLs)

- `https://docs.stoat-perch.ts.net/` → Docsify loads `/docs/README.md` (home)
- `https://docs.stoat-perch.ts.net/#/MAINTENANCE` → Docsify loads `/docs/MAINTENANCE.md`
- `https://docs.stoat-perch.ts.net/#/network/notes` → Docsify loads `/docs/network/notes.md`
- `https://docs.stoat-perch.ts.net/docs/anything.txt` → direct file fetch (any non-markdown)

The `#/` is Docsify's hash routing for markdown. For other file types, use the direct `/docs/…` path.

### Caching gotcha

Docsify uses a **service worker** that caches markdown aggressively. If you edited a file and don't see the change:

- **Hard refresh**: Cmd+Shift+R (desktop) or hold reload icon on Safari iPhone → "Request without service worker"
- **Or** clear site data: DevTools → Application → Storage → Clear site data
- **Or** open in private/incognito window

### Permissions

The docs site is read-only (mounted with `readOnly: true` in the pod). Even though nginx is serving it, nobody can write back via HTTP. Edits happen on the Mac filesystem only.

---

## 10. The "everything broke, start over" nuclear option

NEVER do this without thinking — but for reference, this is how to wipe everything:
```bash
# Uninstall apps
helm uninstall jellyfin -n homelab
helm uninstall immich -n homelab
helm uninstall tailscale-operator -n tailscale

# Delete persistent data (DESTROYS DATA — db state, jellyfin config)
kubectl delete pvc --all -n homelab

# Delete namespaces
kubectl delete namespace homelab tailscale

# Reset OrbStack VM (DESTROYS ALL CLUSTER STATE)
# orbctl reset
```

The HDD files stay (movies + photos), but Postgres DB metadata is lost. After reset, reinstall via the `homelab-k8s-setup` skill.

---

## 11. Cheat sheet — most-used commands

```bash
# Health
kubectl get pods -n homelab
kubectl get nodes

# Refresh port-forward when localhost dies
~/homelab/refresh-localhost.sh

# Restart pod
kubectl rollout restart deployment/<name> -n homelab

# Restart cluster (when exFAT wedges)
orbctl stop && orbctl start

# Scale ML up / down
kubectl scale deployment immich-machine-learning -n homelab --replicas=3
kubectl scale deployment immich-machine-learning -n homelab --replicas=1

# Logs
kubectl logs -n homelab deployment/jellyfin --tail=50
kubectl logs -n homelab deployment/immich-server --tail=50 -f

# Pod events (why won't it start)
kubectl describe pod -n homelab -l app.kubernetes.io/name=server | tail -30

# Mac LAN IP
ipconfig getifaddr en0

# HDD usage
df -h "/Volumes/Seeni's HDD"
du -sh "/Volumes/Seeni's HDD/immich/upload/library/"

# Clean macOS metadata (run after Finder touches the HDD)
find "/Volumes/Seeni's HDD" -name "._*" -type f -delete
find "/Volumes/Seeni's HDD" -name ".DS_Store" -type f -delete
```

---

## 12. Bootstrap dependencies — what must be true on a fresh Mac

### Tailscale MagicDNS resolver (`/etc/resolver/stoat-perch.ts.net`)

The homelab cluster uses Tailscale Ingress for external HTTPS access (`*.stoat-perch.ts.net`). Cluster-internal DNS (`*.homelab.svc.cluster.local`) also flows through OrbStack's resolver. When you clone this repo onto a new Mac, the Tailscale app must be installed and connected to the tailnet **before** running `deploy.sh`.

**What happens automatically:** The Tailscale app writes `/etc/resolver/stoat-perch.ts.net` (via MagicDNS) when you sign in. This file tells macOS to route `*.stoat-perch.ts.net` queries to the Tailscale DNS resolver.

**You do not create this file manually.** Install Tailscale → sign in → MagicDNS auto-creates the resolver.

```bash
# Verify the resolver is in place
cat /etc/resolver/stoat-perch.ts.net
# Expected output (nameserver pointing to 100.100.100.100 — the Tailscale MagicDNS IP):
#   nameserver 100.100.100.100

# If the file is missing: open Tailscale app, sign in, enable MagicDNS in the admin console.
# https://login.tailscale.com/admin/dns  →  Enable MagicDNS toggle
```

If `*.stoat-perch.ts.net` URLs don't resolve on a new Mac after Tailscale is installed:
1. Check `tailscale status` — must be `Connected`
2. Check `ls /etc/resolver/` — the `stoat-perch.ts.net` file must exist
3. Check Tailscale admin console → DNS → MagicDNS is enabled

### launchd jobs and the `~/homelab/` scripts

Two launchd agents manage always-on background tasks:

| plist | What it runs | How often |
|---|---|---|
| `~/Library/LaunchAgents/com.USER_NAME.homelab-localhost.plist` | `~/homelab/localhost-portforward.sh` | At login; restarts if killed |
| `~/Library/LaunchAgents/com.USER_NAME.homelab-backup.plist` | `~/homelab/backup-immich.sh` | Sundays at 03:00 |

**Critical:** The plist files reference `~/homelab/<script>.sh` directly (not the repo path). This means:

- The `~/homelab/` copies are what actually runs on the cluster.
- The repo copies in `cluster-setup/scripts/` are the source-of-truth for version control.
- **After merging any script changes, copy the updated file to `~/homelab/` and reload the launchd agent:**

```bash
# Example: update localhost-portforward.sh
cp /path/to/cluster-setup/scripts/localhost-portforward.sh ~/homelab/localhost-portforward.sh
~/homelab/refresh-localhost.sh    # reload the launchd agent

# Or for backup script (no reload needed — launchd runs it on schedule):
cp /path/to/cluster-setup/scripts/backup-immich.sh ~/homelab/backup-immich.sh
```

On a fresh Mac (new clone), after running `deploy.sh`, copy all scripts from `cluster-setup/scripts/` to `~/homelab/`:
```bash
cp cluster-setup/scripts/*.sh ~/homelab/
# Install plist files from cluster-setup/launchd/
cp cluster-setup/launchd/com.USER_NAME.homelab-localhost.plist ~/Library/LaunchAgents/
cp cluster-setup/launchd/com.USER_NAME.homelab-backup.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.USER_NAME.homelab-localhost.plist
launchctl load ~/Library/LaunchAgents/com.USER_NAME.homelab-backup.plist
```

### Host `~/homelab/storage.yaml` and `~/homelab/ingress.yaml` — DEPRECATED

The monolithic `~/homelab/storage.yaml` and `~/homelab/ingress.yaml` files are **superseded** by the parameterized versions in this repo:

- `cluster-setup/30-storage.yaml` — replaces `~/homelab/storage.yaml` (uses `${HOMELAB_HDD_PATH}` / `${HOMELAB_NAMESPACE}`)
- `cluster-setup/40-ingress.yaml` — replaces `~/homelab/ingress.yaml` (uses `${HOMELAB_NAMESPACE}`)

The host copies predate the portable-repo migration and use hardcoded paths (`/Volumes/Seeni's HDD`, namespace `homelab`). Do **not** apply the host monoliths on a new cluster — use `deploy.sh` from this repo, which applies the parameterized versions via `envsubst`.
```
