# HDD Prep Runbook

One-time setup for the external HDD before the tiered-storage CronJob is deployed.
Target volume label: **`homelab-hdd`**, mounted at `/Volumes/homelab-hdd`.

---

## 1. Prerequisites

- HDD physically connected (USB/Thunderbolt) and visible in Disk Utility — do this before running any commands.
- Nothing on the disk worth keeping — format will erase everything.
- Terminal open and ready.
- OrbStack running (`orbctl status` passes).

---

## 2. Format

### Option A — Disk Utility GUI (preferred)

1. Open **Disk Utility** (`Cmd+Space → Disk Utility`).
2. In the sidebar, select the **physical disk** (top-level entry, not a partition).
3. Click **Erase**.
4. Fill in:
   - **Name:** `homelab-hdd`
   - **Format:** `Mac OS Extended (Case-sensitive, Journaled)` — this is HFS+ HFSJ with case-sensitivity.
   - **Scheme:** `GUID Partition Map`
5. Click **Erase** and wait for completion.
6. Close Disk Utility. The volume mounts automatically at `/Volumes/homelab-hdd`.

### Option B — diskutil CLI (reference / scripted)

Find the disk identifier first:

```bash
diskutil list
# Look for your HDD, e.g. /dev/disk4
```

Erase and reformat (replace `disk4` with your identifier):

```bash
sudo diskutil eraseDisk JHFS+X homelab-hdd GPT /dev/disk4
```

Flag breakdown: `JHFS+X` = HFS+ Journaled + Case-Sensitive. `GPT` = GUID Partition Map.

Verify mount point:

```bash
mount | grep homelab-hdd
# should show: /dev/disk4s2 on /Volumes/homelab-hdd (hfs, ...)
```

---

## 3. Create directory layout

```bash
mkdir -p /Volumes/homelab-hdd/immich-library
mkdir -p /Volumes/homelab-hdd/jellyfin-media
mkdir -p /Volumes/homelab-hdd/backups/postgres
mkdir -p /Volumes/homelab-hdd/backups/library
```

Confirm:

```bash
ls /Volumes/homelab-hdd/
# backups  immich-library  jellyfin-media

ls /Volumes/homelab-hdd/backups/
# library  postgres
```

The `backups/` tree is required by the `immich-backup` CronJob, which mounts
`/Volumes/homelab-hdd/backups` as a hostPath volume (type `""`). The script
also runs `mkdir -p` on both subdirs at startup as a safety net, but the
parent `backups/` directory must exist on the HDD before the first pod mount.

---

## 4. Housekeeping

Disable Spotlight indexing (reduces VirtioFS fd pressure — see Troubleshooting):

```bash
sudo mdutil -i off "/Volumes/homelab-hdd"
```

Exclude from Time Machine:

```bash
sudo tmutil addexclusion "/Volumes/homelab-hdd"
```

Verify both stuck:

```bash
mdutil -s "/Volumes/homelab-hdd"
# should say: Indexing disabled.

tmutil isexcluded "/Volumes/homelab-hdd"
# should say: [Excluded] /Volumes/homelab-hdd
```

---

## 5. Sanity checks

### Write / read / delete

```bash
echo "hdd-prep-ok" > /Volumes/homelab-hdd/.write-test
cat /Volumes/homelab-hdd/.write-test
rm /Volumes/homelab-hdd/.write-test
```

### Symlink support

```bash
touch /tmp/foo
ln -s /tmp/foo /Volumes/homelab-hdd/test-symlink
readlink /Volumes/homelab-hdd/test-symlink    # should print /tmp/foo
rm /Volumes/homelab-hdd/test-symlink /tmp/foo
```

### Case-sensitivity

```bash
touch /Volumes/homelab-hdd/FOO /Volumes/homelab-hdd/foo
ls -la /Volumes/homelab-hdd/ | grep -i foo
# Must show TWO separate entries: FOO and foo
rm /Volumes/homelab-hdd/FOO /Volumes/homelab-hdd/foo
```

### OrbStack VM visibility

Existing HDD-backed PVs use the pattern `/Volumes/<label>/...` from the macOS host.
OrbStack passes macOS volumes through VirtioFS at `/mnt/mac/Volumes/<label>/...` inside the VM.

```bash
orbctl run ls "/mnt/mac/Volumes/homelab-hdd"
# should list: immich-library   jellyfin-media
```

> Cross-reference: `kubectl get pv -o yaml | grep "path:"` on the existing PVs (e.g. `jellyfin-media-pv`, `immich-upload-pv`) shows `/Volumes/Seeni's HDD/...` — the new PVs will follow the same pattern at `/Volumes/homelab-hdd/...`.

---

## 6. Troubleshooting

### ENFILE ("too many open files in system") on pod mount

**Symptom:** a new PV/PVC backed by `/Volumes/homelab-hdd/...` stays in `Pending` or the pod logs show `too many open files in system` on first mount, even though `kern.maxfiles` has plenty of headroom.

**Root cause:** the error is inside OrbStack's VirtioFS host-mount path, not macOS's fd table. Spotlight indexing of a freshly added volume bumps a per-mount limit inside the OrbStack VM. See `feedback_orbstack_hdd_mount_limit` memory node for full details.

**Mitigations (apply all three):**

1. Spotlight disabled before first pod use (Step 4 above).
2. PV spec must use `type: ""` — **not** `DirectoryOrCreate` — to skip the mkdir stat codepath:
   ```yaml
   hostPath:
     path: /Volumes/homelab-hdd/immich-library
     type: ""
   ```
3. If ENFILE still fires on cold start, restart OrbStack to clear VirtioFS state, then re-apply:
   ```bash
   orbctl stop && orbctl start
   kubectl rollout restart deployment/immich-server -n homelab
   ```

---

## 7. What's next

Deploy the tiered-storage CronJob and create the HDD-backed PVs → see **[./deploy.md](./deploy.md)**.
