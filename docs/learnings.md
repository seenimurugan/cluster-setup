# Learnings

Tribal knowledge captured during setup. Update SKILL.md when these become reusable rules.

---

## 2026-05-26

### HDD name has a space and apostrophe
The HDD is mounted at `/Volumes/Seeni's HDD` — both space AND apostrophe in the path. This matters for:
- Shell commands: must quote with double quotes, single quotes break on the apostrophe
- YAML hostPath: works fine (no shell interpretation)
- k8s namespace names: don't use the HDD name in a k8s resource name

**Rule for SKILL.md:** Always quote HDD path with double quotes in shell. Note the apostrophe in hostPath YAML if applicable. Confirmed: apostrophe in hostPath YAML works fine — k8s handles it correctly.

### OrbStack k3s is NOT vanilla k3s — Traefik is NOT pre-installed
Upstream k3s ships with Traefik as default ingress. OrbStack's k3s ships with ONLY:
- `coredns`
- `local-path-provisioner` (default StorageClass = `local-path`)

No Traefik, no ServiceLB. Verified 2026-05-26 on OrbStack 2.1.3, k8s v1.33.9+orb1.

**Implication:** For ingress, we need to install Traefik (or nginx) ourselves, OR skip ingress in v1 and use `kubectl port-forward` to expose services. v1 strategy: skip ingress, use port-forward + Tailscale.

**Rule for SKILL.md:** Drop the `ingress:` blocks from Jellyfin/Immich values. Use port-forward for v1.

### OrbStack passes through `/Volumes/` to k3s pods
Tested with hostPath: `/Volumes` is fully visible from inside pods. Read AND write both work to `/Volumes/Seeni's HDD`. The apostrophe in the path is handled correctly.

**This is the key enabler for HDD-backed PVs.** Without this passthrough, we'd need NFS or a different storage approach.

### OrbStack k8s can be enabled headlessly via CLI
No need to open the GUI. The CLI `orbctl config set k8s.enable true` + `orbctl stop && orbctl start` is sufficient. This makes the skill repeatable without manual clicks.

**Rule for SKILL.md:** Replace the "open OrbStack, go to Settings → Kubernetes" instruction with the CLI-only path.

### OrbStack's default StorageClass `local-path` is inside the VM, NOT on the HDD
The default `local-path` provisioner writes to `/var/lib/rancher/k3s/storage/` which is **inside the k3s VM**, not on macOS — so it doesn't use the HDD. For HDD-backed storage, we must define our own `local-hdd` StorageClass + hostPath PVs.

### Initial coredns restart is normal
On first cluster boot, `coredns` showed `RESTARTS 1` immediately after coming up. This is benign — it's part of the k3s cold-start dance and stabilizes within seconds.

### ⚠️ Seeni's HDD is exFAT — Postgres cannot live there
`diskutil info` confirmed `/Volumes/Seeni's HDD` is **ExFAT** (filesystem personality). exFAT via macOS FUSE does NOT reliably provide:
- POSIX permissions (everything looks like one owner)
- fsync semantics needed by databases
- Atomic rename(2) — required by Postgres for WAL
- File locks (fcntl advisory locks)
- Symlinks — needed by Postgres tablespaces

**Implication:** Putting PostgreSQL on exFAT risks data corruption or outright refusal to start. Media files (movies, photos as blobs) are fine on exFAT — they're just opaque reads/writes.

**The plan must split storage:**
- Jellyfin media + Immich upload (photo blobs) → HDD via hostPath
- Immich PostgreSQL → OrbStack's `local-path` StorageClass (ext4 inside VM, safe for Postgres)
- Immich Redis → same (in-memory anyway)
- Backup strategy: periodic `pg_dump` of Immich DB to the HDD so a VM reset doesn't lose photo metadata/albums/face recognition results.

**Reformatting the HDD is NOT an option** — it has ~700GB of personal drone footage, family photos, and movies. Format change is destructive and we have no backup target large enough.

**Rule for SKILL.md:**
1. Before storage planning, always check the HDD filesystem with `diskutil info "$HDD_PATH" | grep "File System"`.
2. If exFAT/FAT32/NTFS: Postgres goes on local-path (VM-local), media stays on HDD.
3. If APFS/HFS+: Postgres can live on HDD too.

### macOS resource fork files on exFAT
When macOS creates files on exFAT, it generates `._foo` "AppleDouble" sidecar files for metadata. These are harmless but clutter `ls`. No action needed; pods ignore them.

### Immich's official Helm chart does NOT bundle Postgres
Chart `immich/immich` 0.11.1 (appVersion v2.6.3) only deploys: server, machine-learning, valkey (Redis-compatible). No Postgres. The values.yaml has one comment "Add the env vars to connect to your database here." — that's it.

**You must deploy Postgres separately.** Use Immich's pre-built image `ghcr.io/immich-app/postgres:17-vectorchord0.4.3-pgvector0.8.0` (current latest as of 2026-05-26) — it includes pgvector and vectorchord extensions Immich requires for face/object recognition. A vanilla Postgres image will NOT work.

**Rule for SKILL.md:** Provide a separate Postgres StatefulSet + Secret + Service manifest. The chart's `env` block points to it via DB_HOSTNAME/DB_PORT/DB_USERNAME/DB_PASSWORD/DB_DATABASE_NAME.

### Immich chart release 0.12.0 has broken release artifact
`helm install immich/immich` (or even `helm pull`) fails with 404 on the GitHub release tarball. Manual curl of the same URL works fine — it's a helm-vs-redirect issue or unpublished asset.

**Workaround:** Pin to 0.11.1 (same appVersion v2.6.3), or `curl` + extract + `helm install /path/to/local-chart`. This is what we did.

### Tailscale on macOS — brew CLI doesn't include the daemon
`brew install tailscale` installs only the CLI binary. The daemon (`tailscaled`) ships with the Tailscale.app GUI app from the Mac App Store / direct download. Without the GUI app running, the CLI can't connect to anything.

**Rule for SKILL.md:** The user's Mac already has Tailscale.app. Don't try `brew install --cask tailscale` — it's not needed and would conflict. Use the bundled CLI at `/Applications/Tailscale.app/Contents/MacOS/Tailscale` for scripting, or `open -a Tailscale` to launch the GUI daemon.

### PVC selector binding by labels is essential when multiple PVs share a StorageClass
We have three PVs on the `local-hdd` StorageClass — without `labels` on the PVs and `selector.matchLabels` on the PVCs, k8s might bind a PVC to the "wrong" PV (it picks any matching one). Adding `app/purpose` labels and matching selectors guarantees deterministic binding.

### `kubectl wait` label selector
`app.kubernetes.io/name=immich` matches NOTHING for the Immich chart (it uses `app.kubernetes.io/instance=immich` instead, because the chart's components are subcharts named server/machine-learning/valkey with their own `name` labels). Use the **instance** label for chart-wide waits.

### launchd plist needs explicit PATH and KUBECONFIG
launchd jobs don't inherit your shell environment. Without `EnvironmentVariables → PATH` including `/opt/homebrew/bin`, `kubectl` and the Tailscale CLI won't be found. Without `KUBECONFIG`, kubectl can't find the cluster config.

---

## 2026-05-26 — Migration to Pattern B (Tailscale in-cluster)

After Pattern A (Mac-side Tailscale + port-forward) worked, user wanted Pattern B (in-cluster Tailscale operator) so the Mac is not in the network path.

### Tailscale Operator setup
- Helm repo: `https://pkgs.tailscale.com/helmcharts`, chart `tailscale/tailscale-operator` 1.98.3 (appVersion v1.98.3).
- Requires OAuth client from Tailscale admin (NOT just an auth key — keys expire, OAuth lets the operator mint per-device keys on demand).
- OAuth client needs scopes: `Devices: Core (Write)` + `Auth Keys (Write)`, and tag `tag:k8s-operator`.
- ACL policy must define the tag: `tagOwners: { "tag:k8s-operator": [], "tag:k8s": ["tag:k8s-operator"] }`.

```bash
helm install tailscale-operator tailscale/tailscale-operator \
  --namespace tailscale --create-namespace \
  --set-string oauth.clientId='...' \
  --set-string oauth.clientSecret='...' \
  --set apiServerProxyConfig.mode=true
```

### Two exposure modes — pick one based on need
| Mode | Annotation/Field | URL form | Notes |
|---|---|---|---|
| LoadBalancer Service | `type: LoadBalancer` + `loadBalancerClass: tailscale` | `http://<ns>-<svc>.<tailnet>.ts.net:<port>` | Plain TCP, raw port in URL |
| Ingress | `ingressClassName: tailscale` | `https://<rule-host>.<tailnet>.ts.net` | Auto-HTTPS via Tailscale-issued cert, no port |

**Rule for SKILL.md:** Use Ingress when you want clean URLs with HTTPS. LoadBalancer is fine for non-HTTP TCP services.

### HTTPS Certificates must be enabled in Tailscale admin
At https://login.tailscale.com/admin/dns → **HTTPS Certificates** → Enable. Without this, the operator can't provision certs and Ingress access fails (no SNI matching). One-time toggle per tailnet.

### Ingress rules[].host is just the subdomain (no tailnet suffix)
For `https://jellyfin.stoat-perch.ts.net`, the Ingress spec uses `host: jellyfin` (not the full domain). The operator appends `.<tailnet>.ts.net`. Same with `tls[].hosts`.

### Ingress can use `defaultBackend` for single-service exposure
You don't need explicit `rules` when one service backs the whole hostname. `defaultBackend.service.{name,port.number}` is enough.

### After uninstalling Mac Tailscale, the Mac itself can't reach `.ts.net` hosts
This is OBVIOUS in hindsight but caused a false-alarm smoke test: `curl https://immich.stoat-perch.ts.net` from the Mac returns HTTP 000 (no route) because the Mac is no longer on the tailnet. **Test from another device** (iPhone, etc.) after Mac cleanup.

### macOS direct-install Tailscale uninstall requires sudo + reboot
The Tailscale.app (macsys variant) registers a System Extension that survives a plain `rm -rf`. Proper cleanup:
1. Quit the app
2. Drag Tailscale.app to Trash via Finder → macOS prompts for system extension removal → approve
3. `sudo rm -f /usr/local/bin/tailscale` (root-owned symlink from the in-app CLI installer)
4. System extension fully unloads on next reboot (visible via `systemextensionsctl list`)

### LoadBalancer → ClusterIP transition: remove `loadBalancerClass` first
`kubectl patch ... --type=merge -p '{"spec":{"type":"ClusterIP"}}'` alone is rejected because `loadBalancerClass` is set. Use JSON patch:
```bash
kubectl patch svc <name> -n homelab --type=json \
  -p='[{"op":"remove","path":"/spec/loadBalancerClass"},{"op":"replace","path":"/spec/type","value":"ClusterIP"}]'
```

### Tailscale-managed devices appear as `tagged-devices`
In `tailscale status`, devices created by the operator show under `tagged-devices` rather than your user. Visible as `tailscale-operator`, `homelab-jellyfin`, etc. on your admin console — they count against device limits the same as personal devices.

### zsh `read` syntax is NOT bash-compatible — silent failure mode
For interactive credential entry, `read -s -p "Prompt: " VAR` works in bash but in zsh emits `read: -p: no coprocess` and **silently sets VAR to empty**. Subsequent `helm upgrade ... --set-string oauth.clientId="$VAR"` then deploys empty values, which deletes the `operator-oauth` Secret entirely (the chart skips creating Secrets with empty data) — surviving operator pod keeps working off in-memory cached credentials until next restart.

macOS defaults to **zsh** since Catalina. Use zsh syntax in any scripts pasted into Terminal.app:
```zsh
read -s "VAR?Prompt: "   # zsh form: variable, then ?, then prompt
```

**Rule for SKILL.md:** any interactive-credentials snippet must be zsh-compatible. Or wrap with `bash -lc '...'` to force bash.

### How to recover from accidentally-deleted operator-oauth Secret
The operator pod caches credentials in memory at startup, so it keeps working short-term even if the Secret is empty/missing. To recover:
1. Re-run `helm upgrade` with correct credentials (recreates the Secret).
2. `kubectl rollout restart deployment/operator -n tailscale` to force the pod to re-read.
3. Check logs for auth errors. Proxy pods (`ts-*`) survive independently — they have their own tailnet auth keys.

### Immich job concurrency must be 1 because of exFAT bottleneck
**Symptom (2026-05-27):** Immich web UI showed "error loading image" for ~80-500 photos. DB query showed those assets had no `asset_file` row of type `thumbnail`. Server logs filled with:
```
ENFILE: file table overflow, open '/data/thumbs/.../...preview.jpeg'
```

**Cause:** OrbStack's exFAT-via-FUSE passthrough to `/Volumes/Seeni's HDD/immich/upload/` (mounted as `/data` in the pod) **cannot handle concurrent writes**. Immich's default job concurrency (thumbnailGeneration=3, smartSearch=2, faceDetection=2) generates parallel thumb writes that overwhelm FUSE → ENFILE → silent failure for some files.

**Fix:** lower ALL Immich job concurrencies to **1** via the Admin API:
```bash
KEY=$(awk '/^key:/{print $2}' ~/.config/immich/auth.yml)
URL=http://immich-server.homelab.svc.cluster.local:2283/api
CONFIG=$(curl -s -H "x-api-key: $KEY" "$URL/system-config")
NEW=$(python3 -c "
import json
c = json.loads('''$CONFIG''')
for k in c.get('job', {}):
    c['job'][k] = {'concurrency': 1}
print(json.dumps(c))
")
curl -s -X PUT -H "x-api-key: $KEY" -H "Content-Type: application/json" \
  -d "$NEW" "$URL/system-config"
```

After this: zero ENFILE errors. Throughput is lower (serial vs parallel) but consistent. For a homelab this trade-off is correct — better slow + reliable than fast + broken.

**Rule for SKILL.md:** if storing Immich photos on an external HDD with exFAT (not native ext4/APFS), set all job concurrencies to 1 from day 1.

Long-term fix would be to move `/data/thumbs/` and `/data/encoded-video/` to local-path (VM ext4) while keeping `/data/library/` on the HDD. Originals stay on the HDD (read-mostly, big files); derived data goes to fast local storage (write-heavy, regenerable).

### Helm `--set-string` with empty values DELETES Secret keys (gotcha)
The Tailscale operator chart conditionally renders the `operator-oauth` Secret only when both clientId and clientSecret are non-empty. Passing empty strings removes the Secret entirely, which would orphan the Deployment's volume mount on next pod restart.

### Don't scale ML pods up *during* the bulk upload — only after
**Symptom (2026-05-26):** During an active 40k-file Immich bulk upload, scaled `immich-machine-learning` to 3 replicas. After 30 min, OrbStack k3s node flipped to `NotReady`, port-forwards broke, kubectl timed out. Tailscale URLs also stopped responding.

**Root cause:** Combined load too high for the 40 GB OrbStack VM:
- Active CLI upload hashing 40k files + transferring (heavy I/O)
- 3× immich-machine-learning pods (each up to 6 GB limit = potential 18 GB)
- immich-server processing uploads
- Postgres on local-path inside the VM
- Jellyfin running
- Tailscale operator + 2 proxy pods
- VM thrashing → kubelet missing heartbeats → node NotReady

**Fix:**
1. Stop upload (relieves I/O + memory pressure)
2. Scale ML back to 1 (`kubectl scale deployment immich-machine-learning -n homelab --replicas=1`)
3. Force-delete stale ML pods if needed
4. Reload port-forward (`launchctl unload && load`) — it can get pinned to a dead pod IP

**Rule:** Scale ML up AFTER bulk upload finishes (jobs queue and drain post-upload). During upload, keep ML at 1 replica so VM has headroom for I/O + server pod's request-handling.

**Update the bulk upload runbook** to reflect this: scale ML *after* upload completes, not before.

### `kubectl port-forward` can pin to a dead pod IP
When the upstream pod restarts repeatedly (immich-server during heavy upload), `kubectl port-forward` sometimes doesn't reconnect cleanly — the local port returns HTTP 000. Fix: kill the kubectl process or reload the launchd job. Service-level port-forward (`svc/foo`) is more resilient than pod-level (`pod/foo-xyz`) for this reason — we already use service-level, but even that can fail under churn.

### Mac can reach cluster services DIRECTLY via OrbStack — no port-forward needed
OrbStack with `k8s.expose_services: true` (set during initial setup) makes cluster Services resolvable from the Mac via `<service>.<namespace>.svc.cluster.local:<port>`. The Mac talks straight to the cluster CNI through OrbStack's network bridge — **no kubectl port-forward in the path**.

Real-world impact (2026-05-26): the immich CLI was failing repeatedly with `TypeError: fetch failed` because the kubectl port-forward connection kept dying under sustained upload load. Switching the CLI to `http://immich-server.homelab.svc.cluster.local:2283` (edit `~/.config/immich/auth.yml`) eliminated the failures entirely — uploads now go direct, no port-forward in the path.

**Rule for SKILL.md:** for CLI tools and long-running connections, prefer the cluster DNS URL. Keep `localhost:<port>` (via launchd port-forward) for browser convenience only.

The cluster DNS host pattern:
```
<service-name>.<namespace>.svc.cluster.local:<port>
```
e.g. `immich-server.homelab.svc.cluster.local:2283`

### Jellyfin config on exFAT HDD failed under heavy concurrent load
**Symptom (2026-05-26):** During an active Immich upload of ~3000 photos, restarting Jellyfin (any reason — Helm upgrade, manual rollout, etc.) caused the new pod to crash with:
```
System.IO.IOException: Too many open files in system : '/config/config/.jellyfin-config'
```
The error message is misleading — the OrbStack VM's actual `fs.file-max` was 9223372036854775807 (essentially unlimited), only ~3000 FDs were open system-wide, and `fs.inotify.max_user_watches` was at 1M. So neither file-max nor inotify was the real bottleneck.

**Real cause (suspected):** exFAT-via-FUSE on macOS, passed into the OrbStack VM via virtiofs/9p, doesn't reliably support some POSIX operations Jellyfin needs at startup (`File.Exists()` + `CreateEmpty()` on marker files). When the HDD is busy with concurrent reads (Immich serving photos for the upload, ML processing, etc.), these operations time out / fail with errors that .NET's runtime translates to ENFILE ("Too many open files in system") even though FDs are fine.

**Fix:** move Jellyfin's `config` PVC from exFAT hostPath to `local-path` (VM-internal ext4). Same reasoning as Immich Postgres. The HDD remains fine for **media** PV (Jellyfin reads movies sequentially) — only the config/database write workload chokes on exFAT.

**Rule for SKILL.md:** databases AND application state (Jellyfin config, plugin metadata, server.db, etc.) should live on `local-path`, not exFAT. exFAT is only safe for large opaque media files (read-mostly).

### Mounting a live-growing PVC into a second pod via inotify causes pod-start hangs
**Setup (2026-05-26):** mounted Immich's photo library into Jellyfin read-only at `/photos`, so Jellyfin could serve photos to TV apps. When the Immich library was actively growing (uploads in flight), Jellyfin's library-scan-on-start traversed thousands of constantly-changing files. Combined with the exFAT issue above, this caused the Jellyfin pod to fail starting.

**Fix:** remove the `/photos` mount from Jellyfin. Photos stay in Immich (mobile app, web UI, cast from phone). Jellyfin handles only movies/TV/music.

**If we later want photos in Jellyfin:** wait until the bulk import is complete and the library is no longer growing, then re-add the mount and trigger a one-time library scan. Don't enable continuous monitoring on it.



### Skills should live outside `~/.claude/skills/`
Coding-agent-agnostic skills should be authored in the project repo (`/Users/nila/Developer/agents/skills/`) and symlinked into the agent's expected location (e.g. `~/.claude/skills/`). This lets other agents (OpenCode, etc.) reference the same source.

---

## 2026-05-27 — Migration off the HDD (Immich ENFILE root cause)

### Root cause: virtiofs holds host FDs per inode, exFAT amplifies it
For two days Immich kept hitting `ENFILE: file table overflow` on `mkdirSync` calls under `/data/upload/<user>/<shard>/<shard>/`. Symptoms:
- `kubectl exec ... -- mkdir -p /data/upload/_probe-N` also failed with `Too many open files in system`
- macOS `kern.maxfiles=491520`, `kern.num_files=18459` — system-wide budget healthy
- OrbStack `vmgr` process had only ~8k FDs — well below the 245,760 per-process limit (so it seemed)
- Bouncing OrbStack worked for ~30 min then ENFILE returned

The actual mechanism (sources: orbstack#2255, #1253, #2347, phpstan#14307, immich#12552, #12439, docker/for-mac#6807):

1. **Apple's virtiofs holds an `O_PATH` host FD per accessed inode**, only released when the guest sends `FUSE_FORGET`. Linux rarely sends these aggressively.
2. **Immich's deep shard tree** (`upload/<uid>/<2-char>/<2-char>/`) touches tens of thousands of dirs, so vmgr accumulates host FDs against macOS's *per-process* `kern.maxfilesperproc` budget — independent of the system-wide one.
3. **exFAT compounds it**: no dentry caching, every mkdir/stat round-trips through FUSE. Immich maintainers say outright "this is definitely due to the exfat filesystem".
4. **External drives amplify it**: macOS `fseventsd` and Spotlight add more FD pressure on `/Volumes/...` (orbstack#2255 is a known regression specifically for external-disk bind mounts).

**Sysctl tuning doesn't help** — the limit being hit is per-process, not system-wide. OrbStack restart only resets the accumulation; it doesn't stop it. Concurrency tweaks reduce *rate* of FD growth, not cumulative.

### Why "ext4 disk image on the HDD" (Option C from the research) was tempting but wrong here
We initially planned to create a sparse 2 TiB `immich.img` on the HDD, format ext4 inside, loop-mount in the VM. That would collapse "thousands of HDD inodes seen by virtiofs" into "one big file seen by virtiofs", solving the FD problem.

Execution gotcha: `mkfile -n 2048g` on exFAT **does not produce a sparse file**. macOS man page explicitly states "Files created with this flag are NOT supported by file systems that do not support sparse files... msdos, hfs, and afpfs." exFAT silently demoted `-n` to a regular allocation and started writing 2 TiB of zeros at ~120 MB/s. Estimated ~5 hours, file still 0 bytes after 3 hours (exFAT also doesn't update file metadata until the operation completes). The whole laptop stuttered any time another command touched the HDD because the head was busy.

### The actual fix: move live data off the HDD entirely
Architecture chosen 2026-05-27:
- Active data → `local-path` PVCs (inside the OrbStack VM's ext4 disk on internal SSD APFS). Virtiofs is no longer in the data path.
- HDD → backup target only. Weekly `tar.zst` to `/Volumes/Seeni's HDD/backups/`. One file per backup ⇒ no virtiofs FD explosion on the write side either.

PVC changes:
- `immich-upload-pvc` (local-hdd, 1 Ti) → `immich-upload-localpath-pvc` (local-path, 500 Gi)
- `jellyfin-media-pvc` (local-hdd, 2 Ti) → `jellyfin-media-localpath-pvc` (local-path, 200 Gi)
- `jellyfin-config-localpath-pvc` was already on local-path — no change needed

### Why VM-side rsync still failed during the migration
First attempt: a k8s Job mounting old HDD-backed PVC at `/src` and new SSD PVC at `/dst`, running `rsync -aHAX /src/ /dst/`. **Hit the exact ENFILE we were trying to escape.** rsync walks the source tree from inside the VM, so every `stat()` and `opendir()` allocates a virtiofs host FD in vmgr. Identical failure mode to Immich's own mkdirs.

### The migration trick that worked: read HDD natively from macOS, stream into the pod
```bash
cd "/Volumes/Seeni's HDD/immich/upload"
tar --exclude='._*' --exclude='.DS_Store' -cf - . | \
  kubectl exec -i -n homelab migrator-immich -- tar -C /dst -xf -
```

- macOS `tar` reads the HDD via APFS/exFAT native code — **no virtiofs**
- Pipe through `kubectl exec` — streams via the k8s API server, just network I/O
- Pod's `tar` writes into `/dst` which is the VM's ext4 — **no virtiofs**

Virtiofs never touches the data path. Transferred 115.8 GiB Immich + 18.2 GiB Jellyfin in ~35 minutes total. No FD errors.

**Rule:** for any "move data off virtiofs" migration, read the source natively from macOS and stream into the destination via `kubectl exec` / `kubectl cp`. Don't run rsync from inside a pod that mounts the slow side.

### Backup pattern: single tar.zst file, not rsync
Backups still touch the HDD (writes), but they create exactly one file per app per run, so virtiofs only sees one inode. The earlier rsync-based weekly backup (`backup-immich.sh`) was rewritten 2026-05-27 to:
```
kubectl exec -n homelab deployment/immich-server -- \
  tar -C /data -cf - --exclude='thumbs' --exclude='encoded-video' . \
  | zstd -3 -T0 -q -o "$HDD/backups/immich-library/immich-$DATE.tar.zst"
```
zstd compression mostly redundant on JPEG/HEIC content but harmless and gives bounded file sizes.

### What's on the HDD that we did NOT migrate
The HDD also holds ~689 GiB of personal media (drone footage, iPhone backups, photo collections in `Pictures/`, `Seeni Iphone 25-02-2023/`, etc.). These are untouched by the migration — they're not consumed by any cluster app. Either:
- Stay where they are (HDD as personal cold storage + cluster backup target)
- Get imported into Immich (web UI / mobile app / `immich upload` CLI) — Immich dedupes by checksum, safe to re-import

### Things the original session got wrong (so future-me doesn't repeat)
- Assumed `mkfile -n` made sparse files on any FS. It doesn't — exFAT/HFS/msdos silently fall back to full allocation. Always verify with `du -h` after creation.
- Conflated "total HDD used" with "Immich library size" in the implementation plan. The 850 GiB total was mostly personal media; actual Immich was 115.8 GiB. Always re-measure scope before estimating migration time.
- Did not consider that the very rsync used to *migrate* off the broken FS would itself trigger the FS bug. Migration tooling has to use a different code path from the broken one.

### File ownership note
The HDD is mounted with `noowners`, so files appear as `nila:staff` (uid 501) on macOS regardless of who wrote them. After migration, files inside the new ext4 PV show as `501:dialout` (uid 501 mapped, gid 20 → `dialout` in alpine's group file). Immich-server pod runs as root by default in this chart, so it can read/write fine. If the Immich chart ever switches to a non-root user, will need a `chown` pass.

---

## 2026-05-28

### OrbStack VirtioFS can ENFILE on a *fresh* HDD hostPath even when others work
**Symptom.** A new PV pointing under `/Volumes/Seeni's HDD/...` fails to mount with:
```
MountVolume.SetUp failed: mkdir /Volumes/Seeni's HDD/<name>: too many open files in system
```
…while existing HDD-backed PVs (immich, jellyfin) keep running fine. `sysctl kern.maxfiles` on macOS shows huge headroom (saw 24k used of 491k).

**Root cause.** The limit is inside OrbStack's VirtioFS layer, not on the macOS host. Spotlight indexing the HDD + an additional VirtioFS mount target seems to push it over a per-mount/per-process limit inside the OrbStack VM. The "too many open files" surface error is misleading.

**Mitigations (do all of these):**
1. **Default new app PVs to local SSD**, under the source tree (e.g. `/Users/nila/Developer/apps/<app>/.uploads`). The HDD is reserved for the genuinely-large stores (Immich library, Jellyfin media). Most app data is small enough to live on the SSD.
2. If the HDD really is required, **pre-create the directory** on macOS and use `hostPath.type: ""` on the PV — not `DirectoryOrCreate`. The latter triggers an extra mkdir syscall that's the first thing to ENFILE. Jellyfin/Immich PVs both use `type: ""`.
3. **Last resort:** `orb stop && orb start` to reset OrbStack's VirtioFS state and retry. Disruptive (downs the whole cluster), so save it for when nothing else works.

Bit us on 2026-05-28 with the reminders app; uploads PV is now parked on the SSD with a documented migration path in `apps/reminders/MAINTENANCE.md`.

### `whatsapp-web.js` leaves Chromium profile locks on the PVC across pod replacements
**Symptom.** After `kubectl rollout restart` of a `whatsapp-web.js`-based sidecar, the new pod boots but `/status` shows `ready:false, qrAvailable:false` and `lastError` complains:
```
The profile appears to be in use by another Chromium process … on another computer
```

**Root cause.** When a Chromium-bearing pod dies ungracefully, its `LocalAuth` directory on the PVC still contains `SingletonSocket`, `SingletonCookie`, `SingletonLock`. These files are tagged with the OLD pod's hostname+pid. The new pod has a different hostname (pods get a fresh name each rollout), so Chromium treats it as a different machine trying to grab a busy profile and refuses to launch.

**Fix.** Delete the three lock files on the host path before / after the rollout:
```bash
find <pvc-host-path>/wwebjs_auth/session/ -name 'Singleton*' -delete
kubectl rollout restart deploy/<sidecar>
```
Doc this in each WhatsApp-using app's MAINTENANCE.md. Long-term: a preStop hook that runs the find/delete on the mounted volume would make this self-healing.

### Docsify with a `basePath` needs absolute sidebar links AND `relativePath: true`
Two settings interact in the docs site config that bit us repeatedly:

1. **Sidebar entries must use leading slashes** (`/homelab-k8s-setup/apps/foo/README.md`, not `homelab-k8s-setup/apps/foo/README.md`). Without the leading slash + with `relativePath: true`, the link resolves *relative to the current page*. That means it works from the home page, breaks (or, worse, lands on the wrong app's page when path fragments overlap, e.g. grocy ↔ reminders) from anywhere else.
2. **`relativePath: true` is required** in `$docsify` config in `index.html` so that *in-content* links like `[Maintenance](MAINTENANCE.md)` inside a sub-folder README resolve to the right path.

So: in-content links use bare relative paths (`MAINTENANCE.md`), and sidebar links use absolute paths from docs root (`/apps/foo/MAINTENANCE.md`). The two policies are different and both required.

Verify with: `grep -E '^\s*\*\s+\[' docs/_sidebar.md | grep -v '/home\|/apps\|http' | head` — any link in there without a leading `/` is a bug.
