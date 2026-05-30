# Homelab architecture — mental model

The Excalidraw diagram is at `architecture.excalidraw`. Open it at https://excalidraw.com (drag the file in) or in the Excalidraw desktop app.

This doc walks through every box and arrow so the diagram makes sense without me explaining over your shoulder.

---

## The big picture

Everything runs on **one MacBook Pro**. Inside that Mac, a Linux VM (managed by OrbStack) runs a Kubernetes cluster (k3s). Inside that cluster, two apps live: **Jellyfin** (movies) and **Immich** (photos). Their live data lives **inside the OrbStack VM's own ext4 disk** (a sparse file on the Mac's internal APFS SSD). The external HDD is **backup-only** since the 2026-05-27 migration — see `learnings.md` for why.

Two ways to reach the apps:

1. **From phone/TV/family** → over the internet via Tailscale → straight to the cluster.
2. **From this Mac's own browser** → through a local port-forward to the cluster.

The Mac is the only physical device involved. Everything else is software on it.

---

## Layers (outside → in)

```
  External devices (phone, TV, family)
        │
        ▼  Tailscale (encrypted mesh VPN, internet)
        │
  ┌─────────────────── Mac (this laptop) ────────────────────┐
  │                                                          │
  │   Internal SSD (APFS, 1.8 TiB)                           │
  │     └── OrbStack VM disk (sparse ext4 image)             │
  │           └── live data: Immich + Jellyfin + Postgres    │
  │                                                          │
  │   External HDD (exFAT, 4 TB)                             │
  │   /Volumes/Seeni's HDD/                                  │
  │     ├── backups/   ← weekly tar.zst dumps                │
  │     └── personal media (drone footage, iPhone backups)   │
  │                                                          │
  │   ┌──────────── OrbStack (Linux VM) ──────────────────┐  │
  │   │                                                   │  │
  │   │   ┌────────── k3s cluster ─────────────────────┐  │  │
  │   │   │                                            │  │  │
  │   │   │  namespace: homelab                        │  │  │
  │   │   │    • Jellyfin (pod + service + ingress)    │  │  │
  │   │   │    • Immich   (4 pods + service + ingress) │  │  │
  │   │   │                                            │  │  │
  │   │   │  namespace: tailscale                      │  │  │
  │   │   │    • Operator                              │  │  │
  │   │   │    • ts-jellyfin proxy (own Tailnet IP)    │  │  │
  │   │   │    • ts-immich proxy   (own Tailnet IP)    │  │  │
  │   │   │                                            │  │  │
  │   │   └────────────────────────────────────────────┘  │  │
  │   └───────────────────────────────────────────────────┘  │
  │                                                          │
  │   launchd ─── kubectl port-forward 127.0.0.1:{8096,2283} │
  │                                                          │
  └──────────────────────────────────────────────────────────┘
```

---

## What each box does

### The Mac (outer container)
Your physical MacBook Pro. Boots macOS, runs OrbStack, holds the HDD. Everything else lives inside it. If the Mac is asleep / powered off, nothing works.

### External HDD (`/Volumes/Seeni's HDD`)
A 4 TB exFAT drive plugged into the Mac. After the 2026-05-27 migration it is **backup-only**, not live storage. The HDD holds:
- `backups/` — weekly `tar.zst` dumps of Immich library + Jellyfin media + Postgres
- Personal media (drone footage, iPhone backups, photo collections) — untouched, not consumed by the cluster

The cluster apps do **not** mount this drive anymore. Why we moved off it: exFAT-via-virtiofs caused recurring `ENFILE` errors in Immich because Apple's virtiofs holds a host file descriptor per accessed inode, and Immich's deep upload-shard tree exhausted macOS's per-process FD limit on the OrbStack `vmgr`. Full root-cause writeup in `learnings.md`.

### Internal SSD (where live data now lives)
The MacBook's internal SSD is APFS. The OrbStack VM stores its entire Linux disk as a single sparse file on APFS (`~/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data/data.img.raw`, logical 8 TB / physical only what's used). Inside that file Linux owns its own ext4 filesystem. Every app PVC backed by `local-path` storage class lives inside that ext4 — **never crosses the virtiofs boundary**, so the FD accumulation problem doesn't exist.

### OrbStack (Linux VM)
A tiny Linux VM running on the Mac that hosts containers and k3s. Think of it as "Docker Desktop but better, faster, and with k8s included." It bridges the Mac filesystem into the VM — that's how pods inside the cluster can read `/Volumes/Seeni's HDD/...` via `hostPath` volumes.

### k3s cluster
A lightweight Kubernetes distribution running inside the VM. Out of the box, OrbStack's k3s gives you:
- **CoreDNS** for in-cluster DNS
- **local-path-provisioner** — default StorageClass `local-path` that writes inside the VM (ext4, safe for databases)

It does NOT include Traefik (unlike upstream k3s). That's why we use Tailscale Ingress, not Traefik Ingress.

### namespace `homelab` — where the actual apps live

**Jellyfin block (green):**
- `Pod: jellyfin` — the actual Jellyfin server process, listening on 8096.
- `Service: jellyfin (ClusterIP:8096)` — stable in-cluster network address that routes to the pod. Other things refer to "jellyfin" rather than the pod's churning IP.
- `Ingress: jellyfin` — declares "I want this service exposed externally via Tailscale, as host `jellyfin`." The Tailscale operator (in the other namespace) sees this and creates the proxy pod.
- PVCs: `jellyfin-config-localpath-pvc` (5 Gi) and `jellyfin-media-localpath-pvc` (200 Gi) — both `local-path` (inside the VM's ext4). Movies and shows live inside the OrbStack VM disk, not on the HDD anymore.

**Immich block (pink):**
- `immich-server` pod — the main API and web UI on port 2283.
- `immich-machine-learning` pod — runs face/object recognition models.
- `immich-valkey` pod — Redis-compatible queue (Valkey is a fork).
- `immich-postgres` StatefulSet — the database. PVC on `local-path` (inside VM ext4).
- PVC `immich-upload-localpath-pvc` (500 Gi) — Immich's photo library. Also on `local-path` (inside VM ext4), so the upload shard tree never crosses virtiofs.
- `Service: immich-server (ClusterIP:2283)` — same idea as Jellyfin's service.
- `Ingress: immich` — same idea, exposes via Tailscale as host `immich`.

### namespace `tailscale` — the proxy infrastructure

- **Operator** — watches Ingress objects with `ingressClassName: tailscale`. When it sees one, it mints a new Tailscale auth key from your OAuth credentials and spawns a proxy pod for that Ingress. Authenticated via OAuth Secret `operator-oauth`.
- **`ts-jellyfin` proxy** — a tiny pod that runs Tailscale inside itself. It joins your tailnet as a new device called `jellyfin.<your-tailnet>.ts.net`, gets an auto-issued TLS cert from Tailscale, terminates HTTPS, and forwards plaintext HTTP to the in-cluster `jellyfin` Service.
- **`ts-immich` proxy** — same, for `immich.<your-tailnet>.ts.net`.

So each Ingress gets its own dedicated Tailscale node. From the tailnet's perspective, they look like separate machines.

### launchd port-forward (Mac-local)
A macOS launchd job (`com.nila.homelab-localhost`) that runs `kubectl port-forward` for each service, bound to `127.0.0.1` only (NOT exposed to LAN or Tailscale — the Tailscale operator handles that). Auto-starts on login, restarts if it crashes. This is what makes `http://localhost:8096` work from the Mac's own browser.

---

## The two access paths

### Path 1 — Remote (phone, TV, family)

```
Phone → Tailscale (encrypted, over internet)
      → ts-jellyfin proxy (joined as jellyfin.<tailnet>.ts.net)
      → jellyfin Service (ClusterIP)
      → jellyfin Pod
```

The phone never knows there's a cluster underneath. From its perspective, it's hitting `https://jellyfin.stoat-perch.ts.net` and getting Jellyfin's web UI back. The Mac isn't even in the path on the network layer — Tailscale routes peer-to-peer where possible.

URLs:
- `https://jellyfin.stoat-perch.ts.net`
- `https://immich.stoat-perch.ts.net`

These resolve only on devices that are themselves on your tailnet (your phone, TV, etc. — not random people on the internet).

### Path 2 — Local (this Mac)

```
Mac browser → http://localhost:8096
            → launchd-managed kubectl port-forward
            → jellyfin Service
            → jellyfin Pod
```

`kubectl port-forward` opens a TCP tunnel from the Mac to the in-cluster Service. The Mac doesn't need Tailscale for this — it's just a process talking to OrbStack's VM. Fast, local, no certs needed.

URLs:
- `http://localhost:8096`
- `http://localhost:2283`

---

## The storage strategy (post-2026-05-27 migration)

| What | StorageClass | Where it physically lives | Why |
|---|---|---|---|
| Jellyfin media | `local-path` | OrbStack VM ext4 (on internal SSD APFS) | exFAT+virtiofs FD bug; ext4-in-VM bypasses it |
| Jellyfin config | `local-path` | same | same |
| Immich photo library (`/data`) | `local-path` | same | this is where the ENFILE bug used to live; now POSIX-safe |
| Immich Postgres | `local-path` | same | DB needs POSIX semantics anyway |
| Immich Valkey/Redis | emptyDir | RAM-ish | Just a queue, can rebuild if lost |
| Immich ML cache | emptyDir | RAM-ish | Re-downloads models if lost |
| Weekly backups | hostPath (write-only) | HDD `/Volumes/Seeni's HDD/backups/` | Single `tar.zst` files; one inode per backup avoids virtiofs FD explosion |

**Now: blast radius.** Everything lives inside *one* sparse file on APFS (the OrbStack VM disk). If that file gets corrupted (bad shutdown, full disk, OrbStack bug), all apps lose data simultaneously. The weekly backup CronJob/LaunchAgent (`configs/backup-immich.sh`, runs Sun 03:00) is therefore load-bearing — not optional. Backups are written as single compressed tar files to the HDD so they don't re-trigger the virtiofs FD bug.

**If you ever `orbctl reset`** the OrbStack VM, you wipe Immich + Jellyfin + Postgres in one shot. Restore from the latest `tar.zst` on the HDD plus the matching Postgres dump.

---

## The control plane (color: purple dashed arrows in diagram)

The Tailscale operator manages the proxy pods. When you create or delete an Ingress in the `homelab` namespace:

1. Operator notices the change
2. Mints a new Tailscale auth key via the OAuth client
3. Creates/deletes the corresponding `ts-*` proxy pod
4. The proxy pod joins (or leaves) the tailnet using that key

OAuth credentials live in Secret `operator-oauth`. They were rotated once during setup (the originals were pasted in chat — bad idea — so we generated fresh ones and revoked the old).

---

## What's NOT in this diagram (intentionally)

- **CNI / pod networking** — the cluster uses k3s's default flannel; arrows would just clutter without adding insight.
- **CoreDNS** — works invisibly to resolve `jellyfin.homelab.svc.cluster.local` etc.
- **OrbStack internals** — the VM, hypervisor, file-passthrough plumbing — abstracted as one OrbStack box.
- **Tailscale's own infrastructure** — the coordination server etc. — abstracted as the "Tailnet cloud."
- **TV/phone OS-level networking** — abstracted as "Tailscale on."

If any of those become a debugging target, we'll draw them in.

---

## How to extend the diagram

Open `architecture.excalidraw` in https://excalidraw.com, drag boxes around, add new services, save back. The colors used:

- Mac container: light gray `#f3f4f6`
- HDD: blue `#dbeafe`
- OrbStack VM: yellow `#fef3c7`
- k3s cluster: indigo `#e0e7ff`
- Namespaces: white with colored borders
- Jellyfin: green `#dcfce7`
- Immich: pink `#fce7f3`
- Tailscale proxies: purple `#ede9fe`
- External devices: orange `#fed7aa`
- Tailnet cloud: cyan `#cffafe`
- launchd: pale yellow `#fef9c3`

Arrow colors:
- Blue `#1971c2` — user data flow (HTTPS)
- Orange `#e8590c` — localhost access path
- Green dashed `#2f9e44` — storage (hostPath)
- Purple dashed `#9c36b5` — operator → proxy control
