#!/usr/bin/env bash
# 10-orbstack.sh — verify OrbStack is running and k3s is enabled.
# Does NOT try to auto-launch OrbStack; instructs the user instead.
set -euo pipefail

if ! command -v orb &>/dev/null && ! [ -d "/Applications/OrbStack.app" ]; then
  cat <<EOF
ERROR: OrbStack is not installed.
       Install from https://orbstack.dev and launch it once.
       Then enable Kubernetes (k3s) from Settings → Kubernetes.
EOF
  exit 1
fi

# OrbStack writes a kubeconfig to ~/.orbstack/k8s/config.yml (default context
# name: "orbstack"). Use the user's KUBECONFIG if set, otherwise fall back.
if ! kubectl cluster-info &>/dev/null; then
  cat <<EOF
ERROR: kubectl cannot reach a Kubernetes cluster.

       Open OrbStack → Settings → Kubernetes → enable.
       Verify with:  kubectl get nodes

       (If you have multiple kubeconfigs, run:
          kubectl config use-context orbstack
       )
EOF
  exit 1
fi

# Sanity: confirm we're talking to a k3s/OrbStack node, not someone else's
# production cluster.
CTX="$(kubectl config current-context 2>/dev/null || echo unknown)"
NODE="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo unknown)"
echo "[orbstack] kubectl context: $CTX"
echo "[orbstack] cluster node:    $NODE"

if [[ "$CTX" != *orbstack* ]] && [[ "$NODE" != *orbstack* ]]; then
  echo ""
  echo "WARN: current context does not look like an OrbStack k3s cluster."
  echo "      Refusing to continue — switch with:  kubectl config use-context orbstack"
  echo "      Or set ALLOW_NON_ORBSTACK=1 to override (advanced)."
  if [ "${ALLOW_NON_ORBSTACK:-0}" != "1" ]; then
    exit 1
  fi
fi

echo "[orbstack] OK."
