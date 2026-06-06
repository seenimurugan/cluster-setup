# Secrets Disaster Recovery

Two complementary layers protect every Kubernetes Secret in the homelab so a
full cluster loss (or a fresh Mac Mini rebuild) is recoverable.

## Layer (a) — Encrypted offline dump  (`age`)

`scripts/backup-secrets.sh` dumps **all** Secrets across the DR-relevant
namespaces (`homelab`, `monitoring`, `tailscale`, `default`, `kube-system`)
with `kubectl get secret -o yaml`, encrypts the whole stream to an **`age`
public key**, and writes `secrets-<date>.age` to
`$HOMELAB_HDD_PATH/backups/secrets/` on the backup HDD (atomic `.tmp`→`mv`,
HDD guard, structured logging — same shape as `backup-immich.sh`).

### The DR key — OFFLINE, never in git

- **Public (recipient) key:** `age-recipient.pub` (this directory). Safe to
  commit. The backup script encrypts *to* it. It cannot decrypt anything.
- **Private (identity) key:** written once by the operator to
  `~/homelab-secrets-age-key.txt` (mode `600`).

  > ⚠️ **MOVE THE PRIVATE KEY OFFLINE.** Copy
  > `~/homelab-secrets-age-key.txt` to cold storage (password manager,
  > hardware key, printed paper, encrypted USB stored off-machine) and then
  > delete it from the Mac, OR at minimum keep it out of any synced/cloud
  > folder and out of every git repo. Without this key the encrypted dumps —
  > **and the committed SealedSecrets (layer b)** — are unrecoverable. With
  > it, anyone can decrypt every homelab secret. Treat it like a root
  > credential.

### Restore (after a rebuild)

```bash
# Decrypt the latest dump and re-apply every secret:
age -d -i ~/homelab-secrets-age-key.txt \
    /Volumes/homelab-backup-hdd/backups/secrets/secrets-<date>.age \
  | kubectl apply -f -
```

### Run it

```bash
cd cluster-setup
./scripts/backup-secrets.sh          # reads ../.env for HOMELAB_HDD_PATH
tail -f scripts/backup-secrets.log   # structured event=... lines
```

Schedule it next to the existing weekly `backup-immich.sh` launchd job.

## Layer (b) — Sealed-Secrets  (GitOps, encrypted-in-git)

The **sealed-secrets controller** (bitnami-labs) runs in `kube-system`. Each
app's real `Secret` is sealed with `kubeseal` into a `SealedSecret` YAML that
is **safe to commit to git** — only the in-cluster controller can decrypt it.
The controller materializes the real `Secret` when the `SealedSecret` is
applied. Sealing an *existing* secret reproduces identical values, so **no
Secret changes and no pod restarts**.

Each app repo holds its own SealedSecrets under `k8s/sealed/` and its
`deploy.sh` applies them. The legacy `.env`→`create secret` step is kept as a
**documented fallback** (not deleted) to avoid a risky big-bang cutover.

### The controller's sealing key is DR-CRITICAL

The controller stores its private sealing key as a Secret in `kube-system`
labelled `sealedsecrets.bitnami.com/sealed-secrets-key`. **Without this key,
every committed SealedSecret is undecryptable on a rebuilt cluster.**

`backup-secrets.sh` dumps `kube-system`, so the sealing key **is captured in
the encrypted offline dump** (the script logs
`event=secrets_backup.sealing_key outcome=captured`). This key MUST live in
the offline backup. To restore sealing capability on a new cluster, apply the
backed-up sealing key *before* the controller generates a fresh one, then
restart the controller:

```bash
age -d -i ~/homelab-secrets-age-key.txt secrets-<date>.age \
  | kubectl apply -n kube-system -f -      # includes the sealing key
kubectl -n kube-system rollout restart deploy sealed-secrets
```

You can also export just the sealing key for a standalone copy:

```bash
kubectl -n kube-system get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml \
  > sealed-secrets-key-backup.yaml   # KEEP OFFLINE — treat as root cred
```
