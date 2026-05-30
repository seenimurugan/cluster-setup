# Command Log

Every command run during homelab setup, in order. Includes timestamps, output summary, and notes.

---

## Session: 2026-05-26 — Step 1 setup begins

### Pre-flight checks

```bash
# Check existing k8s tooling
which kubectl helm brew orbstack docker rancher 2>/dev/null
kubectl version --client 2>/dev/null
helm version 2>/dev/null
brew list | grep -E "orbstack|rancher|k3s|minikube|kind" 2>/dev/null
ls /Applications | grep -iE "orb|rancher|docker" 2>/dev/null
```
**Result:** Only Homebrew + Docker CLI present. No k8s tooling. Clean slate.

```bash
ls /Applications | grep -iE "orb|rancher|docker|lens|k9s"
brew list 2>/dev/null | grep -iE "orb|rancher|k3s|helm|kubectl|kind|minikube"
```
**Result:** No relevant apps installed.

### HDD checks

```bash
df -h | grep "/Volumes/"
```
**Result:** `Seeni's HDD` mounted at `/Volumes/Seeni's HDD` — 3.6 TB total, 711 GB used, 2.9 TB free. Selected as the HDD for homelab storage.

```bash
uname -m
```
**Result:** (to be filled in) — used to confirm Apple Silicon vs Intel.

---

## Step 1 — Install tooling

```bash
brew install --cask orbstack && brew install kubectl helm
```
**Result:**
- OrbStack 2.1.3 (build 20115) — installed to `/Applications/OrbStack.app`. Symlinks: `/opt/homebrew/bin/orbctl`, `/opt/homebrew/bin/orb`.
- kubectl v1.36.1 (kustomize v5.8.1)
- helm v4.2.0 (Go 1.26.3, KubeClientVersion v1.36)

**Caveat from install:** "Open the OrbStack app to finish setup."

```bash
kubectl version --client && helm version && which orbctl orb kubectl helm
```
**Result:** All binaries linked correctly at `/opt/homebrew/bin/`.

---

## Step 2 — Enable Kubernetes in OrbStack

OrbStack supports headless k8s enablement via CLI — no GUI needed.

```bash
orbctl status
```
**Result:** `Stopped`

```bash
orbctl config show | head -30
```
**Result:** `k8s.enable: false`, `k8s.expose_services: false` (default).

```bash
orbctl config set k8s.enable true
orbctl config set k8s.expose_services true
orbctl stop
orbctl start
```
**Result:** Restarted OrbStack with k8s enabled. After ~15s, cluster is up.

```bash
kubectl get nodes
```
**Result:**
```
NAME       STATUS   ROLES                  AGE   VERSION
orbstack   Ready    control-plane,master   15s   v1.33.9+orb1
```

```bash
kubectl get pods -A
```
**Result:** Only `coredns` + `local-path-provisioner` (in `kube-system`). **No Traefik pre-installed** — this differs from upstream k3s defaults.

```bash
kubectl get storageclass
```
**Result:** `local-path (default)` from `rancher.io/local-path` provisioner. Stores data inside the VM at `/var/lib/rancher/k3s/storage/` — NOT on the HDD. We'll create our own `local-hdd` StorageClass + hostPath PVs.

### hostPath access test — does OrbStack expose `/Volumes/` to pods?

```bash
kubectl run hostpath-test --image=busybox --restart=Never --rm -i --tty=false --overrides='{...hostPath:/Volumes...}' -- ls -la /host-volumes/
```
**Result:** `Macintosh HD` and `Seeni's HDD` both visible from the pod. **YES — OrbStack passes through `/Volumes/` to k3s pods.**

```bash
# Write test
kubectl run ... hostPath:/Volumes/Seeni's HDD ... echo hello > /hdd/k8s-write-test.txt
```
**Result:** Read + write both work. The apostrophe in the HDD name is handled correctly by k8s hostPath.

---

## Step 3 — Prepare HDD directories + filesystem check

```bash
HDD_PATH="/Volumes/Seeni's HDD"
mkdir -p "$HDD_PATH/jellyfin/media/movies" \
         "$HDD_PATH/jellyfin/media/tvshows" \
         "$HDD_PATH/jellyfin/media/music" \
         "$HDD_PATH/jellyfin/config" \
         "$HDD_PATH/immich/upload" \
         "$HDD_PATH/immich/postgres"
```
**Result:** All directories created. Note: macOS created `._foo` AppleDouble sidecar files — harmless on exFAT.

### Filesystem check — CRITICAL FINDING

```bash
diskutil info "/Volumes/Seeni's HDD" | grep -E "File System|Type|Read-Only|Mount Point"
```
**Result:** `File System Personality: ExFAT`

**Impact:** Postgres CANNOT live on exFAT (no POSIX semantics, no atomic rename, no fsync guarantees, no symlinks). The `$HDD_PATH/immich/postgres` directory we just created will NOT be used. Postgres will instead use the default `local-path` StorageClass (ext4 inside the OrbStack VM, durable across Mac reboots but lost on `orbctl reset`).

### HDD content survey

```bash
du -sh "/Volumes/Seeni's HDD"/* | head
```
**Result:** ~700GB used by personal drone footage, photos, and movies. Reformatting would destroy data — not an option. **Plan adjusted: split Postgres (VM-local) from media (HDD).**

---

## Step 4 — Namespace and StorageClass

```bash
kubectl create namespace homelab
kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-hdd
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
EOF
```
**Result:** `namespace/homelab created`, `storageclass.storage.k8s.io/local-hdd created`. Default `local-path` StorageClass remains in place (for Postgres).

## Step 5 — PersistentVolumes and Claims

Wrote `/Users/nila/homelab/storage.yaml` with:
- `jellyfin-media-pv` (2Ti) → `/Volumes/Seeni's HDD/jellyfin/media`
- `jellyfin-config-pv` (5Gi) → `/Volumes/Seeni's HDD/jellyfin/config`
- `immich-upload-pv` (1Ti) → `/Volumes/Seeni's HDD/immich/upload`

Plus matching PVCs in `homelab` namespace. Used `labels` + `selector.matchLabels` to bind each PVC to its specific PV (otherwise k8s could swap them since they share a StorageClass).

```bash
kubectl apply -f ~/homelab/storage.yaml
kubectl get pv
kubectl get pvc -n homelab
```
**Result:** 3 PVs Available, 3 PVCs **Pending** — expected behavior with `WaitForFirstConsumer` (PVCs bind when a pod consumes them).

**Note:** No Postgres PV here. Immich's chart will create one dynamically via `local-path` StorageClass when Postgres pod starts.

---

## Step 6 — Deploy Jellyfin

```bash
helm repo add jellyfin https://jellyfin.github.io/jellyfin-helm
helm repo update jellyfin
helm show values jellyfin/jellyfin | head -200
```
**Result:** Chart added. Inspected default values — schema is:
- `persistence.config.{enabled, size, storageClass, existingClaim}`
- `persistence.media.{enabled, type, existingClaim}` — `type: pvc` is what we want
- No top-level `ingress` block (chart does not ship one) — good, matches our no-ingress strategy

Wrote `~/homelab/jellyfin-values.yaml` using `existingClaim` for both config and media to bind to our pre-made PVCs.

```bash
helm install jellyfin jellyfin/jellyfin --namespace homelab --values ~/homelab/jellyfin-values.yaml
```
**Result:** `STATUS: deployed`. NOTES suggest port-forward via `kubectl port-forward svc/jellyfin 8096:8096`.

```bash
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=jellyfin -n homelab --timeout=180s
```
**Result:** Ready after 33s. PVCs `jellyfin-media-pvc` and `jellyfin-config-pvc` transitioned from `Pending` → `Bound` when pod was scheduled (as expected with `WaitForFirstConsumer`).

```bash
kubectl port-forward svc/jellyfin 8096:8096 -n homelab &
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://localhost:8096/health
curl -s http://localhost:8096/System/Info/Public
```
**Result:**
- HTTP 200 from `/health`
- Public info: `Version: 10.11.8`, `StartupWizardCompleted: false` — ready for browser-based first-time setup

---

## Step 7 — Deploy Immich

### 7a. Add chart, discover bundled-Postgres absence

```bash
helm repo add immich https://immich-app.github.io/immich-charts
helm repo update immich
helm search repo immich --versions
```
**Result:** Latest 0.12.0; tried `helm pull` → **404** on GitHub release tarball. Upstream artifact missing. Fell back to 0.11.1 (same appVersion v2.6.3).

```bash
curl -sL -o /tmp/immich-0.11.1.tgz "https://github.com/immich-app/immich-charts/releases/download/immich-0.11.1/immich-0.11.1.tgz"
cd /tmp && tar xzf immich-0.11.1.tgz
cat /tmp/immich/values.yaml
```
**Finding:** Chart includes ONLY server, machine-learning, valkey. NO Postgres. Comment says: "Add the env vars to connect to your database here."

### 7b. Deploy Postgres separately

Wrote `~/homelab/immich-postgres.yaml` with:
- Secret `immich-postgres-secret` (DB/USER/PASSWORD)
- PVC `immich-postgres-pvc` on `local-path` StorageClass (NOT on HDD — exFAT incompatible)
- StatefulSet running `ghcr.io/immich-app/postgres:17-vectorchord0.4.3-pgvector0.8.0` (Immich's own image with pgvector + vectorchord)
- Headless Service on port 5432

```bash
kubectl apply -f ~/homelab/immich-postgres.yaml
kubectl wait --for=condition=ready pod -l app=immich-postgres -n homelab --timeout=180s
kubectl logs -n homelab immich-postgres-0 --tail=15
```
**Result:** Pod ready in 34s. Postgres 17.6 listening on 5432.

### 7c. Install Immich chart

Wrote `~/homelab/immich-values.yaml` with:
- `controllers.main.containers.main.env` for DB_* envs (reading user/password from the postgres secret via `valueFrom.secretKeyRef`)
- `immich.persistence.library.existingClaim: immich-upload-pvc`
- `valkey.enabled: true`
- `server.enabled: true`, `machine-learning.enabled: true`
- No ingress

```bash
helm install immich /tmp/immich --namespace homelab --values ~/homelab/immich-values.yaml
kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=immich -n homelab --timeout=300s
```
**Result:** All 3 pods ready: `immich-server`, `immich-machine-learning`, `immich-valkey`. Used **`instance` label** for wait — `name` label doesn't span the subcharts.

```bash
kubectl port-forward svc/immich-server 2283:2283 -n homelab &
curl -s http://localhost:2283/api/server/ping
```
**Result:** `{"res":"pong"}` — Immich healthy.

---

## Step 8 — Tailscale + port-forward + launchd

```bash
which tailscale && tailscale --version
```
**Result:** CLI 1.94.2 installed via brew, but daemon not running. `tailscale status` failed.

```bash
ls /Applications/ | grep -i tailscale
```
**Result:** `Tailscale.app` present — user already had GUI version. CLI inside app at `/Applications/Tailscale.app/Contents/MacOS/Tailscale`.

```bash
open -a Tailscale
/Applications/Tailscale.app/Contents/MacOS/Tailscale up
/Applications/Tailscale.app/Contents/MacOS/Tailscale status
/Applications/Tailscale.app/Contents/MacOS/Tailscale ip -4
```
**Result:** Tailnet `seenimurugan@`. This Mac IP: **100.66.97.57**. Other devices (iphone, office linux) visible but offline.

### Port-forward script + launchd

Wrote `~/homelab/tailscale-portforward.sh` — runs two `kubectl port-forward --address 0.0.0.0` (Jellyfin 8096, Immich 2283) in foreground with trap for clean shutdown.

Wrote `~/Library/LaunchAgents/com.nila.homelab-portforward.plist` with:
- `RunAtLoad: true`, `KeepAlive: true` (auto-restart on crash)
- `EnvironmentVariables.PATH = /opt/homebrew/bin:...` (otherwise kubectl not found)
- `EnvironmentVariables.KUBECONFIG = /Users/nila/.kube/config`
- Logs to `~/homelab/portforward.{out,err}.log`

```bash
chmod +x ~/homelab/tailscale-portforward.sh
launchctl load ~/Library/LaunchAgents/com.nila.homelab-portforward.plist
launchctl list | grep homelab
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://100.66.97.57:8096/health
curl -s http://100.66.97.57:2283/api/server/ping
```
**Result:**
- launchd job PID 13911, RunningOK
- Jellyfin via Tailscale IP: HTTP 200
- Immich via Tailscale IP: HTTP 200, `{"res":"pong"}`

**Done with Pattern A.** All services reachable on `http://100.66.97.57:{8096,2283}` from any device on the Tailnet.

---

## Step 9 — Migration: Pattern A → Pattern B (Tailscale in-cluster)

### 9a. Tailscale prep (manual, by user)
- ACL policy edited at https://login.tailscale.com/admin/acls/file:
  ```json
  "tagOwners": { "tag:k8s-operator": [], "tag:k8s": ["tag:k8s-operator"] }
  ```
- OAuth client created at https://login.tailscale.com/admin/settings/oauth with scopes `Devices Core Write` + `Auth Keys Write`, tag `tag:k8s-operator`.
- HTTPS Certificates already enabled at https://login.tailscale.com/admin/dns.

### 9b. Install Tailscale operator

```bash
helm repo add tailscale https://pkgs.tailscale.com/helmcharts
helm repo update tailscale
helm install tailscale-operator tailscale/tailscale-operator \
  --namespace tailscale --create-namespace \
  --set-string oauth.clientId='<ID>' \
  --set-string oauth.clientSecret='<SECRET>' \
  --set apiServerProxyConfig.mode=true
kubectl wait --for=condition=ready pod -l app=operator -n tailscale --timeout=120s
```
**Result:** Operator pod ready. `tailscale-operator` joined tailnet as a `tagged-devices` node.

### 9c. First attempt: LoadBalancer with tailscale class

```bash
kubectl patch svc jellyfin -n homelab --type=merge -p '{"spec":{"type":"LoadBalancer","loadBalancerClass":"tailscale"}}'
kubectl patch svc immich-server -n homelab --type=merge -p '{"spec":{"type":"LoadBalancer","loadBalancerClass":"tailscale"}}'
```
**Result:** Got hostnames `homelab-jellyfin.stoat-perch.ts.net` and `homelab-immich-server.stoat-perch.ts.net`. Worked, but URLs had ports (`:8096`, `:2283`). User asked for cleaner URLs.

### 9d. Switched to Tailscale Ingress for HTTPS

Reverted Services to ClusterIP:
```bash
kubectl patch svc jellyfin -n homelab --type=json \
  -p='[{"op":"remove","path":"/spec/loadBalancerClass"},{"op":"replace","path":"/spec/type","value":"ClusterIP"}]'
kubectl patch svc immich-server -n homelab --type=json \
  -p='[{"op":"remove","path":"/spec/loadBalancerClass"},{"op":"replace","path":"/spec/type","value":"ClusterIP"}]'
```

Created `~/homelab/ingress.yaml` with two Ingress resources, `ingressClassName: tailscale`, hosts `jellyfin` and `immich`, `defaultBackend` pointing at the cluster services.

```bash
kubectl apply -f ~/homelab/ingress.yaml
```
**Result after ~30s:**
- `https://jellyfin.stoat-perch.ts.net` → HTTP 200, valid TLS cert
- `https://immich.stoat-perch.ts.net` → HTTP 200, valid TLS cert

### 9e. Cleanup: remove all Mac-side Tailscale

```bash
launchctl unload ~/Library/LaunchAgents/com.nila.homelab-portforward.plist
rm -f ~/Library/LaunchAgents/com.nila.homelab-portforward.plist
brew uninstall tailscale       # the CLI-only brew install
# User dragged /Applications/Tailscale.app to Trash via Finder — triggered system extension removal
sudo rm -f /usr/local/bin/tailscale   # leftover CLI symlink from in-app installer
```

**Result:** All Tailscale removed from Mac. System extension marked `terminated waiting to uninstall on reboot` — fully gone after next reboot. Mac is no longer on tailnet; cluster nodes (`tailscale-operator`, `homelab-jellyfin` proxy pods, `homelab-immich-server` proxy pods) are the only homelab presence on the tailnet.

Also removed standalone Mac Jellyfin.app (redundant — cluster serves it now).

**End state (Pattern B):**
- Cluster services reachable at `https://jellyfin.stoat-perch.ts.net` and `https://immich.stoat-perch.ts.net` from any device on the tailnet.
- Mac is no longer a hop. Cluster pods join the tailnet directly via the operator.






