# Tiered Storage — Deploy Runbook

**Assumes:** HDD is already formatted as HFS+ Journaled Case-Sensitive, labelled
`homelab-hdd`, and mounted at `/Volumes/homelab-hdd` with the required
subdirectories. (HDD preparation is in `hdd-prep.md`.)

---

## Step 1 — Verify HDD is mounted and subdirectories exist

```bash
mount | grep homelab-hdd
ls /Volumes/homelab-hdd/
# Must show: immich-library  jellyfin-media  backups
```

If the directories are missing, create them before continuing:

```bash
mkdir -p /Volumes/homelab-hdd/immich-library
mkdir -p /Volumes/homelab-hdd/jellyfin-media
mkdir -p /Volumes/homelab-hdd/backups/postgres
mkdir -p /Volumes/homelab-hdd/backups/library
```

---

## Step 2 — Apply Helm patches

Edit `~/homelab/immich-values.yaml` and `~/homelab/jellyfin-values.yaml` as
described in `helm-value-patches.md`.

Then upgrade both releases:

```bash
helm upgrade immich immich/immich \
  --version 0.11.1 \
  --namespace homelab \
  -f ~/homelab/immich-values.yaml \
  --wait --timeout 5m

helm upgrade jellyfin jellyfin/jellyfin \
  --version 3.2.0 \
  --namespace homelab \
  -f ~/homelab/jellyfin-values.yaml \
  --wait --timeout 3m
```

---

## Step 3 — Verify HDD mount inside app pods

Check that the HDD volume mounted correctly in each pod:

```bash
# Immich server: /data-hdd should exist and be the HDD
kubectl exec -n homelab deployment/immich-server -- ls /data-hdd
# Expected: empty dir (or files if HDD already had data)

# Jellyfin: /media-hdd should exist and be the HDD
kubectl exec -n homelab deployment/jellyfin -- ls /media-hdd
# Expected: empty dir (or files)
```

If either `ls` returns "No such file or directory", the Helm patch was not
applied correctly. Re-check `helm-value-patches.md` and re-upgrade.

If `ls` hangs, the HDD is mounted at the host but the virtiofs layer is busy
(typical right after OrbStack start). Wait 30 s and retry. If it keeps
hanging: `orb stop && orb start`, re-verify HDD mount, then retry the pod check.

---

## Step 4 — Apply the CronJob manifests

```bash
kubectl apply -f ~/homelab/tiered-storage-mover.yaml
kubectl apply -f ~/homelab/immich-backup-cronjob.yaml
```

All three CronJobs are defined with `suspend: true`, so they will NOT auto-fire
on a schedule. They exist as templates for manual triggering (via the wrapper
script below or the webapp) and for future automation.

Verify the CronJobs were created and are suspended:

```bash
kubectl get cronjob -n homelab
# NAME                  SCHEDULE    TIMEZONE        SUSPEND   ACTIVE   LAST SCHEDULE
# tier-mover-immich     0 3 * * *   Europe/London   True      0        <none>
# tier-mover-jellyfin   0 3 * * *   Europe/London   True      0        <none>
# immich-backup         0 4 * * *   Europe/London   True      0        <none>
```

`SUSPEND=True` is correct and expected for all three.

---

## Step 5 — Trigger jobs (every time you connect the HDD)

### Via wrapper script (recommended)

```bash
~/homelab/tier-now.sh immich     # move Immich files >2 GiB to HDD
~/homelab/tier-now.sh jellyfin   # move Jellyfin files >3 GiB to HDD
~/homelab/tier-now.sh backup     # pg_dump + library tar snapshot
```

The script:
1. Verifies the HDD is mounted at `/Volumes/homelab-hdd` with the required subdirs
2. Creates a fresh Job from the suspended CronJob
3. Tails the pod logs until the job finishes
4. Reports success or surfaces the FAIL/ERROR lines

### Via webapp

The webapp triggers jobs via:
```
kubectl create job --from=cronjob/<name> <job-name> -n homelab
```
where `<name>` is one of: `tier-mover-immich`, `tier-mover-jellyfin`, `immich-backup`.

### Raw kubectl (no wrapper)

```bash
# Immich mover
JOB="tier-immich-$(date +%Y%m%d-%H%M%S)"
kubectl create job --from=cronjob/tier-mover-immich "$JOB" -n homelab
kubectl logs -n homelab -l "job-name=$JOB" -f

# Jellyfin mover
JOB="tier-jellyfin-$(date +%Y%m%d-%H%M%S)"
kubectl create job --from=cronjob/tier-mover-jellyfin "$JOB" -n homelab
kubectl logs -n homelab -l "job-name=$JOB" -f

# Backup
JOB="immich-backup-$(date +%Y%m%d-%H%M%S)"
kubectl create job --from=cronjob/immich-backup "$JOB" -n homelab
kubectl logs -n homelab -l "job-name=$JOB" -f
```

### Expected mover log lines

```
MOVED /ssd-immich/library/admin/2024/12/abc123.jpg size=3456789 -> /data-hdd/library/admin/2024/12/abc123.jpg
```

Or if no files yet exceed the threshold:

```
SKIP dir-missing /ssd-immich/library      # if library/ subdir doesn't exist yet
SUMMARY immich moved=0 bytes=0 failed=0 skipped=1
```

A non-zero `failed=` count means something went wrong — check the FAIL lines
above the SUMMARY for the reason (sha256 mismatch, cp error, etc.).

### Expected backup log lines

```
=== Step 1: pg_dump → /hdd/backups/postgres/immich-20260530-040001.sql.gz ===
pg_dump complete: 12345678 bytes
=== Step 2: tar library → /hdd/backups/library/immich-library-20260530-040001.tar.gz ===
tar complete: 987654321 bytes
PRUNE postgres/immich-20260401-040001.sql.gz
SUMMARY backup pg_bytes=12345678 library_bytes=987654321 pruned=1
```

---

## Step 6 — Verify symlinks (after mover runs)

After the mover jobs complete, confirm symlinks were created on the SSD and
point to the correct app-pod paths:

```bash
# Immich: check a moved file
kubectl exec -n homelab deployment/immich-server -- \
  find /data/library -maxdepth 4 -type l | head -5
# Each line should be a symlink like:
#   /data/library/admin/2024/12/abc123.jpg

# Check what it points to (should be /data-hdd/...)
kubectl exec -n homelab deployment/immich-server -- \
  sh -c 'find /data/library -maxdepth 4 -type l | head -3 | xargs -I{} readlink {}'
# Expected: /data-hdd/library/admin/2024/12/abc123.jpg

# Confirm the target actually exists (non-zero exit = file missing = broken symlink)
kubectl exec -n homelab deployment/immich-server -- \
  sh -c 'find /data/library -maxdepth 4 -type l | head -3 | while read f; do
    target=$(readlink "$f"); [ -f "$target" ] && echo "OK $f" || echo "BROKEN $f -> $target"
  done'
```

Repeat for Jellyfin:

```bash
kubectl exec -n homelab deployment/jellyfin -- \
  find /media/movies -maxdepth 3 -type l | head -5

kubectl exec -n homelab deployment/jellyfin -- \
  sh -c 'find /media/movies -maxdepth 3 -type l | head -3 | while read f; do
    target=$(readlink "$f"); [ -f "$target" ] && echo "OK $f" || echo "BROKEN $f -> $target"
  done'
```

---

## Step 7 — Verify apps serve the moved files

### Immich

Open the Immich web UI (https://immich.stoat-perch.ts.net) and browse to a
photo that was moved. It should load normally — Immich follows the symlink
transparently.

If images show "error loading image", check:

1. The Immich pod can read `/data-hdd`: `kubectl exec deployment/immich-server -- ls /data-hdd/library`
2. The HDD is still mounted: `mount | grep homelab-hdd`
3. The symlink target exists: (see Step 6 checks above)

### Jellyfin

Open Jellyfin (https://jellyfin.stoat-perch.ts.net) and play a movie/episode
that was moved. It should play without issues.

If playback fails with "file not found":

1. Check `/media-hdd` is accessible: `kubectl exec deployment/jellyfin -- ls /media-hdd`
2. Trigger a library rescan in Jellyfin Dashboard → Libraries → Scan All Libraries
   (Jellyfin re-scans the symlink path and updates the internal media path cache)

---

## Ongoing operations

### Run the movers / backup

Every time you connect the HDD:

```bash
~/homelab/tier-now.sh immich
~/homelab/tier-now.sh jellyfin
~/homelab/tier-now.sh backup     # optional; run when you want a snapshot
```

Or trigger from the webapp (primary trigger going forward).

### Check last run status

```bash
kubectl get jobs -n homelab
# Mover jobs are named tier-immich-<ts> and tier-jellyfin-<ts>
# Backup jobs are named immich-backup-<ts>

kubectl logs -n homelab -l job-name=<job-name> | tail -20
```

### Clean up old Job records

The CronJobs are suspended so their history limits don't apply. Manually
delete completed Jobs once you no longer need their logs:

```bash
# Nuke completed mover + backup jobs older than 7 days
kubectl get jobs -n homelab -o json | jq -r '
  .items[] |
  select(.metadata.name | test("^(tier-immich|tier-jellyfin|immich-backup)-")) |
  select((now - (.status.completionTime // .metadata.creationTimestamp | fromdateiso8601)) > 7*86400) |
  .metadata.name' | xargs -r kubectl delete job -n homelab
```

### Enable nightly automation later (when second HDD is in place)

```bash
kubectl patch cronjob tier-mover-immich   -n homelab -p '{"spec":{"suspend":false}}'
kubectl patch cronjob tier-mover-jellyfin -n homelab -p '{"spec":{"suspend":false}}'
kubectl patch cronjob immich-backup       -n homelab -p '{"spec":{"suspend":false}}'
```

### HDD space usage

```bash
du -sh /Volumes/homelab-hdd/immich-library
du -sh /Volumes/homelab-hdd/jellyfin-media
du -sh /Volumes/homelab-hdd/backups
df -h /Volumes/homelab-hdd
```

### SSD space reclaimed

After the mover runs, the SSD shows symlinks (tiny) where large files were.
Check remaining real data:

```bash
# Inside the mover pod or on the Mac:
du -sh --exclude='*.tmplink' \
  /var/lib/rancher/k3s/storage/pvc-17ce78b9-de1e-4fe7-b2f0-214c599795d9_homelab_immich-upload-localpath-pvc/library
```

### If the HDD is unmounted (e.g. Mac sleep/disconnect)

1. Remount the HDD: plug in USB, wait for Finder to mount it
2. Verify: `mount | grep homelab-hdd`
3. App pods will recover automatically — they follow symlinks on each request,
   no restart needed once the HDD is back

### If a PVC is recreated (SSD paths change)

The mover's hostPath volumes hardcode the PVC UUID. If either PVC is recreated:

1. Get the new path:
   ```bash
   kubectl get pv \
     -o jsonpath='{range .items[?(@.spec.claimRef.name=="immich-upload-localpath-pvc")]}{.spec.local.path}{end}'
   kubectl get pv \
     -o jsonpath='{range .items[?(@.spec.claimRef.name=="jellyfin-media-localpath-pvc")]}{.spec.local.path}{end}'
   ```
2. Update the `hostPath.path` in `~/homelab/tiered-storage-mover.yaml` for the
   affected CronJob (and the snapshot in `docs/homelab-k8s-setup/configs/`)
3. Re-apply: `kubectl apply -f ~/homelab/tiered-storage-mover.yaml`

Note: the backup CronJob mounts `immich-upload-localpath-pvc` by PVC name (not
raw hostPath), so it does NOT need updating if the Immich PVC is recreated.
