# Helm Value Patches — Tiered Storage HDD Mounts

These patches add the new HFS+ HDD (`/Volumes/homelab-hdd`) as a read/write
volume into the Immich server and Jellyfin pods. The symlinks created by the
tiered-storage-mover CronJob point to paths inside these pods (e.g.
`/data-hdd/library/foo.jpg`), so the pods must have these mounts or Immich
and Jellyfin will get broken symlinks.

**Do not apply until the HDD is formatted, mounted, and subdirectories exist.**
See `hdd-prep.md` for that step.

---

## Immich — `~/homelab/immich-values.yaml`

The Immich chart uses the [bjw-s common library](https://bjw-s-labs.github.io/helm-charts/).
Extra volumes for the `immich-server` Deployment are added via
`server.persistence.<name>` entries.

### What to add

Insert the following block at the **top level of `immich-values.yaml`** (or
merge with the existing `server:` key if one already exists):

```yaml
# HDD mount for tiered storage — Immich server gets /data-hdd
# pointing at /Volumes/homelab-hdd/immich-library on the host.
# type: "" required — do NOT use DirectoryOrCreate on HDD hostPaths
# (see learnings: OrbStack HDD mount fd limit).
server:
  persistence:
    hdd:
      enabled: true
      type: hostPath
      hostPath: /Volumes/homelab-hdd/immich-library
      hostPathType: ""
      globalMounts:
        - path: /data-hdd
```

**Context:** The `server:` key already exists in the file (controls probes).
Merge the `persistence:` block under it — do not add a second `server:` key.
The resulting `server:` section should look like:

```yaml
server:
  enabled: true
  controllers:
    main:
      containers:
        main:
          probes:
            # ... existing probe config ...
  persistence:
    hdd:
      enabled: true
      type: hostPath
      hostPath: /Volumes/homelab-hdd/immich-library
      hostPathType: ""
      globalMounts:
        - path: /data-hdd
```

### Verification — rendered template

After patching, run:

```bash
helm template immich immich/immich --version 0.11.1 \
  -f ~/homelab/immich-values.yaml -n homelab \
  | grep -A8 "name: hdd"
```

Expected output inside the Deployment:

```yaml
volumeMounts:
  - mountPath: /data-hdd
    name: hdd
volumes:
  - hostPath:
      path: /Volumes/homelab-hdd/immich-library
    name: hdd
```

Note: the `hostPath.type` field is omitted by the bjw-s renderer when
`hostPathType: ""` — this is correct; an absent `type` field defaults to `""`
at the Kubernetes API level.

---

## Jellyfin — `~/homelab/jellyfin-values.yaml`

The `jellyfin/jellyfin` chart exposes `volumes:` and `volumeMounts:` as
top-level values arrays (documented in `helm show values jellyfin/jellyfin`).

### What to add

Replace the existing (empty) `volumes: []` and `volumeMounts: []` lines, or
add the following if they are absent:

```yaml
# HDD mount for tiered storage — Jellyfin gets /media-hdd
# pointing at /Volumes/homelab-hdd/jellyfin-media on the host.
# type: "" required — do NOT use DirectoryOrCreate on HDD hostPaths
# (see learnings: OrbStack HDD mount fd limit).
volumes:
  - name: media-hdd
    hostPath:
      path: /Volumes/homelab-hdd/jellyfin-media
      type: ""

volumeMounts:
  - name: media-hdd
    mountPath: /media-hdd
```

### Verification — rendered template

```bash
helm template jellyfin jellyfin/jellyfin --version 3.2.0 \
  -f ~/homelab/jellyfin-values.yaml -n homelab \
  | grep -A6 "media-hdd"
```

Expected:

```yaml
volumeMounts:
  - mountPath: /media-hdd
    name: media-hdd
volumes:
  - hostPath:
      path: /Volumes/homelab-hdd/jellyfin-media
      type: ""
    name: media-hdd
```

---

## Helm Upgrade Commands

After editing both values files, upgrade both releases:

```bash
# Immich
helm upgrade immich immich/immich \
  --version 0.11.1 \
  --namespace homelab \
  -f ~/homelab/immich-values.yaml \
  --wait --timeout 5m

# Jellyfin
helm upgrade jellyfin jellyfin/jellyfin \
  --version 3.2.0 \
  --namespace homelab \
  -f ~/homelab/jellyfin-values.yaml \
  --wait --timeout 3m
```

The `--wait` flag blocks until the new pod is Ready, so you know the HDD mount
came up cleanly before proceeding to apply the CronJob.

---

## Caveats

- `hostPathType: ""` / `type: ""` means Kubernetes will NOT pre-check whether
  the host directory exists. The pod will start successfully even if the HDD
  is unmounted. If Immich or Jellyfin writes a real file to `/data-hdd` while
  the HDD is absent, that directory is created inside the OrbStack VM — which
  would silently shadow the HDD mount when it comes back. Always verify the
  HDD is mounted before starting the pods (see `deploy.md`).

- If the HDD is unmounted mid-session, symlinked files will return `ENOENT` to
  the app. Immich will show "error loading image"; Jellyfin will show
  "file not found". Remounting the HDD and waiting for pod readiness resolves
  it without restart.
