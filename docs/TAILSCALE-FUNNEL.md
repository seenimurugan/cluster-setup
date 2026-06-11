# Tailscale Funnel — homelab guide

How this homelab exposes services to the public internet via Tailscale Funnel, what the differences are between Serve and Funnel, and how to add or remove a Funnel'd app safely.

**On this page:** [Serve vs Funnel](#serve-vs-funnel) · [How it's wired here](#how-its-wired-here) · [One-time setup](#one-time-setup) · [Funnel a new app](#funnel-a-new-app) · [Verify public reach](#verify-public-reach) · [Troubleshooting](#troubleshooting) · [Limits & security](#limits--security) · [Current Funnel'd apps](#current-funneld-apps)

---

## Serve vs Funnel

| | Tailscale Serve | Tailscale Funnel |
|---|---|---|
| Who can reach it | Devices on **your tailnet only** | **Anyone on the internet** |
| Auth required | Your Tailscale identity | None — public URL |
| URL | `https://<host>.stoat-perch.ts.net` | Same URL, reachable off-tailnet |
| How to enable | Default for all Tailscale Ingresses | Add the `tailscale.com/funnel: "true"` annotation |
| Ports | Any (operator uses 443 internally) | 443 / 8443 / 10000 only |
| Transport | Direct Tailscale WireGuard | Relayed via Tailscale DERP servers |

In practice: every Ingress with `ingressClassName: tailscale` is a **Serve** by default. Funnel is opt-in per Ingress.

---

## How it's wired here

The **tailscale-operator v1.98.3** (namespace `tailscale`) watches all `Ingress` resources across the cluster. For each Ingress with `ingressClassName: tailscale` it:

1. Mints an auth key via OAuth (stored in a Secret it creates).
2. Spawns a **proxy pod** named `ts-<ingress-name>-<hash>-0` that joins the tailnet as a device tagged `tag:k8s`.
3. The proxy pod negotiates a **Let's Encrypt certificate** for `<host>.stoat-perch.ts.net`.
4. Inbound HTTPS traffic hits the proxy pod → forwarded to the `backend.service` in the Ingress spec.

There are currently ~14 such proxy pods (one per Ingress). Each proxy pod is its own tailnet device.

### Flipping Serve → Funnel

Adding a single annotation to an Ingress is all it takes:

```yaml
metadata:
  annotations:
    tailscale.com/funnel: "true"
```

The operator detects the annotation change and reconfigures the proxy pod automatically. No rebuild or redeploy of the app needed.

---

## One-time setup

These three things must be done **once** in the Tailscale admin console before any Funnel works. They are **manual steps outside any repo** — the operator cannot do them for you.

### 1. Enable HTTPS Certificates + MagicDNS

Admin console → **DNS** → enable:
- **MagicDNS** (required for `<host>.stoat-perch.ts.net` names to resolve)
- **HTTPS Certificates** (required for trusted TLS — without this, every Funnel URL shows "your connection is not secure")

### 2. Add `nodeAttrs` funnel grant in the ACL

Admin console → **Access Controls** → add to the JSON ACL:

```json
"nodeAttrs": [
  { "target": ["autogroup:member"], "attr": ["funnel"] },
  { "target": ["tag:k8s"], "attr": ["funnel"] }
]
```

**Critical gotcha:** `autogroup:member` covers human users but does **not** cover tagged devices. The operator's proxy pods are tagged `tag:k8s`, so they are explicitly not members. Without the second entry (`"target": ["tag:k8s"]`), the Funnel annotation is silently ignored and the app stays tailnet-private.

Both entries are required. The operator handles the rest automatically.

---

## Funnel a new app

Follow this checklist each time you want to expose an app publicly.

### Step 1 — Decide on the Ingress strategy

**Recommended pattern:** keep the app on its existing tailnet-private Ingress, and add a *separate* Ingress with a different hostname (e.g. `seeni-chores` alongside `chores`) with the Funnel annotation. This gives you two URLs:

- `chores.stoat-perch.ts.net` — tailnet-private, no risk of accidental public access
- `seeni-chores.stoat-perch.ts.net` — public

Avoid removing the private Ingress — you want the on-tailnet fast path to stay available.

**For Immich specifically:** never Funnel Immich directly — use [immich-public-proxy](https://github.com/seenimurugan/immich-public-proxy) so only explicitly-shared albums are public.

### Step 2 — Add the Funnel Ingress manifest

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: <app>-funnel          # e.g. chores-funnel
  namespace: homelab
  annotations:
    tailscale.com/funnel: "true"
spec:
  ingressClassName: tailscale
  rules:
    - host: seeni-<app>       # e.g. seeni-chores → seeni-chores.stoat-perch.ts.net
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: <app>   # same Service the private Ingress uses
                port:
                  number: <port>
```

### Step 3 — Deploy

```bash
kubectl apply -f <app>-funnel-ingress.yaml
```

### Step 4 — Watch the operator spawn the proxy pod

```bash
kubectl get pods -n tailscale -w
# Expect a new pod: ts-seeni-<app>-<hash>-0
```

### Step 5 — Verify proxy is serving with Funnel enabled

```bash
kubectl exec -n tailscale <ts-seeni-app-pod> -- tailscale serve status
# Look for "Funnel on" in the output
```

---

## Verify public reach

**Always test from a device that is NOT on the tailnet** — e.g. a phone on cellular data, or a laptop with Tailscale disabled.

```bash
# From off-tailnet:
curl -I https://seeni-<app>.stoat-perch.ts.net
# Expect: HTTP/2 200 (or appropriate redirect)
```

**Why not test from a tailnet device?** MagicDNS routes `<host>.stoat-perch.ts.net` directly to the Tailscale node's private Serve listener when you're on the tailnet. This bypasses the public Funnel path entirely and can show a cert warning — not because Funnel is broken, but because you're hitting Serve instead. Only an off-tailnet test proves Funnel is working.

---

## Troubleshooting

### "Your connection is not secure" / cert warning

- HTTPS Certificates may not be enabled in the admin console → DNS → enable HTTPS Certificates.
- Cert provisioning is **lazy**: the cert is minted on the first inbound request, so the very first hit can briefly warn before the cert is issued. Wait ~30 seconds and retry.
- If persistent: check proxy pod logs for ACME errors: `kubectl -n tailscale logs ts-seeni-<app>-<hash>-0`

### App is reachable on tailnet but not publicly

- Check the Funnel annotation is present and spelled exactly: `tailscale.com/funnel: "true"` (string `"true"`, not boolean).
- Verify the ACL has the `tag:k8s` nodeAttrs entry (see [One-time setup](#one-time-setup)). A missing `tag:k8s` grant is the most common silent failure.
- Check proxy pod status: `kubectl exec -n tailscale <pod> -- tailscale serve status`

### Proxy pod stuck in Pending / CrashLoopBackOff

- Check operator logs: `kubectl -n tailscale logs -l app=operator`
- OAuth key may have expired — the operator usually regenerates automatically, but a rollout restart can help: `kubectl -n tailscale rollout restart deployment/operator`

### On-tailnet device shows a cert warning when opening the Funnel URL

Expected behaviour — see [Verify public reach](#verify-public-reach). Test from off-tailnet instead.

---

## Limits & security

| Concern | Detail |
|---|---|
| **Allowed ports** | 443, 8443, 10000 only. HTTP-only apps need a TLS terminator in front (the operator handles this). |
| **Transport** | Public Funnel traffic is relayed through Tailscale **DERP** servers (the nearest relay). Fine for web UIs; avoid for heavy media streaming (Jellyfin direct play, large file downloads) — use tailnet Serve for those. |
| **Device cap** | Free Personal plan: ~100 tailnet devices / 3 users. Each Funnel'd Ingress = one extra proxy pod = one extra device. Many Funnels are feasible, but monitor device count at admin console → Machines. |
| **Public attack surface** | Every Funnel'd hostname is reachable by anyone on the internet. Change default passwords before enabling Funnel. Prefer narrow-scope proxies (like immich-public-proxy) over Funnelling full admin UIs. |
| **No auth on Funnel** | Tailscale does not add authentication at the Funnel layer — that's your app's responsibility. |

---

## Current Funnel'd apps

| Public URL | Tailscale host | Private URL | What it exposes |
|---|---|---|---|
| https://seeni-chores.stoat-perch.ts.net | `seeni-chores` | https://chores.stoat-perch.ts.net | Kids chore tracker (full app — change password before sharing) |
| https://seeni-photos.stoat-perch.ts.net | `seeni-photos` | https://immich.stoat-perch.ts.net | **immich-public-proxy** only — shared albums, no admin access |

The private tailnet URLs (`chores`, `immich`) are not Funnel'd and remain accessible only on the tailnet.
