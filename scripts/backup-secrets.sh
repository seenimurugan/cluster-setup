#!/bin/bash
# backup-secrets.sh — encrypted offline DR dump of ALL Kubernetes secrets.
#
# PART (a) of the homelab secrets disaster-recovery design.
#
# What it does:
#   1. Dumps every Secret across the DR-relevant namespaces
#      (homelab, monitoring, tailscale, default, kube-system) via
#      `kubectl get secret -o yaml`. This INCLUDES the sealed-secrets
#      controller's sealing key in kube-system (label
#      sealedsecrets.bitnami.com/sealed-secrets-key) once that controller
#      is installed — that key is DR-CRITICAL (without it, the SealedSecrets
#      committed to git cannot be decrypted on a rebuilt cluster).
#   2. Pipes the combined YAML through `age -r <recipient-pubkey>`,
#      encrypting it to the OFFLINE DR public key
#      (secrets-dr/age-recipient.pub). The matching PRIVATE key lives
#      OFFLINE (~/homelab-secrets-age-key.txt → user moves it to cold
#      storage); it is NEVER on the cluster or in git.
#   3. Writes secrets-<date>.age atomically (.tmp → mv) to
#      $HDD_BACKUP_ROOT/secrets/ on the backup HDD.
#
# This dump is READ-ONLY against the cluster (`kubectl get`). It NEVER
# mutates, restarts, or rolls any workload.
#
# Decrypt later with the offline private key:
#   age -d -i ~/homelab-secrets-age-key.txt secrets-<date>.age | kubectl apply -f -
#
# Portable: paths are .env-driven (HOMELAB_HDD_PATH), mirrors backup-immich.sh.

set -uo pipefail

# Load parent .env if present (so HOMELAB_HDD_PATH / HOMELAB_NAMESPACE override defaults)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
fi

# ============================================================================
# CONFIG
# ============================================================================
# Namespaces to dump. Order is informational only.
NAMESPACES_DEFAULT="homelab monitoring tailscale default kube-system"
SECRET_NAMESPACES="${SECRET_BACKUP_NAMESPACES:-$NAMESPACES_DEFAULT}"

# Primary backup target = homelab-backup-hdd (3TB HFS+, always connected).
HDD_BACKUP_ROOT="${HOMELAB_HDD_PATH:-/Volumes/homelab-backup-hdd}/backups"
SECRETS_DIR="$HDD_BACKUP_ROOT/secrets"
KEEP_SECRETS="${SECRET_BACKUP_KEEP:-12}"   # encrypted dumps to retain

KUBECTL="${KUBECTL_BIN:-/opt/homebrew/bin/kubectl}"
AGE="${AGE_BIN:-/opt/homebrew/bin/age}"

# age recipient public key. Default: the committed DR pubkey alongside this repo.
RECIPIENT_FILE="${AGE_RECIPIENT_FILE:-${SCRIPT_DIR}/../secrets-dr/age-recipient.pub}"

DATE=$(date +%Y%m%d-%H%M%S)
LOG="${SCRIPT_DIR}/backup-secrets.log"
exec >> "$LOG" 2>&1

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*"; }

log "=== Secrets backup run starting === namespaces=\"$SECRET_NAMESPACES\""

# ── Pre-flight: tooling ──────────────────────────────────────────────────────
if [ ! -x "$KUBECTL" ] && ! command -v "$KUBECTL" >/dev/null 2>&1; then
  log "ERROR: event=secrets_backup.preflight outcome=abort reason=kubectl-not-found path=$KUBECTL"
  exit 1
fi
if [ ! -x "$AGE" ] && ! command -v "$AGE" >/dev/null 2>&1; then
  log "ERROR: event=secrets_backup.preflight outcome=abort reason=age-not-found path=$AGE action=brew-install-age"
  exit 1
fi

# ── Pre-flight: recipient public key must exist (encrypt-only; never need priv) ─
if [ ! -f "$RECIPIENT_FILE" ]; then
  log "ERROR: event=secrets_backup.preflight outcome=abort reason=age-recipient-pubkey-missing path=$RECIPIENT_FILE"
  exit 1
fi
RECIPIENT="$(grep -Eo 'age1[0-9a-z]+' "$RECIPIENT_FILE" | head -1)"
if [ -z "$RECIPIENT" ]; then
  log "ERROR: event=secrets_backup.preflight outcome=abort reason=no-age-recipient-parsed path=$RECIPIENT_FILE"
  exit 1
fi
log "INFO: event=secrets_backup.recipient recipient=${RECIPIENT} source=$RECIPIENT_FILE"

# ── Pre-flight: backup HDD must be mounted ────────────────────────────────────
if [ ! -d "$(dirname "$HDD_BACKUP_ROOT")" ]; then
  log "ERROR: event=secrets_backup.preflight outcome=abort reason=backup-hdd-not-mounted path=$(dirname "$HDD_BACKUP_ROOT")"
  exit 1
fi
mkdir -p "$SECRETS_DIR"

# ── Pre-flight: cluster reachable ─────────────────────────────────────────────
if ! "$KUBECTL" cluster-info >/dev/null 2>&1; then
  log "ERROR: event=secrets_backup.preflight outcome=abort reason=cluster-unreachable"
  exit 1
fi

OUT="$SECRETS_DIR/secrets-$DATE.age"
TMP="${OUT}.tmp"

# ── Dump → encrypt (atomic) ───────────────────────────────────────────────────
# Build a single multi-document YAML stream across namespaces, then encrypt the
# WHOLE stream once to the recipient public key. We write to a plaintext FIFO?
# No — we keep plaintext only in-memory in the pipe; nothing unencrypted ever
# touches disk. The combined dump is assembled into a temp file in a RAM-ish
# location only if needed; here we stream namespace-by-namespace through age.
#
# We capture per-namespace YAML, concatenate with `---` separators, and feed the
# concatenation into a single age process. kubectl `get -o yaml` for a list adds
# its own `kind: List`, so we separate namespaces with explicit document markers.

# Resolve which namespaces are present and count secrets BEFORE the encrypt
# pipeline, so counters live in the parent shell (a pipeline subshell cannot
# export variables back to the parent). Per-namespace logs are emitted here.
PRESENT_NS=""
NS_OK=0
NS_FAIL=0
SECRET_COUNT=0
for ns in $SECRET_NAMESPACES; do
  if ! "$KUBECTL" get namespace "$ns" >/dev/null 2>&1; then
    log "WARN: event=secrets_backup.namespace outcome=skip ns=$ns reason=namespace-not-found"
    NS_FAIL=$((NS_FAIL + 1))
    continue
  fi
  NCOUNT=$("$KUBECTL" -n "$ns" get secret --no-headers 2>/dev/null | wc -l | tr -d ' ')
  PRESENT_NS="$PRESENT_NS $ns"
  NS_OK=$((NS_OK + 1))
  SECRET_COUNT=$((SECRET_COUNT + NCOUNT))
  log "INFO: event=secrets_backup.namespace outcome=success ns=$ns secrets=$NCOUNT"
done

if [ "$NS_OK" -eq 0 ]; then
  log "ERROR: event=secrets_backup.dump outcome=abort reason=no-namespaces-resolved"
  exit 1
fi

# Assemble plaintext in a pipeline; never write plaintext to disk. The plaintext
# exists only in the in-memory pipe between kubectl and age.
{
  echo "# homelab secrets DR dump"
  echo "# generated=$DATE"
  echo "# namespaces=$PRESENT_NS"
  for ns in $PRESENT_NS; do
    echo "---"
    echo "# namespace: $ns"
    "$KUBECTL" -n "$ns" get secret -o yaml 2>/dev/null
  done
} | "$AGE" -r "$RECIPIENT" -o "$TMP"
AGE_RC=${PIPESTATUS[1]}

if [ "$AGE_RC" -ne 0 ] || [ ! -s "$TMP" ]; then
  rm -f "$TMP"
  log "ERROR: event=secrets_backup.encrypt outcome=failed age_rc=$AGE_RC dest=$OUT action=tmp-removed-previous-good-dump-preserved"
  exit 1
fi

mv "$TMP" "$OUT"
log "INFO: event=secrets_backup.encrypt outcome=success dest=$OUT size=$(du -h "$OUT" | cut -f1) namespaces_ok=$NS_OK namespaces_failed=$NS_FAIL secrets_dumped=$SECRET_COUNT"

# ── Sealed-secrets controller key presence check (DR-CRITICAL) ────────────────
# If the controller is installed, surface whether its sealing key was captured
# (it lives in kube-system, which is in the default namespace list).
SS_KEY_COUNT=$("$KUBECTL" -n kube-system get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "${SS_KEY_COUNT:-0}" -gt 0 ]; then
  if echo "$SECRET_NAMESPACES" | grep -qw kube-system; then
    log "INFO: event=secrets_backup.sealing_key outcome=captured count=$SS_KEY_COUNT reason=kube-system-in-dump-DR-critical-key-included"
  else
    log "WARN: event=secrets_backup.sealing_key outcome=NOT_captured count=$SS_KEY_COUNT reason=kube-system-not-in-SECRET_BACKUP_NAMESPACES action=add-kube-system"
  fi
else
  log "INFO: event=secrets_backup.sealing_key outcome=absent reason=sealed-secrets-controller-not-installed-yet"
fi

# ── Prune old dumps (only after a successful write this run) ──────────────────
log "INFO: event=secrets_backup.prune.start keep=$KEEP_SECRETS"
( cd "$SECRETS_DIR" && ls -t secrets-*.age 2>/dev/null | tail -n +$((KEEP_SECRETS + 1)) | while read -r old; do
    log "INFO: event=secrets_backup.prune file=$old"
    rm -f "$old"
  done )

log "INFO: event=secrets_backup.run_complete outcome=success dest=$OUT"
echo ""
exit 0
