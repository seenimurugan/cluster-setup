# Add a new app to the homelab cluster

Generic runbook for deploying any new app to the cluster — pre-built (Grocy, Linkwarden, Paperless, your own image, etc.) or your own code written in any language.

The end result: app accessible at `https://<name>.stoat-perch.ts.net` from any Tailscale device, optionally at `http://localhost:<port>` from this Mac and `http://192.168.68.57:<port>` on the LAN.

**On this page:** [When to use each pattern](#when-to-use-each-pattern) · [§1 — Deploy a pre-built image (simplest)](#1--deploy-a-pre-built-image-simplest) · [§2 — Deploy your own code (Java/Python/Node/Go/…)](#2--deploy-your-own-code-javapythonnodego) · [§3 — Add a database for the app](#3--add-a-database-for-the-app) · [§4 — Tailscale Ingress (HTTPS from any device on your tailnet)](#4--tailscale-ingress-https-from-any-device-on-your-tailnet) · [§5 — LAN + localhost access (optional)](#5--lan-+-localhost-access-optional) · [§6 — Test, then add to docs](#6--test-then-add-to-docs) · [§6b — Monitoring (logs & metrics)](#6b--monitoring-logs--metrics) · [§7 — Updating an app to a newer version](#7--updating-an-app-to-a-newer-version) · [§8 — Removing an app](#8--removing-an-app) · [Worked example: deploying Grocy (inventory app)](#worked-example-deploying-grocy-inventory-app)

---

## When to use each pattern

| Your situation | Skip to |
|---|---|
| There's already a Docker image for the app (most OSS apps) | §1 — Deploy a pre-built image |
| You wrote the app yourself (Java/Python/Go/Node/…) | §2 — Build, push, then deploy |
| You want a database too (Postgres/MySQL) | §3 — Add a database for the app |
| You want it accessible from your phone via Tailscale | §4 — Add Tailscale Ingress |
| You want it accessible on the LAN (TV, other laptops) | §5 — Add to launchd port-forward |

---

## §1 — Deploy a pre-built image (simplest)

Most OSS apps publish a Docker image. You just need to:

1. Pick image name (from Docker Hub / GHCR / lscr.io)
2. Decide what storage it needs
3. Write 3 small YAML files (Deployment + Service + Ingress)
4. `kubectl apply`

### Template — copy and edit

Save as `~/homelab/<app>-server.yaml`:

```yaml
# Replace <app>, <image>, <containerPort>, <storageSize> below.
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: <app>-data-pvc
  namespace: homelab
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path    # VM-internal ext4. Safe for DBs & app state.
  resources:
    requests:
      storage: <storageSize>      # e.g., 5Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: <app>
  namespace: homelab
spec:
  replicas: 1
  selector:
    matchLabels:
      app: <app>
  strategy:
    type: Recreate    # safe with RWO storage (only 1 pod can mount at a time)
  template:
    metadata:
      labels:
        app: <app>
    spec:
      containers:
        - name: <app>
          image: <image>          # e.g., lscr.io/linuxserver/grocy:latest
          ports:
            - containerPort: <containerPort>
              name: http
          env:
            - name: TZ
              value: "Europe/London"
            # Add app-specific env vars here
          volumeMounts:
            - name: data
              mountPath: /config   # check the image's docs for actual path
          resources:
            requests:
              memory: "128Mi"
              cpu: "50m"
            limits:
              memory: "1Gi"
              cpu: "2"
          # Generous probe timeouts — see learnings.md about 1s defaults
          startupProbe:
            tcpSocket:
              port: <containerPort>
            initialDelaySeconds: 15
            periodSeconds: 15
            timeoutSeconds: 15
            failureThreshold: 40
          livenessProbe:
            tcpSocket:
              port: <containerPort>
            initialDelaySeconds: 60
            periodSeconds: 60
            timeoutSeconds: 15
            failureThreshold: 5
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: <app>-data-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: <app>
  namespace: homelab
spec:
  type: ClusterIP
  selector:
    app: <app>
  ports:
    - port: <containerPort>
      targetPort: http
      name: http
---
# Tailscale HTTPS Ingress — accessible from any tailnet device
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: <app>
  namespace: homelab
spec:
  ingressClassName: tailscale
  defaultBackend:
    service:
      name: <app>
      port:
        number: <containerPort>
  tls:
    - hosts:
        - <app>   # subdomain — operator appends .<tailnet>.ts.net
```

### Apply

```bash
kubectl apply -f ~/homelab/<app>-server.yaml
kubectl rollout status deployment/<app> -n homelab --timeout=180s
kubectl get pods -n homelab -l app=<app>
```

### Verify

```bash
# Cluster DNS (this Mac, no port-forward)
curl -s -o /dev/null -w "%{http_code}\n" http://<app>.homelab.svc.cluster.local:<containerPort>/

# Tailscale URL (from your phone or any tailnet device)
# https://<app>.stoat-perch.ts.net
```

Wait ~30 seconds after applying — the Tailscale operator needs to provision an Ingress proxy pod and join it to the tailnet.

### Snapshot the config

```bash
cp ~/homelab/<app>-server.yaml /Users/nila/Developer/agents/docs/homelab-k8s-setup/configs/
```

---

## §2 — Deploy your own code (Java/Python/Node/Go/…)

Same end-state as §1, but with an extra "containerize and publish" step at the start.

### 2a. Containerize your app

Create a `Dockerfile` next to your source code. Examples:

**Java Spring Boot:**
```dockerfile
FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
COPY target/myapp-*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
```

**Python / FastAPI:**
```dockerfile
FROM python:3.13-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

**Node / Next.js:**
```dockerfile
FROM node:24-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev
COPY . .
RUN npm run build
EXPOSE 3000
CMD ["npm", "start"]
```

**Go:**
```dockerfile
FROM golang:1.24 AS build
WORKDIR /src
COPY . .
RUN go build -o /app .
FROM gcr.io/distroless/static
COPY --from=build /app /app
EXPOSE 8080
ENTRYPOINT ["/app"]
```

Build for the cluster's architecture (arm64 on Apple Silicon):
```bash
docker build --platform linux/arm64 -t mywebapp:0.1 .
```

### 2b. Get the image to the cluster

Three options, easiest first:

**Option A — Local image (no registry)**: OrbStack's k3s can use images that exist on the Mac's Docker. Just build and reference it by name. Add `imagePullPolicy: Never` to the container spec so k8s doesn't try to pull from a registry.

```yaml
containers:
  - name: mywebapp
    image: mywebapp:0.1   # local image, must exist via `docker images`
    imagePullPolicy: Never
```

**Option B — GitHub Container Registry (free, public or private)**:
```bash
# Tag and push
docker tag mywebapp:0.1 ghcr.io/<your-github-user>/mywebapp:0.1
echo "$GHCR_TOKEN" | docker login ghcr.io -u <your-github-user> --password-stdin
docker push ghcr.io/<your-github-user>/mywebapp:0.1
```

Then in the YAML: `image: ghcr.io/<your-github-user>/mywebapp:0.1`. For private images, create a Secret of type `kubernetes.io/dockerconfigjson` and reference it with `imagePullSecrets`.

**Option C — In-cluster registry**: overkill for a homelab; skip.

### 2c. Deploy with the §1 template

Use the same YAML template from §1, just plug in your image and port.

---

## §3 — Add a database for the app

Most apps need data persistence. Options:

- **SQLite** (file inside the data PVC) — easiest, no separate DB pod. Pattern: app writes to `/config/db.sqlite` on its PVC. Used by Grocy, Linkwarden, many others.
- **PostgreSQL** (separate StatefulSet) — needed by Immich-like apps with heavy queries. See `~/homelab/immich-postgres.yaml` as a template.

For a Postgres pattern, the structure is:
1. Secret with `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`
2. PVC on `local-path` (NEVER on exFAT HDD — see learnings)
3. StatefulSet running the postgres image
4. Headless Service on port 5432
5. App's env vars point at `<dbhost>.homelab.svc.cluster.local:5432`

Copy `immich-postgres.yaml`, rename, change creds + storage size, apply.

---

## §4 — Tailscale Ingress (HTTPS from any device on your tailnet)

Already included in §1 template, but the rules:

- `metadata.name`: anything — the resulting hostname uses the host in `rules` (or `tls.hosts` if no rules)
- `spec.ingressClassName: tailscale` is what triggers the operator
- `spec.tls[].hosts[]` — list of subdomains. The operator appends `.<tailnet>.ts.net`. Use `[mywebapp]` → URL becomes `https://mywebapp.stoat-perch.ts.net`
- Wait ~30s after applying — proxy pod must mint an auth key and join the tailnet
- Check status: `kubectl get ingress <app> -n homelab` (ADDRESS column shows the full hostname)

### Multi-path routing (advanced)

Default template uses `defaultBackend` — all traffic goes to one service. For path-based routing (e.g., `/api` to backend, `/` to frontend):
```yaml
spec:
  ingressClassName: tailscale
  rules:
    - host: mywebapp
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service: { name: mywebapp-api, port: { number: 8080 } }
          - path: /
            pathType: Prefix
            backend:
              service: { name: mywebapp-ui, port: { number: 3000 } }
  tls: [{ hosts: [mywebapp] }]
```

---

## §5 — LAN + localhost access (optional)

If you want `http://localhost:<port>` from this Mac and `http://192.168.68.57:<port>` from LAN devices, add the app to the launchd port-forward script.

Edit `~/homelab/localhost-portforward.sh` and add a `kubectl port-forward` line:

```bash
kubectl port-forward svc/<app> <localPort>:<containerPort> -n homelab --address 0.0.0.0 &
APP_PID=$!

# Update the trap line to include APP_PID
trap 'echo "[homelab] Stopping..."; kill $J $I $D $APP_PID 2>/dev/null; exit 0' INT TERM
```

Then reload:
```bash
~/homelab/refresh-localhost.sh
```

Pick a `<localPort>` that isn't already taken (8096 jellyfin, 2283 immich, 8090 docs).

---

## §6 — Test, then add to docs

1. Test:
   ```bash
   # From cluster DNS (works on Mac always)
   curl http://<app>.homelab.svc.cluster.local:<port>/

   # From Tailscale (works on phone)
   # https://<app>.stoat-perch.ts.net

   # From LAN (works on TV)
   # http://192.168.68.57:<localPort>
   ```

2. Snapshot config to docs:
   ```bash
   cp ~/homelab/<app>-server.yaml /Users/nila/Developer/agents/docs/homelab-k8s-setup/configs/
   ```

3. Add the new app's URL to the **"Reach the services"** table in `MAINTENANCE.md`.

4. Add a sidebar entry in `_sidebar.md` pointing to a notes page about the app if you want.

---

## §6b — Monitoring (logs & metrics)

Logs and pod-level metrics are picked up **automatically**, no action needed — confirm at https://grafana.stoat-perch.ts.net → Explore (Loki datasource, `app="<your-app>"`).

If your app exposes its own Prometheus metrics endpoint (e.g. Spring Boot Actuator at `/actuator/prometheus`, FastAPI via `prometheus_fastapi_instrumentator`), opt it in once with a ServiceMonitor:

```bash
cp ~/homelab/monitoring/servicemonitor-template.yaml ~/homelab/<app>-servicemonitor.yaml
# Edit: replace <app>, <port-name>, <path>
kubectl apply -f ~/homelab/<app>-servicemonitor.yaml
```

See [Monitoring docs](apps/monitoring/README.md) for the full pattern.

---

## §7 — Updating an app to a newer version

```bash
# Bump just the image tag — no helm needed
kubectl set image deployment/<app> -n homelab <app>=<new-image>:<new-tag>

# Watch
kubectl rollout status deployment/<app> -n homelab

# If it breaks, roll back
kubectl rollout undo deployment/<app> -n homelab
```

For apps with database migrations (Immich, etc.), **backup first** — see `IMMICH-UPGRADE.md` for the pattern.

---

## §8 — Removing an app

```bash
# Delete the resources
kubectl delete -f ~/homelab/<app>-server.yaml

# Or just delete by name
kubectl delete deployment,service,ingress,pvc -l app=<app> -n homelab

# Tailscale operator removes the proxy pod and the .ts.net hostname automatically
```

---

## Worked example: deploying Grocy (inventory app)

The household inventory app deployed at `https://grocy.stoat-perch.ts.net`. See **`~/homelab/grocy-server.yaml`** for the actual config that followed this runbook. Walks through:

- Pre-built image: `lscr.io/linuxserver/grocy:latest`
- SQLite database (no separate Postgres needed — Grocy uses one file)
- 5Gi PVC for `/config`
- Tailscale Ingress for HTTPS

This is the recommended pattern for OSS apps. For custom-built code, follow §2 instead.
