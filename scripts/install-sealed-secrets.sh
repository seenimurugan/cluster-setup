#!/bin/bash
# install-sealed-secrets.sh — install the bitnami-labs sealed-secrets controller.
#
# PART (b) of the homelab secrets disaster-recovery design (see
# secrets-dr/README.md).
#
# The controller runs in kube-system and materializes real Secrets from the
# SealedSecret YAMLs each app repo commits under k8s/sealed/. Installation is
# ADDITIVE — it does not touch any existing Secret or workload. Re-runnable
# (helm upgrade --install).
#
# DR-CRITICAL: after install, the controller's sealing key lives in
# kube-system labelled sealedsecrets.bitnami.com/sealed-secrets-key. It MUST be
# captured by scripts/backup-secrets.sh into the offline encrypted dump,
# otherwise committed SealedSecrets cannot be decrypted on a rebuilt cluster.

set -euo pipefail

CONTROLLER_NAME="${SEALED_SECRETS_NAME:-sealed-secrets-controller}"
NAMESPACE="${SEALED_SECRETS_NS:-kube-system}"
CHART_VERSION="${SEALED_SECRETS_CHART_VERSION:-}"   # empty = latest

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

if ! command -v helm >/dev/null 2>&1; then
  log "ERROR: event=sealed_secrets.install outcome=abort reason=helm-not-found"
  exit 1
fi
if ! command -v kubeseal >/dev/null 2>&1; then
  log "WARN: event=sealed_secrets.install reason=kubeseal-not-found action=brew-install-kubeseal (needed to seal secrets, not to install controller)"
fi

log "INFO: event=sealed_secrets.install.start controller=$CONTROLLER_NAME ns=$NAMESPACE"

helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets >/dev/null 2>&1 || true
helm repo update sealed-secrets >/dev/null 2>&1

VERSION_ARGS=()
[ -n "$CHART_VERSION" ] && VERSION_ARGS=(--version "$CHART_VERSION")

helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace "$NAMESPACE" \
  --set fullnameOverride="$CONTROLLER_NAME" \
  "${VERSION_ARGS[@]}" \
  --wait --timeout 180s

log "INFO: event=sealed_secrets.install.done outcome=success"

# Surface the DR-critical sealing key presence.
KEY_COUNT=$(kubectl -n "$NAMESPACE" get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key --no-headers 2>/dev/null | wc -l | tr -d ' ')
log "INFO: event=sealed_secrets.sealing_key count=${KEY_COUNT} ns=$NAMESPACE note=back-up-via-scripts/backup-secrets.sh-DR-critical"

log "INFO: event=sealed_secrets.install.complete controller=$CONTROLLER_NAME ns=$NAMESPACE outcome=success"
