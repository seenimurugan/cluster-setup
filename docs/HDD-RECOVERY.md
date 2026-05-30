# HDD recovery runbook

> **Architecture note (post-2026-05-27 migration):** the cluster apps no longer depend on the HDD for live data. Immich, Jellyfin, Postgres, etc. all run from the internal SSD via `local-path` PVCs. The HDD is now used **only** as the weekly backup target (`/Volumes/Seeni's HDD/backups/`) and to hold personal media that the cluster doesn't touch.
>
> That means HDD-missing is no longer a P0 outage — the apps keep working. Only the backup job fails. Most of this runbook is still useful for the eventual re-mount, but you can take it at your own pace.

## Symptoms

You'll know the HDD is gone if you see any of:

- The weekly backup LaunchAgent fails — `~/homelab/backup.log` shows `HDD not mounted (parent dir missing). Skipping`
- `ls /Volumes/Seeni's HDD/` says "No such file or directory"
- Finder no longer shows the drive in the sidebar

**What is NOT a symptom anymore** (these used to indicate HDD trouble in the old architecture but are unrelated now):
- ~~ENFILE / "Too many open files in system"~~ — that bug was caused by virtiofs+exFAT and is gone with the migration. If you ever see it again, suspect the OrbStack VM disk filling up or a different inode-leak source, not the HDD.
- ~~"Error loading image" in Immich~~ — could be from many things now (missing file inside the VM ext4, DB inconsistency, broken upload), not HDD.
- ~~Jellyfin showing no movies~~ — same, look inside the VM PVC first.

---

## Step-by-step recovery

### 1. Confirm the HDD is actually missing

```bash
ls /Volumes/Seeni's\ HDD/ 2>&1
```

If it returns "No such file or directory" — HDD is unmounted on the Mac side.

### 2. Check what macOS sees

```bash
diskutil list external
```

Three possible outcomes:

| Output | Meaning | Next step |
|---|---|---|
| Shows `Seeni's HDD` partition | Drive is detected but NOT mounted | Go to Step 3 (mount it) |
| Shows the drive but no partition / "not initialized" | Filesystem corruption | Go to Step 4 (repair) |
| Doesn't show the drive at all | Hardware/cable issue | Go to Step 5 (physical) |

### 3. Mount the drive (most common fix — what just worked)

```bash
# Find the partition device (look for "Seeni's HDD" in the output)
diskutil list external

# Mount it explicitly — replace disk4s2 with whatever diskutil showed
sudo diskutil mount /dev/disk4s2

# Verify
ls /Volumes/Seeni's\ HDD/ | head
df -h /Volumes/Seeni's\ HDD/
```

If `diskutil mount` succeeds, jump to **Step 6: refresh the cluster**.

### 4. Filesystem repair (if mount fails)

If macOS detects the disk but won't mount, the exFAT filesystem may be marked dirty (happens when the drive is yanked without "Eject" first):

```bash
# Check filesystem integrity
sudo diskutil verifyVolume /dev/disk4s2

# Repair if errors found
sudo diskutil repairVolume /dev/disk4s2

# Try mounting again
sudo diskutil mount /dev/disk4s2
```

⚠️ If repair fails or asks you to reformat → **STOP. Don't reformat.** Get help / check `data recovery` options first. The HDD has irreplaceable photos.

### 5. Hardware troubleshooting (drive not detected at all)

Try in this order:

1. **Unplug, wait 10 sec, replug** — sometimes USB-C just needs reseating
2. **Try a different USB port** — port could be faulty
3. **Try a different USB-C cable** — cables fail silently and frequently
4. **Listen / feel** — is the drive spinning up? If silent and warm/cold, power issue (need a powered hub or different port)
5. **Power-cycle the Mac** — last resort, sometimes resolves USB controller weirdness

After each, retry `diskutil list external`.

### 6. Refresh the cluster — usually NOT needed anymore

In the old architecture, pods had hostPath mounts pointing into the HDD, so re-mounting the HDD required a VM refresh + pod restart. In the new architecture, the apps don't mount the HDD at all, so they don't care whether the HDD comes and goes.

The only consumers of the HDD now are:
- The weekly backup script (`backup-immich.sh`) — re-runs on schedule, will pick up the HDD next Sunday automatically
- Future manual operations like `immich upload` of files from `Pictures/` etc.

If you want to manually trigger a backup right after re-mounting:
```bash
/Users/nila/homelab/backup-immich.sh && tail -30 ~/homelab/backup.log
```

### 7. Verify

```bash
# Pods healthy
kubectl get pods -n homelab

# Immich responds
curl -s -o /dev/null -w "Immich: HTTP %{http_code}\n" http://localhost:2283/api/server/ping

# Pod can actually read HDD content
IM_POD=$(kubectl get pod -n homelab -l app.kubernetes.io/name=server --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n homelab "$IM_POD" -- ls /data/library
# Should list user UUID folders, NOT error
```

---

## Optional: pause the photo pods while the HDD is unplugged

**Not needed anymore.** Since the 2026-05-27 migration, no cluster pod mounts the HDD. The apps stay healthy when the HDD is unplugged. Pausing them was a hack to silence error spam from broken hostPath mounts; with `local-path` PVCs there's no spam to silence.

The legacy hostPath PVs (`immich-upload-pv`, `jellyfin-media-pv`, `jellyfin-config-pv`, `immich-photos-readonly-pv`) still exist in the cluster but are unbound from any running pod. They can be safely deleted once you trust the migration:
```bash
kubectl delete pv immich-upload-pv jellyfin-media-pv jellyfin-config-pv immich-photos-readonly-pv
kubectl delete pvc -n homelab immich-upload-pvc jellyfin-media-pvc jellyfin-config-pvc immich-photos-readonly-pvc
```

---

## Why this happens

The HDD can unmount itself when:

1. **Sleep/wake cycle** — macOS sometimes unmounts external drives during deep sleep and doesn't re-mount on wake
2. **Cable jiggle** — even momentary loss of signal triggers unmount
3. **Bus power throttling** — under heavy load (USB hub with other devices), the HDD may briefly underpower and disconnect
4. **OS update** — macOS sometimes resets external mounts after a security update

The cluster pods don't notice — k8s hostPath mounts are eagerly bound at pod start and don't track liveness of the underlying mount. From the pod's view, `/data` exists but reads/writes return errors.

---

## Prevention

- **Don't yank the drive** — always Eject from Finder first (right-click → Eject)
- **Use a powered USB hub** if you have one — bus-powered drives are more prone to undervoltage
- **Settings → Energy Saver → uncheck "Put hard disks to sleep when possible"** on the Mac — extends drive life but more importantly stops macOS unmounting on idle
- **Settings → Battery → Options → uncheck "Wake for network access"** — reduces sleep-wake cycles

---

## Quick reference

```bash
# Diagnose
ls /Volumes/Seeni's\ HDD/                # Is it mounted?
diskutil list external                   # What does macOS see?

# Mount
sudo diskutil mount /dev/disk4s2         # Adjust device name from diskutil output

# Refresh the cluster after re-mounting
orbctl stop && orbctl start
kubectl rollout restart deployment/immich-server -n homelab
kubectl rollout restart deployment/immich-machine-learning -n homelab
kubectl rollout restart deployment/jellyfin -n homelab
```
